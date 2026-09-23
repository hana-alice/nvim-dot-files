local t = require("tests.harness")
t.bootstrap()
local native = require("workarounds.libuv.content_events")
local uv = vim.uv

local function fixture(junction, body)
  local driver = require("utils.platform").driver()
  if driver.id ~= "windows" then t.skip("native directory classification", "Windows host required"); return end
  local python = vim.fn.exepath("python")
  if python == "" then t.skip("native directory classification", "Python unavailable", { native = true }); return end
  local root = vim.fn.tempname():gsub("\\", "/") .. "_input_directory"
  vim.fn.mkdir(root, "p")
  root = vim.fs.normalize(assert(uv.fs_realpath(root)))
  local directory, target = root .. "/observed", root .. "/target"
  local linked, group, job = false, nil, nil
  local events, failures, ready = {}, {}, 0
  local ok, reason = xpcall(function()
    if junction then
      vim.fn.mkdir(target, "p")
      vim.fn.writefile({ "retained" }, target .. "/sentinel.txt")
      local created, err = uv.fs_symlink(target, directory, driver.directory_symlink_options())
      if not created then t.skip("native junction classification", err, { native = true }); return end
      linked = true
    else
      vim.fn.mkdir(directory, "p")
    end
    local target_before = junction and assert(uv.fs_stat(target .. "/sentinel.txt"))
    native.apply()
    group = assert(native.new_group(python, {
      { path = root, recursive = false }, { path = directory, recursive = true },
    }, { spawn = function(command, options) job = vim.fn.jobstart(command, options); return job end }))
    for _, item in ipairs({ { root, false }, { directory, true } }) do
      assert(group:watch(item[1], function(err, path, event)
        if err then failures[#failures + 1] = err
        else events[#events + 1] = { root = item[1], path = path, event = event } end
      end, { recursive = item[2], on_ready = function(value, err)
        if value then ready = ready + 1 else failures[#failures + 1] = err or "not ready" end
      end }))
    end
    t.assert_true(vim.wait(5000, function() return ready == 2 or #failures > 0 end, 10), "both streams were not ready")
    t.assert_eq(#failures, 0, vim.inspect(failures))
    t.assert_eq(ready, 2)
    local h = { root = root, directory = directory, events = events }
    function h.await(path, stream, action)
      local found
      t.assert_true(vim.wait(3000, function()
        for _, row in ipairs(events) do
          if row.root == root and row.path == path and row.event.stream == stream and row.event.action == action then
            found = row.event; return true
          end
        end
        return #failures > 0
      end, 10), "native event missing: " .. path .. "/" .. stream .. "/" .. action .. " " .. vim.inspect(events))
      t.assert_eq(#failures, 0, vim.inspect(failures))
      return assert(found, "watcher failed before matching native event")
    end
    function h.python(code)
      local reply
      local process = vim.system({ python, "-B", "-c", code, directory }, { text = true }, function(value) reply = value end)
      if not vim.wait(3000, function() return reply ~= nil end, 10) then
        process:kill(9); process:wait(3000); error("owned mutation process timed out")
      end
      t.assert_eq(reply.code, 0, reply.stderr)
    end
    body(h)
    t.assert_eq(#failures, 0, vim.inspect(failures))
    if junction then
      t.assert_eq(vim.fn.readfile(target .. "/sentinel.txt")[1], "retained")
      t.assert_true(vim.deep_equal(uv.fs_stat(target .. "/sentinel.txt").mtime, target_before.mtime))
    end
  end, debug.traceback)
  if group then group:close() end
  if job and job > 0 then t.assert_true(vim.fn.jobwait({ job }, 5000)[1] ~= -1, "owned input helper did not exit") end
  -- Never traverse the target during fixture cleanup, including failed assertions.
  if linked then
    t.assert_eq(vim.fs.dirname(directory), root)
    t.assert_eq(vim.fs.dirname(target), root)
    assert(uv.fs_unlink(directory), "remove owned junction before recursive cleanup")
    t.assert_nil(uv.fs_lstat(directory))
  end
  t.assert_eq(vim.fs.normalize(assert(uv.fs_realpath(root))), root)
  vim.fn.delete(root, "rf")
  if not ok then error(reason) end
end

t.describe("native input directory classification", function()
  t.it("attests a configured ordinary directory write after both streams are armed", function()
    fixture(false, function(h)
      local before = assert(uv.fs_stat(h.directory))
      assert(uv.fs_utime(h.directory, before.atime.sec, before.mtime.sec + 2))
      local event = h.await("observed", "write", 3)
      t.assert_true(event.directory)
      t.assert_true(event.stable_directory_write)
      t.assert_eq(uv.fs_stat(h.directory).ino, before.ino)
    end)
  end)

  t.it("retains actual directory attribute changes as unattested metadata", function()
    fixture(false, function(h)
      h.python(table.concat({
        "import ctypes,sys",
        "k=ctypes.WinDLL('kernel32',use_last_error=True)",
        "k.GetFileAttributesW.argtypes=[ctypes.c_wchar_p]; k.GetFileAttributesW.restype=ctypes.c_uint32",
        "k.SetFileAttributesW.argtypes=[ctypes.c_wchar_p,ctypes.c_uint32]",
        "before=k.GetFileAttributesW(sys.argv[1]); assert before!=0xffffffff",
        "assert k.SetFileAttributesW(sys.argv[1],before^2)",
        "assert k.GetFileAttributesW(sys.argv[1])==before^2",
      }, "\n"))
      local event = h.await("observed", "metadata", 3)
      t.assert_true(event.directory)
      t.assert_false(event.stable_directory_write)
    end)
  end)

  t.it("retains actual directory rename namespace events without attestation", function()
    fixture(false, function(h)
      assert(uv.fs_rename(h.directory, h.root .. "/renamed"))
      for _, item in ipairs({ { "observed", 4 }, { "renamed", 5 } }) do
        local event = h.await(item[1], "metadata", item[2])
        t.assert_true(event.rename)
        t.assert_false(event.stable_directory_write)
      end
    end)
  end)

  t.it("forwards a real junction object's write without ordinary-directory attestation", function()
    fixture(true, function(h)
      -- SetFileTime on OPEN_REPARSE_POINT changes the junction object itself.
      -- Silent in-place target swaps are a separately recorded native capability gap.
      h.python(table.concat({
        "import ctypes,sys,time", "from ctypes import wintypes as w",
        "k=ctypes.WinDLL('kernel32',use_last_error=True)",
        "k.CreateFileW.argtypes=[w.LPCWSTR,w.DWORD,w.DWORD,ctypes.c_void_p,w.DWORD,w.DWORD,w.HANDLE]; k.CreateFileW.restype=w.HANDLE",
        "k.SetFileTime.argtypes=[w.HANDLE,ctypes.c_void_p,ctypes.c_void_p,ctypes.POINTER(w.FILETIME)]",
        "k.CloseHandle.argtypes=[w.HANDLE]",
        "handle=k.CreateFileW(sys.argv[1],0x100,7,None,3,0x02200000,None)",
        "assert handle and handle!=ctypes.c_void_p(-1).value",
        "stamp=time.time_ns()//100+116444736000000000+20000000; value=w.FILETIME(stamp&0xffffffff,stamp>>32)",
        "try: assert k.SetFileTime(handle,None,None,ctypes.byref(value))",
        "finally: k.CloseHandle(handle)",
      }, "\n"))
      local event = h.await("observed", "write", 3)
      t.assert_true(event.directory)
      t.assert_false(event.stable_directory_write, "a configured reparse point is never an ordinary directory")
    end)
  end)
end)
