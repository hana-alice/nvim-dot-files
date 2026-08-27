local runtime = require("ue.workflows._runtime")

local M = {}

local function trim(value)
  return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function join(...)
  return require("ue.core.fs").join(...)
end

local function glob_paths(pattern, glob)
  local result = (glob or vim.fn.glob)(pattern, false, true)
  if type(result) ~= "table" then
    return {}
  end
  return result
end

local function uproject_dir(ctx)
  local uproject = trim(ctx and ctx.uproject)
  if uproject == "" then
    return nil
  end
  return vim.fn.fnamemodify(uproject, ":h")
end

local function find_apks(ctx, opts)
  opts = opts or {}
  local project_dir = uproject_dir(ctx)
  if not project_dir or project_dir == "" then
    return {}
  end
  local patterns = {
    join(project_dir, "Binaries", "Android", "*.apk"),
    join(project_dir, "Intermediate", "Android", "*", "gradle", "app", "build", "outputs", "apk", "*.apk"),
    join(project_dir, "Intermediate", "Android", "*", "gradle", "app", "build", "outputs", "apk", "debug", "*.apk"),
    join(project_dir, "Intermediate", "Android", "*", "gradle", "app", "build", "outputs", "apk", "release", "*.apk"),
  }

  local found = {}
  local seen = {}
  for _, pattern in ipairs(patterns) do
    for _, path in ipairs(glob_paths(pattern, opts.glob)) do
      if not seen[path] then
        seen[path] = true
        found[#found + 1] = {
          path = path,
          mtime = (opts.getftime or vim.fn.getftime)(path),
        }
      end
    end
  end
  table.sort(found, function(a, b)
    if a.mtime ~= b.mtime then
      return a.mtime > b.mtime
    end
    return a.path < b.path
  end)
  return vim.tbl_map(function(item)
    return item.path
  end, found)
end

local function find_apk(ctx, opts)
  return find_apks(ctx, opts)[1]
end

local function age_string(path, now)
  local mtime = vim.fn.getftime(path)
  local age = (now or os.time()) - mtime
  if age < 60 then
    return age .. "s ago"
  end
  if age < 3600 then
    return math.floor(age / 60) .. "m ago"
  end
  return math.floor(age / 3600) .. "h ago"
end

