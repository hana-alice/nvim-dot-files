"""Prove same-context UBT batches in private clangd processes before publication.

Receipts are reused only after byte and include-directory inventory validation.
Callers must invalidate a published receipt when its live dependencies change.
"""
import collections
import argparse
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
from build_hot_super_unity_cdb import compile_context_key, portable_member_path, rewritten_arguments, secondary_unity_chunks
from clangd_batch_admission import compare_graphs
from clangd_batch_runner import normalize_server_profile, run
from clangd_index_graph import _record_key, canonical_file_graph, read_shard

_COLLECTOR_FILES = ('cdb_verified_batch.py', 'build_hot_super_unity_cdb.py', 'clangd_index_graph.py',
                    'clangd_batch_runner.py', 'clangd_vfs_aliases.py', 'clangd_query_profile.py')
_POLICY_FILES = ('clangd_batch_admission.py', 'clangd_batch_bindings.py',
                 '../lua/workarounds/clangd/header_path_case.py')
_HEADER_CASE_PATH = Path(__file__).resolve().parent / _POLICY_FILES[-1]
_HEADER_CASE_POLICY = None
_OWNED_OVERLAY_MEMO = {}
_INCLUDE_ENV = ('CPATH', 'CPLUS_INCLUDE_PATH', 'C_INCLUDE_PATH', 'OBJC_INCLUDE_PATH',
                'OBJCPLUS_INCLUDE_PATH', 'INCLUDE')
# These values are inherited by every private compiler process. Cache/TEMP
# overrides are intentionally absent; unset and empty values remain distinct.
_COMPILER_ENV = _INCLUDE_ENV + ('SDKROOT', 'MACOSX_DEPLOYMENT_TARGET', 'IPHONEOS_DEPLOYMENT_TARGET',
    'TVOS_DEPLOYMENT_TARGET', 'WATCHOS_DEPLOYMENT_TARGET', 'XROS_DEPLOYMENT_TARGET',
    'DEVELOPER_DIR', 'TOOLCHAINS', 'GCC_EXEC_PREFIX', 'COMPILER_PATH', 'PATH', 'PATHEXT',
    'WindowsSdkDir', 'WindowsSDKVersion', 'VCToolsInstallDir', 'VCINSTALLDIR',
    'CL', '_CL_', 'CCC_OVERRIDE_OPTIONS', 'SOURCE_DATE_EPOCH', 'TZ')


def _compiler_environment():
    return {name: os.environ.get(name) for name in _COMPILER_ENV}


def _code_identities():
    return {key: hashlib.sha256(b''.join((Path(__file__).parent / name).read_bytes() for name in files)).hexdigest()
            for key, files in (('collector', _COLLECTOR_FILES), ('policy', _POLICY_FILES))}


_IMPORTED_CODE = _code_identities()


def _json(value):
    return json.dumps(value, sort_keys=True, ensure_ascii=True, separators=(',', ':'))


def _sha(data):
    return hashlib.sha256(data).hexdigest()


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


