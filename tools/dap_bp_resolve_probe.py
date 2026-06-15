#!/usr/bin/env python
# DIAGNOSTIC v2: wait for attach response, THEN run bp evaluate and wait for
# each evaluate RESPONSE (not fixed sleeps). Filters out module-load noise.
import socket, subprocess, json, threading, time, sys, contextlib
DAP = r"C:/tools/lldb-22/install/bin/lldb-dap.exe"
SRC_FILE = sys.argv[4] if len(sys.argv) > 4 else "MobileShadingRenderer.cpp"
SRC_LINE = int(sys.argv[5]) if len(sys.argv) > 5 else 1345

def free_port():
    s = socket.socket(); s.bind(("127.0.0.1", 0)); pp = s.getsockname()[1]; s.close(); return pp

def main():
    serial = sys.argv[1]; pport = int(sys.argv[2]); pid = int(sys.argv[3])
    dp = free_port()
    p = subprocess.Popen([DAP, "--connection", "listen://127.0.0.1:%d" % dp],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        time.sleep(1.3)
        s = socket.create_connection(("127.0.0.1", dp), timeout=10); s.settimeout(300)
        seq = [0]; buf = b""; resp = {}; lock = threading.Lock()
        def snd(c, a=None):
            seq[0] += 1; sid = seq[0]
            b = {"seq": sid, "type": "request", "command": c}
            if a is not None: b["arguments"] = a
            d = json.dumps(b).encode()
            s.sendall(("Content-Length: %d\r\n\r\n" % len(d)).encode() + d)
            return sid
        def rdr():
            nonlocal buf
            try:
                while True:
                    c = s.recv(16384)
                    if not c: break
                    buf += c
                    while b"\r\n\r\n" in buf:
                        h, r = buf.split(b"\r\n\r\n", 1)
                        ln = int([l for l in h.split(b"\r\n") if l.lower().startswith(b"content-length")][0].split(b":")[1])
                        if len(r) < ln: break
                        m = json.loads(r[:ln]); buf = r[ln:]
                        if m.get("type") == "response":
                            with lock: resp[m.get("request_seq")] = m
            except Exception: pass
        threading.Thread(target=rdr, daemon=True).start()
        def wait_resp(sid, t):
            dl = time.time() + t
            while time.time() < dl:
                with lock:
                    if sid in resp: return resp[sid]
                if p.poll() is not None: return "DEAD"
                time.sleep(0.3)
            return None
        def ev(expr, t=30):
            sid = snd("evaluate", {"expression": expr, "context": "repl"})
            r = wait_resp(sid, t)
            if r == "DEAD": return "ADAPTER_DEAD"
            if not r: return "TIMEOUT"
            if not r.get("success"): return "FAIL: " + str(r.get("message"))[:200]
            return (r.get("body") or {}).get("result", "")[:600]

        attach_cmds = [
            "platform select remote-android",
            "platform connect connect://[%s]:%d" % (serial, pport),
            "process attach --pid %d" % pid,
            "process handle SIGSEGV --notify false --pass true  --stop false",
            "process handle SIGBUS  --notify false --pass true  --stop false",
            "process handle SIGPIPE --notify false --pass false --stop false",
        ]
        cfg = {"name": "UE Android Attach (lldb-dap)", "type": "lldb", "request": "attach",
               "stopOnEntry": True, "timeout": 240, "attachCommands": attach_cmds,
               "initCommands": ["settings set plugin.process.gdb-remote.packet-timeout 60",
                                "settings set target.inline-breakpoint-strategy always"]}
        snd("initialize", {"adapterID": "lldb"}); time.sleep(0.8)
        asid = snd("attach", cfg)
        print("waiting for attach response (module enum can take 60-120s)...", flush=True)
        ar = wait_resp(asid, 200)
        print("ATTACH:", "DEAD" if ar == "DEAD" else (("ok" if ar.get("success") else "FAIL:" + str(ar.get("message"))[:160]) if ar else "TIMEOUT"), flush=True)
        if not ar or ar in ("DEAD",) or not ar.get("success"):
            print("adapter poll:", p.poll(), flush=True); return
        print("IMGLIST:", ev("`image list libUE4.so", 40), flush=True)
        print("BPSET:", ev("`breakpoint set -f %s -l %d" % (SRC_FILE, SRC_LINE), 40), flush=True)
        print("BPLIST:", ev("`breakpoint list", 30), flush=True)
        print("adapter poll after bp:", p.poll(), flush=True)
        with contextlib.suppress(Exception): s.close()
    finally:
        with contextlib.suppress(Exception): p.kill()

if __name__ == "__main__":
    main()
