-- Bounded, asynchronous rg stdin search. Coordinates always refer to buffer text.
local M = {}
local uv = vim.uv or vim.loop

M.limits = {
  source_bytes = 2 * 1024 * 1024,
  output_bytes = 8 * 1024 * 1024,
  record_bytes = 1024 * 1024,
  results = 5000,
  query_bytes = 8192,
  stderr_bytes = 8192,
  deadline_ms = 6000,
}

function M.argv(query, modes, executable)
  modes = modes or {}
  local args = { executable or "rg", "--no-config", "--engine=default", "--json", "--text", "--threads=1" }
  if not modes.regex then
    args[#args + 1] = "--fixed-strings"
  end
  args[#args + 1] = modes.case_sensitive and "--case-sensitive" or "--ignore-case"
  if modes.whole_word then
    args[#args + 1] = "--word-regexp"
  end
  vim.list_extend(args, { "-e", query, "-" })
  return args
end

function M.validate(query, limits)
  limits = limits or M.limits
  if type(query) ~= "string" or query:find("[\r\n%z]") then
    return "single-line-query-required"
  end
  if #query > limits.query_bytes then
    return "query-too-large"
  end
end

local function boundary(line, col)
  local byte = line:byte(col + 1)
  return col >= 0 and col <= #line and (not byte or byte < 128 or byte >= 192)
end

-- Keep display strings small even when thousands of hits share one long line.
function M.snippet(line, first, last)
  local from, to = math.max(0, first - 64), math.min(#line, first + 192)
  while from > 0 and not boundary(line, from) do
    from = from - 1
  end
  while to > from and not boundary(line, to) do
    to = to - 1
  end
  local prefix = from > 0 and "…" or ""
  local text = prefix .. line:sub(from + 1, to) .. (to < #line and "…" or "")
  return text, #prefix + first - from, #prefix + math.min(last, to) - from
end

--- Start one owned process; callbacks run on the main thread.
--- spec: {text, lines, query, modes?, limits?}; on_items receives bounded batches.
function M.start(spec, callbacks)
  callbacks = callbacks or {}
  local limits = vim.tbl_extend("force", M.limits, spec.limits or {})
  local admission = require("utils.host_admission")
  local foreground = admission.foreground_begin("current document find")
  local job = { finished = false, count = 0, bytes = 0, records = 0 }
  local completion = {}
  local handle, timer, exit, eof, scheduled, terminal, released, killed
  local queue, head, tail, fragments, fragment_bytes = {}, 1, 0, {}, 0
  local current, subindex, stderr, searched = nil, 1, "", nil
  local drain

  local function release()
    if released then
      return
    end
    released = true
    admission.foreground_done(foreground)
    if timer then
      pcall(timer.stop, timer)
      pcall(timer.close, timer)
      timer = nil
    end
  end

  local function kill()
    if killed or not handle then
      return
    end
    killed = true
    pcall(handle.kill, handle, 15)
  end

  local function schedule()
    if scheduled or job.finished then
      return
    end
    scheduled = true
    vim.schedule(function()
      scheduled = false
      drain()
    end)
  end

  local function stop(state, reason)
    if job.finished or terminal then
      return
    end
    terminal = { state = state, reason = reason }
    queue, fragments, current = {}, {}, nil
    head, tail, fragment_bytes = 1, 0, 0
    kill()
    schedule()
  end

  function job.cancel(reason)
    stop("cancelled", reason or "cancelled")
  end

  function job.when_done(fn)
    if job.finished then
      fn(job.result)
    else
      completion[#completion + 1] = fn
    end
  end

  local function complete()
    if job.finished then
      return
    end
    job.finished = true
    release()
    if not terminal and exit.signal == 0 and (exit.code == 0 or exit.code == 1) and searched ~= #spec.text then
      terminal = { state = "error", reason = "stdin-incomplete" }
    end
    local result = terminal
      or (exit.signal ~= 0 and { state = "cancelled", reason = "process-stopped" })
      or {
        state = exit.code == 0 and (job.count > 0 and "ready" or "empty") or exit.code == 1 and "empty" or "error",
        reason = exit.code > 1 and "rg-error" or nil,
      }
    result.count, result.bytes, result.records = job.count, job.bytes, job.records
    result.code, result.signal, result.stderr = exit.code, exit.signal, stderr
    job.result = result
    queue, fragments, current, spec = {}, {}, nil, nil
    local on_done = callbacks.on_done
    callbacks = {}
    if on_done then
      pcall(on_done, result)
    end
    for _, fn in ipairs(completion) do
      pcall(fn, result)
    end
    completion = {}
  end

  drain = function()
    if job.finished then
      return
    end
    if terminal then
      if exit and eof then
        complete()
      end
      return
    end
    local batch, steps, started = {}, 0, uv.hrtime()
    while steps < 128 and uv.hrtime() - started < 3000000 do
      steps = steps + 1
      if not current then
        if head > tail then
          break
        end
        local record = queue[head]
        queue[head], head = nil, head + 1
        local ok, decoded = pcall(vim.json.decode, record)
        job.records = job.records + 1
        if not ok or type(decoded) ~= "table" then
          stop("error", "invalid-rg-json")
          break
        end
        if decoded.type == "summary" then
          searched = decoded.data and decoded.data.stats and decoded.data.stats.bytes_searched
        elseif decoded.type == "match" then
          current, subindex = decoded.data, 1
          if type(current) ~= "table" or type(current.submatches) ~= "table" then
            stop("error", "invalid-rg-match")
            break
          end
          if type(current.lines) ~= "table" or type(current.lines.text) ~= "string" then
            stop("error", "unsupported-binary-text")
            break
          end
        end
      end
      if current then
        local hit = current.submatches[subindex]
        if not hit then
          current = nil
        else
          subindex = subindex + 1
          local lnum, first, last = current.line_number, hit.start, hit["end"]
          local line = type(lnum) == "number" and spec.lines[lnum] or nil
          if first == last then
            stop("error", "unsupported-zero-width")
            break
          end
          if
            type(line) ~= "string"
            or type(first) ~= "number"
            or type(last) ~= "number"
            or first % 1 ~= 0
            or last % 1 ~= 0
            or first >= last
            or not boundary(line, first)
            or not boundary(line, last)
          then
            stop("error", "invalid-rg-position")
            break
          end
          if job.count >= limits.results then
            stop("truncated", "result-limit")
            break
          end
          job.count = job.count + 1
          local text, from, to = M.snippet(line, first, last)
          batch[#batch + 1] = { lnum = lnum, col = first, end_col = last, text = text, from = from, to = to }
        end
      end
    end
    if #batch > 0 and callbacks.on_items then
      local ok = pcall(callbacks.on_items, batch)
      if not ok then
        stop("error", "result-callback-error")
      end
    end
    if terminal then
      if exit and eof then
        complete()
      end
    elseif current or head <= tail then
      schedule()
    elseif exit and eof then
      complete()
    end
  end

  local function stdout(err, chunk)
    if job.finished then
      return
    end
    if err then
      stop("error", "stdout-error")
    end
    if not chunk then
      eof = true
      if not terminal and fragment_bytes > 0 then
        tail = tail + 1
        queue[tail] = table.concat(fragments)
        fragments, fragment_bytes = {}, 0
      end
      schedule()
      return
    end
    if terminal then
      return
    end
    job.bytes = job.bytes + #chunk
    if job.bytes > limits.output_bytes then
      stop("truncated", "output-limit")
      return
    end
    local offset = 1
    while offset <= #chunk do
      local newline = chunk:find("\n", offset, true)
      local last = newline and newline - 1 or #chunk
      local length = last - offset + 1
      if fragment_bytes + length > limits.record_bytes then
        stop("truncated", "record-limit")
        return
      end
      if length > 0 then
        fragments[#fragments + 1] = chunk:sub(offset, last)
        fragment_bytes = fragment_bytes + length
      end
      if newline then
        if fragment_bytes > 0 then
          tail = tail + 1
          queue[tail] = table.concat(fragments)
        end
        fragments, fragment_bytes = {}, 0
        offset = newline + 1
      else
        break
      end
    end
    schedule()
  end

  local invalid = M.validate(spec.query, limits)
  if invalid or #spec.text > limits.source_bytes then
    terminal = { state = "error", reason = invalid or "source-too-large" }
    exit, eof = { code = -1, signal = 0 }, true
    schedule()
    return job
  end
  if spec.query == "" then
    terminal = { state = "idle" }
    exit, eof = { code = 0, signal = 0 }, true
    schedule()
    return job
  end

  timer = uv.new_timer()
  if not timer then
    terminal = { state = "error", reason = "timer-unavailable" }
    exit, eof = { code = -1, signal = 0 }, true
    schedule()
    return job
  end
  timer:start(limits.deadline_ms, 0, function()
    stop("error", "deadline")
  end)
  local ok, spawned = pcall(function()
    local system = vim.system(M.argv(spec.query, spec.modes), {
      stdin = true,
      stdout = stdout,
      stderr = function(err, chunk)
        if not job.finished and not terminal and not err and chunk then
          stderr = stderr .. chunk:sub(1, math.max(0, limits.stderr_bytes - #stderr))
        end
      end,
    }, function(result)
      exit = { code = result.code or -1, signal = result.signal or 0 }
      schedule()
    end)
    pcall(require("utils.task_registry").register, {
      name = "Current document find",
      group = "Editor",
      kind = "system",
      handle = system,
    })
    handle = system
    local written = pcall(function()
      system:write(spec.text)
      system:write(nil)
    end)
    if not written then
      stop("error", "stdin-write-failed")
    end
    return system
  end)
  if not ok then
    terminal = { state = "error", reason = "spawn-failed" }
    stderr, exit, eof = tostring(spawned):sub(1, limits.stderr_bytes), { code = -1, signal = 0 }, true
    schedule()
  else
    handle = spawned
    if terminal then
      kill()
    end
  end
  return job
end

return M
