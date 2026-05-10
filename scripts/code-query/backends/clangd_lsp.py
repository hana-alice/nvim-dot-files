"""clangd-via-headless-nvim backend.

Strategy: a headless `nvim` instance attaches via msgpack-RPC to whatever
nvim instance the user is currently running (Neovide GUI or terminal nvim),
finds an active clangd LSP client whose root contains FILE, and asks for
textDocument/definition or references at FILE:LINE:COL. The user's clangd
already has the file open and the index is warm — answers come back in tens
of milliseconds.

If no live nvim instance is reachable, we degrade by spawning a one-shot
headless nvim that loads the user's config, opens FILE, waits for clangd to
attach (slow: 5-30s on UE), then issues the request. This is correctness-
preserving but slow — surfaced via stderr so the agent knows.
"""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from typing import List, Dict, Optional


_NVIM = shutil.which("nvim") or r"C:\Program Files\Neovim\bin\nvim.exe"


def lookup(*, file: str, line: int, col: int = 1, kind: str = "def",
           workspace_root: str, timeout: int = 30) -> List[Dict]:
    if kind not in ("def", "ref"):
        raise ValueError(f"kind must be def|ref, got {kind!r}")
    if not os.path.exists(file):
        raise RuntimeError(f"file not found: {file}")

    # Try live nvim first.
    pipes = _list_nvim_pipes()
    for pipe in pipes:
        try:
            res = _query_via_live_nvim(pipe, file, line, col, kind, timeout)
            if res is not None:
                return _to_matches(res, workspace_root, backend=f"clangd-live-{kind}")
        except Exception as e:
            sys.stderr.write(f"[clangd] live nvim {pipe} failed: {e}\n")
            continue

    # Fallback: spawn a one-shot headless nvim with user's config.
    sys.stderr.write("[clangd] no live nvim reachable; spawning headless (slow)\n")
    res = _query_via_headless(file, line, col, kind, timeout)
    return _to_matches(res, workspace_root, backend=f"clangd-headless-{kind}")


# ---------- live nvim path ----------

def _list_nvim_pipes() -> List[str]:
    r"""Enumerate `\\.\pipe\nvim.PID.0` named pipes via PowerShell. Returns pipe
    names in the //./pipe/<name> form which is bash-safe."""
    if not sys.platform.startswith("win") and not os.name == "nt":
        # Linux WSL: nvim TUI on the linux side uses XDG_RUNTIME_DIR socket.
        # Out of scope for now — return empty, fall through to headless.
        return []
    try:
        cp = subprocess.run(
            ["powershell.exe", "-NoProfile", "-Command",
             "[System.IO.Directory]::EnumerateFiles('\\\\.\\pipe\\') "
             "| Where-Object { $_ -match 'nvim\\.\\d+\\.0$' }"],
            capture_output=True, text=True, timeout=8)
    except Exception:
        return []
    pipes = []
    for raw in (cp.stdout or "").splitlines():
        raw = raw.strip()
        if not raw:
            continue
        # e.g. \\.\pipe\nvim.21324.0  → //./pipe/nvim.21324.0
        m = re.search(r"nvim\.(\d+)\.0$", raw)
        if not m:
            continue
        pipes.append(f"//./pipe/nvim.{m.group(1)}.0")
    return pipes


