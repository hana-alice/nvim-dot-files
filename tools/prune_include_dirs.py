#!/usr/bin/env python3
"""
prune_include_dirs.py - 精确裁剪 compile_commands.json 中无用的 -I dirs
v2: 使用目录内容缓存替代逐个 stat，大幅提速

用法:
    python prune_include_dirs.py <compile_commands.json> [--dry-run] [--sample N]

--dry-run:  只分析不修改
--sample N: 每个 PCH 组最多采样 N 个文件 (默认 30)

按 PCH 组聚合分析（同 PCH 组共享 used dirs 集合）。
Intermediate/Generated 目录始终保留。
"""
import json, os, re, sys, time
from collections import defaultdict


# --- 全局目录内容缓存 ---
# key=abs_dir_path → set of relative file paths (with subdirs, up to depth 4)
_dir_cache = {}

def _populate_cache(dirpath):
    """缓存一个目录下的所有头文件（相对路径）"""
    dirpath = os.path.normpath(dirpath)
    if dirpath in _dir_cache:
        return
    files = set()
    if os.path.isdir(dirpath):
        try:
            for root, dirs, fnames in os.walk(dirpath):
                depth = root[len(dirpath):].count(os.sep)
                if depth >= 4:
                    dirs.clear()
                    continue
                for fn in fnames:
                    # 只缓存头文件
                    if fn.endswith(('.h', '.hpp', '.inl', '.inc')):
                        rel = os.path.relpath(os.path.join(root, fn), dirpath)
                        files.add(rel.replace('\\', '/'))
        except PermissionError:
            pass
    _dir_cache[dirpath] = files


def file_exists_in_dir(dirpath, relpath):
    """检查 dirpath/relpath 是否存在（使用缓存）"""
    dirpath = os.path.normpath(dirpath)
    _populate_cache(dirpath)
    return relpath.replace('\\', '/') in _dir_cache.get(dirpath, set())


class IncludeResolver:
    def __init__(self, i_dirs, base_dir):
        self.i_dirs = i_dirs
        self.base_dir = base_dir
        self.resolved_cache = {}  # include_path -> (full_path, dir_used)
        self.used_dirs = set()
        self.visited = set()
        self.header_count = 0

    def resolve(self, include_path):
        if include_path in self.resolved_cache:
            r = self.resolved_cache[include_path]
            if r:
                self.used_dirs.add(r[1])
            return r[0] if r else None

        inc_norm = include_path.replace('\\', '/')
        for d in self.i_dirs:
            abs_d = d if os.path.isabs(d) else os.path.join(self.base_dir, d)
            abs_d = os.path.normpath(abs_d)
            if file_exists_in_dir(abs_d, inc_norm):
                full = os.path.normpath(os.path.join(abs_d, inc_norm))
                self.resolved_cache[include_path] = (full, d)
                self.used_dirs.add(d)
                return full

        self.resolved_cache[include_path] = None
        return None

    def process_file(self, filepath, depth=0):
        filepath = os.path.normpath(filepath)
        if filepath in self.visited or depth > 50:
            return
        self.visited.add(filepath)
        self.header_count += 1
        try:
            with open(filepath, 'r', errors='ignore') as f:
                content = f.read()
        except (FileNotFoundError, PermissionError):
            return
        for line in content.splitlines():
            m = re.match(r'\s*#\s*include\s*"([^"]+)"', line)
            if m:
                inc = m.group(1).replace('\\', '/')
                local = os.path.normpath(os.path.join(os.path.dirname(filepath), inc))
                if os.path.isfile(local):
                    self.process_file(local, depth + 1)
                else:
                    full = self.resolve(inc)
                    if full:
                        self.process_file(full, depth + 1)
            m = re.match(r'\s*#\s*include\s*<([^>]+)>', line)
            if m:
                inc = m.group(1).replace('\\', '/')
                full = self.resolve(inc)
                if full:
                    self.process_file(full, depth + 1)


ALWAYS_KEEP_PATTERNS = ['intermediate', 'generated', '/gen/']

def should_always_keep(d):
    d_low = d.replace('\\', '/').lower()
    return any(p in d_low for p in ALWAYS_KEEP_PATTERNS)


