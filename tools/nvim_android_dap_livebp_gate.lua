-- tools/nvim_android_dap_livebp_gate.lua
-- D1 live-breakpoint feasibility gate (design: android-dap-live-breakpoints).
--
-- Goal: determine whether a breakpoint planted DURING an active session (after
-- attach + continue) actually resolves AND hits, vs. the attach-time preseed
-- path which is already proven. We deliberately DO NOT preseed the target
-- breakpoint. We attach, continue past the entry SIGSTOP burst, wait for the
-- app to reach steady render state, then plant via the chosen live channel and
-- watch for a breakpoint stop.
--
-- Channel selected by NVIM_DAP_LIVEBP_CHANNEL:
--   "evaluate" (default) → dap.session():request("evaluate", repl backtick cmd)
--   "setbreakpoints"      → dap.session():set_breakpoints({ [bufnr] = {{line}} })
--
-- Success = a stopped event with reason="breakpoint" on the target line.
-- Failure-but-resolved = breakpoint list shows resolved=1 yet never hits
--   (confirms 361b9e7 "memory write silently dropped").
--
-- Result JSON keyed for the gate: channel, live_plant_sent, resolved_after_plant,
-- saw_breakpoint, hit_line, adapter_alive, lldb_outputs, events.

local json = vim.json
local start_cwd = vim.fn.getcwd()

local function is_absolute_path(path)
  return path:match("^%a:[/\\]") ~= nil or path:match("^[/\\][/\\]") ~= nil or path:sub(1, 1) == "/"
end

local configured_result_path = vim.env.NVIM_DAP_SMOKE_RESULT
  or "tools/evidence/android-f9/livebp-gate.result.json"
local result_path = is_absolute_path(configured_result_path) and configured_result_path
  or vim.fs.joinpath(start_cwd, configured_result_path)

local target_file = vim.env.NVIM_DAP_SMOKE_FILE
local target_line = tonumber(vim.env.NVIM_DAP_SMOKE_LINE or "1367") or 1367
local project_root = vim.env.NVIM_DAP_SMOKE_PROJECT
local android_serial = vim.env.NVIM_DAP_SMOKE_SERIAL
local android_symbol_lib = vim.env.NVIM_DAP_SMOKE_SYMBOL_LIB
local channel = vim.env.NVIM_DAP_LIVEBP_CHANNEL or "evaluate"
local timeout_ms = tonumber(vim.env.NVIM_DAP_SMOKE_TIMEOUT_MS or "240000") or 240000
-- How long to let the app run after the live plant before declaring "resolved
-- but never hits". MobileShadingRenderer::Render fires every frame, so a few
-- seconds of real running is plenty if the breakpoint actually arms.
local hit_wait_ms = tonumber(vim.env.NVIM_DAP_LIVEBP_HITWAIT_MS or "20000") or 20000

local result = {
  status = "running",
  gate = "live-breakpoint",
  channel = channel,
  target = { file = target_file, line = target_line, project_root = project_root },
  live_plant_sent = false,
  resolved_after_plant = nil,
  saw_breakpoint = false,
  adapter_alive = nil,
  events = {},
  lldb_outputs = {},
  notifications = {},
}

local done = false

