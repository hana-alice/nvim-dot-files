-- WORKAROUND
-- name: blink_cmp.auto_wrap_undo_preview
-- scope: blink_cmp
-- issue: upstream: blink.cmp <= v1.10.2 throws E5108 'start_col must be less than or equal to end_col' from text_edits.write_to_dot_repeat → nvim_buf_get_text when buffer's `formatoptions` contains 't' or 'c' and a completion preview pushes the line past `textwidth`, auto-wrapping it. The next select_next/select_prev calls undo_preview against the now-stale range.
-- symptom: error popup like:
--   Error executing vim.schedule lua callback:
--   .../blink/cmp/lib/text_edits.lua:360: start_col must be less than or equal to end_col
-- triggered when typing in a buffer with `setlocal fo+=t` or `fo+=c` (default for ft=cpp/c/markdown comments) past textwidth and tabbing through the menu.
-- introduced: 2026-04-27
-- removal_condition: blink.cmp ships v1.10.3+ that includes upstream commit d2fcad3 (PR #2378) "fix: disable auto-wrap during completion to prevent preview undo errors" — at that point this workaround becomes a no-op duplicate and should be deleted.
-- upstream_pr: https://github.com/Saghen/blink.cmp/pull/2378
-- owner: hana-alice
-- enabled: true
-- END WORKAROUND

-- Strategy: backport PR #2378 *behaviorally* without editing files inside
-- nvim-data/lazy/blink.cmp. We monkey-patch the menu module's `open` and
-- `close` to wrap them with disable_auto_wrap / restore_auto_wrap, mirroring
-- the upstream patch. The hooks are buffer-local via `vim.b.*` flags so
-- per-buffer state survives nested menu operations.
--
-- Why not patch text_edits.write_to_dot_repeat directly:
--   * The real bug is that the LSP TextEdit range BECAME invalid because the
--     buffer was reflowed between preview-apply and preview-undo. Clamping
--     `nvim_buf_get_text` args after the fact would make dot-repeat record
--     the wrong text. Upstream chose to prevent the reflow instead — same
--     here.
--
-- Apply contract:
--   apply()   — idempotent monkey-patch. Safe to call before blink.cmp loads
--               (defers via VeryLazy autocmd).
--   status()  — returns { applied, patched, fired_open, fired_close }.

local M = {}

local state = {
  applied      = false,
  patched      = false,
  fired_open   = 0,
  fired_close  = 0,
  install_err  = nil,
}

local FLAG_T = "blink_cmp_workaround_restore_fo_t"
local FLAG_C = "blink_cmp_workaround_restore_fo_c"

local function disable_auto_wrap()
  local fo = vim.opt_local.formatoptions:get()
  if fo.t then
    vim.b[FLAG_T] = true
    vim.opt_local.formatoptions:remove("t")
  end
  if fo.c then
    vim.b[FLAG_C] = true
    vim.opt_local.formatoptions:remove("c")
  end
end

local function restore_auto_wrap()
  local restore_t = vim.b[FLAG_T]
  local restore_c = vim.b[FLAG_C]
  if not (restore_t or restore_c) then return end

  pcall(function()
    if restore_t then
      vim.opt_local.formatoptions:append("t")
      vim.b[FLAG_T] = nil
    end
    if restore_c then
      vim.opt_local.formatoptions:append("c")
      vim.b[FLAG_C] = nil
    end
  end)
end

local function install_patch()
  if state.patched then return true end
  local ok, menu = pcall(require, "blink.cmp.completion.windows.menu")
  if not ok or type(menu) ~= "table" then
    state.install_err = "menu module not loadable: " .. tostring(menu)
    return false
  end
  if type(menu.open) ~= "function" or type(menu.close) ~= "function" then
    state.install_err = "menu.open/close missing"
    return false
  end

  local orig_open = menu.open
  local orig_close = menu.close

  menu.open = function(...)
    -- Mirror upstream PR #2378: only act when the menu is actually opening.
    -- Upstream guards with `if menu.win:is_open() then return end` first;
    -- we replicate by deferring to orig_open's own idempotent guard and
    -- pre-disabling the format options unconditionally — disable_auto_wrap
    -- itself is idempotent (only flips when the option is set).
    disable_auto_wrap()
    state.fired_open = state.fired_open + 1
    return orig_open(...)
  end

  menu.close = function(...)
    local ret = orig_close(...)
    restore_auto_wrap()
    state.fired_close = state.fired_close + 1
    return ret
  end

  state.patched = true
  return true
end

function M.apply()
  state.applied = true

  -- Try immediate patch (works once blink.cmp is loaded).
  if install_patch() then return true end

  -- Otherwise defer until blink.cmp shows up. Use a one-shot autocmd
  -- on each event we expect the plugin to have loaded by — InsertEnter
  -- is the latest, VeryLazy the earliest. Re-try on each until success.
  local grp = vim.api.nvim_create_augroup("blink_cmp_auto_wrap_workaround", { clear = true })
  for _, ev in ipairs({ "User", "InsertEnter" }) do
    vim.api.nvim_create_autocmd(ev, {
      group = grp,
      pattern = ev == "User" and "VeryLazy" or nil,
      callback = function()
        if install_patch() then
          return true -- delete this autocmd
        end
      end,
    })
  end
  return state.patched
end

function M.disable()
  -- Reverting a monkey-patch cleanly requires holding refs to the originals
  -- and restoring them; we keep them via closure above but don't expose a
  -- swap-back path. To revert: set frontmatter `enabled: false` and restart.
end

function M.status()
  return vim.deepcopy(state)
end

return M
