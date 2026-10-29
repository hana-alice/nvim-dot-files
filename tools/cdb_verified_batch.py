"""Prove same-context UBT batches in private clangd processes before publication.

Receipts are reused only after byte and include-directory inventory validation.
Callers must invalidate a published receipt when its live dependencies change.
"""
import collections
import argparse
from contextlib import contextmanager
from contextvars import ContextVar
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import time
from urllib.parse import unquote, urlparse

# Imports must not change the directory inventory bound into proof receipts.
# A loaded module's own guard runs after Python may have written its bytecode.
sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))
from build_hot_super_unity_cdb import (compile_context_key, portable_member_path,
    rewritten_arguments, secondary_unity_chunks, strict_unity_chunks,
    tier2_unity_chunks, tier2_candidate_spec, tier2_include_gate, _tier2_entry)
from clangd_batch_admission import compare_graphs
from clangd_batch_runner import normalize_server_profile, run
from clangd_index_graph import _record_key, canonical_file_graph, read_shard, decode_shard

_COLLECTOR_FILES = ('cdb_verified_batch.py', 'build_hot_super_unity_cdb.py', 'clangd_index_graph.py',
                    'clangd_batch_runner.py', 'clangd_vfs_aliases.py', 'clangd_query_profile.py',
                    'clangd_receipt_migration.py')
_POLICY_FILES = ('clangd_batch_admission.py', 'clangd_batch_bindings.py',
                 '../lua/workarounds/clangd/header_path_case.py')
_HEADER_CASE_PATH = Path(__file__).resolve().parent / _POLICY_FILES[-1]
_HEADER_CASE_POLICY = None
_OWNED_OVERLAY_MEMO = {}
_TIER1_BLOB_MEMO = {}
_TIER1_OVERLAY_SCOPE_DEPTH = 0
_TIER1_OVERLAY_READ_VIEW = ContextVar("tier1_overlay_read_view", default=None)
_RUN_METRIC_FIELDS = ('indexing_wall_seconds', 'process_wall_seconds', 'graph_decode_seconds',
                      'spawn_seconds', 'shutdown_seconds', 'cpu_seconds', 'peak_working_set_bytes')
_QUERY_RESOLUTION_MEMO = {}
_INCLUDE_ENV = ('CPATH', 'CPLUS_INCLUDE_PATH', 'C_INCLUDE_PATH', 'OBJC_INCLUDE_PATH',
                'OBJCPLUS_INCLUDE_PATH', 'INCLUDE')
# These values are inherited by every private compiler process. Cache/TEMP
# overrides are intentionally absent; unset and empty values remain distinct.
_COMPILER_ENV = _INCLUDE_ENV + ('SDKROOT', 'MACOSX_DEPLOYMENT_TARGET', 'IPHONEOS_DEPLOYMENT_TARGET',
    'TVOS_DEPLOYMENT_TARGET', 'WATCHOS_DEPLOYMENT_TARGET', 'XROS_DEPLOYMENT_TARGET',
    'DEVELOPER_DIR', 'TOOLCHAINS', 'GCC_EXEC_PREFIX', 'COMPILER_PATH', 'PATH', 'PATHEXT',
    'WindowsSdkDir', 'WindowsSDKVersion', 'VCToolsInstallDir', 'VCINSTALLDIR',
    'CL', '_CL_', 'CCC_OVERRIDE_OPTIONS', 'SOURCE_DATE_EPOCH', 'TZ')


def _compiler_environment(server_profile=None):
    # Without a native query profile there is no driver-resolution proof, so
    # preserve the conservative PATH boundary for that older proof route.
    folded = {name.upper(): value for name, value in os.environ.items()} if os.name == 'nt' else os.environ
    return {name: folded.get(name.upper() if os.name == 'nt' else name) for name in _COMPILER_ENV
            if server_profile is None or name not in ('PATH', 'PATHEXT')}


def _code_identities():
    return {key: hashlib.sha256(b''.join((Path(__file__).parent / name).read_bytes() for name in files)).hexdigest()
            for key, files in (('collector', _COLLECTOR_FILES), ('policy', _POLICY_FILES))}


_IMPORTED_CODE = _code_identities()


def _json(value):
    return json.dumps(value, sort_keys=True, ensure_ascii=True, separators=(',', ':'))


def _sha(data):
    return hashlib.sha256(data).hexdigest()


def _tier1_blob_sha(kind, raw):
    """Reuse a digest only after the caller reads identical complete bytes."""
    if _TIER1_OVERLAY_SCOPE_DEPTH == 0:
        return _sha(raw)
    previous = _TIER1_BLOB_MEMO.get(kind)
    if previous is not None and previous[0] == raw:
        return previous[1]
    digest = _sha(raw)
    # Only the last overlay and tool payloads are retained, regardless of paths.
    _TIER1_BLOB_MEMO[kind] = (raw, digest)
    return digest


def _proof_work_root(output):
    """Persistent private work, outside published receipt/asset namespaces."""
    return (Path(tempfile.gettempdir()).resolve() / 'nvim-ue-batch-work'
            / _sha(str(Path(output).resolve()).encode())[:24])


@contextmanager
def _phase(timings, name):
    started = time.monotonic()
    try:
        yield
    finally:
        row = timings.setdefault(name, {'seconds': 0.0, 'calls': 0})
        row['seconds'] += time.monotonic() - started
        row['calls'] += 1


def _timed(phase_rows, name, operation, *args, **kwargs):
    with _phase(phase_rows, name):
        return operation(*args, **kwargs)


def _write(path, data):
    path = Path(path)
    data = data.encode('utf-8') if isinstance(data, str) else data
    if path.exists() and path.read_bytes() == data:
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + '.' + str(os.getpid()) + '.tmp')
    temporary.write_bytes(data)
    try:
        os.replace(temporary, path)
    except OSError:
        # Another process may publish this content-addressed snapshot after
        # our initial check, then clangd can hold it open against replacement.
        try:
            identical = path.read_bytes() == data
        except OSError:
            identical = False
        if not identical:
            raise
        temporary.unlink(missing_ok=True)


def _native(entry):
    return {field: entry[field] for field in ('directory', 'file', 'arguments')}


def _private_command(entry):
    command = _native(entry)
    directory = Path(command['directory']).resolve()
    source = Path(command['file'])
    return dict(command, directory=str(directory), file=str((directory / source).resolve()))


def _uri_path(uri):
    parsed = urlparse(uri)
    if parsed.scheme != 'file' or parsed.netloc:
        raise ValueError('unsupported-dependency-uri: ' + uri)
    path = unquote(parsed.path)
    return Path(path[1:] if os.name == 'nt' and re.match(r'^/[A-Za-z]:', path) else path)


def _windows_paths(entry):
    if os.name != 'nt':
        return entry
    entry = dict(entry, directory=entry['directory'].replace('/', '\\'))
    args, previous = [], None
    separate = {'-I', '-isystem', '-iquote', '-idirafter', '-include', '-imacros',
                '-isysroot', '--sysroot', '--gcc-toolchain', '-resource-dir', '-ivfsoverlay', '-include-pch'}
    joined = ('-I', '-isystem', '-iquote', '-idirafter', '-include=', '-imacros=',
              '--sysroot=', '--gcc-toolchain=', '-resource-dir=')
    for index, argument in enumerate(entry['arguments']):
        path_value = index == 0 or previous in separate or argument == entry['file']
        path_value = path_value or any(argument.startswith(prefix) for prefix in joined)
        args.append(argument.replace('/', '\\') if path_value else argument)
        previous = argument
    return dict(entry, arguments=args)


def _is_ubt(entry):
    return (Path(entry.get('file', '')).name.startswith('SuperUnity.UBT.')
            and bool(entry.get('nvim_ue_members')) and bool(entry.get('nvim_ue_module_root')))


def _owned_overlay_policy():
    global _HEADER_CASE_POLICY
    if _HEADER_CASE_POLICY is None:
        spec = importlib.util.spec_from_file_location('verified_header_path_case', _HEADER_CASE_PATH)
        _HEADER_CASE_POLICY = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(_HEADER_CASE_POLICY)
    return _HEADER_CASE_POLICY


@contextmanager
def tier1_overlay_scope(enabled=True):
    """Share byte digests and physical-name checks within one Tier 1 operation."""
    global _TIER1_OVERLAY_SCOPE_DEPTH
    if not enabled:
        yield
        return
    if _TIER1_OVERLAY_SCOPE_DEPTH == 0:
        _OWNED_OVERLAY_MEMO.clear()
        _TIER1_BLOB_MEMO.clear()
    _TIER1_OVERLAY_SCOPE_DEPTH += 1
    try:
        yield
    finally:
        _TIER1_OVERLAY_SCOPE_DEPTH -= 1
        if _TIER1_OVERLAY_SCOPE_DEPTH == 0:
            _OWNED_OVERLAY_MEMO.clear()
            _TIER1_BLOB_MEMO.clear()


@contextmanager
def _tier1_overlay_read_view():
    """One synchronous Tier 1 description/input transaction, never a proof run.

    Share one owned overlay's complete current byte observation across nested
    wrapper validation and asset collection. Other paths retain per-access reads;
    only one raw payload is retained. Re-read that path before returning; a
    mismatch rejects the whole operation. No stat shortcut,
    cross-call cache, native execution or frozen authority is authorized here.
    This is not a filesystem snapshot or an ABA/mutation-exclusion guarantee.
    """
    view = {}
    token = _TIER1_OVERLAY_READ_VIEW.set(view)
    try:
        yield
        for path, (raw, _) in view.items():
            if Path(path).read_bytes() != raw:
                raise ValueError('owned-overlay-changed-during-tier1-operation')
    finally:
        _TIER1_OVERLAY_READ_VIEW.reset(token)


def _owned_overlays(entry):
    """Validate only the producer's content-addressed identity overlay.

    Outside a synchronous Tier 1 read view, bytes are checked on every access.
    A read view checks complete current bytes at entry/exit for one shared
    path; other paths keep per-access reads. Physical-spelling validation stays
    scoped to the outer
    qualification/receipt-validation invocation.
    External target contents are not read here.
    """
    result = []
    arguments = entry['arguments']
    for index, argument in enumerate(arguments):
        if argument != '-ivfsoverlay':
            continue
        if (index + 1 >= len(arguments) or arguments[index + 1].startswith('-')
                or arguments[index - 1] in ('-Xclang', '-Xpreprocessor')):
            raise ValueError('unsupported-indirect-compiler-input: missing owned overlay')
        path = (Path(entry['directory']) / arguments[index + 1]).resolve()
        view = _TIER1_OVERLAY_READ_VIEW.get()
        if view is not None and str(path) in view:
            result.append(view[str(path)][1])
            continue
        raw = path.read_bytes()
        digest = _tier1_blob_sha('overlay', raw)
        key = (str(path), digest)
        if key not in _OWNED_OVERLAY_MEMO:
            mapping = _owned_overlay_policy().validate_owned_overlay(path)
            if path.read_bytes() != raw:
                raise ValueError('owned-overlay-changed-during-validation')
            _OWNED_OVERLAY_MEMO[key] = mapping
        item = {'path': str(path), 'sha256': digest, 'mapping': _OWNED_OVERLAY_MEMO[key]}
        if view is not None and not view:
            view[str(path)] = (raw, item)
        result.append(item)
    return result


def _owned_overlay_assets(entries):
    assets = {item['path']: item['sha256'] for entry in entries for item in _owned_overlays(entry)}
    return [{'path': path, 'sha256': digest} for path, digest in sorted(assets.items())]


def _without_overlay_arguments(arguments):
    result, index = [], 0
    while index < len(arguments):
        if arguments[index] == '-ivfsoverlay':
            if index + 1 >= len(arguments):
                raise ValueError('missing-overlay-operand')
            index += 2
        else:
            result.append(arguments[index])
            index += 1
    return result


_FORCED_PREFIX_RECIPE = 'ordered-absolute-forced-prefix-v1'


def _forced_prefix_arguments(arguments):
    """One token scan supplies both eligibility and the exact removable option positions."""
    if not isinstance(arguments, (list, tuple)) or not arguments or any(not isinstance(value, str) for value in arguments):
        return None, (), 'forced-prefix-unavailable: invalid-arguments'
    values = {'-D', '-U', '-I', '-isystem', '-iquote', '-idirafter', '-isysroot', '--sysroot',
              '--gcc-toolchain', '-resource-dir', '-ivfsoverlay', '-target', '-o', '-MF', '-MT', '-MQ', '-MJ'}
    headers, removed, index = [], set(), 1
    while index < len(arguments):
        argument = arguments[index]
        if argument == '--':
            return None, (), 'forced-prefix-unavailable: end-of-options'
        if argument.startswith(('-imacros', '--imacros', '--include', '-Wp,', '-X', '-mllvm', '-fdirectives-only',
                                '/FI', '-FI', '/clang:', '@', '--config',
                                '-include-pch', '-include-pth', '-fmodule', '-fprebuilt-module',
                                '/Yu', '/Fp', '/reference', '/ifcSearchDir')):
            return None, (), 'forced-prefix-unavailable: unsupported-option: ' + argument
        if argument == '-x' or argument in values:
            if index + 1 == len(arguments):
                return None, (), 'forced-prefix-unavailable: missing-option-operand: ' + argument
            if argument == '-x' and arguments[index + 1].endswith('cpp-output'):
                return None, (), 'forced-prefix-unavailable: preprocessed-language'
            index += 2
            continue
        if argument.startswith('-x') and argument[2:].endswith('cpp-output'):
            return None, (), 'forced-prefix-unavailable: preprocessed-language'
        if argument == '-include':
            if index + 1 == len(arguments) or not arguments[index + 1] or arguments[index + 1].startswith('-'):
                return None, (), 'forced-prefix-unavailable: missing-include-operand'
            path = arguments[index + 1]
            if not Path(path).is_absolute():
                return None, (), 'forced-prefix-unavailable: relative-include: ' + path
            headers.append(path)
            removed.update((index, index + 1))
            index += 2
            continue
        if argument.startswith('-include'):
            return None, (), 'forced-prefix-unavailable: joined-include: ' + argument
        index += 1
    return headers, removed, None


def _strict_forced_prefix(group):
    """Describe one complete argv transformation; unsupported groups keep the old constructor."""
    ordered = None
    for entry in group:
        if not isinstance(entry, dict):
            return None, 'forced-prefix-unavailable: invalid-entry'
        headers, _, reason = _forced_prefix_arguments(entry.get('arguments'))
        if reason:
            return None, reason
        if ordered is not None and headers != ordered:
            return None, 'forced-prefix-unavailable: include-sequences-differ'
        ordered = headers
    return ({'recipe': _FORCED_PREFIX_RECIPE, 'headers': ordered} if ordered else None), None


def _forced_prefix_matches(record, group):
    if record.get('ordered_recipe') is not None:
        import cdb_ordered_batch
        return (record['ordered_recipe'] == cdb_ordered_batch.descriptor(cdb_ordered_batch.RECIPE)
                and record.get('forced_prefix') is None)
    return record.get('forced_prefix') == _strict_forced_prefix(group)[0]


def _validate_ubt(entry):
    # Expanded CDB arguments only: indirect files and module state are not yet
    # part of our source/dependency proof, so never certify them accidentally.
    indirect = ('--config', '-ivfsoverlay', '-vfsoverlay', '-fmodule', '-fprebuilt-module',
                '-include-pch', '-include-pth', '/Yu', '/Fp', '/reference', '/ifcSearchDir')
    _owned_overlays(entry)
    for argument in entry['arguments'][1:]:
        if argument == '-ivfsoverlay':
            continue  # Only the separately validated split-form owned overlay.
        options = argument[4:].split(',') if argument.startswith('-Wp,') else [argument]
        for option in options:
            option = option.removeprefix('/clang:').removeprefix('-Xclang=')
            if option.startswith('@') or option.startswith(indirect):
                raise ValueError('unsupported-indirect-compiler-input: ' + option)
    for name in ('CL', '_CL_', 'CCC_OVERRIDE_OPTIONS'):
        if os.environ.get(name):
            raise ValueError('unsupported-compiler-option-environment: ' + name)
    text = Path(entry['file']).read_text(encoding='utf-8')
    if not text.startswith('// Compiler-authored UBT unity membership; copied into nvim cache.\n'):
        raise ValueError('missing-compiler-authored-wrapper-marker')
    members = re.findall(r'^#include "([^"]+)"\s*$', text, re.M)
    if [portable_member_path(path) for path in members] != entry['nvim_ue_members']:
        raise ValueError('wrapper-membership-mismatch')
    if not members or not all(Path(path).is_file() for path in members):
        raise ValueError('missing-wrapper-member')
    return members


def _inventory(path, excluded):
    path = Path(path)
    if not path.is_dir():
        return {'exists': False, 'sha256': None}
    # Match Path equality, including Windows Unicode folding; normcase uses
    # a different Windows mapping. Keep lexical names separate from identities.
    path_key = str.lower if os.name == 'nt' else lambda value: value
    excluded_key = path_key(str(excluded))
    excluded_prefix = excluded_key.rstrip(os.sep) + os.sep

    def is_excluded(value):
        return value == excluded_key or value.startswith(excluded_prefix)

    records, pending, visited = [], [(str(path), '', None)], set()
    while pending:
        directory, relative, physical = pending.pop()
        try:
            info = os.lstat(directory)
        except OSError:
            # A failed optimization probe must retain resolve/scandir behavior,
            # including the native error when a directory disappears mid-scan.
            info, physical = None, None
        reparse = bool(getattr(info, 'st_file_attributes', 0) & stat.FILE_ATTRIBUTE_REPARSE_POINT) if os.name == 'nt' else False
        if physical is None or reparse or stat.S_ISLNK(info.st_mode):
            physical = str(Path(directory).resolve())
        physical_key = path_key(physical)
        if is_excluded(physical_key) or physical_key in visited:
            continue
        visited.add(physical_key)
        with os.scandir(directory) as iterator:
            for item in sorted(iterator, key=lambda item: item.name):
                if is_excluded(path_key(item.path)):
                    continue
                child_relative = relative + item.name
                is_directory = item.is_dir()
                link = os.readlink(item.path) if item.is_symlink() else ''
                records.append((child_relative, 'directory' if is_directory else 'file', link))
                if is_directory:
                    pending.append((item.path, child_relative + os.sep, os.path.join(physical, item.name)))
    return {'exists': True, 'sha256': _sha(_json(sorted(records)).encode())}


def _minimal_roots(paths):
    """Keep lexical coverage and ordering without comparing every sibling pair."""
    result, selected = [], set()
    for path in sorted(map(Path, paths), key=lambda p: (len(p.parts), str(p))):
        if path not in selected and not any(parent in selected for parent in path.parents):
            result.append(path)
            selected.add(path)
    return result


def _include_roots(group, dependencies, effective_entries=(), extra_roots=()):
    roots = {str(_uri_path(item['uri']).parent.resolve()) for item in dependencies}
    roots.update(str(Path(path).resolve()) for path in extra_roots)
    options = {'-I', '-isystem', '-iquote', '-idirafter', '-F', '-isysroot', '--sysroot', '--gcc-toolchain', '-resource-dir'}
    prefixes = ('--sysroot=', '--gcc-toolchain=', '-resource-dir=', '-isystem', '-iquote', '-idirafter', '-I', '-F')
    for entry in list(group) + list(effective_entries):
        roots.add(str(Path(entry['file']).resolve().parent))
        if _is_ubt(entry):
            roots.update(str(Path(path).resolve().parent) for path in _validate_ubt(entry))
        for overlay in _owned_overlays(entry):
            roots.add(str(Path(overlay['path']).parent))
            roots.update(str(Path(path).parent) for path in overlay['mapping'])
        for name in _INCLUDE_ENV + ('SDKROOT',):
            value = os.environ.get(name)
            if value is None:
                continue
            values = [value] if name == 'SDKROOT' else value.split(';' if name == 'INCLUDE' else os.pathsep)
            for value in values:
                path = Path(value.strip('"'))
                roots.add(str((path if path.is_absolute() else Path(entry['directory']) / path).resolve()))
        previous = None
        for argument in entry['arguments'][1:]:
            value = argument if previous in options else next(
                (argument[len(prefix):] for prefix in prefixes if argument.startswith(prefix) and argument != prefix), None)
            if value:
                path = Path(value.strip('"'))
                roots.add(str((path if path.is_absolute() else Path(entry['directory']) / path).resolve()))
            previous = argument
    return list(map(str, _minimal_roots(roots)))


def _inventories(paths, output, memo):
    for path in paths:
        if path not in memo:
            memo[path] = _inventory(path, output)
    return {path: memo[path] for path in paths}


def _query_assets(observations):
    assets = {}
    for observation in observations:
        driver = observation['driver']
        for path in (driver['path'], driver['realpath']):
            assets[path] = driver['sha256']
        entry = observation['entry']
        assets[str(Path(entry['directory']) / entry['file'])] = observation['source_sha256']
    return [{'path': path, 'sha256': digest} for path, digest in sorted(assets.items())]


