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
"""
import sys
import os
import json
import argparse
import re
import shlex
from pathlib import Path

MARKER = '-DUE_DEFS_INJECTED=1'

RE_DEF = re.compile(r'^\s*#\s*define\s+(\w+)(?:\s+(.+?))?\s*$')
RE_UNDEF = re.compile(r'^\s*#\s*undef\s+(\w+)\s*$')


def winpath_to_local(p):
    # Only translate D:\ -> /mnt/d/ when running under WSL (where /mnt/c exists).
    # Under native Windows Python, paths stay as-is.
    if len(p) >= 2 and p[1] == ':' and os.path.isdir('/mnt/c'):
        return f'/mnt/{p[0].lower()}/{p[2:].replace(chr(92), "/").lstrip("/")}'
    return p


def parse_definitions_h(path):
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
                        val = re.sub(r'/\*.*?\*/', '', val).strip()
                        val = re.sub(r'//.*$', '', val).strip()
                        args.append(f'-D{name}={val}' if val else f'-D{name}')
                    continue
                m = RE_UNDEF.match(line)
                if m:
                    args.append(f'-U{m.group(1)}')
    except (OSError, UnicodeDecodeError):
        pass
    return args


def find_force_include_definitions(tokens):
    paths = []
    i, n = 0, len(tokens)
    while i < n:
        t = tokens[i]
        if t == '-include' and i + 1 < n:
            nxt = tokens[i + 1].strip('"')
            if 'Definitions' in nxt and nxt.endswith('.h'):
                paths.append(nxt)
            i += 2
            continue
        if t.startswith('-include='):
            v = t[len('-include='):].strip('"')
            if 'Definitions' in v and v.endswith('.h'):
                paths.append(v)
        i += 1
    return paths


# Match SharedPCH.<Module>.Cpp20.pch  or  PCH.<Module>.pch  or  ExpandedPCH.<Module>.pch
RE_PCH_MODULE = re.compile(r'(?:^|[/\\])(?:Shared|Expanded)?PCH\.([A-Za-z0-9_]+?)(?:\.RTTI)?(?:\.Cpp\d+)?\.pch$', re.IGNORECASE)


def find_pch_module_name(tokens):
    """From -include-pch X.pch, extract module name (e.g. SharedPCH.Engine.Cpp20.pch -> Engine)."""
    i, n = 0, len(tokens)
    while i < n:
        t = tokens[i]
        if t == '-include-pch' and i + 1 < n:
            m = RE_PCH_MODULE.search(tokens[i + 1].strip('"'))
            if m:
                return m.group(1)
            i += 2
            continue
        if t.startswith('-include-pch='):
            m = RE_PCH_MODULE.search(t[len('-include-pch='):].strip('"'))
            if m:
                return m.group(1)
        i += 1
    return None


def find_pch_definitions_h(subset_def_path, pch_module):
    """Given a subset Definitions.<X>.h path AND the PCH module name, locate the
    corresponding 'full' Definitions.h that the PCH would have included.

    UE layout: <Intermediate>/<Target>/Development/<PchModule>/Definitions.h
    We derive that root from the subset's path."""
    if not pch_module:
        return None
    # subset is like .../Development/<SomeModule>/Definitions.<X>.h
    # full   is at .../Development/<PchModule>/Definitions.h
    parts = subset_def_path.replace('\\', '/').split('/')
    try:
        idx = len(parts) - 1 - parts[::-1].index('Development')
    except ValueError:
        return None
    full_path = '/'.join(parts[:idx + 1] + [pch_module, 'Definitions.h'])
    return full_path


