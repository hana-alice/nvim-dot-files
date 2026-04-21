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
import json, os, re, sys, time, threading
from collections import defaultdict
from concurrent.futures import ThreadPoolExecutor, as_completed


# --- 全局目录内容缓存 ---
# key=abs_dir_path → set of relative file paths (with subdirs, up to depth 4)
# Threadsafe: protected by _cache_lock with double-checked locking so the
# slow os.walk for any given dir runs at most once across all workers.
_dir_cache = {}
_cache_lock = threading.Lock()
_pending = {}  # dirpath -> threading.Event signalling walk completion

def _populate_cache(dirpath):
    """缓存一个目录下的所有头文件（相对路径）。线程安全 + 不重复 walk。

    设计：用 _pending dict 记录正在 walk 的目录，每个 dir 关联一个 Event。
    第一个线程：取走 walk 任务，做完 set Event，把结果存入 _dir_cache
    后续线程：看到 _pending[dir] 就 wait Event，醒来后从 _dir_cache 读
    """
    dirpath = os.path.normpath(dirpath)

    # Fast path: cache 已有结果（无锁读 dict 单 key 在 CPython 是原子的）
    if dirpath in _dir_cache:
        return

    own_walk = False
    event = None
    with _cache_lock:
        if dirpath in _dir_cache:
            return
        if dirpath in _pending:
            event = _pending[dirpath]  # 别人在 walk，等
        else:
            event = threading.Event()
            _pending[dirpath] = event
            own_walk = True

    if not own_walk:
        event.wait()
        return

    # 这个线程负责 walk
    files = set()
    if os.path.isdir(dirpath):
        try:
            for root, dirs, fnames in os.walk(dirpath):
                depth = root[len(dirpath):].count(os.sep)
                if depth >= 4:
                    dirs.clear()
                    continue
                for fn in fnames:
                    if fn.endswith(('.h', '.hpp', '.inl', '.inc')):
                        rel = os.path.relpath(os.path.join(root, fn), dirpath)
                        files.add(rel.replace('\\', '/'))
        except PermissionError:
            pass

    with _cache_lock:
        _dir_cache[dirpath] = files
        del _pending[dirpath]
    event.set()


def file_exists_in_dir(dirpath, relpath):
    """检查 dirpath/relpath 是否存在（使用缓存）"""
    dirpath = os.path.normpath(dirpath)
    _populate_cache(dirpath)
    return relpath.replace('\\', '/') in _dir_cache.get(dirpath, set())


# Pre-compiled #include regexes, shared by all IncludeResolver instances.
_RE_INC_QUOTE = re.compile(r'\s*#\s*include\s*"([^"]+)"')
_RE_INC_ANGLE = re.compile(r'\s*#\s*include\s*<([^>]+)>')


class IncludeResolver:
    def __init__(self, i_dirs, base_dir, shared_file_includes=None):
        self.i_dirs = i_dirs
        self.base_dir = base_dir
        self.resolved_cache = {}  # include_path -> (full_path, dir_used)
        self.used_dirs = set()
        # Per-instance recursion guard so we don't re-walk a header within
        # one process_file invocation. Across module groups we still want
        # to re-walk headers (different i_dirs → different used_dirs), so
        # this is intentionally NOT shared.
        self._local_visited = set()
        # shared_file_includes: filepath -> tuple[(kind, raw_include)]
        # First resolver to see a header parses it (the slow part: read +
        # regex). Subsequent resolvers in any module reuse the cached
        # include list and only re-run the cheap resolve step.
        self.file_includes = shared_file_includes if shared_file_includes is not None else {}
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
        if depth > 50:
            return
        # Already-parsed file: re-walk its cached includes with our i_dirs
        # so used_dirs picks up dirs we (this module) need.
        # We *do* track per-resolver visited to avoid infinite recursion.
        if filepath in self._local_visited:
            return
        self._local_visited.add(filepath)
        self.header_count += 1

        cached = self.file_includes.get(filepath)
        if cached is None:
            try:
                with open(filepath, 'r', errors='ignore') as f:
                    content = f.read()
            except (FileNotFoundError, PermissionError):
                self.file_includes[filepath] = ()
                return
            includes = []
            for line in content.splitlines():
                m = _RE_INC_QUOTE.match(line)
                if m:
                    includes.append(('"', m.group(1).replace('\\', '/')))
                    continue
                m = _RE_INC_ANGLE.match(line)
                if m:
                    includes.append(('<', m.group(1).replace('\\', '/')))
            cached = tuple(includes)
            self.file_includes[filepath] = cached

        file_dir = os.path.dirname(filepath)
        for kind, inc in cached:
            if kind == '"':
                local = os.path.normpath(os.path.join(file_dir, inc))
                if os.path.isfile(local):
                    self.process_file(local, depth + 1)
                else:
                    full = self.resolve(inc)
                    if full:
                        self.process_file(full, depth + 1)
            else:  # angle
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


