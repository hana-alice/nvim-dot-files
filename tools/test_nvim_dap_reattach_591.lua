-- End-to-end reattach regression test for UE Android DAP.
-- Flow:
-- 1. Attach to Android process.
-- 2. Set F9 at VulkanCommandBuffer.cpp:591 and wait for a hit.
-- 3. Disconnect.
-- 4. Re-attach, set F9 again at the same line, and wait for a hit again.
-- Run:
--   nvim --headless -i NONE -c "luafile tools/test_nvim_dap_reattach_591.lua"

vim.wait(10000, function()
  return pcall(require, "dap") and pcall(require, "ue")
end, 200)

local ue = require("ue")
ue.setup()
local dap = require("dap")

local TARGET_FILE = vim.env.NVIM_UE_TEST_FILE
  or "D:/UE/EngineRoot/Engine/Source/Runtime/VulkanRHI/Private/VulkanCommandBuffer.cpp"
local TARGET_LINE = 591
local symbol_path = vim.env.NVIM_UE_SYMBOL_PATH
  or [[D:\UE\ProjectRoot\Intermediate\Android\arm64\jni\arm64-v8a\libUE4.so]]
local android_package = vim.env.NVIM_UE_ANDROID_PACKAGE or "com.example.game"

local answers = {
  ["Path to symbol .so"] = symbol_path,
  ["Android package name"] = android_package,
}

local log = {}
local function logmsg(msg)
  local line = os.date("%H:%M:%S") .. " " .. tostring(msg)
  table.insert(log, line)
  io.write(line .. "\n")
  io.flush()
end

local function save_and_quit()
  local f = io.open(vim.fn.stdpath("config") .. "/tools/test_nvim_dap_reattach_591.result.txt", "w")
  if f then
    f:write(table.concat(log, "\n") .. "\n")
    f:close()
  end
  vim.cmd("qall!")
end

local stop_events = {}
local continue_count = 0
local init_count = 0
local terminated_count = 0

dap.listeners.after.event_initialized["reattach591"] = function()
  init_count = init_count + 1
  logmsg("EVENT initialized count=" .. init_count)
end

dap.listeners.after.event_stopped["reattach591"] = function(_, body)
  local reason = body and body.reason or "?"
  table.insert(stop_events, {
    reason = reason,
    threadId = body and body.threadId or nil,
    description = body and body.description or nil,
    text = body and body.text or nil,
  })
  logmsg("EVENT stopped reason=" .. reason)
end

dap.listeners.after.event_continued["reattach591"] = function()
  continue_count = continue_count + 1
  logmsg("EVENT continued count=" .. continue_count)
end

dap.listeners.after.event_terminated["reattach591"] = function()
  terminated_count = terminated_count + 1
  logmsg("EVENT terminated count=" .. terminated_count)
end

dap.listeners.after.event_output["reattach591"] = function(_, body)
  local out = body and body.output or ""
  out = tostring(out):gsub("%s+$", "")
  if out ~= "" then
    logmsg("OUTPUT " .. out:sub(1, 300))
  end
end

vim.fn.input = function(prompt, default)
  for prefix, answer in pairs(answers) do
    if prompt:find(prefix, 1, true) then
      logmsg("INPUT " .. prompt:gsub("%s+$", "") .. " -> " .. answer)
      return answer
    end
  end
  logmsg("INPUT " .. prompt:gsub("%s+$", "") .. " -> " .. tostring(default or ""))
  return default or ""
end

vim.notify = function(msg, level)
  logmsg("NOTIFY[" .. tostring(level or 0) .. "] " .. tostring(msg))
end

local function wait_for(pred, timeout_ms, label)
  local ok = vim.wait(timeout_ms, pred, 200)
  logmsg(("WAIT %s -> %s"):format(label, tostring(ok)))
  return ok
end

local function eval_wait(cmd, timeout_ms)
  local done = false
  local ok_result = nil
  local text_result = nil
  logmsg("EVAL >>> " .. cmd)
  ue._dap_eval_lldb(cmd, function(ok, result)
    ok_result = ok
    text_result = result
    done = true
  end)
  wait_for(function() return done end, timeout_ms or 10000, "eval:" .. cmd)
  logmsg(("EVAL <<< ok=%s result=%s"):format(tostring(ok_result), tostring(text_result):sub(1, 500)))
  return ok_result, text_result
