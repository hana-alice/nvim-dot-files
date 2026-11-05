-- ue/engine_cache.lua — every non-config artifact follows the engine.
--
-- RULE (user, 2026-11-05): apart from the Neovim configuration itself, caches,
-- state, logs and work directories live under <engine>/.cache/nvim-ue/<sub>.
-- The legacy stdpath location is used only when no engine is known (headless
-- tests, non-UE buffers). Why the engine: K76 — the system drive gets low IO
-- priority for background clangd and is space-constrained; the engine's data
-- drive is fast and is where the user cleans up project artifacts.
--
-- Deliberately NOT here (must stay outside watched live roots, see K76/C4):
--   * CDB transaction staging (lua/ue/cdb/transaction.lua) — native watcher
--     overflow under the engine turns into unknown invalidation;
--   * batch_runtime watch probes and short-lived request JSON written while a
--     frozen-input guard watches the engine/project roots.

local M = {}

local SUBDIR = { ".cache", "nvim-ue" }

local function nonempty(value)
  return type(value) == "string" and value ~= "" and value or nil
end

local function engine_of(path)
  path = nonempty(path)
  if not path then return nil end
  local ok, ue = pcall(require, "ue")
  if not ok or type(ue.engine_root_of) ~= "function" then return nil end
  local found_ok, root = pcall(ue.engine_root_of, path)
  return found_ok and nonempty(root) or nil
end

--- Engine root for cache placement: explicit, path-derived, then current buffer/cwd.
---@param opts? { engine_root?: string, path?: string, current?: boolean }
function M.engine(opts)
  opts = opts or {}
  local explicit = nonempty(opts.engine_root)
  -- A recorded engine that no longer exists (moved, fixture path) must not
  -- create a fresh tree on some drive; fall back instead.
  if explicit then return vim.fn.isdirectory(explicit) == 1 and explicit or nil end
  local from_path = engine_of(opts.path)
  if from_path then return from_path end
  if opts.current == false then return nil end
  return engine_of(vim.api.nvim_buf_get_name(0)) or engine_of(vim.fn.getcwd())
end

--- <engine>/.cache/nvim-ue[/sub], or nil when no engine is known.
function M.dir(sub, opts)
  local engine = M.engine(opts)
  if not engine then return nil end
  local root = engine:gsub("\\", "/"):gsub("/+$", "")
  local parts = { root }
  vim.list_extend(parts, SUBDIR)
  if nonempty(sub) then parts[#parts + 1] = sub end
  return table.concat(parts, "/")
end

--- Engine path for `sub`, falling back to `fallback` (a path or a thunk).
function M.dir_or(sub, fallback, opts)
  local dir = M.dir(sub, opts)
  if dir then return dir end
  if type(fallback) == "function" then return fallback() end
  return fallback
end

--- File `name` in the engine dir `sub`, else in `fallback_dir`; creates the parent.
--- Callers on hot or opt-in paths must call this lazily (no per-action mkdir, P5).
function M.file(sub, name, fallback_dir, opts)
  local dir = M.dir_or(sub, fallback_dir, opts)
  if vim.fn.isdirectory(dir) == 0 then pcall(vim.fn.mkdir, dir, "p") end
  return dir .. "/" .. name
end

return M
