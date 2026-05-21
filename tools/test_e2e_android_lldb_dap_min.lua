-- Minimal e2e: drive ue.dap.android.attach() without requiring a host-side
-- DWARF libUE4.so. This is meant for headless runs on machines that don't
-- yet have a synced symbol build but do have a live device.
--
-- Usage:
--   UE_DAP_E2E_PKG=com.example.mygame \
--   UE_DAP_E2E_SERIAL=<adb-serial> \
--   nvim --headless -l tools/test_e2e_android_lldb_dap_min.lua

local function getenv(name, default)
  local v = (vim.uv or vim.loop).os_getenv(name)
  if v == nil or v == "" then return default end
  return v
end

local PKG    = getenv("UE_DAP_E2E_PKG")
local SERIAL = getenv("UE_DAP_E2E_SERIAL")

if not (PKG and SERIAL) then
  io.stderr:write([[
[e2e-min] missing env. Set UE_DAP_E2E_PKG and UE_DAP_E2E_SERIAL.
]])
  os.exit(2)
end

local function p(...)
  io.stdout:write(string.format(...) .. "\n")
  io.stdout:flush()
end

-- Make nvim-dap reachable.
local dap_root = vim.fn.stdpath("data") .. "/lazy/nvim-dap"
if vim.fn.isdirectory(dap_root) == 0 then
  p("FAIL nvim-dap not at %s", dap_root)
  os.exit(2)
end
vim.opt.runtimepath:prepend(dap_root)
package.path = package.path
  .. ";" .. dap_root .. "/lua/?.lua"
  .. ";" .. dap_root .. "/lua/?/init.lua"

p("== ue.dap.android lldb-dap minimal e2e ==")
p("PKG=%s SERIAL=%s", PKG, SERIAL)

-- Monkey-patch ue.dap._progress so step()/error()/hide() echo to stdout
-- (the default impl writes to vim.notify which is silent in headless).
package.loaded["ue.dap._progress"] = {
  step  = function(msg) p("[progress] %s", tostring(msg)) end,
  error = function(msg) p("[progress-ERR] %s", tostring(msg)) end,
  hide  = function() p("[progress] hide") end,
  done  = function() p("[progress] done") end,
}

-- Capture vim.notify for diagnostic visibility too.
local orig_notify = vim.notify
vim.notify = function(msg, level, opts)
  p("[notify] %s", tostring(msg):gsub("\n", " | "))
  return orig_notify and orig_notify(msg, level, opts)
end

-- Stub ue.config to skip all prompts. We pass a dummy "symbol_lib" — the
-- value is fed to `settings set target.exec-search-paths` in init_commands,
-- which silently no-ops if the directory doesn't exist. Real symbol-aware
-- runs should set this to the actual host-side libUE4.so path.
local DUMMY_SYM = vim.fn.tempname() .. "_dummy_libUE4.so"
do
  local f = io.open(DUMMY_SYM, "wb"); if f then f:write("dummy"); f:close() end
end
package.loaded["ue.config"] = setmetatable({
  get = function(k)
    local map = {
      ["dap.android_package"]    = PKG,
      ["dap.android_symbol_lib"] = DUMMY_SYM,
    }
    return map[k]
  end,
  set = function() end,
}, {})

-- Stub pick_symbol_lib: return nil so attach skips the host-side DWARF path.
-- (android.lua's pick_symbol_lib falls back to vim.fn.input, which would
--  hang in headless; intercept upstream.)
vim.fn.input = function(prompt, ...)
  p("UNEXPECTED PROMPT: %s — returning empty", tostring(prompt))
  return ""
end

-- Override fs.is_file for the symbol lib check so pick_symbol_lib's input
-- fallback bails immediately rather than hanging.
local A   = require("ue.dap.android")
local dap = require("dap")

-- Wire all listeners BEFORE attach.
local got_initialized = false
local got_stopped = false
local got_terminated = false
local got_exited = false
local stopped_reason = nil
local stopped_thread_id = nil
local hit_bp = false

dap.listeners.before["event_initialized"]["e2e"] = function()
  got_initialized = true
  p("event: initialized")
