-- WORKAROUND
-- name: snacks.picker_first_open_freeze
-- scope: snacks
-- issue: snacks.nvim is keys-lazy and snacks.picker is a heavy subsystem
--        (input/list/preview/matcher/sort/finder/main + 3 floating windows
--        + layout resolver + frecency cache). First keypress that opens
--        ANY picker (dashboard `f`/`p`/`g`/`r`, <leader>;, <leader>ff, ...)
--        triggers the entire load+init chain on the main loop while the
--        user stares at the dashboard, blocking ~1.3s on cold Neovide.
-- symptom: First picker open after Neovide cold-start freezes for ~1s
--          before the picker UI appears. Subsequent opens within ~5s
--          are instant (~30ms) because everything is hot in cache.
--          After ~10s of idle, the next open is mid-cold (~700ms) due to
--          Windows working-set trimming the snacks Lua bytecode pages.
-- introduced: 2026-04-19
-- removal_condition: snacks.nvim ships partial early-load for the picker
--                    subsystem, OR LazyVim flips snacks to event=VeryLazy.
-- owner: hana-alice
-- enabled: true
-- END WORKAROUND
--
-- INVESTIGATION NOTES (2026-04-19):
-- Original cold-start: ~1330ms (picker.new=119ms, schedule_gap=1210ms).
-- After this warmup:   ~786ms  (picker.new=137ms, schedule_gap=406ms,
--                                layout:show=224ms).
-- The remaining ~700ms is split across:
--   - picker.new() inner work (~140ms)  — Lua-side, can't reduce further
--   - schedule gap            (~400ms)  — Neovim screen redraw + vim.cmd
--                                          dashboard close. Below the
--                                          actionable threshold.
--   - layout:show             (~220ms)  — first floating window creation,
--                                          Neovide GPU resource alloc.
-- Hot-cache cost is ~30ms total. Acceptable.
--
-- Strategy: after VimEnter+UIEnter (so the dashboard is painted and the
-- user can SEE something), defer-load the picker subsystem. By the time
-- the user types `p`/`f`, all heavy require()s and one-shot setup work
-- are already done — the only cost left is window creation + redraw.
--
-- Apply contract:
--   apply()  — call once from setup-time (e.g. config/autocmds.lua).

local M = {}

local applied = false
local warmed = false

local function warmup()
  if warmed then return end
  warmed = true

  -- 1. Force lazy-load snacks.nvim plugin (no-op if already loaded)
  local ok_lazy, lazy = pcall(require, "lazy")
  if ok_lazy then
    pcall(lazy.load, { plugins = { "snacks.nvim" } })
  end

  -- 2. Pre-require the heavy picker submodules. snacks.picker.init.lua
  --    uses lazy require-on-access metatables, so just touching the
  --    field doesn't load anything — we have to require() explicitly.
  local modules = {
    "snacks.picker",
    "snacks.picker.config",
    "snacks.picker.config.defaults",
    "snacks.picker.config.layouts",
    "snacks.picker.config.sources",
    "snacks.picker.core.picker",
    "snacks.picker.core.main",
    "snacks.picker.core.input",
    "snacks.picker.core.list",
    "snacks.picker.core.preview",
    "snacks.picker.core.matcher",
    "snacks.picker.core.finder",
    "snacks.picker.core.actions",
    "snacks.picker.core.filter",
    "snacks.picker.core.frecency",
    "snacks.picker.format",
    "snacks.picker.sort",
    "snacks.picker.preview",
    "snacks.picker.actions",
    "snacks.picker.util",
    "snacks.picker.util.history",
    "snacks.layout",
  }
  for _, mod in ipairs(modules) do
    pcall(require, mod)
  end
end

function M.apply()
  applied = true
  -- Schedule warmup after the dashboard is fully painted. UIEnter fires
  -- once Neovide has the editor grid; +200ms gives the dashboard time to
  -- finish its own render before we steal main-loop time.
  local group = vim.api.nvim_create_augroup("SnacksPickerWarmup", { clear = true })
  vim.api.nvim_create_autocmd("UIEnter", {
    group = group,
    once = true,
    callback = function()
      vim.defer_fn(warmup, 200)
    end,
  })
  -- Fallback for non-Neovide / TUI cases where UIEnter timing differs:
  -- also hook VimEnter as a safety net.
  vim.api.nvim_create_autocmd("VimEnter", {
    group = group,
    once = true,
    callback = function()
      vim.defer_fn(warmup, 500)
    end,
  })
end

function M.status()
  return { applied = applied, warmed = warmed }
end

return M
