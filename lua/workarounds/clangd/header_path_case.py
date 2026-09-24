"""Bounded physical-name VFS for the verified Windows clangd header-case bug.

Only file self-mappings are supported. This is not arbitrary VFS support.
Directory enumeration reads names/attributes, never source file contents.
"""
import argparse
import ctypes
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import sys
import time

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).absolute().parents[3] / 'tools'))
from build_hot_super_unity_cdb import write_if_changed
from cdb_argv import normalize_cdb
from clangd_diagnostic_compat import probe_clangd

IS_WINDOWS = os.name == 'nt'
MAX_FILES = 250_000
MAX_ENTRIES = 1_000_000
MAX_SECONDS = 120
MAX_BYTES = 96 * 1024 * 1024
EXCLUDED = {'.git', 'binaries', 'content', 'deriveddatacache', 'saved', 'node_modules', 'dist', 'target'}
EXTENSIONS = {'', '.h', '.hh', '.hpp', '.hxx', '.inl', '.inc', '.ipp', '.tpp', '.def', '.cuh'}
FLAGS = {'version': 0, 'case-sensitive': False, 'use-external-names': True, 'fallthrough': True}
OWNED = re.compile(r'header-path-case\.([0-9a-f]{64})\.json\Z')


def supported_version(output):
    match = re.search(r'\bclangd version (\d+)\.(\d+)\.(\d+)\b', output)
    return bool(match and match.groups() == ('22', '1', '5'))


def absolute(path, directory=''):
    if not isinstance(path, str) or not path or '\0' in path:
        raise ValueError('invalid-header-path')
    return os.path.abspath(os.path.join(directory, path)).replace('\\', '/')


def _long_name(path):
    # Expand the native 8.3 spelling only. Component checks below still reject
    # links/reparse points; GetFinalPathNameByHandle/realpath are not used.
    function = ctypes.WinDLL('kernel32', use_last_error=True).GetLongPathNameW
    function.argtypes = (ctypes.c_wchar_p, ctypes.c_wchar_p, ctypes.c_uint32)
    function.restype = ctypes.c_uint32
    buffer = ctypes.create_unicode_buffer(32768)
    length = function(path, buffer, len(buffer))
    if not length or length >= len(buffer):
        raise ValueError('unconfirmed-short-header-path: ' + path)
    return absolute(buffer.value)


class Names:
    """One bounded enumeration cache, retaining lexical identity across links."""
    def __init__(self):
        self.directories, self.paths = {}, {}
        self.entries = 0
        self.started = time.monotonic()

    def check(self):
        if self.entries > MAX_ENTRIES or time.monotonic() - self.started > MAX_SECONDS:
            raise ValueError('header-path-enumeration-limit')

    def directory(self, path):
        if path not in self.directories:
            self.check()
            values = {}
            with os.scandir(path) as stream:
                for entry in stream:
                    self.entries += 1
                    self.check()
                    folded = entry.name.casefold()
                    if folded in values:
                        raise ValueError('header-path-case-collision: ' + entry.path)
                    values[folded] = entry
            self.directories[path] = values
        return self.directories[path]

    @staticmethod
    def attributes(entry):
        info = entry.stat(follow_symlinks=False)
        if stat.S_ISLNK(info.st_mode) or getattr(info, 'st_file_attributes', 0) & 0x400:
            raise ValueError('unsupported-header-path-link: ' + entry.path)
        return info

    def physical(self, path, kind=None):
        path = absolute(str(path))
        folded = path.casefold()
        if folded not in self.paths:
            parent, name = os.path.split(path)
            if not name or parent == path:
                physical = path
                info = os.stat(path, follow_symlinks=False)
            else:
                parent = self.physical(parent, 'directory')
                entry = self.directory(parent).get(name.casefold())
                if entry is None:
                    if IS_WINDOWS and '~' in name:
                        expanded = _long_name(path)
                        if expanded.casefold() != folded:
                            return self.physical(expanded, kind)
                    raise FileNotFoundError(path)
                info = self.attributes(entry)
                physical = (parent.rstrip('/') + '/' + entry.name)
            self.paths[folded] = physical, info
        physical, info = self.paths[folded]
        if kind == 'directory' and not stat.S_ISDIR(info.st_mode):
            raise ValueError('expected-header-directory: ' + path)
        if kind == 'file' and not stat.S_ISREG(info.st_mode):
            raise ValueError('expected-regular-header-file: ' + path)
        return physical


