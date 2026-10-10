local t = require("tests.harness")
t.bootstrap()

local uv = vim.uv or vim.loop
local marker = require("utils.platform.watch_barrier_marker")
local barrier = require("utils.platform.input_watch_barrier")

-- These injected callbacks test the barrier protocol only. Native delivery and
-- marker creation are separately exercised below on the actual host driver.
local function protocol(paths, body, create_failure, create_release)
  local original_create = marker.create
  local roots, callbacks, markers, observed = {}, {}, {}, {}
  local group = { phase = "running" }
  function group:watch(root, callback, options)
    callbacks[root .. ":" .. tostring(options.recursive)] = callback
    return { close = function() end }
  end
  function group:close() self.phase = "closed" end
  for _, path in ipairs(paths) do
    roots[#roots + 1] = type(path) == "table" and path or { path = path, recursive = true }
  end
  marker.create = function(path, callback)
    markers[#markers + 1] = path
    local failure = create_failure
    if type(create_failure) == "function" then failure = create_failure(path) end
    callback(not failure, failure, create_release and function(done) create_release(path, done) end or nil)
    return not failure
  end
  barrier.attach(group, roots)
  for _, root in ipairs(roots) do
    group:watch(root.path, function(err, name, events)
      observed[#observed + 1] = { err = err, name = name, events = events }
    end, { recursive = root.recursive })
  end
  local h = { group = group, markers = markers, observed = observed }
  function h.emit(root, name, stream, action, err, events, recursive)
    if recursive == nil then recursive = true end
    callbacks[root .. ":" .. tostring(recursive)](err, name, events or { stream = stream, action = action })
  end
  function h.ack(index, stream)
    h.emit(roots[index].path, vim.fs.basename(markers[index]), stream, stream == "write" and 3 or 1,
      nil, nil, roots[index].recursive)
  end
  local ok, err = xpcall(function() body(h) end, debug.traceback)
  group:close()
  marker.create = original_create
  vim.wait(20, function() return false end, 1)
  if not ok then error(err) end
end

local function request(h)
  local result = { calls = 0 }
  h.group:barrier(function(ok, reason, elapsed)
    result.calls = result.calls + 1
    result.ok, result.reason, result.elapsed = ok, reason, elapsed
  end)
  return result
end

local function completed(result)
  t.assert_true(vim.wait(1100, function() return result.calls > 0 end, 5), "barrier callback missing")
  t.assert_eq(result.calls, 1)
end

t.describe("platform watch barrier protocol", function()
  for _, code in ipairs({5, 19}) do
    t.it("proven tool root create denial " .. code .. " stops marker writes while preserving events", function()
      local root = "C:/protocol-readonly"
      protocol({{path = root, recursive = true, tool_root = true}}, function(h)
        local first = request(h)
        completed(first)
        t.assert_true(first.ok)
        t.assert_true(h.group.readonly_tool_roots[root])
        t.assert_eq(#h.markers, 1)
        local second = request(h)
        completed(second)
        t.assert_true(second.ok)
        t.assert_eq(#h.markers, 1, "known denied tool roots must not attempt another marker")
        h.emit(root, "lib/runtime.h", "write", 3)
        t.assert_eq(#h.observed, 1)
        t.assert_eq(h.observed[1].name, "lib/runtime.h")
      end, "CreateFileW failed (Win32 error " .. code .. ")")
    end)
  end
  for _, value in ipairs({
    {tool = false, reason = "CreateFileW failed (Win32 error 5)"},
    {tool = false, reason = "CreateFileW failed (Win32 error 19)"},
    {tool = true, reason = "WriteFile failed (Win32 error 5)"},
    {tool = true, reason = "FlushFileBuffers failed (Win32 error 5)"},
    {tool = true, reason = "CreateFileW failed (Win32 error 32)"},
  }) do
    t.it("denial cannot bypass barrier for " .. tostring(value.tool) .. " " .. value.reason, function()
      protocol({{path = "C:/protocol-denial", recursive = true, tool_root = value.tool}}, function(h)
        local result = request(h)
        completed(result)
        t.assert_false(result.ok)
        t.assert_nil(h.group.readonly_tool_roots["C:/protocol-denial"])
        t.assert_eq(result.reason, "barrier-marker:" .. value.reason)
      end, value.reason)
    end)
  end
  t.it("mixed writable and readonly tool roots retain both writable stream acknowledgements", function()
    protocol({"C:/protocol-writable", {path = "C:/protocol-readonly", recursive = true, tool_root = true}}, function(h)
      local result = request(h)
      t.assert_true(h.group.readonly_tool_roots["C:/protocol-readonly"])
      h.ack(1, "metadata")
      vim.wait(20, function() return result.calls > 0 end, 1)
      t.assert_eq(result.calls, 0, "tool identity substitution cannot acknowledge a writable stream")
      h.ack(1, "write")
      completed(result)
      t.assert_true(result.ok)
      t.assert_eq(#h.markers, 2)
      local second = request(h)
      t.assert_eq(#h.markers, 3, "subsequent barrier still writes the writable root")
      for _, stream in ipairs({"metadata", "write"}) do
        h.emit("C:/protocol-writable", vim.fs.basename(h.markers[3]), stream, stream == "write" and 3 or 1)
      end
      completed(second)
      t.assert_true(second.ok)
    end, function(path)
      if path:find("C:/protocol-readonly/", 1, true) then return "CreateFileW failed (Win32 error 5)" end
    end)
  end)
  t.it("direct and recursive subscriptions on the same path require separate acknowledgements", function()
    protocol({ { path = "C:/protocol", recursive = false }, { path = "C:/protocol", recursive = true } }, function(h)
      local result = request(h)
      t.assert_true(h.markers[1] ~= h.markers[2], "each subscription needs a unique marker")
      h.ack(1, "metadata")
      h.ack(1, "write")
      for _, stream in ipairs({ "metadata", "write" }) do
        h.emit("C:/protocol", vim.fs.basename(h.markers[2]), stream, stream == "write" and 3 or 1, nil, nil, false)
      end
      vim.wait(20, function() return result.calls > 0 end, 1)
      t.assert_eq(result.calls, 0)
      h.ack(2, "metadata")
      h.ack(2, "write")
      completed(result)
      t.assert_true(result.ok)
      t.assert_eq(#h.observed, 0)
    end)
  end)

  for _, cleanup_failure in ipairs({ false, true }) do
    t.it(cleanup_failure and "cleanup failure revokes acknowledged success" or "success waits for every marker cleanup", function()
      local releases = {}
      protocol({ "C:/protocol-a", "C:/protocol-b" }, function(h)
        local result = request(h)
        for index = 1, 2 do h.ack(index, "metadata"); h.ack(index, "write") end
        t.assert_eq(#releases, 2)
        vim.wait(20, function() return result.calls > 0 end, 1)
        t.assert_eq(result.calls, 0, "ACK alone cannot report success before cleanup")
        releases[1](true)
        vim.wait(20, function() return result.calls > 0 end, 1)
        t.assert_eq(result.calls, 0, "all marker owners must finish cleanup")
        releases[2](not cleanup_failure, cleanup_failure and "owner close denied" or nil)
        completed(result)
        t.assert_eq(result.ok, not cleanup_failure)
        if cleanup_failure then t.assert_match(result.reason, "barrier%-cleanup:owner close denied") end
      end, nil, function(_, done) releases[#releases + 1] = done end)
    end)
  end

  t.it("requires metadata and write acknowledgements from every root", function()
    protocol({ "C:/protocol-a", "C:/protocol-b" }, function(h)
      local result = request(h)
      t.assert_eq(#h.markers, 2)
      h.ack(1, "metadata")
      h.ack(1, "metadata") -- duplicate must not consume another root
      h.ack(2, "write")
      vim.wait(20, function() return result.calls > 0 end, 1)
      t.assert_eq(result.calls, 0)
      h.ack(1, "write")
      t.assert_eq(result.calls, 0)
      h.ack(2, "metadata")
      completed(result)
      t.assert_true(result.ok)
      t.assert_eq(#h.observed, 0, "owned markers must stay inside the watcher wrapper")
    end)
  end)

  t.it("same-process markers are private across groups and cannot acknowledge another group", function()
    protocol({ "C:/protocol-shared" }, function(first)
      local first_result = request(first)
      protocol({ "C:/protocol-shared" }, function(second)
        local second_result = request(second)
        local first_name, second_name = vim.fs.basename(first.markers[1]), vim.fs.basename(second.markers[1])
        t.assert_true(first_name ~= second_name)
        for _, stream in ipairs({ "metadata", "write" }) do
          local action = stream == "write" and 3 or 1
          second.emit("C:/protocol-shared", first_name, stream, action)
          first.emit("C:/protocol-shared", second_name, stream, action)
        end
        vim.wait(20, function() return first_result.calls > 0 or second_result.calls > 0 end, 1)
        t.assert_eq(first_result.calls, 0)
        t.assert_eq(second_result.calls, 0)
        t.assert_eq(#first.observed, 0)
        t.assert_eq(#second.observed, 0)
        first.ack(1, "metadata")
        first.ack(1, "write")
        second.ack(1, "metadata")
        second.ack(1, "write")
        completed(first_result)
        completed(second_result)
        t.assert_true(first_result.ok)
        t.assert_true(second_result.ok)
        local unregistered = ".nvim-ue-watch-barrier-unregistered.tmp"
        first.emit("C:/protocol-shared", unregistered, "metadata", 1)
        t.assert_eq(#first.observed, 1, "marker-shaped names without registered ownership are normal input")
        t.assert_eq(first.observed[1].name, unregistered)
      end)
    end)
  end)

  t.it("parent root delivery cannot acknowledge a nested root subscription", function()
    protocol({ "C:/protocol", "C:/protocol/child" }, function(h)
      local result = request(h)
      h.ack(1, "metadata")
      h.ack(1, "write")
      local child_marker = "child/" .. vim.fs.basename(h.markers[2])
      h.emit("C:/protocol", child_marker, "metadata", 1)
      h.emit("C:/protocol", child_marker, "write", 3)
      vim.wait(20, function() return result.calls > 0 end, 1)
      t.assert_eq(result.calls, 0)
      h.ack(2, "metadata")
      h.ack(2, "write")
      completed(result)
      t.assert_true(result.ok)
    end)
  end)

  t.it("completion waits until callbacks after the marker in the same frame run", function()
    protocol({ "C:/protocol" }, function(h)
      local changed, seen
      h.group:barrier(function(ok) seen = { ok = ok, changed = changed } end)
      h.ack(1, "metadata")
      h.ack(1, "write")
      t.assert_nil(seen)
      h.emit("C:/protocol", "changed.cpp", "write", 3)
      changed = #h.observed == 1 and h.observed[1].name == "changed.cpp"
      t.assert_true(vim.wait(100, function() return seen ~= nil end, 1))
      t.assert_true(seen.ok)
      t.assert_true(seen.changed)
    end)
  end)

  for _, failure in ipairs({ "overflow", "error" }) do
    t.it("same-frame " .. failure .. " revokes success after all marker acknowledgements", function()
      protocol({ "C:/protocol" }, function(h)
        local result = request(h)
        h.ack(1, "metadata")
        h.ack(1, "write")
        t.assert_eq(result.calls, 0, "success must remain pending until the native frame finishes")
        h.emit("C:/protocol", "changed.cpp", "write", 3,
          failure == "error" and "native failure after marker" or nil,
          failure == "overflow" and { overflow = true } or nil)
        completed(result)
        t.assert_false(result.ok, "queued success must not conceal a later native-frame failure")
        t.assert_eq(result.reason, "barrier-watch-unknown")
      end)
    end)
  end

  for _, failure in ipairs({ "error", "overflow", "unknown", "missing-name", "close" }) do
    t.it("fails closed on " .. failure, function()
      protocol({ "C:/protocol" }, function(h)
        local result = request(h)
        if failure == "close" then
          h.group:close()
        else
          local name = "changed.cpp"
          if failure == "missing-name" then name = nil end
          h.emit("C:/protocol", name, "write", 3,
            failure == "error" and "native failure" or nil,
            failure == "overflow" and { overflow = true } or failure == "unknown" and { unknown = true } or nil)
        end
        completed(result)
        t.assert_false(result.ok)
        t.assert_match(result.reason, "barrier%-watch%-")
      end)
    end)
  end

  t.it("fails closed at the bounded 750 ms timeout", function()
    protocol({ "C:/protocol" }, function(h)
      local result = request(h)
      h.ack(1, "metadata")
      completed(result)
      t.assert_false(result.ok)
      t.assert_eq(result.reason, "barrier-timeout")
      t.assert_true(result.elapsed >= 700 and result.elapsed < 1100, tostring(result.elapsed))
    end)
  end)

  t.it("timeout starts from request time after a synchronous caller burst", function()
    protocol({ "C:/protocol" }, function(h)
      uv.update_time()
      local burst_started = uv.hrtime()
      -- Headless-only bounded CPU work reproduces libuv's stale cached clock.
      while (uv.hrtime() - burst_started) / 1e6 < 850 do end
      local result = request(h)
      h.ack(1, "metadata")
      completed(result)
      t.assert_false(result.ok)
      t.assert_eq(result.reason, "barrier-timeout")
      t.assert_true(result.elapsed >= 700 and result.elapsed < 1100, tostring(result.elapsed))
    end)
  end)

  t.it("marker creation failure cannot grant barrier success", function()
    protocol({ "C:/protocol" }, function(h)
      local result = request(h)
      completed(result)
      t.assert_false(result.ok)
      t.assert_match(result.reason, "barrier%-marker:denied")
    end, "denied")
  end)
end)

local driver = require("utils.platform").driver()
t.describe("platform watch barrier native", function()
  if type(driver.input_event_watcher) ~= "function" then
    t.skip("three native barriers and exclusive marker", "host driver has no native input watcher", { native = true })
    return
  end
  local python = require("utils.platform").resolve_tool({ name = "python", env = { "UE_PYTHON" },
    driver_candidates = function(value) return value.python_candidates() end })
  if not python.ok then
    t.skip("three native barriers and exclusive marker", "Python unavailable for native input watcher", { native = true })
    return
  end

  t.it("three consecutive writable-root barriers finish within one second without residue", function()
    local root = vim.fn.tempname():gsub("\\", "/") .. "_watch_barrier"
    vim.fn.mkdir(root, "p")
    root = vim.fs.normalize(assert(uv.fs_realpath(root)))
    local group, err
    local ok, failure = xpcall(function()
      require("workarounds.libuv.content_events").apply()
      group, err = driver.input_event_watcher({ { path = root, recursive = false } })
      t.assert_true(group ~= nil, err)
      local ready, failures = false, {}
      t.assert_true(group:watch(root, function(watch_err)
        if watch_err then failures[#failures + 1] = watch_err end
      end, { recursive = false, on_ready = function(value, reason)
        ready = value
        if not value then failures[#failures + 1] = reason or "watch not ready" end
      end }))
      t.assert_true(vim.wait(5500, function() return ready or #failures > 0 end, 10))
      t.assert_eq(#failures, 0, vim.inspect(failures))
      t.assert_true(ready)
      for index = 1, 3 do
        local result = request({ group = group })
        completed(result)
        t.assert_true(result.ok, "native barrier " .. index .. ": " .. tostring(result.reason))
        t.assert_true(result.elapsed < 1000, "elapsed ms: " .. tostring(result.elapsed))
        t.assert_eq(#vim.fn.glob(root .. "/.nvim-ue-watch-barrier-*.tmp", false, true), 0)
      end
      t.assert_eq(#failures, 0, vim.inspect(failures))
    end, debug.traceback)
    if group then group:close() end
    vim.fn.delete(root, "rf")
    if not ok then error(failure) end
  end)

  t.it("native marker refuses to replace an existing target", function()
    local path = vim.fn.tempname():gsub("\\", "/") .. "_watch_barrier.tmp"
    vim.fn.writefile({ "retain existing bytes" }, path)
    local ok, err = xpcall(function()
      local result
      marker.create(path, function(value, reason) result = { ok = value, reason = reason } end)
      t.assert_true(vim.wait(2000, function() return result ~= nil end, 5))
      t.assert_false(result.ok)
      t.assert_match(result.reason, "CreateFileW")
      t.assert_eq(vim.fn.readfile(path)[1], "retain existing bytes")
    end, debug.traceback)
    vim.fn.delete(path)
    if not ok then error(err) end
  end)
end)
