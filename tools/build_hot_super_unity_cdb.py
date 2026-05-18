#!/usr/bin/env python3
"""build_hot_super_unity_cdb.py — super-unity for per-file hot subset CDBs.

Companion to build_super_unity_cdb.py. The full pipeline's super-unity input
is UE's unity-build products (Module.<Mod>.cpp). The hot/current subset is
plain per-file .cpp (e.g. ApplicationCore.cpp). This script groups per-file
entries by (SharedPCH, module) and merges each group into a SuperUnity.<pch>.<chunk>.cpp
that #include's its member .cpp files, with API-macro re-injection per member.

Output: a super-only CDB whose entries reference synthesised SuperUnity.*.cpp
files in <stage_dir>/super_unity_cpps/. Fed to clangd-indexer instead of
the original per-file hot.json, this collapses 2985 TUs into ~15 super-TUs
(200× preamble share for SharedPCH.Engine etc), with the same symbol
coverage.

INPUT  : per-file CDB (after prebuild_pch_v2 / resolve_cdb_paths /
         unify_include_dirs / prune_include_dirs), already inject'd with -D
         from Definitions.<Mod>.h by inject_definitions_to_cdb.py.
OUTPUT : <out_cdb> super-only CDB.

USAGE  : python build_hot_super_unity_cdb.py <per_file_cdb> <out_cdb>
                  [--max-mods N] [--super-dir <dir>]

DESIGN NOTES
  - module name comes from the file path .../Source/<Group>/<Module>/(Private|Public|Classes)/...
  - SharedPCH name comes from scanning each entry's args for either:
        '-include <...SharedPCH.X.h>'      (A-fix post-2026-05-18 form)
        '-include-pch <...SharedPCH.X.pch>' (legacy / parallel form)
    if neither is present, the TU is bucketed as 'NONE' and gets its own
    no-PCH chunk (rare in hot subset post A-fix; we still keep them since
    they parse fine).
  - chunk size is the number of MEMBER .cpps per super-TU (default 80).
    Engine has 1209 .cpps in hot → 1209/80 = ~16 chunks for that PCH bucket.
    Smaller chunks = less RAM per indexer process but more preamble work.
  - per-member API macros: read Definitions.<Mod>.h once per distinct
    module across the whole CDB, cache, re-emit at top of each member's
    #include block in the super-TU. This is the same scheme the full
    pipeline already uses.

PITFALLS HANDLED
  - args glued vs split form (-IPATH vs -I PATH, etc.): union must use a
    single walker. Same logic as build_super_unity_cdb.py, deduplicated.
  - module discovery from per-file paths must tolerate edge cases:
        .../Source/Runtime/<Mod>/Private/...    (most common)
        .../Source/Runtime/<Mod>/Public/...     (Public/Classes counted as same module)
        .../Source/Developer/<Mod>/Private/...
        .../Source/Editor/<Mod>/Private/...
        .../Plugins/.../Source/<Mod>/Private/...
    All resolve to <Mod> (the directory containing Private/Public/Classes).
"""

import argparse
import json
import os
import re
import sys
from collections import defaultdict, OrderedDict

RE_API_DEF = re.compile(
    r'^\s*#\s*define\s+(\w+_API|\w+_NON_ATTRIBUTED_API)\s+(DLLEXPORT|DLLIMPORT)\s*$'
)
# Match SharedPCH.X.h, SharedPCH.X.Y.h, PCH.X.h, PCH.X.Y.h forms in -include
# or -include-pch arguments. We treat per-module PCH.<Mod>.h as its own bucket
# (one Module = one bucket = no preamble share inside a module, only across
# its TUs). SharedPCH.<Variant> covers the cross-module preamble share that
# gives the bulk of the speed-up.
RE_PCH_HEADER = re.compile(r'(SharedPCH|PCH)\.([\w.]+?)\.h\b', re.IGNORECASE)
RE_PCH_BINARY = re.compile(r'(SharedPCH|PCH)\.([\w.]+?)\.pch\b', re.IGNORECASE)


# ---- path helpers ----------------------------------------------------------

def winpath_local(p):
    """Translate D:\foo or D:/foo into /mnt/d/foo when running under WSL."""
    if len(p) >= 2 and p[1] == ':' and os.path.isdir('/mnt/c'):
        return f'/mnt/{p[0].lower()}/' + p[2:].replace('\\', '/').lstrip('/')
    return p


