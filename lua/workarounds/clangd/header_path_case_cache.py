"""One-time, reversible repair of empty mapped-header shards after CDB commit.

No native processes, recursive cache walks, source changes, or broad cache clear.
The caller holds the prepare writer lease and supplies the selected tuple paths.
"""
import argparse
import ctypes
from ctypes import wintypes
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import time

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).absolute().parent))
sys.path.insert(0, str(Path(__file__).absolute().parents[3] / 'tools'))
import header_path_case as policy
import clangd_index_graph as graph
from build_hot_super_unity_cdb import write_if_changed
from cdb_argv import normalize_cdb

POLICY = 'empty-mapped-header-shards-v1'


class MigrationError(RuntimeError):
    def __init__(self, cause, manifest):
        self.manifest = str(manifest)
        super().__init__(f'header cache migration incomplete: {cause}; recovery manifest: {manifest}')


def _running_clangd():
    """Use the same Toolhelp process snapshot as the Windows platform driver."""
    if os.name != 'nt':
        raise OSError('clangd writer probe is available only on Windows')
    class ProcessEntry(ctypes.Structure):
        _fields_ = [('dwSize', wintypes.DWORD), ('cntUsage', wintypes.DWORD),
                    ('th32ProcessID', wintypes.DWORD), ('th32DefaultHeapID', ctypes.c_size_t),
                    ('th32ModuleID', wintypes.DWORD), ('cntThreads', wintypes.DWORD),
                    ('th32ParentProcessID', wintypes.DWORD), ('pcPriClassBase', wintypes.LONG),
                    ('dwFlags', wintypes.DWORD), ('szExeFile', wintypes.WCHAR * 260)]
    kernel = ctypes.WinDLL('kernel32', use_last_error=True)
    kernel.CreateToolhelp32Snapshot.argtypes = (wintypes.DWORD, wintypes.DWORD)
    kernel.CreateToolhelp32Snapshot.restype = wintypes.HANDLE
    for name in ('Process32FirstW', 'Process32NextW'):
        function = getattr(kernel, name)
        function.argtypes = (wintypes.HANDLE, ctypes.POINTER(ProcessEntry))
        function.restype = wintypes.BOOL
    kernel.CloseHandle.argtypes = (wintypes.HANDLE,)
    kernel.CloseHandle.restype = wintypes.BOOL
    handle = kernel.CreateToolhelp32Snapshot(2, 0)
    if handle == ctypes.c_void_p(-1).value:
        raise ctypes.WinError(ctypes.get_last_error())
    try:
        entry = ProcessEntry(); entry.dwSize = ctypes.sizeof(entry)
        found = kernel.Process32FirstW(handle, ctypes.byref(entry))
        writers = []
        while found:
            if entry.szExeFile.casefold().startswith('clangd'):
                writers.append(int(entry.th32ProcessID))
            found = kernel.Process32NextW(handle, ctypes.byref(entry))
        error = ctypes.get_last_error()
        if error != 18:  # ERROR_NO_MORE_FILES is the only successful end.
            raise ctypes.WinError(error)
        return writers
    finally:
        if not kernel.CloseHandle(handle):
            raise ctypes.WinError(ctypes.get_last_error())


def _writer_defer(manifest=None):
    try:
        writers = _running_clangd()
    except OSError as error:
        reason, writers = 'clangd-writer-probe-unavailable: ' + str(error), []
    else:
        if not writers:
            return None
        reason = 'clangd-writer-present'
    return {'migrated': 0, 'deferred': True, 'status': 'pending', 'reason': reason,
            'writer_pids': writers, 'manifest': str(manifest) if manifest else None}


