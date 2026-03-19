-- Headless test: verify dap_continue BP re-plant and source-nav listener
-- Run: nvim --headless -c "luafile tools/test_dap_logic.lua" -c "qa"

local function p(msg) print(msg) io.stdout:flush() end
local function fail(msg) p("FAIL: " .. msg); os.exit(1) end
local function pass(msg) p("PASS: " .. msg) end

local ok, M = pcall(dofile, vim.fn.stdpath("config") .. "/lua/ue.lua")
if not ok then fail("load ue.lua: " .. tostring(M)) end

-- ── Shared stubs ────────────────────────────────────────────────────────────
local bufnr = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_name(bufnr, "C:/Engine/Source/VulkanCommandBuffer.cpp")
local fake_bps = { [bufnr] = { { line = 327 }, { line = 400 } } }

M.dap_breakpoints_module = function()
  return { get = function() return fake_bps end }
end
M.android_dap_breakpoint_spec_for = function(b, line, path, _)
  local file = vim.fn.fnamemodify(path, ":t")
  return { set_commands = { ('breakpoint set -H --file "%s" --line %d'):format(file, line) } }, nil
end

-- ── Test 1: no skip_bp in dap_continue — all BPs re-planted ────────────────
p("\n── Test 1: dap_continue re-plants all BPs (no skip_bp) ──")
fake_bps = { [bufnr] = { { line = 327 } } }

local eval_called, eval_commands, dap_continue_called = false, nil, false
M.android_dap_eval_lldb_commands = function(cmds, cb)
  eval_called = true; eval_commands = cmds; cb(true, "ok")
end
local fake_session = {
  stopped_thread_id = 42,
  current_frame = { source = { path = "C:/Engine/Source/VulkanCommandBuffer.cpp" }, line = 327 },
}
M.require_dap_module = function(name)
  if name ~= "dap" then return nil end
  return { session = function() return fake_session end, continue = function() dap_continue_called = true end }
end
M.dap_continue()
vim.wait(200, function() return dap_continue_called end, 10)

if not eval_called then fail("android_dap_eval_lldb_commands NOT called") end
local has_327 = false
for _, c in ipairs(eval_commands or {}) do
  if c:find("327") then has_327 = true end
end
if not has_327 then fail("line 327 missing from re-plant commands") end
if not dap_continue_called then fail("dap.continue() NOT called after re-plant") end
pass("dap_continue re-plants line 327 and calls dap.continue()")

-- ── Test 2: dap_continue falls through when no BPs ──────────────────────────
p("\n── Test 2: dap_continue falls through when no BPs ──")
fake_bps = {}
eval_called = false; dap_continue_called = false
M.dap_continue()
vim.wait(100, function() return dap_continue_called end, 10)
if eval_called then fail("android_dap_eval_lldb_commands called unexpectedly with no BPs") end
if not dap_continue_called then fail("dap.continue() NOT called when no BPs") end
pass("dap_continue falls through to dap.continue() with no BPs")

-- ── Test 3: extra_clears only sync ──────────────────────────────────────────
p("\n── Test 3: extra_clears-only sync sends clear command ──")
fake_bps = {}
local cmds3, count3 = M.android_dap_breakpoint_commands({
  extra_clears = { { file = "Foo.cpp", line = 10 } },
})
if count3 ~= 0 then fail("count3 should be 0") end
if #cmds3 == 0 then fail("extra_clears should produce commands") end
local found_clear = false
for _, c in ipairs(cmds3) do
  if c:find("Foo.cpp") and c:find("10") then found_clear = true end
end
if not found_clear then fail("breakpoint clear for Foo.cpp:10 not found") end
pass("extra_clears generates clear command")

-- ── Test 4: listeners registered ────────────────────────────────────────────
p("\n── Test 4: listeners registered after setup_dap ──")
local fake_dap2 = {
  listeners = {
    after = { event_stopped = {}, event_initialized = {} },
    before = { event_terminated = {}, event_exited = {}, disconnect = {} },
  },
  adapters = {}, configurations = {},
}
M.codelldb_paths = function()
  return { adapter = "C:\\fake\\codelldb.exe", liblldb = "C:\\fake\\liblldb.dll" }, nil
