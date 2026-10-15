"""Bounded branch-switch reindex through private CDBs and a shared shard junction."""
from __future__ import annotations

import argparse
import ctypes as C
from ctypes import wintypes as W
import json
import hashlib
import os
from pathlib import Path
import queue
import shutil
import subprocess
import sys
import threading
import time
from typing import Any
from urllib.parse import unquote, urlsplit

# Also importable when the CLI is started with Python's isolated (-I) mode.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import clangd_batch_runner as runner
from clangd_index_graph import _chunks, _strings, _Reader

GIB = 1024 ** 3
FLOOR_GIB, WORKER_GIB = 6, 7  # Guard floor; measured worker peak is ~6.5 GB.


def norm(path: str | Path) -> str:
    return os.path.normcase(os.path.abspath(path))


def uri_path(uri: str) -> str:
    parts = urlsplit(uri)
    if parts.scheme != 'file':
        raise ValueError('unsupported-source-uri')
    path = unquote(parts.path)
    if os.name == 'nt' and len(path) > 2 and path[0] == '/' and path[2] == ':':
        path = path[1:]
    return norm(('//' + parts.netloc if parts.netloc else '') + path)


def read_edges(index: Path) -> dict[str, set[str]]:
    edges: dict[str, set[str]] = {}
    for shard in index.glob('*.idx'):
        chunks = _chunks(shard.read_bytes())
        strings = _strings(chunks[b'stri'])
        reader = _Reader(chunks[b'srcs'])
        while reader.remaining():
            reader.byte()
            source = uri_path(reader.string(strings))
            reader.take(8)
            includes = {uri_path(reader.string(strings)) for _ in range(reader.count())}
            edges.setdefault(source, set()).update(includes)
    if not edges:
        raise ValueError('missing-shard-graph')
    return edges


def closure(main: str, edges: dict[str, set[str]]) -> set[str]:
    seen, stack = {main}, [main]
    while stack:
        for included in edges.get(stack.pop(), ()):
            if included not in seen:
                seen.add(included)
                stack.append(included)
    return seen


def select_cover(closures: dict[str, set[str]], changed: set[str]) -> list[str]:
    known = set().union(*closures.values()) if closures else set()
    if changed - known:
        raise ValueError('uncovered-changed-files')
    # A changed main must run even when another TU includes that main.
    selected = [main for main in closures if main in changed]
    remaining = set(changed)
    for main in selected:
        remaining.difference_update(closures[main])
    candidates = {main: files & remaining for main, files in closures.items() if main not in selected}
    while remaining:
        best = max(candidates, key=lambda main: len(candidates[main] & remaining) / len(closures[main]))
        covered = candidates.pop(best) & remaining
        if not covered:
            raise ValueError('uncovered-changed-files')
        selected.append(best)
        remaining.difference_update(covered)
    return selected