local function pick_summary(stderr_lines, stdout_lines)
  for _, line in ipairs(stderr_lines or {}) do
    if line:find("Failure %[") or line:find("^adb: ") then
      return line
    end
  end
  if stderr_lines and #stderr_lines > 0 then
    return stderr_lines[#stderr_lines]
  end
  if stdout_lines and #stdout_lines > 0 then
    return stdout_lines[#stdout_lines]
  end
  return "(no output captured)"
end

local function failure_hint(summary, serial)
  if summary:find("INSTALL_FAILED_UPDATE_INCOMPATIBLE") then
    return ("→ run: adb -s %s uninstall <your.package.id>  (signature mismatch from leftover PMS record)"):format(
      serial
    )
  end
  if summary:find("INSTALL_FAILED_INSUFFICIENT_STORAGE") then
    return ("→ free space on /data or use adb -s %s install -r -d"):format(serial)
  end
  if summary:find("INSTALL_FAILED_VERSION_DOWNGRADE") then
    return ("→ downgrade blocked; use adb -s %s install -r -d (allow downgrade) or uninstall first"):format(serial)
  end
  if summary:find("INSTALL_FAILED_NO_MATCHING_ABIS") then
    return ("→ ABI mismatch; check device ABI with: adb -s %s shell getprop ro.product.cpu.abi"):format(serial)
  end
  if summary:find("INSTALL_PARSE_FAILED") then
    return "→ APK corrupt or unsigned; rebuild + re-sign"
  end
  if summary:find("device offline") or summary:find("no devices/emulators") then
    return "→ adb device gone; check: adb devices"
  end
  return nil
end

local function deps(request)
  local context = request.context or {}
  local logger = context.logger or require("utils.log")
  return {
    resolve_context = context.resolve_context,
    android_device = context.android_device or require("utils.android_device"),
    host_driver = request.host_driver or require("utils.platform").driver(),
    targets = context.targets or require("ue.targets"),
    target_tasks = context.target_tasks or require("ue.target_tasks"),
    resolve_tool = context.resolve_tool or require("utils.platform").resolve_tool,
    progress = context.progress or require("fidget.progress"),
    logger = logger,
    notify_error = context.notify_error or function(scope, message)
      logger.notify_error(scope, message)
    end,
    notification_history = context.notification_history
      or (pcall(require, "utils.notification_history") and require("utils.notification_history") or nil),
    task_registry = context.task_registry
      or (pcall(require, "utils.task_registry") and require("utils.task_registry") or nil),
    jobstart = context.jobstart or vim.fn.jobstart,
    schedule = context.schedule or vim.schedule,
    schedule_wrap = context.schedule_wrap or vim.schedule_wrap,
    defer_fn = context.defer_fn or vim.defer_fn,
    new_timer = context.new_timer or function()
      return (vim.uv or vim.loop).new_timer()
    end,
    find_apk = context.find_apk or find_apk,
    now = context.now or os.time,
    reinvoke = context.reinvoke,
  }
end

local function notify_history(history, payload)
  if history and type(history.record) == "function" then
    pcall(history.record, payload)
  end
end

local function build_snapshot(ctx, host_driver, serial, apk, adb)
  return runtime.snapshot({
    operation = "install",
    owner = "android.install",
    project = { canonical = trim(ctx and ctx.project_root or ctx and ctx.engine_root) },
    target = { id = "Android" },
    host = { id = type(host_driver) == "table" and host_driver.id or "" },
    device = { serial = serial },
    configuration = trim(ctx and ctx.configuration),
    runtime = { artifact = trim(apk), adb = trim(adb) },
    context = {
      engine_root = trim(ctx and ctx.engine_root),
      project_root = trim(ctx and ctx.project_root),
      uproject = trim(ctx and ctx.uproject),
    },
  })
end

function M.run(request)
  local d = deps(request)
  local ctx, err = d.resolve_context()
  if not ctx then
    vim.notify(err, vim.log.levels.WARN)
    return nil, err
  end
  if not ctx.project_root then
    local message = "No project configured. Run :UESetProject [path]"
    vim.notify(message, vim.log.levels.WARN)
    return nil, message
  end

  local _, unavailable = d.targets.resolve("Android", "install", d.host_driver)
  if unavailable then
    d.notify_error("ue.android", unavailable.reason)
    return nil, unavailable.reason
  end

  local apk = d.find_apk(ctx)
  if not apk then
    local message = "No APK found in project build outputs"
    d.notify_error("ue.android", message)
    return nil, message
  end

  local adb_result = d.resolve_tool({
    name = "adb",
    env = { "UE_ADB" },
    driver = d.host_driver,
    driver_candidates = { "adb" },
  })
  if not adb_result or adb_result.ok ~= true then
    local message = "adb not found in PATH"
    d.notify_error("ue.android", message)
    return nil, message
  end

  local serial = d.android_device.get()
  if not serial then
    d.android_device.ensure(
      { adb = adb_result.path, prompt = "Select Android device for APK install:" },
      function(selected)
        if selected and type(d.reinvoke) == "function" then
          d.reinvoke()
        end
      end
    )
    return nil, "device-selection-pending"
  end

  local snapshot = request.snapshot or build_snapshot(ctx, d.host_driver, serial, apk, adb_result.path)
  local plan = d.targets.plan("Android", "install", {
    adb = snapshot.runtime.adb,
    apk = snapshot.runtime.artifact,
    cwd = ctx.engine_root,
    device_id = snapshot.device.serial,
  }, d.host_driver)
  local install_cmd, install_err = d.target_tasks.command(plan)
  if not install_cmd then
    d.notify_error("ue.android", install_err)
    return nil, install_err
  end

  local age = age_string(snapshot.runtime.artifact, d.now())
  local artifact_name = vim.fn.fnamemodify(plan.metadata.artifact, ":t")
  notify_history(d.notification_history, {
    scope = "ue.install",
    level = vim.log.levels.INFO,
    message = ("Installing APK: %s (built %s) on %s"):format(artifact_name, age, snapshot.device.serial),
  })

  local handle = d.progress.handle.create({
    title = "Installing APK",
    message = ("built %s — %s"):format(age, artifact_name),
    lsp_client = { name = "adb" },
    percentage = 0,
  })

  local dots = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
  local tick = 0
  local timer = d.new_timer()
  timer:start(
    0,
    120,
    d.schedule_wrap(function()
      if handle then
        tick = tick + 1
        handle.message = dots[tick % #dots + 1] .. " installing..."
      end
    end)
  )

  local stdout_lines, stderr_lines = {}, {}
  local admission = require("utils.host_admission")
  local foreground_token = admission.foreground_begin("UEInstallAndroid")
  local ok, install_jobid = pcall(d.jobstart, install_cmd, {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      for _, line in ipairs(data) do
        if line ~= "" then
          table.insert(stdout_lines, line)
          d.schedule(function()
            if handle then
              handle.message = line
            end
          end)
        end
      end
    end,
    on_stderr = function(_, data)
      for _, line in ipairs(data) do
        if line ~= "" then
          table.insert(stderr_lines, line)
          d.schedule(function()
            if handle then
              handle.message = line
            end
          end)
        end
      end
    end,
    on_exit = function(_, code)
      d.schedule(function()
        if foreground_token then
          admission.foreground_done(foreground_token)
          foreground_token = nil
        end
        timer:stop()
        timer:close()
        if code == 0 then
          handle.message = "Installed successfully"
          notify_history(d.notification_history, {
            scope = "ue.install",
            level = vim.log.levels.INFO,
            message = ("Installed successfully: %s"):format(artifact_name),
          })
          handle:finish()
          return
        end

        local stderr_blob = table.concat(stderr_lines, "\n")
        local stdout_blob = table.concat(stdout_lines, "\n")
        local summary = pick_summary(stderr_lines, stdout_lines)
        local hint = failure_hint(summary, snapshot.device.serial)

        handle.message = ("✗ exit %d — %s%s"):format(code, summary, hint and ("  " .. hint) or "")
        notify_history(d.notification_history, {
          scope = "ue.install",
          level = vim.log.levels.ERROR,
          message = ("adb install failed (exit %d): %s%s. See :NvimLog"):format(
            code,
            summary,
            hint and ("  " .. hint) or ""
          ),
        })
        if type(d.logger.error) == "function" then
          d.logger.error(
            "ue.install",
            ("adb install failed (exit %d): %s\n--- stderr ---\n%s\n--- stdout ---\n%s\nLog: see :NvimLog"):format(
              code,
              artifact_name,
              stderr_blob,
              stdout_blob
            )
          )
        end
        d.defer_fn(function()
          if handle then
            handle:finish()
          end
        end, 8000)
      end)
    end,
  })

  if not ok or not install_jobid or install_jobid <= 0 then
    admission.foreground_done(foreground_token)
    foreground_token = nil
    timer:stop()
    timer:close()
    if handle then
      handle.message = "Failed to start adb install"
      handle:finish()
    end
    local message = "Failed to start adb install job"
    d.notify_error("ue.android", message)
    return nil, message, snapshot
  end

  if d.task_registry and type(d.task_registry.register) == "function" then
    pcall(d.task_registry.register, {
      name = "UEInstallAndroid",
      group = "android",
      kind = "job",
      handle = install_jobid,
      started_at = os.time(),
    })
  end

  return install_jobid, nil, snapshot
end

function M._find_apk_for_test(ctx)
  return find_apk(ctx)
end

function M._find_apks_for_test(ctx, opts)
  return find_apks(ctx, opts)
end

function M._age_string_for_test(path, now)
  return age_string(path, now)
end

return {
  owner = "android.install",
  run = M.run,
  api = {
    find_apk = M._find_apk_for_test,
    find_apks = M._find_apks_for_test,
  },
  _find_apk_for_test = M._find_apk_for_test,
  _find_apks_for_test = M._find_apks_for_test,
  _age_string_for_test = M._age_string_for_test,
}
