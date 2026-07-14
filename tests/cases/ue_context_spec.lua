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
  local uproject = project .. "/Source/Client/Client.uproject"

  write_file(engine .. "/Engine/Build/BatchFiles/Build.bat", "@echo off")
  for _, dir in ipairs({ "Binaries", "Build", "Config", "Plugins", "Shaders", "Source" }) do
    vim.fn.mkdir(engine .. "/Engine/" .. dir, "p")
  end
  write_file(uproject, "{}")
  write_file(project .. "/Source/Client/Source/Client.Target.cs", "public class ClientTarget {}")
  write_file(project .. "/Source/Client/Binaries/Android/Client-arm64.apk", "apk")
  write_file(engine .. "/.cache/nvim-ue/state.json", vim.json.encode({
    engine_root = engine,
    project_root = project,
    uproject = uproject,
    target_platform = "Android",
    target_configuration = "Development",
    android_package = "com.example.client",
    updated_at = "2026-07-13T00:00:00Z",
  }))

  return root, engine
end

t.describe("ue.ai_context", function()
  t.it("按引擎 state 解析项目、Android Development 和原生命令", function()
    local root, engine = fixture()
    local context, err = require("ue").ai_context(engine)
    vim.fn.delete(root, "rf")

    t.assert_nil(err)
    t.assert_eq(context.target.platform, "Android")
    t.assert_eq(context.target.selected_configuration, "Development")
    t.assert_eq(context.target.ubt_configuration, "Development")
    t.assert_eq(context.target.kind, "Game")
    t.assert_eq(context.target.name, "Client")
    t.assert_eq(context.state.android_package, "com.example.client")
    t.assert_eq(context.artifacts.build_command[1], "cmd.exe")
    t.assert_contains(context.artifacts.build_command[4], "Build.bat Client Android Development")
    t.assert_eq(context.artifacts.install_command[1], "adb")
    t.assert_eq(context.artifacts.install_command[2], "install")
    t.assert_eq(context.artifacts.install_command[3], "-r")
    t.assert_nil(context.commands[2].native_action)
  end)

  t.it("Markdown 同时包含键位、Neovim 命令和解析结果", function()
    local root, engine = fixture()
    local context = assert(require("ue").ai_context(engine))
    local markdown = require("ue.ai_context").render_markdown(context)
    vim.fn.delete(root, "rf")

    t.assert_contains(markdown, "`<Space>ub`")
    t.assert_contains(markdown, "`:UEBuild`")
    t.assert_contains(markdown, "Android")
    t.assert_contains(markdown, "Development")
    t.assert_contains(markdown, "adb install -r")
  end)
end)
