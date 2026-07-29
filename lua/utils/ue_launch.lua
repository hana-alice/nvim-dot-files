local M = {}

local android_device = require("utils.android_device")

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

local function desktop_editor_executable(env, engine_root, platform)
  local platform_dir = env.join(engine_root, "Engine", "Binaries", platform)
  local candidates = existing_launch_candidates(env, {
    env.join(platform_dir, "UnrealEditor.exe"),
    env.join(platform_dir, "UE4Editor.exe"),
    env.join(platform_dir, "UnrealEditor"),
    env.join(platform_dir, "UE4Editor"),
  })

  if platform == "Mac" then
    vim.list_extend(candidates, glob_launch_candidates(env, {
      env.join(platform_dir, "*.app", "Contents", "MacOS", "UnrealEditor"),
      env.join(platform_dir, "*.app", "Contents", "MacOS", "UE4Editor"),
    }))
  end

  return candidates[1]
end

local function desktop_project_executable(env, ctx, platform, configuration, kind)
  local uproject = ctx.uproject or env.find_uproject_in_dir(ctx.project_root)
  if not uproject then
    return nil
  end

  local target_name = env.build_target_name(ctx.project_root, uproject, kind)
  local project_name = project_name_from_uproject(env.trim, uproject)
  local bin_dir = env.join(ctx.project_root, "Binaries", platform)
  local extension = platform == "Win64" and ".exe" or ""
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

local function desktop_launch_spec(env, ctx)
  if not ctx.project_root then
    return nil, "No project configured for engine root. Run :UESetProject [path]"
  end

  local uproject = ctx.uproject or env.find_uproject_in_dir(ctx.project_root)
  if not uproject then
    return nil, "No .uproject found in project root: " .. ctx.project_root
  end

  local platform = env.target_platform(ctx.engine_root, nil)
  local configuration = env.target_configuration(ctx.engine_root, ctx.project_root, uproject, platform)
  local selected_configuration = env.selected_target_configuration(ctx.engine_root, ctx.project_root, uproject, platform)
  local kind = env.target_kind(ctx.engine_root, ctx.project_root, uproject, platform)

  if platform == "Android" then
    return nil, "Android should be launched through adb"
  end
  if platform == "IOS" then
    return nil, "iOS launch is not supported from this command"
  end

  if kind == "Editor" then
    local editor = desktop_editor_executable(env, ctx.engine_root, platform)
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

  local exe = desktop_project_executable(env, ctx, platform, configuration, kind)
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

local function android_launch_argv(adb, serial, package_name)
  return android_device.adb_args(adb, serial, {
    "shell",
    "monkey",
    "-p",
    package_name,
    "-c",
    "android.intent.category.LAUNCHER",
    "1",
  })
end

local function android_launch_command(env, ctx, serial)
  local engine_root = ctx.engine_root or ""
  local state = ctx.state or {}
  local package_name = env.trim(state.android_package or "")
  if package_name == "" then
    package_name = env.trim(vim.fn.input("Android package name: ", ""))
  end
  if package_name == "" then
    return nil, "Android package name is required"
  end
  if engine_root ~= "" and package_name ~= env.trim(state.android_package or "") then
    env.update_state_field(engine_root, "android_package", package_name)
  end

  local adb = vim.fn.exepath("adb")
  adb = adb ~= "" and adb or "adb"
  if vim.fn.executable(adb) ~= 1 and not env.is_file(adb) then
    return nil, "adb not found in PATH"
  end

  if not serial or serial == "" then
    return nil, "Android serial is required"
  end

  local cmd, cmd_err = android_launch_argv(adb, serial, package_name)
  if not cmd then return nil, cmd_err end

  return {
    package_name = package_name,
    serial = serial,
    cmd = cmd,
  }
end

