#!/usr/bin/env python3
"""Evidence-gated Apple device LLDB-DAP probe.

The default ``preflight`` command is read-only and emits only redacted counts,
tool versions, and capability booleans. ``attach`` requires every project and
device identity as an explicit argument; it never discovers a "first" device,
certificate, process, binary, or source file on behalf of the caller.

This is a diagnostic gate, not the Neovim runtime implementation. A successful
attach result is deliberately stricter than an adapter startup: host binary and
dSYM UUIDs must match, the device process identity must be proven, a DAP
breakpoint must resolve and stop, the top frame must map to the requested source,
and disconnect must leave the pre-existing application alive.
"""

from __future__ import annotations

import argparse
import contextlib
import hashlib
import json
import os
from pathlib import Path
import queue
import re
import shutil
import subprocess
import tempfile
import threading
import time
from typing import Any


SCHEMA = "ue-ios-dap-probe-v1"
UUID_RE = re.compile(r"UUID:\s+([0-9A-Fa-f-]+)")
MODULE_UUID_RE = re.compile(r"^\[\s*\d+\]\s+([0-9A-Fa-f-]{36})\s+", re.MULTILINE)
IDENTITY_COUNT_RE = re.compile(r"(\d+)\s+valid identities found")
APPLE_DEVICE_ID_RE = re.compile(
    r"(?<![0-9A-Fa-f])(?:[0-9A-Fa-f]{40}|[0-9A-Fa-f]{8}-[0-9A-Fa-f]{16})(?![0-9A-Fa-f])"
)


def digest(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8", "surrogateescape")).hexdigest()[:12]


def pid_digest(value: int | str) -> str:
    return digest(f"pid:{value}")


def redact_text(value: str, *sensitive: str) -> str:
    redacted = value
    for item in sorted((item for item in sensitive if item), key=len, reverse=True):
        redacted = redacted.replace(item, "<redacted>")
    return APPLE_DEVICE_ID_RE.sub("<redacted-device-id>", redacted)


def path_evidence(value: str) -> dict[str, str]:
    path = Path(value).expanduser()
    resolved = str(path.resolve(strict=False))
    evidence = {"name": path.name, "digest": digest(resolved)}
    if resolved.startswith(("/Applications/", "/usr/", "/Library/")):
        evidence["system_path"] = resolved
    return evidence


def attach_identity(args: argparse.Namespace) -> dict[str, Any]:
    return {
        "device_digest": digest(args.device),
        "bundle_digest": digest(args.bundle_id),
        "pid_digest": pid_digest(args.pid),
        "binary": path_evidence(args.binary),
        "dsym": path_evidence(args.dsym),
        "source": {"name": Path(args.source).name, "line": args.line},
        "adapter": path_evidence(args.adapter),
    }


def command(
    argv: list[str], *, timeout: float = 30.0, check: bool = False
) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(
        argv,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        timeout=timeout,
        check=False,
    )
    if check and result.returncode != 0:
        raise RuntimeError(f"command failed ({result.returncode}): {Path(argv[0]).name}")
    return result


def atomic_write_json(path: str, payload: dict[str, Any]) -> None:
    destination = Path(path).expanduser()
    destination.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=destination.name + ".", dir=destination.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(payload, handle, ensure_ascii=False, indent=2, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, destination)
    except BaseException:
        with contextlib.suppress(OSError):
            os.unlink(temporary)
        raise


def emit(payload: dict[str, Any], output: str | None) -> None:
    if output:
        atomic_write_json(output, payload)
    print(json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True))


def result_devices(payload: Any) -> list[dict[str, Any]]:
    if not isinstance(payload, dict):
        return []
    devices = payload.get("devices")
    if not isinstance(devices, list):
        result = payload.get("result")
        devices = result.get("devices") if isinstance(result, dict) else None
    return [item for item in devices or [] if isinstance(item, dict)]


def is_available_physical_ios(item: dict[str, Any]) -> bool:
    hardware = item.get("hardwareProperties") or {}
    connection = item.get("connectionProperties") or {}
    platform = str(
        item.get("platform")
        or item.get("operatingSystem")
        or item.get("runtimePlatform")
        or hardware.get("platform")
        or ""
    )
    available = (
        item.get("available") is True
        or str(item.get("availability") or "").lower() == "available"
        or (
            connection.get("pairingState") == "paired"
            and str(connection.get("tunnelState") or "").lower() == "connected"
        )
    )
    physical = (
        item.get("physical") is True
        or hardware.get("reality") == "physical"
        or hardware.get("deviceType") in {"iPhone", "iPad"}
    )
    return available and physical and platform.startswith("iOS")


def read_json(path: Path) -> Any:
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def first_line(value: str) -> str:
    for line in value.splitlines():
        if line.strip():
            return line.strip()[:240]
    return ""


def legacy_device(payload: Any) -> dict[str, Any] | None:
    if not isinstance(payload, dict) or payload.get("Event") != "DeviceDetected":
        return None
    device = payload.get("Device")
    return device if isinstance(device, dict) else None


