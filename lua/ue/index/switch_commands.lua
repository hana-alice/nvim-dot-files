-- Explicit index actions; context and prepare policy belong to the facade.
local M = {}
local running, inventory_running = {}, false

function M.run(deps)
  local ctx = deps.resolve()
  local notify = deps.notify or vim.notify
  if not ctx then notify("No UE context", vim.log.levels.WARN, { title = "UE index" }); return false end
  local scope = deps.scope(ctx)
  if running[scope] then return false end
  running[scope] = true
  local switch = deps.switch or require("ue.index.switch_reindex")
  notify("Switch reindex started (baseline and source coverage check)", vim.log.levels.INFO, { title = "UE index" })
  local finished = false
  local function finish(result)
    if finished then return end
    finished, running[scope] = true, nil
    notify(switch.summary(result), result.ok and vim.log.levels.INFO or vim.log.levels.WARN, { title = "UE index" })
    if deps.completed then deps.completed(result) end
  end
  local function restart(result, fallback)
    local completed = false
    local function attached(ok, reason)
      if completed then return end
      completed = true
      result.fallback = fallback .. (ok and ":attached" or ":attachment-failed")
      if not ok then result.ok = false; result.reason = reason or "reader-attachment-failed" end
      finish(result)
    end
    local ok, started = pcall(deps.restart, ctx, attached)
    if not ok then attached(false, tostring(started))
    elseif not started and not completed then attached(false, "reader-restart-deferred") end
  end
  local helper = vim.tbl_extend("force", deps.helper or {}, { suppress_notify = true })
  local started = switch.before(ctx, scope, function(result)
    if result.ok and not deps.force_reader_refresh and (result.action == "none" or result.action == "baseline") then
      result.fallback = "none"; finish(result); return
    end
    if not result.needs_prepare then restart(result, result.ok and "none" or "reader-refresh"); return end
    local called = false
    local ok, dispatched = pcall(deps.prepare, ctx, function(success, reason)
      if called then return end
      called = true
      if not success then
        result.fallback = "prepare-failed"
        result.reason = (result.reason or "needs-prepare") .. "; " .. tostring(reason or "prepare-failed")
        finish(result)
        return
      end
      local baseline_started = switch.baseline(ctx, scope, function(baseline)
        baseline.fallback = "prepare-completed"
        baseline.changed = result.changed
        baseline.uncovered_changed_files = result.uncovered_changed_files
        baseline.reason = (result.reason or "needs-prepare") .. (baseline.ok and "" or ("; " .. tostring(baseline.reason)))
        restart(baseline, "prepare-completed")
      end, helper)
      if baseline_started == false then
        result.reason = (result.reason or "needs-prepare") .. "; baseline-busy"
        restart(result, "prepare-completed")
      end
    end)
    if not ok then
      result.fallback = "prepare-error"; result.reason = tostring(dispatched); finish(result)
    elseif dispatched == false and not called then
      result.fallback = "prepare-not-started"; finish(result)
    end
  end, helper)
  if started == false then finish({ ok = false, reason = "switch-refresh-already-running-or-exiting", fallback = "not-started" }) end
  return true
end

