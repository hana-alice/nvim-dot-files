"""
Quick probe: hardware breakpoint on pthread_mutex_lock to diagnose anti-cheat.
If this doesn't fire, hardware breakpoints are being cleared (likely by anti-cheat).
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
        self.sock.sendall(("Content-Length: %d\r\n\r\n" % len(body)).encode("ascii") + body)

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
                n = int(hdrs["content-length"]); total = h + 4 + n
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
            if rem <= 0: raise TimeoutError("wait_for timeout %ds" % timeout)
            try: msg = self.read_one(timeout=min(rem, 3))
            except TimeoutError: continue
            t, ev = msg.get("type"), msg.get("event")
            if t == "event" and ev == "output":
                body = msg.get("body") or {}
                out = body.get("output", "").rstrip()
                if out: p("  [output/%s] %s" % (body.get("category", "?"), out))
            if pred(msg): return msg

    def resp(self, seq, timeout=20):
        msg = self.wait_for(
            lambda m: m.get("type") == "response" and m.get("request_seq") == seq,
            timeout=timeout)
        if not msg.get("success"):
            raise RuntimeError("request failed: %s" % msg.get("message", "?"))
        return msg

    def eval_cmd(self, cmd, frame_id=None, timeout=20):
        args = {"expression": cmd, "context": "repl"}
        if frame_id is not None:
            args["frameId"] = frame_id
        seq = self.request("evaluate", args)
        return self.resp(seq, timeout=timeout)

    def get_frame_id(self, thread_id, timeout=15):
        seq = self.request("stackTrace", {"threadId": thread_id, "startFrame": 0, "levels": 1})
        r = self.resp(seq, timeout=timeout)
        frames = (r.get("body") or {}).get("stackFrames") or []
        return frames[0]["id"] if frames else None


def attach_config(connect_uri, pid):
    target_cmds = ['target create "%s"' % SYMBOLS]
    for p2 in android_probe.DEFAULT_EXEC_SEARCH:
        target_cmds.append('settings append target.exec-search-paths "%s"' % p2)
    return {
        "name": "mutex-bp-probe", "type": "codelldb", "request": "attach",
        "breakpointMode": "file", "stopOnEntry": False,
        "program": str(SYMBOLS), "cwd": str(PROJECT_ROOT),
        "relativePathBase": str(PROJECT_ROOT), "sourceLanguages": ["cpp"],
        "sourceMap": {ENGINE_ROOT.as_posix(): ENGINE_ROOT.as_posix(),
                      PROJECT_ROOT.as_posix(): PROJECT_ROOT.as_posix()},
        "initCommands": [
            "settings set stop-disassembly-display never",
            "settings set target.preload-symbols false",
            "settings set symbols.load-on-demand true",
            "platform select remote-android",
        ],
        "targetCreateCommands": target_cmds,
        "processCreateCommands": [
            'platform connect "%s"' % connect_uri,
            "process attach -p %s" % pid,
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
    raise RuntimeError("cannot connect to codelldb on port %d" % port)


def main():
    android_probe.ensure_adb_ready()
    android_probe.cleanup_device()
    android_probe.stage_platform_bits(android_probe.AS2024_LLDB_SERVER)
    bridge = adapter_proc = client = None
    try:
        pid = android_probe.resolve_pid()
        bridge, connect_uri, _, serial = android_probe.start_platform_server(pid)
        p("pid=%s  serial=%s" % (pid, serial))
        port = allocate_port()
        adapter_proc = subprocess.Popen(
            [str(CODELLDB_ADAPTER), "--port", str(port), "--liblldb", str(CODELLDB_LIBLLDB)],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        client = connect_client(port)
        seq = client.request("initialize", {
            "adapterID": "codelldb", "linesStartAt1": True,
            "columnsStartAt1": True, "pathFormat": "path"})
        client.resp(seq, timeout=15); p("init ok")
        attach_seq = client.request("attach", attach_config(connect_uri, pid))
        client.wait_for(
            lambda m: m.get("type") == "event" and m.get("event") == "initialized",
            timeout=30); p("initialized")
        seq = client.request("configurationDone")
        client.resp(seq, timeout=20); p("configurationDone ok")
        stop = None; deadline = time.time() + 40
        while time.time() < deadline:
            try: msg = client.read_one(timeout=3)
            except TimeoutError: break
            if msg.get("type") == "response" and msg.get("request_seq") == attach_seq:
                p("attach ok: success=%s" % msg.get("success"))
            elif msg.get("type") == "event" and msg.get("event") == "stopped":
                stop = msg; break
        if not stop:
            p("pausing...")
            seq = client.request("pause", {"threadId": 1})
            stop = client.wait_for(
                lambda m: m.get("type") == "event" and m.get("event") == "stopped",
                timeout=20)
        thread_id = (stop.get("body") or {}).get("threadId") or 1
        p("stopped, threadId=%d" % thread_id)
        frame_id = client.get_frame_id(thread_id); p("frame_id=%s" % frame_id)

        # Test hardware BP on pthread_mutex_lock (libc, guaranteed to be called)
        p("\n--- Setting hardware BP: pthread_mutex_lock ---")
        r = client.eval_cmd("breakpoint set -H --name pthread_mutex_lock", frame_id=frame_id)
        result = (r.get("body") or {}).get("result", "")
        p("  result: %r" % result)
        p("  (checking breakpoint list...)")
        r2 = client.eval_cmd("breakpoint list", frame_id=frame_id)
        p("  bp list result: %r" % (r2.get("body") or {}).get("result", ""))

        p("\n--- Continue, 15s wait for pthread_mutex_lock hit ---")
        seq = client.request("continue", {"threadId": thread_id})
        client.resp(seq, timeout=15); p("continue ok")
        try:
            stop2 = client.wait_for(
                lambda m: m.get("type") == "event" and m.get("event") == "stopped",
                timeout=15)
            body2 = stop2.get("body") or {}
            p("STOPPED: reason=%s  threadId=%s  hitIds=%s" % (
                body2.get("reason"), body2.get("threadId"), body2.get("hitBreakpointIds")))
            thread_id2 = body2.get("threadId") or thread_id
            seq = client.request("stackTrace", {"threadId": thread_id2, "startFrame": 0, "levels": 3})
            sr = client.resp(seq, timeout=15)
            frames = (sr.get("body") or {}).get("stackFrames") or []
            p("Stack:")
            for f in frames[:3]:
                p("  %s @ %s:%s" % (f.get("name"), (f.get("source") or {}).get("path", "?"), f.get("line")))
            if body2.get("reason") == "breakpoint":
                p("\nHARDWARE BREAKPOINTS WORK! (anti-cheat is not clearing debug registers)")
            else:
                p("\nStopped but not at breakpoint (reason=%s)" % body2.get("reason"))
        except TimeoutError:
            p("TIMEOUT: pthread_mutex_lock NOT hit in 15s")
            p("=> Likely anti-cheat is clearing hardware debug registers")

        seq = client.request("disconnect", {"terminateDebuggee": False})
        try: client.resp(seq, timeout=10)
        except Exception: pass
    finally:
        if client: client.close()
        if adapter_proc:
            try:
                adapter_proc.kill()
                _, stderr = adapter_proc.communicate(timeout=5)
                if stderr.strip(): p("\n=== Adapter stderr ===\n" + stderr.strip())
            except Exception: pass
        if bridge:
            try: bridge.kill(); bridge.communicate(timeout=3)
            except Exception: pass
        android_probe.cleanup_device()


if __name__ == "__main__":
    try: main()
    except Exception as exc:
        import traceback
        print("\nFATAL: %s" % exc, file=sys.stderr)
        traceback.print_exc(file=sys.stderr)
        sys.exit(1)