def legacy_device_evidence(device: dict[str, Any]) -> dict[str, str]:
    keys = {
        "product_type": "ProductType",
        "product_version": "ProductVersion",
        "build_version": "BuildVersion",
        "architecture": "modelArch",
    }
    return {
        output: str(device.get(source) or "")
        for output, source in keys.items()
        if device.get(source)
    }


def expected_legacy_symbols_root(device: dict[str, Any]) -> str | None:
    product = str(device.get("ProductType") or "")
    version = str(device.get("ProductVersion") or "")
    build = str(device.get("BuildVersion") or "")
    if not product or not version or not build:
        return None
    return f"{product} {version} ({build})"


def legacy_preflight(args: argparse.Namespace) -> int:
    checks: dict[str, Any] = {
        "device_digest": digest(args.device),
        "symbols": path_evidence(args.symbols),
    }
    blockers: list[str] = []

    selected = command([args.xcode_select, "-p"])
    selected_path = selected.stdout.strip()
    checks["selected_xcode"] = (
        path_evidence(selected_path) if selected.returncode == 0 and selected_path else None
    )
    if not checks["selected_xcode"]:
        blockers.append("selected-xcode-unavailable")
    versions = command([args.xcrun, "xcodebuild", "-version"])
    checks["xcode_version"] = first_line(versions.stdout or versions.stderr)

    ios_deploy = shutil.which(args.ios_deploy)
    checks["ios_deploy"] = path_evidence(ios_deploy) if ios_deploy else None
    if not ios_deploy:
        blockers.append("ios-deploy-unavailable")
    else:
        version = command([ios_deploy, "--version"])
        checks["ios_deploy_version"] = first_line(version.stdout or version.stderr)
        if version.returncode != 0:
            blockers.append("ios-deploy-version-failed")
        detected = command([
            ios_deploy,
            "--id",
            args.device,
            "--detect",
            "--json",
            "--no-wifi",
            "--timeout",
            str(max(1, int(args.timeout))),
        ], timeout=args.timeout + 5)
        device: dict[str, Any] | None = None
        if detected.returncode == 0:
            with contextlib.suppress(json.JSONDecodeError):
                device = legacy_device(json.loads(detected.stdout))
        checks["explicit_usb_device_detected"] = bool(
            device
            and detected.stdout
            and device.get("DeviceIdentifier") == args.device
        )
        if not checks["explicit_usb_device_detected"]:
            blockers.append("explicit-legacy-device-unavailable")

        if device:
            checks["device"] = legacy_device_evidence(device)
            try:
                major = int(str(device.get("ProductVersion") or "").split(".", 1)[0])
            except ValueError:
                major = 0
            checks["pre_ios17"] = 0 < major < 17
            if not checks["pre_ios17"]:
                blockers.append("legacy-backend-requires-pre-ios17")

            symbols = Path(args.symbols).expanduser().resolve(strict=False)
            expected_root = expected_legacy_symbols_root(device)
            checks["exact_device_support_layout"] = bool(
                expected_root
                and symbols.name == "Symbols"
                and symbols.parent.name == expected_root
            )
            checks["system_symbols_present"] = all(
                (symbols / relative).is_file()
                for relative in (
                    "usr/lib/libSystem.B.dylib",
                    "System/Library/Frameworks/Foundation.framework/Foundation",
                )
            )
            if not checks["exact_device_support_layout"]:
                blockers.append("legacy-device-support-layout-mismatch")
            if not checks["system_symbols_present"]:
                blockers.append("legacy-system-symbols-missing")

    adapter_find = command([args.xcrun, "--find", "lldb-dap"])
    adapter = adapter_find.stdout.strip()
    checks["adapter"] = path_evidence(adapter) if adapter_find.returncode == 0 and adapter else None
    if not checks["adapter"]:
        blockers.append("apple-lldb-dap-unavailable")
    else:
        adapter_version = command([adapter, "--version"])
        checks["adapter_version"] = first_line(adapter_version.stdout or adapter_version.stderr)

    symbols = str(Path(args.symbols).expanduser().resolve(strict=False))
    lldb = command([
        args.xcrun,
        "lldb",
        "--batch",
        "-o",
        "platform select remote-ios --sysroot " + lldb_quote(symbols),
        "-o",
        "platform status",
        "-o",
        "quit",
    ], timeout=args.timeout)
    lldb_output = lldb.stdout + "\n" + lldb.stderr
    checks["lldb_remote_ios_sysroot"] = lldb.returncode == 0 and "Platform: remote-ios" in lldb_output
    if not checks["lldb_remote_ios_sysroot"]:
        blockers.append("lldb-remote-ios-sysroot-unavailable")

    payload = {
        "schema": SCHEMA,
        "mode": "legacy-preflight",
        "status": "blocked" if blockers else "ready-for-legacy-transport-probe",
        "checks": checks,
        "blockers": sorted(set(blockers)),
        "note": (
            "Legacy preflight never unlocks the Neovim IOS DAP matrix; "
            "the strict source breakpoint attach gate is still required."
        ),
    }
    emit(payload, args.output)
    return 2 if blockers else 0


