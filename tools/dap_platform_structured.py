#!/usr/bin/env python
# DIAGNOSTIC: test lldb-dap structured platform attach keys (bypass getopt URL bug)
import socket, subprocess, json, threading, time, sys, contextlib
DAP = r"C:/tools/lldb-22/install/bin/lldb-dap.exe"
SYMSO = r"E:/Projects/SampleGame-3.4/Source/SampleGame/Binaries/Android/SampleGame_Symbols_v100000001/SampleGame-arm64/libUE4.so"

def free_port():
    s = socket.socket(); s.bind(("127.0.0.1", 0)); pp = s.getsockname()[1]; s.close(); return pp

def main():
    pport = int(sys.argv[1]); pid = int(sys.argv[2]); mode = sys.argv[3]
    dap_port = free_port()
    p = subprocess.Popen([DAP, "--connection", "listen://127.0.0.1:%d" % dap_port],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        time.sleep(1.3)
        s = socket.create_connection(("127.0.0.1", dap_port), timeout=10); s.settimeout(60)
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
                        elif m.get("type") == "event" and m.get("event") in ("initialized","stopped","exited","terminated","process"):
                            print("EVT| %s %s" % (m.get("event"), json.dumps(m.get("body") or {})[:120]), flush=True)
            except Exception: pass
        threading.Thread(target=rdr, daemon=True).start()

        common = {"name": "p", "type": "lldb", "request": "attach",
                  "stopOnEntry": True, "timeout": 60,
                  "initCommands": ["settings set plugin.process.gdb-remote.packet-timeout 60"]}
        if mode == "A":
            # platformName + gdb-remote-port (structured, no getopt)
            cfg = dict(common, platformName="remote-android",
                       **{"gdb-remote-port": pport, "gdb-remote-hostname": "127.0.0.1"})
        elif mode == "Aport":
            # gdb-remote-port only (no platform)
            cfg = dict(common, **{"gdb-remote-port": pport, "gdb-remote-hostname": "127.0.0.1"})
        elif mode == "sym":
            # with symbol-rich program so module resolves
            cfg = dict(common, program=SYMSO, platformName="remote-android",
                       **{"gdb-remote-port": pport, "gdb-remote-hostname": "127.0.0.1"})
        print("=== MODE=%s pport=%d ===" % (mode, pport), flush=True)
        print("CFG=" + json.dumps({k: cfg[k] for k in cfg if k not in ("initCommands",)}), flush=True)
        snd("initialize", {"adapterID": "lldb", "linesStartAt1": True, "columnsStartAt1": True})
        time.sleep(0.9)
        snd("attach", cfg)
        # wait for attach resp
        time.sleep(20)
        snd("threads", {})
        time.sleep(3)
        with contextlib.suppress(Exception): s.close()
    finally:
        with contextlib.suppress(Exception): p.kill()

if __name__ == "__main__":
    main()
