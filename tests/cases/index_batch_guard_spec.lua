local t = require("tests.harness")
t.bootstrap()
local batch_guard = require("ue.index.batch_guard")

local function harness(overrides, attach_now)
  local queue, watches, sent, cancelled, order = {}, {}, {}, {}, {}
  local callbacks = { ready = 0, invalidated = 0, verification_cancelled = 0 }
  local client = {
    id = 77,
    request = function(_, method, _, handler)
      sent[#sent + 1] = { method = method, handler = handler }
      return true, #sent
    end,
    request_sync = function() return { result = "current" } end,
    cancel_request = function(_, id) cancelled[#cancelled + 1] = id end,
  }
  local opts = {
    receipts = { "/receipts/frozen.json" },
    roots = { "/engine/Source", "/project/Source", "/engine/Source/Nested" },
    schedule = function(callback) queue[#queue + 1] = callback end,
    watch_factory = function(root, callback, options)
      t.assert_eq(type(options.recursive), "boolean")
      order[#order + 1] = "watch"
      local watch = { root = root, callback = callback, recursive = options.recursive, stopped = 0, closed = 0 }
      function watch:stop() self.stopped = self.stopped + 1 end
      function watch:close() self.closed = self.closed + 1 end
      watches[#watches + 1] = watch
      return watch, { recursive = options.recursive, direct = not options.recursive }
    end,
    verify_async = function(receipts, callback)
      t.assert_eq(receipts[1], "/receipts/frozen.json")
      order[#order + 1] = "verify"
      callbacks.verify = callback
      return function() callbacks.verification_cancelled = callbacks.verification_cancelled + 1 end
    end,
    on_ready = function() callbacks.ready = callbacks.ready + 1 end,
    on_invalidated = function(reason)
      callbacks.invalidated = callbacks.invalidated + 1
      callbacks.reason = reason
    end,
  }
  for key, value in pairs(overrides or {}) do opts[key] = value end
  local guard = batch_guard.start({ scope = "fixture" }, attach_now and client or nil, opts)
  local function flush()
    while #queue > 0 do
      local callback = table.remove(queue, 1)
      callback()
    end
  end
  return { guard = guard, client = client, callbacks = callbacks, watches = watches,
    sent = sent, cancelled = cancelled, order = order, opts = opts, flush = flush }
end

t.describe("frozen batch live validity guard", function()
  t.it("installs minimal recursive watches before asynchronous proof and supports later client attachment", function()
    local h = harness()
    t.assert_eq(table.concat(h.order, ","), "watch,watch,verify")
    t.assert_eq(h.guard:status().state, "validating")
    t.assert_eq(h.callbacks.ready, 0)
    t.assert_true(h.guard:attach(h.client))
    for _, method in ipairs({ "textDocument/references", "textDocument/rename", "textDocument/prepareRename" }) do
      t.assert_false(h.client:request(method, {}, function() error("blocked request dispatched") end))
    end
    t.assert_nil(h.client:request_sync("textDocument/references", {}))
    t.assert_true(h.client:request("textDocument/definition", {}, function() end))
    h.callbacks.verify({ ok = true, evidence = { valid = true } })
    t.assert_eq(h.guard:status().state, "validating", "ready must wait for the scheduled epoch check")
    h.flush()
    t.assert_eq(h.guard:status().state, "ready")
    t.assert_eq(h.callbacks.ready, 1)
    t.assert_true(h.client:request("textDocument/references", {}, function() end))
    h.guard:stop()
    h.flush()
  end)

  t.it("an event during validation immediately revokes the epoch and rejects a queued success", function()
    local h = harness(nil, true)
    h.callbacks.verify({ ok = true })
    local before = h.guard:status().epoch
    h.watches[1].callback(nil, "Nested/input.h", { change = true })
    t.assert_eq(h.guard:status().epoch, before + 1)
    t.assert_eq(h.guard:status().state, "invalidated")
    t.assert_false(h.client:request("textDocument/rename", {}, function() end))
    h.flush()
    t.assert_eq(h.callbacks.ready, 0)
    t.assert_eq(h.callbacks.invalidated, 1)
    t.assert_eq(h.callbacks.verification_cancelled, 1)
    for _, watch in ipairs(h.watches) do t.assert_eq(watch.closed, 1) end
    h.callbacks.verify({ ok = true })
    h.watches[1].callback(nil, "again.h", {})
    h.flush()
    t.assert_eq(h.callbacks.invalidated, 1)
    t.assert_eq(h.callbacks.ready, 0)
  end)

  t.it("discards stale replies exactly once and cancels other pending requests before fallback", function()
    local h = harness(nil, true)
    h.callbacks.verify({ ok = true })
    h.flush()
    local responses = {}
    for _, method in ipairs({ "textDocument/references", "textDocument/rename" }) do
      h.client:request(method, {}, function(err, result)
        responses[#responses + 1] = { err = err, result = result }
      end)
    end
    h.watches[1].callback(nil, "input.h", {})
    h.sent[1].handler(nil, { stale = true })
    t.assert_eq(#responses, 1)
    t.assert_nil(responses[1].result)
    t.assert_eq(responses[1].err.code, -32801)
    h.flush()
    t.assert_eq(#responses, 2)
    t.assert_eq(h.cancelled[1], 2)
    t.assert_eq(h.callbacks.invalidated, 1)
    h.sent[1].handler(nil, { stale = true })
    h.sent[2].handler(nil, { stale = true })
    t.assert_eq(#responses, 2)
    t.assert_false(h.client:request("textDocument/prepareRename", {}, function() end))
    t.assert_true(h.client:request("textDocument/definition", {}, function() end))
  end)

  t.it("discards a synchronous response when an input event arrives during the wait", function()
    local h = harness()
    h.client.request_sync = function()
      h.watches[1].callback(nil, "input.h", {})
      return { result = { stale = true } }
    end
    h.guard:attach(h.client)
    h.callbacks.verify({ ok = true })
    h.flush()
    local response, reason = h.client:request_sync("textDocument/references", {})
    t.assert_nil(response)
    t.assert_eq(reason, "frozen-batch-invalidated")
    h.flush()
  end)

  t.it("verification failures, absent recursive capability and excessive roots retain the original fallback", function()
    local h = harness(nil, true)
    h.callbacks.verify({ ok = false, reason = "dependency-bytes-changed" })
    h.flush()
    t.assert_eq(h.callbacks.reason, "dependency-bytes-changed")
    t.assert_eq(h.callbacks.ready, 0)
    local missing = harness({ watch_factory = function() return nil, "ENOSYS" end })
    missing.flush()
    t.assert_eq(missing.callbacks.reason, "recursive-watch-unavailable")
    t.assert_nil(missing.callbacks.verify)
    local no_capability = harness({ watch_factory = function() return { close = function() end } end })
    no_capability.flush()
    t.assert_eq(no_capability.callbacks.reason, "recursive-watch-unavailable")
    local bounded = harness({ max_roots = 1 })
    bounded.flush()
    t.assert_eq(bounded.callbacks.reason, "watch-root-limit")
    t.assert_eq(#bounded.watches, 0)
  end)

  t.it("does not treat a direct ancestor as covering nested lookup directories or recursive sources", function()
    local h = harness({ roots = { "/source", { path = "/drivers", recursive = false },
      { path = "/drivers/nested", recursive = false }, { path = "/source/tools", recursive = false } } })
    t.assert_eq(#h.watches, 3)
    t.assert_true(h.watches[1].recursive)
    t.assert_false(h.watches[2].recursive)
    t.assert_false(h.watches[3].recursive)
    h.callbacks.verify({ ok = true }); h.flush()
    t.assert_eq(h.guard:status().state, "ready")
    h.guard:stop(); h.flush()
  end)

  t.it("requires direct capability independently and bounds direct roots separately from recursive roots", function()
    local roots = { { path = "/lookup", recursive = false } }
    local missing = harness({ roots = roots, watch_factory = function()
      return { close = function() end }, { recursive = true }
    end })
    missing.flush()
    t.assert_eq(missing.callbacks.reason, "direct-watch-unavailable")
    t.assert_nil(missing.callbacks.verify)
    local bounded = harness({ roots = { roots[1], { path = "/other", recursive = false } }, max_lookup_roots = 1 })
    bounded.flush()
    t.assert_eq(bounded.callbacks.reason, "lookup-watch-root-limit")
    t.assert_eq(#bounded.watches, 0)
  end)

  t.it("installs large direct-watch sets in scheduled batches before any verification", function()
    local roots = {}
    for number = 1, 197 do roots[#roots + 1] = { path = "/driver-" .. number, recursive = false } end
    local h = harness({ roots = roots })
    t.assert_eq(#h.watches, 16)
    t.assert_nil(h.callbacks.verify)
    h.flush()
    t.assert_eq(#h.watches, 197)
    t.assert_eq(h.order[#h.order], "verify")
    h.callbacks.verify({ ok = true }); h.flush()
    t.assert_eq(h.guard:status().state, "ready")
    h.guard:stop(); h.flush()
  end)

  t.it("an event during scheduled watch installation prevents all remaining watches and validation", function()
    local roots = {}
    for number = 1, 40 do roots[#roots + 1] = { path = "/driver-" .. number, recursive = false } end
    local h = harness({ roots = roots })
    h.watches[1].callback(nil, "clang", { rename = true })
    h.flush()
    t.assert_eq(#h.watches, 16)
    t.assert_nil(h.callbacks.verify)
    t.assert_eq(h.callbacks.invalidated, 1)
    for _, watch in ipairs(h.watches) do t.assert_eq(watch.closed, 1) end
  end)

  t.it("waits for every native ready acknowledgement including synchronous and out-of-order callbacks", function()
    local callbacks, closed = {}, 0
    local h = harness({
      roots = { "/a", "/b", "/c" },
      watch_factory = function(root, _, options)
        callbacks[root] = options.on_ready
        if root == "/a" then options.on_ready(true) end
        return { close = function() closed = closed + 1 end }, { recursive = true, pending = true }
      end,
    })
    h.flush()
    t.assert_nil(h.callbacks.verify)
    callbacks["/c"](true); callbacks["/c"](true); h.flush()
    t.assert_nil(h.callbacks.verify, "duplicate ready cannot settle another root")
    callbacks["/b"](true); h.flush()
    t.assert_type(h.callbacks.verify, "function")
    h.callbacks.verify({ ok = true }); h.flush()
    t.assert_eq(h.callbacks.ready, 1)
    h.guard:stop(); h.flush()
    t.assert_eq(closed, 3)
  end)

  t.it("creates shared backends only for the minimized set and closes them on setup rejection", function()
    local captured, closes = nil, 0
    local h = harness({ watch_backend = function(roots)
      captured = roots
      return nil, function() closes = closes + 1 end
    end })
    h.flush()
    t.assert_eq(#captured, 2, "covered descendants must never become unregistered backend watches")
    t.assert_eq(h.callbacks.reason, "input-watch-unavailable")
    t.assert_nil(h.callbacks.verify)
    t.assert_eq(closes, 1)
  end)

  t.it("closes shared resources on partial setup failure and ignores late readiness", function()
    local ready, events, closed, shared_closed = {}, {}, 0, 0
    local h = harness({
      watch_factory = function(root, callback, options)
        ready[#ready + 1], events[#events + 1] = options.on_ready, callback
        return { close = function() closed = closed + 1 end }, { recursive = true, pending = true }
      end,
      close_watches = function() shared_closed = shared_closed + 1 end,
    })
    ready[1](false)
    for _, notify in ipairs(ready) do notify(true) end
    h.flush()
    t.assert_eq(h.callbacks.reason, "watch-ready-failed")
    t.assert_nil(h.callbacks.verify)
    t.assert_eq(closed, #ready)
    t.assert_eq(shared_closed, 1)
    h.guard:stop(); h.flush()
    t.assert_eq(shared_closed, 1)

    local bad = harness({ roots = { "relative" }, close_watches = function() shared_closed = shared_closed + 1 end })
    bad.flush()
    t.assert_eq(shared_closed, 2, "shared owner closes even when no handle was registered")
  end)

  t.it("revokes pending native watches on real events and never validates a late ready", function()
    local notify, event
    local h = harness({ roots = { "/input" }, watch_factory = function(_, callback, options)
      notify, event = options.on_ready, callback
      return { close = function() end }, { recursive = true, pending = true }
    end })
    event(nil, "changed.h", { change = true })
    notify(true); h.flush()
    t.assert_eq(h.callbacks.reason, "input-changed")
    t.assert_nil(h.callbacks.verify)
  end)

  t.it("stop and replacement keep old clients and callbacks gated without blocking the new owner", function()
    local old = harness(nil, true)
    old.guard:stop()
    old.callbacks.verify({ ok = true })
    old.flush()
    t.assert_eq(old.callbacks.ready, 0)
    t.assert_false(old.client:request("textDocument/references", {}, function() end))
    local new = harness()
    new.guard:attach(old.client)
    new.callbacks.verify({ ok = true })
    new.flush()
    old.watches[1].callback("late watcher error")
    old.flush()
    t.assert_true(old.client:request("textDocument/references", {}, function() end))
    t.assert_eq(new.guard:status().state, "ready")
    new.guard:stop()
    new.flush()
  end)

  t.it("activation and consumer callback errors cannot prevent fallback or drain of other requests", function()
    local failed = harness({ on_ready = function() error("publish failed") end })
    failed.callbacks.verify({ ok = true })
    failed.flush()
    t.assert_eq(failed.callbacks.reason, "activation-failed")
    local h = harness(nil, true)
    h.callbacks.verify({ ok = true })
    h.flush()
    h.client:request("textDocument/references", {}, function() error("consumer failed") end)
    local drained = false
    h.client:request("textDocument/rename", {}, function(err, result)
      drained = err ~= nil and result == nil
    end)
    h.watches[1].callback("watch failed")
    h.flush()
    t.assert_true(drained)
    t.assert_eq(h.callbacks.reason, "watch-error")
    t.assert_eq(#h.cancelled, 2)
  end)

  t.it("a real recursive fs_event revokes an activated guard on a nested input change when supported", function()
    local uv = vim.uv or vim.loop
    local root = vim.fn.tempname():gsub("\\", "/") .. "_batch_guard"
    vim.fn.mkdir(root .. "/nested", "p")
    local file = root .. "/nested/input.h"
    vim.fn.writefile({ "before" }, file)
    local probe, probe_error = uv.new_fs_event()
    if not probe then
      vim.fn.delete(root, "rf")
      t.skip("recursive fs_event capability", tostring(probe_error))
      return
    end
    local observed = false
    local started = probe:start(root, { recursive = true }, function(err)
      if not err then observed = true end
    end)
    if started then vim.fn.writefile({ "capability probe" }, file) end
    local capable = started and vim.wait(1000, function() return observed end, 10)
    probe:stop()
    probe:close()
    if not capable then
      vim.fn.delete(root, "rf")
      t.skip("recursive fs_event capability", "nested event not observed on this host")
      return
    end
    local guard
    local ok, err = xpcall(function()
      local ready, invalidated = false, false
      guard = batch_guard.start({}, nil, {
        receipts = { "fixture" }, roots = { root },
        watch_factory = function(path, callback, options)
          local handle = assert(uv.new_fs_event())
          local result, start_error = handle:start(path, options, callback)
          if not result then handle:close(); return nil, start_error end
          return handle, { recursive = true }
        end,
        verify_async = function(_, callback) vim.schedule(function() callback({ ok = true }) end) end,
        on_ready = function() ready = true end,
        on_invalidated = function() invalidated = true end,
      })
      t.assert_true(vim.wait(1000, function() return ready end, 10))
      vim.fn.writefile({ "changed after verification" }, file)
      t.assert_true(vim.wait(1000, function() return invalidated end, 10))
      t.assert_eq(guard:status().state, "invalidated")
    end, debug.traceback)
    if guard then guard:stop() end
    vim.wait(20, function() return false end, 10)
    vim.fn.delete(root, "rf")
    if not ok then error(err) end
  end)
end)