def _observe_queries(entries, clangd, profile, directory, observations, timeout):
    if profile is None:
        return
    from clangd_query_profile import observe, query_tuple
    known = {_json(item['tuple']) for item in observations}
    for entry in entries:
        native = _private_command(entry)
        key = _json(query_tuple(native))
        if key in known:
            continue
        result = observe(native, clangd, profile['query_driver'], directory / _sha(key.encode())[:20],
            min(timeout, 10), launch_cwd=profile['launch_cwd'], environment=dict(os.environ))
        if result.get('ok') is not True:
            raise ValueError('query-observation-failed: ' + result.get('reason', 'unknown'))
        observation = result['evidence']
        if observation['profile'] != profile or observation['compiler_environment'] != _compiler_environment(profile):
            raise ValueError('query-observation-profile-mismatch')
        observations.append(observation)
        known.add(key)


def _verify_effective_query(entry, effective, observations):
    if not observations:
        return
    from clangd_query_profile import query_tuple
    key = _json(query_tuple(_private_command(entry)))
    observed = next((item for item in observations if _json(item['tuple']) == key), None)
    if observed is None:
        raise ValueError('effective-query-observation-unavailable')
    original, actual = entry['arguments'], effective['arguments']
    source = _command_key(Path(entry['directory']) / entry['file'])
    remaining = iter(actual[1:])
    for arg in original[1:]:
        if arg == '--' or (not arg.startswith('-') and _command_key(Path(entry['directory']) / arg) == source):
            continue
        if not any(value == arg for value in remaining):
            raise ValueError('effective-query-original-arguments-changed')

    def system_paths(arguments):
        result, position = [], 1
        while position < len(arguments):
            arg = arguments[position]
            if arg == '-isystem':
                position += 1
                result.append(arguments[position])
            elif arg.startswith('-isystem'):
                result.append(arg[len('-isystem'):])
            position += 1
        return result

    if system_paths(actual) != system_paths(original) + observed['ordered_includes']:
        raise ValueError('effective-query-system-includes-mismatch')
    targets = [actual[index + 1] if arg == '-target' else arg.split('=', 1)[1]
        for index, arg in enumerate(actual) if arg == '-target' or arg.startswith('--target=')]
    if not targets or targets[-1] != observed['tuple']['Target']:
        raise ValueError('effective-query-target-mismatch')
    driver = Path(actual[0])
    if os.name == 'nt' and not driver.is_file() and driver.suffix.lower() != '.exe':
        driver = Path(str(driver) + '.exe')
    if _command_key(driver) != _command_key(observed['driver']['realpath']):
        raise ValueError('effective-query-driver-mismatch')


def _query_roots(observations):
    return sorted({str(Path(path).resolve()) for item in observations
                   for path in item['ordered_includes'] + [item['builtin_path']] + item['implicit_search_roots']})


def _source_identity(path, info=None):
    if os.name == 'nt':
        # LLVM Windows file_status hashes the canonical handle path, not the
        # inode: different hardlink names therefore remain distinct to Clang.
        return ['realpath', str(Path(path).resolve(strict=True))]
    info = info or Path(path).stat()
    if not info.st_ino:
        raise ValueError('original-file-identity-unavailable: ' + str(path))
    return ['inode', str(info.st_dev), str(info.st_ino)]


def _query_resolution_current(observations, executable, profile, memo=None, *, force=False):
    """Re-observe changed lookup state; never infer a driver from PATH text."""
    if profile is None:
        return not observations
    if not observations:
        return False
    from clangd_query_profile import lookup_environment, semantic_identity, validate
    current = lookup_environment()
    for observation in observations:
        if not force and observation.get('lookup_environment') == current:
            continue
        key = ('query-resolution', _json(semantic_identity(observation)), _json(current))
        if not force and memo is not None and key in memo:
            if not memo[key]:
                return False
            continue
        with tempfile.TemporaryDirectory(prefix='nvim-ue-batch-lookup-validation-') as scratch:
            result = validate(observation, observation['entry'], str(executable), profile['query_driver'],
                Path(scratch), launch_cwd=profile['launch_cwd'], environment=dict(os.environ))
        valid = result.get('ok') is True and lookup_environment() == current
        if memo is not None:
            memo[key] = valid
        if not valid:
            return False
    return True


def _cache_valid(record, output, memo, *, validate_resolution=True):
    if not isinstance(record, dict) or record.get('schema') != 1:
        return False
    identities = record.get('identities')
    if not isinstance(identities, dict) or identities.get('compiler_environment') != _compiler_environment(identities.get('server_profile')):
        return False
    if validate_resolution and not _query_resolution_current(record.get('query_profiles', []), identities['tool_path'],
                                                            identities.get('server_profile'), _QUERY_RESOLUTION_MEMO):
        return False
    originals = record.get('original_entries', record.get('effective_entries',
        [record['entry']] if 'entry' in record else []))
    try:
        if any(item not in record['assets'] for item in _owned_overlay_assets(originals)):
            return False
    except (OSError, ValueError, KeyError, TypeError):
        return False
    for item in record['dependencies'] + record['assets'] + _query_assets(record.get('query_profiles', [])):
        path = Path(item['path'])
        if not path.is_file() or _sha(path.read_bytes()) != item['sha256']:
            return False
        if 'file_identity' in item and _source_identity(path) != item['file_identity']:
            return False
    return _inventories(record['inventories'], output, memo) == record['inventories']


def _identities(executable, tool_hash=None, imported=False, server_profile=None):
    library = _libclang(executable)
    return {'tool_path': str(executable.resolve()), 'tool': tool_hash or _sha(executable.read_bytes()),
        **(_IMPORTED_CODE if imported else _code_identities()),
        'compiler_environment': _compiler_environment(server_profile),
        'server_profile': normalize_server_profile(server_profile),
        'binding_path': str(library.resolve()) if library else None,
        'binding': _sha(library.read_bytes()) if library else None}


def _read_receipts(paths):
    records = [json.loads(Path(path).read_text(encoding='utf-8')) for path in paths]
    if not records or any(not isinstance(record, dict) or record.get('schema') != 2 or not record.get('dependencies')
        or not record.get('assets') or not record.get('inventories') or not record.get('original_entries')
        or not isinstance(record.get('identities'), dict)
        or not isinstance(record['identities'].get('compiler_environment'), dict)
        or 'server_profile' not in record['identities'] or 'server_profile' not in record
        or record['server_profile'] != record['identities']['server_profile']
        or (record['server_profile'] is not None and not record.get('query_profiles')) for record in records):
        raise ValueError('incomplete-verified-receipt')
    if any(not _forced_prefix_matches(record, record['original_entries']) for record in records):
        raise ValueError('receipt-forced-prefix-mismatch')
    return records


def describe_receipts(receipt_paths, server_profile=None):
    """Read descriptors without hashing; install watches before validation."""
    try:
        records = _read_receipts(receipt_paths)
        profile = normalize_server_profile(server_profile)
        if any(record['server_profile'] != profile for record in records):
            raise ValueError('receipt-server-profile-mismatch')
        queries = [item for record in records for item in record.get('query_profiles', [])]
        driver_files = {path for item in queries for path in
            [item['driver']['path'], item['driver']['realpath']] + item.get('driver_candidates', [])}
        driver_roots = {path for item in queries for path in item.get('driver_search_roots', [])}
        if profile is not None:
            from clangd_query_profile import _driver_candidates, lookup_environment
            folded = {name.upper(): value for name, value in os.environ.items()}
            for item in queries:
                current_roots, current_files = _driver_candidates(item['tuple'], Path(item['clangd']['path']),
                    Path(profile['launch_cwd']), folded)
                driver_roots.update(current_roots)
                driver_files.update(current_files)
        environment = records[0]['identities']['compiler_environment']
        if any(record['identities']['compiler_environment'] != environment for record in records):
            raise ValueError('receipt-compiler-environments-disagree')
        roots = {path for record in records for path in record['inventories']}
        # Tool/policy files and immutable assets get exact-file and direct
        # namespace watches in activation. Their parents are not source trees.
        minimal = _minimal_roots(roots)
        return {'ok': True, 'watch_roots': sorted(map(str, minimal)),
                'compiler_environment': environment,
                'compiler_lookup_environment': lookup_environment() if profile else {},
                'server_profile': profile,
                'query_driver_files': sorted(driver_files), 'query_driver_search_roots': sorted(driver_roots),
                'query_search_roots': _query_roots(queries), 'query_profiles': queries,
                'exclude_roots': []}
    except (OSError, ValueError, KeyError, TypeError) as error:
        return {'ok': False, 'reason': str(error), 'watch_roots': [], 'exclude_roots': []}


def validate_receipts(receipt_paths, clangd_path, server_profile=None):
    """Verify live dependencies, immutable assets, inventories and tool policy."""
    started = time.monotonic()
    _OWNED_OVERLAY_MEMO.clear()
    _QUERY_RESOLUTION_MEMO.clear()
    result = describe_receipts(receipt_paths, server_profile)
    try:
        if not result['ok']:
            return result
        records = _read_receipts(receipt_paths)
        executable = Path(shutil.which(str(clangd_path)) or clangd_path)
        identities, memos, checked_queries = _identities(executable, server_profile=server_profile), {}, set()
        for record in records:
            if record['identities']['compiler_environment'] != identities['compiler_environment']:
                raise ValueError('receipt-compiler-environment-changed')
            if record['identities'] != identities:
                raise ValueError('receipt-tool-or-policy-changed')
            output = Path(record['output_dir']).resolve()
            memo = memos.setdefault(str(output), {})
            # Every query is rediscovered immediately below; do not repeat it
            # here merely because a semantically irrelevant PATH was changed.
            if not _cache_valid(dict(record, schema=1), output, memo, validate_resolution=False):
                raise ValueError('receipt-input-or-asset-changed')
            for observation in record.get('query_profiles', []):
                key = _json({name: observation[name] for name in
                    ('tuple', 'profile', 'compiler_environment', 'clangd', 'driver', 'ordered_includes', 'target')})
                if key in checked_queries:
                    continue
                from clangd_query_profile import validate
                profile = identities['server_profile']
                # The proof store and immutable asset ancestors are watched.
                # Query scratch must not change them while validation runs.
                with tempfile.TemporaryDirectory(prefix='nvim-ue-batch-query-validation-') as scratch:
                    query = validate(observation, observation['entry'], str(executable), profile['query_driver'], Path(scratch),
                        launch_cwd=profile['launch_cwd'], environment=dict(os.environ))
                if query.get('ok') is not True:
                    raise ValueError('receipt-query-profile-invalid: ' + query.get('reason', 'unknown'))
                checked_queries.add(key)
        result.update(ok=True, reason='verified-receipts-current', receipt_count=len(records))
    except (OSError, ValueError, KeyError, TypeError) as error:
        result.update(ok=False, reason=str(error))
    finally:
        result['validation_seconds'] = round(time.monotonic() - started, 6)
    return result


def _index(entries, directory, clangd, timeout, server_profile=None, record_pool=None, run_metrics=None):
    directory.mkdir(parents=True, exist_ok=True)
    trigger = directory / 'trigger.cpp'
    _write(trigger, '// Private BackgroundIndex trigger.\n')
    commands = [_private_command(entry) for entry in entries]
    commands.append({'directory': str(directory), 'file': str(trigger),
                     'arguments': ['clang++', '-x', 'c++', '-c', str(trigger)]})
    _write(directory / 'compile_commands.json', _json(commands))
    result = run(directory, directory / 'run', trigger, clangd, timeout=timeout, jobs=1, server_profile=server_profile)
    if run_metrics is not None:
        run_metrics.append(result)
    effective = {}
    started = time.monotonic()
    try:
        graph = _graph_result(result, trigger, effective, record_pool)
    finally:
        result['graph_decode_seconds'] = time.monotonic() - started
    return graph, result, [_effective_entry(entry, effective) for entry in entries]


def _command_key(path):
    return os.path.normcase(str(Path(path).resolve()))


def _effective_entry(entry, commands):
    command = commands.get(_command_key(entry['file']))
    if not command or not command.get('arguments') or not command.get('directory'):
        raise ValueError('original-main-command-unavailable: ' + entry['file'])
    return dict(entry, directory=command['directory'], arguments=command['arguments'])


def _intern_file_record(uri, record, pool):
    # Original graphs are read-only throughout _freeze/_admit and serialization.
    # Keep only a small hash key, not a second full structural key or JSON copy.
    # Equality remains decisive even if two different records hash identically.
    bucket = pool.setdefault((uri, hash(_record_key(record))), [])
    for existing in bucket:
        if existing == record:
            return existing
    bucket.append(record)
    return record


def _intern_graph_records(graph, pool):
    for uri, record in graph.items():
        graph[uri] = _intern_file_record(uri, record, pool)
    return graph


def _graph_result(result, trigger, effective=None, record_pool=None):
    if not result.get('background_compile_success') or result.get('missing_main_shards'):
        category = 'compiler-errors: ' if result.get('indexing_complete') and result.get('compile_failure_count', 0) else ''
        raise ValueError('private-index-failed: ' + category + str(trigger.parent / 'run/run.json'))
    shard_cache = record_pool.setdefault('header_shards', {'bytes': 0, 'records': {}}) if record_pool is not None else None
    def shards():
        for path in result['shards']:
            # A cache is local to this original-TU collection, not a production
            # shard import. Exact RIFF bytes preserve every semantic field and
            # dependency edge; a hash collision alone never authorizes reuse.
            raw = Path(path).read_bytes() if shard_cache is not None and Path(path).is_file() else None
            digest = _sha(raw) if raw is not None else None
            if digest is not None:
                for prior, graph in shard_cache['records'].get(digest, []):
                    if raw == prior and trigger.as_uri() not in graph:
                        yield None, graph
                        break
                else:
                    graph = None
                if graph is not None:
                    continue
            shard = read_shard(path)
            if effective is not None and shard.get('command'):
                own = [(uri, node) for uri, node in shard['sources'].items()
                       if node['digest'] != '0000000000000000']
                if len(own) != 1 or not own[0][1]['flags'] & 1:
                    raise ValueError('command-on-non-main-shard')
                key = _command_key(_uri_path(own[0][0]))
                if key in effective and effective[key] != shard['command']:
                    raise ValueError('conflicting-main-shard-commands')
                effective[key] = shard['command']
            yield shard, raw
    if record_pool is None:
        graph = canonical_file_graph((shard for shard, _ in shards()), ignore_files={trigger.as_uri()})
    else:
        graph = {}
        # Release duplicate file records while reading each independent TU,
        # rather than retaining a second complete decoded TU until _index ends.
        for shard, raw in shards():
            if shard is None:
                collected = raw
            else:
                collected = canonical_file_graph([shard], ignore_files={trigger.as_uri()})
                if (raw is not None and len(collected) == 1 and not shard.get('command')
                        and not any(record['source']['flags'] & 1 for record in collected.values())
                        and shard_cache['bytes'] + len(raw) <= 64 * 1024 * 1024):
                    shard_cache['records'].setdefault(_sha(raw), []).append((raw, collected))
                    shard_cache['bytes'] += len(raw)
            for uri, record in collected.items():
                if uri in graph and graph[uri] != record:
                    raise ValueError('conflicting clangd file shards for ' + uri)
                graph[uri] = record if shard is None else _intern_file_record(uri, record, record_pool)
                collected[uri] = graph[uri]
        graph = dict(sorted(graph.items()))
    own = set(graph)
    for uri, record in graph.items():
        if record['source']['flags'] & 2:
            raise ValueError('private-index-had-errors: ' + uri)
        if set(record['source']['direct_includes']) - own:
            raise ValueError('incomplete-dependency-shards: ' + uri)
    return graph


def _freeze(group, originals, assets, tool_hash, server_profile=None, timings=None, prepared=None):
    timings = timings if timings is not None else {}
    forced_prefix, _ = _strict_forced_prefix(group) if prepared is None else (None, None)
    if prepared is not None:
        import cdb_ordered_batch
        cdb_ordered_batch.validate_prepared(prepared, group)
    prefix = ''
    if forced_prefix:
        for header in forced_prefix['headers']:
            if ('"' in header or any(ord(char) < 32 for char in header)
                    or (os.name != 'nt' and '\\' in header)):
                raise ValueError('forced-prefix-unrepresentable-include: ' + repr(header))
            prefix += '#include "' + (header.replace('\\', '/') if os.name == 'nt' else header) + '"\n'
        try:
            prefix.encode('utf-8')
        except UnicodeError as error:
            raise ValueError('forced-prefix-unrepresentable-include') from error
    forced_paths = {os.path.normcase(os.path.normpath(header)) for header in forced_prefix['headers']} if forced_prefix else set()
    canonical_names = {os.path.normcase(os.path.normpath(path))
                       for entry in group for overlay in _owned_overlays(entry)
                       for path in overlay['mapping']}
    dependencies = sorted({uri for graph in originals for uri in graph})
    files = []
    for uri in dependencies:
        path = _uri_path(uri)
        with _phase(timings, 'freeze_read_hash'):
            with path.open('rb') as stream:
                physical = os.fstat(stream.fileno())
                raw = stream.read()
            file_identity = _source_identity(path, physical)
            digest = _sha(raw)
        if os.path.normcase(os.path.normpath(str(path))) in forced_paths:
            if b'\0' in raw or raw.startswith((b'CPCH', b'CPCM')):
                raise ValueError('forced-prefix-nontextual-input: ' + str(path))
        # Equal bytes do not imply equal #pragma-once file identity. Preserve
        # aliases recognized by Clang even when their suffixes differ.
        copy = assets / 'snapshots' / (_sha(_json([digest, file_identity]).encode()) + '.snapshot')
        _timed(timings, 'snapshot_write', _write, copy, raw)
        files.append({'uri': uri, 'path': str(path), 'sha256': digest, 'snapshot': str(copy),
                      'file_identity': file_identity})
    if forced_paths - {os.path.normcase(os.path.normpath(item['path'])) for item in files}:
        raise ValueError('forced-prefix-input-outside-frozen-closure')
    body = '// Verified same-context UBT batch.\n' + prefix + ''.join(
        '#include "' + entry['file'].replace('\\', '/') + '"\n' for entry in group)
    if prepared is not None:
        body = prepared['body']
        if {_command_key(path) for path in prepared['definition_sha256']} - {_command_key(item['path']) for item in files}:
            raise ValueError('ordered-definitions-outside-frozen-closure')
    identity_inputs = {'entries': [_native(entry) for entry in group],
                          'files': files, 'tool': tool_hash, 'compiler_environment': _compiler_environment(server_profile),
                          'server_profile': server_profile}
    if forced_prefix:
        identity_inputs['forced_prefix'] = forced_prefix
        identity_inputs['body'] = body
    if prepared is not None:
        identity_inputs.update(ordered_recipe=prepared['recipe'], body=body,
                               ordered_command=_native(prepared['candidate']))
    identity = _sha(_json(identity_inputs).encode())
    wrapper = assets / ('SuperUnity.Batch.' + identity[:24] + '.cpp')
    _write(wrapper, body)
    body_snapshot = assets / 'snapshots' / (_sha(body.encode()) + '.cpp')
    _write(body_snapshot, body)
    mapping = [{'type': 'file', 'name': str(_uri_path(item['uri'])),
                'external-contents': item['snapshot']} for item in files]
    mapping.append({'type': 'file', 'name': str(wrapper), 'external-contents': str(body_snapshot)})
    overlay = assets / ('overlay.' + identity[:24] + '.json')
    arguments = rewritten_arguments(prepared['candidate'] if prepared is not None else group[0], str(wrapper))
    if arguments is None:
        raise ValueError('batch-source-rewrite-failed')
    if forced_prefix:
        headers, removed, reason = _forced_prefix_arguments(arguments)
        if reason or headers != forced_prefix['headers']:
            raise ValueError('forced-prefix-argument-rewrite-mismatch')
        arguments = [argument for index, argument in enumerate(arguments) if index not in removed]
    # The original identity overlay falls through to live files. Never keep it
    # in a frozen candidate. Its equivalent closure-only outer layer resolves
    # original canonical names through the closed snapshot beneath it.
    arguments = _without_overlay_arguments(arguments)
    outer = None
    if canonical_names:
        # Stock clangd's canonical system-header table matches '/' suffixes.
        # The outer name is observable by SymbolCollector, unlike snapshot paths.
        # Preserve the original policy scope: unmapped dependencies must retain
        # their native lookup spelling, including system include suggestions.
        outer_data = _json({'version': 0, 'case-sensitive': False, 'use-external-names': True,
            'fallthrough': True, 'roots': [{'type': 'file', 'name': item['name'].replace('\\', '/'),
                'external-contents': item['name'].replace('\\', '/')} for item in mapping
                if os.path.normcase(os.path.normpath(item['name'])) in canonical_names]})
        outer = assets / ('canonical.' + _sha(outer_data.encode())[:24] + '.json')
        _write(outer, outer_data)
        mapping.append({'type': 'file', 'name': str(outer), 'external-contents': str(outer)})
    overlay_data = _json({'version': 0, 'case-sensitive': os.name != 'nt',
                         'use-external-names': False, 'fallthrough': False, 'roots': mapping})
    if canonical_names:
        overlay = assets / ('overlay.' + _sha(overlay_data.encode())[:24] + '.json')
    _write(overlay, overlay_data)
    overlays = ['-ivfsoverlay', str(overlay)] + (['-ivfsoverlay', str(outer)] if outer else [])
    candidate_base = _native(prepared['candidate']) if prepared is not None else group[0]
    candidate = _windows_paths(dict(candidate_base, file=str(wrapper),
        arguments=arguments + overlays,
        nvim_ue_members=[member for entry in group for member in entry['nvim_ue_members']],
        nvim_ue_batch_ubt_count=len(group)))
    return candidate, files, identity


