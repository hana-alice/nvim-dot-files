local t = require("tests.harness")
t.bootstrap()

-- Exercise the real LspProgress subscription, without a running clangd or real
-- timers. Every fixture restores the process-wide LSP/timer seams on failure.
local function fixture(run)
  local original = {
    defer = vim.defer_fn,
    get_client = vim.lsp.get_client_by_id,
    get_clients = vim.lsp.get_clients,
  }
  local root = vim.fn.tempname():gsub("\\", "/")
  local ctx = { paths = { semantic_cdb = root .. "/compile_commands.json" } }
  local state = { index_selection = { generation_id = "g" } }
  local signatures = { [ctx.paths.semantic_cdb] = "semantic-1", [root .. "/base.json"] = "base-1" }
  local timers, clients = {}, {}
  local M, core = {}, { RT = {}, h = {}, deps = {} }
  core.h.ensure_index_state = function() return state end
  core.h.file_signature = function(path) return signatures[path] end
  core.deps.status_root_key = function() return root end
  core.deps.refresh_statusline = function() end
  core.deps.invalidate_status_cache = function() end
  M.base_compile_commands_path = function() return root .. "/base.json" end
  M.source_refresh_pending = function() return false end
  vim.defer_fn = function(callback, delay)
    timers[#timers + 1] = { callback = callback, delay = delay }
    return { stop = function() end, close = function() end }
  end
  vim.lsp.get_client_by_id = function(id) return clients[id] end
  vim.lsp.get_clients = function(opts)
    local found = {}
    for _, client in pairs(clients) do
      if not opts or not opts.name or client.name == opts.name then found[#found + 1] = client end
    end
    return found
  end
  local f = { m = M, ctx = ctx, state = state, timers = timers, signatures = signatures, root = root }
  function f.client(id, config)
    local client = {
      id = id, name = "clangd", initialized = true,
      config = config or { cmd = { "clangd", "--compile-commands-dir=" .. root } },
      is_stopped = function() return false end,
    }
    clients[id] = client
    return client
  end
  function f.arm(publication, phase)
    M.phase_publication_committed(ctx, { generation_id = "g" }, phase or "current", publication or {
      ordinary = true, original_changed = true, original_append_only = false,
    })
  end
  function f.progress(id, kind, token)
    vim.api.nvim_exec_autocmds("LspProgress", { data = {
      client_id = id,
      params = { token = token or "backgroundIndexProgress", value = { kind = kind } },
    } })
    vim.wait(10, function() return false end, 1)
  end
  function f.flush() vim.wait(10, function() return false end, 1) end
  function f.poll()
    local pending = timers
    timers = {}
    for _, timer in ipairs(pending) do
      if timer.delay <= 1000 then timer.callback() else timers[#timers + 1] = timer end
    end
    f.flush()
  end
  function f.timeout()
    local timeout
    for _, timer in ipairs(timers) do
      if timer.delay >= 179000 and timer.delay <= 180000 then timeout = timer end
    end
    t.assert_true(timeout ~= nil, "必须安装不超过 180 秒的兜底")
    timeout.callback()
    f.flush()
  end
  local ok, err = xpcall(function()
    require("ue.index._phase_barrier")(M, core)
    run(f)
  end, debug.traceback)
  if M.cancel_phase_barriers then M.cancel_phase_barriers() end
  vim.defer_fn = original.defer
  vim.lsp.get_client_by_id = original.get_client
  vim.lsp.get_clients = original.get_clients
  if not ok then error(err) end
end

t.describe("ordinary phase publication completion barrier", function()
  t.it("交付文案区分 CDB 生成、首阶段完成与后续后台索引", function()
    local M = {}
    require("ue.index._delivery")(M, { h = {}, deps = {} })
    local summary = { status = "ready", freshness = "fresh", coverage_level = "full",
      background_index = { phase = "current", status = "cdb-generated", first_stage_complete = false } }
    local verdict, line = M.index_delivery_line(summary)
    t.assert_eq(verdict, "pending", "CDB 文件存在不得冒充后台索引完成")
    t.assert_match(line, "CDB generated")
    summary.background_index.status = "timeout"
    t.assert_eq(M.index_delivery_line(summary), "pending", "超时仅解锁调度，不证明索引完成")
    summary.background_index.status = "indexed"
    summary.background_index.first_stage_complete = true
    t.assert_eq(M.index_delivery_line(summary), "ready")
    summary.background_index.phase = "hot"
    summary.background_index.status = "indexing"
    verdict, line = M.index_delivery_line(summary)
    t.assert_eq(verdict, "pending")
    t.assert_match(line, "first stage indexed")
    summary.status = "running"
    verdict, line = M.index_delivery_line(summary)
    t.assert_eq(verdict, "building")
    t.assert_match(line, "first stage indexed")
  end)

  t.it("CDB 生成并非首阶段完成：等待对应 reader 的 begin/end 后才继续", function()
    fixture(function(f)
      local client = f.client(11)
      f.arm()
      t.assert_eq(f.m.phase_barrier_status(f.ctx).status, "cdb-generated")
      t.assert_false(f.m.phase_barrier_status(f.ctx).first_stage_complete)
      local published = {}
      f.m.wait_phase_publication(f.ctx, function() published[#published + 1] = "full" end)
      f.flush()
      t.assert_eq(#published, 0)
      f.m.phase_reader_loading(f.ctx, client)
      f.progress(11, "begin")
      t.assert_eq(f.m.phase_barrier_status(f.ctx).status, "indexing")
      t.assert_eq(#published, 0)
      f.progress(11, "end")
      t.assert_eq(#published, 1)
      t.assert_eq(published[1], "full")
      t.assert_true(f.m.phase_barrier_status(f.ctx).first_stage_complete)
      t.assert_eq(f.m.phase_barrier_status(f.ctx).status, "indexed")
      f.progress(11, "end")
      t.assert_eq(#published, 1, "重复 end 不得重复发布")
    end)
  end)

  t.it("首次发布后新启动的同根 clangd 可用 begin 绑定并完成", function()
    fixture(function(f)
      f.arm()
      local continued = false
      f.m.wait_phase_publication(f.ctx, function() continued = true end)
      f.client(21)
      f.progress(21, "begin")
      t.assert_false(continued)
      f.progress(21, "end")
      t.assert_true(continued)
      t.assert_true(f.m.phase_barrier_status(f.ctx).first_stage_complete)
    end)
  end)

  t.it("旧 end、其它 token/client、冻结 reader 均不能冒充完成信号", function()
    fixture(function(f)
      local reader = f.client(11)
      f.client(12, { cmd = { "clangd", "--compile-commands-dir=" .. f.root .. "/other" } })
      f.client(13, { cmd = { "clangd", "--compile-commands-dir=" .. f.root }, _ue_batch_scope = f.root })
      f.arm()
      local continued = 0
      f.m.wait_phase_publication(f.ctx, function() continued = continued + 1 end)
      f.m.phase_reader_loading(f.ctx, reader)
      f.progress(11, "end")
      f.progress(11, "begin", "other-progress")
      f.progress(11, "end", "other-progress")
      f.progress(12, "begin")
      f.progress(12, "end")
      f.progress(13, "begin")
      f.progress(13, "end")
      t.assert_eq(continued, 0)
      f.progress(11, "begin")
      f.progress(12, "end")
      t.assert_eq(continued, 0)
      f.progress(11, "end")
      t.assert_eq(continued, 1)
    end)
  end)

  t.it("追加阶段须等 CDB 重读启动，不能消费旧后台索引的 begin/end", function()
    fixture(function(f)
      local reader = f.client(11)
      f.arm({ ordinary = true, original_changed = true, original_append_only = true }, "hot")
      local continued = false
      f.m.wait_phase_publication(f.ctx, function() continued = true end)
      f.progress(11, "begin")
      f.progress(11, "end")
      t.assert_false(continued)
      f.m.phase_reader_loading(f.ctx, reader)
      f.progress(11, "end")
      t.assert_false(continued)
      f.progress(11, "begin")
      f.progress(11, "end")
      t.assert_true(continued)
    end)
  end)

  t.it("current 完成后 hot 重新设屏障，full 仍等 hot 完成且保留首阶段证据", function()
    fixture(function(f)
      local reader = f.client(11)
      f.arm()
      f.progress(11, "begin")
      f.progress(11, "end")
      t.assert_true(f.m.phase_barrier_status(f.ctx).first_stage_complete)
      f.arm({ ordinary = true, original_changed = true, original_append_only = true }, "hot")
      local full_published = false
      f.m.wait_phase_publication(f.ctx, function() full_published = true end)
      f.flush()
      t.assert_false(full_published)
      t.assert_true(f.m.phase_barrier_status(f.ctx).first_stage_complete)
      f.m.phase_reader_loading(f.ctx, reader)
      f.progress(11, "begin")
      t.assert_false(full_published)
      f.progress(11, "end")
      t.assert_true(full_published)
    end)
  end)

  t.it("没有客户端完成信号也在 180 秒兜底继续，且不谎报索引完成", function()
    fixture(function(f)
      f.arm()
      local continued = 0
      f.m.wait_phase_publication(f.ctx, function() continued = continued + 1 end)
      f.timeout()
      t.assert_eq(continued, 1)
      t.assert_eq(f.m.phase_barrier_status(f.ctx).status, "timeout")
      t.assert_false(f.m.phase_barrier_status(f.ctx).first_stage_complete)
    end)
  end)

  t.it("强制 prepare 绕过已有屏障，等待者只释放一次", function()
    fixture(function(f)
      f.arm()
      local continued = 0
      f.m.wait_phase_publication(f.ctx, function() continued = continued + 1 end)
      f.m.bypass_phase_barrier(f.ctx)
      f.flush()
      t.assert_eq(continued, 1)
      t.assert_false(f.m.phase_barrier_status(f.ctx).first_stage_complete)
      f.m.bypass_phase_barrier(f.ctx)
      f.flush()
      t.assert_eq(continued, 1)
    end)
  end)

  t.it("强制 prepare 整轮后续 current/hot/full 都不再建立屏障", function()
    fixture(function(f)
      f.arm()
      f.ctx._bypass_phase_barrier = true
      for _, phase in ipairs({ "current", "hot", "full" }) do
        f.arm({ ordinary = true, original_changed = true, original_append_only = true }, phase)
        local continued = false
        f.m.wait_phase_publication(f.ctx, function() continued = true end)
        f.flush()
        t.assert_true(continued, phase .. " 不得重建 force 已绕过的屏障")
      end
    end)
  end)

  t.it("新会话复用 partial CDB 仍等待当前 reader 的完成", function()
    fixture(function(f)
      f.state.index_selection.coverage_level = "current"
      f.client(11)
      f.arm({ ordinary = true, changed = false, original_changed = false })
      local continued = false
      f.m.wait_phase_publication(f.ctx, function() continued = true end)
      f.flush()
      t.assert_false(continued, "磁盘 CDB 未变不能证明新会话的后台索引已完成")
      f.progress(11, "end")
      t.assert_false(continued, "没有 begin 证据时不能采纳 end")
      f.progress(11, "begin")
      f.progress(11, "end")
      t.assert_true(continued)
    end)
  end)

  t.it("复用 partial CDB 时可采纳 live reader 已存在的 pending background progress", function()
    fixture(function(f)
      f.state.index_selection.coverage_level = "current"
      local reader = f.client(11)
      reader.progress = { pending = { backgroundIndexProgress = "indexing" } }
      f.arm({ ordinary = true, changed = false, original_changed = false })
      local continued = false
      f.m.wait_phase_publication(f.ctx, function() continued = true end)
      f.flush()
      t.assert_false(continued)
      f.progress(11, "end")
      t.assert_true(continued)
      t.assert_true(f.m.phase_barrier_status(f.ctx).first_stage_complete)
    end)
  end)

  t.it("重复 cached noop 保留原来的 180 秒 deadline 与已注册等待者", function()
    fixture(function(f)
      f.arm()
      local original_deadline = f.timers[1]
      local continued = 0
      f.m.wait_phase_publication(f.ctx, function() continued = continued + 1 end)
      f.arm({ ordinary = true, changed = false, original_changed = false })
      local deadline_count = 0
      for _, timer in ipairs(f.timers) do
        if timer.delay >= 179000 then deadline_count = deadline_count + 1 end
      end
      t.assert_eq(deadline_count, 1, "重复 prepare 不得重置或延长 deadline")
      f.flush()
      t.assert_eq(continued, 0)
      original_deadline.callback()
      f.flush()
      t.assert_eq(continued, 1)
      t.assert_eq(f.m.phase_barrier_status(f.ctx).status, "timeout")
    end)
  end)

  t.it("新 generation 的 cached current 不继承旧首阶段完成，须重新等待 begin/end", function()
    fixture(function(f)
      f.client(11)
      f.arm()
      f.progress(11, "begin")
      f.progress(11, "end")
      t.assert_true(f.m.phase_barrier_status(f.ctx).first_stage_complete)
      f.state.index_selection = { generation_id = "g2", coverage_level = "current" }
      local stale = f.m.phase_barrier_status(f.ctx)
      t.assert_false(stale.first_stage_complete, "状态查询不能把上一 generation 的完成证据用于当前 build")
      t.assert_eq(stale.status, "bypassed")
      t.assert_eq(stale.reason, "generation-changed")
      f.m.phase_publication_committed(f.ctx, { generation_id = "g2" }, "current", {
        ordinary = true, changed = false, original_changed = false,
      })
      local fresh = f.m.phase_barrier_status(f.ctx)
      t.assert_false(fresh.first_stage_complete)
      t.assert_eq(fresh.status, "cdb-generated")
      local continued = false
      f.m.wait_phase_publication(f.ctx, function() continued = true end)
      f.progress(11, "end")
      t.assert_false(continued, "旧 end 不能通过新 generation 屏障")
      f.progress(11, "begin")
      f.progress(11, "end")
      t.assert_true(continued)
      t.assert_true(f.m.phase_barrier_status(f.ctx).first_stage_complete)
    end)
  end)

  t.it("待退役旧 reader 的 begin/end 不得证明新 publication 已完成", function()
    fixture(function(f)
      local retired = f.client(11)
      f.client(12)
      f.m.phase_reader_eligible = function(client) return client ~= retired end
      f.arm()
      f.m.phase_reader_loading(f.ctx, retired)
      local continued = false
      f.m.wait_phase_publication(f.ctx, function() continued = true end)
      f.progress(11, "begin")
      f.progress(11, "end")
      t.assert_false(continued)
      f.progress(12, "begin")
      f.progress(12, "end")
      t.assert_true(continued)
    end)
  end)

  t.it("cached noop 不能采纳待退役 reader 的历史 pending progress", function()
    fixture(function(f)
      f.state.index_selection.coverage_level = "current"
      local retired = f.client(11)
      retired.progress = { pending = { backgroundIndexProgress = "indexing" } }
      f.m.phase_reader_eligible = function(client) return client ~= retired end
      f.arm({ ordinary = true, changed = false, original_changed = false })
      local continued = false
      f.m.wait_phase_publication(f.ctx, function() continued = true end)
      f.progress(11, "end")
      t.assert_false(continued)
      f.timeout()
      t.assert_true(continued)
      t.assert_false(f.m.phase_barrier_status(f.ctx).first_stage_complete)
    end)
  end)

  for _, invalidation in ipairs({ "generation", "semantic-cdb", "base-cdb", "source", "stopped", "frozen-client" }) do
    t.it(invalidation .. " 变化释放屏障，不延误重启或命令刷新", function()
      fixture(function(f)
        local reader = f.client(11)
        f.arm()
        f.m.phase_reader_loading(f.ctx, reader)
        f.progress(11, "begin")
        local continued = false
        f.m.wait_phase_publication(f.ctx, function() continued = true end)
        if invalidation == "generation" then f.state.index_selection.generation_id = "g2"
        elseif invalidation == "semantic-cdb" then f.signatures[f.ctx.paths.semantic_cdb] = "semantic-2"
        elseif invalidation == "base-cdb" then f.signatures[f.root .. "/base.json"] = "base-2"
        elseif invalidation == "source" then f.m.source_refresh_pending = function() return true end
        elseif invalidation == "stopped" then reader.is_stopped = function() return true end
        elseif invalidation == "frozen-client" then reader.config._ue_batch_scope = f.root end
        f.poll()
        t.assert_true(continued)
        t.assert_false(f.m.phase_barrier_status(f.ctx).first_stage_complete)
      end)
    end)
  end

  t.it("冻结发布不建屏障且释放普通阶段等待；无变化发布不新增等待", function()
    fixture(function(f)
      f.arm({ ordinary = false, original_changed = true })
      local continued = 0
      f.m.wait_phase_publication(f.ctx, function() continued = continued + 1 end)
      f.flush()
      t.assert_eq(continued, 1)
      f.arm()
      f.m.wait_phase_publication(f.ctx, function() continued = continued + 1 end)
      f.arm({ ordinary = false, original_changed = true })
      f.flush()
      t.assert_eq(continued, 2)
    end)
    fixture(function(f)
      f.state.index_selection.coverage_level = "full"
      f.arm({ ordinary = true, changed = false, original_changed = false })
      local continued = false
      f.m.wait_phase_publication(f.ctx, function() continued = true end)
      f.flush()
      t.assert_true(continued)
    end)
  end)
end)
