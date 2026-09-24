local t = require("tests.harness")
t.bootstrap()
local runtime = require("ue.index.batch_runtime")

local function fixture(body)
  runtime._reset_for_test()
  local root = vim.fn.tempname():gsub("\\", "/") .. "_batch_recovery"
  vim.fn.mkdir(root .. "/engine", "p")
  root = vim.fs.normalize(assert(vim.uv.fs_realpath(root)))
  vim.fn.mkdir(root .. "/background/verified", "p")
  local source = root .. "/engine/source.cpp"
  vim.fn.writefile({ "int saved;" }, source)
  local buffer = vim.fn.bufadd(source)
  vim.fn.bufload(buffer)
  vim.bo[buffer].filetype = "cpp"
  local h = { root = root, buffer = buffer, now = 0, timers = {}, queue = {}, calls = {}, watches = {},
    restarts = {}, fallbacks = {}, roots = {}, stamp = "publication-a", generation = "generation-a", restart_allowed = true }
  h.buffers = { buffer }
  h.ctx = { engine_root = root .. "/engine", project_root = root .. "/project",
    paths = { clangd_dir = root, semantic_cdb = root .. "/background/compile_commands.json" } }
  h.command = { "clangd", "--background-index", "--compile-commands-dir=" .. root .. "/background" }
  h.config = { filetypes = { "cpp" }, cmd_cwd = root }
  h.original = { id = 101, name = "clangd", initialized = true, attached_buffers = { [buffer] = true },
    config = { cmd = vim.deepcopy(h.command), _ue_resolved_cmd = vim.deepcopy(h.command),
      cmd_cwd = root, root_dir = h.ctx.engine_root, filetypes = { "cpp" } }, stopped = false }
  h.original.is_stopped = function() return h.original.stopped end
  h.original.stop = function() error("coordinator must use its scoped restart dependency") end
  h.clients = { h.original }
  h.descriptor = { ok = true, info_sha256 = "info-a", generation_id = h.generation,
    compiler_environment = {}, tool_path = root .. "/clangd.exe", receipts = { root .. "/receipt.json" },
    watch_roots = { root .. "/engine", root .. "/background" }, input_roots = { root .. "/engine" },
    exclude_roots = {}, watched_files = { source, root .. "/receipt.json" },
    original_cdb = h.ctx.paths.semantic_cdb, verified_cdb = root .. "/background/verified/compile_commands.json" }
  local function schedule(fn) h.queue[#h.queue + 1] = fn end
  local function defer(fn, ms)
    local timer = { due = h.now + ms, callback = fn, closed = false }
    function timer:stop() self.closed = true end
    function timer:close() self.closed = true end
    h.timers[#h.timers + 1] = timer
    return timer
  end
  h.opts = { no_buffer_watch = false, clangd = "fixture-clangd", resolve_context = function() return h.ctx end,
    get_command = function() return h.command end, get_config = function() return h.config end,
    fingerprint = function() return h.stamp end, get_generation = function() return h.generation end,
    now_ms = function() return h.now end, schedule = schedule,
    probe_recursive = function(done) done(true) end,
    run_async = function(info, _, mode, callback)
      local call = { info = info, mode = mode, callback = callback, cancelled = false }
      h.calls[#h.calls + 1] = call
      return function() call.cancelled = true end
    end,
    watch_factory = function(path, callback, options)
      local handle = { path = path, callback = callback, closed = false }
      function handle:stop() self.closed = true end
      function handle:close() self.closed = true end
      h.watches[#h.watches + 1] = handle
      return handle, { recursive = options.recursive, direct = not options.recursive }
    end,
    restart = function(clients) h.fallbacks[#h.fallbacks + 1] = clients end,
  }
  local get_clients = vim.lsp.get_clients
  vim.lsp.get_clients = function(filter)
    local found = {}
    for _, client in ipairs(h.clients) do
      if not client.is_stopped() and (not filter or not filter.bufnr or client.attached_buffers[filter.bufnr])
          and (not filter or not filter.name or filter.name == client.name) then found[#found + 1] = client end
    end
    return found
  end
  local owner
  local ok, err = xpcall(function()
    owner = require("ue.index.batch_recovery").new({ runtime = runtime,
      get_clients = function() return h.clients end, now_ms = function() return h.now end,
      delay_ms = 200, schedule = schedule, defer = defer,
      subscribe = function(callback) h.event = callback; return function() h.unsubscribed = true end end,
      restart = function(clients)
        h.restarts[#h.restarts + 1] = clients
        if h.restart_allowed then
          for _, client in ipairs(clients) do client.stopped = true end
        end
        return h.restart_allowed, 200
      end })
    h.owner = owner
    function h.flush()
      local count = 0
      while #h.queue > 0 do
        count = count + 1; assert(count < 100, "coordinator scheduled an unbounded immediate loop")
        table.remove(h.queue, 1)()
      end
    end
    function h.advance(ms)
      h.now = h.now + ms
      h.flush()
      local pending = h.timers
      h.timers = {}
      for _, timer in ipairs(pending) do
        if not timer.closed and timer.due <= h.now then timer.closed = true; timer.callback()
        elseif not timer.closed then h.timers[#h.timers + 1] = timer end
      end
      h.flush()
    end
    function h.emit(event)
      if h.event then h.event({ event = event or "BufModifiedSet", buf = buffer, data = { client_id = h.original.id } }) end
      h.flush()
    end
    function h.edit()
      vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { "int unsaved;" })
      h.emit("BufModifiedSet")
    end
    function h.clean()
      vim.api.nvim_buf_call(buffer, function() vim.cmd("silent edit!") end)
      h.emit("BufModifiedSet")
    end
    function h.prepare()
      return owner:prepare(buffer, h.ctx.engine_root, function(value) h.roots[#h.roots + 1] = value end, h.opts)
    end
    function h.start()
      h.edit(); h.prepare()
      t.assert_eq(#h.calls, 0, "dirty documents must not start descriptor helpers")
      h.clean(); h.advance(200)
      t.assert_eq(#h.calls, 1, "one clean original reader should start one descriptor")
      t.assert_eq(h.calls[1].mode, "describe")
      h.calls[1].callback(vim.deepcopy(h.descriptor)); h.flush()
      t.assert_eq(#h.calls, 2)
      t.assert_eq(h.calls[2].mode, "validate")
    end
    function h.validate(result)
      h.calls[#h.calls].callback(vim.tbl_extend("force", vim.deepcopy(h.descriptor), result or {})); h.flush()
    end
    function h.second_scope()
      local second = h.root .. "/second"
      vim.fn.mkdir(second .. "/engine", "p")
      vim.fn.mkdir(second .. "/background/verified", "p")
      local source = second .. "/engine/source.cpp"
      vim.fn.writefile({ "int second_saved;" }, source)
      local second_buffer = vim.fn.bufadd(source)
      h.buffers[#h.buffers + 1] = second_buffer
      vim.fn.bufload(second_buffer)
      vim.bo[second_buffer].filetype = "cpp"
      vim.api.nvim_buf_set_lines(second_buffer, 0, -1, false, { "int second_unsaved;" })
      local ctx = { engine_root = second .. "/engine", paths = {
        clangd_dir = second, semantic_cdb = second .. "/background/compile_commands.json" } }
      local command = { "clangd", "--background-index", "--compile-commands-dir=" .. second .. "/background" }
      h.clients[#h.clients + 1] = { id = 104, name = "clangd", initialized = true,
        attached_buffers = { [second_buffer] = true },
        config = { cmd = command, _ue_resolved_cmd = command, cmd_cwd = h.root, root_dir = ctx.engine_root },
        is_stopped = function() return false end }
      local opts = vim.tbl_extend("force", h.opts, {
        resolve_context = function() return ctx end, get_command = function() return command end,
      })
      h.owner:prepare(second_buffer, ctx.engine_root, function() end, opts)
      vim.api.nvim_buf_call(second_buffer, function() vim.cmd("silent edit!") end)
      h.emit("BufModifiedSet"); h.advance(200)
    end
    body(h)
  end, debug.traceback)
  if owner then owner:stop() end
  runtime._reset_for_test()
  if h.flush then h.flush() end
  vim.lsp.get_clients = get_clients
  for _, owned in ipairs(h.buffers) do
    if vim.api.nvim_buf_is_valid(owned) then vim.api.nvim_buf_delete(owned, { force = true }) end
  end
  vim.fn.delete(root, "rf")
  if not ok then error(err) end
end

t.describe("document-driven frozen batch recovery", function()
  t.it("retains a dirty original across publication then fully validates the new frozen view before promotion", function()
    fixture(function(h)
      h.edit(); h.prepare()
      local recovery = require("ue.index.batch_recovery")
      local saved_status = recovery.status
      recovery.status = function() return h.owner:status() end
      local state = { last_restart_at = 99, restart_debounce_s = 10 }
      local index = {}
      require("ue.index._clangd")(index, { RT = state, h = { unix_now = function() return 100 end } })
      local ok, err = pcall(function()
        local restarted, delay = index.maybe_restart_clangd_for_index({
          context = h.ctx, original_changed = false,
          defer_fn = function() error("retaining the reader must not schedule a restart") end,
        })
        t.assert_false(restarted); t.assert_nil(delay)
        t.assert_eq(state.last_restart_at, 99)
        t.assert_eq(#h.calls, 0); t.assert_eq(#h.restarts, 0)
        t.assert_false(h.original.stopped); t.assert_true(vim.bo[h.buffer].modified)
      end)
      recovery.status = saved_status
      if not ok then error(err) end
      h.stamp = "publication-b"
      h.descriptor.info_sha256 = "info-b"
      h.clean(); h.advance(200)
      t.assert_eq(#h.calls, 1); t.assert_eq(h.calls[1].mode, "describe")
      t.assert_false(h.original.stopped)
      h.calls[1].callback(vim.deepcopy(h.descriptor)); h.flush()
      t.assert_eq(#h.calls, 2); t.assert_eq(h.calls[2].mode, "validate")
      t.assert_eq(#h.restarts, 0)
      h.validate(); h.advance(200)
      t.assert_eq(#h.restarts, 1); t.assert_eq(#h.restarts[1], 1)
      t.assert_eq(h.restarts[1][1], h.original)
      t.assert_true(runtime.activation(h.ctx.paths.semantic_cdb).ready)
    end)
  end)

  t.it("keeps the original reader alive through clean validation then restarts only that reader", function()
    fixture(function(h)
      local other = { id = 102, name = "clangd", initialized = true, attached_buffers = { [h.buffer] = true },
        config = { cmd = { "clangd", "--compile-commands-dir=" .. h.root .. "/other" } }, is_stopped = function() return false end }
      h.clients[#h.clients + 1] = other
      h.start()
      t.assert_false(h.original.stopped)
      t.assert_eq(#h.restarts, 0)
      t.assert_true(vim.deep_equal(runtime.command(h.command), h.command))
      h.validate(); h.advance(200)
      t.assert_eq(#h.restarts, 1)
      t.assert_eq(#h.restarts[1], 1)
      t.assert_eq(h.restarts[1][1], h.original)
      t.assert_true(runtime.activation(h.ctx.paths.semantic_cdb).ready)
    end)
  end)

  t.it("coalesces repeated clean events across descriptor validation and pending handoff", function()
    fixture(function(h)
      h.start()
      for _ = 1, 5 do h.emit("BufWritePost"); h.emit("LspAttach") end
      h.advance(200)
      t.assert_eq(#h.calls, 2)
      h.validate(); h.advance(200)
      for _ = 1, 5 do h.emit("BufModifiedSet"); h.advance(200) end
      t.assert_eq(#h.calls, 2)
      t.assert_eq(#h.restarts, 1)
    end)
  end)

  t.it("waits for an original reader when the buffer becomes clean before attachment", function()
    fixture(function(h)
      h.clients = {}
      h.edit(); h.prepare(); h.clean(); h.advance(200)
      t.assert_eq(#h.calls, 0)
      h.clients = { h.original }; h.owner:attach(h.original, h.buffer); h.advance(200)
      t.assert_eq(#h.calls, 1)
    end)
  end)

  t.it("revokes a validation on redirty and rejects its late successful result", function()
    fixture(function(h)
      h.start()
      h.edit()
      local state = runtime.activation(h.ctx.paths.semantic_cdb)
      t.assert_true(state.failed, "redirty must revoke before the debounce expires")
      t.assert_true(h.calls[2].cancelled)
      h.validate(); h.advance(200)
      t.assert_false(runtime.activation(h.ctx.paths.semantic_cdb).ready)
      t.assert_eq(#h.restarts, 0)
      t.assert_false(h.original.stopped)
    end)
  end)

  t.it("honors both the document retry cooldown and actual old helper completion", function()
    fixture(function(h)
      h.start(); h.edit(); h.clean()
      h.advance(29999)
      t.assert_eq(#h.calls, 2)
      h.advance(201)
      t.assert_eq(#h.calls, 2, "cancel is not evidence of helper exit")
      h.validate()
      t.assert_false(h.original.stopped)
      h.advance(200)
      t.assert_eq(#h.calls, 3, "helper completion should wake the clean document retry")
      t.assert_eq(h.calls[3].mode, "describe")
    end)
  end)

  for _, failure in ipairs({ "receipt-input-or-asset-changed", "input-changed" }) do
    t.it("does not automatically retry the non-document failure " .. failure, function()
      fixture(function(h)
        h.start()
        if failure == "input-changed" then
          h.watches[1].callback(nil, "source.cpp", { action = 3, change = true, directory = false })
          h.validate()
        else h.validate({ ok = false, reason = failure }) end
        t.assert_eq(runtime.activation(h.ctx.paths.semantic_cdb).reason, failure)
        for _ = 1, 3 do h.emit("BufWritePost"); h.advance(60000) end
        t.assert_eq(#h.calls, 2)
        t.assert_eq(#h.restarts, 0)
      end)
    end)
  end

  for _, change in ipairs({ "reader", "profile", "context" }) do
    t.it("abandons a pending candidate when its " .. change .. " changes", function()
      fixture(function(h)
        h.start()
        if change == "reader" then h.clients = {}; h.emit("LspDetach")
        elseif change == "profile" then h.config.cmd_env = { CPATH = h.root .. "/new-includes" }; h.emit("BufWritePost")
        else
          h.ctx = vim.deepcopy(h.ctx)
          h.ctx.paths.semantic_cdb = h.root .. "/other/compile_commands.json"
          h.emit("BufWritePost")
        end
        h.advance(200); h.validate(); h.advance(200)
        t.assert_eq(#h.restarts, 0)
        t.assert_false(h.original.stopped)
        t.assert_false(runtime.activation(h.descriptor.original_cdb).ready)
      end)
    end)
  end

  t.it("debounces a rejected scoped restart without repeating successful validation", function()
    fixture(function(h)
      h.start(); h.restart_allowed = false; h.validate()
      t.assert_eq(#h.restarts, 1)
      h.emit("BufWritePost"); h.advance(199)
      t.assert_eq(#h.restarts, 1)
      h.restart_allowed = true; h.advance(1)
      t.assert_eq(#h.restarts, 2)
      t.assert_eq(#h.calls, 2)
    end)
  end)

  t.it("confirms the real frozen attachment and does not restart it on clean events", function()
    fixture(function(h)
      h.start(); h.validate(); h.advance(200)
      local config = vim.deepcopy(h.config)
      config.cmd = runtime.configure_process(runtime.command(h.command), config)
      config._ue_resolved_cmd = config.cmd
      local frozen = { id = 103, name = "clangd", initialized = true, config = config,
        attached_buffers = { [h.buffer] = true }, is_stopped = function() return false end,
        request = function() return true, 1 end }
      h.clients = { frozen }; h.owner:attach(frozen, h.buffer)
      for _ = 1, 3 do h.emit("LspAttach"); h.emit("BufModifiedSet"); h.advance(200) end
      t.assert_eq(#h.restarts, 1)
      t.assert_eq(#h.calls, 2)
      t.assert_true(runtime.activation(h.ctx.paths.semantic_cdb).ready)
    end)
  end)

  t.it("stop cancels the candidate subscription timers and late completion callbacks", function()
    fixture(function(h)
      h.start(); h.owner:stop(); h.flush()
      t.assert_true(h.unsubscribed)
      t.assert_true(h.calls[2].cancelled)
      for _, watch in ipairs(h.watches) do t.assert_true(watch.closed) end
      for _, timer in ipairs(h.timers) do t.assert_true(timer.closed) end
      h.validate(); h.emit("BufWritePost"); h.advance(60000)
      t.assert_eq(#h.calls, 2)
      t.assert_eq(#h.restarts, 0)
      t.assert_false(runtime.activation(h.ctx.paths.semantic_cdb).ready)
    end)
  end)

  t.it("serializes two automatic scopes until the failed scope's helper actually exits", function()
    fixture(function(h)
      h.start()
      local old_validation = h.calls[2]
      h.second_scope()
      t.assert_eq(#h.calls, 2, "scope B must wait while scope A validates")
      h.watches[1].callback(nil, "source.cpp", { action = 3, change = true, directory = false })
      h.flush(); h.advance(1000)
      t.assert_true(old_validation.cancelled)
      t.assert_eq(runtime.activation(h.ctx.paths.semantic_cdb).pending_helpers, 1)
      t.assert_eq(#h.calls, 2, "scope A fallback/on_dir is not a helper-exit barrier")
      old_validation.callback(vim.deepcopy(h.descriptor)); h.flush(); h.advance(200)
      t.assert_eq(#h.calls, 3, "scope B must wake after the actual scope A helper callback")
      t.assert_eq(h.calls[3].mode, "describe")
      t.assert_contains(h.calls[3].info:gsub("\\", "/"), "/second/background/batches.json")
      t.assert_eq(#h.restarts, 0)
    end)
  end)

  t.it("ignores an already queued old timer callback after dirty cancellation and clean rearm", function()
    fixture(function(h)
      h.edit(); h.prepare(); h.clean()
      local old = assert(h.timers[#h.timers])
      h.advance(100)
      h.edit(); h.clean()
      local replacement = assert(h.timers[#h.timers])
      t.assert_true(old.closed)
      t.assert_true(replacement ~= old)
      old.callback() -- A timer may already have queued delivery when stop/close runs.
      h.flush()
      t.assert_eq(#h.calls, 0, "stale callback must not clear the replacement timer and start validation")
      t.assert_false(replacement.closed)
      h.advance(199)
      t.assert_eq(#h.calls, 0)
      h.advance(1)
      t.assert_eq(#h.calls, 1)
      t.assert_eq(h.calls[1].mode, "describe")
    end)
  end)

  t.it("accepts an external frozen attachment during restart backoff without later stopping the original", function()
    fixture(function(h)
      h.start(); h.restart_allowed = false; h.validate()
      t.assert_eq(#h.restarts, 1)
      local config = vim.deepcopy(h.config)
      config.cmd = runtime.configure_process(runtime.command(h.command), config)
      config._ue_resolved_cmd = config.cmd
      local frozen = { id = 105, name = "clangd", initialized = true, config = config,
        attached_buffers = { [h.buffer] = true }, is_stopped = function() return false end,
        request = function() return true, 1 end }
      h.clients[#h.clients + 1] = frozen
      h.owner:attach(frozen, h.buffer)
      h.restart_allowed = true
      h.emit("LspAttach"); h.advance(1000)
      t.assert_eq(#h.restarts, 1, "the actual same-attempt attachment already completed promotion")
      t.assert_false(h.original.stopped)
      t.assert_eq(#h.calls, 2)
      t.assert_true(runtime.activation(h.ctx.paths.semantic_cdb).ready)
    end)
  end)

  t.it("retains the automatic slot after a manual replacement until the old attempt drains", function()
    fixture(function(h)
      h.start(); h.second_scope()
      local old_validation = h.calls[2]
      local old_attempt = runtime.activation(h.ctx.paths.semantic_cdb).attempt
      h.stamp = "manual-publication-b"
      runtime.prepare(h.buffer, h.ctx.engine_root, function() end, h.opts)
      t.assert_eq(#h.calls, 3)
      h.calls[3].callback({ ok = false, reason = "manual-descriptor-rejected" }); h.flush()
      local replacement = runtime.activation(h.ctx.paths.semantic_cdb)
      t.assert_true(replacement.attempt ~= old_attempt)
      t.assert_true(replacement.failed)
      t.assert_eq(replacement.pending_helpers, 0)
      t.assert_true(old_validation.cancelled)
      h.emit("BufWritePost"); h.advance(1000)
      t.assert_eq(#h.calls, 3, "a different drained record does not prove the owned old helper exited")
      old_validation.callback(vim.deepcopy(h.descriptor)); h.flush(); h.advance(200)
      t.assert_eq(#h.calls, 4, "the replaced old record's drain must still wake the waiting scope")
      t.assert_contains(h.calls[4].info:gsub("\\", "/"), "/second/background/batches.json")
      t.assert_eq(#h.restarts, 0)
    end)
  end)

  for _, mismatch in ipairs({ "profile", "cwd" }) do
    t.it("does not confirm a matching-attempt frozen client rejected for its " .. mismatch, function()
      fixture(function(h)
        h.start(); h.restart_allowed = false; h.validate()
        local config = vim.deepcopy(h.config)
        config.cmd = runtime.configure_process(runtime.command(h.command), config)
        config._ue_resolved_cmd = config.cmd
        if mismatch == "profile" then config._ue_batch_server_profile = { query_driver = "wrong-driver" }
        else config._ue_batch_launch_cwd = h.root .. "/wrong-cwd" end
        local frozen = { id = 106, name = "clangd", initialized = true, config = config,
          attached_buffers = { [h.buffer] = true }, is_stopped = function() return false end,
          request = function() return true, 1 end }
        local state = runtime.activation(h.ctx.paths.semantic_cdb)
        t.assert_eq(config._ue_batch_attempt, state.attempt)
        t.assert_eq(config._ue_batch_stamp, state.stamp)
        h.clients[#h.clients + 1] = frozen
        -- Rejected fake clients must never reach the real editor restart machinery.
        local index = require("ue.index")
        local restart, rejected = index.maybe_restart_clangd_for_index, nil
        index.maybe_restart_clangd_for_index = function(opts) rejected = opts.get_clients(); return true end
        local accepted, error_message = xpcall(function() h.owner:attach(frozen, h.buffer) end, debug.traceback)
        index.maybe_restart_clangd_for_index = restart
        if not accepted then error(error_message) end
        t.assert_eq(rejected and rejected[1], frozen, "runtime must actually reject the fake client")
        h.restart_allowed = true; h.advance(200)
        t.assert_eq(#h.restarts, 2, "rejected attachment must leave the genuine promotion pending")
        t.assert_eq(h.restarts[2][1], h.original)
        t.assert_eq(#h.calls, 2)
      end)
    end)
  end
end)
