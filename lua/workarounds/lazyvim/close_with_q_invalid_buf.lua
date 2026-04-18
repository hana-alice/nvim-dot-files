-- WORKAROUND
-- name: lazyvim.close_with_q_invalid_buf
-- scope: lazyvim
-- issue: internal: LazyVim/lua/lazyvim/config/autocmds.lua close_with_q autocmd schedules vim.keymap.set without re-checking buffer validity → "Invalid buffer id: N" when transient FileType buffers (notify popups, lspinfo flashes, picker preview tabs) are wiped between FileType firing and the scheduled callback running.
-- symptom: Errors like "Error executing vim.schedule lua callback: vim/keymap.lua:77: Invalid buffer id: 209" pop up while navigating snacks/noice picker candidates or when notify bubbles vanish quickly.
-- introduced: 2026-04-18
-- removal_condition: LazyVim ships a buffer-validity guard in config/autocmds.lua close_with_q (https://github.com/LazyVim/LazyVim) — track upstream and delete this when fixed.
-- owner: hana-alice
-- enabled: true
-- END WORKAROUND

-- WHY
-- ---
-- Upstream callback (LazyVim/lua/lazyvim/config/autocmds.lua):
--   callback = function(event)
--     vim.bo[event.buf].buflisted = false
--     vim.schedule(function()
--       vim.keymap.set("n", "q", ..., { buffer = event.buf, ... })
--     end)
--   end
--
-- Between FileType firing and vim.schedule running, the buffer can already
-- be wiped (e.g. snacks/noice preview swap, notify autohide). nvim_buf_set_keymap
-- then throws "Invalid buffer id: N" with a noisy stacktrace, but does no real
-- harm — the buffer is gone, the keymap was never needed.
--
-- FIX
-- ---
-- Replace the autocmd's callback with a wrapped version that re-checks
-- nvim_buf_is_valid() inside vim.schedule, and silently no-ops if invalid.
-- We re-create the autocmd in the SAME augroup ("lazyvim_close_with_q")
-- so LazyVim's clear-on-reload semantics still work.
--
-- Why not just pcall? pcall would still be noisy via vim.schedule's error
-- reporting unless we set the entire callback to noref. A targeted validity
-- check is the actual semantic fix and matches what upstream should do.

local M = {}

local applied = false
local AUGROUP_NAME = "lazyvim_close_with_q"

local PATTERNS = {
  "PlenaryTestPopup",
  "checkhealth",
  "dap-float",
  "dbout",
  "gitsigns-blame",
  "grug-far",
  "help",
  "lspinfo",
  "neotest-output",
  "neotest-output-panel",
  "neotest-summary",
  "notify",
  "qf",
  "spectre_panel",
  "startuptime",
  "tsplayground",
}

local function safe_callback(event)
  -- Mirrors upstream behavior, but guarded.
  if not vim.api.nvim_buf_is_valid(event.buf) then
    return
  end
  vim.bo[event.buf].buflisted = false
  vim.schedule(function()
    if not vim.api.nvim_buf_is_valid(event.buf) then
      return -- buffer gone before schedule fired — nothing to map
    end
    vim.keymap.set("n", "q", function()
      vim.cmd("close")
      pcall(vim.api.nvim_buf_delete, event.buf, { force = true })
    end, {
      buffer = event.buf,
      silent = true,
      desc = "Quit buffer",
    })
  end)
end

function M.apply()
  if applied then
    return
  end
  -- LazyVim creates its FileType autocmd on VeryLazy via its own augroup.
  -- We must run AFTER that so our nvim_create_augroup({ clear = true })
  -- nukes theirs and replaces with the guarded version.
  vim.api.nvim_create_autocmd("User", {
    pattern = "VeryLazy",
    once = true,
    callback = function()
      -- Clear LazyVim's augroup of the same name and re-register our guarded autocmd.
      local group = vim.api.nvim_create_augroup(AUGROUP_NAME, { clear = true })
      vim.api.nvim_create_autocmd("FileType", {
        group = group,
        pattern = PATTERNS,
        callback = safe_callback,
      })
      applied = true
    end,
  })
end

function M.disable()
  -- Restoring upstream's unguarded callback is not meaningful (it's the bug).
  -- To truly disable, set enabled=false in frontmatter and restart.
  pcall(vim.api.nvim_del_augroup_by_name, AUGROUP_NAME)
end

function M.status()
  return { applied = applied, augroup = AUGROUP_NAME, patterns = #PATTERNS }
end

return M