def _binding_proof(group, added, directory, clangd, timeout):
    executable = Path(clangd)
    library = _libclang(executable)
    version = subprocess.run([str(executable), '--version'], capture_output=True, timeout=10,
        creationflags=(subprocess.CREATE_NO_WINDOW | subprocess.IDLE_PRIORITY_CLASS) if os.name == 'nt' else 0)
    major = re.search(r'clangd version (\d+)', version.stdout.decode('utf-8', errors='replace'))
    resource = executable.parent.parent / 'lib/clang' / (major.group(1) if major else 'missing')
    if not library or not resource.is_dir():
        raise ValueError('original-binding-toolchain-unavailable')
    requests = [{'uri': ref['location']['uri'], 'line': ref['location']['start'][0],
        'column': ref['location']['start'][1], 'symbol_id': ref['symbol_id'],
        'kind': ref['kind'], 'container': ref['container'],
        'contexts': ref['original_graph_indices']} for ref in added]
    request, output = directory / 'bindings-request.json', directory / 'bindings-result.json'
    _write(request, _json({'entries': [_native(entry) for entry in group], 'requests': requests,
                         'libclang_path': str(library), 'resource_dir': str(resource)}))
    result = subprocess.run([sys.executable, '-I', str(Path(__file__).with_name('clangd_batch_bindings.py')),
        '--request', str(request), '--out', str(output)], capture_output=True, timeout=timeout,
        creationflags=(subprocess.CREATE_NO_WINDOW | subprocess.IDLE_PRIORITY_CLASS) if os.name == 'nt' else 0)
    _write(directory / 'bindings.stderr.log', result.stderr)
    proof = json.loads(output.read_text(encoding='utf-8')) if output.is_file() else {}
    if result.returncode or proof.get('ok') is not True:
        raise ValueError('original-binding-proof-failed: ' + str(output))
    results = proof.get('evidence', {}).get('requests', [])
    if len(results) != len(requests) or not all(item.get('ok') is True for item in results):
        raise ValueError('incomplete-original-binding-proof')
    proven = {(r['uri'], r['line'], r['column'], r['symbol_id'], tuple(r['contexts'])) for r in requests}
    return lambda uri, line, column, symbol, contexts: (uri, line, column, symbol, tuple(contexts)) in proven


def _libclang(executable):
    return next((path for path in (executable.parent / 'libclang.dll',
        executable.parent.parent / 'lib/libclang.dylib', executable.parent.parent / 'lib/libclang.so') if path.is_file()), None)


def _template_argument_proof(group, candidate, requests, directory, clangd, timeout):
    if not candidate:
        raise ValueError('candidate-template-effective-command-unavailable')
    executable = Path(clangd)
    library = _libclang(executable)
    version = subprocess.run([str(executable), '--version'], capture_output=True, timeout=10,
        creationflags=(subprocess.CREATE_NO_WINDOW | subprocess.IDLE_PRIORITY_CLASS) if os.name == 'nt' else 0)
    major = re.search(r'clangd version (\d+)', version.stdout.decode('utf-8', errors='replace'))
    resource = executable.parent.parent / 'lib/clang' / (major.group(1) if major else 'missing')
    if not library or not resource.is_dir():
        raise ValueError('template-argument-toolchain-unavailable')
    entries = [_native(entry) for entry in group] + [_native(candidate)]
    request, output = directory / 'template-arguments-request.json', directory / 'template-arguments-result.json'
    payload = _json({'action': 'template-arguments', 'entries': entries, 'requests': requests,
                     'libclang_path': str(library), 'resource_dir': str(resource)})
    _write(request, payload)
    result = subprocess.run([sys.executable, '-I', str(Path(__file__).with_name('clangd_batch_bindings.py')),
        '--request', str(request), '--out', str(output)], capture_output=True, timeout=timeout,
        creationflags=(subprocess.CREATE_NO_WINDOW | subprocess.IDLE_PRIORITY_CLASS) if os.name == 'nt' else 0)
    _write(directory / 'template-arguments.stderr.log', result.stderr)
    raw = output.read_bytes() if output.is_file() else b'{}'
    proof = json.loads(raw)
    if result.returncode or proof.get('ok') is not True or request.read_bytes() != payload.encode('utf-8'):
        raise ValueError('template-argument-proof-failed: ' + str(output))
    evidence = proof.get('evidence', {})
    results = evidence.get('requests', [])
    if evidence.get('entries') != entries or len(results) != len(requests):
        raise ValueError('template-argument-proof-contexts-changed')
    for expected, observed in zip(requests, results):
        expected_contexts = {(item['index'], 'original') for item in expected['originals']}
        expected_contexts.add((len(group), 'candidate'))
        contexts = observed.get('contexts', [])
        if (observed.get('request') != expected or observed.get('ok') is not True
                or len(contexts) != len(expected_contexts)
                or any(type(item.get('index')) is not int or item.get('ok') is not True for item in contexts)
                or {(item['index'], item.get('role')) for item in contexts} != expected_contexts):
            raise ValueError('incomplete-template-argument-proof')
    proven = {_json(item) for item in requests}
    assets = [{'path': str(request), 'sha256': _sha(payload.encode('utf-8'))},
              {'path': str(output), 'sha256': _sha(raw)}]
    return lambda item: _json(item) in proven, assets


def _candidate_overlays(candidate):
    arguments = candidate['arguments']
    return [(arguments[index + 1], json.loads(Path(arguments[index + 1]).read_text(encoding='utf-8')))
            for index, argument in enumerate(arguments[:-1]) if argument == '-ivfsoverlay']


def _candidate_assets(candidate):
    paths = {candidate['file']}
    for path, overlay in _candidate_overlays(candidate):
        paths.add(path)
        # Outer mappings name virtual files in the closed lower layer. They
        # are not physical live assets; only lower snapshot targets are hashed.
        if overlay.get('fallthrough') is False:
            paths.update(item['external-contents'] for item in overlay['roots'] if item['type'] == 'file')
    return [{'path': path, 'sha256': _sha(Path(path).read_bytes())} for path in sorted(paths)]


def _alias_overlay(group, candidate, root, assets, clangd, timeout):
    executable = Path(clangd)
    library = _libclang(executable)
    if not library:
        raise ValueError('alias-toolchain-unavailable')
    flags = subprocess.CREATE_NO_WINDOW | subprocess.IDLE_PRIORITY_CLASS
    version = subprocess.run([clangd, '--version'], capture_output=True, timeout=10, creationflags=flags)
    major = re.search(r'clangd version (\d+)', version.stdout.decode('utf-8', errors='replace'))
    if not major:
        raise ValueError('alias-clangd-version-unavailable')
    resource = executable.parent.parent / 'lib/clang' / major.group(1)
    request, response = root / 'aliases-request.json', root / 'aliases-result.json'
    _write(request, _json({'entries': [_native(entry) for entry in group], 'libclang_path': str(library),
                         'resource_dir': str(resource)}))
    result = subprocess.run([sys.executable, '-I', str(Path(__file__).with_name('clangd_vfs_aliases.py')),
        '--request', str(request), '--out', str(response)], capture_output=True, timeout=timeout, creationflags=flags)
    _write(root / 'aliases.stderr.log', result.stderr)
    proof = json.loads(response.read_text(encoding='utf-8')) if response.is_file() else {}
    if result.returncode or proof.get('ok') is not True:
        raise ValueError('compiler-alias-proof-failed: ' + str(response))
    overlays = _candidate_overlays(candidate)
    if not overlays or overlays[0][1].get('fallthrough') is not False:
        raise ValueError('alias-lower-filesystem-not-closed')
    lower = overlays[0][1]
    norm = lambda path: os.path.normcase(os.path.normpath(path))
    known = {norm(item['name']): item['name'] for item in lower['roots']}
    aliases = {}
    for _, outer in overlays[1:]:
        if outer.get('fallthrough') is not True or outer.get('use-external-names') is not True:
            raise ValueError('unsupported-frozen-outer-overlay')
        for item in outer['roots']:
            if (item.get('type') != 'file' or norm(item['name']) not in known
                    or item.get('external-contents') != item['name']):
                raise ValueError('outer-canonical-target-outside-frozen-files')
            aliases[norm(item['name'])] = item
    original_alias_count = len(aliases)
    for item in proof.get('aliases', []):
        alias, target = item['alias'], item['target']
        if not Path(alias).is_absolute() or norm(target) not in known:
            raise ValueError('alias-target-outside-verified-dependencies')
        alias_key, target_key = norm(alias), norm(target)
        if alias_key in known:
            if alias_key != target_key:
                raise ValueError('alias-shadows-frozen-file')
            continue
        if alias_key in aliases and norm(aliases[alias_key]['external-contents']) != target_key:
            raise ValueError('conflicting-compiler-alias')
        aliases[alias_key] = {'type': 'file', 'name': alias, 'external-contents': known[target_key], 'use-external-name': True}
    parents = {norm(str(Path(item['name']).parent)) for item in lower['roots']}
    for item in proof.get('directory_aliases', []):
        alias, target = item['alias'], item['target']
        if not Path(alias).is_absolute() or norm(alias) != norm(target) or norm(target) not in parents:
            raise ValueError('directory-alias-outside-frozen-parents')
        if norm(alias) in known or norm(alias) in aliases:
            raise ValueError('directory-alias-shadows-frozen-file')
        aliases[norm(alias)] = {'type': 'directory-remap', 'name': alias,
            'external-contents': target, 'use-external-name': True}
    if len(aliases) == original_alias_count:
        raise ValueError('private-index-failed: compiler-errors: no compiler-proven VFS aliases')
    outer_data = _json({'version': 0, 'case-sensitive': False, 'use-external-names': True,
                       'fallthrough': True, 'roots': [aliases[key] for key in sorted(aliases)]})
    outer = assets / ('aliases.' + _sha(outer_data.encode())[:24] + '.json')
    _write(outer, outer_data)
    lower['roots'].append({'type': 'file', 'name': str(outer), 'external-contents': str(outer)})
    lower_data = _json(lower)
    inner = assets / ('overlay.aliases.' + _sha(lower_data.encode())[:24] + '.json')
    _write(inner, lower_data)
    return _windows_paths(dict(candidate, arguments=_without_overlay_arguments(candidate['arguments'])
        + ['-ivfsoverlay', str(inner), '-ivfsoverlay', str(outer)]))


def _candidate_index(effective_group, candidate, root, assets, clangd, timeout, runs, evidence, server_profile=None,
                     allow_alias_retry=True):
    observations = evidence.setdefault('query_profiles', [])
    count = len(observations)
    _observe_queries([candidate], clangd, server_profile, root / 'query', observations, timeout)
    if count:
        original = observations[0]
        for observed in observations[count:]:
            if ([_command_key(path) for path in observed['ordered_includes']]
                    != [_command_key(path) for path in original['ordered_includes']]
                    or observed['target'] != original['target']
                    or _command_key(observed['builtin_path']) != _command_key(original['builtin_path'])):
                raise ValueError('candidate-query-results-differ-from-original')
    try:
        graph, result, effective = _index([candidate], root, clangd, timeout, server_profile, run_metrics=runs)
    except ValueError as error:
        if not allow_alias_retry or os.name != 'nt' or not str(error).startswith('private-index-failed: compiler-errors:'):
            raise
        alias_started = time.monotonic()
        candidate = _alias_overlay(effective_group, candidate, root, assets, clangd, timeout)
        evidence['alias_probe_seconds'] = round(time.monotonic() - alias_started, 6)
        graph, result, effective = _index([candidate], root.with_name(root.name + '-aliases'), clangd,
            timeout, server_profile, run_metrics=runs)
    _verify_effective_query(candidate, effective[0], observations)
    evidence.update(assets=_candidate_assets(candidate) + _owned_overlay_assets(effective_group),
                    replay_candidate=candidate, effective_candidate=effective[0])
    return candidate, graph


def _admit(group, candidate, originals, graph, root, clangd, timeout, effective_group, effective_candidate=None):
    ignored = {Path(entry['file']).resolve().as_uri() for entry in group + [candidate]}
    verdict = compare_graphs(originals, graph, ignore_files=ignored)
    template_resolver, template_assets = None, []
    if verdict['reason'] == 'template-arguments-require-compiler-proof':
        template_resolver, template_assets = _template_argument_proof(effective_group, effective_candidate,
            verdict['template_arguments'], root, clangd, timeout)
        verdict = compare_graphs(originals, graph, ignore_files=ignored,
                                 resolve_template_arguments=template_resolver)
    if verdict['reason'] == 'added-references-require-original-proof':
        resolve = _binding_proof(effective_group, verdict['added_refs'], root, clangd, timeout)
        verdict = compare_graphs(originals, graph, ignore_files=ignored, resolve_original=resolve,
                                 resolve_template_arguments=template_resolver)
    if template_assets:
        verdict['template_argument_proof_assets'] = template_assets
    _write(root / 'admission.json', _json(verdict))
    return verdict


def replay_proof(entries, proof_dir, clangd_path, timeout=90):
    """Diagnose a historical run under current admission, never certify freshness.

    A run without its original include inventory cannot mint a current receipt.
    New cache records support fully validated policy-only replay in accelerate.
    """
    root, originals, effective_group = Path(proof_dir).resolve(), [], []
    candidate, effective_candidate = None, None
    forced_prefix, _ = _strict_forced_prefix(entries)
    for index in range(len(entries) + 1):
        directory = root / ('original-' + str(index) if index < len(entries) else 'candidate')
        raw = (directory / 'compile_commands.json').read_bytes()
        commands = json.loads(raw)
        report = json.loads((directory / 'run/run.json').read_text(encoding='utf-8'))
        if _sha(raw) != report['cdb_sha256'] or len(commands) != 2:
            raise ValueError('historical-native-cdb-changed')
        if index < len(entries) and commands[0] != _private_command(entries[index]):
            raise ValueError('historical-original-command-mismatch')
        effective = {}
        graph = _graph_result(report, Path(commands[-1]['file']), effective)
        if index < len(entries):
            originals.append(graph)
            effective_group.append(_effective_entry(entries[index], effective))
        else:
            candidate = commands[0]
            effective_candidate = _effective_entry(candidate, effective)
    if forced_prefix:
        # Historical diagnostic replay may not relabel a different constructor.
        prefix = ''.join('#include "' + (path.replace('\\', '/') if os.name == 'nt' else path) + '"\n'
                         for path in forced_prefix['headers'])
        remaining, _, unavailable = _forced_prefix_arguments(candidate['arguments'])
        if (unavailable or remaining or not Path(candidate['file']).read_text(encoding='utf-8').startswith(
                '// Verified same-context UBT batch.\n' + prefix)):
            raise ValueError('historical-forced-prefix-mismatch')
    work = _proof_work_root(root)
    work.mkdir(parents=True, exist_ok=True)
    evidence = Path(tempfile.mkdtemp(prefix='policy-replay-', dir=work))
    verdict = _admit(entries, candidate, originals, graph, evidence, clangd_path, timeout,
                     effective_group, effective_candidate)
    return {'ok': verdict['accepted'], 'admission': verdict, 'diagnostic_only': True,
            'freshness_proven': False, 'reason': 'historical-include-inventory-unavailable', 'evidence_dir': str(evidence)}


def _original_queries(entry, observations):
    if not observations:
        return []
    from clangd_query_profile import query_tuple
    key = query_tuple(_private_command(entry))
    return [item for item in observations if item['tuple'] == key][:1]


def _original_query_identity(observations):
    # Query tuples can be shared by different sources; the current original
    # command and its source bytes are bound separately below. Native query
    # output, lookup candidates, driver bytes and ordered includes still match.
    from clangd_query_profile import semantic_identity
    return [{key: value for key, value in semantic_identity(item).items()
             if key not in ('entry', 'entry_sha256', 'source_sha256')}
            for item in observations]


def _original_cache_path(entry, identities, output):
    key = _sha(_json({'entry': entry, 'identities': identities}).encode())
    return output / 'originals' / (key + '.json')


def _original_main_shard(entry, effective, paths):
    main = Path(_private_command(entry)['file'])
    for path in paths:
        if not os.path.normcase(Path(path).name).startswith(os.path.normcase(main.name) + '.'):
            continue
        shard = read_shard(path)
        own = [(uri, node) for uri, node in shard['sources'].items() if node['digest'] != '0000000000000000']
        if (len(own) == 1 and _command_key(_uri_path(own[0][0])) == _command_key(main)
                and own[0][1]['flags'] & 1):
            if shard['command'] != {key: effective[key] for key in ('directory', 'arguments')}:
                raise ValueError('original-effective-command-mismatch')
            return {'path': str(path), 'sha256': _sha(Path(path).read_bytes())}
    raise ValueError('original-main-shard-unavailable: ' + entry['file'])


def _cached_original(entry, identities, output, memo, queries, record_pool=None):
    try:
        record = json.loads(_original_cache_path(entry, identities, output).read_text(encoding='utf-8'))
        if (record.get('kind') != 'independent-original-tu' or record.get('entry') != entry
                or record.get('identities') != identities or not record.get('dependencies')
                or _original_query_identity(record['query_profiles']) != _original_query_identity(queries)
                or not _cache_valid(record, output, memo)):
            return None
        if len(record['graph_files']) != 1:
            return None
        asset = record['graph_files'][0]
        path = Path(asset['path'])
        if path.resolve().parent != output / 'originals' / 'graphs' or asset not in record['assets']:
            return None
        saved = _read_saved_graph(asset)
        graph, effective = saved['graph'], saved['effective_entry']
        if (saved['entry'] != entry or record['effective_entry'] != effective
                or dict(entry, directory=effective['directory'], arguments=effective['arguments']) != effective
                or not effective['arguments'] or not effective['directory']):
            return None
        main_asset = record['main_shard']
        if (main_asset not in record['assets']
                or _original_main_shard(entry, effective, [main_asset['path']]) != main_asset):
            return None
        dependencies = {item['uri']: item for item in record['dependencies']}
        main_key = _command_key(_private_command(entry)['file'])
        mains = [uri for uri in graph if _command_key(_uri_path(uri)) == main_key]
        if (len(dependencies) != len(record['dependencies']) or set(dependencies) != set(graph)
                or set(saved['frozen_sources']) != set(graph)
                or len(mains) != 1 or not graph[mains[0]]['source']['flags'] & 1):
            return None
        for uri, node in graph.items():
            dependency, source = dependencies[uri], node['source']
            if (Path(dependency['path']).resolve() != _uri_path(uri).resolve()
                    or source['flags'] & 2 or set(source['direct_includes']) - set(graph)
                    or source['digest'] == '0000000000000000'
                    or saved['frozen_sources'][uri] != {'digest': source['digest'], 'sha256': dependency['sha256']}
                    or {'path': dependency['snapshot'], 'sha256': dependency['sha256']} not in record['assets']):
                return None
        roots = _include_roots([entry], record['dependencies'], [effective], extra_roots=_query_roots(queries))
        if set(roots) != set(record['inventories']):
            return None
        _verify_effective_query(entry, effective, queries)
        if record_pool is not None:
            _intern_graph_records(graph, record_pool)
        return graph, effective
    except (OSError, ValueError, KeyError, TypeError, AttributeError):
        return None


def _read_saved_graph(asset):
    if 'format' in asset:
        import cdb_ordered_batch
        return cdb_ordered_batch.read_graph(asset)
    raw = Path(asset['path']).read_bytes()
    if _sha(raw) != asset['sha256']:
        raise ValueError('stored-collector-graph-changed')
    return json.loads(raw)


