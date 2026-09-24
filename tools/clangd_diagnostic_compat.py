#!/usr/bin/env python3
"""Apply the declared LLVM 22.1 Android C++17 diagnostic compatibility policy.

Runs on the prepare transaction's working CDB, between receipt begin and seal.
It never changes build inputs, guesses another clangd, or disables a diagnostic.
"""
import argparse
import collections
import json
from pathlib import Path
import re
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from cdb_argv import normalize_cdb
from build_hot_super_unity_cdb import write_if_changed

GROUP = 'missing-template-arg-list-after-template-kw'
FLAG = '-Wno-error=' + GROUP


def supported_version(output):
    version = re.search(r'\bclangd version (\d+)\.(\d+)\.(\d+)\b', output)
    return bool(version and version.group(1, 2) == ('22', '1'))


def probe_clangd(path):
    """Probe only the selected absolute executable; never search PATH here."""
    if not path or not Path(path).is_absolute() or not Path(path).is_file():
        return '', 'selected-clangd-unavailable'
    try:
        result = subprocess.run([path, '--version'], capture_output=True, text=True,
                                timeout=5, check=False,
                                creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
    except (OSError, subprocess.TimeoutExpired) as error:
        return '', 'selected-clangd-probe-failed: ' + str(error)
    output = result.stdout + result.stderr
    if result.returncode:
        return output, 'selected-clangd-probe-failed'
    return output, None if supported_version(output) else 'unsupported-clangd-version'


def transform_entry(entry):
    structured = normalize_cdb([entry])[0][0]
    args = structured['arguments']
    if any(not isinstance(arg, str) or '\0' in arg for arg in args):
        raise ValueError('compile arguments must be NUL-free strings')
    end = args.index('--') if '--' in args else len(args)
    options = args[1:end]
    controls = {'-W' + GROUP, '-Wno-' + GROUP}
    controls.update('-W' + prefix + '=' + GROUP
                    for prefix in ('error', 'no-error', 'fatal-errors', 'no-fatal-errors'))
    if any(arg in controls for arg in options):
        return entry, 'explicit-diagnostic-control'
    if '-w' in options or '-Wno-everything' in options:
        return entry, 'warnings-disabled'
    target, standard, language = None, None, None
    index = 1
    while index < end:
        arg = args[index]
        if arg in ('--target', '-target', '-std', '-x'):
            if index + 1 >= end:
                return entry, 'incomplete-compile-option'
            value = args[index + 1]
            if arg in ('--target', '-target'):
                target = value
            elif arg == '-std':
                standard = value
            else:
                language = value
            index += 2
            continue
        if arg.startswith(('--target=', '-target=')):
            target = arg.split('=', 1)[1]
        elif arg.startswith('-std='):
            standard = arg.split('=', 1)[1]
        elif arg.startswith('-x') and len(arg) > 2:
            language = arg[2:]
        index += 1
    if not target or not re.fullmatch(r'[A-Za-z0-9_]+(?:-[A-Za-z0-9_]+)*-linux-android(?:eabi)?\d*', target):
        return entry, 'unsupported-target'
    if standard != 'c++17':
        return entry, 'unsupported-language-standard'
    if language not in (None, 'none', 'c++', 'c++-header'):
        return entry, 'unsupported-language'
    if language in (None, 'none') and Path(entry['file']).suffix.lower() not in ('.cc', '.cpp', '.cxx', '.c++', '.hpp', '.hh', '.hxx'):
        return entry, 'unproven-c++-language'

    # Do not infer source operands from their spelling: the same path can be an
    # -include operand. This position also preserves consumers' source-last form.
    # Explicit group controls were excluded above; global -Werror cannot override
    # this diagnostic's NoWarningAsError mapping, regardless of option order.
    structured['arguments'] = [args[0], FLAG, *args[1:]]
    return structured, 'added'


def apply_policy(cdb_path, version_output):
    """Pure version admission plus content-stable publication; no native probe."""
    if not supported_version(version_output):
        return {'changed': False, 'reason': 'unsupported-clangd-version', 'added': 0}
    with open(cdb_path, encoding='utf-8-sig') as stream:
        entries = json.load(stream)
    if not isinstance(entries, list):
        raise ValueError('compilation database must be an array')
    counts = collections.Counter()
    transformed = []
    for entry in entries:
        value, reason = transform_entry(entry)
        transformed.append(value)
        counts[reason] += 1
    changed = False
    if counts['added']:
        changed = write_if_changed(str(cdb_path), json.dumps(transformed, ensure_ascii=False))
    return {'changed': changed, 'added': counts['added'], 'entries': len(entries),
            'outcomes': dict(counts)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('cdb')
    parser.add_argument('--clangd', default='', help='actual selected absolute clangd executable')
    args = parser.parse_args()
    version, reason = probe_clangd(args.clangd)
    result = ({'changed': False, 'added': 0, 'reason': reason} if reason
              else apply_policy(args.cdb, version))
    result.update(clangd=args.clangd, clangd_version=version.strip(), flag=FLAG)
    print('clangd diagnostic compatibility: ' + json.dumps(result, ensure_ascii=True))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
