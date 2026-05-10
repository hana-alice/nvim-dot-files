"""ctx — resolve index-context for a path.

We piggy-back on the user's nvim config: `lua/ue.lua` already exposes
`csearch_ctx(bufnr)` and `clangd_root(bufnr)` and knows where the per-engine
csearch / gtags / clangd indexes live. Re-implementing that path discovery in
Python would drift out of sync. So we ask nvim itself.

Two paths:
  1. live-nvim:    cheap RPC into the user's running instance (~50ms)
  2. headless:     spawn `nvim --headless` with the user's config (~1-3s)

Result is cached for the lifetime of one CLI invocation.
"""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from typing import Dict, Optional


_NVIM = shutil.which("nvim") or r"C:\Program Files\Neovim\bin\nvim.exe"
_CACHE: Dict[str, Dict] = {}


def resolve(path: str, want: str = "all") -> Optional[Dict]:
    """Return ctx dict: {workspace_root, csearch_idx, gtags_db, clangd_root}.

    Falls back gracefully — keys are absent (not None) if the underlying
    discovery couldn't fill them. Returns {} (truthy=False) only when nvim
    itself is unreachable.
    """
    key = os.path.abspath(path)
    if key in _CACHE:
        return _CACHE[key]

    ctx = _via_live(key) or _via_headless(key) or {}
    _CACHE[key] = ctx
    return ctx


# ---------- live nvim ----------

def _list_pipes() -> list:
    if os.name != "nt":
        return []
    try:
        cp = subprocess.run(
            ["powershell.exe", "-NoProfile", "-Command",
             "[System.IO.Directory]::EnumerateFiles('\\\\.\\pipe\\') "
             "| Where-Object { $_ -match 'nvim\\.\\d+\\.0$' }"],
            capture_output=True, text=True, timeout=8)
    except Exception:
        return []
    out = []
    for raw in (cp.stdout or "").splitlines():
        m = re.search(r"nvim\.(\d+)\.0$", raw.strip())
        if m:
            out.append(f"//./pipe/nvim.{m.group(1)}.0")
    return out


_LUA_CTX = r"""
local target = TARGET_PATH
local ok_ue, ue = pcall(require, "ue")
if not ok_ue then
  return { error = "require('ue') failed: " .. tostring(ue) }
end

-- Open a scratch buffer pointing at target so csearch_ctx/clangd_root can
-- resolve the project from the file path (they take a bufnr and read its
-- name).
local bufnr = vim.fn.bufadd(target)
vim.fn.bufload(bufnr)

local out = {}
local ok1, c = pcall(ue.csearch_ctx, bufnr)
if ok1 and c then
  out.workspace_root = c.workspace_root
  out.csearch_idx    = c.csearch_idx
end
local ok2, croot = pcall(ue.clangd_root, bufnr)
if ok2 and croot then
  out.clangd_root = croot
end

-- Try to surface gtags DB path. ue.lua keeps it inside resolve_context().ctx.paths
-- but does not expose a public getter. Reach in via a small adaptor if possible.
local ok3, ctx = pcall(function()
  return rawget(_G, "_ue_resolve_context_for_external_use") and
         _G._ue_resolve_context_for_external_use({ bufname = vim.api.nvim_buf_get_name(bufnr) })
end)
if ok3 and ctx and ctx.paths and ctx.paths.workspace_db then
  out.gtags_db = ctx.paths.workspace_db
end

-- Fallback: probe conventional gtags DB locations.
if not out.gtags_db and out.workspace_root then
  local probes = {
    out.workspace_root,
    out.workspace_root .. "/.cache/nvim-ue/gtags",
    vim.fn.stdpath("cache") .. "/ue/gtags/" .. vim.fn.sha256(out.workspace_root):sub(1, 16),
  }
  for _, p in ipairs(probes) do
    if vim.fn.filereadable(p .. "/GTAGS") == 1 then
      out.gtags_db = p
      break
    end
  end
end

return out
"""


def _run_lua_get(target: str, runner) -> Optional[Dict]:
    out_path = os.path.join(tempfile.gettempdir(),
                            f"code_query_ctx_{os.getpid()}.json")
    if os.path.exists(out_path):
        try: os.unlink(out_path)
        except OSError: pass

    target_lua = _lua_str(target.replace("\\", "/"))
    body = _LUA_CTX.replace("TARGET_PATH", target_lua)
    wrapped = (
        "local _ok, _res = pcall(function()\n"
        + body + "\n"
        "end)\n"
        "local _payload = vim.json.encode(_ok and _res or { error = tostring(_res) })\n"
        f"local _f = io.open({_lua_str(out_path)}, 'w')\n"
        "if _f then _f:write(_payload); _f:close() end\n"
    )
    lua_file = os.path.join(tempfile.gettempdir(),
                            f"code_query_ctx_{os.getpid()}.lua")
    with open(lua_file, "w", encoding="utf-8") as f:
        f.write(wrapped)

    try:
        ok = runner(lua_file, out_path)
    finally:
        try: os.unlink(lua_file)
        except OSError: pass

    if not ok or not os.path.exists(out_path):
        return None
    try:
        with open(out_path, "r", encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError):
        return None
    finally:
        try: os.unlink(out_path)
        except OSError: pass

    if not isinstance(data, dict):
        return None
    if data.get("error"):
        sys.stderr.write(f"[ctx] {data['error']}\n")
        return None
    return data


def _via_live(target: str) -> Optional[Dict]:
    pipes = _list_pipes()
    for pipe in pipes:
        def runner(lua_file, out_path, _pipe=pipe):
            cmd = [_NVIM, "--server", _pipe, "--remote-send",
                   "<C-\\><C-N>:luafile " + lua_file.replace("\\", "/") + "<CR>"]
            cp = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
            if cp.returncode != 0:
                return False
            import time
            deadline = time.time() + 5
            while time.time() < deadline:
                if os.path.exists(out_path) and os.path.getsize(out_path) > 0:
                    return True
                time.sleep(0.05)
            return False

        res = _run_lua_get(target, runner)
        if res:
            return res
    return None


def _via_headless(target: str) -> Optional[Dict]:
    def runner(lua_file, _out_path):
        cmd = [_NVIM, "--headless",
               "--cmd", "lua vim.g.started_with_stdin = true",
               "-c", "luafile " + lua_file.replace("\\", "/"),
               "-c", "qa!"]
        try:
            cp = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
        except subprocess.TimeoutExpired:
            return False
        return cp.returncode == 0

    return _run_lua_get(target, runner)


def _lua_str(s: str) -> str:
    for level in ("", "=", "==", "==="):
        open_b, close_b = "[" + level + "[", "]" + level + "]"
        if close_b not in s:
            return open_b + s + close_b
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'
