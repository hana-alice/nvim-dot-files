-- utils.async_launcher — non-blocking launcher for any heavy command
-- (git, UE prepare, GTAGS index, build, etc.).
--
-- Problem this solves
-- -------------------
-- Many actions in this config involve work that takes 100ms–30s:
-- lazy-loading plugins, spawning external processes (git/cl/UBT/cindex),
-- compiling treesitter parsers, walking a 1M-file repo. Running any of
-- this on the main thread freezes the editor for the duration.
--
-- The user rule for this config is **"any modification must not block
-- the UI"**. This util enforces that rule the same way for every
-- subsystem so behaviour is consistent.
--
-- Contract this util implements
-- -----------------------------
-- 1. **Placeholder window first.** `launch()` opens a small floating
--    window IMMEDIATELY with the action's name and a spinner. The
--    user sees something on screen within one frame.
-- 2. **Right-bottom progress.** A fidget.progress.handle is created
--    on the same tick, so the progress message lives in the standard
--    notification corner alongside LSP progress.
-- 3. **Real work runs async.** The actual function/command is
--    dispatched via `vim.schedule` + `vim.defer_fn(0)` so the
--    placeholder has a chance to composite before any heavy work
--    starts. Two deferrals matter — one is not enough on Neovide.
-- 4. **Self-clean.** Once the action returns (or its picker takes
--    focus), the placeholder closes and the progress handle is
--    marked done.
-- 5. **Cooperative progress.** `run` receives a `report` callback as
--    its only argument. Calling `report("phase 2/5 ...")` updates
--    both the placeholder body and the fidget message — no extra
--    `vim.notify` floats clutter the screen.
--
-- The launcher does NOT make the underlying work fast — that's
-- impossible. It only guarantees the editor never appears frozen,
-- and that all heavy commands look/feel the same.
--
-- Public API
-- ----------
--   async_launcher.launch(opts) where opts =
--     {
--       name        = string,             -- shown in placeholder + progress
--       run         = fun(report)→any?    -- the real work
--                                         -- gets a `report(msg)` callback
--       hold_ms     = number?,            -- min placeholder visible time (250)
--       on_done     = function()?,        -- called after run() returns
--       group       = string?,            -- displayed prefix ("git" / "ue" / ...)
--                                         --   default: first word of name
--     }
--
--   async_launcher.cmd(name, ex_cmd, opts?)
--     → function() that launches "<cmd>ex_cmd<cr>" with a placeholder.
--
--   async_launcher.prompt_cmd(name, prompt, default, fmt, opts?)
--     → function() that synchronously prompts (ESCable) then launches
--       the formatted ex command.
--
-- Usage
-- -----
--   { "<leader>gM", function()
--       require("utils.async_launcher").launch({
--         name = "Diffview: branch history",
--         run  = function(report)
--           report("loading diffview...")
--           vim.cmd("DiffviewFileHistory")
--         end,
--       })
--     end },
--
--   vim.api.nvim_create_user_command("UEPrepare", function()
--     require("utils.async_launcher").launch({
--       name = "UE: Prepare (rsp + ccjson + index)",
--       group = "ue",
--       run  = function() prepare_async() end,
--     })
--   end, {})

local M = {}

local api = vim.api
local uv  = vim.uv or vim.loop

