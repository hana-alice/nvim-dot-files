local t = require("tests.harness")
t.bootstrap()

-- Use private watcher instances and real temporary files; never start a native
-- watcher or modify the test runner's existing watcher owner.
local function with_watchers(fn)
  local root = vim.fn.tempname():gsub("\\", "/")
  vim.fn.mkdir(root, "p")
  local original = package.loaded["utils.ue_watch"]
  local instances = {}
  local function open(name)
    local dir = root .. "/" .. (name or "A")
    vim.fn.mkdir(dir, "p")
    package.loaded["utils.ue_watch"] = nil
    local watch = require("utils.ue_watch")
    watch._set_opts_for_test({ root = dir, dirty_json_path = dir .. "/dirty.json" })
    instances[#instances + 1] = watch
    return watch, dir .. "/dirty.json", dir
  end
  local ok, err = xpcall(function() fn(open) end, debug.traceback)
  for _, watch in ipairs(instances) do
    watch._set_opts_for_test(nil)
  end
  package.loaded["utils.ue_watch"] = original
  vim.fn.delete(root, "rf")
  if not ok then error(err) end
end

local function flood(watch, dir)
  local files = {}
  for i = 1, 1100 do files[i] = ("%s/Source/f%04d.cpp"):format(dir, i) end
  watch._seed_persistent_dirty_for_test(files)
  watch._save_persistent_dirty_for_test()
end

t.describe("dirty overflow survives owner lifetime", function()
  t.it("keeps legacy newline path files readable through the shared reader", function()
    with_watchers(function(open)
      local watch, path, dir = open()
      vim.fn.writefile({ dir .. "/A.cpp", dir .. "/B.cpp" }, path)
      t.assert_eq(#watch.snapshot_persistent_dirty(), 2)
      t.assert_false(watch.persistent_dirty_status().capped)
    end)
  end)

  t.it("retains the path-array format and restores loss evidence in a fresh owner", function()
    with_watchers(function(open)
      local watch, path, dir = open()
      flood(watch, dir)
      local stored = vim.json.decode(table.concat(vim.fn.readfile(path), "\n"))
      t.assert_eq(#stored, 1000)
      t.assert_type(stored[1], "string")
      local reopened = open()
      local status = reopened.persistent_dirty_status()
      t.assert_eq(status.count, 1000)
      t.assert_true(status.capped, "a new owner must retain overflow evidence")
    end)
  end)

  t.it("another project remains clean and returning to the old bucket retains overflow", function()
    with_watchers(function(open)
      local watch, _, dir = open("A")
      flood(watch, dir)
      local other = open("B")
      t.assert_eq(other.persistent_dirty_status().count, 0)
      t.assert_false(other.persistent_dirty_status().capped)
      local returned = open("A")
      t.assert_true(returned.persistent_dirty_status().capped)
    end)
  end)

  t.it("subtracting every retained path leaves durable overflow with zero paths", function()
    with_watchers(function(open)
      local watch, _, dir = open()
      flood(watch, dir)
      t.assert_true(watch.remove_persistent_dirty(watch.snapshot_persistent_dirty(), "incremental"))
      local reopened = open()
      t.assert_eq(reopened.persistent_dirty_status().count, 0)
      t.assert_true(reopened.persistent_dirty_status().capped)
    end)
  end)

  t.it("status observes overflow published after its first empty read", function()
    with_watchers(function(open)
      local reader = open()
      t.assert_eq(reader.persistent_dirty_status().count, 0)
      local writer, _, dir = open()
      flood(writer, dir)
      t.assert_true(reader.persistent_dirty_status().capped)
    end)
  end)

  t.it("a successful reset can retire an old marker even with an empty snapshot", function()
    with_watchers(function(open)
      local watch, _, dir = open()
      flood(watch, dir)
      watch.remove_persistent_dirty(watch.snapshot_persistent_dirty(), "incremental")
      t.assert_true(watch.remove_persistent_dirty({}, "reset", os.time() + 10, true))
      t.assert_false(watch.persistent_dirty_status().capped)
      local reopened = open()
      t.assert_false(reopened.persistent_dirty_status().capped)
    end)
  end)

  t.it("reset keeps same-second overflow and concurrent unacknowledged paths", function()
    with_watchers(function(open)
      local watch, _, dir = open()
      local started_at = os.time()
      flood(watch, dir)
      local retained = watch.snapshot_persistent_dirty()
      local other = open()
      other._seed_persistent_dirty_for_test({ dir .. "/Source/z_later.cpp" })
      other._save_persistent_dirty_for_test()
      watch.remove_persistent_dirty(retained, "reset", started_at, true)
      local reopened = open()
      t.assert_true(reopened.persistent_dirty_status().capped)
      t.assert_true(vim.tbl_contains(reopened.snapshot_persistent_dirty(), dir .. "/Source/z_later.cpp"))
    end)
  end)

  t.it("unknown overflow marker content stays conservatively capped", function()
    with_watchers(function(open)
      local watch, path = open()
      vim.fn.writefile({ "[]" }, path)
      vim.fn.writefile({ "interrupted marker" }, path .. ".overflow")
      t.assert_true(watch.persistent_dirty_status().capped)
      watch.remove_persistent_dirty({}, "reset", os.time() + 10, true)
      t.assert_true(watch.persistent_dirty_status().capped)
    end)
  end)

  t.it("failure to publish the marker cannot publish a lossy path array", function()
    with_watchers(function(open)
      local watch, path, dir = open()
      watch._seed_persistent_dirty_for_test({ dir .. "/baseline.cpp" })
      watch._save_persistent_dirty_for_test()
      local before = table.concat(vim.fn.readfile(path), "\n")
      local rename, defer = vim.uv.fs_rename, vim.defer_fn
      vim.uv.fs_rename = function(source, destination)
        if destination == path .. ".overflow" then return nil, "injected marker publication failure" end
        return rename(source, destination)
      end
      vim.defer_fn = function() return { stop = function() end, close = function() end } end
      local ok, err = xpcall(function()
        flood(watch, dir)
        t.assert_eq(table.concat(vim.fn.readfile(path), "\n"), before)
      end, debug.traceback)
      vim.uv.fs_rename, vim.defer_fn = rename, defer
      -- Complete the owner-bound retry synchronously after restoring I/O.
      watch._save_persistent_dirty_for_test()
      if not ok then error(err) end
    end)
  end)

  t.it("failed reset publication retains its overflow evidence", function()
    with_watchers(function(open)
      local watch, path, dir = open()
      flood(watch, dir)
      local rename = vim.uv.fs_rename
      vim.uv.fs_rename = function(source, destination)
        if destination == path then return nil, "injected reset publication failure" end
        return rename(source, destination)
      end
      local ok, err = xpcall(function()
        t.assert_false(watch.remove_persistent_dirty(
          watch.snapshot_persistent_dirty(), "reset", os.time() + 10, true))
      end, debug.traceback)
      vim.uv.fs_rename = rename
      if not ok then error(err) end
      local reopened = open()
      t.assert_true(reopened.persistent_dirty_status().capped)
    end)
  end)

  t.it("failed marker deletion leaves durable overflow after path subtraction", function()
    with_watchers(function(open)
      local watch, path, dir = open()
      flood(watch, dir)
      local unlink = vim.uv.fs_unlink
      vim.uv.fs_unlink = function(target)
        if target == path .. ".overflow" then return nil, "injected unlink failure", "EPERM" end
        return unlink(target)
      end
      local ok, err = xpcall(function()
        t.assert_false(watch.remove_persistent_dirty(
          watch.snapshot_persistent_dirty(), "reset", os.time() + 10, true))
        t.assert_true(watch.persistent_dirty_status().capped)
      end, debug.traceback)
      vim.uv.fs_unlink = unlink
      if not ok then error(err) end
      local reopened = open()
      t.assert_true(reopened.persistent_dirty_status().capped)
    end)
  end)

  for _, case in ipairs({
    { "covered-reset", "write" }, { "covered-reset", "close" },
    { "manual-clear", "write" }, { "manual-clear", "close" },
  }) do
    local operation, failure = case[1], case[2]
    t.it("failed path " .. failure .. " cannot retire overflow: " .. operation, function()
      with_watchers(function(open)
        local watch, path, dir = open()
        flood(watch, dir)
        local before = table.concat(vim.fn.readfile(path), "\n")
        local io_open = io.open
        io.open = function(target, mode)
          local fd, err = io_open(target, mode)
          if fd and mode == "w" and target:sub(1, #path + 5) == path .. ".tmp." then
            return {
              write = function(_, data)
                if failure == "write" then return nil, "injected short write" end
                return fd:write(data)
              end,
              close = function()
                local closed = fd:close()
                if failure == "close" then return nil, "injected close failure" end
                return closed
              end,
            }
          end
          return fd, err
        end
        local ok, err = xpcall(function()
          local result
          if operation == "manual-clear" then result = watch.clear_persistent_dirty("manual")
          else result = watch.remove_persistent_dirty(
            watch.snapshot_persistent_dirty(), "reset", os.time() + 10, true) end
          t.assert_false(result)
          t.assert_eq(table.concat(vim.fn.readfile(path), "\n"), before)
        end, debug.traceback)
        io.open = io_open
        if not ok then error(err) end
        local reopened = open()
        t.assert_true(reopened.persistent_dirty_status().capped)
      end)
    end)
  end

  t.it("a repeated trim advances the marker beyond an older build cutoff", function()
    with_watchers(function(open)
      local watch, path, dir = open()
      local now = os.time
      local first = now()
      local ok, err = xpcall(function()
        os.time = function() return first end
        flood(watch, dir)
        os.time = function() return first + 2 end
        flood(watch, dir)
      end, debug.traceback)
      os.time = now
      if not ok then error(err) end
      local marker = vim.json.decode(table.concat(vim.fn.readfile(path .. ".overflow"), "\n"))
      t.assert_eq(marker.overflow_at, first + 2)
      watch.remove_persistent_dirty(watch.snapshot_persistent_dirty(), "older-reset", first + 1, true)
      local reopened = open()
      t.assert_true(reopened.persistent_dirty_status().capped)
    end)
  end)

  t.it("smart build requires a reset even when retained overflow paths are empty", function()
    local ue = require("ue")
    local mode = ue._csearch_build_mode_for_test({
      has_snapshot = true, added_n = 0, removed_n = 0, dirty_n = 0,
      total_n = 10000, dirty_capped = true,
    })
    t.assert_eq(mode, "reset")
  end)

  t.it("freshness stays stale with zero retained paths despite a matching list fingerprint", function()
    with_watchers(function(open)
      local watch, _, dir = open()
      flood(watch, dir)
      watch.remove_persistent_dirty(watch.snapshot_persistent_dirty(), "incremental")
      local ue, runtime = require("ue"), nil
      for i = 1, 30 do
        local name, value = debug.getupvalue(ue.cached_grep, i)
        if name == "CORE_RT" then runtime = value; break end
      end
      assert(runtime, "cached grep must retain its prepare runtime")
      local read_index, old_read
      for i = 1, 20 do
        local name, value = debug.getupvalue(runtime.prepare_freshness, i)
        if name == "read_state" then read_index, old_read = i, value; break end
      end
      assert(read_index, "freshness must read published input fingerprints")
      local old_fingerprint, old_job = runtime.list_fingerprint, runtime.prepare_jobid
      local list = dir .. "/workspace.files"
      vim.fn.writefile({ "Source/sample.cpp" }, list)
      runtime.list_fingerprint = function() return "matching-fingerprint" end
      runtime.prepare_jobid = nil
      debug.setupvalue(runtime.prepare_freshness, read_index, function()
        return { csearch_input_hash = "matching-fingerprint" }
      end)
      local ok, err = xpcall(function()
        t.assert_eq(runtime.prepare_freshness({ engine_root = dir,
          paths = { workspace_all_list = list } }), "stale")
      end, debug.traceback)
      debug.setupvalue(runtime.prepare_freshness, read_index, old_read)
      runtime.list_fingerprint, runtime.prepare_jobid = old_fingerprint, old_job
      if not ok then error(err) end
    end)
  end)

  t.it("the incremental command routes zero-path overflow to the search-only rebuild", function()
    with_watchers(function(open)
      local watch, _, dir = open()
      flood(watch, dir)
      watch.remove_persistent_dirty(watch.snapshot_persistent_dirty(), "incremental")
      local source = table.concat(vim.fn.readfile(vim.fn.getcwd() .. "/lua/ue.lua"), "\n")
      local tree = vim.treesitter.get_string_parser(source, "lua"):parse()[1]
      local callback
      local function visit(node)
        if callback then return end
        if node:type() == "function_call" then
          local arguments = node:field("arguments")[1]
          if arguments then
            local first = arguments:named_child(0)
            if first and vim.treesitter.get_node_text(first, source) == '"UEPrepareIncremental"' then
              callback = vim.treesitter.get_node_text(arguments:named_child(1), source)
              return
            end
          end
        end
        for child in node:iter_children() do visit(child) end
      end
      visit(tree:root())
      assert(callback, "incremental command callback unavailable")
      local context, routed = { paths = {}, engine_root = dir }, nil
      local command = assert(loadstring("local M, resolve_context = ...; return " .. callback))(
        { build_csearch_async = function(opts) routed = opts.context end },
        function() return context end)
      command()
      t.assert_true(routed == context, "full search-only owner must receive the original context")
    end)
  end)
end)
