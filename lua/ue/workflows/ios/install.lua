local Common = require("ue.workflows.ios.common")

local M = {
  owner = "ios.install",
  operation = "install",
}

function M.install(platform, deps)
  local ctx, err = deps.resolve_context()
  if not ctx or not ctx.project_root then
    deps.target_error("ue.install", err or "No project configured. Run :UESetProject [path]")
    return
  end
  local output_path = vim.fn.tempname() .. ".install.json"
  local target_ctx, context_err, driver = deps.target_context(ctx, platform, {
    json_output = output_path,
  })
  if not target_ctx then
    deps.target_error("ue.install", context_err)
    return
  end
  if not target_ctx.device_id then
    deps.target_error("ue.install", ("no %s device selected; run :UESet%sDevice"):format(driver.id, driver.id))
    return
  end
  local host_driver = require("utils.platform").driver()
  local resolved, unavailable = require("ue.targets").resolve(driver.id, "install", host_driver)
  if not resolved then
    pcall(os.remove, output_path)
    deps.target_error("ue.install", unavailable.reason)
    return
  end
  driver = resolved
  local task_runner = require("ue.target_tasks")
  local install_progress = task_runner.progress({
    title = driver.id .. " install",
    scope = "ue.install",
    message = "Validating signing and install inputs",
    percentage = 0,
    replace = "ue.target.install." .. driver.id:lower(),
  })
  local install_progress_finished = false
  local function finish_install_progress(message, percentage, level)
    if install_progress_finished then
      return
    end
    install_progress_finished = true
    install_progress:finish(message, percentage, level)
  end
  local function install_error(message)
    finish_install_progress(driver.id .. " install failed", nil, vim.log.levels.ERROR)
    deps.target_error("ue.install", message)
  end
  if target_ctx.device_backend == "legacy-mobiledevice" then
    local prepared, prepared_err = Common.prepare_legacy_install(ctx, driver, target_ctx, {
      collect_existing_artifacts = deps.collect_existing_artifacts,
    })
    if not prepared then
      pcall(os.remove, output_path)
      install_error(prepared_err)
      return
    end
  end
  install_progress:report("Checking SDK, signing identity, and private key", 8)
  deps.run_target_preflight(driver, "install", target_ctx, host_driver, function(ok, preflight_err)
    if not ok then
      install_error(preflight_err)
      return
    end
    install_progress:report("Resolving bundle and tuple artifact", 12)
    Common.with_target_bundle_id(ctx, driver, target_ctx, host_driver, function(bundle_id, artifacts, bundle_err)
      if not bundle_id then
        install_error(bundle_err)
        return
      end
      target_ctx.bundle_id = bundle_id
      target_ctx.artifacts = artifacts
      target_ctx.json_output = output_path
      local plan = driver.install_plan(target_ctx, host_driver)
      install_progress:report("Starting container-preserving install", 15)
      local function progress_report(message, percentage)
        install_progress:report(message, percentage)
      end
      local stdout_progress = type(driver.install_progress_tracker) == "function"
          and driver.install_progress_tracker(progress_report)
        or function() end
      local stderr_progress = type(driver.install_progress_tracker) == "function"
          and driver.install_progress_tracker(progress_report)
        or function() end
      local handle, run_err = task_runner.run(plan, {
        name = "UE " .. driver.id .. " install",
        foreground = true,
        on_stdout = stdout_progress,
        on_stderr = stderr_progress,
        on_exit = function(result)
          if result.code ~= 0 then
            pcall(os.remove, output_path)
            local failure = type(driver.install_failure_reason) == "function"
                and driver.install_failure_reason(result, plan)
              or nil
            install_error(failure or task_runner.error_message(result))
            return
          end
          if plan.metadata and plan.metadata.backend == "legacy-mobiledevice" then
            pcall(os.remove, output_path)
            local runtime, update_err = deps.update_target_runtime(ctx.engine_root, driver.id, {
              device_id = target_ctx.device_id,
              device_backend = target_ctx.device_backend,
              bundle_id = bundle_id,
            })
            if not runtime then
              install_error(update_err)
              return
            end
            local message = ("Installed %s on %s via legacy MobileDevice"):format(bundle_id, target_ctx.device_id)
            finish_install_progress(message, 100)
            vim.notify(message)
            return
          end
          local payload, payload_err = deps.read_result_file(output_path)
          if not payload then
            install_error(payload_err)
            return
          end
          local parsed = driver.parse_install_result(payload, {
            device_id = target_ctx.device_id,
            bundle_id = bundle_id,
          })
          if not parsed.ok then
            install_error(parsed.reason)
            return
          end
          local runtime, update_err = deps.update_target_runtime(ctx.engine_root, driver.id, {
            device_id = target_ctx.device_id,
            bundle_id = bundle_id,
            artifacts = artifacts,
          })
          if not runtime then
            install_error(update_err)
            return
          end
          local message = ("Installed %s on %s"):format(bundle_id, target_ctx.device_id)
          finish_install_progress(message, 100)
          vim.notify(message)
        end,
      })
      if not handle then
        pcall(os.remove, output_path)
        install_error(run_err or "install task failed to start")
      end
    end)
  end)
end

function M.run(request)
  local payload = request.payload or {}
  return M.install(payload.platform or "IOS", request.deps)
end

return M
