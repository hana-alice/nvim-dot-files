#!/usr/bin/env python3
"""inject_definitions_to_cdb.py - 把 -include Definitions.h 中的 #define 平铺到 CDB

clangd-indexer 在 disableUnsupportedOptions() 中清掉 -include-pch，
导致 PCH 中编码的 -D 宏（来自 Definitions.<Module>.h）丢失，每个 UE TU 撞 #error。

本脚本扫描 CDB，对每个 entry：
  1. 找它的 -include <Definitions.<Mod>.h>
  2. 解析该 .h 中所有 #define / #undef
  3. 把它们作为显式 -D / -U 平铺到 entry 的 command/arguments
  4. （可选）保留原 -include 以确保 clangd 行为一致

幂等：再次运行不会重复注入，靠特殊 marker -DUE_DEFS_INJECTED=1 检测。

用法:
  python inject_definitions_to_cdb.py path/to/compile_commands.json [--dry-run]

Controlled BackgroundIndex passes --preserve-exact: validate explicit
Definitions/PCH files and preserve their original compiler semantics. The
legacy injection mode only reads explicitly included Definitions headers;
source location never authorizes guessing another build's flags or includes.
"""
import sys
import os
import json
import argparse
import re
import shlex

MARKER = '-DUE_DEFS_INJECTED=1'

RE_DEF = re.compile(r'^\s*#\s*define\s+(\w+)(?:\s+(.+?))?\s*$')
RE_UNDEF = re.compile(r'^\s*#\s*undef\s+(\w+)\s*$')
RE_INCLUDE = re.compile(r'^\s*#\s*include\s+"([^"]+)"\s*$')


def winpath_to_local(p):
    # Only translate D:\ -> /mnt/d/ when running under WSL (where /mnt/c exists).
    # Under native Windows Python, paths stay as-is.
    if sys.platform.startswith('linux') and len(p) >= 2 and p[1] == ':' and os.path.isdir('/mnt/c'):
        return f'/mnt/{p[0].lower()}/{p[2:].replace(chr(92), "/").lstrip("/")}'
    return p


def parse_definitions_h(path, _seen=None):
    """Parse a Definitions.h-style header and return -D/-U flags.

    Recursively follows #include "SharedDefinitions.*.h" / "Definitions.*.h"
    so SharedPCH macros (PLATFORM_WINDOWS, UBT_COMPILED_PLATFORM, WITH_EDITOR,
    UE_EDITOR, etc.) propagate to TUs whose own Definitions.<Mod>.h only does
    `#include "SharedDefinitions.X.Cpp20.h"` plus a few #defines.
    """
    args = []
    if not os.path.isfile(path):
        return args
    if _seen is None:
        _seen = set()
    real = os.path.realpath(path)
    if real in _seen:
        return args
    _seen.add(real)
    base_dir = os.path.dirname(path)
    try:
        with open(path, encoding='utf-8', errors='replace') as f:
            for line in f:
                m = RE_DEF.match(line)
                if m:
                    name, val = m.group(1), m.group(2)
                    if val is None or val.strip() == '':
                        args.append(f'-D{name}=')
                    else:
                        val = re.sub(r'/\*.*?\*/', '', val).strip()
                        val = re.sub(r'//.*$', '', val).strip()
                        args.append(f'-D{name}={val}')
                    continue
                m = RE_UNDEF.match(line)
                if m:
                    args.append(f'-U{m.group(1)}')
                    continue
                m = RE_INCLUDE.match(line)
                if m:
                    inc = m.group(1)
                    # Only follow Definitions/SharedDefinitions siblings —
                    # ignore real engine headers like "CoreMinimal.h".
                    if not (inc.startswith('Definitions.') or inc.startswith('SharedDefinitions.')):
                        continue
                    cand = os.path.join(base_dir, inc)
                    if os.path.isfile(cand):
                        args.extend(parse_definitions_h(cand, _seen))
    except (OSError, UnicodeDecodeError):
        pass
    return args


