-- Full E2E test: attach, hit BP at VulkanShaders.cpp:60, continue, monitor
-- cd <PROJ_DRIVE>\uetemp
-- nvim --headless -u $LOCALAPPDATA\nvim\init.lua +"luafile $LOCALAPPDATA/nvim/tools/test_e2e_full.lua"

local function p(...)
  local args = { ... }
  for i, v in ipairs(args) do args[i] = tostring(v) end
  io.write(table.concat(args, "\t") .. "\n")
  io.flush()
end

vim.notify = function(msg, level, opts)
  p(("[L%s] %s"):format(level or "?", msg))
end
vim.fn.input = function(prompt, default)
  return default or ""
end

p("=== Full E2E Test ===")

require("lazy").load({ plugins = { "nvim-dap", "nvim-dap-ui", "nvim-nio" } })
local dap = require("dap")
local M = require("ue")
local dapui_ok, dapui = pcall(require, "dapui")
if dapui_ok then
  dapui.open = function() end
  dapui.close = function() end
end

local stop_events = {}
local continued_events = {}

-- Log ALL dap events
dap.listeners.after.event_stopped["test"] = function(session, body)
  body = body or {}
  local entry = {
    reason = body.reason or "?",
    desc = body.description or "",
    thread = body.threadId,
    bps = body.hitBreakpointIds,
    all_stopped = body.allThreadsStopped,
    ts = vim.uv.hrtime(),
  }
  table.insert(stop_events, entry)
  p(("STOP #%d: reason=%s desc=%s thread=%s bp=%s allStopped=%s"):format(
    #stop_events, entry.reason, entry.desc, tostring(entry.thread),
    entry.bps and table.concat(vim.tbl_map(tostring, entry.bps), ",") or "none",
    tostring(entry.all_stopped)))
end

dap.listeners.after.event_continued["test"] = function(session, body)
  body = body or {}
  table.insert(continued_events, {
    thread = body.threadId,
    all = body.allThreadsContinued,
    ts = vim.uv.hrtime(),
  })
  p(("CONTINUED: thread=%s all=%s"):format(
    tostring(body.threadId), tostring(body.allThreadsContinued)))
end

dap.listeners.after.event_output["test"] = function(_, body)
  if body and body.output and body.category == "console" then
    local out = body.output:gsub("%s+$", "")
    if out ~= "" and #out < 300 then
      p("LLDB:", out)
    end
  end
end

dap.listeners.after.event_terminated["test"] = function()
  p("EVENT: terminated")
end
dap.listeners.after.event_exited["test"] = function()
  p("EVENT: exited")
end
dap.listeners.after.disconnect["test"] = function()
  p("EVENT: disconnect")
end

-- After READY, wait for breakpoint hit, then test continue
local ready_seen = false
local orig_notify = vim.notify
vim.notify = function(msg, level, opts)
  orig_notify(msg, level, opts)
  if not ready_seen and tostring(msg):find("READY") then
    ready_seen = true
    p("=== READY detected, waiting for breakpoint hit ===")
    -- Wait up to 15s for a breakpoint hit
    local check_count = 0
    local function check_bp()
      check_count = check_count + 1
      for _, ev in ipairs(stop_events) do
        if ev.bps and #ev.bps > 0 then
          p("=== BP hit detected, continuing in 1s ===")
          vim.defer_fn(function()
            p("=== Calling M.dap_continue() ===")
            p("  _dap_run_state before:", M._dap_run_state)
            p("  stopped_thread_id:", tostring(dap.session() and dap.session().stopped_thread_id or "nil"))
            M.dap_continue()
            -- Wait 10s, report state, exit
            vim.defer_fn(function()
              p("=== Post-continue state (10s later) ===")
              p("  stop_events total:", #stop_events)
              p("  continued_events total:", #continued_events)
              p("  _dap_run_state:", M._dap_run_state)
              local sess = dap.session()
              p("  session alive:", sess and "yes" or "no")
              if sess then
                p("  stopped_thread_id:", tostring(sess.stopped_thread_id or "nil"))
              end
              for i, ev in ipairs(stop_events) do
                p(("  stop[%d]: reason=%s thread=%s bp=%s"):format(
                  i, ev.reason, tostring(ev.thread),
                  ev.bps and table.concat(vim.tbl_map(tostring, ev.bps), ",") or "none"))
              end
              vim.cmd("qall!")
            end, 10000)
          end, 1000)
          return
        end
      end
      if check_count < 30 then
        vim.defer_fn(check_bp, 500)
      else
        p("=== No breakpoint hit after 15s, dumping state ===")
        p("  stop_events:", #stop_events)
        for i, ev in ipairs(stop_events) do
          p(("  stop[%d]: reason=%s thread=%s"):format(i, ev.reason, tostring(ev.thread)))
        end
        vim.cmd("qall!")
      end
    end
    vim.defer_fn(check_bp, 500)
  end
end

vim.defer_fn(function()
  p("=== GLOBAL TIMEOUT 90s ===")
  p("stop_events:", #stop_events)
  p("ready_seen:", tostring(ready_seen))
  vim.cmd("qall!")
end, 90000)

p("Triggering attach...")
vim.cmd("UEDAPAttach android")
