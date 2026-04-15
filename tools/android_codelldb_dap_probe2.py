"""
DAP probe that exactly matches the nvim-dap attach config used in ue.lua.
Tests: attach, breakpoint via LLDB evaluate, continue, step over.
"""
import json
import os
import select
import socket
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import tools.android_lldb_probe as android_probe
from tools.sanitized_test_config import CODELLDB_ROOT, ENGINE_ROOT, PROJECT_ROOT

CODELLDB_ADAPTER = CODELLDB_ROOT / "adapter" / "codelldb.exe"
CODELLDB_LIBLLDB = CODELLDB_ROOT / "lldb" / "bin" / "liblldb.dll"
SYMBOLS = android_probe.DEFAULT_SYMBOLS
BREAK_FILE = "VulkanCommandBuffer.cpp"
BREAK_LINE = 334


def p(msg):
    print(msg, flush=True)


def allocate_port():
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class DAPClient:
    def __init__(self, sock):
        self.sock = sock
        self.seq = 1
        self.buf = bytearray()

    def close(self):
        try:
            self.sock.close()
        except Exception:
            pass

    def send(self, payload):
        body = json.dumps(payload).encode()
        header = f"Content-Length: {len(body)}\r\n\r\n".encode("ascii")
        self.sock.sendall(header + body)

    def request(self, command, arguments=None):
        seq = self.seq
        self.seq += 1
        self.send({"seq": seq, "type": "request", "command": command, "arguments": arguments or {}})
        return seq

    def read_one(self, timeout=30):
        deadline = time.time() + timeout
        while True:
            h = self.buf.find(b"\r\n\r\n")
            if h != -1:
                hdrs = {k.strip().lower(): v.strip() for line in bytes(self.buf[:h]).decode("ascii").split("\r\n") for k, v in [line.split(":", 1)]}
                n = int(hdrs["content-length"])
                total = h + 4 + n
                if len(self.buf) >= total:
                    msg = json.loads(bytes(self.buf[h + 4:total]))
                    del self.buf[:total]
                    return msg
            rem = deadline - time.time()
            if rem <= 0:
                raise TimeoutError("DAP read timeout")
            r, _, _ = select.select([self.sock], [], [], rem)
            if not r:
                raise TimeoutError("DAP read timeout")
            chunk = self.sock.recv(65536)
            if not chunk:
                raise RuntimeError("DAP stream closed")
            self.buf.extend(chunk)

    def wait_for(self, pred, timeout=30):
        deadline = time.time() + timeout
        while True:
            rem = deadline - time.time()
            if rem <= 0:
                raise TimeoutError(f"wait_for timeout after {timeout}s")
            try:
                msg = self.read_one(timeout=min(rem, 3))
            except TimeoutError:
                continue
            if msg.get("type") == "event" and msg.get("event") == "output":
                body = msg.get("body") or {}
                p(f"  [output/{body.get('category','?')}] {body.get('output','').rstrip()}")
            if pred(msg):
                return msg

    def resp(self, seq, timeout=20):
        msg = self.wait_for(lambda m: m.get("type") == "response" and m.get("request_seq") == seq, timeout=timeout)
        if not msg.get("success"):
            raise RuntimeError(f"request failed: {json.dumps(msg)}")
        return msg

    def evaluate(self, expression, frame_id=None, context="repl", timeout=20):
        args = {"expression": expression, "context": context}
        if frame_id is not None:
            args["frameId"] = frame_id
        seq = self.request("evaluate", args)
        return self.resp(seq, timeout=timeout)