def preflight(args: argparse.Namespace) -> int:
    checks: dict[str, Any] = {}
    blockers: list[str] = []

    selected = command([args.xcode_select, "-p"])
    selected_path = selected.stdout.strip()
    checks["selected_xcode"] = (
        path_evidence(selected_path) if selected.returncode == 0 and selected_path else None
    )
    if not checks["selected_xcode"]:
        blockers.append("selected-xcode-unavailable")

    versions = command([args.xcrun, "xcodebuild", "-version"])
    checks["xcode_version"] = first_line(versions.stdout or versions.stderr)

    adapter_find = command([args.xcrun, "--find", "lldb-dap"])
    adapter = adapter_find.stdout.strip()
    checks["adapter"] = path_evidence(adapter) if adapter_find.returncode == 0 and adapter else None
    if not checks["adapter"]:
        blockers.append("apple-lldb-dap-unavailable")
    else:
        adapter_version = command([adapter, "--version"])
        checks["adapter_version"] = first_line(adapter_version.stdout or adapter_version.stderr)

    devicectl_version = command([args.xcrun, "devicectl", "--version"])
    checks["devicectl_version"] = first_line(devicectl_version.stdout or devicectl_version.stderr)
    if devicectl_version.returncode != 0:
        blockers.append("devicectl-unavailable")

    help_probe = command([
        args.xcrun,
        "lldb",
        "--batch",
        "-o",
        "help device select",
        "-o",
        "help device process attach",
        "-o",
        "quit",
    ])
    help_text = help_probe.stdout + "\n" + help_probe.stderr
    checks["lldb_device_select"] = "device select <device-uuid>" in help_text
    checks["lldb_device_process_attach"] = "device process attach" in help_text and "--pid" in help_text
    if not checks["lldb_device_select"] or not checks["lldb_device_process_attach"]:
        blockers.append("lldb-coredevice-commands-unavailable")

    identities = command([args.security, "find-identity", "-v", "-p", "codesigning"])
    identity_output = identities.stdout + "\n" + identities.stderr
    identity_match = IDENTITY_COUNT_RE.search(identity_output)
    identity_count = int(identity_match.group(1)) if identity_match else None
    checks["valid_signing_identity_count"] = identity_count
    if identities.returncode != 0 or identity_count is None:
        blockers.append("signing-identity-probe-failed")
    elif identity_count == 0:
        blockers.append("no-valid-signing-identity")

    with tempfile.TemporaryDirectory(prefix="ue-ios-dap-probe-") as temporary:
        device_json = Path(temporary) / "devices.json"
        devices_run = command([
            args.xcrun,
            "devicectl",
            "list",
            "devices",
            "--quiet",
            "--json-output",
            str(device_json),
        ])
        devices: list[dict[str, Any]] = []
        if devices_run.returncode == 0 and device_json.is_file():
            with contextlib.suppress(json.JSONDecodeError, OSError):
                devices = result_devices(read_json(device_json))
        available = [item for item in devices if is_available_physical_ios(item)]
        checks["known_device_count"] = len(devices)
        checks["available_physical_ios_count"] = len(available)
        if devices_run.returncode != 0 or not device_json.is_file():
            blockers.append("device-list-failed")
        elif not available:
            blockers.append("no-available-physical-ios-device")

    payload = {
        "schema": SCHEMA,
        "mode": "preflight",
        "status": "blocked" if blockers else "ready-for-attach-probe",
        "checks": checks,
        "blockers": sorted(set(blockers)),
        "note": "Preflight never unlocks the Neovim IOS DAP matrix; only a passing attach probe can do that.",
    }
    emit(payload, args.output)
    return 2 if blockers else 0


def recursive_dicts(value: Any):
    if isinstance(value, dict):
        yield value
        for child in value.values():
            yield from recursive_dicts(child)
    elif isinstance(value, list):
        for child in value:
            yield from recursive_dicts(child)


def app_identity(payload: Any, bundle_id: str) -> tuple[str, str] | None:
    result = payload.get("result") if isinstance(payload, dict) else None
    if not isinstance(result, dict):
        return None
    device_id = str(result.get("deviceIdentifier") or "")
    apps = result.get("apps") or result.get("applications") or result.get("installedApplications")
    matches = [
        item for item in apps or []
        if isinstance(item, dict)
        and (item.get("bundleIdentifier") or item.get("bundleID") or item.get("applicationIdentifier")) == bundle_id
    ]
    if not device_id or len(matches) != 1:
        return None
    app_url = str(matches[0].get("url") or matches[0].get("path") or matches[0].get("bundleURL") or "").rstrip("/")
    return (device_id, app_url) if app_url else None


def process_identity_matches(payload: Any, pid: int, device_id: str, app_url: str) -> bool:
    result = payload.get("result") if isinstance(payload, dict) else None
    if not isinstance(result, dict) or result.get("deviceIdentifier") != device_id:
        return False
    processes = result.get("runningProcesses") or result.get("processes") or []
    matches = [
        item for item in processes
        if isinstance(item, dict)
        and str(item.get("processIdentifier") or item.get("pid")) == str(pid)
    ]
    if len(matches) != 1:
        return False
    executable = str(
        matches[0].get("executable") or matches[0].get("executableURL") or matches[0].get("path") or ""
    ).rstrip("/")
    return executable.startswith(app_url + "/")


