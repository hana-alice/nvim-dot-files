local M = {}

local function project_name_from_uproject(trim, uproject)
  local name = trim(vim.fs.basename(uproject or ""))
  if name == "" then
    return ""
  end
  return name:gsub("%.uproject$", "")
end

local function existing_launch_candidates(env, candidates)
  local existing = {}
  local seen = {}
  for _, candidate in ipairs(candidates or {}) do
    local normalized = env.norm(candidate)
    local key = normalized:lower()
    if normalized ~= "" and not seen[key] and env.is_file(normalized) then
      seen[key] = true
      existing[#existing + 1] = normalized
    end
  end
  table.sort(existing, function(a, b)
    local ma = env.file_mtime(a)
    local mb = env.file_mtime(b)
    if ma ~= mb then
      return ma > mb
    end
    return a < b
  end)
  return existing
end

local function glob_launch_candidates(env, patterns)
  local candidates = {}
  local seen = {}
  for _, pattern in ipairs(patterns or {}) do
    for _, match in ipairs(env.glob_paths(pattern)) do
      local normalized = env.norm(match)
      local key = normalized:lower()
      if normalized ~= "" and env.is_file(normalized) and not seen[key] then
        seen[key] = true
        candidates[#candidates + 1] = normalized
      end
    end
  end
  table.sort(candidates, function(a, b)
    local ma = env.file_mtime(a)
    local mb = env.file_mtime(b)
    if ma ~= mb then
      return ma > mb
    end
    return a < b
  end)
  return candidates
end

local function desktop_editor_executable(env, engine_root, driver)
  local policy = driver.runtime.launch
  local platform_dir = env.join(engine_root, "Engine", "Binaries", driver.id)
  local explicit = {}
  for _, name in ipairs(policy.editor_names or {}) do
    explicit[#explicit + 1] = env.join(platform_dir, name)
  end
  local candidates = existing_launch_candidates(env, explicit)

  if policy.editor_app_bundles then
    local patterns = {}
    for _, name in ipairs(policy.editor_names or {}) do
      patterns[#patterns + 1] = env.join(platform_dir, "*.app", "Contents", "MacOS", name)
    end
    vim.list_extend(candidates, glob_launch_candidates(env, patterns))
  end

  return candidates[1]
end

local function desktop_project_executable(env, ctx, driver, configuration, kind)
  local uproject = ctx.uproject or env.find_uproject_in_dir(ctx.project_root)
  if not uproject then
    return nil
  end

  local target_name = env.build_target_name(ctx.project_root, uproject, kind)
  local project_name = project_name_from_uproject(env.trim, uproject)
  local platform = driver.id
  local bin_dir = env.join(ctx.project_root, "Binaries", platform)
  local extension = driver.runtime.launch.executable_suffix or ""
  local base_names = {}

  local function add_name(name)
    name = env.trim(name)
    if name ~= "" then
      base_names[#base_names + 1] = name
    end
  end

  add_name(target_name)
  if project_name ~= target_name then
    add_name(project_name)
  end

  local candidates = {}
  for _, base in ipairs(base_names) do
    candidates[#candidates + 1] = env.join(bin_dir, base .. extension)
    candidates[#candidates + 1] = env.join(bin_dir, ("%s-%s-%s%s"):format(base, platform, configuration, extension))
    candidates[#candidates + 1] = env.join(bin_dir, ("%s-%s%s"):format(base, configuration, extension))
  end

  local existing = existing_launch_candidates(env, candidates)
  if #existing > 0 then
    return existing[1]
  end

  local patterns = {}
  for _, base in ipairs(base_names) do
    patterns[#patterns + 1] = env.join(bin_dir, base .. "*" .. extension)
  end
  local globbed = glob_launch_candidates(env, patterns)
  return globbed[1]
end

local function desktop_launch_spec(env, ctx, driver)
  if not ctx.project_root then
    return nil, "No project configured for engine root. Run :UESetProject [path]"
  end

  local uproject = ctx.uproject or env.find_uproject_in_dir(ctx.project_root)
  if not uproject then
    return nil, "No .uproject found in project root: " .. ctx.project_root
  end

  local platform = driver.id
  local configuration = env.target_configuration(ctx.engine_root, ctx.project_root, uproject, platform)
  local selected_configuration = env.selected_target_configuration(ctx.engine_root, ctx.project_root, uproject, platform)
  local kind = env.target_kind(ctx.engine_root, ctx.project_root, uproject, platform)

  if kind == "Editor" then
    local editor = desktop_editor_executable(env, ctx.engine_root, driver)
    if not editor then
      return nil, ("Editor executable not found for %s under engine root: %s"):format(platform, ctx.engine_root)
    end
    return {
      platform = platform,
      selected_configuration = selected_configuration,
      configuration = configuration,
      kind = kind,
      exe = editor,
      cwd = env.dirname(editor),
      args = { uproject },
    }
  end

  local exe = desktop_project_executable(env, ctx, driver, configuration, kind)
  if not exe then
    local target_name = env.build_target_name(ctx.project_root, uproject, kind)
    return nil, ("Launch binary not found for %s %s (%s) under %s"):format(
      platform,
      selected_configuration,
      target_name,
      env.join(ctx.project_root, "Binaries", platform)
    )
  end

  return {
    platform = platform,
    selected_configuration = selected_configuration,
    configuration = configuration,
    kind = kind,
    exe = exe,
    cwd = env.dirname(exe),
    args = {},
  }
end

local function launch_desktop_process(env, spec)
  local exe = env.trim(spec and spec.exe or "")
  if exe == "" then
    return false, "Launch executable was empty"
  end
  if not env.is_file(exe) then
    return false, "Launch executable not found: " .. exe
  end

  local host_driver = env.host_driver or require("utils.platform").driver()
  local plan = host_driver.launch_process_plan({
    executable = exe,
    args = spec.args or {},
    cwd = spec.cwd or env.dirname(exe),
  })
  local cmd, plan_err = require("ue.target_tasks").command(plan)
  if not cmd then
    return false, plan_err
  end

  if plan.metadata and plan.metadata.launch_mode == "wait" then
    local result = vim.system(cmd, { text = true }):wait()
    local output = ((result.stdout or "") .. "\n" .. (result.stderr or "")):gsub("^%s+", ""):gsub("%s+$", "")
    if (result.code or 0) ~= 0 then
      return false, output ~= "" and output or ("Launch failed with exit code " .. tostring(result.code))
    end

    local pid = output:match(plan.metadata.pid_pattern or "pid=(%d+)")
    if not pid then
      return false, output ~= "" and output or "Launch did not report a process id"
    end
    return true, pid
  end

  local ok, jobid = pcall(vim.fn.jobstart, cmd, {
    cwd = plan.cwd or spec.cwd,
    detach = true,
  })
  if not ok or not jobid or jobid <= 0 then
    return false, "Failed to launch process"
  end
  return true, tostring(jobid)
end

local function resolve_driver(env, ctx)
  local platform = env.target_platform(ctx.engine_root, nil)
  local host_driver = env.host_driver or require("utils.platform").driver()
  local driver, unavailable = require("ue.targets").resolve(platform, "launch", host_driver)
  if not driver then
    return nil, unavailable.reason
  end
  return driver
end

local RESOLVE_STRATEGIES = {
  workflow = function(env, _, driver)
    local owner = require("ue.workflows").lookup(driver.id, "launch")
    if not owner or type(owner.prepare) ~= "function" then
      return nil, driver.id .. " launch workflow is unavailable"
    end
    local prepared, err = owner.prepare({
      target_id = driver.id,
      host_driver = env.host_driver,
      context = env,
    }, { prompt_device = false })
    if not prepared then return nil, err end
    return {
      platform = driver.id,
      kind = driver.id,
      serial = prepared.snapshot.device.serial,
      package_name = prepared.snapshot.runtime.package_name,
      cmd = prepared.command,
      plan = prepared.plan,
    }, prepared.snapshot
  end,
  desktop = function(env, ctx, driver)
    local spec, launch_err = desktop_launch_spec(env, ctx, driver)
    if not spec then
      return nil, launch_err
    end
    return spec, ctx
  end,
  ["managed-device"] = function(_, _, driver)
    return nil, driver.id .. " launch is owned by the managed-device lifecycle"
  end,
  unavailable = function(_, _, driver)
    return nil, driver.id .. " launch is unavailable"
  end,
}

local LAUNCH_STRATEGIES = {
  workflow = function(env, _, driver)
    local function dispatch()
      local context = vim.tbl_extend("force", {}, env, { reinvoke = dispatch })
      return require("ue.workflows").dispatch(driver.id, "launch", {
        host_driver = env.host_driver,
        context = context,
      })
    end
    local result, err = dispatch()
    if result == nil then
      if type(err) ~= "table" then return true end
      return false, err and (err.reason or err)
    end
    return true
  end,
  desktop = function(env, ctx, driver)
    local spec, launch_err = desktop_launch_spec(env, ctx, driver)
    if not spec then
      return false, launch_err
    end

    local ok, detail = launch_desktop_process(env, spec)
    if not ok then
      return false, detail
    end

    local target = vim.fn.fnamemodify(spec.exe, ":t")
    local args = #spec.args > 0 and (" " .. table.concat(spec.args, " ")) or ""
    require("utils.log").notify(
      "ue_launch",
      ("Launched %s: %s%s (pid %s)"):format(spec.platform, target, args, detail),
      vim.log.levels.INFO
    )
    return true
  end,
  ["managed-device"] = function(_, _, driver)
    return false, driver.id .. " launch is owned by the managed-device lifecycle"
  end,
  unavailable = function(_, _, driver)
    return false, driver.id .. " launch is unavailable"
  end,
}

function M.resolve_spec(env)
  local ctx, err = env.resolve_context()
  if not ctx then
    return nil, err
  end

  local driver, driver_err = resolve_driver(env, ctx)
  if not driver then
    return nil, driver_err
  end
  local strategy = driver.runtime.launch.strategy
  local resolver = RESOLVE_STRATEGIES[strategy]
  if not resolver then
    return nil, "Unknown launch strategy: " .. tostring(strategy)
  end
  return resolver(env, ctx, driver)
end

function M.launch(env)
  local ctx, err = env.resolve_context()
  if not ctx then
    require("utils.log").notify("ue_launch", err, vim.log.levels.WARN)
    return
  end

  local driver, driver_err = resolve_driver(env, ctx)
  if not driver then
    require("utils.log").notify_error("ue_launch", driver_err)
    return
  end
  local strategy = driver.runtime.launch.strategy
  local launcher = LAUNCH_STRATEGIES[strategy]
  if not launcher then
    require("utils.log").notify_error("ue_launch", "Unknown launch strategy: " .. tostring(strategy))
    return
  end
  local ok, launch_err = launcher(env, ctx, driver)
  if not ok and launch_err then
    require("utils.log").notify_error("ue_launch", launch_err)
  end
end

-- Pure command-shape seam for headless regression (no adb/device required).
function M._android_launch_argv_for_test(adb, serial, package_name)
  local host_driver = require("utils.platform")._driver_for_test("windows")
  return require("ue.workflows").invoke(
    "Android", "launch", "command", { adb, serial, package_name, host_driver }, host_driver
  )
end

return M
