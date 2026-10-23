local t = require("tests.harness")
t.bootstrap()

local function fixture(callback)
  local names = { "ue.core.fs", "ue.index.batch_background", "ue.clangd_jobs" }
  local previous = {}
  for _, name in ipairs(names) do previous[name] = package.loaded[name] end
  local stat = vim.uv.fs_stat
  local observed = { stats = 0, directories = {}, calls = {}, restarts = 0, saves = 0 }
  local source = "/residual-fixture/full/compile_commands.json.semantic.json"
  local ctx = { engine_root = "/residual-fixture/engine", project_root = "/residual-fixture/project",
    paths = { index_state = "/residual-fixture/index.json" }, state = {} }
  local request = { enabled = true, background = "/residual-fixture/full/compile_commands.json",
    marker = "/residual-fixture/full/index.json", store = "/residual-fixture/verified_batches",
    python = "python", clangd = "clangd", profile = { query_driver = "driver" },
    env = { PATH = "preserved", PYTHONPATH = "", NVIM_UE_BATCH_TIER = "1" } }
  package.loaded["ue.core.fs"] = { join = function(...) return table.concat({ ... }, "/") end,
    ensure_dir = function(path) observed.directories[#observed.directories + 1] = path end }
  package.loaded["ue.index.batch_background"] = { start = function(spec, opts)
    observed.calls[#observed.calls + 1] = { spec = spec, opts = opts }
    return spec
  end }
  package.loaded["ue.clangd_jobs"] = { resolve = function() return 8 end }
  vim.uv.fs_stat = function(path)
    observed.stats = observed.stats + 1
    if path == source then return { size = 10, mtime = { sec = 1 }, ctime = { sec = 2 } } end
    return stat(path)
  end
  local state = { index_artifacts = {} }
  local M = { base_compile_commands_path = function() return "/residual-fixture/base.json" end,
    maybe_restart_clangd_for_index = function() observed.restarts = observed.restarts + 1 end }
  local core = { h = { file_signature = function() return "base-current" end,
    generation_for_context = function() return { generation_id = observed.stale and "changed" or "current" } end,
    ensure_index_state = function() return state end, normalize_index_state = function() end,
    save_index_state = function() observed.saves = observed.saves + 1 end },
    deps = { invalidate_status_cache = function() end, refresh_statusline = function() end } }
  dofile(vim.fn.getcwd() .. "/lua/ue/index/_batch_background.lua")(M, core)
  local ok, err = xpcall(function() callback(M, ctx, request, observed) end, debug.traceback)
  vim.uv.fs_stat = stat
  for _, name in ipairs(names) do package.loaded[name] = previous[name] end
  if not ok then error(err) end
end

t.describe("显式 residual queue request", function()
  t.it("ordinary requests keep their current mode control and worker policy", function()
    fixture(function(M, ctx, request, observed)
      local spec = M.start_background_batches(ctx, request)
      t.assert_eq(spec.env, request.env)
      t.assert_eq(spec.auto_tier1_large, true)
      t.assert_eq(spec.residual_strict_limit, nil)
      t.assert_eq(spec.control_dir, "/residual-fixture/background-control")
      t.assert_eq(observed.calls[1].opts.max_workers, 2)
    end)
  end)

  t.it("residual requests copy strict child env and isolate control while sharing scope and locks", function()
    fixture(function(M, ctx, request, observed)
      request.residual_strict_limit = 2
      local normalize = require("utils.platform").driver().environment_key
      if normalize("nvim_ue_batch_tier") == normalize("NVIM_UE_BATCH_TIER") then
        request.env.nvim_ue_batch_tier = "1"
      end
      local before, ambient = vim.deepcopy(request), vim.env.NVIM_UE_BATCH_TIER
      local spec = M.start_background_batches(ctx, request)
      t.assert_true(vim.deep_equal(request, before))
      t.assert_eq(vim.env.NVIM_UE_BATCH_TIER, ambient)
      t.assert_true(spec.env ~= request.env)
      t.assert_eq(spec.env.NVIM_UE_BATCH_TIER, "strict")
      t.assert_eq(spec.env.nvim_ue_batch_tier, nil)
      t.assert_eq(spec.env.PATH, "preserved")
      t.assert_eq(spec.env.PYTHONPATH, "")
      t.assert_eq(spec.profile, request.profile)
      t.assert_eq(spec.residual_strict_limit, 2)
      t.assert_false(spec.auto_tier1_large)
      t.assert_eq(observed.calls[1].opts.max_workers, 1)
      t.assert_eq(spec.scope, request.background .. ".semantic.json")
      t.assert_eq(spec.source, spec.scope)
      t.assert_eq(spec.store, request.store)
      t.assert_eq(spec.publish_lock, ctx.paths.index_state .. ".build.lock")
      local control = "/residual-fixture/background-control-strict-residual"
      t.assert_eq(spec.control_dir, control)
      t.assert_eq(spec.plan, control .. "/plan.json")
      t.assert_eq(spec.collect_result, control .. "/collection.json")
      t.assert_eq(spec.publication_request_path, control .. "/activation-request.json")
      t.assert_eq(spec.publication_request.publication_result, control .. "/activation.json")
      spec.publish({ activation = { ok = true, generation_id = "current", manifest = { generation_id = "current" },
        publication = { changed = false } } })
      t.assert_eq(observed.saves, 1)
      t.assert_eq(observed.restarts, 0)
      observed.stale = true
      t.assert_false(pcall(spec.publish, {}))
      t.assert_eq(observed.saves, 1)
    end)
  end)

  t.it("invalid residual limits and missing child env fail before source or directory work", function()
    for _, limit in ipairs({ false, true, "1", 0, 3, 1.5 }) do
      fixture(function(M, ctx, request, observed)
        request.residual_strict_limit = limit
        local value, reason = M.start_background_batches(ctx, request)
        t.assert_eq(value, nil)
        t.assert_eq(reason, "invalid-residual-strict-limit")
        t.assert_eq(observed.stats, 0)
        t.assert_eq(#observed.directories, 0)
        t.assert_eq(#observed.calls, 0)
      end)
    end
    fixture(function(M, ctx, request, observed)
      request.residual_strict_limit, request.env = 1, nil
      local value, reason = M.start_background_batches(ctx, request)
      t.assert_eq(value, nil)
      t.assert_eq(reason, "invalid-residual-strict-environment")
      t.assert_eq(observed.stats, 0)
      t.assert_eq(#observed.calls, 0)
    end)
  end)
end)
