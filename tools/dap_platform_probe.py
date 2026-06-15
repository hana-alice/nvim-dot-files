#!/usr/bin/env python
# tools/dap_platform_probe.py  (DIAGNOSTIC ONLY)
#
# Robust lldb-dap platform-mode probe. Self-contained:
#  - picks a free host port for the lldb-dap --connection listener
#  - always kills the spawned lldb-dap on exit
#  - prints every DAP "output" event verbatim
#
# It assumes the device-side `lldb-server platform --server --listen 127.0.0.1:<pport>`
# is already running and `adb forward tcp:<pport> tcp:<pport>` is set up by the caller.
#
# Usage:
#   python tools/dap_platform_probe.py <pport> <pid> <connect-form>
# connect-form:
#   sep      : initCommands = [platform select remote-android, platform connect connect://localhost:<pport>]
#   oneline  : initCommands = [platform connect -p remote-android connect://localhost:<pport>]
#   gdbsrv   : initCommands = [platform select remote-gdb-server, platform connect connect://localhost:<pport>]
#   ipv4     : ... connect://127.0.0.1:<pport>
#   bracket  : ... connect://[127.0.0.1]:<pport>

import socket, subprocess, json, threading, time, sys, contextlib

DAP = r"C:/tools/lldb-22/install/bin/lldb-dap.exe"
SYMSO = r"E:/sample/zeqiang_sample_3.4/Source/Client/Binaries/Android/Client_Symbols_v170300916/Client-arm64/libUE4.so"

def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    pp = s.getsockname()[1]
    s.close()
    return pp

def main():
    pport = int(sys.argv[1]); pid = int(sys.argv[2]); form = sys.argv[3]
    dap_port = free_port()
    p = subprocess.Popen([DAP, "--connection", "listen://127.0.0.1:%d" % dap_port],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        time.sleep(1.3)
        s = socket.create_connection(("127.0.0.1", dap_port), timeout=10); s.settimeout(40)
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
                            print("RESP| %s %s" % (m.get("command"),
                                  "ok" if m.get("success") else "FAIL:" + str(m.get("message"))[:160]), flush=True)
            except Exception:
                pass
        threading.Thread(target=rdr, daemon=True).start()

        url4 = "connect://127.0.0.1:%d" % pport
        urlL = "connect://localhost:%d" % pport
        urlB = "connect://[127.0.0.1]:%d" % pport
        forms = {
            "sep":     ["platform select remote-android", "platform connect " + urlL],
            "ipv4":    ["platform select remote-android", "platform connect " + url4],
            "bracket": ["platform select remote-android", "platform connect " + urlB],
            "oneline": ["platform connect -p remote-android " + urlL],
            "gdbsrv":  ["platform select remote-gdb-server", "platform connect " + urlL],
        }
        init = forms[form]
        print("=== FORM=%s initCommands=%r ===" % (form, init), flush=True)
        snd("initialize", {"adapterID": "lldb", "linesStartAt1": True, "columnsStartAt1": True})
        time.sleep(0.9)
        snd("attach", {"name": "probe", "type": "lldb", "request": "attach", "stopOnEntry": True,
                       "timeout": 60, "initCommands": init,
                       "attachCommands": ["process attach --pid %d" % pid]})
        time.sleep(25)
        with contextlib.suppress(Exception): s.close()
    finally:
        with contextlib.suppress(Exception): p.kill()

if __name__ == "__main__":
    main()
