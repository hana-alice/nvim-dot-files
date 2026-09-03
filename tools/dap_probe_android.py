#!/usr/bin/env python
# tools/dap_probe_android.py
#
# Controlled, repeatable diagnostic probe for UE Android DAP attach.
# DIAGNOSTIC ONLY — not referenced by any runtime Lua. Reproduces the
# gdb-remote handshake + breakpoint command sequence outside nvim so the
# adapter <-> lldb-server boundary can be isolated.
#
# ⚠️ FALSIFIED ROUTE (docs/CONSTRAINTS.md K31/P16/K56). This probe drives the
# `lldb-server gdbserver --attach <pid>` form, which is NOT the production
# route: on this device class it never reliably binds its listen port, and the
# `lost connection` class of failure it was written to chase is actually a
# server-uid problem (K56 — the platform server must run as the app uid via
# `run-as <pkg>`). The production probe is tools/dap_platform_probe.py
# (serial-form `platform connect` + `process attach --pid`). Kept only as a
# differential/archaeological instrument.
#
# Usage:
#   python tools/dap_probe_android.py <serial> <pid> <MODE> [base_hex]
#   MODE = handshake | none | imagelookup | sourcebp | addrbp
#
# handshake : start gdbserver, forward, raw $qSupported probe (no lldb-dap)
# none      : full lldb-dap attach (target create -> gdb-remote -> signals
#             -> ASLR slide), then `breakpoint list` + `image list`
# imagelookup / sourcebp / addrbp : as `none`, plus one breakpoint command
#
# Only ever targets the serial you pass. Always cleans up lldb-server +
# adb forward on exit.

import socket, subprocess, json, threading, time, sys, os

DAP   = r"C:/tools/lldb-22/install/bin/lldb-dap.exe"
SYMSO = r"E:/Projects/SampleGame-3.4/Source/SampleGame/Binaries/Android/SampleGame_Symbols_v100000001/SampleGame-arm64/libUE4.so"
PKG   = "<android-package>"
SRC_FILE = "MobileShadingRenderer.cpp"
SRC_LINE = 1345

DEV_PORT = 18011
DAP_PORT = 12399

def adb(serial, *args, capture=True):
    env = dict(os.environ); env["MSYS_NO_PATHCONV"] = "1"
    cmd = ["adb", "-s", serial] + list(args)
    r = subprocess.run(cmd, capture_output=True, text=True, env=env)
    return r.stdout.strip(), r.returncode

def runas(serial, shcmd):
    return adb(serial, "shell", "run-as %s sh -c %r" % (PKG, shcmd))

def gdbsum(p):
    return "$%s#%02x" % (p, sum(p.encode()) & 0xff)

def read_base(serial, pid):
    out, _ = adb(serial, "shell", "run-as", PKG, "cat", "/proc/%d/maps" % pid)
    for line in out.splitlines():
        if line.rstrip().endswith("/lib/arm64/libUE4.so"):
            return line.split("-", 1)[0].strip()
    return None

def start_gdbserver(serial, pid, port, bind="*"):
    runas(serial, "killall lldb-server 2>/dev/null")
    time.sleep(0.5)
    adb(serial, "forward", "--remove", "tcp:%d" % port)
    adb(serial, "forward", "tcp:%d" % port, "tcp:%d" % port)
    env = dict(os.environ); env["MSYS_NO_PATHCONV"] = "1"
    sh = "files/lldb-server gdbserver --attach %d %s:%d 2>&1" % (pid, bind, port)
    p = subprocess.Popen(["adb", "-s", serial, "shell", "run-as %s sh -c %r" % (PKG, sh)],
                         stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=env)
    return p

def cleanup(serial, port, gsp):
    try: gsp.kill()
    except Exception: pass
    runas(serial, "killall lldb-server 2>/dev/null")
    adb(serial, "forward", "--remove", "tcp:%d" % port)

def mode_handshake(serial, pid):
    print("=== MODE=handshake ===")
    for bind in ("*", "127.0.0.1"):
        port = DEV_PORT
        print("--- bind=%s ---" % bind)
        gsp = start_gdbserver(serial, pid, port, bind)
        time.sleep(6)
        # is the server listening on device?
        ltcp, _ = adb(serial, "shell", "run-as", PKG, "cat", "/proc/net/tcp")
        hexport = "%04X" % port
        listening = [l for l in ltcp.splitlines() if (":%s" % hexport) in l]
        print("device /proc/net/tcp lines for port %d (%s): %d" % (port, hexport, len(listening)))
        for l in listening[:3]:
            print("   ", l.strip()[:90])
        tr, _ = adb(serial, "shell", "run-as", PKG, "cat", "/proc/%d/status" % pid)
        print("   target:", " ".join(x for x in tr.splitlines() if x.startswith(("State","TracerPid"))))
        # raw handshake from host
        try:
            s = socket.create_connection(("127.0.0.1", port), timeout=6); s.settimeout(6)
            print("   host connect: OK")
            s.sendall(b"+")
            s.sendall(gdbsum("qSupported").encode())
            time.sleep(1.5)
            try:
                rx = s.recv(600)
                print("   handshake RX (%d bytes): %r" % (len(rx), rx[:200]))
            except Exception as e:
                print("   handshake recv err:", e)
            s.close()
        except Exception as e:
            print("   host connect FAIL:", e)
        # server stdout so far
        try:
            gsp.stdout and os.set_blocking(gsp.stdout.fileno(), False)
        except Exception:
            pass
        cleanup(serial, port, gsp)
        time.sleep(1)

