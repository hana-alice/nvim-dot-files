"""
Focused probe: hardware-only breakpoints on FVulkanCmdBuffer::Begin.
Tests whether HW BPs actually fire on Android after continue.
"""
import json
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

    def drain_all(self, timeout=5, label=""):
        """Read and print all pending messages until timeout."""
        msgs = []
        deadline = time.time() + timeout
        while True:
            rem = deadline - time.time()
            if rem <= 0:
                break
            try:
                msg = self.read_one(timeout=min(rem, 1))
                msgs.append(msg)
                t = msg.get("type")
                ev = msg.get("event")
                cmd = msg.get("command")
                if t == "event" and ev == "output":
                    body = msg.get("body") or {}
                    out = body.get("output", "").rstrip()
                    if out:
                        p(f"  [{label}output/{body.get('category','?')}] {out}")
                elif t == "event":
                    p(f"  [{label}event] {ev}: {json.dumps(msg.get('body',{}), default=str)[:200]}")
                elif t == "response":
                    p(f"  [{label}resp] {cmd}: success={msg.get('success')} {msg.get('message','')}")
            except TimeoutError:
                break
        return msgs

    def resp(self, seq, timeout=20):
        deadline = time.time() + timeout
        while True:
            rem = deadline - time.time()
            if rem <= 0:
                raise TimeoutError(f"resp timeout for seq={seq}")
            msg = self.read_one(timeout=rem)
            t = msg.get("type")
            ev = msg.get("event")
            if t == "event" and ev == "output":
                body = msg.get("body") or {}
                out = body.get("output", "").rstrip()
                if out:
                    p(f"  [output/{body.get('category','?')}] {out}")
            elif t == "event":
                p(f"  [event] {ev}: {json.dumps(msg.get('body',{}), default=str)[:200]}")
            if t == "response" and msg.get("request_seq") == seq:
                if not msg.get("success"):
                    raise RuntimeError(f"request failed: {msg.get('message','?')}")
                return msg

    def evaluate(self, expression, frame_id=None, context="repl", timeout=30):
        args = {"expression": expression, "context": context}
        if frame_id is not None:
            args["frameId"] = frame_id
        seq = self.request("evaluate", args)
        # Collect output events and response
        deadline = time.time() + timeout
        output_lines = []
        while True:
            rem = deadline - time.time()
            if rem <= 0:
                raise TimeoutError(f"evaluate timeout")
            msg = self.read_one(timeout=rem)
            t = msg.get("type")
            ev = msg.get("event")
            if t == "event" and ev == "output":
                body = msg.get("body") or {}
                out = body.get("output", "").rstrip()
                if out:
                    output_lines.append(out)
                    p(f"  [eval-output] {out}")
            elif t == "response" and msg.get("request_seq") == seq:
                result = (msg.get("body") or {}).get("result", "")
                if result:
                    p(f"  [eval-result] {result}")
                return msg, output_lines


