"""
Check if the game is actually running after debugger attach+continue.
1. Attach, continue (no BPs)
2. Wait 5s, pause
3. Get GameThread stack trace — is it in tick loop or stuck?
4. Also test: is SW BP writable at correct ASLR'd address?
"""
import json
import re
import select
import socket
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import tools.android_lldb_probe as probe
from tools.sanitized_test_config import CODELLDB_ROOT

CODELLDB_ADAPTER = CODELLDB_ROOT / "adapter" / "codelldb.exe"
CODELLDB_LIBLLDB = CODELLDB_ROOT / "lldb" / "bin" / "liblldb.dll"
SYMBOLS = probe.DEFAULT_SYMBOLS


def p(msg):
    print(msg, flush=True)


class DAPClient:
    def __init__(self, sock):
        self.sock = sock
        self.seq = 1
        self.buf = bytearray()
    def close(self):
        try: self.sock.close()
        except: pass
    def send(self, payload):
        body = json.dumps(payload).encode()
        header = f"Content-Length: {len(body)}\r\n\r\n".encode("ascii")
        self.sock.sendall(header + body)
    def request(self, command, arguments=None):
        seq = self.seq; self.seq += 1
        self.send({"seq": seq, "type": "request", "command": command, "arguments": arguments or {}})
        return seq
    def read_one(self, timeout=30):
        deadline = time.time() + timeout
        while True:
            h = self.buf.find(b"\r\n\r\n")
            if h != -1:
                hdrs = {}
                for line in bytes(self.buf[:h]).decode("ascii").split("\r\n"):
                    if ":" in line:
                        k, v = line.split(":", 1)
                        hdrs[k.strip().lower()] = v.strip()
                n = int(hdrs["content-length"])
                total = h + 4 + n
                if len(self.buf) >= total:
                    msg = json.loads(bytes(self.buf[h + 4:total]))
                    del self.buf[:total]
                    return msg
            rem = deadline - time.time()
            if rem <= 0: raise TimeoutError()
            r, _, _ = select.select([self.sock], [], [], rem)
            if not r: raise TimeoutError()
            chunk = self.sock.recv(65536)
            if not chunk: raise RuntimeError("closed")
            self.buf.extend(chunk)
    def collect_until(self, pred, timeout=60):
        msgs = []
        deadline = time.time() + timeout
        while True:
            rem = deadline - time.time()
            if rem <= 0: return msgs, None
            try: msg = self.read_one(timeout=min(rem, 3))
            except TimeoutError: continue
            msgs.append(msg)
            t, ev = msg.get("type"), msg.get("event")
            if t == "event" and ev == "output":
                out = (msg.get("body") or {}).get("output", "").rstrip()
                if out and len(out) < 300: p(f"  [output] {out}")
            elif t == "event":
                p(f"  [{ev}] {json.dumps(msg.get('body',{}), default=str)[:200]}")
            elif t == "response":
                p(f"  [resp:{msg.get('command','?')}] success={msg.get('success')}")
            if pred(msg): return msgs, msg
    def eval_repl(self, cmd, fid=None, timeout=15):
        seq = self.request("evaluate", {"expression": cmd, "context": "repl", **({"frameId": fid} if fid else {})})
        outputs = []
        msgs, resp = self.collect_until(lambda m: m.get("type") == "response" and m.get("request_seq") == seq, timeout=timeout)
        for m in msgs:
            if m.get("type") == "event" and m.get("event") == "output":
                outputs.append((m.get("body") or {}).get("output", ""))
        result = (resp.get("body") or {}).get("result", "") if resp else ""
        return result, "\n".join(outputs)


def allocate_port():
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]

def connect_client(port, timeout=15):
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            s = socket.create_connection(("127.0.0.1", port), timeout=2)
            s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            return DAPClient(s)
        except OSError: time.sleep(0.2)
    raise RuntimeError("connect failed")


