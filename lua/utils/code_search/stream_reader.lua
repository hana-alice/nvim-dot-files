-- Owns one query's pipes and delivery. Spawn decisions remain in init.lua.
-- Exit is not EOF: drain both pipes before announcing a complete result.
local M = {}
M.__index = M
local uv = vim.uv or vim.loop

local function close(handle)
  if handle and not handle:is_closing() then
    handle:close()
  end
end

function M.new(opts, callbacks)
  local self = setmetatable({}, M)
  self.opts, self.callbacks = opts, callbacks or {}
  self.stdout, self.stderr = assert(uv.new_pipe(false)), assert(uv.new_pipe(false))
  self.limit = math.max(0, math.floor(tonumber(opts.max_count) or 5000))
  self.queue, self.queued, self.delivered = {}, 0, 0
  self.received, self.stderr_text, self.leftover = 0, "", ""
  self.started = uv.hrtime()
  return self
end

function M:metadata(state, reason)
  local complete = state == "complete" or state == "empty"
  return {
    backend = self.opts.backend,
    state = state,
    reason = reason,
    delivered = self.delivered,
    received = self.received,
    limit = self.limit,
    complete = complete,
    total_known = complete,
    exit_code = self.exit_code,
    exit_signal = self.exit_signal,
    elapsed_ms = (uv.hrtime() - self.started) / 1e6,
  }
end

function M:_close_timer()
  if self.timer then
    self.timer:stop()
    close(self.timer)
    self.timer = nil
  end
end

function M:_close_pipes()
  for _, field in ipairs({ "stdout", "stderr" }) do
    local pipe = self[field]
    if pipe and not pipe:is_closing() then
      pipe:read_stop()
      close(pipe)
    end
    self[field .. "_eof"] = true
  end
end

function M:_kill()
  if self.handle and not self.handle:is_closing() then
    pcall(self.handle.kill, self.handle, "sigterm")
  end
end

function M:_schedule_flush()
  if self.flush_scheduled or self.stopped or self.finished then
    return
  end
  self.flush_scheduled = true
  vim.schedule(function()
    self:_flush()
  end)
end

function M:_terminal()
  if self.forced then
    if self.forced == "error" then
      return "error",
        self.forced_reason,
        -1,
        self.stderr_text ~= "" and self.stderr_text or "search output could not be read"
    end
    return self.forced,
      self.forced_reason,
      self.forced == "timeout" and 124 or 0,
      self.forced == "timeout" and "search timed out" or nil
  end
  local code, stderr = self.exit_code or 0, self.stderr_text
  if code ~= 0 and not (code == 1 and self.received == 0 and stderr == "") then
    local reason = stderr:find("regex parse error", 1, true) or stderr:find("error parsing regexp", 1, true)
    return self.failure_state or "error",
      reason and "invalid-pattern" or (self.failure_reason or "backend-failed"),
      code,
      stderr ~= "" and stderr or "search backend failed"
  end
  return self.delivered == 0 and "empty" or "complete", nil, code, nil
end

function M:_flush()
  self.flush_scheduled = false
  if self.stopped or self.finished then
    return
  end
  while self.delivered < self.queued do
    self.delivered = self.delivered + 1
    local item = self.queue[self.delivered]
    self.queue[self.delivered] = nil
    if self.callbacks.on_line then
      self.callbacks.on_line(item.file, item.lnum, item.col, item.text, item.location)
    end
    if self.stopped then
      return
    end
  end
  if self.forced or (self.exited and self.stdout_eof and self.stderr_eof) then
    self.finished = true
    self:_close_timer()
    self:_close_pipes()
    local state, reason, code, err = self:_terminal()
    self.final = self:metadata(state, reason)
    if self.callbacks.on_done then
      self.callbacks.on_done(code, err, self.final)
    end
  end
end

function M:_force(state, reason)
  if self.forced or self.stopped or self.finished then
    return
  end
  self.forced, self.forced_reason = state, reason
  self:_close_timer()
  self:_kill()
  self:_close_pipes()
  self:_schedule_flush()
end

function M:_record(record)
  if self.stopped or self.finished or self.forced then
    return
  end
  local item = self.opts.parse(record)
  if item == false then
    return
  end -- Provider explicitly skipped a control row.
  if not item then
    if record ~= "" then
      self.stderr_text = "invalid search output record"
      self:_force("error", "invalid-output")
    end
    return
  end
  self.received = self.received + 1
  if self.queued >= self.limit then
    self:_force("truncated", "result-limit")
    return
  end
  self.queued = self.queued + 1
  self.queue[self.queued] = item
end

function M:_feed(data, eof)
  self.leftover = self.leftover .. (data or "")
  local separator = self.opts.separator or "\n"
  while not self.forced and not self.stopped do
    local first, last
    if self.opts.record_end then
      first, last = self.opts.record_end(self.leftover)
    else
      first, last = self.leftover:find(separator, 1, true)
    end
    if not first then
      break
    end
    local record = self.leftover:sub(1, first - 1)
    self.leftover = self.leftover:sub(last + 1)
    self:_record(record:gsub("\r$", ""))
  end
  if eof and self.leftover ~= "" and not self.forced then
    self:_record(self.leftover:gsub("\r$", ""))
    self.leftover = ""
  end
  self:_schedule_flush()
end

function M:attach(handle, err)
  self.handle = handle
  if not handle then
    self.exit_code, self.exited = -1, true
    self.stderr_text, self.failure_reason = tostring(err or "failed to spawn search"), "spawn-failed"
    self:_close_pipes()
    self:_schedule_flush()
    return function(reason)
      return self:stop(reason)
    end
  end
  self.stdout:read_start(function(read_err, data)
    if self.stopped or self.finished or self.forced then
      return
    end
    if read_err then
      self.failure_reason, self.stderr_text = "output-read-failed", tostring(read_err)
      self:_force("error", "output-read-failed")
      return
    end
    self:_feed(data, data == nil)
    if data == nil then
      self.stdout_eof = true
      close(self.stdout)
    end
    self:_schedule_flush()
  end)
  self.stderr:read_start(function(read_err, data)
    if self.stopped or self.finished or self.forced then
      return
    end
    if data then
      self.stderr_text = (self.stderr_text .. data):sub(1, 8192)
    end
    if read_err then
      self.stderr_text = tostring(read_err)
    end
    if data == nil then
      self.stderr_eof = true
      close(self.stderr)
    end
    self:_schedule_flush()
  end)
  local timeout = tonumber(self.opts.timeout_ms) or 30000
  if timeout >= 0 then
    self.timer = assert(uv.new_timer())
    self.timer:start(
      timeout,
      0,
      vim.schedule_wrap(function()
        self:_force("timeout", "deadline")
      end)
    )
  end
  return function(reason)
    return self:stop(reason)
  end
end

function M:exit(code, signal)
  self.exit_code, self.exit_signal, self.exited = code, signal, true
  close(self.handle)
  if not self.stopped and not self.finished then
    self:_schedule_flush()
  end
end

function M:stop(reason)
  if self.final then
    return self.final
  end
  self.stopped = true
  self:_close_timer()
  self:_kill()
  self:_close_pipes()
  self.queue = {}
  self.final = self:metadata("canceled", reason or "canceled")
  return self.final
end

return M