def _json(raw):
    def unique(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError('duplicate-overlay-json-key: ' + key)
            result[key] = value
        return result
    return json.loads(raw, object_pairs_hook=unique)


def validate_owned_overlay(path):
    """Return canonical file->same-file mapping, or raise; never recurse roots."""
    path = Path(path)
    match = OWNED.fullmatch(path.name)
    if not path.is_absolute() or not match:
        raise ValueError('not-owned-header-overlay: ' + str(path))
    if path.stat().st_size > MAX_BYTES:
        raise ValueError('header-overlay-size-limit')
    raw = path.read_bytes()
    if hashlib.sha256(raw).hexdigest() != match.group(1):
        raise ValueError('header-overlay-content-hash-mismatch')
    value = _json(raw)
    if not isinstance(value, dict) or set(value) != {*FLAGS, 'roots'}:
        raise ValueError('unsupported-header-overlay-fields')
    if any(type(value[k]) is not type(v) or value[k] != v for k, v in FLAGS.items()):
        raise ValueError('unsupported-header-overlay-flags')
    if not isinstance(value['roots'], list) or not value['roots'] or len(value['roots']) > MAX_FILES:
        raise ValueError('header-overlay-file-limit')
    names, mapping, folded = Names(), {}, set()
    for item in value['roots']:
        if not isinstance(item, dict) or set(item) != {'type', 'name', 'external-contents'} or item['type'] != 'file':
            raise ValueError('unsupported-header-overlay-node')
        name = item['name']
        if not isinstance(name, str) or name != item['external-contents'] or not os.path.isabs(name):
            raise ValueError('header-overlay-is-not-self-map')
        if name.casefold() in folded:
            raise ValueError('header-path-case-collision: ' + name)
        if names.physical(name, 'file') != name:
            raise ValueError('noncanonical-header-overlay-name: ' + name)
        folded.add(name.casefold())
        mapping[name] = name
    return mapping


def _read(cdb):
    entries = json.loads(Path(cdb).read_text(encoding='utf-8-sig'))
    if not isinstance(entries, list):
        raise ValueError('compilation database must be an array')
    return entries


def _owner_dir(cdb, logical_cdb):
    logical = Path(logical_cdb or cdb)
    if not logical.is_absolute():
        raise ValueError('logical CDB must be absolute')
    return logical.parent / 'header-path-case'


def _without_owned(entries, owner):
    result, removed, verified = [], 0, set()
    for original in entries:
        entry = normalize_cdb([original])[0][0]
        args = entry['arguments']
        if any(not isinstance(a, str) or '\0' in a for a in args):
            raise ValueError('invalid-compile-arguments')
        end = args.index('--') if '--' in args else len(args)
        output, index, count = [args[0]], 1, 0
        while index < end:
            arg = args[index]
            if arg.startswith('-ivfsoverlay'):
                if arg != '-ivfsoverlay' or index + 1 >= end:
                    raise ValueError('unsupported-header-overlay-option')
                path = Path(args[index + 1])
                if not path.is_absolute() or absolute(str(path.parent)).casefold() != absolute(str(owner)).casefold():
                    raise ValueError('foreign-header-overlay')
                if str(path) not in verified:
                    validate_owned_overlay(path)
                    verified.add(str(path))
                count += 1
                if count > 1:
                    raise ValueError('duplicate-owned-header-overlay')
                index += 2
            else:
                output.append(arg); index += 1
        output.extend(args[end:])
        entry['arguments'] = output
        result.append(entry if count else original)
        removed += count
    return result, removed


def _gate(entries, version):
    reason = None if IS_WINDOWS and supported_version(version) else 'unsupported-host-or-clangd-version'
    if reason:
        for entry in normalize_cdb(entries)[0]:
            if any('header-path-case.' in a for a in entry['arguments']):
                raise ValueError('stale-owned-overlay: ' + reason)
    return reason


def strip_owned(cdb_path, version_output, logical_cdb=None):
    entries = _read(cdb_path)
    reason = _gate(entries, version_output)
    if reason:
        return {'changed': False, 'removed': 0, 'reason': reason}
    output, removed = _without_owned(entries, _owner_dir(cdb_path, logical_cdb))
    changed = bool(removed) and write_if_changed(str(cdb_path), json.dumps(output, ensure_ascii=False))
    return {'changed': changed, 'removed': removed}


def _collect(entries, owner, scope_roots=None):
    names, roots, required, missing = Names(), set(), set(), set()
    owner_key = absolute(str(owner)).casefold()
    scopes = [names.physical(root, 'directory') for root in scope_roots or []]
    thirdparty, foreign = set(), set()

    def within(path, root):
        return path.casefold() == root.casefold() or path.casefold().startswith(root.casefold().rstrip('/') + '/')

    def directory(path):
        # Scope only the confirmed first-party header bug. Search paths remain
        # untouched; other files continue through the real filesystem.
        if 'thirdparty' in path.casefold().split('/'):
            thirdparty.add(path); return
        if scopes and not any(within(path, root) or within(root, path) for root in scopes):
            foreign.add(path); return
        try:
            value = names.physical(path, 'directory')
        except FileNotFoundError:
            missing.add(path); return
        if value.rstrip('/') == Path(value).anchor.rstrip('/\\'):
            raise ValueError('header-path-drive-root-scan')
        if value.casefold() == owner_key or value.casefold().startswith(owner_key + '/'):
            raise ValueError('owned-overlay-directory-is-an-include-root')
        if scopes and not any(within(value, root) for root in scopes):
            roots.update(root for root in scopes if within(root, value))
        else:
            roots.add(value)

    def explicit_file(path):
        physical = names.physical(path, 'file')
        lexical_name, real_name = os.path.basename(path), os.path.basename(physical)
        if lexical_name != real_name and lexical_name.casefold() == real_name.casefold():
            required.add(physical)
        directory(os.path.dirname(physical))
        return physical

    for entry in normalize_cdb(entries)[0]:
        cwd = entry.get('directory')
        if not isinstance(cwd, str) or not os.path.isabs(cwd):
            raise ValueError('unconfirmed-working-directory')
        explicit_file(absolute(entry['file'], cwd))
        args = entry['arguments']; end = args.index('--') if '--' in args else len(args)
        include, forced, index = [], [], 1
        while index < end:
            arg = args[index]
            if arg.startswith(('@', '--config', '-fmodule', '-iprefix', '-iwithprefix', '-ivfsoverlay',
                               '-vfsoverlay', '/clang:', '-Xpreprocessor', '-internal-', '-iframework', '-F')) or arg == '-Xclang':
                raise ValueError('unsupported-indirect-header-input: ' + arg)
            option, value = None, None
            for flag in ('-isystem', '-iquote', '-idirafter', '-include-pch', '-include-pth', '-include', '-imacros',
                         '-isysroot', '--sysroot', '-resource-dir', '-I', '/FI', '/I'):
                if arg == flag:
                    if index + 1 >= end: raise ValueError('incomplete-header-option: ' + arg)
                    option, value = flag, args[index + 1]; index += 1; break
                if arg.startswith(flag) and len(arg) > len(flag):
                    option, value = flag, arg[len(flag):].removeprefix('='); break
            if option in ('-include-pch', '-include-pth') or arg.startswith(('/Yu', '/Yc', '/Fp')):
                raise ValueError('binary-pch-header-case-unsupported')
            if option in ('-I', '/I', '-isystem', '-iquote', '-idirafter'):
                if value.startswith(('=', '$')): raise ValueError('unexpanded-header-search-path')
                include.append(absolute(value, cwd)); directory(include[-1])
            elif option in ('-include', '/FI', '-imacros'):
                forced.append(value)
            elif option in ('--sysroot', '-isysroot'):
                foreign.add(absolute(os.path.join(value, 'usr', 'include'), cwd))
            elif option == '-resource-dir':
                foreign.add(absolute(os.path.join(value, 'include'), cwd))
            index += 1
        for value in forced:
            candidates = [absolute(value, cwd)] if os.path.isabs(value) else [absolute(value, p) for p in [cwd, *include]]
            for candidate in candidates:
                try: explicit_file(candidate); break
                except FileNotFoundError: continue
            else: raise ValueError('forced-header-unavailable: ' + value)
    # A declared child beneath a skipped directory remains its own explicit root.
    selected = []
    for root in sorted(roots, key=lambda p: (len(p.split('/')), p.casefold(), p)):
        if not any(root.casefold().startswith(parent.casefold() + '/')
                   and not any(part.casefold() in EXCLUDED for part in root[len(parent) + 1:].split('/')) for parent in selected):
            selected.append(root)
    mapping = {path: path for path in required}
    stack = list(selected)
    while stack:
        directory_path = stack.pop()
        for entry in names.directory(directory_path).values():
            path = directory_path.rstrip('/') + '/' + entry.name
            if entry.name.casefold() == 'thirdparty':
                thirdparty.add(path); continue
            if path.casefold() == owner_key or entry.name.casefold() in EXCLUDED:
                continue
            info = names.attributes(entry)
            if stat.S_ISDIR(info.st_mode):
                stack.append(path)
            elif stat.S_ISREG(info.st_mode) and Path(entry.name).suffix.lower() in EXTENSIONS:
                mapping[path] = path
                if len(mapping) > MAX_FILES: raise ValueError('header-overlay-file-limit')
    return mapping, {'scan_roots': len(selected), 'directories': len(names.directories),
                     'enumerated_entries': names.entries, 'missing_include_roots': len(missing),
                     'scope_roots': scopes, 'explicit_case_aliases': len(required),
                     'unmapped_thirdparty_roots': len(thirdparty), 'unmapped_foreign_roots': len(foreign),
                     'scan_seconds': time.monotonic() - names.started}


def apply_policy(cdb_path, version_output, logical_cdb=None, scope_roots=None):
    started = time.monotonic()
    entries = _read(cdb_path)
    reason = _gate(entries, version_output)
    if reason: return {'changed': False, 'reason': reason}
    owner = _owner_dir(cdb_path, logical_cdb)
    stripped, _ = _without_owned(entries, owner)
    mapping, report = _collect(stripped, owner, scope_roots)
    if not mapping:
        changed = stripped != entries and write_if_changed(str(cdb_path), json.dumps(stripped, ensure_ascii=False))
        return dict(report, changed=bool(changed), files=0, reason='no-in-scope-header-case-inputs',
                    entries=len(entries), total_seconds=time.monotonic() - started)
    payload = dict(FLAGS, roots=[{'type': 'file', 'name': name, 'external-contents': name}
                               for name in sorted(mapping, key=lambda p: (p.casefold(), p))])
    raw = json.dumps(payload, ensure_ascii=False, separators=(',', ':')).encode('utf-8')
    if len(raw) > MAX_BYTES: raise ValueError('header-overlay-size-limit')
    owner.mkdir(parents=True, exist_ok=True)
    overlay = owner / ('header-path-case.' + hashlib.sha256(raw).hexdigest() + '.json')
    if overlay.exists() and overlay.read_bytes() != raw:
        raise ValueError('owned-header-overlay-was-modified')
    write_if_changed(str(overlay), raw.decode('utf-8'))
    transformed = normalize_cdb(stripped)[0]
    for entry in transformed:
        arguments = entry['arguments']
        position = arguments.index('--') if '--' in arguments else len(arguments)
        entry['arguments'] = [*arguments[:position], '-ivfsoverlay', str(overlay), *arguments[position:]]
    changed = transformed != entries and write_if_changed(str(cdb_path), json.dumps(transformed, ensure_ascii=False))
    return dict(report, changed=bool(changed), overlay=str(overlay), files=len(mapping),
                overlay_bytes=len(raw), entries=len(entries), total_seconds=time.monotonic() - started)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('cdb')
    parser.add_argument('--clangd', default='')
    parser.add_argument('--logical-cdb')
    parser.add_argument('--scope-root', action='append', default=[])
    parser.add_argument('--strip-owned', action='store_true')
    args = parser.parse_args()
    version, reason = probe_clangd(args.clangd) if IS_WINDOWS else ('', 'unsupported-host')
    if args.strip_owned:
        result = strip_owned(args.cdb, version if not reason else '', args.logical_cdb)
    else:
        result = apply_policy(args.cdb, version if not reason else '', args.logical_cdb, args.scope_root)
    if reason: result['reason'] = reason
    result.update(clangd=args.clangd, clangd_version=version.strip())
    print('clangd header path casing: ' + json.dumps(result, ensure_ascii=True))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
