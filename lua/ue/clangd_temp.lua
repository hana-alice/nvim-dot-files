-- ue/clangd_temp.lua — per-session TEMP for clangd so its preamble files never pile up.
--
-- WHY (measured 2026-10-26): clangd writes disk preambles as %TEMP%\preamble-*.pch
-- and deletes them on didClose or a graceful exit, but NOT when the process is
-- killed (Neovim quit, crash, test teardown). %TEMP% had accumulated 1404 such
-- files (1.09 GB) since 2026-08. A file can be deleted while clangd still maps
-- it, so stale files may only be swept when their owner session is provably dead.
--
-- RULE: each Neovim gives its clangd TEMP=<root>/clangd-tmp/<nvim pid>. On
-- startup, directories whose pid is no longer alive are removed. Unknown
-- liveness keeps the directory (never delete what might be in use).
--
-- WHERE (K76, 2026-11): background-priority clangd threads also get low IO
-- priority on Windows; on the system drive a shard write measured 7-10 ms vs
-- ~1 ms on the engine's data drive. So <root> follows the engine
-- (<engine>/.cache/nvim-ue) and falls back to stdpath("state") only without one.

local M = {}

local function legacy_root()
  return vim.fs.joinpath(vim.fn.stdpath("state"), "clangd-tmp")
end

function M.root(deps)
  deps = deps or {}
  if deps.cache then return vim.fs.joinpath(deps.cache, "clangd-tmp") end
  if deps.engine_root and deps.engine_root ~= "" then
    return vim.fs.joinpath(deps.engine_root, ".cache", "nvim-ue", "clangd-tmp")
  end
  return legacy_root()
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
  local root = deps.root or M.root(deps)
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

local swept = {}
local function sweep_once(root, deps)
  if swept[root] then return end
  swept[root] = true
  pcall(M.sweep, vim.tbl_extend("force", deps or {}, { root = root }))
end

--- Merge the session TEMP into a spawn environment (never mutates `env`).
--- deps.engine_root places TEMP under the engine cache (K76).
function M.spawn_env(env, deps)
  sweep_once(M.root(deps), deps)
  -- Sessions from before the engine-cache move still own stdpath dirs.
  if not (deps and deps.cache) then sweep_once(legacy_root(), deps) end
  local ok, overrides = pcall(M.environment, deps)
  if not ok or not overrides then return env end
  return vim.tbl_extend("force", env or {}, overrides)
end

function M._reset_for_test() swept = {} end

return M
