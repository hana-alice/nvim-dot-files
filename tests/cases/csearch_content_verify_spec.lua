local t = require("tests.harness")
t.bootstrap()
local verify = require("ue.csearch_verify")
local cs = require("utils.code_search")

local function await(start)
  local done, values, count = false
  start(function(...) values, count, done = { ... }, select("#", ...), true end)
  t.assert_true(vim.wait(15000, function() return done end, 10), "content-check timeout")
  return unpack(values, 1, count)
end

t.describe("csearch trigram content verification", function()
  t.it("list read failures never publish a partially read list", function()
    local path = vim.fn.tempname() .. ".files"
    vim.fn.writefile({ "promised.cpp" }, path)
    local read = vim.uv.fs_read
    vim.uv.fs_read = function(_, _, _, callback)
      vim.schedule(function() callback("EIO: owned read failure") end)
    end
    local lines, failure
    local ok, err = xpcall(function()
      lines, failure = await(function(cb) verify.read_list(path, cb) end)
    end, debug.traceback)
    vim.uv.fs_read = read
    if not ok then error(err) end
    t.assert_nil(lines)
    t.assert_contains(failure, "EIO")
  end)

  t.it("bounds changed and random samples without duplicates", function()
    local changed, all = {}, {}
    for n = 1, 100 do changed[n], all[n] = "Changed" .. n, "Other" .. n end
    local paths = verify.sample(changed, all, function() return 1 end)
    t.assert_eq(#paths, 20)
    t.assert_eq(paths[1], "Changed1")
    t.assert_eq(paths[17], "Other1")
    local seen = {}
    for _, path in ipairs(paths) do seen[path] = true end
    t.assert_eq(vim.tbl_count(seen), 20)
  end)

  t.it("smart publication retains the filtered repair snapshot", function()
    local root = vim.fn.tempname():gsub("\\", "/") .. "_repair_snapshot"
    vim.fn.mkdir(root, "p")
    local files = {}
    for i = 1, 8 do files[i] = root .. "/Member" .. i .. ".cpp" end
    local idx, full, repaired = root .. "/index.idx", root .. "/all.files", root .. "/repair.files"
    vim.fn.writefile(files, full)
    vim.fn.writefile(files, idx .. ".files")
    local remaining = vim.list_slice(files, 1, 7)
    vim.fn.writefile(remaining, repaired)
    local watch = require("utils.ue_watch")
    local build, status, snapshot = cs.build_index, watch.persistent_dirty_status, watch.snapshot_persistent_dirty
    watch.persistent_dirty_status = function() return { capped = false } end
    watch.snapshot_persistent_dirty = function() return { files[1] } end
    cs.build_index = function(_, _, cb)
      cb(true, nil, { repair_reset = true, repair_input = repaired })
    end
    local valid, failure
    local ok, err = xpcall(function()
      valid, failure = await(function(cb)
        require("ue.csearch_smart").csearch_smart_build({ paths = { csearch_idx = idx } },
          { csearch_idx = idx }, full, cb, {})
      end)
    end, debug.traceback)
    cs.build_index, watch.persistent_dirty_status, watch.snapshot_persistent_dirty = build, status, snapshot
    if not ok then error(err) end
    t.assert_true(valid, failure)
    t.assert_eq(table.concat(vim.fn.readfile(idx .. ".files"), "\n"), table.concat(remaining, "\n"))
  end)

  local tool = vim.env.NVIM_W1_CINDEX or cs.cindex_uefilter_exe()
  if not tool or not cs.csearch_exe() then
    t.skip("native content self-check and repair", "cindex/csearch unavailable", { native = true })
    return
  end
  local function fixture(body)
    local root = vim.fn.tempname():gsub("\\", "/") .. "_content_check"
    vim.fn.mkdir(root .. "/Source With Spaces", "p")
    local files = {}
    for n = 1, 8 do
      local path = root .. "/Source With Spaces/Member" .. n .. ".cpp"
      vim.fn.writefile({ "static int ORIGINAL_CONTENT_MARKER_" .. n .. " = 1;" }, path)
      files[n] = path
    end
    local ctx = { workspace_root = root, csearch_idx = root .. "/index.idx" }
    local full = root .. "/all.files"
    vim.fn.writefile(files, full)
    local original = cs.cindex_uefilter_exe
    cs.cindex_uefilter_exe = function() return tool end
    local ok, err = xpcall(function()
      local built, failure = await(function(cb) cs.build_index(ctx, full, cb, { mode = "reset" }) end)
      t.assert_true(built, failure)
      vim.fn.writefile(files, ctx.csearch_idx .. ".files")
      body(root, ctx, files, full)
    end, debug.traceback)
    cs.cindex_uefilter_exe = original
    if not ok then error(err) end
    -- Keep owned fixture evidence; never remove the user's index.
  end

  t.it("detects stale trigrams even when generic text can still read the current disk file", function()
    fixture(function(root, ctx, files)
      vim.fn.writefile({ "static int FRESH_CONTENT_LONG_IDENTIFIER = 2;" }, files[1])
      local function query(token)
        return vim.system({ cs.csearch_exe(), "-l", "-f", "Member1.cpp", token },
          { text = true, env = { CSEARCHINDEX = ctx.csearch_idx } }):wait()
      end
      t.assert_eq(query("static").code, 0)
      t.assert_eq(query("FRESH_CONTENT_LONG_IDENTIFIER").code, 1)
      local valid, failure, stats = await(function(cb) verify.check(ctx, { files[1] }, cb) end)
      t.assert_false(valid)
      t.assert_contains(failure, "trigram content mismatch")
      t.assert_eq(stats.token, "FRESH_CONTENT_LONG_IDENTIFIER")
      vim.fn.writefile({ vim.json.encode({ valid = valid, failure = failure, stats = stats }) }, root .. "/evidence.json")
    end)
  end)

  t.it("intentional text exclusions and truncated files do not cause repair loops", function()
    fixture(function(_, ctx, files, full)
      vim.fn.writefile({ "LONG_EXCLUDED_CONTENT_IDENTIFIER" .. string.rep("x", 2001) }, files[1])
      vim.fn.writefile({ "INVALID_EXCLUDED_CONTENT_IDENTIFIER" .. string.char(255) }, files[2])
      local lines = {}
      for n = 1, 3000 do lines[n] = "LARGE_FILE_CONTENT_IDENTIFIER" end
      vim.fn.writefile(lines, files[3])
      local built, err = await(function(cb) cs.build_index(ctx, full, cb, { mode = "reset" }) end)
      t.assert_true(built, err)
      local valid, failure, stats = await(function(cb) verify.check(ctx, { files[1], files[2], files[3] }, cb) end)
      t.assert_true(valid, failure)
      t.assert_eq(stats.checked_tokens, 0)
      t.assert_eq(stats.skipped_files, 3)
    end)
  end)

  t.it("repairs exactly once before success while retaining the caller writer lease", function()
    fixture(function(root, ctx, files, full)
      vim.fn.writefile({ "static int FRESH_REPAIRED_CONTENT_IDENTIFIER = 3;" }, files[1])
      local delta, empty = root .. "/delta.files", root .. "/empty.files"
      vim.fn.writefile({ files[1] }, delta)
      vim.fn.writefile({}, empty)
      local lock = require("ue.file_lock")
      local lease = assert(lock.acquire(root .. "/writer.lock"))
      local spawn, record = vim.loop.spawn, require("utils.probe").record
      local calls, probes = {}, {}
      vim.loop.spawn = function(exe, opts, callback)
        if exe == tool then
          local reset = vim.tbl_contains(opts.args, "-reset")
          calls[#calls + 1] = reset and "reset" or "add"
          t.assert_nil(lock.acquire(root .. "/writer.lock"), "repair must keep the existing lease")
          if not reset then
            opts = vim.tbl_extend("force", opts, { args = vim.deepcopy(opts.args) })
            -- Real cindex exits successfully with an empty delta: reproduce a
            -- partial/omitted update without a fake executable or fake index.
            for n, arg in ipairs(opts.args) do if arg == "-files-from" then opts.args[n + 1] = empty end end
          end
        end
        return spawn(exe, opts, callback)
      end
      require("utils.probe").record = function(topic, key, data)
        probes[#probes + 1] = { topic = topic, key = key, data = data }
      end
      local success, failure, stats
      local passed, err = xpcall(function()
        success, failure, stats = await(function(cb)
          cs.build_index(ctx, delta, cb, { mode = "add", complete_list_path = full })
        end)
      end, debug.traceback)
      vim.loop.spawn, require("utils.probe").record = spawn, record
      lock.release(lease)
      if not passed then error(err) end
      t.assert_true(success, failure)
      t.assert_true(stats.repair_reset)
      t.assert_eq(table.concat(calls, ","), "add,reset")
      t.assert_eq(probes[1].key, "trigram-mismatch")
      t.assert_eq(probes[1].data.state, "inconsistent")
      local valid = await(function(cb) verify.check(ctx, { files[1], files[8] }, cb) end)
      t.assert_true(valid, "both repaired and untouched files must remain searchable")
      t.assert_eq(#vim.fn.readfile(ctx.csearch_idx .. ".files"), 8)
      vim.fn.writefile({ vim.json.encode({ calls = calls, probes = probes, stats = stats }) }, root .. "/repair.json")
    end)
  end)

  t.it("query errors are not misreported as content mismatches or reset loops", function()
    fixture(function(_, ctx, files)
      local system = vim.system
      vim.system = function(_, _, callback)
        vim.schedule(function() callback({ code = 2, stderr = "real-query failure seam" }) end)
        return { is_closing = function() return true end }
      end
      local valid, failure = await(function(cb) verify.check(ctx, { files[1] }, cb) end)
      vim.system = system
      t.assert_nil(valid)
      t.assert_contains(failure, "verification query failed")
    end)
  end)

  t.it("failed automatic reset never advances the snapshot or triggers a second reset", function()
    fixture(function(root, ctx, files, full)
      vim.fn.writefile({ "static int FAILED_REPAIR_CONTENT_IDENTIFIER = 4;" }, files[1])
      local empty = root .. "/empty.files"
      vim.fn.writefile({}, empty)
      local spawn = vim.loop.spawn
      local watch = require("utils.ue_watch")
      local status, snapshot = watch.persistent_dirty_status, watch.snapshot_persistent_dirty
      local resets = 0
      watch.persistent_dirty_status = function() return { capped = false } end
      watch.snapshot_persistent_dirty = function() return { files[1] } end
      vim.loop.spawn = function(exe, opts, callback)
        if exe == tool then
          if vim.tbl_contains(opts.args, "-reset") then
            resets = resets + 1
            return nil, "owned reset failure seam"
          end
          opts = vim.tbl_extend("force", opts, { args = vim.deepcopy(opts.args) })
          for n, arg in ipairs(opts.args) do if arg == "-files-from" then opts.args[n + 1] = empty end end
        end
        return spawn(exe, opts, callback)
      end
      local valid, failure, stats
      local repair_list = verify.repair_list
      local ok, err = xpcall(function()
        verify.repair_list = function(_, _, _, cb) cb(nil, "owned repair input read failure") end
        valid, failure, stats = await(function(cb)
          require("ue.csearch_smart").csearch_smart_build({ paths = { csearch_idx = ctx.csearch_idx } },
            ctx, full, cb, {})
        end)
        t.assert_false(valid)
        t.assert_contains(failure, "repair input read failure")
        t.assert_true(stats.repair_attempted)
        t.assert_eq(resets, 0, "unavailable full repair input must not fall back to another reset")
        verify.repair_list = repair_list
        valid, failure, stats = await(function(cb)
          require("ue.csearch_smart").csearch_smart_build({ paths = { csearch_idx = ctx.csearch_idx } },
            ctx, full, cb, {})
        end)
      end, debug.traceback)
      verify.repair_list = repair_list
      vim.loop.spawn = spawn
      watch.persistent_dirty_status, watch.snapshot_persistent_dirty = status, snapshot
      if not ok then error(err) end
      t.assert_false(valid)
      t.assert_contains(failure, "failed to spawn")
      t.assert_true(stats.repair_attempted)
      t.assert_eq(resets, 1)
      t.assert_eq(table.concat(vim.fn.readfile(ctx.csearch_idx .. ".files"), "\n"), table.concat(files, "\n"))
      t.assert_nil(vim.uv.fs_stat(ctx.csearch_idx .. ".git-baseline.json"))
    end)
  end)
end)
