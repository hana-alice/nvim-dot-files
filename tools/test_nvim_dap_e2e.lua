-- End-to-end test: attach, test pause, test breakpoint
vim.wait(10000, function()
  return pcall(require, "dap") and pcall(require, "ue")
end, 200)

local ue = require("ue")
ue.setup()
local dap = require("dap")

local symbol_path = vim.env.NVIM_UE_SYMBOL_PATH
  or [[D:\UE\ProjectRoot\Intermediate\Android\arm64\jni\arm64-v8a\libUE4.so]]
local android_package = vim.env.NVIM_UE_ANDROID_PACKAGE or "com.example.game"

local log = {}
local function logmsg(msg)
  table.insert(log, os.date("%H:%M:%S") .. " " .. msg)
  io.write(msg .. "\n")
  io.flush()
end

local got_initialized = false
local got_stopped = false
local got_continued = false

dap.listeners.after.event_initialized["e2e"] = function()
  got_initialized = true
  logmsg("EVENT: initialized")
end
dap.listeners.after.event_stopped["e2e"] = function(_, body)
  got_stopped = true
  logmsg("EVENT: stopped reason=" .. (body and body.reason or "?"))
end
dap.listeners.after.event_continued["e2e"] = function()
  got_continued = true
  logmsg("EVENT: continued")
end
dap.listeners.after.event_terminated["e2e"] = function()
  logmsg("EVENT: terminated")
end

-- Non-interactive inputs
local answers = {
  ["Path to libUE4.so"] = symbol_path,
  ["Path to symbol .so"] = symbol_path,
  ["Android package name"] = android_package,
}
vim.fn.input = function(prompt, default)
  for prefix, answer in pairs(answers) do
    if prompt:find(prefix, 1, true) then
      logmsg("INPUT: " .. prompt:sub(1, 40) .. " -> " .. answer:sub(1, 40))
      return answer
    end
  end
  return default or ""
end

vim.notify = function(msg, level)
  logmsg("NOTIFY[" .. (level or 0) .. "]: " .. tostring(msg))
end

-- Phase 1: Attach
logmsg("=== Phase 1: Attach ===")
vim.cmd("UEAndroidDAPAttach")
local ok = vim.wait(90000, function() return got_initialized end, 1000)
if not ok then
  logmsg("FAIL: No initialized event")
  vim.cmd("qall!")
  return
end
-- Wait for auto-continue
vim.wait(15000, function() return got_continued end, 500)
logmsg("initialized=" .. tostring(got_initialized) .. " continued=" .. tostring(got_continued))

-- Phase 2: Test pause (F6)
logmsg("=== Phase 2: Pause (F6) ===")
got_stopped = false
ue.dap_pause()
local pause_ok = vim.wait(10000, function() return got_stopped end, 500)
logmsg("pause result: stopped=" .. tostring(got_stopped))

-- Phase 3: Test breakpoint (F9) while paused
if got_stopped then
  logmsg("=== Phase 3: Breakpoint (F9) while paused ===")
  -- Create a temp buffer with a fake C++ file to set a breakpoint on
  vim.cmd("edit " .. vim.fn.stdpath("config"):gsub("\\", "/") .. "/tools/test_bp_target.cpp")
  vim.api.nvim_buf_set_lines(0, 0, -1, false, {
    "#include <stdio.h>",
    "void test_func() {",
    "  printf(\"hello\");",
    "}",
  })
  vim.api.nvim_win_set_cursor(0, { 3, 0 })  -- line 3
  ue.dap_toggle_breakpoint()
  vim.wait(5000, function() return false end, 500)
  logmsg("breakpoint specs count: " .. vim.tbl_count(ue._breakpoint_specs))

  -- Also test setting BP via LLDB on a real function
  logmsg("=== Phase 3b: LLDB HW BP on known symbol ===")
  ue._dap_eval_lldb('breakpoint set -H -n "FEngineLoop::Tick"', function(ok2, result)
    vim.schedule(function()
      logmsg("LLDB BP result: ok=" .. tostring(ok2) .. " result=" .. tostring(result):sub(1, 100))
    end)
  end)
  vim.wait(5000, function() return false end, 500)

  -- Continue after pause
  logmsg("=== Phase 4: Continue (F5) ===")
  got_continued = false
  ue.dap_continue()
  vim.wait(5000, function() return got_continued end, 500)
  logmsg("continue result: continued=" .. tostring(got_continued))
else
  logmsg("SKIP: Could not pause, skipping BP and continue tests")

  -- Try breakpoint while running (no pause needed for LLDB eval)
  logmsg("=== Phase 3-alt: LLDB eval while running ===")
  ue._dap_eval_lldb('breakpoint set -H -n "FEngineLoop::Tick"', function(ok2, result)
    vim.schedule(function()
      logmsg("LLDB BP (running): ok=" .. tostring(ok2) .. " result=" .. tostring(result):sub(1, 100))
    end)
  end)
  vim.wait(5000, function() return false end, 500)
end

-- Phase 5: Check session alive
logmsg("=== Phase 5: Session check ===")
if dap.session() then
  logmsg("PASS: Session still alive")
else
  logmsg("FAIL: Session died")
end

-- Disconnect
logmsg("Disconnecting...")
if dap.session() then
  dap.disconnect({ terminateDebuggee = false })
  vim.wait(5000, function() return dap.session() == nil end, 500)
end
logmsg("Done")

local f = io.open(vim.fn.stdpath("config") .. "/tools/test_nvim_dap_e2e.result.txt", "w")
if f then f:write(table.concat(log, "\n") .. "\n"); f:close() end
vim.cmd("qall!")