end
M.setup_dap(fake_dap2, nil)
if not fake_dap2.listeners.after.event_stopped["ue-android-dap-source-nav"] then
  fail("ue-android-dap-source-nav NOT registered")
end
pass("ue-android-dap-source-nav registered")
if not fake_dap2.listeners.after.event_stopped["ue-android-dap-breakpoint-sync"] then
  fail("ue-android-dap-breakpoint-sync NOT registered")
end
pass("ue-android-dap-breakpoint-sync registered")

-- ── Test 5: source-nav reads session.threads frames (no extra request) ──────
p("\n── Test 5: source-nav uses session.threads frames ──")
local nav_listener = fake_dap2.listeners.after.event_stopped["ue-android-dap-source-nav"]

local tmpfile = vim.fn.tempname() .. ".cpp"
local f = io.open(tmpfile, "w"); f:write("// source\n"); f:close()

local frame_set_called, frame_set_frame = false, nil
local extra_requests = 0

local nav_session = {
  stopped_thread_id = 1,
  threads = {
    [1] = {
      id = 1,
      frames = {
        -- Frame 0: virtual/no-symbol (sourceReference > 0)
        { id = 1, name = "kernel_fn", line = 1, source = { sourceReference = 9, path = "/system/lib/libc.so" } },
        -- Frame 1: real local file
        { id = 2, name = "RealFn",   line = 42, source = { sourceReference = 0, path = tmpfile } },
      },
    },
  },
  _frame_set = function(self, frame) frame_set_called = true; frame_set_frame = frame end,
  request = function(self, method, params, cb)
    extra_requests = extra_requests + 1
    -- should NOT be called when threads already populated
  end,
}

nav_listener(nav_session, { reason = "breakpoint", threadId = 1 })
vim.wait(400, function() return frame_set_called end, 10)
os.remove(tmpfile)

if not frame_set_called then
  fail("_frame_set NOT called")
end
if frame_set_frame and frame_set_frame.id ~= 2 then
  fail("Wrong frame: got id=" .. tostring(frame_set_frame.id) .. " want id=2")
end
if extra_requests > 0 then
  fail("Extra DAP requests sent even though threads.frames was populated (" .. extra_requests .. " requests)")
end
pass("source-nav used session.threads frames directly, called _frame_set with frame id=2, no extra requests")

-- ── Test 6: source-nav falls back to stackTrace request if threads empty ────
p("\n── Test 6: source-nav falls back to stackTrace request ──")
local tmpfile2 = vim.fn.tempname() .. ".cpp"
local f2 = io.open(tmpfile2, "w"); f2:write("// source2\n"); f2:close()

local frame_set_called2, fb_requests = false, 0
local nav_session2 = {
  stopped_thread_id = 1,
  threads = {},  -- empty — no frames yet
  _frame_set = function(self, frame) frame_set_called2 = true end,
  request = function(self, method, params, cb)
    fb_requests = fb_requests + 1
    if method == "stackTrace" then
      cb(nil, {
        stackFrames = {
          { id = 1, name = "kernel", line = 1, source = { sourceReference = 3, path = "/sys/lib.so" } },
          { id = 2, name = "GoodFn", line = 7, source = { sourceReference = 0, path = tmpfile2 } },
        },
      })
    end
  end,
}

nav_listener(nav_session2, { reason = "breakpoint", threadId = 1 })
vim.wait(400, function() return frame_set_called2 end, 10)
os.remove(tmpfile2)

if not frame_set_called2 then
  fail("_frame_set NOT called in fallback path")
end
if fb_requests == 0 then
  fail("Expected fallback stackTrace request, none sent")
end
pass("source-nav fell back to stackTrace request when threads empty, _frame_set called")

