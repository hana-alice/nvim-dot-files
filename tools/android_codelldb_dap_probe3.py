"""
DAP probe: tests hardware breakpoints and the full F9/F10 flow.
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
BREAK_FUNC = "FVulkanCmdBuffer::Begin"


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
            t = msg.get("type")
            ev = msg.get("event")
            if t == "event" and ev == "output":
                body = msg.get("body") or {}
                out = body.get("output", "").rstrip()
                if out:
                    p(f"  [output/{body.get('category','?')}] {out}")
            if pred(msg):
                return msg

    def resp(self, seq, timeout=20):
        msg = self.wait_for(lambda m: m.get("type") == "response" and m.get("request_seq") == seq, timeout=timeout)
        if not msg.get("success"):
            raise RuntimeError(f"request failed: {msg.get('message','?')}")
        return msg

    def evaluate(self, expression, frame_id=None, context="repl", timeout=20):
        args = {"expression": expression, "context": context}
        if frame_id is not None:
            args["frameId"] = frame_id
        seq = self.request("evaluate", args)
        return self.resp(seq, timeout=timeout)

    def pause_and_stop(self, thread_id=1, timeout=20):
        seq = self.request("pause", {"threadId": thread_id})
        stop = self.wait_for(lambda m: m.get("type") == "event" and m.get("event") == "stopped", timeout=timeout)
        return stop

    def get_frame_id(self, thread_id, timeout=15):
        seq = self.request("stackTrace", {"threadId": thread_id, "startFrame": 0, "levels": 1})
        resp = self.resp(seq, timeout=timeout)
        frames = (resp.get("body") or {}).get("stackFrames") or []
        return frames[0]["id"] if frames else None


def attach_config(connect_uri, pid):
    target_create_cmds = [f'target create "{SYMBOLS}"']
    for path_str in android_probe.DEFAULT_EXEC_SEARCH:
        target_create_cmds.append(f'settings append target.exec-search-paths "{path_str}"')
    return {
        "name": "Android DAP Probe3",
        "type": "codelldb",
        "request": "attach",
        "breakpointMode": "file",
        "stopOnEntry": False,
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


def try_set_breakpoint(client, frame_id, cmd_text, label):
    """Try setting a breakpoint via evaluate, return True if no error in output."""
    p(f"\n--- Try: {label} ---")
    p(f"  Command: {cmd_text}")
    # LLDB evaluate in repl context: the command output goes to output event
    # The evaluate result is empty; check output events for success/failure
    success = True
    seq = client.request("evaluate", {"expression": cmd_text, "context": "repl",
                                       **({"frameId": frame_id} if frame_id else {})})
    deadline = time.time() + 20
    while time.time() < deadline:
        try:
            msg = client.read_one(timeout=min(deadline - time.time(), 3))
        except TimeoutError:
            break
        t = msg.get("type")
        ev = msg.get("event")
        if t == "response" and msg.get("request_seq") == seq:
            if not msg.get("success"):
                p(f"  evaluate FAILED: {msg.get('message','?')}")
                success = False
            else:
                result = (msg.get("body") or {}).get("result", "")
                if "error" in result.lower():
                    p(f"  evaluate error in result: {result}")
                    success = False
                elif result:
                    p(f"  evaluate result: {result}")
            break
        elif t == "event" and ev == "output":
            body = msg.get("body") or {}
            out = body.get("output", "").rstrip()
            if out:
                p(f"  [output] {out}")
                if "error" in out.lower():
                    success = False
    return success


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
        p(f"pid={pid}  serial={serial}")

        port = allocate_port()
        adapter_proc = subprocess.Popen(
            [str(CODELLDB_ADAPTER), "--port", str(port), "--liblldb", str(CODELLDB_LIBLLDB)],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        )
        client = connect_client(port)

        # Initialize
        seq = client.request("initialize", {
            "adapterID": "codelldb", "clientID": "probe3", "clientName": "probe3",
            "linesStartAt1": True, "columnsStartAt1": True, "pathFormat": "path",
            "supportsRunInTerminalRequest": False, "supportsVariablePaging": True, "supportsVariableType": True,
        })
        client.resp(seq, timeout=15)
        p("initialize: ok")

        # Attach
        attach_seq = client.request("attach", attach_config(connect_uri, pid))
        client.wait_for(lambda m: m.get("type") == "event" and m.get("event") == "initialized", timeout=30)
        p("initialized event")

        seq = client.request("configurationDone")
        client.resp(seq, timeout=20)
        p("configurationDone: ok")

        # Wait for process to attach and continue
        p("\n=== Waiting for process to attach (up to 30s) ===")
        attach_resp = None
        deadline = time.time() + 30
        while time.time() < deadline:
            try:
                msg = client.read_one(timeout=min(deadline - time.time(), 3))
            except TimeoutError:
                break
            t = msg.get("type")
            ev = msg.get("event")
            if t == "response" and msg.get("request_seq") == attach_seq:
                attach_resp = msg
                p(f"attach response: success={msg.get('success')}")
                break
            elif t == "event" and ev == "output":
                body = msg.get("body") or {}
                out = body.get("output", "").rstrip()
                if out and "Process" in out:
                    p(f"  [output] {out}")
            elif t == "event" and ev == "stopped":
                p(f"  [stopped] reason={msg.get('body',{}).get('reason')}")
                # If stopped, continue immediately since stopOnEntry=false
                seq2 = client.request("continue", {"threadId": (msg.get("body") or {}).get("threadId", 1)})
                break

        # Pause the process
        p("\n=== Pausing process ===")
        stop = None
        try:
            stop = client.pause_and_stop(thread_id=1, timeout=20)
        except TimeoutError:
            # Try with the process pid as thread id
            try:
                stop = client.pause_and_stop(thread_id=int(pid), timeout=20)
            except TimeoutError:
                p("ERROR: cannot pause process")
                raise

        thread_id = (stop.get("body") or {}).get("threadId") or 1
        p(f"Process stopped. threadId={thread_id}")

        # Get a valid frame
        frame_id = client.get_frame_id(thread_id, timeout=15)
        p(f"frame_id={frame_id}")

        # Test different breakpoint methods
        p("\n=== Testing breakpoint methods ===")

        # Method 0: DAP setBreakpoints (what nvim-dap sends via F9)
        bp_source_path = str(ENGINE_ROOT / "Engine" / "Source" / "Runtime" / "VulkanRHI" / "Private" / BREAK_FILE)
        p(f"\n--- Try: DAP setBreakpoints (path={bp_source_path}, line={BREAK_LINE}) ---")
        bp_seq = client.request("setBreakpoints", {
            "source": {"name": BREAK_FILE, "path": bp_source_path},
            "breakpoints": [{"line": BREAK_LINE}],
            "sourceModified": False,
        })
        bp_resp = client.resp(bp_seq, timeout=20)
        bp_body = bp_resp.get("body") or {}
        for bp in bp_body.get("breakpoints", []):
            p(f"  DAP BP: verified={bp.get('verified')}  message={bp.get('message','')}"
              f"  line={bp.get('line')}  id={bp.get('id')}")

        # Method 1: LLDB file+line with bare filename
        sw_cmd = f'breakpoint set --file "{BREAK_FILE}" --line {BREAK_LINE}'
        try_set_breakpoint(client, frame_id, sw_cmd, "LLDB file+line (bare filename)")

        # Method 1b: LLDB file+line with full path
        sw_full_cmd = f'breakpoint set --file "{bp_source_path}" --line {BREAK_LINE}'
        try_set_breakpoint(client, frame_id, sw_full_cmd, "LLDB file+line (full path)")

        # Method 2: hardware file+line
        hw_cmd = f'breakpoint set -H --file "{BREAK_FILE}" --line {BREAK_LINE}'
        try_set_breakpoint(client, frame_id, hw_cmd, "hardware file+line (-H)")

        # Method 3: function name software
        fn_cmd = f'breakpoint set --name "{BREAK_FUNC}"'
        try_set_breakpoint(client, frame_id, fn_cmd, "software function name")

        # Method 4: function name hardware
        fn_hw_cmd = f'breakpoint set -H --name "{BREAK_FUNC}"'
        try_set_breakpoint(client, frame_id, fn_hw_cmd, "hardware function name (-H)")

        # List all breakpoints
        p("\n=== breakpoint list ===")
        try_set_breakpoint(client, frame_id, "breakpoint list", "breakpoint list")

        # DWARF source path inspection — key diagnostic for "Resolved locations: 0"
        p("\n=== DWARF source path inspection ===")
        # Check if LLDB can find VulkanCommandBuffer.cpp in the debug symbols at all
        try_set_breakpoint(client, frame_id,
                           f'image lookup --verbose --file "{BREAK_FILE}"',
                           "image lookup --file (DWARF source paths)")

        # Check what compilation units LLDB knows about for VulkanRHI
        try_set_breakpoint(client, frame_id,
                           'image lookup --verbose --name "FVulkanCmdBuffer::Begin"',
                           "image lookup --name (function symbol lookup)")

        # List loaded modules to check if libUE4.so symbols are loaded
        try_set_breakpoint(client, frame_id,
                           'image list libUE4.so',
                           "image list libUE4.so (module load status)")

        # Check source-map settings
        try_set_breakpoint(client, frame_id,
                           'settings show target.source-map',
                           "target.source-map (active source remapping)")

        # Continue and wait for breakpoint hit
        p("\n=== Continue and wait for breakpoint hit (30s) ===")
        seq = client.request("continue", {"threadId": thread_id})
        client.resp(seq, timeout=20)
        p("continue: ok")

        try:
            stop2 = client.wait_for(
                lambda m: m.get("type") == "event" and m.get("event") == "stopped",
                timeout=30
            )
            body2 = stop2.get("body") or {}
            p(f"\nStopped: reason={body2.get('reason')}  threadId={body2.get('threadId')}")
            p(f"  hitBreakpointIds={body2.get('hitBreakpointIds')}")

            thread_id2 = body2.get("threadId") or thread_id
            seq = client.request("stackTrace", {"threadId": thread_id2, "startFrame": 0, "levels": 5})
            sr = client.resp(seq, timeout=15)
            frames2 = (sr.get("body") or {}).get("stackFrames") or []
            p("Stack:")
            for f in frames2[:5]:
                p(f"  {f.get('name')} @ {(f.get('source') or {}).get('path','?')}:{f.get('line')}")

            if body2.get("reason") == "breakpoint":
                p("\n=== F9 (breakpoint) WORKS! Testing F10 (step over) ===")
                frame_id2 = frames2[0]["id"] if frames2 else None
                seq = client.request("next", {"threadId": thread_id2, "granularity": "statement"})
                try:
                    client.resp(seq, timeout=10)
                    step_stop = client.wait_for(
                        lambda m: m.get("type") == "event" and m.get("event") == "stopped",
                        timeout=15
                    )
                    step_body = step_stop.get("body") or {}
                    p(f"Step stop: reason={step_body.get('reason')}  threadId={step_body.get('threadId')}")
                    seq = client.request("stackTrace", {"threadId": step_body.get("threadId") or thread_id2, "startFrame": 0, "levels": 3})
                    sr3 = client.resp(seq, timeout=15)
                    step_frames = (sr3.get("body") or {}).get("stackFrames") or []
                    p("Stack after step:")
                    for f in step_frames[:3]:
                        p(f"  {f.get('name')} @ {(f.get('source') or {}).get('path','?')}:{f.get('line')}")
                    p("\nSUCCESS: F10 (step over) also works!")
                except Exception as e:
                    p(f"Step over failed: {e}")
            else:
                p(f"Stopped but not at breakpoint (reason={body2.get('reason')})")
        except TimeoutError:
            p("TIMEOUT: no stop event in 30s")

        # Disconnect
        seq = client.request("disconnect", {"terminateDebuggee": False})
        try:
            client.resp(seq, timeout=10)
        except Exception:
            pass

    finally:
        if client:
            client.close()
        if adapter_proc:
            try:
                adapter_proc.kill()
                _, stderr = adapter_proc.communicate(timeout=5)
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
