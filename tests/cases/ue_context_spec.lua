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
      -- argv[1] 是 `adb_executable()` 的结果：能解析到时为 `exepath("adb")` 的**绝对路径**
      -- （本机可能是 C:\WINDOWS\adb.EXE），解析不到才回落字面量 "adb"。路径字面量取决于
      -- 宙主 PATH，不是不变量；真正的不变量是 basename 为 adb 且 `-s <serial>` 在位且有序。
      -- → openspec/specs/global-android-device-selection/spec.md（统一 `adb -s <serial>`）
      local adb_argv0 = context.artifacts.install_command[1]
      t.assert_match(adb_argv0:lower(), "adb%.?%a*$")
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
      -- 同上：adb 可执行文件字面量由宙主 PATH 决定，不变量是 `-s <serial> install -r` 片段。
      t.assert_contains(markdown, "-s SERIAL-CONTEXT install -r")
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

t.describe("UE clangd durable prepare gate", function()
  local ue = require("ue")
  local engine = "/Workspace/UE"
  local project = "/Workspace/Game"

  t.it("gates UE buffers by current tuple artifact readiness", function()
    t.assert_false(ue._clangd_gate_allows_for_test(
      "/Workspace/Game/Source/Game.cpp", project, engine, false))
    t.assert_false(ue._clangd_gate_allows_for_test(
      "/Workspace/UE/Engine/Source/Runtime/Core.cpp", project, engine, false))
    t.assert_true(ue._clangd_gate_allows_for_test(
      "/Workspace/Game/Source/Game.cpp", project, engine, true))
  end)

  t.it("does not gate ordinary C++ buffers outside the pinned UE roots", function()
    t.assert_true(ue._clangd_gate_allows_for_test(
      "/Workspace/Other/main.cpp", project, engine, false))
  end)

  t.it("reuses valid tuple artifacts after a Nvim restart", function()
    local unique = tostring(vim.uv.hrtime())
    local ctx = {
      engine_root = "/Workspace/UE-" .. unique,
      project_root = "/Workspace/Game-" .. unique,
      paths = { clangd_dir = "/Workspace/cache/clangd/IOS-Development-" .. unique },
    }
    local snapshot_calls = 0
    local ready = ue._clangd_artifacts_ready_for_test(ctx, {
      semantic_index_snapshot = function(received)
        t.assert_eq(received, ctx)
        snapshot_calls = snapshot_calls + 1
        return { readiness = "ready", generation_id = "persisted-generation" }
      end,
    })

    t.assert_true(ready)
    t.assert_eq(snapshot_calls, 1)
  end)

  t.it("revalidates the tuple when prepared artifacts change in the same process", function()
    local ctx = {
      engine_root = "/Workspace/UE-revalidate",
      project_root = "/Workspace/Game-revalidate",
      paths = { clangd_dir = "/Workspace/cache/clangd/revalidate" },
    }
    local readiness = "ready"
    local dependencies = {
      semantic_index_snapshot = function()
        return { readiness = readiness }
      end,
    }

    t.assert_true(ue._clangd_artifacts_ready_for_test(ctx, dependencies))
    readiness = "stale"
    t.assert_false(ue._clangd_artifacts_ready_for_test(ctx, dependencies))
  end)

  t.it("rejects missing or stale tuple artifacts", function()
    local function context(suffix)
      return {
        engine_root = "/Workspace/UE-" .. suffix,
        project_root = "/Workspace/Game-" .. suffix,
        paths = { clangd_dir = "/Workspace/cache/clangd/" .. suffix },
      }
    end
    for _, readiness in ipairs({ "missing", "stale", "building" }) do
      local ready = ue._clangd_artifacts_ready_for_test(context(readiness .. vim.uv.hrtime()), {
        semantic_index_snapshot = function()
          return { readiness = readiness }
        end,
      })
      t.assert_false(ready, readiness)
    end
  end)

  t.it("routes lspconfig through the durable artifact root gate", function()
    local config = vim.fn.stdpath("config")
    local plugin = table.concat(vim.fn.readfile(config .. "/lua/plugins/ue.lua"), "\n")
    local core = table.concat(vim.fn.readfile(config .. "/lua/ue.lua"), "\n")
    t.assert_contains(plugin, "clangd_start_root(bufnr)")
    t.assert_contains(core, "clangd_artifacts_ready")
    t.assert_contains(core, "start_deferred_clangd")
    t.assert_contains(core, 'pcall(exec_autocmds, "FileType"')
    t.assert_false(core:find("LspStart clangd", 1, true) ~= nil)
    t.assert_contains(core, "if not cdb_pipeline_done then")
    t.assert_contains(core, "if cdb_pipeline_ok then")
  end)

  t.it("retries the native FileType wake until clangd is attached", function()
    local callbacks = {}
    local exec_count = 0
    local attached = false
    ue._wake_deferred_clangd_for_test(42, {
      buffer_ready = function() return true end,
      get_clients = function()
        return attached and { { name = "clangd" } } or {}
      end,
      exec_autocmds = function(event, opts)
        t.assert_eq(event, "FileType")
        t.assert_eq(opts.buffer, 42)
        exec_count = exec_count + 1
        attached = exec_count == 2
      end,
      defer_fn = function(callback, delay)
        t.assert_eq(delay, 250)
        callbacks[#callbacks + 1] = callback
      end,
      max_attempts = 3,
    })

    t.assert_eq(exec_count, 1)
    t.assert_eq(#callbacks, 1)
    callbacks[1]()
    t.assert_eq(exec_count, 2)
    t.assert_eq(#callbacks, 1)
  end)
end)

t.describe("target_platform 无持久状态时的默认值", function()
  local ue = require("ue")

  t.it("Windows host / 盘符 engine root 默认 Win64（不再回落 Linux）", function()
    -- Fresh checkout: engine root exists but has no persisted state at all.
    local root = ("C:/tmp/nvim-ue-plat-%d-%d"):format(vim.fn.getpid(), vim.uv.hrtime())
    vim.fn.mkdir(root, "p")
    local saved = vim.env.UE_TARGET_PLATFORM
    local platform = require("utils.platform")
    local saved_driver = platform.driver
    vim.env.UE_TARGET_PLATFORM = nil
    platform.driver = function() return require("utils.platform.windows") end
    local ok, plat = pcall(ue._target_platform_for_test, root, nil)
    platform.driver = saved_driver
    vim.env.UE_TARGET_PLATFORM = saved
    vim.fn.delete(root, "rf")
    assert(ok, plat)
    -- On a Windows host this must never be Linux (2026-08-18: bare-state
    -- UEBuild produced `<Target> Linux Development` → UBT exit 6,
    -- "Unable to find valid SDK(s) for Linux").
    t.assert_eq(plat, "Win64")
  end)

  t.it("env override 仍最高优先", function()
    local saved = vim.env.UE_TARGET_PLATFORM
    vim.env.UE_TARGET_PLATFORM = "Android"
    local plat = ue._target_platform_for_test("C:/nonexistent-engine", nil)
    vim.env.UE_TARGET_PLATFORM = saved
    t.assert_eq(plat, "Android")
  end)

  t.it("UEBuild 新 bucket 未设 platform 时先弹 picker 再续跑（源断言）", function()
    local source = table.concat(vim.fn.readfile(vim.fn.stdpath("config") .. "/lua/ue.lua"), "\n")
    -- Fresh-bucket gate exists in build_android and resumes the build after
    -- an explicit choice; never builds a guessed platform silently.
    t.assert_contains(source, "not CORE_RT.project_state.target_is_set(ctx.engine_root)")
    t.assert_contains(source, "_platform_prompted = true")
    -- Picker floats the engine-level last-used pair as suggestion only.
    t.assert_contains(source, "engine_target_default(engine_root)")
    t.assert_contains(source, "(last used on this engine)")
  end)
end)
