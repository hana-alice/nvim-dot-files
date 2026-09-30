-- Prepare owns the live writer lease through raw generation, transformation,
-- partition and commit. Only physical output paths change in the copied ctx.
local M = {}
local fs = require("ue.core.fs")
local locks = require("ue.file_lock")

local function run_helper(config, operation, done)
  local python = require("utils.platform").resolve_tool({ name = "python", env = { "UE_PYTHON" },
    driver_candidates = function(driver) return driver.python_candidates() end })
  if not python.ok then done(false, "Python unavailable for CDB transaction"); return end
  local command = { python.path, "-B", "-I", vim.fn.stdpath("config") .. "/tools/cdb_transaction.py",
    operation, config.config }
  local ok_spawn, handle = pcall(vim.system, command, { text = true }, function(result)
    vim.schedule(function()
      local ok, value = pcall(vim.json.decode, result.stdout or "")
      if not ok or type(value) ~= "table" then value = { reason = result.stderr or "invalid transaction result" } end
      done(result.code == 0 and value.ok == true, value.reason, value)
    end)
  end)
  if not ok_spawn then done(false, tostring(handle)); return end
  pcall(require("utils.task_registry").register, {
    name = "UE CDB transaction " .. operation, group = "ue", kind = "system", handle = handle,
  })
  return handle
end

--- opts.generate(ctx,progress,done) and opts.pipeline are supplied by ue.lua;
--- the transaction remains independent of its facade and testable headlessly.
function M.run(ctx, progress, on_done, opts)
  opts = opts or {}
  if opts._host_admitted ~= true then
    local _, handle, _, control = require("utils.host_admission").run_when_allowed({
      name = "CDB transaction",
      start = function()
        return M.run(ctx, progress, on_done, vim.tbl_extend("force", opts, { _host_admitted = true }))
      end,
      on_error = function(err) on_done(false, tostring(err)) end,
    })
    return handle or control
  end
  local targets = require("ue.cdb.paths").targets(ctx)
  local active = targets[1]
  local lease, err = locks.acquire(active .. ".writer.lock")
  if not lease then on_done(false, "CDB writer is owned by another Neovim: " .. tostring(err)); return end
  local parent = fs.dirname(active)
  -- Do not stage underneath a watched live root: even excluded filenames can
  -- overflow the host watcher and produce an unknown-path invalidation.
  local work = vim.fs.normalize(vim.fn.tempname() .. "-ue-cdb-prepare")
  for _, root in ipairs({ ctx.engine_root, ctx.project_root or parent, parent }) do
    if root and fs.path_has_prefix(work:lower(), vim.fs.normalize(root):lower()) then
      locks.release(lease)
      on_done(false, "CDB staging directory overlaps a live input root: " .. root)
      return
    end
  end
  local config = {
    active = active, targets = targets, work = work,
    stage = fs.join(work, "compile_commands.json"),
    shards = require("ue.cdb.shards").shards_dir(ctx), stage_shards = fs.join(work, "shards"),
    stage_manifest = fs.join(work, "partition.json"), manifest = fs.join(parent, "compile_commands.partition.json"),
    stage_partition = fs.join(work, "partition"), partition_dir = fs.join(parent, ".cache", "nvim-ue", "cdb", "active"),
    stage_pch = fs.join(work, "pch"), pch_dir = fs.join(parent, ".cache", "nvim-ue", "clangd", "pch"),
    config = fs.join(work, "transaction.json"),
  }
  if ctx.paths.semantic_cdb then
    config.semantic_cdb = ctx.paths.semantic_cdb
    config.header_path_case_cache_dir = fs.join(fs.dirname(ctx.paths.semantic_cdb), ".cache", "clangd", "index")
  end
  vim.fn.mkdir(work, "p")
  local file, file_err = io.open(config.config, "wb")
  if not file then locks.release(lease); on_done(false, tostring(file_err)); return end
  file:write(vim.json.encode(config)); file:close()
  local working = vim.deepcopy(ctx)
  working.paths = working.paths or {}
  working.paths.active_cdb, working.paths.cdb_shards_dir = config.stage, config.stage_shards
  local helper = opts.helper or run_helper
  local finished = false
  local function finish(ok, message, result)
    if finished then return end
    finished = true
    local completed = false
    local function complete()
      if completed then return end
      completed = true
      locks.release(lease)
      local migrated = result and result.cache_migration and (result.cache_migration.migrated or 0) > 0
      if ok and result and (result.changed or migrated) then
        local refresh = migrated and vim.tbl_extend("force", result, { changed = true, cdb_changed = result.changed }) or result
        pcall(opts.on_committed or require("ue.cdb.pipeline").committed, refresh, ctx)
      end
      on_done(ok, message or active, result)
    end
    local cleaned = pcall(helper, config, "cleanup", complete)
    if not cleaned then complete() end
  end
  local function invoke(operation, ...)
    local ok, result = pcall(operation, ...)
    if not ok then finish(false, tostring(result)) end
  end
  invoke(helper, config, "prepare", function(ok, message)
    if not ok then finish(false, message); return end
    invoke(opts.generate, working, progress, function(generated, generation_err)
      if not generated then finish(false, generation_err); return end
      invoke(opts.pipeline, config.stage, { config.stage }, function(processed, pipeline_err)
        if not processed then finish(false, pipeline_err); return end
        local partition = opts.partition or require("ue.index").partition_base_cdb_async
        invoke(partition, working, { out_dir = config.stage_partition, manifest = config.stage_manifest }, function(partitioned, partition_err)
          if not partitioned then finish(false, partition_err); return end
          invoke(helper, config, "commit", function(committed, commit_err, result)
            finish(committed, commit_err, result)
          end)
        end)
      end, { defer_restart = true, _host_admitted = true, logical_cdb = active,
        recipes_dir = config.stage_pch, engine_root = ctx.engine_root, project_root = ctx.project_root })
    end)
  end)
  return { stage = config.stage }
end

return M