local function append(list, value) list[#list + 1] = value end
local function event(name, payload) append(result.events, { name = name, payload = payload or vim.NIL }) end

local function append_lldb_output(output)
  if type(output) ~= "string" or output == "" then return end
  local trimmed = output:gsub("[\r\n]+$", "")
  if trimmed == "" then return end
  if trimmed:find("breakpoint", 1, true) or trimmed:find("Breakpoint", 1, true)
    or trimmed:find("MobileShadingRenderer", 1, true) or trimmed:find("resolved", 1, true)
    or trimmed:find("pending", 1, true) or trimmed:find("libUE4.so", 1, true)
    or trimmed:find("error", 1, true) then
    append(result.lldb_outputs, trimmed)
  end
end

-- Track resolved=N for the LAST breakpoint-list dump we trigger after plant.
local function scan_resolved(output)
  for line in (output .. "\n"):gmatch("([^\n]*)\n") do
    local resolved = line:match("locations = %d+, resolved = (%d+)")
    if resolved then result.resolved_after_plant = tonumber(resolved) end
  end
end

local function capture_output(output)
  append_lldb_output(output)
  scan_resolved(output or "")
end

local function encode(value)
  local ok, encoded = pcall(json.encode, value)
  if ok then return encoded end
  return json.encode({ status = "encode_error", error = tostring(encoded) })
end

local function write_result()
  local dir = vim.fn.fnamemodify(result_path, ":h")
  if dir and dir ~= "" then vim.fn.mkdir(dir, "p") end
  vim.fn.writefile({ encode(result) }, result_path)
end

local function cleanup()
  local ok, dap = pcall(require, "dap")
  if ok and dap.session and dap.session() then pcall(dap.disconnect, { terminateDebuggee = false }) end
end

local function finish(status, extra)
  if done then return end
  done = true
  result.status = status
  if extra then for k, v in pairs(extra) do result[k] = v end end
  -- record adapter liveness right before teardown
  local ok, dap = pcall(require, "dap")
  result.adapter_alive = ok and dap.session and dap.session() ~= nil or false
  cleanup()
  write_result()
  vim.schedule(function() vim.cmd("qa!") end)
end

local original_notify = vim.notify
vim.notify = function(message, level, opts)
  append(result.notifications, { message = tostring(message), level = level, title = opts and opts.title or nil })
  if original_notify then original_notify(message, level, opts) end
end

local function ensure_nvim_dap_runtime()
  local ok = pcall(require, "dap")
  if ok then return true end
  local dap_root = vim.fn.stdpath("data") .. "/lazy/nvim-dap"
  if vim.fn.isdirectory(dap_root) == 0 then return false end
  vim.opt.runtimepath:prepend(dap_root)
  package.path = package.path .. ";" .. dap_root .. "/lua/?.lua" .. ";" .. dap_root .. "/lua/?/init.lua"
  return pcall(require, "dap")
end

local function cache_dir_for_engine(engine_root)
  return vim.fs.joinpath(engine_root, ".cache", "nvim-ue")
end

local function main()
  local ok_ue, ue = pcall(require, "ue")
  if not ok_ue then return finish("error", { error = "require('ue') failed: " .. tostring(ue) }) end
  if not ensure_nvim_dap_runtime() then return finish("error", { error = "nvim-dap not found" }) end
  local dap = require("dap")
  ue.setup()
  local smoke_dapui = { open = function() end, close = function() end, toggle = function() end, elements = {} }
  if type(ue.setup_dap) == "function" then ue.setup_dap(dap, smoke_dapui) end

  -- Open the target file but DO NOT toggle a breakpoint on it (no preseed).
  vim.opt.swapfile = false
  vim.cmd("silent edit " .. vim.fn.fnameescape(target_file))
  local target_bufnr = vim.api.nvim_get_current_buf()
  vim.api.nvim_win_set_cursor(0, { target_line, 0 })

  if vim.fn.isdirectory(project_root) == 0 then
    return finish("error", { error = "project root missing: " .. tostring(project_root) })
  end
  vim.cmd("silent cd " .. vim.fn.fnameescape(project_root))
  local current_project, current_engine, err = ue.ue_roots()
  if not current_project then
    return finish("error", { error = "UE project context missing: " .. tostring(err) })
  end
  result.engine_root = current_engine
  result.project_root = current_project

  local matches = vim.fn.globpath(current_project, "*.uproject", false, true)
  local ctx = {
    engine_root = current_engine,
    project_root = current_project,
    uproject = matches[1],
    android_serial = android_serial,
    android_symbol_lib = android_symbol_lib,
    state = {},
    paths = { cache = cache_dir_for_engine(current_engine) },
  }

  local listener_key = "ue-livebp-gate"
  local continued_once = false
  local live_planted = false
  local entry_timer = vim.uv and vim.uv.new_timer() or nil
  local entry_count = 0
  local pending_entry = nil

  -- Plant the breakpoint LIVE via the chosen channel, then trigger a
  -- `breakpoint list` to record resolved state, then arm a hit deadline.
  local function plant_live(session)
    if live_planted then return end
    live_planted = true
    result.live_plant_sent = true
    local basename = vim.fs.basename(target_file)

    if channel == "setbreakpoints" then
      event("live_plant_setbreakpoints", { file = basename, line = target_line })
      -- toggle the nvim-dap breakpoint now (mid-session) and push it
      pcall(function()
        require("dap.breakpoints").set({}, target_bufnr, target_line)
      end)
      pcall(function()
        session:set_breakpoints({ [target_bufnr] = require("dap.breakpoints").get(target_bufnr)[target_bufnr] })
      end)
      -- ask lldb to list breakpoints so we capture resolved=N
      session:request("evaluate",
        { expression = "`breakpoint list", context = "repl" },
        function(e, r) event("livebp_list_resp", { error = e and tostring(e) or nil, result = r and r.result or nil }) end)
    else
      -- evaluate backtick command channel: lldb-dap treats a leading backtick
      -- as a raw lldb command. Send `breakpoint set -f <file> -l <line>`.
      local cmd = ("`breakpoint set -f \"%s\" -l %d"):format(basename, target_line)
      event("live_plant_evaluate", { cmd = cmd })
      session:request("evaluate", { expression = cmd, context = "repl" }, function(e, r)
        event("livebp_set_resp", { error = e and tostring(e) or nil, result = r and r.result or nil })
        session:request("evaluate", { expression = "`breakpoint list", context = "repl" },
          function(e2, r2)
            event("livebp_list_resp", { error = e2 and tostring(e2) or nil, result = r2 and r2.result or nil })
            -- The evaluate result text also carries the resolved=N line.
            if r2 and r2.result then scan_resolved(r2.result) end
          end)
      end)
    end

    -- Hit deadline: if no breakpoint stop within hit_wait_ms after planting
    -- (while the app runs), conclude resolved-but-never-hits.
    vim.defer_fn(function()
      if done or result.saw_breakpoint then return end
      finish("live_no_hit", {
        error = "live breakpoint planted but no breakpoint stop within hit window",
        continued_once = continued_once,
        hit_wait_ms = hit_wait_ms,
      })
    end, hit_wait_ms)
  end

  local function request_continue(session, body)
    local tid = body and body.threadId or session.stopped_thread_id
    session:request("continue", { threadId = tid }, function(ce, cr)
      event("continue_response", { threadId = tid, error = ce and tostring(ce) or nil,
        response = cr or vim.NIL })
    end)
  end

  -- After the entry burst settles, continue once, then wait for steady state
  -- and plant the live breakpoint.
  local function continue_then_plant(session, body)
    pending_entry = body
    entry_count = entry_count + 1
    if not entry_timer then
      if not continued_once then continued_once = true; request_continue(session, body) end
      return
    end
    entry_timer:stop()
    entry_timer:start(1800, 0, function()
      entry_timer:stop()
      vim.schedule(function()
        if done or continued_once then return end
        continued_once = true
        event("continue_after_entry_burst", { entry_stop_count = entry_count })
        request_continue(session, pending_entry or body)
        -- Let the app run to steady render state, THEN plant live. The app is
        -- now executing the render loop, so a live breakpoint that truly arms
        -- will hit within a frame or two.
        vim.defer_fn(function()
          if done then return end
          local s = require("dap").session()
          if s then plant_live(s) end
        end, 4000)
      end)
    end)
  end

  dap.listeners.after.event_initialized[listener_key] = function(s) event("initialized", { session = tostring(s) }) end
  dap.listeners.after.event_continued[listener_key] = function(_, body) event("continued", body) end
  dap.listeners.after.event_output[listener_key] = function(_, body) capture_output(body and body.output or "") end

  dap.listeners.after.event_stopped[listener_key] = function(session, body)
    event("stopped", body)
    local hit = body.reason == "breakpoint"
      or (type(body.hitBreakpointIds) == "table" and #body.hitBreakpointIds > 0)
    if hit then
      result.saw_breakpoint = true
      -- capture the stop frame
      local tid = body.threadId or session.stopped_thread_id
      session:request("stackTrace", { threadId = tid, startFrame = 0, levels = 4 }, function(_se, sr)
        local frames = {}
        for _, fr in ipairs((sr and sr.stackFrames) or {}) do
          append(frames, { name = fr.name, line = fr.line,
            source = fr.source and fr.source.path or nil })
        end
        finish("ok", {
          stop = { reason = body.reason, hitBreakpointIds = body.hitBreakpointIds,
            threadId = tid, frames = frames },
          continued_once = continued_once,
        })
      end)
      return
    end
    local is_entry = body.reason == "entry"
      or tostring(body.description or ""):find("SIGSTOP", 1, true) ~= nil
    if is_entry then continue_then_plant(session, body); return end
    -- A non-entry, non-breakpoint stop after planting could mean the live
    -- breakpoint stopped us in an unexpected way; record but keep going.
    if not continued_once then
      continued_once = true
      vim.defer_fn(function() request_continue(session, body) end, 500)
    end
  end

  dap.listeners.before.event_terminated[listener_key] = function(_, body)
    finish(result.saw_breakpoint and "ok" or "terminated_before_hit", { terminated = body })
  end
  dap.listeners.before.event_exited[listener_key] = function(_, body)
    finish(result.saw_breakpoint and "ok" or "exited_before_hit", { exited = body })
  end

  local ok_android, android = pcall(require, "ue.dap.android")
  if not ok_android or type(android.attach) ~= "function" then
    return finish("error", { error = "ue.dap.android.attach missing: " .. tostring(android) })
  end
  event("android_attach_start", { serial = ctx.android_serial, symbol_lib = ctx.android_symbol_lib })
  android.attach({ context = ctx })

  vim.defer_fn(function()
    if done then return end
    finish("timeout", { error = ("Timed out after %d ms"):format(timeout_ms),
      continued_once = continued_once, live_planted = live_planted })
  end, timeout_ms)
end

main()
vim.wait(timeout_ms + 5000, function() return done end, 200)
if not done then finish("timeout", { error = "Timed out before completion" }) end
