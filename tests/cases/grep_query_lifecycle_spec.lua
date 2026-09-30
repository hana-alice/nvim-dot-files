local t = require("tests.harness")
t.bootstrap()
local ue = require("ue")

-- Exercise the real picker finder/drain/watchdog with a controllable async
-- backend. The separate real-Snacks reproduction covers its trimmed-query dedup.
local function fixture(raw, body)
  local captured, runtime, resolve_index, previous_resolve
  for index = 1, 80 do
    local name, value = debug.getupvalue(ue.cached_grep, index)
    if not name then break end
    if name == "CORE_RT" then runtime = value end
    if name == "resolve_context" then resolve_index, previous_resolve = index, value end
  end
  assert(runtime and resolve_index, "cached_grep context dependencies unavailable")
  local snacks, search = package.loaded.snacks, package.loaded["utils.code_search"]
  local new_timer, schedule_wrap = vim.loop.new_timer, vim.schedule_wrap
  local notify_freshness = runtime.notify_freshness
  local old_trace, old_grouping = vim.g.ue_grep_trace, vim.g.ue_grep_grouping_enabled
  local h = { stopped = false, hits = {}, calls = 0, sleeps = 0 }
  local context = { engine_root = vim.fn.getcwd(), paths = { csearch_idx = "fixture.idx" }, state = {} }
  local ok, err = xpcall(function()
    debug.setupvalue(ue.cached_grep, resolve_index, function() return context end)
    runtime.notify_freshness = function() end
    vim.g.ue_grep_trace, vim.g.ue_grep_grouping_enabled = false, false
    package.loaded.snacks = { picker = { pick = function(opts) captured = opts end } }
    package.loaded["utils.code_search"] = {
      is_indexed = function() return true end,
      stream = function(_, query, _, callbacks)
        h.calls, h.query, h.callbacks = h.calls + 1, query, callbacks
        return function() h.stopped = true end
      end,
    }
    vim.schedule_wrap = function(callback) return callback end
    vim.loop.new_timer = function()
      local timer = { closed = false }
      function timer:start(_, _, callback) self.callback = callback end
      function timer:stop() self.stopped = true end
      function timer:close() self.closed = true end
      function timer:is_closing() return self.closed end
      h.timer = timer
      return timer
    end
    assert(ue.cached_grep({ search = "" }))
    h.picker = { opts = { regex = false, word = false, case = false, scoped = false },
      input = { filter = { search = raw } } }
    function h.complete()
      h.callbacks.on_line("fixture.cpp", 7, 1, "KnownNeedle")
      h.callbacks.on_done(0)
    end
    function h.run(step)
      local finder = captured.finder({}, {
        filter = { search = vim.trim(raw) }, picker = h.picker,
        async = { sleep = function()
          h.sleeps = h.sleeps + 1
          assert(h.sleeps <= 5, "finder did not settle after controlled completion")
          step(h.sleeps)
        end },
      })
      finder(function(item) h.hits[#h.hits + 1] = item end)
    end
    body(h)
  end, debug.traceback)
  debug.setupvalue(ue.cached_grep, resolve_index, previous_resolve)
  runtime.notify_freshness = notify_freshness
  package.loaded.snacks, package.loaded["utils.code_search"] = snacks, search
  vim.loop.new_timer, vim.schedule_wrap = new_timer, schedule_wrap
  vim.g.ue_grep_trace, vim.g.ue_grep_grouping_enabled = old_trace, old_grouping
  if not ok then error(err) end
end

t.describe("csearch picker query lifecycle", function()
  for _, raw in ipairs({ "KnownNeedle ", " KnownNeedle", "\tKnownNeedle\t" }) do
    t.it("delivers a padded initial query without requiring a forced rerun: " .. vim.inspect(raw), function()
      fixture(raw, function(h)
        h.run(function() h.complete() end)
        t.assert_eq(h.query, "KnownNeedle")
        t.assert_eq(#h.hits, 1, "equivalent whitespace must not abort the initial finder")
        t.assert_false(h.stopped)
        -- Snacks sees the same trimmed query and does not restart its finder.
        h.picker.input.filter.search = vim.trim(raw)
        t.assert_eq(h.calls, 1)
        t.assert_eq(#h.hits, 1, "removing padding must retain the already delivered result")
      end)
    end)
  end

  t.it("keeps delayed backend results when the watchdog sees only padding change", function()
    fixture("KnownNeedle", function(h)
      h.run(function(step)
        if step == 1 then
          h.picker.input.filter.search = " KnownNeedle "
          h.timer.callback()
        else h.complete() end
      end)
      t.assert_false(h.stopped, "watchdog must compare the normalized query")
      t.assert_eq(#h.hits, 1)
      t.assert_true(h.timer.closed)
    end)
  end)

  t.it("drains the final buffered hit after an equivalent padding edit at completion", function()
    fixture("KnownNeedle", function(h)
      h.run(function()
        h.picker.input.filter.search = "KnownNeedle "
        h.complete()
      end)
      t.assert_eq(#h.hits, 1, "final-drain cancellation must use the same normalization")
      t.assert_false(h.stopped)
    end)
  end)

  t.it("still cancels a genuinely changed query and discards late backend hits", function()
    fixture("KnownNeedle", function(h)
      h.run(function()
        h.picker.input.filter.search = "DifferentQuery"
        h.timer.callback()
        h.complete() -- Deliberately late delivery must not escape the aborted finder.
      end)
      t.assert_true(h.stopped)
      t.assert_eq(#h.hits, 0)
      t.assert_true(h.timer.closed)
    end)
  end)
end)
