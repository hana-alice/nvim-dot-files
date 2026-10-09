-- Background proof publication uses the existing generation and activation gates.
return function(M, core)
  local fs = require("ue.core.fs")
  local queue = require("ue.index.batch_background")
  local h = core.h

  M.start_background_batches = function(ctx, request)
    if not request or not request.enabled then return end
    local source = request.background .. ".semantic.json"
    local stat = vim.uv.fs_stat(source)
    if not stat then return end
    local base = M.base_compile_commands_path(ctx)
    local base_signature = h.file_signature(base)
    local generation = h.generation_for_context(ctx, { base_cdb_path = base })
    if generation.failed then
      require("utils.log").warn_ctx("ue.index", "background batch digest failed", { reason = generation.digest_error })
      return
    end
    if generation.pending then
      h.generation_for_context_async(ctx, { base_cdb_path = base }, function(value, err)
        if not value then
          require("utils.log").warn_ctx("ue.index", "background batch digest failed", { reason = err })
          return
        end
        M.start_background_batches(ctx, request)
      end)
      return
    end
    local control = fs.join(vim.fs.dirname(request.store), "background-control")
    fs.ensure_dir(control)
    local function current()
      return vim.deep_equal(base_signature, h.file_signature(base))
        and h.generation_for_context(ctx, { base_cdb_path = base }).generation_id == generation.generation_id
    end
    local spec = { scope = source, source = source, signature = { size = stat.size, mtime = stat.mtime, ctime = stat.ctime },
      store = request.store, python = request.python, clangd = request.clangd, profile = request.profile,
      script = fs.join(vim.fn.stdpath("config"), "tools", "cdb_background_batch.py"),
      cwd = ctx.engine_root, env = request.env, control_dir = control,
      plan = fs.join(control, "plan.json"), collect_result = fs.join(control, "collection.json"),
      background = request.background, marker = request.marker,
      publication_request = { schema = 1, ctx = { engine_root = ctx.engine_root, project_root = ctx.project_root,
        paths = ctx.paths, state = ctx.state }, base = base, base_signature = base_signature,
        generation_id = generation.generation_id, source = source, marker = request.marker,
        background = request.background, publication_result = fs.join(control, "activation.json") },
      publication_request_path = fs.join(control, "activation-request.json"), nvim = vim.v.progpath,
      publication_worker = fs.join(vim.fn.stdpath("config"), "lua", "ue", "index", "batch_publish_worker.lua"),
      publish_lock = ctx.paths.index_state .. ".build.lock", current = current,
      publish = function(result)
        if not current() then error("background-proof-generation-changed") end
        local state = h.ensure_index_state(ctx)
        h.normalize_index_state(state)
        local activated = result.activation
        if not activated or not activated.ok or activated.generation_id ~= generation.generation_id
            or not activated.manifest or activated.manifest.generation_id ~= generation.generation_id then
          error("background-proof-publication-failed")
        end
        state.index_artifacts.full, state.index_selection = activated.manifest, activated.index_selection
        local publication = activated.publication
        h.save_index_state(ctx, state)
        core.deps.invalidate_status_cache()
        core.deps.refresh_statusline()
        if type(publication) ~= "table" or publication.changed ~= false then
          M.maybe_restart_clangd_for_index({ context = ctx,
            original_changed = type(publication) == "table" and publication.original_changed or nil })
        end
      end,
    }
    return queue.start(spec, { max_workers = math.min(2, math.max(1, math.floor(require("ue.clangd_jobs").resolve() / 4))) })
  end
end