def _save_originals(group, originals, effective_group, pending, files, frozen_graph,
                    identities, output, memo, observations, compressed=False):
    """Bind independent native graphs to bytes via the existing frozen run.

    A successful frozen candidate supplies clangd's native source digests for
    the SHA-bound snapshots. Never label a post-index SHA as the original
    compiler's input without this association. Semantic rejection may still
    leave reusable originals; a failed candidate compilation cannot do so.
    """
    dependencies = {item['uri']: item for item in files}
    for index in list(pending):
        graph, entry, effective = originals[index], group[index], effective_group[index]
        if any(uri not in dependencies or uri not in frozen_graph
               or node['source']['digest'] != frozen_graph[uri]['source']['digest']
               for uri, node in graph.items()):
            continue
        own_files = [dependencies[uri] for uri in sorted(graph)]
        if any(_sha(Path(path).read_bytes()) != item['sha256']
               for item in own_files for path in (item['path'], item['snapshot'])):
            continue
        queries = _original_queries(entry, observations)
        roots = _include_roots([entry], own_files, [effective], extra_roots=_query_roots(queries))
        saved = {'entry': entry, 'effective_entry': effective, 'graph': graph,
                 'frozen_sources': {uri: {'digest': graph[uri]['source']['digest'],
                                          'sha256': dependencies[uri]['sha256']} for uri in graph}}
        if compressed:
            import cdb_ordered_batch
            asset = cdb_ordered_batch.save_graph(output / 'originals' / 'graphs', saved)
        else:
            raw = _json(saved)
            digest = _sha(raw.encode())
            path = output / 'originals' / 'graphs' / (digest + '.json')
            _write(path, raw)
            asset = {'path': str(path), 'sha256': digest}
        record = {'schema': 1, 'kind': 'independent-original-tu', 'entry': entry,
                  'effective_entry': effective, 'identities': identities,
                  'dependencies': own_files, 'query_profiles': queries,
                  'inventories': _inventories(roots, output, memo), 'graph_files': [asset],
                  'assets': [asset, pending[index]['main_shard']] + _owned_overlay_assets([entry])
                      + [{'path': item['snapshot'], 'sha256': item['sha256']} for item in own_files],
                  **pending[index]}
        _write(_original_cache_path(entry, identities, output), _json(record))
        del pending[index]


def _prove(group, root, assets, clangd, tool_hash, timeout, evidence, reused=None, server_profile=None,
           original_identities=None, inventory_memo=None, prepared=None):
    timings = evidence.setdefault('phase_timings', {})
    forced_prefix, unavailable = _strict_forced_prefix(group) if prepared is None else (None, None)
    if prepared is not None:
        evidence['ordered_recipe'] = prepared['recipe']
    if forced_prefix:
        evidence['forced_prefix'] = forced_prefix
    elif unavailable:
        evidence['forced_prefix_unavailable'] = unavailable
    original_overlay_assets = _owned_overlay_assets(group)
    for entry in group:
        _validate_ubt(entry)
    members = [member for entry in group for member in entry['nvim_ue_members']]
    if len(set(members)) != len(members):
        raise ValueError('overlapping-original-members')
    originals, runs, effective_group, pending_originals = [], [], [], {}
    evidence['run_metrics'] = runs
    record_pool = {}
    output = assets.parent.resolve()
    memo = inventory_memo if inventory_memo is not None else {}
    identities = original_identities or _identities(Path(clangd), tool_hash, imported=True, server_profile=server_profile)
    evidence.update(original_cache_hits=0, original_cache_misses=0, original_cache_unlinked=0)
    if reused:
        if not _forced_prefix_matches(reused, group):
            raise ValueError('stored-forced-prefix-mismatch')
        evidence.update({key: reused[key] for key in (
            'dependencies', 'assets', 'graph_files', 'identity', 'replay_candidate', 'effective_entries',
            'effective_candidate', 'query_profiles')})
        if 'candidate_order' in reused:
            evidence['candidate_order'] = reused['candidate_order']
        if server_profile:
            from clangd_query_profile import validate
            for index, observed in enumerate(evidence['query_profiles']):
                checked = validate(observed, observed['entry'], clangd, server_profile['query_driver'],
                    root / ('query-revalidate-' + str(index)), min(timeout, 10),
                    launch_cwd=server_profile['launch_cwd'], environment=dict(os.environ))
                if checked.get('ok') is not True:
                    raise ValueError('query-profile-replay-invalid: ' + checked.get('reason', 'unknown'))
        effective_group = evidence['effective_entries']
        if len(effective_group) != len(group):
            raise ValueError('stored-original-command-count-changed')
        graphs = []
        for index, item in enumerate(reused['graph_files']):
            loaded_graph = _read_saved_graph(item)
            if index < len(group):
                _intern_graph_records(loaded_graph, record_pool)
            graphs.append(loaded_graph)
        originals, graph = graphs[:-1], graphs[-1]
        if len(originals) != len(group):
            raise ValueError('stored-original-graph-count-changed')
        record_pool.clear()
        candidate, files, identity = dict(reused['replay_candidate']), reused['dependencies'], reused['identity']
    else:
        for index, entry in enumerate(group):
            queries = _original_queries(entry, evidence['query_profiles'])
            cached = _timed(timings, 'original_cache_validate', _cached_original,
                            entry, identities, output, memo, queries, record_pool)
            if cached:
                graph, effective_entry = cached
                effective = [effective_entry]
                evidence['original_cache_hits'] += 1
            else:
                evidence['original_cache_misses'] += 1
                graph, result, effective = _timed(timings, 'original_index', _index,
                    [entry], root / ('original-' + str(index)), clangd, timeout,
                    server_profile, record_pool=record_pool, run_metrics=runs)
                pending_originals[index] = {
                    'main_shard': _original_main_shard(entry, effective[0], result['shards']),
                    'first_index_metrics': {key: result.get(key) for key in (
                        'indexing_wall_seconds', 'cpu_seconds', 'peak_working_set_bytes')}}
                evidence['original_cache_unlinked'] = len(pending_originals)
            _verify_effective_query(entry, effective[0], evidence['query_profiles'])
            originals.append(graph)
            effective_group.extend(effective)
        record_pool.clear()
        evidence['effective_entries'] = effective_group
        candidate, files, identity = _timed(timings, 'freeze', _freeze,
            group, originals, assets, tool_hash, server_profile, timings=timings,
            **({'prepared': prepared} if prepared is not None else {}))
        evidence.update(dependencies=files, identity=identity, replay_candidate=candidate)
        evidence['assets'] = _candidate_assets(candidate) + original_overlay_assets
        candidate, graph = _timed(timings, 'candidate_index', _candidate_index,
            effective_group, candidate, root / 'candidate', assets, clangd, timeout, runs, evidence, server_profile,
            **({'allow_alias_retry': False} if prepared is not None else {}))
        _timed(timings, 'original_cache_save', _save_originals,
                        group, originals, effective_group, pending_originals, files, graph,
                        identities, output, memo, evidence['query_profiles'],
                        **({'compressed': True} if prepared is not None else {}))
        evidence['original_cache_unlinked'] = len(pending_originals)
    verdict = _timed(timings, 'graph_compare_and_bindings', _admit,
                     group, candidate, originals, graph, root, clangd, timeout,
                     effective_group, evidence['effective_candidate'])
    if verdict['reason'] == 'symbol-identities-changed' and verdict.get('missing') and not reused and prepared is None:
        missing = set(verdict['missing'])
        scores = [len(missing & {symbol['id'] for file in original.values() for symbol in file['symbols']})
                  for original in originals]
        owner = max(range(len(group)), key=lambda index: scores[index])
        if owner and scores[owner]:
            order = [owner] + [index for index in range(len(group)) if index != owner]
            candidate, files, identity = _timed(timings, 'freeze', _freeze,
                [group[index] for index in order], originals, assets, tool_hash, server_profile, timings=timings)
            evidence.update(dependencies=files, identity=identity, replay_candidate=candidate, candidate_order=order)
            evidence['assets'] = _candidate_assets(candidate) + original_overlay_assets
            candidate, graph = _timed(timings, 'candidate_index', _candidate_index,
                effective_group, candidate, root / 'candidate-reordered', assets, clangd, timeout, runs, evidence, server_profile)
            _timed(timings, 'original_cache_save', _save_originals,
                            group, originals, effective_group, pending_originals, files, graph,
                            identities, output, memo, evidence['query_profiles'])
            evidence['original_cache_unlinked'] = len(pending_originals)
            verdict = _timed(timings, 'graph_compare_and_bindings', _admit,
                             group, candidate, originals, graph, root, clangd, timeout,
                             effective_group, evidence['effective_candidate'])
    # Compiler proof request/result bytes become immutable receipt assets only
    # after admission completes; never watch the mutable invocation directory.
    sealed = []
    for item in verdict.get('template_argument_proof_assets', []):
        raw = Path(item['path']).read_bytes()
        if _sha(raw) != item['sha256']:
            raise ValueError('template-proof-changed-before-sealing')
        path = assets / ('template-proof.' + item['sha256'] + '.json')
        _write(path, raw)
        sealed.append({'path': str(path), 'sha256': item['sha256']})
    if sealed:
        verdict['template_argument_proof_assets'] = sealed
    evidence['assets'].extend(sealed)
    if prepared is not None:
        evidence['assets'].extend(prepared['recipe']['code_assets'])
    if not reused:
        evidence['graph_files'] = []
        for index, value in enumerate(originals + [graph]):
            with _phase(timings, 'graph_serialize'):
                if prepared is not None:
                    import cdb_ordered_batch
                    evidence['graph_files'].append(cdb_ordered_batch.save_graph(root / 'graphs', value))
                else:
                    path, raw = root / ('graph-' + str(index) + '.json'), _json(value)
                    _write(path, raw)
                    evidence['graph_files'].append({'path': str(path), 'sha256': _sha(raw.encode())})
    if not verdict.get('accepted'):
        raise ValueError('admission-rejected: ' + verdict['reason'])
    if _timed(timings, 'dependencies_revalidate', lambda:
            any(_sha(Path(item['path']).read_bytes()) != item['sha256'] for item in files)):
        raise ValueError('dependencies-changed-during-proof')
    if any(_sha(Path(item['path']).read_bytes()) != item['sha256'] for item in original_overlay_assets):
        raise ValueError('owned-overlay-changed-during-proof')
    if any(_sha(Path(item['path']).read_bytes()) != item['sha256']
           for item in _query_assets(evidence['query_profiles'])):
        raise ValueError('query-inputs-changed-during-proof')
    receipt = assets / ('receipt.' + identity[:24] + '.json')
    _write(receipt, _json({'schema': 1, 'identity': identity, 'tool_sha256': tool_hash,
        **({'forced_prefix': forced_prefix} if forced_prefix else {}),
        **({'ordered_recipe': prepared['recipe'], 'ordered_originals': [
            {'file': entry['file'], 'module_root': entry['nvim_ue_module_root'],
             'members': entry['nvim_ue_members']} for entry in group]} if prepared is not None else {}),
        'server_profile': server_profile,
        'query_profiles': evidence['query_profiles'],
        'effective_entries': [_native(entry) for entry in effective_group],
        'effective_candidate': _native(evidence['effective_candidate']),
        'original_entries': [_native(entry) for entry in group], 'candidate': _native(candidate),
        'dependencies': files, 'admission_reason': verdict['reason'],
        'original_graph_sha256': [item['sha256'] for item in evidence['graph_files'][:-1]],
        'candidate_graph_sha256': evidence['graph_files'][-1]['sha256'],
        'proven_added_references': verdict.get('added_refs', []),
        'proven_template_arguments': verdict.get('proven_template_arguments', []),
        'template_argument_proof_assets': verdict.get('template_argument_proof_assets', [])}))
    candidate['nvim_ue_batch_receipt'] = str(receipt)
    evidence['assets'] = [item for item in evidence['assets'] if Path(item['path']) != receipt]
    evidence['assets'].append({'path': str(receipt), 'sha256': _sha(receipt.read_bytes())})
    return candidate, {'receipt': str(receipt), 'graph_replayed': bool(reused),
        'original_cache_hits': evidence['original_cache_hits'], 'original_cache_misses': evidence['original_cache_misses'],
        'original_cache_unlinked': len(pending_originals),
        'candidate_order': evidence.get('candidate_order', list(range(len(group)))),
        'alias_probe_seconds': evidence.get('alias_probe_seconds', 0), 'run_metrics': [
        {key: run.get(key) for key in _RUN_METRIC_FIELDS}
        for run in runs]}


_HINT_BYTES, _HINT_GROUPS = 2 * 1024 * 1024, 2048


def _cache_key(group, identities, profile, ordered_recipe=None):
    value = {'entries': group, 'collector': identities.get('collector'),
        'tool': identities.get('tool'), 'tool_path': identities.get('tool_path'),
        'compiler_environment': identities.get('compiler_environment'), 'server_profile': profile}
    forced_prefix, _ = _strict_forced_prefix(group)
    if ordered_recipe is not None:
        value['ordered_recipe'] = ordered_recipe
    elif forced_prefix:
        value['forced_prefix'] = forced_prefix
    return _sha(_json(value).encode())


def _group_hint(group, key):
    return {'cache_key': key, 'entry_hashes': [_sha(_json(entry).encode()) for entry in group],
            'module_root': group[0]['nvim_ue_module_root'], 'context_key': compile_context_key(group[0])}


def _read_group_hints(output):
    try:
        path = output / 'accepted-groups.json'
        with path.open('rb') as stream:
            raw = stream.read(_HINT_BYTES + 1)
        if len(raw) > _HINT_BYTES:
            return [], 'group-hints-size-limit'
        document = json.loads(raw)
        hints = document['groups']
        if document['schema'] != 1 or not isinstance(hints, list) or len(hints) > _HINT_GROUPS:
            return [], 'invalid-group-hints'
        valid = []
        for item in hints:
            if (not isinstance(item, dict) or set(item) != {'cache_key', 'entry_hashes', 'module_root', 'context_key'}
                    or not isinstance(item['module_root'], str) or not item['module_root']
                    or not isinstance(item['context_key'], str) or not re.fullmatch('[0-9a-f]{16}', item['context_key'])
                    or not isinstance(item['entry_hashes'], list) or len(item['entry_hashes']) < 2
                    or any(not isinstance(value, str) or not re.fullmatch('[0-9a-f]{64}', value)
                           for value in [item['cache_key']] + item['entry_hashes'])
                    or len(set(item['entry_hashes'])) != len(item['entry_hashes'])):
                continue
            valid.append(item)
        return valid, 'loaded' if len(valid) == len(hints) else 'invalid-group-hints-skipped'
    except FileNotFoundError:
        return [], 'missing'
    except (OSError, ValueError, KeyError, TypeError):
        return [], 'invalid-group-hints'


def _cached_group_matches(record, group, output):
    """A lookup hint cannot substitute another group's valid certificate."""
    if (not isinstance(record, dict) or not isinstance(record.get('candidate'), dict)
            or not _forced_prefix_matches(record, group)):
        return False
    candidate = record['candidate']
    path = Path(candidate['nvim_ue_batch_receipt'])
    if path.resolve().parent != (output / 'assets').resolve():
        return False
    raw = path.read_bytes()
    digest = _sha(raw)
    receipt = json.loads(raw)
    if not isinstance(receipt, dict):
        return False
    order = record.get('candidate_order', list(range(len(group))))
    return (receipt.get('schema') == 2 and _forced_prefix_matches(receipt, group)
        and Path(receipt['output_dir']).resolve() == output
        and receipt['original_entries'] == [_native(entry) for entry in group]
        and receipt['candidate'] == _native(candidate)
        and all(receipt[key] == record[key] for key in ('identities', 'dependencies', 'inventories', 'query_profiles'))
        and candidate.get('nvim_ue_batch_receipt_sha256') == digest
        and {'path': str(path), 'sha256': digest} in record['assets']
        and candidate['nvim_ue_batch_ubt_count'] == len(group)
        and sorted(order) == list(range(len(group)))
        and candidate['nvim_ue_members'] == [member for i in order for member in group[i]['nvim_ue_members']])


def _explicit_group_indexes(entries, indexes, max_group, max_sources):
    if (not isinstance(entries, (list, tuple)) or any(not isinstance(entry, dict)
            or any(not isinstance(entry.get(name), str) or not entry[name] for name in ('file', 'directory'))
            or not isinstance(entry.get('arguments'), list) or not entry['arguments']
            or any(not isinstance(value, str) or not value for value in entry['arguments'])
            or (_is_ubt(entry) and (not isinstance(entry['nvim_ue_module_root'], str)
                or not isinstance(entry['nvim_ue_members'], list)
                or any(not isinstance(value, str) or not value for value in entry['nvim_ue_members'])))
            for entry in entries)):
        raise ValueError('explicit-group-entries-invalid')
    if type(max_group) is not int or max_group < 2 or type(max_sources) is not int or max_sources < 1:
        raise ValueError('explicit-group-limits-invalid')
    if (not isinstance(indexes, (list, tuple)) or not 2 <= len(indexes) <= max_group
            or any(type(index) is not int or not 0 <= index < len(entries) for index in indexes)
            or list(indexes) != sorted(set(indexes))):
        raise ValueError('explicit-group-indexes-invalid')
    selected = [entries[index] for index in indexes]
    if any(not _is_ubt(entry) for entry in selected):
        raise ValueError('explicit-group-original-ubt-required')
    if len({(entry['nvim_ue_module_root'], compile_context_key(entry)) for entry in selected}) != 1:
        raise ValueError('explicit-group-context-mismatch')
    members = [_command_key(member) for entry in selected for member in _validate_ubt(entry)]
    if len(set(members)) != len(members):
        raise ValueError('overlapping-original-members')
    if secondary_unity_chunks(selected, max_sources=max_sources, max_unities=max_group,
            split_member_classes=False, diagnostics=[],
            avoid_same_stem_pairs=False) != [list(range(len(selected)))]:
        raise ValueError('explicit-group-budget-exceeded')
    return list(indexes)


def _batch_groups(entries, groups, output, identities, profile, max_group, claimed, memo, metrics,
                  max_sources=80, verify_missing=False, prioritize_small=False):
    hints, metrics['group_hints_status'] = _read_group_hints(output)
    lookup = collections.defaultdict(list)
    for indexes in groups.values():
        for index in indexes:
            lookup[_sha(_json(entries[index]).encode())].append(index)
    eligible = []
    for hint in hints:
        hashes = hint['entry_hashes']
        if len(hashes) > max_group or any(len(lookup[h]) != 1 for h in hashes):
            continue
        indexes = [lookup[h][0] for h in hashes]
        group = [entries[i] for i in indexes]
        if sum(len(entry['nvim_ue_members']) for entry in group) > max_sources:
            continue
        if (any(entry['nvim_ue_module_root'] != hint['module_root']
                or compile_context_key(entry) != hint['context_key'] for entry in group)
                or _cache_key(group, identities, profile) != hint['cache_key']):
            continue
        eligible.append((indexes, hint['cache_key']))
    for indexes, key in sorted(eligible, key=lambda item: (-len(item[0]), tuple(item[0]), item[1])):
        if claimed.intersection(indexes):
            continue
        path = output / 'receipts' / (key + '.json')
        try:
            if path.resolve().parent != (output / 'receipts').resolve():
                continue
            record = json.loads(path.read_text(encoding='utf-8'))
            group = [entries[i] for i in indexes]
            if (isinstance(record, dict) and record.get('accepted') is True and record.get('identities') == identities
                    and _cached_group_matches(record, group, output) and _cache_valid(record, output, memo)):
                yield indexes, record
        except (OSError, ValueError, KeyError, TypeError):
            continue
    # Accepted hints may cover only part of an otherwise larger chunk. Repack
    # the unclaimed originals so a cached pair cannot suppress their candidacy.
    available = [index for index in range(len(entries)) if index not in claimed]
    chunks = [[available[index] for index in chunk] for chunk in
        strict_unity_chunks([entries[index] for index in available],
            max_sources=max_sources, max_unities=max_group)]
    if prioritize_small:
        # A first bounded prepare should prove a small same-context group, not
        # retain the largest module's independent graphs for the whole budget.
        chunks.sort(key=lambda chunk: (sum(len(entries[i]['nvim_ue_members']) for i in chunk),
                                       len(chunk), chunk[0]))
    pending = list(reversed(chunks))
    while pending:
        chunk = pending.pop()
        if claimed.intersection(chunk):
            continue
        yield chunk, None
        # A semantic conflict in a large chunk need not disable every original
        # in it. Reuse their original evidence when trying smaller chunks. An
        # automatic cache-only lookup never starts this qualification work.
        if (verify_missing and len(chunk) > 2 and not claimed.intersection(chunk)
                and metrics['groups'][-1]['reason'].startswith('admission-rejected:')):
            middle = len(chunk) // 2
            pending.extend(part for part in (chunk[middle:], chunk[:middle]) if len(part) > 1)


def _save_group_hints(output, additions):
    existing, _ = _read_group_hints(output)
    merged = {item['cache_key']: item for item in existing + additions}
    raw = _json({'schema': 1, 'groups': [merged[key] for key in sorted(merged)]})
    if len(merged) > _HINT_GROUPS or len(raw.encode()) > _HINT_BYTES:
        return 'group-hints-capacity-exceeded'
    try:
        _write(output / 'accepted-groups.json', raw)
        return 'saved'
    except OSError:
        # Losing an advisory lookup is observable, but never drops coverage or
        # invalidates an independently usable receipt.
        return 'group-hints-write-failed'


def _tier1_ubt_members(entry):
    members = _validate_ubt(entry)
    expected = '// Compiler-authored UBT unity membership; copied into nvim cache.\n' + ''.join(
        '#include "' + path + '"\n' for path in members)
    if Path(entry['file']).read_text(encoding='utf-8') != expected:
        raise ValueError('tier1-noncanonical-original-wrapper')
    return members


