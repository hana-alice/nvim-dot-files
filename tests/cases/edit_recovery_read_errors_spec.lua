local t = require("tests.harness")
t.bootstrap()

-- One native process, bounded local fixtures, no capture/prune/child jobs.
-- Fixture files are retained; I/O errors are explicitly injected, not claimed
-- as evidence of the host's actual ACLs or a dead external process.
local function scope(fn)
  local dir = vim.fn.tempname() .. "-edit-recovery-read-errors"
  vim.fn.mkdir(dir, "p")
  local selected = vim.fs.normalize(vim.uv.fs_realpath(dir) or dir)
  local modules = { "ue", "ue.config", "utils.probe", "utils.edit_recovery" }
  local saved = {}
  for _, name in ipairs(modules) do
    saved[name] = package.loaded[name]
  end
  local native = { scandir = vim.uv.fs_scandir, open = vim.uv.fs_open }
  local notify, select = vim.notify, vim.ui.select
  local context = { dir = selected, notices = {}, probes = {} }
  context.journal = vim.fs.joinpath(selected, "journal")
  context.scan_root = vim.fs.joinpath(context.journal, vim.fn.sha256(selected):sub(1, 24))
  package.loaded.ue = { resolve_context = function() return { project_root = selected } end }
  package.loaded["ue.config"] = {
    get = function()
      return { enabled = false, root = context.journal, max_bytes = 2 * 1024 * 1024 }
    end,
  }
  package.loaded["utils.probe"] = {
    record = function(topic, key, data)
      context.probes[#context.probes + 1] = { topic = topic, key = key, data = data }
    end,
  }
  package.loaded["utils.edit_recovery"] = nil
  vim.notify = function(message, level)
    context.notices[#context.notices + 1] = { message = message, level = level }
  end
  vim.ui.select = function(items)
    context.shown = items
  end
  local ok, err = pcall(function() fn(require("utils.edit_recovery"), context) end)
  vim.uv.fs_scandir, vim.uv.fs_open = native.scandir, native.open
  vim.notify, vim.ui.select = notify, select
  for _, name in ipairs(modules) do
    package.loaded[name] = saved[name]
  end
  if not ok then
    error(err, 0)
  end
end

local function await(action)
  local done, values, count, fast = false
  action(function(...)
    values, count, fast = { ... }, select("#", ...), vim.in_fast_event()
    done = true
  end)
  t.assert_true(vim.wait(5000, function() return done end, 5), "recovery callback timeout")
  t.assert_false(fast, "recovery completion must leave the fast event")
  return unpack(values, 1, count)
end

local function snapshot(context, index)
  context.session = context.session or (vim.fn.getpid() .. "-" .. tostring(vim.uv.hrtime()))
  local directory = vim.fs.joinpath(context.scan_root, context.session)
  vim.fn.mkdir(directory, "p")
  local path = vim.fs.joinpath(directory, index .. ".json")
  local raw = vim.json.encode({
    version = 1, pid = vim.fn.getpid(), session = context.session, project = context.dir,
    name = "original.cpp", lines = { "retained text " .. index }, at = os.time(),
    filetype = "cpp", fileformat = "unix", fileencoding = "utf-8", bomb = false, endofline = true,
  })
  vim.fn.writefile({ raw }, path, "b")
  return path, raw
end

local function list(recovery, opts)
  return await(function(done) recovery.list(done, opts or { include_live = true }) end)
end

local function open_live(recovery)
  local original = recovery.list
  recovery.list = function(done, opts)
    original(done, vim.tbl_extend("force", {}, opts or {}, { include_live = true }))
  end
  recovery.open(false)
end

t.describe("edit_recovery_read_errors: recovery absence is proved only by a complete scan", function()
  t.it("ENOENT inside an EACCES path does not turn the denied scan into an empty store", function()
    scope(function(recovery, context)
      local scandir = vim.uv.fs_scandir
      vim.uv.fs_scandir = function(path, callback)
        if path == context.scan_root then
          vim.schedule(function() callback("EACCES: permission denied: /private/ENOENT/journal", nil) end)
          return {}
        end
        return scandir(path, callback)
      end
      local items, err, metadata = list(recovery)
      t.assert_eq(#items, 0); t.assert_contains(err, "EACCES")
      t.assert_eq(metadata.state, "unavailable"); t.assert_false(metadata.empty_store)
    end)
  end)
  t.it("report C11 EACCES is unavailable and WARN, never an empty-success message", function()
    scope(function(recovery, context)
      local scandir = vim.uv.fs_scandir
      vim.uv.fs_scandir = function(path, callback)
        if path == context.scan_root then
          vim.schedule(function() callback("EACCES: injected recovery directory denial", nil) end)
          return {}
        end
        return scandir(path, callback)
      end
      local items, err, metadata = list(recovery)
      t.assert_eq(#items, 0)
      t.assert_contains(err, "EACCES")
      t.assert_eq(metadata.state, "unavailable")
      t.assert_eq(metadata.error_count, 1)
      t.assert_eq(metadata.errors[1].stage, "scan")
      t.assert_false(metadata.truncated)
      t.assert_eq(context.probes[1].key, "read-failed")
      recovery.open(false)
      t.assert_true(vim.wait(5000, function() return #context.notices > 0 end, 5))
      t.assert_eq(#context.notices, 1)
      t.assert_eq(context.notices[1].level, vim.log.levels.WARN)
      t.assert_contains(context.notices[1].message, "无法确认")
      t.assert_contains(context.notices[1].message, "EACCES")
      t.assert_false(context.notices[1].message:find("没有可恢复", 1, true))
    end)
  end)

  t.it("initial missing store ENOENT remains a complete, ordinary empty result", function()
    scope(function(recovery, context)
      t.assert_nil(vim.uv.fs_stat(context.scan_root), "fixture must actually start without a store")
      local items, err, metadata = list(recovery)
      t.assert_eq(#items, 0)
      t.assert_nil(err)
      t.assert_eq(metadata.state, "complete")
      t.assert_true(metadata.empty_store)
      t.assert_eq(metadata.error_count, 0)
      recovery.open(false)
      t.assert_true(vim.wait(5000, function() return #context.notices > 0 end, 5))
      t.assert_eq(context.notices[1].level, vim.log.levels.INFO)
      t.assert_contains(context.notices[1].message, "没有可恢复")
      t.assert_eq(#context.probes, 0)
    end)
  end)

  t.it("nested ENOENT is incomplete rather than an initial empty store", function()
    scope(function(recovery, context)
      local path = snapshot(context, 1)
      local directory, scandir = vim.fs.dirname(path), vim.uv.fs_scandir
      vim.uv.fs_scandir = function(scan_path, callback)
        if scan_path == directory then
          vim.schedule(function() callback("ENOENT: injected disappearing session directory", nil) end)
          return {}
        end
        return scandir(scan_path, callback)
      end
      local items, err, metadata = list(recovery)
      t.assert_eq(#items, 0)
      t.assert_contains(err, "ENOENT")
      t.assert_eq(metadata.state, "unavailable")
      t.assert_false(metadata.empty_store)
      t.assert_true(vim.uv.fs_stat(path), "failed scan must retain the actual fixture snapshot")
    end)
  end)

  t.it("one unreadable snapshot retains the valid partial result and concrete error", function()
    scope(function(recovery, context)
      local good = snapshot(context, 1)
      local bad, raw = snapshot(context, 2)
      local fs_open = vim.uv.fs_open
      vim.uv.fs_open = function(path, flags, mode, callback)
        if path == bad then
          vim.schedule(function() callback("EACCES: injected unreadable recovery snapshot", nil) end)
          return {}
        end
        return fs_open(path, flags, mode, callback)
      end
      local items, err, metadata = list(recovery)
      t.assert_eq(#items, 1)
      t.assert_eq(items[1].path, good)
      t.assert_contains(err, "EACCES")
      t.assert_eq(metadata.state, "partial")
      t.assert_eq(metadata.errors[1].stage, "read")
      t.assert_eq(table.concat(vim.fn.readfile(bad, "b"), "\n"), raw)
      open_live(recovery)
      t.assert_true(vim.wait(5000, function() return context.shown ~= nil end, 5))
      t.assert_eq(#context.shown, 1)
      t.assert_eq(context.shown[1].path, good)
      t.assert_eq(context.notices[1].level, vim.log.levels.WARN)
      t.assert_contains(context.notices[1].message, "部分记录读取失败")
      t.assert_eq(table.concat(vim.fn.readfile(bad, "b"), "\n"), raw, "picker must retain unreadable bytes")
    end)
  end)

  t.it("confirmed invalid JSON stays excluded but is visible in metadata and WARN", function()
    scope(function(recovery, context)
      local path = snapshot(context, 1)
      local raw = '{"version":'
      vim.fn.writefile({ raw }, path, "b")
      local items, err, metadata = list(recovery)
      t.assert_eq(#items, 0)
      t.assert_nil(err, "known-invalid snapshot exclusion remains compatible")
      t.assert_eq(metadata.state, "unavailable")
      t.assert_contains(metadata.errors[1].reason, "invalid recovery snapshot")
      open_live(recovery)
      t.assert_true(vim.wait(5000, function() return #context.notices > 0 end, 5))
      t.assert_eq(context.notices[1].level, vim.log.levels.WARN)
      t.assert_false(context.notices[1].message:find("没有可恢复", 1, true))
      t.assert_eq(table.concat(vim.fn.readfile(path, "b"), "\n"), raw)
    end)
  end)

  t.it("error samples and notification reasons are bounded while total count is accurate", function()
    scope(function(recovery, context)
      local unreadable = {}
      for index = 1, 12 do unreadable[snapshot(context, index)] = true end
      local fs_open = vim.uv.fs_open
      vim.uv.fs_open = function(path, flags, mode, callback)
        if unreadable[path] then
          vim.schedule(function() callback("EIO:\n" .. string.rep("x", 1000), nil) end)
          return {}
        end
        return fs_open(path, flags, mode, callback)
      end
      local items, err, metadata = list(recovery)
      t.assert_eq(#items, 0)
      t.assert_eq(metadata.state, "unavailable")
      t.assert_eq(metadata.error_count, 12)
      t.assert_eq(#metadata.errors, 8)
      t.assert_true(#err <= 160)
      t.assert_false(err:find("\n", 1, true))
      for _, item in ipairs(metadata.errors) do t.assert_true(#item.reason <= 160) end
    end)
  end)
end)