def get_module(file_path):
    """Extract UE module name from cpp path.
    .../Source/.../<Module>/Public|Private|Classes|Internal/...cpp"""
    parts = file_path.replace('\\', '/').split('/')
    for i, p in enumerate(parts):
        if p in ('Private', 'Public', 'Classes', 'Internal') and i > 0:
            return parts[i - 1]
    return None


def get_group_key(file_path, args):
    """Group key for prune: module first, fall back to PCH for non-module files."""
    mod = get_module(file_path)
    if mod:
        return f'mod:{mod}'
    return f'pch:{get_pch(args)}'


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


def _process_group(pch, indices, cdb, sample_n, shared_file_includes):
    """Worker: compute (group_used, all_dirs, sample_count, header_count)
    for one PCH/module group. Read-only on cdb, no mutation. Shares the
    file_includes cache (key→tuple) across all groups so each .h is read+
    regex'd at most once globally; only the cheap resolve step repeats."""
    t0 = time.time()
    step = max(1, len(indices) // sample_n)
    sample = indices[::step][:sample_n]

    group_used = set()
    headers = 0
    sampled = 0
    for s_idx in sample:
        e = cdb[s_idx]
        args = e.get('arguments') or []
        if not args:
            continue
        sampled += 1
        base = e.get('directory', '').replace('\\', '/')
        fpath = e.get('file', '').replace('\\', '/')
        resolver = IncludeResolver(extract_i_dirs(args), base, shared_file_includes)
        resolver.process_file(fpath)
        group_used.update(resolver.used_dirs)
        headers += resolver.header_count

    all_dirs = set()
    for idx in indices:
        all_dirs.update(extract_i_dirs(cdb[idx].get('arguments') or []))

    return pch, group_used, all_dirs, sampled, headers, time.time() - t0


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)

    cdb_path = sys.argv[1]
    dry_run = '--dry-run' in sys.argv
    sample_n = 2  # per-module groups have 1-3 distinct -I sets; 2 is enough
    workers = min(20, (os.cpu_count() or 4))
    for i, a in enumerate(sys.argv):
        if a == '--sample' and i + 1 < len(sys.argv):
            sample_n = int(sys.argv[i + 1])
        elif a == '--workers' and i + 1 < len(sys.argv):
            workers = int(sys.argv[i + 1])

    with open(cdb_path) as f:
        cdb = json.load(f)

    print(f"Loaded {len(cdb)} entries | sample={sample_n} | workers={workers} | {'DRY RUN' if dry_run else 'LIVE'}")

    # 按 module 分组（同 module 共享 used dirs 集合，比 PCH 分组细得多）
    pch_groups = defaultdict(list)
    for idx, e in enumerate(cdb):
        key = get_group_key(e.get('file', ''), e.get('arguments', []))
        pch_groups[key].append(idx)

    print(f"Module/PCH groups: {len(pch_groups)}")

    total_removed = 0
    t_start = time.time()

    # Phase 1: parallel scan — produce per-group (used_dirs, all_dirs)
    # Threads share _dir_cache (filled lazily, walk-once per dir) AND
    # shared_file_includes (each .h is read+regex'd once globally).
    sorted_groups = sorted(pch_groups.items(), key=lambda x: -len(x[1]))
    group_results = {}  # pch -> (group_used, all_dirs)
    shared_file_includes = {}

    with ThreadPoolExecutor(max_workers=workers) as pool:
        futures = {pool.submit(_process_group, pch, indices, cdb, sample_n, shared_file_includes): (pch, len(indices))
                   for pch, indices in sorted_groups}
        for fut in as_completed(futures):
            pch, n = futures[fut]
            try:
                pch_, group_used, all_dirs, sampled, headers, dt = fut.result()
            except Exception as ex:
                print(f"  ERROR group {pch}: {ex}")
                continue
            group_results[pch] = (group_used, all_dirs)
            print(f"  {pch or '(none)':40s}: {n:5d} entries, "
                  f"sampled {sampled:2d}, used {len(group_used):3d}/{len(all_dirs):3d} dirs, "
                  f"{headers:5d} headers ({dt:.1f}s)")

    print(f"file_includes cache: {len(shared_file_includes)} headers parsed once")

    # Phase 2: serial prune (CPU-only, fast — no IO)
    for pch, indices in sorted_groups:
        if pch not in group_results:
            continue
        group_used, all_dirs = group_results[pch]
        keep = group_used | {d for d in all_dirs if should_always_keep(d)}
        for idx in indices:
            args = cdb[idx].get('arguments') or []
            if not args:
                continue
            new_args, removed = prune_args(args, keep)
            if not dry_run:
                cdb[idx]['arguments'] = new_args
            total_removed += removed

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
