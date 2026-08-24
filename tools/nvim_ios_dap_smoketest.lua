-- Real-device Nvim DAP probe for the production IOS handler.
--
-- Required environment:
--   NVIM_IOS_DAP_SMOKE_MODE=launch|attach
--   NVIM_IOS_DAP_SMOKE_FILE=/absolute/source.cpp
--   NVIM_IOS_DAP_SMOKE_LINE=123
-- Optional:
--   NVIM_IOS_DAP_SMOKE_EXPR="1 + 2"
--   NVIM_IOS_DAP_SMOKE_RESULT=/tmp/ios-dap.json
--   NVIM_IOS_DAP_SMOKE_TIMEOUT_MS=120000

local mode = tostring(vim.env.NVIM_IOS_DAP_SMOKE_MODE or "")
local target_file = tostring(vim.env.NVIM_IOS_DAP_SMOKE_FILE or "")
local target_line = tonumber(vim.env.NVIM_IOS_DAP_SMOKE_LINE or "")
local expression = tostring(vim.env.NVIM_IOS_DAP_SMOKE_EXPR or "1 + 2")
local result_path = tostring(vim.env.NVIM_IOS_DAP_SMOKE_RESULT or "/tmp/nvim-ios-dap-smoke.json")
local timeout_ms = tonumber(vim.env.NVIM_IOS_DAP_SMOKE_TIMEOUT_MS or "120000") or 120000

local result = {
  status = "running",
  mode = mode,
  target = { file = target_file, line = target_line },
  expression = expression,
  events = {},
  notifications = {},
  adapter_output = {},
}
local done = false
local cleaning = false
local breakpoint_added = false
local target_buf = nil

local function append(list, value)
  list[#list + 1] = value
end

local original_notify = vim.notify
vim.notify = function(message, level, opts)
  append(result.notifications, {
    message = tostring(message),
    level = level,
    title = opts and opts.title or nil,
  })
  return original_notify(message, level, opts)
end

local function write_result()
  vim.fn.mkdir(vim.fn.fnamemodify(result_path, ":h"), "p")
  vim.fn.writefile({ vim.json.encode(result) }, result_path)
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

local function validate_inputs()
  if mode ~= "launch" and mode ~= "attach" then
    return "mode must be launch or attach"
  end
  if target_file == "" or vim.fn.filereadable(target_file) ~= 1 then
    return "NVIM_IOS_DAP_SMOKE_FILE must name a readable source file"
  end
  if not target_line or target_line < 1 then
    return "NVIM_IOS_DAP_SMOKE_LINE must be positive"
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

vim.cmd("silent edit " .. vim.fn.fnameescape(target_file))
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
local continued = false
local saw_verified_breakpoint = false
local saw_breakpoint_stop = false

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
          name = frame.name,
          line = frame.line,
          source = frame.source and frame.source.path or nil,
        })
      end
      local target_frame = frames[1]
      for _, frame in ipairs(frames) do
        if frame.source and vim.fs.basename(frame.source) == vim.fs.basename(target_file) then
          target_frame = frame
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
          breakpoint_stop = saw_breakpoint_stop,
          stop_reason = body.reason,
          frames = frames,
          stack_error = stack_err and tostring(stack_err) or nil,
          evaluation = {
            error = eval_err and tostring(eval_err) or nil,
            result = eval_response and eval_response.result or nil,
            type = eval_response and eval_response.type or nil,
          },
        }
        local source_ok = false
        for _, frame in ipairs(frames) do
          if frame.source and vim.fs.basename(frame.source) == vim.fs.basename(target_file) then
            source_ok = true
            break
          end
        end
        local eval_ok = not eval_err and fields.evaluation.result ~= nil
        local ok = saw_verified_breakpoint and source_ok and eval_ok
        if not ok then
          fields.error = "missing verified breakpoint, source frame, or evaluation result"
        end
        stop_and_finish(ok and "ok" or "error", fields)
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
  if continued then
    return
  end
  continued = true
  vim.defer_fn(function()
    if done or cleaning then
      return
    end
    session:request("continue", { threadId = body.threadId or session.stopped_thread_id }, function(err)
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
require("ue.dap.ios")[mode]({})

vim.defer_fn(function()
  if not done and not cleaning then
    stop_and_finish("timeout", { error = ("timed out after %d ms"):format(timeout_ms) })
  end
end, timeout_ms)

vim.wait(timeout_ms + 60000, function()
  return done
end, 100)
if not done then
  finish("timeout", { error = "cleanup did not finish before the outer timeout" })
end
