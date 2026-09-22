"""Observe one native query-driver extraction without building a TU graph.

Restricted to the reviewed Windows LLVM 22.1.5 extractor protocol:
https://github.com/llvm/llvm-project/blob/llvmorg-22.1.5/clang-tools-extra/clangd/SystemIncludeExtractor.cpp
The logged command is a completion marker only, never an argv authority.
Callers must obtain effective argv structurally from the main-file shard.
"""
import argparse
import ctypes
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import threading
import time


PARSER_ID = 'windows-llvm-22.1.5-query-driver-v3'
LLVM_COMMIT = '5ea218a153f4d2f815b8244eab3e4b4ba5e00e6c'
ANDROID_NDK_9_VERSION = (
    'Android (7019983 based on r365631c3) clang version 9.0.9 '
    '(https://android.googlesource.com/toolchain/llvm-project '
    'a2a1e703c0edb03ba29944e529ccbf457742737b) (based on LLVM 9.0.9svn)')
# Same compiler environment boundary as cdb_verified_batch. Never persist the
# full environment, which contains unrelated variables and potentially secrets.
COMPILER_ENV = ('CPATH', 'CPLUS_INCLUDE_PATH', 'C_INCLUDE_PATH', 'OBJC_INCLUDE_PATH',
    'OBJCPLUS_INCLUDE_PATH', 'INCLUDE', 'SDKROOT', 'MACOSX_DEPLOYMENT_TARGET',
    'IPHONEOS_DEPLOYMENT_TARGET', 'TVOS_DEPLOYMENT_TARGET', 'WATCHOS_DEPLOYMENT_TARGET',
    'XROS_DEPLOYMENT_TARGET', 'DEVELOPER_DIR', 'TOOLCHAINS', 'GCC_EXEC_PREFIX',
    'COMPILER_PATH', 'PATH', 'PATHEXT', 'WindowsSdkDir', 'WindowsSDKVersion',
    'VCToolsInstallDir', 'VCINSTALLDIR', 'CL', '_CL_', 'CCC_OVERRIDE_OPTIONS',
    'SOURCE_DATE_EPOCH', 'TZ')


def _json(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=True)


def _sha(data):
    return hashlib.sha256(data).hexdigest()


