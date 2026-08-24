local Common = require("ue.workflows.ios.common")

local M = {
  owner = "ios.device",
  operation = "device",
}

function M.select(platform, opts, deps)
  opts = opts or {}
  local task_runner = require("ue.target_tasks")
  local workflow_progress = task_runner.progress({
    title = "IOS device discovery",
    message = "Starting device discovery",
    percentage = 0,
    replace = "ue.ios.device.discovery",
  })
  local progress_finished = false
  local function finish_progress(message, percentage, level)
    if progress_finished then
      return
    end
    progress_finished = true
    workflow_progress:finish(message, percentage, level)
  end
  local function fail(message)
    finish_progress("IOS device discovery failed", nil, vim.log.levels.ERROR)
    deps.target_error("ue.device", message)
    if type(opts.on_error) == "function" then
      opts.on_error(message)
    end
  end

  local ctx, err = deps.resolve_context()
  if not ctx then
    fail(err)
    return
  end
  if
    opts.expected_engine_root
    and not deps.target_context_matches(ctx, opts.expected_engine_root, opts.expected_project_root)
  then
    fail("project changed during IOS setup; rerun :UEPrepare")
    return
  end

  local output_path = vim.fn.tempname() .. ".devices.json"
  local target_ctx, context_err, driver = deps.target_context(ctx, platform, {
    json_output = output_path,
  })
  if not target_ctx then
    fail(context_err)
    return
  end

  local host_driver = require("utils.platform").driver()
  local resolved, unavailable = require("ue.targets").resolve(driver.id, "device", host_driver)
  if not resolved then
    pcall(os.remove, output_path)
    fail(unavailable.reason)
    return
  end
  driver = resolved

  local function persist_device(device)
    if
      opts.expected_engine_root
      and not deps.target_context_matches(deps.resolve_context(), opts.expected_engine_root, opts.expected_project_root)
    then
      fail("project changed during IOS setup; rerun :UEPrepare")
      return
    end
    local runtime, update_err = deps.update_target_runtime(ctx.engine_root, driver.id, {
      device_id = device.id,
      device_name = device.name,
      device_backend = device.backend,
      device_transport = device.transport,
    })
    if not runtime then
      fail(update_err)
      return
    end
    finish_progress("IOS device ready: " .. (device.name or device.id), 100)
    vim.notify(("%s device selected: %s"):format(driver.id, device.name or device.id))
    if type(opts.on_selected) == "function" then
      opts.on_selected(device, driver)
    end
  end

  local function refresh_offline_device(device)
    local function rediscover(message, level, detail)
      if deps.trim(detail or "") ~= "" then
        pcall(function()
          require("utils.notification_history").record({
            scope = "ue.device",
            title = "IOS USB refresh",
            message = message,
            detail = detail,
            level = level or vim.log.levels.INFO,
          })
        end)
      end
      pcall(os.remove, output_path)
      finish_progress(message, 100, level)
      local next_opts = vim.deepcopy(opts)
      next_opts.offline_refresh_attempted = true
      vim.schedule(function()
        deps.select_target_device(platform, next_opts)
      end)
    end

    local transport = deps.trim(device and device.transport):lower()
    if driver.id ~= "IOS" or transport ~= "usb" then
      rediscover(
        ("Refreshed IOS device list; saved %s route is still offline"):format(
          transport ~= "" and transport or "unknown"
        ),
        vim.log.levels.WARN
      )
      return
    end

    local reset_script, reset_err = Common.resolve_usb_reset_script(ctx)
    if not reset_script then
      rediscover(
        "Refreshed IOS device list; USB recovery helper is unavailable",
        vim.log.levels.WARN,
        tostring(reset_err)
      )
      return
    end

    workflow_progress:report("Refreshing selected IOS USB route: " .. device.id, 92)
    local reset_handle, reset_run_err = task_runner.run({
      executable = reset_script,
      args = { "--force", device.id },
      cwd = require("ue.core.fs").dirname(reset_script),
      metadata = { platform = "IOS", operation = "device-refresh", device_id = device.id },
    }, {
      name = "UE IOS selected device refresh",
      on_exit = function(result)
        if result.code ~= 0 then
          rediscover(
            "IOS USB route is still offline; refreshed device list",
            vim.log.levels.WARN,
            task_runner.error_message(result)
          )
          return
        end
        rediscover("IOS USB route refreshed; rediscovering selected device")
      end,
    })
    if not reset_handle then
      rediscover(
        "Refreshed IOS device list; USB recovery could not start",
        vim.log.levels.WARN,
        tostring(reset_run_err)
      )
    end
  end

  local function choose(devices)
    local preferred_device_id = deps.trim(opts.preferred_device_id or "")
    if #devices == 0 and preferred_device_id == "" then
      return false
    end
    if preferred_device_id ~= "" then
      for _, device in ipairs(devices) do
        if device.id == preferred_device_id and device.available ~= false then
          persist_device(device)
          return true
        end
      end
      devices[#devices + 1] = {
        id = preferred_device_id,
        name = target_ctx.device_name or preferred_device_id,
        platform = "iOS",
        backend = target_ctx.device_backend or "legacy-mobiledevice",
        transport = target_ctx.device_transport or "usb",
        available = false,
      }
    end
    if preferred_device_id ~= "" and opts.offline_refresh_attempted == true then
      local message = ("Selected IOS USB device remains offline after one refresh: %s"):format(preferred_device_id)
      pcall(os.remove, output_path)
      finish_progress(message, 100, vim.log.levels.WARN)
      if type(opts.on_error) == "function" then
        opts.on_error(message)
      end
      return true
    end
    if opts.auto_select_single == true and #devices == 1 then
      persist_device(devices[1])
      return true
    end
    workflow_progress:report("Waiting for IOS device selection", 90)
    vim.ui.select(devices, {
      prompt = "Select " .. driver.id .. " device:",
      format_item = function(device)
        local backend = device.backend and (", " .. device.backend) or ""
        local transport = device.transport and (", " .. device.transport) or ""
        local availability = device.available == false and ", saved, offline" or ""
        return ("%s (%s%s%s%s, %s)"):format(
          device.name or "unnamed",
          device.os_version or device.platform or "unknown",
          backend,
          transport,
          availability,
          device.id
        )
      end,
    }, function(device)
      if not device then
        fail(driver.id .. " device selection cancelled")
        return
      end
      if device.available == false then
        refresh_offline_device(device)
        return
      end
      persist_device(device)
    end)
    return true
  end

  local function run_fallback(primary_reason, recovery_attempted)
    pcall(os.remove, output_path)
    if
      type(driver.fallback_device_list_plan) ~= "function" or type(driver.parse_fallback_device_list) ~= "function"
    then
      fail(primary_reason)
      return
    end

    workflow_progress:report("Checking pre-iOS17 USB MobileDevice", recovery_attempted and 75 or 35)
    local fallback_plan = driver.fallback_device_list_plan(target_ctx, host_driver)
    local fallback_handle, fallback_err = task_runner.run(fallback_plan, {
      name = "UE " .. driver.id .. " fallback device discovery",
      on_exit = function(result)
        if result.code ~= 0 then
          fail(primary_reason .. "; fallback " .. task_runner.error_message(result))
          return
        end
        local parsed = driver.parse_fallback_device_list(result.stdout)
        if not parsed.ok then
          fail(primary_reason .. "; fallback " .. parsed.reason)
          return
        end
        if not choose(parsed.devices) then
          if driver.id == "IOS" and not recovery_attempted then
            local reset_script, reset_err = Common.resolve_usb_reset_script(ctx)
            if not reset_script then
              fail(primary_reason .. "; no available pre-iOS17 USB device; " .. tostring(reset_err))
              return
            end
            workflow_progress:report("Recovering legacy IOS USB route", 55)
            local reset_args = {}
            if deps.trim(target_ctx.device_id or "") ~= "" then
              reset_args = { "--force", target_ctx.device_id }
            end
            local reset_handle, reset_run_err = task_runner.run({
              executable = reset_script,
              args = reset_args,
              cwd = require("ue.core.fs").dirname(reset_script),
              metadata = { platform = "IOS", operation = "device-recovery" },
            }, {
              name = "UE IOS USB recovery",
              on_exit = function(reset_result)
                if reset_result.code ~= 0 then
                  fail("IOS USB recovery failed: " .. task_runner.error_message(reset_result))
                  return
                end
                workflow_progress:report("Rechecking recovered IOS device", 70)
                run_fallback(primary_reason, true)
              end,
            })
            if not reset_handle then
              fail("IOS USB recovery failed to start: " .. tostring(reset_run_err))
            end
            return
          end
          fail(primary_reason .. "; no available pre-iOS17 USB device")
        end
      end,
    })
    if not fallback_handle then
      fail(primary_reason .. "; fallback " .. tostring(fallback_err))
    end
  end

  local function run_mobiledevice(primary_devices, primary_reason)
    if
      type(driver.mobiledevice_device_list_plans) ~= "function"
      or type(driver.parse_mobiledevice_device_list) ~= "function"
    then
      if not choose(primary_devices) then
        run_fallback(primary_reason)
      end
      return
    end

    local plans = driver.mobiledevice_device_list_plans(target_ctx, host_driver)
    if type(plans) ~= "table" or plans.ok == false or #plans == 0 then
      if not choose(primary_devices) then
        run_fallback(primary_reason .. "; MobileDevice discovery is unavailable")
      end
      return
    end

    workflow_progress:report("Checking USB and Wi-Fi MobileDevice routes", 35)
    local devices = vim.deepcopy(primary_devices or {})
    local positions = {}
    for index, device in ipairs(devices) do
      positions[device.id] = index
    end
    local pending = #plans
    local function present_choices()
      if not choose(devices) then
        run_fallback(primary_reason)
      end
    end
    local function enrich_mobiledevice_names()
      if type(driver.mobiledevice_info_plan) ~= "function" or type(driver.parse_mobiledevice_info) ~= "function" then
        present_choices()
        return
      end
      local pending_info = 0
      for _, device in ipairs(devices) do
        if device.backend == "legacy-mobiledevice" then
          pending_info = pending_info + 1
        end
      end
      if pending_info == 0 then
        present_choices()
        return
      end
      local function complete_info()
        pending_info = pending_info - 1
        if pending_info == 0 then
          present_choices()
        end
      end
      for index, device in ipairs(devices) do
        if device.backend == "legacy-mobiledevice" then
          local device_index = index
          local candidate = device
          local info_plan = driver.mobiledevice_info_plan(candidate, target_ctx, host_driver)
          local info_handle = task_runner.run(info_plan, {
            name = "UE IOS device identity",
            on_exit = function(result)
              if result.code == 0 then
                local parsed = driver.parse_mobiledevice_info(result.stdout, candidate)
                if parsed.ok then
                  devices[device_index] = parsed.device
                end
              end
              complete_info()
            end,
          })
          if not info_handle then
            complete_info()
          end
        end
      end
    end
    local function append(device)
      local position = positions[device.id]
      if not position then
        devices[#devices + 1] = device
        positions[device.id] = #devices
      elseif devices[position].transport == "network" and device.transport == "usb" then
        devices[position] = device
      end
    end
    local function complete_one()
      pending = pending - 1
      if pending > 0 then
        return
      end
      enrich_mobiledevice_names()
    end

    for _, mobile_plan in ipairs(plans) do
      local plan = mobile_plan
      local handle = task_runner.run(plan, {
        name = "UE IOS " .. tostring(plan.metadata.transport) .. " device discovery",
        on_exit = function(result)
          if result.code == 0 then
            local parsed = driver.parse_mobiledevice_device_list(result.stdout, plan.metadata.transport)
            if parsed.ok then
              for _, device in ipairs(parsed.devices) do
                append(device)
              end
            end
          end
          complete_one()
        end,
      })
      if not handle then
        complete_one()
      end
    end
  end

  workflow_progress:report("Checking CoreDevice", 10)
  local plan = driver.device_list_plan(target_ctx, host_driver)
  local handle, run_err = task_runner.run(plan, {
    name = "UE " .. driver.id .. " device discovery",
    on_exit = function(result)
      if result.code ~= 0 then
        run_mobiledevice({}, task_runner.error_message(result))
        return
      end
      local payload, payload_err = deps.read_result_file(output_path)
      if not payload then
        run_mobiledevice({}, payload_err)
        return
      end
      local parsed = driver.parse_device_list(payload)
      if not parsed.ok then
        run_mobiledevice({}, parsed.reason)
        return
      end
      pcall(os.remove, output_path)
      run_mobiledevice(parsed.devices, "no available physical " .. driver.id .. " CoreDevice")
    end,
  })
  if not handle then
    run_mobiledevice({}, run_err or "primary device discovery failed to start")
  end
  return handle
end

function M.run(request)
  local payload = request.payload or {}
  return M.select(payload.platform or "IOS", payload.opts, request.deps)
end

return M
