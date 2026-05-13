-- E2E test for ue.dap.android codelldb route.
-- Runs from headless nvim (with full plugin tree). Performs:
--   1. bootstrap (push lldb-server to app sandbox)
--   2. start lldb-server gdbserver --attach
--   3. wire codelldb adapter
--   4. open a dap session, drive it via dap.session():on_event /:request
--   5. setFunctionBreakpoints on FEngineLoop::Tick
--   6. wait for stopped/initialized events
--   7. inspect threads + stackTrace (GameThread / RenderThread / RHIThread)
--   8. inspect scopes + locals on top GameThread frame
--   9. continue → disconnect cleanly
--
-- Usage:
--   UE_DAP_E2E_PKG=com.example.mygame \
--   UE_DAP_E2E_SERIAL=ABCDEF123456 \
--   UE_DAP_E2E_SYM=/abs/path/to/libUE4.so \
--   UE_DAP_E2E_PROOT=/abs/path/to/project \
--   nvim --headless -l tools/test_e2e_android_codelldb.lua
-- (Run with full init so nvim-dap is on rtp.)

local function getenv(name, default)
  local v = (vim.uv or vim.loop).os_getenv(name)
  if v == nil or v == "" then return default end
  return v
end

local PKG    = getenv("UE_DAP_E2E_PKG")
local SERIAL = getenv("UE_DAP_E2E_SERIAL")
local SYM    = getenv("UE_DAP_E2E_SYM")
local PROOT  = getenv("UE_DAP_E2E_PROOT")
local PORT   = tonumber(getenv("UE_DAP_E2E_PORT", "5045"))

if not (PKG and SERIAL and SYM and PROOT) then
  io.stderr:write([[
[e2e] missing required env vars. Set:
  UE_DAP_E2E_PKG     Android package name (e.g. com.example.mygame)
  UE_DAP_E2E_SERIAL  adb serial of the test device
  UE_DAP_E2E_SYM     absolute path to host-side libUE4.so with DWARF
  UE_DAP_E2E_PROOT   absolute path to project root
  UE_DAP_E2E_PORT    (optional, default 5045) gdbserver TCP port
]])
  os.exit(2)
end

local function p(...)
  io.stdout:write(string.format(...) .. "\n")
  io.stdout:flush()
end

-- Add nvim-dap to runtimepath manually so we don't need lazy.nvim to bootstrap.
local dap_root = vim.fn.stdpath("data") .. "/lazy/nvim-dap"
if vim.fn.isdirectory(dap_root) == 0 then
  p("FAIL nvim-dap not found at %s", dap_root)
  os.exit(2)
end
vim.opt.runtimepath:prepend(dap_root)
package.path = package.path
  .. ";" .. dap_root .. "/lua/?.lua"
  .. ";" .. dap_root .. "/lua/?/init.lua"

p("== ue.dap.android codelldb e2e ==")

-- Force test config into ue.config so we don't get prompted.
local cfg = require("ue.config")
cfg.set = cfg.set or function() end
do
  local ok = pcall(function()
    require("ue.config")._values = require("ue.config")._values or {}
  end)
  -- Direct table override; ue.config.get reads from this table in test runs.
  package.loaded["ue.config"] = setmetatable({
    get = function(k)
      local map = {
        ["dap.android_package"]    = PKG,
        ["dap.android_symbol_lib"] = SYM,
        ["dap.android_port"]       = PORT,
      }
      return map[k]
    end,
    set = function() end,
  }, {})
end

-- Stub vim.fn.input so any unanticipated prompt fails loudly instead of hanging.
vim.fn.input = function(prompt, ...)
  error("UNEXPECTED PROMPT: " .. tostring(prompt))
end

local A = require("ue.dap.android")
local C = require("ue.dap._common")
local dap = require("dap")

-- Hook events EARLY via dap.listeners (before attach), since
-- session.on_event_* won't catch events emitted before we read dap.session().
local got_initialized = false
local got_stopped = false
local stopped_thread_id = nil
dap.listeners.before["event_initialized"]["e2e"] = function(_, _)
  got_initialized = true
  p("event: initialized")
end
dap.listeners.before["event_stopped"]["e2e"] = function(_, body)
  got_stopped = true
  stopped_thread_id = body and body.threadId or 1
  p("event: stopped reason=%s thread=%s description=%s",
    tostring(body and body.reason), tostring(body and body.threadId),
    tostring(body and body.description))
end
dap.listeners.before["event_terminated"]["e2e"] = function() p("event: terminated") end
dap.listeners.before["event_exited"]["e2e"]     = function() p("event: exited") end
dap.listeners.before["event_output"]["e2e"]     = function(_, body)
  if body and body.output then
    local s = body.output:gsub("\n$", "")
    if #s > 0 then p("output[%s]: %s", body.category or "?", s) end
  end
end

-- Patch pick_serial via env-flavored override: we feed ctx.project_root for
-- symbol auto-detect.
A.attach({ context = { project_root = PROOT, engine_root = PROOT, android_serial = SERIAL } })

