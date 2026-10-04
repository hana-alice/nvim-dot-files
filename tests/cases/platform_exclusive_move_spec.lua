local t = require("tests.harness")
t.bootstrap()

local driver = require("utils.platform").driver()
local uv = vim.uv
local ffi_ok = pcall(require, "ffi")
if not uv.new_work or not ffi_ok then
  t.skip("native exclusive move", "libuv workers and LuaJIT FFI are required", { native = true })
  return
end

local sequence = 0
local function fixture(fn)
  sequence = sequence + 1
  local parent = vim.env.NVIM_TEST_RUN_ROOT or vim.fn.tempname()
  local root = vim.fs.joinpath(parent, "exclusive_move_" .. sequence)
  vim.fn.mkdir(root, "p")
  root = assert(uv.fs_realpath(root)):gsub("\\", "/")
  local ok, err = xpcall(function()
    fn(root)
  end, debug.traceback)
  vim.fn.delete(root, "rf")
  if not ok then
    error(err, 0)
  end
end

local function write(path, text)
  local fd = assert(uv.fs_open(path, "wx", 384))
  assert(uv.fs_write(fd, text, 0))
  assert(uv.fs_close(fd))
end

local function read(path)
  local fd = assert(uv.fs_open(path, "r", 384))
  local size = assert(uv.fs_fstat(fd)).size
  local bytes = assert(uv.fs_read(fd, size, 0))
  assert(uv.fs_close(fd))
  return bytes
end

local function move(from, to)
  t.assert_type(driver.rename_no_replace, "function")
  local result, count, inline = nil, 0, true
  local queued, queue_err = driver.rename_no_replace(from, to, function(ok, err)
    count = count + 1
    result = { ok = ok, err = err, fast = vim.in_fast_event(), inline = inline }
    vim.api.nvim_get_current_win()
  end)
  inline = false
  t.assert_true(
    vim.wait(5000, function()
      return result ~= nil
    end, 5),
    "native callback completed"
  )
  t.assert_eq(count, 1)
  t.assert_false(result.inline)
  t.assert_false(result.fast)
  return result, queued, queue_err
end