_LIVE_LUA_TEMPLATE = r"""
local file = vim.fn.fnamemodify({FILE_LIT}, ":p")
local line = {LINE} - 1   -- 0-indexed for LSP
local col  = {COL} - 1
local kind = {KIND_LIT}   -- "def" | "ref"

-- Find a clangd client whose root contains `file`.
local clients = vim.lsp.get_clients and vim.lsp.get_clients({ name = "clangd" })
              or vim.lsp.get_active_clients({ name = "clangd" })
if not clients or #clients == 0 then
  return { error = "no clangd client" }
end
local function path_under(p, root)
  if not root then return false end
  p = p:gsub("\\", "/"):lower(); root = root:gsub("\\", "/"):lower()
  return p:sub(1, #root) == root
end
local client
for _, c in ipairs(clients) do
  if path_under(file, c.config and c.config.root_dir) then client = c; break end
end
client = client or clients[1]

-- Make sure the buffer is loaded and attached.
local bufnr = vim.fn.bufadd(file)
vim.fn.bufload(bufnr)
if not vim.lsp.buf_is_attached(bufnr, client.id) then
  pcall(vim.lsp.buf_attach_client, bufnr, client.id)
end

local method = (kind == "ref")
  and "textDocument/references"
  or  "textDocument/definition"
local params = {
  textDocument = { uri = vim.uri_from_fname(file) },
  position     = { line = line, character = col },
}
if method == "textDocument/references" then
  params.context = { includeDeclaration = true }
end

local ok, result = pcall(function()
  return vim.lsp.buf_request_sync(bufnr, method, params, {TIMEOUT_MS})
end)
if not ok then return { error = "buf_request_sync threw: " .. tostring(result) } end
if not result then return { error = "buf_request_sync returned nil" } end

local out = {}
for _, r in pairs(result) do
  if r.error then table.insert(out, { error = vim.inspect(r.error) }) end
  local items = r.result
  if items then
    if items.uri then items = { items } end   -- single Location
    for _, loc in ipairs(items) do
      local uri = loc.uri or loc.targetUri
      local rng = loc.range or loc.targetSelectionRange or loc.targetRange
      if uri and rng then
        table.insert(out, {
          path = vim.uri_to_fname(uri),
          line = rng.start.line + 1,
          col  = rng.start.character + 1,
        })
      end
    end
  end
end
return out
"""


def _query_via_live_nvim(pipe: str, file: str, line: int, col: int,
                         kind: str, timeout: int) -> Optional[List[Dict]]:
    """Run a Lua snippet on a live nvim via --remote-expr+luaeval. Returns the
    list of locations, or None to indicate "this pipe couldn't help, try next"."""
    lua = (_LIVE_LUA_TEMPLATE
           .replace("{FILE_LIT}", _lua_str(file.replace("\\", "/")))
           .replace("{LINE}", str(line))
           .replace("{COL}", str(col))
           .replace("{KIND_LIT}", _lua_str(kind))
           .replace("{TIMEOUT_MS}", str(timeout * 1000)))

    # Write Lua to a temp file and trigger via :luafile + result-to-file dance.
    # We avoid --remote-expr luaeval(...) escaping hell entirely.
    out_path = os.path.join(tempfile.gettempdir(),
                            f"code_query_clangd_{os.getpid()}.json")
    if os.path.exists(out_path):
        try: os.unlink(out_path)
        except OSError: pass

    wrapped = (
        "local _ok, _res = pcall(function()\n"
        + lua + "\n"
        "end)\n"
        f"local _payload = vim.json.encode(_ok and _res or {{ error = tostring(_res) }})\n"
        f"local _f = io.open({_lua_str(out_path)}, 'w')\n"
        "if _f then _f:write(_payload); _f:close() end\n"
    )
    lua_file = os.path.join(tempfile.gettempdir(),
                            f"code_query_clangd_{os.getpid()}.lua")
    with open(lua_file, "w", encoding="utf-8") as f:
        f.write(wrapped)

    # Use --remote-send with luafile (asynchronous, no return-value escaping
    # nightmare). Drop a Normal-mode prefix in case the user is in insert.
    cmd = [_NVIM, "--server", pipe, "--remote-send",
           "<C-\\><C-N>:luafile " + lua_file.replace("\\", "/") + "<CR>"]
    cp = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    if cp.returncode != 0:
        return None  # pipe dead

    # Wait briefly for the lua to write the result file.
    import time
    deadline = time.time() + max(timeout, 5)
    while time.time() < deadline:
        if os.path.exists(out_path) and os.path.getsize(out_path) > 0:
            break
        time.sleep(0.05)
    if not os.path.exists(out_path):
        return None

    try:
        with open(out_path, "r", encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError):
        return None
    finally:
        try: os.unlink(out_path)
        except OSError: pass
        try: os.unlink(lua_file)
        except OSError: pass

    if isinstance(data, dict) and data.get("error"):
        sys.stderr.write(f"[clangd] live nvim error: {data['error']}\n")
        # `no clangd client` → try next pipe
        if "no clangd client" in str(data["error"]):
            return None
        return []
    if isinstance(data, list):
        # Filter out per-server errors that bubbled up.
        return [d for d in data if isinstance(d, dict) and d.get("path")]
    return []