_TIER1_PREFIX_RECIPE = 'tier1-ordered-absolute-forced-prefix-v1'


def _tier1_recipe(group, recipe=None):
    if recipe is None:
        return None
    if recipe != _TIER1_PREFIX_RECIPE:
        raise ValueError('tier1-unknown-recipe')
    prefix, reason = _strict_forced_prefix(group)
    if reason or not prefix:
        raise ValueError(reason or 'tier1-recipe-forced-prefix-required')
    if any(any(char in path for char in ('"', '\r', '\n', '\0')) for path in prefix['headers']):
        raise ValueError('tier1-recipe-invalid-header-path')
    return {'recipe': recipe, 'headers': prefix['headers']}


@_tier1_overlay_read_view()
def _tier1_candidate_spec(group, assets, recipe=None):
    """Describe a deterministic live-source candidate without writing assets."""
    members = [path for entry in group for path in _tier1_ubt_members(entry)]
    body = '// Tier 1 same-context compiler-authored UBT batch.\n' + ''.join(
        '#include "' + path.replace('\\', '/') + '"\n' for path in members)
    descriptor = _tier1_recipe(group, recipe)
    identity_inputs = {'entries': [_native(entry) for entry in group], 'body': body}
    if descriptor is not None:
        body = '// Tier 1 ordered absolute forced-prefix batch v1.\n' + ''.join(
            '#include "' + path.replace('\\', '/') + '"\n' for path in descriptor['headers'] + members)
        identity_inputs.update(body=body, recipe=descriptor)
    identity = _sha(_json(identity_inputs).encode())
    wrapper = Path(assets) / ('SuperUnity.Tier1.Batch.' + identity[:24] + '.cpp')
    arguments = rewritten_arguments(group[0], str(wrapper))
    if arguments is None:
        raise ValueError('tier1-source-rewrite-failed')
    if descriptor is not None:
        headers, removed, reason = _forced_prefix_arguments(arguments)
        if reason or headers != descriptor['headers']:
            raise ValueError(reason or 'tier1-recipe-rewritten-prefix-mismatch')
        aliases = {_command_key(path) for path in members + [entry['file'] for entry in group] + [str(wrapper)]}
        if any(_command_key(path) in aliases for path in headers):
            raise ValueError('tier1-recipe-header-source-alias')
        arguments = [value for index, value in enumerate(arguments) if index not in removed]
    candidate = dict(group[0], file=str(wrapper), arguments=arguments,
        nvim_ue_members=[member for entry in group for member in entry['nvim_ue_members']],
        nvim_ue_tier=1, nvim_ue_tier1_ubt_count=len(group))
    # Tier 1 qualifies only this explicit candidate run. It must never inherit
    # a strict frozen reader's certificate or be discovered by its cache.
    for name in ('nvim_ue_batch_receipt', 'nvim_ue_batch_receipt_sha256', 'nvim_ue_batch_ubt_count'):
        candidate.pop(name, None)
    if descriptor is not None:
        candidate['nvim_ue_tier1_recipe'] = descriptor
    return _windows_paths(candidate), body


def _tier1_candidate(group, assets, recipe=None):
    """Build a content-addressed Tier 1 wrapper without strict-proof metadata."""
    candidate, body = _tier1_candidate_spec(group, assets, **({'recipe': recipe} if recipe is not None else {}))
    _write(candidate['file'], body)
    return candidate


def _tier1_candidate_index(candidate, directory, clangd, timeout, server_profile=None):
    """Index just the candidate, then inspect per-file own nodes, not graphs.

    Included .cpp files have a file shard with a nonzero own digest. They need
    not have the IsTU flag (1), which belongs to the enclosing candidate TU.
    """
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True)
    trigger = directory / 'trigger.cpp'
    _write(trigger, '// Private Tier 1 BackgroundIndex trigger.\n')
    _write(directory / 'compile_commands.json', _json([_private_command(candidate),
        {'directory': str(directory), 'file': str(trigger),
         'arguments': ['clang++', '-x', 'c++', '-c', str(trigger)]}]))
    result = run(directory, directory / 'run', trigger, clangd, timeout=timeout, jobs=1,
        server_profile=server_profile)
    if result.get('background_compile_success') is not True:
        return dict(result, member_main_shards=[])
    sources = set()
    for path in result.get('shards', []):
        shard = read_shard(path)
        own = [(uri, node) for uri, node in shard['sources'].items()
               if node['digest'] != '0000000000000000']
        if len(own) != 1:
            raise ValueError('tier1-invalid-own-shard: ' + str(path))
        uri, node = own[0]
        if node['flags'] & 2:
            return dict(result, background_compile_success=False, shard_had_errors=True,
                member_main_shards=sorted(sources))
        sources.add(str(_uri_path(uri)))
    return dict(result, member_main_shards=sorted(sources))


def _tier1_members_match(group, candidate, recipe=None):
    """Compare the wrapper's actual includes independently of its metadata."""
    expected = [path for entry in group for path in _tier1_ubt_members(entry)]
    text = Path(candidate['file']).read_text(encoding='utf-8')
    if recipe is not None:
        wanted, body = _tier1_candidate_spec(group, Path(candidate['file']).parent, recipe=recipe)
        keys = [_command_key(path) for path in expected]
        members = [member for entry in group for member in entry['nvim_ue_members']]
        return (text == body and _native(candidate) == _native(wanted)
            and candidate.get('nvim_ue_tier1_recipe') == wanted['nvim_ue_tier1_recipe']
            and candidate.get('nvim_ue_members') == members and len(keys) == len(set(keys))
            and len(members) == len(set(members))), expected
    # This producer owns the whole wrapper. Reject noncanonical lines instead
    # of overlooking an additional preprocessor spelling such as '# include'.
    if not re.fullmatch(r'// Tier 1 same-context compiler-authored UBT batch\.\n'
                        r'(?:#include "[^"\r\n]+"\n)+', text):
        return False, expected
    actual = re.findall(r'^#include "([^"]+)"$', text, re.M)
    original_keys, candidate_keys = ([_command_key(path) for path in paths] for paths in (expected, actual))
    expected_members = [member for entry in group for member in entry['nvim_ue_members']]
    actual_members = candidate.get('nvim_ue_members', [])
    return (len(original_keys) == len(set(original_keys))
        and len(candidate_keys) == len(set(candidate_keys))
        and set(original_keys) == set(candidate_keys)
        and len(expected_members) == len(set(expected_members))
        and len(actual_members) == len(set(actual_members))
        and set(expected_members) == set(actual_members)), expected


def _tier1_source_coverage(entries):
    return collections.Counter(member for entry in entries for member in
        (entry.get('nvim_ue_members') or [entry.get('file', '')]))


@_tier1_overlay_read_view()
def _tier1_inputs(group, recipe=None):
    paths = [entry['file'] for entry in group]
    paths += [path for entry in group for path in _tier1_ubt_members(entry)]
    inputs = ([{'path': str(path), 'sha256': _sha(Path(path).read_bytes())}
             for path in sorted(set(paths))] + _owned_overlay_assets(group))
    if recipe is not None:
        for path in sorted(set(_tier1_recipe(group, recipe)['headers'])):
            raw = Path(path).read_bytes()
            if not raw or b'\0' in raw or raw.startswith((b'CPCH', b'CPCM')):
                raise ValueError('tier1-recipe-forced-header-not-text')
            raw.decode('utf-8')
            inputs.append({'path': path, 'sha256': _sha(raw)})
    return inputs


def _tier1_cache_key(group, candidate, tool_hash, profile, environment, recipe=None, fallback_of=None):
    value = {'original_entries': [_native(entry) for entry in group],
        'candidate': _native(candidate), 'tool_sha256': tool_hash,
        'server_profile': profile, 'compiler_environment': environment}
    if recipe is not None:
        value['recipe'] = _tier1_recipe(group, recipe)
    if fallback_of is not None:
        value['fallback_of'] = fallback_of
    return _sha(_json(value).encode())


def _tier1_compile_rejection(result):
    """Only a completed, cleanly exited run can establish a reusable rejection."""
    return (isinstance(result, dict) and result.get('indexing_complete') is True
        and type(result.get('exit_code')) is int and result['exit_code'] == 0
        and ((type(result.get('compile_failure_count')) is int and result['compile_failure_count'] > 0)
            or result.get('shard_had_errors') is True))


def _tier1_gate_failed(reason):
    return (isinstance(reason, str) and (reason in ('tier1-candidate-index-failed',
        'tier1-main-shards-missing', 'tier1-membership-mismatch')
        or reason.startswith('tier1-invalid-own-shard: ')))


def _tier1_split_rejection(receipt):
    result = receipt.get('compile_result') or {}
    return (receipt.get('split_retry') is True
        and _tier1_gate_failed(receipt.get('reason'))
        and result.get('indexing_complete') is True
        and type(result.get('exit_code')) is int and result['exit_code'] == 0)


def _tier1_cached(group, candidate, body, output, key, inputs, tool_hash, profile, environment,
                  recipe=None, fallback_of=None):
    """Validate only wrapper/member/owned-overlay bytes, not header dependencies.

    Header changes intentionally DO NOT invalidate Tier 1 receipts. This is the
    selected live-CDB tradeoff; these receipts never authorize frozen activation.
    The explicit prefix recipe additionally binds its ordered forced-header bytes.
    """
    try:
        index = json.loads((output / 'receipts' / (key + '.json')).read_text(encoding='utf-8'))
        if (index.get('schema') != 1 or index.get('tier') != 1 or index.get('cache_key') != key
                or type(index.get('accepted')) is not bool):
            raise ValueError('tier1-cache-index-invalid')
        path = Path(index['receipt'])
        if path.resolve().parent != (output / 'receipts').resolve():
            raise ValueError('tier1-cache-receipt-outside-store')
        raw = path.read_bytes()
        digest = _sha(raw)
        receipt = json.loads(raw)
        descriptor = _tier1_recipe(group, recipe)
        if (digest != index['receipt_sha256'] or receipt.get('schema') != 1
                or receipt.get('tier') != 1 or receipt.get('reusable') is not True
                or receipt.get('cache_key') != key or receipt.get('accepted') is not index['accepted']
                or receipt.get('original_entries') != [_native(entry) for entry in group]
                or receipt.get('candidate') != _native(candidate)
                or receipt.get('members') != candidate['nvim_ue_members']
                or receipt.get('tool_sha256') != tool_hash or receipt.get('server_profile') != profile
                or receipt.get('compiler_environment') != environment
                or receipt.get('fallback_of') != fallback_of
                or receipt.get('recipe') != descriptor or candidate.get('nvim_ue_tier1_recipe') != descriptor):
            raise ValueError('tier1-cache-receipt-identity-mismatch')
        if receipt.get('inputs') != inputs:
            raise ValueError('tier1-cache-inputs-changed')
        if (not receipt['accepted'] and not _tier1_compile_rejection(receipt.get('compile_result'))
                and not _tier1_split_rejection(receipt)):
            raise ValueError('tier1-cache-rejection-inconclusive')
        if receipt.get('candidate_sha256') != _sha(body.encode('utf-8')):
            raise ValueError('tier1-cache-candidate-hash-mismatch')
        if Path(candidate['file']).read_bytes() != body.encode('utf-8'):
            raise ValueError('tier1-cache-candidate-changed')
        gates = receipt.get('gates')
        if (not isinstance(gates, dict) or not isinstance(receipt.get('reason'), str)
                or not receipt['reason'] or (receipt['accepted'] and not all(
                    gates.get(name) is True for name in ('compile_success', 'main_shards_complete', 'members_equal')))):
            raise ValueError('tier1-cache-gates-invalid')
        return {'receipt': str(path), 'receipt_sha256': digest, 'accepted': receipt['accepted'],
                'reason': receipt['reason'], 'gates': gates}, None
    except (OSError, ValueError, KeyError, TypeError, AttributeError) as error:
        return None, str(error)


def _tier1_postcheck(group, candidate, inputs, environment, profile, gates, recipe=None):
    gates['members_equal'], _ = _tier1_members_match(group, candidate, **({'recipe': recipe} if recipe is not None else {}))
    if not gates['members_equal']:
        raise ValueError('tier1-membership-mismatch')
    if any(_sha(Path(item['path']).read_bytes()) != item['sha256'] for item in inputs):
        raise ValueError('tier1-inputs-changed-during-index')
    if _compiler_environment(profile) != environment:
        raise ValueError('tier1-compiler-environment-changed')


def _tier1_write_receipt(output, receipt, record):
    """The ordinary schema1 commit path, also used after real cohort proof."""
    receipt_raw = _json(receipt)
    receipt_digest = _sha(receipt_raw.encode())
    receipt_path = output / 'receipts' / ('receipt.' + receipt_digest[:24] + '.json')
    _write(receipt_path, receipt_raw)
    if _sha(receipt_path.read_bytes()) != receipt_digest:
        raise ValueError('tier1-receipt-changed-during-publication')
    record['receipt'] = str(receipt_path)
    if receipt['cache_key']:
        _write(output / 'receipts' / (receipt['cache_key'] + '.json'), _json({'schema': 1, 'tier': 1,
            'cache_key': receipt['cache_key'], 'accepted': receipt['accepted'], 'receipt': str(receipt_path),
            'receipt_sha256': receipt_digest}))
    return receipt_path, receipt_digest


def tier1_grouping_options(max_unities=8, budget_factor=None):
    """Share Tier 1 packing policy across qualification, planning and reuse."""
    try:
        split_classes = int(os.environ.get('NVIM_UE_TIER1_SPLIT_CLASSES', '0'))
    except ValueError as error:
        raise ValueError('NVIM_UE_TIER1_SPLIT_CLASSES must be 0 or 1') from error
    if split_classes not in (0, 1):
        raise ValueError('NVIM_UE_TIER1_SPLIT_CLASSES must be 0 or 1')
    return {'max_unities': max_unities, 'budget_factor': budget_factor,
        'split_member_classes': bool(split_classes)}


def _tier1_crosses_classes(group):
    classes = set()
    for entry in group:
        generated = [member.lower().endswith('.gen.cpp') for member in entry['nvim_ue_members']]
        classes.add('gen' if all(generated) else 'mixed' if any(generated) else 'src')
    return len(classes) > 1


def _tier1_fallback_chunks(group, max_group=8, budget_factor=None):
    if not _tier1_crosses_classes(group):
        return []
    return secondary_unity_chunks(group, max_unities=max_group, budget_factor=budget_factor,
        split_member_classes=True, avoid_same_stem_pairs=False)


@tier1_overlay_scope()
def _accelerate_tier1(entries, output_dir, clangd_path, max_group=8, timeout=90,
                      budget_factor=None, server_profile=None, reuse_only=False, recipe=None):
    """Qualify live-source chunks, or perform strictly read-only cache reuse.

    Header dependencies are deliberately excluded from the Tier 1 cache boundary.
    Compiler-success and rejection caches bind wrapper/member/owned-overlay bytes.
    They are independent of strict frozen-runtime qualification.
    Only the explicit prefix recipe adds its forced-header bytes to those inputs.
    """
    started = time.monotonic()
    output = Path(output_dir).resolve() / 'tier1'
    diagnostics = []
    chunks = secondary_unity_chunks(entries, diagnostics=diagnostics,
        **tier1_grouping_options(max_unities=max_group, budget_factor=budget_factor))
    if recipe is not None:
        _tier1_recipe(entries, recipe)
        if chunks != [list(range(len(entries)))]:
            raise ValueError('tier1-recipe-exact-whole-chunk-required')
    metrics = {'tier': 1, 'original_ubt_count': sum(_is_ubt(entry) for entry in entries),
        'batch_count': 0, 'accepted_ubt_count': 0, 'groups': [], 'chunk_diagnostics': diagnostics,
        'cache_hits': 0, 'receipt_reuse': False, 'proof_directory': None}
    shaders = {'.usf', '.ush', '.hlsl', '.hlsli', '.glsl', '.vert', '.frag', '.geom', '.tesc', '.tese', '.comp', '.metal'}
    metrics['shader_count'] = sum(Path(entry.get('file', '')).suffix.lower() in shaders for entry in entries)
    metrics['exact_count'] = sum(not _is_ubt(entry) and Path(entry.get('file', '')).suffix.lower()
        in ('.c', '.cc', '.cpp', '.cxx', '.c++') for entry in entries)
    metrics['other_count'] = len(entries) - metrics['original_ubt_count'] - metrics['shader_count'] - metrics['exact_count']
    resolved = shutil.which(str(clangd_path)) if clangd_path else None
    executable = Path(resolved or clangd_path or '')
    try:
        tool_hash = _tier1_blob_sha('tool', executable.read_bytes()) if executable.is_file() else None
        tool_error = None
    except OSError as error:
        tool_hash, tool_error = None, 'clangd-unreadable: ' + str(error)
    try:
        profile, profile_error = normalize_server_profile(server_profile), None
    except ValueError as error:
        profile, profile_error = None, str(error)
    environment = _compiler_environment(profile)
    invocation, replacements, consumed = None, {}, set()
    pending = [(chunk, None) for chunk in chunks]
    for chunk, fallback_of in pending:
        group = [entries[index] for index in chunk]
        gates = {'compile_success': False, 'main_shards_complete': False, 'members_equal': False}
        record = {'tier': 1, 'original_indexes': chunk, 'original_ubt_count': len(chunk),
            'accepted': False, 'gates': gates, 'run_metrics': [], 'cached': False, 'deferred': False}
        recipe_options = {'recipe': recipe} if recipe is not None else {}
        if recipe_options:
            record['recipe'] = recipe
        cache_options = {'fallback_of': fallback_of} if fallback_of is not None else {}
        if fallback_of is not None:
            record['fallback_of'] = fallback_of
        inputs, candidate, result, cache_key, cached, body = [], None, None, None, None, None
        group_started = time.monotonic()
        try:
            if profile_error:
                raise ValueError(profile_error)
            if not tool_hash:
                raise ValueError(tool_error or 'clangd-unavailable')
            inputs = _tier1_inputs(group, **recipe_options)
            candidate, body = _tier1_candidate_spec(group, output / 'assets', **recipe_options)
            cache_key = _tier1_cache_key(group, candidate, tool_hash, profile, environment,
                **recipe_options, **cache_options)
            record['cache_key'] = cache_key
            cached, record['cache_reason'] = _tier1_cached(group, candidate, body, output,
                cache_key, inputs, tool_hash, profile, environment, **recipe_options, **cache_options)
            if cached:
                record.update(accepted=cached['accepted'], reason=cached['reason'], cached=True,
                    gates=dict(cached['gates']), receipt=cached['receipt'])
                metrics['cache_hits'] += 1
            elif reuse_only:
                record.update(reason='verification-not-cached', deferred=True)
            else:
                candidate = _tier1_candidate(group, output / 'assets', **recipe_options)
                gates['members_equal'], expected = _tier1_members_match(group, candidate, **recipe_options)
                if not gates['members_equal']:
                    raise ValueError('tier1-membership-mismatch')
                if invocation is None:
                    work = _proof_work_root(output)
                    work.mkdir(parents=True, exist_ok=True)
                    invocation = Path(tempfile.mkdtemp(prefix='tier1-', dir=work))
                    metrics['proof_directory'] = str(invocation)
                run_name = ('fallback-' if fallback_of is not None else 'group-') + str(chunk[0])
                result = _tier1_candidate_index(candidate, invocation / run_name,
                    str(executable.resolve()), timeout, server_profile=profile)
                record['run_metrics'] = [{key: result.get(key) for key in _RUN_METRIC_FIELDS}]
                gates['compile_success'] = result.get('background_compile_success') is True
                if not gates['compile_success']:
                    raise ValueError('tier1-candidate-index-failed')
                observed = {_command_key(path) for path in result.get('member_main_shards', [])}
                record['missing_member_main_shards'] = [path for path in expected if _command_key(path) not in observed]
                gates['main_shards_complete'] = (result.get('missing_main_shards') in ([], 0)
                    and not record['missing_member_main_shards'])
                if not gates['main_shards_complete']:
                    raise ValueError('tier1-main-shards-missing')
                # Recheck actual wrapper and source inputs after the private run.
                _tier1_postcheck(group, candidate, inputs, environment, profile, gates, **recipe_options)
                record.update(accepted=True, reason='tier1-compile-shards-members-accepted')
        except (OSError, ValueError, KeyError, TypeError, subprocess.TimeoutExpired) as error:
            record['reason'] = str(error)
            record['deferred'] = reuse_only
        split_retry = (fallback_of is None and cache_key is not None and not record['accepted']
            and _tier1_gate_failed(record['reason'])
            and _tier1_crosses_classes(group))
        # Runtime/process paths and timings deliberately stay out of receipts.
        # These diagnostic receipts have no strict-runtime publication fields.
        try:
            if cached:
                receipt_path, receipt_digest = Path(cached['receipt']), cached['receipt_sha256']
            elif not reuse_only:
                receipt = {'schema': 1, 'tier': 1,
                'reusable': record['accepted'] or _tier1_compile_rejection(result), 'cache_key': cache_key,
                'accepted': record['accepted'],
                'reason': record['reason'], 'gates': dict(gates), 'inputs': inputs,
                'compile_result': {name: result.get(name) for name in
                    ('indexing_complete', 'exit_code', 'compile_failure_count', 'shard_had_errors')}
                    if result is not None else None,
                'original_entries': [_native(entry) for entry in group],
                'candidate': _native(candidate) if candidate else None,
                'candidate_sha256': _sha(body.encode('utf-8')) if body is not None else None,
                'members': candidate.get('nvim_ue_members', []) if candidate else [],
                'tool_sha256': tool_hash, 'server_profile': profile, 'compiler_environment': environment}
                if split_retry:
                    receipt['split_retry'] = True
                    receipt['reusable'] = receipt['reusable'] or _tier1_split_rejection(receipt)
                if fallback_of is not None:
                    receipt['fallback_of'] = fallback_of
                if recipe_options:
                    receipt['recipe'] = _tier1_recipe(group, recipe)
                receipt_path, receipt_digest = _tier1_write_receipt(output, receipt, record)
        except (OSError, ValueError, KeyError, TypeError) as error:
            record.update(accepted=False, reason='tier1-receipt-unavailable: ' + str(error))
        if record['accepted']:
            candidate.update(nvim_ue_tier1_receipt=str(receipt_path),
                nvim_ue_tier1_receipt_sha256=receipt_digest)
            replacements[min(chunk)] = dict(sorted(candidate.items()))
            consumed.update(index for index in chunk if index != min(chunk))
            metrics['batch_count'] += 1
            metrics['accepted_ubt_count'] += len(chunk)
        record['proof_seconds'] = round(time.monotonic() - group_started, 6)
        metrics['groups'].append(record)
        if split_retry and _tier1_gate_failed(record['reason']):
            children = [[chunk[index] for index in child] for child in
                _tier1_fallback_chunks(group, max_group=max_group, budget_factor=budget_factor)]
            record['fallback_chunks'] = children
            pending.extend((child, cache_key) for child in children)
        print('[tier1-batch] ' + ('admitted' if record['accepted'] else 'retained')
            + ' group=' + str(chunk[0]) + ' ubt=' + str(len(chunk)) + ' reason=' + record['reason'], flush=True)
    background = [replacements.get(index, entry) for index, entry in enumerate(entries) if index not in consumed]
    original_coverage = _tier1_source_coverage(entries)
    covered = _tier1_source_coverage(background)
    if original_coverage != covered:
        background = list(entries)
        metrics.update(batch_count=0, accepted_ubt_count=0, invalidated_reason='tier1-output-coverage-mismatch')
        for record in metrics['groups']:
            record.update(accepted=False, reason='tier1-output-coverage-mismatch')
    metrics.update(output_entries=len(background), input_member_count=sum(original_coverage.values()),
        output_member_count=sum(_tier1_source_coverage(background).values()),
        coverage_complete=original_coverage == _tier1_source_coverage(background),
        retained_ubt_count=metrics['original_ubt_count'] - metrics['accepted_ubt_count'],
        new_batch_count=sum(record['accepted'] and not record['cached'] for record in metrics['groups']),
        new_proof_count=sum(not record['cached'] and not record['deferred'] for record in metrics['groups']),
        deferred_group_count=sum(record['deferred'] for record in metrics['groups']),
        proof_accepted_count=sum(record['accepted'] for record in metrics['groups']),
        proof_rejected_count=sum(not record['accepted'] and not record['deferred'] for record in metrics['groups']),
        proof_uncached_count=sum(record['deferred'] for record in metrics['groups']),
        selector_reuse_status='accepted' if replacements else 'zero-hit',
        receipt_reuse=metrics['cache_hits'] > 0,
        proof_seconds=round(time.monotonic() - started, 6))
    return background, metrics