def _file_hash(path):
    digest = hashlib.sha256()
    with Path(path).open('rb') as file:
        for chunk in iter(lambda: file.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def _driver_profile(version_text):
    """Return the exact compiler profile certified by this parser revision."""
    if version_text.startswith('clang version 22.1.5 ') and LLVM_COMMIT in version_text:
        return 'llvm-22.1.5'
    if version_text.startswith(ANDROID_NDK_9_VERSION):
        return 'android-ndk-r20b-clang-9.0.9'
    return None


def _key(path):
    return os.path.normcase(os.path.normpath(str(path)))


def query_tuple(entry):
    """Return the exact reviewed DriverArgs tuple; unsupported syntax raises.

    This key alone is not a certificate: cwd, environment, allowlist and tool
    identity must also match. Directory participates for relative driver paths.
    """
    if not isinstance(entry, dict) or not isinstance(entry.get('directory'), str):
        raise ValueError('standard-cdb-directory-required')
    directory = Path(entry['directory'])
    args, source = entry.get('arguments'), entry.get('file')
    if not directory.is_absolute() or not directory.is_dir():
        raise ValueError('absolute-cdb-directory-required')
    if not isinstance(source, str) or Path(source).suffix.lower() not in {'.cpp', '.cc', '.cxx'}:
        raise ValueError('cxx-source-required')
    if not isinstance(args, list) or not args or any(not isinstance(a, str) or not a
            or any(c in a for c in ('\0', '\r', '\n')) for a in args):
        raise ValueError('expanded-cdb-arguments-required')
    driver = args[0]
    if not re.fullmatch(r'clang(?:\+\+)?(?:\.exe)?', Path(driver).name, re.I):
        raise ValueError('plain-clang-driver-required')
    if '/' in driver or '\\' in driver:
        driver = str(directory / driver)
    result = dict(Driver=driver, Lang='c++', StandardIncludes=True,
                  StandardCXXIncludes=True, Sysroot='', ISysroot='', Target='', Stdlib='', Specs=[])
    pairs = {'-x': 'Lang', '--sysroot': 'Sysroot', '-isysroot': 'ISysroot',
             '-target': 'Target', '--stdlib': 'Stdlib'}
    values = {'-I', '-D', '-U', '-isystem', '-iquote', '-idirafter', '-include', '-imacros',
              '-o', '-MF', '-MT', '-MQ', '-F', '-iframework', '-ivfsoverlay'}
    singles = {'-c', '-S', '-E', '-pipe', '-pthread', '-no-canonical-prefixes',
               '-MD', '-MMD', '-MP', '-MG', '-nostdlibinc', '-nobuiltininc', '--driver-mode=g++'}
    i, files = 1, []
    while i < len(args):
        arg = args[i]
        if arg in pairs or arg in values:
            if i + 1 >= len(args) or args[i + 1].startswith('-'):
                raise ValueError('missing-or-ambiguous-option-value')
            if arg in pairs:
                result[pairs[arg]] = args[i + 1]
            i += 2
            continue
        if arg in ('-nostdinc', '--no-standard-includes'):
            result['StandardIncludes'] = False
        elif arg == '-nostdinc++':
            result['StandardCXXIncludes'] = False
        elif arg.startswith(('--target=', '--sysroot=', '--stdlib=', '-stdlib=')):
            name, value = arg.split('=', 1)
            result[{'--target': 'Target', '--sysroot': 'Sysroot', '--stdlib': 'Stdlib', '-stdlib': 'Stdlib'}[name]] = value
        elif arg.startswith('-isysroot'):
            result['ISysroot'] = arg[len('-isysroot'):]
        elif arg.startswith('-x'):
            result['Lang'] = arg[2:]
        elif arg in singles or re.match(r'^-(?:[DIUFWOg].+|std=.+|f[\w-]+(?:=.+)?|m[\w-]+(?:=.+)?)$', arg):
            if arg.startswith(('-fplugin', '-fpass-plugin', '-fmodule', '-fprebuilt-module')):
                raise ValueError('unsupported-indirect-compiler-state')
        elif arg.startswith('--gcc-toolchain='):
            pass  # Preserved in native CDB, intentionally absent in DriverArgs.render.
        elif not arg.startswith(('-', '@')):
            files.append(_key(directory / arg))
        else:
            raise ValueError('unsupported-query-option:' + arg)
        i += 1
    if files != [_key(directory / source)] or result['Lang'] != 'c++':
        raise ValueError('single-cxx-input-required')
    if not re.fullmatch(r'[A-Za-z0-9_.+-]+', result['Target']):
        raise ValueError('explicit-target-required')
    if not result['Sysroot'] or not Path(result['Sysroot']).is_absolute():
        raise ValueError('absolute-sysroot-required')
    if result['ISysroot'] and not Path(result['ISysroot']).is_absolute():
        raise ValueError('absolute-isysroot-required')
    if result['Stdlib'] not in ('', 'libc++', 'libstdc++'):
        raise ValueError('unsupported-standard-library')
    return result


def _driver_candidates(tuple_, clangd, cwd, environment):
    """Conservative SearchPathW scope, not a simulated resolver or search order.

    LLVM 22.1.5 Program.inc appends '', '.exe', then every PATHEXT suffix before
    SearchPathW(NULL,...). Watch exact candidate names for newly shadowing files;
    do not recursively inventory these often enormous system/PATH directories.
    https://learn.microsoft.com/en-us/windows/win32/api/processenv/nf-processenv-searchpathw
    """
    token = tuple_['Driver']
    if Path(token).is_absolute():
        return [Path(token).parent.as_posix()], [Path(token).as_posix()]
    kernel = ctypes.WinDLL('kernel32', use_last_error=True)
    def system_directory(name):
        buffer = ctypes.create_unicode_buffer(32768)
        function = getattr(kernel, name)
        function.argtypes = [ctypes.c_wchar_p, ctypes.c_uint]
        function.restype = ctypes.c_uint
        count = function(buffer, len(buffer))
        if not count or count >= len(buffer):
            raise ValueError('windows-search-directory-unavailable')
        return Path(buffer.value)
    windows = system_directory('GetWindowsDirectoryW')
    roots = [clangd.parent, cwd, system_directory('GetSystemDirectoryW'), windows / 'System', windows]
    for segment in (environment.get('PATH') or '').split(';'):
        if '"' in segment or '%' in segment:
            raise ValueError('unsupported-driver-search-path-syntax')
        roots.append(cwd / segment if segment else cwd)
    extensions = ['', '.exe'] + (environment.get('PATHEXT') or '').split(';')
    if any(ext and not re.fullmatch(r'\.[A-Za-z0-9]+', ext) for ext in extensions):
        raise ValueError('unsupported-driver-search-extension')
    unique_roots = {_key(root): root for root in roots}
    candidates = {}
    for root in unique_roots.values():
        for ext in extensions:
            path = root / (token + ext)
            candidates.setdefault(_key(path), path.as_posix())
    return [root.as_posix() for root in unique_roots.values()], list(candidates.values())


def _implicit_search_roots(driver):
    # LLVM 22.1.5 Gnu.cpp addLibCxxIncludePaths/GCCInstallationDetector silently
    # probe installation-relative include, lib/lib64 and triple directories.
    # Their absent candidates need inventory coverage even though -v does not
    # print them. Bound this to the verified bin/clang[++].exe installation;
    # never turn an unfamiliar layout into a whole-drive inventory.
    roots = {}
    for path in (driver, driver.resolve(strict=True)):
        prefix = path.parent.parent
        if (path.parent.name.lower() != 'bin' or len(prefix.parts) <= 1
                or not re.fullmatch(r'clang(?:\+\+)?\.exe', path.name, re.I)):
            raise ValueError('unsupported-driver-installation-layout')
        roots.setdefault(_key(prefix), prefix.as_posix())
    return list(roots.values())


def _one(values, name):
    if len(values) != 1:
        raise ValueError('missing-or-ambiguous-' + name)
    return values[0]


def _parse_clangd_output(output, entry, cdb_path):
    lines = [re.sub(r'^[IVWE]\[[^\]]+\] ', '', line) for line in output.splitlines()]
    if any('Generic fallback command' in line or 'Failed to load compilation database' in line for line in lines):
        raise ValueError('clangd-cdb-fallback')
    source = _one([line.removeprefix('Testing on source file ') for line in lines
                   if line.startswith('Testing on source file ')], 'source-marker')
    loaded = _one([line.removeprefix('Loaded compilation database from ') for line in lines
                   if line.startswith('Loaded compilation database from ')], 'cdb-marker')
    if _key(source) != _key(Path(entry['directory']) / entry['file']) or _key(loaded) != _key(cdb_path):
        raise ValueError('clangd-source-or-cdb-mismatch')
    command = _one([line for line in lines if line.startswith('Compile command from CDB is: ')], 'effective-command')
    match = re.fullmatch(r'Compile command from CDB is: \[(.+)\] (.+)', command)
    if not match or _key(match[1]) != _key(entry['directory']):
        raise ValueError('clangd-command-directory-mismatch')
    prefix = 'System includes extractor: successfully executed '
    position = _one([i for i, line in enumerate(lines) if line.startswith(prefix)], 'extractor-success')
    if position + 2 >= len(lines):
        raise ValueError('truncated-extractor-success')
    includes = re.fullmatch(r'\s*got includes: "(.*)"', lines[position + 1])
    target = re.fullmatch(r'\s*got target: "([A-Za-z0-9_.+-]+)"', lines[position + 2])
    if not includes or not target:
        raise ValueError('malformed-extractor-success')
    driver = lines[position][len(prefix):]
    if not Path(driver).is_absolute() or not Path(driver).is_file():
        raise ValueError('observed-driver-is-not-an-absolute-file')
    added = [line.removeprefix('System include extraction: adding ').strip() for line in lines
             if line.startswith('System include extraction: adding ')]
    builtin = _one([line.removeprefix('System includes extractor: builtin headers ') for line in lines
                    if line.startswith('System includes extractor: builtin headers ')], 'builtin-observation')
    return {'driver': driver, 'includes': includes[1].split(', ') if includes[1] else [],
            'target': target[1], 'raw_includes': added, 'builtin': builtin,
            'effective_command_log_sha256': _sha(command.encode())}


def _parse_driver_output(output):
    lines = [line.strip() for line in output.splitlines()]
    start = _one([i for i, line in enumerate(lines) if line == '#include <...> search starts here:'], 'driver-search-start')
    end = _one([i for i, line in enumerate(lines) if line == 'End of search list.'], 'driver-search-end')
    target = _one([line[8:] for line in lines if line.startswith('Target: ')], 'driver-target')
    includes = lines[start + 1:end]
    if end <= start or any(not item or not Path(item).is_absolute() or ', ' in item or '"' in item for item in includes):
        raise ValueError('unsupported-driver-include-list')
    return includes, target


def _run(command, cwd, environment, timeout, stem):
    completed = subprocess.run(command, cwd=cwd, env=environment, input=b'', capture_output=True,
        timeout=timeout, creationflags=subprocess.CREATE_NO_WINDOW | subprocess.IDLE_PRIORITY_CLASS)
    Path(str(stem) + '.stdout').write_bytes(completed.stdout)
    Path(str(stem) + '.stderr').write_bytes(completed.stderr)
    if completed.returncode:
        raise ValueError('driver-query-failed:' + str(completed.returncode))
    return completed, {'argv': command, 'cwd': str(cwd), 'returncode': completed.returncode,
                      'stdout_sha256': _sha(completed.stdout), 'stderr_sha256': _sha(completed.stderr)}


def _observe_clangd(command, cwd, environment, timeout, output):
    stderr_path = output / 'clangd.stderr.log'
    stdout_path = output / 'clangd.stdout.log'
    seen, errors, total = threading.Event(), [], 0
    started = time.monotonic()
    with stdout_path.open('wb') as stdout, stderr_path.open('wb') as stderr:
        process = subprocess.Popen(command, cwd=cwd, env=environment, stdin=subprocess.DEVNULL,
            stdout=stdout, stderr=subprocess.PIPE,
            creationflags=subprocess.CREATE_NO_WINDOW | subprocess.IDLE_PRIORITY_CLASS)
        def reader():
            nonlocal total
            try:
                for line in iter(process.stderr.readline, b''):
                    total += len(line)
                    stderr.write(line)
                    if total > 8 * 1024 * 1024:
                        errors.append('clangd-log-limit'); process.kill(); break
                    if b'Compile command from CDB is:' in line:
                        seen.set()
                        process.terminate()
                        break
                    if b'Generic fallback command is:' in line or b'Failed to load compilation database' in line:
                        process.terminate(); break
            except Exception as error:
                errors.append(str(error))
        thread = threading.Thread(target=reader, daemon=True)
        thread.start()
        try:
            process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            errors.append('clangd-query-timeout')
        finally:
            if process.poll() is None:
                process.kill()
            process.wait(timeout=3)
            thread.join(timeout=3)
            process.stderr.close()
        if thread.is_alive() or errors:
            raise ValueError(';'.join(errors) or 'clangd-log-reader-incomplete')
    if not seen.is_set():
        raise ValueError('clangd-effective-command-unavailable')
    return {'argv': command, 'cwd': str(cwd), 'pid': process.pid, 'returncode': process.returncode,
            'seconds': round(time.monotonic() - started, 6), 'terminated_after_command': True,
            'stderr_path': str(stderr_path), 'stderr_sha256': _file_hash(stderr_path),
            'stdout_sha256': _file_hash(stdout_path)}


def observe(entry, clangd_path, query_driver, output_dir, timeout=10, *, launch_cwd=None, environment=None):
    """Return {ok, reason, evidence}; unsupported inputs never grant authority.

    launch_cwd is mandatory and is also used by both direct driver queries.
    environment is the full effective child environment, not an override map.
    Only compiler variables are persisted; private cache/TEMP overrides are not
    part of semantic identity. No process or file outside output_dir is changed.
    """
    started = time.monotonic()
    try:
        if launch_cwd is None:
            raise ValueError('launch-cwd-required')
        if not isinstance(query_driver, str) or not query_driver.strip() or any(c in query_driver for c in '\0\r\n'):
            raise ValueError('query-driver-required')
        if os.name != 'nt':
            raise ValueError('unsupported-query-profile-host')
        if not isinstance(timeout, (int, float)) or not 0 < timeout <= 60:
            raise ValueError('invalid-query-timeout')
        def remaining():
            value = timeout - (time.monotonic() - started)
            if value <= 0:
                raise ValueError('query-profile-timeout')
            return value
        cwd = Path(launch_cwd)
        if not cwd.is_absolute() or not cwd.is_dir():
            raise ValueError('absolute-existing-launch-cwd-required')
        tuple_ = query_tuple(entry)
        native = {key: entry[key] for key in ('directory', 'file', 'arguments')}
        source = (Path(native['directory']) / native['file']).resolve(strict=True)
        source_hash = _file_hash(source)
        tool = Path(clangd_path)
        if not tool.is_absolute() or not tool.is_file():
            raise ValueError('absolute-clangd-required')
        tool = tool.resolve(strict=True)
        tool_hash = _file_hash(tool)
        env = dict(os.environ if environment is None else environment)
        folded = {key.upper(): value for key, value in env.items()}
        semantic_env = {name: folded.get(name.upper()) for name in COMPILER_ENV}
        if any(semantic_env[name] for name in ('CL', '_CL_', 'CCC_OVERRIDE_OPTIONS')):
            raise ValueError('unsupported-environment-argument-injection')
        search_roots, candidates = _driver_candidates(tuple_, tool, cwd, folded)
        output = Path(output_dir).resolve()
        output.mkdir(parents=True, exist_ok=True)
        for name, suffix in (('LOCALAPPDATA', 'localappdata'), ('XDG_CACHE_HOME', 'cache'), ('TEMP', 'tmp'), ('TMP', 'tmp')):
            folder = output / suffix
            folder.mkdir(exist_ok=True)
            env[name] = str(folder)
        version, _ = _run([str(tool), '--version'], cwd, env, remaining(), output / 'clangd-version')
        version_text = version.stdout.decode('utf-8').strip()
        if (not version_text.startswith('clangd version 22.1.5 ') or LLVM_COMMIT not in version_text
                or 'Platform: x86_64-pc-windows-msvc' not in version_text or ctypes.sizeof(ctypes.c_void_p) != 8):
            raise ValueError('unsupported-clangd-extractor-version')
        cdb = output / 'compile_commands.json'
        cdb.write_text(_json([native]), encoding='utf-8')
        command = [str(tool), '--check=' + str(source), '--compile-commands-dir=' + str(output),
                   '--enable-config=false', '--query-driver=' + query_driver, '--background-index=false',
                   '-j=1', '--log=verbose']
        run = _observe_clangd(command, cwd, env, remaining(), output)
        run['cdb_path'] = str(cdb)
        observed = _parse_clangd_output(Path(run['stderr_path']).read_text(encoding='utf-8'), native, cdb)
        driver = Path(observed['driver'])
        if not re.fullmatch(r'clang(?:\+\+)?\.exe', driver.name, re.I):
            raise ValueError('unsupported-observed-driver-name')
        implicit_roots = _implicit_search_roots(driver)
        driver_hash = _file_hash(driver)
        driver_version, _ = _run([str(driver), '--version'], cwd, env, remaining(), output / 'driver-version')
        driver_version_text = driver_version.stdout.decode('utf-8').strip()
        driver_profile = _driver_profile(driver_version_text)
        if driver_profile is None:
            raise ValueError('unsupported-driver-version')
        argv = [str(driver), '-E', '-v', '-x', tuple_['Lang']]
        if not tuple_['StandardIncludes']:
            argv.append('-nostdinc')
        if not tuple_['StandardCXXIncludes']:
            argv.append('-nostdinc++')
        for flag, name in (('--sysroot', 'Sysroot'), ('-isysroot', 'ISysroot'), ('-target', 'Target'), ('--stdlib', 'Stdlib')):
            if tuple_[name]:
                argv += [flag, tuple_[name]]
        queried, query_record = _run(argv + ['-'], cwd, env, remaining(), output / 'driver-query')
        raw_includes, target = _parse_driver_output(queried.stderr.decode('utf-8'))
        builtin, builtin_record = _run([str(driver), '-print-file-name=include'], cwd, env, remaining(), output / 'driver-builtin')
        builtin_path = builtin.stdout.decode('utf-8').strip()
        if not Path(builtin_path).is_absolute() or '\n' in builtin_path:
            raise ValueError('invalid-builtin-query-output')
        filtered = [path for path in raw_includes if path != builtin_path]
        builtin_message = builtin_path + (' excluded' if builtin_path in raw_includes else " not found in driver's response")
        if (observed['includes'] != filtered or observed['raw_includes'] != raw_includes
                or observed['target'] != target or observed['builtin'] != builtin_message):
            raise ValueError('native-driver-query-mismatch')
        if any(_file_hash(path) != expected for path, expected in
               ((tool, tool_hash), (driver, driver_hash), (source, source_hash))):
            raise ValueError('query-input-changed-during-observation')
        evidence = {'schema': 1, 'parser_id': PARSER_ID, 'helper_sha256': _file_hash(__file__),
            'entry': native, 'entry_sha256': _sha(_json(native).encode()), 'source_sha256': source_hash,
            'profile': {'enable_config': False, 'query_driver': query_driver, 'launch_cwd': cwd.as_posix()},
            'compiler_environment': semantic_env, 'environment_sha256': _sha(_json(semantic_env).encode()),
            'driver_search_roots': search_roots, 'driver_candidates': candidates,
            'implicit_search_roots': implicit_roots,
            'tuple': tuple_, 'clangd': {'path': str(tool), 'sha256': tool_hash, 'version': version_text},
            'driver': {'path': str(driver), 'realpath': str(driver.resolve(strict=True)), 'sha256': driver_hash,
                       'version': driver_version_text}, 'driver_profile': driver_profile,
            'query': query_record, 'builtin_query': builtin_record,
            'raw_includes': raw_includes, 'ordered_includes': filtered, 'target': target, 'builtin_path': builtin_path,
            'observed_includes': observed['includes'], 'observed_target': observed['target'], 'clangd_run': run}
        return {'ok': True, 'reason': 'native-query-profile-observed', 'evidence': evidence}
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
        return {'ok': False, 'reason': str(error), 'evidence': None}


def validate(evidence, entry, clangd_path, query_driver, output_dir, timeout=10, *, launch_cwd=None, environment=None):
    """Rediscover through clangd; never trust the previously resolved driver path."""
    if not isinstance(evidence, dict) or evidence.get('schema') != 1 or evidence.get('parser_id') != PARSER_ID:
        return {'ok': False, 'reason': 'invalid-query-evidence', 'evidence': None}
    result = observe(entry, clangd_path, query_driver, output_dir, timeout,
                     launch_cwd=launch_cwd, environment=environment)
    if not result['ok']:
        return result
    keys = ('schema', 'parser_id', 'helper_sha256', 'entry', 'entry_sha256', 'source_sha256',
            'profile', 'compiler_environment', 'environment_sha256', 'driver_search_roots', 'driver_candidates',
            'implicit_search_roots', 'driver_profile',
            'tuple', 'clangd', 'driver', 'raw_includes', 'ordered_includes', 'target',
            'builtin_path', 'observed_includes', 'observed_target', 'query', 'builtin_query')
    if any(evidence.get(key) != result['evidence'][key] for key in keys):
        return {'ok': False, 'reason': 'query-profile-changed', 'evidence': result['evidence']}
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--request', required=True)
    parser.add_argument('--out', required=True)
    options = parser.parse_args()
    request = json.loads(Path(options.request).read_text(encoding='utf-8-sig'))
    function = validate if 'evidence' in request else observe
    result = function(**request)
    Path(options.out).write_text(_json(result), encoding='utf-8')
    raise SystemExit(0 if result['ok'] else 1)
