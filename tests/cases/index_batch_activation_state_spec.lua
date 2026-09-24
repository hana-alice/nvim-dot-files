local t = require("tests.harness")
t.bootstrap()
local runtime = require("ue.index.batch_runtime")

-- Exercise the production state machine with delayed helper completions and
-- explicit watch callbacks. No native compiler, watcher or user buffer starts.
local function fixture(body)
  runtime._reset_for_test()
  local root = vim.fn.tempname():gsub("\\", "/") .. "_activation_api"
  vim.fn.mkdir(root .. "/background/verified", "p")
  root = vim.fs.normalize(assert(vim.uv.fs_realpath(root)))
  local h = { calls = {}, queue = {}, continuations = {}, notifications = {}, watches = {}, restarts = {}, now = 0 }
  h.original = root .. "/background/compile_commands.json"
  h.config = { cmd_cwd = root }
  h.command = { "clangd", "--background-index", "--compile-commands-dir=" .. root .. "/background" }
  h.ctx = { paths = { semantic_cdb = h.original, clangd_dir = root } }
  h.descriptor = { ok = true, original_cdb = h.original,
    verified_cdb = root .. "/background/verified/compile_commands.json",
    info_sha256 = "publication-a", generation_id = "generation-a", compiler_environment = {},
    tool_path = root .. "/clangd.exe", receipts = { root .. "/receipt.json" },
    watch_roots = { root .. "/input" }, input_roots = { root .. "/input" },
    watched_files = { root .. "/input/file.h" }, exclude_roots = {} }
  h.opts = { no_buffer_watch = true,
    resolve_context = function() return h.ctx end,
    get_command = function() return h.command end,
    get_config = function() return h.config end,
    fingerprint = function() return "stamp-a" end,
    get_generation = function() return "generation-a" end,
    now_ms = function() return h.now end,
    schedule = function(callback) h.queue[#h.queue + 1] = callback end,
    probe_recursive = function(callback) callback(true) end,
    run_async = function(_, _, mode, callback)
      local call = { mode = mode, callback = callback, cancellations = 0 }
      h.calls[#h.calls + 1] = call
      return function() call.cancellations = call.cancellations + 1 end
    end,
    watch_factory = function(_, callback, options)
      local handle = { callback = callback, closed = false }
      function handle:close() self.closed = true end
      h.watches[#h.watches + 1] = handle
      return handle, { recursive = options.recursive, direct = not options.recursive }
    end,
    on_state = function(snapshot) h.notifications[#h.notifications + 1] = snapshot end,
    restart = function(clients) h.restarts[#h.restarts + 1] = clients end,
  }
  function h.flush()
    local count = 0
    while #h.queue > 0 do
      count = count + 1; assert(count < 100, "fixture callback loop")
      table.remove(h.queue, 1)()
    end
  end
  function h.prepare()
    runtime.prepare(0, root, function(value) h.continuations[#h.continuations + 1] = value end, h.opts)
  end
  function h.describe() h.calls[#h.calls].callback(vim.deepcopy(h.descriptor)) end
  function h.validate()
    h.calls[#h.calls].callback(vim.deepcopy(h.descriptor))
    h.flush()
  end
  local ok, err = xpcall(function() body(h, root) end, debug.traceback)
  runtime._reset_for_test(); h.flush()
  assert(vim.fs.normalize(assert(vim.uv.fs_realpath(root))) == root, "fixture cleanup path changed")
  vim.fn.delete(root, "rf")
  if not ok then error(err) end
end

t.describe("activation observation and cancellation", function()
  t.it("returns detached scalar snapshots without exporting mutable authority", function()
    fixture(function(h)
      t.assert_nil(runtime.activation(nil)); t.assert_nil(runtime.activation(h.original))
      h.prepare()
      local state = runtime.activation(h.original)
      t.assert_eq(state.phase, "describing"); t.assert_eq(state.pending_helpers, 1)
      t.assert_eq(state.stamp, "stamp-a"); t.assert_eq(state.generation, "generation-a")
      t.assert_false(state.ready); t.assert_false(state.failed)
      t.assert_type(state.attempt, "number"); t.assert_type(state.scope, "string")
      local allowed = { scope = true, attempt = true, stamp = true, generation = true, phase = true,
        reason = true, failed = true, ready = true, pending_helpers = true, retry_after = true, verified = true }
      for field, value in pairs(state) do
        t.assert_true(allowed[field], "unexpected exported field " .. field)
        t.assert_true(type(value) == "string" or type(value) == "number" or type(value) == "boolean")
      end
      state.phase, state.ready, state.attempt, state.stamp = "ready", true, -1, "forged"
      local next_state = runtime.activation(h.original)
      t.assert_eq(next_state.phase, "describing"); t.assert_false(next_state.ready)
      t.assert_true(next_state.attempt > 0); t.assert_eq(next_state.stamp, "stamp-a")
      t.assert_true(vim.deep_equal(runtime.command(h.command, h.config), h.command))
      h.describe()
      local noticed = h.notifications[#h.notifications]
      noticed.generation = "mutated notification"
      t.assert_eq(runtime.activation(h.original).generation, "generation-a")
      h.validate()
      local ready = runtime.activation(h.original)
      t.assert_true(ready.ready); t.assert_eq(ready.phase, "ready"); t.assert_eq(ready.pending_helpers, 0)
      t.assert_eq(ready.verified, h.descriptor.verified_cdb)
    end)
  end)

  t.it("rejects missing scopes and stale attempts without changing the current attempt", function()
    fixture(function(h, root)
      t.assert_false(runtime.cancel_activation(nil, 1))
      t.assert_false(runtime.cancel_activation(h.original, 1))
      h.prepare()
      local before = runtime.activation(h.original)
      t.assert_false(runtime.cancel_activation(root .. "/other/compile_commands.json", before.attempt))
      t.assert_false(runtime.cancel_activation(h.original, before.attempt + 1))
      t.assert_false(runtime.cancel_activation(h.original, nil))
      t.assert_true(vim.deep_equal(runtime.activation(h.original), before))
      t.assert_eq(h.calls[1].cancellations, 0); t.assert_eq(#h.continuations, 0)
    end)
  end)

  t.it("abandoning describe waits for real helper completion and cooldown before demand can retry", function()
    fixture(function(h)
      h.prepare()
      local first = runtime.activation(h.original)
      local old = h.calls[1]
      t.assert_true(runtime.cancel_activation(h.original, first.attempt))
      local abandoned = runtime.activation(h.original)
      t.assert_true(abandoned.failed); t.assert_false(abandoned.ready)
      t.assert_eq(abandoned.reason, "activation-abandoned"); t.assert_eq(abandoned.retry_after, 30000)
      t.assert_eq(abandoned.pending_helpers, 1); t.assert_eq(old.cancellations, 1)
      t.assert_eq(#h.continuations, 1)
      t.assert_false(runtime.cancel_activation(h.original, first.attempt), "already failed attempt must reject")
      h.now = 30000; h.prepare()
      t.assert_eq(#h.calls, 1, "termination request is not helper completion")
      old.callback(vim.deepcopy(h.descriptor))
      t.assert_eq(runtime.activation(h.original).pending_helpers, 0)
      t.assert_eq(#h.calls, 1, "helper completion must not schedule a new proof")
      h.now = 29999; h.prepare(); t.assert_eq(#h.calls, 1)
      h.now = 30000; h.prepare()
      local current = runtime.activation(h.original)
      t.assert_true(current.attempt > first.attempt); t.assert_eq(current.pending_helpers, 1)
      t.assert_false(runtime.cancel_activation(h.original, first.attempt))
      local notifications = #h.notifications
      old.callback(vim.deepcopy(h.descriptor))
      t.assert_eq(#h.notifications, notifications, "duplicate helper completion must be ignored")
      t.assert_true(vim.deep_equal(runtime.activation(h.original), current))
      h.describe(); h.validate(); t.assert_true(runtime.activation(h.original).ready)
    end)
  end)

  for _, stage in ipairs({ "validating", "ready" }) do
    t.it("cancels an unattached " .. stage .. " candidate without granting late authority", function()
      fixture(function(h)
        h.prepare(); h.describe()
        local validation = h.calls[2]
        if stage == "ready" then h.validate() end
        local before = runtime.activation(h.original)
        t.assert_true(runtime.cancel_activation(h.original, before.attempt))
        t.assert_false(runtime.activation(h.original).ready, "guard revocation is immediate")
        h.flush()
        local failed = runtime.activation(h.original)
        t.assert_true(failed.failed); t.assert_eq(failed.reason, "activation-abandoned")
        t.assert_true(h.watches[1].closed)
        t.assert_eq(failed.pending_helpers, stage == "validating" and 1 or 0)
        if stage == "validating" then
          t.assert_eq(validation.cancellations, 1)
          validation.callback(vim.deepcopy(h.descriptor)); h.flush()
          t.assert_eq(runtime.activation(h.original).pending_helpers, 0)
        end
        t.assert_false(runtime.activation(h.original).ready)
        t.assert_eq(runtime.activation(h.original).reason, "activation-abandoned")
        t.assert_true(vim.deep_equal(runtime.command(h.command, h.config), h.command))
        for _, clients in ipairs(h.restarts) do t.assert_eq(#clients, 0, "no attached reader should be restarted") end
      end)
    end)
  end

  t.it("refuses cancellation once a frozen client is attached", function()
    fixture(function(h)
      h.prepare(); h.describe(); h.validate()
      local config = vim.deepcopy(h.config)
      runtime.configure_process(runtime.command(h.command, config), config)
      local client = { id = 710, config = config, attached_buffers = {},
        request = function() return true, 1 end, cancel_request = function() end }
      runtime.attach(client, 0)
      local before = runtime.activation(h.original)
      t.assert_true(before.ready)
      t.assert_false(runtime.cancel_activation(h.original, before.attempt))
      h.flush()
      t.assert_true(vim.deep_equal(runtime.activation(h.original), before))
      t.assert_eq(client._ue_batch_guard.guard:status().state, "ready")
      t.assert_eq(#h.restarts, 0)
    end)
  end)

  t.it("isolates throwing observers while notifying after state changes and before ready continuation", function()
    fixture(function(h)
      local observed = {}
      h.opts.on_state = function(state)
        observed[#observed + 1] = { snapshot = vim.deepcopy(state), roots = #h.continuations, restarts = #h.restarts }
        state.phase, state.failed, state.ready = "observer mutation", true, false
        error("observer failure must not affect activation")
      end
      h.prepare(); h.describe()
      t.assert_eq(observed[1].snapshot.phase, "validating")
      t.assert_eq(observed[1].snapshot.pending_helpers, 1)
      h.calls[2].callback(vim.deepcopy(h.descriptor))
      t.assert_eq(observed[#observed].snapshot.pending_helpers, 0)
      t.assert_false(runtime.activation(h.original).ready, "helper return alone does not establish guard readiness")
      h.flush()
      local ready = observed[#observed]
      t.assert_true(ready.snapshot.ready); t.assert_eq(ready.roots, 0)
      t.assert_eq(#h.continuations, 1); t.assert_true(runtime.activation(h.original).ready)
      local attempt = runtime.activation(h.original).attempt
      t.assert_true(runtime.cancel_activation(h.original, attempt)); h.flush()
      t.assert_true(observed[#observed].snapshot.failed)
      t.assert_eq(observed[#observed].snapshot.reason, "activation-abandoned")
      t.assert_eq(observed[#observed].restarts, 1, "fallback notification must follow scoped retirement")
      t.assert_eq(runtime.activation(h.original).reason, "activation-abandoned")
    end)
  end)
end)