def find_force_include_definitions(tokens):
    paths = []
    i, n = 0, len(tokens)
    while i < n:
        t = tokens[i]
        # GCC/clang style: -include <path>
        if t == '-include' and i + 1 < n:
            nxt = tokens[i + 1].strip('"')
            if 'Definitions' in nxt and nxt.endswith('.h'):
                paths.append(nxt)
            i += 2
            continue
        # GCC/clang inline: -include=<path>
        if t.startswith('-include='):
            v = t[len('-include='):].strip('"')
            if 'Definitions' in v and v.endswith('.h'):
                paths.append(v)
            i += 1
            continue
        # MSVC / clang-cl: /FI<path> or /FI <path> (and -FI variants)
        # UE generates these for cl-mode CDB entries (the common case on Win).
        if (t.startswith('/FI') or t.startswith('-FI')) and len(t) > 3:
            v = t[3:].strip('"')
            if 'Definitions' in v and v.endswith('.h'):
                paths.append(v)
            i += 1
            continue
        if (t == '/FI' or t == '-FI') and i + 1 < n:
            nxt = tokens[i + 1].strip('"')
            if 'Definitions' in nxt and nxt.endswith('.h'):
                paths.append(nxt)
            i += 2
            continue
        i += 1
    return paths


def quote_for_command(token):
    """Return token quoted for inclusion in a 'command' string. Preserves =val."""
    if any(c in token for c in (' ', '\t', '"')):
        return '"' + token.replace('"', '\\"') + '"'
    return token