def find_uht_include_dirs(any_def_path):
    """UE puts generated reflection headers at <Intermediate>/Build/<Plat>/<Target>/Inc/<Module>/UHT/.
    Indexer cannot find them because CDB only has -I.../Inc (one level too high).
    Walk the Inc tree once and return [-Idir, ...] for every UHT directory.

    `any_def_path` is one Definitions.h path used to locate the project root."""
    parts = any_def_path.replace('\\', '/').split('/')
    try:
        idx = parts.index('Intermediate')
    except ValueError:
        return []
    # .../Engine/Intermediate/Build/Win64/x64/UnrealEditor/Development/Mod/Definitions.h
    # we want    .../Engine/Intermediate/Build/Win64/UnrealEditor/Inc/<Mod>/UHT
    base = '/'.join(parts[:idx + 1])  # .../Engine/Intermediate
    # Most layouts: Build/<Plat>/<Target>/Inc/<Module>/UHT
    # Build/<Plat> + UnrealEditor (Target) + Inc + */UHT
    candidates = []
    inc_root_local = winpath_to_local(base + '/Build/Win64/UnrealEditor/Inc')
    if not os.path.isdir(inc_root_local):
        return []
    inc_root_win = base + '/Build/Win64/UnrealEditor/Inc'
    for entry in os.listdir(inc_root_local):
        uht = os.path.join(inc_root_local, entry, 'UHT')
        if os.path.isdir(uht):
            # Use Win-style for CDB consistency
            candidates.append(f'-I{inc_root_win}/{entry}/UHT')
    return candidates


def find_module_publics(any_cpp_path):
    """Walk Source/{Runtime,Editor,Developer}/<Module>/{Public,Internal,Classes}
    and return [-Idir,...] for every such module dir found.

    UE compiles using PCH which inlines these paths; clangd-indexer has no PCH
    so it needs them as explicit -I. Without these, transitive #include chains
    like `UnrealClient.h -> Elements/Framework/TypedElementListFwd.h` fail."""
    parts = any_cpp_path.replace('\\', '/').split('/')
    try:
        idx = parts.index('Source')
    except ValueError:
        return []
    src_root = '/'.join(parts[:idx + 1])
    src_local = winpath_to_local(src_root)
    if not os.path.isdir(src_local):
        return []
    dirs = []
    for sub in ('Runtime', 'Editor', 'Developer'):
        sub_dir = f'{src_local}/{sub}'
        if not os.path.isdir(sub_dir):
            continue
        try:
            for mod in os.listdir(sub_dir):
                mod_dir = f'{sub_dir}/{mod}'
                if not os.path.isdir(mod_dir):
                    continue
                for kind in ('Public', 'Internal', 'Classes'):
                    kdir = f'{mod_dir}/{kind}'
                    if os.path.isdir(kdir):
                        # Emit Windows-style path matching CDB convention
                        win_path = f'{src_root}/{sub}/{mod}/{kind}'
                        dirs.append(f'-I{win_path}')
        except (OSError, PermissionError):
            continue
    return dirs



def quote_for_command(token):
    """Return token quoted for inclusion in a 'command' string. Preserves =val."""
    if any(c in token for c in (' ', '\t', '"')):
        return '"' + token.replace('"', '\\"') + '"'
    return token


def get_module_from_filepath(file_path):
    """Extract UE module name from a cpp file path.
    .../Source/.../<Module>/Public|Private|Classes|Internal/...cpp"""
    parts = file_path.replace('\\', '/').split('/')
    for i, p in enumerate(parts):
        if p in ('Private', 'Public', 'Classes', 'Internal') and i > 0:
            return parts[i - 1]
    return None


# Cache the project's Intermediate/Build/.../Development root once
_dev_root_cache = [None]
def find_dev_root(any_cpp_path):
    """Locate <Intermediate>/Build/<Plat>/<Target>/Development by scanning sibling dirs."""
    if _dev_root_cache[0] is not None:
        return _dev_root_cache[0]
    parts = any_cpp_path.replace('\\', '/').split('/')
    # Find 'Engine' or any 'Source' parent
    for i, p in enumerate(parts):
        if p == 'Source':
            engine_root = '/'.join(parts[:i])  # .../Engine
            # Try common layouts
            candidates = [
                f'{engine_root}/Intermediate/Build/Win64/x64/UnrealEditor/Development',
                f'{engine_root}/Intermediate/Build/Win64/UnrealEditor/Development',
            ]
            for c in candidates:
                if os.path.isdir(winpath_to_local(c)):
                    _dev_root_cache[0] = c
                    return c
            break
    _dev_root_cache[0] = ''
    return ''


