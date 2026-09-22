-- WORKAROUND
-- name: libuv.content_events
-- scope: libuv
-- issue: https://github.com/libuv/libuv/blob/v1.51.0/src/win/fs-event.c#L39
-- symptom: Windows access and attribute notifications trigger unnecessary source refreshes.
-- introduced: 2026-09-22
-- removal_condition: libuv exposes a selectable Windows notification filter and native metadata/write/lifecycle regressions pass through it.
-- owner: hana-alice
-- enabled: true
-- END WORKAROUND

local M = {}
local enabled = true
function M.apply() enabled = true end
function M.disable() enabled = false end
function M.status() return { applied = enabled } end

local MAX_FRAME = 1024 * 1024
local function relative_path(path)
  if type(path) ~= "string" or path == "" or path:find("[%z\r\n:]") then return nil end
  path = path:gsub("\\", "/")
  if path:sub(1, 1) == "/" then return nil end
  for part in path:gmatch("[^/]+") do if part == "." or part == ".." then return nil end end
  return path
end

-- One long-lived, parent-bound helper. Native I/O and cancellation memory live
-- in the child; no polling timer or filesystem walk runs in the editor.
function M.new(python, deps)
  if not enabled then return nil, "libuv.content_events is disabled" end
  if type(python) ~= "string" or python == "" then return nil, "Python unavailable for content watcher" end
  deps = deps or {}
  local spawn = deps.spawn or function(command, options) return vim.fn.jobstart(command, options) end
  local stop = deps.stop or vim.fn.jobstop
  local defer = deps.defer or vim.defer_fn
  local register = deps.register or require("utils.task_registry").register
  local h = { content_events = true, phase = "stopped" }
  local serial, job = 0, nil

  function h:stop()
    serial = serial + 1
    local previous = job
    job = nil
    if self.phase ~= "error" then self.phase = "stopped" end
    if previous then pcall(stop, previous) end
  end
  function h:close() self:stop() end

  function h:start(root, _, callback)
    self:stop()
    serial = serial + 1
    local generation, tail, stderr = serial, "", ""
    self.phase, self.error = "starting", nil
    local function alive() return serial == generation end
    local function fail(reason)
      if not alive() then return end
      self.phase, self.error = "error", reason
      self:stop()
      callback(reason, nil, { unknown = true })
    end
    local function frame(line)
      local ok, value = pcall(vim.json.decode, line)
      if not ok or type(value) ~= "table" or value.v ~= 1 then fail("invalid watcher frame"); return end
      if value.kind == "ready" and self.phase == "starting" then
        self.phase = "running"
        callback(nil, nil, { ready = true })
      elseif value.kind == "error" then
        fail("native watcher: " .. tostring(value.error or "unknown error"))
      elseif value.kind == "overflow" and self.phase == "running" then
        callback(nil, nil, { overflow = true, unknown = true })
      elseif value.kind == "events" and self.phase == "running" and type(value.events) == "table"
          and vim.islist(value.events) and #value.events > 0 and #value.events <= 8192 then
        local batch = {}
        for _, event in ipairs(value.events) do
          local path = type(event) == "table" and relative_path(event.path)
          local action = type(event) == "table" and event.action
          if not path or type(action) ~= "number" or action % 1 ~= 0 or action < 1 or action > 5 then
            fail("invalid watcher event"); return
          end
          batch[#batch + 1] = { path, { change = action == 3, rename = action ~= 3, action = action,
            directory = event.directory == true } }
        end
        for _, event in ipairs(batch) do
          if not alive() then return end
          callback(nil, event[1], event[2])
        end
      else fail("unexpected watcher frame: " .. tostring(value.kind)) end
    end
    local callbacks = {
      stdout_buffered = false, stderr_buffered = false,
      on_stdout = function(_, data)
        if not alive() then return end
        for index, part in ipairs(data or {}) do
          tail = tail .. part
          if #tail > MAX_FRAME then fail("watcher frame exceeds size limit"); return end
          if index < #data then
            if tail ~= "" then frame(tail) end
            tail = ""
            if not alive() then return end
          end
        end
      end,
      on_stderr = function(_, data)
        if alive() then stderr = (stderr .. table.concat(data or {}, "\n")):sub(-4096) end
      end,
      on_exit = function(_, code)
        if alive() then fail("watcher exited " .. tostring(code) .. (stderr ~= "" and (": " .. stderr) or "")) end
      end,
    }
    local command = { python, "-B", "-u", "-I",
      vim.fn.stdpath("config") .. "/lua/workarounds/libuv/content_events.py", root, tostring(vim.fn.getpid()) }
    local ok, started = pcall(spawn, command, callbacks)
    if not ok or type(started) ~= "number" or started <= 0 then
      self.phase, self.error = "error", "cannot start native watcher: " .. tostring(started)
      serial = serial + 1
      return nil, self.error
    end
    job = started
    pcall(register, { name = "UE content watcher", group = "ue", kind = "job", handle = job })
    defer(function() if alive() and self.phase == "starting" then fail("native watcher ready timeout") end end, 5000)
    return 0
  end
  return h
end

return M