def tier2_enabled():
    value = os.environ.get('NVIM_UE_TIER2', '0')
    if value not in ('0', '1'):
        raise ValueError('NVIM_UE_TIER2 must be 0 or 1')
    return value == '1'


def tier2_grouping_options(max_unities=8, budget_factor=None):
    """Resolve the same environment budget as ordinary Tier 1 planning."""
    if budget_factor is None:
        budget_factor = int(os.environ.get('NVIM_UE_SUPER_UNITY_BUDGET_FACTOR', '8'))
    return {'max_unities': max_unities, 'budget_factor': budget_factor}


def _tier2_candidate(group, assets):
    # Include the complete recipe in the asset identity without depending on a
    # runtime proof directory. The source placeholder itself is never written.
    placeholder, body = tier2_candidate_spec(group, str(Path(assets) / 'candidate.cpp'))
    identity = _sha(_json({'entries': [_native(entry) for entry in group],
        'body': body, 'arguments': placeholder['arguments'][:-1]}).encode())
    wrapper = Path(assets) / ('SuperUnity.Tier2.Batch.' + identity[:24] + '.cpp')
    candidate, body = tier2_candidate_spec(group, str(wrapper))
    for name in list(candidate):
        if (name.startswith('nvim_ue_batch_') or name.startswith('nvim_ue_tier1_')
                or name.startswith('nvim_ue_frozen') or name.startswith('nvim_ue_freeze')):
            candidate.pop(name)
    candidate['nvim_ue_tier2_ubt_count'] = len(group)
    return _windows_paths(candidate), body


def _tier2_inputs(group):
    inputs = _tier1_inputs(group)
    bound = {item['path'] for item in inputs}
    for path in sorted({_tier2_entry(entry)['definitions'] for entry in group}):
        if path not in bound:
            inputs.append({'path': path, 'sha256': _sha(Path(path).read_bytes())})
    return inputs


def _tier2_members_match(group, candidate, body):
    expected = [path for entry in group for path in _tier1_ubt_members(entry)]
    wanted, wanted_body = _tier2_candidate(group, Path(candidate['file']).parent)
    keys = [_command_key(path) for path in expected]
    members = [member for entry in group for member in entry['nvim_ue_members']]
    return (body == wanted_body and Path(candidate['file']).read_bytes() == body.encode('utf-8')
        and _native(candidate) == _native(wanted)
        and candidate.get('nvim_ue_members') == members
        and len(keys) == len(set(keys)) and len(members) == len(set(members))), expected


def _tier2_include_tool(clangd):
    suffix = '.exe' if os.name == 'nt' else ''
    sibling = Path(clangd).parent / ('clang++' + suffix)
    resolved = str(sibling) if sibling.is_file() else shutil.which('clang++') or shutil.which('clang')
    if not resolved:
        raise ValueError('tier2-include-compiler-unavailable')
    path = Path(resolved).resolve()
    return path, _sha(path.read_bytes())


_TIER2_GATES = ('include_resolution_equal', 'compile_success', 'main_shards_complete', 'members_equal')


def _tier2_reusable_rejection(receipt):
    include = receipt.get('include_result')
    return (isinstance(include, dict) and include.get('ok') is False
        and include.get('reason') == 'dependency-set-mismatch'
        or _tier1_compile_rejection(receipt.get('compile_result')))


def _tier2_cached(output, identity, candidate, body):
    """Read successful or conclusive negative live receipts without writes."""
    try:
        key = _sha(_json(identity).encode())
        index = json.loads((output / 'receipts' / (key + '.json')).read_bytes())
        if (index.get('schema') != 1 or index.get('tier') != 2
                or index.get('cache_key') != key or type(index.get('accepted')) is not bool):
            raise ValueError('tier2-cache-index-invalid')
        path = Path(index['receipt'])
        if path.resolve().parent != (output / 'receipts').resolve():
            raise ValueError('tier2-cache-receipt-outside-store')
        raw = path.read_bytes()
        receipt, digest = json.loads(raw), _sha(raw)
        if (digest != index.get('receipt_sha256') or receipt.get('schema') != 1
                or receipt.get('tier') != 2 or receipt.get('cache_key') != key
                or receipt.get('accepted') is not index['accepted'] or receipt.get('reusable') is not True
                or any(receipt.get(name) != value for name, value in identity.items())
                or receipt.get('candidate_sha256') != _sha(body.encode('utf-8'))
                or receipt.get('members') != candidate['nvim_ue_members']
                or not isinstance(receipt.get('reason'), str) or not receipt['reason']
                or not isinstance(receipt.get('gates'), dict)
                or (receipt['accepted'] and not all(
                    receipt['gates'].get(name) is True for name in _TIER2_GATES))
                or (not receipt['accepted'] and not _tier2_reusable_rejection(receipt))):
            raise ValueError('tier2-cache-receipt-identity-mismatch')
        if Path(candidate['file']).read_bytes() != body.encode('utf-8'):
            raise ValueError('tier2-cache-candidate-changed')
        return {'receipt': str(path), 'receipt_sha256': digest,
                'accepted': receipt['accepted'], 'reason': receipt['reason'], 'gates': receipt['gates']}, None
    except (OSError, ValueError, KeyError, TypeError, AttributeError) as error:
        return None, str(error)


def _tier2_write_receipt(output, receipt, record):
    raw = _json(receipt)
    digest = _sha(raw.encode())
    path = output / 'receipts' / ('receipt.' + digest[:24] + '.json')
    _write(path, raw)
    if _sha(path.read_bytes()) != digest:
        raise ValueError('tier2-receipt-changed-during-publication')
    record['receipt'] = str(path)
    if receipt.get('cache_key'):
        _write(output / 'receipts' / (receipt['cache_key'] + '.json'), _json({
            'schema': 1, 'tier': 2, 'cache_key': receipt['cache_key'],
            'accepted': receipt['accepted'], 'receipt': str(path), 'receipt_sha256': digest}))
    return path, digest


@tier1_overlay_scope()
def _accelerate_tier2(entries, output_dir, clangd_path, max_group=8, timeout=90,
                      budget_factor=None, server_profile=None, reuse_only=False):
    """Qualify cross-module chunks first, then qualify all residual Tier 1 chunks.

    Every rejected Tier 2 owner remains in the residual input, including include
    resolution failures. Neither route grants strict frozen publication rights.
    """
    started = time.monotonic()
    output = Path(output_dir).resolve() / 'tier2'
    diagnostics = []
    packing = tier2_grouping_options(max_unities=max_group, budget_factor=budget_factor)
    chunks = tier2_unity_chunks(entries, **packing, diagnostics=diagnostics)
    records, replacements, consumed = [], {}, set()
    resolved = shutil.which(str(clangd_path)) if clangd_path else None
    executable = Path(resolved or clangd_path or '')
    try:
        profile = normalize_server_profile(server_profile)
        environment = _compiler_environment(profile)
        tool_hash = _tier1_blob_sha('tool', executable.read_bytes()) if executable.is_file() else None
        if not tool_hash:
            raise ValueError('clangd-unavailable')
        include_tool, include_hash = _tier2_include_tool(executable)
        setup_error = None
    except (OSError, ValueError) as error:
        profile, environment, tool_hash = None, None, None
        include_tool, include_hash, setup_error = None, None, str(error)
    invocation = None
    for chunk in chunks:
        group = [entries[index] for index in chunk]
        gates = dict.fromkeys(_TIER2_GATES, False)
        record = {'tier': 2, 'original_indexes': chunk, 'original_ubt_count': len(chunk),
            'accepted': False, 'gates': gates, 'run_metrics': [], 'cached': False, 'deferred': False}
        candidate, body, identity, cached, result, key = None, None, None, None, None, None
        include_result = None
        group_started = time.monotonic()
        try:
            if setup_error:
                raise ValueError(setup_error)
            inputs = _tier2_inputs(group)
            candidate, body = _tier2_candidate(group, output / 'assets')
            identity = {'original_entries': [_native(entry) for entry in group],
                'candidate': _native(candidate), 'candidate_sha256': _sha(body.encode('utf-8')),
                'inputs': inputs, 'tool_sha256': tool_hash, 'include_tool': str(include_tool),
                'include_tool_sha256': include_hash, 'server_profile': profile,
                'compiler_environment': environment}
            key = _sha(_json(identity).encode())
            record['cache_key'] = key
            cached, record['cache_reason'] = _tier2_cached(output, identity, candidate, body)
            if cached:
                record.update(accepted=cached['accepted'], reason=cached['reason'], cached=True,
                    gates=dict(cached['gates']), receipt=cached['receipt'])
            elif reuse_only:
                record.update(reason='verification-not-cached', deferred=True)
            else:
                if invocation is None:
                    work = _proof_work_root(output)
                    work.mkdir(parents=True, exist_ok=True)
                    invocation = Path(tempfile.mkdtemp(prefix='tier2-', dir=work))
                group_work = invocation / ('group-' + str(chunk[0]))
                # A conclusive include rejection also binds an actual asset;
                # reuse validates its complete bytes without recreating it.
                _write(candidate['file'], body)
                include_result = tier2_include_gate(group, group_work / 'includes',
                    str(include_tool), timeout=min(timeout, 10))
                record['include_gate'] = include_result
                gates['include_resolution_equal'] = include_result.get('ok') is True
                if not gates['include_resolution_equal']:
                    raise ValueError('tier2-include-resolution-mismatch: ' + str(include_result.get('reason')))
                gates['members_equal'], expected = _tier2_members_match(group, candidate, body)
                if not gates['members_equal']:
                    raise ValueError('tier2-membership-mismatch')
                result = _tier1_candidate_index(candidate, group_work / 'index',
                    str(executable.resolve()), timeout, server_profile=profile)
                record['run_metrics'] = [{name: result.get(name) for name in _RUN_METRIC_FIELDS}]
                gates['compile_success'] = result.get('background_compile_success') is True
                if not gates['compile_success']:
                    raise ValueError('tier2-candidate-index-failed')
                observed = {_command_key(path) for path in result.get('member_main_shards', [])}
                record['missing_member_main_shards'] = [path for path in expected if _command_key(path) not in observed]
                gates['main_shards_complete'] = (result.get('missing_main_shards') in ([], 0)
                    and not record['missing_member_main_shards'])
                if not gates['main_shards_complete']:
                    raise ValueError('tier2-main-shards-missing')
                gates['members_equal'], _ = _tier2_members_match(group, candidate, body)
                if not gates['members_equal']:
                    raise ValueError('tier2-membership-mismatch')
                if _tier2_inputs(group) != inputs:
                    raise ValueError('tier2-inputs-changed-during-index')
                if (_compiler_environment(profile) != environment
                        or _sha(executable.read_bytes()) != tool_hash
                        or _sha(include_tool.read_bytes()) != include_hash):
                    raise ValueError('tier2-tool-or-environment-changed')
                record.update(accepted=True, reason='tier2-includes-compile-shards-members-accepted')
        except (OSError, UnicodeError, ValueError, KeyError, TypeError, subprocess.TimeoutExpired) as error:
            record.update(reason=str(error), deferred=reuse_only)
        try:
            if cached:
                receipt_path, digest = Path(cached['receipt']), cached['receipt_sha256']
            elif not reuse_only:
                receipt = dict(identity or {}, schema=1, tier=2, cache_key=key,
                    accepted=record['accepted'], reusable=record['accepted'], reason=record['reason'],
                    gates=dict(gates), members=candidate.get('nvim_ue_members', []) if candidate else [],
                    include_result={name: include_result.get(name) for name in
                        ('ok', 'reason', 'only_tier1', 'only_tier2')} if include_result is not None else None,
                    compile_result={name: result.get(name) for name in
                        ('indexing_complete', 'exit_code', 'compile_failure_count', 'shard_had_errors')}
                        if result is not None else None)
                receipt['reusable'] = record['accepted'] or _tier2_reusable_rejection(receipt)
                receipt_path, digest = _tier2_write_receipt(output, receipt, record)
        except (OSError, ValueError, KeyError, TypeError) as error:
            record.update(accepted=False, reason='tier2-receipt-unavailable: ' + str(error))
        if record['accepted']:
            candidate.update(nvim_ue_tier1_receipt=str(receipt_path), nvim_ue_tier1_receipt_sha256=digest)
            replacements[min(chunk)] = dict(sorted(candidate.items()))
            consumed.update(chunk)
        record['proof_seconds'] = round(time.monotonic() - group_started, 6)
        records.append(record)
        print('[tier2-batch] ' + ('admitted' if record['accepted'] else 'retained')
            + ' group=' + str(chunk[0]) + ' ubt=' + str(len(chunk)) + ' reason=' + record['reason'], flush=True)
    residual_indexes = [index for index in range(len(entries)) if index not in consumed]
    residual = [entries[index] for index in residual_indexes]
    fallback, metrics = _accelerate_tier1(residual, output_dir, clangd_path, max_group,
        timeout, packing['budget_factor'], server_profile, reuse_only=reuse_only)
    # Rebase the residual Tier 1 proof records and attach each replacement to its
    # first original owner. This preserves CDB order across both tiers.
    by_receipt = {entry.get('nvim_ue_tier1_receipt'): entry for entry in fallback
                  if entry.get('nvim_ue_tier1_receipt')}
    for record in metrics['groups']:
        local_indexes = record['original_indexes']
        record['original_indexes'] = [residual_indexes[index] for index in local_indexes]
        if record.get('fallback_chunks'):
            record['fallback_chunks'] = [[residual_indexes[index] for index in child]
                                         for child in record['fallback_chunks']]
        if record['accepted']:
            candidate = by_receipt[record['receipt']]
            replacements[min(record['original_indexes'])] = candidate
            consumed.update(record['original_indexes'])
    for detail in metrics.get('chunk_diagnostics', []):
        if isinstance(detail.get('entry_index'), int):
            detail['entry_index'] = residual_indexes[detail['entry_index']]
    background = [replacements.get(index, entry) for index, entry in enumerate(entries)
                  if index not in consumed or index in replacements]
    records.extend(metrics['groups'])
    expected, actual = _tier1_source_coverage(entries), _tier1_source_coverage(background)
    if actual != expected:
        background, replacements = list(entries), {}
        for record in records:
            record.update(accepted=False, reason='tier2-output-coverage-mismatch')
        metrics['invalidated_reason'] = 'tier2-output-coverage-mismatch'
    original_count = sum(_is_ubt(entry) for entry in entries)
    accepted_count = sum(record['original_ubt_count'] for record in records if record['accepted'])
    metrics.update(tier=2, original_ubt_count=original_count, groups=records,
        chunk_diagnostics=diagnostics + metrics.get('chunk_diagnostics', []),
        batch_count=sum(record['accepted'] for record in records), accepted_ubt_count=accepted_count,
        retained_ubt_count=original_count - accepted_count, output_entries=len(background),
        input_member_count=sum(expected.values()), output_member_count=sum(_tier1_source_coverage(background).values()),
        coverage_complete=expected == _tier1_source_coverage(background),
        cache_hits=sum(record['cached'] for record in records),
        new_batch_count=sum(record['accepted'] and not record['cached'] for record in records),
        new_proof_count=sum(not record['cached'] and not record['deferred'] for record in records),
        deferred_group_count=sum(record['deferred'] for record in records),
        proof_accepted_count=sum(record['accepted'] for record in records),
        proof_rejected_count=sum(not record['accepted'] and not record['deferred'] for record in records),
        proof_uncached_count=sum(record['deferred'] for record in records),
        selector_reuse_status='accepted' if replacements else 'zero-hit',
        receipt_reuse=any(record['cached'] for record in records),
        proof_directory=str(invocation) if invocation else metrics.get('proof_directory'),
        proof_seconds=round(time.monotonic() - started, 6))
    return background, metrics


def accelerate_tier2(entries, output_dir, clangd_path, max_group=8, timeout=90,
                     budget_factor=None, server_profile=None):
    return _accelerate_tier2(entries, output_dir, clangd_path, max_group, timeout,
        budget_factor, server_profile)


def reuse_tier2(entries, output_dir, clangd_path, max_group=8, timeout=90,
                budget_factor=None, server_profile=None):
    return _accelerate_tier2(entries, output_dir, clangd_path, max_group, timeout,
        budget_factor, server_profile, reuse_only=True)


def accelerate_tier1(entries, output_dir, clangd_path, max_group=8, timeout=90,
                     budget_factor=None, server_profile=None, *, recipe=None):
    if tier2_enabled() and recipe is None:
        return accelerate_tier2(entries, output_dir, clangd_path, max_group, timeout,
            budget_factor, server_profile)
    return _accelerate_tier1(entries, output_dir, clangd_path, max_group, timeout,
        budget_factor, server_profile, **({'recipe': recipe} if recipe is not None else {}))


def reuse_tier1(entries, output_dir, clangd_path, max_group=8, timeout=90,
                budget_factor=None, server_profile=None, *, recipe=None):
    """Reuse current Tier 1 successes/rejections without any filesystem writes."""
    if tier2_enabled() and recipe is None:
        return reuse_tier2(entries, output_dir, clangd_path, max_group, timeout,
            budget_factor, server_profile)
    return _accelerate_tier1(entries, output_dir, clangd_path, max_group, timeout,
        budget_factor, server_profile, reuse_only=True, **({'recipe': recipe} if recipe is not None else {}))


