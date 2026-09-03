-- ue.dap.exit_reason — truthful session-exit reporting.
--
-- WHY THIS EXISTS
-- ---------------
-- lldb-dap tells us how the inferior died, but only as a raw number:
--   {"body":{"category":"console","output":"Process 18690 exited with status = 9 (0x00000009) \n"}}
--   {"body":{"exitCode":9},"event":"exited"}
-- Measured (2026-09-03): `liblldb.dll` contains exactly one relevant format
-- string, `" Process %llu exited with status = %i (0x%8.8x) %s"`, and NO
-- "Terminated due to signal" text (grep -c == 0). So any human-readable
-- "SIGKILL — externally killed" wording must be synthesized here; lldb will
-- never hand it to us.
--
-- Before this module the Android liveness poller reported every death as
--   "App <pkg> exited on <serial>. Detaching."
-- which is indistinguishable between "your crash was caught" (it wasn't),
-- "the app self-crashed", and "something SIGKILLed the app". That opacity is
-- the user-visible defect; the debugger was behaving correctly.
--
-- Two sources are combined:
--   1. the DAP exit status (this module's note/take), and
--   2. Android's own post-mortem record, `dumpsys activity exit-info <pkg>`,
--      which is authoritative about WHO killed the process.
--
-- Pure parsing lives here so it is headless-testable; the adb round-trip is
-- driven by the Android owner (lua/ue/dap/android.lua).
local M = {}

-- ── signal-number vocabulary (Linux/Android arm64 asm-generic) ────────────
local SIGNAL_NAMES = {
  [1] = "SIGHUP", [2] = "SIGINT", [3] = "SIGQUIT", [4] = "SIGILL",
  [5] = "SIGTRAP", [6] = "SIGABRT", [7] = "SIGBUS", [8] = "SIGFPE",
  [9] = "SIGKILL", [10] = "SIGUSR1", [11] = "SIGSEGV", [12] = "SIGUSR2",
  [13] = "SIGPIPE", [14] = "SIGALRM", [15] = "SIGTERM", [16] = "SIGSTKFLT",
  [17] = "SIGCHLD", [18] = "SIGCONT", [19] = "SIGSTOP", [20] = "SIGTSTP",
  [24] = "SIGXCPU", [25] = "SIGXFSZ", [31] = "SIGSYS",
}

---Name of a signal number, or nil when it is not a signal we know.
---@param n integer|nil
---@return string|nil
function M.signal_name(n)
  n = tonumber(n)
  if not n then return nil end
  return SIGNAL_NAMES[n]
end

-- Signals UE's Android fatal handler hooks (AndroidPlatformMisc.cpp
-- TargetSignals[]): SIGQUIT SIGILL SIGFPE SIGBUS SIGSEGV SIGSYS SIGABRT
-- SIGTRAP. SIGKILL is deliberately absent — it cannot be hooked.
local UE_FATAL_SIGNALS = {
  [3] = true, [4] = true, [8] = true, [7] = true,
  [11] = true, [31] = true, [6] = true, [5] = true,
}

---Human-readable explanation of an lldb "exited with status = N".
---
---IMPORTANT (讲事实讲证据): lldb prints the same field for a plain `exit(N)`
---and for death-by-signal-N, and the trailing description was empty in the
---measured log. We therefore say "matches <SIG>" — never "was killed by" —
---and point at the authoritative Android record instead of guessing.
---@param status integer|nil
---@return string
function M.describe_status(status)
  status = tonumber(status)
  if not status then return "exit status unknown" end
  local sig = M.signal_name(status)
  if status == 9 then
    return ("exit status 9 — matches SIGKILL (killed from outside the app; "
      .. "SIGKILL can NOT be caught by any debugger)")
  end
  if sig and UE_FATAL_SIGNALS[status] then
    return ("exit status %d — matches %s, one of UE's fatal TargetSignals "
      .. "(the app died on its own crash path)"):format(status, sig)
  end
  if sig then
    return ("exit status %d — matches %s"):format(status, sig)
  end
  return ("exit status %d"):format(status)
end

-- ── in-flight note taken from the DAP protocol ────────────────────────────
M._last = nil

---Record what the adapter told us about the inferior's death.
---@param info table|nil  { status = integer|nil, source = string|nil }
function M.note(info)
  if type(info) ~= "table" then return end
  local status = tonumber(info.status)
  if not status then return end
  M._last = { status = status, source = info.source or "dap" }
end

---Parse lldb's console line, if it is one. Returns the status or nil.
---@param line string|nil
---@return integer|nil
function M.parse_console_exit(line)
  if type(line) ~= "string" then return nil end
  local status = line:match("[Pp]rocess%s+%d+%s+exited with status%s*=%s*(%-?%d+)")
  return status and tonumber(status) or nil
end

---Consume the recorded exit note (single-shot).
---@return table|nil
function M.take()
  local last = M._last
  M._last = nil
  return last
end

function M.reset()
  M._last = nil
end

-- ── `dumpsys activity exit-info <pkg>` parsing ────────────────────────────
--
-- Measured shape (Android 15, 2026-09-03):
--   ApplicationExitInfo #1:
--     timestamp=2026-09-03 18:09:26.867 pid=26871 realUid=10542 ... user=0
--     process=com.example reason=10 (USER REQUESTED) subreason=21 (FORCE STOP) status=0
--     importance=400 pss=0.00 rss=415MB state=empty trace=null
--     description=stop com.example due to from pid 1976 (system)
--     anrInfo=null
--
-- `dumpsys activity exit-info` takes a PACKAGE only (`dumpsys activity -h`
-- documents `exit-info [PACKAGE_NAME]`), so pid filtering happens here.

---@param text string|nil
---@return table[] records newest-first, as emitted by dumpsys
function M.parse_exit_info(text)
  if type(text) ~= "string" or text == "" then return {} end
  local records = {}
  local current = nil
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    if line:match("ApplicationExitInfo%s*#%d+") then
      current = {}
      records[#records + 1] = current
    elseif current then
      local pid = line:match("%f[%w]pid=(%d+)")
      if pid then current.pid = tonumber(pid) end
      local ts = line:match("timestamp=([%d%-]+%s[%d:%.]+)")
      if ts then current.timestamp = ts end
      local proc = line:match("process=([%S]+)")
      if proc then current.process = proc end
      local rcode, rname = line:match("reason=(%d+)%s*%(([^%)]*)%)")
      if rcode then
        current.reason_code = tonumber(rcode)
        current.reason = rname
      end
      local scode, sname = line:match("subreason=(%d+)%s*%(([^%)]*)%)")
      if scode then
        current.subreason_code = tonumber(scode)
        current.subreason = sname
      end
      local status = line:match("%f[%w]status=(%-?%d+)")
      if status then current.status = tonumber(status) end
      local desc = line:match("^%s*description=(.*)$")
      if desc and desc ~= "null" then current.description = desc end
    end
  end
  return records
end

---Find the newest record for a pid.
---@param text string|nil
---@param pid integer|nil
---@return table|nil
function M.find_exit_info(text, pid)
  pid = tonumber(pid)
  if not pid then return nil end
  for _, rec in ipairs(M.parse_exit_info(text)) do
    if rec.pid == pid then return rec end
  end
  return nil
end

-- Android ApplicationExitInfo.REASON_* values we can speak to.
local REASON_HINT = {
  [1] = "the app terminated itself (its own crash / exit path ran)",
  [2] = "a Java-level uncaught exception",
  [3] = "a native crash (SIGSEGV/SIGABRT/…) — this IS catchable, see below",
  [4] = "ANR (the app stopped responding)",
  [5] = "the app initialization failed",
  [6] = "the kernel low-memory killer reclaimed it",
  [10] = "something outside the app requested the kill (force-stop) — uncatchable",
  [11] = "a dependency died",
  [12] = "another process killed it",
  [13] = "the system upgraded/replaced the package",
  [14] = "Android's watchdog / permission change killed it",
  [16] = "excessive resource usage",
}

---One-line human summary of an ApplicationExitInfo record.
---@param rec table|nil
---@return string|nil
function M.summarize_record(rec)
  if type(rec) ~= "table" then return nil end
  local parts = {}
  if rec.reason then
    parts[#parts + 1] = ("reason=%s"):format(rec.reason)
  end
  if rec.subreason and rec.subreason ~= "UNKNOWN" then
    parts[#parts + 1] = ("subreason=%s"):format(rec.subreason)
  end
  if rec.status and rec.status ~= 0 then
    parts[#parts + 1] = ("status=%d"):format(rec.status)
  end
  local head = ("Android exit record: %s"):format(table.concat(parts, " "))
  local hint = rec.reason_code and REASON_HINT[rec.reason_code] or nil
  if hint then head = head .. ("\n  → %s"):format(hint) end
  if rec.description then head = head .. ("\n  description: %s"):format(rec.description) end
  return head
end

---Compose the full user-facing explanation.
---
---`opts.no_record_hint` is supplied by the PLATFORM OWNER (e.g. the Android
---owner passes the `dumpsys activity exit-info` command line). This module is
---target-generic and must not embed target-specific tooling literals — that is
---the ue_platform_boundary contract.
---@param opts table { status = integer|nil, record = table|nil, no_record_hint = string|nil }
---@return string
function M.compose(opts)
  opts = type(opts) == "table" and opts or {}
  local lines = {}
  if opts.status ~= nil then
    lines[#lines + 1] = M.describe_status(opts.status)
  end
  local summary = M.summarize_record(opts.record)
  if summary then
    lines[#lines + 1] = summary
  elseif type(opts.no_record_hint) == "string" and opts.no_record_hint ~= "" then
    lines[#lines + 1] = opts.no_record_hint
  end
  local uncatchable = (tonumber(opts.status) == 9)
    or (opts.record and opts.record.reason_code == 10)
    or (opts.record and opts.record.reason_code == 6)
  if uncatchable then
    lines[#lines + 1] = "The debugger did not miss a crash: this death cannot be trapped."
  end
  return table.concat(lines, "\n")
end

return M
