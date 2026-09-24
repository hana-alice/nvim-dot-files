"""UE clangd 22.1.5 friend-template workaround; see the sibling Lua owner.

Only textual forced inputs are supported. No UE file, binary PCH, diagnostic,
compiler installation or original argument is modified by this transformation.
"""
import argparse
import collections
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[3] / 'tools'))
from build_hot_super_unity_cdb import write_if_changed
from cdb_argv import normalize_cdb
from clangd_diagnostic_compat import probe_clangd

PREFIX = Path(__file__).with_suffix('.h').resolve()
_CONTENT = ('class FObjectInitializer;\n'
            'template<class T> void InternalConstructor(const FObjectInitializer&);\n')
# The real-engine native index comparison certified this exact header pair.
# Text resembling a declaration is not sufficient context evidence.
_SUPPORTED_HEADERS = {(
    '09b0971f4dc8e962a4f9576a1a001cc8b7f5ea67e85144bea321f95bd5b218c1',
    'dfb8c4aa42f46fd2bac8db123b8a69a4ea1334511b13edc6f5b87344b4d5080d',
)}


def supported_version(output):
    match = re.search(r'\bclangd version (\d+)\.(\d+)\.(\d+)\b', output)
    return bool(match and match.groups() == ('22', '1', '5'))


def canonical(path, directory=''):
    return os.path.normcase(os.path.abspath(os.path.join(directory, str(path))))


def _owns_prefix(arguments, directory):
    end = arguments.index('--') if '--' in arguments else len(arguments)
    own = canonical(PREFIX)
    for index, argument in enumerate(arguments[1:end], 1):
        value = None
        if argument in ('-include', '-include-pch', '-include-pth', '-imacros', '/FI'):
            if index + 1 < end:
                value = arguments[index + 1]
        elif argument.startswith(('-include=', '-imacros=')):
            value = argument.split('=', 1)[1]
        elif argument.startswith('/FI'):
            value = argument[3:]
        elif argument.startswith('-include'):
            value = argument[len('-include'):]
        if value and canonical(value, directory) == own:
            return True
    return False


def _read_entries(cdb_path):
    entries = json.loads(Path(cdb_path).read_text(encoding='utf-8-sig'))
    if not isinstance(entries, list):
        raise ValueError('compilation database must be an array')
    return entries


def _skip(entries, reason):
    for entry in entries:
        structured = normalize_cdb([entry])[0][0]
        if _owns_prefix(structured['arguments'], structured['directory']):
            raise ValueError('stale-owned-prefix: ' + reason)
    return {'changed': False, 'added': 0, 'reason': reason}


def engine_context(engine_root):
    """Only a byte-identical engine header pair with native evidence qualifies."""
    if not engine_root or not Path(engine_root).is_absolute():
        return None, 'unconfirmed-engine-root'
    public = Path(engine_root) / 'Engine/Source/Runtime/CoreUObject/Public'
    try:
        hashes = tuple(hashlib.sha256((public / name).read_bytes()).hexdigest()
                       for name in ('UObject/UObjectGlobals.h', 'UObject/Class.h'))
    except OSError:
        return None, 'engine-coreuobject-headers-unavailable'
    if hashes not in _SUPPORTED_HEADERS:
        return None, 'unverified-engine-header-bytes'
    return canonical(public), None


def forced_input_reason(path, cache):
    key = canonical(path)
    if key not in cache:
        try:
            with open(path, 'rb') as stream:
                head = stream.read(4096)
            if Path(path).suffix.lower() in ('.pch', '.gch', '.pcm', '.pth') or b'\0' in head or head.startswith((b'CPCH', b'BC\xc0\xde')):
                cache[key] = 'binary-forced-input'
            elif any(Path(str(path) + suffix).exists() for suffix in ('.gch', '.pch')):
                cache[key] = 'implicit-binary-pch'
            else:
                cache[key] = None
        except OSError:
            cache[key] = 'forced-input-unavailable'
    return cache[key]