@contextmanager
def _cohort_writer(generation):
    lock = generation / 'writer.lock'
    try:
        lock.mkdir()
    except FileExistsError as error:
        raise ValueError('cohort-writer-busy') from error
    try:
        _write(lock / 'owner.json', _json({'pid': os.getpid()}))
        yield
    finally:
        (lock / 'owner.json').unlink(missing_ok=True)
        lock.rmdir()


def _cohort_specs(entries, group_specs, generation):
    if (not isinstance(entries, list) or not entries or not all(isinstance(entry, dict) and _is_ubt(entry) for entry in entries)
            or not isinstance(group_specs, list) or len(group_specs) != 2):
        raise ValueError('cohort-requires-exactly-two-complete-ubt-groups')
    claimed, stores, specs = set(), set(), []
    for spec in group_specs:
        indexes = spec.get('indexes') if isinstance(spec, dict) else None
        if (not isinstance(indexes, list) or len(indexes) < 2
                or any(type(index) is not int or not 0 <= index < len(entries) for index in indexes)
                or indexes != list(range(indexes[0], indexes[-1] + 1)) or claimed.intersection(indexes)):
            raise ValueError('cohort-invalid-original-indexes')
        selected = [entries[index] for index in indexes]
        packing = spec.get('packing', {'max_unities': 8, 'budget_factor': 8})
        if (not isinstance(packing, dict) or set(packing) != {'max_unities', 'budget_factor'}
                or any(type(value) is not int or not 1 <= value <= 32 for value in packing.values())
                or secondary_unity_chunks(selected, **tier1_grouping_options(**packing)) != [list(range(len(selected)))]):
            raise ValueError('cohort-invalid-tier1-packing')
        identity = _sha(json.dumps({'tier': 1, 'entries': selected}, ensure_ascii=False,
            separators=(',', ':')).encode('utf-8'))
        store = Path(spec['store']).resolve()
        if (spec.get('id') != identity or store.name != identity or store.parent.name != 'tier1'
                or store.parent.parent.name != 'background-proofs' or str(store) in stores
                or not store.is_relative_to(generation)):
            raise ValueError('cohort-invalid-canonical-store')
        specs.append(dict(spec, indexes=list(indexes), store=str(store), packing=dict(packing)))
        stores.add(str(store))
        claimed.update(indexes)
    if claimed != set(range(len(entries))):
        raise ValueError('cohort-scope-not-completely-covered')
    return sorted(specs, key=lambda spec: spec['indexes'][0])


def _cohort_run_clean(result):
    observers = result.get('observers', {})
    progress = result.get('background_progress', {})
    counts = [progress.get(key) for key in ('begins', 'ends', 'pairs')]
    return (result.get('background_compile_success') is True and result.get('indexing_complete') is True
        and result.get('initialized') is True and result.get('shutdown_response') is True
        and result.get('exit_code') == 0 and result.get('compile_failure_count') == 0
        and result.get('missing_main_shards') == [] and result.get('shutdown_clean') is True
        and result.get('process_reaped') is True and progress.get('complete') is True
        and progress.get('token') == 'backgroundIndexProgress' and progress.get('open') == 0
        and progress.get('errors') == [] and all(type(count) is int and count > 0 for count in counts)
        and len(set(counts)) == 1
        and observers.get('joined') is True and observers.get('errors') == []
        and observers.get('eof') == {'stdout': True, 'stderr': True})


def _cohort_driver_identity(command):
    # This first handoff scope deliberately does not simulate PATH resolution.
    # Ordinary qualification still accepts commands outside this cache scope.
    driver = Path(command['arguments'][0])
    if not driver.is_absolute():
        raise ValueError('cohort-handoff-absolute-driver-required')
    if os.name == 'nt' and not driver.is_file() and driver.suffix.lower() != '.exe':
        driver = Path(str(driver) + '.exe')
    return {'spelling': command['arguments'][0], 'path': str(driver),
        'realpath': str(driver.resolve(strict=True)), 'sha256': _sha(driver.read_bytes())}


_COHORT_LOADER_POLICY = 'cdb-mains-all-sources-all-own-v1'
_COHORT_INVENTORY_FIELDS = ('path', 'sha256', 'size', 'own_uri', 'own_digest', 'flags')


def _cohort_source_key(uri):
    if not isinstance(uri, str):
        raise ValueError('cohort-handoff-invalid-source-uri')
    parsed = urlparse(uri)
    if (parsed.scheme != 'file' or parsed.netloc or parsed.params or parsed.query or parsed.fragment
            or not _uri_path(uri).is_absolute()):
        raise ValueError('cohort-handoff-invalid-source-uri')
    return _command_key(_uri_path(uri))


def _cohort_loader_reachability(native, shards, diagnostics):
    """Replay the loader's complete Sources edges, rooted only in the actual CDB."""
    if not isinstance(native, list) or not native or not isinstance(shards, list) or not shards:
        raise ValueError('cohort-handoff-invalid-loader-evidence')
    roots = [_command_key(row['file']) for row in native]
    if len(set(roots)) != len(roots):
        raise ValueError('cohort-handoff-duplicate-main')
    edges = {}
    diagnostics.update(policy=_COHORT_LOADER_POLICY, root_count=len(roots), own_count=len(shards))
    for item in shards:
        if not isinstance(item, dict) or not isinstance(item.get('sources'), list) or not item['sources']:
            raise ValueError('cohort-handoff-invalid-loader-evidence')
        own = _cohort_source_key(item.get('own_uri'))
        sources = {_cohort_source_key(uri) for uri in item['sources']}
        if own in edges or own not in sources:
            raise ValueError('cohort-handoff-invalid-loader-evidence')
        edges[own] = sources - {own}
    missing = sorted(set(roots) - edges.keys())
    diagnostics['missing_mains'] = missing
    if missing:
        raise ValueError('cohort-handoff-main-own-missing')
    missing = sorted({child for values in edges.values() for child in values} - edges.keys())
    diagnostics.update(edge_count=sum(map(len, edges.values())), missing_dependencies=missing)
    if missing:
        raise ValueError('cohort-handoff-missing-dependency-own')
    pending, reached = list(roots), set()
    while pending:
        current = pending.pop()
        if current not in reached:
            reached.add(current)
            pending.extend(edges[current] - reached)
    diagnostics.update(reachable_count=len(reached), unreachable=sorted(edges.keys() - reached))
    if diagnostics['unreachable']:
        raise ValueError('cohort-handoff-unreachable-shards')


@tier1_overlay_scope()
def qualify_tier1_cohort(entries, group_specs, generation_dir, clangd_path, *, timeout,
                        server_profile=None, position_encoding='utf-8', input_seal=None):
    """Qualify two complete scoped candidates through one real, all-clean run.

    This private entrypoint does not publish a live selection. Its optional
    cache handoff additionally needs a caller's actual pre-run input seal.
    """
    started = time.monotonic()
    generation = Path(generation_dir).resolve()
    specs = _cohort_specs(entries, group_specs, generation)
    if generation.exists():
        raise ValueError('cohort-generation-not-fresh')
    if position_encoding not in ('utf-8', 'utf-16', 'utf-32'):
        raise ValueError('unsupported-position-encoding')
    profile = normalize_server_profile(server_profile)
    executable = Path(shutil.which(str(clangd_path)) or clangd_path).resolve()
    tool_hash = _sha(executable.read_bytes())
    environment = _compiler_environment(profile)
    handoff_environment = _compiler_environment(None)
    records = [{'tier': 1, 'id': spec['id'], 'original_indexes': spec['indexes'],
        'original_ubt_count': len(spec['indexes']), 'accepted': False, 'cached': False,
        'deferred': False, 'run_metrics': [], 'gates': {'compile_success': False,
        'main_shards_complete': False, 'members_equal': False}} for spec in specs]
    metrics = {'tier': 1, 'groups': records, 'cohort_run': None, 'cohort_evidence': None,
        'partial_commits': [], 'batch_count': 0, 'accepted_ubt_count': 0, 'output_entries': len(entries),
        'original_ubt_count': len(entries), 'exact_count': 0, 'shader_count': 0, 'other_count': 0,
        'coverage_complete': True, 'handoff': {'ready': False, 'manifest': None, 'reason': 'cohort-not-qualified'}}
    generation.mkdir(parents=True)
    with _cohort_writer(generation):
        prepared = []
        try:
            for spec, record in zip(specs, records):
                group = [entries[index] for index in spec['indexes']]
                output = Path(spec['store']) / 'tier1'
                inputs = _tier1_inputs(group)
                candidate, body = _tier1_candidate_spec(group, output / 'assets')
                key = _tier1_cache_key(group, candidate, tool_hash, profile, environment)
                _write(candidate['file'], body)
                members_equal, members = _tier1_members_match(group, candidate)
                if not members_equal:
                    raise ValueError('tier1-membership-mismatch')
                prepared.append((spec, group, output, inputs, candidate, body, key, members))
            trigger = generation / 'trigger.cpp'
            trigger_raw = b'// Private Tier 1 cohort trigger.\n'
            _write(trigger, trigger_raw)
            native = [_private_command(row[4]) for row in prepared] + [{'directory': str(generation),
                'file': str(trigger), 'arguments': [prepared[0][4]['arguments'][0], '-x', 'c++', '-c', str(trigger)]}]
            drivers, driver_error = {}, None
            try:
                drivers = {_command_key(entry['file']): _cohort_driver_identity(entry) for entry in native}
            except (OSError, ValueError, KeyError, TypeError) as error:
                driver_error = str(error)
            cdb_raw = _json(native).encode('utf-8')
            _write(generation / 'compile_commands.json', cdb_raw)
            cache_environment = generation / 'environment'
            result = run(generation, generation / 'producer', trigger, str(executable), timeout=timeout,
                jobs=1, server_profile=profile, position_encoding=position_encoding,
                cache_environment=cache_environment, require_main_evidence=True)
            metrics['cohort_run'] = result
            expected_environment = {'LOCALAPPDATA': str(cache_environment),
                'XDG_CACHE_HOME': str(cache_environment / 'cache'), 'TEMP': str(cache_environment), 'TMP': str(cache_environment)}
            if (not _cohort_run_clean(result) or result.get('cdb_sha256') != _sha(cdb_raw)
                    or result.get('server_profile') != profile or result.get('root_uri') != generation.as_uri()
                    or result.get('cdb_dir') != str(generation) or result.get('isolated_environment') != expected_environment
                    or result.get('launch_cwd') != (profile['launch_cwd'] if profile else generation.as_posix())
                    or not result.get('command') or _command_key(result['command'][0]) != _command_key(executable)
                    or '--compile-commands-dir=' + str(generation) not in result['command']):
                raise ValueError('cohort-run-incomplete')
            loaded = result.get('loaded_cdb_events', [])
            if (len(loaded) != 1 or _command_key(loaded[0]['path'])
                    != _command_key(generation / 'compile_commands.json')):
                raise ValueError('cohort-loaded-cdb-unproven')
            expected = {_command_key(entry['file']): entry for entry in native}
            events = collections.Counter(_command_key(event['path']) for event in result.get('main_events', []))
            if not all(events[key] == 1 for key in expected):
                raise ValueError('cohort-main-execution-unproven')
            own, mains, inventory, topology = {}, {}, [], []
            paths = result.get('shards', [])
            if not paths or len(set(paths)) != len(paths):
                raise ValueError('cohort-invalid-shard-inventory')
            decode_started = time.monotonic()
            for value in paths:
                path = Path(value).resolve()
                if not path.is_relative_to(generation) or path.is_symlink():
                    raise ValueError('cohort-shard-outside-generation')
                raw = path.read_bytes()
                shard = decode_shard(raw)
                nodes = [(uri, node) for uri, node in shard['sources'].items()
                    if node['digest'] != '0000000000000000']
                if len(nodes) != 1:
                    raise ValueError('tier1-invalid-own-shard: ' + str(path))
                uri, node = nodes[0]
                if node['flags'] & 2:
                    raise ValueError('cohort-shard-had-errors')
                key = _command_key(_uri_path(uri))
                if key in own:
                    raise ValueError('cohort-duplicate-own-uri')
                own[key] = (uri, node)
                inventory.append({'path': str(path), 'sha256': _sha(raw), 'size': len(raw),
                    'own_uri': uri, 'own_digest': node['digest'], 'flags': node['flags']})
                topology.append(dict(inventory[-1], sources=list(shard['sources'])))
                if key in expected:
                    command = shard.get('command')
                    if (not node['flags'] & 1 or not isinstance(command, dict)
                            or not isinstance(command.get('arguments'), list) or not command['arguments']
                            or _command_key(command.get('directory', '')) != _command_key(expected[key]['directory'])
                            or not any(not argument.startswith('-') and _command_key(
                                Path(command['directory']) / argument) == key for argument in command['arguments'][1:])):
                        raise ValueError('cohort-main-command-unproven')
                    # Same ordered preservation rule as _verify_effective_query.
                    # Native additions are attributed by the sole loaded CDB,
                    # disabled config, fresh cache and this exact main witness.
                    remaining = iter(command['arguments'][1:])
                    for argument in expected[key]['arguments'][1:]:
                        if argument == '--' or (not argument.startswith('-') and _command_key(
                                Path(command['directory']) / argument) == key):
                            continue
                        if not any(value == argument for value in remaining):
                            raise ValueError('cohort-main-original-arguments-changed')
                    mains[key] = {'uri': uri, 'shard': str(path), 'command': command,
                        'cdb_entry': expected[key], 'indexed_events': events[key]}
            metrics['manifest_decode_seconds'] = time.monotonic() - decode_started
            if set(mains) != set(expected):
                raise ValueError('cohort-main-shards-missing')
            for row, record in zip(prepared, records):
                spec, group, output, inputs, candidate, body, key, members = row
                record['gates']['compile_success'] = True
                record['gates']['main_shards_complete'] = all(_command_key(member) in own for member in members)
                if not record['gates']['main_shards_complete']:
                    raise ValueError('tier1-main-shards-missing')
                _tier1_postcheck(group, candidate, inputs, environment, profile, record['gates'])
                record['main_evidence_key'] = _command_key(candidate['file'])
            if ((generation / 'compile_commands.json').read_bytes() != cdb_raw
                    or _sha(executable.read_bytes()) != tool_hash):
                raise ValueError('cohort-identity-changed-during-index')
            result['shard_had_errors'] = False
            evidence = {'schema': 'tier1-cohort-evidence-v2', 'cdb_sha256': _sha(cdb_raw),
                'loader_policy': _COHORT_LOADER_POLICY, 'run': result, 'mains': mains, 'shards': topology}
            evidence_path = generation / 'cohort-evidence.json'
            evidence_raw = _json(evidence).encode('utf-8')
            _write(evidence_path, evidence_raw)
            evidence_digest = _sha(evidence_raw)
            metrics['cohort_evidence'] = str(evidence_path)
            for row, record in zip(prepared, records):
                spec, group, output, inputs, candidate, body, key, members = row
                commit = {'id': spec['id'], 'committed': False}
                try:
                    receipt = {'schema': 1, 'tier': 1, 'reusable': True, 'cache_key': key,
                        'accepted': True, 'reason': 'tier1-compile-shards-members-accepted',
                        'gates': dict(record['gates']), 'inputs': inputs,
                        'compile_result': {name: result.get(name) for name in
                            ('indexing_complete', 'exit_code', 'compile_failure_count', 'shard_had_errors')},
                        'original_entries': [_native(entry) for entry in group], 'candidate': _native(candidate),
                        'candidate_sha256': _sha(body.encode('utf-8')), 'members': candidate['nvim_ue_members'],
                        'tool_sha256': tool_hash, 'server_profile': profile, 'compiler_environment': environment,
                        'qualification': {'kind': 'cohort', 'evidence_sha256': evidence_digest,
                            'main_uri': mains[record['main_evidence_key']]['uri']}}
                    receipt_path, receipt_digest = _tier1_write_receipt(output, receipt, record)
                    candidate.update(nvim_ue_tier1_receipt=str(receipt_path), nvim_ue_tier1_receipt_sha256=receipt_digest)
                    commit.update(committed=True, receipt=str(receipt_path), receipt_sha256=receipt_digest)
                except (OSError, ValueError, KeyError, TypeError) as error:
                    commit.update(error=str(error), receipt=record.get('receipt'))
                metrics['partial_commits'].append(commit)
            if not all(commit['committed'] for commit in metrics['partial_commits']):
                raise ValueError('cohort-receipt-commit-incomplete')
            background = [dict(sorted(row[4].items())) for row in prepared]
            if _tier1_source_coverage(background) != _tier1_source_coverage(entries):
                raise ValueError('tier1-output-coverage-mismatch')
            for record in records:
                record.update(accepted=True, reason='tier1-cohort-qualified')
            metrics.update(batch_count=2, accepted_ubt_count=len(entries), output_entries=2)
            try:
                loader_started = time.monotonic()
                try:
                    _cohort_loader_reachability(native, topology, metrics['handoff'].setdefault('loader', {}))
                finally:
                    metrics['handoff']['loader_seconds'] = time.monotonic() - loader_started
                encoding = result.get('position_encoding', {}).get('effective')
                if encoding != position_encoding:
                    raise ValueError('cohort-handoff-encoding-mismatch')
                if _compiler_environment(None) != handoff_environment:
                    raise ValueError('cohort-handoff-environment-changed')
                if driver_error:
                    raise ValueError(driver_error)
                for key, main in mains.items():
                    before = drivers[key]
                    current = _cohort_driver_identity(main['cdb_entry'])
                    actual = _cohort_driver_identity(main['command'])
                    if (current != before or any(actual[name] != before[name] for name in ('realpath', 'sha256'))):
                        raise ValueError('cohort-handoff-driver-changed-or-unproven')
                    drivers[key] = {'input': before, 'effective': actual}
                if not isinstance(input_seal, dict):
                    raise ValueError('cohort-handoff-input-seal-required')
                sealed = {_command_key(path): digest for path, digest in input_seal.items()}
                generated = {_command_key(trigger): _sha(trigger_raw)}
                generated.update((_command_key(row[4]['file']), _sha(row[5].encode('utf-8'))) for row in prepared)
                bound = {item['path']: item['sha256'] for row in prepared for item in row[3]}
                for key, (uri, node) in own.items():
                    path = _uri_path(uri)
                    digest = generated.get(key, sealed.get(key))
                    if not isinstance(digest, str) or _sha(path.read_bytes()) != digest:
                        raise ValueError('cohort-handoff-input-unknown-or-changed: ' + str(path))
                    bound[str(path)] = digest
                manifest = {'schema': 'tier1-cohort-cache-v2', 'generation': str(generation),
                    'loader_policy': _COHORT_LOADER_POLICY,
                    'cdb_dir': str(generation), 'cdb_sha256': _sha(cdb_raw), 'root_uri': generation.as_uri(),
                    'trigger': str(trigger), 'cache_environment': str(cache_environment),
                    'position_encoding': position_encoding, 'tool': str(executable), 'tool_sha256': tool_hash,
                    'server_profile': profile, 'compiler_environment': environment, 'mains': mains,
                    'handoff_environment': handoff_environment, 'drivers': drivers,
                    'evidence': {'path': str(evidence_path), 'sha256': evidence_digest},
                    'receipts': metrics['partial_commits'], 'inputs': bound, 'shards': inventory}
                manifest_path = generation / 'cohort-cache.json'
                _write(manifest_path, _json(manifest))
                metrics['handoff'].update(ready=True, manifest=str(manifest_path), reason='same-store-ready')
            except (OSError, ValueError, KeyError, TypeError) as error:
                metrics['handoff']['reason'] = str(error)
            metrics['proof_seconds'] = time.monotonic() - started
            return background, metrics
        except (OSError, ValueError, KeyError, TypeError, subprocess.TimeoutExpired) as error:
            for record in records:
                record.update(accepted=False, reason=str(error))
            metrics['handoff']['reason'] = str(error)
            metrics['proof_seconds'] = time.monotonic() - started
            return list(entries), metrics


