"""Keep two LLVM 22.1 warnings visible for Android Clang 9.0.9 C++17 inputs.

See the sibling Lua registry entry. Never edit build flags, source or installed
toolchains; only the transaction's derived editor commands are transformed.
"""
import argparse
import collections
import json
from pathlib import Path
import re
import subprocess
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[3] / 'tools'))
from build_hot_super_unity_cdb import write_if_changed
from cdb_argv import normalize_cdb
from clangd_diagnostic_compat import probe_clangd, supported_version

GROUPS = ('vla-cxx-extension', 'unused-but-set-variable')
FLAGS = ['-Wno-error=' + group for group in GROUPS]
# DiagnosticGroups.td: unused-variable is a sibling, not a parent, of the new group.
PARENTS = (('vla', 'vla-extension', 'pedantic'), ('unused',))


def compile_options(args):
    result, index = {}, 1
    names = {'-target': 'target', '--target': 'target', '-std': 'std', '-x': 'language',
             '--gcc-toolchain': 'toolchain', '--sysroot': 'sysroot'}
    while index < len(args) and args[index] != '--':
        arg = args[index]
        if arg in names:
            if index + 1 == len(args):
                return {}
            result[names[arg]] = args[index + 1]
            index += 2
            continue
        for name, key in names.items():
            if arg.startswith(name + '='):
                result[key] = arg[len(name) + 1:]
        if arg.startswith('-x') and len(arg) > 2:
            result['language'] = arg[2:]
        index += 1
    return result


def transform_entry(entry, clangd_version, build_version):
    if not supported_version(clangd_version):
        return entry, 'unsupported-clangd-version'
    if not ('Android' in build_version and re.search(r'\bclang version 9\.0\.9\b', build_version)):
        return entry, 'unsupported-build-compiler'
    normalized = normalize_cdb([entry])[0][0]
    args = normalized['arguments']
    end = args.index('--') if '--' in args else len(args)
    options = args[1:end]
    if any(arg.startswith(('@', '-Wp,')) or arg in ('-Xclang', '-Xpreprocessor') for arg in options):
        return entry, 'unsupported-indirect-options'
    values = compile_options(args)
    if not re.fullmatch(r'[A-Za-z0-9_]+(?:-[A-Za-z0-9_]+)*-linux-android(?:eabi)?\d*', values.get('target', '')):
        return entry, 'unsupported-target'
    if values.get('std') != 'c++17':
        return entry, 'unsupported-language-standard'
    language = values.get('language')
    if language not in (None, 'none', 'c++', 'c++-header'):
        return entry, 'unsupported-language'
    if language in (None, 'none') and Path(entry['file']).suffix.lower() not in ('.cc', '.cpp', '.cxx', '.c++', '.hpp', '.hh', '.hxx'):
        return entry, 'unproven-c++-language'
    if '-w' in options or '-Wno-everything' in options:
        return entry, 'warnings-disabled'
    global_error = False
    for arg in options:
        if arg in ('-Werror', '-Wno-error'):
            global_error = arg == '-Werror'
    if not global_error:
        return entry, 'no-global-werror'
    additions = []
    for group, parents, flag in zip(GROUPS, PARENTS, FLAGS):
        controls = {prefix + name for name in (group, *parents) for prefix in
                    ('-W', '-Wno-', '-Werror=', '-Wno-error=', '-Wfatal-errors=', '-Wno-fatal-errors=')}
        if group == 'vla-cxx-extension':
            controls.update(('-pedantic', '-pedantic-errors'))
        if not any(arg in controls for arg in options):
            additions.append(flag)
    if not additions:
        return entry, 'explicit-diagnostic-control'
    normalized['arguments'] = [args[0], *additions, *args[1:]]
    return normalized, 'added'


def build_compiler(entry):
    args = entry['arguments']
    options = compile_options(args)
    root = Path(options.get('toolchain', ''))
    sysroot = Path(options.get('sysroot', ''))
    driver = Path(args[0])
    if not all(path.is_absolute() for path in (root, sysroot, driver)):
        return None
    if (sysroot.resolve() != (root / 'sysroot').resolve()
            or driver.resolve().parent != (root / 'bin').resolve()
            or driver.name not in ('clang++', 'clang++.exe') or not driver.is_file()):
        return None
    return driver.resolve()


def apply_policy(cdb_path, clangd_version):
    entries = json.loads(Path(cdb_path).read_text(encoding='utf-8-sig'))
    if not isinstance(entries, list):
        raise ValueError('compilation database must be an array')
    if not supported_version(clangd_version):
        return {'changed': False, 'added': 0, 'entries': len(entries), 'outcomes': {'unsupported-clangd-version': len(entries)}}
    versions, outcomes, output = {}, collections.Counter(), []
    for entry in entries:
        structured = normalize_cdb([entry])[0][0]
        driver = build_compiler(structured)
        if driver is None:
            output.append(entry)
            outcomes['unproven-build-compiler'] += 1
            continue
        if driver not in versions:
            try:
                result = subprocess.run([str(driver), '--version'], capture_output=True, text=True, timeout=5,
                    creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
                versions[driver] = result.stdout + result.stderr if result.returncode == 0 else ''
            except (OSError, subprocess.TimeoutExpired):
                versions[driver] = ''
        transformed, reason = transform_entry(entry, clangd_version, versions[driver])
        output.append(transformed)
        outcomes[reason] += 1
    changed = bool(outcomes['added']) and write_if_changed(str(cdb_path), json.dumps(output, ensure_ascii=False))
    return {'changed': changed, 'added': outcomes['added'], 'entries': len(entries),
            'outcomes': dict(outcomes), 'build_compilers': {str(path): version.strip() for path, version in versions.items()}}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('cdb')
    parser.add_argument('--clangd', default='')
    args = parser.parse_args()
    version, reason = probe_clangd(args.clangd)
    result = {'changed': False, 'added': 0, 'reason': reason} if reason else apply_policy(args.cdb, version)
    print('legacy Android diagnostic compatibility: ' + json.dumps(result, ensure_ascii=True))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
