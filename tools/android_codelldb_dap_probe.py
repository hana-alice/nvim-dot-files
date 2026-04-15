import argparse
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
DEFAULT_SOURCE = ENGINE_ROOT / "Engine" / "Source" / "Runtime" / "Launch" / "Private" / "LaunchEngineLoop.cpp"


def print_section(title):
    print(f"\n=== {title} ===", flush=True)


def allocate_port():
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


class DAPClient:
    def __init__(self, sock):
        self.sock = sock
        self.seq = 1
        self.buffer = bytearray()

    def close(self):
        self.sock.close()

    def send(self, payload):
        body = json.dumps(payload).encode("utf-8")
        header = f"Content-Length: {len(body)}\r\n\r\n".encode("ascii")
        self.sock.sendall(header + body)

    def request(self, command, arguments=None):
        seq = self.seq
        self.seq += 1
        self.send(
            {
                "seq": seq,
                "type": "request",
                "command": command,
                "arguments": arguments or {},
            }
        )
        return seq

    def read_message(self, timeout=30):
        deadline = time.time() + timeout
        while True:
            header_end = self.buffer.find(b"\r\n\r\n")
            if header_end != -1:
                header_blob = bytes(self.buffer[:header_end]).decode("ascii")
                headers = {}
                for line in header_blob.split("\r\n"):
                    key, value = line.split(":", 1)
                    headers[key.strip().lower()] = value.strip()
                length = int(headers["content-length"])
                total = header_end + 4 + length
                if len(self.buffer) >= total:
                    body = bytes(self.buffer[header_end + 4 : total])
                    del self.buffer[:total]
                    return json.loads(body.decode("utf-8"))

            remaining = deadline - time.time()
            if remaining <= 0:
                raise socket.timeout("timed out waiting for DAP payload")
            readable, _, _ = select.select([self.sock], [], [], remaining)
            if not readable:
                raise socket.timeout("timed out waiting for DAP payload")
            chunk = self.sock.recv(65536)
            if not chunk:
                raise RuntimeError("DAP stream closed")
            self.buffer.extend(chunk)

    def wait_for(self, predicate, timeout=30):
        deadline = time.time() + timeout
        messages = []
        while True:
            remaining = deadline - time.time()
            if remaining <= 0:
                raise TimeoutError(f"timed out waiting for DAP message; seen={messages}")
            try:
                message = self.read_message(timeout=min(remaining, 5))
            except socket.timeout:
                continue
            messages.append(
                {
                    "type": message.get("type"),
                    "event": message.get("event"),
                    "command": message.get("command"),
                    "success": message.get("success"),
                    "category": (message.get("body") or {}).get("category"),
                    "output": (message.get("body") or {}).get("output"),
                }
            )
            if predicate(message):
                message["_seen"] = messages
                return message


def adapter_command(port):
    if not CODELLDB_ADAPTER.is_file():
        raise RuntimeError(f"codelldb adapter not found: {CODELLDB_ADAPTER}")
    if not CODELLDB_LIBLLDB.is_file():
        raise RuntimeError(f"liblldb not found: {CODELLDB_LIBLLDB}")
    return [
        str(CODELLDB_ADAPTER),
        "--port",
        str(port),
        "--liblldb",
        str(CODELLDB_LIBLLDB),
    ]


def connect_client(port, timeout=15):
    deadline = time.time() + timeout
    last_error = None
    while time.time() < deadline:
        try:
            sock = socket.create_connection(("127.0.0.1", port), timeout=2)
            sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            return DAPClient(sock)
        except OSError as exc:
            last_error = exc
            time.sleep(0.2)
    raise RuntimeError(f"failed to connect to codelldb adapter on port {port}: {last_error}")


def source_map():
    return {
        ENGINE_ROOT.as_posix(): ENGINE_ROOT.as_posix(),
        PROJECT_ROOT.as_posix(): PROJECT_ROOT.as_posix(),
    }


