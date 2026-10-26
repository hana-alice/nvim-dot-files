-- ue/clangd_temp.lua — per-session TEMP for clangd so its preamble files never pile up.
--
-- WHY (measured 2026-10-26): clangd writes disk preambles as %TEMP%\preamble-*.pch
-- and deletes them on didClose or a graceful exit, but NOT when the process is
-- killed (Neovim quit, crash, test teardown). %TEMP% had accumulated 1404 such
-- files (1.09 GB) since 2026-08. A file can be deleted while clangd still maps
-- it, so stale files may only be swept when their owner session is provably dead.
--
-- RULE: each Neovim gives its clangd TEMP=stdpath("state")/clangd-tmp/<nvim pid>. On
-- startup, directories whose pid is no longer alive are removed. Unknown
-- liveness keeps the directory (never delete what might be in use).

local M = {}

function M.root(deps)
  deps = deps or {}
  return vim.fs.joinpath(deps.cache or vim.fn.stdpath("state"), "clangd-tmp")
end

--- TEMP/TMP overrides for this session's clangd; creates the directory.
function M.environment(deps)
  deps = deps or {}
  local dir = vim.fs.joinpath(M.root(deps), tostring(deps.pid or vim.fn.getpid()))
  if vim.fn.isdirectory(dir) == 0 and vim.fn.mkdir(dir, "p") == 0 then return nil end
  return { TEMP = dir, TMP = dir, TMPDIR = dir }
end

--- Remove directories of dead sessions. Returns the number removed.
function M.sweep(deps)
  deps = deps or {}
  local root = M.root(deps)
  local self_pid = tostring(deps.pid or vim.fn.getpid())
  local exists = deps.process_exists or function(pid)
    local driver = require("utils.platform").driver()
    if type(driver.process_exists) ~= "function" then return nil end
    local ok, alive = pcall(driver.process_exists, pid)
    if not ok then return nil end
    return alive
  end
  local removed = 0
  for name, kind in vim.fs.dir(root) do
    if kind == "directory" and name:match("^%d+$") and name ~= self_pid and exists(tonumber(name)) == false then
      if vim.fn.delete(vim.fs.joinpath(root, name), "rf") == 0 then removed = removed + 1 end
    end
  end
  return removed
end

local swept = false
--- Merge the session TEMP into a spawn environment (never mutates `env`).
function M.spawn_env(env, deps)
  if not swept then
    swept = true
    pcall(M.sweep, deps)
  end
  local ok, overrides = pcall(M.environment, deps)
  if not ok or not overrides then return env end
  return vim.tbl_extend("force", env or {}, overrides)
end

function M._reset_for_test() swept = false end

return M