function M.inventory(deps)
  if inventory_running then return false end
  local notify = deps.notify or vim.notify
  local ctx = deps.resolve()
  if not ctx then notify("No UE context", vim.log.levels.WARN, { title = "UE index TEMP" }); return false end
  local platform = require("utils.platform")
  local python = (deps.resolve_python or function()
    return platform.resolve_tool({ name = "python", env = { "UE_PYTHON" },
      driver_candidates = function(driver) return driver.python_candidates() end })
  end)()
  if not python.ok then notify("Inventory failed: python-unavailable", vim.log.levels.WARN); return false end
  local config = vim.fn.stdpath("config")
  local token = tostring(vim.fn.getpid()) .. "-" .. tostring((vim.uv or vim.loop).hrtime())
  local output = vim.fs.joinpath(config, ".tmp", "review-gd", "n4", "batch-work-inventory-command-" .. token .. ".json")
  vim.fn.mkdir(vim.fs.dirname(output), "p")
  local work = deps.work_root or vim.fs.joinpath(vim.env.TEMP or vim.env.TMP or vim.fn.stdpath("cache"), "nvim-ue-batch-work")
  local argv = { python.path, "-B", vim.fs.joinpath(config, "tools", "cdb_batch_work_inventory.py"),
    "--work-root", work, "--out", output }
  local paths = ctx.paths or {}
  local references = deps.inventory_roots and deps.inventory_roots(ctx) or {}
  if not deps.inventory_roots then
    for _, name in ipairs({ "clangd_dir", "runtime_dir" }) do
      if paths[name] then references[#references + 1] = paths[name] end
    end
    for _, root in ipairs({ ctx.engine_root or "", ctx.project_root or "" }) do
      if root ~= "" then references[#references + 1] = vim.fs.joinpath(root, ".cache", "nvim-ue") end
    end
  end
  for _, root in ipairs(references) do
    if root and root ~= "" then vim.list_extend(argv, { "--reference-root", root }) end
  end
  for _, root in ipairs(deps.active_roots and deps.active_roots(ctx) or {}) do
    vim.list_extend(argv, { "--active-root", root })
  end
  inventory_running = true
  local admission = require("utils.host_admission")
  local token = (deps.foreground_begin or admission.foreground_begin)("Read-only index TEMP inventory")
  local released = false
  local function release()
    if released then return end
    released = true
    (deps.foreground_done or admission.foreground_done)(token)
  end
  notify("TEMP inventory started (read-only dry-run)", vim.log.levels.INFO, { title = "UE index TEMP" })
  local ok, handle = pcall(deps.system or vim.system, argv, { text = true, timeout = 180000 }, function(result)
    (deps.schedule or vim.schedule)(function()
      inventory_running = false
      release()
      local message = result.code == 0 and ("Dry-run inventory written: " .. output)
        or ("Inventory failed: " .. vim.trim(result.stderr or result.stdout or "unknown"))
      if result.code == 0 then
        local ok_json, report = pcall(vim.json.decode, result.stdout or "")
        if ok_json and type(report) == "table" and type(report.totals) == "table" then
          local bytes = {}
          for _, name in ipairs({ "referenced", "active", "unreferenced_reclaimable", "unknown" }) do
            bytes[#bytes + 1] = name .. "=" .. tostring((report.totals[name] or {}).logical_bytes or 0)
          end
          message = message .. "\nBytes: " .. table.concat(bytes, "; ") .. "; errors=" .. tostring(report.errors or 0)
        end
      end
      notify(message, result.code == 0 and vim.log.levels.INFO or vim.log.levels.WARN, { title = "UE index TEMP" })
    end)
  end)
  if not ok then
    inventory_running = false
    release()
    notify("Inventory failed: " .. tostring(handle), vim.log.levels.WARN, { title = "UE index TEMP" })
    return false
  end
  pcall(deps.register or require("utils.task_registry").register,
    { name = "Read-only index TEMP inventory", group = "index", kind = "system", handle = handle })
  return true
end

function M.setup(deps)
  vim.api.nvim_create_user_command("UEIndexStatus", function() deps.index_status() end, {})
  vim.api.nvim_create_user_command("UEIndexNow", function() deps.index_now() end, {})
  vim.api.nvim_create_user_command("UEIndexSwitchReindex", function() M.run(deps) end,
    { desc = "Refresh changed source shards after a branch switch; prepare uncovered inputs" })
  vim.api.nvim_create_user_command("UEIndexBatchWorkInventory", function() M.inventory(deps) end,
    { desc = "Read-only dry-run of referenced, active and reclaimable index TEMP work" })
end

return M
