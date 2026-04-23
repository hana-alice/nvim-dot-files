-- Headless smoke test for utils.log.
-- Run with: nvim --headless -u NONE -l scripts/test_log.lua
--
-- Adds nvim/lua to package.path so utils.log resolves cleanly when invoked
-- from the repo root.

local script_dir = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
local repo_root = script_dir:gsub("[/\\]scripts[/\\]?$", "")
package.path = table.concat({
  repo_root .. "/lua/?.lua",
  repo_root .. "/lua/?/init.lua",
  package.path,
}, ";")

-- Force log into a temp dir so we don't pollute the real one.
local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
local orig_stdpath = vim.fn.stdpath
vim.fn.stdpath = function(what)
  if what == "log" then return tmp end
  return orig_stdpath(what)
end

local fails = 0
local function check(name, cond, detail)
  if cond then
    print("  ok  - " .. name)
  else
    fails = fails + 1
    print("  FAIL- " .. name .. (detail and (" :: " .. tostring(detail)) or ""))
  end
end

local log = require("utils.log")

print("== utils.log smoke ==")
print("log path: " .. log.path())

-- 1. Basic emit at default WARN+
log.error("smoke", "first error message")
log.warn("smoke", "first warn message")
log.info("smoke", "should NOT appear at default level")
log.debug("smoke", "should NOT appear at default level")

-- 2. Format-string detection (single % is NOT a fmt spec).
log.error("smoke", "path with literal percent: %LOCALAPPDATA%\\nvim and trailing arg", "extra")
log.error("smoke", "fmt %s with code=%d", "OK", 42)

-- 3. Structured ctx
log.error_ctx("smoke", "structured failure", { code = 1, cmd = "git push", cwd = "/tmp/x", note = "spaces inside" })

-- 4. Scoped logger
local L = log.scoped("smoke.scoped")
L.error("hello from scoped")
L.error_ctx("scoped ctx", { a = 1, b = "two" })

-- 5. set_level allows info through
log.set_level("info")
log.info("smoke", "now visible at info")
log.set_level("warn")

-- 6. per-scope override raises threshold for one scope only
log.set_scope_level("smoke.muted", "error")
log.warn("smoke.muted", "this MUST be dropped (override=error)")
log.error("smoke.muted", "this should appear (>= error)")
log.set_scope_level("smoke.muted", nil)

-- 7. pcall captures traceback
local ok = log.pcall("smoke", function() error("boom") end)
check("pcall returns false on throw", ok == false)

-- 8. wrap_job non-zero exit logs ctx; callback throw is logged + (would) notify
local wrap = log.wrap_job("smoke.job", { cmd = { "echo", "hi" }, cwd = "/tmp", on_exit = function() error("user cb broke") end })
wrap.on_stderr(0, { "fake stderr 1", "fake stderr 2" }, "stderr")
wrap.on_exit(0, 7, "exit")

-- 9. fast-event simulation: enqueue then flush via schedule
local fast_called = false
vim.schedule(function() fast_called = true end)
-- We can't truly enter fast-event from the script, but enqueue path is
-- exercised when resolved_path was nil at first write -- test the pending
-- buffer path by clearing state and re-entering via a libuv timer (timer
-- callback IS a fast event).
local timer = (vim.uv or vim.loop).new_timer()
local timer_logged = false
timer:start(10, 0, function()
  log.error("smoke.fast", "logged from libuv timer (fast event)")
  timer_logged = true
  timer:close()
end)

-- 10. notify_error mirrors to log + would notify (we don't intercept notify)
log.notify_error("smoke", "notify_error path")

-- Wait for scheduled flushes + timer to complete.
local deadline = vim.loop.now() + 500
while vim.loop.now() < deadline and not (fast_called and timer_logged) do
  vim.wait(20, function() return false end)
end
-- One more poll cycle to drain pending_buffer flush_pending schedule.
vim.wait(50, function() return false end)

check("fast event scheduled callback fired", fast_called)
check("timer wrote a log entry", timer_logged)

-- Read back the file and verify content.
local fh = io.open(log.path(), "rb")
check("log file exists", fh ~= nil)
local content = fh and fh:read("*a") or ""
if fh then fh:close() end

local function has(s) return content:find(s, 1, true) ~= nil end

check("contains ERROR line",                has("ERROR [smoke] first error message"))
check("contains WARN line",                 has("WARN [smoke] first warn message"))
check("info dropped at default WARN",       not has("should NOT appear at default level"))
check("literal percent NOT formatted",      has("%LOCALAPPDATA%\\nvim"))
check("fmt with %s/%d formatted",           has("fmt OK with code=42"))
check("structured ctx rendered with sorted keys",
      has("structured failure cmd=") and has("code=1") and has("cwd=/tmp/x") and has('note="spaces inside"'))
check("scoped logger writes correct scope", has("[smoke.scoped] hello from scoped"))
check("scoped ctx renders",                 has("[smoke.scoped] scoped ctx a=1 b=two"))
check("set_level info raises visibility",   has("INFO [smoke] now visible at info"))
check("scope override drops below threshold", not has("this MUST be dropped"))
check("scope override allows >= threshold", has("this should appear"))
check("pcall logs failure",                 has("ERROR [smoke] pcall failed: ") and has("boom"))
check("wrap_job logs job failure ctx",      has("ERROR [smoke.job] job failed") and has("code=7") and has("cmd=\"echo hi\""))
check("wrap_job logs stderr_tail",          has("stderr_tail") and has("fake stderr 1"))
check("wrap_job callback throw logged",     has("callback on_exit threw"))
check("fast event entry written",           has("[smoke.fast] logged from libuv timer"))
check("notify_error writes ERROR line",     has("ERROR [smoke] notify_error path"))

print("")
if fails == 0 then
  print("== ALL CHECKS PASSED ==")
  print("(log file: " .. log.path() .. ")")
else
  print("== " .. fails .. " CHECK(S) FAILED ==")
  print("(inspect: " .. log.path() .. ")")
  os.exit(1)
end
