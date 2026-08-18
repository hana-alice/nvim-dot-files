local t = require("tests.harness")
t.bootstrap()

local function write_file(path, content)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  vim.fn.writefile(vim.split(content or "", "\n", { plain = true }), path)
end

local function fixture()
  local root = ("C:/tmp/nvim-ue-context-%d-%d"):format(vim.fn.getpid(), vim.uv.hrtime())
  local engine = root .. "/UE"
  local project = root .. "/Project"
  local uproject = project .. "/Source/SampleGame/SampleGame.uproject"

  write_file(engine .. "/Engine/Build/BatchFiles/Build.bat", "@echo off")
  for _, dir in ipairs({ "Binaries", "Build", "Config", "Plugins", "Shaders", "Source" }) do
    vim.fn.mkdir(engine .. "/Engine/" .. dir, "p")
  end
  write_file(uproject, "{}")
  write_file(project .. "/Source/SampleGame/Source/SampleGame.Target.cs", "public class SampleGameTarget {}")
  write_file(project .. "/Source/SampleGame/Binaries/Android/SampleGame-arm64.apk", "apk")
  write_file(engine .. "/.cache/nvim-ue/state.json", vim.json.encode({
    engine_root = engine,
    project_root = project,
    uproject = uproject,
    target_platform = "Android",
    target_configuration = "Development",
    android_package = "com.example.samplegame",
    updated_at = "2026-07-13T00:00:00Z",
  }))

  return root, engine
end

local function find_command(context, nvim_command)
  for _, command in ipairs(context.commands or {}) do
    if command.nvim_command == nvim_command then return command end
  end
end

t.describe("ue.ai_context", function()
  t.it("按引擎 state 解析项目，并服从 host-target matrix", function()
    local root, engine = fixture()
    require("utils.android_device").set("SERIAL-CONTEXT")
    local context, err = require("ue").ai_context(engine)
    require("utils.android_device").clear()
    vim.fn.delete(root, "rf")

    t.assert_nil(err)
    t.assert_eq(context.target.platform, "Android")
    t.assert_eq(context.target.selected_configuration, "Development")
    t.assert_eq(context.target.ubt_configuration, "Development")
    t.assert_eq(context.target.kind, "Game")
    t.assert_eq(context.target.name, "SampleGame")
    t.assert_eq(context.state.android_package, "com.example.samplegame")
    t.assert_eq(context.android_device_serial, "SERIAL-CONTEXT")
    local host_id = require("utils.platform").driver().id
    if host_id == "windows" then
      local build_text = table.concat(context.artifacts.build_command, " ")
      t.assert_eq(context.artifacts.build_command[1], "cmd.exe")
      t.assert_contains(build_text, "Build.bat")
      t.assert_contains(build_text, "SampleGame Android Development")
      t.assert_eq(context.artifacts.install_command[1], "adb")
      t.assert_eq(context.artifacts.install_command[2], "-s")
      t.assert_eq(context.artifacts.install_command[3], "SERIAL-CONTEXT")
      t.assert_eq(context.artifacts.install_command[4], "install")
      t.assert_eq(context.artifacts.install_command[5], "-r")
      t.assert_nil(assert(find_command(context, ":UEInstall")).native_action)
    else
      t.assert_nil(context.artifacts.build_command)
      t.assert_contains(context.artifacts.build_error, "unavailable on host " .. host_id)
      t.assert_nil(context.artifacts.install_command)
      t.assert_contains(assert(find_command(context, ":UEInstall")).native_action, "unavailable on host")
    end
  end)

  t.it("Markdown 同时包含键位、Neovim 命令和解析结果", function()
    local root, engine = fixture()
    require("utils.android_device").set("SERIAL-CONTEXT")
    local context = assert(require("ue").ai_context(engine))
    local markdown = require("ue.ai_context").render_markdown(context)
    require("utils.android_device").clear()
    vim.fn.delete(root, "rf")

    t.assert_contains(markdown, "`<Space>ub`")
    t.assert_contains(markdown, "`:UEBuild`")
    t.assert_contains(markdown, "Android")
    t.assert_contains(markdown, "Development")
    t.assert_contains(markdown, "Android device serial: `SERIAL-CONTEXT`")
    if require("utils.platform").is_windows then
      t.assert_contains(markdown, "adb -s SERIAL-CONTEXT install -r")
    else
      t.assert_contains(markdown, "Android install is unavailable on host")
    end
  end)

  t.it("未选择设备时不生成裸 adb install，并给出设置指引", function()
    local root, engine = fixture()
    require("utils.android_device").clear()
    local context = assert(require("ue").ai_context(engine))
    vim.fn.delete(root, "rf")

    t.assert_nil(context.artifacts.install_command)
    local install = assert(find_command(context, ":UEInstall"))
    if require("utils.platform").is_windows then
      t.assert_contains(install.native_action or "", ":UESetAndroidDevice")
    else
      t.assert_contains(install.native_action or "", "unavailable on host")
    end
  end)
end)
