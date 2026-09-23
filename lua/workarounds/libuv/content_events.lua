-- WORKAROUND
-- name: libuv.content_events
-- scope: libuv
-- issue: https://github.com/libuv/libuv/blob/v1.51.0/src/win/fs-event.c#L39
-- symptom: Windows access notifications revoke frozen input guards, and source metadata events trigger unnecessary refreshes.
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

-- Frozen inputs require attribute/security/creation observations as well as
-- content and names. This grouped subscription excludes ONLY last access.
function M.new_group(python, roots, deps)
  if not enabled then return nil, "libuv.content_events is disabled" end
  if type(python) ~= "string" or python == "" then return nil, "Python unavailable for input watcher" end
  if type(roots) ~= "table" or not vim.islist(roots) or #roots == 0 or #roots > 288 then
    return nil, "invalid input watcher roots"
  end
  deps = deps or {}
  local spawn, stop = deps.spawn or vim.fn.jobstart, deps.stop or vim.fn.jobstop
  local send, defer = deps.send or vim.fn.chansend, deps.defer or vim.defer_fn
  local schedule = deps.schedule or vim.schedule
  local register = deps.register or require("utils.task_registry").register
  local entries, lookup, recursive_count, direct_count = {}, {}, 0, 0
  local function root_key(path, recursive)
    return vim.fs.normalize(path):gsub("\\", "/"):lower() .. ":" .. tostring(recursive)
  end
  for index, root in ipairs(roots) do
    if type(root) ~= "table" or type(root.path) ~= "string" or root.path == ""
        or root.path:find("[%z\r\n]") or not (root.path:match("^%a:[/\\]") or root.path:match("^[/\\][/\\]"))
        or type(root.recursive) ~= "boolean" then return nil, "invalid input watcher root" end
    local key = root_key(root.path, root.recursive)
    if lookup[key] then return nil, "duplicate input watcher root" end
    local entry = { id = index, path = root.path, recursive = root.recursive }
    entries[index], lookup[key] = entry, entry
    if root.recursive then recursive_count = recursive_count + 1 else direct_count = direct_count + 1 end
  end
  if recursive_count > 32 or direct_count > 256 then return nil, "input watcher root budget exceeded" end
  local group = { phase = "starting", input_events = true }
  local job, tail, stderr = nil, "", ""
  local function alive() return group.phase == "starting" or group.phase == "running" end
  local function ready(entry, ok, reason)
    if not entry.handle or entry.handle.closed or entry.notified then return end
    entry.notified = true
    entry.on_ready(ok, reason)
  end
  local function fail(reason)
    if not alive() then return end
    group.phase, group.error = "error", reason
    local previous = job; job = nil
    if previous then pcall(stop, previous) end
    for _, entry in ipairs(entries) do
      if entry.handle and not entry.handle.closed then
        pcall(ready, entry, false, reason)
        pcall(entry.callback, reason, nil, { unknown = true })
      end
    end
  end
  function group:close()
    if self.phase == "closed" then return end
    self.phase = "closed"
    local previous = job; job = nil
    if previous then pcall(stop, previous) end
    for _, entry in ipairs(entries) do if entry.handle then entry.handle.closed = true end end
  end
  function group:watch(root, callback, options)
    if not alive() then return nil, self.error or "input watcher closed" end
    options = options or {}
    if type(root) ~= "string" or type(options.recursive) ~= "boolean"
        or type(callback) ~= "function" or type(options.on_ready) ~= "function" then
      fail("invalid input watch registration"); return nil, self.error
    end
    local entry = lookup[root_key(root, options.recursive)]
    if not entry or entry.handle then fail("unexpected input watch registration"); return nil, self.error end
    local handle = { closed = false }
    function handle:stop() self.closed = true end
    function handle:close() self:stop() end
    entry.handle, entry.callback, entry.on_ready = handle, callback, options.on_ready
    if entry.armed then schedule(function() if alive() then ready(entry, true) end end) end
    return handle, { recursive = entry.recursive, direct = not entry.recursive, pending = true }
  end
  local function frame(line)
    local ok, value = pcall(vim.json.decode, line)
    local id = ok and type(value) == "table" and value.root_id or nil
    local entry = type(id) == "number" and id % 1 == 0 and entries[id] or nil
    if not entry or value.v ~= 1 then fail("invalid input watcher frame"); return end
    if value.kind == "ready" and not entry.armed then
      entry.armed = true
      local all = true
      for _, item in ipairs(entries) do if not item.armed then all = false; break end end
      if all then group.phase = "running" end
      if entry.handle then ready(entry, true) end
    elseif value.kind == "error" or value.kind == "overflow" then
      fail("native input watcher: " .. tostring(value.error or value.kind))
    elseif value.kind == "events" and entry.armed and type(value.events) == "table"
        and vim.islist(value.events) and #value.events > 0 and #value.events <= 8192 then
      -- Never lose changes during yielded root installation. Early readiness is
      -- safe to remember; early input changes revoke the entire group.
      if not entry.handle then fail("input changed before watch registration"); return end
      local batch = {}
      for _, event in ipairs(value.events) do
        local path = type(event) == "table" and relative_path(event.path)
        local action = type(event) == "table" and event.action
        if not path or type(action) ~= "number" or action % 1 ~= 0 or action < 1 or action > 5 then
          fail("invalid input watcher event"); return
        end
        batch[#batch + 1] = { path, { change = action == 3, rename = action ~= 3,
          action = action, directory = event.directory == true } }
      end
      for _, event in ipairs(batch) do
        if not alive() then return end
        if not entry.handle.closed then entry.callback(nil, event[1], event[2]) end
      end
    else fail("unexpected input watcher frame") end
  end
  local callbacks = { stdout_buffered = false, stderr_buffered = false,
    on_stdout = function(_, data)
      if not alive() then return end
      for index, part in ipairs(data or {}) do
        tail = tail .. part
        if #tail > MAX_FRAME then fail("input watcher frame exceeds size limit"); return end
        if index < #data then
          if tail ~= "" then frame(tail) end
          tail = ""
          if not alive() then return end
        end
      end
    end,
    on_stderr = function(_, data) if alive() then stderr = (stderr .. table.concat(data or {}, "\n")):sub(-4096) end end,
    on_exit = function(_, code)
      if alive() then fail("input watcher exited " .. tostring(code) .. (stderr ~= "" and (": " .. stderr) or "")) end
    end }
  local command = { python, "-B", "-u", "-I", vim.fn.stdpath("config") .. "/lua/workarounds/libuv/content_events.py",
    "--group", tostring(vim.fn.getpid()) }
  local ok, started = pcall(spawn, command, callbacks)
  if not ok or type(started) ~= "number" or started <= 0 then
    group:close(); return nil, "cannot start input watcher: " .. tostring(started)
  end
  job = started
  local configuration = {}
  for _, entry in ipairs(entries) do configuration[#configuration + 1] = { id = entry.id, path = entry.path, recursive = entry.recursive } end
  local encoded = vim.json.encode({ v = 1, roots = configuration }) .. "\n"
  if #encoded > MAX_FRAME then fail("input watcher configuration exceeds size limit")
  else
    local sent, count = pcall(send, job, encoded)
    if not sent or type(count) ~= "number" or count <= 0 then fail("cannot send input watcher configuration") end
  end
  pcall(register, { name = "Frozen input watcher", group = "index", kind = "job", handle = started })
  defer(function() if group.phase == "starting" then fail("input watcher ready timeout") end end, 5000)
  return group
end

return M