@contextmanager
def tier1_cohort_reader_scope(generation_dir, clangd_path, *, server_profile=None, position_encoding='utf-8'):
    """Claim one private same-store reader; the caller reaps it before exit.

    This is an experimental caller-owned lifecycle, not a live-editor hook.
    Reader writes can invalidate the original manifest without revoking receipts.
    """
    generation = Path(generation_dir).resolve()
    with _cohort_writer(generation):
        manifest = json.loads((generation / 'cohort-cache.json').read_text(encoding='utf-8'))
        cdb_raw = (generation / 'compile_commands.json').read_bytes()
        executable = Path(shutil.which(str(clangd_path)) or clangd_path).resolve()
        profile = normalize_server_profile(server_profile)
        if (manifest.get('schema') != 'tier1-cohort-cache-v2' or manifest.get('generation') != str(generation)
                or manifest.get('loader_policy') != _COHORT_LOADER_POLICY
                or manifest.get('cdb_dir') != str(generation) or manifest.get('root_uri') != generation.as_uri()
                or manifest.get('cache_environment') != str(generation / 'environment')
                or manifest.get('position_encoding') != position_encoding or manifest.get('server_profile') != profile
                or manifest.get('compiler_environment') != _compiler_environment(profile)
                or manifest.get('handoff_environment') != _compiler_environment(None)
                or manifest.get('tool') != str(executable) or _sha(executable.read_bytes()) != manifest.get('tool_sha256')
                or _sha(cdb_raw) != manifest.get('cdb_sha256')):
            raise ValueError('cohort-handoff-identity-changed')
        native = json.loads(cdb_raw)
        evidence_raw = Path(manifest['evidence']['path']).read_bytes()
        if _sha(evidence_raw) != manifest['evidence']['sha256']:
            raise ValueError('cohort-handoff-evidence-changed')
        evidence = json.loads(evidence_raw)
        if (evidence.get('schema') != 'tier1-cohort-evidence-v2'
                or evidence.get('loader_policy') != _COHORT_LOADER_POLICY
                or evidence.get('cdb_sha256') != manifest['cdb_sha256']
                or evidence.get('mains') != manifest['mains']
                or not isinstance(evidence.get('shards'), list)
                or [{name: item[name] for name in _COHORT_INVENTORY_FIELDS} for item in evidence['shards']]
                    != manifest['shards']):
            raise ValueError('cohort-handoff-evidence-mismatch')
        if (not isinstance(native, list) or len(native) != 3
                or len({_command_key(row['file']) for row in native}) != len(native)
                or {_command_key(row['file']) for row in native} != set(manifest['mains'])
                or _command_key(manifest['trigger']) != _command_key(generation / 'trigger.cpp')):
            raise ValueError('cohort-handoff-main-evidence-mismatch')
        by_own = {_cohort_source_key(item['own_uri']): item for item in evidence['shards']}
        for entry in native:
            key = _command_key(entry['file'])
            main = manifest['mains'][key]
            if (main['cdb_entry'] != entry or _cohort_source_key(main['uri']) != key
                    or key not in by_own or main['uri'] != by_own[key]['own_uri']
                    or main['shard'] != by_own[key]['path'] or not by_own[key]['flags'] & 1):
                raise ValueError('cohort-handoff-main-evidence-mismatch')
        _cohort_loader_reachability(native, evidence['shards'], {})
        receipt_mains, receipt_paths = set(), set()
        if len(manifest['receipts']) != 2:
            raise ValueError('cohort-handoff-receipt-evidence-mismatch')
        for item in manifest['receipts']:
            path = Path(item['receipt']).resolve()
            if not path.is_relative_to(generation) or str(path) in receipt_paths or item.get('committed') is not True:
                raise ValueError('cohort-handoff-receipt-evidence-mismatch')
            raw = path.read_bytes()
            if _sha(raw) != item['receipt_sha256']:
                raise ValueError('cohort-handoff-evidence-changed')
            receipt = json.loads(raw)
            qualification = receipt.get('qualification', {})
            key = _cohort_source_key(qualification.get('main_uri'))
            if (receipt.get('schema') != 1 or receipt.get('tier') != 1 or receipt.get('accepted') is not True
                    or qualification != {'kind': 'cohort', 'evidence_sha256': manifest['evidence']['sha256'],
                        'main_uri': manifest['mains'].get(key, {}).get('uri')}
                    or key in receipt_mains or key not in manifest['mains']
                    or _private_command(receipt['candidate']) != manifest['mains'][key]['cdb_entry']):
                raise ValueError('cohort-handoff-receipt-evidence-mismatch')
            receipt_paths.add(str(path))
            receipt_mains.add(key)
        if receipt_mains != set(manifest['mains']) - {_command_key(manifest['trigger'])}:
            raise ValueError('cohort-handoff-receipt-evidence-mismatch')
        for key, main in manifest['mains'].items():
            current = {'input': _cohort_driver_identity(main['cdb_entry']),
                'effective': _cohort_driver_identity(main['command'])}
            if current != manifest['drivers'][key]:
                raise ValueError('cohort-handoff-driver-changed')
        for path, digest in manifest['inputs'].items():
            if _sha(Path(path).read_bytes()) != digest:
                raise ValueError('cohort-handoff-input-changed')
        expected = set()
        for item in manifest['shards']:
            path = Path(item['path']).resolve()
            if not path.is_relative_to(generation) or path.is_symlink() or str(path) in expected:
                raise ValueError('cohort-handoff-invalid-shard-path')
            raw = path.read_bytes()
            if len(raw) != item['size'] or _sha(raw) != item['sha256']:
                raise ValueError('cohort-handoff-shard-changed')
            expected.add(str(path))
        if {str(path.resolve()) for path in generation.rglob('*.idx')} != expected:
            raise ValueError('cohort-handoff-shard-inventory-changed')
        yield {key: manifest[key] for key in ('cdb_dir', 'root_uri', 'trigger', 'cache_environment',
            'position_encoding', 'server_profile')} | {'manifest': manifest}


def accelerate(entries, output_dir, clangd_path, max_group=8, timeout=90, verify_missing=True, server_profile=None,
               max_sources=80, max_new_groups=None, group_indexes=None, strict_recipe=None):
    """Return (background_entries, metrics); rejected groups keep exact originals.

    output_dir must be a private proof/artifact directory, never a live clangd
    cache. Cache misses start independent original-TU caches; hits revalidate
    original bytes, snapshot assets and complete include-directory inventories.
    With verify_missing=False, misses retain originals without compiler work or
    graph replay; only receipts with the complete current identity are reused.
    Compact accepted hints discover noncontiguous groups; max_group remains a
    hard limit and every discovered group goes through the full cache gate.
    A bounded prepare qualifies at most max_new_groups cache misses and stops
    qualifying once it accepts a new batch in this invocation. Cached batches
    do not consume that stage; later prepares can qualify the next group.
    Fully cached prepares validate without changing their publication.
    group_indexes requests exactly one ordered original group without planner,
    hint discovery or rejection bisection; all strict proof/cache gates still run.
    """
    if max_new_groups is not None and (type(max_new_groups) is not int or max_new_groups < 0):
        raise ValueError('batch-proof-limit-must-be-nonnegative')
    if max_new_groups is not None and not verify_missing:
        raise ValueError('batch-proof-limit-requires-qualification')
    started = time.monotonic()
    _OWNED_OVERLAY_MEMO.clear()
    ordered_recipe = None
    if strict_recipe is not None:
        import cdb_ordered_batch
        ordered_recipe = cdb_ordered_batch.descriptor(strict_recipe)
        if group_indexes is None:
            raise ValueError('ordered-recipe-explicit-group-required')
    if group_indexes is not None:
        if ordered_recipe is None:
            group_indexes = _explicit_group_indexes(entries, group_indexes, max_group, max_sources)
        else:
            group_indexes, _ = cdb_ordered_batch.validate_group(entries, group_indexes,
                max_group, max_sources, sys.modules[__name__])
    output = Path(output_dir).resolve()
    _QUERY_RESOLUTION_MEMO.clear()
    output.mkdir(parents=True, exist_ok=True)
    # Revalidation must be read-only in a watched proof store. Even creating
    # an empty observation directory revokes the live frozen reader via the
    # store's protected ancestor watch. Retain a directory only for real work.
    invocation = None
    groups = collections.defaultdict(list)
    metrics = {'original_ubt_count': sum(_is_ubt(entry) for entry in entries),
        'batch_count': 0, 'accepted_ubt_count': 0, 'groups': [], 'proof_directory': None,
        'cache_hits': 0, 'deferred_group_count': 0, 'new_proof_count': 0, 'new_batch_count': 0,
        'qualification_limit': max_new_groups}
    shader = lambda e: Path(e.get('file', '')).suffix.lower() in (
        '.usf', '.ush', '.hlsl', '.hlsli', '.glsl', '.vert', '.frag', '.geom', '.tesc', '.tese', '.comp', '.metal')
    exact = lambda e: not _is_ubt(e) and Path(e.get('file', '')).suffix.lower() in ('.c', '.cc', '.cpp', '.cxx', '.c++')
    metrics['shader_count'] = sum(shader(entry) for entry in entries)
    metrics['exact_count'] = sum(exact(entry) for entry in entries)
    metrics['other_count'] = sum(not _is_ubt(entry) and not shader(entry) and not exact(entry) for entry in entries)
    for index, entry in enumerate(entries):
        if _is_ubt(entry):
            groups[(entry['nvim_ue_module_root'], compile_context_key(entry))].append(index)
    replacements, consumed, claimed, new_hints, admitted_queries = {}, set(), set(), [], []
    resolved = shutil.which(str(clangd_path)) if clangd_path else None
    executable = Path(resolved or clangd_path or '')
    tool_hash = _sha(executable.read_bytes()) if executable.is_file() else None
    try:
        profile = normalize_server_profile(server_profile)
        profile_error = None
    except ValueError as error:
        profile, profile_error = None, str(error)
    identities = _identities(executable, tool_hash, imported=True, server_profile=profile) if tool_hash else {}
    inventory_memo = {}
    chunk_size = max(1, int(max_group))
    planned = ([(group_indexes, None)] if group_indexes is not None else
        _batch_groups(entries, groups, output, identities, profile, chunk_size, claimed, inventory_memo, metrics,
            max_sources=max_sources, verify_missing=verify_missing, prioritize_small=max_new_groups is not None))
    for chunk, hinted_cache in planned:
        group_start = time.monotonic()
        record = {'original_indexes': chunk, 'original_ubt_count': len(chunk), 'accepted': False, 'run_metrics': []}
        if ordered_recipe is not None:
            record['strict_recipe'] = strict_recipe
        print('[verified-batch] start group=' + str(chunk[0]) + ' ubt=' + str(len(chunk)), flush=True)
        group, evidence, candidate, cached, reused = [entries[i] for i in chunk], {}, None, hinted_cache, None
        timings = evidence.setdefault('phase_timings', {})
        cache_key = _cache_key(group, identities, profile, ordered_recipe)
        cache_file = output / 'receipts' / (cache_key + '.json')
        try:
            if profile_error:
                raise ValueError(profile_error)
            if tool_hash is None and verify_missing:
                raise ValueError('clangd-unavailable')
            if verify_missing:
                for entry in group:
                    _validate_ubt(entry)
            if cached is None and cache_file.is_file():
                try:
                    loaded = json.loads(cache_file.read_text(encoding='utf-8'))
                    if (isinstance(loaded, dict) and _forced_prefix_matches(loaded, group)
                            and loaded.get('ordered_recipe') == ordered_recipe
                            and (verify_missing or loaded.get('identities') == identities)
                            and _cache_valid(loaded, output, inventory_memo)):
                        if loaded.get('identities') == identities:
                            if loaded.get('accepted') and not _cached_group_matches(loaded, group, output):
                                raise ValueError('cached-original-group-mismatch')
                            cached = loaded
                        elif verify_missing and loaded.get('compile_rejection'):
                            cached = loaded
                        elif verify_missing and loaded.get('graph_files'):
                            reused = loaded
                except (OSError, ValueError, KeyError, TypeError):
                    pass
            if not cached and not verify_missing:
                metrics['deferred_group_count'] += 1
                record['deferred'] = True
                raise ValueError('verification-not-cached')
            if not cached and max_new_groups is not None:
                reason = ('verification-stage-complete' if metrics['new_batch_count'] else
                          'verification-budget-exhausted' if metrics['new_proof_count'] >= max_new_groups else None)
                if reason:
                    metrics['deferred_group_count'] += 1
                    record['deferred'] = True
                    raise ValueError(reason)
            if cached:
                metrics['cache_hits'] += 1
                record.update(cached=True, first_proof_seconds=cached['first_proof_seconds'])
                if not cached['accepted']:
                    raise ValueError(cached['reason'])
                candidate, detail = cached['candidate'], {'receipt': cached['candidate']['nvim_ue_batch_receipt'],
                    'candidate_order': cached.get('candidate_order', list(range(len(group))))}
            else:
                metrics['new_proof_count'] += 1
                if invocation is None:
                    work = _proof_work_root(output)
                    work.mkdir(parents=True, exist_ok=True)
                    invocation = Path(tempfile.mkdtemp(prefix='proof-', dir=work))
                    metrics['proof_directory'] = str(invocation)
                evidence['query_profiles'] = list(reused.get('query_profiles', [])) if reused else []
                group_root = invocation / ('group-' + str(chunk[0]))
                prepared = None
                if ordered_recipe is not None:
                    with tier1_overlay_scope():
                        prepared = cdb_ordered_batch.prepare(group, output / 'assets' / 'ordered',
                            sys.modules[__name__], max_group=max_group, max_sources=max_sources)
                _timed(timings, 'query_observe', _observe_queries,
                    group, str(executable.resolve()), profile,
                    group_root / 'queries', evidence['query_profiles'], timeout)
                with _phase(timings, 'inventory_before'):
                    before = _inventories(_include_roots(group, [], extra_roots=_query_roots(evidence['query_profiles'])),
                        output, inventory_memo)
                if reused:
                    metrics['cache_hits'] += 1
                    record.update(first_proof_seconds=reused['first_proof_seconds'], graph_replayed=True)
                candidate, detail = _prove(group, group_root,
                    output / 'assets', str(executable.resolve()), tool_hash, timeout, evidence, reused=reused, server_profile=profile,
                    original_identities=identities, inventory_memo=inventory_memo,
                    **({'prepared': prepared} if prepared is not None else {}))
                if _timed(timings, 'inventory_after', lambda:
                        any(_inventory(path, output) != value for path, value in before.items())):
                    raise ValueError('include-inventory-changed-during-proof')
            if _compiler_environment(profile) != identities['compiler_environment']:
                raise ValueError('compiler-environment-changed-during-proof')
            checked_queries = cached.get('query_profiles', []) if cached else evidence.get('query_profiles', [])
            if not _timed(timings, 'query_resolution_revalidate', _query_resolution_current,
                    checked_queries, executable, profile, force=not bool(cached)):
                raise ValueError('compiler-resolution-changed-during-proof')
            admitted_queries.extend(checked_queries)
            anchor = min(chunk)
            replacements[anchor] = candidate
            consumed.update(index for index in chunk if index != anchor)
            claimed.update(chunk)
            metrics['batch_count'] += 1
            if not cached:
                metrics['new_batch_count'] += 1
            metrics['accepted_ubt_count'] += len(chunk)
            record.update(accepted=True, reason='verified-original-tu-union', **detail)
        except (OSError, ValueError, KeyError, TypeError, subprocess.TimeoutExpired) as error:
            record['reason'] = str(error)
        record.update({key: evidence[key] for key in (
            'original_cache_hits', 'original_cache_misses', 'original_cache_unlinked',
            'forced_prefix', 'forced_prefix_unavailable') if key in evidence})
        if evidence.get('run_metrics'):
            record['run_metrics'] = [{key: run.get(key) for key in _RUN_METRIC_FIELDS}
                                     for run in evidence['run_metrics']]
        evidence.pop('run_metrics', None)
        compile_rejection = record['reason'].startswith('private-index-failed: compiler-errors:')
        if (not cached and evidence.get('dependencies') and evidence.get('assets')
                and (record['accepted'] or compile_rejection or record['reason'].startswith('admission-rejected:'))):
            with _phase(timings, 'inventory_receipt'):
                inventory = _inventories(_include_roots(group, evidence['dependencies'], evidence.get('effective_entries', []),
                    extra_roots=_query_roots(evidence.get('query_profiles', []))), output, inventory_memo)
            if record['accepted']:
                receipt_path = Path(candidate['nvim_ue_batch_receipt'])
                evidence['assets'] = [item for item in evidence['assets'] if Path(item['path']) != receipt_path]
                receipt = json.loads(receipt_path.read_text(encoding='utf-8'))
                receipt.update(schema=2, identities=identities, inventories=inventory,
                    assets=evidence['assets'], output_dir=str(output), watch_roots=list(inventory))
                _write(receipt_path, _json(receipt))
                candidate['nvim_ue_batch_receipt_sha256'] = _sha(receipt_path.read_bytes())
                evidence['assets'].append({'path': str(receipt_path), 'sha256': candidate['nvim_ue_batch_receipt_sha256']})
            with _phase(timings, 'receipt_cache_write'):
                _write(cache_file, _json(dict(evidence, schema=1, inventories=inventory, accepted=record['accepted'],
                    reason=record['reason'], candidate=candidate if record['accepted'] else None,
                    compile_rejection=compile_rejection,
                    identities=identities, first_proof_seconds=reused['first_proof_seconds'] if reused else time.monotonic() - group_start)))
        record['proof_seconds'] = round(time.monotonic() - group_start, 6)
        record['phase_timings'] = {key: dict(value, seconds=round(value['seconds'], 6))
                                 for key, value in timings.items()}
        metrics['groups'].append(record)
        if record['accepted']:
            # Receipts sort their JSON keys. Match that ordering on the first
            # publication too, or a cache hit rewrites equal CDB commands solely
            # because the fresh candidate had a different field insertion order.
            replacements[min(chunk)] = dict(sorted(candidate.items()))
            if group_indexes is None:
                new_hints.append(_group_hint(group, cache_key))
        print('[verified-batch] ' + ('admitted' if record['accepted'] else 'retained')
            + ' group=' + str(chunk[0]) + ' ubt=' + str(len(chunk))
            + ' batches=' + str(metrics['batch_count']) + ' proof_seconds=' + str(record['proof_seconds'])
            + ' reason=' + record['reason'], flush=True)
    result = [replacements.get(index, entry) for index, entry in enumerate(entries) if index not in consumed]
    run_timings = {}
    try:
        inventory_changed = _timed(run_timings, 'inventory_final', lambda:
            any(_inventory(path, output) != value for path, value in inventory_memo.items()))
    except OSError:
        inventory_changed = True
    try:
        resolution_changed = bool(admitted_queries) and not _timed(run_timings, 'query_resolution_final', _query_resolution_current,
            admitted_queries, executable, profile, force=bool(metrics['new_proof_count']))
    except (OSError, ValueError, KeyError, TypeError) as error:
        resolution_changed = True
        metrics['query_resolution_error'] = str(error)
    invalidated = ('compiler-environment-changed-during-run' if tool_hash
        and _compiler_environment(profile) != identities['compiler_environment'] else
        'compiler-resolution-changed-during-run' if resolution_changed else
        'include-inventory-changed-during-run' if inventory_changed else None)
    if invalidated:
        result = list(entries)
        metrics.update(batch_count=0, new_batch_count=0, accepted_ubt_count=0, invalidated_reason=invalidated)
        for record in metrics['groups']:
            record.update(accepted=False, reason=invalidated)
    elif new_hints and verify_missing:
        metrics['group_hints_write_status'] = _save_group_hints(output, new_hints)
    metrics.update(output_entries=len(result), retained_ubt_count=metrics['original_ubt_count'] - metrics['accepted_ubt_count'],
                   proof_seconds=round(time.monotonic() - started, 6), baseline_cache_reused=metrics['cache_hits'] > 0)
    metrics.update(proof_accepted_count=sum(bool(record.get('accepted')) for record in metrics['groups']),
        proof_rejected_count=sum(not record.get('accepted') and not record.get('deferred') for record in metrics['groups']),
        proof_uncached_count=sum(record.get('reason') == 'verification-not-cached' for record in metrics['groups']),
        selector_reuse_status=('qualification' if verify_missing else
                               'accepted' if metrics['batch_count'] else 'zero-hit'))
    metrics['phase_timings'] = {key: dict(value, seconds=round(value['seconds'], 6))
                              for key, value in run_timings.items()}
    if invocation is not None:
        _write(invocation / 'metrics.json', _json(metrics))
    return result, metrics


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    action = parser.add_mutually_exclusive_group(required=True)
    action.add_argument('--describe-receipts')
    action.add_argument('--validate-receipts')
    action.add_argument('--replay-proof')
    parser.add_argument('--clangd')
    parser.add_argument('--server-profile', type=json.loads, default=None)
    parser.add_argument('--out', required=True)
    arguments = parser.parse_args()
    try:
        payload = json.loads(Path(arguments.describe_receipts or arguments.validate_receipts or arguments.replay_proof).read_text(encoding='utf-8'))
        if arguments.replay_proof:
            if arguments.server_profile is not None:
                raise ValueError('historical-query-profile-replay-unsupported')
            result = replay_proof(payload['entries'], payload['proof_dir'], arguments.clangd)
        else:
            paths = payload.get('receipt_paths', payload.get('receipts')) if isinstance(payload, dict) else payload
            if not isinstance(paths, list) or not all(isinstance(path, str) for path in paths):
                raise ValueError('receipt-path-list-required')
            result = (describe_receipts(paths, server_profile=arguments.server_profile) if arguments.describe_receipts
                      else validate_receipts(paths, arguments.clangd, server_profile=arguments.server_profile))
    except (OSError, ValueError, KeyError, TypeError) as error:
        result = {'ok': False, 'reason': str(error)}
    _write(arguments.out, _json(result))
    print(_json(result))
    raise SystemExit(0 if result['ok'] else 1)
