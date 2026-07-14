-- utils/stall_probe.lua — main-loop stall detector (diagnostic probe).
--
-- WHY: user reports intermittent "卡卡的" UI hitches that are hard to
-- reproduce on demand. This probe turns them into hard evidence: a 100ms
-- uv timer measures its own scheduling drift; when a tick arrives late by
-- more than `threshold_ms`, the main loop was blocked for that long
-- (synchronous Lua/VimL, clipboard provider, blocking spawn, GC, ...).
--
-- WHAT IT RECORDS per stall (ring buffer + utils.log scope "stall", WARN):
--   * stall duration (ms over the expected tick)
--   * wall-clock timestamp
--   * mode / buffer name / filetype at the moment the loop unblocked
--   * the last few keys pressed with their age relative to the stall end
--     (via vim.on_key) — this is what ties a stall to `y`/`p`/`gd`/etc.
--
-- WHAT IT CANNOT SEE: client-side (Neovide) render lag. If the UI stutters
-- but :StallReport shows nothing at that time, the block is in the GUI
-- process, not in nvim — that distinction is exactly why this probe exists.
--
-- Design constraints honored:
--   * P6 (never block UI): the timer callback is fast-event safe — only
--     uv.hrtime arithmetic; context capture goes through vim.schedule.
--   * P5 (no periodic ticker notifications): the probe never notifies on
--     its own. Evidence goes to the ring buffer + rotating log only.
--   * Headless-testable: pure decision fn `M._over_threshold` + record API
--     exposed for specs; no timer needed to test the logic.
--
-- Public API:
--   M.setup(opts?)   -- start probe + install :StallProbe / :StallReport
--   M.stop()         -- stop timer, remove on_key hook (records retained)
--   M.status()       -- { enabled, interval_ms, threshold_ms, count }
--   M.get_stalls()   -- copy of the ring buffer (oldest -> newest)
--   M.clear()        -- drop recorded stalls

local uv = vim.uv or vim.loop

local M = {}

local DEFAULTS = {
  interval_ms = 100, -- tick cadence
  threshold_ms = 150, -- lateness beyond the interval that counts as a stall
  max_records = 200, -- ring buffer cap
  max_keys = 10, -- how many recent keys to remember
}

local state = {
  enabled = false,
  opts = vim.deepcopy(DEFAULTS),
  timer = nil,
  last_tick = nil, -- uv.hrtime() of previous tick
  stalls = {}, -- ring buffer of records (oldest first)
  keys = {}, -- ring of { key = "<translated>", t = hrtime }
  on_key_ns = nil,
}

-- ---------------------------------------------------------------------------
-- Pure helpers (headless-testable)
-- ---------------------------------------------------------------------------

--- Decide whether a tick gap constitutes a stall.
--- @param gap_ms number actual time between ticks
--- @param interval_ms number expected tick interval
--- @param threshold_ms number tolerated lateness
--- @return number|nil over_ms lateness beyond the interval, nil if not a stall
function M._over_threshold(gap_ms, interval_ms, threshold_ms)
  local over = gap_ms - interval_ms
  if over >= threshold_ms then
    return over
  end
  return nil
end

