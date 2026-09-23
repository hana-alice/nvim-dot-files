local t = require("tests.harness")
t.bootstrap()
local native = require("workarounds.libuv.content_events")

local function transport()
  native.apply()
  local callbacks, timers, stopped, sent = nil, {}, {}, {}
  local group = assert(native.new_group("python", {
    { path = "C:/fixture/source", recursive = true }, { path = "C:/fixture/lookup", recursive = false },
  }, { spawn = function(command, options)
      t.assert_true(vim.tbl_contains(command, "--group")); callbacks = options; return 82
    end,
    send = function(job, text) sent[#sent + 1] = { job, text }; return #text end,
    stop = function(job) stopped[#stopped + 1] = job end,
    schedule = function(fn) fn() end,
    defer = function(fn) timers[#timers + 1] = fn end, register = function() end }))
  local function frame(id, kind, events, stream)
    callbacks.on_stdout(82, { vim.json.encode({ v = 1, root_id = id, kind = kind, events = events,
      stream = stream, streams = kind == "ready" and { "metadata", "write" } or nil }), "" })
  end
  return group, callbacks, timers, stopped, sent, frame
end

t.describe("grouped native input transport", function()
  t.it("sends bounded roots through stdin and retains early readiness", function()
    local group, _, _, stopped, sent, frame = transport()
    local config = vim.json.decode(sent[1][2])
    t.assert_eq(#config.roots, 2)
    t.assert_eq(config.roots[2].recursive, false)
    frame(1, "ready"); frame(2, "ready")
    local ready, events = {}, {}
    local one, capability = group:watch("C:/fixture/source", function(_, path) events[#events + 1] = path end,
      { recursive = true, on_ready = function(ok) ready[#ready + 1] = ok end })
    local two = group:watch("C:/fixture/lookup", function(_, path) events[#events + 1] = path end,
      { recursive = false, on_ready = function(ok) ready[#ready + 1] = ok end })
    t.assert_true(capability.pending and capability.recursive)
    t.assert_eq(#ready, 2)
    one:close()
    frame(2, "events", { { path = "driver.exe", action = 3 } })
    t.assert_eq(events[1], "driver.exe")
    t.assert_eq(#stopped, 0, "closing a virtual handle must retain siblings")
    two:close(); group:close(); group:close()
    t.assert_eq(#stopped, 1)
  end)

  t.it("an early actual change fails registered and future roots", function()
    local group, _, _, stopped, _, frame = transport()
    local errors, readiness = {}, {}
    group:watch("C:/fixture/source", function(err) errors[#errors + 1] = err end,
      { recursive = true, on_ready = function(ok) readiness[#readiness + 1] = ok end })
    frame(2, "ready")
    frame(2, "events", { { path = "new.exe", action = 1 } })
    t.assert_eq(group.phase, "error")
    t.assert_eq(readiness[1], false)
    t.assert_eq(#errors, 1)
    local later = group:watch("C:/fixture/lookup", function() end, { recursive = false, on_ready = function() end })
    t.assert_nil(later)
    t.assert_eq(#stopped, 1)
    group:close()
  end)

  t.it("forwards stream classification without dropping metadata or legacy events", function()
    local group, _, _, _, _, frame = transport()
    local events = {}
    group:watch("C:/fixture/source", function(err, path, event)
      t.assert_nil(err); events[#events + 1] = { path = path, event = event }
    end, { recursive = true, on_ready = function(ok) t.assert_true(ok) end })
    frame(1, "ready")
    frame(1, "events", { { path = "stable", action = 3, directory = true, stable_directory_write = true } }, "write")
    frame(1, "events", { { path = "stable", action = 3, directory = true } }, "metadata")
    frame(1, "events", { { path = "stable", action = 3, directory = true } })
    t.assert_eq(#events, 3)
    t.assert_true(events[1].event.stable_directory_write)
    t.assert_eq(events[1].event.stream, "write")
    t.assert_eq(events[2].event.stream, "metadata")
    t.assert_false(events[2].event.stable_directory_write)
    t.assert_nil(events[3].event.stream)
    t.assert_false(events[3].event.stable_directory_write)
    group:close()
  end)

  for index, sample in ipairs({
    { stream = "other", directory = true, action = 3 },
    { stream = "metadata", directory = true, action = 3, stable_directory_write = true },
    { directory = true, action = 3, stable_directory_write = true },
    { stream = "write", directory = false, action = 3, stable_directory_write = true },
    { stream = "write", directory = true, action = 4, stable_directory_write = true },
    { stream = "write", directory = true, action = 3, stable_directory_write = "true" },
  }) do
    t.it("rejects malformed directory classification " .. index, function()
      local group, _, _, _, _, frame = transport()
      local failure
      group:watch("C:/fixture/source", function(err) failure = err end,
        { recursive = true, on_ready = function() end })
      frame(1, "ready")
      frame(1, "events", { { path = "root", directory = sample.directory,
        action = sample.action, stable_directory_write = sample.stable_directory_write } }, sample.stream)
      t.assert_eq(group.phase, "error")
      t.assert_true(failure ~= nil)
      group:close()
    end)
  end

  for _, readiness in ipairs({ '{"v":1,"root_id":1,"kind":"ready","streams":["metadata"]}',
    '{"v":1,"root_id":1,"kind":"ready"}' }) do
    t.it("refuses unproven stream readiness: " .. readiness, function()
      local group, callbacks = transport()
      local failed
      group:watch("C:/fixture/source", function(err) failed = err end,
        { recursive = true, on_ready = function(ok) t.assert_false(ok) end })
      callbacks.on_stdout(82, { readiness, "" })
      t.assert_eq(group.phase, "error")
      t.assert_true(failed ~= nil)
      group:close()
    end)
  end

  for _, failure in ipairs({ "overflow", "error", "bad-id", "bad-path", "timeout", "exit", "duplicate-ready", "oversized" }) do
    t.it("fails closed across roots on " .. failure, function()
      local group, callbacks, timers, stopped, _, frame = transport()
      local errors, ready = {}, {}
      group:watch("C:/fixture/source", function(err) errors[#errors + 1] = err end,
        { recursive = true, on_ready = function(ok) ready[#ready + 1] = ok end })
      if failure == "timeout" then timers[1]()
      elseif failure == "exit" then callbacks.on_exit(82, 0)
      elseif failure == "bad-id" then frame(9, "ready")
      elseif failure == "oversized" then callbacks.on_stdout(82, { string.rep("x", 1024 * 1024 + 1) })
      else
        frame(1, "ready")
        if failure == "bad-path" then frame(1, "events", { { path = "../escape", action = 3 } })
        elseif failure == "duplicate-ready" then frame(1, "ready")
        else frame(1, failure) end
      end
      t.assert_eq(group.phase, "error")
      t.assert_eq(#errors, 1)
      t.assert_eq(#ready, 1, "readiness must settle once")
      t.assert_eq(#stopped, 1)
      group:close()
    end)
  end

  t.it("stops partial installation and ignores late frames", function()
    local group, callbacks, timers, stopped, _, frame = transport()
    local called = 0
    group:watch("C:/fixture/source", function() called = called + 1 end,
      { recursive = true, on_ready = function() called = called + 1 end })
    group:close(); frame(1, "ready"); callbacks.on_exit(82, 1); timers[1]()
    t.assert_eq(called, 0)
    t.assert_eq(#stopped, 1)
  end)
end)

t.describe("input directory annotation boundaries", function()
  t.it("requires an exact configured ordinary directory with unchanged identity", function()
    local python = vim.fn.exepath("python")
    if python == "" then t.skip("directory annotation helper", "python unavailable"); return end
    local code = table.concat({
      "import importlib.util,os,stat,sys,types",
      "sys.dont_write_bytecode=True",
      "spec=importlib.util.spec_from_file_location('input_watch',sys.argv[1]); m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)",
      "root=os.path.abspath('fixture-parent'); child=os.path.join(root,'child'); key=os.path.normcase(child)",
      "current=types.SimpleNamespace(st_mode=stat.S_IFDIR,st_file_attributes=16,st_dev=9,st_ino=12)",
      "m.os.lstat=lambda path: current",
      "baseline={key:m.ordinary_directory_identity(child)}",
      "event={'path':'child','directory':True,'action':3}",
      "assert m.input_event(root,'write',event,baseline)['stable_directory_write'] is True",
      "assert 'stable_directory_write' not in m.input_event(root,'metadata',event,baseline)",
      "assert 'stable_directory_write' not in m.input_event(root,'write',dict(event,path='child/descendant'),baseline)",
      "assert 'stable_directory_write' not in m.input_event(root,'write',dict(event,action=1),baseline)",
      "assert 'stable_directory_write' not in m.input_event(root,'write',dict(event,directory=False),baseline)",
      "current.st_ino=13; assert 'stable_directory_write' not in m.input_event(root,'write',event,baseline)",
      "current.st_ino=12; current.st_file_attributes=16|1024; assert m.ordinary_directory_identity(child) is None",
      "current.st_file_attributes=16; current.st_ino=0; assert m.ordinary_directory_identity(child) is None",
      "current.st_ino=12; current.st_dev=0; assert m.ordinary_directory_identity(child) is None",
      "current.st_dev=9; current.st_mode=stat.S_IFREG; assert m.ordinary_directory_identity(child) is None",
      "def missing(path): raise OSError('unavailable')",
      "m.os.lstat=missing; assert m.ordinary_directory_identity(child) is None",
      "assert m.FILTER==0x1b and m.INPUT_STREAMS=={'metadata':0x147,'write':0x18}",
      "print('directory annotation boundaries passed')",
    }, "\n")
    local result = vim.system({ python, "-B", "-c", code,
      vim.fn.getcwd() .. "/lua/workarounds/libuv/content_events.py" }, { text = true }):wait(5000)
    t.assert_eq(result.code, 0, result.stderr)
  end)
end)

t.describe("native Windows frozen input filters", function()
  t.it("ignores access but retains writes, attributes and namespace with direct/recursive isolation", function()
    if vim.fn.has("win32") ~= 1 and vim.fn.has("win64") ~= 1 then
      t.skip("native Windows input group", "current host is not Windows"); return
    end
    local python = vim.fn.exepath("python")
    if python == "" then
      if vim.env.NVIM_TEST_REQUIRE_NATIVE == "1" then error("native Python required") end
      t.skip("native Windows input group", "python unavailable"); return
    end
    local root = vim.fn.tempname():gsub("\\", "/")
    local source, lookup = root .. "/source", root .. "/lookup"
    vim.fn.mkdir(source .. "/nested", "p"); vim.fn.mkdir(lookup .. "/nested", "p")
    local file = source .. "/test.h"
    vim.fn.writefile({ "int a;" }, file)
    local group, events, ready = nil, {}, 0
    local function drain(ms) vim.wait(ms, function() return false end, 10) end
    local function script(code, path)
      local done, failure = false, nil
      vim.system({ python, "-c", code, path }, { text = true }, function(reply)
        failure = reply.code ~= 0 and reply.stderr or nil; done = true
      end)
      t.assert_true(vim.wait(3000, function() return done end, 10), "native mutation timeout")
      t.assert_nil(failure)
    end
    local ok, err = pcall(function()
      group = assert(native.new_group(python, {
        { path = source, recursive = true }, { path = lookup, recursive = false },
      }))
      for _, item in ipairs({ { source, true }, { lookup, false } }) do
        assert(group:watch(item[1], function(event_err, path, event)
          t.assert_nil(event_err)
          events[#events + 1] = { root = item[1], path = path, event = event }
        end, { recursive = item[2], on_ready = function(value, reason)
          t.assert_true(value, reason); ready = ready + 1
        end }))
      end
      t.assert_true(vim.wait(5000, function() return ready == 2 end, 10), "group not ready")
      drain(300); events = {}
      local atime = table.concat({
        "import ctypes,sys,time", "from ctypes import wintypes as w", "k=ctypes.WinDLL('kernel32',use_last_error=True)",
        "k.CreateFileW.argtypes=[w.LPCWSTR,w.DWORD,w.DWORD,ctypes.c_void_p,w.DWORD,w.DWORD,w.HANDLE]; k.CreateFileW.restype=w.HANDLE",
        "k.SetFileTime.argtypes=[w.HANDLE,ctypes.c_void_p,ctypes.POINTER(w.FILETIME),ctypes.c_void_p]",
        "k.CloseHandle.argtypes=[w.HANDLE]", "h=k.CreateFileW(sys.argv[1],0x100,7,None,3,0,None)",
        "assert h and h!=ctypes.c_void_p(-1).value", "n=time.time_ns()//100+116444736000000000; stamp=w.FILETIME(n&0xffffffff,n>>32)",
        "assert k.SetFileTime(h,None,ctypes.byref(stamp),None); k.CloseHandle(h)",
      }, "\n")
      script(atime, file); drain(400)
      t.assert_eq(#events, 0, "LAST_ACCESS must not invalidate frozen input: " .. vim.inspect(events))
      local before = assert(vim.uv.fs_stat(file))
      vim.fn.writefile({ "int b;" }, file)
      vim.uv.fs_utime(file, before.mtime.sec, before.mtime.sec)
      t.assert_true(vim.wait(3000, function() return #events > 0 end, 10), "same-mtime write lost")
      t.assert_eq(events[1].path, "test.h")
      drain(200); events = {}
      vim.fn.writefile({ "nested" }, source .. "/nested/recursive.h")
      t.assert_true(vim.wait(3000, function()
        for _, event in ipairs(events) do if event.path == "nested/recursive.h" then return true end end
      end, 10), "recursive content creation lost")
      drain(200); events = {}
      script("import ctypes,sys\nk=ctypes.WinDLL('kernel32',use_last_error=True)\nk.GetFileAttributesW.argtypes=[ctypes.c_wchar_p]\nk.SetFileAttributesW.argtypes=[ctypes.c_wchar_p,ctypes.c_ulong]\na=k.GetFileAttributesW(sys.argv[1]); assert a!=-1\nassert k.SetFileAttributesW(sys.argv[1],a^2)", file)
      t.assert_true(vim.wait(3000, function() return #events > 0 end, 10), "attribute change lost")
      drain(200); events = {}
      vim.fn.writefile({ "nested" }, lookup .. "/nested/hidden.h")
      drain(300)
      for _, event in ipairs(events) do t.assert_false(event.path:find("hidden.h", 1, true) ~= nil, "direct watch recursed") end
      events = {}
      vim.fn.writefile({ "driver" }, lookup .. "/driver.exe")
      t.assert_true(vim.wait(3000, function()
        for _, event in ipairs(events) do if event.path == "driver.exe" then return true end end
      end, 10), "direct namespace creation lost")
      drain(200); events = {}
      assert(vim.uv.fs_rename(lookup .. "/driver.exe", lookup .. "/renamed.exe"))
      t.assert_true(vim.wait(3000, function()
        for _, event in ipairs(events) do if event.event.rename then return true end end
      end, 10), "rename lost")
    end)
    if group then group:close() end
    drain(100)
    pcall(vim.fn.delete, root, "rf")
    if not ok then error(err) end
  end)
end)
