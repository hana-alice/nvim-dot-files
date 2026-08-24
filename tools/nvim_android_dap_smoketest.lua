local json = vim.json

local start_cwd = vim.fn.getcwd()
local configured_result_path = vim.env.NVIM_DAP_SMOKE_RESULT or "tools/nvim_android_dap_smoketest.result.json"
local function is_absolute_path(path)
  return path:match("^%a:[/\\]") ~= nil
    or path:match("^[/\\][/\\]") ~= nil
    or path:sub(1, 1) == "/"
end

local result_path = is_absolute_path(configured_result_path)
    and configured_result_path
  or vim.fs.joinpath(start_cwd, configured_result_path)
local target_file = vim.env.NVIM_DAP_SMOKE_FILE
  or "D:/UE/EngineRoot/Engine/Source/Runtime/Launch/Private/LaunchEngineLoop.cpp"
local target_line = tonumber(vim.env.NVIM_DAP_SMOKE_LINE or "4829") or 4829
local project_root = vim.env.NVIM_DAP_SMOKE_PROJECT or "D:/UE/ProjectRoot"
local android_serial = vim.env.NVIM_DAP_SMOKE_SERIAL
local android_package = vim.env.NVIM_DAP_SMOKE_PACKAGE
local android_symbol_lib = vim.env.NVIM_DAP_SMOKE_SYMBOL_LIB
local android_build_root = vim.env.NVIM_DAP_SMOKE_BUILD_ROOT
local timeout_ms = tonumber(vim.env.NVIM_DAP_SMOKE_TIMEOUT_MS or "90000") or 90000

local result = {
  status = "running",
  target = {
    file = target_file,
    line = target_line,
    project_root = project_root,
  },
  events = {},
  lldb_outputs = {},
  notifications = {},
}

local done = false
local collecting_target_image_lookup = false

local function ensure_nvim_dap_runtime()
  local ok = pcall(require, "dap")
  if ok then
    return true
  end
  local dap_root = vim.fn.stdpath("data") .. "/lazy/nvim-dap"
  if vim.fn.isdirectory(dap_root) == 0 then
    return false
  end
  vim.opt.runtimepath:prepend(dap_root)
  package.path = package.path
    .. ";" .. dap_root .. "/lua/?.lua"
    .. ";" .. dap_root .. "/lua/?/init.lua"
  return pcall(require, "dap")
end