def attach_config(connect_uri, pid):
    target_create_cmds = [f'target create "{SYMBOLS}"']
    for path in android_probe.DEFAULT_EXEC_SEARCH:
        target_create_cmds.append(f'settings append target.exec-search-paths "{path}"')
    return {
        "name": "Android DAP Probe2",
        "type": "codelldb",
        "request": "attach",        # matches nvim-dap
        "breakpointMode": "file",
        "stopOnEntry": False,       # matches nvim-dap (stopOnEntry=false)
        "program": str(SYMBOLS),
        "cwd": str(PROJECT_ROOT),
        "relativePathBase": str(PROJECT_ROOT),
        "sourceLanguages": ["cpp"],
        "sourceMap": {
            ENGINE_ROOT.as_posix(): ENGINE_ROOT.as_posix(),
            PROJECT_ROOT.as_posix(): PROJECT_ROOT.as_posix(),
        },
        "initCommands": [
            "settings set stop-disassembly-display never",
            "settings set target.inline-breakpoint-strategy always",
            "settings set target.move-to-nearest-code true",
            "settings set target.process.stop-on-sharedlibrary-events false",
            "settings set target.preload-symbols false",
            "settings set symbols.load-on-demand true",
            "platform select remote-android",
        ],
        "targetCreateCommands": target_create_cmds,
        "processCreateCommands": [
            f'platform connect "{connect_uri}"',
            f"process attach -p {pid}",   # stops the process on attach
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
    if not CODELLDB_ADAPTER.is_file():
        raise RuntimeError(f"codelldb not found: {CODELLDB_ADAPTER}")
    if not SYMBOLS.is_file():
        raise RuntimeError(f"symbols not found: {SYMBOLS}")

    android_probe.ensure_adb_ready()
    android_probe.cleanup_device()
    android_probe.stage_platform_bits(android_probe.AS2024_LLDB_SERVER)

    bridge = adapter_proc = client = None
    try:
        pid = android_probe.resolve_pid()
        bridge, connect_uri, _, serial = android_probe.start_platform_server(pid)
        p(f"\n=== Environment ===")
        p(f"pid={pid}  serial={serial}")
        p(f"uri={connect_uri}")
        p(f"symbols={SYMBOLS}")

        port = allocate_port()
        adapter_proc = subprocess.Popen(
            [str(CODELLDB_ADAPTER), "--port", str(port), "--liblldb", str(CODELLDB_LIBLLDB)],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        )
        client = connect_client(port)

        # Initialize
        p("\n=== Initialize ===")
        seq = client.request("initialize", {
            "adapterID": "codelldb", "clientID": "probe2", "clientName": "probe2",
            "linesStartAt1": True, "columnsStartAt1": True, "pathFormat": "path",
            "supportsRunInTerminalRequest": False, "supportsVariablePaging": True, "supportsVariableType": True,
        })
        init_resp = client.resp(seq, timeout=15)
        p("initialize: ok")

        # Attach (matches nvim-dap's dap.run(config) with request="attach")
        p("\n=== Attach (request=attach, stopOnEntry=false) ===")
        attach_seq = client.request("attach", attach_config(connect_uri, pid))

        # Wait for initialized event
        initialized = client.wait_for(lambda m: m.get("type") == "event" and m.get("event") == "initialized", timeout=30)
        p(f"initialized event received")

        # Send configurationDone (no setBreakpoints - matching nvim-dap approach)
        p("\n=== configurationDone ===")
        seq = client.request("configurationDone")
        config_resp = client.resp(seq, timeout=20)
        p("configurationDone: ok")

        # Wait for attach response and any stops
        p("\n=== Waiting for attach response and process events ===")
        attach_resp = None
        first_stop = None
        deadline = time.time() + 45
        while time.time() < deadline and (attach_resp is None or first_stop is None):
            try:
                msg = client.read_one(timeout=min(deadline - time.time(), 3))
            except TimeoutError:
                continue
            t = msg.get("type")
            ev = msg.get("event")
            if t == "response" and msg.get("request_seq") == attach_seq:
                attach_resp = msg
                p(f"attach response: success={msg.get('success')}")
            elif t == "event" and ev == "stopped":
                first_stop = msg
                p(f"stopped: reason={msg.get('body',{}).get('reason')}  threadId={msg.get('body',{}).get('threadId')}")
                break
            elif t == "event" and ev == "output":
                body = msg.get("body") or {}
                p(f"  [output/{body.get('category','?')}] {body.get('output','').rstrip()}")
            elif t == "event" and ev == "continued":
                p(f"  [continued]")
            elif t == "event" and ev in ("module", "loadedSource", "capabilities"):
                pass
            else:
                p(f"  [msg] {json.dumps(msg)[:200]}")

        if attach_resp is None:
            p("WARNING: no attach response received within 45s")
        if first_stop is None:
            p("WARNING: no stopped event received within 45s — process running freely")
            p("Attempting to pause the process...")
            pause_seq = client.request("pause", {"threadId": 1})
            try:
                first_stop = client.wait_for(lambda m: m.get("type") == "event" and m.get("event") == "stopped", timeout=15)
                p(f"stopped after pause: reason={first_stop.get('body',{}).get('reason')}  threadId={first_stop.get('body',{}).get('threadId')}")
            except TimeoutError:
                p("ERROR: pause did not produce a stop event")
                raise RuntimeError("cannot pause process")

        thread_id = (first_stop.get("body") or {}).get("threadId") or 1
        p(f"\nProcess stopped. thread_id={thread_id}")

        # Get stack trace to get a valid frame_id
        p("\n=== Stack Trace ===")
        seq = client.request("stackTrace", {"threadId": thread_id, "startFrame": 0, "levels": 5})
        stack_resp = client.resp(seq, timeout=20)
        frames = (stack_resp.get("body") or {}).get("stackFrames") or []
        frame_id = frames[0]["id"] if frames else None
        for f in frames[:5]:
            p(f"  frame {f.get('id')}: {f.get('name')} @ {(f.get('source') or {}).get('path','?')}:{f.get('line')}")

        # Set breakpoint via LLDB command evaluate (nvim-dap approach)
        p(f"\n=== Set breakpoint via LLDB evaluate (file+line) ===")
        bp_cmd = f'breakpoint set --file "{BREAK_FILE}" --line {BREAK_LINE}'
        p(f"Command: {bp_cmd}")
        for prefix in [f"/cmd {bp_cmd}", bp_cmd]:
            try:
                eval_resp = client.evaluate(prefix, frame_id=frame_id, context="repl", timeout=20)
                result = (eval_resp.get("body") or {}).get("result", "")
                p(f"evaluate result: {result}")
                if "error:" not in result.lower():
                    break
            except Exception as e:
                p(f"evaluate error: {e}")

        # Continue
        p("\n=== Continue ===")
        seq = client.request("continue", {"threadId": thread_id})
        cont_resp = client.resp(seq, timeout=20)
        p(f"continue: allThreadsContinued={cont_resp.get('body',{}).get('allThreadsContinued')}")

        # Wait for breakpoint hit
        p(f"\n=== Waiting for breakpoint at {BREAK_FILE}:{BREAK_LINE} (30s) ===")
        try:
            stop = client.wait_for(lambda m: m.get("type") == "event" and m.get("event") == "stopped", timeout=30)
            body = stop.get("body") or {}
            p(f"STOPPED: reason={body.get('reason')}  threadId={body.get('threadId')}")
            p(f"  hitBreakpointIds={body.get('hitBreakpointIds')}")
            p(f"  description={body.get('description')}")

            thread_id2 = body.get("threadId") or thread_id
            seq = client.request("stackTrace", {"threadId": thread_id2, "startFrame": 0, "levels": 5})
            stack_resp2 = client.resp(seq, timeout=20)
            frames2 = (stack_resp2.get("body") or {}).get("stackFrames") or []
            frame_id2 = frames2[0]["id"] if frames2 else None
            p("Stack after breakpoint hit:")
            for f in frames2[:5]:
                p(f"  frame {f.get('id')}: {f.get('name')} @ {(f.get('source') or {}).get('path','?')}:{f.get('line')}")

            # Test step over (F10)
            p("\n=== Step Over (F10 / DAP next) ===")
            seq = client.request("next", {"threadId": thread_id2, "granularity": "statement"})
            try:
                step_resp = client.resp(seq, timeout=10)
                p(f"next response: success={step_resp.get('success')}")
                # Wait for stop after step
                step_stop = client.wait_for(lambda m: m.get("type") == "event" and m.get("event") == "stopped", timeout=15)
                step_body = step_stop.get("body") or {}
                p(f"stopped after step: reason={step_body.get('reason')}  threadId={step_body.get('threadId')}")
                seq = client.request("stackTrace", {"threadId": step_body.get("threadId") or thread_id2, "startFrame": 0, "levels": 3})
                step_stack = client.resp(seq, timeout=15)
                step_frames = (step_stack.get("body") or {}).get("stackFrames") or []
                p("Stack after step over:")
                for f in step_frames[:3]:
                    p(f"  frame {f.get('id')}: {f.get('name')} @ {(f.get('source') or {}).get('path','?')}:{f.get('line')}")
                p("\nSUCCESS: F9 (breakpoint) and F10 (step over) work!")
            except Exception as e:
                p(f"step over error: {e}")
        except TimeoutError:
            p(f"TIMEOUT: breakpoint at {BREAK_FILE}:{BREAK_LINE} not hit in 30s")

        # Disconnect
        p("\n=== Disconnect ===")
        seq = client.request("disconnect", {"terminateDebuggee": False})
        try:
            client.resp(seq, timeout=10)
            p("disconnect: ok")
        except Exception:
            pass

    finally:
        if client:
            client.close()
        if adapter_proc:
            try:
                adapter_proc.kill()
                stdout, stderr = adapter_proc.communicate(timeout=5)
                if stderr.strip():
                    p(f"\n=== Adapter stderr ===\n{stderr.strip()}")
            except Exception:
                pass
        if bridge:
            try:
                bridge.kill()
                bridge.communicate(timeout=3)
            except Exception:
                pass
        android_probe.cleanup_device()


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        import traceback
        print(f"\nFATAL: {exc}", file=sys.stderr)
        traceback.print_exc(file=sys.stderr)
        sys.exit(1)
