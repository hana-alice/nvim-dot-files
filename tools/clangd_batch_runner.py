"""Bounded private BackgroundIndex run used to verify a proposed batch.

The process, CDB, logs and both workspace/global shard stores are owned by this
run. Completion is LSP progress plus actual main-file shards; it is not an
assertion that compilation or graph equivalence succeeded. Never attaches to
or controls the user's compiler process.
"""
import argparse
import ctypes
from ctypes import wintypes
import hashlib
import json
import os
from pathlib import Path
import queue
import subprocess
import shutil
import threading
import time
from collections import deque


def process_metrics(process):
    if os.name != 'nt':
        return {'cpu_seconds': None, 'peak_working_set_bytes': None}
    class Counters(ctypes.Structure):
        _fields_ = [('cb', wintypes.DWORD), ('PageFaultCount', wintypes.DWORD)] + [
            (name, ctypes.c_size_t) for name in ('PeakWorkingSetSize', 'WorkingSetSize',
                'QuotaPeakPagedPoolUsage', 'QuotaPagedPoolUsage', 'QuotaPeakNonPagedPoolUsage',
                'QuotaNonPagedPoolUsage', 'PagefileUsage', 'PeakPagefileUsage')]
    counters = Counters()
    counters.cb = ctypes.sizeof(counters)
    memory = ctypes.windll.psapi.GetProcessMemoryInfo
    memory.argtypes = [wintypes.HANDLE, ctypes.c_void_p, wintypes.DWORD]
    memory_ok = memory(wintypes.HANDLE(int(process._handle)), ctypes.byref(counters), counters.cb)
    stamps = [wintypes.FILETIME() for _ in range(4)]
    times = ctypes.windll.kernel32.GetProcessTimes
    times.argtypes = [wintypes.HANDLE] + [ctypes.POINTER(wintypes.FILETIME)] * 4
    times_ok = times(wintypes.HANDLE(int(process._handle)), *(ctypes.byref(s) for s in stamps))
    cpu = sum((s.dwHighDateTime << 32) | s.dwLowDateTime for s in stamps[2:]) / 10000000
    return {'cpu_seconds': round(cpu, 4) if times_ok else None,
            'peak_working_set_bytes': counters.PeakWorkingSetSize if memory_ok else None}


def normalize_server_profile(profile):
    """Accept only the semantic server configuration covered by this collector."""
    if profile is None:
        return None
    if not isinstance(profile, dict) or set(profile) != {'query_driver', 'launch_cwd', 'enable_config'}:
        raise ValueError('unsupported-server-profile-fields')
    if profile['enable_config'] is not False:
        raise ValueError('unsupported-server-profile-config')
    query = profile['query_driver']
    if not isinstance(query, str) or not query or any(char in query for char in '\0\r\n'):
        raise ValueError('invalid-server-profile-query-driver')
    cwd = profile['launch_cwd']
    if not isinstance(cwd, str) or not Path(cwd).is_absolute() or not Path(cwd).is_dir():
        raise ValueError('invalid-server-profile-launch-cwd')
    return {'query_driver': query, 'launch_cwd': Path(cwd).resolve().as_posix(), 'enable_config': False}


