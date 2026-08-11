local t = require("tests.harness")
t.bootstrap()

local ue = require("ue")

local function with_target_env(platform, configuration, target, fn)
  local old_platform = vim.env.UE_TARGET_PLATFORM
  local old_configuration = vim.env.UE_TARGET_CONFIGURATION
  local old_target = vim.env.UE_BUILD_TARGET
  vim.env.UE_TARGET_PLATFORM = platform
  vim.env.UE_TARGET_CONFIGURATION = configuration
  vim.env.UE_BUILD_TARGET = target
  local ok, result_a, result_b, result_c = pcall(fn)
  vim.env.UE_TARGET_PLATFORM = old_platform
  vim.env.UE_TARGET_CONFIGURATION = old_configuration
  vim.env.UE_BUILD_TARGET = old_target
  if not ok then
    error(result_a)
  end
  return result_a, result_b, result_c
end

t.describe("ue target integration", function()
  t.it("IOS build combines the IOS target driver with the macOS host driver", function()
    local command, err, plan = with_target_env("IOS", "Development", "SampleGame", function()
      return ue._target_plan_for_test(
        "build",
        {
          engine_root = "/UE Root",
          project_root = "/Project Root",
          uproject = "/Project Root/Sample.uproject",
          state = {},
        },
        "IOS",
        {
          host_driver = require("utils.platform.macos"),
        }
      )
    end)

    t.assert_eq(err, nil)
    t.assert_eq(command[1], "/UE Root/Engine/Build/BatchFiles/Mac/Build.sh")
    t.assert_contains(command, "IOS")
    t.assert_contains(command, "-Project=/Project Root/Sample.uproject")
    t.assert_eq(plan.metadata.platform, "IOS")
  end)

  t.it("Mac target uses its own driver and never receives IOS argv", function()
    local command = with_target_env("Mac", "Development", "SampleEditor", function()
      return ue._target_plan_for_test(
        "build",
        {
          engine_root = "/UE",
          project_root = "/Project",
          uproject = "/Project/Sample.uproject",
          state = {},
        },
        "Mac",
        {
          host_driver = require("utils.platform.macos"),
        }
      )
    end)

    t.assert_contains(command, "Mac")
    t.assert_false(vim.tbl_contains(command, "IOS"))
  end)

  t.it("accepts only the pinned clangd 22.1 toolchain", function()
    local compatible = ue._clangd_version_compatible_for_test("clangd version 22.1.5")
    local apple = ue._clangd_version_compatible_for_test("Apple clangd version 17.0.0")
    local future_minor = ue._clangd_version_compatible_for_test("clangd version 22.2.0")
    t.assert_true(compatible)
    t.assert_false(apple)
    t.assert_false(future_minor)
  end)

  t.it("keeps IOS command strings out of other target drivers", function()
    local config = vim.fn.stdpath("config")
    local mac = table.concat(vim.fn.readfile(config .. "/lua/ue/targets/mac.lua"), "\n")
    local android = table.concat(vim.fn.readfile(config .. "/lua/ue/targets/android.lua"), "\n")
    local core = table.concat(vim.fn.readfile(config .. "/lua/ue.lua"), "\n")
    t.assert_false(mac:find("devicectl", 1, true) ~= nil)
    t.assert_false(android:find("devicectl", 1, true) ~= nil)
    t.assert_false(core:find("BuildCookRun", 1, true) ~= nil)
    t.assert_false(core:find("devicectl", 1, true) ~= nil)
    t.assert_false(core:find("ue_android_so_build.ps1", 1, true) ~= nil)
    t.assert_false(core:find("ue_android_so_deploy.ps1", 1, true) ~= nil)
  end)
end)
