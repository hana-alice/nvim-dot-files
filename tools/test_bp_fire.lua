-- Test: attach with new ASLR fix, set BP on Render(), verify it fires
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

local got_initialized, got_stopped, got_continued = false, false, false
local stop_reason = ""

dap.listeners.after.event_initialized["t"] = function() got_initialized = true; logmsg("EVT:init") end
dap.listeners.after.event_stopped["t"] = function(_, b)
  got_stopped = true; stop_reason = b and b.reason or "?"
  logmsg("EVT:stopped " .. stop_reason)
end
dap.listeners.after.event_continued["t"] = function() got_continued = true; logmsg("EVT:continued") end
dap.listeners.after.event_output["t"] = function(_, b)
  if b and b.output then
    local l = b.output:gsub("%s+$", "")
    if l ~= "" then logmsg("CON: " .. l:sub(1, 250)) end
  end
end

local answers = {
  ["Path to libUE4.so"] = symbol_path,
  ["Path to symbol .so"] = symbol_path,
  ["Android package name"] = android_package,
}
vim.fn.input = function(prompt, default)
  for p, a in pairs(answers) do if prompt:find(p, 1, true) then return a end end
  return default or ""
end
vim.notify = function(msg, level) logmsg("N[" .. (level or 0) .. "]: " .. tostring(msg)) end

local function eval_wait(cmd, timeout)
  logmsg(">>> " .. cmd)
  local done = false
  ue._dap_eval_lldb(cmd, function() done = true end)
  vim.wait(timeout or 10000, function() return done end, 200)
  vim.wait(1000, function() return false end, 200)
end

local function save_and_quit()
  local f = io.open(vim.fn.stdpath("config") .. "/tools/test_bp_fire.result.txt", "w")
  if f then f:write(table.concat(log, "\n") .. "\n"); f:close() end
  if dap.session() then dap.disconnect({ terminateDebuggee = false }) end
  vim.wait(3000, function() return dap.session() == nil end, 500)
  vim.cmd("qall!")
end

-- Phase 1: Attach (with new ASLR fix in event_initialized callback)
logmsg("=== Attach ===")
vim.cmd("UEAndroidDAPAttach")

-- Wait for ASLR fix + continue (signaled by got_continued)
logmsg("Waiting for attach + ASLR fix + continue...")
local ok = vim.wait(120000, function() return got_continued end, 1000)
if not ok then
  logmsg("FAIL: no continue after 120s")
  save_and_quit()
  return
end
logmsg("Attached, ASLR fixed, running")

-- Phase 2: Pause, verify ASLR, set BP
logmsg("=== Pause ===")
got_stopped = false
ue.dap_pause()
vim.wait(10000, function() return got_stopped end, 500)
if not got_stopped then
  logmsg("FAIL: no pause")
  save_and_quit()
  return
end

-- Verify ASLR fix: image list base should match /proc/maps
eval_wait("image list libUE4.so")

-- Set HW BP on Render
eval_wait('breakpoint set -H -n "FMobileSceneRenderer::Render"')
eval_wait("breakpoint list")

-- Phase 3: Continue and wait for BP hit
logmsg("=== Continue and wait for BP ===")
got_stopped = false
got_continued = false
eval_wait("process continue")
vim.wait(3000, function() return got_continued end, 200)

logmsg("Waiting 20s for BP hit...")
local hit = vim.wait(20000, function() return got_stopped end, 500)
if hit then
  logmsg("=== BP HIT! reason=" .. stop_reason .. " ===")
  eval_wait("bt 10")
  logmsg("PASS")
else
  logmsg("=== NO HIT after 20s ===")
  -- Re-pause and check hit count
  got_stopped = false
  ue.dap_pause()
  vim.wait(10000, function() return got_stopped end, 500)
  eval_wait("breakpoint list")
  logmsg("FAIL: BP did not fire")
end

save_and_quit()
