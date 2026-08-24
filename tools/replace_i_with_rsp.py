"""Replace each CDB entry's -I list with the ground truth from its module's
.Shared.rsp file. Replaces both prune (rsp is already pruned) and injection
of module-public dirs (rsp has the real list)."""
import os, re, json, shlex, sys
from pathlib import Path
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
    parts = any_cpp_path.replace('\\', '/').split('/')
    for i, p in enumerate(parts):
        if p == 'Source':
            engine_root = '/'.join(parts[:i])
            for c in [
                f'{engine_root}/Intermediate/Build/Win64/x64/UnrealEditor/Development',
                f'{engine_root}/Intermediate/Build/Win64/UnrealEditor/Development',
            ]:
                if os.path.isdir(winpath_local(c)):
                    return c
    return ''


_rsp_cache = {}
def expand_rsp(rsp_path, depth=0):
    """Recursively expand @file references."""
    rsp_path_local = winpath_local(rsp_path)
    if rsp_path_local in _rsp_cache:
        return _rsp_cache[rsp_path_local]
    if depth > 5 or not os.path.isfile(rsp_path_local):
        return ''
    content = open(rsp_path_local, encoding='utf-8', errors='replace').read()
    out = []
    rsp_dir = os.path.dirname(rsp_path_local)
    for line in content.splitlines():
        s = line.strip()
        if s.startswith('@'):
            ref = s[1:].strip('"')
            ref_local = os.path.normpath(os.path.join(rsp_dir, ref))
            if os.path.isfile(ref_local):
                out.append(expand_rsp(ref_local, depth + 1))
            else:
                out.append(line)
        else:
            out.append(line)
    full = '\n'.join(out)
    _rsp_cache[rsp_path_local] = full
    return full


def extract_i_dirs_from_rsp(rsp_path, base_dir):
    """Return list of absolute -Idir tokens from the .rsp content.
    base_dir is the directory used to resolve relative paths (CDB's directory)."""
    full = expand_rsp(rsp_path)
    if not full:
        return []
    try:
        tokens = shlex.split(full, posix=False)
    except ValueError:
        tokens = full.split()
    i_dirs = []
    i = 0
    while i < len(tokens):
        t = tokens[i].strip('"')
        if t in ('/I', '-I') and i + 1 < len(tokens):
            i_dirs.append(tokens[i + 1].strip('"'))
            i += 2
        elif t.startswith('/I') and len(t) > 2:
            i_dirs.append(t[2:].strip('"'))
            i += 1
        elif t.startswith('-I') and len(t) > 2:
            i_dirs.append(t[2:].strip('"'))
            i += 1
        else:
            i += 1
    # Absolutize
    abs_dirs = []
    seen = set()
    for d in i_dirs:
        if not d:
            continue
        if d.startswith('/') or (len(d) >= 2 and d[1] == ':'):
            abs_d = d
        else:
            abs_d = os.path.normpath(os.path.join(base_dir, d)).replace('\\', '/')
        if abs_d not in seen:
            seen.add(abs_d)
            abs_dirs.append(abs_d)
    return abs_dirs


def main():
    if len(sys.argv) < 2:
        print('usage: replace_i_with_rsp.py <cdb.json>')
        return 1
    cdb_path = sys.argv[1]
    cdb = json.load(open(winpath_local(cdb_path)))
    print(f'Loaded {len(cdb)} entries')

    if not cdb:
        return 1
    dev_root = find_dev_root(cdb[0].get('file', ''))
    print(f'dev_root: {dev_root}')
    if not dev_root:
        print('ERROR: cannot find Intermediate dev root')
        return 1
    dev_root_local = winpath_local(dev_root)

    # Group entries by module
    mod_to_entries = defaultdict(list)
    for idx, e in enumerate(cdb):
        mod = get_module_from_filepath(e.get('file', ''))
        if mod:
            mod_to_entries[mod].append(idx)

    print(f'Modules: {len(mod_to_entries)}')

    # For each module, find its .Shared.rsp and extract -I
    n_replaced = 0
    n_no_rsp = 0
    sample_old, sample_new = 0, 0
    for mod, indices in mod_to_entries.items():
        rsp_path = f'{dev_root_local}/{mod}/{mod}.Shared.rsp'
        if not os.path.isfile(rsp_path):
            n_no_rsp += len(indices)
            continue

        # Use the first entry's directory as base for relative resolution
        base_dir = cdb[indices[0]].get('directory', '').replace('\\', '/')
        if not base_dir:
            n_no_rsp += len(indices)
            continue
        abs_i_dirs = extract_i_dirs_from_rsp(rsp_path, base_dir)
        if not abs_i_dirs:
            n_no_rsp += len(indices)
            continue

        for idx in indices:
            e = cdb[idx]
            args = e.get('arguments', [])
            # Strip all existing -I
            new_args = []
            i = 0
            while i < len(args):
                if args[i] == '-I' and i + 1 < len(args):
                    i += 2
                elif args[i].startswith('-I') and len(args[i]) > 2:
                    i += 1
                else:
                    new_args.append(args[i])
                    i += 1
            # Insert new -I right after the compiler (first token)
            old_n = len(args) - len(new_args)
            new_args = new_args[:1] + [f'-I{d}' for d in abs_i_dirs] + new_args[1:]
            if idx == indices[0]:
                sample_old += old_n
                sample_new += len(abs_i_dirs)
            e['arguments'] = new_args
            n_replaced += 1

    print(f'Replaced: {n_replaced}')
    print(f'No .rsp:  {n_no_rsp}')
    if sample_new:
        print(f'Sample first-of-each-module: avg old={sample_old//max(1,len(mod_to_entries))}, new={sample_new//max(1,len(mod_to_entries))}')

    out = winpath_local(cdb_path)
    bak = out + '.pre-rsp-replace.bak'
    if not os.path.exists(bak):
        import shutil
        shutil.copy2(out, bak)
        print(f'Backup: {bak}')
    with open(out, 'w', encoding='utf-8') as f:
        json.dump(cdb, f)
    print(f'Wrote: {out}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
