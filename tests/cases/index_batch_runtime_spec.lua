local t = require("tests.harness")
t.bootstrap()
local runtime = require("ue.index.batch_runtime")

local function fixture(body)
  runtime._reset_for_test()
  local root = vim.fn.tempname():gsub("\\", "/") .. "_batch_runtime"
  vim.fn.mkdir(root, "p")
  root = vim.fs.normalize(assert(vim.uv.fs_realpath(root)))
  vim.fn.mkdir(root .. "/background/verified", "p")
  local h = { queue = {}, calls = {}, watches = {}, restarts = {}, roots = {}, config = {}, stamp = "metadata-v1", generation = "gen-a", now = 0 }
  h.ctx = { paths = { clangd_dir = root, semantic_cdb = root .. "/background/compile_commands.json" } }
  h.command = { "clangd", "--background-index", "--compile-commands-dir=" .. root .. "/background" }
  h.descriptor = { ok = true, info_sha256 = "sha-v1", generation_id = "gen-a", compiler_environment = {}, tool_path = root .. "/clangd.exe",
    receipts = { root .. "/receipt.json" },
    watch_roots = { root .. "/input", root .. "/output" }, exclude_roots = { root .. "/output" },
    input_roots = { root .. "/input" },
    watched_files = { root .. "/output/frozen.cpp", root .. "/output/metadata.json" },
    original_cdb = h.ctx.paths.semantic_cdb, verified_cdb = root .. "/background/verified/compile_commands.json" }
  h.opts = {
    clangd = "fixture-clangd", no_buffer_watch = true,
    resolve_context = function() return h.ctx end,
    get_command = function() return h.command end,
    get_config = function() return h.config end,
    fingerprint = function() return h.stamp end,
    get_generation = function() return h.generation end,
    now_ms = function() return h.now end,
    schedule = function(callback) h.queue[#h.queue + 1] = callback end,
    probe_recursive = function(callback) callback(h.capable ~= false) end,
    run_async = function(_, _, mode, callback, request)
      h.calls[#h.calls + 1] = { mode = mode, callback = callback, request = vim.deepcopy(request) }
      return function() end
    end,
    watch_factory = function(path, callback, options)
      t.assert_eq(type(options.recursive), "boolean")
      local handle = { root = path, recursive = options.recursive, callback = callback, close = function() end, stop = function() end }
      h.watches[#h.watches + 1] = handle
      return handle, { recursive = options.recursive, direct = not options.recursive }
    end,
    restart = function(clients) h.restarts[#h.restarts + 1] = clients end,
  }
  function h.flush()
    while #h.queue > 0 do table.remove(h.queue, 1)() end
  end
  function h.prepare()
    return runtime.prepare(0, root, function(value) h.roots[#h.roots + 1] = value end, h.opts)
  end
  function h.describe() h.calls[#h.calls].callback(h.descriptor) end
  function h.result(overrides)
    return vim.tbl_extend("force", vim.deepcopy(h.descriptor), overrides or {})
  end
  function h.validate()
    h.calls[#h.calls].callback(h.result())
    h.flush()
  end
  local ok, err = xpcall(function() body(h, root) end, debug.traceback)
  runtime._reset_for_test()
  h.flush()
  vim.fn.delete(root, "rf")
  if not ok then error(err) end
end

t.describe("frozen batch startup runtime", function()
  local query_driver_forms = {
    { "--query-driver=C:/toolchain/*clang++.exe" },
    { "-query-driver=C:/toolchain/*clang++.exe" },
    { "--query-driver", "C:/toolchain/*clang++.exe" },
    { "-query-driver", "C:/toolchain/*clang++.exe" },
  }

  t.it("retains original startup without helpers for every nonempty query-driver spelling", function()
    for _, arguments in ipairs(query_driver_forms) do
      fixture(function(h)
        vim.list_extend(h.command, arguments)
        h.opts.fingerprint = function() error("uncertified profile must be rejected before metadata") end
        for count = 1, 2 do
          local _, reason = h.prepare()
          t.assert_eq(reason, "uncertified-clangd-query-driver")
          t.assert_eq(#h.roots, count, "original startup callback must fire exactly once per request")
          t.assert_eq(#h.calls, 0, "uncertified profile must never start descriptor or validation helpers")
          t.assert_true(vim.deep_equal(runtime.command(h.command), h.command))
        end
      end)
    end
  end)

  t.it("does not reuse ready activation after the server adds query-driver", function()
    fixture(function(h)
      h.prepare(); h.describe(); h.validate()
      local certified = vim.deepcopy(h.command)
      t.assert_contains(runtime.command(certified)[3], "/verified")
      vim.list_extend(h.command, query_driver_forms[1])
      local _, reason = h.prepare()
      t.assert_eq(reason, "uncertified-clangd-query-driver")
      t.assert_eq(#h.calls, 2, "ready metadata must not bypass the profile guard or trigger new validation")
      t.assert_eq(#h.roots, 2)
      t.assert_true(vim.deep_equal(runtime.command(h.command), h.command))
      t.assert_contains(runtime.command(certified)[3], "/verified", "the existing certified client remains safe")
      h.flush()
      t.assert_eq(#h.restarts, 0)
    end)
  end)

  t.it("returns directly selected frozen commands to the original view without altering query-driver or caller env", function()
    for _, arguments in ipairs(query_driver_forms) do
      fixture(function(h)
        h.prepare(); h.describe(); h.validate()
        local before = { KEEP = "caller", LOCALAPPDATA = "caller-cache" }
        local config = { cmd_env = vim.deepcopy(before) }
        local frozen = runtime.configure_process(runtime.command(h.command), config)
        vim.list_extend(frozen, arguments)
        frozen[#frozen + 1] = "--log=verbose"
        local expected = vim.list_extend(vim.deepcopy(h.command), arguments)
        expected[#expected + 1] = "--log=verbose"
        local original = runtime.configure_process(frozen, config)
        t.assert_true(vim.deep_equal(original, expected), "only the selected CDB directory may change")
        t.assert_true(vim.deep_equal(config.cmd_env, before), "restore owned cache overrides and preserve caller env")
        t.assert_eq(config._ue_batch_disabled_reason, "uncertified-clangd-query-driver")
        t.assert_nil(config._ue_batch_scope)
        t.assert_contains(runtime.command(h.command)[3], "/verified", "do not revoke another safe client")
        h.flush()
        t.assert_eq(#h.restarts, 0)
      end)
    end
  end)

  t.it("permits empty query-driver values without treating unrelated flags as a profile change", function()
    for _, arguments in ipairs({ { "--query-driver=" }, { "-query-driver=" },
      { "--query-driver", "" }, { "-query-driver", "" } }) do
      fixture(function(h)
        vim.list_extend(h.command, arguments)
        h.command[#h.command + 1] = "--log=verbose"
        h.prepare(); h.describe(); h.validate()
        local config = { cmd_env = { KEEP = "caller" } }
        local command = runtime.configure_process(runtime.command(h.command), config)
        t.assert_contains(command[3], "/verified")
        t.assert_eq(command[#command], "--log=verbose")
        t.assert_nil(config._ue_batch_disabled_reason)
      end)
    end
  end)

  t.it("does not invalidate an unrelated certified scope when another scope uses query-driver", function()
    fixture(function(h, root)
      h.prepare(); h.describe(); h.validate()
      local certified = vim.deepcopy(h.command)
      h.ctx = { paths = { clangd_dir = root .. "/other", semantic_cdb = root .. "/other/background/compile_commands.json" } }
      h.command = { "clangd", "--compile-commands-dir=" .. root .. "/other/background", "--query-driver=other-clang" }
      local _, reason = h.prepare()
      t.assert_eq(reason, "uncertified-clangd-query-driver")
      t.assert_eq(#h.calls, 2)
      t.assert_true(vim.deep_equal(runtime.command(h.command), h.command))
      t.assert_contains(runtime.command(certified)[3], "/verified")
      h.flush()
      t.assert_eq(#h.restarts, 0)
    end)
  end)

  t.it("keeps original commands until watched asynchronous validation completes", function()
    fixture(function(h)
      h.prepare()
      t.assert_eq(#h.roots, 0)
      t.assert_true(vim.deep_equal(runtime.command(h.command), h.command))
      h.describe()
      t.assert_eq(#h.watches, 2)
      t.assert_eq(h.calls[2].mode, "validate")
      t.assert_true(vim.deep_equal(runtime.command(h.command), h.command))
      h.validate()
      t.assert_eq(#h.roots, 1)
      t.assert_contains(runtime.command(h.command)[3], "/verified")
      h.prepare()
      t.assert_eq(#h.calls, 2, "unchanged ready metadata must not rehash receipts")
      t.assert_eq(#h.roots, 2)
      local custom = vim.list_extend(vim.deepcopy(h.command), { "--compile-commands-dir=/custom" })
      t.assert_true(vim.deep_equal(runtime.command(custom), custom))
    end)
  end)

  t.it("isolates frozen process cache and immediately gates only its clients on input changes", function()
    fixture(function(h, root)
      h.prepare(); h.describe(); h.validate()
      local config = { cmd_env = { EXISTING = "retained" } }
      local frozen = runtime.configure_process(runtime.command(h.command), config)
      t.assert_contains(config.cmd_env.LOCALAPPDATA, "/frozen-cache")
      t.assert_eq(config.cmd_env.XDG_CACHE_HOME, config.cmd_env.LOCALAPPDATA)
      t.assert_eq(config.cmd_env.EXISTING, "retained")
      local callback
      local client = { id = 3, config = config,
        request = function(_, _, _, handler) callback = handler; return true, 1 end,
        cancel_request = function() end }
      runtime.attach(client, 0)
      local response
      client:request("textDocument/references", {}, function(err, result) response = { err, result } end)
      h.watches[2].callback(nil, "validation-output.log", {})
      t.assert_contains(runtime.command(h.command)[3], "/verified", "excluded proof output must not invalidate")
      h.watches[2].callback(nil, "frozen.cpp", {})
      t.assert_false(client:request("textDocument/rename", {}, function() end))
      t.assert_true(vim.deep_equal(runtime.command(h.command), h.command), "event revokes authority before deferred fallback")
      callback(nil, { stale = true })
      t.assert_eq(response[1].code, -32801)
      t.assert_nil(response[2])
      h.flush()
      t.assert_eq(#h.restarts, 1)
      t.assert_eq(#h.restarts[1], 1)
      t.assert_eq(h.restarts[1][1], client)
      local original = runtime.configure_process(frozen, config)
      t.assert_eq(original[3], "--compile-commands-dir=" .. root .. "/background")
      t.assert_nil(config.cmd_env.LOCALAPPDATA)
      t.assert_eq(config.cmd_env.EXISTING, "retained")
      h.prepare()
      t.assert_eq(#h.calls, 2, "failed frozen input stays original for the same metadata")
    end)
  end)

  t.it("retries an input change only on demand after thirty seconds and shares the pending attempt", function()
    fixture(function(h)
      h.prepare(); h.describe(); h.validate()
      local old_watch = h.watches[1]
      old_watch.callback(nil, "input.h", { action = 3, change = true }); h.flush()
      for _, now in ipairs({ 0, 29999 }) do
        h.now = now; h.prepare()
        t.assert_eq(#h.calls, 2, "early demand must retain original commands without helpers")
        t.assert_true(vim.deep_equal(runtime.command(h.command), h.command))
      end
      h.now = 30000; h.flush()
      t.assert_eq(#h.calls, 2, "elapsed time alone must not start recovery")
      local delivered = #h.roots
      h.prepare(); h.prepare()
      t.assert_eq(#h.calls, 3, "simultaneous demand must share one fresh descriptor")
      t.assert_eq(h.calls[3].mode, "describe")
      t.assert_eq(#h.roots, delivered, "retry waiters must not be released before fresh validation")
      t.assert_true(vim.deep_equal(runtime.command(h.command), h.command))
      h.describe()
      t.assert_eq(#h.calls, 4); t.assert_eq(h.calls[4].mode, "validate")
      old_watch.callback(nil, "late-old-event.h", {}); h.flush()
      t.assert_true(vim.deep_equal(runtime.command(h.command), h.command), "descriptor alone grants no authority")
      h.validate()
      t.assert_eq(#h.roots, delivered + 2)
      t.assert_contains(runtime.command(h.command)[3], "/verified")
      h.now = 90000; h.prepare()
      t.assert_eq(#h.calls, 4, "ready reuse must not start another recovery")
      t.assert_eq(#h.restarts, 1, "demand-driven recovery must not itself restart a client")
    end)
  end)

  t.it("rejects late retry validation when another input event restarts the failure cooldown", function()
    fixture(function(h)
      h.prepare(); h.describe(); h.validate()
      h.watches[1].callback(nil, "first.h", {}); h.flush()
      local old_count = #h.watches
      h.now = 30000; h.prepare()
      t.assert_eq(#h.calls, 3)
      h.describe()
      t.assert_eq(#h.calls, 4)
      h.now = 30010
      h.watches[old_count + 1].callback(nil, "changed-during-retry.h", {})
      h.calls[4].callback(h.result()); h.flush()
      t.assert_true(vim.deep_equal(runtime.command(h.command), h.command), "stale retry validation cannot reactivate")
      h.now = 60009; h.prepare()
      t.assert_eq(#h.calls, 4, "retry cooldown must start at the latest failure")
      h.now = 60010; h.prepare()
      t.assert_eq(#h.calls, 5); t.assert_eq(h.calls[5].mode, "describe")
    end)
  end)

  t.it("waits for cancelled helper exit and never lets duplicate old completion settle newer work", function()
    fixture(function(h)
      h.prepare(); h.describe()
      local old_validate = h.calls[2].callback
      h.watches[1].callback(nil, "changed-during-validation.h", {}); h.flush()
      h.now = 30000; h.prepare()
      t.assert_eq(#h.calls, 2, "cancellation is not evidence that the old validation helper exited")
      t.assert_true(vim.deep_equal(runtime.command(h.command), h.command))
      old_validate(h.result()); h.flush()
      t.assert_true(vim.deep_equal(runtime.command(h.command), h.command), "old success cannot reactivate failed authority")
      local previous_watches = #h.watches
      h.prepare(); t.assert_eq(#h.calls, 3)
      h.describe(); t.assert_eq(#h.calls, 4)
      local retry_validate = h.calls[4].callback
      old_validate(h.result()); h.flush()
      h.watches[previous_watches + 1].callback(nil, "changed-during-retry.h", {}); h.flush()
      h.now = 60000; h.prepare()
      t.assert_eq(#h.calls, 4, "duplicate old completion must not decrement the newer pending helper")
      retry_validate(h.result()); h.flush()
      t.assert_true(vim.deep_equal(runtime.command(h.command), h.command))
      h.prepare(); t.assert_eq(#h.calls, 5)
      h.describe(); h.validate()
      t.assert_eq(#h.calls, 6)
      t.assert_contains(runtime.command(h.command)[3], "/verified")
      old_validate(h.result()); retry_validate(h.result()); h.flush()
      h.prepare()
      t.assert_eq(#h.calls, 6, "late duplicate completions must not create work or alter ready reuse")
      t.assert_contains(runtime.command(h.command)[3], "/verified")
    end)
  end)

  t.it("keeps watch errors and rejected retry proofs sticky after further demand", function()
    for _, failure in ipairs({ "watch-error", "validation" }) do
      fixture(function(h)
        h.prepare(); h.describe(); h.validate()
        h.watches[1].callback(failure == "watch-error" and "lost notifications" or nil, "input.h", {})
        h.flush()
        local expected = 2
        if failure == "validation" then
          h.now = 30000; h.prepare(); t.assert_eq(#h.calls, 3)
          h.describe(); t.assert_eq(#h.calls, 4)
          h.calls[4].callback(h.result({ ok = false, reason = "dependency-bytes-changed" })); h.flush()
          expected = 4
        end
        h.now = 90000; h.prepare(); h.prepare()
        t.assert_eq(#h.calls, expected, "non-input failures must not become an automatic retry policy")
        t.assert_true(vim.deep_equal(runtime.command(h.command), h.command))
      end)
    end
  end)

  t.it("refuses same-metadata recovery across generation, query profile or compiler environment changes", function()
    for _, changed in ipairs({ "generation", "profile", "environment" }) do
      fixture(function(h, root)
        h.config = { cmd_cwd = root, cmd_env = { CPATH = "certified-include" } }
        vim.list_extend(h.command, { "--enable-config=false", "--query-driver=clang*" })
        h.descriptor.server_profile = runtime.server_profile(h.command, h.config)
        h.descriptor.compiler_environment = { CPATH = "certified-include" }
        h.prepare(); h.describe(); h.validate()
        h.watches[1].callback(nil, "input.h", {}); h.flush()
        if changed == "generation" then h.generation = "gen-b"
        elseif changed == "profile" then h.command[#h.command] = "--query-driver=other*"
        else h.config.cmd_env.CPATH = "different-include" end
        h.now = 30000; h.prepare()
        h.now = 90000; h.prepare()
        t.assert_eq(#h.calls, 2, "recovery must retain its original certificate boundary: " .. changed)
        t.assert_true(vim.deep_equal(runtime.command(h.command, h.config), h.command))
      end)
    end
  end)

  t.it("does not attach a late frozen client from an earlier attempt to the fresh guard", function()
    fixture(function(h)
      h.prepare(); h.describe(); h.validate()
      local old_config = {}
      runtime.configure_process(runtime.command(h.command), old_config)
      t.assert_true(old_config._ue_batch_attempt ~= nil, "frozen process configuration must bind its activation attempt")
      h.watches[1].callback(nil, "input.h", {}); h.flush()
      h.now = 30000; h.prepare(); t.assert_eq(#h.calls, 3)
      h.describe(); h.validate()
      local fresh_config = {}
      runtime.configure_process(runtime.command(h.command), fresh_config)
      t.assert_true(fresh_config._ue_batch_attempt ~= nil and fresh_config._ue_batch_attempt ~= old_config._ue_batch_attempt)
      local function client(id, config)
        return { id = id, config = config, attached_buffers = {}, request = function() return true, 1 end,
          cancel_request = function() end, stop = function() end }
      end
      local fresh = client(702, fresh_config)
      runtime.attach(fresh, 0)
      t.assert_eq(fresh._ue_batch_guard.guard:status().state, "ready")
      local late = client(701, old_config)
      runtime.attach(late, 0); h.flush()
      t.assert_true(not late._ue_batch_guard or late._ue_batch_guard.guard ~= fresh._ue_batch_guard.guard,
        "same publication stamp must not let a previous attempt join the new guard")
      if late._ue_batch_guard then t.assert_false(late._ue_batch_guard.guard:status().state == "ready") end
      t.assert_eq(fresh._ue_batch_guard.guard:status().state, "ready", "late stale clients must not revoke fresh clients")
      t.assert_contains(runtime.command(h.command)[3], "/verified")
    end)
  end)

  t.it("logs the first native invalidation once and still falls back if logging fails", function()
    local log = require("utils.log")
    local original = log.warn_ctx
    local ok, err = xpcall(function()
      for _, broken in ipairs({ false, true }) do
        fixture(function(h, root)
          local captured = {}
          log.warn_ctx = function(scope, message, context)
            captured[#captured + 1] = { scope = scope, message = message, context = context }
            if broken then error("logging unavailable") end
          end
          h.prepare(); h.describe(); h.validate()
          h.watches[1].callback(nil, "first.h", { action = 3, change = true, directory = false })
          h.watches[1].callback(nil, "later.h", { rename = true })
          h.flush()
          t.assert_eq(#captured, 1)
          t.assert_eq(captured[1].scope, "ue.index")
          t.assert_eq(captured[1].context.watch_event.root, root .. "/input")
          t.assert_eq(captured[1].context.watch_event.filename, "first.h")
          t.assert_eq(captured[1].context.watch_event.action, 3)
          t.assert_eq(#h.restarts, 1, "logging failure must not suppress protective fallback")
          t.assert_true(vim.deep_equal(runtime.command(h.command), h.command))
        end)
      end
    end, debug.traceback)
    log.warn_ctx = original
    if not ok then error(err) end
  end)

  t.it("rejects validation that finishes after an event or changed publication metadata", function()
    fixture(function(h)
      h.prepare(); h.describe()
      h.watches[1].callback(nil, "new-header.h", {})
      h.validate()
      t.assert_true(vim.deep_equal(runtime.command(h.command), h.command))
      t.assert_eq(#h.roots, 1)
      h.stamp = "metadata-v2"
      h.prepare(); h.describe()
      h.stamp = "metadata-v3"
      h.validate()
      t.assert_true(vim.deep_equal(runtime.command(h.command), h.command))
      t.assert_eq(#h.roots, 2)
    end)
  end)

  for _, stage in ipairs({ "descriptor", "validation", "ready", "repeat-start" }) do
    t.it("rejects a generation change at " .. stage .. " even with unchanged publication metadata", function()
      fixture(function(h)
        if stage == "descriptor" then h.descriptor.generation_id = "old-generation" end
        h.prepare(); h.describe()
        if stage == "validation" then
          h.calls[2].callback({ ok = true, info_sha256 = "sha-v1", generation_id = "old-generation",
            compiler_environment = {} })
          h.flush()
        elseif stage == "ready" then
          h.calls[2].callback(h.result())
          h.generation = "gen-b"
          h.flush()
        elseif stage == "repeat-start" then
          h.validate()
          t.assert_contains(runtime.command(h.command)[3], "/verified")
          h.generation = "gen-b"
          h.prepare()
          h.flush()
        end
        t.assert_true(vim.deep_equal(runtime.command(h.command), h.command))
      end)
    end)
  end

  t.it("compares effective compiler environment overrides and preserves caller changes on reused configs", function()
    fixture(function(h)
      h.descriptor.compiler_environment = { CPATH = "proof-include-path" }
      h.config.cmd_env = { CPATH = "proof-include-path" }
      h.prepare(); h.describe(); h.validate()
      local config = { cmd_env = { CPATH = "proof-include-path", UNRELATED = "keep" } }
      local frozen = runtime.configure_process(runtime.command(h.command), config)
      t.assert_contains(frozen[3], "/verified")
      t.assert_eq(config.cmd_env.CPATH, "proof-include-path")
      config.cmd_env.CPATH = "different-include-path"
      local original = runtime.configure_process(frozen, config)
      t.assert_eq(original[3], h.command[3])
      t.assert_eq(config.cmd_env.CPATH, "different-include-path", "caller overrides must not be erased while restoring owned cache env")
      t.assert_eq(config.cmd_env.UNRELATED, "keep")
      t.assert_nil(config.cmd_env.LOCALAPPDATA)
      h.flush()
    end)
  end)

  t.it("activates only an explicitly requested and newly certified query profile with its effective environment", function()
    fixture(function(h, root)
      h.config = { cmd_cwd = root, cmd_env = { CPATH = "caller-include", KEEP = "caller" } }
      vim.list_extend(h.command, { "--enable-config=false", "--query-driver=" .. root .. "/clang*" })
      local profile, reason = runtime.server_profile(h.command, h.config)
      t.assert_nil(reason)
      t.assert_eq(profile.launch_cwd, vim.fs.normalize(assert(vim.uv.fs_realpath(root))))
      h.descriptor.server_profile = profile
      h.descriptor.compiler_environment = { CPATH = "caller-include" }
      h.prepare()
      t.assert_true(vim.deep_equal(h.calls[1].request.server_profile, profile))
      t.assert_eq(h.calls[1].request.environment.CPATH, "caller-include")
      t.assert_eq(h.calls[1].request.environment.KEEP, "caller")
      t.assert_eq(h.calls[1].request.launch_cwd, profile.launch_cwd)
      t.assert_true(vim.deep_equal(runtime.command(h.command, h.config), h.command))
      h.describe(); h.validate()
      t.assert_true(vim.deep_equal(h.calls[2].request, h.calls[1].request))
      local config = vim.deepcopy(h.config)
      local frozen = runtime.configure_process(runtime.command(h.command, config), config)
      t.assert_contains(frozen[3], "/verified")
      t.assert_eq(frozen[#frozen], h.command[#h.command], "preserve the user query allowlist")
      t.assert_eq(config.cmd_env.KEEP, "caller")
      t.assert_eq(config.cmd_env.CPATH, "caller-include")
      t.assert_true(vim.deep_equal(config._ue_batch_server_profile, profile))
      t.assert_eq(config._ue_batch_launch_cwd, profile.launch_cwd)
      t.assert_nil(config._ue_batch_disabled_reason)
    end)
  end)

  t.it("does not let persisted no-query metadata authorize a supported but uncertified query profile", function()
    fixture(function(h)
      vim.list_extend(h.command, { "--enable-config=false", "--query-driver=clang*" })
      h.prepare(); h.describe()
      t.assert_eq(#h.calls, 1, "mismatched descriptor must never launch expensive validation")
      t.assert_eq(#h.roots, 1)
      t.assert_true(vim.deep_equal(runtime.command(h.command), h.command))
    end)
  end)

  for _, mutation in ipairs({ "query", "cwd", "environment", "unknown-option", "enabled-config" }) do
    t.it("retains original commands after a certified profile changes " .. mutation, function()
      fixture(function(h, root)
        h.config = { cmd_cwd = root, cmd_env = { CPATH = "proof-include" } }
        vim.list_extend(h.command, { "--enable-config=false", "--query-driver=clang*" })
        h.descriptor.server_profile = runtime.server_profile(h.command, h.config)
        h.descriptor.compiler_environment = { CPATH = "proof-include" }
        h.prepare(); h.describe(); h.validate()
        local config, changed = vim.deepcopy(h.config), vim.deepcopy(h.command)
        local frozen = runtime.command(changed, config)
        t.assert_contains(frozen[3], "/verified")
        if mutation == "query" then
          changed[#changed], frozen[#frozen] = "--query-driver=other*", "--query-driver=other*"
        elseif mutation == "cwd" then
          vim.fn.mkdir(root .. "/other", "p")
          config.cmd_cwd = root .. "/other"
        elseif mutation == "environment" then config.cmd_env.CPATH = "different"
        elseif mutation == "unknown-option" then
          changed[#changed + 1], frozen[#frozen + 1] = "--experimental-semantic-option", "--experimental-semantic-option"
        else
          changed[#changed + 1], frozen[#frozen + 1] = "--enable-config=true", "--enable-config=true"
        end
        t.assert_true(vim.deep_equal(runtime.command(changed, config), changed))
        local original = runtime.configure_process(frozen, config)
        t.assert_true(vim.deep_equal(original, changed), "only frozen CDB selection may be reverted")
        t.assert_nil(config._ue_batch_scope)
        t.assert_eq(config.cmd_env.CPATH, mutation == "environment" and "different" or "proof-include")
      end)
    end)
  end

  for _, mutation in ipairs({ "cwd", "environment", "query" }) do
    t.it("rejects asynchronous validation if the requested " .. mutation .. " changes", function()
      fixture(function(h, root)
        h.config = { cmd_cwd = root, cmd_env = { CPATH = "proof-include" } }
        vim.list_extend(h.command, { "--enable-config=false", "--query-driver=clang*" })
        h.descriptor.server_profile = runtime.server_profile(h.command, h.config)
        h.descriptor.compiler_environment = { CPATH = "proof-include" }
        h.prepare(); h.describe()
        if mutation == "cwd" then
          vim.fn.mkdir(root .. "/other", "p")
          h.config.cmd_cwd = root .. "/other"
        elseif mutation == "environment" then h.config.cmd_env.CPATH = "changed-after-describe"
        else h.command[#h.command] = "--query-driver=other*" end
        h.validate()
        t.assert_eq(#h.roots, 1)
        t.assert_true(vim.deep_equal(runtime.command(h.command, h.config), h.command))
      end)
    end)
  end

  t.it("rejects a validation response for a different profile after a matching descriptor", function()
    fixture(function(h)
      vim.list_extend(h.command, { "--enable-config=false", "--query-driver=clang*" })
      h.descriptor.server_profile = runtime.server_profile(h.command, h.config)
      h.prepare(); h.describe()
      h.calls[2].callback(h.result({ server_profile = vim.NIL }))
      h.flush()
      t.assert_true(vim.deep_equal(runtime.command(h.command), h.command))
      t.assert_eq(#h.roots, 1)
    end)
  end)

  t.it("merges effective environment case-insensitively on Windows and honors explicit unset values", function()
    local env = runtime.process_environment({ cmd_env = { Path = "caller-path", CPATH = vim.NIL } })
    t.assert_nil(env.CPATH)
    if vim.fn.has("win32") == 1 then t.assert_eq(env.PATH, "caller-path"); t.assert_nil(env.Path)
    else t.assert_eq(env.Path, "caller-path") end
  end)

  t.it("rejects duplicate Windows environment spellings before proof and when selecting a ready batch", function()
    if vim.fn.has("win32") ~= 1 then t.skip("Windows environment aliases", "Windows host required"); return end
    for _, entries in ipairs({ { CPATH = "UPPER", cpath = "lower" },
        { Path = "same", PATH = "same" } }) do
      fixture(function(h)
        local config = { cmd_env = vim.deepcopy(entries) }
        local profile, reason = runtime.server_profile(h.command, config)
        t.assert_nil(profile)
        t.assert_eq(reason, "ambiguous-clangd-environment-key")
        h.config = config
        h.prepare()
        t.assert_eq(#h.calls, 0, "ambiguous overrides must not launch a helper")
        h.config = {}
        h.prepare(); h.describe(); h.validate()
        local frozen = runtime.command(h.command)
        t.assert_contains(frozen[3], "/verified")
        local original = runtime.configure_process(frozen, config)
        t.assert_true(vim.deep_equal(original, h.command))
        t.assert_true(vim.deep_equal(config.cmd_env, entries), "fallback keeps the original caller environment")
        t.assert_nil(config._ue_batch_spawn_env)
      end)
    end
  end)

  t.it("passes a case-normalized frozen override through real RPC spawning and unsets helper variables with clear_env", function()
    if vim.fn.has("win32") ~= 1 then t.skip("Windows environment spelling", "Windows host required"); return end
    local python = vim.fn.exepath("python")
    if python == "" then t.skip("environment subprocess", "Python unavailable", { native = true }); return end
    fixture(function(h, root)
      h.config.cmd_env = { Path = "caller-path-for-probe" }
      h.descriptor.compiler_environment = { PATH = "caller-path-for-probe" }
      h.prepare(); h.describe(); h.validate()
      local config = vim.deepcopy(h.config)
      runtime.configure_process(runtime.command(h.command), config)
      local aliases = 0
      for name in pairs(config._ue_batch_spawn_env) do if name:upper() == "PATH" then aliases = aliases + 1 end end
      t.assert_eq(aliases, 1)
      t.assert_eq(config.cmd_env.Path, "caller-path-for-probe", "caller spelling remains intact")
      local out = root .. "/rpc-environment.json"
      local script = "import json,os,sys; open(sys.argv[1],'w').write(json.dumps({'path':os.environ.get('PATH')}))"
      local exited = false
      local rpc = vim.lsp.rpc.start({ python, "-c", script, out }, { on_exit = function() exited = true end },
        { cwd = root, env = config._ue_batch_spawn_env })
      local finished = vim.wait(5000, function() return exited end, 10)
      if not finished then rpc.terminate() end
      t.assert_true(finished)
      local observed = vim.json.decode(table.concat(vim.fn.readfile(out), "\n"))
      t.assert_eq(observed.path, "caller-path-for-probe")
      local before = vim.env.UE_BATCH_UNSET_TEST
      vim.env.UE_BATCH_UNSET_TEST = "inherited-probe"
      local ok, err = xpcall(function()
        local process = vim.system({ python, "-c", "import os; print('absent' if 'UE_BATCH_UNSET_TEST' not in os.environ else 'present')" },
          { text = true, clear_env = true, env = runtime.process_environment({ cmd_env = { UE_BATCH_UNSET_TEST = vim.NIL } }) }):wait()
        t.assert_eq(process.code, 0, process.stderr)
        t.assert_eq(vim.trim(process.stdout), "absent")
        local profile, reason = runtime.server_profile(h.command, { cmd_env = { UE_BATCH_UNSET_TEST = vim.NIL } })
        t.assert_nil(profile)
        t.assert_eq(reason, "unsupported-clangd-environment")
      end, debug.traceback)
      vim.env.UE_BATCH_UNSET_TEST = before
      if not ok then error(err) end
    end)
  end)

  t.it("rejects a junction launch cwd rather than proving a different physical directory", function()
    fixture(function(h, root)
      vim.fn.mkdir(root .. "/physical", "p")
      local link = root .. "/alias"
      local created, reason = vim.uv.fs_symlink(root .. "/physical", link,
        { dir = true, junction = vim.fn.has("win32") == 1 })
      if not created then t.skip("launch cwd alias capability", reason); return end
      local ok, err = xpcall(function()
        vim.list_extend(h.command, { "--enable-config=false", "--query-driver=clang*" })
        local profile, rejected = runtime.server_profile(h.command, { cmd_cwd = link })
        t.assert_nil(profile)
        t.assert_eq(rejected, "unsupported-clangd-launch-cwd-alias")
      end, debug.traceback)
      assert(vim.uv.fs_unlink(link))
      if not ok then error(err) end
    end)
  end)

  t.it("pins the certified native clangd when an unchanged PATH gains a different real executable", function()
    if not require("utils.platform").is_windows then t.skip("Windows executable search", "Windows host required"); return end
    local native = require("utils.ue_goto.semantic_sidecar_libclang").discover_toolchain()
    if not native.ok then t.skip("native clangd executable pin", native.reason, { native = true }); return end
    fixture(function(h, root)
      local shadow = root .. "/lookup"
      vim.fn.mkdir(shadow, "p")
      h.command[1] = "clangd.exe"
      h.descriptor.tool_path = native.clangd_path
      local search = shadow .. ";" .. vim.env.PATH
      h.config.cmd_env = { Path = search }
      h.descriptor.compiler_environment = { PATH = search }
      h.prepare(); h.describe(); h.validate()
      local compiler = vim.fs.dirname(native.clangd_path) .. "/clang++.exe"
      local copied, reason = vim.uv.fs_copyfile(compiler, shadow .. "/clangd.exe")
      if not copied then t.skip("native executable copy", reason, { native = true }); return end
      local config = vim.deepcopy(h.config)
      local frozen = runtime.configure_process(runtime.command(h.command), config)
      t.assert_eq(frozen[1], native.clangd_path)
      local pinned = vim.system({ frozen[1], "--version" }, { text = true, env = config._ue_batch_spawn_env }):wait()
      local changed = vim.system({ shadow .. "/clangd.exe", "--version" }, { text = true }):wait()
      t.assert_eq(pinned.code, 0, pinned.stderr)
      t.assert_contains(pinned.stdout, "clangd version")
      t.assert_eq(changed.code, 0, changed.stderr)
      t.assert_contains(changed.stdout, "clang version")
      t.assert_eq(runtime.configure_process(frozen, config)[1], native.clangd_path, "repeat configuration retains the pin")
      h.watches[1].callback(nil, "changed.h", { change = true })
      local original = runtime.configure_process(frozen, config)
      t.assert_true(vim.deep_equal(original, h.command), "fallback restores the exact caller executable token")
    end)
  end)

  t.it("accepts real Windows drive roots and installs direct watches using absolute root paths", function()
    if not require("utils.platform").is_windows then t.skip("Windows drive root watches", "Windows host required"); return end
    fixture(function(h, root)
      local drive = assert(root:match("^(%a:)/")) .. "\\"
      h.descriptor.lookup_roots = { drive }
      h.descriptor.watched_files[#h.descriptor.watched_files + 1] = drive
      h.descriptor.watch_roots = { root }
      h.opts.probe_direct, h.opts.probe_recursive, h.opts.schedule = nil, nil, nil
      local observed = {}
      h.opts.watch_factory = function(path, callback, options)
        observed[#observed + 1] = { path = path, recursive = options.recursive }
        local handle = assert(vim.uv.new_fs_event())
        assert(handle:start(path, options, callback))
        return handle, { recursive = options.recursive, direct = not options.recursive }
      end
      h.prepare(); h.describe()
      t.assert_true(vim.wait(3000, function() return #h.calls == 2 or #h.roots == 1 end, 10))
      t.assert_eq(#h.calls, 2, "drive root descriptor must reach validation after real host probes")
      h.validate()
      t.assert_true(vim.wait(1000, function() return #h.roots == 1 end, 10))
      t.assert_contains(runtime.command(h.command)[3], "/verified")
      local found = false
      for _, watch in ipairs(observed) do
        if not watch.recursive then
          found = true
          t.assert_eq(watch.path, drive:sub(1, 2) .. "/", "uv must receive C:/ rather than drive-relative C:")
        end
      end
      t.assert_true(found)
    end)
  end)

  t.it("uses independently proven direct watches for lookup entries and revokes on ancestor changes", function()
    fixture(function(h, root)
      h.descriptor.lookup_roots = { root .. "/lookup", root }
      h.descriptor.watched_files[#h.descriptor.watched_files + 1] = root .. "/lookup/clang++"
      h.descriptor.watched_files[#h.descriptor.watched_files + 1] = root .. "/lookup"
      h.opts.probe_direct = function(callback) callback(true) end
      h.prepare(); h.describe(); h.validate()
      local parent, direct
      for _, watch in ipairs(h.watches) do
        if watch.root == root then parent = watch end
        if watch.root == root .. "/lookup" then direct = watch end
      end
      t.assert_false(parent.recursive)
      t.assert_false(direct.recursive)
      direct.callback(nil, "unrelated.txt", { change = true })
      t.assert_contains(runtime.command(h.command)[3], "/verified")
      parent.callback(nil, "lookup", { rename = true })
      t.assert_true(vim.deep_equal(runtime.command(h.command), h.command))
    end)
  end)

  t.it("rejects changed watch coverage after describe and ignores only set ordering", function()
    for _, field in ipairs({ "watch_roots", "lookup_roots", "watched_files", "input_roots", "exclude_roots" }) do
      fixture(function(h, root)
        h.descriptor.lookup_roots = { root .. "/lookup" }
        h.opts.probe_direct = function(callback) callback(true) end
        h.prepare(); h.describe()
        local changed = h.result()
        changed[field][#changed[field] + 1] = root .. "/lookup/newly-created"
        h.calls[2].callback(changed); h.flush()
        t.assert_true(vim.deep_equal(runtime.command(h.command), h.command), field .. " changed after watch installation")
      end)
    end
    fixture(function(h)
      h.prepare(); h.describe()
      local reordered = h.result()
      reordered.watch_roots = { reordered.watch_roots[2], reordered.watch_roots[1] }
      h.calls[2].callback(reordered); h.flush()
      t.assert_contains(runtime.command(h.command)[3], "/verified")
    end)
  end)

  t.it("retains original UBT when direct lookup event capability is unavailable", function()
    fixture(function(h, root)
      h.descriptor.lookup_roots = { root .. "/lookup" }
      h.opts.probe_direct = function(callback) callback(false) end
      h.prepare(); h.describe()
      t.assert_eq(#h.calls, 1)
      t.assert_eq(#h.roots, 1)
      t.assert_true(vim.deep_equal(runtime.command(h.command), h.command))
    end)
  end)

  t.it("the real direct-watch probe covers candidate creation, directory rename and link retarget before validation", function()
    fixture(function(h, root)
      vim.fn.mkdir(root .. "/lookup", "p")
      h.descriptor.lookup_roots = { root .. "/lookup" }
      h.opts.probe_direct = nil
      h.prepare(); h.describe()
      t.assert_true(vim.wait(2500, function() return #h.calls == 2 or #h.roots == 1 end, 10))
      if #h.calls ~= 2 then t.skip("direct watch capability", "host probe did not prove all event types"); return end
      h.validate()
      t.assert_contains(runtime.command(h.command)[3], "/verified")
    end)
  end)

  t.it("real watches ignore workspace cache and unrelated phase logs but revoke on original input changes", function()
    fixture(function(h, root)
      vim.fn.mkdir(root .. "/input", "p")
      vim.fn.mkdir(root .. "/cache", "p")
      vim.fn.mkdir(root .. "/artifacts", "p")
      local source = root .. "/input/original.h"
      vim.fn.writefile({ "before" }, source)
      h.descriptor.watch_roots = { root }
      h.descriptor.exclude_roots = { root .. "/cache" }
      h.opts.probe_recursive, h.opts.watch_factory, h.opts.schedule = nil, nil, nil
      h.prepare(); h.describe()
      t.assert_true(vim.wait(2000, function() return #h.calls == 2 or #h.roots == 1 end, 10))
      if #h.calls == 1 then t.skip("recursive runtime event filtering", "host capability unavailable"); return end
      h.calls[2].callback(h.result())
      t.assert_true(vim.wait(1000, function() return #h.roots == 1 end, 10))
      vim.fn.writefile({ "index shard" }, root .. "/cache/new.idx")
      vim.fn.writefile({ "unrelated phase progress" }, root .. "/artifacts/progress.log")
      vim.wait(100, function() return false end, 10)
      t.assert_contains(runtime.command(h.command)[3], "/verified")
      vim.fn.writefile({ "changed" }, source)
      t.assert_true(vim.wait(1000, function() return #h.restarts > 0 end, 10))
      t.assert_true(vim.deep_equal(runtime.command(h.command), h.command))
    end)
  end)

  t.it("keeps first frozen cache writes from revoking their watched database parent", function()
    fixture(function(h, root)
      local frozen_dir = root .. "/background/verified"
      local cache = frozen_dir .. "/.cache/clangd/index"
      vim.fn.mkdir(frozen_dir, "p")
      vim.fn.mkdir(root .. "/input", "p")
      vim.fn.writefile({ "[]" }, h.descriptor.verified_cdb)
      h.descriptor.watch_roots = { root }
      h.descriptor.watched_files = { h.descriptor.verified_cdb, frozen_dir }
      h.descriptor.exclude_roots = { frozen_dir .. "/.cache", root .. "/frozen-cache" }
      h.opts.probe_recursive, h.opts.watch_factory, h.opts.schedule = nil, nil, nil
      h.prepare(); h.describe()
      t.assert_true(vim.wait(2500, function() return #h.calls == 2 or #h.roots == 1 end, 10))
      if #h.calls == 1 then t.skip("cold frozen cache notifications", "host capability unavailable"); return end
      h.calls[2].callback(h.result())
      t.assert_true(vim.wait(1000, function() return #h.roots == 1 end, 10))
      local cmd = runtime.configure_process(runtime.command(h.command), {})
      t.assert_contains(cmd[3], "/verified")
      -- Exercise the first local-cache creation and shard write that startup
      -- performs. Real parent notifications must not revoke a fresh activation.
      vim.fn.mkdir(cache, "p")
      vim.fn.writefile({ "first shard" }, cache .. "/first.idx")
      vim.wait(150, function() return false end, 10)
      t.assert_contains(runtime.command(h.command)[3], "/verified", "own first cache write revoked activation")
      vim.fn.writefile({ "[{}]" }, h.descriptor.verified_cdb)
      t.assert_true(vim.wait(1000, function() return #h.restarts > 0 end, 10))
      t.assert_true(vim.deep_equal(runtime.command(h.command), h.command), "database writes must still invalidate")
    end)
  end)

  t.it("retains original commands when the owned cache path is blocked or the descriptor points elsewhere", function()
    for _, scenario in ipairs({ "blocked", "foreign" }) do
      fixture(function(h, root)
        local foreign = root .. "/foreign"
        if scenario == "blocked" then
          vim.fn.writefile({ "keep" }, root .. "/background/verified/.cache")
        else
          h.descriptor.verified_cdb = foreign .. "/compile_commands.json"
        end
        h.prepare(); h.describe()
        t.assert_eq(#h.calls, 1, "unavailable cache must fall back before input validation")
        t.assert_true(vim.deep_equal(runtime.command(h.command), h.command))
        t.assert_nil(vim.uv.fs_stat(foreign), "descriptor must not choose a filesystem write target")
        if scenario == "blocked" then
          t.assert_eq(vim.fn.readfile(root .. "/background/verified/.cache")[1], "keep")
        end
      end)
    end
  end)

  t.it("revokes immediately when a watched ancestor of an input root is renamed", function()
    fixture(function(h, root)
      h.descriptor.watch_roots = { root }
      h.descriptor.input_roots = { root .. "/include/subdir" }
      h.prepare(); h.describe(); h.validate()
      t.assert_contains(runtime.command(h.command)[3], "/verified")
      h.watches[1].callback(nil, "include", { rename = true })
      t.assert_true(vim.deep_equal(runtime.command(h.command), h.command),
        "ancestor rename must revoke before the deferred restart callback")
      h.flush()
      t.assert_eq(#h.restarts, 1)
    end)
  end)

  t.it("a real parent directory rename invalidates its nested tracked input root", function()
    fixture(function(h, root)
      vim.fn.mkdir(root .. "/include/subdir", "p")
      vim.fn.writefile({ "int tracked;" }, root .. "/include/subdir/source.h")
      h.descriptor.watch_roots = { root }
      h.descriptor.input_roots = { root .. "/include/subdir" }
      h.opts.probe_recursive, h.opts.watch_factory, h.opts.schedule = nil, nil, nil
      h.prepare(); h.describe()
      t.assert_true(vim.wait(2000, function() return #h.calls == 2 or #h.roots == 1 end, 10))
      if #h.calls == 1 then t.skip("recursive ancestor rename", "host capability unavailable"); return end
      h.calls[2].callback(h.result())
      t.assert_true(vim.wait(1000, function() return #h.roots == 1 end, 10))
      t.assert_contains(runtime.command(h.command)[3], "/verified")
      local fs = require("ue.core.fs")
      local owned = vim.fs.normalize(assert(vim.uv.fs_realpath(root)))
      local source = vim.fs.normalize(assert(vim.uv.fs_realpath(root .. "/include")))
      local target = owned .. "/renamed"
      t.assert_true(fs.path_has_prefix(source, owned) and fs.path_has_prefix(target, owned),
        "directory rename must stay within this fixture's resolved owned root")
      assert(vim.uv.fs_rename(source, target))
      t.assert_true(vim.wait(1000, function() return #h.restarts > 0 end, 10))
      t.assert_true(vim.deep_equal(runtime.command(h.command), h.command))
    end)
  end)

  t.it("missing metadata and failed recursive capability immediately retain the original view", function()
    fixture(function(h)
      h.stamp = nil
      h.prepare()
      t.assert_eq(#h.calls, 0)
      t.assert_eq(#h.roots, 1)
      h.stamp = "metadata-v1"
      h.capable = false
      h.prepare(); h.describe()
      t.assert_eq(#h.calls, 1, "validation must not run without recursive watch proof")
      t.assert_eq(#h.roots, 2)
      h.prepare()
      t.assert_eq(#h.calls, 1, "capability failure must not retry for unchanged metadata")
    end)
  end)

  t.it("the default recursive capability probe observes a real nested event before validation", function()
    fixture(function(h)
      h.opts.probe_recursive = nil
      h.opts.schedule = nil
      h.prepare(); h.describe()
      t.assert_true(vim.wait(2000, function() return #h.calls == 2 or #h.roots == 1 end, 10))
      if #h.calls == 1 then
        t.skip("native recursive watcher", "runtime probe proved recursion unavailable")
        return
      end
      h.calls[2].callback(h.result())
      t.assert_true(vim.wait(1000, function() return #h.roots == 1 end, 10))
      t.assert_contains(runtime.command(h.command)[3], "/verified")
    end)
  end)

  t.it("the real asynchronous CLI rejects malformed publication metadata and releases original startup", function()
    fixture(function(h, root)
      local python = require("utils.platform").resolve_tool({ name = "python", env = { "UE_PYTHON" },
        driver_candidates = function(driver) return driver.python_candidates() end })
      if not python.ok then t.skip("activation CLI capability", python.reason); return end
      vim.fn.mkdir(root .. "/background", "p")
      vim.fn.writefile({ "{}" }, root .. "/background/batches.json")
      h.opts.run_async, h.opts.fingerprint = nil, nil
      h.prepare()
      t.assert_eq(#h.roots, 0, "helper result must arrive asynchronously")
      t.assert_true(vim.wait(10000, function() return #h.roots == 1 end, 10))
      t.assert_true(vim.deep_equal(runtime.command(h.command), h.command))
    end)
  end)

  t.it("only frozen invalidation bypasses restart debounce and respects the supplied scope", function()
    require("ue")
    local index = require("ue.index")
    local saved = index._rt.last_restart_at
    local stopped = 0
    local now = math.max(saved, 100)
    index._rt.last_restart_at = now
    local deps = {
      now = function() return now end,
      get_clients = function() return { { attached_buffers = {}, stop = function() stopped = stopped + 1 end } } end,
      list_bufs = function() return {} end, defer_fn = function(callback) callback() end,
    }
    local ok, err = xpcall(function()
      index.maybe_restart_clangd_for_index(deps)
      t.assert_eq(stopped, 0)
      deps.invalidated_frozen_batch = true
      index.maybe_restart_clangd_for_index(deps)
      t.assert_eq(stopped, 1)
    end, debug.traceback)
    index._rt.last_restart_at = saved
    if not ok then error(err) end
  end)
end)
