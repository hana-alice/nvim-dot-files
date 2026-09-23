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
  local function frame(id, kind, events)
    callbacks.on_stdout(82, { vim.json.encode({ v = 1, root_id = id, kind = kind, events = events }), "" })
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