def workers_for(available: int, requested: int) -> int:
    """Run only as many workers as commit headroom can finish without tripping the guard."""
    return max(0, min(requested, (available - FLOOR_GIB * GIB) // (WORKER_GIB * GIB)))


def split_lpt(selected: list[str], closures: dict[str, set[str]], workers: int) -> list[list[str]]:
    bins: list[list[str]] = [[] for _ in range(workers)]
    loads = [0] * workers
    for main in sorted(selected, key=lambda main: len(closures[main]), reverse=True):
        worker = loads.index(min(loads))
        bins[worker].append(main)
        loads[worker] += len(closures[main])
    return [items for items in bins if items]


def snapshot(paths: set[str], budget: float = 10) -> dict[str, list[int] | None]:
    # Daemon stat workers cannot hold process shutdown beyond the stat deadline.
    pending: queue.Queue[str] = queue.Queue()
    completed: queue.Queue[tuple[str, list[int] | None]] = queue.Queue()
    for path in paths:
        pending.put(path)
    def stat_worker() -> None:
        while True:
            try:
                path = pending.get_nowait()
            except queue.Empty:
                return
            try:
                stat = os.stat(path)
                value = [stat.st_mtime_ns, stat.st_size]
            except FileNotFoundError:
                value = None
            except OSError:
                value = None
            completed.put((path, value))
    for _ in range(min(8, len(paths))):
        threading.Thread(target=stat_worker, daemon=True).start()
    result: dict[str, list[int] | None] = {}
    deadline = time.monotonic() + budget
    while len(result) < len(paths):
        try:
            path, value = completed.get(timeout=max(0, deadline - time.monotonic()))
        except queue.Empty as error:
            raise TimeoutError('manifest-stat-budget-exceeded') from error
        result[path] = value
    return result


def manifest_state(path: Path, current: dict[str, list[int] | None], generation: dict[str, str] | None = None) -> tuple[str, set[str]]:
    if not path.exists():
        return 'missing-baseline', set()
    previous = json.loads(path.read_text(encoding='utf-8'))
    if generation is not None:
        if not isinstance(previous, dict) or previous.get('generation') != generation:
            return 'stale-baseline', set()
        previous = previous.get('sources')
        if not isinstance(previous, dict):
            return 'stale-baseline', set()
    changed = {source for source in set(previous) | set(current) if previous.get(source) != current.get(source)}
    return ('changed' if changed else 'none'), changed


def save_manifest(path: Path, data: dict[str, list[int] | None], generation: dict[str, str] | None = None) -> None:
    if generation is not None:
        data = dict(version=2, generation=generation, sources=data)
    content = json.dumps(data, separators=(',', ':'))
    if path.exists() and path.read_text(encoding='utf-8') == content:
        return
    temporary = path.with_suffix('.writing')
    temporary.write_text(content, encoding='utf-8')
    os.replace(temporary, path)


def generation_identity(cdb: Path, index: Path) -> dict[str, str]:
    shards = []
    for shard in sorted(index.glob('*.idx')):
        stat = shard.stat()
        shards.append((shard.name, stat.st_mtime_ns, stat.st_size))
    if not shards:
        raise ValueError('missing-shard-generation')
    return dict(cdb=hashlib.sha256(cdb.read_bytes()).hexdigest(),
                shards=hashlib.sha256(json.dumps(shards).encode()).hexdigest())


def source_inventory(roots: list[str], budget: float = 10) -> set[str]:
    """Bounded explicit-command inventory; never follow links or generated trees."""
    sources: set[str] = set()
    deadline = time.monotonic() + budget
    ignored = {'.git', 'binaries', 'intermediate', 'saved', 'deriveddatacache', 'node_modules'}
    for root in roots:
        if not Path(root).is_dir():
            continue
        def failed(error: OSError) -> None:
            raise error
        try:
            for directory, folders, files in os.walk(root, followlinks=False, onerror=failed):
                folders[:] = [name for name in folders if name.lower() not in ignored
                              and not Path(directory, name).is_symlink()
                              and not (getattr(Path(directory, name).lstat(), 'st_file_attributes', 0) & 0x400)]
                if time.monotonic() > deadline or len(sources) > 200000:
                    raise TimeoutError('source-inventory-budget-exceeded')
                sources.update(norm(Path(directory, name)) for name in files
                               if Path(name).suffix.lower() in {'.cpp', '.c', '.cc', '.cxx', '.h', '.hpp', '.inl', '.ipp'})
        except OSError as error:
            if isinstance(error, TimeoutError):
                raise
            raise ValueError('source-inventory-unavailable') from error
    return sources


def cleanup_worker(worker: Path, work_root: Path) -> None:
    if worker.parent.resolve() != work_root.resolve() or not worker.name[1:].isdigit() or worker.name[0] != 'w':
        raise ValueError('worker-outside-work-root')
    if not os.path.lexists(worker):
        return
    # Never recurse through any reparse point, including crash leftovers.
    def detach(path: Path) -> None:
        stat = path.lstat()
        if getattr(stat, 'st_file_attributes', 0) & 0x400:
            os.rmdir(path) if path.is_dir() else os.unlink(path)
            return
        if path.is_symlink():
            path.unlink()
        elif path.is_dir():
            for child in path.iterdir():
                detach(child)
    detach(worker)
    if worker.exists():
        shutil.rmtree(worker)


class Memory(C.Structure):
    _fields_ = [('length', W.DWORD), ('load', W.DWORD)] + [(name, C.c_ulonglong) for name in
        ('total_phys', 'available_phys', 'total_commit', 'available_commit', 'total_virtual', 'available_virtual', 'extended')]


class BasicLimit(C.Structure):
    _fields_ = [('process_time', C.c_longlong), ('job_time', C.c_longlong), ('flags', W.DWORD),
        ('minimum', C.c_size_t), ('maximum', C.c_size_t), ('active', W.DWORD),
        ('affinity', C.c_size_t), ('priority', W.DWORD), ('scheduling', W.DWORD)]


class ExtendedLimit(C.Structure):
    _fields_ = [('basic', BasicLimit), ('io', C.c_ulonglong * 6), ('process_memory', C.c_size_t),
        ('job_memory', C.c_size_t), ('peak_process', C.c_size_t), ('peak_job', C.c_size_t)]


class OwnedJob:
    def __init__(self) -> None:
        if os.name != 'nt':
            raise RuntimeError('windows-job-junction-required')
        self.kernel = C.WinDLL('kernel32', use_last_error=True)
        self.kernel.CreateJobObjectW.restype = W.HANDLE
        for name, args in [('SetInformationJobObject', [W.HANDLE, C.c_int, C.c_void_p, W.DWORD]),
            ('AssignProcessToJobObject', [W.HANDLE, W.HANDLE]), ('TerminateJobObject', [W.HANDLE, W.UINT]),
            ('CloseHandle', [W.HANDLE]), ('GlobalMemoryStatusEx', [C.POINTER(Memory)])]:
            getattr(self.kernel, name).argtypes = args
        self.handle = self.kernel.CreateJobObjectW(None, None)
        self.stop = threading.Event()
        self.reason = ''
        self.original = subprocess.Popen
        limit = ExtendedLimit()
        limit.basic.flags = 0x2000 | 0x100 | 0x200  # kill-on-close, process/job commit bounds
        limit.process_memory, limit.job_memory = 8 * GIB, 16 * GIB
        if not self.handle or not self.kernel.SetInformationJobObject(self.handle, 9, C.byref(limit), C.sizeof(limit)):
            self.close()
            raise C.WinError(C.get_last_error())
        if self.available() < FLOOR_GIB * GIB:
            self.close()
            raise RuntimeError(f'available-commit-below-{FLOOR_GIB}-gib')

    def available(self) -> int:
        memory = Memory()
        memory.length = C.sizeof(memory)
        if not self.kernel.GlobalMemoryStatusEx(C.byref(memory)):
            raise C.WinError(C.get_last_error())
        return memory.available_commit

    def __enter__(self) -> OwnedJob:
        resume = C.WinDLL('ntdll').NtResumeProcess
        resume.argtypes, resume.restype = [W.HANDLE], C.c_long
        def owned(*args: Any, **kwargs: Any) -> subprocess.Popen:
            kwargs['creationflags'] = kwargs.get('creationflags', 0) | 0x4
            process = self.original(*args, **kwargs)
            if not self.kernel.AssignProcessToJobObject(self.handle, W.HANDLE(int(process._handle))) or resume(W.HANDLE(int(process._handle))) != 0:
                process.kill()
                process.wait()
                raise RuntimeError('worker-job-assignment-failed')
            return process
        subprocess.Popen = owned
        def guard() -> None:
            while not self.stop.wait(.5):
                try:
                    low = self.available() < FLOOR_GIB * GIB
                except OSError:
                    low = True
                if low:
                    self.reason = f'available-commit-below-{FLOOR_GIB}-gib'
                    self.kernel.TerminateJobObject(self.handle, 1)
                    return
        threading.Thread(target=guard, daemon=True).start()
        return self

    def close(self) -> None:
        self.stop.set()
        subprocess.Popen = self.original
        if self.handle:
            self.kernel.TerminateJobObject(self.handle, 1)
            self.kernel.CloseHandle(self.handle)
            self.handle = None

    def __exit__(self, *args: Any) -> None:
        self.close()


def execute(args: argparse.Namespace) -> dict[str, Any]:
    started = time.monotonic()
    report: dict[str, Any] = dict(ok=False, action='reindex', changed=0, cover_tus=0, workers=[], seconds=0, reason='')
    root, index = Path(args.work_root).resolve(), Path(args.index_dir).resolve()
    root.mkdir(parents=True, exist_ok=True)
    if root == index or root in index.parents or index in root.parents:
        raise ValueError('overlapping-work-and-index-directories')
    lock = (root / 'switch-reindex.lock').open('a+b')
    owned: list[Path] = []
    try:
        import msvcrt
        lock.seek(0)
        msvcrt.locking(lock.fileno(), msvcrt.LK_NBLCK, 1)
        for worker in root.glob('w[0-9]*'):
            cleanup_worker(worker, root)
        entries = json.loads(Path(args.cdb).read_text(encoding='utf-8-sig'))
        by_main = {norm(Path(entry['directory']) / entry['file']): entry for entry in entries
                   if Path(entry['file']).name != 'index_trigger.cpp'}
        edges = read_edges(index)
        generation = generation_identity(Path(args.cdb), index)
        known_sources = set(edges) | set(by_main)
        for includes in edges.values():
            known_sources.update(includes)
        current = snapshot(known_sources | source_inventory(getattr(args, 'source_root', [])))
        if generation_identity(Path(args.cdb), index) != generation:
            raise ValueError('generation-changed-during-snapshot')
        manifest = root / 'srcs-manifest.json'
        if getattr(args, 'baseline_only', False):
            save_manifest(manifest, current, generation)
            return dict(report, ok=True, action='baseline', seconds=round(time.monotonic() - started, 3))
        state, changed = manifest_state(manifest, current, generation)
        if args.changed_list and state not in ('missing-baseline', 'stale-baseline'):
            changed.update(norm(source) for source in json.loads(Path(args.changed_list).read_text(encoding='utf-8-sig')))
            state = 'changed' if changed else 'none'
        report['changed'] = len(changed)
        if state in ('missing-baseline', 'stale-baseline'):
            return dict(report, action='needs-prepare', needs_prepare=True, reason=state, seconds=round(time.monotonic() - started, 3))
        if state == 'none':
            return dict(report, ok=True, action=state, seconds=round(time.monotonic() - started, 3))
        closures = {main: closure(main, edges) for main in by_main}
        covered = set().union(*closures.values()) if closures else set()
        previous = json.loads(manifest.read_text(encoding='utf-8')).get('sources', {}) if manifest.exists() else {}
        uncovered = sorted(source for source in changed if source not in covered
                           or current.get(source) is None or previous.get(source) is None)
        if uncovered:
            return dict(report, action='needs-prepare', needs_prepare=True, reason='uncovered-changed-files',
                        uncovered_changed_files=uncovered, seconds=round(time.monotonic() - started, 3))
        selected = select_cover(closures, changed)
        report['cover_tus'] = len(selected)
        if not selected:
            save_manifest(manifest, current, generation)
            return dict(report, ok=True, action='none', seconds=round(time.monotonic() - started, 3))
        profile = args.server_profile
        results: queue.Queue[dict[str, Any]] = queue.Queue()
        def worker_run(worker: Path, trigger: Path, count: int) -> None:
            try:
                result = runner.run(worker, worker / 'native', trigger, args.clangd, args.timeout, args.jobs, profile)
                results.put(dict(tus=count, wall_seconds=result['process_wall_seconds'],
                    peak_working_set_bytes=result['peak_working_set_bytes'],
                    failed=result['compile_failure_count'] or int(not result['background_compile_success'])))
            except Exception as error:
                results.put(dict(tus=count, wall_seconds=0, peak_working_set_bytes=None, failed=1, reason=str(error)))
        threads: list[threading.Thread] = []
        import _winapi
        with OwnedJob() as job:
            count = workers_for(job.available(), args.workers)
            if count == 0:
                raise RuntimeError('insufficient-commit-headroom')
            report['planned_workers'] = count
            for number, mains in enumerate(split_lpt(selected, closures, count)):
                worker = root / ('w' + str(number))
                owned.append(worker)
                (worker / '.cache/clangd').mkdir(parents=True)
                _winapi.CreateJunction(str(index), str(worker / '.cache/clangd/index'))
                trigger = worker / 'index_trigger.cpp'
                trigger.write_text('// Private branch-switch index trigger.\n', encoding='utf-8')
                rows = [by_main[main] for main in mains] + [dict(file=str(trigger), directory=str(worker),
                    arguments=[str(Path(args.clangd).with_name('clang++.exe')), '-std=c++17', str(trigger)])]
                (worker / 'compile_commands.json').write_text(json.dumps(rows), encoding='utf-8')
                thread = threading.Thread(target=worker_run, args=(worker, trigger, len(mains)))
                threads.append(thread)
                thread.start()
            for thread in threads:
                thread.join()
            report['workers'] = [results.get() for _ in threads]
            report['reason'] = job.reason
        report['ok'] = not report['reason'] and all(worker['failed'] == 0 for worker in report['workers'])
        if report['ok']:
            # Worker shard writes advance the baseline's shard generation too.
            completed_sources = snapshot(known_sources | source_inventory(getattr(args, 'source_root', [])))
            if completed_sources != current:
                raise ValueError('source-changed-during-reindex')
            completed_generation = generation_identity(Path(args.cdb), index)
            if completed_generation['cdb'] != generation['cdb']:
                raise ValueError('generation-changed-during-reindex')
            save_manifest(manifest, current, completed_generation)
        elif not report['reason']:
            report['reason'] = 'worker-failed-or-timed-out'
    except Exception as error:
        report.update(ok=False, reason=str(error))
        if str(error) in {'missing-shard-graph', 'missing-shard-generation', 'generation-changed-during-snapshot',
                          'generation-changed-during-reindex', 'source-changed-during-reindex',
                          'source-inventory-budget-exceeded', 'source-inventory-unavailable',
                          'manifest-stat-budget-exceeded'}:
            report.update(action='needs-prepare', needs_prepare=True)
    finally:
        for thread in locals().get('threads', []):
            if thread.is_alive():
                thread.join()
        for worker in owned:
            cleanup_worker(worker, root)
        lock.close()
    return dict(report, seconds=round(time.monotonic() - started, 3))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('cdb', 'index-dir', 'work-root', 'clangd'):
        parser.add_argument('--' + name, required=True)
    parser.add_argument('--workers', type=int, default=2, choices=(1, 2))
    parser.add_argument('--jobs', type=int, default=8)
    parser.add_argument('--server-profile', type=json.loads, default=None)
    parser.add_argument('--changed-list')
    parser.add_argument('--source-root', action='append', default=[])
    parser.add_argument('--baseline-only', action='store_true', help='Only after a successful prepare establishes current inputs')
    parser.add_argument('--timeout', type=int, default=600)
    args = parser.parse_args()
    if args.jobs < 1 or args.jobs > 8 or args.timeout < 1:
        parser.error('jobs must be 1..8 and timeout must be positive')
    try:
        report = execute(args)
    except Exception as error:
        report = dict(ok=False, action='reindex', changed=0, cover_tus=0, workers=[], seconds=0, reason=str(error))
    print(json.dumps(report, separators=(',', ':')))
    raise SystemExit(0 if report['ok'] else 1)


if __name__ == '__main__':
    main()
