-- tools/nvim_android_dap_livebp_e2e.lua
-- End-to-end verification of the PRODUCTION live-breakpoint path
-- (design android-dap-live-breakpoints, tasks 4.5).
--
-- Unlike the D1 gate (nvim_android_dap_livebp_gate.lua) which plants the
-- breakpoint with its OWN channel code, this harness drives the real user
-- flow: attach → continue past entry burst → toggle a breakpoint via
-- `dap.breakpoints` + `dap.session():set_breakpoints()` exactly as F9 does,
-- so the PRODUCTION `dap.listeners.after.setBreakpoints["ue_android_bp_local_response"]`
-- fires and routes through `ue_android_live_plant_via_evaluate`. We then watch
-- for the breakpoint stop and assert no :UEDAPReattach warning was emitted.
--
-- Success = stopped reason="breakpoint" + production diag lines present
--           ("active-session setBreakpoints → live evaluate plant") +
--           no "are not silently reattached" notification.
-- Failure-honest = production warns/notifies on resolved=0 (still no crash).
--
-- Result JSON: tools/evidence/android-f9/livebp-e2e.result.json

local json = vim.json
local start_cwd = vim.fn.getcwd()

local function is_absolute_path(path)
  return path:match("^%a:[/\\]") ~= nil or path:match("^[/\\][/\\]") ~= nil or path:sub(1, 1) == "/"
end

local configured_result_path = vim.env.NVIM_DAP_SMOKE_RESULT
  or "tools/evidence/android-f9/livebp-e2e.result.json"
local result_path = is_absolute_path(configured_result_path) and configured_result_path
  or vim.fs.joinpath(start_cwd, configured_result_path)

local target_file = vim.env.NVIM_DAP_SMOKE_FILE
local target_line = tonumber(vim.env.NVIM_DAP_SMOKE_LINE or "1367") or 1367
local project_root = vim.env.NVIM_DAP_SMOKE_PROJECT
local android_serial = vim.env.NVIM_DAP_SMOKE_SERIAL
local android_symbol_lib = vim.env.NVIM_DAP_SMOKE_SYMBOL_LIB
local timeout_ms = tonumber(vim.env.NVIM_DAP_SMOKE_TIMEOUT_MS or "240000") or 240000
local hit_wait_ms = tonumber(vim.env.NVIM_DAP_LIVEBP_HITWAIT_MS or "20000") or 20000

local result = {
  status = "running",
  gate = "live-breakpoint-e2e-production",
  target = { file = target_file, line = target_line, project_root = project_root },
  live_plant_sent = false,
  saw_breakpoint = false,
  adapter_alive = nil,
  production_live_plant_diag = false,
  saw_reattach_warning = false,
  events = {},
  notifications = {},
}

local done = false
local function append(list, value) list[#list + 1] = value end
local function event(name, payload) append(result.events, { name = name, payload = payload or vim.NIL }) end

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

local function scan_diag_for_production_plant()
  -- Inspect the production diag log to confirm the real listener routed the
  -- session-time change through the live evaluate channel.
  local path = vim.fn.stdpath("cache") .. "/ue-dap-bp-diag.log"
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok or type(lines) ~= "table" then return end
  for _, l in ipairs(lines) do
    if tostring(l):find("active-session setBreakpoints", 1, true)
      and tostring(l):find("live evaluate plant", 1, true) then
      result.production_live_plant_diag = true
    end
  end
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
  local ok, dap = pcall(require, "dap")
  result.adapter_alive = ok and dap.session and dap.session() ~= nil or false
  scan_diag_for_production_plant()
  cleanup()
  write_result()
  vim.schedule(function() vim.cmd("qa!") end)
end

local original_notify = vim.notify
vim.notify = function(message, level, opts)
  local msg = tostring(message)
  append(result.notifications, { message = msg, level = level, title = opts and opts.title or nil })
  if msg:find("are not silently reattached", 1, true) then
    result.saw_reattach_warning = true
  end
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

  local listener_key = "ue-livebp-e2e"
  local continued_once = false
  local live_planted = false
  local entry_timer = vim.uv and vim.uv.new_timer() or nil
  local entry_count = 0
  local pending_entry = nil

  -- Drive the REAL F9 flow: toggle breakpoint in nvim-dap store then push via
  -- session:set_breakpoints — this is exactly what the F9 keymap does, so the
  -- production after.setBreakpoints listener fires and plants live.
  local function plant_like_f9(session)
    if live_planted then return end
    live_planted = true
    result.live_plant_sent = true
    event("f9_toggle", { file = vim.fs.basename(target_file), line = target_line })
    pcall(function() require("dap.breakpoints").set({}, target_bufnr, target_line) end)
    pcall(function()
      local bps = require("dap.breakpoints").get(target_bufnr)
      session:set_breakpoints({ [target_bufnr] = bps[target_bufnr] })
    end)
    vim.defer_fn(function()
      if done or result.saw_breakpoint then return end
      finish("live_no_hit", {
        error = "production live plant sent but no breakpoint stop within hit window",
        continued_once = continued_once, hit_wait_ms = hit_wait_ms,
      })
    end, hit_wait_ms)
  end

  local function request_continue(session, body)
    local tid = body and body.threadId or session.stopped_thread_id
    session:request("continue", { threadId = tid }, function(ce)
      event("continue_response", { threadId = tid, error = ce and tostring(ce) or nil })
    end)
  end

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
        vim.defer_fn(function()
          if done then return end
          local s = require("dap").session()
          if s then plant_like_f9(s) end
        end, 4000)
      end)
    end)
  end

  dap.listeners.after.event_initialized[listener_key] = function(s) event("initialized", { session = tostring(s) }) end
  dap.listeners.after.event_continued[listener_key] = function(_, body) event("continued", body) end

  dap.listeners.after.event_stopped[listener_key] = function(session, body)
    event("stopped", body)
    local hit = body.reason == "breakpoint"
      or (type(body.hitBreakpointIds) == "table" and #body.hitBreakpointIds > 0)
    if hit then
      result.saw_breakpoint = true
      local tid = body.threadId or session.stopped_thread_id
      session:request("stackTrace", { threadId = tid, startFrame = 0, levels = 4 }, function(_se, sr)
        local frames = {}
        for _, fr in ipairs((sr and sr.stackFrames) or {}) do
          append(frames, { name = fr.name, line = fr.line, source = fr.source and fr.source.path or nil })
        end
        finish("ok", {
          stop = { reason = body.reason, hitBreakpointIds = body.hitBreakpointIds, threadId = tid, frames = frames },
          continued_once = continued_once,
        })
      end)
      return
    end
    local is_entry = body.reason == "entry"
      or tostring(body.description or ""):find("SIGSTOP", 1, true) ~= nil
    if is_entry then continue_then_plant(session, body); return end
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
