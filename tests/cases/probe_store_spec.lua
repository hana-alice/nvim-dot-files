local t = require("tests.harness")
t.bootstrap()

local function empty() return { version = 1, topics = {} } end
local function fixture(fn)
  local root = vim.fs.normalize(vim.fn.tempname())
  vim.fn.mkdir(root, "p")
  local ok, err = xpcall(function() fn(root .. "/probes.json") end, debug.traceback)
  vim.fn.delete(root, "rf")
  if not ok then error(err) end
end
local function snapshot(base, count, revision)
  local data = vim.deepcopy(base or empty())
  data.topics.topic = data.topics.topic or { max_records = 200, armed_until = os.time() + 1000, records = {} }
  data.topics.topic.observation = { revision = revision or "r1", started = 1 }
  data.topics.topic.records.key = { count = count, failure_count = count, first = 1, last = count,
    revision = revision or "r1", data = { state = "unavailable" },
    stats = { samples = count, total_ms = count * 5, min_ms = 5, max_ms = 5,
      buckets = { lt_10 = count }, outcomes = { unavailable = count } } }
  return { data = data, base = vim.deepcopy(base or empty()), topic_updates = { topic = true }, record_updates = {} }
end

t.describe("probe durable store", function()
  t.it("compacts expired disk topics before merging an automatically reopened topic", function()
    fixture(function(path)
      local probe = assert(loadfile(vim.fn.stdpath("config") .. "/lua/utils/probe.lua"))()
      local expired = os.time() - 45 * 86400
      vim.fn.writefile({ vim.json.encode({ version = 1, topics = { topic = {
        armed_until = expired, max_records = 200, records = { key = {
          count = 9, failure_count = 9, first = expired, last = expired, data = { state = "unavailable" },
        } },
      } } }) }, path)
      probe._set_path_for_test(path)
      local ok, err = xpcall(function()
        t.assert_true(probe.record("topic", "key", { state = "unavailable" }))
        probe._flush_for_test()
        probe._set_path_for_test(path)
        t.assert_true(probe.is_armed("topic"), "old disk lifecycle must not cancel the freshly opened window")
        local reloaded = require("utils.probe_store").read(path)
        t.assert_eq(reloaded.topics.topic.records.key.count, 1, "expired counters must not be resurrected")
      end, debug.traceback)
      probe._set_path_for_test(nil)
      if not ok then error(err) end
    end)
  end)

  t.it("does not treat an unreadable primary with a failed stat as an empty store", function()
    fixture(function(path)
      local store = require("utils.probe_store")
      t.assert_true(store.save(path, snapshot(nil, 1)))
      local original = table.concat(vim.fn.readfile(path), "\n")
      local open, stat = io.open, vim.uv.fs_stat
      local ok, err = xpcall(function()
        io.open = function(name, mode)
          if name == path and mode == "rb" then return nil, "injected read EACCES" end
          return open(name, mode)
        end
        vim.uv.fs_stat = function(name)
          if name == path then return nil, "injected stat EIO", "EIO" end
          return stat(name)
        end
        t.assert_nil(store.read(path))
        t.assert_false(store.save(path, snapshot(nil, 2)))
        t.assert_eq(table.concat(vim.fn.readfile(path), "\n"), original)
      end, debug.traceback)
      io.open, vim.uv.fs_stat = open, stat
      if not ok then error(err) end
    end)
  end)

  t.it("creates a missing parent directory before acquiring the writer lease", function()
    fixture(function(path)
      local nested = vim.fs.dirname(path) .. "/new/nested/probes.json"
      local store = require("utils.probe_store")
      t.assert_true(store.save(nested, snapshot(nil, 1)))
      t.assert_eq(store.read(nested).topics.topic.records.key.count, 1)
    end)
  end)

  for _, phase in ipairs({ "write", "flush", "close", "rename" }) do
    t.it("preserves the previous file and releases the lease after " .. phase .. " failure", function()
      fixture(function(path)
        local store = require("utils.probe_store")
        local lock = require("ue.file_lock")
        local ok, base = store.save(path, snapshot(nil, 1))
        t.assert_true(ok)
        local prior = table.concat(vim.fn.readfile(path), "\n")
        local current = snapshot(base, 2)
        local open, rename = io.open, vim.uv.fs_rename
        local checked, err = xpcall(function()
          io.open = function(name, mode)
            local file, reason = open(name, mode)
            if not file or mode ~= "wb" or name:sub(1, #path + 5) ~= path .. ".tmp." then return file, reason end
            return {
              write = function(_, value) if phase == "write" then return nil, "injected write EIO" end; return file:write(value) end,
              flush = function() if phase == "flush" then return nil, "injected flush EIO" end; return file:flush() end,
              close = function() local result = file:close(); if phase == "close" then return nil, "injected close EIO" end; return result end,
            }
          end
          vim.uv.fs_rename = function(from, to)
            if phase == "rename" and to == path then return nil, "injected rename EIO" end
            return rename(from, to)
          end
          local saved = store.save(path, current)
          t.assert_false(saved)
          t.assert_eq(table.concat(vim.fn.readfile(path), "\n"), prior)
          t.assert_nil(lock.owner(path .. ".lock"))
        end, debug.traceback)
        io.open, vim.uv.fs_rename = open, rename
        if not checked then error(err) end
        local saved, latest = store.save(path, current)
        t.assert_true(saved)
        t.assert_eq(latest.topics.topic.records.key.count, 2)
      end)
    end)
  end

  t.it("journals an exiting writer under a busy lock and replays its delta once", function()
    fixture(function(path)
      local store, lock = require("utils.probe_store"), require("ue.file_lock")
      local lease = assert(lock.acquire(path .. ".lock"))
      local pending = snapshot(nil, 1)
      local ok, _, durable = store.save(path, pending, { exiting = true })
      t.assert_false(ok)
      t.assert_true(durable)
      local again, _, durable_again = store.save(path, pending, { exiting = true })
      t.assert_false(again)
      t.assert_true(durable_again)
      lock.release(lease)
      local recovered = assert(store.read(path))
      t.assert_eq(recovered.topics.topic.records.key.count, 1)
      local saved, latest = store.save(path, { data = recovered, base = recovered })
      t.assert_true(saved)
      t.assert_eq(latest.topics.topic.records.key.count, 1)
      t.assert_eq(store.read(path).topics.topic.records.key.stats.samples, 1)
    end)
  end)

  t.it("does not replay a committed journal again when deletion fails", function()
    fixture(function(path)
      local store, lock = require("utils.probe_store"), require("ue.file_lock")
      local lease = assert(lock.acquire(path .. ".lock"))
      local pending = snapshot(nil, 1)
      local _, _, durable = store.save(path, pending, { exiting = true })
      t.assert_true(durable)
      lock.release(lease)
      local unlink = vim.uv.fs_unlink
      local ok, err = xpcall(function()
        vim.uv.fs_unlink = function(name)
          if name:sub(1, #path + 9) == path .. ".pending." then return nil, "injected deletion failure" end
          return unlink(name)
        end
        local saved, latest = store.save(path, pending)
        t.assert_true(saved)
        t.assert_eq(latest.topics.topic.records.key.count, 1, "retry of the journaled snapshot must not add it twice")
        t.assert_eq(store.read(path).topics.topic.records.key.count, 1)
      end, debug.traceback)
      vim.uv.fs_unlink = unlink
      if not ok then error(err) end
      local recovered = store.read(path)
      t.assert_true(store.save(path, { data = recovered, base = recovered }))
      t.assert_eq(store.read(path).topics.topic.records.key.count, 1)
    end)
  end)

  t.it("merges concurrent counter deltas while keeping the current revision statistics", function()
    fixture(function(path)
      local store = require("utils.probe_store")
      local _, base = store.save(path, snapshot(nil, 1, "r1"))
      local left, right = snapshot(base, 2, "r2"), snapshot(base, 2, "r1")
      left.data.topics.topic.records.key.stats.samples = 1
      left.data.topics.topic.records.key.stats.total_ms = 5
      left.data.topics.topic.records.key.stats.buckets.lt_10 = 1
      left.data.topics.topic.records.key.stats.outcomes.unavailable = 1
      t.assert_true(store.save(path, left))
      local ok, result = store.save(path, right)
      t.assert_true(ok)
      t.assert_eq(result.topics.topic.observation.revision, "r2")
      t.assert_eq(result.topics.topic.records.key.count, 3)
      t.assert_eq(result.topics.topic.records.key.revision, "r2")
      t.assert_eq(result.topics.topic.records.key.stats.samples, 1)
    end)
  end)

  t.it("keeps a slept revision dormant after a delayed observe but honors an explicit arm", function()
    fixture(function(path)
      local store = require("utils.probe_store")
      local delayed = snapshot(nil, 1)
      delayed.topic_updates.topic = "observe"
      local _, first = store.save(path, snapshot(nil, 1))
      local sleeping = { data = vim.deepcopy(first), base = first, topic_updates = { topic = "sleep" } }
      sleeping.data.topics.topic.armed_until = nil
      t.assert_true(store.save(path, sleeping))
      local ok, result = store.save(path, delayed)
      t.assert_true(ok)
      t.assert_nil(result.topics.topic.armed_until)
      t.assert_eq(result.topics.topic.records.key.count, 2)
      local arm = { data = vim.deepcopy(first), base = first, topic_updates = { topic = "arm" } }
      t.assert_true(store.save(path, arm))
      t.assert_true(store.read(path).topics.topic.armed_until > os.time())
      local latest = store.read(path)
      local next_revision = { data = vim.deepcopy(latest), base = latest, topic_updates = { topic = "observe" } }
      next_revision.data.topics.topic.observation = { revision = "r2", started = 2 }
      next_revision.data.topics.topic.armed_until = nil
      t.assert_true(store.save(path, next_revision))
      t.assert_true(store.save(path, arm))
      t.assert_nil(store.read(path).topics.topic.armed_until, "old-revision explicit arm must not overwrite the newer revision")
    end)
  end)
end)