def infer_definitions_paths_from_module(file_path, dev_root):
    """When CDB lacks -include Definitions.X.h, try to locate the Definitions.h
    files based on file path -> module name -> Intermediate layout."""
    if not dev_root:
        return []
    mod = get_module_from_filepath(file_path)
    if not mod:
        return []
    paths = []
    # Subset Definitions.<Module>.h (per-module slim defines)
    subset = f'{dev_root}/{mod}/Definitions.{mod}.h'
    if os.path.isfile(winpath_to_local(subset)):
        paths.append(subset)
    # Plain Definitions.h (full set, for PCH-source modules)
    full = f'{dev_root}/{mod}/Definitions.h'
    if os.path.isfile(winpath_to_local(full)):
        paths.append(full)
    return paths


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('cdb', help='compile_commands.json (Windows or WSL path)')
    ap.add_argument('--dry-run', action='store_true', help='Show what would change without writing')
    ap.add_argument('--keep-include', action='store_true',
                    help='Keep original -include Definitions.h alongside expanded -D (default: drop them — indexer ignores -include anyway since the bytes are already exploded into -D)')
    args = ap.parse_args()

    cdb_local = winpath_to_local(args.cdb)
    if not os.path.isfile(cdb_local):
        print(f'ERROR: {cdb_local} not found', file=sys.stderr)
        return 1
    with open(cdb_local, encoding='utf-8') as f:
        cdb = json.load(f)

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

    # Compute UHT -I dirs ONCE per CDB (not per entry; they're project-wide).
    # Try first from CDB's -include Definitions; fall back to inferring dev_root
    # from any cpp file path (CDBs from new UBT may not embed -include).
    uht_dirs = []
    for e in cdb:
        tokens = list(e['arguments']) if 'arguments' in e else shlex.split(e.get('command', ''), posix=False)
        defs = find_force_include_definitions(tokens)
        if defs:
            uht_dirs = find_uht_include_dirs(defs[0])
            break
    if not uht_dirs and cdb:
        # Fallback: derive from any cpp's path -> Engine root -> Intermediate
        any_cpp = cdb[0].get('file', '')
        dev_root = find_dev_root(any_cpp)
        if dev_root:
            # find_uht_include_dirs expects a Definitions.h path inside Intermediate;
            # fake one by appending /<anything>/Definitions.h to dev_root
            fake_def = f'{dev_root}/Core/Definitions.h'
            uht_dirs = find_uht_include_dirs(fake_def)
    print(f'UHT include dirs to inject: {len(uht_dirs)}', file=sys.stderr)
    if uht_dirs:
        print(f'  sample: {uht_dirs[0]}', file=sys.stderr)

    # Module Public/Internal/Classes -I (safety net for transitive #include chains
    # that UE compiles via PCH; clangd-indexer has no PCH).
    module_dirs = []
    if cdb:
        module_dirs = find_module_publics(cdb[0].get('file', ''))
    print(f'Module Public/Internal/Classes -I: {len(module_dirs)}', file=sys.stderr)
    if module_dirs:
        print(f'  sample: {module_dirs[0]}', file=sys.stderr)

    n_entries = len(cdb)
    n_modified = 0
    n_no_def = 0
    n_def_total = 0

    # Cache the dev_root for module-based Definitions.h fallback
    dev_root_for_fallback = ''
    if cdb:
        dev_root_for_fallback = find_dev_root(cdb[0].get('file', ''))

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
        # FALLBACK: if CDB doesn't carry -include Definitions (newer UBT
        # GenerateClangDatabase omits these), infer them from the cpp file path.
        if not def_paths and dev_root_for_fallback:
            def_paths = infer_definitions_paths_from_module(e.get('file', ''), dev_root_for_fallback)
        # Also locate the PCH-module's full Definitions.h (contains UE_BUILD_*,
        # WITH_EDITOR, UBT_COMPILED_PLATFORM, etc that the subset .h omits).
        pch_module = find_pch_module_name(tokens)
        if pch_module and def_paths:
            full_def = find_pch_definitions_h(def_paths[0], pch_module)
            if full_def and os.path.isfile(winpath_to_local(full_def)) and full_def not in def_paths:
                def_paths.insert(0, full_def)  # full first → subset overrides

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
        # Inject UHT include dirs so .generated.h headers resolve
        existing_dirs = {t for t in new_tokens if t.startswith('-I')}
        for d in uht_dirs:
            if d not in existing_dirs:
                new_tokens.append(d)
                existing_dirs.add(d)
        # Inject module Public/Internal/Classes -I as safety net
        for d in module_dirs:
            if d not in existing_dirs:
                new_tokens.append(d)
                existing_dirs.add(d)
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
