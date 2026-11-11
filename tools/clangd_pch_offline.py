"""Produce private PCH-assisted BackgroundIndex shards for an ordinary clangd reader.

Only the private workspace is indexed. Failed/error-marked shards are never
published. No-PCH commands use a separate ordinary lane, without a manifest.
The caller owns the prepare writer lease; this tool also excludes other runs.
"""
import argparse
import concurrent.futures
import ctypes
import hashlib
import json
import os
from pathlib import Path
import queue
import re
import shutil
import subprocess
import sys
import threading
import time
from urllib.parse import unquote, urlparse

import clangd_index_graph as graph
import pch_offline_tier1 as tier1

# Threads for per-file metadata/IO work (shard decode, stat, publish copy).
# File-open latency bound, not CPU: no compiler or clangd runs on these.
IO_THREADS = 4
MERGE_SEPARATORS = os.name == "nt" and os.environ.get("PCH_OFFLINE_MERGE_SEPARATORS") == "1"


def norm(value):
    value = str(value).replace("\\", "/")
    return value.lower() if os.name == "nt" else value


def sha(path):
    with Path(path).open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def write_json(path, value):
    path = Path(path)
    data = (json.dumps(value, ensure_ascii=False, sort_keys=True, indent=2) + "\n").encode()
    if path.is_file() and path.read_bytes() == data:
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".new-" + str(os.getpid()))
    tmp.write_bytes(data)
    os.replace(tmp, path)


def prefix_headers(cmd):
    args = cmd["arguments"]
    headers = [args[i + 1] for i, arg in enumerate(args[:-1]) if arg == "-include"]
    for i, header in enumerate(headers):
        if header.replace("\\", "/").rsplit("/", 1)[-1].startswith(("SharedPCH.", "PCH.")):
            return headers[:i + 1]
    return []


def context_key(cmd, overlay_digests=None):
    """Preserve case-sensitive macros, target, language, overlays and prefix order.

    Module -I lists remain on each TU. PCH reuse is limited to the validated
    prefix recipe, and clang's PCH validation remains enabled.
    """
    prefix = prefix_headers(cmd)
    if not prefix:
        return "no-pch"
    args, out, i, forced = cmd["arguments"], [], 1, 0
    while i < len(args):
        arg = args[i]
        if arg == "--":
            i += 1
            continue
        if arg in ("-D", "-U") and i + 1 < len(args):
            out += [arg, args[i + 1]]
            i += 2
            continue
        if arg == "-include":
            if forced < len(prefix):
                out += [arg, norm(args[i + 1])]
            forced += 1
            i += 2
            continue
        if arg == "-ivfsoverlay":
            overlay = args[i + 1]
            out += [arg, (overlay_digests or {}).get(overlay, overlay)]
            i += 2
            continue
        if arg in ("-o", "-MF", "-include-pch", "-I"):
            i += 2
            continue
        if arg in ("-c", "-MD", "-MMD") or arg.startswith(("-I", "-MF")) or norm(arg) == norm(cmd["file"]):
            i += 1
            continue
        # Opt-in only. Merging separator-spelling duplicates (27 → 18 contexts)
        # changed the full-run index far beyond noise in R50 cold13, so it stays
        # off until the cause is understood. Macro values keep their exact bytes.
        if MERGE_SEPARATORS and not arg.startswith(("-D", "-U")):
            arg = arg.replace("\\", "/")
        out.append(arg)
        i += 1
    # Relative headers and include paths must not accidentally share a context.
    return hashlib.sha256("\0".join([norm(cmd["directory"]), *out]).encode()).hexdigest()[:24]


def producer_args(cmd, pch, headers, compiler):
    args, out, i, forced = cmd["arguments"], [str(compiler)], 1, 0
    while i < len(args):
        arg = args[i]
        if arg == "--":
            i += 1
            continue
        if arg == "-include":
            if forced < len(headers) - 1:
                out += [arg, args[i + 1]]
            forced += 1
            i += 2
            continue
        if arg in ("-o", "-MF", "-include-pch"):
            i += 2
            continue
        if arg in ("-c", "-MD", "-MMD") or arg.startswith("-MF") or norm(arg) == norm(cmd["file"]):
            i += 1
            continue
        if arg == "-x":
            out += ["-x", "c++-header"]
            i += 2
            continue
        out.append(arg)
        i += 1
    return out + ["-fparse-all-comments", "-fretain-comments-from-system-headers",
                  "-fno-pch-instantiate-templates", headers[-1], "-o", str(pch)]


def dependency_scan_args(producer):
    """Preprocess-only twin of a producer command: list the prefix closure on stdout."""
    if len(producer) < 3 or producer[-2] != "-o":
        raise ValueError("producer command must end with -o <pch>")
    return producer[:-2] + ["-M", "-MG"]


def parse_depfile(text, directory):
    """Make-style depfile -> absolute prerequisite paths (escapes, continuations, drive letters)."""
    joined = re.sub(r"\\\r?\n", " ", text)
    match = re.search(r":(?:\s|$)", joined)
    if not match:
        return []
    body, result, current, i = joined[match.end():], [], [], 0
    while i < len(body):
        char = body[i]
        if char == "\\" and i + 1 < len(body) and body[i + 1] in " #":
            current.append(body[i + 1])
            i += 2
            continue
        if char == "$" and body[i + 1:i + 2] == "$":
            current.append("$")
            i += 2
            continue
        if char.isspace():
            if current:
                result.append("".join(current))
                current = []
        else:
            current.append(char)
        i += 1
    if current:
        result.append("".join(current))
    return [os.path.normpath(os.path.join(directory, p)) for p in result]


def driver_query_args(row):
    """SystemIncludeExtractor::DriverArgs (LLVM 22); no module search dirs."""
    args = row["arguments"]
    lang = "c" if Path(row["file"]).suffix == ".c" else "c++"
    values, switches, specs = {}, [], []
    names = {"--sysroot": "--sysroot", "-isysroot": "-isysroot",
             "-target": "-target", "--target": "-target",
             "-stdlib": "--stdlib", "--stdlib": "--stdlib"}
    i = 1
    while i < len(args):
        arg = args[i]
        if arg == "-x":
            lang = args[i + 1]
            i += 2
            continue
        if arg.startswith("-x"):
            lang = arg[2:]
        elif arg in ("-nostdinc", "--no-standard-includes"):
            switches.append("-nostdinc")
        elif arg == "-nostdinc++":
            switches.append(arg)
        elif arg in names:
            values[names[arg]] = args[i + 1]
            i += 2
            continue
        elif "=" in arg and arg.split("=", 1)[0] in names:
            key, value = arg.split("=", 1)
            values[names[key]] = value
        elif arg.startswith("-isysroot"):
            values["-isysroot"] = arg[len("-isysroot"):]
        elif arg.startswith(("-specs=", "--specs=")):
            specs.append(arg)
        elif arg == "--specs":
            specs += [arg, args[i + 1]]
            i += 2
            continue
        i += 1
    if lang == "objective-c++-header":
        lang = "c++-header"
    return [args[0], "-E", "-v", "-x", lang, *switches,
            *(x for key in ("--sysroot", "-isysroot", "-target", "--stdlib")
              if key in values for x in (key, values[key])), *specs, "-"]


def parse_driver_output(text, builtin):
    includes, active, ended, target = [], False, False, ""
    for line in text.splitlines():
        stripped = line.strip()
        if stripped.startswith("Target: "):
            target = stripped[len("Target: "):]
        if stripped == "#include <...> search starts here:":
            active = True
        elif stripped == "End of search list.":
            ended = True
            active = False
        elif active and stripped != builtin.strip():
            includes.append(stripped)
    if not ended:
        raise ValueError("query-driver did not report a complete system include list")
    return {"includes": includes, "target": target}


