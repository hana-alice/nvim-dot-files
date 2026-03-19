"""
End-to-end DAP test: simulates nvim-dap's full flow with ASLR fix.
Attach → ASLR fix in processCreateCommands → setBreakpoints → continue → verify hit.
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
BREAK_FILE = "VulkanCommandBuffer.cpp"
BREAK_LINE = 334
BREAK_FILE_FULL = str(ENGINE_ROOT / "Engine" / "Source" / "Runtime" / "VulkanRHI" / "Private" / BREAK_FILE)


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
            if rem <= 0:
                raise TimeoutError("DAP read timeout")
            r, _, _ = select.select([self.sock], [], [], rem)
            if not r:
                raise TimeoutError("DAP read timeout")
            chunk = self.sock.recv(65536)
            if not chunk:
                raise RuntimeError("DAP stream closed")
            self.buf.extend(chunk)

    def collect_until(self, pred, timeout=60):
        """Read messages until pred returns True, collecting all."""
        msgs = []
        deadline = time.time() + timeout
        while True:
            rem = deadline - time.time()
            if rem <= 0:
                return msgs, None
            try:
                msg = self.read_one(timeout=min(rem, 3))
            except TimeoutError:
                continue
            msgs.append(msg)
            t = msg.get("type")
            ev = msg.get("event")
            if t == "event" and ev == "output":
                body = msg.get("body") or {}
                out = body.get("output", "").rstrip()
                if out and len(out) < 300:
                    p(f"  [output] {out}")
            elif t == "event":
                p(f"  [{ev}] {json.dumps(msg.get('body',{}), default=str)[:200]}")
            elif t == "response":
                cmd = msg.get("command", "?")
                p(f"  [resp:{cmd}] success={msg.get('success')} {msg.get('message','')}")
            if pred(msg):
                return msgs, msg
        return msgs, None


def aslr_fix_script(pid):
    """Same Python exec() as ue.lua's M._lldb_fix_module_base_command"""
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