--- Append a record to a ring buffer, dropping the oldest past `cap`.
--- Returns the same table for convenience (mutates in place by design:
--- this is an internal ring buffer, not shared state).
local function ring_push(ring, item, cap)
  ring[#ring + 1] = item
  while #ring > cap do
    table.remove(ring, 1)
  end
  return ring
end

-- Exposed for specs.
M._ring_push = ring_push

-- ---------------------------------------------------------------------------
-- Key trail (last few pressed keys, for correlating stall -> action)
-- ---------------------------------------------------------------------------

local function record_key(key)
  local ok, trans = pcall(vim.fn.keytrans, key)
  if not ok or not trans or trans == "" then
    return
  end
  -- Mouse-move spam would flush real keys out of the tiny ring.
  if trans:find("MouseMove", 1, true) then
    return
  end
  ring_push(state.keys, { key = trans, t = uv.hrtime() }, state.opts.max_keys)
end

local function keys_snapshot(now_hrtime)
  local parts = {}
  for _, k in ipairs(state.keys) do
    local age_s = (now_hrtime - k.t) / 1e9
    parts[#parts + 1] = string.format("%s(%.1fs)", k.key, age_s)
  end
  return table.concat(parts, " ")
end

-- ---------------------------------------------------------------------------
-- Stall capture
-- ---------------------------------------------------------------------------

--- Build + store a stall record. Runs on the main loop (scheduled).
--- Exposed for specs (which call it directly without a timer).
function M._capture_stall(over_ms)
  local now = uv.hrtime()
  local bufnr = vim.api.nvim_get_current_buf()
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name ~= "" then
    name = vim.fn.fnamemodify(name, ":t")
  end
  local record = {
    time = os.date("%Y-%m-%d %H:%M:%S"),
    over_ms = math.floor(over_ms + 0.5),
    mode = vim.api.nvim_get_mode().mode,
    buf = name ~= "" and name or ("[" .. (vim.bo[bufnr].buftype ~= "" and vim.bo[bufnr].buftype or "noname") .. "]"),
    ft = vim.bo[bufnr].filetype,
    keys = keys_snapshot(now),
  }
  ring_push(state.stalls, record, state.opts.max_records)
  require("utils.log").warn_ctx("stall", "main-loop stall", {
    over_ms = record.over_ms,
    mode = record.mode,
    buf = record.buf,
    ft = record.ft,
    keys = record.keys,
  })
  return record
end

local function on_tick()
  -- FAST EVENT CONTEXT: uv.hrtime + arithmetic + vim.schedule only.
  local now = uv.hrtime()
  local prev = state.last_tick
  state.last_tick = now
  if not prev then
    return
  end
  local gap_ms = (now - prev) / 1e6
  local over = M._over_threshold(gap_ms, state.opts.interval_ms, state.opts.threshold_ms)
  if over then
    vim.schedule(function()
      -- Probe may have been stopped between detection and capture.
      if state.enabled then
        M._capture_stall(over)
      end
    end)
  end
end

-- ---------------------------------------------------------------------------
-- Report rendering
-- ---------------------------------------------------------------------------

local function report_lines()
  local lines = {
    "Stall probe report — main-loop blocks > "
      .. state.opts.threshold_ms
      .. "ms (interval "
      .. state.opts.interval_ms
      .. "ms)",
    "NOTE: if the UI stuttered but nothing is listed at that time, the lag",
    "      was client-side (Neovide render), not the nvim main loop.",
    "",
  }
  if #state.stalls == 0 then
    lines[#lines + 1] = "(no stalls recorded this session)"
    return lines
  end
  lines[#lines + 1] = string.format("%-19s  %8s  %-4s  %-28s  %-10s  recent keys(age at stall end)", "when", "blocked", "mode", "buffer", "filetype")
  for i = #state.stalls, 1, -1 do
    local r = state.stalls[i]
    lines[#lines + 1] = string.format(
      "%-19s  %6dms  %-4s  %-28s  %-10s  %s",
      r.time,
      r.over_ms,
      r.mode,
      r.buf:sub(1, 28),
      (r.ft or ""):sub(1, 10),
      r.keys
    )
  end
  return lines
end

local function open_report()
  local lines = report_lines()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = "stallreport"
  vim.cmd("botright split")
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  vim.api.nvim_win_set_height(win, math.min(#lines + 1, 16))
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.keymap.set("n", "q", "<cmd>close<cr>", { buffer = buf, nowait = true, silent = true })
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

function M.stop()
  if state.timer then
    state.timer:stop()
    state.timer:close()
    state.timer = nil
  end
  if state.on_key_ns then
    -- Passing nil removes the callback for this namespace.
    pcall(vim.on_key, nil, state.on_key_ns)
    state.on_key_ns = nil
  end
  state.enabled = false
  state.last_tick = nil
end

local function start()
  if state.timer then
    return
  end
  state.timer = uv.new_timer()
  state.last_tick = nil
  state.timer:start(state.opts.interval_ms, state.opts.interval_ms, on_tick)
  state.on_key_ns = state.on_key_ns or vim.api.nvim_create_namespace("ue_stall_probe")
  vim.on_key(record_key, state.on_key_ns)
  state.enabled = true
end

function M.status()
  return {
    enabled = state.enabled,
    interval_ms = state.opts.interval_ms,
    threshold_ms = state.opts.threshold_ms,
    count = #state.stalls,
  }
end

function M.get_stalls()
  return vim.deepcopy(state.stalls)
end

function M.clear()
  state.stalls = {}
end

local function install_commands()
  vim.api.nvim_create_user_command("StallReport", open_report, {
    desc = "Show recorded main-loop stalls (newest first)",
    force = true,
  })
  vim.api.nvim_create_user_command("StallProbe", function(args)
    local action = (args.args or ""):lower()
    if action == "on" then
      start()
      vim.notify("stall probe: on", vim.log.levels.INFO)
    elseif action == "off" then
      M.stop()
      vim.notify("stall probe: off", vim.log.levels.INFO)
    elseif action == "clear" then
      M.clear()
      vim.notify("stall probe: records cleared", vim.log.levels.INFO)
    else
      local s = M.status()
      vim.notify(
        string.format(
          "stall probe: %s | threshold=%dms interval=%dms | %d stall(s) recorded (:StallReport)",
          s.enabled and "on" or "off",
          s.threshold_ms,
          s.interval_ms,
          s.count
        ),
        vim.log.levels.INFO
      )
    end
  end, {
    nargs = "?",
    complete = function()
      return { "on", "off", "status", "clear" }
    end,
    desc = "Stall probe control: on|off|status|clear",
    force = true,
  })
end

function M.setup(opts)
  state.opts = vim.tbl_extend("force", vim.deepcopy(DEFAULTS), opts or {})
  install_commands()
  start()
  return M
end

return M
