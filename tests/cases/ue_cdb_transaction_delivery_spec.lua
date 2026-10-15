local t = require("tests.harness")
t.bootstrap()

local transaction = require("ue.cdb.transaction")
local locks = require("ue.file_lock")

local function fixture(body)
  local root = vim.fs.normalize(vim.fn.tempname() .. "-cdb-delivery")
  local path = root .. "/live/compile_commands.json"
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local bytes = '[{"directory":"fixture","file":"New.cpp","arguments":["clang++","New.cpp"]}]'
  local ctx = { engine_root = root .. "/engine", project_root = root .. "/project",
    paths = { active_cdb = path, cdb_shards_dir = root .. "/shards" } }
  local saved_index, saved_log = package.loaded["ue.index"], package.loaded["utils.log"]
  local saved_release = locks.release
  local evidence = { recorded = {}, recovery = 0, scheduled = 0, refresh = 0, callbacks = 0, commits = 0 }
  package.loaded["utils.log"] = { notify_error = function(_, message)
    evidence.recorded[#evidence.recorded + 1] = message
  end }
  package.loaded["ue.index"] = {
    source_observation_unknown = function(context, reason)
      t.assert_eq(context, ctx)
      t.assert_contains(reason, "reader-refresh")
      -- Recovery is handed to the existing owner only after the writer exits.
      local lease = assert(locks.acquire(path .. ".writer.lock"))
      t.assert_true(locks.release(lease))
      evidence.recovery = evidence.recovery + 1
      return true
    end,
    schedule_prepare_delivery = function() error("recovery must not acknowledge a failed prepare") end,
    schedule_index_phase = function(context, phase, delay)
      t.assert_eq(context, ctx)
      t.assert_eq(phase, "current")
      t.assert_eq(delay, 50)
      evidence.scheduled = evidence.scheduled + 1
    end,
  }
  local function run(overrides)
    local result
    local options = {
      _host_admitted = true,
      helper = function(_, operation, done)
        if operation == "commit" then
          evidence.commits = evidence.commits + 1
          local file = assert(io.open(path, "wb"))
          assert(file:write(bytes)); assert(file:close())
          done(true, nil, { ok = true, changed = true })
        else done(true) end
      end,
      generate = function(_, _, done) done(true) end,
      pipeline = function(_, _, done) done(true) end,
      partition = function(_, _, done) done(true) end,
      on_committed = function()
        evidence.refresh = evidence.refresh + 1
        error("fixture reader refresh failed")
      end,
    }
    for key, value in pairs(overrides or {}) do options[key] = value end
    transaction.run(ctx, function() end, function(ok, message, detail)
      evidence.callbacks = evidence.callbacks + 1
      result = { ok = ok, message = message, detail = detail }
    end, options)
    t.assert_true(result ~= nil, "synchronous fixture must complete")
    if evidence.held_lease then t.assert_true(vim.uv.fs_stat(path .. ".writer.lock") ~= nil)
    else t.assert_nil(vim.uv.fs_stat(path .. ".writer.lock")) end
    return result
  end
  local ok, err = xpcall(function() body(ctx, run, evidence, bytes) end, debug.traceback)
  locks.release = saved_release
  if evidence.held_lease then saved_release(evidence.held_lease) end
  package.loaded["ue.index"], package.loaded["utils.log"] = saved_index, saved_log
  if not ok then error(err) end
end

t.describe("CDB committed versus reader delivery", function()
  t.it("reports refresh exceptions as committed but undelivered and schedules existing recovery owner", function()
    fixture(function(ctx, run, evidence, bytes)
      local result = run()
      t.assert_false(result.ok)
      t.assert_false(result.detail.ok)
      t.assert_true(result.detail.committed)
      t.assert_false(result.detail.delivered)
      t.assert_eq(result.detail.delivery_status, "refresh-failed")
      t.assert_true(result.detail.recovery_scheduled)
      t.assert_contains(result.message, "CDB committed")
      t.assert_contains(result.message, "fixture reader refresh failed")
      t.assert_eq(evidence.recovery, 1)
      t.assert_eq(evidence.scheduled, 1)
      t.assert_eq(evidence.refresh, 1)
      t.assert_eq(evidence.callbacks, 1)
      t.assert_contains(evidence.recorded[1], "fixture reader refresh failed")
      local file = assert(io.open(ctx.paths.active_cdb, "rb"))
      t.assert_eq(file:read("*a"), bytes); file:close()
    end)
  end)

  t.it("keeps the primary delivery error when recovery owner also fails", function()
    fixture(function(_, run, evidence)
      package.loaded["ue.index"].source_observation_unknown = function() error("fixture owner unavailable") end
      local result = run()
      t.assert_false(result.ok)
      t.assert_true(result.detail.committed)
      t.assert_false(result.detail.delivered)
      t.assert_false(result.detail.recovery_scheduled)
      t.assert_contains(result.detail.recovery_error, "fixture owner unavailable")
      t.assert_contains(result.message, "fixture reader refresh failed")
      t.assert_eq(evidence.scheduled, 0)
      t.assert_eq(evidence.callbacks, 1)
    end)
  end)

  t.it("does not claim recovery scheduling when its writer lease failed to release", function()
    fixture(function(_, run, evidence)
      locks.release = function(lease) evidence.held_lease = lease; return false end
      local result = run()
      t.assert_false(result.ok)
      t.assert_true(result.detail.committed)
      t.assert_false(result.detail.delivered)
      t.assert_false(result.detail.writer_lease_released)
      t.assert_false(result.detail.recovery_scheduled)
      t.assert_contains(result.detail.recovery_error, "CDB writer lease not released")
      t.assert_eq(evidence.recovery, 0)
      t.assert_eq(evidence.scheduled, 0)
    end)
  end)

  t.it("does not claim actual attachment when the refresh request was only accepted", function()
    fixture(function(_, run, evidence)
      local result = run({ on_committed = function() evidence.refresh = evidence.refresh + 1 end })
      t.assert_true(result.ok)
      t.assert_true(result.detail.committed)
      t.assert_eq(result.detail.delivery_status, "refresh-requested")
      t.assert_nil(result.detail.delivered, "refresh invocation is not reader attachment proof")
      t.assert_eq(evidence.recovery, 0)
    end)
  end)

  t.it("treats an explicit refresh rejection as a delivery failure", function()
    fixture(function(_, run)
      local result = run({ on_committed = function() return false, "fixture reader rejected" end })
      t.assert_false(result.ok)
      t.assert_contains(result.message, "fixture reader rejected")
      t.assert_true(result.detail.committed)
      t.assert_false(result.detail.delivered)
    end)
  end)

  t.it("leaves unchanged commits alone and does not repeat recovery or restarts", function()
    fixture(function(_, run, evidence)
      local result = run({ helper = function(_, operation, done)
        if operation == "commit" then done(true, nil, { ok = true, changed = false }) else done(true) end
      end })
      t.assert_true(result.ok)
      t.assert_true(result.detail.committed)
      t.assert_eq(result.detail.delivery_status, "unchanged")
      t.assert_nil(result.detail.delivered)
      t.assert_eq(evidence.refresh, 0)
      t.assert_eq(evidence.recovery, 0)
    end)
  end)

  t.it("does not schedule reader recovery for a precommit failure", function()
    fixture(function(_, run, evidence)
      local result = run({ generate = function(_, _, done) done(false, "fixture generation failure") end })
      t.assert_false(result.ok)
      t.assert_eq(evidence.commits, 0)
      t.assert_eq(evidence.refresh, 0)
      t.assert_eq(evidence.recovery, 0)
    end)
  end)
end)