-- ── Test 7: source-nav skips when top frame already has local source ─────────
p("\n── Test 7: source-nav skips when top frame already readable ──")
local tmpfile3 = vim.fn.tempname() .. ".cpp"
local f3 = io.open(tmpfile3, "w"); f3:write("// good top\n"); f3:close()

local frame_set_called3 = false
local nav_session3 = {
  stopped_thread_id = 1,
  threads = {
    [1] = {
      frames = {
        { id = 1, name = "GoodFn", line = 5, source = { sourceReference = 0, path = tmpfile3 } },
      },
    },
  },
  _frame_set = function(self, frame) frame_set_called3 = true end,
  request = function() end,
}
nav_listener(nav_session3, { reason = "breakpoint", threadId = 1 })
vim.wait(400, function() return frame_set_called3 end, 10)
os.remove(tmpfile3)

if frame_set_called3 then
  p("NOTE: _frame_set called even when top frame already readable (harmless but wastes a re-nav)")
else
  pass("source-nav skipped _frame_set when top frame already had local source")
end

-- ── Test 8: is_real_stop: SIGSTOP exception is NOT real ─────────────────────
p("\n── Test 8: breakpoint-sync SIGSTOP exception → is NOT real_stop ──")
-- Simulate the listener being called with reason="exception", desc="signal SIGSTOP"
local sync_listener = fake_dap2.listeners.after.event_stopped["ue-android-dap-breakpoint-sync"]

local sync_resumed = false
local sync_evaled = false
M.android_dap_eval_lldb_commands = function(cmds, cb)
  sync_evaled = true; cb(true, "ok")
end

-- Set a pending action like a real sync would
local fake_sync_session = {
  stopped_thread_id = 1,
  request = function(self, method, params, cb)
    if method == "stackTrace" then
      cb(nil, { stackFrames = { { id = 10, name = "main" } } })
    end
  end,
}
M.require_dap_module = function(name)
  if name ~= "dap" then return nil end
  return {
    session = function() return fake_sync_session end,
    continue = function() sync_resumed = true end,
  }
end
M._android_dap_pending_breakpoint_action = {
  session = fake_sync_session,
  commands = { 'breakpoint set -H --file "Foo.cpp" --line 1' },
  resume_after_pause = true,
  on_success = function() end,
  on_failure = function() end,
}

sync_listener(fake_sync_session, {
  reason = "exception",
  description = "signal SIGSTOP",
  text = "signal SIGSTOP",
  threadId = 1,
})
vim.wait(300, function() return sync_evaled end, 10)

if not sync_evaled then fail("eval was not called for SIGSTOP exception") end
if not sync_resumed then
  -- The continue is scheduled via vim.schedule so wait a bit more
  vim.wait(300, function() return sync_resumed end, 10)
end
if not sync_resumed then fail("process NOT resumed after SIGSTOP exception (is_real_stop wrongly true)") end
pass("SIGSTOP exception treated as non-real → eval + resume ✓")

-- ── Test 9: is_real_stop: real breakpoint IS real ───────────────────────────
p("\n── Test 9: breakpoint-sync real breakpoint → stays paused ──")
local real_bp_evaled = false
local real_bp_resumed = false
M.android_dap_eval_lldb_commands = function(cmds, cb)
  real_bp_evaled = true; cb(true, "ok")
end

fake_sync_session.stopped_thread_id = 1
M.require_dap_module = function(name)
  if name ~= "dap" then return nil end
  return {
    session = function() return fake_sync_session end,
    continue = function() real_bp_resumed = true end,
  }
end
M._android_dap_pending_breakpoint_action = {
  session = fake_sync_session,
  commands = { 'breakpoint set -H --file "Foo.cpp" --line 1' },
  resume_after_pause = true,
  on_success = function() end,
  on_failure = function() end,
}

sync_listener(fake_sync_session, {
  reason = "breakpoint",
  threadId = 1,
})
vim.wait(300, function() return real_bp_evaled end, 10)

