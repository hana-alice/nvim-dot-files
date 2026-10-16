local t = require("tests.harness")
t.bootstrap()
local client = require("utils.ue_goto.semantic_client")
local admission = require("utils.host_admission")

local function fixture(body)
  local previous = vim.api.nvim_get_current_buf()
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(buf, vim.fn.tempname() .. ".h")
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "int first;", "int second;" })
  vim.bo[buf].modified = false
  vim.api.nvim_set_current_buf(buf)
  client._reset_for_test()
  local events = { deferred = {}, readings = { status = "ready", host_pct = 10 }, calls = 0, cancellations = 0 }
  local cpu = {
    subscribe = function(callback) events.listener = callback; return "owned-subscription" end,
    unsubscribe = function() events.listener = nil end,
  }
  local policy = {
    options = function() return { enabled = true, high_pct = 85, low_pct = 70, foreground_active = false } end,
    admit = admission.admit,
    run_when_allowed = function(spec)
      spec.reading = function() return events.readings end
      spec.schedule = function(fn) fn() end
      spec.timer_factory = function()
        return { start = function() end, stop = function() end, close = function() end }
      end
      return admission.run_when_allowed(spec)
    end,
  }
  local fake = {
    cancel_queued_actions = function() events.cancellations = events.cancellations + 1 end,
    discover_toolchain = function() return { project_root = vim.fs.dirname(vim.api.nvim_buf_get_name(buf)), build_fingerprint = "build" } end,
    capture_overlays = client.capture_overlays,
    resolve_header = function(spec, callback)
      events.calls = events.calls + 1
      events.spec, events.callback = spec, callback
    end,
  }
  local background = require("utils.ue_goto.semantic_prewarm").install(fake, {
    cpu = cpu, admission = policy,
    defer = function(fn, delay)
      events.delay = delay
      events.deferred[#events.deferred + 1] = fn
      return { stop = function() end, close = function() end }
    end,
  })
  function events.fire() table.remove(events.deferred, 1)() end
  local ok, err = xpcall(function() body(background, events, buf) end, debug.traceback)
  background.cancel()
  client._reset_for_test()
  vim.api.nvim_set_current_buf(previous)
  vim.api.nvim_buf_delete(buf, { force = true })
  if not ok then error(err) end
end

t.describe("cpp semantic client: background header prewarm", function()
  t.it("another buffer's FileType or start cannot cancel the current header warmup", function()
    fixture(function(background, events, buf)
      background.start(buf); events.fire()
      local snapshot = events.spec.snapshot
      local another = vim.api.nvim_create_buf(true, false)
      local ok, err = xpcall(function()
        vim.api.nvim_buf_set_name(another, vim.fn.tempname() .. ".h")
        t.assert_false(background.on_enter({ buf = another, event = "FileType" }))
        t.assert_false(background.start(another))
        t.assert_true(client.snapshot_is_current(snapshot))
        vim.api.nvim_buf_set_name(another, vim.fn.tempname() .. ".cpp")
        t.assert_false(background.start(another))
        t.assert_true(client.snapshot_is_current(snapshot))
        t.assert_eq(events.calls, 1)
      end, debug.traceback)
      vim.api.nvim_buf_delete(another, { force = true })
      if not ok then error(err) end
    end)
  end)

  t.it("warms asynchronously through the same resolver without cancelling the active action or committing lineage", function()
    fixture(function(background, events, buf)
      local action = client.begin_action(buf)
      client.note_origin(action.winid, "fixture.cpp", "build", "original")
      t.assert_true(background.start(buf))
      t.assert_eq(events.calls, 0)
      events.fire()
      t.assert_eq(events.calls, 1)
      t.assert_eq(events.delay, 50)
      t.assert_true(events.spec.snapshot.prewarm)
      t.assert_true(client.snapshot_is_current(action))
      events.callback({ state = "resolved", origin_context = { origin_tu = "different.cpp" } })
      t.assert_eq(client.window_origin(action.winid, "build").origin_tu, "fixture.cpp")
      t.assert_false(client.snapshot_is_current(events.spec.snapshot))
    end)
  end)

  t.it("cursor motion preserves a warmup but document edits still reject it", function()
    fixture(function(background, events, buf)
      background.start(buf); events.fire()
      local snapshot = events.spec.snapshot
      vim.api.nvim_win_set_cursor(0, { 2, 0 })
      t.assert_true(client.snapshot_is_current(snapshot))
      vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "long first;" })
      local current, reason = client.snapshot_is_current(snapshot)
      t.assert_false(current)
      t.assert_eq(reason, "document-changed")
    end)
  end)

  t.it("a foreground action supersedes queued warmup and restores foreground priority", function()
    fixture(function(background, events, buf)
      background.start(buf); events.fire()
      local old_cancel, old_priority = client.cancel_prewarm, client.set_priority
      local priorities = {}
      client.cancel_prewarm = background.cancel
      client.set_priority = function(value) priorities[#priorities + 1] = value end
      local ok, err = xpcall(function()
        client.begin_action(buf)
        t.assert_false(client.snapshot_is_current(events.spec.snapshot))
        t.assert_eq(priorities[#priorities], "normal")
      end, debug.traceback)
      client.cancel_prewarm, client.set_priority = old_cancel, old_priority
      if not ok then error(err) end
    end)
  end)

  t.it("a buffer switch before the delayed start sends no compiler work", function()
    fixture(function(background, events, buf)
      background.start(buf)
      local replacement = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_set_current_buf(replacement)
      events.fire()
      t.assert_eq(events.calls, 0)
      vim.api.nvim_set_current_buf(buf)
      vim.api.nvim_buf_delete(replacement, { force = true })
    end)
  end)

  t.it("host pressure defers initial work and cancels a pending admission on switch", function()
    fixture(function(background, events, buf)
      events.readings = { status = "ready", host_pct = 99 }
      background.start(buf); events.fire()
      t.assert_eq(events.calls, 0)
      background.cancel()
      t.assert_nil(events.listener)
    end)
  end)

  t.it("host pressure after start invalidates queued requests and leaves no subscriber", function()
    fixture(function(background, events, buf)
      background.start(buf); events.fire()
      events.listener({ status = "ready", host_pct = 99 })
      t.assert_false(client.snapshot_is_current(events.spec.snapshot))
      t.assert_nil(events.listener)
    end)
  end)

  t.it("failed inclusion during background resolution does not revoke the user's lineage", function()
    fixture(function(background, events, buf)
      background.start(buf); events.fire()
      local spec = events.spec
      local path = vim.api.nvim_buf_get_name(buf)
      client.note_origin(spec.snapshot.winid, {
        id = "original", origin_tu = "fixture.cpp", subject_membership = { path },
      }, "build")
      local old_request = client.request
      local ok, err = xpcall(function()
        client.request = function(op, _, callback)
          callback(op == "query" and { state = "invalid-semantic-context", reason = "invalid-query-file-not-in-tu" }
            or { state = "unavailable", contexts = {} })
        end
        client.resolve_header(spec, function() end)
        t.assert_eq(client.window_origin(spec.snapshot.winid, "build").origin_tu, "fixture.cpp")
      end, debug.traceback)
      client.request = old_request
      if not ok then error(err) end
    end)
  end)

  t.it("a changed build generation rejects the warmup completion", function()
    fixture(function(background, events, buf)
      background.start(buf); events.fire()
      local spec = events.spec
      spec.environment.index = { generation_id = "obsolete" }
      spec.environment.evidence_roots = { "fixture-evidence" }
      local old_request, old_index = client.request, client.index_snapshot_is_current
      local ok, err = xpcall(function()
        client.index_snapshot_is_current = function() return false, "index-generation-changed" end
        client.request = function(_, _, callback) callback({ state = "resolved", contexts = {} }) end
        local response, reason
        client.resolve_header(spec, function(value, why) response, reason = value, why end)
        t.assert_nil(response)
        t.assert_eq(reason, "index-generation-changed")
      end, debug.traceback)
      client.request, client.index_snapshot_is_current = old_request, old_index
      if not ok then error(err) end
    end)
  end)

  for _, verdict in ipairs({ "unavailable", "invalid-semantic-context", "ambiguous-context" }) do
    t.it("does not cache a negative result: " .. verdict, function()
      fixture(function(background, events, buf)
        background.start(buf); events.fire()
        events.callback({ state = verdict })
        background.start(buf); events.fire()
        t.assert_eq(events.calls, 2)
      end)
    end)
  end
end)