def extract_i_dirs(args):
    dirs = []
    i = 0
    while i < len(args):
        if args[i] == '-I' and i + 1 < len(args):
            dirs.append(args[i + 1].replace('\\', '/'))
            i += 2
        elif args[i].startswith('-I') and len(args[i]) > 2:
            dirs.append(args[i][2:].replace('\\', '/'))
            i += 1
        else:
            i += 1
    return dirs


def get_pch(args):
    for i, a in enumerate(args):
        if a == '-include-pch' and i + 1 < len(args):
            return args[i + 1].replace('\\', '/').split('/')[-1]
    return ''


def prune_args(args, keep_dirs):
    new_args = []
    i = 0
    removed = 0
    while i < len(args):
        if args[i] == '-I' and i + 1 < len(args):
            d = args[i + 1].replace('\\', '/')
            if d in keep_dirs or should_always_keep(d):
                new_args.append(args[i])
                new_args.append(args[i + 1])
            else:
                removed += 1
            i += 2
        elif args[i].startswith('-I') and len(args[i]) > 2:
            d = args[i][2:].replace('\\', '/')
            if d in keep_dirs or should_always_keep(d):
                new_args.append(args[i])
            else:
                removed += 1
            i += 1
        else:
            new_args.append(args[i])
            i += 1
    return new_args, removed


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)

    cdb_path = sys.argv[1]
    dry_run = '--dry-run' in sys.argv
    sample_n = 30
    for i, a in enumerate(sys.argv):
        if a == '--sample' and i + 1 < len(sys.argv):
            sample_n = int(sys.argv[i + 1])

    with open(cdb_path) as f:
        cdb = json.load(f)

    print(f"Loaded {len(cdb)} entries | sample={sample_n} | {'DRY RUN' if dry_run else 'LIVE'}")

    # 按 PCH 分组
    pch_groups = defaultdict(list)
    for idx, e in enumerate(cdb):
        pch = get_pch(e.get('arguments', []))
        pch_groups[pch].append(idx)

    print(f"PCH groups: {len(pch_groups)}")

    total_removed = 0
    t_start = time.time()

    for pch, indices in sorted(pch_groups.items(), key=lambda x: -len(x[1])):
        t0 = time.time()

        # 采样
        step = max(1, len(indices) // sample_n)
        sample = indices[::step][:sample_n]

        group_used = set()
        for s_idx in sample:
            e = cdb[s_idx]
            args = e['arguments']
            base = e.get('directory', '').replace('\\', '/')
            fpath = e.get('file', '').replace('\\', '/')
            resolver = IncludeResolver(extract_i_dirs(args), base)
            resolver.process_file(fpath)
            group_used.update(resolver.used_dirs)

        # 所有 always-keep dirs
        all_dirs = set()
        for idx in indices:
            all_dirs.update(extract_i_dirs(cdb[idx]['arguments']))
        keep = group_used | {d for d in all_dirs if should_always_keep(d)}

        # 裁剪
        grp_removed = 0
        for idx in indices:
            new_args, removed = prune_args(cdb[idx]['arguments'], keep)
            if not dry_run:
                cdb[idx]['arguments'] = new_args
            grp_removed += removed

        t1 = time.time()
        orig_count = len(extract_i_dirs(cdb[indices[0]]['arguments'])) if dry_run else len(all_dirs)
        print(f"  {pch or '(none)':40s}: {len(indices):5d} entries, "
              f"sampled {len(sample):2d}, used {len(group_used):3d}/{len(all_dirs):3d} dirs, "
              f"removed {grp_removed:6d} args ({t1-t0:.1f}s)")
        total_removed += grp_removed

    elapsed = time.time() - t_start
    print(f"\nTotal: removed {total_removed} -I args in {elapsed:.1f}s")
    print(f"Dir cache: {len(_dir_cache)} directories cached")

    if not dry_run:
        if total_removed == 0:
            print("No changes needed — CDB already pruned")
        else:
            with open(cdb_path, 'w') as f:
                json.dump(cdb, f, indent=2)
            print(f"Written to {cdb_path}")
    else:
        print("[DRY RUN] No changes made")


if __name__ == '__main__':
    main()