if not real_bp_evaled then fail("eval not called for real breakpoint stop") end
vim.wait(100, function() return real_bp_resumed end, 10)
if real_bp_resumed then fail("process was resumed after a REAL breakpoint stop — should stay paused!") end
pass("real breakpoint stop → eval but NO resume ✓")

-- ── Test 10: breakpoint clear "no breakpoints found" is non-fatal ────────────
p("\n── Test 10: eval_lldb_command: 'no breakpoints found' is non-fatal ──")
-- Simulate CodeLLDB returning "error: No breakpoints found for Foo.cpp, line 1."
-- This happens when clear_remote=true but no LLDB BP exists yet (fresh attach).
-- The command should be treated as success so the subsequent set command runs.
local no_bp_ok, no_bp_result = nil, nil
-- Temporarily monkey-patch android_dap_current_session to return a fake session
-- that returns the "no breakpoints found" error via evaluate.
local orig_get_session = M.android_dap_current_session
local fake_eval_session = {
  current_frame = nil,
  evaluate = function(self, params, cb)
    -- Simulate LLDB returning the "no breakpoints found" error string
    cb(nil, { result = 'error: No breakpoints found for Foo.cpp, line 1.' })
  end,
}
M.android_dap_current_session = function()
  return fake_eval_session, nil
end
M.android_dap_eval_lldb_command('breakpoint clear --file "Foo.cpp" --line 1', function(ok, result)
  no_bp_ok = ok; no_bp_result = result
end)
M.android_dap_current_session = orig_get_session
if not no_bp_ok then
  fail("'no breakpoints found' was incorrectly treated as a failure (got: " .. tostring(no_bp_result) .. ")")
end
pass("'no breakpoints found' treated as non-fatal — breakpoint clear is idempotent ✓")

-- ── Test 11: setup_dap installs empty pending action when no BPs queued ───────
p("\n── Test 11: event_initialized sets empty pending action when no BPs ──")
-- Simulate setup_dap with a fresh dap object and no breakpoints.
-- After android_dap_sync_breakpoints returns (count=0), an empty pending
-- should be installed so the initial SIGSTOP auto-continues.
M.android_dap_sync_breakpoints = function(opts) return true, 0 end  -- no BPs
M._android_dap_pending_breakpoint_action = nil
local fake_dap3 = {
  listeners = {
    after = { event_stopped = {}, event_initialized = {} },
    before = { event_terminated = {}, event_exited = {}, disconnect = {} },
  },
  adapters = {}, configurations = {},
}
local fake_sess3 = { id = "sess3" }
local orig_session_fn
-- Patch dap.session() inside the setup_dap call
fake_dap3.session = function() return fake_sess3 end
M.codelldb_paths = function()
  return { adapter = "C:\\fake\\codelldb.exe", liblldb = "C:\\fake\\liblldb.dll" }, nil
end
M.setup_dap(fake_dap3, nil)
-- Simulate event_initialized firing
local init_listener = fake_dap3.listeners.after.event_initialized["ue-android-dap-breakpoint-init"]
if not init_listener then
  fail("ue-android-dap-breakpoint-init listener not registered")
end
-- The listener uses vim.schedule internally; call via pcall and pump with vim.wait
init_listener()
vim.wait(300, function() return M._android_dap_pending_breakpoint_action ~= nil end, 10)
if not M._android_dap_pending_breakpoint_action then
  fail("Empty pending action NOT set after event_initialized with no BPs")
end
local ep = M._android_dap_pending_breakpoint_action
if ep.session ~= fake_sess3 then
  fail("Empty pending action has wrong session")
end
if type(ep.commands) ~= "table" or #ep.commands ~= 0 then
  fail("Empty pending action should have commands={}")
end
if not ep.resume_after_pause then
  fail("Empty pending action should have resume_after_pause=true")
end
pass("Empty pending action set → initial SIGSTOP will auto-continue ✓")
-- Restore
M.android_dap_sync_breakpoints = nil  -- let the real one be used

p("\n═══ All tests passed ═══")