def dap_attach_config(connect_uri, pid, symbols):
    search_paths = [str(symbols.parent), *android_probe.DEFAULT_EXEC_SEARCH[1:]]
    target_create_commands = [f'target create "{symbols}"']
    for path in search_paths:
        target_create_commands.append(f'settings append target.exec-search-paths "{path}"')
    return {
        "name": "Android Attach Probe",
        "type": "codelldb",
        "request": "launch",
        "breakpointMode": "file",
        "stopOnEntry": True,
        "program": str(symbols),
        "cwd": str(PROJECT_ROOT),
        "relativePathBase": str(PROJECT_ROOT),
        "sourceLanguages": ["cpp"],
        "sourceMap": source_map(),
        "launchCompleteCommand": "None",
        "initCommands": [
            "settings set stop-disassembly-display never",
            "settings set target.inline-breakpoint-strategy always",
            "settings set target.move-to-nearest-code true",
            "settings set target.process.stop-on-sharedlibrary-events false",
            "settings set target.preload-symbols false",
            "settings set symbols.load-on-demand true",
            "platform select remote-android",
        ],
        "targetCreateCommands": target_create_commands,
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


def send_initialize(client):
    initialize_seq = client.request(
        "initialize",
        {
            "adapterID": "codelldb",
            "clientID": "codex",
            "clientName": "codex",
            "locale": "zh-CN",
            "linesStartAt1": True,
            "columnsStartAt1": True,
            "pathFormat": "path",
            "supportsRunInTerminalRequest": False,
            "supportsVariablePaging": True,
            "supportsVariableType": True,
        },
    )
    response = client.wait_for(lambda msg: msg.get("type") == "response" and msg.get("request_seq") == initialize_seq, timeout=15)
    if not response.get("success", False):
        raise RuntimeError(f"initialize failed: {response}")
    return response


def send_set_breakpoints(client, source_file, line):
    seq = client.request(
        "setBreakpoints",
        {
            "source": {
                "name": Path(source_file).name,
                "path": str(source_file),
            },
            "breakpoints": [{"line": line}],
            "sourceModified": False,
        },
    )
    response = client.wait_for(lambda msg: msg.get("type") == "response" and msg.get("request_seq") == seq, timeout=20)
    if not response.get("success", False):
        raise RuntimeError(f"setBreakpoints failed: {response}")
    return response


def send_request_and_wait(client, command, arguments=None, timeout=20):
    seq = client.request(command, arguments)
    response = client.wait_for(lambda msg: msg.get("type") == "response" and msg.get("request_seq") == seq, timeout=timeout)
    if not response.get("success", False):
        raise RuntimeError(f"{command} failed: {response}")
    return response


def wait_for_event(client, name, timeout):
    return client.wait_for(lambda msg: msg.get("type") == "event" and msg.get("event") == name, timeout=timeout)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-file", default=str(DEFAULT_SOURCE))
    parser.add_argument("--line", type=int, default=4829)
    parser.add_argument("--seconds", type=int, default=60)
    parser.add_argument("--symbols", default=str(android_probe.DEFAULT_SYMBOLS))
    parser.add_argument("--breakpoint-phase", choices=["pre", "post"], default="pre")
    args = parser.parse_args()

    symbols = Path(args.symbols)
    source_file = Path(args.source_file)
    if not symbols.is_file():
        raise RuntimeError(f"symbols not found: {symbols}")
    if not source_file.is_file():
        raise RuntimeError(f"source file not found: {source_file}")

    android_probe.ensure_adb_ready()
    android_probe.cleanup_device()
    android_probe.stage_platform_bits(android_probe.AS2024_LLDB_SERVER)

    bridge = None
    adapter_proc = None
    client = None
    try:
        pid = android_probe.resolve_pid()
        bridge, connect_uri, _, serial = android_probe.start_platform_server(pid)

        print_section("Environment")
        print(f"serial={serial}")
        print(f"pid={pid}")
        print(f"connect_uri={connect_uri}")
        print(f"source={source_file}:{args.line}")

        port = allocate_port()
        adapter_proc = subprocess.Popen(
            adapter_command(port),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        client = connect_client(port)

        print_section("Initialize")
        initialize = send_initialize(client)
        print(json.dumps(initialize.get("body", {}), ensure_ascii=False, indent=2))

        print_section("Attach")
        attach_seq = client.request("attach", dap_attach_config(connect_uri, pid, symbols))
        initialized = wait_for_event(client, "initialized", timeout=20)
        print(json.dumps(initialized, ensure_ascii=False, indent=2))

        if args.breakpoint_phase == "pre":
            print_section("Set Breakpoints")
            bp_response = send_set_breakpoints(client, source_file, args.line)
            print(json.dumps(bp_response.get("body", {}), ensure_ascii=False, indent=2))

        print_section("Configuration Done")
        config_done = send_request_and_wait(client, "configurationDone", timeout=20)
        print(json.dumps(config_done.get("body", {}), ensure_ascii=False, indent=2))

        attach_response = None
        first_stop = None
        deadline = time.time() + 90
        while time.time() < deadline and (attach_response is None or first_stop is None):
            try:
                message = client.read_message(timeout=min(deadline - time.time(), 5))
            except socket.timeout:
                continue
            if message.get("type") == "response" and message.get("request_seq") == attach_seq:
                attach_response = message
            elif message.get("type") == "event" and message.get("event") == "stopped" and first_stop is None:
                first_stop = message
            elif message.get("type") == "event" and message.get("event") == "output":
                print(json.dumps(message, ensure_ascii=False, indent=2))
            elif message.get("type") == "event" and message.get("event") == "module":
                pass
            else:
                print(json.dumps(message, ensure_ascii=False, indent=2))

        print_section("Attach Response")
        print(json.dumps(attach_response or {"missing": True}, ensure_ascii=False, indent=2))

        print_section("Initial Stop")
        print(json.dumps(first_stop, ensure_ascii=False, indent=2))

        if first_stop is None:
            raise RuntimeError("initial stopped event not received")

        if args.breakpoint_phase == "post":
            print_section("Set Breakpoints")
            bp_response = send_set_breakpoints(client, source_file, args.line)
            print(json.dumps(bp_response.get("body", {}), ensure_ascii=False, indent=2))

        print_section("Continue")
        continue_response = send_request_and_wait(
            client,
            "continue",
            {
                "threadId": first_stop.get("body", {}).get("threadId"),
            },
            timeout=20,
        )
        print(json.dumps(continue_response.get("body", {}), ensure_ascii=False, indent=2))

        print_section("Breakpoint Stop")
        stop = wait_for_event(client, "stopped", timeout=args.seconds)
        print(json.dumps(stop, ensure_ascii=False, indent=2))

        thread_id = stop.get("body", {}).get("threadId")
        print_section("Stack Trace")
        stack = send_request_and_wait(
            client,
            "stackTrace",
            {
                "threadId": thread_id,
                "startFrame": 0,
                "levels": 8,
            },
            timeout=20,
        )
        print(json.dumps(stack.get("body", {}), ensure_ascii=False, indent=2))

        frames = stack.get("body", {}).get("stackFrames") or []
        frame_id = frames[0]["id"] if frames else None
        if frame_id is not None:
          print_section("Scopes")
          scopes = send_request_and_wait(client, "scopes", {"frameId": frame_id}, timeout=20)
          print(json.dumps(scopes.get("body", {}), ensure_ascii=False, indent=2))

        print_section("Disconnect")
        disconnect = send_request_and_wait(client, "disconnect", {"terminateDebuggee": False}, timeout=20)
        print(json.dumps(disconnect.get("body", {}), ensure_ascii=False, indent=2))
    finally:
        if client is not None:
            try:
                client.close()
            except Exception:
                pass
        if adapter_proc is not None:
            try:
                adapter_proc.kill()
            except Exception:
                pass
            try:
                stdout, stderr = adapter_proc.communicate(timeout=5)
                print_section("Adapter Logs")
                print("stdout:")
                print(stdout.strip())
                print("stderr:")
                print(stderr.strip())
            except Exception:
                pass
        if bridge is not None:
            try:
                bridge.kill()
            except Exception:
                pass
            try:
                bridge.communicate(timeout=5)
            except Exception:
                pass
        android_probe.cleanup_device()


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(f"FATAL: {exc}", file=sys.stderr)
        sys.exit(1)
