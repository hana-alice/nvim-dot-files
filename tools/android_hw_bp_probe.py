"""
Focused probe: hardware breakpoint at FVulkanCmdBuffer::Begin, 90s wait.
"""
import json, select, socket, subprocess, sys, time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import tools.android_lldb_probe as android_probe
from tools.sanitized_test_config import CODELLDB_ROOT, ENGINE_ROOT, PROJECT_ROOT

CODELLDB_ADAPTER = CODELLDB_ROOT / "adapter" / "codelldb.exe"
CODELLDB_LIBLLDB = CODELLDB_ROOT / "lldb" / "bin" / "liblldb.dll"
SYMBOLS = android_probe.DEFAULT_SYMBOLS


def p(msg): print(msg, flush=True)


def allocate_port():
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class DAPClient:
    def __init__(self, sock):
        self.sock = sock; self.seq = 1; self.buf = bytearray()

    def close(self):
        try: self.sock.close()
        except Exception: pass

    def send(self, payload):
        body = json.dumps(payload).encode()
        self.sock.sendall(f"Content-Length: {len(body)}\r\n\r\n".encode("ascii") + body)

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
            if rem <= 0: raise TimeoutError("DAP read timeout")
            r, _, _ = select.select([self.sock], [], [], rem)
            if not r: raise TimeoutError("DAP read timeout")
            chunk = self.sock.recv(65536)
            if not chunk: raise RuntimeError("DAP stream closed")
            self.buf.extend(chunk)

    def wait_for(self, pred, timeout=30):
        deadline = time.time() + timeout
        while True:
            rem = deadline - time.time()
            if rem <= 0: raise TimeoutError(f"wait_for timeout after {timeout}s")
            try: msg = self.read_one(timeout=min(rem, 3))
            except TimeoutError: continue
            t, ev = msg.get("type"), msg.get("event")
            if t == "event" and ev == "output":
                body = msg.get("body") or {}
                out = body.get("output", "").rstrip()
                if out: p(f"  [output/{body.get('category','?')}] {out}")
            if pred(msg): return msg

    def resp(self, seq, timeout=20):
        msg = self.wait_for(lambda m: m.get("type") == "response" and m.get("request_seq") == seq, timeout=timeout)
        if not msg.get("success"): raise RuntimeError(f"request failed: {msg.get('message','?')}")
        return msg

    def get_frame_id(self, thread_id, timeout=15):
        seq = self.request("stackTrace", {"threadId": thread_id, "startFrame": 0, "levels": 1})
        resp = self.resp(seq, timeout=timeout)
        frames = (resp.get("body") or {}).get("stackFrames") or []
        return frames[0]["id"] if frames else None

    def eval_cmd(self, cmd, frame_id=None, timeout=20):
        args = {"expression": cmd, "context": "repl"}
        if frame_id is not None: args["frameId"] = frame_id
        seq = self.request("evaluate", args)
        return self.resp(seq, timeout=timeout)


def attach_config(connect_uri, pid):
    target_cmds = [f'target create "{SYMBOLS}"']
    for p2 in android_probe.DEFAULT_EXEC_SEARCH:
        target_cmds.append(f'settings append target.exec-search-paths "{p2}"')
    return {
        "name": "hw-bp-probe", "type": "codelldb", "request": "attach",
        "breakpointMode": "file", "stopOnEntry": False,
        "program": str(SYMBOLS), "cwd": str(PROJECT_ROOT),
        "relativePathBase": str(PROJECT_ROOT), "sourceLanguages": ["cpp"],
        "sourceMap": {ENGINE_ROOT.as_posix(): ENGINE_ROOT.as_posix(),
                      PROJECT_ROOT.as_posix(): PROJECT_ROOT.as_posix()},
        "initCommands": [
            "settings set stop-disassembly-display never",
            "settings set target.inline-breakpoint-strategy always",
            "settings set target.move-to-nearest-code true",
            "settings set target.process.stop-on-sharedlibrary-events false",
            "settings set target.preload-symbols false",
            "settings set symbols.load-on-demand true",
            "platform select remote-android",
        ],
        "targetCreateCommands": target_cmds,
        "processCreateCommands": [
            f'platform connect "{connect_uri}"',
            f"process attach -p {pid}",
            "settings set target.process.thread.step-avoid-regexp ''",
            "process handle SIGSTOP -p true -s false -n false",
            "process handle SIGSEGV -p true -s false -n false",
            "process handle SIGBUS -p true -s false -n false",
            "process handle SIGPIPE -p true -s false -n false",
        ],
        "preTerminateCommands": ["process detach"],
    }


def connect_client(port, timeout=15):
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            s = socket.create_connection(("127.0.0.1", port), timeout=2)
            s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            return DAPClient(s)
        except OSError:
            time.sleep(0.2)
    raise RuntimeError(f"cannot connect to codelldb on port {port}")


