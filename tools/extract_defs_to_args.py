#!/usr/bin/env python3
"""extract_defs_to_args.py - 把 -include Definitions.<Mod>.h 中的 #define 转成 -D / -U 参数

clangd-indexer 内部调用 Compiler.cpp::disableUnsupportedOptions() 会把
-include-pch 等清理掉，导致 PCH 中的 -D 宏（UE_BUILD_DEVELOPMENT, WITH_EDITOR ...）
全部丢失，每个 UE TU 撞 Build.h:47 #error。

UBT 真实 -D 来源是 PCH 内嵌的 Definitions.<Module>.h。我们不依赖 PCH，
直接把这个 .h 解析成 -D 数组，注入 CDB 里每个对应模块的 entry。

用法（先验证）:
  python extract_defs_to_args.py path/to/Definitions.h
       -> 打印解析出的 -D / -U args，逐行
"""
import sys
import re
import json
import argparse
import os
from pathlib import Path

# Match #define NAME [VALUE]    or    #undef NAME
RE_DEF = re.compile(r'^\s*#\s*define\s+(\w+)(?:\s+(.+?))?\s*$')
RE_UNDEF = re.compile(r'^\s*#\s*undef\s+(\w+)\s*$')


def parse_definitions_h(path):
    """Parse a Definitions.<Module>.h and return list of -D/-U args (strings)."""
    args = []
    if not os.path.isfile(path):
        return args
    try:
        with open(path, encoding='utf-8', errors='replace') as f:
            for line in f:
                m = RE_DEF.match(line)
                if m:
                    name, val = m.group(1), m.group(2)
                    if val is None or val.strip() == '':
                        args.append(f'-D{name}')
                    else:
                        # Trim trailing C-style comment
                        val = re.sub(r'/\*.*?\*/', '', val).strip()
                        val = re.sub(r'//.*$', '', val).strip()
                        if val:
                            args.append(f'-D{name}={val}')
                        else:
                            args.append(f'-D{name}')
                    continue
                m = RE_UNDEF.match(line)
                if m:
                    args.append(f'-U{m.group(1)}')
    except (OSError, UnicodeDecodeError) as e:
        print(f'WARN: cannot read {path}: {e}', file=sys.stderr)
    return args


def cmd_or_args(entry):
    """Get tokens from CDB entry whether it uses 'command' or 'arguments'."""
    if 'arguments' in entry:
        return list(entry['arguments'])
    cmd = entry.get('command', '')
    # Naive split that respects quotes
    import shlex
    try:
        return shlex.split(cmd, posix=False)
    except ValueError:
        return cmd.split()


def find_force_include_definitions(tokens):
    """Locate '-include <path-to-Definitions*.h>' in token stream.
    Returns list of paths (Win-style)."""
    paths = []
    i = 0
    n = len(tokens)
    while i < n:
        t = tokens[i]
        if t == '-include' and i + 1 < n:
            nxt = tokens[i + 1]
            if 'Definitions' in nxt and nxt.endswith('.h'):
                paths.append(nxt.strip('"'))
            i += 2
            continue
        if t.startswith('-include='):
            v = t[len('-include='):].strip('"')
            if 'Definitions' in v and v.endswith('.h'):
                paths.append(v)
        i += 1
    return paths


def winpath_to_local(p):
    """Convert D:/foo or D:\\foo to /mnt/d/foo for WSL filesystem reads."""
    if len(p) >= 2 and p[1] == ':':
        drive = p[0].lower()
        rest = p[2:].replace('\\', '/').lstrip('/')
        return f'/mnt/{drive}/{rest}'
    return p


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('definitions_h', help='Path to a Definitions.<Module>.h, OR a compile_commands.json')
    ap.add_argument('--show-cdb-entry', help='If first arg is CDB, print extracted args for entry matching this filename substring')
    args = ap.parse_args()

    p = args.definitions_h
    if p.endswith('.json'):
        cdb = json.load(open(winpath_to_local(p), encoding='utf-8'))
        print(f'CDB entries: {len(cdb)}', file=sys.stderr)
        # Show stats: how many entries reference Definitions, how many .h files exist
        seen = {}
        missing = 0
        for e in cdb:
            tokens = cmd_or_args(e)
            for path in find_force_include_definitions(tokens):
                local = winpath_to_local(path)
                if local in seen:
                    continue
                if os.path.isfile(local):
                    seen[local] = parse_definitions_h(local)
                else:
                    missing += 1
                    seen[local] = None
        ok = sum(1 for v in seen.values() if v is not None)
        print(f'Distinct Definitions.h files: {len(seen)}', file=sys.stderr)
        print(f'  exist on disk (parsed):  {ok}', file=sys.stderr)
        print(f'  missing on disk:         {missing}', file=sys.stderr)
        # Print one sample
        for path, defs in seen.items():
            if defs:
                print(f'\n--- sample: {path} ({len(defs)} defs) ---', file=sys.stderr)
                for d in defs[:25]:
                    print(f'  {d}', file=sys.stderr)
                break
        if args.show_cdb_entry:
            for e in cdb:
                if args.show_cdb_entry in e.get('file', ''):
                    tokens = cmd_or_args(e)
                    paths = find_force_include_definitions(tokens)
                    print(f'\n=== CDB entry: {e["file"]} ===')
                    print(f'  -include Definitions paths: {paths}')
                    for path in paths:
                        local = winpath_to_local(path)
                        defs = parse_definitions_h(local)
                        print(f'  -> {local}: {len(defs)} defs extracted')
                        for d in defs[:30]:
                            print(f'      {d}')
                    break
    else:
        defs = parse_definitions_h(winpath_to_local(p))
        print(f'{len(defs)} -D/-U args extracted from {p}', file=sys.stderr)
        for d in defs:
            print(d)


if __name__ == '__main__':
    sys.exit(main())