def attach_config(connect_uri, pid):
    target_create_cmds = [f'target create "{SYMBOLS}"']
    for path_str in android_probe.DEFAULT_EXEC_SEARCH:
        target_create_cmds.append(f'settings append target.exec-search-paths "{path_str}"')
    return {
        "name": "E2E DAP Test",
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
            aslr_fix_script(pid),
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

        # Verify game is in foreground
        top = subprocess.run(["adb", "shell", "dumpsys activity activities | grep topResumedActivity"],
                             capture_output=True, text=True, timeout=5)
        p(f"  topActivity: {top.stdout.strip()}")

        port = allocate_port()
        adapter_proc = subprocess.Popen(
            [str(CODELLDB_ADAPTER), "--port", str(port), "--liblldb", str(CODELLDB_LIBLLDB)],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        )
        client = connect_client(port)

        # === INITIALIZE ===
        seq = client.request("initialize", {
            "adapterID": "codelldb", "clientID": "e2e", "clientName": "e2e",
            "linesStartAt1": True, "columnsStartAt1": True, "pathFormat": "path",
            "supportsRunInTerminalRequest": False,
        })
        msgs, _ = client.collect_until(
            lambda m: m.get("type") == "response" and m.get("request_seq") == seq, timeout=15)
        p("initialize: ok")

        # === ATTACH (sends request, waits for initialized event) ===
        attach_seq = client.request("attach", attach_config(connect_uri, pid))
        p("Waiting for initialized event (processCreateCommands + ASLR fix)...")
        msgs, init_evt = client.collect_until(
            lambda m: m.get("type") == "event" and m.get("event") == "initialized", timeout=90)
        if not init_evt:
            raise RuntimeError("No initialized event!")
        p("initialized event received")

        # === setBreakpoints (like nvim-dap F9) ===
        # This is the critical test: does setBreakpoints resolve correctly after ASLR fix?
        p(f"\n=== setBreakpoints: {BREAK_FILE}:{BREAK_LINE} ===")
        bp_seq = client.request("setBreakpoints", {
            "source": {"name": BREAK_FILE, "path": BREAK_FILE_FULL},
            "breakpoints": [{"line": BREAK_LINE}],
            "sourceModified": False,
        })

        # === configurationDone ===
        cfg_seq = client.request("configurationDone")

        # Collect all responses (setBreakpoints response, configurationDone response, stopped event, attach response)
        p("\n=== Waiting for responses ===")
        bp_resp = None
        cfg_resp = None
        attach_resp = None
        stopped_evt = None
        deadline = time.time() + 60
        while time.time() < deadline:
            if bp_resp and cfg_resp:
                break
            try:
                msg = client.read_one(timeout=min(deadline - time.time(), 3))
            except TimeoutError:
                continue
            t = msg.get("type")
            ev = msg.get("event")
            if t == "event" and ev == "output":
                body = msg.get("body") or {}
                out = body.get("output", "").rstrip()
                if out and len(out) < 300:
                    p(f"  [output] {out}")
            elif t == "event" and ev == "stopped":
                body = msg.get("body") or {}
                stopped_evt = msg
                p(f"  [stopped] reason={body.get('reason')} threadId={body.get('threadId')}")
            elif t == "event":
                p(f"  [{ev}]")
            elif t == "response":
                rseq = msg.get("request_seq")
                if rseq == bp_seq:
                    bp_resp = msg
                    bps = (msg.get("body") or {}).get("breakpoints", [])
                    for bp in bps:
                        p(f"  setBreakpoints result: verified={bp.get('verified')} "
                          f"message='{bp.get('message','')}' line={bp.get('line')} id={bp.get('id')}")
                elif rseq == cfg_seq:
                    cfg_resp = msg
                    p(f"  configurationDone: success={msg.get('success')}")
                elif rseq == attach_seq:
                    attach_resp = msg
                    p(f"  attach: success={msg.get('success')}")

        if not bp_resp:
            p("ERROR: no setBreakpoints response")
        if not cfg_resp:
            p("ERROR: no configurationDone response")

        # === Plant hardware breakpoints (like ue.lua dap_continue) ===
        # Software BPs fail with error:9 on Android. Clear the SW BP and plant HW BP.
        if stopped_evt:
            tid = (stopped_evt.get("body") or {}).get("threadId") or int(pid)

            # Get a frameId for evaluate context
            st_seq = client.request("stackTrace", {"threadId": tid, "startFrame": 0, "levels": 1})
            msgs_st, st_resp = client.collect_until(
                lambda m: m.get("type") == "response" and m.get("request_seq") == st_seq, timeout=15)
            fid = None
            if st_resp:
                frs = (st_resp.get("body") or {}).get("stackFrames") or []
                if frs:
                    fid = frs[0]["id"]

            # Clear the software BP that setBreakpoints created, then plant HW BP
            hw_cmds = [
                f'breakpoint clear --file "{BREAK_FILE}" --line {BREAK_LINE}',
                f'breakpoint set -H --file "{BREAK_FILE}" --line {BREAK_LINE}',
            ]
            p(f"\n=== Planting HW breakpoints (like ue.lua dap_continue) ===")
            for cmd in hw_cmds:
                p(f"  eval: {cmd}")
                ev_seq = client.request("evaluate", {
                    "expression": cmd, "context": "repl",
                    **({  "frameId": fid} if fid else {}),
                })
                msgs_ev, ev_resp = client.collect_until(
                    lambda m: m.get("type") == "response" and m.get("request_seq") == ev_seq, timeout=15)
                if ev_resp:
                    result = (ev_resp.get("body") or {}).get("result", "")
                    p(f"    result: {result[:200]}")

            # Now continue
            p(f"\n=== Continuing from initial stop (threadId={tid}) ===")
            cont_seq = client.request("continue", {"threadId": tid})
            msgs, _ = client.collect_until(
                lambda m: m.get("type") == "response" and m.get("request_seq") == cont_seq, timeout=20)
            p("continue: ok")
        else:
            p("WARNING: no initial stopped event, process may already be running")

        # === Wait for breakpoint hit ===
        p(f"\n=== Waiting for breakpoint hit (45s) ===")
        msgs, hit = client.collect_until(
            lambda m: m.get("type") == "event" and m.get("event") == "stopped"
                      and (m.get("body") or {}).get("reason") == "breakpoint",
            timeout=45)

        if hit:
            body = hit.get("body") or {}
            p(f"\n*** BREAKPOINT HIT! ***")
            p(f"  reason={body.get('reason')} threadId={body.get('threadId')}")
            p(f"  hitBreakpointIds={body.get('hitBreakpointIds')}")

            # Get stack trace
            tid = body.get("threadId") or int(pid)
            seq = client.request("stackTrace", {"threadId": tid, "startFrame": 0, "levels": 5})
            msgs2, sr = client.collect_until(
                lambda m: m.get("type") == "response" and m.get("request_seq") == seq, timeout=15)
            if sr:
                frames = (sr.get("body") or {}).get("stackFrames") or []
                p("Stack:")
                for f in frames[:5]:
                    src = (f.get("source") or {}).get("path", "?")
                    p(f"  {f.get('name','?')} @ {src}:{f.get('line')}")
            p("\nSUCCESS: F9 breakpoint works!")
        else:
            p("\nFAILED: no breakpoint hit in 45s")
            # Pause and check state
            try:
                pause_seq = client.request("pause", {"threadId": int(pid)})
                msgs3, stop2 = client.collect_until(
                    lambda m: m.get("type") == "event" and m.get("event") == "stopped", timeout=10)
                if stop2:
                    tid2 = (stop2.get("body") or {}).get("threadId") or int(pid)
                    # Get frame for evaluate
                    st_seq = client.request("stackTrace", {"threadId": tid2, "startFrame": 0, "levels": 1})
                    msgs4, sr2 = client.collect_until(
                        lambda m: m.get("type") == "response" and m.get("request_seq") == st_seq, timeout=10)
                    fid = None
                    if sr2:
                        frs = (sr2.get("body") or {}).get("stackFrames") or []
                        if frs:
                            fid = frs[0]["id"]
                    # Check breakpoint list and image list
                    for cmd in ["breakpoint list", "image list libUE4.so"]:
                        ev_seq = client.request("evaluate", {"expression": cmd, "context": "repl",
                                                              **({"frameId": fid} if fid else {})})
                        msgs5, _ = client.collect_until(
                            lambda m: m.get("type") == "response" and m.get("request_seq") == ev_seq, timeout=15)
            except Exception as e:
                p(f"  Post-check failed: {e}")

        # === Disconnect ===
        seq = client.request("disconnect", {"terminateDebuggee": False})
        try:
            client.collect_until(
                lambda m: m.get("type") == "response" and m.get("request_seq") == seq, timeout=10)
        except:
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
            except:
                pass
        if bridge:
            try:
                bridge.kill()
                bridge.communicate(timeout=3)
            except:
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
