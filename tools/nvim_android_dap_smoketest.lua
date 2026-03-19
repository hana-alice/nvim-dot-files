local json = vim.json

local result_path = vim.env.NVIM_DAP_SMOKE_RESULT or "tools/nvim_android_dap_smoketest.result.json"
local target_file = vim.env.NVIM_DAP_SMOKE_FILE
  or "D:/UE/EngineRoot/Engine/Source/Runtime/Launch/Private/LaunchEngineLoop.cpp"
local target_line = tonumber(vim.env.NVIM_DAP_SMOKE_LINE or "4829") or 4829
local project_root = vim.env.NVIM_DAP_SMOKE_PROJECT or "D:/UE/ProjectRoot"
local timeout_ms = tonumber(vim.env.NVIM_DAP_SMOKE_TIMEOUT_MS or "90000") or 90000

local result = {
  status = "running",
  target = {
    file = target_file,
    line = target_line,
    project_root = project_root,
  },
  events = {},
  notifications = {},
}

local done = false

local function append(list, value)
  list[#list + 1] = value
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
  vim.fn.writefile({ encode(result) }, result_path)
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
  ue.setup()

  local ok_dap, dap = pcall(require, "dap")
  if not ok_dap then
    return finish("error", { error = "require('dap') failed: " .. tostring(dap) })
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
  local captured_stop = nil

  local function request_scopes(session, frame_id)
    if not frame_id then
      return finish("ok", {
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

  dap.listeners.after.event_initialized[listener_key] = function(session)
    event("initialized", { session = tostring(session) })
  end

  dap.listeners.after.event_continued[listener_key] = function(_, body)
    event("continued", body)
  end

  dap.listeners.after.event_stopped[listener_key] = function(session, body)
    event("stopped", body)
    local hit_breakpoint = body.reason == "breakpoint"
      or (type(body.hitBreakpointIds) == "table" and #body.hitBreakpointIds > 0)
    if hit_breakpoint then
      saw_breakpoint = true
      return capture_stop(session, body)
    end
    if not continued_once then
      continued_once = true
      vim.defer_fn(function()
        event("continue_after_initial_stop", { reason = body.reason })
        dap.continue()
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

  local session, session_err = ue.android_platform_lldb_session(ctx)
  if not session then
    return finish("error", {
      error = "android_platform_lldb_session failed: " .. tostring(session_err),
    })
  end
  event("preflight_start")
  local code, output = run_preflight(session)
  result.preflight = {
    code = code,
    output_tail = vim.split(output, "\n", { plain = true, trimempty = true }),
  }
  if #result.preflight.output_tail > 60 then
    result.preflight.output_tail = vim.list_slice(result.preflight.output_tail, #result.preflight.output_tail - 59, #result.preflight.output_tail)
  end
  if code ~= 0 then
    return finish("error", {
      error = ("preflight failed with exit code %d"):format(code),
    })
  end
  event("preflight_done")
  ue.run_android_dap_session(ctx, session)

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
