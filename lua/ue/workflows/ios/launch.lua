local Common = require("ue.workflows.ios.common")

local M = {
  owner = "ios.launch",
  operation = "launch",
}

function M.launch(platform, opts, deps)
  opts = opts or {}
  local ctx, err = deps.resolve_context()
  if not ctx or not ctx.project_root then
    deps.target_error("ue.launch", err or "No project configured. Run :UESetProject [path]")
    return
  end
  local output_path = vim.fn.tempname() .. ".launch.json"
  local target_ctx, context_err, driver = deps.target_context(ctx, platform, {
    json_output = output_path,
  })
  if not target_ctx then
    deps.target_error("ue.launch", context_err)
    return
  end
  if not target_ctx.device_id then
    deps.target_error("ue.launch", ("no %s device selected; run :UESet%sDevice"):format(driver.id, driver.id))
    return
  end
  local host_driver = require("utils.platform").driver()
  local resolved, unavailable = require("ue.targets").resolve(driver.id, "launch", host_driver)
  if not resolved then
    pcall(os.remove, output_path)
    deps.target_error("ue.launch", unavailable.reason)
    return
  end
  driver = resolved
  if driver.id == "IOS" and target_ctx.device_backend == "legacy-mobiledevice" and opts.device_verified ~= true then
    pcall(os.remove, output_path)
    return Common.ensure_legacy_launch_device(ctx, target_ctx, deps, function()
      M.launch(platform, { device_verified = true }, deps)
    end)
  end
  if deps.target_launch_running[driver.id] then
    pcall(os.remove, output_path)
    vim.notify(driver.id .. " launch is already in progress", vim.log.levels.INFO)
    return
  end
  deps.target_launch_running[driver.id] = true
  local task_runner = require("ue.target_tasks")
  local launch_progress = task_runner.progress({
    title = driver.id .. " launch",
    scope = "ue.launch",
    message = "Validating installed IOS app and device route",
    percentage = 0,
    replace = "ue.target.launch." .. driver.id:lower(),
  })
  local launch_progress_finished = false
  local function finish_launch_progress(message, percentage, level)
    if launch_progress_finished then
      return
    end
    launch_progress_finished = true
    deps.target_launch_running[driver.id] = nil
    launch_progress:finish(message, percentage, level)
  end
  local function launch_error(message)
    pcall(os.remove, output_path)
    finish_launch_progress(driver.id .. " launch failed", nil, vim.log.levels.ERROR)
    deps.target_error("ue.launch", message)
  end
  if target_ctx.device_backend == "legacy-mobiledevice" then
    launch_progress:report("Loading persisted IOS signing and app evidence", 5)
    local prepared, prepare_err = Common.prepare_legacy_launch(ctx, driver, target_ctx)
    if not prepared then
      launch_error(prepare_err)
      return
    end
  end
  launch_progress:report("Checking IOS launch prerequisites", 10)
  deps.run_target_preflight(driver, "launch", target_ctx, host_driver, function(ok, preflight_err)
    if not ok then
      launch_error(preflight_err)
      return
    end
    launch_progress:report("Resolving installed IOS bundle", 20)
    Common.with_target_bundle_id(ctx, driver, target_ctx, host_driver, function(bundle_id, artifacts, bundle_err)
      if not bundle_id then
        launch_error(bundle_err)
        return
      end
      target_ctx.bundle_id = bundle_id
      target_ctx.artifacts = artifacts
      target_ctx.json_output = output_path
      local plan = driver.launch_plan(target_ctx, host_driver)
      launch_progress:report("Waiting for selected IOS device", 30)
      local handle, run_err = task_runner.run(plan, {
        name = "UE " .. driver.id .. " launch",
        on_exit = function(result)
          if result.code ~= 0 then
            launch_error(task_runner.error_message(result))
            return
          end
          launch_progress:report("Verifying launched IOS process", 85)
          local payload, payload_err = deps.read_result_file(output_path)
          if not payload then
            launch_error(payload_err)
            return
          end
          local parsed = driver.parse_launch_result(payload, {
            device_id = target_ctx.device_id,
            bundle_id = bundle_id,
          })
          if not parsed.ok then
            launch_error(parsed.reason)
            return
          end
          local runtime, update_err = deps.update_target_runtime(ctx.engine_root, driver.id, {
            device_id = target_ctx.device_id,
            bundle_id = bundle_id,
            artifacts = artifacts,
            process_id = parsed.process_id,
          })
          if not runtime then
            launch_error(update_err)
            return
          end
          local message = ("Launched %s on %s (pid %s)"):format(
            bundle_id,
            target_ctx.device_id,
            tostring(parsed.process_id)
          )
          finish_launch_progress(message, 100)
          vim.notify(message)
        end,
      })
      if not handle then
        launch_error(run_err or "launch task failed to start")
      end
    end)
  end)
end

function M.run(request)
  local payload = request.payload or {}
  return M.launch(payload.platform or "IOS", payload.opts, request.deps)
end

return M