local function powershell_start_process_command(powershell_quote, exe, args, working_dir)
  local function windows_native_path(value)
    value = tostring(value or "")
    if value:match("^[A-Za-z]:/") or value:match("^//") then
      return value:gsub("/", "\\")
    end
    return value
  end

  exe = windows_native_path(exe)
  working_dir = windows_native_path(working_dir)
  local quoted_args = {}
  for _, arg in ipairs(args or {}) do
    quoted_args[#quoted_args + 1] = powershell_quote(windows_native_path(arg))
  end

  local start_process = "Start-Process -FilePath " .. powershell_quote(exe)
  if working_dir and working_dir ~= "" then
    start_process = start_process .. " -WorkingDirectory " .. powershell_quote(working_dir)
  end
  start_process = start_process .. " -ArgumentList $argsList -PassThru"

  local ps = {
    "$ErrorActionPreference = 'Stop'",
    "$argsList = @(" .. table.concat(quoted_args, ", ") .. ")",
    "$proc = " .. start_process,
    "if (-not $proc -or -not $proc.Id) { throw 'Start-Process did not return a process id' }",
    "Start-Sleep -Milliseconds 200",
    "if (-not (Get-Process -Id $proc.Id -ErrorAction SilentlyContinue)) { throw ('Process exited immediately: ' + $proc.Id) }",
    "Write-Output ('pid=' + $proc.Id)",
  }

  return {
    "powershell.exe",
    "-NoProfile",
    "-ExecutionPolicy",
    "Bypass",
    "-Command",
    table.concat(ps, "; "),
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

  local cmd
  if env.is_windows_path(exe) then
    cmd = powershell_start_process_command(env.powershell_quote, exe, spec.args or {}, spec.cwd or env.dirname(exe))
    local result = vim.system(cmd, { text = true }):wait()
    local output = ((result.stdout or "") .. "\n" .. (result.stderr or "")):gsub("^%s+", ""):gsub("%s+$", "")
    if (result.code or 0) ~= 0 then
      return false, output ~= "" and output or ("Launch failed with exit code " .. tostring(result.code))
    end

    local pid = output:match("pid=(%d+)")
    if not pid then
      return false, output ~= "" and output or "Launch did not report a process id"
    end
    return true, pid
  end

  cmd = { exe }
  vim.list_extend(cmd, spec.args or {})
  local ok, jobid = pcall(vim.fn.jobstart, cmd, {
    cwd = spec.cwd,
    detach = true,
  })
  if not ok or not jobid or jobid <= 0 then
    return false, "Failed to launch process"
  end
  return true, tostring(jobid)
end

local function launch_android_process(env, spec)
  local output = {}

  local function append(data)
    for _, line in ipairs(data or {}) do
      line = env.trim(env.strip_ansi(line))
      if line ~= "" then
        output[#output + 1] = line
      end
    end
  end

  local ok, jobid = pcall(vim.fn.jobstart, spec.cmd, {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      append(data)
    end,
    on_stderr = function(_, data)
      append(data)
    end,
    on_exit = function(_, code)
      vim.schedule(function()
        if code == 0 then
          local device = spec.serial and (" on " .. spec.serial) or ""
          require("utils.log").notify(
            "ue_launch",
            ("Android app launched: %s%s"):format(spec.package_name, device),
            vim.log.levels.INFO
          )
          return
        end
        local detail = #output > 0 and ("\n" .. table.concat(output, "\n")) or ""
        require("utils.log").notify_error("ue_launch", ("Android launch failed (exit %d)%s"):format(code, detail))
      end)
    end,
  })
  if not ok or not jobid or jobid <= 0 then
    return false, "Failed to start adb launch job"
  end
  -- Register the adb-launch job for :Tasks list/cancel. Pure side-path:
  -- register only, after job creation; on_exit above is untouched. (The
  -- desktop launch_desktop_process job is intentionally detach=true /
  -- fire-and-forget and NOT registered — same rationale as the short-lived
  -- detach jobs excluded by the task-registry design.)
  pcall(function()
    require("utils.task_registry").register({
      name = "UELaunch (" .. (spec.package_name or "android") .. ")",
      group = "android",
      kind = "job",
      handle = jobid,
      started_at = os.time(),
    })
  end)
  return true
end

function M.resolve_spec(env)
  local ctx, err = env.resolve_context()
  if not ctx then
    return nil, err
  end

  local platform = env.target_platform(ctx.engine_root, nil)
  if platform == "Android" then
    local serial = android_device.get()
    if not serial then
      return nil, "Android device is not selected; run :UESetAndroidDevice"
    end
    local spec, launch_err = android_launch_command(env, ctx, serial)
    if not spec then
      return nil, launch_err
    end
    spec.platform = platform
    spec.kind = "Android"
    return spec, ctx
  end

  local spec, launch_err = desktop_launch_spec(env, ctx)
  if not spec then
    return nil, launch_err
  end
  return spec, ctx
end

function M.launch(env)
  local ctx, err = env.resolve_context()
  if not ctx then
    require("utils.log").notify("ue_launch", err, vim.log.levels.WARN)
    return
  end

  local platform = env.target_platform(ctx.engine_root, nil)
  if platform == "Android" then
    local adb = vim.fn.exepath("adb")
    adb = adb ~= "" and adb or "adb"
    if vim.fn.executable(adb) ~= 1 and not env.is_file(adb) then
      require("utils.log").notify_error("ue_launch", "adb not found in PATH")
      return
    end

    local function launch_on_serial(serial)
      if not serial or serial == "" then return end
      local spec, launch_err = android_launch_command(env, ctx, serial)
      if not spec then
        require("utils.log").notify_error("ue_launch", launch_err)
        return
      end
      local ok, err_msg = launch_android_process(env, spec)
      if not ok then
        require("utils.log").notify_error("ue_launch", err_msg)
      end
    end

    android_device.ensure({
      adb = adb,
      prompt = "Select Android device for UE launch:",
    }, launch_on_serial)
    return
  end

  local spec, launch_err = desktop_launch_spec(env, ctx)
  if not spec then
    require("utils.log").notify_error("ue_launch", launch_err)
    return
  end

  local ok, detail = launch_desktop_process(env, spec)
  if not ok then
    require("utils.log").notify_error("ue_launch", detail)
    return
  end

  local target = vim.fn.fnamemodify(spec.exe, ":t")
  local args = #spec.args > 0 and (" " .. table.concat(spec.args, " ")) or ""
  require("utils.log").notify(
    "ue_launch",
    ("Launched %s: %s%s (pid %s)"):format(spec.platform, target, args, detail),
    vim.log.levels.INFO
  )
end

-- Pure command-shape seam for headless regression (no adb/device required).
function M._android_launch_argv_for_test(adb, serial, package_name)
  return android_launch_argv(adb, serial, package_name)
end

return M