def _query_via_headless(file: str, line: int, col: int, kind: str,
                        timeout: int) -> List[Dict]:
    """Spawn a one-shot headless nvim. Slow path."""
    out_path = os.path.join(tempfile.gettempdir(),
                            f"code_query_clangd_hl_{os.getpid()}.json")
    if os.path.exists(out_path):
        try: os.unlink(out_path)
        except OSError: pass

    lua = (_LIVE_LUA_TEMPLATE
           .replace("{FILE_LIT}", _lua_str(file.replace("\\", "/")))
           .replace("{LINE}", str(line))
           .replace("{COL}", str(col))
           .replace("{KIND_LIT}", _lua_str(kind))
           .replace("{TIMEOUT_MS}", str(timeout * 1000)))
    file_fwd = file.replace("\\", "/")
    timeout_ms = timeout * 1000
    wrapped = (
        "vim.g.started_with_stdin = true\n"
        "vim.cmd('edit ' .. " + _lua_str(file_fwd) + ")\n"
        "local ok = vim.wait(" + str(timeout_ms) + ", function()\n"
        "  local cs = (vim.lsp.get_clients and vim.lsp.get_clients({ name = 'clangd' }))\n"
        "         or vim.lsp.get_active_clients({ name = 'clangd' })\n"
        "  return cs and #cs > 0\n"
        "end, 100)\n"
        "if not ok then\n"
        "  local f = io.open(" + _lua_str(out_path) + ", 'w')\n"
        "  if f then f:write('{\"error\":\"clangd never attached\"}'); f:close() end\n"
        "  vim.cmd('qa!')\n"
        "end\n"
        "local res = (function()\n"
        + lua + "\n"
        "end)()\n"
        "local f = io.open(" + _lua_str(out_path) + ", 'w')\n"
        "if f then f:write(vim.json.encode(res)); f:close() end\n"
        "vim.cmd('qa!')\n"
    )
    lua_file = os.path.join(tempfile.gettempdir(),
                            f"code_query_clangd_hl_{os.getpid()}.lua")
    with open(lua_file, "w", encoding="utf-8") as f:
        f.write(wrapped)

    cmd = [_NVIM, "--headless",
           "--cmd", "lua vim.g.started_with_stdin = true",
           "-c", "luafile " + lua_file.replace("\\", "/"),
           "-c", "qa!"]
    try:
        subprocess.run(cmd, capture_output=True, text=True,
                       timeout=timeout + 30)
    except subprocess.TimeoutExpired:
        sys.stderr.write("[clangd] headless nvim timed out\n")

    if not os.path.exists(out_path):
        return []
    try:
        with open(out_path, "r", encoding="utf-8") as f:
            data = json.load(f)
    finally:
        try: os.unlink(out_path)
        except OSError: pass
        try: os.unlink(lua_file)
        except OSError: pass
    if isinstance(data, dict) and data.get("error"):
        sys.stderr.write(f"[clangd] headless error: {data['error']}\n")
        return []
    return data if isinstance(data, list) else []


def _to_matches(items: List[Dict], workspace_root: str, backend: str) -> List[Dict]:
    out = []
    seen = set()
    wr = (workspace_root or "").replace("\\", "/").rstrip("/")
    for it in items or []:
        if not isinstance(it, dict) or not it.get("path"):
            continue
        p = it["path"].replace("\\", "/")
        if wr and p.lower().startswith(wr.lower() + "/"):
            p = p[len(wr) + 1:]
        line = int(it.get("line", 1))
        col = int(it.get("col", 1))
        key = (p.lower(), line, col)
        if key in seen:
            continue
        seen.add(key)
        out.append({
            "path": p,
            "line": line,
            "col": col,
            "backend": backend,
        })
    return out


def _lua_str(s: str) -> str:
    # Use long-bracket to avoid escaping headaches with backslashes/quotes.
    # Pick a level that's not present in the string.
    for level in ("", "=", "==", "==="):
        open_b = "[" + level + "["
        close_b = "]" + level + "]"
        if close_b not in s:
            return open_b + s + close_b
    # Fallback to quoted string with conservative escaping.
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'
