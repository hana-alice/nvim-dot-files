"""build_super_unity_cdb.py - 按 SharedPCH 分组合并 unity TU。

当前 build_unity_cdb 产 821 TU（每 module 1-N 个 Module.<Mod>.<i>.cpp）。
但 821 个 TU 各自 #include 同一份 SharedPCH（11 种 PCH 共享，分成 7 大组），
clangd-indexer 没有 preamble share → 重复 parse 7 大 PCH 821 次。

方案：把同 SharedPCH group 的 Module.<Mod>.cpp 集中成 1 个 super-unity.cpp
- 保留 .obj.rsp 的 args（任意 module 的，因为它们 SharedPCH 一致）
- super-unity.cpp 内容 = 所有成员 Module.X.cpp 的 #include
- 默认按 50 mods/unity 切分（控制单 TU 内存）

输出 CDB 含约 25 entry（vs 821）。
"""
import json, os, sys, re
from collections import defaultdict

RE_FI_PCH = re.compile(r'/FI"([^"]*(?:SharedPCH|PCH)\.[^"]*)"')

# Match #define X DLLEXPORT  or  #define X_NON_ATTRIBUTED_API DLLEXPORT  in Definitions.<Mod>.h
RE_API_DEF = re.compile(r'^\s*#\s*define\s+(\w+_API|\w+_NON_ATTRIBUTED_API)\s+(DLLEXPORT|DLLIMPORT)\s*$')

def winpath_local(p):
    if len(p) >= 2 and p[1] == ':' and os.path.isdir('/mnt/c'):
        return f'/mnt/{p[0].lower()}/' + p[2:].replace('\\', '/').lstrip('/')
    return p


def winpath_from_local(p):
    """/mnt/d/foo -> D:/foo"""
    if p.startswith('/mnt/') and len(p) > 6 and p[6] == '/':
        drive = p[5].upper()
        return f'{drive}:{p[6:]}'
    return p


def get_module_from_unity(file_path):
    """Module.<Mod>.cpp or Module.<Mod>.<N>.cpp -> <Mod>"""
    fp = file_path.replace('\\', '/')
    base = os.path.basename(fp)
    if base.startswith('Module.') and base.endswith('.cpp'):
        parts = fp.split('/')
        if len(parts) >= 2:
            return parts[-2]
    return None


def get_module_api_defines(dev_root_local, mod):
    """Read Definitions.<Mod>.h and return list of (NAME, VALUE) for *_API / *_NON_ATTRIBUTED_API.
    These are the per-module DLLEXPORT macros; they need to be re-applied per-module
    inside super-unity.cpp because all members are concatenated into one TU."""
    defs_h = f'{dev_root_local}/{mod}/Definitions.{mod}.h'
    if not os.path.isfile(defs_h):
        return []
    out = []
    try:
        for line in open(defs_h, encoding='utf-8', errors='replace'):
            m = RE_API_DEF.match(line)
            if m:
                out.append((m.group(1), m.group(2)))
    except OSError:
        pass
    return out


def find_shared_pch_for_module(dev_root_local, mod):
    mod_dir = f'{dev_root_local}/{mod}'
    if not os.path.isdir(mod_dir):
        return ()
    rsps = [f for f in os.listdir(mod_dir) if f.startswith(f'Module.{mod}') and f.endswith('.obj.rsp')]
    if not rsps:
        return ()
    try:
        content = open(f'{mod_dir}/{rsps[0]}', encoding='utf-8', errors='replace').read()
    except OSError:
        return ()
    pchs = sorted(set(os.path.basename(m.group(1)) for m in RE_FI_PCH.finditer(content)))
    return tuple(pchs) if pchs else ('NONE',)