def winpath_from_local(p):
    """/mnt/d/foo -> D:/foo. Identity for native Windows paths."""
    if p.startswith('/mnt/') and len(p) > 6 and p[6] == '/':
        drive = p[5].upper()
        return f'{drive}:{p[6:]}'
    return p


# ---- module discovery ------------------------------------------------------

# Common UE source layout markers; the module name is the directory IMMEDIATELY
# above one of these subdirectories.
_MODULE_MARKER_DIRS = ('Private', 'Public', 'Classes', 'Internal')


def get_module_from_perfile(file_path):
    """For .../Source/.../<Module>/<Private|Public|Classes|Internal>/...
    return <Module>. Returns None if no marker found.
    """
    fp = file_path.replace('\\', '/')
    parts = fp.split('/')
    for i, seg in enumerate(parts):
        if seg in _MODULE_MARKER_DIRS and i >= 1:
            return parts[i - 1]
    return None


# ---- PCH discovery (from args, no rsp lookup) ------------------------------

def get_pch_key_from_args(args):
    """Walk an entry's arguments, return a PCH bucket key like
    'SharedPCH.Engine.ShadowErrors' / 'PCH.CoreUObject' / 'NONE'. We keep
    the full prefix (SharedPCH vs PCH) so per-module PCH buckets stay
    isolated from cross-module SharedPCH ones — they have wildly different
    include sets.
    """
    for i, a in enumerate(args):
        if a == '-include' and i + 1 < len(args):
            m = RE_PCH_HEADER.search(args[i + 1])
            if m:
                return f'{m.group(1)}.{m.group(2)}'
        if a == '-include-pch' and i + 1 < len(args):
            m = RE_PCH_BINARY.search(args[i + 1])
            if m:
                return f'{m.group(1)}.{m.group(2)}'
        # glued: -include=path or /FIpath (very rare in clang form post-prep)
        if a.startswith('-include'):
            m = RE_PCH_HEADER.search(a) or RE_PCH_BINARY.search(a)
            if m:
                return f'{m.group(1)}.{m.group(2)}'
    return 'NONE'


# ---- API-macro extraction --------------------------------------------------

def get_module_api_defines(engine_source_roots, mod, _cache={}):
    """Find Definitions.<Mod>.h in the standard UE Intermediate path and
    extract API-export macros. Memoised across calls.

    engine_source_roots: iterable of project source root candidates to probe
    so we don't hard-code project layouts. We just need the per-module
    `Definitions.<Mod>.h` file; UBT writes that next to Module.<Mod>.cpp
    under Engine/Intermediate/Build/.../<Mod>/.
    """
    if mod in _cache:
        return _cache[mod]
    out = []
    for root in engine_source_roots:
        candidate = f'{root}/{mod}/Definitions.{mod}.h'
        if not os.path.isfile(candidate):
            continue
        try:
            with open(candidate, encoding='utf-8', errors='replace') as f:
                for line in f:
                    m = RE_API_DEF.match(line)
                    if m:
                        out.append((m.group(1), m.group(2)))
            break
        except OSError:
            continue
    _cache[mod] = out
    return out


def discover_engine_intermediate_roots(cdb):
    """Heuristic: scan first ~300 entries for paths like
    `.../Intermediate/Build/<Platform>/<Target>/<Config>/<Module>/Definitions.<Module>.h`
    inside -include args or -I paths. Return a deduped list of candidate
    `<Config>` parent dirs that get_module_api_defines will probe for
    Definitions.<Mod>.h.

    We avoid hard-coding 'Win64' or 'UE4Editor' segments — UE projects use
    arbitrary Target names (UE4Editor, UE5Editor, ClientGame, ServerGame,
    or even the cross-project resolve-leak's 'Client' here). The marker we
    rely on is 'Intermediate/Build/.../Definitions.<X>.h' presence.
    """
    seen = OrderedDict()
    rx = re.compile(
        r'(.+?Intermediate[/\\]Build[/\\][^/\\]+[/\\][^/\\]+[/\\][^/\\]+)[/\\][^/\\]+[/\\]Definitions\.',
        re.IGNORECASE,
    )
    for e in cdb[:500]:
        for a in e.get('arguments', []):
            m = rx.search(a)
            if m:
                root = m.group(1).replace('\\', '/')
                seen[winpath_local(root)] = None
    return list(seen.keys())


