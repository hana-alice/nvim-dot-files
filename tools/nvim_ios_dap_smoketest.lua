-- Real-device Nvim DAP probe for the production iOS handler.
--
-- Required environment:
--   NVIM_IOS_DAP_SMOKE_MODE=launch|attach
--   NVIM_IOS_DAP_SMOKE_DEVICE=<Apple device identifier>
--   NVIM_IOS_DAP_SMOKE_BACKEND=coredevice
--   NVIM_IOS_DAP_SMOKE_BUNDLE=com.example.game
--   NVIM_IOS_DAP_SMOKE_BINARY=/absolute/path/to/local/MachO
--   NVIM_IOS_DAP_SMOKE_DSYM=/absolute/path/to/local.dSYM
--   NVIM_IOS_DAP_SMOKE_SOURCE=/absolute/source.cpp
--   NVIM_IOS_DAP_SMOKE_LINE=123
-- Optional:
--   NVIM_IOS_DAP_SMOKE_PID=4242
--   NVIM_IOS_DAP_SMOKE_PROJECT=/absolute/project/or.uproject
--   NVIM_IOS_DAP_SMOKE_CWD=/absolute/working/dir
--   NVIM_IOS_DAP_SMOKE_EXPR="1 + 2"
--   NVIM_IOS_DAP_SMOKE_RESULT=/tmp/ios-dap.json
--   NVIM_IOS_DAP_SMOKE_TIMEOUT_MS=120000

local mode = tostring(vim.env.NVIM_IOS_DAP_SMOKE_MODE or "")
local device_id = tostring(vim.env.NVIM_IOS_DAP_SMOKE_DEVICE or "")
local backend = tostring(vim.env.NVIM_IOS_DAP_SMOKE_BACKEND or "")
local bundle_id = tostring(vim.env.NVIM_IOS_DAP_SMOKE_BUNDLE or "")
local binary_path = tostring(vim.env.NVIM_IOS_DAP_SMOKE_BINARY or "")
local dsym_path = tostring(vim.env.NVIM_IOS_DAP_SMOKE_DSYM or "")
local target_source = tostring(vim.env.NVIM_IOS_DAP_SMOKE_SOURCE or "")
local target_line = tonumber(vim.env.NVIM_IOS_DAP_SMOKE_LINE or "")
local target_pid = tonumber(vim.env.NVIM_IOS_DAP_SMOKE_PID or "")
local project_input = tostring(vim.env.NVIM_IOS_DAP_SMOKE_PROJECT or "")
local explicit_cwd = tostring(vim.env.NVIM_IOS_DAP_SMOKE_CWD or "")
local expression = tostring(vim.env.NVIM_IOS_DAP_SMOKE_EXPR or "1 + 2")
local result_path = tostring(vim.env.NVIM_IOS_DAP_SMOKE_RESULT or "/tmp/nvim-ios-dap-smoke.json")
local timeout_ms = tonumber(vim.env.NVIM_IOS_DAP_SMOKE_TIMEOUT_MS or "120000") or 120000

local result = {
  status = "running",
  mode = mode,
  backend = backend,
  target = { source = target_source, line = target_line },
  identity = {
    device_id = device_id,
    bundle_id = bundle_id,
    pid = target_pid,
    binary = binary_path,
    dsym = dsym_path,
    project = project_input,
    cwd = explicit_cwd,
    expression = expression,
  },
  events = {},
  notifications = {},
  adapter_output = {},
}
local done = false
local cleaning = false
local breakpoint_added = false
local target_buf = nil
local project_info = nil
local smoke_cwd = nil
local handler_started = false