def uuid_set(xcrun: str, path: str) -> set[str]:
    probe = command([xcrun, "dwarfdump", "--uuid", path], timeout=30, check=True)
    values = {match.group(1).upper() for match in UUID_RE.finditer(probe.stdout + probe.stderr)}
    if not values:
        raise RuntimeError("dwarfdump returned no UUID")
    return values


def lldb_quote(value: str) -> str:
    if "\n" in value or "\r" in value or "\x00" in value:
        raise ValueError("LLDB command value contains a control character")
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def loaded_uuid_probe_command(expected_uuids: set[str]) -> str:
    values = ",".join(json.dumps(item) for item in sorted(expected_uuids))
    return "".join((
        "script import lldb; ios_expected_uuids={",
        values,
        "}; ios_target=lldb.target; ios_main_name=ios_target.GetExecutable().GetFilename(); ",
        "ios_loaded_main=[ios_module for ios_module in ios_target.modules ",
        "if ios_module.GetFileSpec().GetFilename() == ios_main_name ",
        "and ios_module.GetObjectFileHeaderAddress().GetLoadAddress(ios_target) ",
        "!= lldb.LLDB_INVALID_ADDRESS]; print('__UE_IOS_LOADED_UUID_OK__' ",
        "if len(ios_loaded_main) == 1 and ",
        "(ios_loaded_main[0].GetUUIDString() or '').upper() in ios_expected_uuids ",
        "else '__UE_IOS_LOADED_UUID_MISMATCH__')",
    ))


