-- tests/cases/commands_spec.lua
-- 用户命令注册回归。
-- 冻结清单：新增 UE* 命令时需同步此处（防误删/防漏注册）。

local t = require("tests.harness")
local cfg = t.bootstrap()

-- 78 个 UE* 命令冻结清单（来自 lua/ue.lua + lua/ue/*.lua）。
local UE_COMMANDS = {
  "UEBuild", "UEBuildAndroid", "UEBuildAndroidSO", "UEBuildIOS", "UEBuildPCH", "UECachePaths", "UECDBPartition",
  "UECDBStatus", "UECDBSwitch", "UECheatsheet", "UECheatsheetEdit", "UEClearCache",
  "UECompileForNvim",
  "UEDAPAttach", "UEDAPClearBreakpoints", "UEDAPCondBreakpoint", "UEDAPContinue",
  "UEDAPDiag", "UEDAPEval", "UEDAPFrameDown", "UEDAPFrameUp", "UEDAPHover",
  "UEDAPLaunch", "UEDAPListBreakpoints", "UEDAPLogpoint", "UEDAPNextTab",
  "UEDAPPause", "UEDAPPrevTab", "UEDAPReattach", "UEDAPREPL", "UEDAPRestartFrame",
  "UEDAPRunToCursor", "UEDAPStatus", "UEDAPStepIn", "UEDAPStepOut", "UEDAPStepOver",
  "UEDAPStop", "UEDAPTab", "UEDAPToggleBreakpoint", "UEDAPToggleUI", "UEDAPWatchAdd",
  "UEDAPWatchUE", "UEDebugLogToggle", "UEDirtyClear", "UEDirtyStatus",
  "UEDeployAndroidSO", "UEExportCompileCommands", "UEGenerateFromRSP", "UEGrepDiagDump",
  "UEGrepGroupingToggle", "UEGrepTraceShow", "UEGrepTraceToggle", "UEIndexFull",
  "UEIndexHot", "UEIndexNow", "UEIndexStatus", "UEIndexTimings", "UEInstallAndroid", "UEInstallIOS",
  "UEIOSSymbols", "UELaunch", "UELogToggle", "UEPackageIOS", "UEPaths", "UEPrepare", "UEPrepareIncremental",
  "UEPrepareReindex", "UEPrepareSync", "UEResetLayout", "UESetAndroidDevice",
  "UESetAndroidPackage", "UESetIOSDevice", "UESetPlatform", "UESetProject", "UESetUprojectRelativePath", "UEWatchFlush",
  "UEWatchStatus", "UEWatchStop",
}

t.describe("commands: UE* 全量注册", function()
  require("ue").setup()
  t.it("冻结清单含 78 个命令", function()
    t.assert_eq(#UE_COMMANDS, 78)
  end)
  for _, c in ipairs(UE_COMMANDS) do
    t.it(":" .. c .. " 已注册", function()
      require("ue").setup()
      t.assert_eq(vim.fn.exists(":" .. c), 2, c .. " 未注册")
    end)
  end
end)

-- Generic (prefix-free) background-task management commands. Registered by
-- ue.setup() but intentionally NOT UE-prefixed — they're a general editor
-- feature backed by lua/utils/task_registry.lua.
local TASK_COMMANDS = { "Tasks", "TaskStop", "TaskStopAll" }

t.describe("commands: 通用任务管理命令注册", function()
  require("ue").setup()
  t.it("冻结清单含 3 个任务命令", function()
    t.assert_eq(#TASK_COMMANDS, 3)
  end)
  for _, c in ipairs(TASK_COMMANDS) do
    t.it(":" .. c .. " 已注册", function()
      require("ue").setup()
      t.assert_eq(vim.fn.exists(":" .. c), 2, c .. " 未注册")
    end)
  end
end)

t.describe("commands: 辅助命令（keymaps.lua 注册）", function()
  vim.g.mapleader = " "
  vim.g.maplocalleader = " "
  require("ue").setup()
  require("utils.log").install_commands()
  require("utils.core_health").setup()
  pcall(dofile, cfg .. "/lua/config/keymaps.lua")
  for _, c in ipairs({
    "Restart", "RestartDetect", "UEDefStatus", "UEDefCancel", "UEDefContextClear",
    "NotificationHistory", "NotificationHistoryClear", "NvimCoreHealth", "WindowTitle", "WindowTitleReset",
  }) do
    t.it(":" .. c .. " 已注册", function()
      t.assert_eq(vim.fn.exists(":" .. c), 2, c .. " 未注册")
    end)
  end
end)

t.describe("commands: workarounds 命令（setup 后注册）", function()
  require("workarounds").setup({ auto_apply = false })
  for _, c in ipairs({ "WorkaroundList", "WorkaroundStatus", "WorkaroundEnable", "WorkaroundDisable" }) do
    t.it(":" .. c .. " 已注册", function()
      t.assert_eq(vim.fn.exists(":" .. c), 2, c .. " 未注册")
    end)
  end
end)