def main():
    android_probe.ensure_adb_ready()
    android_probe.cleanup_device()
    android_probe.stage_platform_bits(android_probe.AS2024_LLDB_SERVER)

    bridge = adapter_proc = client = None
    try:
        pid = android_probe.resolve_pid()
        bridge, connect_uri, _, serial = android_probe.start_platform_server(pid)
        p(f"pid={pid}  serial={serial}")

        port = allocate_port()
        adapter_proc = subprocess.Popen(
            [str(CODELLDB_ADAPTER), "--port", str(port), "--liblldb", str(CODELLDB_LIBLLDB)],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        )
        client = connect_client(port)

        seq = client.request("initialize", {
            "adapterID": "codelldb", "clientID": "hw-bp-probe",
            "linesStartAt1": True, "columnsStartAt1": True, "pathFormat": "path",
            "supportsRunInTerminalRequest": False,
        })
        client.resp(seq, timeout=15)
        p("initialize: ok")

        attach_seq = client.request("attach", attach_config(connect_uri, pid))
        client.wait_for(lambda m: m.get("type") == "event" and m.get("event") == "initialized", timeout=30)
        p("initialized")

        seq = client.request("configurationDone")
        client.resp(seq, timeout=20)
        p("configurationDone: ok")

        # Drain until stopped
        stop = None
        deadline = time.time() + 40
        while time.time() < deadline:
            try: msg = client.read_one(timeout=3)
            except TimeoutError: break
            t, ev = msg.get("type"), msg.get("event")
            if t == "response" and msg.get("request_seq") == attach_seq:
                p(f"attach response: success={msg.get('success')}")
            elif t == "event" and ev == "stopped":
                stop = msg
                break

        if not stop:
            p("No initial stop — pausing...")
            seq = client.request("pause", {"threadId": 1})
            stop = client.wait_for(lambda m: m.get("type") == "event" and m.get("event") == "stopped", timeout=20)

        thread_id = (stop.get("body") or {}).get("threadId") or 1
        p(f"stopped, threadId={thread_id}")

        frame_id = client.get_frame_id(thread_id)
        p(f"frame_id={frame_id}")

        # Set ONE hardware breakpoint at function entry
        p("\n--- Setting hardware breakpoint: UObject::ProcessEvent ---")
        r = client.eval_cmd('breakpoint set -H --name "UObject::ProcessEvent"', frame_id=frame_id)
        result = (r.get("body") or {}).get("result", "")
        p(f"  result: {result!r}")

        # Continue and wait up to 30s for the hit
        p("\n--- Continue, waiting 30s for breakpoint hit ---")
        seq = client.request("continue", {"threadId": thread_id})
        client.resp(seq, timeout=15)
        p("continue: ok")

        try:
            stop2 = client.wait_for(
                lambda m: m.get("type") == "event" and m.get("event") == "stopped",
                timeout=30
            )
            body2 = stop2.get("body") or {}
            p(f"\nSTOPPED: reason={body2.get('reason')}  threadId={body2.get('threadId')}")
            p(f"  hitBreakpointIds={body2.get('hitBreakpointIds')}")

            thread_id2 = body2.get("threadId") or thread_id
            seq = client.request("stackTrace", {"threadId": thread_id2, "startFrame": 0, "levels": 5})
            sr = client.resp(seq, timeout=15)
            frames = (sr.get("body") or {}).get("stackFrames") or []
            p("Stack:")
            for f in frames[:5]:
                p(f"  {f.get('name')} @ {(f.get('source') or {}).get('path','?')}:{f.get('line')}")

            if body2.get("reason") == "breakpoint":
                p("\n=== HARDWARE BREAKPOINT WORKS! Testing step over ===")
                seq = client.request("next", {"threadId": thread_id2, "granularity": "statement"})
                client.resp(seq, timeout=10)
                step_stop = client.wait_for(
                    lambda m: m.get("type") == "event" and m.get("event") == "stopped", timeout=15)
                step_body = step_stop.get("body") or {}
                p(f"Step stop: reason={step_body.get('reason')}  threadId={step_body.get('threadId')}")
                seq = client.request("stackTrace", {"threadId": step_body.get("threadId") or thread_id2, "startFrame": 0, "levels": 3})
                sr3 = client.resp(seq, timeout=15)
                step_frames = (sr3.get("body") or {}).get("stackFrames") or []
                p("Stack after step:")
                for f in step_frames[:3]:
                    p(f"  {f.get('name')} @ {(f.get('source') or {}).get('path','?')}:{f.get('line')}")
                p("\nSUCCESS: F9 (hardware breakpoint) and F10 (step over) both work!")
            else:
                p(f"Stopped but not breakpoint (reason={body2.get('reason')})")
        except TimeoutError:
            p("TIMEOUT: hardware breakpoint not hit in 90s")

        seq = client.request("disconnect", {"terminateDebuggee": False})
        try: client.resp(seq, timeout=10)
        except Exception: pass

    finally:
        if client: client.close()
        if adapter_proc:
            try:
                adapter_proc.kill()
                _, stderr = adapter_proc.communicate(timeout=5)
                if stderr.strip(): p(f"\n=== Adapter stderr ===\n{stderr.strip()}")
            except Exception: pass
        if bridge:
            try: bridge.kill(); bridge.communicate(timeout=3)
            except Exception: pass
        android_probe.cleanup_device()


if __name__ == "__main__":
    try: main()
    except Exception as exc:
        import traceback
        print(f"\nFATAL: {exc}", file=sys.stderr)
        traceback.print_exc(file=sys.stderr)
        sys.exit(1)
