-- tools/stall_attribute.lua — attribute main-loop stalls to their CAUSE.
--
-- WHY: `tools/stall_profile.lua` (jit.profile sampling) proved insufficient on
-- its own: LuaJIT's sampler keeps firing while the loop is IDLE and attributes
-- those samples to the last Lua stack that ran, so an idle session reports
-- ~60% in `vim.schedule_wrap` and the real blocker is buried. jit.profile
-- answers "which Lua ran a lot", not "who held the loop during THIS 250ms gap".
--
-- WHAT THIS DOES INSTEAD: arm a high-resolution stall detector that, on
-- detecting a gap, samples the *live* process facts that can explain a block
-- the Lua profiler cannot see (C-level work, spawns, fs syscalls, GC):
--
--   * gcbytes / gc step count      -> GC pause suspicion
--   * uv handle census by type     -> timer/process/fs_event pile-up
--   * active jobs + channel count  -> spawn storms (K40/K42 family)
--   * lsp client request backlog   -> clangd request pressure
--   * autocmd-per-event totals     -> per-keystroke handler pile-up
--
-- THE DECISIVE DISCRIMINATOR: rusage CPU time consumed DURING the gap.
--   * cpu_ms ~= gap_ms  -> THIS process burned the wall time: an in-process
--                          block (synchronous Lua/C, GC, blocking spawn).
--                          Fixable inside this repository.
--   * cpu_ms ~= 0       -> the process was DESCHEDULED: the machine was
--                          oversubscribed (clangd workers, UBT build, another
--                          Neovim). No Lua callback is at fault; the fix is
--                          resource budgeting, not code motion.
-- Without this ratio every "who stalled us" investigation is guesswork, which
-- is exactly how K40/K42 cost multiple mis-diagnosed rounds.
--
-- Written for attaching to a RUNNING instance over --server, so evidence comes
-- from the real session that stutters, not a synthetic headless one.
--
-- USAGE:
--   nvim --headless --server //./pipe/nvim.<PID>.0 --remote-expr \
--     "luaeval('dofile(_A)', '<config>/tools/stall_attribute.lua')"
--   -> appends to <stdpath('state')>/stall_attribute.<pid>.txt
--
-- Diagnostic only; nothing here is armed by default (P5/P6).

local uv = vim.uv or vim.loop

local DURATION_MS = tonumber(vim.env.UE_STALL_ATTR_MS or "") or 20000
local TICK_MS = 50
local THRESHOLD_MS = 120

local out_path = ("%s/stall_attribute.%d.txt"):format(vim.fn.stdpath("state"), vim.fn.getpid())
local records = {}
local baseline = nil

-- Census of libuv handles by type: a growing `timer` or `process` count across
-- stalls is direct evidence of handle pile-up rather than one slow callback.
local function handle_census()
  local by_type = {}
  local ok = pcall(function()
    uv.walk(function(handle)
      local ok_type, t = pcall(function()
        return handle:get_type()
      end)
      t = (ok_type and t) or "unknown"
      local active = false
      local ok_active, a = pcall(function()
        return handle:is_active()
      end)
      if ok_active then
        active = a and true or false
      end
      local key = t .. (active and "" or "(idle)")
      by_type[key] = (by_type[key] or 0) + 1
    end)
  end)
  if not ok then
    return { walk = "failed" }
  end
  return by_type
end

local function autocmd_census()
  local by_event = {}
  local ok, cmds = pcall(vim.api.nvim_get_autocmds, {})
  if not ok then
    return by_event
  end
  for _, c in ipairs(cmds) do
    local e = c.event or "?"
    by_event[e] = (by_event[e] or 0) + 1
  end
  return by_event
end

