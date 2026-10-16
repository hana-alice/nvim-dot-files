local t = require("tests.harness")
t.bootstrap()
local progress = require("ue.index.batch_progress")

t.describe("durable background observations", function()
  t.it("records proof, collect and pending hints without granting authority", function()
    local record = { scope = "fixture", owner_pid = 123, phase = "collecting", pending_accepted = { a = 1, b = 2 },
      last_proof = { completed_at = 4, accepted = 1 }, last_collect = { started_at = 5, outcome = "running" } }
    local value = progress.snapshot(record, { alive = function() return false end })
    t.assert_eq(value.pending_accepted_count, 3)
    t.assert_false(value.owner_alive)
    t.assert_eq(value.last_proof.completed_at, 4)
    value.last_proof.completed_at = 99
    t.assert_eq(record.last_proof.completed_at, 4)
    t.assert_nil(value.ready)
  end)

  t.it("persists unchanged observations once and survives a fresh reader", function()
    local directory = vim.fn.tempname()
    vim.fn.mkdir(directory, "p")
    local scope = directory .. "/full/source.json"
    local path = progress.path(scope)
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    local value = progress.snapshot({ scope = scope, owner_pid = 2147483647, phase = "proving", pending_accepted = { a = 1 } },
      { alive = function() return true end })
    t.assert_true(progress.write(path, value))
    local before = vim.uv.fs_stat(path)
    t.assert_true(progress.write(path, value))
    t.assert_true(vim.deep_equal(before.mtime, vim.uv.fs_stat(path).mtime))
    local fresh = dofile(vim.fn.getcwd() .. "/lua/ue/index/batch_progress.lua")
    fresh.alive = function() return false end
    local result = fresh.summary(scope)
    t.assert_eq(result.phase, "orphaned")
    t.assert_eq(result.pending_accepted_count, 1)
    t.assert_false(result.queue_active)
    t.assert_nil(result.ready)
  end)

  t.it("corrupt or oversized summary is not usable and unknown pid stays unknown", function()
    local path = vim.fn.tempname()
    vim.fn.writefile({ "{broken" }, path)
    t.assert_nil(progress.read(path))
    t.assert_nil(progress.alive(nil))
    t.assert_nil(progress.path("relative-fixture"))
  end)
end)
