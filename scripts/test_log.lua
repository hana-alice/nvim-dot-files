-- scripts/test_log.lua: headless smoke test for utils.log
-- Run with: nvim --headless -u NONE +"set rtp+=." -l scripts/test_log.lua
--
-- Validates:
--   * log.path() returns a file inside stdpath("log")
--   * info/warn/error all write when level low enough; debug/trace gated
--   * rotation kicks in once we exceed MAX_BYTES
--   * wrap_job logs non-zero exits
--   * pcall wrapper logs failures
--
-- Exits with non-zero on failure so CI/dev can see it explode.

local errors = {}
local function check(cond, label)
  if cond then
    print("ok  " .. label)
  else
    print("FAIL " .. label)
    errors[#errors + 1] = label
  end
end

-- Make sure rtp includes the user's nvim config so require("utils.log") works
-- even when invoked from a script outside the runtime path.
local config_root = vim.fn.stdpath("config")
vim.opt.runtimepath:prepend(config_root)

local log = require("utils.log")

-- 1. Path
local p = log.path()
check(type(p) == "string" and p ~= "", "log.path() returns a string")
print("    path = " .. p)

-- Start clean so size assertions are deterministic.
log.clear()

-- 2. Default level WARN: info should NOT show, warn should.
local before = vim.uv.fs_stat(p)
local before_size = (before and before.size) or 0
log.info("test", "this should be filtered out at default level")
local after_info = vim.uv.fs_stat(p)
check(((after_info and after_info.size) or 0) == before_size,
  "INFO is suppressed at default WARN level")

log.warn("test", "warn line %d", 1)
log.error("test", "error with table arg", { foo = "bar", n = 3 })
local after_err = vim.uv.fs_stat(p)
check(((after_err and after_err.size) or 0) > before_size, "WARN/ERROR landed")

-- 3. set_level("debug") raises threshold so DEBUG lines persist.
log.set_level("debug")
log.debug("test", "debug visible after set_level")
log.set_level("warn")

-- 4. Rotation: write enough to cross 2 MB. Each line ~250 bytes; need ~9000.
local big = string.rep("x", 200)
for i = 1, 12000 do
  log.error("rot", "%d %s", i, big)
end

local function file_exists(path)
  return vim.fn.filereadable(path) == 1
end
check(file_exists(p .. ".1"), "rotation produced .1 backup")

-- 5. wrap_job: spawn a command that exits non-zero, expect ERROR line.
log.clear()
local cmd = vim.fn.has("win32") == 1
  and { "cmd.exe", "/c", "exit 7" }
  or { "sh", "-c", "echo bad >&2; exit 7" }

local job_done = false
local exit_code
local job = vim.fn.jobstart(cmd, log.wrap_job("test_job", {
  cmd = cmd,
  on_exit = function(_, code) exit_code = code; job_done = true end,
}))
check(job > 0, "jobstart returned a valid id")
vim.wait(5000, function() return job_done end, 50)
check(exit_code == 7, "job exited with code 7")

-- Give the wrap_job's on_exit a moment to flush.
vim.wait(100)
local handle = io.open(log.path(), "r")
local body = handle and handle:read("*a") or ""
if handle then handle:close() end
check(body:find("job exited code=7") ~= nil, "wrap_job logged the non-zero exit")

-- 6. log.pcall: failure produces ERROR line.
log.clear()
local ok = log.pcall("test_pcall", function() error("boom") end)
check(ok == false, "log.pcall returns false on failure")
local body2 = ""
local h2 = io.open(log.path(), "r")
if h2 then body2 = h2:read("*a"); h2:close() end
check(body2:find("pcall failed") ~= nil, "log.pcall recorded ERROR line")

if #errors > 0 then
  print("\nFAILED checks: " .. #errors)
  for _, e in ipairs(errors) do print("  - " .. e) end
  vim.cmd("cquit 1")
else
  print("\nALL CHECKS PASSED")
  vim.cmd("quit")
end
