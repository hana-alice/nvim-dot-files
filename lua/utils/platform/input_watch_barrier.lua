-- Windows grouped watches have independent metadata/write streams. A marker
-- in every subscription must pass both streams before reuse may inspect epoch.
local M = {}
local uv = vim.uv or vim.loop
-- Other consumers (notably frozen batch guards) must not see this process's
-- own marker writes. Exact paths only; an old event evicted from this bounded
-- registry is an ordinary input event and therefore fails closed.
local owned, history, slot = {}, {}, 0

function M.attach(group, roots)
  local watch, close = group.watch, group.close
  local pending
  -- Only inventory-proven tool roots can use identity evidence instead of a
  -- marker. A denied source/cache root still fails closed. Keep observing both
  -- native streams, including all non-marker events, for these tool roots.
  group.readonly_tool_roots = {}
  local token = tostring(vim.fn.getpid()) .. "-" .. vim.fn.sha256(vim.fn.tempname()):sub(1, 20)
  local serial = 0
  local function key(path) return vim.fs.normalize(path):gsub("\\", "/"):lower() end
  local function subscription(path, recursive) return key(path) .. ":" .. tostring(recursive) end
  local function finish(ok, reason)
    local request = pending
    if not request then return end
    if request.finishing then
      if not ok then request.ok, request.reason = false, reason end
      return
    end
    request.finishing, request.ok, request.reason = true, ok, reason
    request.timer:stop(); request.timer:close()
    local remaining = #request.releases
    local function deliver()
      if remaining ~= 0 then return end
      -- Finish after cleanup and outside the frame. Later callbacks in that
      -- frame may still turn an acknowledged barrier into a failed one.
      vim.schedule(function()
        if pending == request then pending = nil end
        request.done(request.ok, request.reason, (uv.hrtime() - request.started) / 1e6)
      end)
    end
    for _, release in ipairs(request.releases) do
      release(function(cleaned, err)
        if not cleaned then request.ok, request.reason = false, "barrier-cleanup:" .. tostring(err) end
        remaining = remaining - 1
        deliver()
      end)
    end
    if #request.releases == 0 then deliver() end
  end
  function group:watch(root, callback, options)
    options = options or {}
    return watch(self, root, function(err, name, events)
      if err or not name or (events and (events.unknown or events.overflow)) then
        finish(false, "barrier-watch-unknown")
      end
      local path = name and key(root .. "/" .. name)
      if path and owned[path] then
        local request = pending
        local marker = request and request.markers[path]
        if marker and marker.root == subscription(root, options.recursive) and events then
          if events.stream == "metadata" and (events.action == 1 or events.action == 2) then marker.metadata = true end
          if events.stream == "write" and events.action == 3 then marker.write = true end
          if marker.metadata and marker.write and not marker.acknowledged then
            marker.acknowledged = true
            request.remaining = request.remaining - 1
          end
          if request.remaining == 0 and request.created == request.expected then finish(true) end
        end
        return
      end
      callback(err, name, events)
    end, options)
  end
  function group:barrier(done)
    if self.phase ~= "running" then done(false, "barrier-watch-not-running"); return end
    if pending then done(false, "barrier-already-pending"); return end
    serial = serial + 1
    local writable = {}
    for _, root in ipairs(roots) do
      if not self.readonly_tool_roots[root.path] then writable[#writable + 1] = root end
    end
    local request = { done = done, started = uv.hrtime(), markers = {}, releases = {}, remaining = #writable,
      expected = #writable,
      created = 0, timer = uv.new_timer() }
    pending = request
    -- libuv caches its clock between loop turns. Synchronous caller writes
    -- must not consume this request's timeout before it has even started.
    uv.update_time()
    request.timer:start(750, 0, vim.schedule_wrap(function()
      if pending == request then finish(false, "barrier-timeout") end
    end))
    if #writable == 0 then finish(true); return end
    for index, root in ipairs(writable) do
      local path = root.path .. "/.nvim-ue-watch-barrier-" .. token .. "-" .. serial .. "-" .. index .. ".tmp"
      local id = key(path)
      owned[id], request.markers[id] = true, { root = subscription(root.path, root.recursive) }
      slot = slot % 4096 + 1
      if history[slot] then owned[history[slot]] = nil end
      history[slot] = id
      require("utils.platform.watch_barrier_marker").create(path, function(ok, reason, release)
        if pending ~= request or request.finishing then
          if release then release(function() end) end
          return
        end
        if not ok then
          owned[id] = nil
          -- Only failure to CREATE the owner with access denied/write-protect
          -- qualifies. Writer/flush/close errors must never downgrade a barrier.
          if root.tool_root and (reason == "CreateFileW failed (Win32 error 5)"
            or reason == "CreateFileW failed (Win32 error 19)") then
            self.readonly_tool_roots[root.path] = true
            request.remaining = request.remaining - 1
            request.created = request.created + 1
            if request.remaining == 0 and request.created == request.expected then finish(true) end
          else finish(false, "barrier-marker:" .. tostring(reason)) end
          return
        end
        if release then request.releases[#request.releases + 1] = release end
        request.created = request.created + 1
        if request.remaining == 0 and request.created == request.expected then finish(true) end
      end)
    end
  end
  function group:close()
    finish(false, "barrier-watch-closed")
    return close(self)
  end
  return group
end

return M