def run(cdb_dir, out_dir, trigger, clangd, timeout=90, jobs=1, server_profile=None):
    cdb_dir, out_dir, trigger = (Path(path).resolve() for path in (cdb_dir, out_dir, trigger))
    profile = normalize_server_profile(server_profile)
    out_dir.mkdir(parents=True, exist_ok=True)
    environment = out_dir / 'environment'
    environment.mkdir(exist_ok=True)
    env = dict(os.environ)
    env.update({'LOCALAPPDATA': str(environment), 'XDG_CACHE_HOME': str(environment / 'cache'),
                'TEMP': str(environment), 'TMP': str(environment)})
    entries = json.loads((cdb_dir / 'compile_commands.json').read_text(encoding='utf-8-sig'))
    command = [str(clangd), '--compile-commands-dir=' + str(cdb_dir), '--background-index',
               '--enable-config=false', '-j=' + str(max(1, int(jobs))), '--log=info']
    if profile:
        command.append('--query-driver=' + profile['query_driver'])
    launch_cwd = profile['launch_cwd'] if profile else str(cdb_dir)
    started = time.monotonic()
    process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
        stderr=subprocess.PIPE, cwd=launch_cwd, env=env,
        creationflags=(subprocess.CREATE_NO_WINDOW | subprocess.IDLE_PRIORITY_CLASS) if os.name == 'nt' else 0)
    messages = queue.Queue()
    stdout_log = (out_dir / 'lsp-received.ndjson').open('w', encoding='utf-8')
    sent_log = (out_dir / 'lsp-sent.ndjson').open('w', encoding='utf-8')
    stderr_log = (out_dir / 'clangd.stderr.log').open('wb')
    stderr_lines = deque(maxlen=512)
    compile_failures = []
    compile_failure_count = 0

    def read_stdout():
        try:
            while True:
                headers = {}
                while True:
                    line = process.stdout.readline()
                    if not line:
                        return
                    if line in (b'\r\n', b'\n'):
                        break
                    key, value = line.decode('ascii').split(':', 1)
                    headers[key.lower()] = value.strip()
                body = process.stdout.read(int(headers['content-length']))
                message = json.loads(body)
                stdout_log.write(json.dumps({'seconds': round(time.monotonic() - started, 4), 'message': message}) + '\n')
                stdout_log.flush()
                messages.put(message)
        except Exception as error:
            messages.put({'reader_error': repr(error)})

    def read_stderr():
        nonlocal compile_failure_count
        for line in iter(process.stderr.readline, b''):
            stderr_log.write(line)
            stderr_log.flush()
            decoded = line.decode('utf-8', errors='replace').rstrip()
            stderr_lines.append(decoded)
            if 'Failed to compile ' in decoded:
                compile_failure_count += 1
                if len(compile_failures) < 32:
                    compile_failures.append(decoded)

    readers = [threading.Thread(target=read_stdout, daemon=True), threading.Thread(target=read_stderr, daemon=True)]
    for reader in readers:
        reader.start()

    def send(message):
        encoded = json.dumps(message, separators=(',', ':')).encode('utf-8')
        process.stdin.write(('Content-Length: %d\r\n\r\n' % len(encoded)).encode('ascii') + encoded)
        process.stdin.flush()
        sent_log.write(json.dumps({'seconds': round(time.monotonic() - started, 4), 'message': message}) + '\n')
        sent_log.flush()

    def handle(message):
        if 'id' in message and 'method' in message:
            send({'jsonrpc': '2.0', 'id': message['id'], 'result': None})

    initialized = False
    progress = []
    progress_end = None
    complete = False
    expected_names = [Path(entry['file']).name + '.' for entry in entries]
    observed_shards = []
    deadline = started + timeout
    try:
        send({'jsonrpc': '2.0', 'id': 1, 'method': 'initialize', 'params': {
            'processId': os.getpid(), 'rootUri': cdb_dir.as_uri(),
            'capabilities': {'window': {'workDoneProgress': True}},
            'workspaceFolders': [{'uri': cdb_dir.as_uri(), 'name': 'isolated-probe'}]}})
        while time.monotonic() < deadline and process.poll() is None:
            try:
                message = messages.get(timeout=0.2)
            except queue.Empty:
                message = {}
            handle(message)
            if message.get('id') == 1 and 'result' in message and not initialized:
                initialized = True
                send({'jsonrpc': '2.0', 'method': 'initialized', 'params': {}})
                send({'jsonrpc': '2.0', 'method': 'textDocument/didOpen', 'params': {'textDocument': {
                    'uri': trigger.as_uri(), 'languageId': 'cpp', 'version': 1,
                    'text': trigger.read_text(encoding='utf-8')}}})
            if message.get('method') == '$/progress':
                event = {'seconds': round(time.monotonic() - started, 4), **message['params']}
                progress.append(event)
                if event.get('value', {}).get('kind') == 'end':
                    progress_end = time.monotonic()
            if progress_end and time.monotonic() - progress_end >= 0.8:
                observed_shards = list(cdb_dir.rglob('*.idx')) + list(environment.rglob('*.idx'))
                present = {path.name for path in observed_shards}
                if all(any(name.startswith(prefix) for name in present) for prefix in expected_names):
                    complete = True
                    break
        indexed_wall = time.monotonic() - started
        before_shutdown = process_metrics(process)
        shutdown_response = False
        if process.poll() is None:
            send({'jsonrpc': '2.0', 'id': 2, 'method': 'shutdown', 'params': None})
            shutdown_deadline = time.monotonic() + 8
            while time.monotonic() < shutdown_deadline and process.poll() is None:
                try:
                    message = messages.get(timeout=0.2)
                except queue.Empty:
                    continue
                handle(message)
                if message.get('id') == 2:
                    shutdown_response = True
                    break
            send({'jsonrpc': '2.0', 'method': 'exit', 'params': None})
            try:
                process.wait(timeout=8)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
        metrics = process_metrics(process)
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()
        for reader in readers:
            reader.join(timeout=2)
        stdout_log.close()
        sent_log.close()
        stderr_log.close()
    observed_shards = sorted({str(path) for path in list(cdb_dir.rglob('*.idx')) + list(environment.rglob('*.idx'))})
    present = {Path(path).name for path in observed_shards}
    missing = [prefix for prefix in expected_names if not any(name.startswith(prefix) for name in present)]
    report = {'command': command, 'server_profile': profile, 'launch_cwd': Path(launch_cwd).as_posix(),
        'isolated_environment': {key: env[key] for key in ('LOCALAPPDATA', 'XDG_CACHE_HOME', 'TEMP', 'TMP')},
        'cdb_sha256': hashlib.sha256((cdb_dir / 'compile_commands.json').read_bytes()).hexdigest(),
        'initialized': initialized, 'indexing_complete': complete, 'shutdown_response': shutdown_response,
        'indexing_wall_seconds': round(indexed_wall, 4), 'process_wall_seconds': round(time.monotonic() - started, 4),
        'exit_code': process.returncode, 'progress': progress, 'shard_count': len(observed_shards),
        'shards': observed_shards, 'missing_main_shards': missing, 'before_shutdown_metrics': before_shutdown,
        **metrics, 'indexing_log_lines': [line for line in stderr_lines if 'Indexed ' in line or 'Enqueueing ' in line],
        'error_lines': [line for line in stderr_lines if line.startswith('E[')],
        'compile_failure_lines': compile_failures, 'compile_failure_count': compile_failure_count,
        'background_compile_success': complete and process.returncode == 0 and compile_failure_count == 0}
    (out_dir / 'run.json').write_text(json.dumps(report, indent=2), encoding='utf-8')
    return report


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--cdb-dir', required=True)
    parser.add_argument('--out-dir', required=True)
    parser.add_argument('--trigger', required=True)
    parser.add_argument('--clangd', default=os.environ.get('UE_CLANGD') or shutil.which('clangd'))
    parser.add_argument('--timeout', type=int, default=90)
    args = parser.parse_args()
    if not args.clangd:
        parser.error('clangd is unavailable; supply the existing --clangd executable')
    result = run(args.cdb_dir, args.out_dir, args.trigger, args.clangd, args.timeout)
    print(json.dumps({key: value for key, value in result.items() if key not in ('shards', 'progress', 'error_lines')}, indent=2))
    raise SystemExit(0 if result['background_compile_success'] else 1)