end

local function prepare_target_buffer()
  vim.cmd("edit " .. TARGET_FILE)
  vim.api.nvim_win_set_cursor(0, { TARGET_LINE, 0 })
  logmsg(("BUFFER %s:%d"):format(TARGET_FILE, TARGET_LINE))
end

local function wait_for_breakpoint_hit(timeout_ms, cycle)
  local start_index = #stop_events + 1
  local ok = wait_for(function()
    for i = start_index, #stop_events do
      if stop_events[i].reason == "breakpoint" then
        return true
      end
    end
    return false
  end, timeout_ms, cycle .. ":breakpoint-hit")
  if not ok then
    return false
  end
  for i = start_index, #stop_events do
    if stop_events[i].reason == "breakpoint" then
      logmsg(("HIT %s reason=%s threadId=%s"):format(cycle, stop_events[i].reason, tostring(stop_events[i].threadId)))
      return true
    end
  end
  return false
end

local function disconnect_session(cycle)
  if not dap.session() then
    logmsg("DISCONNECT " .. cycle .. " skipped; no session")
    return true
  end
  logmsg("DISCONNECT " .. cycle .. " start")
  dap.disconnect({ terminateDebuggee = false })
  local ok = wait_for(function() return dap.session() == nil end, 20000, cycle .. ":session-nil")
  logmsg("STATE breakpoint_specs_after_disconnect=" .. vim.tbl_count(ue._breakpoint_specs or {}))
  return ok
end

local function attach_cycle(cycle)
  logmsg("=== " .. cycle .. " attach ===")
  local init_before = init_count
  local cont_before = continue_count
  vim.cmd("UEAndroidDAPAttach")
  if not wait_for(function() return init_count > init_before end, 120000, cycle .. ":initialized") then
    return false, "no initialized event"
  end
  if not wait_for(function() return continue_count > cont_before end, 60000, cycle .. ":continued") then
    return false, "no continued event"
  end
  if not dap.session() then
    return false, "session missing after attach"
  end
  return true
end

local function set_breakpoint_here(cycle)
  local stop_before = #stop_events
  prepare_target_buffer()
  logmsg("STATE breakpoint_specs_before_f9=" .. vim.tbl_count(ue._breakpoint_specs or {}))
  ue.dap_toggle_breakpoint()
  vim.wait(3000, function() return false end, 200)
  logmsg("STATE breakpoint_specs_after_f9=" .. vim.tbl_count(ue._breakpoint_specs or {}))
  eval_wait("breakpoint list", 10000)
  for i = stop_before + 1, #stop_events do
    if stop_events[i].reason == "breakpoint" then
      logmsg("HIT " .. cycle .. " occurred during F9")
      return true
    end
  end
  return false
end

local function cycle(cycle_name)
  local ok, err = attach_cycle(cycle_name)
  if not ok then
    return false, err
  end

  local hit = set_breakpoint_here(cycle_name)
  if not hit then
    hit = wait_for_breakpoint_hit(45000, cycle_name)
  end
  if not hit then
    logmsg("INFO no hit while running; pausing for diagnostics")
    ue.dap_pause()
    wait_for(function() return #stop_events > 0 end, 10000, cycle_name .. ":pause-stop")
    eval_wait("breakpoint list", 10000)
    eval_wait("bt 8", 10000)
    return false, "no breakpoint hit"
  end

  eval_wait("bt 8", 10000)
  if not disconnect_session(cycle_name) then
    return false, "disconnect failed"
  end
  return true
end

local ok1, err1 = cycle("cycle1")
if not ok1 then
  logmsg("FAIL cycle1: " .. tostring(err1))
  save_and_quit()
  return
end

local ok2, err2 = cycle("cycle2")
if not ok2 then
  logmsg("FAIL cycle2: " .. tostring(err2))
  save_and_quit()
  return
end

logmsg("PASS both cycles hit breakpoint at " .. TARGET_FILE .. ":" .. TARGET_LINE)
save_and_quit()