t.describe("platform native no-replace move", function()
  t.it("keeps the optional capability on real drivers and absent from the stub", function()
    for _, id in ipairs({ "windows", "linux", "macos" }) do
      t.assert_type(require("utils.platform." .. id).rename_no_replace, "function")
    end
    t.assert_nil(require("utils.platform.stub").rename_no_replace)
  end)

  t.it("moves a real file asynchronously and preserves bytes", function()
    fixture(function(root)
      local from, to = root .. "/before.txt", root .. "/after.txt"
      write(from, "source\0bytes\n")
      local result, queued = move(from, to)
      t.assert_true(queued)
      t.assert_true(result.ok, result.err)
      t.assert_nil(result.err)
      t.assert_nil(uv.fs_lstat(from))
      t.assert_eq(read(to), "source\0bytes\n")
    end)
  end)

  t.it("moves Unicode files including supplementary UTF-16 characters", function()
    fixture(function(root)
      local from, to = root .. "/源😀 file.txt", root .. "/目标🚀 file.txt"
      write(from, "unicode bytes")
      local result = move(from, to)
      t.assert_true(result.ok, result.err)
      t.assert_nil(uv.fs_lstat(from))
      t.assert_eq(read(to), "unicode bytes")
    end)
  end)

  t.it("moves nonempty Unicode directories without copying their children", function()
    fixture(function(root)
      local from, to = root .. "/源😀 directory", root .. "/目标🚀 directory"
      vim.fn.mkdir(from, "p")
      write(from .. "/nested.txt", "directory child")
      local original = assert(uv.fs_stat(from .. "/nested.txt"))
      local result = move(from, to)
      t.assert_true(result.ok, result.err)
      t.assert_nil(uv.fs_lstat(from))
      t.assert_eq(read(to .. "/nested.txt"), "directory child")
      local moved = assert(uv.fs_stat(to .. "/nested.txt"))
      t.assert_eq(moved.ino, original.ino)
      t.assert_eq(moved.dev, original.dev)
    end)
  end)

  for _, source_kind in ipairs({ "file", "directory" }) do
    for _, target_kind in ipairs({ "file", "directory" }) do
      t.it("refuses existing " .. target_kind .. " for " .. source_kind, function()
        fixture(function(root)
          local from, to = root .. "/source", root .. "/destination"
          if source_kind == "directory" then
            vim.fn.mkdir(from)
          else
            write(from, "source remains")
          end
          if target_kind == "directory" then
            vim.fn.mkdir(to)
          else
            write(to, "target remains")
          end
          local result = move(from, to)
          t.assert_false(result.ok)
          t.assert_type(result.err, "string")
          t.assert_true(#result.err > 0)
          t.assert_eq(assert(uv.fs_lstat(from)).type, source_kind)
          t.assert_eq(assert(uv.fs_lstat(to)).type, target_kind)
          if source_kind == "file" then
            t.assert_eq(read(from), "source remains")
          end
          if target_kind == "file" then
            t.assert_eq(read(to), "target remains")
          end
        end)
      end)
    end
  end

  t.it("reports missing sources and invalid paths without mutation", function()
    fixture(function(root)
      local result = move(root .. "/missing", root .. "/target")
      t.assert_false(result.ok)
      t.assert_type(result.err, "string")
      write(root .. "/source", "source remains")
      for _, path in ipairs({ "", "relative-target", root .. "/target\0suffix" }) do
        result = move(root .. "/source", path)
        t.assert_false(result.ok)
        t.assert_type(result.err, "string")
        t.assert_eq(read(root .. "/source"), "source remains")
      end
      t.assert_nil(uv.fs_lstat(root .. "/target"))
    end)
  end)

  t.it("fails closed when worker support is absent without ordinary rename fallback", function()
    fixture(function(root)
      write(root .. "/source", "source remains")
      local native_work, ordinary_rename = uv.new_work, uv.fs_rename
      uv.new_work = nil
      uv.fs_rename = function()
        error("ordinary rename fallback attempted")
      end
      local ok, result, queued = pcall(move, root .. "/source", root .. "/target")
      uv.new_work, uv.fs_rename = native_work, ordinary_rename
      t.assert_true(ok, tostring(result))
      t.assert_false(queued)
      t.assert_false(result.ok)
      t.assert_contains(result.err, "worker support")
      t.assert_eq(read(root .. "/source"), "source remains")
      t.assert_nil(uv.fs_lstat(root .. "/target"))
    end)
  end)

  t.it("rejects malformed Windows UTF-8 instead of silently changing the destination", function()
    if driver.id ~= "windows" then
      return t.skip("strict Windows UTF-8 conversion", "Windows host required")
    end
    fixture(function(root)
      write(root .. "/source", "source remains")
      local result = move(root .. "/source", root .. "/bad_" .. string.char(0xC0, 0xAF))
      t.assert_false(result.ok)
      t.assert_contains(result.err, "UTF-8")
      t.assert_eq(read(root .. "/source"), "source remains")
    end)
  end)

  t.it("refuses targets created after queueing while the main loop remains usable", function()
    fixture(function(root)
      local script = root .. "/race.lua"
      local code = [=[
local cfg, root = arg[1], arg[2]
package.path = cfg .. "/lua/?.lua;" .. cfg .. "/lua/?/init.lua;" .. package.path
local uv = vim.uv
local driver = require("utils.platform").driver()
assert(type(driver.rename_no_replace) == "function", "rename_no_replace missing")
local function write(path, bytes)
  local fd = assert(uv.fs_open(path, "wx", 384))
  assert(uv.fs_write(fd, bytes, 0)); assert(uv.fs_close(fd))
end
local function read(path)
  local fd = assert(uv.fs_open(path, "r", 384))
  local bytes = assert(uv.fs_read(fd, assert(uv.fs_fstat(fd)).size, 0))
  assert(uv.fs_close(fd)); return bytes
end
for _, kind in ipairs({ "file", "directory" }) do
  local base = root .. "/race_" .. kind
  assert(vim.fn.mkdir(base) == 1)
  local from, to = base .. "/source", base .. "/target"
  if kind == "directory" then
    assert(vim.fn.mkdir(from) == 1); write(from .. "/child.txt", "source remains")
  else write(from, "source remains") end
  local blocked, result, heartbeat, count = nil, nil, false, 0
  local blocker = uv.new_work(function(base)
    local uv = require("luv")
    local fd = assert(uv.fs_open(base .. "/ready", "wx", 384)); assert(uv.fs_close(fd))
    for _ = 1, 1000 do
      if uv.fs_stat(base .. "/release") then return true end
      uv.sleep(5)
    end
    return false
  end, function(ok) blocked = ok end)
  assert(blocker:queue(base))
  assert(vim.wait(2000, function() return uv.fs_stat(base .. "/ready") ~= nil end, 5))
  assert(driver.rename_no_replace(from, to, function(ok, err)
    count = count + 1
    result = { ok = ok, err = err, fast = vim.in_fast_event() }
    vim.api.nvim_get_current_win()
  end))
  -- UV_THREADPOOL_SIZE=1: this is after enqueue and before the actual syscall.
  if kind == "directory" then
    assert(vim.fn.mkdir(to) == 1); write(to .. "/child.txt", "target remains")
  else write(to, "target remains") end
  vim.schedule(function() heartbeat = true end)
  assert(vim.wait(500, function() return heartbeat end, 5))
  assert(result == nil, "native move ran before the blocker was released")
  write(base .. "/release", "release")
  assert(vim.wait(5000, function() return result ~= nil and blocked ~= nil end, 5))
  assert(blocked and count == 1 and not result.fast)
  assert(result.ok == false and type(result.err) == "string")
  local suffix = kind == "directory" and "/child.txt" or ""
  assert(read(from .. suffix) == "source remains")
  assert(read(to .. suffix) == "target remains")
end
io.write("PASS: native late-target file/directory refusal; main loop heartbeat\n")
]=]
      write(script, code)
      local result = vim
        .system(
          { vim.v.progpath, "-u", "NONE", "-i", "NONE", "--headless", "-l", script, vim.fn.stdpath("config"), root },
          { env = { UV_THREADPOOL_SIZE = "1" }, text = true }
        )
        :wait(15000)
      t.assert_eq(result.code, 0, result.stderr)
      t.assert_contains(result.stdout, "PASS: native late-target")
    end)
  end)
end)