def manifest_command(row, driver, resource_dir):
    args = row["arguments"]
    if any(arg.startswith("@") for arg in args):
        raise ValueError("expand CDB response files before offline indexing")
    if sum(norm(arg) == norm(row["file"]) for arg in args[1:]) != 1:
        raise ValueError("expected exactly one main-file input")
    raw = [arg for arg in args[1:] if arg != "--" and norm(arg) != norm(row["file"])]
    mode = [] if any(arg.startswith("--driver-mode=") for arg in raw) else ["--driver-mode=g++"]
    # Unsupported driver modes fail closed instead of guessing their effective argv.
    if not re.search(r"(?:clang\+\+|g\+\+)(?:\.exe)?$", args[0], re.I):
        raise ValueError("offline PCH currently requires a clang++/g++ driver")
    tail = [token for inc in driver["includes"] for token in ("-isystem", inc)]
    if not any(arg == "-target" or arg.startswith("--target=") for arg in raw) and driver["target"]:
        tail.append("--target=" + driver["target"])
    if not any(arg == "-resource-dir" or arg.startswith("-resource-dir=") for arg in raw):
        tail.append("-resource-dir=" + str(resource_dir))
    source = os.path.normpath(str(Path(row["directory"]) / row["file"]))
    return {"file": row["file"], "directory": row["directory"],
            "arguments": [args[0], *mode, *raw, *tail, "--", source],
            "output": row.get("output", ""), "heuristic": ""}


_CPP_INCLUDE = re.compile(r'^[ \t]*#[ \t]*include[ \t]+"([^"]+\.(?:cpp|cc|cxx|c))"', re.M)


def tu_cost(path, depth=0):
    """Estimated parse cost: number of leaf .cpp sources a unity TU includes.

    Wrapper -> UBT unity -> members; a plain TU costs 1. On the R50 cold run
    this correlates 0.77 with measured TU time and gives a near-optimal
    longest-first schedule (simulated makespan 498 s vs 495 s ideal).
    """
    try:
        text = Path(path).read_text(encoding="utf-8-sig", errors="replace")
    except OSError:
        return 1
    hits = _CPP_INCLUDE.findall(text) if depth < 3 else []
    return sum(tu_cost(Path(path).parent / hit, depth + 1) for hit in hits) or 1


def write_index_order(lane, rows, contexts=None):
    """Queue order for the private clangd (order only, never content).

    A TU whose PCH prefix shards are not yet stored indexes the full PCH
    (R50 cold: 31 such TUs, 401 worker-s, some starting 540 s in). So the
    cheapest TU of each PCH context runs first as its seed, then the rest
    longest-first to keep the tail short.
    """
    sources = [str((Path(row["directory"]) / row["file"]).resolve()) for row in rows]
    with concurrent.futures.ThreadPoolExecutor(max_workers=IO_THREADS) as pool:
        costs = list(pool.map(tu_cost, sources))
    keyed = sorted(zip(costs, sources, contexts or [None] * len(rows)), key=lambda item: (item[0], item[1]))
    seeds, seen = [], set()
    if contexts:
        for item in keyed:
            if item[2] not in seen:
                seen.add(item[2])
                seeds.append(item)
    chosen = {id(item) for item in seeds}
    rest = sorted((item for item in keyed if id(item) not in chosen), key=lambda item: (-item[0], item[1]))
    order = [item[1] for item in seeds + rest]
    path = lane / "index-order.txt"
    path.write_text("\n".join(order) + "\n", encoding="utf-8")
    return path


def log_counts(lines):
    result = dict(paired=0, mismatch=0, unlisted=0, compile_failure_count=0, compile_failure_tus=[])
    for line in lines:
        if "manifest selection for " in line:
            if ": paired (" in line:
                result["paired"] += 1
            elif "(command-mismatch)" in line:
                result["mismatch"] += 1
            elif "(unlisted)" in line:
                result["unlisted"] += 1
        if "Failed to compile " in line:
            source = line.split("Failed to compile ", 1)[1].rsplit(", index may be incomplete", 1)[0]
        elif " failed: " in line and line.split("] ", 1)[-1].startswith("Indexing "):
            # Fails before diagnostics (e.g. PCH rejected): no "Failed to compile".
            source = line.split("Indexing ", 1)[1].split(" failed: ", 1)[0]
        else:
            source = None
        if source is not None and source not in result["compile_failure_tus"]:
            result["compile_failure_tus"].append(source)
    result["compile_failure_count"] = len(result["compile_failure_tus"])
    return result


