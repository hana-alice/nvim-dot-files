import json
import os
import pathlib
import subprocess
import time


CASES = json.loads(os.environ["CLANGD_BG_CASES"])
if isinstance(CASES, dict):
    CASES = [CASES]


def read_message(stream):
    headers = {}
    while True:
        line = stream.readline()
        if not line:
            return None
        if line == b"\r\n":
            break
        name, value = line.decode("utf-8").split(":", 1)
        headers[name.strip().lower()] = value.strip()
    body = stream.read(int(headers["content-length"]))
    return json.loads(body.decode("utf-8"))


class LSP:
    def __init__(self, cmd, cwd, stderr_path):
        self._stderr = open(stderr_path, "wb")
        self._proc = subprocess.Popen(
            cmd,
            cwd=cwd,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=self._stderr,
        )
        self._id = 0

    def send(self, message):
        data = json.dumps(message).encode("utf-8")
        self._proc.stdin.write(f"Content-Length: {len(data)}\r\n\r\n".encode("ascii"))
        self._proc.stdin.write(data)
        self._proc.stdin.flush()

    def request(self, method, params):
        self._id += 1
        req_id = self._id
        self.send({"jsonrpc": "2.0", "id": req_id, "method": method, "params": params})
        while True:
            message = read_message(self._proc.stdout)
            if message is None:
                raise RuntimeError("clangd exited before replying")
            if message.get("id") == req_id:
                if "error" in message:
                    raise RuntimeError(str(message["error"]))
                return message.get("result")

    def notify(self, method, params):
        self.send({"jsonrpc": "2.0", "method": method, "params": params})

    def close(self):
        try:
            self.request("shutdown", None)
        except Exception:
            pass
        try:
            self.notify("exit", None)
        except Exception:
            pass
        try:
            self._proc.terminate()
            self._proc.wait(timeout=3)
        except Exception:
            self._proc.kill()
        self._stderr.close()


def marker(path, pattern, token):
    for line_no, line in enumerate(pathlib.Path(path).read_text().splitlines()):
        if pattern in line:
            return {"line": line_no, "character": line.index(token)}
    raise RuntimeError(f"marker not found: {pattern}")


def first_loc(result):
    if not result:
        return None
    if isinstance(result, dict) and "uri" in result:
        return {
            "path": pathlib.Path(result["uri"].replace("file:///", "")).as_posix(),
            "line": result["range"]["start"]["line"] + 1,
        }
    loc = result[0]
    if "targetUri" in loc:
        return {
            "path": pathlib.Path(loc["targetUri"].replace("file:///", "")).as_posix(),
            "line": loc["targetSelectionRange"]["start"]["line"] + 1,
        }
    return {
        "path": pathlib.Path(loc["uri"].replace("file:///", "")).as_posix(),
        "line": loc["range"]["start"]["line"] + 1,
    }


results = []

for case in CASES:
    workspace = pathlib.Path(case["workspace"])
    stderr_path = workspace / f"{case['name']}.stderr.log"

    client = LSP(case["cmd"], str(workspace), str(stderr_path))
    root_uri = workspace.as_uri()
    client.request(
        "initialize",
        {
            "processId": None,
            "rootUri": root_uri,
            "capabilities": {"textDocument": {}, "workspace": {}},
            "workspaceFolders": [{"uri": root_uri, "name": workspace.name}],
            "initializationOptions": case.get("initialization_options"),
        },
    )
    client.notify("initialized", {})
    if "settings" in case:
        client.notify("workspace/didChangeConfiguration", {"settings": case["settings"]})

    for open_path in [case["open_path"], case["header_path"]]:
        text = pathlib.Path(open_path).read_text()
        client.notify(
            "textDocument/didOpen",
            {
                "textDocument": {
                    "uri": pathlib.Path(open_path).as_uri(),
                    "languageId": "cpp",
                    "version": 1,
                    "text": text,
                }
            },
        )

    time.sleep(case.get("settle_s", 4.0))

    call_pos = marker(case["open_path"], case["call_marker"], case["call_token"])
    decl_pos = marker(case["header_path"], case["decl_marker"], case["decl_token"])
    call_def = first_loc(
        client.request(
            "textDocument/definition",
            {"textDocument": {"uri": pathlib.Path(case["open_path"]).as_uri()}, "position": call_pos},
        )
    )
    decl_def = first_loc(
        client.request(
            "textDocument/definition",
            {"textDocument": {"uri": pathlib.Path(case["header_path"]).as_uri()}, "position": decl_pos},
        )
    )
    client.close()

    stderr_text = stderr_path.read_text(encoding="utf-8", errors="replace")
    background_lines = [
        line
        for line in stderr_text.splitlines()
        if "Processing file " in line or "Indexed " in line
    ]
    indexed_targets = {
        "all.cpp": any("all.cpp" in line for line in background_lines),
        "calls.cpp": any("calls.cpp" in line for line in background_lines),
        "delta.cpp": any("delta.cpp" in line for line in background_lines),
        "api.hpp": any("api.hpp" in line for line in background_lines),
    }
    results.append(
        {
            "name": case["name"],
            "call_definition": call_def,
            "decl_definition": decl_def,
            "indexed_log_lines": len(background_lines),
            "indexed_targets": indexed_targets,
            "background_lines": background_lines,
        }
    )

print(json.dumps(results))