local function append(list, value)
  list[#list + 1] = value
end

local function append_lldb_output(output)
  if type(output) ~= "string" or output == "" then
    return
  end
  local trimmed = output:gsub("[\r\n]+$", "")
  if trimmed == "" then
    return
  end
  if trimmed:find("breakpoint", 1, true)
      or trimmed:find("Breakpoint", 1, true)
      or trimmed:find("MobileShadingRenderer.cpp", 1, true)
      or trimmed:find("image lookup", 1, true)
      or trimmed:find("FMobileSceneRenderer", 1, true)
      or trimmed:find("hit count", 1, true)
      or trimmed:find("libUE4.so", 1, true) then
    append(result.lldb_outputs, trimmed)
  end
end

local function remember_breakpoint_summary(line)
  if type(line) ~= "string" then
    return
  end
  local id, file, requested_line, exact_match, locations, resolved, hit_count =
    line:match("^(%d+): file = '([^']+)', line = (%d+), exact_match = (%d+), locations = (%d+), resolved = (%d+), hit count = (%d+)")
  if id then
    result.breakpoint_summary = result.breakpoint_summary or {}
    result.breakpoint_summary[#result.breakpoint_summary + 1] = {
      id = tonumber(id),
      file = file,
      requested_line = tonumber(requested_line),
      exact_match = tonumber(exact_match),
      locations = tonumber(locations),
      resolved = tonumber(resolved),
      hit_count = tonumber(hit_count),
    }
    return
  end

  local parent, loc, where, address, loc_hit_count =
    line:match("^%s*(%d+)%.(%d+): where = (.-), address = (0x%x+), resolved, hit count = (%d+)")
  if parent then
    result.breakpoint_locations = result.breakpoint_locations or {}
    local resolved_file, resolved_line, resolved_column =
      where:match(" at ([^:]+):(%d+):(%d+)$")
    result.breakpoint_locations[#result.breakpoint_locations + 1] = {
      id = tonumber(parent),
      location = tonumber(loc),
      where = where,
      address = address,
      resolved_file = resolved_file,
      resolved_line = tonumber(resolved_line),
      resolved_column = tonumber(resolved_column),
      hit_count = tonumber(loc_hit_count),
    }
  end
end

local function remember_image_lookup(line)
  if type(line) ~= "string" then
    return
  end
  if line:find("(lldb) image lookup --file", 1, true) then
    collecting_target_image_lookup = true
    result.image_lookup = {
      addresses = {},
      summaries = {},
    }
    return
  end
  if line:find("(lldb)", 1, true) and not line:find("image lookup --file", 1, true) then
    collecting_target_image_lookup = false
  end
  local count, file, line_no, image =
    line:match("^(%d+) matches found in ([^:]+):(%d+) in (.+):$")
  if count then
    collecting_target_image_lookup = true
    result.image_lookup = result.image_lookup or {}
    result.image_lookup.match_count = tonumber(count)
    result.image_lookup.file = file
    result.image_lookup.line = tonumber(line_no)
    result.image_lookup.image = image
    return
  end
  local address = line:match("^%s*Address: libUE4%.so%[(0x%x+)%]")
  if collecting_target_image_lookup and address then
    result.image_lookup = result.image_lookup or {}
    result.image_lookup.addresses = result.image_lookup.addresses or {}
    result.image_lookup.addresses[#result.image_lookup.addresses + 1] = address
    return
  end
  local summary = line:match("^%s*Summary: (.+)$")
  if collecting_target_image_lookup and summary and summary:find("MobileShadingRenderer.cpp", 1, true) then
    result.image_lookup = result.image_lookup or {}
    result.image_lookup.summaries = result.image_lookup.summaries or {}
    result.image_lookup.summaries[#result.image_lookup.summaries + 1] = summary
  end
end

local function capture_lldb_output(output)
  append_lldb_output(output)
  for _, line in ipairs(vim.split(output, "\n", { plain = true, trimempty = true })) do
    line = line:gsub("\r$", "")
    remember_breakpoint_summary(line)
    remember_image_lookup(line)
  end
end

local function encode(value)
  local ok, encoded = pcall(json.encode, value)
  if ok then
    return encoded
  end
  return json.encode({
    status = "encode_error",
    error = tostring(encoded),
  })
end

local function write_result()
  local dir = vim.fn.fnamemodify(result_path, ":h")
  if dir and dir ~= "" then
    vim.fn.mkdir(dir, "p")
  end
  vim.fn.writefile({ encode(result) }, result_path)
end

local function cleanup_dap_session()
  local ok, dap = pcall(require, "dap")
  if not ok or not dap.session or not dap.session() then
    return
  end
  pcall(dap.disconnect, { terminateDebuggee = false })
end

local function finish(status, extra)
  if done then
    return
  end
  done = true
  result.status = status
  if extra then
    for key, value in pairs(extra) do
      result[key] = value
    end
  end
  if status ~= "ok" then
    cleanup_dap_session()
  end
  write_result()
  vim.schedule(function()
    vim.cmd("qa!")
  end)
end

local function event(name, payload)
  append(result.events, {
    name = name,
    payload = payload or vim.NIL,
  })
end

local original_notify = vim.notify
vim.notify = function(message, level, opts)
  append(result.notifications, {
    message = tostring(message),
    level = level,
    title = opts and opts.title or nil,
  })
  if original_notify then
    original_notify(message, level, opts)
  end
end

local function merge_frame(frame)
  if not frame then
    return nil
  end
  return {
    id = frame.id,
    name = frame.name,
    line = frame.line,
    column = frame.column,
    source = frame.source and frame.source.path or nil,
  }
end

local function cache_dir_for_engine(engine_root)
  local override = vim.fs.normalize(vim.env.UE_NVIM_CACHE_ROOT or vim.env.UE_NVIM_CACHE_DIR or "")
  if override == "" then
    return vim.fs.joinpath(engine_root, ".cache", "nvim-ue")
  end
  local suffix = engine_root:gsub("^[A-Za-z]:", function(prefix)
    return prefix:sub(1, 1)
  end)
  suffix = suffix:gsub("[^%w%._-]+", "_")
  suffix = suffix:gsub("_+", "_")
  suffix = suffix:gsub("^_+", ""):gsub("_+$", "")
  if suffix == "" then
    suffix = "engine"
  end
  return vim.fs.joinpath(override, suffix)
end

local function setup_target()
  vim.opt.swapfile = false
  vim.opt.writebackup = false
  vim.opt.backup = false
  vim.cmd("silent edit " .. vim.fn.fnameescape(target_file))
  vim.api.nvim_win_set_cursor(0, { target_line, 0 })
end

local function ensure_project(ue)
  if project_root and project_root ~= "" then
    if vim.fn.isdirectory(project_root) == 0 then
      return nil, nil, "configured project root does not exist: " .. project_root
    end
    vim.cmd("silent cd " .. vim.fn.fnameescape(project_root))
    local current_project, current_engine, err = ue.ue_roots()
    if current_project then
      return current_project, current_engine
    end
    return nil, current_engine, err
  end

  local current_project, current_engine, err = ue.ue_roots()
  if current_project then
    return current_project, current_engine
  end
  event("detect_project_from_cwd", { error = err, project_root = project_root })
  vim.cmd("silent cd " .. vim.fn.fnameescape(project_root))
  current_project, current_engine, err = ue.ue_roots()
  if current_project then
    return current_project, current_engine
  end
  return nil, current_engine, err
end

local function make_context(current_project, current_engine)
  local matches = vim.fn.globpath(current_project, "*.uproject", false, true)
  return {
    engine_root = current_engine,
    project_root = current_project,
    uproject = matches[1],
    android_serial = android_serial,
    android_package = android_package,
    android_symbol_lib = android_symbol_lib,
    android_build_root = android_build_root,
    state = {},
    paths = {
      cache = cache_dir_for_engine(current_engine),
    },
  }
end

local function run_preflight(session)
  local system = vim.system(session.preflight_cmd, {
    text = true,
    cwd = vim.fn.getcwd(),
  }):wait()
  return system.code or 0, (system.stdout or "") .. (system.stderr or "")
end

local function main()
  local ok_ue, ue = pcall(require, "ue")
  if not ok_ue then
    return finish("error", { error = "require('ue') failed: " .. tostring(ue) })
  end
  if not ensure_nvim_dap_runtime() then
    return finish("error", { error = "nvim-dap not found under stdpath('data')/lazy/nvim-dap" })
  end
  local dap = require("dap")
  ue.setup()
  local smoke_dapui = {
    open = function() end,
    close = function() end,
    toggle = function() end,
    elements = {},
  }
  if type(ue.setup_dap) == "function" then
    ue.setup_dap(dap, smoke_dapui)
  end

  setup_target()
  local current_project, current_engine, err = ensure_project(ue)
  if not current_project then
    return finish("error", {
      error = "UE project context is missing: " .. tostring(err),
      engine_root = current_engine,
    })
  end

  result.engine_root = current_engine
  result.project_root = current_project
  local ctx = make_context(current_project, current_engine)
  result.cache_dir = ctx.paths.cache

  local listener_key = "ue-smoke-test"
  local saw_breakpoint = false
  local continued_once = false
  local entry_continue_timer = vim.uv and vim.uv.new_timer() or nil
  local pending_entry_body = nil
  local entry_stop_count = 0
  local captured_stop = nil

  local function request_scopes(session, frame_id)
    if not frame_id then
      return finish("ok", {
        saw_breakpoint = saw_breakpoint,
        continued_once = continued_once,
        session_active = dap.session() ~= nil,
        stop = captured_stop,
      })
    end
    session:request("scopes", { frameId = frame_id }, function(scopes_err, scopes_resp)
      captured_stop.scopes_error = scopes_err and tostring(scopes_err) or nil
      captured_stop.scopes = {}
      for _, scope in ipairs((scopes_resp and scopes_resp.scopes) or {}) do
        append(captured_stop.scopes, {
          name = scope.name,
          expensive = scope.expensive,
          variablesReference = scope.variablesReference,
        })
      end
      finish("ok", {
        saw_breakpoint = saw_breakpoint,
        continued_once = continued_once,
        session_active = dap.session() ~= nil,
        stop = captured_stop,
      })
    end)
  end

  local function capture_stop(session, body)
    local thread_id = body.threadId or session.stopped_thread_id
    session:request("stackTrace", { threadId = thread_id, startFrame = 0, levels = 8 }, function(stack_err, stack_resp)
      local frames = {}
      for _, frame in ipairs((stack_resp and stack_resp.stackFrames) or {}) do
        append(frames, merge_frame(frame))
      end
      captured_stop = {
        reason = body.reason,
        description = body.description,
        text = body.text,
        threadId = thread_id,
        hitBreakpointIds = body.hitBreakpointIds,
        stack_error = stack_err and tostring(stack_err) or nil,
        frames = frames,
      }
      request_scopes(session, frames[1] and frames[1].id or nil)
    end)
  end

  local function request_continue(session, body)
    local thread_id = body.threadId or session.stopped_thread_id
    session:request("continue", { threadId = thread_id }, function(continue_err, continue_resp)
      event("continue_response", {
        threadId = thread_id,
        error = continue_err and tostring(continue_err) or nil,
        response = continue_resp or vim.NIL,
      })
    end)
  end

  local function schedule_continue_after_entry_burst(session, body)
    pending_entry_body = body
    entry_stop_count = entry_stop_count + 1
    if not entry_continue_timer then
      if not continued_once then
        continued_once = true
        request_continue(session, body)
      end
      return
    end
    entry_continue_timer:stop()
    entry_continue_timer:start(1500, 0, function()
      entry_continue_timer:stop()
      vim.schedule(function()
        if done or continued_once then
          return
        end
        continued_once = true
        event("continue_after_entry_burst", {
          entry_stop_count = entry_stop_count,
          reason = pending_entry_body and pending_entry_body.reason or nil,
          threadId = pending_entry_body and pending_entry_body.threadId or nil,
        })
        request_continue(session, pending_entry_body or body)
      end)
    end)
  end

  dap.listeners.after.event_initialized[listener_key] = function(session)
    event("initialized", { session = tostring(session) })
  end

  dap.listeners.after.event_continued[listener_key] = function(_, body)
    event("continued", body)
  end

  dap.listeners.after.event_output[listener_key] = function(_, body)
    capture_lldb_output(body and body.output or "")
  end

  dap.listeners.after.setBreakpoints[listener_key] = function(_, err, response)
    result.dap_set_breakpoints = {
      error = err and tostring(err) or nil,
      response = response or vim.NIL,
    }
  end

  dap.listeners.after.event_stopped[listener_key] = function(session, body)
    event("stopped", body)
    local hit_breakpoint = body.reason == "breakpoint"
      or (type(body.hitBreakpointIds) == "table" and #body.hitBreakpointIds > 0)
    if hit_breakpoint then
      saw_breakpoint = true
      return capture_stop(session, body)
    end

    local is_attach_entry_stop = body.reason == "entry"
      or tostring(body.description or ""):find("SIGSTOP", 1, true) ~= nil
    if is_attach_entry_stop then
      schedule_continue_after_entry_burst(session, body)
      return
    end

    if not continued_once then
      continued_once = true
      vim.defer_fn(function()
        event("continue_after_initial_stop", { reason = body.reason })
        request_continue(session, body)
      end, 800)
      return
    end
    finish("error", {
      error = "Unexpected non-breakpoint stop after continue",
      stop = {
        reason = body.reason,
        description = body.description,
        text = body.text,
      },
    })
  end

  dap.listeners.before.event_terminated[listener_key] = function(_, body)
    if not saw_breakpoint then
      finish("error", {
        error = "DAP session terminated before hitting breakpoint",
        terminated = body,
      })
    end
  end

  dap.listeners.before.event_exited[listener_key] = function(_, body)
    if not saw_breakpoint then
      finish("error", {
        error = "DAP session exited before hitting breakpoint",
        exited = body,
      })
    end
  end

  ue.dap_toggle_breakpoint()
  event("breakpoint_queued", {
    file = target_file,
    line = target_line,
  })

  local ok_android, android = pcall(require, "ue.dap.android")
  if not ok_android or type(android.attach) ~= "function" then
    return finish("error", {
      error = "require('ue.dap.android').attach failed: " .. tostring(android),
    })
  end
  event("android_attach_start", {
    serial = ctx.android_serial,
    package = ctx.android_package,
    symbol_lib = ctx.android_symbol_lib,
  })
  android.attach({ context = ctx })

  vim.defer_fn(function()
    if done then
      return
    end
    finish("timeout", {
      error = ("Timed out after %d ms"):format(timeout_ms),
      saw_breakpoint = saw_breakpoint,
      continued_once = continued_once,
      session_active = dap.session() ~= nil,
    })
  end, timeout_ms)
end

main()
vim.wait(timeout_ms + 5000, function()
  return done
end, 200)
if not done then
  finish("timeout", {
    error = ("Timed out after %d ms before completion"):format(timeout_ms),
  })
end
