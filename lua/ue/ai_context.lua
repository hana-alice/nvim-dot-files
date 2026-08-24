local M = {}
local file_lock = require("ue.file_lock")

local function command_text(argv)
  if type(argv) ~= "table" then
    return nil
  end

  local parts = {}
  for _, value in ipairs(argv) do
    value = tostring(value)
    if value:find("%s") then
      value = '"' .. value:gsub('"', '\\"') .. '"'
    end
    parts[#parts + 1] = value
  end
  return table.concat(parts, " ")
end

local function display(value)
  if value == nil or value == "" then
    return "<none>"
  end
  return tostring(value)
end

local function diagnostic_text(value)
  if type(value) ~= "table" then
    return value
  end
  return tostring(value.reason or value.message or vim.inspect(value))
end

---Build the target-specific, read-only command summary used by the exported AI
---context. This report owner may compare target ids for presentation, while the
---facade remains limited to context resolution and dependency injection.
function M.resolve_target_artifacts(ctx, platform_id, state, deps)
  local targets = deps.targets or require("ue.targets")
  local host_driver = deps.host_driver or require("utils.platform").driver()
  local build_command, build_error = deps.android_build_command(ctx)
  local android_active = platform_id == targets.must_get("Android").id
  local so_build_command, so_build_error
  if android_active then
    so_build_command, so_build_error = deps.android_build_command(ctx, { operation = "so_build" })
  else
    so_build_error = "UEBuildAndroidSO requires target platform Android."
  end

  local apk = android_active and deps.find_apk(ctx) or nil
  local selected_android_serial = deps.android_device.get()
  local so_deploy_command, so_deploy_error
  if android_active then
    so_deploy_command, so_deploy_error = deps.android_so_deploy_command(
      ctx, selected_android_serial, state.android_package, host_driver
    )
  else
    so_deploy_error = "UEDeployAndroidSO requires target platform Android."
  end

  local _, install_unavailable = targets.resolve("Android", "install", host_driver)
  local ios_active = platform_id == targets.must_get("IOS").id
  local install_plan = android_active
      and not install_unavailable
      and apk
      and selected_android_serial
      and targets.plan("Android", "install", {
        adb = deps.android_device.adb_executable(),
        apk = apk,
        cwd = ctx.engine_root,
        device_id = selected_android_serial,
      }, host_driver)
    or nil
  local install_command = install_plan and deps.target_tasks.command(install_plan) or nil
  local install_native_action
  if ios_active then
    local _, ios_install_unavailable = targets.resolve("IOS", "install", host_driver)
    if ios_install_unavailable then
      install_native_action = ("IOS install is unavailable on host %s: %s"):format(
        tostring(host_driver.id), tostring(ios_install_unavailable.reason)
      )
    else
      install_native_action = "Installs the current tuple's signed staged app in place; does not uninstall or launch."
    end
  elseif not android_active then
    install_native_action = "UEInstall supports active Android and IOS targets."
  elseif install_unavailable then
    install_native_action = ("Android install is unavailable on host %s: %s"):format(
      tostring(host_driver.id), tostring(install_unavailable.reason)
    )
  elseif not apk then
    install_native_action = "No APK found under the active uproject build outputs."
  elseif not selected_android_serial then
    install_native_action = "Android device is not selected; run :UESetAndroidDevice."
  end

  return {
    android_device_serial = selected_android_serial,
    build_command = build_command,
    build_error = diagnostic_text(build_error),
    so_build_command = so_build_command,
    so_build_error = diagnostic_text(so_build_error),
    so_deploy_command = so_deploy_command,
    so_deploy_error = diagnostic_text(so_deploy_error),
    latest_apk = apk,
    install_command = install_command,
    install_native_action = install_native_action,
  }
end

function M.render_markdown(context)
  local target = context.target or {}
  local state = context.state or {}
  local artifacts = context.artifacts or {}
  local lines = {
    "# UE Neovim AI Context",
    "",
    "> Generated from the requested engine root and the live Neovim UE state.",
    "> Treat paths and commands below as resolved facts for this checkout.",
    "",
    "## Active Context",
    "",
    "- Engine root: `" .. display(context.engine_root) .. "`",
    "- Project root: `" .. display(context.project_root) .. "`",
    "- UProject: `" .. display(context.uproject) .. "`",
    "- Platform: `" .. display(target.platform) .. "`",
    "- Selected configuration: `" .. display(target.selected_configuration) .. "`",
    "- UBT configuration: `" .. display(target.ubt_configuration) .. "`",
    "- Target kind: `" .. display(target.kind) .. "`",
    "- Target name: `" .. display(target.name) .. "`",
    "- Android package: `" .. display(state.android_package) .. "`",
    "- Android device serial: `" .. display(context.android_device_serial) .. "`",
    "- State file: `" .. display(context.state_path) .. "`",
    "- State updated at: `" .. display(state.updated_at) .. "`",
    "",
    "## Resolution Rules",
    "",
    "1. The engine root is the directory supplied to the exporter.",
    "2. Project root and `.uproject` are captured by this Neovim process; persisted state lives in `<engine>/.cache/nvim-ue/projects/<project-key>/`.",
    "3. `UE_TARGET_PLATFORM`, `UE_TARGET_CONFIGURATION`, and `UE_BUILD_TARGET` override persisted values.",
    "4. A configuration such as `Development Editor` is split into UBT configuration `Development` and target kind `Editor`.",
    "5. `<Space>uA` selects process-local `vim.g.ue_android_device_serial`; Android operations use `adb -s <serial>`.",
    "6. `<Space>ui` installs the newest APK without launching it; `<Space>uq` replaces the SO and leaves the package stopped; `<Space>ul` is the explicit launch action.",
    "",
    "## Common UE Commands",
    "",
    "| Key | Neovim command | Purpose | Resolved native action |",
    "|---|---|---|---|",
  }

  for _, command in ipairs(context.commands or {}) do
    local native = command.native_command and command_text(command.native_command)
      or command.native_action
      or "<internal Neovim/Lua operation>"
    native = diagnostic_text(native)
    native = native:gsub("|", "\\|")
    lines[#lines + 1] = ("| `%s` | `%s` | %s | `%s` |"):format(
      command.key,
      command.nvim_command,
      command.purpose,
      native
    )
  end

  lines[#lines + 1] = ""
  lines[#lines + 1] = "## Resolved Artifacts"
  lines[#lines + 1] = ""
  lines[#lines + 1] = "- Build command: `" .. display(command_text(artifacts.build_command)) .. "`"
  lines[#lines + 1] = "- Latest APK: `" .. display(artifacts.latest_apk) .. "`"
  lines[#lines + 1] = "- Install command: `" .. display(command_text(artifacts.install_command)) .. "`"
  lines[#lines + 1] = "- Compile commands: `" .. display(artifacts.compile_commands) .. "`"
  lines[#lines + 1] = "- External clangd index: `" .. display(artifacts.clangd_index) .. "`"
  lines[#lines + 1] = ""
  lines[#lines + 1] = "## Source Of Truth"
  lines[#lines + 1] = ""
  lines[#lines + 1] = "- Keymaps: `lua/config/keymaps.lua`"
  lines[#lines + 1] = "- Context/build/install resolution: `lua/ue.lua`"
  lines[#lines + 1] = "- Persisted selection: `" .. display(context.state_path) .. "`"
  lines[#lines + 1] = ""

  return table.concat(lines, "\n")
end

function M.write(context, output_dir)
  output_dir = vim.fs.normalize(output_dir)
  vim.fn.mkdir(output_dir, "p")
  local lease, lease_err = file_lock.acquire(output_dir .. "/.ue-nvim-context.lock")
  if not lease then error("AI context export owned by another Neovim: " .. tostring(lease_err)) end

  local json_path = output_dir .. "/ue-nvim-context.json"
  local markdown_path = output_dir .. "/ue-nvim-context.md"
  local function atomic_write(path, content)
    local temp = path .. (".tmp.%d.%s"):format(vim.fn.getpid(), tostring(vim.uv.hrtime()))
    local file = assert(io.open(temp, "wb"))
    file:write(content)
    file:close()
    local ok, err = vim.uv.fs_rename(temp, path)
    if not ok then
      pcall(vim.fn.delete, temp)
      error("cannot atomically replace " .. path .. ": " .. tostring(err))
    end
  end
  local ok, write_err = xpcall(function()
    atomic_write(json_path, vim.json.encode(context) .. "\n")
    atomic_write(markdown_path, M.render_markdown(context) .. "\n")
  end, debug.traceback)
  file_lock.release(lease)
  if not ok then error(write_err) end
  return {
    json = json_path,
    markdown = markdown_path,
  }
end

M.command_text = command_text

return M
