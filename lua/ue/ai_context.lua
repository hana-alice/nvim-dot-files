local M = {}

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
    "- State file: `" .. display(context.state_path) .. "`",
    "- State updated at: `" .. display(state.updated_at) .. "`",
    "",
    "## Resolution Rules",
    "",
    "1. The engine root is the directory supplied to the exporter.",
    "2. Project root and `.uproject` come from `<engine>/.cache/nvim-ue/state.json`.",
    "3. `UE_TARGET_PLATFORM`, `UE_TARGET_CONFIGURATION`, and `UE_BUILD_TARGET` override persisted values.",
    "4. A configuration such as `Development Editor` is split into UBT configuration `Development` and target kind `Editor`.",
    "5. `<Space>ui` installs the newest APK found under the active `.uproject` directory.",
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

  local json_path = output_dir .. "/ue-nvim-context.json"
  local markdown_path = output_dir .. "/ue-nvim-context.md"
  vim.fn.writefile({ vim.json.encode(context) }, json_path)
  vim.fn.writefile(vim.split(M.render_markdown(context), "\n", { plain = true }), markdown_path)
  return {
    json = json_path,
    markdown = markdown_path,
  }
end

M.command_text = command_text

return M