def _sha(path):
    digest = hashlib.sha256()
    with open(path, 'rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


def _write(path, value):
    write_if_changed(str(path), json.dumps(value, ensure_ascii=False, sort_keys=True, indent=2) + '\n')


def _safe(path, names=None):
    path = Path(path)
    if not path.is_absolute() or '..' in path.parts:
        raise ValueError('cache migration requires absolute non-traversing paths')
    ancestor = path
    while not ancestor.exists() and ancestor != ancestor.parent:
        ancestor = ancestor.parent
    # Enumeration refuses reparse/symlink boundaries without resolving them to
    # another project or volume. A missing suffix may be created only here.
    (names or policy.Names()).physical(str(ancestor))
    return path


def _paths(semantic_cdb, cache_dir):
    semantic, cache = _safe(semantic_cdb), _safe(cache_dir)
    expected = semantic.parent / '.cache/clangd/index'
    if semantic.name != 'compile_commands.json' or policy.absolute(str(cache)).casefold() != policy.absolute(str(expected)).casefold():
        raise ValueError('cache root does not belong to the selected semantic CDB')
    return semantic, cache


def _overlays(active):
    entries = normalize_cdb(json.loads(Path(active).read_text(encoding='utf-8-sig')))[0]
    paths = set()
    for entry in entries:
        arguments = entry['arguments']
        end = arguments.index('--') if '--' in arguments else len(arguments)
        for index, argument in enumerate(arguments[:end]):
            if argument != '-ivfsoverlay':
                continue
            if index + 1 >= end:
                raise ValueError('incomplete committed overlay argument')
            path = Path(arguments[index + 1])
            if policy.OWNED.fullmatch(path.name):
                if not path.is_absolute() or (index > 0 and arguments[index - 1] == '-Xclang'):
                    raise ValueError('unconfirmed committed owned overlay')
                if policy.absolute(str(path.parent)).casefold() != policy.absolute(str(Path(active).parent / 'header-path-case')).casefold():
                    raise ValueError('committed overlay belongs to another active CDB')
                paths.add(path)
    identities = []
    for path in sorted(paths):
        match = policy.OWNED.fullmatch(path.name)
        digest = _sha(path)
        if digest != match.group(1):
            raise ValueError('committed owned overlay content changed')
        identities.append({'path': str(path), 'sha256': digest})
    return identities


def _scan(cache, mapping):
    uris = {Path(name).as_uri() for name in mapping if Path(name).suffix.lower() in policy.EXTENSIONS}
    files, counts = [], {'scanned': 0, 'invalid_riff': 0, 'retained': 0}
    if not cache.exists():
        return files, counts
    with os.scandir(cache) as stream:
        candidates = sorted((entry.name for entry in stream if entry.name.endswith('.idx')))
    names = policy.Names()
    for name in candidates:
        path = _safe(cache / name, names)
        if not path.is_file():
            continue
        counts['scanned'] += 1
        if path.stat().st_size > 64 * 1024 * 1024:
            counts['retained'] += 1; continue
        raw = path.read_bytes()
        try:
            chunks = graph._chunks(raw)
            if any(chunks[tag] for tag in (b'symb', b'refs', b'rela')) or b'cmdl' in chunks:
                counts['retained'] += 1; continue
            decoded = graph.read_shard(path)
            own = [(uri, node) for uri, node in decoded['sources'].items() if node['digest'] != '0000000000000000']
            if len(own) != 1 or own[0][0] not in uris or own[0][1]['flags'] & 3:
                counts['retained'] += 1; continue
            if any(decoded[key] for key in ('symbols', 'refs', 'relations')):
                counts['retained'] += 1; continue
        except (ValueError, UnicodeError):
            counts['invalid_riff'] += 1; continue
        digest = hashlib.sha256(raw).hexdigest()
        if _sha(path) != digest:
            raise ValueError('header shard changed while classifying: ' + str(path))
        files.append({'original': str(path), 'sha256': digest, 'own_uri': own[0][0], 'status': 'pending'})
    return files, counts


def _items(manifest_path, value):
    _, cache = _paths(value['semantic_cdb'], value['cache_dir'])
    expected_parent = cache.parent / 'header-path-case-migrations' / value['key']
    if manifest_path != expected_parent / 'manifest.json' or value.get('policy') != POLICY or value.get('schema') != 1:
        raise ValueError('invalid migration manifest owner')
    seen, names = set(), policy.Names()
    for item in value['files']:
        original, backup = _safe(item['original'], names), _safe(item['backup'], names)
        if original.parent != cache or original.suffix != '.idx' or backup != expected_parent / 'backup' / original.name:
            raise ValueError('migration item leaves the owned cache or backup directory')
        if original.name in seen or not re.fullmatch('[0-9a-f]{64}', item['sha256']):
            raise ValueError('invalid migration item identity')
        seen.add(original.name)
        yield item, original, backup


def migrate(active_cdb, semantic_cdb, cache_dir):
    started = time.monotonic()
    active = _safe(active_cdb)
    semantic, cache = _paths(semantic_cdb, cache_dir)
    overlays = _overlays(active)
    if not overlays:
        return {'migrated': 0, 'reason': 'no-committed-owned-overlay'}
    identity = {'policy': POLICY, 'policy_sha256': _sha(__file__), 'mapper_sha256': _sha(policy.__file__),
                'decoder_sha256': _sha(graph.__file__), 'cache_dir': str(cache), 'overlays': overlays}
    key = hashlib.sha256(json.dumps(identity, sort_keys=True).encode()).hexdigest()
    directory = _safe(cache.parent / 'header-path-case-migrations' / key)
    manifest = directory / 'manifest.json'
    if manifest.exists():
        value = json.loads(manifest.read_text(encoding='utf-8'))
        if value.get('identity') != identity or value.get('key') != key:
            raise ValueError('migration marker identity mismatch')
        if value.get('status') in ('complete', 'restored'):
            return {'migrated': 0, 'already_completed': True, 'manifest': str(manifest), 'status': value['status']}
    deferred = _writer_defer(manifest if manifest.exists() else None)
    if deferred:
        return deferred
    if not manifest.exists():
        directory.mkdir(parents=True, exist_ok=True)
        value = {'schema': 1, 'policy': POLICY, 'key': key, 'identity': identity, 'active_cdb': str(active),
                 'semantic_cdb': str(semantic), 'cache_dir': str(cache), 'status': 'planning', 'files': []}
        _write(manifest, value)
    try:
        mapping = {}
        for overlay in overlays:
            mapping.update(policy.validate_owned_overlay(overlay['path']))
        if value['status'] == 'planning':
            deferred = _writer_defer(manifest)
            if deferred:
                return deferred
            files, counts = _scan(cache, mapping)
            for item in files:
                item['backup'] = str(directory / 'backup' / Path(item['original']).name)
            value.update(status='pending', files=files, counts=counts)
            _write(manifest, value)
        if value['files']:
            (directory / 'backup').mkdir(exist_ok=True)
        for item, original, backup in list(_items(manifest, value)):
            if backup.exists():
                if _sha(backup) != item['sha256'] or original.exists():
                    raise ValueError('migration backup or original conflicts: ' + str(original))
            else:
                deferred = _writer_defer(manifest)
                if deferred:
                    value['deferred_reason'] = deferred['reason']
                    _write(manifest, value)
                    return dict(deferred, migrated=sum(item['status'] == 'migrated' for item in value['files']))
                # Hash immediately before the only removal: an atomic rename of
                # this exact direct shard to its pre-recorded private backup.
                if _sha(original) != item['sha256']:
                    raise ValueError('header shard changed before migration: ' + str(original))
                os.rename(original, backup)
                if _sha(backup) != item['sha256']:
                    raise ValueError('header shard changed during migration: ' + str(backup))
            item['status'] = 'migrated'
            # The complete pending plan was durable before the first rename.
            # On interruption, original/backup hashes recover progress without
            # rewriting an increasingly large manifest once per shard.
        value.update(status='complete', seconds=time.monotonic() - started)
        value.pop('error', None)
        _write(manifest, value)
        return {'migrated': len(value['files']), 'manifest': str(manifest), 'counts': value.get('counts', {}),
                'seconds': value['seconds']}
    except Exception as error:
        value['error'] = str(error)
        _write(manifest, value)
        raise MigrationError(error, manifest) from error


def restore(manifest_path):
    deferred = _writer_defer(manifest_path)
    if deferred:
        return deferred
    manifest = _safe(manifest_path)
    value = json.loads(manifest.read_text(encoding='utf-8'))
    restored = 0
    for item, original, backup in _items(manifest, value):
        if original.exists():
            if _sha(original) != item['sha256']:
                raise ValueError('refusing to replace a regenerated header shard: ' + str(original))
        elif backup.exists() and _sha(backup) == item['sha256']:
            os.rename(backup, original)
            restored += 1
        else:
            raise ValueError('restoration bytes unavailable: ' + str(original))
        item['status'] = 'restored'
    value['status'] = 'restored'
    _write(manifest, value)
    return {'restored': restored, 'manifest': str(manifest)}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--restore', required=True, metavar='MANIFEST')
    print(json.dumps(restore(parser.parse_args().restore)))
