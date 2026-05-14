-- lua/ue/dap/_progress.lua
--
-- Tiny single-line progress popup for DAP attach/launch flows.
--
-- Design goals:
--   * One floating window, single line, anchored bottom-right.
--   * Updates in place — no notification spam stacking on screen.
--   * Auto-shows on first step(); auto-hides on done()/error()/timeout.
--   * Survives reload (cleans previous instance).
--   * Zero dependencies (no fidget / nvim-notify required).
--
-- Usage:
--   local P = require("ue.dap._progress")
--   P.step("1/6 picking device …")
--   P.step("2/6 pushing lldb-server …")
--   ...
--   P.done("attached pid=24386 base=0x7594c2a000")  -- success, auto-hide 2s
--   P.error("lldb-server push failed")              -- red, auto-hide 5s
--
-- The popup never steals focus and never blocks. Safe to call from
-- vim.schedule / async handlers.

local M = {}

local NS_NAME = "ue_dap_progress"
local ns = vim.api.nvim_create_namespace(NS_NAME)

local state = {
  buf = nil,
  win = nil,
  timer = nil,
  width = 60,
}

local function cleanup_timer()
  if state.timer then
    pcall(function() state.timer:stop() end)
    pcall(function() state.timer:close() end)
    state.timer = nil
  end
end

local function close_win()
  cleanup_timer()
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    pcall(vim.api.nvim_win_close, state.win, true)
  end
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    pcall(vim.api.nvim_buf_delete, state.buf, { force = true })
  end
  state.win = nil
  state.buf = nil
end

local function ensure_win()
  if state.buf and vim.api.nvim_buf_is_valid(state.buf)
     and state.win and vim.api.nvim_win_is_valid(state.win) then
    return
  end
  close_win()
  state.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[state.buf].buftype = "nofile"
  vim.bo[state.buf].bufhidden = "wipe"
  vim.bo[state.buf].swapfile = false
  vim.api.nvim_buf_set_name(state.buf, "[ue-dap progress]")

  local width = state.width
  local row = vim.o.lines - 4   -- above status/cmdline
  local col = vim.o.columns - width - 2
  if col < 0 then col = 0 end

  state.win = vim.api.nvim_open_win(state.buf, false, {
    relative  = "editor",
    width     = width,
    height    = 1,
    row       = row,
    col       = col,
    style     = "minimal",
    border    = "rounded",
    focusable = false,
    zindex    = 200,
    noautocmd = true,
  })
  -- visual: dim border, normal text
  pcall(vim.api.nvim_set_option_value, "winhighlight",
    "Normal:Normal,FloatBorder:Comment", { win = state.win })
  pcall(vim.api.nvim_set_option_value, "winblend", 10, { win = state.win })
end

local function set_line(text, hl_group)
  ensure_win()
  -- truncate to width-2 (leave 1px breathing room)
  if #text > state.width - 2 then
    text = text:sub(1, state.width - 5) .. "..."
  end
  pcall(vim.api.nvim_buf_set_lines, state.buf, 0, -1, false, { " " .. text })
  pcall(vim.api.nvim_buf_clear_namespace, state.buf, ns, 0, -1)
  if hl_group then
    pcall(vim.api.nvim_buf_set_extmark, state.buf, ns, 0, 0, {
      end_col   = #text + 1,
      hl_group  = hl_group,
    })
  end
end

local function arm_autoclose(ms)
  cleanup_timer()
  state.timer = vim.uv.new_timer()
  if not state.timer then return end
  state.timer:start(ms, 0, vim.schedule_wrap(function()
    close_win()
  end))
end

--- Update the progress line. Auto-shows the popup on first call.
function M.step(text)
  set_line(tostring(text), "DiagnosticInfo")
  cleanup_timer()  -- step keeps the popup alive
end

--- Mark success. Popup turns green and auto-hides after 2s.
function M.done(text)
  set_line("✓ " .. tostring(text or "done"), "DiagnosticOk")
  arm_autoclose(2000)
end

--- Mark error. Popup turns red and auto-hides after 5s.
function M.error(text)
  set_line("✗ " .. tostring(text or "error"), "DiagnosticError")
  arm_autoclose(5000)
end

--- Force-close the popup immediately.
function M.hide()
  close_win()
end

--- For tests: returns a snapshot of the current popup state.
function M._inspect()
  return {
    buf = state.buf,
    win = state.win,
    visible = (state.win and vim.api.nvim_win_is_valid(state.win)) or false,
    text = (state.buf and vim.api.nvim_buf_is_valid(state.buf))
      and (vim.api.nvim_buf_get_lines(state.buf, 0, -1, false)[1] or "") or "",
  }
end

return M
