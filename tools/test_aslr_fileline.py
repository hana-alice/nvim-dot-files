"""
Test ASLR fix + file+line HW BP via CodeLLDB.
Goal: determine if the ASLR --slide fix produces correct addresses.
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
BREAK_FILE = "VulkanCommandBuffer.cpp"
BREAK_LINE = 334


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
            if rem <= 0: raise TimeoutError("DAP read timeout")
            r, _, _ = select.select([self.sock], [], [], rem)
            if not r: raise TimeoutError("DAP read timeout")
            chunk = self.sock.recv(65536)
            if not chunk: raise RuntimeError("DAP stream closed")
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
                p(f"  [resp:{msg.get('command','?')}] success={msg.get('success')} {msg.get('message','')}")
            if pred(msg): return msgs, msg
        return msgs, None

    def eval_repl(self, cmd, fid=None, timeout=15):
        """Evaluate a repl command and collect output events + response."""
        seq = self.request("evaluate", {
            "expression": cmd, "context": "repl",
            **({"frameId": fid} if fid else {}),
        })
        outputs = []
        msgs, resp = self.collect_until(
            lambda m: m.get("type") == "response" and m.get("request_seq") == seq, timeout=timeout)
        for m in msgs:
            if m.get("type") == "event" and m.get("event") == "output":
                outputs.append((m.get("body") or {}).get("output", ""))
        result = (resp.get("body") or {}).get("result", "") if resp else ""
        return result, "\n".join(outputs), resp


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
    raise RuntimeError(f"cannot connect to codelldb on port {port}")


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

    # Read actual /proc/maps for comparison
    maps_out = subprocess.run(["adb", "shell", f"cat /proc/{pid}/maps | grep libUE4.so | head -5"],
                              capture_output=True, text=True, timeout=10)
    p(f"\n=== /proc/{pid}/maps (libUE4.so) ===")
    p(maps_out.stdout.strip())
    # Parse actual base
    actual_base = None
    for line in maps_out.stdout.strip().splitlines():
        if "libUE4.so" in line:
            actual_base = int(line.split("-")[0], 16)
            break
    # Parse executable range
    exec_start = exec_end = None
    for line in maps_out.stdout.strip().splitlines():
        if "r-xp" in line and "libUE4.so" in line:
            parts = line.split()
            addrs = parts[0].split("-")
            exec_start = int(addrs[0], 16)
            exec_end = int(addrs[1], 16)
            break
    p(f"  Actual base: 0x{actual_base:x}" if actual_base else "  Actual base: unknown")
    p(f"  Exec range: 0x{exec_start:x}-0x{exec_end:x}" if exec_start else "  Exec range: unknown")

    adapter_proc = client = None
    try:
        port = allocate_port()
        adapter_proc = subprocess.Popen(
            [str(CODELLDB_ADAPTER), "--port", str(port), "--liblldb", str(CODELLDB_LIBLLDB)],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        )
        client = connect_client(port)

        # Initialize
        seq = client.request("initialize", {
            "adapterID": "codelldb", "clientID": "e2e",
            "linesStartAt1": True, "columnsStartAt1": True, "pathFormat": "path",
        })
        client.collect_until(lambda m: m.get("type") == "response" and m.get("request_seq") == seq, timeout=15)
        p("\ninitialize: ok")

        # Attach with ASLR fix in processCreateCommands
        target_create_cmds = [f'target create "{SYMBOLS}"']
        for ps in probe.DEFAULT_EXEC_SEARCH:
            target_create_cmds.append(f'settings append target.exec-search-paths "{ps}"')

        attach_cfg = {
            "type": "codelldb", "request": "attach",
            "breakpointMode": "file", "stopOnEntry": False,
            "program": str(SYMBOLS), "sourceLanguages": ["cpp"],
            "initCommands": [
                "settings set stop-disassembly-display never",
                "settings set target.inline-breakpoint-strategy always",
                "settings set target.move-to-nearest-code true",
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

        attach_seq = client.request("attach", attach_cfg)
        p("Waiting for initialized event...")
        msgs, init_evt = client.collect_until(
            lambda m: m.get("type") == "event" and m.get("event") == "initialized", timeout=90)
        if not init_evt:
            raise RuntimeError("No initialized event!")

        cfg_seq = client.request("configurationDone")

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
                body = msg.get("body") or {}
                p(f"  [stopped] reason={body.get('reason')} threadId={body.get('threadId')}")
            elif t == "event" and ev == "output":
                out = (msg.get("body") or {}).get("output", "").rstrip()
                if out and len(out) < 300: p(f"  [output] {out}")
            elif t == "response":
                p(f"  [resp:{msg.get('command')}] success={msg.get('success')}")

        if not stopped_evt:
            raise RuntimeError("No stopped event!")

        tid = (stopped_evt.get("body") or {}).get("threadId") or int(pid)
        p(f"\n=== Stopped. tid={tid} ===")

        # Get frame
        st_seq = client.request("stackTrace", {"threadId": tid, "startFrame": 0, "levels": 1})
        msgs, st_resp = client.collect_until(
            lambda m: m.get("type") == "response" and m.get("request_seq") == st_seq, timeout=15)
        fid = None
        if st_resp:
            frs = (st_resp.get("body") or {}).get("stackFrames") or []
            if frs: fid = frs[0]["id"]

        # Check LLDB's module base after ASLR fix
        p("\n=== Checking module base after ASLR fix ===")
        result, output, _ = client.eval_repl("image list libUE4.so", fid)
        # Parse address from image list output
        lldb_base = None
        for line in (output + result).splitlines():
            m = re.search(r'0x([0-9a-fA-F]+)\s+.*libUE4', line)
            if m:
                lldb_base = int(m.group(1), 16)
                break
        p(f"  LLDB module base: 0x{lldb_base:x}" if lldb_base else "  LLDB module base: unknown")
        if actual_base and lldb_base:
            if lldb_base == actual_base:
                p("  BASE MATCH OK")
            else:
                p(f"  *** BASE MISMATCH! actual=0x{actual_base:x} lldb=0x{lldb_base:x} ***")

        # Now set HW BP by file+line
        p(f"\n=== Setting HW BP: {BREAK_FILE}:{BREAK_LINE} ===")
        result, output, _ = client.eval_repl(
            f'breakpoint set -H --file "{BREAK_FILE}" --line {BREAK_LINE}', fid)
        bp_output = output + result
        p(f"  {bp_output.strip()}")

        # Parse the resolved address
        bp_addr = None
        m = re.search(r'address\s*=\s*0x([0-9a-fA-F]+)', bp_output)
        if m:
            bp_addr = int(m.group(1), 16)
            p(f"  BP address: 0x{bp_addr:x}")
            if exec_start and exec_end:
                if exec_start <= bp_addr < exec_end:
                    p(f"  ADDRESS IN EXEC RANGE: OK")
                else:
                    p(f"  *** ADDRESS NOT IN EXEC RANGE! 0x{exec_start:x}-0x{exec_end:x} ***")

        # Check breakpoint details
        result, output, _ = client.eval_repl("breakpoint list -v", fid)
        p(f"\n  Breakpoint details:\n  {(output+result).strip()[:500]}")

        # Continue and wait for hit
        p(f"\n=== Continue + wait for BP hit (30s) ===")
        cont_seq = client.request("continue", {"threadId": tid})
        client.collect_until(
            lambda m: m.get("type") == "response" and m.get("request_seq") == cont_seq, timeout=10)

        msgs, hit = client.collect_until(
            lambda m: m.get("type") == "event" and m.get("event") == "stopped"
                      and (m.get("body") or {}).get("reason") == "breakpoint",
            timeout=30)

        if hit:
            body = hit.get("body") or {}
            p(f"\n*** BREAKPOINT HIT! reason={body.get('reason')} threadId={body.get('threadId')} ***")
            p("SUCCESS: ASLR fix + file+line HW BP works!")
        else:
            p("\n*** File+line HW BP didn't fire in 30s ***")

            # Pause and check if the problem is the address
            pause_seq = client.request("pause", {"threadId": int(pid)})
            msgs, stop2 = client.collect_until(
                lambda m: m.get("type") == "event" and m.get("event") == "stopped", timeout=10)

            if stop2 and bp_addr:
                tid2 = (stop2.get("body") or {}).get("threadId") or int(pid)
                st_seq2 = client.request("stackTrace", {"threadId": tid2, "startFrame": 0, "levels": 1})
                msgs, st_resp2 = client.collect_until(
                    lambda m: m.get("type") == "response" and m.get("request_seq") == st_seq2, timeout=10)
                fid2 = None
                if st_resp2:
                    frs2 = (st_resp2.get("body") or {}).get("stackFrames") or []
                    if frs2: fid2 = frs2[0]["id"]

                # Check memory at BP address
                p(f"\n=== Diagnostics ===")
                for cmd in [
                    f"memory region 0x{bp_addr:x}",
                    "breakpoint list -v",
                    # Read 4 bytes at BP addr — if readable, the address maps to real memory
                    f"memory read -c 4 -fx 0x{bp_addr:x}",
                    # Check what function is actually at that address
                    f"image lookup -a 0x{bp_addr:x}",
                ]:
                    p(f"\n  >>> {cmd}")
                    result, output, _ = client.eval_repl(cmd, fid2)
                    p(f"  {(output+result).strip()[:400]}")

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
