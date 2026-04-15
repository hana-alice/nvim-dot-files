"""
Minimal CodeLLDB DAP test: HW BP at PC+4 (should fire immediately on continue).
This isolates whether CodeLLDB can handle hardware breakpoints at all.
"""
import json
import select
import socket
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import tools.android_lldb_probe as probe
from tools.sanitized_test_config import CODELLDB_ROOT, ENGINE_ROOT, PROJECT_ROOT

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
                ok = msg.get("success")
                p(f"  [resp:{cmd}] success={ok} {msg.get('message','')}")
            if pred(msg):
                return msgs, msg
        return msgs, None


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
        except OSError:
            time.sleep(0.2)
    raise RuntimeError(f"cannot connect to codelldb on port {port}")


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

        # Initialize
        seq = client.request("initialize", {
            "adapterID": "codelldb", "clientID": "e2e", "clientName": "e2e",
            "linesStartAt1": True, "columnsStartAt1": True, "pathFormat": "path",
            "supportsRunInTerminalRequest": False,
        })
        client.collect_until(lambda m: m.get("type") == "response" and m.get("request_seq") == seq, timeout=15)
        p("initialize: ok")

        # Attach config (NO ASLR fix — we're testing PC+4 which doesn't need it)
        target_create_cmds = [f'target create "{SYMBOLS}"']
        for ps in probe.DEFAULT_EXEC_SEARCH:
            target_create_cmds.append(f'settings append target.exec-search-paths "{ps}"')

        attach_cfg = {
            "name": "PC+4 Test",
            "type": "codelldb",
            "request": "attach",
            "breakpointMode": "file",
            "stopOnEntry": False,
            "program": str(SYMBOLS),
            "cwd": str(PROJECT_ROOT),
            "sourceLanguages": ["cpp"],
            "initCommands": [
                "settings set stop-disassembly-display never",
                "settings set target.inline-breakpoint-strategy always",
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

        # Don't send setBreakpoints — just configurationDone
        attach_seq = client.request("attach", attach_cfg)
        p("Waiting for initialized event...")
        msgs, init_evt = client.collect_until(
            lambda m: m.get("type") == "event" and m.get("event") == "initialized", timeout=90)
        if not init_evt:
            raise RuntimeError("No initialized event!")
        p("initialized event received")

        cfg_seq = client.request("configurationDone")

        # Wait for stopped + attach + configurationDone responses
        stopped_evt = None
        deadline = time.time() + 60
        while time.time() < deadline:
            try:
                msg = client.read_one(timeout=3)
            except TimeoutError:
                if stopped_evt:
                    break
                continue
            t = msg.get("type")
            ev = msg.get("event")
            if t == "event" and ev == "stopped":
                stopped_evt = msg
                body = msg.get("body") or {}
                p(f"  [stopped] reason={body.get('reason')} threadId={body.get('threadId')}")
            elif t == "event" and ev == "output":
                body = msg.get("body") or {}
                out = body.get("output", "").rstrip()
                if out and len(out) < 300:
                    p(f"  [output] {out}")
            elif t == "response":
                p(f"  [resp:{msg.get('command')}] success={msg.get('success')}")

        if not stopped_evt:
            raise RuntimeError("No stopped event after attach!")

        tid = (stopped_evt.get("body") or {}).get("threadId") or int(pid)
        p(f"\n=== Stopped. threadId={tid} ===")

        # Get stack trace to find PC
        st_seq = client.request("stackTrace", {"threadId": tid, "startFrame": 0, "levels": 1})
        msgs, st_resp = client.collect_until(
            lambda m: m.get("type") == "response" and m.get("request_seq") == st_seq, timeout=15)
        fid = None
        if st_resp:
            frs = (st_resp.get("body") or {}).get("stackFrames") or []
            if frs:
                fid = frs[0]["id"]
                p(f"  Top frame: {frs[0].get('name','?')} id={fid}")

        # Use LLDB to get PC — capture from output events since repl results go there
        p("\n=== Getting PC register ===")
        ev_seq = client.request("evaluate", {
            "expression": "register read pc",
            "context": "repl",
            **({"frameId": fid} if fid else {}),
        })
        pc_addr = None
        msgs, ev_resp = client.collect_until(
            lambda m: m.get("type") == "response" and m.get("request_seq") == ev_seq, timeout=15)
        # Parse PC from output events
        for m in msgs:
            if m.get("type") == "event" and m.get("event") == "output":
                out = (m.get("body") or {}).get("output", "")
                if "pc =" in out or "0x" in out:
                    for part in out.split():
                        if part.startswith("0x"):
                            try:
                                pc_addr = int(part, 16)
                            except ValueError:
                                pass
        # Also try evaluate result
        if not pc_addr and ev_resp:
            result = (ev_resp.get("body") or {}).get("result", "")
            for part in result.split():
                if part.startswith("0x"):
                    try:
                        pc_addr = int(part, 16)
                    except ValueError:
                        pass

        if not pc_addr:
            # Fallback: try expression evaluation for $pc
            p("  register read didn't give PC, trying expression $pc...")
            ev_seq2 = client.request("evaluate", {
                "expression": "?$pc",
                "context": "repl",
                **({"frameId": fid} if fid else {}),
            })
            msgs2, ev_resp2 = client.collect_until(
                lambda m: m.get("type") == "response" and m.get("request_seq") == ev_seq2, timeout=15)
            if ev_resp2:
                result2 = (ev_resp2.get("body") or {}).get("result", "")
                p(f"  ?$pc result: {result2}")
                for part in result2.split():
                    if part.startswith("0x"):
                        try:
                            pc_addr = int(part, 16)
                        except ValueError:
                            pass
            # Also check output events
            for m in msgs2:
                if m.get("type") == "event" and m.get("event") == "output":
                    out = (m.get("body") or {}).get("output", "")
                    for part in out.split():
                        if part.startswith("0x"):
                            try:
                                if not pc_addr:
                                    pc_addr = int(part, 16)
                            except ValueError:
                                pass

        if not pc_addr:
            p("ERROR: couldn't read PC via any method")
            return

        pc_plus_4 = pc_addr + 4
        p(f"  PC = 0x{pc_addr:x}, PC+4 = 0x{pc_plus_4:x}")

        # Set HW BP at PC+4
        p(f"\n=== Setting HW BP at PC+4 (0x{pc_plus_4:x}) ===")
        ev_seq = client.request("evaluate", {
            "expression": f"breakpoint set -H -a 0x{pc_plus_4:x}",
            "context": "repl",
            **({"frameId": fid} if fid else {}),
        })
        msgs, ev_resp = client.collect_until(
            lambda m: m.get("type") == "response" and m.get("request_seq") == ev_seq, timeout=15)
        if ev_resp:
            result = (ev_resp.get("body") or {}).get("result", "")
            p(f"  BP result: {result}")

        # Continue — should hit immediately
        p("\n=== Continue (expecting immediate hit) ===")
        cont_seq = client.request("continue", {"threadId": tid})
        msgs, _ = client.collect_until(
            lambda m: m.get("type") == "response" and m.get("request_seq") == cont_seq, timeout=10)

        # Wait for stopped event
        p("\n=== Waiting for PC+4 BP hit (10s) ===")
        msgs, hit = client.collect_until(
            lambda m: m.get("type") == "event" and m.get("event") == "stopped",
            timeout=10)
        if hit:
            body = hit.get("body") or {}
            reason = body.get("reason", "?")
            p(f"\n*** STOPPED: reason={reason} threadId={body.get('threadId')} ***")
            if reason == "breakpoint":
                p("SUCCESS: HW BP via CodeLLDB works! Issue is in address resolution.")
            else:
                p(f"Stopped for other reason: {reason}")
        else:
            p("\n*** FAILED: PC+4 HW BP didn't fire via CodeLLDB ***")
            p("This means CodeLLDB cannot use hardware breakpoints on this device.")

        # Disconnect
        seq = client.request("disconnect", {"terminateDebuggee": False})
        try:
            client.collect_until(lambda m: m.get("type") == "response" and m.get("request_seq") == seq, timeout=10)
        except:
            pass

    finally:
        if client:
            client.close()
        if adapter_proc:
            try:
                adapter_proc.kill()
                _, stderr = adapter_proc.communicate(timeout=5)
                if stderr and stderr.strip():
                    p(f"\n=== Adapter stderr ===\n{stderr.strip()}")
            except:
                pass
        if bridge:
            try:
                bridge.kill()
                bridge.communicate(timeout=3)
            except:
                pass
        probe.cleanup_device()


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        import traceback
        print(f"\nFATAL: {exc}", file=sys.stderr)
        traceback.print_exc(file=sys.stderr)
        sys.exit(1)