def aslr_fix_script(pid):
    lines = [
        "ci=lldb.debugger.GetCommandInterpreter()",
        "ro=lldb.SBCommandReturnObject()",
        f"ci.HandleCommand('platform shell cat /proc/{pid}/maps',ro)",
        "o=ro.GetOutput() if ro.Succeeded() else ''",
        "lines=[l for l in o.splitlines() if 'libUE4.so' in l]",
        "base=int(lines[0].split('-')[0],16) if lines else 0",
        "ci.HandleCommand('target modules load --file libUE4.so --slide 0x%x'%base,lldb.SBCommandReturnObject()) if base else None",
    ]
    return 'script exec("' + "\\n".join(lines) + '")'


def main():
    probe.ensure_adb_ready()
    probe.cleanup_device()
    probe.stage_platform_bits(probe.AS2024_LLDB_SERVER)

    pid = probe.resolve_pid()
    bridge, connect_uri, _, serial = probe.start_platform_server(pid)
    p(f"pid={pid} serial={serial}")

    adapter_proc = client = None
    try:
        port = allocate_port()
        adapter_proc = subprocess.Popen(
            [str(CODELLDB_ADAPTER), "--port", str(port), "--liblldb", str(CODELLDB_LIBLLDB)],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        )
        client = connect_client(port)

        seq = client.request("initialize", {"adapterID": "codelldb", "linesStartAt1": True, "columnsStartAt1": True, "pathFormat": "path"})
        client.collect_until(lambda m: m.get("type") == "response" and m.get("request_seq") == seq, timeout=15)

        target_create = [f'target create "{SYMBOLS}"']
        for ps in probe.DEFAULT_EXEC_SEARCH:
            target_create.append(f'settings append target.exec-search-paths "{ps}"')

        attach_seq = client.request("attach", {
            "type": "codelldb", "request": "attach", "breakpointMode": "file",
            "program": str(SYMBOLS), "sourceLanguages": ["cpp"],
            "initCommands": [
                "settings set stop-disassembly-display never",
                "settings set target.inline-breakpoint-strategy always",
                "settings set target.move-to-nearest-code true",
                "platform select remote-android",
            ],
            "targetCreateCommands": target_create,
            "processCreateCommands": [
                f'platform connect "{connect_uri}"',
                f"process attach -p {pid}",
                aslr_fix_script(pid),
                "settings set target.process.thread.step-avoid-regexp ''",
                "process handle SIGSTOP -p true -s false -n false",
                "process handle SIGSEGV -p true -s false -n false",
                "process handle SIGBUS -p true -s false -n false",
                "process handle SIGPIPE -p true -s false -n false",
            ],
            "preTerminateCommands": ["process detach"],
        })

        client.collect_until(lambda m: m.get("type") == "event" and m.get("event") == "initialized", timeout=90)
        client.request("configurationDone")

        # Wait for stopped
        stopped_evt = None
        deadline = time.time() + 60
        while time.time() < deadline:
            try: msg = client.read_one(timeout=3)
            except TimeoutError:
                if stopped_evt: break
                continue
            t, ev = msg.get("type"), msg.get("event")
            if t == "event" and ev == "stopped":
                stopped_evt = msg
                p(f"  [stopped] {(msg.get('body') or {}).get('reason')}")
            elif t == "event" and ev == "output":
                out = (msg.get("body") or {}).get("output", "").rstrip()
                if out and len(out) < 200: p(f"  [output] {out}")
            elif t == "response":
                p(f"  [resp:{msg.get('command')}]")

        tid = (stopped_evt.get("body") or {}).get("threadId") or int(pid)
        p(f"\nAttached. tid={tid}")

        # Continue with NO breakpoints — just let it run
        p("\n=== Continue (no BPs) and wait 5s ===")
        cont_seq = client.request("continue", {"threadId": tid})
        client.collect_until(lambda m: m.get("type") == "response" and m.get("request_seq") == cont_seq, timeout=10)

        # Wait 5 seconds
        time.sleep(5)

        # Pause
        p("=== Pausing after 5s ===")
        pause_seq = client.request("pause", {"threadId": int(pid)})
        msgs, stop2 = client.collect_until(
            lambda m: m.get("type") == "event" and m.get("event") == "stopped", timeout=10)
        if not stop2:
            p("ERROR: pause failed!")
            return

        # Get threads
        p("\n=== Getting thread list ===")
        th_seq = client.request("threads")
        msgs, th_resp = client.collect_until(
            lambda m: m.get("type") == "response" and m.get("request_seq") == th_seq, timeout=15)
        threads = (th_resp.get("body") or {}).get("threads", []) if th_resp else []

        # Find GameThread
        game_threads = [t for t in threads if "GameThread" in (t.get("name") or "")]
        render_threads = [t for t in threads if "RenderThread" in (t.get("name") or "")]
        p(f"  Total threads: {len(threads)}")
        p(f"  GameThread(s): {[(t['id'], t.get('name','')) for t in game_threads]}")
        p(f"  RenderThread(s): {[(t['id'], t.get('name','')) for t in render_threads]}")

        # Get stack trace for each GameThread
        for gt in game_threads[:3]:
            p(f"\n=== GameThread tid={gt['id']} ({gt.get('name','')}) stack ===")
            st_seq = client.request("stackTrace", {"threadId": gt["id"], "startFrame": 0, "levels": 15})
            msgs, st_resp = client.collect_until(
                lambda m: m.get("type") == "response" and m.get("request_seq") == st_seq, timeout=15)
            if st_resp:
                frames = (st_resp.get("body") or {}).get("stackFrames") or []
                for f in frames[:15]:
                    src = (f.get("source") or {}).get("name", "")
                    p(f"  {f.get('name','?')} ({src}:{f.get('line','')})")

        # Get stack trace for RenderThread
        for rt in render_threads[:2]:
            p(f"\n=== RenderThread tid={rt['id']} ({rt.get('name','')}) stack ===")
            st_seq = client.request("stackTrace", {"threadId": rt["id"], "startFrame": 0, "levels": 10})
            msgs, st_resp = client.collect_until(
                lambda m: m.get("type") == "response" and m.get("request_seq") == st_seq, timeout=15)
            if st_resp:
                frames = (st_resp.get("body") or {}).get("stackFrames") or []
                for f in frames[:10]:
                    src = (f.get("source") or {}).get("name", "")
                    p(f"  {f.get('name','?')} ({src}:{f.get('line','')})")

        # Also check: main thread (PID thread) stack
        main_tid = int(pid)
        p(f"\n=== Main thread tid={main_tid} stack ===")
        st_seq = client.request("stackTrace", {"threadId": main_tid, "startFrame": 0, "levels": 10})
        msgs, st_resp = client.collect_until(
            lambda m: m.get("type") == "response" and m.get("request_seq") == st_seq, timeout=15)
        if st_resp:
            frames = (st_resp.get("body") or {}).get("stackFrames") or []
            for f in frames[:10]:
                src = (f.get("source") or {}).get("name", "")
                p(f"  {f.get('name','?')} ({src}:{f.get('line','')})")

        # Quick test: check process status via LLDB
        p("\n=== Process status ===")
        # Need a frameId for eval
        st_seq = client.request("stackTrace", {"threadId": (stop2.get("body") or {}).get("threadId") or main_tid, "startFrame": 0, "levels": 1})
        msgs, st_resp = client.collect_until(lambda m: m.get("type") == "response" and m.get("request_seq") == st_seq, timeout=10)
        fid = None
        if st_resp:
            frs = (st_resp.get("body") or {}).get("stackFrames") or []
            if frs: fid = frs[0]["id"]
        result, output = client.eval_repl("process status", fid)
        p(f"  {(output+result).strip()[:300]}")

        # Disconnect
        seq = client.request("disconnect", {"terminateDebuggee": False})
        try: client.collect_until(lambda m: m.get("type") == "response" and m.get("request_seq") == seq, timeout=10)
        except: pass

    finally:
        if client: client.close()
        if adapter_proc:
            try:
                adapter_proc.kill()
                _, stderr = adapter_proc.communicate(timeout=5)
                if stderr and stderr.strip(): p(f"\n=== Adapter stderr ===\n{stderr.strip()}")
            except: pass
        if bridge:
            try: bridge.kill(); bridge.communicate(timeout=3)
            except: pass
        probe.cleanup_device()


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        import traceback
        print(f"\nFATAL: {exc}", file=sys.stderr)
        traceback.print_exc(file=sys.stderr)
        sys.exit(1)
