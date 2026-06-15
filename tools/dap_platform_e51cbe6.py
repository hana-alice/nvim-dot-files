#!/usr/bin/env python
# DIAGNOSTIC: reproduce the 5/21 e51cbe6 WORKING platform-mode attach exactly.
# device: lldb-server platform --server --listen *:<pport>  (from /data/local/tmp)
# host attachCommands:
#   platform select remote-android
#   platform connect connect://[<serial>]:<pport>
#   process attach --pid <pid>
#   process handle SIG* ...
import socket, subprocess, json, threading, time, sys, contextlib
DAP = r"C:/tools/lldb-22/install/bin/lldb-dap.exe"
SYMSO = r"E:/aki/zeqiang_aki_3.4/Source/Client/Binaries/Android/Client_Symbols_v170300916/Client-arm64/libUE4.so"

def free_port():
    s = socket.socket(); s.bind(("127.0.0.1", 0)); pp = s.getsockname()[1]; s.close(); return pp

def main():
    serial = sys.argv[1]; pport = int(sys.argv[2]); pid = int(sys.argv[3])
    dap_port = free_port()
    p = subprocess.Popen([DAP, "--connection", "listen://127.0.0.1:%d" % dap_port],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        time.sleep(1.3)
        s = socket.create_connection(("127.0.0.1", dap_port), timeout=10); s.settimeout(200)
        seq = [0]; buf = b""
        def snd(c, a=None):
            seq[0] += 1
            b = {"seq": seq[0], "type": "request", "command": c}
            if a is not None: b["arguments"] = a
            d = json.dumps(b).encode()
            s.sendall(("Content-Length: %d\r\n\r\n" % len(d)).encode() + d)
        def rdr():
            nonlocal buf
            try:
                while True:
                    c = s.recv(8192)
                    if not c: break
                    buf += c
                    while b"\r\n\r\n" in buf:
                        h, r = buf.split(b"\r\n\r\n", 1)
                        ln = int([l for l in h.split(b"\r\n") if l.lower().startswith(b"content-length")][0].split(b":")[1])
                        if len(r) < ln: break
                        m = json.loads(r[:ln]); buf = r[ln:]
                        if m.get("event") == "output":
                            o = (m.get("body") or {}).get("output", "")
                            if o.strip(): print("OUT| " + o.rstrip()[:240], flush=True)
                        elif m.get("type") == "response":
                            print("RESP| %s %s" % (m.get("command"), "ok" if m.get("success") else "FAIL:" + str(m.get("message"))[:200]), flush=True)
                        elif m.get("type") == "event" and m.get("event") in ("initialized","stopped","exited","terminated"):
                            print("EVT| %s %s" % (m.get("event"), json.dumps(m.get("body") or {})[:140]), flush=True)
            except Exception: pass
        threading.Thread(target=rdr, daemon=True).start()
        attach_cmds = [
            "platform select remote-android",
            "platform connect connect://[%s]:%d" % (serial, pport),
            "process attach --pid %d" % pid,
            "process handle SIGSEGV --notify false --pass false --stop false",
            "process handle SIGBUS  --notify false --pass false --stop false",
            "process handle SIGPIPE --notify false --pass false --stop false",
        ]
        cfg = {"name": "UE Android Attach (lldb-dap)", "type": "lldb", "request": "attach",
               "stopOnEntry": True, "timeout": 180, "attachCommands": attach_cmds,
               "initCommands": ["settings set plugin.process.gdb-remote.packet-timeout 60",
                                "settings set target.inline-breakpoint-strategy always"]}
        print("=== e51cbe6 reproduce: connect://[%s]:%d pid=%d ===" % (serial, pport, pid), flush=True)
        snd("initialize", {"adapterID": "lldb", "linesStartAt1": True, "columnsStartAt1": True})
        time.sleep(0.9)
        snd("attach", cfg)
        # wait attach
        dl = time.time() + 90; done = False
        while time.time() < dl and not done:
            time.sleep(0.5)
        time.sleep(30)
        snd("threads", {})
        time.sleep(4)
        with contextlib.suppress(Exception): s.close()
    finally:
        with contextlib.suppress(Exception): p.kill()

if __name__ == "__main__":
    main()