-- Spinner frames (matches fidget's default braille set).
local SPINNER = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local FRAME_MS = 80

-- Track active launches so a rapid second press doesn't stack
-- placeholder windows. Keyed by name.
local active = {}

local function close_window(state)
  if state.closed then return end
  state.closed = true

  if state.timer then
    state.timer:stop()
    state.timer:close()
    state.timer = nil
  end

  if state.win and api.nvim_win_is_valid(state.win) then
    pcall(api.nvim_win_close, state.win, true)
  end
  if state.buf and api.nvim_buf_is_valid(state.buf) then
    pcall(api.nvim_buf_delete, state.buf, { force = true })
  end

  if state.handle then
    pcall(function() state.handle:finish() end)
  end

  active[state.name] = nil
end

local function open_placeholder(state)
  local group = state.group or "task"
  local title = "  " .. group .. " · " .. state.name .. "  "
  local hint  = "running in background — press q to dismiss"
  local width = math.max(#title, #hint, #state.name + 8) + 2

  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].buftype   = "nofile"
  vim.bo[buf].swapfile  = false
  vim.bo[buf].filetype  = "async_launcher_placeholder"

  -- 4 lines: spinner+name, optional sub-progress, blank, hint
  api.nvim_buf_set_lines(buf, 0, -1, false, {
    " ⠋ " .. state.name,
    "   ",
    "",
    " " .. hint,
  })

  local lines = vim.o.lines
  local cols  = vim.o.columns
  local height = 4
  local row = math.floor((lines - height) / 2 - 2)
  local col = math.floor((cols  - width)  / 2)

  local win = api.nvim_open_win(buf, false, {
    relative = "editor",
    row      = row,
    col      = col,
    width    = width,
    height   = height,
    style    = "minimal",
    border   = "rounded",
    focusable = false,
    noautocmd = true,
    zindex   = 60,
  })

  if api.nvim_win_is_valid(win) then
    vim.wo[win].winhl = "Normal:NormalFloat,FloatBorder:DiagnosticInfo"
    vim.wo[win].cursorline = false
  end

  -- q dismisses the placeholder early. The underlying job is NOT
  -- cancelled — this only hides the indicator.
  vim.keymap.set("n", "q", function()
    if active[state.name] then close_window(active[state.name]) end
  end, { buffer = buf, nowait = true, silent = true })

  return buf, win
end

local function start_spinner(state)
  state.frame = 1
  state.timer = uv.new_timer()
  state.timer:start(FRAME_MS, FRAME_MS, vim.schedule_wrap(function()
    if state.closed or not state.buf or not api.nvim_buf_is_valid(state.buf) then
      if state.timer then
        state.timer:stop(); state.timer:close(); state.timer = nil
      end
      return
    end
    state.frame = state.frame % #SPINNER + 1
    local line = " " .. SPINNER[state.frame] .. " " .. state.name
    pcall(api.nvim_buf_set_lines, state.buf, 0, 1, false, { line })
  end))
end

local function start_progress(state)
  -- fidget progress handle (right-bottom corner). Falls back to a
  -- single vim.notify if fidget isn't loaded yet.
  local ok, progress = pcall(require, "fidget.progress")
  if ok then
    return progress.handle.create({
      title       = state.group or "task",
      message     = state.name,
      lsp_client  = { name = state.group or "task" },
      percentage  = nil,    -- spinner mode (no determinate %)
      cancellable = false,
    })
  end
  vim.notify(
    (state.group or "task") .. ": " .. state.name .. " ...",
    vim.log.levels.INFO,
    { title = state.group or "task" })
  return nil
end

-- The `report` callback handed to run(). Updates both the placeholder
-- sub-line and the fidget handle message. Fast-event safe (uses
-- vim.schedule for buffer mutation).
local function make_reporter(state)
  return function(msg)
    if state.closed then return end
    msg = tostring(msg or "")
    state.last_msg = msg

    if state.handle then
      pcall(function() state.handle:report({ message = msg }) end)
    end

    vim.schedule(function()
      if state.closed then return end
      if state.buf and api.nvim_buf_is_valid(state.buf) then
        local sub = "   " .. msg
        pcall(api.nvim_buf_set_lines, state.buf, 1, 2, false, { sub })
      end
    end)
  end
end

local function infer_group(name)
  return name:match("^%s*(%S+)") or "task"
end

---@param opts table
---  { name=string, run=function(report?), hold_ms?=number,
---    on_done?=function, group?=string }
function M.launch(opts)
  assert(opts and opts.name and opts.run,
    "async_launcher.launch: name + run required")
  local name = opts.name

  if active[name] then
    -- De-dupe: same launch already in flight, do nothing.
    return
  end

  local state = {
    name    = name,
    group   = opts.group or infer_group(name):gsub(":$", ""),
    started = uv.hrtime(),
    closed  = false,
  }
  active[name] = state

  -- Step 1 (synchronous, this tick): open placeholder + progress.
  --   Critical — must not block. No require() of heavy modules here.
  local pl_ok, buf, win = pcall(open_placeholder, state)
  if pl_ok then
    state.buf = buf
    state.win = win
    start_spinner(state)
  end
  state.handle = start_progress(state)

  local report = make_reporter(state)

  -- Step 2 (next tick): yield to event loop, THEN run the real work.
  -- Two deferrals: vim.schedule alone isn't enough on Neovide to
  -- guarantee the placeholder has composited before heavy work starts.
  vim.schedule(function()
    vim.defer_fn(function()
      local run_ok, err = pcall(opts.run, report)
      if not run_ok then
        vim.notify("async_launcher: " .. tostring(err),
          vim.log.levels.ERROR, { title = state.group })
      end

      -- Honour minimum visible time so the user can read the title
      -- even if the command returns instantly.
      local elapsed_ms = (uv.hrtime() - state.started) / 1e6
      local hold = opts.hold_ms or 250
      local remaining = math.max(0, hold - elapsed_ms)

      vim.defer_fn(function()
        close_window(state)
        if opts.on_done then pcall(opts.on_done) end
      end, remaining)
    end, 0)
  end)
end

---Convenience wrapper for "<cmd>SomeCommand<cr>" style maps.
---@param name string
---@param ex_cmd string  -- e.g. "DiffviewOpen"
---@param opts table?    -- forwarded to launch (group, hold_ms, on_done)
function M.cmd(name, ex_cmd, opts)
  return function()
    local merged = vim.tbl_extend("keep", opts or {}, {
      name = name,
      run  = function() vim.cmd(ex_cmd) end,
    })
    M.launch(merged)
  end
end

---Convenience wrapper that prompts for input first (synchronous,
---ESCable), then dispatches the rest async with the placeholder.
---@param name string
---@param prompt string
---@param default string
---@param fmt fun(input: string): string  -- builds the ex command
---@param opts table?
function M.prompt_cmd(name, prompt, default, fmt, opts)
  return function()
    local input = vim.fn.input(prompt, default or "")
    if input == nil or input == "" then return end
    local merged = vim.tbl_extend("keep", opts or {}, {
      name = name .. " (" .. input .. ")",
      run  = function() vim.cmd(fmt(input)) end,
    })
    M.launch(merged)
  end
end

---Whether a launch with this name is currently in flight.
---@param name string
function M.is_active(name)
  return active[name] ~= nil
end

return M