class Resources:
    """Limits only our children: IDLE, per-process cap (default 16 GiB) and >=8 GiB free host RAM."""
    def __init__(self, process_limit=16 << 30):
        self.process_limit = process_limit
        self.children, self.lock, self.error = {}, threading.Lock(), None
        self.peak_bytes, self.min_available, self.cpu_seconds = 0, None, 0
        self.stop = threading.Event()
        self.job, self.kernel = None, None
        if os.name == "nt":
            from ctypes import wintypes as w
            class Basic(ctypes.Structure):
                _fields_ = [("process_time", ctypes.c_int64), ("job_time", ctypes.c_int64), ("flags", w.DWORD),
                            ("min_ws", ctypes.c_size_t), ("max_ws", ctypes.c_size_t), ("active", w.DWORD),
                            ("affinity", ctypes.c_size_t), ("priority", w.DWORD), ("scheduling", w.DWORD)]
            class Extended(ctypes.Structure):
                _fields_ = [("basic", Basic), ("io", ctypes.c_uint64 * 6),
                            ("process_memory", ctypes.c_size_t), ("job_memory", ctypes.c_size_t),
                            ("peak_process", ctypes.c_size_t), ("peak_job", ctypes.c_size_t)]
            kernel = ctypes.WinDLL("kernel32", use_last_error=True)
            kernel.CreateJobObjectW.argtypes, kernel.CreateJobObjectW.restype = [w.LPVOID, w.LPCWSTR], w.HANDLE
            kernel.SetInformationJobObject.argtypes = [w.HANDLE, ctypes.c_int, w.LPVOID, w.DWORD]
            kernel.AssignProcessToJobObject.argtypes = [w.HANDLE, w.HANDLE]
            kernel.CloseHandle.argtypes = [w.HANDLE]
            self.job, self.kernel = kernel.CreateJobObjectW(None, None), kernel
            limits = Extended()
            limits.basic.flags = 0x2100  # PROCESS_MEMORY | KILL_ON_JOB_CLOSE
            limits.process_memory = process_limit
            if not self.job or not kernel.SetInformationJobObject(self.job, 9, ctypes.byref(limits), ctypes.sizeof(limits)):
                raise OSError("could not establish owned process memory limit")
        self.thread = threading.Thread(target=self.watch, daemon=True)
        self.thread.start()

    def sample(self, process=None):
        if os.name != "nt":
            return None, 0, 0
        from ctypes import wintypes as w
        class Memory(ctypes.Structure):
            _fields_ = [("length", w.DWORD), ("load", w.DWORD)] + [(name, ctypes.c_ulonglong) for name in
                ("total", "available", "page_total", "page_available", "virtual_total", "virtual_available", "extended")]
        memory = Memory()
        memory.length = ctypes.sizeof(memory)
        if not ctypes.windll.kernel32.GlobalMemoryStatusEx(ctypes.byref(memory)):
            raise OSError("GlobalMemoryStatusEx failed")
        peak, cpu = 0, 0
        if process:
            class Counters(ctypes.Structure):
                _fields_ = [("cb", w.DWORD), ("faults", w.DWORD)] + [(name, ctypes.c_size_t) for name in
                    ("peak_rss", "rss", "peak_paged", "paged", "peak_nonpaged", "nonpaged", "private", "peak_private")]
            counters = Counters()
            counters.cb = ctypes.sizeof(counters)
            handle = w.HANDLE(int(process._handle))
            if ctypes.windll.psapi.GetProcessMemoryInfo(handle, ctypes.byref(counters), counters.cb):
                peak = max(counters.peak_rss, counters.peak_private)
            stamps = [w.FILETIME() for _ in range(4)]
            if ctypes.windll.kernel32.GetProcessTimes(handle, *(ctypes.byref(s) for s in stamps)):
                cpu = sum((s.dwHighDateTime << 32) | s.dwLowDateTime for s in stamps[2:]) / 1e7
        return memory.available, peak, cpu

    def spawn(self, args, **kwargs):
        available, _, _ = self.sample()
        if self.error or (available is not None and available < 8 << 30):
            raise RuntimeError(self.error or "host memory reserve below 8 GiB")
        flags = subprocess.CREATE_NO_WINDOW | subprocess.IDLE_PRIORITY_CLASS | 0x4 if os.name == "nt" else 0
        process = subprocess.Popen(args, creationflags=flags, **kwargs)
        if self.job:
            from ctypes import wintypes as w
            resume = ctypes.WinDLL("ntdll").NtResumeProcess
            resume.argtypes, resume.restype = [w.HANDLE], ctypes.c_long
            if not self.kernel.AssignProcessToJobObject(self.job, w.HANDLE(int(process._handle))) or resume(w.HANDLE(int(process._handle))) != 0:
                process.kill()
                process.wait()
                raise OSError("could not assign/resume owned process in memory-limited job")
        with self.lock:
            self.children[process.pid] = process
        return process

    def finish(self, process):
        available, peak, cpu = self.sample(process)
        with self.lock:
            self.children.pop(process.pid, None)
            self.peak_bytes = max(self.peak_bytes, peak)
            self.cpu_seconds += cpu
        if self.error:
            raise RuntimeError(self.error)

    def watch(self):
        while not self.stop.wait(.2):
            try:
                with self.lock:
                    children = list(self.children.values())
                available, _, _ = self.sample()
                if available is not None:
                    self.min_available = min(self.min_available or available, available)
                    if available < 8 << 30:
                        self.error = "host memory reserve below 8 GiB"
                for child in children:
                    _, peak, _ = self.sample(child)
                    self.peak_bytes = max(self.peak_bytes, peak)
                    if peak >= self.process_limit:
                        self.error = "owned child exceeded %d GiB" % (self.process_limit >> 30)
                if self.error:
                    for child in children:
                        if child.poll() is None:
                            child.kill()
            except OSError as error:
                self.error = str(error)

    def capture(self, args, cwd, env=None, timeout=180):
        child = self.spawn(args, cwd=cwd, env=env, stdin=subprocess.PIPE,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            out, err = child.communicate(b"", timeout=timeout)
            return child.returncode, out.decode(errors="replace"), err.decode(errors="replace")
        finally:
            if child.poll() is None:
                child.kill()
                child.wait()
            self.finish(child)

    def close(self):
        self.stop.set()
        self.thread.join(timeout=2)
        if self.job:
            self.kernel.CloseHandle(self.job)


def index_workspace(cdb_dir, clangd, env, resources, jobs, resource_dir, timeout, manifest=None, order=None,
                    inject=None):
    """Wait for an initialize handshake and paired BackgroundIndex progress.

    One didOpen triggers compilation database discovery (the production reader
    uses the same handshake). Completion requires background progress.
    inject: {normalized main file: [raw CDB rows]}; when that file logs a
    compile failure, its rows are pushed into this clangd's in-memory CDB
    (LSP compilationDatabaseChanges) and indexed before completion.
    """
    # clangd's LLVM build pins _WIN32_WINNT 0x0601, so its EcoQoS branch is
    # compiled out: "background" and "low" both map to THREAD_MODE_BACKGROUND
    # (measured: no throughput difference, thread power-throttling mask 0).
    command = [str(clangd), "--compile-commands-dir=" + str(cdb_dir), "--background-index",
               "--enable-config=false", "--background-index-priority=background", "--log=info",
               "--query-driver=**/clang*,**/gcc,**/g++,**/cc,**/c++", "-j=" + str(jobs),
               "--resource-dir=" + str(resource_dir)]
    local_env = dict(env)
    if manifest:
        local_env["CLANGD_EXPERIMENTAL_INDEX_PCH_MANIFEST"] = str(manifest)
    if order:
        # Scheduling only; a clangd without this hook keeps its random order.
        local_env["CLANGD_EXPERIMENTAL_INDEX_ORDER_FILE"] = str(order)
    # Concurrent TUs skip header shards another TU already stored with the same
    # digest (first writer instead of last); a clangd without the hook ignores it.
    # PCH_OFFLINE_SKIP_PUBLISHED_SHARDS=0 disables it (A/B checks).
    local_env["CLANGD_EXPERIMENTAL_SKIP_PUBLISHED_SHARDS"] = (
        "0" if os.environ.get("PCH_OFFLINE_SKIP_PUBLISHED_SHARDS") == "0" else "1")
    # Later TUs of a manifest profile wait for its first TU (the seed) so they
    # see its prefix shards and select thin PCH instead of a second full parse
    # (cold7: ~160 avoidable full worker-s, incl. the longest paired TU).
    # Scheduling only; clangd without the hook ignores it. =0 disables (A/B).
    local_env["CLANGD_EXPERIMENTAL_PCH_SEED_GATE"] = (
        "0" if os.environ.get("PCH_OFFLINE_SEED_GATE") == "0" else "1")
    # Forced prefix headers are no include edge of a main file, so the shard
    # loader never reaches their stored shards; this registers those whose
    # digest matches the disk file (thin selection still checks metadata).
    local_env["CLANGD_EXPERIMENTAL_PCH_PRELOAD_PREFIX"] = (
        "0" if os.environ.get("PCH_OFFLINE_PRELOAD_PREFIX") == "0" else "1")
    # The shard-version lookup of the file filter used mixed-separator paths on
    # Windows, so every TU re-collected all already-stored headers (62-row j1
    # sample: -43% worker cpu, symbols/refs identical). Its doc-comment fix-ups
    # in SymbolCollector are gated by the same flag. =0 disables (A/B).
    local_env["CLANGD_EXPERIMENTAL_FILTER_NATIVE_PATH"] = (
        "0" if os.environ.get("PCH_OFFLINE_FILTER_NATIVE_PATH") == "0" else "1")
    # Thin TUs skip deserializing prefix top-level decls; with the filter fixed
    # those are all rejected anyway (merged diff 0, a further -9%). =0 disables.
    local_env["CLANGD_EXPERIMENTAL_THIN_NOLOAD"] = (
        "0" if os.environ.get("PCH_OFFLINE_THIN_NOLOAD") == "0" else "1")
    # Offline lanes never query the in-memory index, yet the idle Heavy rebuild
    # runs before the progress "end" (BackgroundQueue OnIdle), holding the
    # paired lane 6.8-9.1 s after its last TU (cold10-19). j1 shards identical.
    # =0 keeps the rebuilds (A/B).
    local_env["CLANGD_EXPERIMENTAL_SKIP_INDEX_REBUILD"] = (
        "0" if os.environ.get("PCH_OFFLINE_SKIP_INDEX_REBUILD") == "0" else "1")
    # Every row carries the same multi-MB -ivfsoverlay; re-parsing its YAML costs
    # ~0.08 s per TU (j1 rep->load 0.045 vs 0.125 s). v26+ caches the parsed
    # tree per process and clones it per TU. Older binaries ignore it. =0 A/B.
    local_env["CLANGD_EXPERIMENTAL_VFS_OVERLAY_CACHE"] = (
        "0" if os.environ.get("PCH_OFFLINE_VFS_OVERLAY_CACHE") == "0" else "1")
    if inject:
        # An injected unity member already has a (non-TU) shard written by its
        # failed wrapper with the same digest; upstream would skip it as fresh.
        local_env["CLANGD_EXPERIMENTAL_REINDEX_NON_TU"] = "1"
    process = resources.spawn(command, cwd=cdb_dir, env=local_env, stdin=subprocess.PIPE,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    messages, errors, lines = queue.Queue(), [], []
    def stdout():
        try:
            while True:
                headers = {}
                while True:
                    line = process.stdout.readline(8193)
                    if not line:
                        return
                    if line in (b"\r\n", b"\n"):
                        break
                    key, value = line.decode("ascii").split(":", 1)
                    headers[key.lower()] = value.strip()
                size = int(headers["content-length"])
                if not 0 < size <= 4 << 20:
                    raise ValueError("LSP frame limit")
                messages.put(json.loads(process.stdout.read(size)))
        except Exception as error:
            errors.append(repr(error))
    def stderr():
        try:
            with (cdb_dir / "clangd.stderr.log").open("w", encoding="utf-8") as log:
                for raw in iter(process.stderr.readline, b""):
                    line = raw.decode(errors="replace").rstrip()
                    log.write(line + "\n")
                    lines.append(line)
        except Exception as error:
            errors.append(repr(error))
    readers = [threading.Thread(target=f, daemon=True) for f in (stdout, stderr)]
    for reader in readers:
        reader.start()
    def send(message):
        data = json.dumps(dict(jsonrpc="2.0", **message)).encode()
        process.stdin.write(("Content-Length: %d\r\n\r\n" % len(data)).encode() + data)
        process.stdin.flush()
    started, began, ended, completed, initialized = time.monotonic(), False, None, False, False
    inject = dict(inject or {})
    scanned, pending, injected, settled = 0, set(), [], 0.0
    def scan_injections():
        nonlocal scanned, settled
        count = len(lines)
        for line in lines[scanned:count]:
            if "Failed to compile " in line and inject:
                source = line.split("Failed to compile ", 1)[1].rsplit(", index may be incomplete", 1)[0]
                rows = inject.pop(norm(Path(source).resolve()), None)
                if rows:
                    send(dict(method="workspace/didChangeConfiguration", params={"settings": {
                        "compilationDatabaseChanges": {row["file"]: {
                            "workingDirectory": row["directory"], "compilationCommand": row["arguments"]}
                            for row in rows}}}))
                    for row in rows:
                        pending.add(norm(Path(row["directory"], row["file"]).resolve()))
                        injected.append(row["file"])
            elif pending and ("Indexed " in line or "Indexing " in line):
                if line.split("] ", 1)[-1].startswith("Indexed "):
                    done = line.split("Indexed ", 1)[1].rsplit(" (", 1)[0]
                elif " failed: " in line and line.split("] ", 1)[-1].startswith("Indexing "):
                    done = line.split("Indexing ", 1)[1].split(" failed: ", 1)[0]
                else:
                    continue
                key = norm(Path(done).resolve())
                if key in pending:
                    pending.discard(key)
                    settled = time.monotonic()
        scanned = count
    try:
        send(dict(id=1, method="initialize", params={"processId": os.getpid(), "rootUri": cdb_dir.as_uri(),
             "capabilities": {"window": {"workDoneProgress": True}},
             "workspaceFolders": [{"uri": cdb_dir.as_uri(), "name": "pch-offline"}]}))
        while time.monotonic() - started < timeout and process.poll() is None:
            if errors or resources.error:
                raise RuntimeError(str(errors or resources.error))
            try:
                message = messages.get(timeout=.2)
            except queue.Empty:
                message = {}
            if "id" in message and "method" in message:
                send(dict(id=message["id"], result=None))
            elif message.get("id") == 1 and "result" in message:
                initialized = True
                send(dict(method="initialized", params={}))
                row = json.loads((cdb_dir / "compile_commands.json").read_text(encoding="utf-8"))[0]
                source = (Path(row["directory"]) / row["file"]).resolve()
                send(dict(method="textDocument/didOpen", params={"textDocument": {
                    "uri": source.as_uri(), "languageId": "cpp", "version": 1,
                    "text": source.read_text(encoding="utf-8-sig")}}))
                if os.environ.get("PCH_OFFLINE_KEEP_OPEN") != "1":
                    # The open's first update looks up the command, which
                    # broadcasts the CDB to the background index; closing at
                    # once stops its foreground preamble/AST, which otherwise
                    # competes with the workers (R50 cold12 retry: 13 s, 127 MB).
                    # =1 keeps the file open (A/B).
                    send(dict(method="textDocument/didClose", params={"textDocument": {
                        "uri": source.as_uri()}}))
            if message.get("method") == "$/progress" and message["params"].get("token") == "backgroundIndexProgress":
                kind = message["params"]["value"]["kind"]
                if kind == "begin":
                    began, ended = True, None
                elif kind == "end" and began:
                    ended = time.monotonic()
            if initialized:
                scan_injections()
            # An injected TU's end can be read before its log line: wait for
            # every injected file (at most 10 s past an end, for a file clangd
            # did not index), then 2 s without a new progress begin.
            now = time.monotonic()
            if (initialized and ended and now - ended > 1 and (not pending or now - ended > 10)
                    and (not injected or now - max(ended, settled) > 2)):
                completed = True
                break
        if not completed:
                raise RuntimeError("background indexing did not complete before deadline")
        send(dict(id=2, method="shutdown", params=None))
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            message = messages.get(timeout=2)
            if message.get("id") == 2:
                break
            if "id" in message and "method" in message:
                send(dict(id=message["id"], result=None))
        send(dict(method="exit", params=None))
        process.wait(timeout=10)
        if process.returncode:
            raise RuntimeError("clangd exit " + str(process.returncode))
    finally:
        if process.poll() is None:
            process.kill()
            process.wait(timeout=10)
        for reader in readers:
            reader.join(timeout=2)
        resources.finish(process)
    return dict(log_counts(lines), elapsed_s=round(time.monotonic() - started, 3),
                indexing_complete=completed, command=command, injected=injected)


def path_stamp(path):
    try:
        stat = Path(path).stat()
        return [stat.st_size, stat.st_mtime_ns, stat.st_ctime_ns]
    except OSError:
        return None


def acquire_writer_lock(path):
    """The OS releases this lock even if the Python owner is terminated."""
    descriptor = os.open(path, os.O_CREAT | os.O_RDWR)
    try:
        if os.fstat(descriptor).st_size == 0:
            os.write(descriptor, b"\0")
        os.lseek(descriptor, 0, os.SEEK_SET)
        try:
            if os.name == "nt":
                import msvcrt
                msvcrt.locking(descriptor, msvcrt.LK_NBLCK, 1)
            else:
                import fcntl
                fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError as error:
            raise RuntimeError("offline PCH writer lock unavailable: " + str(error)) from error
        os.lseek(descriptor, 0, os.SEEK_SET)
        owner = str(os.getpid()).encode()
        os.write(descriptor, owner)
        os.ftruncate(descriptor, len(owner))
        return descriptor
    except BaseException:
        os.close(descriptor)
        raise


def publish_shard(source, destination, attempts=5, delay=0.2):
    """Atomic copy; tolerate a reader briefly holding the destination (Windows sharing)."""
    try:
        if destination.exists() and sha(destination) == sha(source):
            return True
    except OSError:
        pass
    temporary = destination.with_name(destination.name + ".new-" + str(os.getpid()))
    shutil.copyfile(source, temporary)
    for attempt in range(attempts):
        try:
            os.replace(temporary, destination)
            return True
        except PermissionError:
            if attempt + 1 < attempts:
                time.sleep(delay)
    temporary.unlink(missing_ok=True)
    return False


def uri_path(uri):
    file = unquote(urlparse(uri).path)
    if os.name == "nt" and re.match(r"/[A-Za-z]:", file):
        file = file[1:]
    return file


def shard_graph(path):
    """Owned source nodes -> (flags, direct include paths), from the srcs chunk only."""
    # Decode only the source graph, not the potentially very large ref slab.
    chunks = graph._chunks(path.read_bytes())
    strings = graph._strings(chunks[b"stri"])
    reader, result = graph._Reader(chunks[b"srcs"]), {}
    while reader.remaining():
        flags, uri, digest = reader.byte(), reader.string(strings), reader.take(8)
        includes = [uri_path(reader.string(strings)) for _ in range(reader.count())]
        if digest != b"\0" * 8:
            result[uri_path(uri)] = (flags, includes)
    return result


def shard_sources(path):
    return {file: flags for file, (flags, _) in shard_graph(path).items()}


def first_error(text):
    """First compiler diagnostic line containing 'error:' (trimmed), or ''."""
    for line in text.splitlines():
        if "error:" in line:
            return line.strip()[:300]
    return ""


def reaching_sources(edges, sources, targets):
    """Sources whose forward include closure reaches any of targets (normalized)."""
    result = []
    for source in sources:
        seen, stack = set(), [norm(source)]
        while stack:
            node = stack.pop()
            if node in seen:
                continue
            if node in targets:
                result.append(source)
                break
            seen.add(node)
            stack.extend(edges.get(node, ()))
    return result


def row_roots(row, source, context=None):
    """Files whose change can alter this TU, besides what they transitively include."""
    roots = [source]
    args = row["arguments"]
    for i, token in enumerate(args[:-1]):
        if token in ("-include", "-ivfsoverlay"):
            roots.append(os.path.normpath(os.path.join(row["directory"], args[i + 1])))
    if context:
        roots.append("context:" + context)
    return [norm(p) for p in roots]


def affected_rows(edges, roots, changed):
    """Rows whose roots transitively reach any changed file (reverse include walk)."""
    parents = {}
    for node, children in edges.items():
        for child in children:
            parents.setdefault(child, []).append(node)
    reached, pending = set(changed), list(changed)
    while pending:
        for parent in parents.get(pending.pop(), ()):
            if parent not in reached:
                reached.add(parent)
                pending.append(parent)
    return {key for key, row in roots.items() if reached.intersection(row["roots"])}


def fold_kept_shards(covered, edges, shard_owner, shards):
    """Shards judge dropped that a cleanly folded original row re-produced.

    judge withholds the failed wrapper's member shards; the folded UBT row that
    the paired clangd then indexed cleanly rewrote those members' shards
    (REINDEX_NON_TU). Keep the row's own shard and its directly included,
    clean, owned shards (R50 cold40: only the row's own shard was kept, so 783
    member .cpp shards went unpublished, 31680 vs 32463).
    """
    kept = set()
    for source in covered:
        for node in [source, *edges.get(source, ())]:
            name = shard_owner.get(node)
            if name in shards:
                kept.add(name)
    return kept


def retry_lane(run_dir, retry, groups, profiles, clangd, env, resources, args, resource_dir,
               report, shards, shard_owner, rejected, edges, dependencies):
    """Index failed Tier 1 wrappers' original UBT rows with thin PCH; return covered sources.

    Each context gets one clean, already indexed anchor row whose published
    closure is copied in: the loader then knows the prefix shards (thin PCH)
    and the anchor itself is up to date. Retry shards never replace a shard the
    paired lane published; a clean retry shard replaces a rejected one.
    """
    lane = run_dir / "retry"
    index = lane / ".cache/clangd/index"
    index.mkdir(parents=True)
    anchors, copied = {}, set()
    for key in sorted({key for _, _, key in retry}):
        # One clean, already indexed row per context; its published closure is
        # copied so shared headers are not re-serialized. Forced prefix headers
        # are not reachable from main-file include edges, so the first retried
        # TU of a context indexes the full PCH and later ones go thin (R50 s8).
        # A context whose rows were all in the failed wrapper has no anchor; its
        # retry simply starts from full PCH (R50 cold4: 6 TUs otherwise fell back).
        anchors[key] = []
        for row, command in sorted(groups.get(key, ()), key=lambda item: tu_cost(Path(item[0]["directory"], item[0]["file"]))):
            source = norm(Path(row["directory"], row["file"]).resolve())
            if shard_owner.get(source) in shards:
                break
        else:
            continue
        anchors[key] = [(row, command, key)]
        seen, stack = set(), [source]
        while stack:
            node = stack.pop()
            if node not in seen:
                seen.add(node)
                stack.extend(edges.get(node, ()))
                if shard_owner.get(node) in shards:
                    copied.add(shard_owner[node])
    retry = [item for item in retry if item[2] in anchors]
    if not retry:
        return set()
    # The prefix sources' own shards too: a clangd with the preload hook then
    # selects thin for every retried TU, including each context's first.
    for key in anchors:
        for file in shard_graph(Path(profiles[key]["full_metadata"])):
            if shard_owner.get(norm(file)) in shards:
                copied.add(shard_owner[norm(file)])
    with concurrent.futures.ThreadPoolExecutor(max_workers=IO_THREADS) as pool:
        list(pool.map(lambda name: shutil.copyfile(shards[name], index / name), sorted(copied)))
    items = [item for chosen in anchors.values() for item in chosen] + retry
    lane_rows = [row for row, _, _ in items]
    write_json(lane / "compile_commands.json", lane_rows)
    manifest = lane / "manifest.json"
    write_json(manifest, dict(version=1, profiles={key: profiles[key] for key in anchors},
                              commands=[dict(command, profile=key) for _, command, key in items]))
    order = write_index_order(lane, lane_rows, [key for _, _, key in items])
    summary = index_workspace(lane, clangd, env, resources, args.jobs, resource_dir, args.timeout, manifest, order)
    report["tier1_retry_failures"] = sorted(str(Path(p).resolve()) for p in summary["compile_failure_tus"])
    if summary["mismatch"] or summary["unlisted"]:
        # Only the retry is unusable: its rows stay fallback for the reader, and
        # the paired publication already in flight is unaffected.
        report["tier1_retry_mismatch"] = summary["mismatch"] + summary["unlisted"]
        return set()
    fresh = sorted(p for p in index.glob("*.idx") if p.name not in copied)
    with concurrent.futures.ThreadPoolExecutor(max_workers=IO_THREADS) as pool:
        decoded = list(pool.map(shard_graph, fresh))
        stamped = {p for nodes in decoded for p in nodes} - dependencies.keys()
        dependencies.update(zip(stamped, pool.map(path_stamp, stamped)))
    for shard, nodes in zip(fresh, decoded):
        if shard.name in shards:
            continue  # the paired lane's copy is published (skip hook: same digest)
        for file, (_, includes) in nodes.items():
            edges.setdefault(norm(file), set()).update(norm(p) for p in includes)
        if any(flags & 2 for flags, _ in nodes.values()):
            rejected.add(shard.name)
            continue
        shards[shard.name] = shard
        rejected.discard(shard.name)
        for file in nodes:
            shard_owner[norm(file)] = shard.name
    failed = {norm(p) for p in report["tier1_retry_failures"]}
    rejected_files = {file for file, name in shard_owner.items() if name in rejected}
    sources = [str(Path(row["directory"], row["file"]).resolve()) for row, _, _ in retry]
    blocked = {norm(p) for p in reaching_sources(edges, sources, rejected_files)}
    return {norm(p) for p in sources if norm(p) not in failed and norm(p) not in blocked
            and shard_owner.get(norm(p)) in shards}


def drift_plan(previous, identity, rows, target, threshold):
    """Decide reuse / delta (reader rebuilds stale shards itself) / full rerun.

    Correctness never rests on this decision: the ordinary reader re-checks every
    shard digest at load. The plan only decides whether offline work pays off.
    """
    try:
        if previous.get("identity") != identity:
            return "full", "identity", None
        old_rows, edges = previous["rows"], previous["graph"]
        changed = {norm(p) for p, stamp in previous["dependencies"].items() if path_stamp(p) != stamp}
        affected = {key for key, row in rows.items()
                    if key not in old_rows or old_rows[key]["command"] != row["command"]}
        affected |= affected_rows(edges, {k: v for k, v in old_rows.items() if k in rows}, changed)
        missing = sum(1 for name in previous["shards"] if not (Path(target) / name).is_file())
        ratio = max(len(affected) / max(len(rows), 1), missing / max(len(previous["shards"]), 1))
        if ratio > threshold:
            return "full", "drift %.3f > %.3f" % (ratio, threshold), None
        report = {k: v for k, v in previous["report"].items() if k != "full_reason"}
        if not affected and not missing and not changed:
            return "reuse", None, dict(report, skipped=True, mode="reuse")
        return "delta", None, dict(report, skipped=True, mode="delta",
                                   delta_affected_tus=len(affected), delta_changed_files=len(changed),
                                   delta_missing_shards=missing, drift_ratio=round(ratio, 4))
    except (KeyError, TypeError, AttributeError, ValueError):
        return "full", "receipt", None


def group_contexts(rows, commands):
    """Return ({context: [(row, command)]}, no-PCH rows, {overlay: content digest})."""
    groups, ordinary, overlay_digests = {}, [], {}
    for command in commands:
        for i, token in enumerate(command["arguments"][:-1]):
            if token == "-ivfsoverlay":
                overlay = command["arguments"][i + 1]
                if overlay not in overlay_digests:
                    overlay_digests[overlay] = sha(Path(command["directory"]) / overlay)
    for row, command in zip(rows, commands):
        key = context_key(command, overlay_digests)
        if key == "no-pch":
            ordinary.append(row)
        else:
            groups.setdefault(key, []).append((row, command))
    return groups, ordinary, overlay_digests


def run(args):
    started, resources = time.monotonic(), Resources(getattr(args, "process_gib", 16) << 30)
    cdb, target, binary = Path(args.cdb).resolve(), Path(args.index_dir).resolve(), Path(args.bin_dir).expanduser().resolve()
    work = target.parent / "pch-offline"
    work.mkdir(parents=True, exist_ok=True)
    report = dict(ok=False, skipped=False, contexts=0, paired=0, mismatch=0, unlisted=0,
                  compile_failure_count=0, producer_failure_count=0, producer_failure_context_count=0,
                  compile_failure_tus=[], producer_failure_tus=[], fallback_tus=[], fallback_count=0,
                  ordinary_tus=0, shards=0)
    lock = work / "writer.lock"
    lock_fd = side = spec_pool = None
    try:
        lock_fd = acquire_writer_lock(lock)
        rows = json.loads(cdb.read_text(encoding="utf-8-sig"))
        if not rows or any(not isinstance(row.get("arguments"), list) for row in rows):
            raise ValueError("nonempty arguments-based CDB required")
        tier1_state = None
        clangd, probe = binary / "clangd.exe", binary / "clangd-pch-probe.exe"
        compiler_candidates = [args.compiler, shutil.which("clang++"), str(binary / "clang++.exe")]
        if os.name == "nt" and os.environ.get("ProgramFiles"):
            compiler_candidates.append(str(Path(os.environ["ProgramFiles"]) / "LLVM/bin/clang++.exe"))
        compiler = next((Path(p) for p in compiler_candidates if p and Path(p).is_file()), Path(""))
        if not compiler.is_file():
            raise ValueError("matching clang++ unavailable; supply --compiler")
        env = {key: value for key, value in os.environ.items() if not key.startswith("CLANGD_")}
        environment = work / "environment"
        environment.mkdir(exist_ok=True)
        env.update(TEMP=str(environment), TMP=str(environment), LOCALAPPDATA=str(environment),
                   XDG_CACHE_HOME=str(environment / "cache"))
        identities = {str(path): sha(path) for path in (cdb, clangd, probe, compiler, Path(__file__),
                                                         Path(tier1.__file__))}
        if tier1_state:
            # Receipts are keyed for the official reader; a new reader must re-qualify.
            identities["tier1-reader"] = tier1_state["tool_sha256"]
        driver_cache = {}
        commands = []
        rc, resource_dir, err = resources.capture([str(compiler), "-print-resource-dir"], cdb.parent, env)
        if rc:
            raise RuntimeError(err)
        resource_dir = resource_dir.strip()
        def driver_for(row):
            query = driver_query_args(row)
            key = tuple(query)
            if key not in driver_cache:
                identities[str(Path(query[0]))] = sha(query[0])
                rc, _, output = resources.capture(query, row["directory"], env)
                if rc:
                    raise RuntimeError("query-driver failed: " + output)
                rc, builtin, err = resources.capture([query[0], "-print-file-name=include"], row["directory"], env)
                if rc:
                    raise RuntimeError("builtin include query failed: " + err)
                driver_cache[key] = parse_driver_output(output, builtin)
            return driver_cache[key]
        receipt = work / "receipt.json"
        run_dir = work / ("run-" + str(time.time_ns()))
        reasons = {}
        def build_variant(task):
            key, command, headers, variant = task
            # Named by the producer input, not the context key: a speculative
            # build is found by its input, and one input is built once per run.
            name = hashlib.sha256(json.dumps(signature(task)[1:]).encode()).hexdigest()[:24]
            directory = run_dir / "artifacts" / name / variant
            directory.mkdir(parents=True)
            argv = [str(probe), str(directory / "metadata.idx"), "--",
                    *producer_args(command, directory / "prefix.pch", headers, compiler)]
            local_env = dict(env)
            if variant == "thin":
                local_env["CLANGD_EXPERIMENTAL_PCH_THIN"] = "1"
            rc, out, err = resources.capture(argv, command["directory"], local_env)
            (directory / "stderr.log").write_text(err, encoding="utf-8")
            write_json(directory / "command.json", argv)
            if rc or not (directory / "prefix.pch").is_file() or not (directory / "metadata.idx").is_file():
                reason = first_error(err) or "exit %s" % rc
                # Bind the failed prefix closure so a header fix retriggers the
                # tool; -MG keeps listing past missing (generated) headers.
                scan = dependency_scan_args(argv[3:])
                rc, out, err = resources.capture(scan, command["directory"], env)
                (directory / "depscan.log").write_text(err, encoding="utf-8")
                closure = parse_depfile(out, command["directory"])
                return None, closure or [os.path.normpath(os.path.join(command["directory"], h))
                                         for h in headers], reason
            return {variant + "_pch": str(directory / "prefix.pch"),
                    variant + "_metadata": str(directory / "metadata.idx")}, [], None
        def producer_tasks(items):
            # full and thin of one context are independent compiles: one flat
            # task list keeps the longest context at max(full, thin) instead of
            # full + thin (R50 cold12: 15 + 10 s on the producer critical path).
            tasks = []
            for key, members in items:
                command = min((command for _, command in members), key=lambda x: sum(map(len, x["arguments"])))
                headers = prefix_headers(command)
                tasks += [(key, command, headers, variant) for variant in ("full", "thin")]
            return tasks
        def signature(task):
            # Everything the producer reads from its task; the output path is a
            # placeholder. The context key is only a label: retry-only rows' keys
            # spell overlays by path, not digest, when no published row names them.
            _, command, headers, variant = task
            return variant, command["directory"], tuple(producer_args(command, Path("pch"), headers, compiler))
        # Speculative producer: contexts whose producer argv Tier 1 substitution
        # does not change are built while prepare (file-IO bound, ~22 s) runs
        # (R50 cold12: 10 of 27 contexts, 82 of 372 producer worker-s). A result
        # is used only for a task with the identical signature. Cold runs only:
        # a receipt may mean reuse, where any producer work is waste.
        # PCH_OFFLINE_SPECULATE=1 enables it (experimental).
        speculative = {}
        if (getattr(args, "tier1_plan", None) and not receipt.is_file()
                and os.environ.get("PCH_OFFLINE_SPECULATE") == "1"):
            try:
                pre_groups = group_contexts(rows, [manifest_command(row, driver_for(row), resource_dir)
                                                   for row in rows])[0]
            except (OSError, ValueError, RuntimeError):
                pre_groups = {}
            if pre_groups:
                spec_pool = concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs)
                for task in producer_tasks(pre_groups.items()):
                    speculative[signature(task)] = spec_pool.submit(build_variant, task)
            report["speculative_tasks"] = len(speculative)
        if getattr(args, "tier1_plan", None):
            # Absorb the background proof's ordinary Tier 1 groups: one private
            # run decides their gates. Any setup failure keeps the rows unchanged.
            begin = time.monotonic()
            try:
                rows, tier1_state = tier1.prepare(rows, args.tier1_plan, args.tier1_clangd,
                                                  getattr(args, "server_profile", None))
            except Exception as error:
                report["tier1_error"] = str(error)[:300]
            report["tier1_prepare_s"] = round(time.monotonic() - begin, 3)
        source_paths = {(row["directory"], row["file"]): str((Path(row["directory"]) / row["file"]).resolve())
                        for row in rows}
        for row in rows:
            commands.append(manifest_command(row, driver_for(row), resource_dir))
        report["setup_commands_s"] = round(time.monotonic() - started, 3)
        identity = hashlib.sha256(json.dumps({k: v for k, v in identities.items() if k != str(cdb)},
                                             sort_keys=True).encode()).hexdigest()
        row_commands = {norm(source_paths[row["directory"], row["file"]]):
                        dict(command=hashlib.sha256(json.dumps(command, sort_keys=True).encode()).hexdigest())
                        for row, command in zip(rows, commands)}
        try:
            previous = json.loads(receipt.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            previous = None
        if isinstance(previous, dict):
            mode, reason, cached = drift_plan(previous, identity, row_commands, target, args.drift_threshold)
            if cached:
                report.update(cached)
                if tier1_state:
                    # Reuse/delta skips judging: only receipts that prepare just
                    # re-validated are collectable; stale prior ids are dropped.
                    report.update(tier1.cached_report(tier1_state))
                return report
            report["full_reason"] = reason
        else:
            report["full_reason"] = "no-receipt"
        run_dir.mkdir(exist_ok=True)
        groups, ordinary, overlay_digests = group_contexts(rows, commands)
        report.update(contexts=len(groups), ordinary_tus=len(ordinary), rows=len(rows))
        phases = report.setdefault("phase_s", {})
        mark = [time.monotonic()]
        def phase(name):
            now = time.monotonic()
            phases[name] = round(now - mark[0], 3)
            mark[0] = now
        phases["setup"] = round(mark[0] - started, 3)
        def produce_all(items, pool, reuse=None):
            tasks = producer_tasks(items)
            reuse = {} if reuse is None else reuse
            # One build per producer input per run (its artifact path is derived from it).
            futures = [reuse.get(signature(task)) or reuse.setdefault(signature(task), pool.submit(build_variant, task))
                       for task in tasks]
            built = {}
            for (key, _, headers, _), future in zip(tasks, futures):
                result = future.result()
                if result[2]:
                    reasons.setdefault(key, result[2])
                built.setdefault(key, (dict(first_header=headers[-1], prefix_headers=headers), []))
                if built[key][0] is None or result[0] is None:
                    built[key] = (None, built[key][1] + result[1])
                else:
                    built[key][0].update(result[0])
            return [(key, profile, closure) for key, (profile, closure) in built.items()]
        profiles, failed_closure, failed_contexts = {}, set(), {}
        if spec_pool:
            # Contexts only the pre-substitution rows have are the Tier 1 original
            # rows' own; they stay for the retry lane's missing contexts below.
            # Unstarted ones are cancelled so they do not delay the producer phase.
            wanted = {signature(task) for task in producer_tasks(groups.items())}
            for name in [name for name in speculative if name not in wanted]:
                if speculative[name].cancel():
                    del speculative[name]
            report["speculative_used"] = len(wanted & speculative.keys())
        pool = spec_pool or concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs)
        try:
            for key, profile, closure in produce_all(groups.items(), pool, speculative):
                if profile:
                    profiles[key] = profile
                else:
                    failed_closure.update(closure)
                    failed_contexts[key] = closure
                    report["producer_failure_context_count"] += 1
                    report["producer_failure_tus"] += [source_paths[row["directory"], row["file"]]
                                                       for row, _ in groups[key]]
        finally:
            # Speculative retry-only contexts may still build; do not wait for them here.
            pool.shutdown(wait=pool is not spec_pool)
        phase("producer")
        # Keep the first diagnostic per failed context so the cause is visible.
        report["producer_failure_reasons"] = dict(sorted(reasons.items()))
        report["producer_failure_tus"] = sorted(set(report["producer_failure_tus"]))
        report["producer_failure_count"] = len(report["producer_failure_tus"])
        paired_rows, manifest_rows, paired_contexts = [], [], []
        for key, members in groups.items():
            if key in profiles:
                for row, command in members:
                    paired_rows.append(row)
                    paired_contexts.append(key)
                    manifest_rows.append(dict(command, profile=key))
        # Fold the Tier 1 retry into the paired clangd: a wrapper that logs a
        # compile failure gets its original UBT rows pushed over LSP at once,
        # while the lane is still busy, instead of a separate retry lane after
        # it (R50 cold12: 44 s phase; failures logged 19-137 s in). Only groups
        # whose every original row has a paired profile; the rest keep the lane.
        # PCH_OFFLINE_FOLD_RETRY=1 enables it (experimental).
        fold, fold_rows = {}, set()
        if tier1_state and os.environ.get("PCH_OFFLINE_FOLD_RETRY") == "1":
            for group in tier1_state["groups"]:
                if group["cached"]:
                    continue
                built = [(row, manifest_command(row, driver_for(row), resource_dir)) for row in group["original_rows"]]
                keys = [context_key(command, overlay_digests) for _, command in built]
                if not built or any(key not in profiles for key in keys):
                    continue
                if len(manifest_rows) + len(built) > 2000:
                    break  # the clangd manifest limit; the rest keep the retry lane
                fold[norm(group["wrapper"])] = [row for row, _ in built]
                # Pushed commands carry no output (ClangdLSPServer::applyConfiguration).
                manifest_rows += [dict(command, output="", profile=key) for (_, command), key in zip(built, keys)]
                fold_rows.update(norm(Path(row["directory"], row["file"]).resolve()) for row, _ in built)
            report["tier1_fold_groups"] = len(fold)
        manifest = run_dir / "manifest.json"
        write_json(manifest, dict(version=1, profiles=profiles, commands=manifest_rows))
        report["manifest"] = str(manifest)
        dependencies = {str(cdb): path_stamp(cdb)}
        dependencies.update({p: path_stamp(p) for p in failed_closure})
        report["producer_failure_dependency_count"] = len(failed_closure)
        edges = {}
        for key, closure in failed_contexts.items():
            edges["context:" + key] = {norm(p) for p in closure}
        shards, shard_owner, rejected = {}, {}, set()
        lanes = []
        lane_specs = [(name, lane_rows, lane_manifest, lane_contexts)
                      for name, lane_rows, lane_manifest, lane_contexts in (
                          ("ordinary", ordinary, None, None), ("paired", paired_rows, manifest, paired_contexts))
                      if lane_rows]
        def index_lane(spec):
            name, lane_rows, lane_manifest, lane_contexts = spec
            lane = run_dir / name
            write_json(lane / "compile_commands.json", lane_rows)
            order = write_index_order(lane, lane_rows, lane_contexts)
            return index_workspace(lane, clangd, env, resources, args.jobs, resource_dir, args.timeout,
                                   lane_manifest, order, fold if name == "paired" else None)
        # The lanes share nothing (own directory, own clangd); the few no-PCH
        # TUs fill the paired lane's seed ramp instead of running before it
        # (R50 cold12: ordinary 7 s serial; paired occupancy 0-9 in its first 10 s).
        # Results are consumed in the original lane order below.
        # PCH_OFFLINE_SERIAL_LANES=1 restores the serial order (A/B measurement).
        lane_workers = 1 if os.environ.get("PCH_OFFLINE_SERIAL_LANES") == "1" else max(1, len(lane_specs))
        with concurrent.futures.ThreadPoolExecutor(max_workers=lane_workers) as pool:
            summaries = list(pool.map(index_lane, lane_specs))
        phase("index_lanes")
        for (name, _, _, _), summary in zip(lane_specs, summaries):
            lane = run_dir / name
            lanes.append(summary)
            for key in ("paired", "mismatch", "unlisted"):
                report[key] += summary[key]
            report["compile_failure_tus"] += [str(Path(p).resolve()) for p in summary["compile_failure_tus"]]
            # Decode is file-open bound on Windows (R50: 32k shards, 24 s serial).
            paths = sorted((lane / ".cache/clangd/index").glob("*.idx"))
            with concurrent.futures.ThreadPoolExecutor(max_workers=IO_THREADS) as pool:
                decoded = list(pool.map(shard_graph, paths))
                stamped = {p for nodes in decoded for p in nodes} - dependencies.keys()
                dependencies.update(zip(stamped, pool.map(path_stamp, stamped)))
            for shard, nodes in zip(paths, decoded):
                sources = {file: flags for file, (flags, _) in nodes.items()}
                # HadErrors shards cannot be published, but their dependency
                # graph must invalidate a cached failure when a header is fixed.
                for file, (_, includes) in nodes.items():
                    edges.setdefault(norm(file), set()).update(norm(p) for p in includes)
                for file in sources:
                    shard_owner[norm(file)] = shard.name
                if any(flags & 2 for flags in sources.values()):
                    rejected.add(shard.name)
                    continue
                shards[shard.name] = shard
            phase("graph_" + name)
        if report["mismatch"] or report["unlisted"]:
            raise RuntimeError("manifest command matching failed; no shards published")
        target.mkdir(parents=True, exist_ok=True)
        def publish(items):
            # Each shard is an independent atomic copy; threads overlap per-file
            # open/close latency (R50: 31k shards, 78 s serial; 3000-shard bench 5.1 → 2.1 s).
            with concurrent.futures.ThreadPoolExecutor(max_workers=IO_THREADS) as pool:
                done = list(pool.map(lambda item: publish_shard(item[1], target / item[0]), items))
            return [name for (name, _), ok in zip(items, done) if not ok]
        def commit(verdicts):
            begin = time.monotonic()
            return tier1.commit(tier1_state, verdicts, identities[str(clangd)]), round(time.monotonic() - begin, 3)
        # A clean TU whose closure reaches a header shard owned by a failed TU
        # (HadErrors, unpublished) is rebuilt by the official reader too (R47: 8).
        tier1_verdicts, tier1_mapping, retry_covered = {}, {}, set()
        side = concurrent.futures.ThreadPoolExecutor(max_workers=2)
        committed = None
        if tier1_state:
            tier1_verdicts, dropped, tier1_mapping = tier1.judge(
                tier1_state, report["compile_failure_tus"], report["producer_failure_tus"], shard_owner, shards)
            if fold:
                # Folded original rows the paired clangd indexed cleanly keep
                # their (rewritten, clean) shards; judge drops every shard the
                # failed wrapper's members own.
                tried = {norm(Path(p).resolve()) for summary in summaries for p in summary.get("injected", ())}
                failed = {norm(p) for p in report["compile_failure_tus"]}
                rejected_files = {file for file, name in shard_owner.items() if name in rejected}
                blocked = {norm(p) for p in reaching_sources(edges, sorted(tried), rejected_files)}
                retry_covered = {p for p in tried if p not in failed and p not in blocked
                                 and shard_owner.get(p) in shards}
                dropped = set(dropped) - fold_kept_shards(retry_covered, edges, shard_owner, shards)
                report["tier1_fold_tus"], report["tier1_fold_covered"] = len(tried), len(retry_covered)
            # An unqualified wrapper's shards never reach the reader; its original
            # UBT rows stay in the published CDB and are indexed there.
            for name in dropped:
                shards.pop(name, None)
            report["tier1_dropped_shards"] = len(dropped)
            phase("tier1_judge")
            # Receipts depend only on the verdicts; write them while the retry
            # lane indexes (R50 cold6: commit 18 s + publish 25 s ran after it).
            committed = side.submit(commit, tier1_verdicts)
        # Published paired shards never change: retry only adds names (a clean
        # copy of a rejected shard), published below once it finishes.
        first_batch = list(shards.items())
        published = side.submit(publish, first_batch)
        if tier1_state:
            retry, missing = [], {}
            for row in tier1.retry_rows(tier1_state, tier1_verdicts):
                if norm(Path(row["directory"], row["file"]).resolve()) in fold_rows:
                    continue  # already tried in the paired clangd
                command = manifest_command(row, driver_for(row), resource_dir)
                key = context_key(command, overlay_digests)
                if key in profiles:
                    retry.append((row, command, key))
                elif key != "no-pch" and key not in failed_contexts:
                    missing.setdefault(key, []).append((row, command))
            # Original rows can form a PCH context no published row has (the
            # failed wrapper's own context differs): build its prefix now (R50
            # cold4: 6 CoreUObject TUs otherwise fell back to the reader).
            if missing:
                with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as pool:
                    for key, profile, _ in produce_all(missing.items(), pool, speculative):
                        if profile:
                            profiles[key] = profile
                            retry += [(row, command, key) for row, command in missing[key]]
                report["tier1_retry_new_contexts"] = sum(key in profiles for key in missing)
            if retry:
                # Union, not assignment: folded rows the paired clangd already
                # covered stay covered (R50 cold40: 45 folded rows reported as
                # fallback because the 6-row retry lane overwrote the set).
                lane_covered = retry_lane(run_dir, retry, groups, profiles, clangd, env, resources, args, resource_dir,
                                          report, shards, shard_owner, rejected, edges, dependencies)
                retry_covered = retry_covered | lane_covered
                report["tier1_retry_tus"], report["tier1_retry_covered"] = len(retry), len(lane_covered)
                phase("index_retry")
        rejected_files = {file for file, name in shard_owner.items() if name in rejected}
        report["dependency_fallback_tus"] = sorted(
            reaching_sources(edges, [source_paths[row["directory"], row["file"]] for row in rows], rejected_files))
        # Bind forced inputs, overlay mappings and their external contents too. An
        # overlay is a root on its own: shard include graphs already name the
        # external files a TU really read, so mapped files need no extra edges.
        # Real CDBs repeat the same 25k-entry overlay across hundreds of rows
        # (R47: 633 per-row copies, one content, 16M entries / 25215 unique files);
        # parse each distinct overlay content once and stat each external once.
        overlay_externals = {}
        def overlay_dependencies(p, digest):
            if digest not in overlay_externals:
                found = set()
                def visit(value):
                    if isinstance(value, dict):
                        if "external-contents" in value:
                            found.add(value["external-contents"])
                        for child in value.values():
                            visit(child)
                    elif isinstance(value, list):
                        for child in value:
                            visit(child)
                visit(json.loads(Path(p).read_text(encoding="utf-8-sig")))
                overlay_externals[digest] = found
                for external in found - dependencies.keys():
                    dependencies[external] = path_stamp(external)
        row_receipts = {}
        for row in rows:
            source = source_paths[row["directory"], row["file"]]
            dependencies[source] = path_stamp(source)
            failed_key = next((key for key in failed_contexts
                               if any(member is row for member, _ in groups[key])), None)
            row_receipts[norm(source)] = dict(row_commands[norm(source)],
                                              roots=row_roots(row, source, failed_key))
            for i, token in enumerate(row["arguments"][:-1]):
                if token in ("-include", "-ivfsoverlay"):
                    p = str(Path(row["directory"]) / row["arguments"][i + 1])
                    dependencies[p] = path_stamp(p)
                    if token == "-ivfsoverlay":
                        overlay_dependencies(p, overlay_digests.get(row["arguments"][i + 1]) or sha(p))
        phase("row_receipts")
        first_names = {name for name, _ in first_batch}
        contended = published.result() + publish([item for item in shards.items() if item[0] not in first_names])
        for name in contended:
            # A running reader holds this shard; it keeps its own equivalent copy.
            del shards[name]
        report["contended_shards"] = len(contended)
        phase("publish")
        report.update(ok=True, shards=len(shards), lanes=lanes, indexing_complete=True)
        report["compile_failure_tus"] = sorted(set(report["compile_failure_tus"]))
        report["compile_failure_count"] = len(report["compile_failure_tus"])
        report["fallback_tus"] = tier1.fallback_tus(
            tier1_state, tier1_verdicts, tier1_mapping,
            report["compile_failure_tus"] + report["producer_failure_tus"] + report["dependency_fallback_tus"],
            retry_covered)
        report["fallback_count"] = len(report["fallback_tus"])
        if committed:
            fields, phases["tier1_commit_busy"] = committed.result()
            report.update(fields)
            phase("tier1_receipts")
        report["elapsed_s"] = round(time.monotonic() - started, 3)
        # A completed run can be partial: failed TUs remain in the unchanged CDB
        # for ordinary clangd, and are not retried offline until inputs change.
        write_json(receipt, dict(version=2, identity=identity, dependencies=dependencies, rows=row_receipts,
                   graph={node: sorted(children) for node, children in edges.items()},
                   shards={name: path_stamp(target / name) for name in shards}, report=report))
        phase("receipt")
    except Exception as error:
        report["error"] = str(error)
    finally:
        if side is not None:
            side.shutdown(wait=True)
        if spec_pool is not None:
            spec_pool.shutdown(wait=True, cancel_futures=True)
        resources.close()
        report.update(elapsed_s=round(time.monotonic() - started, 3), peak_process_bytes=resources.peak_bytes,
                      min_available_bytes=resources.min_available, child_cpu_s=round(resources.cpu_seconds, 3))
        if lock_fd is not None:
            os.close(lock_fd)
    return report


def positive_jobs(value):
    count = int(value)
    if count < 1:
        raise argparse.ArgumentTypeError("jobs must be a positive integer")
    return count


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cdb", required=True)
    parser.add_argument("--index-dir", required=True)
    parser.add_argument("--bin-dir", required=True)
    parser.add_argument("--compiler")
    parser.add_argument("-j", "--jobs", type=positive_jobs, default=2)
    parser.add_argument("--timeout", type=int, default=1800)
    parser.add_argument("--process-gib", type=positive_jobs, default=16,
                        help="memory cap per owned child process (GiB); the host 8 GiB reserve still applies")
    parser.add_argument("--drift-threshold", type=float, default=0.5,
                        help="affected-TU ratio above which the offline run repeats in full")
    parser.add_argument("--report")
    parser.add_argument("--tier1-plan", help="background proof plan.json whose ordinary Tier 1 groups are absorbed")
    parser.add_argument("--tier1-clangd", help="official reader clangd that Tier 1 receipts are keyed for")
    parser.add_argument("--server-profile", type=json.loads, default=None)
    args = parser.parse_args()
    if args.tier1_plan and not args.tier1_clangd:
        parser.error("--tier1-plan requires --tier1-clangd")
    report = run(args)
    if args.report:
        write_json(args.report, report)
    print(json.dumps(report, ensure_ascii=False))
    return 0 if report["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
