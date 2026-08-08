#!/usr/bin/env python3
"""Read-only, path-sanitized real-workspace clangd definition smoke.

Input stays outside the repository:
  UE_CPP_CLANGD_SMOKE_SPEC={...}
The script may let clangd update its normal BackgroundIndex shard cache, but
never writes engine/project source files or project `.clangd` configuration.
"""

import hashlib
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import time


SPEC = json.loads(os.environ["UE_CPP_CLANGD_SMOKE_SPEC"])


def rpc_read(stream):
    headers = {}
    while True:
        line = stream.readline()
        if not line:
            return None
        if line == b"\r\n":
            break
        name, value = line.decode("utf-8").split(":", 1)
        headers[name.strip().lower()] = value.strip()
    return json.loads(stream.read(int(headers["content-length"])).decode("utf-8"))


class LSP:
    def __init__(self, cmd, cwd):
        self.stderr = tempfile.NamedTemporaryFile(prefix="nvim-ue-clangd-", suffix=".log", delete=False)
        self.process = subprocess.Popen(
            cmd, cwd=cwd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.stderr
        )
        self.next_id = 0

    def send(self, payload):
        data = json.dumps(payload).encode("utf-8")
        self.process.stdin.write(f"Content-Length: {len(data)}\r\n\r\n".encode("ascii"))
        self.process.stdin.write(data)
        self.process.stdin.flush()

    def notify(self, method, params):
        self.send({"jsonrpc": "2.0", "method": method, "params": params})

    def request(self, method, params):
        self.next_id += 1
        request_id = self.next_id
        self.send({"jsonrpc": "2.0", "id": request_id, "method": method, "params": params})
        while True:
            message = rpc_read(self.process.stdout)
            if message is None:
                raise RuntimeError("clangd-exited")
            if message.get("id") == request_id:
                if "error" in message:
                    raise RuntimeError("clangd-request-error")
                return message.get("result")

    def close(self):
        try:
            self.request("shutdown", None)
            self.notify("exit", None)
        except Exception:
            pass
        try:
            self.process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            self.process.kill()
        self.stderr.close()
        try:
            os.unlink(self.stderr.name)
        except OSError:
            pass


def compile_command(case):
    tool = pathlib.Path(__file__).resolve().parents[1] / "tools" / "query_compile_command.py"
    cmd = [sys.executable, str(tool), SPEC["base_cdb"], case.get("donor", case["path"])]
    if os.path.normcase(case.get("donor", case["path"])) != os.path.normcase(case["path"]):
        cmd.extend(["--subject", case["path"]])
    result = subprocess.run(cmd, capture_output=True, text=True)
    decoded = json.loads(result.stdout)
    if result.returncode != 0 or decoded.get("state") != "resolved":
        raise RuntimeError(f"{case['label']}:compile-command:{decoded.get('reason', 'failed')}")
    return decoded["command"]


def position(case):
    return {"line": int(case["line"]) - 1, "character": int(case["column"]) - 1}


def first_location(value):
    if not value:
        return None
    item = value if isinstance(value, dict) else value[0]
    if "targetUri" in item:
        uri = item["targetUri"]
        line = item["targetSelectionRange"]["start"]["line"] + 1
    else:
        uri = item["uri"]
        line = item["range"]["start"]["line"] + 1
    return {"name": pathlib.Path(uri.replace("file:///", "")).name, "line": line}


def symbol_identity(value):
    if not value:
        return None, None
    item = value if isinstance(value, dict) else value[0]
    return item.get("usr"), item.get("containerName")


def request_at(client, case, method):
    return client.request(method, {
        "textDocument": {"uri": pathlib.Path(case["path"]).as_uri()},
        "position": position(case),
    })


def short_hash(value):
    return hashlib.sha256((value or "").encode("utf-8")).hexdigest()[:16]


def main():
    cases = SPEC["cases"]
    changes = {case["path"]: compile_command(case) for case in cases}
    semantic_dir = pathlib.Path(SPEC["semantic_cdb_dir"])
    clangd = SPEC["clangd_path"]
    client = LSP([
        clangd,
        "--background-index",
        "--background-index-priority=background",
        "--enable-config=false",
        "--pch-storage=memory",
        "--clang-tidy=false",
        "-j=1",
        f"--compile-commands-dir={semantic_dir}",
    ], str(semantic_dir))
    try:
        root_uri = pathlib.Path(SPEC["workspace_root"]).as_uri()
        client.request("initialize", {
            "processId": None,
            "rootUri": root_uri,
            "capabilities": {"textDocument": {}, "workspace": {}},
            "initializationOptions": {
                "compilationDatabasePath": str(semantic_dir),
                "compilationDatabaseChanges": changes,
            },
        })
        client.notify("initialized", {})
        client.notify("workspace/didChangeConfiguration", {
            "settings": {"compilationDatabaseChanges": changes}
        })
        for case in cases:
            path = pathlib.Path(case["path"])
            client.notify("textDocument/didOpen", {
                "textDocument": {
                    "uri": path.as_uri(),
                    "languageId": "cpp",
                    "version": 1,
                    "text": path.read_text(encoding="utf-8", errors="replace"),
                }
            })

        deadline = time.monotonic() + float(SPEC.get("timeout_s", 600))
        resolved = {}
        while time.monotonic() < deadline:
            for case in cases:
                target = first_location(request_at(client, case, "textDocument/definition"))
                if target and target["name"] == case["expected_name"]:
                    expected_line = case.get("expected_line")
                    if expected_line is None or target["line"] == int(expected_line):
                        resolved[case["label"]] = target
            if len(resolved) == len(cases):
                break
            time.sleep(2)
        if len(resolved) != len(cases):
            missing = sorted(case["label"] for case in cases if case["label"] not in resolved)
            raise RuntimeError("definition-timeout:" + ",".join(missing))

        identities = {}
        containers = {}
        for case in cases:
            usr, container = symbol_identity(request_at(client, case, "textDocument/symbolInfo"))
            if not usr:
                raise RuntimeError(case["label"] + ":identity-missing")
            identities[case["label"]] = usr
            containers[case["label"]] = container or ""
            expected_container = case.get("expected_container")
            if expected_container and expected_container not in containers[case["label"]]:
                raise RuntimeError(case["label"] + ":container-mismatch")

        groups = {}
        for case in cases:
            group = case.get("usr_group")
            if group:
                if group in groups and groups[group] != identities[case["label"]]:
                    raise RuntimeError(group + ":identity-conflict")
                groups[group] = identities[case["label"]]
        for case in cases:
            distinct = case.get("usr_distinct_from")
            if distinct and identities[case["label"]] == identities[distinct]:
                raise RuntimeError(case["label"] + ":identity-not-distinct")

        for case in cases:
            target = resolved[case["label"]]
            print(json.dumps({
                "label": case["label"],
                "state": "resolved",
                "usr_hash": short_hash(identities[case["label"]]),
                "container": containers[case["label"]],
                "target": f"{target['name']}:{target['line']}",
            }, separators=(",", ":")))
        print(json.dumps({"summary": "PASS", "cases": len(cases)}, separators=(",", ":")))
        return 0
    finally:
        client.close()


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as error:
        print(json.dumps({"summary": "FAIL", "reason": str(error)}, separators=(",", ":")),
              file=sys.stderr)
        sys.exit(1)
