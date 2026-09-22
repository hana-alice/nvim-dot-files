local t = require("tests.harness")
t.bootstrap()

local function fixture()
  local state, scheduled, cleared, marked = { modules = {} }, {}, {}, {}
  local M, core = {}, { RT = {}, h = {}, deps = {} }
  local ctx = { paths = { semantic_cdb = "/project/background/compile_commands.json" } }
  core.deps.status_root_key = function() return "project" end
  core.h.ensure_index_state = function() return state end
  core.h.save_index_state = function() end
  M.mark_module_dirty = function(_, path, reason) marked[#marked + 1] = { path, reason } end
  M.schedule_index_refresh = function(_, opts) scheduled[#scheduled + 1] = opts end
  M.schedule_index_phase = function(_, phase, delay, opts) scheduled[#scheduled + 1] = { phase, delay, opts } end
  M.clear_module_dirty_flags = function(_, keys) cleared[#cleared + 1] = keys end
  require("ue.index._source")(M, core)
  return M, ctx, state, scheduled, cleared, marked, core.RT, core
end

t.describe("source content refresh delivery", function()
  t.it("lost watcher coverage queues a protected full refresh independently of CDB bytes", function()
    local m, ctx, state, scheduled, _, marked = fixture()
    t.assert_true(m.source_observation_unknown(ctx, "overflow"))
    t.assert_eq(state.source_revision, 1)
    t.assert_true(state.root_dirty)
    t.assert_true(m.source_refresh_pending(ctx))
    t.assert_eq(#marked, 0, "unknown paths must not be fabricated as files")
    t.assert_eq(scheduled[1][1], "full")
    t.assert_true(scheduled[1][3].protect)
    local complete
    m.deliver_source_refresh(ctx, {}, { restart = function(_, done) complete = done; return true end })
    t.assert_true(m.source_refresh_pending(ctx))
    complete(true)
    t.assert_false(m.source_refresh_pending(ctx))
  end)

  t.it("a second loss during attachment remains pending after the older acknowledgement", function()
    local m, ctx = fixture()
    m.source_observation_unknown(ctx, "overflow")
    local complete
    m.deliver_source_refresh(ctx, {}, { restart = function(_, done) complete = done; return true end })
    m.source_observation_unknown(ctx, "watcher-exit")
    complete(true)
    t.assert_true(m.source_refresh_pending(ctx))
    m.deliver_source_refresh(ctx, {}, { restart = function(_, done) done(true); return true end })
    t.assert_false(m.source_refresh_pending(ctx))
  end)

  t.it("unchanged prepare/bookkeeping and same bytes do not request a restart", function()
    local m, ctx, state, _, _, marked = fixture()
    m.source_content_changed(ctx, "/project/file.cpp", "hash-a", true)
    t.assert_false(m.source_content_changed(ctx, "/project/file.cpp", "hash-a"))
    state.root_dirty = true -- prepare/bookkeeping is independent of source bytes.
    local starts = 0
    m.deliver_source_refresh(ctx, { "module" }, { restart = function() starts = starts + 1 end })
    t.assert_eq(starts, 0)
    t.assert_eq(#marked, 0)
    t.assert_false(m.source_refresh_pending(ctx))
  end)

  t.it("same-CDB source changes stay pending until an actual refreshed client attaches", function()
    local m, ctx, _, scheduled, cleared = fixture()
    m.source_content_changed(ctx, "/project/file.cpp", "hash-a", true)
    t.assert_true(m.source_content_changed(ctx, "/project/file.cpp", "hash-b"))
    t.assert_eq(#scheduled, 1)
    local complete
    m.deliver_source_refresh(ctx, { "module" }, { restart = function(_, done) complete = done; return true end })
    t.assert_true(m.source_refresh_pending(ctx), "generator success is not refresh delivery")
    t.assert_eq(#cleared, 0)
    complete(true)
    t.assert_false(m.source_refresh_pending(ctx))
    t.assert_eq(#cleared, 1)
    t.assert_eq(cleared[1][1], "module")
  end)

  t.it("debounce and failed restarts preserve pending and use the existing current queue", function()
    local m, ctx, _, scheduled, cleared = fixture()
    m.source_content_changed(ctx, "/project/file.cpp", "hash-a")
    m.deliver_source_refresh(ctx, { "module" }, { restart = function() return false, 1234 end })
    t.assert_true(m.source_refresh_pending(ctx))
    t.assert_eq(scheduled[#scheduled][1], "current")
    t.assert_eq(scheduled[#scheduled][2], 1234)
    local complete
    m.deliver_source_refresh(ctx, { "module" }, { restart = function(_, done) complete = done; return true end })
    complete(false)
    t.assert_true(m.source_refresh_pending(ctx))
    t.assert_eq(#cleared, 0)
    t.assert_eq(scheduled[#scheduled][1], "current")
  end)

  t.it("a source change during restart is not consumed by an older completion", function()
    local m, ctx, _, _, cleared = fixture()
    m.source_content_changed(ctx, "/project/a.cpp", "hash-a")
    local complete
    m.deliver_source_refresh(ctx, { "module" }, { restart = function(_, done) complete = done; return true end })
    m.source_content_changed(ctx, "/project/b.h", "hash-b")
    complete(true)
    t.assert_true(m.source_refresh_pending(ctx))
    t.assert_eq(#cleared, 0)
    m.deliver_source_refresh(ctx, { "module" }, { restart = function(_, done) done(true); return true end })
    t.assert_false(m.source_refresh_pending(ctx))
    t.assert_eq(#cleared, 1)
  end)

  t.it("duplicate source events do not advance pending revisions or create extra restarts", function()
    local m, ctx, state, scheduled = fixture()
    m.source_content_changed(ctx, "/project/a.cpp", "hash-a")
    local revision = state.source_revision
    t.assert_false(m.source_content_changed(ctx, "/project/a.cpp", "hash-a"))
    t.assert_eq(state.source_revision, revision)
    t.assert_eq(#scheduled, 1)
    local starts, complete = 0, nil
    local deps = { restart = function(_, done) starts = starts + 1; complete = done; return true end }
    m.deliver_source_refresh(ctx, {}, deps)
    m.deliver_source_refresh(ctx, {}, deps)
    t.assert_eq(starts, 1)
    complete(true)
    m.deliver_source_refresh(ctx, {}, deps)
    t.assert_eq(starts, 1)
  end)

  t.it("asynchronous file checks ignore identical bytes and deduplicate unreadable events", function()
    local m, ctx, state, _, _, _, rt = fixture()
    local root = vim.fn.tempname():gsub("\\", "/")
    vim.fn.mkdir(root, "p")
    ctx.project_root = root
    local path = root .. "/file.cpp"
    local function checked(baseline)
      m.check_source(ctx, path, baseline)
      t.assert_true(vim.wait(2000, function() return next(rt.source_reads) == nil end, 10))
    end
    local ok, err = xpcall(function()
      vim.fn.writefile({ "int value = 1;" }, path)
      checked(true)
      checked(false)
      t.assert_false(m.source_refresh_pending(ctx))
      vim.fn.writefile({ "int value = 2;" }, path)
      checked(false)
      t.assert_eq(state.source_revision, 1)
      vim.fn.writefile({ "int value = 2;" }, path)
      checked(false)
      t.assert_eq(state.source_revision, 1)
      vim.fn.delete(path)
      checked(false)
      t.assert_eq(state.source_revision, 2)
      checked(false)
      t.assert_eq(state.source_revision, 2)
    end, debug.traceback)
    vim.fn.delete(root, "rf")
    if not ok then error(err) end
  end)

  t.it("a thrown restart keeps the source request queued", function()
    local m, ctx, _, scheduled = fixture()
    m.source_content_changed(ctx, "/project/file.cpp", "hash-a")
    m.deliver_source_refresh(ctx, {}, { restart = function() error("start failed") end })
    t.assert_true(m.source_refresh_pending(ctx))
    t.assert_eq(scheduled[#scheduled][1], "current")
  end)

  t.it("generated artifacts cannot report source changes delivered before attachment", function()
    local m = {}
    require("ue.index._delivery")(m, {})
    local status = m.index_delivery_line({ status = "ready", freshness = "fresh",
      coverage_level = "full", source_refresh_pending = true })
    t.assert_eq(status, "pending")
    status = m.index_delivery_line({ status = "ready", freshness = "fresh", coverage_level = "full" })
    t.assert_eq(status, "ready")
  end)
end)

t.describe("native unchanged-CDB source refresh", function()
  t.it("restarts the owned real clangd and refreshes included source without rewriting commands", function()
    local tool = require("utils.ue_goto.semantic_sidecar_libclang").discover_toolchain()
    if not tool.ok then
      if vim.env.NVIM_TEST_REQUIRE_NATIVE == "1" then error(tool.reason) end
      t.skip("native clangd", tool.reason)
      return
    end
    local m, ctx, _, _, _, _, rt, core = fixture()
    rt.last_restart_at, rt.restart_debounce_s = 0, 45
    core.h.unix_now = os.time
    require("ue.index._clangd")(m, core)
    local root = vim.fn.tempname():gsub("\\", "/") .. "_source_refresh"
    vim.fn.mkdir(root .. "/environment", "p")
    local consumer, impl, wrapper = root .. "/consumer.cpp", root .. "/impl.cpp", root .. "/Module.cpp"
    ctx.project_root, ctx.paths.semantic_cdb = root, root .. "/compile_commands.json"
    vim.fn.writefile({ "int target();", "int consume(){return target();}" }, consumer)
    vim.fn.writefile({ "int target(){return 1;}" }, impl)
    vim.fn.writefile({ '#include "impl.cpp"' }, wrapper)
    local entries = {}
    for _, file in ipairs({ wrapper, consumer }) do
      entries[#entries + 1] = { directory = root, file = file,
        arguments = { "clang++", "-std=c++17", "-nostdinc++", "-c", file } }
    end
    local encoded = vim.json.encode(entries)
    vim.fn.writefile({ encoded }, ctx.paths.semantic_cdb)
    local buffer = vim.fn.bufadd(consumer)
    vim.fn.bufload(buffer)
    vim.bo[buffer].filetype = "cpp"
    local owned, starts = {}, 0
    local config = { name = "clangd", root_dir = root,
      cmd = { tool.clangd_path, "--background-index", "--enable-config=false", "-j=1", "--log=error",
        "--compile-commands-dir=" .. root },
      cmd_env = { LOCALAPPDATA = root .. "/environment", XDG_CACHE_HOME = root .. "/environment" } }
    local function start()
      starts = starts + 1
      local id = vim.lsp.start(vim.deepcopy(config), { bufnr = buffer, reuse_client = function() return false end })
      t.assert_type(id, "number")
      owned[#owned + 1] = id
    end
    local function await_definition(expected)
      local pending, line = false, nil
      return vim.wait(10000, function()
        local client = vim.lsp.get_client_by_id(owned[#owned])
        if not pending and client and client.initialized and not client:is_stopped() then
          pending = true
          client:request("textDocument/definition", {
            textDocument = { uri = vim.uri_from_fname(consumer) }, position = { line = 1, character = 22 },
          }, function(_, locations)
            pending = false
            for _, location in ipairs(locations or {}) do
              if vim.fs.basename(vim.uri_to_fname(location.uri)) == "impl.cpp" then
                line = location.range.start.line
              end
            end
          end, buffer)
        end
        return line == expected
      end, 100)
    end
    local ok, err = xpcall(function()
      start()
      t.assert_true(await_definition(0), "baseline definition missing")
      m.source_content_changed(ctx, impl, "old", true)
      vim.fn.writefile({ "", "", "", "", "", "int target(){return 2;}" }, impl)
      m.source_content_changed(ctx, impl, "new")
      local deps = { restart = function(context, callback)
        return m.restart_source_clangd(context, callback, {
          get_clients = function() return { vim.lsp.get_client_by_id(owned[#owned]) } end,
          start_clangd = start,
        })
      end }
      m.deliver_source_refresh(ctx, {}, deps)
      t.assert_true(m.source_refresh_pending(ctx), "must wait for real LspAttach")
      t.assert_true(vim.wait(10000, function() return not m.source_refresh_pending(ctx) end, 50))
      t.assert_true(await_definition(5), "changed body stayed stale")
      t.assert_eq(starts, 2)
      m.source_content_changed(ctx, impl, "new")
      m.deliver_source_refresh(ctx, {}, deps)
      t.assert_eq(starts, 2, "unchanged bytes must not restart again")
      t.assert_eq(vim.fn.readfile(ctx.paths.semantic_cdb)[1], encoded)
      t.assert_eq(vim.fn.readfile(wrapper)[1], '#include "impl.cpp"')
    end, debug.traceback)
    for _, id in ipairs(owned) do
      local client = vim.lsp.get_client_by_id(id)
      if client then client:stop(true) end
    end
    pcall(vim.api.nvim_buf_delete, buffer, { force = true })
    vim.wait(2000, function()
      for _, id in ipairs(owned) do if vim.lsp.get_client_by_id(id) then return false end end
      return true
    end, 20)
    vim.fn.delete(root, "rf")
    if not ok then error(err) end
  end)
end)

t.describe("scoped source restart acknowledgement", function()
  local function restart_fixture(no_client)
    local m, rt = {}, { last_restart_at = 0, restart_debounce_s = 45 }
    require("ue.index._clangd")(m, { RT = rt, h = { unix_now = function() return 100 end } })
    local stopped, callbacks, deferred, deleted = {}, {}, {}, {}
    local function client(id, root)
      return { id = id, config = { _ue_resolved_cmd = { "clangd", "--compile-commands-dir=" .. root } },
        attached_buffers = {}, stop = function() stopped[#stopped + 1] = id end }
    end
    local clients = { client(1, "/project/background"), client(2, "/foreign/background") }
    local fresh = { [1] = clients[1], [3] = client(3, "/project/background"), [4] = client(4, "/foreign/background") }
    local deps = {
      get_clients = function() return no_client and {} or clients end,
      get_client_by_id = function(id) return fresh[id] end,
      create_autocmd = function(_, opts) callbacks[1] = opts.callback; return 1 end,
      delete_autocmd = function(id) deleted[#deleted + 1] = id end,
      defer_fn = function(fn, delay) deferred[delay] = fn end,
    }
    return m, { paths = { semantic_cdb = "/project/background/compile_commands.json" } }, deps,
      stopped, callbacks, deferred, deleted
  end

  t.it("only stops matching CDB clients and requires a new matching attachment", function()
    local m, ctx, deps, stopped, callbacks, _, deleted = restart_fixture()
    local result
    t.assert_true(m.restart_source_clangd(ctx, function(ok) result = ok end, deps))
    t.assert_eq(#stopped, 1)
    t.assert_eq(stopped[1], 1)
    callbacks[1]({ data = { client_id = 1 } })
    callbacks[1]({ data = { client_id = 4 } })
    t.assert_nil(result)
    callbacks[1]({ data = { client_id = 3 } })
    t.assert_true(result)
    t.assert_eq(#deleted, 1)
  end)

  t.it("no-client state waits for natural attachment without forcing a start", function()
    local m, ctx, deps, stopped, callbacks, deferred = restart_fixture(true)
    local result
    t.assert_true(m.restart_source_clangd(ctx, function(ok) result = ok end, deps))
    t.assert_eq(#stopped, 0)
    t.assert_nil(next(deferred))
    t.assert_nil(result)
    callbacks[1]({ data = { client_id = 3 } })
    t.assert_true(result)
  end)

  t.it("a later CDB override keeps a foreign client outside the restart scope", function()
    for _, override in ipairs({ { "--compile-commands-dir=/foreign/background" },
      { "--compile-commands-dir", "/foreign/background" } }) do
      local m, ctx, deps, stopped, _, deferred = restart_fixture()
      local clients = deps.get_clients()
      vim.list_extend(clients[1].config._ue_resolved_cmd, override)
      m.restart_source_clangd(ctx, function() end, deps)
      t.assert_eq(#stopped, 0)
      t.assert_nil(next(deferred))
    end
  end)

  t.it("attachment timeout reports failure exactly once", function()
    local m, ctx, deps, _, callbacks, deferred = restart_fixture()
    local results = {}
    m.restart_source_clangd(ctx, function(ok) results[#results + 1] = ok end, deps)
    deferred[15000]()
    callbacks[1]({ data = { client_id = 3 } })
    t.assert_eq(#results, 1)
    t.assert_false(results[1])
  end)
end)