local function lsp_census()
  local rows = {}
  local ok, clients = pcall(function()
    return vim.lsp.get_clients()
  end)
  if not ok then
    return rows
  end
  for _, c in ipairs(clients) do
    local pending = 0
    for _ in pairs(c.requests or {}) do
      pending = pending + 1
    end
    rows[#rows + 1] = ("%s(pending=%d,bufs=%d)"):format(c.name, pending, vim.tbl_count(c.attached_buffers or {}))
  end
  return rows
end

-- Total CPU (user+sys) this process has consumed, in ms.
local function cpu_ms()
  local ok, ru = pcall(uv.getrusage)
  if not ok or type(ru) ~= "table" then
    return nil
  end
  local function to_ms(t)
    if type(t) ~= "table" then
      return 0
    end
    return (t.sec or 0) * 1000 + (t.usec or 0) / 1000
  end
  return to_ms(ru.utime) + to_ms(ru.stime)
end

local function snapshot()
  return {
    gc_kb = math.floor(collectgarbage("count")),
    handles = handle_census(),
    lsp = lsp_census(),
    chans = #vim.api.nvim_list_chans(),
    bufs = #vim.api.nvim_list_bufs(),
    wins = #vim.api.nvim_list_wins(),
  }
end

local function fmt_tbl(t)
  local keys = {}
  for k in pairs(t) do
    keys[#keys + 1] = tostring(k)
  end
  table.sort(keys)
  local parts = {}
  for _, k in ipairs(keys) do
    parts[#parts + 1] = k .. "=" .. tostring(t[k])
  end
  return table.concat(parts, " ")
end

local last_tick = nil
local last_cpu = nil
local timer = uv.new_timer()
local stop_timer = uv.new_timer()

timer:start(TICK_MS, TICK_MS, function()
  local now = uv.hrtime()
  local now_cpu = cpu_ms()
  local prev, prev_cpu = last_tick, last_cpu
  last_tick, last_cpu = now, now_cpu
  if not prev then
    return
  end
  local gap_ms = (now - prev) / 1e6
  local over = gap_ms - TICK_MS
  if over < THRESHOLD_MS then
    return
  end
  -- Attribute the gap BEFORE scheduling: cpu delta must cover the gap itself,
  -- not the gap plus however long our own callback waited to run.
  local burned = (now_cpu and prev_cpu) and (now_cpu - prev_cpu) or nil
  vim.schedule(function()
    local snap = snapshot()
    records[#records + 1] = {
      over_ms = math.floor(over + 0.5),
      gap_ms = math.floor(gap_ms + 0.5),
      cpu_ms = burned and math.floor(burned + 0.5) or nil,
      at = os.date("%H:%M:%S"),
      mode = vim.api.nvim_get_mode().mode,
      snap = snap,
    }
  end)
end)

stop_timer:start(DURATION_MS, 0, function()
  timer:stop()
  timer:close()
  stop_timer:stop()
  stop_timer:close()
  vim.schedule(function()
    local lines = {
      ("=== stall_attribute %s pid=%d window=%dms stalls=%d ==="):format(
        os.date("%Y-%m-%dT%H:%M:%S"),
        vim.fn.getpid(),
        DURATION_MS,
        #records
      ),
    }
    if baseline then
      lines[#lines + 1] = "baseline: gc_kb=" .. baseline.gc_kb .. " chans=" .. baseline.chans
      lines[#lines + 1] = "baseline handles: " .. fmt_tbl(baseline.handles)
      lines[#lines + 1] = "baseline autocmds(top): " .. fmt_tbl(baseline.autocmds or {})
      lines[#lines + 1] = "baseline lsp: " .. table.concat(baseline.lsp, " ")
    end
    for _, r in ipairs(records) do
      -- verdict: share of the gap this process actually spent on-CPU.
      local verdict = "cpu=?"
      if r.cpu_ms then
        local share = r.cpu_ms / math.max(r.gap_ms, 1)
        verdict = ("cpu=%dms/%dms(%.0f%%) %s"):format(
          r.cpu_ms,
          r.gap_ms,
          share * 100,
          share >= 0.6 and "IN-PROCESS-BLOCK" or (share <= 0.2 and "DESCHEDULED(host oversubscribed)" or "MIXED")
        )
      end
      lines[#lines + 1] = ("[%s] blocked=%dms mode=%s %s gc_kb=%d chans=%d bufs=%d wins=%d"):format(
        r.at,
        r.over_ms,
        r.mode,
        verdict,
        r.snap.gc_kb,
        r.snap.chans,
        r.snap.bufs,
        r.snap.wins
      )
      lines[#lines + 1] = "    handles: " .. fmt_tbl(r.snap.handles)
      lines[#lines + 1] = "    lsp: " .. table.concat(r.snap.lsp, " ")
    end
    local f = io.open(out_path, "a")
    if f then
      f:write(table.concat(lines, "\n") .. "\n\n")
      f:close()
    end
  end)
end)

baseline = snapshot()
baseline.autocmds = autocmd_census()

return ("attributing stalls for %dms -> %s"):format(DURATION_MS, out_path)