end
dap.listeners.before["event_stopped"]["e2e"] = function(_, body)
  got_stopped = true
  stopped_reason = body and body.reason or "?"
  stopped_thread_id = body and body.threadId or 0
  p("event: stopped reason=%s tid=%s desc=%s",
    tostring(stopped_reason), tostring(stopped_thread_id),
    tostring(body and body.description))
  if stopped_reason == "breakpoint" or stopped_reason == "function breakpoint" then
    hit_bp = true
  end
end
dap.listeners.before["event_terminated"]["e2e"] = function() got_terminated = true; p("event: terminated") end
dap.listeners.before["event_exited"]["e2e"]     = function() got_exited = true; p("event: exited") end
dap.listeners.before["event_output"]["e2e"]     = function(_, body)
  if body and body.output then
    local s = body.output:gsub("\n$", "")
    if #s > 0 then p("output[%s]: %s", body.category or "?", s) end
  end
end

p("calling A.attach({ context = { android_serial = SERIAL } })")
A.attach({ context = { android_serial = SERIAL } })

local function wait_for(predicate, timeout_ms)
  local elapsed = 0
  while elapsed < timeout_ms do
    if predicate() then return true end
    vim.wait(200)
    elapsed = elapsed + 200
  end
  return false
end

local sess
p("waiting for dap session (up to 30s)...")
if not wait_for(function() sess = dap.session(); return sess ~= nil end, 30000) then
  p("FAIL no dap session after 30s")
  os.exit(2)
end
p("OK session: %s", tostring(sess))

-- platform mode + attach can take 30-90s on first pull (3.85GB libUE4.so
-- from device into ~/.lldb/module_cache). Be generous.
p("waiting for initialized + stopped (up to 180s)...")
local wait_start = vim.uv.now()
local last_log = wait_start
local function tick_log()
  local now = vim.uv.now()
  if now - last_log > 5000 then
    p("  ...still waiting (%ds elapsed, initialized=%s, stopped=%s)",
      math.floor((now - wait_start) / 1000),
      tostring(got_initialized), tostring(got_stopped))
    last_log = now
  end
end
local elapsed = 0
while elapsed < 180000 and not (got_initialized and got_stopped) do
  tick_log()
  vim.wait(500)
  elapsed = elapsed + 500
end
if not got_initialized then
  p("FAIL no initialized event after 180s")
  A.stop_android_debugger()
  os.exit(2)
end

-- After initialized, set BP on Tick.
p("setting function breakpoint FEngineLoop::Tick...")
sess:request("setFunctionBreakpoints", { breakpoints = { { name = "FEngineLoop::Tick" } } }, function(err, body)
  p("setFunctionBreakpoints err=%s verified=%s",
    tostring(err),
    body and body.breakpoints and vim.inspect(vim.tbl_map(function(b) return b.verified end, body.breakpoints)) or "?")
end)
vim.wait(3000)

p("configurationDone + continue (waiting up to 30s for Tick hit)...")
sess:request("configurationDone", nil, function(err) p("configurationDone err=%s", tostring(err)) end)
vim.wait(500)
got_stopped = false
sess:request("continue", { threadId = 1 }, function(err) p("continue err=%s", tostring(err)) end)

if not wait_for(function() return got_stopped end, 30000) then
  p("FAIL no stopped event after continue (initialized=%s)", tostring(got_initialized))
  A.stop_android_debugger()
  os.exit(2)
end

if hit_bp then
  p("🎯 BP HIT — reason=%s thread=%s", stopped_reason, tostring(stopped_thread_id))
  -- Quick stack trace to prove the chain.
  sess:request("stackTrace", { threadId = stopped_thread_id, levels = 5 }, function(err, body)
    p("stackTrace err=%s frames=%s", tostring(err),
      body and body.stackFrames and tostring(#body.stackFrames) or "?")
    if body and body.stackFrames then
      for i, f in ipairs(body.stackFrames) do
        p("  #%d %s @ %s:%s",
          i - 1, tostring(f.name),
          tostring(f.source and f.source.path or "?"), tostring(f.line))
      end
    end
  end)
  vim.wait(3000)
  p("✅ END-TO-END PASS via nvim-dap / lldb-dap")
else
  p("⚠️  stopped but not on BP (reason=%s) — adapter is alive though",
    tostring(stopped_reason))
end

p("disconnecting...")
A.stop_android_debugger()
vim.wait(3000)
p("== done ==")
os.exit(hit_bp and 0 or 1)
