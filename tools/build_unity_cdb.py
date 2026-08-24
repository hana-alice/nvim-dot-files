"""Build a CDB using UE's own Module.<Mod>.<N>.cpp unity files instead of
individual cpps. This avoids per-TU preamble repetition (the main bottleneck).

For each Module.<Mod>.<N>.cpp under <dev_root>/<Module>/:
  - Find a representative individual cpp from that module in the source CDB
  - Copy its arguments (-I, -D, etc., already cleaned by replace_i_with_rsp)
  - Swap the file path to point at the unity .cpp

Output a CDB that has ~899 entries instead of 11593.
"""
import json, os, sys, glob
from collections import defaultdict


def winpath_local(p):
    if sys.platform.startswith('linux') and len(p) >= 2 and p[1] == ':' and os.path.isdir('/mnt/c'):
        return f'/mnt/{p[0].lower()}/' + p[2:].replace('\\', '/').lstrip('/')
    return p


def get_module_from_filepath(file_path):
    parts = file_path.replace('\\', '/').split('/')
    for i, p in enumerate(parts):
        if p in ('Private', 'Public', 'Classes', 'Internal') and i > 0:
            return parts[i - 1]
    return None


def find_dev_root(any_cpp_path):
    """Find the *largest* dev_root by trying multiple parents and picking
    the one with most Module.*.cpp files. UE plugins have their own little
    Intermediate/Build dirs that contain only 1-2 modules; the engine's
    main one (under Engine/Intermediate) has hundreds. Picking the small
    one would silently produce a near-empty unity CDB."""
    parts = any_cpp_path.replace('\\', '/').split('/')
    candidates = []
    # Try every Source/ ancestor as a candidate root
    for i, p in enumerate(parts):
        if p == 'Source':
            engine_root = '/'.join(parts[:i])
            for c in [
                f'{engine_root}/Intermediate/Build/Win64/x64/UnrealEditor/Development',
                f'{engine_root}/Intermediate/Build/Win64/UnrealEditor/Development',
                f'{engine_root}/Intermediate/Build/Win64/UE4Editor/Development',
                f'{engine_root}/Intermediate/Build/Win64/UE5Editor/Development',
                f'{engine_root}/Intermediate/Build/Win64/x64/UE4Editor/Development',
                f'{engine_root}/Intermediate/Build/Win64/x64/UE5Editor/Development',
            ]:
                local = winpath_local(c)
                if os.path.isdir(local):
                    try:
                        n = len(os.listdir(local))
                    except Exception:
                        n = 0
                    candidates.append((n, c))
    if not candidates:
        return ''
    # Pick the candidate with most module subdirs (engine main, not plugin)
    candidates.sort(reverse=True)
    return candidates[0][1]


def main():
    if len(sys.argv) < 3:
        print('usage: build_unity_cdb.py <src_cdb> <out_cdb>')
        return 1
    src = winpath_local(sys.argv[1])
    out = winpath_local(sys.argv[2])

    cdb = json.load(open(src))
    print(f'Source CDB: {len(cdb)} entries')

    if not cdb:
        return 1
    # Sample a wide swath of cpps so we catch the engine main dev_root
    # (cdb[0..200] might be all plugins with 1-2 modules each).
    dev_root = ''
    seen_roots = set()
    best = (0, '')
    for e in cdb:
        cand = find_dev_root(e.get('file', ''))
        if cand and cand not in seen_roots:
            seen_roots.add(cand)
            try:
                n = len(os.listdir(winpath_local(cand)))
            except Exception:
                n = 0
            if n > best[0]:
                best = (n, cand)
    dev_root = best[1]
    if not dev_root:
        print('ERROR: no dev_root')
        return 1
    dev_root_local = winpath_local(dev_root)
    print(f'dev_root: {dev_root}')

    # Group source CDB entries by module — collect ALL entries per module so
    # we can take the union of -I flags. A single template cpp's -I set is
    # incomplete for the unity TU because the unity .cpp #includes 50+ cpps
    # from the same module, and each cpp may depend on different downstream
    # modules. Single template → unity TU often hits "fatal error: X.h file
    # not found" for headers needed by sibling cpps.
    mod_to_entries = defaultdict(list)
    for e in cdb:
        mod = get_module_from_filepath(e.get('file', ''))
        if mod:
            mod_to_entries[mod].append(e)
    print(f'Modules in source CDB: {len(mod_to_entries)}')

    new_cdb = []
    n_unity_found = 0
    n_no_template = 0
    n_modules_used = set()

    # Walk dev_root for Module.*.cpp files
    for mod_dir in sorted(os.listdir(dev_root_local)):
        mod_dir_local = f'{dev_root_local}/{mod_dir}'
        if not os.path.isdir(mod_dir_local):
            continue

        # Find unity files in this module dir
        unity_files = sorted(glob.glob(f'{mod_dir_local}/Module.{mod_dir}.cpp')) \
                    + sorted(glob.glob(f'{mod_dir_local}/Module.{mod_dir}.[0-9]*.cpp'))
        if not unity_files:
            continue

        # Find template entries from source CDB for this module
        entries = mod_to_entries.get(mod_dir, [])
        if not entries:
            n_no_template += len(unity_files)
            continue

        # Build the union of -I flags from all sibling cpps of this module.
        # Strategy: take the first entry's args as a base (preserves arg order
        # for non-I flags like -D, -W, /FI, etc.), then APPEND any -I path we
        # haven't seen yet from sibling entries.
        template = entries[0]
        base_args = list(template.get('arguments', []))
        seen_I = set()
        for i, a in enumerate(base_args):
            if a == '-I' and i + 1 < len(base_args):
                seen_I.add(base_args[i+1])

        extra_I = []
        for sib in entries[1:]:
            sa = sib.get('arguments') or []
            for i, a in enumerate(sa):
                if a == '-I' and i + 1 < len(sa) and sa[i+1] not in seen_I:
                    extra_I.append('-I')
                    extra_I.append(sa[i+1])
                    seen_I.add(sa[i+1])

        n_modules_used.add(mod_dir)

        for unity_local in unity_files:
            n_unity_found += 1
            # Convert to Windows path
            unity_win = unity_local.replace('/mnt/d/', 'D:/').replace('/mnt/c/', 'C:/').replace('/', '\\')

            # Copy base args, swap file, append union -Is at the end (-I order
            # only matters within the same set of paths; appended last means
            # they apply after the template's set, which is fine for fallback).
            new_args = list(base_args) + extra_I
            old_cpp = template['file']
            for i, a in enumerate(new_args):
                if a == old_cpp or os.path.basename(a) == os.path.basename(old_cpp):
                    new_args[i] = unity_win
                    break

            new_cdb.append({
                'directory': template['directory'],
                'arguments': new_args,
                'file': unity_win,
            })

    print(f'Unity TUs created:    {n_unity_found}')
    print(f'Modules used:         {len(n_modules_used)}')
    print(f'Unity files w/o template (skipped): {n_no_template}')

    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, 'w', encoding='utf-8') as f:
        json.dump(new_cdb, f)
    print(f'Wrote: {out}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
