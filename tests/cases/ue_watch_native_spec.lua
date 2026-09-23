local t = require("tests.harness")
local cfg = t.bootstrap()

local function transport()
  local native = require("workarounds.libuv.content_events")
  native.apply()
  local callbacks, timeouts, stops, messages = {}, {}, {}, {}
  local handle = assert(native.new("python", {
    spawn = function(_, options) callbacks = options; return 91 end,
    stop = function(job) stops[#stops + 1] = job end,
    defer = function(fn) timeouts[#timeouts + 1] = fn end,
    register = function() end,
  }))
  t.assert_true(handle:start("C:/fixture", {}, function(err, path, event)
    messages[#messages + 1] = { err = err, path = path, event = event }
  end) ~= nil)
  return handle, callbacks, timeouts, stops, messages
end

t.describe("native watcher transport", function()
  t.it("handles fragmented and combined frames, preserving native actions", function()
    local h, cb, _, _, messages = transport()
    cb.on_stdout(91, { '{"v":1,"kind":"rea' })
    t.assert_eq(h.phase, "starting")
    cb.on_stdout(91, { 'dy"}', '{"v":1,"kind":"events","events":[{"path":"sub\\\\file.h","action":3},{"path":"old.h","action":4}]}', '' })
    t.assert_eq(h.phase, "running")
    t.assert_eq(messages[1].event.ready, true)
    t.assert_eq(messages[2].path, "sub/file.h")
    t.assert_eq(messages[2].event.change, true)
    t.assert_eq(messages[3].event.rename, true)
    h:stop()
  end)

  t.it("stop invalidates queued stdout, exit and startup timeout", function()
    local h, cb, timers, stops, messages = transport()
    h:stop(); h:close()
    cb.on_stdout(91, { '{"v":1,"kind":"ready"}', '' })
    cb.on_exit(91, 1)
    timers[1]()
    t.assert_eq(#messages, 0)
    t.assert_eq(#stops, 1)
  end)

  t.it("overflow is explicit and the next source event is retained", function()
    local h, cb, _, _, messages = transport()
    cb.on_stdout(91, { '{"v":1,"kind":"ready"}', '{"v":1,"kind":"overflow"}',
      '{"v":1,"kind":"events","events":[{"path":"keep.h","action":1}]}', '' })
    t.assert_true(messages[2].event.overflow)
    t.assert_eq(messages[3].path, "keep.h")
    h:stop()
  end)

  for _, frame in ipairs({ 'not json', '{"v":1,"kind":"events","events":[{"path":"../escape.h","action":3}]}',
    '{"v":1,"kind":"events","events":[{"path":"C:/escape.h","action":3}]}',
    '{"v":1,"kind":"events","events":[{"path":"ok.h","action":9}]}',
    '{"v":2,"kind":"ready"}' }) do
    t.it("rejects malformed or unsafe frame: " .. frame, function()
      local h, cb, _, stops, messages = transport()
      cb.on_stdout(91, { frame, '' })
      t.assert_eq(h.phase, "error")
      t.assert_eq(#stops, 1)
      t.assert_true(messages[1].err ~= nil)
      t.assert_nil(messages[1].path)
    end)
  end

  t.it("bounds incomplete frames and reports missing readiness and unexpected exit", function()
    local h, cb, _, _, messages = transport()
    cb.on_stdout(91, { string.rep("x", 1024 * 1024 + 1) })
    t.assert_eq(h.phase, "error")
    t.assert_true(messages[1].err ~= nil)
    h, cb, _, _, messages = transport()
    cb.on_exit(91, 0)
    t.assert_eq(h.phase, "error")
    t.assert_true(messages[1].err ~= nil)
    local timers
    h, cb, timers, _, messages = transport()
    timers[1]()
    t.assert_eq(h.phase, "error")
    t.assert_true(messages[1].err ~= nil)
  end)
end)

t.describe("native Windows filter", function()
  t.it("drops access-only SetFileTime but keeps a write with preserved mtime", function()
    if vim.fn.has("win32") ~= 1 and vim.fn.has("win64") ~= 1 then
      t.skip("Windows-only native filter", "current host is not Windows")
      return
    end
    local python = vim.fn.exepath("python")
    if python == "" then
      t.skip("Windows-only native filter", "python unavailable")
      return
    end
    local root = vim.fn.tempname():gsub("\\", "/")
    vim.fn.mkdir(root, "p")
    local source = root .. "/sample.cpp"
    vim.fn.writefile({ "int value = 1;" }, source)
    local handle = assert(require("utils.platform.windows").content_event_watcher())
    local events, ready = {}, false
    local ok, err = pcall(function()
      t.assert_true(handle:start(root, {}, function(event_err, path, event)
        t.assert_nil(event_err)
        if event.ready then ready = true; return end
        events[#events + 1] = { path = path, event = event }
      end) ~= nil)
      t.assert_true(vim.wait(5000, function() return ready end, 20), "native helper not ready")
      local set_atime = table.concat({
        "import ctypes, sys, time",
        "from ctypes import wintypes",
        "k=ctypes.WinDLL('kernel32',use_last_error=True)",
        "h=k.CreateFileW(sys.argv[1],0x0100,7,None,3,0,None)",
        "if h in (0,ctypes.c_void_p(-1).value): raise ctypes.WinError(ctypes.get_last_error())",
        "class FT(ctypes.Structure): _fields_=[('low',wintypes.DWORD),('high',wintypes.DWORD)]",
        "n=int(time.time()*10000000+116444736000000000); ft=FT(n&0xffffffff,n>>32)",
        "k.SetFileTime.argtypes=[wintypes.HANDLE,ctypes.c_void_p,ctypes.POINTER(FT),ctypes.c_void_p]",
        "k.SetFileTime.restype=wintypes.BOOL",
        "if not k.SetFileTime(h,None,ctypes.byref(ft),None): raise ctypes.WinError(ctypes.get_last_error())",
        "k.CloseHandle(h)",
      }, "\n")
      local done, failure = false, nil
      vim.system({ python, "-c", set_atime, source }, { text = true }, function(result)
        failure = result.code ~= 0 and (result.stderr or result.stdout or "SetFileTime failed") or nil
        done = true
      end)
      t.assert_true(vim.wait(3000, function() return done end, 20), "SetFileTime timed out")
      t.assert_nil(failure)
      vim.wait(500, function() return false end, 10)
      t.assert_eq(#events, 0, "access-only update must be filtered at subscription")

      local before = assert(vim.uv.fs_stat(source))
      vim.fn.writefile({ "int value = 2;" }, source)
      vim.uv.fs_utime(source, before.mtime.sec, before.mtime.sec)
      t.assert_true(vim.wait(3000, function() return #events > 0 end, 20),
        "real write with preserved mtime was lost")
    end)
    pcall(handle.stop, handle); pcall(handle.close, handle)
    pcall(vim.fn.delete, root, "rf")
    if not ok then error(err) end
    t.assert_eq(events[1].path, "sample.cpp")
  end)
end)

t.describe("native watcher host ownership", function()
  t.it("only Windows exposes the optional watcher factory", function()
    t.assert_type(require("utils.platform.windows").content_event_watcher, "function")
    for _, name in ipairs({ "macos", "linux", "stub" }) do
      t.assert_nil(require("utils.platform." .. name).content_event_watcher)
    end
  end)
end)

t.describe("ue_watch native integration", function()
  local watch = require("utils.ue_watch")

  local function fake_handle(capture)
    local handle = { phase = "stopped" }
    function handle:start(_, _, callback)
      capture.callback = callback
      self.phase = "running"
      return 1
    end
    function handle:stop() self.phase = "stopped" end
    function handle:close() self.phase = "closed" end
    return handle
  end

  local function cleanup(root)
    watch.stop()
    watch._set_content_watcher_for_test(nil)
    pcall(vim.fn.delete, root, "rf")
  end

  t.it("ignores OMX artifact events without suppressing real source refresh", function()
    local root = vim.fn.tempname():gsub("\\", "/")
    vim.fn.mkdir(root .. "/.omx/artifacts", "p")
    vim.fn.mkdir(root .. "/Source", "p")
    for _, path in ipairs({ "/.omx/artifacts/copy.cpp", "/.omx/artifacts/shim.h", "/Source/real.cpp" }) do
      vim.fn.writefile({ "int source_value;" }, root .. path)
    end
    local capture, delivered, injected = {}, {}, {}
    local owner, state, scheduled, restarts = {}, {}, 0, 0
    local ctx = { engine_root = root, paths = {} }
    local core = { RT = {}, deps = { status_root_key = function() return root end }, h = {
      ensure_index_state = function() return state end, save_index_state = function() end,
    } }
    owner.mark_module_dirty = function() end
    owner.clear_module_dirty_flags = function() end
    owner.schedule_index_refresh = function() scheduled = scheduled + 1 end
    owner.schedule_index_phase = function() scheduled = scheduled + 1 end
    require("ue.index._source")(owner, core)
    local function deliver()
      return owner.deliver_source_refresh(ctx, {}, { restart = function(_, complete)
        restarts = restarts + 1; complete(true); return true
      end })
    end
    local function drain()
      local done = false
      vim.schedule(function() done = true end)
      t.assert_true(vim.wait(500, function() return done end, 10), "scheduled events did not drain")
    end
    local previous_ue = package.loaded.ue
    package.loaded.ue = { cdb_inject_paths = function(paths)
      vim.list_extend(injected, paths); return true
    end }
    watch._set_content_watcher_for_test(function() return fake_handle(capture) end)
    local ok, err = pcall(function()
      t.assert_true(watch.start({ root = root, debounce_ms = 60000,
        dirty_json_path = root .. "/dirty.json", on_source_changed = function(path)
          delivered[#delivered + 1] = path
          owner.check_source(ctx, path)
        end,
      }))
      capture.callback(nil, nil, { ready = true })
      local before = watch.status().last_event_at
      capture.callback(nil, ".omx/artifacts/copy.cpp", { change = true })
      capture.callback(nil, ".omx/artifacts/shim.h", { rename = true })
      capture.callback(nil, ".omx/artifacts/deleted.cpp", { rename = true })
      drain()
      t.assert_eq(watch.status().pending_adds, 0)
      t.assert_eq(watch.status().pending_dels, 0)
      t.assert_eq(watch.status().last_event_at, before, "artifact events must not arm the flush timer")
      watch.flush_now(); drain()
      t.assert_eq(#delivered, 0)
      t.assert_eq(#injected, 0)
      t.assert_eq(#watch.snapshot_persistent_dirty(), 0)
      t.assert_eq(state.source_revision or 0, 0)
      t.assert_eq(scheduled, 0)
      t.assert_false(deliver())
      t.assert_eq(restarts, 0)

      capture.callback(nil, "Source/real.cpp", { change = true })
      drain()
      t.assert_eq(watch.status().pending_adds, 1)
      watch.flush_now()
      t.assert_true(vim.wait(500, function() return state.source_revision == 1 end, 10))
      t.assert_true(vim.deep_equal(delivered, { root .. "/Source/real.cpp" }))
      t.assert_true(vim.deep_equal(injected, delivered))
      t.assert_true(vim.deep_equal(watch.snapshot_persistent_dirty(), delivered))
      t.assert_eq(scheduled, 1)
      t.assert_true(deliver())
      t.assert_eq(restarts, 1)
      t.assert_eq(state.source_delivered, 1)
    end)
    cleanup(root)
    package.loaded.ue = previous_ue
    if not ok then error(err) end
  end)

  t.it("selects the driver watcher and preserves native writes with old mtimes", function()
    local root = vim.fn.tempname():gsub("\\", "/")
    vim.fn.mkdir(root, "p")
    local source, index = root .. "/native.cpp", root .. "/csearch.idx"
    vim.fn.writefile({ "int native_source;" }, source)
    vim.fn.writefile({ "index" }, index)
    vim.uv.fs_utime(source, 1000, 1000)
    vim.uv.fs_utime(index, 2000, 2000)

    local capture, fake = {}, nil
    fake = fake_handle(capture)
    watch._set_content_watcher_for_test(function() return fake end)
    local ok, err = pcall(function()
      t.assert_true(watch.start({
        root = root,
        csearch_index = index,
        dirty_json_path = root .. "/dirty.json",
      }), "native watcher start failed")
      capture.callback(nil, nil, { ready = true })
      t.assert_true(vim.wait(500, function() return watch.status().native_ready end, 10),
        "native watcher did not become ready")
      capture.callback(nil, "native.cpp", { change = true })
      t.assert_true(vim.wait(500, function() return watch.status().pending_adds == 1 end, 10),
        "native write was filtered by the csearch timestamp")
      t.assert_eq(watch.status().watch_mode, "native")
    end)
    cleanup(root)
    if not ok then error(err) end
  end)

  t.it("coalesces an unresolved native gap until observation resumes", function()
    local root = vim.fn.tempname():gsub("\\", "/")
    vim.fn.mkdir(root, "p")
    local capture, unknown = {}, 0
    local fake = fake_handle(capture)
    watch._set_content_watcher_for_test(function() return fake end)
    local ok, err = pcall(function()
      t.assert_true(watch.start({
        root = root,
        dirty_json_path = root .. "/dirty.json",
        on_source_unknown = function() unknown = unknown + 1 end,
      }))
      capture.callback(nil, nil, { ready = true })
      t.assert_true(vim.wait(500, function() return watch.status().native_ready end, 10))
      capture.callback(nil, nil, { overflow = true, unknown = true })
      capture.callback(nil, nil, { overflow = true, unknown = true })
      t.assert_true(vim.wait(500, function() return unknown == 1 end, 10),
        "repeated overflow should be coalesced")
      t.assert_true(watch.status().unknown_coverage)
      capture.callback(nil, nil, { ready = true })
      capture.callback(nil, nil, { overflow = true, unknown = true })
      t.assert_true(vim.wait(500, function() return unknown == 2 end, 10),
        "a new gap after readiness must be reportable")
      t.assert_contains(watch.status().unknown_coverage_reason, "overflow")
    end)
    cleanup(root)
    if not ok then error(err) end
  end)

  t.it("falls back to libuv while exposing native unavailability", function()
    local root = vim.fn.tempname():gsub("\\", "/")
    vim.fn.mkdir(root, "p")
    local unknown = 0
    watch._set_content_watcher_for_test(function()
      return nil, "python missing"
    end)
    local ok, err = pcall(function()
      t.assert_true(watch.start({
        root = root,
        dirty_json_path = root .. "/dirty.json",
        on_source_unknown = function() unknown = unknown + 1 end,
      }))
      local status = watch.status()
      t.assert_eq(status.watch_mode, "libuv")
      t.assert_true(status.unknown_coverage)
      t.assert_contains(status.unknown_coverage_reason, "python missing")
      t.assert_eq(unknown, 1)
    end)
    cleanup(root)
    if not ok then error(err) end
  end)
end)
