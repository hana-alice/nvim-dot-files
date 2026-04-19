-- WORKAROUND
-- name: neovide.exit_with_gui
-- scope: neovide
-- issue: https://github.com/neovide/neovide/issues/796 (and family)
-- symptom: After the Neovide window is closed, the underlying nvim.exe stays alive forever as a background process — accumulating across sessions until tasklist shows multiple "ghost" nvim.exe holding onto pipes, file locks, and CPU/RAM.
-- introduced: 2026-04-19
-- removal_condition: Neovide reliably tears down its child nvim on window close (track upstream tracking issue; safe to delete this when `tasklist /FI "IMAGENAME eq nvim.exe"` is empty after closing the last Neovide window).
-- owner: hana-alice
-- enabled: true
-- END WORKAROUND

-- WHY
-- ---
-- Neovide is a Skia GUI front-end that talks to nvim via the stdio RPC
-- channel. When the user closes the Neovide window, Neovide drops its
-- end of the channel — but nvim itself keeps running, because:
--
--   1. nvim has no concept of "the only UI just left, time to exit".
--   2. Background jobs (LSP, csearch, gtags, build watchers) hold the
--      event loop open.
--   3. Any pending UI input (modal dialog, unsaved buffer prompt) blocks
--      the normal exit path.
--
-- Net effect: after a few sessions you accumulate orphan nvim.exe
-- instances visible in tasklist, each ~25-100 MB, holding named pipes
-- and file locks (especially nasty on Windows where file deletion fails
-- silently while a stale nvim has the file open).
--
-- FIX
-- ---
-- Listen for the UI's RPC channel detaching. The Neovide-spawned UI is
-- registered as an entry in nvim_list_uis(); when its `chan` disappears
-- from that list, the GUI is gone and nvim is genuinely headless again.
-- In that case, force-exit immediately (no normal exit handlers — those
-- are exactly what was getting stuck).
--
-- We only arm this when vim.g.neovide is truthy, so terminal nvim is
-- not affected (in a terminal there is no separate UI channel; the TTY
-- is the UI and detaching it would kill us anyway via SIGHUP).
--
-- The detection happens via UIEnter once we can read uis(), then we
-- record the GUI chan and watch for it to vanish on every UILeave / a
-- short-lived timer.

local M = {}

local applied = false
local AUGROUP_NAME = "workaround_neovide_exit_with_gui"
local DEBUG = false

local function log(...)
  if not DEBUG then return end
  local args = { ... }
  vim.schedule(function()
    vim.notify("[neovide.exit_with_gui] " .. table.concat(vim.tbl_map(tostring, args), " "),
               vim.log.levels.DEBUG, { title = "workaround" })
  end)
end

-- Look at nvim_list_uis() and pick the one most likely to be the GUI.
-- A Neovide UI advertises ext_multigrid / ext_messages / rgb=true and
-- has a non-zero chan. There's only ever 1 GUI per nvim, so first match
-- wins.
local function find_gui_chan()
  local uis = vim.api.nvim_list_uis()
  for _, ui in ipairs(uis) do
    if ui.chan and ui.chan ~= 0 then
      return ui.chan
    end
  end
  return nil
end

-- Hard exit. Bypasses VimLeavePre / VimLeave / shutdown hooks because
-- those are exactly the things that get stuck with running jobs.
-- Saved buffers were already saved by the user (Neovide closing implies
-- they were done editing). If they had unsaved changes, that's on them
-- to use :wq before closing the GUI.
local function hard_exit()
  log("GUI gone, hard-exiting nvim process")
  -- Stop all running jobs first to release pipe handles cleanly on Win.
  pcall(function()
    local jobs = vim.fn.getbufinfo()
    for _, job_id in ipairs(vim.fn.jobs and vim.fn.jobs() or {}) do
      pcall(vim.fn.jobstop, job_id)
    end
  end)
  -- os.exit() bypasses everything — that's the whole point.
  os.exit(0, true)
end

function M.apply()
  if applied then return end

  -- Only arm under Neovide. Skip cleanly otherwise so terminal nvim is
  -- never killed by us.
  if not vim.g.neovide then
    log("not running under neovide, skipping")
    applied = true
    return
  end

  local group = vim.api.nvim_create_augroup(AUGROUP_NAME, { clear = true })
  local watched_chan = nil

  -- Phase 1: arm only after the GUI has fully attached and we can
  -- observe its channel ID.
  vim.api.nvim_create_autocmd("UIEnter", {
    group = group,
    callback = function()
      vim.schedule(function()
        watched_chan = find_gui_chan()
        log("UI attached on chan", watched_chan)
      end)
    end,
  })

  -- Phase 2: nvim fires ChanInfo / no direct ChanDetach event, so we
  -- watch via UILeave and a short polling timer. UILeave fires when the
  -- last UI detaches; that's our exit trigger.
  vim.api.nvim_create_autocmd("UILeave", {
    group = group,
    callback = function()
      vim.schedule(function()
        local remaining = #vim.api.nvim_list_uis()
        log("UILeave; remaining UIs:", remaining)
        if remaining == 0 then
          hard_exit()
        end
      end)
    end,
  })

  -- Belt-and-suspenders: also poll every 2s. UILeave should be enough
  -- on a clean disconnect, but if Neovide crashes (Skia GPU error etc.)
  -- the channel can vanish without a clean event. Polling catches that.
  local timer = (vim.uv or vim.loop).new_timer()
  timer:start(2000, 2000, function()
    vim.schedule(function()
      if not watched_chan then
        watched_chan = find_gui_chan()
        return
      end
      local uis = vim.api.nvim_list_uis()
      if #uis == 0 then
        log("poll: no UIs left, exiting")
        hard_exit()
      end
    end)
  end)

  applied = true
end

function M.disable()
  pcall(vim.api.nvim_del_augroup_by_name, AUGROUP_NAME)
end

function M.status()
  return {
    applied = applied,
    augroup = AUGROUP_NAME,
    is_neovide = vim.g.neovide and true or false,
    ui_chan = find_gui_chan(),
    ui_count = #vim.api.nvim_list_uis(),
  }
end

return M