def attach_config(connect_uri, pid):
    target_create_cmds = [f'target create "{SYMBOLS}"']
    for path_str in android_probe.DEFAULT_EXEC_SEARCH:
        target_create_cmds.append(f'settings append target.exec-search-paths "{path_str}"')
    return {
        "name": "HW BP Focused Probe",
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
            # Fix ASLR module base - same approach as ue.lua
            'script exec("ci=lldb.debugger.GetCommandInterpreter()\\n'
            'ro=lldb.SBCommandReturnObject()\\n'
            f"ci.HandleCommand('platform shell cat /proc/{pid}/maps',ro)\\n"
            "o=ro.GetOutput() if ro.Succeeded() else ''\\n"
            "lines=[l for l in o.splitlines() if 'libUE4.so' in l]\\n"
            "base=int(lines[0].split('-')[0],16) if lines else 0\\n"
            "ci.HandleCommand('target modules load --file libUE4.so --slide 0x%x'%base,lldb.SBCommandReturnObject()) if base else None"
            '")',
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

        # Initialize
        seq = client.request("initialize", {
            "adapterID": "codelldb", "clientID": "hwprobe", "clientName": "hwprobe",
            "linesStartAt1": True, "columnsStartAt1": True, "pathFormat": "path",
            "supportsRunInTerminalRequest": False,
        })
        client.resp(seq, timeout=15)
        p("initialize: ok")

        # Attach
        attach_seq = client.request("attach", attach_config(connect_uri, pid))

        # Drain all messages until we see configurationDone response
        # (initialized event triggers configurationDone)
        p("\n=== Waiting for initialized event ===")
        deadline = time.time() + 60
        got_initialized = False
        while time.time() < deadline:
            msg = client.read_one(timeout=max(deadline - time.time(), 1))
            t = msg.get("type")
            ev = msg.get("event")
            if t == "event" and ev == "output":
                body = msg.get("body") or {}
                out = body.get("output", "").rstrip()
                if out:
                    p(f"  [output] {out[:200]}")
            elif t == "event" and ev == "initialized":
                p("  initialized event")
                got_initialized = True
                break
            elif t == "event":
                p(f"  [event] {ev}")
            elif t == "response":
                p(f"  [resp] {msg.get('command')}: success={msg.get('success')}")

        if not got_initialized:
            raise RuntimeError("no initialized event")

        # Send configurationDone
        cfg_seq = client.request("configurationDone")

        # Now drain ALL remaining messages (stopped, attach resp, configurationDone resp)
        p("\n=== Draining attach messages ===")
        got_cfg_resp = False
        got_attach_resp = False
        initial_thread_id = None
        deadline = time.time() + 60
        while time.time() < deadline:
            if got_cfg_resp and got_attach_resp:
                break
            try:
                msg = client.read_one(timeout=max(deadline - time.time(), 1))
            except TimeoutError:
                break
            t = msg.get("type")
            ev = msg.get("event")
            if t == "event" and ev == "output":
                body = msg.get("body") or {}
                out = body.get("output", "").rstrip()
                if out and len(out) < 300:
                    p(f"  [output] {out}")
            elif t == "event" and ev == "stopped":
                body = msg.get("body") or {}
                initial_thread_id = body.get("threadId")
                p(f"  [stopped] reason={body.get('reason')}  threadId={initial_thread_id}")
            elif t == "event":
                p(f"  [event] {ev}")
            elif t == "response" and msg.get("request_seq") == cfg_seq:
                got_cfg_resp = True
                p(f"  configurationDone: success={msg.get('success')}")
            elif t == "response" and msg.get("request_seq") == attach_seq:
                got_attach_resp = True
                p(f"  attach: success={msg.get('success')}")

        p(f"attach_resp={got_attach_resp}  cfg_resp={got_cfg_resp}  initial_thread={initial_thread_id}")

        # Continue the process first (it's stopped from SIGSTOP)
        p("\n=== Continuing (resume from SIGSTOP) ===")
        cont_tid = initial_thread_id or int(pid)
        seq = client.request("continue", {"threadId": cont_tid})
        client.resp(seq, timeout=20)
        p("continue: ok")

        # Let the process run for 2s to ensure it's actually executing
        p("Letting process run for 2s...")
        client.drain_all(timeout=2, label="run-")

        # Pause to set HW breakpoints
        p("\n=== Pausing to set HW breakpoint ===")
        seq = client.request("pause", {"threadId": cont_tid})
        stop = None
        deadline = time.time() + 20
        while time.time() < deadline:
            msg = client.read_one(timeout=max(deadline - time.time(), 1))
            t = msg.get("type")
            ev = msg.get("event")
            if t == "event" and ev == "stopped":
                stop = msg
                break
            elif t == "event" and ev == "output":
                body = msg.get("body") or {}
                out = body.get("output", "").rstrip()
                if out:
                    p(f"  [output] {out[:200]}")

        if not stop:
            raise RuntimeError("Failed to pause process")

        thread_id = (stop.get("body") or {}).get("threadId") or cont_tid
        p(f"Paused. threadId={thread_id}")

        # Get frame
        seq = client.request("stackTrace", {"threadId": thread_id, "startFrame": 0, "levels": 1})
        sr = client.resp(seq, timeout=15)
        frames = (sr.get("body") or {}).get("stackFrames") or []
        frame_id = frames[0]["id"] if frames else None
        p(f"frame_id={frame_id}")

        # Check process status before setting BP
        p("\n=== Process status ===")
        client.evaluate("process status", frame_id=frame_id)

        # Check how many HW breakpoint resources are available
        p("\n=== HW breakpoint resource check ===")
        client.evaluate("settings show target.use-hex-immediates", frame_id=frame_id)

        # FIX MODULE BASE using same approach as ue.lua
        p("\n=== Fixing module ASLR base ===")
        fix_lines = [
            "ci=lldb.debugger.GetCommandInterpreter()",
            "ro=lldb.SBCommandReturnObject()",
            f"ci.HandleCommand('platform shell cat /proc/{pid}/maps',ro)",
            "o=ro.GetOutput() if ro.Succeeded() else ''",
            "lines=[l for l in o.splitlines() if 'libUE4.so' in l]",
            "base=int(lines[0].split('-')[0],16) if lines else 0",
            "print('libUE4.so base: 0x%x'%base) if base else print('FAILED: no libUE4.so in maps')",
            "ci.HandleCommand('target modules load --file libUE4.so --slide 0x%x'%base,lldb.SBCommandReturnObject()) if base else None",
        ]
        fix_cmd = 'script exec("' + "\\n".join(fix_lines) + '")'
        client.evaluate(fix_cmd, frame_id=frame_id)

        p("\n=== image list AFTER fix ===")
        client.evaluate("image list libUE4.so", frame_id=frame_id)

        # Set HW BP by function name — should now use correct address
        p(f"\n=== Setting HW breakpoint on {BREAK_FUNC} (with fixed base) ===")
        client.evaluate(f'breakpoint set -H --name "{BREAK_FUNC}"', frame_id=frame_id)

        p("\n=== breakpoint list ===")
        client.evaluate("breakpoint list", frame_id=frame_id)

        # Check process status again
        p("\n=== Process status before continue ===")
        client.evaluate("process status", frame_id=frame_id)

        # Check RenderThread stack
        p("\n=== Inspecting RenderThread ===")
        seq = client.request("threads")
        tr = client.resp(seq, timeout=15)
        threads = (tr.get("body") or {}).get("threads") or []
        render_tid = None
        for t_info in threads:
            name = t_info.get("name") or ""
            if "RenderThread" in name and "RTHeart" not in name:
                p(f"  Found {name}: id={t_info['id']}")
                render_tid = t_info["id"]
                seq = client.request("stackTrace", {"threadId": render_tid, "startFrame": 0, "levels": 20})
                sr2 = client.resp(seq, timeout=15)
                rframes = (sr2.get("body") or {}).get("stackFrames") or []
                for rf in rframes[:20]:
                    src = (rf.get("source") or {}).get("path", "?")
                    p(f"    {rf.get('name','?')} @ {src}:{rf.get('line')}")
                break

        # Also check GameThread
        p("\n=== Inspecting GameThread ===")
        for t_info in threads:
            name = t_info.get("name") or ""
            if "GameThread" in name:
                p(f"  Found {name}: id={t_info['id']}")
                seq = client.request("stackTrace", {"threadId": t_info['id'], "startFrame": 0, "levels": 10})
                sr2 = client.resp(seq, timeout=15)
                gframes = (sr2.get("body") or {}).get("stackFrames") or []
                for gf in gframes[:10]:
                    src = (gf.get("source") or {}).get("path", "?")
                    p(f"    {gf.get('name','?')} @ {src}:{gf.get('line')}")
                break

        # Continue and wait for BP hit
        p("\n=== Continue and wait for breakpoint hit (30s) ===")
        seq = client.request("continue", {"threadId": thread_id})
        client.resp(seq, timeout=20)
        p("continue: ok")
        hit = False
        deadline = time.time() + 15
        msg_count = 0
        while time.time() < deadline:
            try:
                msg = client.read_one(timeout=min(deadline - time.time(), 3))
                msg_count += 1
            except TimeoutError:
                continue
            t = msg.get("type")
            ev = msg.get("event")
            if t == "event" and ev == "stopped":
                body = msg.get("body") or {}
                p(f"\n*** STOPPED: reason={body.get('reason')}  threadId={body.get('threadId')}"
                  f"  hitBreakpointIds={body.get('hitBreakpointIds')}")
                hit = True

                # Get stack trace
                tid = body.get("threadId") or thread_id
                seq = client.request("stackTrace", {"threadId": tid, "startFrame": 0, "levels": 5})
                sr = client.resp(seq, timeout=15)
                stack = (sr.get("body") or {}).get("stackFrames") or []
                p("Stack:")
                for f in stack[:5]:
                    src = (f.get("source") or {}).get("path", "?")
                    p(f"  {f.get('name')} @ {src}:{f.get('line')}")

                if body.get("reason") == "breakpoint":
                    p("\nSUCCESS: Hardware breakpoint hit!")
                break
            elif t == "event":
                body = msg.get("body") or {}
                if ev == "output":
                    out = body.get("output", "").rstrip()
                    if out:
                        p(f"  [output] {out[:200]}")
                else:
                    p(f"  [event] {ev}: {json.dumps(body, default=str)[:200]}")
            elif t == "response":
                p(f"  [resp] {msg.get('command')}: success={msg.get('success')} {msg.get('message','')}")

        p(f"\nTotal messages received during wait: {msg_count}")

        if not hit:
            p("\nFAILED: No breakpoint hit in 45s")
            # Try to check if process is still running
            p("\n=== Checking process state ===")
            seq = client.request("threads")
            try:
                tr = client.resp(seq, timeout=10)
                threads = (tr.get("body") or {}).get("threads") or []
                p(f"  Thread count: {len(threads)}")
                for t in threads[:5]:
                    p(f"  Thread id={t.get('id')} name={t.get('name')}")
            except Exception as e:
                p(f"  threads request failed: {e}")

            # Try process status
            p("\n=== Process status after wait ===")
            try:
                seq = client.request("pause", {"threadId": thread_id})
                deadline2 = time.time() + 10
                while time.time() < deadline2:
                    msg2 = client.read_one(timeout=max(deadline2 - time.time(), 1))
                    if msg2.get("type") == "event" and msg2.get("event") == "stopped":
                        p("  Process paused successfully")
                        fid = None
                        tid2 = (msg2.get("body") or {}).get("threadId") or thread_id
                        seq = client.request("stackTrace", {"threadId": tid2, "startFrame": 0, "levels": 1})
                        sr2 = client.resp(seq, timeout=10)
                        frs = (sr2.get("body") or {}).get("stackFrames") or []
                        if frs:
                            fid = frs[0]["id"]
                        client.evaluate("process status", frame_id=fid)
                        client.evaluate("breakpoint list", frame_id=fid)
                        break
                    elif msg2.get("type") == "event" and msg2.get("event") == "output":
                        out = (msg2.get("body") or {}).get("output", "").rstrip()
                        if out:
                            p(f"  [output] {out[:200]}")
            except Exception as e:
                p(f"  Post-check failed: {e}")

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