def transform_entry(entry, public_root, forced_cache=None):
    structured = normalize_cdb([entry])[0][0]
    args = structured['arguments']
    directory = structured['directory']
    def reject(reason):
        if _owns_prefix(args, directory):
            raise ValueError('stale-owned-prefix: ' + reason)
        return entry, reason
    if not os.path.isabs(directory):
        return reject('unconfirmed-working-directory')
    if not args or any(not isinstance(arg, str) or '\0' in arg for arg in args):
        raise ValueError('compile arguments must be nonempty NUL-free strings')
    end = args.index('--') if '--' in args else len(args)
    options = args[1:end]
    if any(arg.startswith('@') for arg in options):
        return reject('unexpanded-response-input')
    if any(arg == '-Xclang' or arg.startswith(('--config', '-ivfsoverlay', '-fmodule', '-imacros')) for arg in options):
        return reject('unsupported-indirect-frontend-input')
    if any(arg.startswith(('-include-pch', '-include-pth', '/Yu', '/Yc', '/Fp')) for arg in options):
        return reject('binary-pch-command')
    if '--driver-mode=cl' in options or Path(args[0]).stem.lower() in ('clang-cl', 'cl'):
        return reject('unsupported-driver-mode')
    language, public_seen, forced = None, False, []
    index = 1
    while index < end:
        arg = args[index]
        paired = arg in ('-x', '-I', '-isystem', '-iquote', '-include')
        if paired:
            if index + 1 >= end:
                return reject('incomplete-compile-option')
            value = args[index + 1]
            if arg == '-x':
                language = value
            elif arg == '-include':
                forced.append(canonical(value, directory))
            elif canonical(value, directory) == public_root:
                public_seen = True
            index += 2
            continue
        if arg.startswith('-x') and len(arg) > 2:
            language = arg[2:]
        elif arg.startswith('-I') and len(arg) > 2:
            public_seen |= canonical(arg[2:], directory) == public_root
        elif arg.startswith(('-isystem=', '-iquote=')):
            public_seen |= canonical(arg.split('=', 1)[1], directory) == public_root
        elif arg.startswith('-include='):
            forced.append(canonical(arg.split('=', 1)[1], directory))
        elif arg.startswith(('-include', '/FI')):
            return reject('unsupported-forced-input-spelling')
        index += 1
    suffix = Path(entry['file']).suffix.lower()
    if language not in (None, 'none', 'c++', 'c++-header'):
        return reject('unsupported-language')
    if suffix not in ('.cpp', '.cc', '.cxx', '.c++', '.hpp', '.hh', '.hxx', '.h'):
        return reject('non-c++-source')
    if language in (None, 'none') and suffix == '.h':
        return reject('unconfirmed-header-language')
    if not public_seen:
        return reject('no-coreuobject-include-context')
    cache = forced_cache if forced_cache is not None else {}
    for path in forced:
        reason = forced_input_reason(path, cache)
        if reason:
            return reject(reason)
    own = canonical(PREFIX)
    if own in forced:
        if forced.count(own) != 1:
            return reject('duplicate-prefix-input')
        if forced[0] != own:
            return reject('existing-prefix-not-first')
        return entry, 'already-first-prefix'
    structured['arguments'] = [args[0], '-include', str(PREFIX), *args[1:]]
    return structured, 'added'


def apply_policy(cdb_path, version_output, engine_root):
    entries = _read_entries(cdb_path)
    if not supported_version(version_output):
        return _skip(entries, 'unsupported-clangd-version')
    public, reason = engine_context(engine_root)
    if reason:
        return _skip(entries, reason)
    if PREFIX.read_text(encoding='utf-8') != _CONTENT:
        raise ValueError('compatibility-prefix-content-changed')
    output, counts, cache = [], collections.Counter(), {}
    for entry in entries:
        value, reason = transform_entry(entry, public, cache)
        output.append(value)
        counts[reason] += 1
    changed = bool(counts['added']) and write_if_changed(str(cdb_path), json.dumps(output, ensure_ascii=False))
    return {'changed': changed, 'added': counts['added'], 'entries': len(entries), 'outcomes': dict(counts)}


def pch_recipes(cdb_path, command):
    """Leave affected rows on text PCH; existing recipe code drops -include."""
    entries = json.loads(Path(cdb_path).read_text(encoding='utf-8-sig'))
    own = canonical(PREFIX)
    affected = [any(arg == '-include' and index + 1 < len(entry.get('arguments', []))
                    and canonical(entry['arguments'][index + 1], entry['directory']) == own
                    for index, arg in enumerate(entry.get('arguments', []))) for entry in entries]
    print('clangd friend-template compatibility: ' + json.dumps({
        'textual_pch_only_entries': sum(affected), 'recipe_eligible_entries': len(entries) - sum(affected)}), flush=True)
    if not any(affected):
        return subprocess.run(command, check=False).returncode
    selected = [entry for entry, skip in zip(entries, affected) if not skip]
    if not selected:
        return 0
    with tempfile.TemporaryDirectory(prefix='friend-template-pch-', dir=Path(cdb_path).parent) as folder:
        subset = Path(folder) / 'compile_commands.json'
        subset.write_text(json.dumps(selected), encoding='utf-8')
        if command.count(str(cdb_path)) != 1:
            raise ValueError('unconfirmed-pch-step-command')
        args = [str(subset) if arg == str(cdb_path) else arg for arg in command]
        if '--logical-cdb' not in args:
            args.extend(['--logical-cdb', str(cdb_path)])
        code = subprocess.run(args, check=False).returncode
        if code:
            return code
        processed = json.loads(subset.read_text(encoding='utf-8-sig'))
        if [(e['directory'], e['file']) for e in processed] != [(e['directory'], e['file']) for e in selected]:
            raise ValueError('pch-step-changed-source-ownership')
        values = iter(processed)
        merged = [entry if skip else next(values) for entry, skip in zip(entries, affected)]
        if merged != entries:
            write_if_changed(str(cdb_path), json.dumps(merged, ensure_ascii=False))
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('cdb')
    parser.add_argument('--clangd', default='')
    parser.add_argument('--engine-root', default='')
    parser.add_argument('--skip-reason', default='')
    parser.add_argument('--pch-command', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if args.pch_command:
        return pch_recipes(args.cdb, args.pch_command)
    if args.skip_reason:
        print('clangd friend-template compatibility: ' + json.dumps(_skip(_read_entries(args.cdb), args.skip_reason)))
        return 0
    version, reason = probe_clangd(args.clangd)
    result = (_skip(_read_entries(args.cdb), reason) if reason
              else apply_policy(args.cdb, version, args.engine_root))
    result.update(clangd=args.clangd, clangd_version=version.strip(), prefix=str(PREFIX))
    print('clangd friend-template compatibility: ' + json.dumps(result, ensure_ascii=True))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