def validate_exact_inputs(cdb):
    """Controlled BackgroundIndex consumes the original preprocessor inputs.

    Flattening headers can change conditional definitions and removing PCH can
    remove unrelated compiler state. Validate explicit build products without
    inventing replacements from another target's intermediate directories.
    """
    for entry in cdb:
        tokens = entry.get('arguments')
        if not isinstance(tokens, list):
            print('ERROR: exact input validation requires structured arguments', file=sys.stderr)
            return 1
        paths = find_force_include_definitions(tokens)
        for index, token in enumerate(tokens):
            if token == '-include-pch':
                if index + 1 == len(tokens):
                    print('ERROR: missing -include-pch value', file=sys.stderr)
                    return 1
                paths.append(tokens[index + 1])
            elif token.startswith('-include-pch='):
                paths.append(token[len('-include-pch='):])
        for path in paths:
            local = winpath_to_local(path.strip('"'))
            if not os.path.isabs(local):
                directory = winpath_to_local(entry.get('directory', ''))
                if not os.path.isabs(directory):
                    print('ERROR: explicit build input requires absolute command directory', file=sys.stderr)
                    return 1
                local = os.path.join(directory, local)
            if not os.path.isfile(local):
                print(f'ERROR: missing explicit build input for {entry.get("file")}: {path}', file=sys.stderr)
                return 1
    print(f'Validated exact Definitions/PCH inputs for {len(cdb)} entries; no flags changed', file=sys.stderr)
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('cdb', help='compile_commands.json (Windows or WSL path)')
    ap.add_argument('--dry-run', action='store_true', help='Show what would change without writing')
    ap.add_argument('--preserve-exact', action='store_true',
                    help='Validate explicit Definitions/PCH inputs and retain exact arguments for controlled BackgroundIndex')
    ap.add_argument('--keep-include', action='store_true',
                    help='Keep original -include Definitions.h alongside expanded -D (default: drop them — indexer ignores -include anyway since the bytes are already exploded into -D)')
    args = ap.parse_args()

    cdb_local = winpath_to_local(args.cdb)
    if not os.path.isfile(cdb_local):
        print(f'ERROR: {cdb_local} not found', file=sys.stderr)
        return 1
    with open(cdb_local, encoding='utf-8') as f:
        cdb = json.load(f)

    if args.preserve_exact:
        return validate_exact_inputs(cdb)

    # Quick idempotency check: any entry already has marker?
    sample = cdb[0] if cdb else {}
    sample_cmd = sample.get('command') or ' '.join(sample.get('arguments', []))
    if MARKER in sample_cmd:
        print(f'CDB already injected (marker {MARKER} present). Re-run with --dry-run to inspect.', file=sys.stderr)
        if not args.dry_run:
            return 0

    defs_cache = {}  # path -> [-Dfoo, -Ubar, ...]
    def get_defs(p):
        if p not in defs_cache:
            defs_cache[p] = parse_definitions_h(winpath_to_local(p))
        return defs_cache[p]

    # Legacy indexer injection is limited to explicitly force-included
    # Definitions headers. Never infer other build products or include roots.
    n_entries = len(cdb)
    n_modified = 0
    n_no_def = 0
    n_def_total = 0

    for e in cdb:
        # Get tokens
        if 'arguments' in e:
            tokens = list(e['arguments'])
            mode = 'arguments'
        else:
            cmd = e.get('command', '')
            try:
                tokens = shlex.split(cmd, posix=False)
            except ValueError:
                tokens = cmd.split()
            mode = 'command'

        def_paths = find_force_include_definitions(tokens)
        # CRITICAL: paths in /FI / -include are usually RELATIVE to the
        # entry's `directory` (UBT cwd = Engine/Source). Resolve to absolute
        # here, otherwise parse_definitions_h's `os.path.isfile()` silently
        # fails and returns [] -> 0 -D injected.
        entry_cwd = e.get('directory', '') or ''
        if def_paths and entry_cwd:
            resolved = []
            for p in def_paths:
                pn = p.replace('\\', '/')
                if not os.path.isabs(pn) and not (len(pn) >= 2 and pn[1] == ':'):
                    pn = os.path.normpath(os.path.join(entry_cwd, pn)).replace('\\', '/')
                resolved.append(pn)
            def_paths = resolved
        if not def_paths:
            n_no_def += 1
            continue

        # Gather all defs (later overrides earlier, mirror C preprocessor semantics)
        injected = []
        for p in def_paths:
            injected.extend(get_defs(p))
        if not injected:
            n_no_def += 1
            continue
        n_def_total += len(injected)

        # Build new tokens: drop -include <Defs.h> if not keeping; drop -include-pch (indexer kills it anyway)
        new_tokens = []
        i, ntok = 0, len(tokens)
        while i < ntok:
            t = tokens[i]
            # drop "-include <DefsPath>"
            if t == '-include' and i + 1 < ntok and tokens[i+1].strip('"') in def_paths:
                if args.keep_include:
                    new_tokens.append(t)
                    new_tokens.append(tokens[i+1])
                i += 2
                continue
            if t.startswith('-include=') and t[len('-include='):].strip('"') in def_paths:
                if args.keep_include:
                    new_tokens.append(t)
                i += 1
                continue
            # drop -include-pch <pch>  (indexer disables it; carrying it serializes badly)
            if t == '-include-pch' and i + 1 < ntok:
                i += 2
                continue
            if t.startswith('-include-pch='):
                i += 1
                continue
            new_tokens.append(t)
            i += 1

        # Append marker + injected defs (de-dup, last wins)
        seen_names = set()
        # Also collect existing -D names so we don't trample CDB-original macros
        for t in new_tokens:
            if t.startswith('-D'):
                name = t[2:].split('=', 1)[0]
                seen_names.add(name)
        # Reverse-iterate injected so "last wins" naturally; but UBT order is
        # already last-wins, so we apply in order and let later entries override.
        ordered = []
        emitted_idx = {}
        for tok in injected:
            if tok.startswith('-D'):
                name = tok[2:].split('=', 1)[0]
            elif tok.startswith('-U'):
                name = tok[2:]
            else:
                continue
            if name in seen_names:
                # CDB-original takes precedence over Definitions.h (rare but safe)
                continue
            if name in emitted_idx:
                ordered[emitted_idx[name]] = tok  # later override
            else:
                emitted_idx[name] = len(ordered)
                ordered.append(tok)

        new_tokens.append(MARKER)
        new_tokens.extend(ordered)

        # Write back
        if mode == 'arguments':
            e['arguments'] = new_tokens
        else:
            e['command'] = ' '.join(quote_for_command(t) for t in new_tokens)
        n_modified += 1

    print(f'Entries:      {n_entries}', file=sys.stderr)
    print(f'  modified:   {n_modified}', file=sys.stderr)
    print(f'  no Defs:    {n_no_def}', file=sys.stderr)
    print(f'Distinct Definitions.h files: {len(defs_cache)}', file=sys.stderr)
    print(f'  Total -D/-U injected (sum): {n_def_total}', file=sys.stderr)
    print(f'  Avg per entry:              {n_def_total / max(1, n_modified):.1f}', file=sys.stderr)

    if args.dry_run:
        print('Dry-run, not writing.', file=sys.stderr)
        return 0

    # Backup once
    bak = cdb_local + '.pre-defs-inject.bak'
    if not os.path.exists(bak):
        import shutil
        shutil.copy2(cdb_local, bak)
        print(f'Backup: {bak}', file=sys.stderr)

    with open(cdb_local, 'w', encoding='utf-8') as f:
        json.dump(cdb, f, indent=2 if len(cdb) < 200 else None)
    print(f'Wrote: {cdb_local}', file=sys.stderr)
    return 0


if __name__ == '__main__':
    sys.exit(main())