def main():
    if len(sys.argv) < 3:
        print('usage: build_super_unity_cdb.py <unity_cdb> <out_cdb> [max_mods_per_unity]')
        return 1
    src = winpath_local(sys.argv[1])
    out = winpath_local(sys.argv[2])
    max_mods = int(sys.argv[3]) if len(sys.argv) > 3 else 50

    cdb = json.load(open(src))
    print(f'Source unity CDB: {len(cdb)} entries', file=sys.stderr)
    if not cdb:
        return 1

    # Find dev_root from first entry
    first_file = cdb[0].get('file', '').replace('\\', '/')
    dev_root = None
    parts = first_file.split('/')
    if 'Development' in parts:
        idx = parts.index('Development')
        dev_root = '/'.join(parts[:idx + 1])
    if not dev_root:
        print('ERROR: no dev_root', file=sys.stderr)
        return 1
    dev_root_local = winpath_local(dev_root)

    # Group entries by SharedPCH set
    pch_cache = {}
    def get_pch(mod):
        if mod not in pch_cache:
            pch_cache[mod] = find_shared_pch_for_module(dev_root_local, mod)
        return pch_cache[mod]

    groups = defaultdict(list)  # pch_key -> [(mod, entry)]
    for e in cdb:
        mod = get_module_from_unity(e.get('file', ''))
        if not mod:
            continue
        pch = get_pch(mod)
        groups[pch].append((mod, e))

    print(f'Distinct SharedPCH groups: {len(groups)}', file=sys.stderr)
    for k, v in sorted(groups.items(), key=lambda x: -len(x[1])):
        print(f'  {len(v):>4d} TUs  →  {", ".join(k)}', file=sys.stderr)

    # Output dir for super-unity .cpp files
    out_dir = os.path.dirname(out) or '.'
    os.makedirs(out_dir, exist_ok=True)
    super_dir = os.path.join(out_dir, 'super_unity_cpps')
    os.makedirs(super_dir, exist_ok=True)
    # Clear old
    for f in os.listdir(super_dir):
        if f.endswith('.cpp'):
            os.remove(os.path.join(super_dir, f))

    new_cdb = []
    n_super = 0
    n_skipped_oversized = 0

    for pch_key, members in groups.items():
        # Slice into chunks
        pch_name = pch_key[0].replace('SharedPCH.', '').replace('.h', '').replace('.', '_') if pch_key != ('NONE',) else 'NONE'
        for chunk_idx, start in enumerate(range(0, len(members), max_mods)):
            chunk = members[start:start + max_mods]
            n_super += 1

            # Pick template entry from chunk[0]
            template_entry = chunk[0][1]

            # Build super-unity.cpp content
            super_cpp_local = f'{super_dir}/SuperUnity.{pch_name}.{chunk_idx}.cpp'
            super_cpp_win = winpath_from_local(super_cpp_local).replace('/', '\\')
            with open(super_cpp_local, 'w', encoding='utf-8') as f:
                f.write(f'// Super-unity for SharedPCH={pch_name}, chunk {chunk_idx}\n')
                f.write(f'// Members: {len(chunk)} unity TUs\n\n')
                for mod, e in chunk:
                    member_path = e['file'].replace('\\', '/')
                    api_defs = get_module_api_defines(dev_root_local, mod)
                    f.write(f'\n// ---- {mod} ({len(api_defs)} API macros) ----\n')
                    for name, val in api_defs:
                        f.write(f'#undef {name}\n#define {name} {val}\n')
                    f.write(f'#include "{member_path}"\n')

            # Build args: union of -I from ALL chunk members (so each module's
            # Public/Private/Classes/UHT headers resolve), -D from chunk[0]
            # (note: per-module <MOD>_API=DLLEXPORT will be wrong for non-chunk[0],
            # but indexer mostly tolerates this — symbols get recorded either way).
            base_args = list(template_entry.get('arguments', []))
            # Collect all unique -I from all members
            all_includes = []
            seen_inc = set()
            for _, mem_e in chunk:
                for a in mem_e.get('arguments', []):
                    if a.startswith('-I'):
                        if a not in seen_inc:
                            seen_inc.add(a)
                            all_includes.append(a)
            # Replace template's -I block with the union
            new_args = [a for a in base_args if not a.startswith('-I')]
            # Insert union -I right after clang++
            new_args = new_args[:1] + all_includes + new_args[1:]
            # Swap file path
            old_cpp = template_entry['file']
            for i, a in enumerate(new_args):
                if a == old_cpp:
                    new_args[i] = super_cpp_win
                    break

            new_cdb.append({
                'directory': template_entry['directory'],
                'arguments': new_args,
                'file': super_cpp_win,
            })

    print(f'Super-unity TUs created: {n_super} (vs {len(cdb)} original)', file=sys.stderr)
    print(f'Compression: {len(cdb)/n_super:.1f}x', file=sys.stderr)

    with open(out, 'w', encoding='utf-8') as f:
        json.dump(new_cdb, f)
    print(f'Wrote: {out}', file=sys.stderr)
    return 0


if __name__ == '__main__':
    sys.exit(main())