def _owned_overlays(entry):
    """Validate only the producer's content-addressed identity overlay.

    Bytes are checked on each access; expensive physical-spelling validation is
    shared only within the current qualification/receipt-validation invocation.
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
        raw = path.read_bytes()
        digest = _sha(raw)
        key = (str(path), digest)
        if key not in _OWNED_OVERLAY_MEMO:
            mapping = _owned_overlay_policy().validate_owned_overlay(path)
            if path.read_bytes() != raw:
                raise ValueError('owned-overlay-changed-during-validation')
            _OWNED_OVERLAY_MEMO[key] = mapping
        result.append({'path': str(path), 'sha256': digest, 'mapping': _OWNED_OVERLAY_MEMO[key]})
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
    selected = []
    for path in sorted(map(Path, roots), key=lambda p: (len(p.parts), str(p))):
        if not any(parent == path or parent in path.parents for parent in selected):
            selected.append(path)
    return list(map(str, selected))


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
        if observation['profile'] != profile or observation['compiler_environment'] != _compiler_environment():
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


def _cache_valid(record, output, memo):
    if not isinstance(record, dict) or record.get('schema') != 1:
        return False
    if not isinstance(record.get('identities'), dict) or record['identities'].get('compiler_environment') != _compiler_environment():
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
        'compiler_environment': _compiler_environment(),
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
        environment = records[0]['identities']['compiler_environment']
        if any(record['identities']['compiler_environment'] != environment for record in records):
            raise ValueError('receipt-compiler-environments-disagree')
        roots = {path for record in records for path in record['inventories']}
        for record in records:
            roots.add(str(Path(record['identities']['tool_path']).parent))
            if record['identities'].get('binding_path'):
                roots.add(str(Path(record['identities']['binding_path']).parent))
        roots.add(str(Path(__file__).resolve().parent))
        roots.add(str(_HEADER_CASE_PATH.resolve().parent))
        minimal = []
        for path in sorted(map(Path, roots), key=lambda value: (len(value.parts), str(value))):
            if not any(parent == path or parent in path.parents for parent in minimal):
                minimal.append(path)
        return {'ok': True, 'watch_roots': sorted(map(str, minimal)),
                'compiler_environment': environment,
                'server_profile': profile,
                'query_driver_files': sorted(driver_files), 'query_driver_search_roots': sorted(driver_roots),
                'query_search_roots': _query_roots(queries), 'query_profiles': queries,
                'exclude_roots': sorted({record['output_dir'] for record in records})}
    except (OSError, ValueError, KeyError, TypeError) as error:
        return {'ok': False, 'reason': str(error), 'watch_roots': [], 'exclude_roots': []}


def validate_receipts(receipt_paths, clangd_path, server_profile=None):
    """Verify live dependencies, immutable assets, inventories and tool policy."""
    started = time.monotonic()
    _OWNED_OVERLAY_MEMO.clear()
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
            if not _cache_valid(dict(record, schema=1), output, memo):
                raise ValueError('receipt-input-or-asset-changed')
            for observation in record.get('query_profiles', []):
                key = _json({name: observation[name] for name in
                    ('tuple', 'profile', 'compiler_environment', 'clangd', 'driver', 'ordered_includes', 'target')})
                if key in checked_queries:
                    continue
                from clangd_query_profile import validate
                profile = identities['server_profile']
                directory = Path(tempfile.mkdtemp(prefix='query-validation-', dir=output))
                query = validate(observation, observation['entry'], str(executable), profile['query_driver'], directory,
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


def _index(entries, directory, clangd, timeout, server_profile=None, record_pool=None):
    directory.mkdir(parents=True, exist_ok=True)
    trigger = directory / 'trigger.cpp'
    _write(trigger, '// Private BackgroundIndex trigger.\n')
    commands = [_private_command(entry) for entry in entries]
    commands.append({'directory': str(directory), 'file': str(trigger),
                     'arguments': ['clang++', '-x', 'c++', '-c', str(trigger)]})
    _write(directory / 'compile_commands.json', _json(commands))
    result = run(directory, directory / 'run', trigger, clangd, timeout=timeout, jobs=1, server_profile=server_profile)
    effective = {}
    graph = _graph_result(result, trigger, effective, record_pool)
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
    def shards():
        for path in result['shards']:
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
            yield shard
    if record_pool is None:
        graph = canonical_file_graph(shards(), ignore_files={trigger.as_uri()})
    else:
        graph = {}
        # Release duplicate file records while reading each independent TU,
        # rather than retaining a second complete decoded TU until _index ends.
        for shard in shards():
            for uri, record in canonical_file_graph([shard], ignore_files={trigger.as_uri()}).items():
                if uri in graph and graph[uri] != record:
                    raise ValueError('conflicting clangd file shards for ' + uri)
                graph[uri] = _intern_file_record(uri, record, record_pool)
        graph = dict(sorted(graph.items()))
    own = set(graph)
    for uri, record in graph.items():
        if record['source']['flags'] & 2:
            raise ValueError('private-index-had-errors: ' + uri)
        if set(record['source']['direct_includes']) - own:
            raise ValueError('incomplete-dependency-shards: ' + uri)
    return graph


def _freeze(group, originals, assets, tool_hash, server_profile=None):
    canonical_names = {os.path.normcase(os.path.normpath(path))
                       for entry in group for overlay in _owned_overlays(entry)
                       for path in overlay['mapping']}
    dependencies = sorted({uri for graph in originals for uri in graph})
    files = []
    for uri in dependencies:
        path = _uri_path(uri)
        with path.open('rb') as stream:
            physical = os.fstat(stream.fileno())
            raw = stream.read()
        file_identity = _source_identity(path, physical)
        digest = _sha(raw)
        # Equal bytes do not imply equal #pragma-once file identity. Preserve
        # aliases recognized by Clang even when their suffixes differ.
        copy = assets / 'snapshots' / (_sha(_json([digest, file_identity]).encode()) + '.snapshot')
        _write(copy, raw)
        files.append({'uri': uri, 'path': str(path), 'sha256': digest, 'snapshot': str(copy),
                      'file_identity': file_identity})
    identity = _sha(_json({'entries': [_native(entry) for entry in group],
                          'files': files, 'tool': tool_hash, 'compiler_environment': _compiler_environment(),
                          'server_profile': server_profile}).encode())
    wrapper = assets / ('SuperUnity.Batch.' + identity[:24] + '.cpp')
    body = '// Verified same-context UBT batch.\n' + ''.join(
        '#include "' + entry['file'].replace('\\', '/') + '"\n' for entry in group)
    _write(wrapper, body)
    body_snapshot = assets / 'snapshots' / (_sha(body.encode()) + '.cpp')
    _write(body_snapshot, body)
    mapping = [{'type': 'file', 'name': str(_uri_path(item['uri'])),
                'external-contents': item['snapshot']} for item in files]
    mapping.append({'type': 'file', 'name': str(wrapper), 'external-contents': str(body_snapshot)})
    overlay = assets / ('overlay.' + identity[:24] + '.json')
    arguments = rewritten_arguments(group[0], str(wrapper))
    if arguments is None:
        raise ValueError('batch-source-rewrite-failed')
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
    candidate = _windows_paths(dict(group[0], file=str(wrapper),
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


def _candidate_index(effective_group, candidate, root, assets, clangd, timeout, runs, evidence, server_profile=None):
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
        graph, result, effective = _index([candidate], root, clangd, timeout, server_profile)
        runs.append(result)
    except ValueError as error:
        report = root / 'run/run.json'
        if report.is_file():
            runs.append(json.loads(report.read_text(encoding='utf-8')))
        if os.name != 'nt' or not str(error).startswith('private-index-failed: compiler-errors:'):
            raise
        alias_started = time.monotonic()
        candidate = _alias_overlay(effective_group, candidate, root, assets, clangd, timeout)
        evidence['alias_probe_seconds'] = round(time.monotonic() - alias_started, 6)
        graph, result, effective = _index([candidate], root.with_name(root.name + '-aliases'), clangd, timeout, server_profile)
        runs.append(result)
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
    evidence = Path(tempfile.mkdtemp(prefix='policy-replay-', dir=root))
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
    return [{key: value for key, value in item.items()
             if key not in ('entry', 'entry_sha256', 'source_sha256', 'clangd_run')}
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
        raw = path.read_bytes()
        if _sha(raw) != asset['sha256']:
            return None
        saved = json.loads(raw)
        del raw
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


def _save_originals(group, originals, effective_group, pending, files, frozen_graph,
                    identities, output, memo, observations):
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
           original_identities=None, inventory_memo=None):
    original_overlay_assets = _owned_overlay_assets(group)
    for entry in group:
        _validate_ubt(entry)
    members = [member for entry in group for member in entry['nvim_ue_members']]
    if len(set(members)) != len(members):
        raise ValueError('overlapping-original-members')
    originals, runs, effective_group, pending_originals = [], [], [], {}
    record_pool = {}
    output = assets.parent.resolve()
    memo = inventory_memo if inventory_memo is not None else {}
    identities = original_identities or _identities(Path(clangd), tool_hash, imported=True, server_profile=server_profile)
    evidence.update(original_cache_hits=0, original_cache_misses=0, original_cache_unlinked=0)
    if reused:
        evidence.update({key: reused[key] for key in (
            'dependencies', 'assets', 'graph_files', 'identity', 'replay_candidate', 'effective_entries',
            'effective_candidate', 'query_profiles')})
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
            raw = Path(item['path']).read_bytes()
            if _sha(raw) != item['sha256']:
                raise ValueError('stored-collector-graph-changed')
            loaded_graph = json.loads(raw)
            del raw
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
            cached = _cached_original(entry, identities, output, memo, queries, record_pool)
            if cached:
                graph, effective_entry = cached
                effective = [effective_entry]
                evidence['original_cache_hits'] += 1
            else:
                evidence['original_cache_misses'] += 1
                graph, result, effective = _index([entry], root / ('original-' + str(index)), clangd, timeout,
                                                  server_profile, record_pool=record_pool)
                runs.append(result)
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
        candidate, files, identity = _freeze(group, originals, assets, tool_hash, server_profile)
        evidence.update(dependencies=files, identity=identity, replay_candidate=candidate)
        evidence['assets'] = _candidate_assets(candidate) + original_overlay_assets
        candidate, graph = _candidate_index(effective_group, candidate, root / 'candidate', assets, clangd, timeout, runs, evidence, server_profile)
        _save_originals(group, originals, effective_group, pending_originals, files, graph,
                        identities, output, memo, evidence['query_profiles'])
        evidence['original_cache_unlinked'] = len(pending_originals)
    verdict = _admit(group, candidate, originals, graph, root, clangd, timeout,
                     effective_group, evidence['effective_candidate'])
    if verdict['reason'] == 'symbol-identities-changed' and verdict.get('missing') and not reused:
        missing = set(verdict['missing'])
        scores = [len(missing & {symbol['id'] for file in original.values() for symbol in file['symbols']})
                  for original in originals]
        owner = max(range(len(group)), key=lambda index: scores[index])
        if owner and scores[owner]:
            order = [owner] + [index for index in range(len(group)) if index != owner]
            candidate, files, identity = _freeze([group[index] for index in order], originals, assets, tool_hash, server_profile)
            evidence.update(dependencies=files, identity=identity, replay_candidate=candidate, candidate_order=order)
            evidence['assets'] = _candidate_assets(candidate) + original_overlay_assets
            candidate, graph = _candidate_index(effective_group, candidate, root / 'candidate-reordered', assets, clangd, timeout, runs, evidence, server_profile)
            _save_originals(group, originals, effective_group, pending_originals, files, graph,
                            identities, output, memo, evidence['query_profiles'])
            evidence['original_cache_unlinked'] = len(pending_originals)
            verdict = _admit(group, candidate, originals, graph, root, clangd, timeout,
                             effective_group, evidence['effective_candidate'])
    evidence['assets'].extend(verdict.get('template_argument_proof_assets', []))
    if not reused:
        evidence['graph_files'] = []
        for index, value in enumerate(originals + [graph]):
            path, raw = root / ('graph-' + str(index) + '.json'), _json(value)
            _write(path, raw)
            evidence['graph_files'].append({'path': str(path), 'sha256': _sha(raw.encode())})
    if not verdict.get('accepted'):
        raise ValueError('admission-rejected: ' + verdict['reason'])
    if any(_sha(Path(item['path']).read_bytes()) != item['sha256'] for item in files):
        raise ValueError('dependencies-changed-during-proof')
    if any(_sha(Path(item['path']).read_bytes()) != item['sha256'] for item in original_overlay_assets):
        raise ValueError('owned-overlay-changed-during-proof')
    if any(_sha(Path(item['path']).read_bytes()) != item['sha256']
           for item in _query_assets(evidence['query_profiles'])):
        raise ValueError('query-inputs-changed-during-proof')
    receipt = assets / ('receipt.' + identity[:24] + '.json')
    _write(receipt, _json({'schema': 1, 'identity': identity, 'tool_sha256': tool_hash,
        'server_profile': server_profile,
        'query_profiles': evidence['query_profiles'],
        'effective_entries': [_native(entry) for entry in effective_group],
        'effective_candidate': _native(evidence['effective_candidate']),
        'original_entries': [_native(entry) for entry in group], 'candidate': _native(candidate),
        'dependencies': files, 'admission_reason': verdict['reason'],
        'original_graph_sha256': [_sha(_json(original).encode()) for original in originals],
        'candidate_graph_sha256': _sha(_json(graph).encode()),
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
        {key: run.get(key) for key in ('indexing_wall_seconds', 'cpu_seconds', 'peak_working_set_bytes')}
        for run in runs]}


_HINT_BYTES, _HINT_GROUPS = 2 * 1024 * 1024, 2048


def _cache_key(group, identities, profile):
    return _sha(_json({'entries': group, 'collector': identities.get('collector'),
        'tool': identities.get('tool'), 'tool_path': identities.get('tool_path'),
        'compiler_environment': identities.get('compiler_environment'), 'server_profile': profile}).encode())


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
    if not isinstance(record, dict) or not isinstance(record.get('candidate'), dict):
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
    return (receipt.get('schema') == 2 and Path(receipt['output_dir']).resolve() == output
        and receipt['original_entries'] == [_native(entry) for entry in group]
        and receipt['candidate'] == _native(candidate)
        and all(receipt[key] == record[key] for key in ('identities', 'dependencies', 'inventories', 'query_profiles'))
        and candidate.get('nvim_ue_batch_receipt_sha256') == digest
        and {'path': str(path), 'sha256': digest} in record['assets']
        and candidate['nvim_ue_batch_ubt_count'] == len(group)
        and sorted(order) == list(range(len(group)))
        and candidate['nvim_ue_members'] == [member for i in order for member in group[i]['nvim_ue_members']])


def _batch_groups(entries, groups, output, identities, profile, max_group, claimed, memo, metrics,
                  max_sources=80, verify_missing=False):
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
    pending = [[available[index] for index in chunk] for chunk in reversed(
        secondary_unity_chunks([entries[index] for index in available],
            max_sources=max_sources, max_unities=max_group))]
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


def accelerate(entries, output_dir, clangd_path, max_group=8, timeout=90, verify_missing=True, server_profile=None,
               max_sources=80):
    """Return (background_entries, metrics); rejected groups keep exact originals.

    output_dir must be a private proof/artifact directory, never a live clangd
    cache. Cache misses start independent original-TU caches; hits revalidate
    original bytes, snapshot assets and complete include-directory inventories.
    With verify_missing=False, misses retain originals without compiler work or
    graph replay; only receipts with the complete current identity are reused.
    Compact accepted hints discover noncontiguous groups; max_group remains a
    hard limit and every discovered group goes through the full cache gate.
    """
    started = time.monotonic()
    _OWNED_OVERLAY_MEMO.clear()
    output = Path(output_dir).resolve()
    output.mkdir(parents=True, exist_ok=True)
    invocation = Path(tempfile.mkdtemp(prefix='proof-', dir=output))
    groups = collections.defaultdict(list)
    metrics = {'original_ubt_count': sum(_is_ubt(entry) for entry in entries),
        'batch_count': 0, 'accepted_ubt_count': 0, 'groups': [], 'proof_directory': str(invocation),
        'cache_hits': 0, 'deferred_group_count': 0}
    shader = lambda e: Path(e.get('file', '')).suffix.lower() in (
        '.usf', '.ush', '.hlsl', '.hlsli', '.glsl', '.vert', '.frag', '.geom', '.tesc', '.tese', '.comp', '.metal')
    exact = lambda e: not _is_ubt(e) and Path(e.get('file', '')).suffix.lower() in ('.c', '.cc', '.cpp', '.cxx', '.c++')
    metrics['shader_count'] = sum(shader(entry) for entry in entries)
    metrics['exact_count'] = sum(exact(entry) for entry in entries)
    metrics['other_count'] = sum(not _is_ubt(entry) and not shader(entry) and not exact(entry) for entry in entries)
    for index, entry in enumerate(entries):
        if _is_ubt(entry):
            groups[(entry['nvim_ue_module_root'], compile_context_key(entry))].append(index)
    replacements, consumed, claimed, new_hints = {}, set(), set(), []
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
    for chunk, hinted_cache in _batch_groups(entries, groups, output, identities, profile,
                                             chunk_size, claimed, inventory_memo, metrics,
                                             max_sources=max_sources, verify_missing=verify_missing):
        group_start = time.monotonic()
        record = {'original_indexes': chunk, 'original_ubt_count': len(chunk), 'accepted': False, 'run_metrics': []}
        print('[verified-batch] start group=' + str(chunk[0]) + ' ubt=' + str(len(chunk)), flush=True)
        group, evidence, candidate, cached, reused = [entries[i] for i in chunk], {}, None, hinted_cache, None
        cache_key = _cache_key(group, identities, profile)
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
                    if (isinstance(loaded, dict) and (verify_missing or loaded.get('identities') == identities)
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
            if cached:
                metrics['cache_hits'] += 1
                record.update(cached=True, first_proof_seconds=cached['first_proof_seconds'])
                if not cached['accepted']:
                    raise ValueError(cached['reason'])
                candidate, detail = cached['candidate'], {'receipt': cached['candidate']['nvim_ue_batch_receipt'],
                    'candidate_order': cached.get('candidate_order', list(range(len(group))))}
            else:
                evidence['query_profiles'] = list(reused.get('query_profiles', [])) if reused else []
                group_root = invocation / ('group-' + str(chunk[0]))
                _observe_queries(group, str(executable.resolve()), profile,
                    group_root / 'queries', evidence['query_profiles'], timeout)
                before = _inventories(_include_roots(group, [], extra_roots=_query_roots(evidence['query_profiles'])),
                    output, inventory_memo)
                if reused:
                    metrics['cache_hits'] += 1
                    record.update(first_proof_seconds=reused['first_proof_seconds'], graph_replayed=True)
                candidate, detail = _prove(group, group_root,
                    output / 'assets', str(executable.resolve()), tool_hash, timeout, evidence, reused=reused, server_profile=profile,
                    original_identities=identities, inventory_memo=inventory_memo)
                if any(_inventory(path, output) != value for path, value in before.items()):
                    raise ValueError('include-inventory-changed-during-proof')
            if _compiler_environment() != identities['compiler_environment']:
                raise ValueError('compiler-environment-changed-during-proof')
            anchor = min(chunk)
            replacements[anchor] = candidate
            consumed.update(index for index in chunk if index != anchor)
            claimed.update(chunk)
            metrics['batch_count'] += 1
            metrics['accepted_ubt_count'] += len(chunk)
            record.update(accepted=True, reason='verified-original-tu-union', **detail)
        except (OSError, ValueError, KeyError, TypeError, subprocess.TimeoutExpired) as error:
            record['reason'] = str(error)
        record.update({key: evidence[key] for key in (
            'original_cache_hits', 'original_cache_misses', 'original_cache_unlinked') if key in evidence})
        record['proof_seconds'] = round(time.monotonic() - group_start, 6)
        compile_rejection = record['reason'].startswith('private-index-failed: compiler-errors:')
        if (not cached and evidence.get('dependencies') and evidence.get('assets')
                and (record['accepted'] or compile_rejection or record['reason'].startswith('admission-rejected:'))):
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
            _write(cache_file, _json(dict(evidence, schema=1, inventories=inventory, accepted=record['accepted'],
                reason=record['reason'], candidate=candidate if record['accepted'] else None,
                compile_rejection=compile_rejection,
                identities=identities, first_proof_seconds=reused['first_proof_seconds'] if reused else record['proof_seconds'])))
        metrics['groups'].append(record)
        if record['accepted']:
            new_hints.append(_group_hint(group, cache_key))
        print('[verified-batch] ' + ('admitted' if record['accepted'] else 'retained')
            + ' group=' + str(chunk[0]) + ' ubt=' + str(len(chunk))
            + ' batches=' + str(metrics['batch_count']) + ' proof_seconds=' + str(record['proof_seconds'])
            + ' reason=' + record['reason'], flush=True)
    result = [replacements.get(index, entry) for index, entry in enumerate(entries) if index not in consumed]
    try:
        inventory_changed = any(_inventory(path, output) != value for path, value in inventory_memo.items())
    except OSError:
        inventory_changed = True
    invalidated = ('compiler-environment-changed-during-run' if tool_hash
        and _compiler_environment() != identities['compiler_environment'] else
        'include-inventory-changed-during-run' if inventory_changed else None)
    if invalidated:
        result = list(entries)
        metrics.update(batch_count=0, accepted_ubt_count=0, invalidated_reason=invalidated)
        for record in metrics['groups']:
            record.update(accepted=False, reason=invalidated)
    elif new_hints and verify_missing:
        metrics['group_hints_write_status'] = _save_group_hints(output, new_hints)
    metrics.update(output_entries=len(result), retained_ubt_count=metrics['original_ubt_count'] - metrics['accepted_ubt_count'],
                   proof_seconds=round(time.monotonic() - started, 6), baseline_cache_reused=metrics['cache_hits'] > 0)
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