# ---- arg walker (split / glued form aware) ---------------------------------

def walk_args(args):
    """Yield ('inc'|'def'|'other', tuple_of_tokens) preserving original form.
    Same semantics as the full-pipeline build_super_unity_cdb.py.
    """
    n = len(args)
    i = 0
    while i < n:
        a = args[i]
        if a in ('-I', '-D', '-U', '-include', '-isystem', '-imacros') and i + 1 < n:
            kind = 'inc' if a in ('-I', '-include', '-isystem', '-imacros') else 'def'
            yield kind, (a, args[i + 1])
            i += 2
            continue
        if (a.startswith('-I') and len(a) > 2) or a.startswith('-isystem='):
            yield 'inc', (a,)
            i += 1
            continue
        if (a.startswith('-D') and len(a) > 2) or (a.startswith('-U') and len(a) > 2):
            yield 'def', (a,)
            i += 1
            continue
        if a == '-include-pch' and i + 1 < n:
            # Drop -include-pch entirely from super-TUs. The .pch was per-TU;
            # the super-TU includes raw .cpps so the original SharedPCH header
            # gets pulled in via the surviving '-include <SharedPCH.h>' token.
            i += 2
            continue
        yield 'other', (a,)
        i += 1


# ---- main ------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('src', help='per-file CDB (hot.json)')
    ap.add_argument('out', help='output super-unity CDB path')
    ap.add_argument('--max-mods', type=int, default=80,
                    help='max member .cpps per super-TU (default 80)')
    ap.add_argument('--super-dir', default=None,
                    help='where to write SuperUnity.*.cpp (default: <out_dir>/super_unity_cpps)')
    args = ap.parse_args()

    src_local = winpath_local(args.src)
    out_local = winpath_local(args.out)
    with open(src_local, encoding='utf-8') as f:
        cdb = json.load(f)

    print(f'[hot-super] input: {len(cdb)} per-file TUs', file=sys.stderr)
    if not cdb:
        print('[hot-super] empty CDB, nothing to do', file=sys.stderr)
        return 0

    # Discover Engine Intermediate roots for Definitions.<Mod>.h lookup
    intermediate_roots = discover_engine_intermediate_roots(cdb)
    print(f'[hot-super] Intermediate roots probed: {len(intermediate_roots)}',
          file=sys.stderr)
    for r in intermediate_roots[:4]:
        print(f'  - {r}', file=sys.stderr)

    # Group entries by (pch_key, module_name)
    # NOTE: we deliberately do NOT split by per-entry args differences
    # within the same (pch, mod) bucket — the union-merge step downstream
    # consolidates -I/-D/-U across all members. Cross-module bucketing
    # via shared PCH is what gives the 200× preamble share win.
    groups = defaultdict(list)  # (pch_key, mod) -> [entry]
    no_mod = 0
    for e in cdb:
        f_ = e.get('file', '')
        mod = get_module_from_perfile(f_)
        if not mod:
            no_mod += 1
            continue
        pch = get_pch_key_from_args(e.get('arguments', []))
        groups[(pch, mod)].append(e)

    if no_mod:
        print(f'[hot-super] WARN: {no_mod} entries had no Private/Public/Classes/Internal '
              f'parent — skipped', file=sys.stderr)

    # Print group distribution before chunking
    pch_to_count = defaultdict(int)
    for (pch, _mod), entries in groups.items():
        pch_to_count[pch] += len(entries)
    print(f'[hot-super] PCH buckets:', file=sys.stderr)
    for pch, n in sorted(pch_to_count.items(), key=lambda x: -x[1]):
        print(f'  {n:5d}  {pch}', file=sys.stderr)

    # Output dir for SuperUnity.*.cpp
    out_dir = os.path.dirname(out_local) or '.'
    os.makedirs(out_dir, exist_ok=True)
    super_dir = args.super_dir or os.path.join(out_dir, 'super_unity_cpps')
    super_dir_local = winpath_local(super_dir)
    os.makedirs(super_dir_local, exist_ok=True)
    # Clear previous super .cpps so stale files don't confuse the indexer
    for fn in os.listdir(super_dir_local):
        if fn.endswith('.cpp'):
            try:
                os.remove(os.path.join(super_dir_local, fn))
            except OSError:
                pass

    new_cdb = []
    n_super = 0

    # Iterate by PCH bucket so we get nice SuperUnity.<pch>.<N>.cpp names,
    # but chunk inside each bucket across all its modules. To keep RAM
    # bounded we chunk by absolute member count (--max-mods), not by module.
    # Across-module chunking is fine because each member's -D/-I goes
    # through the union step below.
    by_pch = defaultdict(list)  # pch -> [(mod, entry)]
    for (pch, mod), entries in groups.items():
        for e in entries:
            by_pch[pch].append((mod, e))

    for pch_key, members in by_pch.items():
        pch_tag = pch_key if pch_key != 'NONE' else 'NONE'
        pch_tag = pch_tag.replace('.', '_')
        for chunk_idx, start in enumerate(range(0, len(members), args.max_mods)):
            chunk = members[start:start + args.max_mods]
            n_super += 1
            template_entry = chunk[0][1]

            # Synthesise the SuperUnity .cpp containing #include's of all
            # chunk members plus per-module API-macro re-injection.
            super_cpp_local = f'{super_dir_local}/SuperUnity.{pch_tag}.{chunk_idx}.cpp'
            super_cpp_win = winpath_from_local(super_cpp_local).replace('/', '\\')
            with open(super_cpp_local, 'w', encoding='utf-8', newline='\n') as fp:
                fp.write(f'// Super-unity for SharedPCH={pch_tag}, chunk {chunk_idx}\n')
                fp.write(f'// Members: {len(chunk)} per-file TUs\n\n')
                last_mod = None
                for mod, e in chunk:
                    member_path = e['file'].replace('\\', '/')
                    if mod != last_mod:
                        api = get_module_api_defines(intermediate_roots, mod)
                        fp.write(f'\n// ---- {mod} ({len(api)} API macros) ----\n')
                        for name, val in api:
                            fp.write(f'#undef {name}\n#define {name} {val}\n')
                        last_mod = mod
                    fp.write(f'#include "{member_path}"\n')

            # Merge args: union of -I/-D/-U across chunk members; -include /
            # -isystem / -imacros also dedup'd into the 'inc' bucket. Other
            # flags inherited from template_entry (chunk[0]).
            base_args = list(template_entry.get('arguments', []))
            all_inc = []
            seen_inc = set()
            all_def = []
            seen_def = set()
            for _, mem_e in chunk:
                for kind, payload in walk_args(mem_e.get('arguments', [])):
                    key = '\x00'.join(payload)
                    if kind == 'inc' and key not in seen_inc:
                        seen_inc.add(key)
                        all_inc.append(payload)
                    elif kind == 'def' and key not in seen_def:
                        seen_def.add(key)
                        all_def.append(payload)

            # Strip every -I/-D/-U/-include/-include-pch from template,
            # keep only 'other' tokens (driver path, -std=, -x, etc.)
            new_args = []
            for kind, payload in walk_args(base_args):
                if kind == 'other':
                    new_args.extend(payload)

            # Re-insert merged union after the driver path (new_args[0]).
            flat_inc = [tok for tup in all_inc for tok in tup]
            flat_def = [tok for tup in all_def for tok in tup]
            if new_args:
                new_args = new_args[:1] + flat_inc + flat_def + new_args[1:]
            else:
                new_args = flat_inc + flat_def

            # Swap the file path token to point at SuperUnity .cpp
            old_cpp = template_entry.get('file', '')
            replaced = False
            for i, a in enumerate(new_args):
                if a == old_cpp:
                    new_args[i] = super_cpp_win
                    replaced = True
                    break
            if not replaced:
                # template's args didn't carry the source path as a positional
                # token (some forms put it elsewhere). Append it.
                new_args.append(super_cpp_win)

            new_cdb.append({
                'directory': template_entry.get('directory', ''),
                'arguments': new_args,
                'file': super_cpp_win,
            })

    print(f'[hot-super] super-TUs created: {n_super} (compression {len(cdb)/max(n_super,1):.1f}x)',
          file=sys.stderr)

    with open(out_local, 'w', encoding='utf-8') as f:
        json.dump(new_cdb, f)
    print(f'[hot-super] wrote: {out_local}', file=sys.stderr)
    return 0


if __name__ == '__main__':
    sys.exit(main())
