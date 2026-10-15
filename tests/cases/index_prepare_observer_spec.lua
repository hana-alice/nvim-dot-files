local t = require("tests.harness")
t.bootstrap()
local observer = require("ue.index.prepare_observer")
local ctx = { engine_root = "/e", project_root = "/p", paths = { active_cdb = "/cdb" } }

t.describe("maintenance prepare completion", function()
  t.it("real success beats the scheduled running-false failure", function()
    observer._reset_for_test()
    local outcomes = {}
    observer.run(ctx, function() observer.running(false); observer.prepared(ctx) end, function() return false end,
      function(ok) outcomes[#outcomes + 1] = ok end)
    vim.wait(20, function() return false end)
    t.assert_eq(#outcomes, 1); t.assert_true(outcomes[1])
  end)

  t.it("context changes and failed asynchronous prepares cannot establish baseline", function()
    observer._reset_for_test()
    local result, reason
    observer.run(ctx, function() end, function() return true end, function(ok, err) result, reason = ok, err end)
    -- Busy prevents starting a maintenance subscriber; ordinary prepare stays untouched.
    t.assert_false(result); t.assert_eq(reason, "prepare-already-running")
    local running = false
    observer.run(ctx, function() running = true end, function() return running end, function(ok, err) result, reason = ok, err end)
    observer.prepared({ engine_root = "/another" })
    t.assert_false(result); t.assert_eq(reason, "prepare-context-changed")
    running = false
    observer.run(ctx, function() running = true end, function() return running end, function(ok, err) result, reason = ok, err end)
    observer.failed("preflight-failed")
    t.assert_false(result); t.assert_eq(reason, "preflight-failed")
  end)

  t.it("running without delivery terminates once, and immediate refusal is honest", function()
    observer._reset_for_test()
    local count, reason = 0, nil
    observer.run(ctx, function() end, function() return false end, function(_, err) count, reason = count + 1, err end)
    t.assert_eq(reason, "prepare-not-started")
    local running = false
    observer.run(ctx, function() running = true end, function() return running end, function(_, err) count, reason = count + 1, err end)
    observer.running(false)
    vim.wait(100, function() return count == 2 end)
    t.assert_eq(count, 2); t.assert_eq(reason, "prepare-did-not-complete")
    observer._reset_for_test()
  end)
end)