-- attach() schedules dap.run via nvim-dap; we need to keep the event loop
-- alive long enough to see initialized + setBreakpoints + stopped.
local sess

local function wait_for(predicate, timeout_ms)
  local elapsed = 0
  while elapsed < timeout_ms do
    if predicate() then return true end
    vim.wait(200)
    elapsed = elapsed + 200
  end
  return false
end

p("waiting for dap session...")
if not wait_for(function() sess = dap.session(); return sess ~= nil end, 15000) then
  p("FAIL no dap session after 15s")
  os.exit(2)
end
p("session: %s", tostring(sess))

-- Wait for stopOnEntry stop. codelldb attach via gdb-remote can take 30s+
-- because target create on a 3.85GB libUE4.so reads/parses DWARF first.
p("waiting for stopped event (stopOnEntry, up to 60s)...")
if not wait_for(function() return got_stopped end, 60000) then
  p("FAIL no stopped event after 60s (initialized=%s)", tostring(got_initialized))
  A.stop_android_debugger()
  os.exit(2)
end
p("stopped on thread %s", tostring(stopped_thread_id))

-- threads
sess:request("threads", nil, function(err, body)
  p("threads err=%s count=%s", tostring(err), body and body.threads and tostring(#body.threads) or "?")
end)
vim.wait(2000)

-- Set function breakpoint on FEngineLoop::Tick — called every game frame
-- (~16ms at 60fps), so should hit within 1s of resume.
sess:request("setFunctionBreakpoints", { breakpoints = {
  { name = "FEngineLoop::Tick" },
} }, function(err, body)
  p("setFunctionBreakpoints err=%s body=%s", tostring(err), vim.inspect(body))
end)
vim.wait(2000)

-- stackTrace on the actually-stopped thread.
sess:request("stackTrace", { threadId = stopped_thread_id, levels = 10 }, function(err, body)
  p("stackTrace err=%s frames=%s", tostring(err),
    body and body.stackFrames and tostring(#body.stackFrames) or "?")
  if body and body.stackFrames then
    for i, f in ipairs(body.stackFrames) do
      p("  frame %d: %s @ %s:%s", i, tostring(f.name),
        tostring(f.source and f.source.path), tostring(f.line))
    end
  end
end)
vim.wait(3000)

-- ── REAL BREAKPOINT HIT VERIFICATION ──────────────────────────────────────
-- With module rebased + SIGSEGV pass-through + function bp set on
-- FEngineLoop::Tick, continue and the bp should fire within ~16ms.
got_stopped = false
stopped_thread_id = nil

sess:request("configurationDone", nil, function(err, _)
  p("configurationDone err=%s", tostring(err))
end)
vim.wait(500)

p("continuing process, waiting for FEngineLoop::Tick bp to fire (up to 15s)...")
sess:request("continue", { threadId = 1 }, function(err, _)
  p("continue err=%s", tostring(err))
end)

local hit_real_bp = wait_for(function() return got_stopped end, 15000)
if not hit_real_bp then
  p("⚠️  bp didn't fire in 15s — falling back to manual pause to inspect state")
  sess:request("pause", { threadId = 1 }, function(err, _) p("pause err=%s", tostring(err)) end)
  wait_for(function() return got_stopped end, 5000)
end

if got_stopped then
  if hit_real_bp then
    p("🎯 REAL BREAKPOINT HIT! stopped on thread %s", tostring(stopped_thread_id))
  else
    p("✅ paused on thread %s (bp didn't fire in time)", tostring(stopped_thread_id))
  end

  -- Enumerate all threads to find the UE GameThread (this is where Tick lives;
  -- the Android main thread just runs ALooper in bionic libc syscalls).
  -- codelldb formats thread.name as: `<lldb_idx>: tid=<linux_tid> "<comm>"`.
  local game_thread_id = nil
  local render_thread_id = nil
  local rhi_thread_id = nil
  local thread_names = {}
  sess:request("threads", nil, function(err, body)
    p("threads(post-pause) err=%s count=%s", tostring(err),
      body and body.threads and tostring(#body.threads) or "?")
    if body and body.threads then
      for _, t in ipairs(body.threads) do
        thread_names[t.id] = t.name
        local nm = tostring(t.name or "")
        -- comm sits inside escaped quotes in the codelldb-formatted name.
        local comm = nm:match('"([^"]+)"') or nm
        if comm:match("GameThread") and not game_thread_id then
          game_thread_id = t.id
          p("  → found GameThread: id=%s comm=%s full=%s", tostring(t.id), comm, nm)
        elseif comm:match("RenderThread") and not render_thread_id then
          render_thread_id = t.id
          p("  → found RenderThread: id=%s comm=%s", tostring(t.id), comm)
        elseif comm == "RHIThread" and not rhi_thread_id then
          rhi_thread_id = t.id
          p("  → found RHIThread: id=%s", tostring(t.id))
        end
      end
      if not game_thread_id then
        -- Dump first 30 thread names to see what codelldb actually returns.
        p("  (no GameThread found; first 30 thread names:)")
        local n = 0
        for _, t in ipairs(body.threads) do
          n = n + 1
          if n <= 30 then p("    [%s] %s", tostring(t.id), tostring(t.name)) end
        end
      end
    end
  end)
  vim.wait(2000)

  -- Show stack on the paused (main/Java) thread first — expect libc/looper.
  sess:request("stackTrace", { threadId = stopped_thread_id, levels = 10 }, function(err, body)
    p("stackTrace(main thread %s = %s) err=%s frames=%s",
      tostring(stopped_thread_id), tostring(thread_names[stopped_thread_id]),
      tostring(err), body and body.stackFrames and tostring(#body.stackFrames) or "?")
    if body and body.stackFrames then
      for i, f in ipairs(body.stackFrames) do
        local sym = f.name or "?"
        local src = (f.source and f.source.path) or "<no source>"
        p("  frame %d: %s @ %s:%s", i, tostring(sym), tostring(src), tostring(f.line))
      end
    end
  end)
  vim.wait(2000)

  -- 🎯 The real stack we want: GameThread, where FEngineLoop::Tick lives.
  local gt_top_frame_id = nil
  local gt_top_frame_name = nil
  if game_thread_id then
    sess:request("stackTrace", { threadId = game_thread_id, levels = 25 }, function(err, body)
      p("=== stackTrace(GameThread %s) === err=%s frames=%s",
        tostring(game_thread_id), tostring(err),
        body and body.stackFrames and tostring(#body.stackFrames) or "?")
      if body and body.stackFrames then
        for i, f in ipairs(body.stackFrames) do
          local sym = f.name or "?"
          local src = (f.source and f.source.path) or "<no source>"
          p("  GT frame %d: id=%s %s @ %s:%s",
            i, tostring(f.id), tostring(sym), tostring(src), tostring(f.line))
          if i == 1 then
            gt_top_frame_id = f.id
            gt_top_frame_name = sym
          end
        end
      end
    end)
    vim.wait(3000)
  else
    p("WARN: no GameThread found in thread list")
  end

  if render_thread_id then
    sess:request("stackTrace", { threadId = render_thread_id, levels = 15 }, function(err, body)
      p("=== stackTrace(RenderThread %s) === err=%s frames=%s",
        tostring(render_thread_id), tostring(err),
        body and body.stackFrames and tostring(#body.stackFrames) or "?")
      if body and body.stackFrames then
        for i, f in ipairs(body.stackFrames) do
          local sym = f.name or "?"
          local src = (f.source and f.source.path) or "<no source>"
          p("  RT frame %d: %s @ %s:%s", i, tostring(sym), tostring(src), tostring(f.line))
        end
      end
    end)
    vim.wait(2000)
  end

  if rhi_thread_id then
    sess:request("stackTrace", { threadId = rhi_thread_id, levels = 15 }, function(err, body)
      p("=== stackTrace(RHIThread %s) === err=%s frames=%s",
        tostring(rhi_thread_id), tostring(err),
        body and body.stackFrames and tostring(#body.stackFrames) or "?")
      if body and body.stackFrames then
        for i, f in ipairs(body.stackFrames) do
          local sym = f.name or "?"
          local src = (f.source and f.source.path) or "<no source>"
          p("  RHI frame %d: %s @ %s:%s", i, tostring(sym), tostring(src), tostring(f.line))
        end
      end
    end)
    vim.wait(2000)
  end

  -- frameId 0 is the top of the most recently fetched stackTrace.
  -- DAP requires fetching stackTrace first to get valid frame ids.

  -- 🔬 Inspect locals on the top GameThread frame (Tick).
  if gt_top_frame_id then
    p("--- locals on GT top frame %s (%s) ---", tostring(gt_top_frame_id), tostring(gt_top_frame_name))
    local local_var_ref = nil
    sess:request("scopes", { frameId = gt_top_frame_id }, function(err, body)
      p("scopes err=%s count=%s", tostring(err),
        body and body.scopes and tostring(#body.scopes) or "?")
      if body and body.scopes then
        for _, s in ipairs(body.scopes) do
          p("  scope: %s (varRef=%s, expensive=%s)",
            tostring(s.name), tostring(s.variablesReference), tostring(s.expensive))
          if tostring(s.name):lower():find("local") and not local_var_ref then
            local_var_ref = s.variablesReference
          end
        end
      end
    end)
    vim.wait(2000)

    if local_var_ref then
      sess:request("variables", { variablesReference = local_var_ref }, function(err, body)
        p("variables(locals) err=%s count=%s", tostring(err),
          body and body.variables and tostring(#body.variables) or "?")
        if body and body.variables then
          for i, v in ipairs(body.variables) do
            if i <= 15 then
              local val = tostring(v.value or ""):gsub("\n", " "):sub(1, 120)
              p("    %s : %s = %s", tostring(v.name), tostring(v.type or "?"), val)
            end
          end
        end
      end)
      vim.wait(2000)
    end
  end
end

-- Clean up.
p("disconnecting...")
A.stop_android_debugger()
vim.wait(2000)
p("== done ==")
os.exit(0)
