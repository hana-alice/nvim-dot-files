-- tests/cases/ue_api_spec.lua
-- ue 公共 API 冻结：PUBLIC_TABLES 非空 table、PUBLIC_FUNCTIONS 为 function。
-- 迁移自 scripts/headless_smoke.lua 的对应断言。

local t = require("tests.harness")
t.bootstrap()

local PUBLIC_TABLES = {
  "FT_CPP", "FT_SHADER", "FT_CODE", "FT_CONFIG", "FT_ALL",
  "FT_GTAGS", "GLOBS_CODE", "GLOBS_ALL",
}

local PUBLIC_FUNCTIONS = {
  "clangd_cmd", "clangd_root", "current_platform", "platform_path_priorities",
  "android_build_command", "picker_options", "picker_project_options",
  "current_scope_picker_options", "cached_grep_file_list", "cached_code_file_list",
  "cached_files", "cached_grep", "statusline_status", "index_status", "index_now",
  "index_hot", "index_full", "ue_roots", "gtags_rebuild_shaders",
  "gtags_references", "gtags_definition", "launch_app", "toggle_log",
  "toggle_debug_log", "prepare_headless",
}

t.describe("ue: 公共表冻结", function()
  local ue = require("ue")
  for _, k in ipairs(PUBLIC_TABLES) do
    t.it("ue." .. k .. " 是非空 table", function()
      local v = ue[k]
      t.assert_type(v, "table", "ue." .. k)
      t.assert_true(#v > 0, "ue." .. k .. " 应非空")
    end)
  end
end)

t.describe("ue: 公共函数冻结", function()
  local ue = require("ue")
  for _, fn in ipairs(PUBLIC_FUNCTIONS) do
    t.it("ue." .. fn .. " 是 function", function()
      t.assert_type(ue[fn], "function", "ue." .. fn)
    end)
  end
end)