# ---- lldb-dap based modes ----
class Dap:
    def __init__(self):
        env = dict(os.environ)
        self.p = subprocess.Popen([DAP, "--connection", "listen://127.0.0.1:%d" % DAP_PORT],
                                  stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=env)
        time.sleep(1.2)
        self.s = socket.create_connection(("127.0.0.1", DAP_PORT), timeout=10); self.s.settimeout(150)
        self.seq = 0; self.events = []; self.buf = b""
        threading.Thread(target=self._reader, daemon=True).start()
    def send(self, cmd, args=None):
        self.seq += 1
        body = {"seq": self.seq, "type": "request", "command": cmd}
        if args is not None: body["arguments"] = args
        data = json.dumps(body).encode()
        self.s.sendall(("Content-Length: %d\r\n\r\n" % len(data)).encode() + data)
    def _reader(self):
        try:
            while True:
                c = self.s.recv(8192)
                if not c: break
                self.buf += c
                while b"\r\n\r\n" in self.buf:
                    head, rest = self.buf.split(b"\r\n\r\n", 1)
                    ln = int([l for l in head.split(b"\r\n") if l.lower().startswith(b"content-length")][0].split(b":")[1])
                    if len(rest) < ln: break
                    msg = json.loads(rest[:ln]); self.buf = rest[ln:]; self.events.append(msg)
                    t = msg.get("type"); tag = msg.get("command") or msg.get("event"); ex = ""
                    if msg.get("event") == "output": ex = repr((msg.get("body") or {}).get("output",""))[:200]
                    if t == "response": ex = "ok" if msg.get("success") else "FAIL:" + repr(msg.get("message",""))[:160]
                    print("  <<", t, tag, ex)
        except Exception as e:
            print("  reader_end", e)
    def wait(self, pred, t=70):
        dl = time.time() + t
        while time.time() < dl:
            for m in self.events:
                if pred(m): return m
            if self.p.poll() is not None: return "DEAD"
            time.sleep(0.3)
        return None
    def evaluate(self, expr, label):
        print("--- EVAL[%s]: %s" % (label, expr))
        before = len(self.events)
        self.send("evaluate", {"expression": expr, "context": "repl"})
        time.sleep(3.0)
        for m in self.events[before:]:
            if m.get("type") == "response" and m.get("command") == "evaluate":
                print("    RESULT:", ("ok " + repr((m.get('body') or {}).get('result',''))[:400]) if m.get("success") else "FAIL:" + repr(m.get("message",""))[:200])
        print("    adapter poll:", self.p.poll())
    def close(self):
        try: self.s.close()
        except Exception: pass
        try: self.p.kill()
        except Exception: pass

def mode_dap(serial, pid, mode, base):
    print("=== MODE=%s (base=0x%s) ===" % (mode, base))
    gsp = start_gdbserver(serial, pid, DEV_PORT, "*")
    time.sleep(4)
    d = Dap()
    attach_cmds = [
        '?target create "%s"' % SYMSO,
        '?gdb-remote 127.0.0.1:%d' % DEV_PORT,
        '?process handle SIGSEGV --notify false --pass true  --stop false',
        '?process handle SIGBUS  --notify false --pass true  --stop false',
        '?process handle SIGPIPE --notify false --pass false --stop false',
        '?target modules load --file libUE4.so --slide 0x%s' % base,
    ]
    d.send("initialize", {"adapterID": "lldb", "linesStartAt1": True, "columnsStartAt1": True})
    time.sleep(1.0)
    d.send("attach", {"name": "probe", "type": "lldb", "request": "attach",
                      "stopOnEntry": True, "timeout": 180, "attachCommands": attach_cmds,
                      "initCommands": ["settings set plugin.process.gdb-remote.packet-timeout 60"],
                      "postRunCommands": []})
    ar = d.wait(lambda m: m.get("type") == "response" and m.get("command") == "attach", 80)
    print("=== ATTACH:", "DEAD" if ar == "DEAD" else (("ok" if ar.get("success") else "FAIL") if ar else "TIMEOUT"))
    print("=== adapter poll:", d.p.poll())
    if ar and ar != "DEAD" and ar.get("success"):
        d.evaluate("`image list libUE4.so", "imglist")
        if mode == "imagelookup":
            d.evaluate("`image lookup --file %s --line %d" % (SRC_FILE, SRC_LINE), "imglookup")
        elif mode == "sourcebp":
            d.evaluate("`breakpoint set -f %s -l %d" % (SRC_FILE, SRC_LINE), "sourcebp")
        elif mode == "addrbp":
            d.evaluate("`image lookup --file %s --line %d" % (SRC_FILE, SRC_LINE), "imglookup")
            print("    (read address from imglookup output, then breakpoint set --address manually)")
        d.evaluate("`breakpoint list", "bplist")
    d.close()
    cleanup(serial, DEV_PORT, gsp)

def main():
    serial = sys.argv[1]; pid = int(sys.argv[2]); mode = sys.argv[3]
    base = sys.argv[4] if len(sys.argv) > 4 else None
    if mode == "handshake":
        mode_handshake(serial, pid)
    else:
        if not base:
            base = read_base(serial, pid)
            print("resolved base = 0x%s" % base)
        mode_dap(serial, pid, mode, base)

if __name__ == "__main__":
    main()