class DAPClient:
    def __init__(self, adapter: str):
        self.process = subprocess.Popen(
            [adapter],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        self.sequence = 0
        self.responses: dict[int, dict[str, Any]] = {}
        self.events: queue.Queue[dict[str, Any]] = queue.Queue()
        self.condition = threading.Condition()
        self.stderr = bytearray()
        self.reader = threading.Thread(target=self._read_messages, daemon=True)
        self.stderr_reader = threading.Thread(target=self._read_stderr, daemon=True)
        self.reader.start()
        self.stderr_reader.start()

    def _read_stderr(self) -> None:
        assert self.process.stderr is not None
        while len(self.stderr) < 65536:
            chunk = self.process.stderr.read(min(4096, 65536 - len(self.stderr)))
            if not chunk:
                break
            self.stderr.extend(chunk)

    def _read_messages(self) -> None:
        assert self.process.stdout is not None
        stream = self.process.stdout
        try:
            while True:
                headers: dict[str, str] = {}
                while True:
                    line = stream.readline()
                    if not line:
                        return
                    if line in (b"\r\n", b"\n"):
                        break
                    key, _, value = line.decode("ascii", "replace").partition(":")
                    headers[key.lower()] = value.strip()
                length = int(headers["content-length"])
                body = stream.read(length)
                if len(body) != length:
                    return
                message = json.loads(body.decode("utf-8"))
                with self.condition:
                    if message.get("type") == "response":
                        self.responses[int(message.get("request_seq", -1))] = message
                    elif message.get("type") == "event":
                        self.events.put(message)
                    self.condition.notify_all()
        except BaseException:
            with self.condition:
                self.condition.notify_all()

    def send(self, name: str, arguments: dict[str, Any] | None = None) -> int:
        self.sequence += 1
        message: dict[str, Any] = {
            "seq": self.sequence,
            "type": "request",
            "command": name,
        }
        if arguments is not None:
            message["arguments"] = arguments
        data = json.dumps(message, separators=(",", ":")).encode("utf-8")
        frame = f"Content-Length: {len(data)}\r\n\r\n".encode("ascii") + data
        if not self.process.stdin:
            raise RuntimeError("adapter stdin is unavailable")
        self.process.stdin.write(frame)
        self.process.stdin.flush()
        return self.sequence

    def response(self, sequence: int, timeout: float) -> dict[str, Any]:
        deadline = time.monotonic() + timeout
        with self.condition:
            while sequence not in self.responses:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise TimeoutError(f"DAP response timeout for request {sequence}")
                if self.process.poll() is not None:
                    raise RuntimeError(f"lldb-dap exited with {self.process.returncode}")
                self.condition.wait(min(remaining, 0.25))
            response = self.responses.pop(sequence)
        if not response.get("success"):
            raise RuntimeError(f"DAP {response.get('command')} failed: {response.get('message')}")
        return response

    def request(self, name: str, arguments: dict[str, Any] | None, timeout: float) -> dict[str, Any]:
        return self.response(self.send(name, arguments), timeout)

    def event(self, name: str, timeout: float) -> dict[str, Any]:
        deadline = time.monotonic() + timeout
        deferred: list[dict[str, Any]] = []
        try:
            while True:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise TimeoutError(f"DAP event timeout for {name}")
                try:
                    message = self.events.get(timeout=remaining)
                except queue.Empty as error:
                    raise TimeoutError(f"DAP event timeout for {name}") from error
                if message.get("event") == name:
                    return message
                deferred.append(message)
        finally:
            for message in deferred:
                self.events.put(message)

    def output_marker(self, success: str, failure: str, timeout: float) -> bool:
        deadline = time.monotonic() + timeout
        deferred: list[dict[str, Any]] = []
        try:
            while True:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise TimeoutError("DAP loaded-image UUID marker timed out")
                try:
                    message = self.events.get(timeout=remaining)
                except queue.Empty as error:
                    raise TimeoutError("DAP loaded-image UUID marker timed out") from error
                body = message.get("body") or {}
                output = str(body.get("output") or "").strip() if message.get("event") == "output" else ""
                if output == success:
                    return True
                if output == failure:
                    return False
                deferred.append(message)
        finally:
            for message in deferred:
                self.events.put(message)

    def close(self) -> None:
        with contextlib.suppress(Exception):
            if self.process.stdin:
                self.process.stdin.close()
        with contextlib.suppress(subprocess.TimeoutExpired):
            self.process.wait(timeout=2)
        if self.process.poll() is None:
            self.process.kill()
            with contextlib.suppress(subprocess.TimeoutExpired):
                self.process.wait(timeout=2)


def process_payload(args: argparse.Namespace) -> tuple[Any, bool, str | None]:
    with tempfile.TemporaryDirectory(prefix="ue-ios-process-probe-") as temporary:
        app_output = Path(temporary) / "apps.json"
        app_result = command([
            args.xcrun,
            "devicectl",
            "device",
            "info",
            "apps",
            "--device",
            args.device,
            "--bundle-id",
            args.bundle_id,
            "--quiet",
            "--json-output",
            str(app_output),
        ], timeout=args.timeout)
        if app_result.returncode != 0 or not app_output.is_file():
            return None, False, None
        identity = app_identity(read_json(app_output), args.bundle_id)
        if identity is None:
            return None, False, None
        device_id, app_url = identity
        output = Path(temporary) / "processes.json"
        result = command([
            args.xcrun,
            "devicectl",
            "device",
            "info",
            "processes",
            "--device",
            device_id,
            "--quiet",
            "--json-output",
            str(output),
        ], timeout=args.timeout)
        if result.returncode != 0 or not output.is_file():
            return None, False, device_id
        payload = read_json(output)
        return payload, process_identity_matches(payload, args.pid, device_id, app_url), device_id


def cli_attach_probe(args: argparse.Namespace, expected_uuids: set[str], device_id: str) -> dict[str, bool]:
    process = subprocess.Popen(
        [args.xcrun, "lldb"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    output = bytearray()
    condition = threading.Condition()

    def read_output() -> None:
        assert process.stdout is not None
        while True:
            chunk = os.read(process.stdout.fileno(), 4096)
            if not chunk:
                break
            with condition:
                if len(output) < 4 * 1024 * 1024:
                    output.extend(chunk[: 4 * 1024 * 1024 - len(output)])
                condition.notify_all()

    reader = threading.Thread(target=read_output, daemon=True)
    reader.start()

    def send(*commands: str) -> None:
        if not process.stdin:
            raise RuntimeError("LLDB CLI stdin is unavailable")
        process.stdin.write(("\n".join(commands) + "\n").encode())
        process.stdin.flush()

    marker_index = 0

    def marked(commands: list[str], timeout: float) -> str:
        nonlocal marker_index
        marker_index += 1
        marker = f"__UE_IOS_CLI_PROBE_{marker_index}__"
        with condition:
            start = len(output)
        send(*commands, "script print(" + json.dumps(marker) + ")")
        deadline = time.monotonic() + timeout
        with condition:
            while marker.encode() not in output[start:]:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise TimeoutError("LLDB CLI command marker timed out")
                if process.poll() is not None:
                    raise RuntimeError(f"LLDB CLI exited with {process.returncode}")
                condition.wait(min(remaining, 0.25))
            return bytes(output[start:]).decode("utf-8", "replace")

    attached = False
    threads = False
    uuid_match = False
    detached = False
    exit_ok = False
    deadline = time.monotonic() + args.timeout
    try:
        marked([
            "settings set target.memory-module-load-level minimal",
            "settings set symbols.enable-external-lookup false",
            "target create " + lldb_quote(args.binary),
            "device select " + lldb_quote(device_id),
            f"device process attach -p {args.pid}",
            "target symbols add " + lldb_quote(args.dsym),
        ], min(args.timeout, 30))
        while time.monotonic() < deadline and not (attached and threads and uuid_match):
            time.sleep(2)
            remaining = max(0.25, deadline - time.monotonic())
            probe = marked([
                "process status",
                "thread list",
                "image list -u -f -- " + lldb_quote(Path(args.binary).name),
            ], min(remaining, 10))
            loaded_uuids = {match.group(1).upper() for match in MODULE_UUID_RE.finditer(probe)}
            attached = "Process" in probe and "stopped" in probe
            threads = "thread #" in probe
            uuid_match = bool(loaded_uuids) and loaded_uuids == expected_uuids
        if attached:
            detach_output = marked(["process detach"], min(max(0.25, deadline - time.monotonic()), 10))
            detached = "detached" in detach_output.lower()
        send("quit")
        process.wait(timeout=min(max(0.25, deadline - time.monotonic()), 10))
        exit_ok = process.returncode == 0
    finally:
        if process.poll() is None:
            with contextlib.suppress(Exception):
                send("process detach", "quit")
            with contextlib.suppress(subprocess.TimeoutExpired):
                process.wait(timeout=5)
        if process.poll() is None:
            process.kill()
            with contextlib.suppress(subprocess.TimeoutExpired):
                process.wait(timeout=2)
    return {
        "exit_ok": exit_ok,
        "attached": attached,
        "threads": threads,
        "loaded_image_uuid_match": uuid_match,
        "detached": detached,
    }


def dap_attach_probe(
    args: argparse.Namespace, expected_uuids: set[str], device_id: str
) -> dict[str, Any]:
    client = DAPClient(args.adapter)
    attached = False
    disconnect_ack = False
    try:
        client.request("initialize", {
            "adapterID": "nvim-dap",
            "clientID": "neovim",
            "clientName": "neovim",
            "columnsStartAt1": True,
            "linesStartAt1": True,
            "pathFormat": "path",
            "supportsProgressReporting": True,
            "supportsRunInTerminalRequest": True,
            "supportsStartDebuggingRequest": True,
            "supportsVariableType": True,
            "locale": os.environ.get("LANG", "en_US"),
        }, args.timeout)
        attach_sequence = client.send("attach", {
            "name": "UE IOS protocol probe",
            "type": "lldb",
            "request": "attach",
            "stopOnEntry": True,
            "cwd": str(Path(args.source).resolve().parent),
            "timeout": max(240, int(args.timeout)),
            "initCommands": [
                "settings set stop-disassembly-display never",
                "settings set target.inline-breakpoint-strategy always",
                "settings set target.move-to-nearest-code true",
                "settings set target.process.stop-on-sharedlibrary-events false",
                "settings set target.memory-module-load-level partial",
            ],
            "attachCommands": [
                "target create " + lldb_quote(args.binary),
                "device select " + lldb_quote(device_id),
                f"device process attach -p {args.pid}",
                "target symbols add " + lldb_quote(args.dsym),
            ],
            "postRunCommands": [
                "process status",
                loaded_uuid_probe_command(expected_uuids),
            ],
        })
        client.event("initialized", args.timeout)
        attached = True
        loaded_uuid_match = client.output_marker(
            "__UE_IOS_LOADED_UUID_OK__",
            "__UE_IOS_LOADED_UUID_MISMATCH__",
            args.timeout,
        )
        if not loaded_uuid_match:
            raise RuntimeError("loaded iOS executable UUID does not match the local debug artifact")
        breakpoint_response = client.request("setBreakpoints", {
            "source": {"path": str(Path(args.source).resolve())},
            "breakpoints": [{"line": args.line}],
            "sourceModified": False,
        }, args.timeout)
        breakpoints = (breakpoint_response.get("body") or {}).get("breakpoints") or []
        verified = any(item.get("verified") is True for item in breakpoints if isinstance(item, dict))
        client.request("configurationDone", {}, args.timeout)
        client.response(attach_sequence, args.timeout)
        initial_stop = client.event("stopped", args.timeout)
        threads_response = client.request("threads", {}, args.timeout)
        threads = (threads_response.get("body") or {}).get("threads") or []
        thread_id = (initial_stop.get("body") or {}).get("threadId")
        if thread_id is None and threads:
            thread_id = threads[0].get("id")
        if thread_id is None:
            raise RuntimeError("DAP returned no stopped thread")
        max_bootstrap_stops = 8
        stopped = initial_stop
        for bootstrap_index in range(max_bootstrap_stops + 1):
            stopped_body = stopped.get("body") or {}
            reason = stopped_body.get("reason")
            hit_ids = stopped_body.get("hitBreakpointIds") or []
            if reason == "breakpoint" or hit_ids:
                break
            if bootstrap_index == max_bootstrap_stops:
                raise RuntimeError(
                    f"exceeded {max_bootstrap_stops} non-breakpoint bootstrap stops"
                )
            thread_id = stopped_body.get("threadId") or thread_id
            client.request("continue", {"threadId": thread_id}, args.timeout)
            stopped = client.event("stopped", args.hit_timeout)
        reason = (stopped.get("body") or {}).get("reason")
        stopped_thread = (stopped.get("body") or {}).get("threadId") or thread_id
        stack = client.request("stackTrace", {
            "threadId": stopped_thread,
            "startFrame": 0,
            "levels": 20,
        }, args.timeout)
        frames = (stack.get("body") or {}).get("stackFrames") or []
        expected_source = str(Path(args.source).resolve())
        frame_match = any(
            isinstance(frame, dict)
            and str((frame.get("source") or {}).get("path") or "") == expected_source
            and int(frame.get("line") or -1) == args.line
            for frame in frames
        )
        client.request("disconnect", {
            "restart": False,
            "terminateDebuggee": False,
        }, args.timeout)
        disconnect_ack = True
        return {
            "attach_response": True,
            "loaded_image_uuid_match": loaded_uuid_match,
            "breakpoint_verified": verified,
            "thread_count": len(threads),
            "stopped_reason": reason,
            "source_frame_match": frame_match,
            "disconnect_ack": disconnect_ack,
        }
    finally:
        if attached and not disconnect_ack:
            with contextlib.suppress(Exception):
                client.request("disconnect", {
                    "restart": False,
                    "terminateDebuggee": False,
                }, min(args.timeout, 10))
        client.close()


def attach(args: argparse.Namespace) -> int:
    payload: dict[str, Any] = {
        "schema": SCHEMA,
        "mode": "attach",
        "status": "failed",
        "identity": attach_identity(args),
        "checks": {},
        "errors": [],
    }
    canonical_device = ""
    try:
        for label, value in (("binary", args.binary), ("dsym", args.dsym), ("source", args.source)):
            if not Path(value).exists():
                raise RuntimeError(f"{label} does not exist")
        binary_uuids = uuid_set(args.xcrun, args.binary)
        dsym_uuids = uuid_set(args.xcrun, args.dsym)
        payload["checks"]["host_uuid_match"] = binary_uuids == dsym_uuids
        payload["checks"]["uuid_count"] = len(binary_uuids)
        if binary_uuids != dsym_uuids:
            raise RuntimeError("host binary and dSYM UUIDs differ")
        verified_dsym = command(
            [args.xcrun, "dwarfdump", "--verify", "--quiet", args.dsym],
            timeout=args.timeout,
        )
        payload["checks"]["dsym_verified"] = verified_dsym.returncode == 0
        if verified_dsym.returncode != 0:
            payload["status"] = "blocked"
            raise RuntimeError("dSYM failed DWARF verification")

        _, process_match, canonical_device = process_payload(args)
        payload["checks"]["process_identity_match"] = process_match
        if not process_match:
            raise RuntimeError("device process identity could not be proven")

        dap = dap_attach_probe(args, binary_uuids, canonical_device)
        payload["checks"]["dap"] = dap
        if not (
            dap.get("attach_response")
            and dap.get("loaded_image_uuid_match")
            and dap.get("breakpoint_verified")
            and dap.get("stopped_reason") == "breakpoint"
            and dap.get("source_frame_match")
            and dap.get("disconnect_ack")
        ):
            raise RuntimeError("raw DAP breakpoint/frame gate failed")

        cli = cli_attach_probe(args, binary_uuids, canonical_device)
        payload["checks"]["lldb_cli"] = cli
        if not all(cli.values()):
            raise RuntimeError("LLDB CLI attach/thread/detach probe failed")

        _, survived, _ = process_payload(args)
        payload["checks"]["app_survived_disconnect"] = survived
        if not survived:
            raise RuntimeError("application did not survive detach")
        payload["checks"]["loaded_image_uuid_match"] = cli["loaded_image_uuid_match"]
        payload["status"] = "passed"
        payload["errors"] = []
        emit(payload, args.output)
        return 0
    except (OSError, RuntimeError, TimeoutError, ValueError, subprocess.TimeoutExpired) as error:
        payload["errors"].append(redact_text(
            str(error),
            args.device,
            args.bundle_id,
            str(args.pid),
            args.binary,
            args.dsym,
            args.source,
            args.adapter,
            canonical_device,
        )[:240])
    emit(payload, args.output)
    return 1


def self_test(args: argparse.Namespace) -> int:
    fixture = {
        "result": {
            "devices": [
                {
                    "identifier": "PRIVATE-DEVICE-ID",
                    "connectionProperties": {"pairingState": "paired", "tunnelState": "connected"},
                    "hardwareProperties": {"platform": "iOS", "reality": "physical", "deviceType": "iPhone"},
                },
                {
                    "identifier": "OFFLINE-ID",
                    "connectionProperties": {"pairingState": "paired", "tunnelState": "unavailable"},
                    "hardwareProperties": {"platform": "iOS", "reality": "physical", "deviceType": "iPhone"},
                },
            ]
        }
    }
    devices = result_devices(fixture)
    assert len(devices) == 2
    assert len([item for item in devices if is_available_physical_ios(item)]) == 1
    app_fixture = {"result": {
        "deviceIdentifier": "PRIVATE-DEVICE-ID",
        "apps": [{"bundleIdentifier": "com.example.game", "url": "file:///private/Game.app"}],
    }}
    assert app_identity(app_fixture, "com.example.game") == (
        "PRIVATE-DEVICE-ID", "file:///private/Game.app"
    )
    process_fixture = {"result": {
        "deviceIdentifier": "PRIVATE-DEVICE-ID",
        "runningProcesses": [{"processIdentifier": 42, "executable": "file:///private/Game.app/Game"}],
    }}
    assert process_identity_matches(process_fixture, 42, "PRIVATE-DEVICE-ID", "file:///private/Game.app")
    assert not process_identity_matches(process_fixture, 43, "PRIVATE-DEVICE-ID", "file:///private/Game.app")
    assert MODULE_UUID_RE.search("[  0] 322CB148-C401-3EA0-A023-4B21A104D42F /tmp/Game")
    redacted = json.dumps(path_evidence("/private/example/Secret/Binary"))
    assert "/private/example" not in redacted
    assert "PRIVATE-DEVICE-ID" not in json.dumps({"device_digest": digest("PRIVATE-DEVICE-ID")})
    private_ids = "legacy 0123456789abcdef0123456789abcdef01234567 modern 12345678-0123456789ABCDEF"
    scrubbed = redact_text(private_ids)
    assert "0123456789abcdef0123456789abcdef01234567" not in scrubbed
    assert "12345678-0123456789ABCDEF" not in scrubbed
    assert scrubbed.count("<redacted-device-id>") == 2
    legacy_fixture = {
        "Event": "DeviceDetected",
        "Device": {
            "DeviceIdentifier": "PRIVATE-DEVICE-ID",
            "DeviceName": "PRIVATE-NAME",
            "ProductType": "iPhone13,2",
            "ProductVersion": "15.4.1",
            "BuildVersion": "19E258",
            "modelArch": "arm64e",
        },
    }
    legacy = legacy_device(legacy_fixture)
    assert legacy is not None
    legacy_evidence = legacy_device_evidence(legacy)
    assert legacy_evidence["product_type"] == "iPhone13,2"
    assert "DeviceIdentifier" not in legacy_evidence
    assert "DeviceName" not in legacy_evidence
    assert expected_legacy_symbols_root(legacy) == "iPhone13,2 15.4.1 (19E258)"
    attach_identity_example = attach_identity(argparse.Namespace(
        device="PRIVATE-DEVICE-ID",
        bundle_id="com.example.game",
        pid=4242,
        binary="/private/example/MyGame",
        dsym="/private/example/MyGame.dSYM",
        source="/private/example/Game.cpp",
        line=7,
        adapter="/Applications/Xcode.app/Contents/Developer/usr/bin/lldb-dap",
    ))
    encoded_identity = json.dumps(attach_identity_example, sort_keys=True)
    assert '"pid":' not in encoded_identity
    assert '"pid_digest":' in encoded_identity
    assert "4242" not in encoded_identity
    assert attach_identity_example["pid_digest"] == pid_digest(4242)
    payload = {
        "schema": SCHEMA,
        "mode": "self-test",
        "status": "passed",
        "attach_identity_example": attach_identity_example,
    }
    emit(payload, args.output)
    return 0


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(description=__doc__)
    subcommands = root.add_subparsers(dest="mode", required=True)

    pre = subcommands.add_parser("preflight", help="Probe local tools, signing count, and available device count")
    pre.add_argument("--xcrun", default="/usr/bin/xcrun")
    pre.add_argument("--xcode-select", default="/usr/bin/xcode-select")
    pre.add_argument("--security", default="/usr/bin/security")
    pre.add_argument("--output")
    pre.set_defaults(run=preflight)

    legacy = subcommands.add_parser(
        "legacy-preflight",
        help="Probe an explicit pre-iOS17 MobileDevice target and exact DeviceSupport symbols",
    )
    legacy.add_argument("--xcrun", default="/usr/bin/xcrun")
    legacy.add_argument("--xcode-select", default="/usr/bin/xcode-select")
    legacy.add_argument("--ios-deploy", default="ios-deploy")
    legacy.add_argument("--device", required=True)
    legacy.add_argument("--symbols", required=True)
    legacy.add_argument("--timeout", type=float, default=5.0)
    legacy.add_argument("--output")
    legacy.set_defaults(run=legacy_preflight)

    attach_parser = subcommands.add_parser("attach", help="Run the strict CLI/raw-DAP attach gate")
    attach_parser.add_argument("--xcrun", default="/usr/bin/xcrun")
    attach_parser.add_argument("--adapter", required=True)
    attach_parser.add_argument("--device", required=True)
    attach_parser.add_argument("--pid", type=int, required=True)
    attach_parser.add_argument("--bundle-id", required=True)
    attach_parser.add_argument("--binary", required=True)
    attach_parser.add_argument("--dsym", required=True)
    attach_parser.add_argument("--source", required=True)
    attach_parser.add_argument("--line", type=int, required=True)
    attach_parser.add_argument("--timeout", type=float, default=45.0)
    attach_parser.add_argument("--hit-timeout", type=float, default=120.0)
    attach_parser.add_argument("--output")
    attach_parser.set_defaults(run=attach)

    test = subcommands.add_parser("self-test", help="Validate pure parsers and redaction without external tools")
    test.add_argument("--output")
    test.set_defaults(run=self_test)
    return root


def main() -> int:
    args = parser().parse_args()
    return int(args.run(args))


if __name__ == "__main__":
    raise SystemExit(main())
