local t = require("tests.harness")
t.bootstrap()

local function fixture(run)
  local saved = { defer = vim.defer_fn, get_client = vim.lsp.get_client_by_id, get_clients = vim.lsp.get_clients }
  local root = vim.fn.tempname():gsub("\\", "/")
  local ctx = { paths = { semantic_cdb = root .. "/compile_commands.json" } }
  local state = { index_selection = { generation_id = "race-generation" } }
  local timers = {}
  local client = { id = 8301, name = "clangd", initialized = true,
    config = { cmd = { "clangd", "--compile-commands-dir=" .. root } },
    progress = { pending = {} }, is_stopped = function() return false end }
  local M = { base_compile_commands_path = function() return root .. "/base.json" end }
  local core = { h = { ensure_index_state = function() return state end,
    file_signature = function(path) return path .. ":unchanged" end }, deps = {} }
  vim.defer_fn = function(callback, delay) timers[#timers + 1] = { callback = callback, delay = delay } end
  vim.lsp.get_client_by_id = function(id) if id == client.id then return client end end
  vim.lsp.get_clients = function() return { client } end
  local f = { m = M, ctx = ctx, client = client, state = state }
  function f.arm(phase, append, noop)
    M.phase_publication_committed(ctx, { generation_id = "race-generation" }, phase, {
      ordinary = true, changed = not noop, original_changed = not noop, original_append_only = append == true,
    })
  end
  function f.progress(kind)
    -- Neovim's real handler keeps the title, rather than a boolean/table.
    if kind == "end" then client.progress.pending.backgroundIndexProgress = nil
    else client.progress.pending.backgroundIndexProgress = "indexing" end
    vim.api.nvim_exec_autocmds("LspProgress", { data = { client_id = client.id,
      params = { token = "backgroundIndexProgress", value = { kind = kind } } } })
    vim.wait(5, function() return false end, 1)
  end
  function f.deadlines()
    local count = 0
    for _, timer in ipairs(timers) do if timer.delay == 180000 then count = count + 1 end end
    return count
  end
  function f.timeout()
    for index = #timers, 1, -1 do
      if timers[index].delay == 180000 then timers[index].callback(); return end
    end
    error("missing fixed deadline")
  end
  local ok, err = xpcall(function()
    require("ue.index._phase_barrier")(M, core)
    run(f)
  end, debug.traceback)
  if M.cancel_phase_barriers then M.cancel_phase_barriers() end
  vim.defer_fn, vim.lsp.get_client_by_id, vim.lsp.get_clients = saved.defer, saved.get_client, saved.get_clients
  if not ok then error(err) end
end

t.describe("ordinary phase progress race", function()
  t.it("full 完成后的 hot noop 与重复 prepare 不增加等待期限", function()
    fixture(function(f)
      f.arm("current")
      f.progress("begin")
      f.progress("end")
      f.arm("full", true)
      f.m.phase_reader_loading(f.ctx, f.client)
      f.progress("begin")
      f.progress("end")
      t.assert_eq(f.m.phase_barrier_status(f.ctx).status, "indexed")
      f.state.index_selection.coverage_level = "full"
      local count = f.deadlines()
      f.arm("hot", false, true)
      for _, phase in ipairs({ "current", "hot", "full" }) do f.arm(phase, false, true) end
      t.assert_eq(f.deadlines(), count, "无变化不能重置或新建 180 秒期限")
      t.assert_false(f.m.phase_barrier_pending(f.ctx))
      local status = f.m.phase_barrier_status(f.ctx)
      t.assert_eq(status.status, "indexed")
      t.assert_true(status.first_stage_complete)
    end)
  end)

  t.it("reload 前已开始且仍 pending 的进度不能被 loading 抹掉", function()
    fixture(function(f)
      f.arm("current")
      f.progress("begin")
      f.progress("end")
      f.arm("full", true)
      f.progress("begin")
      t.assert_eq(f.client.progress.pending.backgroundIndexProgress, "indexing")
      f.m.phase_reader_loading(f.ctx, f.client)
      local released = false
      f.m.wait_phase_publication(f.ctx, function() released = true end)
      f.progress("end")
      t.assert_true(released, "正向 pending begin 已存在，end 后不得空等 180 秒")
      t.assert_eq(f.m.phase_barrier_status(f.ctx).status, "indexed")
    end)
  end)

  t.it("前阶段超时后遗留的 pending 不能冒充追加阶段 begin", function()
    fixture(function(f)
      f.arm("current")
      f.progress("begin")
      f.timeout()
      t.assert_eq(f.m.phase_barrier_status(f.ctx).status, "timeout")
      t.assert_eq(f.client.progress.pending.backgroundIndexProgress, "indexing")
      f.arm("full", true)
      f.m.phase_reader_loading(f.ctx, f.client)
      local released = false
      f.m.wait_phase_publication(f.ctx, function() released = true end)
      f.progress("end")
      t.assert_false(released, "超时前旧 begin 不得解锁新阶段")
      t.assert_true(f.m.phase_barrier_pending(f.ctx))
      f.progress("begin")
      f.progress("end")
      t.assert_true(released)
    end)
  end)

  t.it("另一 reader 的 pending 不继承前 reader 的 indexed 证明", function()
    fixture(function(f)
      f.arm("current")
      f.progress("begin")
      f.progress("end")
      f.arm("full", true)
      f.client.id = 8302
      f.client.progress.pending.backgroundIndexProgress = "indexing"
      f.m.phase_reader_loading(f.ctx, f.client)
      local released = false
      f.m.wait_phase_publication(f.ctx, function() released = true end)
      f.progress("end")
      t.assert_false(released, "前 reader 的完成不能消除新 reader 的旧进度歧义")
      f.progress("begin")
      f.progress("end")
      t.assert_true(released)
    end)
  end)

  t.it("发布前已经 pending 的外来进度不能冒充本轮 begin", function()
    fixture(function(f)
      f.arm("current")
      f.progress("begin")
      f.progress("end")
      f.progress("begin")
      f.arm("full", true)
      f.m.phase_reader_loading(f.ctx, f.client)
      local released = false
      f.m.wait_phase_publication(f.ctx, function() released = true end)
      f.progress("end")
      t.assert_false(released, "publication 之前的外来 begin 不得证明本轮完成")
      t.assert_true(f.m.phase_barrier_pending(f.ctx))
      f.progress("begin")
      f.progress("end")
      t.assert_true(released)
    end)
  end)

  t.it("loading 后已观察到 begin 时重复 loading 保留本轮证据", function()
    fixture(function(f)
      f.arm("full", true)
      f.m.phase_reader_loading(f.ctx, f.client)
      f.progress("begin")
      f.m.phase_reader_loading(f.ctx, f.client)
      local released = false
      f.m.wait_phase_publication(f.ctx, function() released = true end)
      f.progress("end")
      t.assert_true(released, "重复 loading 不得清掉已经观察到的 begin")
      t.assert_eq(f.m.phase_barrier_status(f.ctx).status, "indexed")
    end)
  end)

  t.it("reload 时无 pending 且只收到 end 不能冒充完成", function()
    fixture(function(f)
      f.arm("full", true)
      f.m.phase_reader_loading(f.ctx, f.client)
      local released = false
      f.m.wait_phase_publication(f.ctx, function() released = true end)
      f.progress("end")
      t.assert_false(released)
      t.assert_true(f.m.phase_barrier_pending(f.ctx))
      f.progress("begin")
      f.progress("end")
      t.assert_true(released)
    end)
  end)
end)