local function append(list, value)
  list[#list + 1] = value
end

local function trim(value)
  return vim.trim(tostring(value or ""))
end

local function short_digest(value)
  local ok, digest = pcall(vim.fn.sha256, tostring(value or ""))
  if ok and type(digest) == "string" and digest ~= "" then
    return digest:sub(1, 12)
  end
  return "sha256-unavailable"
end

local function path_exists(path)
  local normalized = trim(path)
  return normalized ~= "" and (vim.fn.filereadable(normalized) == 1 or vim.fn.isdirectory(normalized) == 1)
end

local function path_evidence(path)
  local normalized = trim(path)
  if normalized == "" then
    return nil
  end
  return {
    name = vim.fs.basename(normalized),
    digest = short_digest("path:" .. normalized),
  }
end

local function string_digest(label, value)
  local normalized = trim(value)
  if normalized == "" then
    return nil
  end
  return short_digest(label .. ":" .. normalized)
end

local function numeric_digest(label, value)
  local number = tonumber(value)
  if not number or number <= 0 then
    return nil
  end
  return short_digest(label .. ":" .. tostring(number))
end

local function replace_literal(text, needle, replacement)
  local rendered = tostring(text or "")
  local target = tostring(needle or "")
  if target == "" then
    return rendered
  end
  local start = 1
  while true do
    local first, last = rendered:find(target, start, true)
    if not first then
      break
    end
    rendered = rendered:sub(1, first - 1) .. replacement .. rendered:sub(last + 1)
    start = first + #replacement
  end
  return rendered
end

local function redact_text(value)
  local rendered = tostring(value or "")
  local sensitive = {
    device_id,
    bundle_id,
    target_pid and tostring(target_pid) or nil,
    binary_path,
    dsym_path,
    target_source,
    project_info and project_info.project_root or project_input,
    project_info and project_info.uproject or nil,
    smoke_cwd or explicit_cwd,
  }
  table.sort(sensitive, function(left, right)
    return #tostring(left or "") > #tostring(right or "")
  end)
  for _, item in ipairs(sensitive) do
    local normalized = trim(item)
    if normalized ~= "" then
      rendered = replace_literal(rendered, normalized, "<redacted>")
    end
  end
  local home = trim((vim.uv.os_homedir and vim.uv.os_homedir()) or "")
  if home ~= "" then
    rendered = replace_literal(rendered, home, "<redacted-path>")
  end
  rendered = rendered:gsub("/[Uu]sers/[^/%s]+/[^%s,;]+", "<redacted-path>")
  rendered = rendered:gsub("[A-Za-z]:/[Uu]sers/[^/%s]+/[^%s,;]+", "<redacted-path>")
  return rendered
end

local function error_code(message)
  local slug = trim(message):lower():gsub("[^a-z0-9]+", "-"):gsub("^%-+", ""):gsub("%-+$", "")
  if slug == "" then
    return "error"
  end
  if #slug > 48 then
    slug = slug:sub(1, 48):gsub("%-+$", "")
  end
  return slug
end

local function error_evidence(message)
  local rendered = trim(message)
  if rendered == "" then
    return nil
  end
  return {
    code = error_code(rendered),
    message = redact_text(rendered),
  }
end

local function sanitize_notification(entry)
  return {
    message = redact_text(entry.message),
    level = entry.level,
    title = entry.title and redact_text(entry.title) or nil,
  }
end

local function sanitize_event(entry)
  local name = entry.name or "event"
  if name == "initialized" then
    return { name = name, config_digest = string_digest("config", entry.config) }
  end
  if name == "setBreakpoints" then
    local breakpoints = {}
    for _, breakpoint in ipairs(entry.breakpoints or {}) do
      append(breakpoints, {
        id_digest = numeric_digest("breakpoint", breakpoint.id),
        verified = breakpoint.verified == true,
        line = tonumber(breakpoint.line),
        message = breakpoint.message and redact_text(breakpoint.message) or nil,
      })
    end
    return {
      name = name,
      error = error_evidence(entry.error),
      breakpoints = breakpoints,
    }
  end
  if name == "stopped" then
    return {
      name = name,
      reason = entry.reason,
      description = entry.description and redact_text(entry.description) or nil,
      thread_digest = numeric_digest("thread", entry.threadId),
      hit_breakpoint_count = type(entry.hitBreakpointIds) == "table" and #entry.hitBreakpointIds or 0,
    }
  end
  if name == "continue" then
    return { name = name, error = error_evidence(entry.error) }
  end
  if name == "start" then
    return { name = name, mode = entry.mode }
  end
  return {
    name = name,
    error = error_evidence(entry.error),
    summary = redact_text(vim.inspect(entry)),
  }
end

local function sanitize_frame(frame)
  if type(frame) ~= "table" then
    return nil
  end
  return {
    id_digest = numeric_digest("frame", frame.id),
    source = path_evidence(frame.source),
    line = tonumber(frame.line),
  }
end

local function serialize_result()
  local frames = {}
  for _, frame in ipairs(result.frames or {}) do
    local sanitized = sanitize_frame(frame)
    if sanitized then
      append(frames, sanitized)
    end
  end
  return {
    schema = "ue-ios-production-dap-smoke-v1",
    status = result.status,
    mode = result.mode,
    backend = result.backend,
    target = {
      source = path_evidence(result.target.source),
      line = result.target.line,
    },
    identity = {
      device_digest = string_digest("device", result.identity.device_id),
      bundle_digest = string_digest("bundle", result.identity.bundle_id),
      pid_digest = numeric_digest("pid", result.identity.pid),
      binary = path_evidence(result.identity.binary),
      dsym = path_evidence(result.identity.dsym),
      project = path_evidence(result.identity.project),
      cwd = path_evidence(result.identity.cwd),
      expression_digest = string_digest("expr", result.identity.expression),
    },
    verified_breakpoint = result.verified_breakpoint == true,
    loaded_image_uuid_match = result.loaded_image_uuid_match == true,
    breakpoint_stop = result.breakpoint_stop == true,
    exact_source_frame = result.exact_source_frame == true,
    stop_reason = result.stop_reason,
    source_frame = result.source_frame and {
      source = path_evidence(result.source_frame.source),
      line = result.source_frame.line,
    } or nil,
    stack_error = error_evidence(result.stack_error),
    evaluation = result.evaluation and {
      ok = result.evaluation.ok == true,
      error = error_evidence(result.evaluation.error),
      result_digest = string_digest("eval-result", result.evaluation.result),
      type_digest = string_digest("eval-type", result.evaluation.type),
    } or nil,
    cleanup = result.cleanup and {
      ok = result.cleanup.ok == true,
      error = error_evidence(result.cleanup.error),
    } or nil,
    error = error_evidence(result.error),
    events = vim.tbl_map(sanitize_event, result.events),
    notifications = vim.tbl_map(sanitize_notification, result.notifications),
    adapter_output = vim.tbl_map(redact_text, result.adapter_output),
    frames = frames,
  }
end

local original_notify = vim.notify
vim.notify = function(message, level, opts)
  append(result.notifications, {
    message = tostring(message),
    level = level,
    title = opts and opts.title or nil,
  })
  if handler_started and level == vim.log.levels.ERROR then
    result.startup_error = tostring(message)
  end
  return original_notify(message, level, opts)
end

local function write_result()
  vim.fn.mkdir(vim.fn.fnamemodify(result_path, ":h"), "p")
  vim.fn.writefile({ vim.json.encode(serialize_result()) }, result_path)
end

local function restore_breakpoint()
  if breakpoint_added and target_buf and vim.api.nvim_buf_is_valid(target_buf) then
    pcall(require("dap.breakpoints").remove, target_buf, target_line)
  end
end

local function finish(status, fields)
  if done then
    return
  end
  done = true
  result.status = status
  for key, value in pairs(fields or {}) do
    result[key] = value
  end
  restore_breakpoint()
  write_result()
  vim.schedule(function()
    vim.cmd("qa!")
  end)
end

local function stop_and_finish(status, fields)
  if cleaning then
    return
  end
  cleaning = true
  require("ue.dap.ios").stop({
    on_done = function(ok, err)
      fields = fields or {}
      fields.cleanup = { ok = ok, error = err }
      finish(ok and status or "cleanup_error", fields)
    end,
  })
end

local function resolve_project()
  local normalized = trim(project_input)
  if normalized == "" then
    return nil
  end
  local resolved = vim.fs.normalize(normalized)
  if resolved:sub(-9) == ".uproject" then
    if vim.fn.filereadable(resolved) ~= 1 then
      return nil, "NVIM_IOS_DAP_SMOKE_PROJECT must name a readable .uproject"
    end
    return {
      project_root = vim.fs.dirname(resolved),
      uproject = resolved,
    }
  end
  if vim.fn.isdirectory(resolved) ~= 1 then
    return nil, "NVIM_IOS_DAP_SMOKE_PROJECT must name a readable project directory or .uproject"
  end
  local matches = vim.fn.globpath(resolved, "*.uproject", false, true)
  if #matches ~= 1 then
    return nil, "NVIM_IOS_DAP_SMOKE_PROJECT must resolve to exactly one .uproject"
  end
  return {
    project_root = resolved,
    uproject = vim.fs.normalize(matches[1]),
  }
end

local function validate_inputs()
  if mode ~= "launch" and mode ~= "attach" then
    return "NVIM_IOS_DAP_SMOKE_MODE must be launch or attach"
  end
  if trim(device_id) == "" then
    return "NVIM_IOS_DAP_SMOKE_DEVICE is required; smoke never auto-selects the first device"
  end
  if trim(backend) == "" then
    return "NVIM_IOS_DAP_SMOKE_BACKEND is required"
  end
  if backend ~= "coredevice" then
    return "NVIM_IOS_DAP_SMOKE_BACKEND must be coredevice"
  end
  if trim(bundle_id) == "" then
    return "NVIM_IOS_DAP_SMOKE_BUNDLE is required"
  end
  if not path_exists(binary_path) then
    return "NVIM_IOS_DAP_SMOKE_BINARY must name a readable local debug binary"
  end
  if not path_exists(dsym_path) then
    return "NVIM_IOS_DAP_SMOKE_DSYM must name a readable local dSYM"
  end
  if target_source == "" or vim.fn.filereadable(target_source) ~= 1 then
    return "NVIM_IOS_DAP_SMOKE_SOURCE must name a readable source file"
  end
  if not target_line or target_line < 1 then
    return "NVIM_IOS_DAP_SMOKE_LINE must be positive"
  end
  if mode == "attach" and target_pid ~= nil and target_pid < 1 then
    return "NVIM_IOS_DAP_SMOKE_PID must be positive when provided"
  end
  project_info = resolve_project()
  if not project_info and trim(project_input) ~= "" then
    local _, project_err = resolve_project()
    return project_err
  end
  smoke_cwd = trim(explicit_cwd) ~= "" and vim.fs.normalize(explicit_cwd)
    or (project_info and project_info.project_root or vim.fn.getcwd())
  if vim.fn.isdirectory(smoke_cwd) ~= 1 then
    return "NVIM_IOS_DAP_SMOKE_CWD must name a readable directory"
  end
end

local input_error = validate_inputs()
if input_error then
  finish("error", { error = input_error })
  return
end

local function ensure_nvim_dap_runtime()
  if pcall(require, "dap") then
    return true
  end
  local root = vim.fn.stdpath("data") .. "/lazy/nvim-dap"
  if vim.fn.isdirectory(root) == 0 then
    return false
  end
  vim.opt.runtimepath:prepend(root)
  package.path = package.path .. ";" .. root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua"
  return pcall(require, "dap")
end

local ok_ue, ue = pcall(require, "ue")
local ok_dap = ensure_nvim_dap_runtime()
local dap = ok_dap and require("dap") or nil
if not ok_ue or not ok_dap then
  finish("error", {
    error = "ue or nvim-dap is unavailable",
    ue_error = ok_ue and nil or tostring(ue),
    dap_available = ok_dap,
  })
  return
end

ue.setup()
if type(ue.setup_dap) == "function" then
  ue.setup_dap(dap, {
    open = function() end,
    close = function() end,
    toggle = function() end,
    elements = {},
  })
end

vim.cmd("silent cd " .. vim.fn.fnameescape(smoke_cwd))
vim.cmd("silent edit " .. vim.fn.fnameescape(target_source))
target_buf = vim.api.nvim_get_current_buf()
vim.api.nvim_win_set_cursor(0, { target_line, 0 })

local breakpoints = require("dap.breakpoints")
local already_set = false
for _, bp in ipairs(breakpoints.get(target_buf)[target_buf] or {}) do
  if tonumber(bp.line) == target_line then
    already_set = true
    break
  end
end
if not already_set then
  breakpoints.set({}, target_buf, target_line)
  breakpoint_added = true
end

local listener = "ue-ios-real-device-smoke"
local continue_in_flight = false
local non_breakpoint_stops = 0
local max_bootstrap_stops = 8
local saw_verified_breakpoint = false
local saw_breakpoint_stop = false
local saw_loaded_uuid_match = false

dap.listeners.after.event_initialized[listener] = function(session)
  append(result.events, { name = "initialized", config = session.config.name })
end

dap.listeners.after.setBreakpoints[listener] = function(_, err, response)
  local summary = { name = "setBreakpoints", error = err and tostring(err) or nil, breakpoints = {} }
  for _, bp in ipairs((response and response.breakpoints) or {}) do
    append(summary.breakpoints, {
      id = bp.id,
      verified = bp.verified,
      line = bp.line,
      message = bp.message,
    })
    if bp.verified == true then
      saw_verified_breakpoint = true
    end
  end
  append(result.events, summary)
end

dap.listeners.after.event_output[listener] = function(_, body)
  local output = body and tostring(body.output or "") or ""
  if trim(output) == "__UE_IOS_LOADED_UUID_OK__" then
    saw_loaded_uuid_match = true
  end
  if output:find("error", 1, true) or output:find("breakpoint", 1, true) then
    append(result.adapter_output, output:sub(1, 2000))
  end
end

local function evaluate_at_stop(session, body)
  local thread_id = tonumber(body.threadId or session.stopped_thread_id)
  session:request(
    "stackTrace",
    { threadId = thread_id, startFrame = 0, levels = 8 },
    function(stack_err, stack_response)
      local frames = {}
      for _, frame in ipairs((stack_response and stack_response.stackFrames) or {}) do
        append(frames, {
          id = frame.id,
          line = frame.line,
          source = frame.source and frame.source.path or nil,
        })
      end
      local target_frame = frames[1]
      local exact_source_frame = false
      for _, frame in ipairs(frames) do
        local same_file = frame.source and vim.fs.normalize(frame.source) == vim.fs.normalize(target_source)
        local same_line = tonumber(frame.line) == target_line
        if same_file and target_frame == frames[1] then
          target_frame = frame
        end
        if same_file and same_line then
          target_frame = frame
          exact_source_frame = true
          break
        end
      end
      local frame_id = target_frame and target_frame.id or nil
      session:request("evaluate", {
        expression = expression,
        frameId = frame_id,
        context = "repl",
      }, function(eval_err, eval_response)
        local fields = {
          verified_breakpoint = saw_verified_breakpoint,
          loaded_image_uuid_match = saw_loaded_uuid_match,
          breakpoint_stop = saw_breakpoint_stop,
          exact_source_frame = exact_source_frame,
          stop_reason = body.reason,
          source_frame = target_frame and {
            source = target_frame.source,
            line = target_frame.line,
          } or nil,
          frames = frames,
          stack_error = stack_err and tostring(stack_err) or nil,
          evaluation = {
            ok = not eval_err and eval_response and eval_response.result ~= nil or false,
            error = eval_err and tostring(eval_err) or nil,
            result = eval_response and eval_response.result or nil,
            type = eval_response and eval_response.type or nil,
          },
        }
        local eval_ok = fields.evaluation.ok == true
        local ok = saw_loaded_uuid_match and saw_verified_breakpoint and exact_source_frame and eval_ok
        if not ok then
          fields.error = "missing verified breakpoint, exact source frame, or evaluation result"
        end
        stop_and_finish(ok and "passed" or "error", fields)
      end)
    end
  )
end

dap.listeners.after.event_stopped[listener] = function(session, body)
  append(result.events, {
    name = "stopped",
    reason = body.reason,
    description = body.description,
    threadId = body.threadId,
    hitBreakpointIds = body.hitBreakpointIds,
  })
  local breakpoint_stop = body.reason == "breakpoint"
    or (type(body.hitBreakpointIds) == "table" and #body.hitBreakpointIds > 0)
  if breakpoint_stop then
    saw_breakpoint_stop = true
    evaluate_at_stop(session, body)
    return
  end
  if continue_in_flight then
    return
  end
  non_breakpoint_stops = non_breakpoint_stops + 1
  if non_breakpoint_stops > max_bootstrap_stops then
    stop_and_finish("error", {
      error = ("exceeded %d non-breakpoint bootstrap stops"):format(max_bootstrap_stops),
    })
    return
  end
  continue_in_flight = true
  vim.defer_fn(function()
    if done or cleaning then
      continue_in_flight = false
      return
    end
    session:request("continue", { threadId = body.threadId or session.stopped_thread_id }, function(err)
      continue_in_flight = false
      append(result.events, { name = "continue", error = err and tostring(err) or nil })
      if err then
        stop_and_finish("error", { error = "continue failed: " .. tostring(err) })
      end
    end)
  end, 1000)
end

dap.listeners.before.event_terminated[listener] = function(_, body)
  if not cleaning then
    stop_and_finish("error", { error = "terminated before proof", terminated = body })
  end
end
dap.listeners.before.event_exited[listener] = function(_, body)
  if not cleaning then
    stop_and_finish("error", { error = "exited before proof", exited = body })
  end
end

append(result.events, { name = "start", mode = mode })
local explicit_context = project_info
    and {
      project_root = project_info.project_root,
      uproject = project_info.uproject,
      state = {
        uproject = project_info.uproject,
        target_runtime = {
          IOS = {
            device_id = device_id,
            bundle_id = bundle_id,
            device_backend = backend,
          },
        },
      },
      paths = {},
    }
  or nil
handler_started = true
require("ue.dap.ios")[mode]({
  mode = mode,
  device = device_id,
  device_id = device_id,
  backend = backend,
  device_backend = backend,
  bundle = bundle_id,
  bundle_id = bundle_id,
  binary = binary_path,
  binary_path = binary_path,
  dsym = dsym_path,
  dsym_path = dsym_path,
  source = target_source,
  source_path = target_source,
  line = target_line,
  pid = target_pid,
  project = project_info and project_info.project_root or nil,
  project_root = project_info and project_info.project_root or nil,
  cwd = smoke_cwd,
  expression = expression,
  context = explicit_context,
})

vim.defer_fn(function()
  if not done and not cleaning then
    if result.startup_error then
      stop_and_finish("blocked", { error = result.startup_error })
    else
      stop_and_finish("timeout", { error = ("timed out after %d ms"):format(timeout_ms) })
    end
  end
end, timeout_ms)

vim.wait(timeout_ms + 60000, function()
  return done
end, 100)
if not done then
  finish("timeout", { error = "cleanup did not finish before the outer timeout" })
end
