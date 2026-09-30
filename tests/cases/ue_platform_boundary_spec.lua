local t = require("tests.harness")
t.bootstrap()

local boundary = require("tests.helpers.ue_platform_boundary")

local FIXTURE_ROOT = vim.fn.getcwd() .. "/tests/fixtures/ue_platform_boundary"

local CASES = {
  {
    name = "direct OS probe only host owners may probe",
    pass = FIXTURE_ROOT .. "/direct_os_probe_ok.lua",
    pass_path = "lua/utils/platform/windows.lua",
    fail = FIXTURE_ROOT .. "/direct_os_probe_bad.lua",
    fail_path = "lua/config/clipboard.lua",
    rule = boundary.RULES.direct_os_probe,
  },
  {
    name = "compat booleans may not drive generic behavior",
    pass = FIXTURE_ROOT .. "/compat_boolean_branch_ok.lua",
    pass_path = "lua/utils/platform/init.lua",
    fail = FIXTURE_ROOT .. "/compat_boolean_branch_bad.lua",
    fail_path = "lua/utils/code_search/init.lua",
    rule = boundary.RULES.compat_boolean_branch,
  },
  {
    name = "generic conditions may not compare concrete targets",
    pass = FIXTURE_ROOT .. "/target_literal_condition_ok.lua",
    pass_path = "lua/ue/targets/android.lua",
    fail = FIXTURE_ROOT .. "/target_literal_condition_bad.lua",
    fail_path = "lua/ue.lua",
    rule = boundary.RULES.target_literal_condition,
  },
  {
    name = "host executable construction belongs to host capability owners",
    pass = FIXTURE_ROOT .. "/host_executable_path_ok.lua",
    pass_path = "lua/utils/platform/windows.lua",
    fail = FIXTURE_ROOT .. "/host_executable_path_bad.lua",
    fail_path = "lua/utils/code_search/init.lua",
    rule = boundary.RULES.host_executable_path,
  },
  {
    name = "target policy literals need owner or precise allowlisted UI context",
    pass = FIXTURE_ROOT .. "/target_policy_literal_ok.lua",
    pass_path = "lua/config/keymaps.lua",
    fail = FIXTURE_ROOT .. "/target_policy_literal_bad.lua",
    fail_path = "lua/ue.lua",
    rule = boundary.RULES.target_policy_literal,
  },
  {
    name = "generic and cross-target imports may not bind concrete owners",
    pass = FIXTURE_ROOT .. "/concrete_import_ok.lua",
    pass_path = "lua/ue/targets/ios.lua",
    fail = FIXTURE_ROOT .. "/concrete_import_bad.lua",
    fail_path = "lua/ue.lua",
    rule = boundary.RULES.concrete_cross_target_import,
  },
}

local function read(path)
  return table.concat(vim.fn.readfile(path), "\n")
end

local function has_rule(violations, rule)
  for _, violation in ipairs(violations) do
    if violation.rule == rule then
      return true
    end
  end
  return false
end

t.describe("ue platform boundary: per-rule fixtures", function()
  for _, case in ipairs(CASES) do
    t.it(case.name, function()
      local pass_violations = boundary.analyze_source(read(case.pass), case.pass_path)
      local fail_violations = boundary.analyze_source(read(case.fail), case.fail_path)
      t.assert_false(has_rule(pass_violations, case.rule), "positive fixture should not trigger " .. case.rule)
      t.assert_true(has_rule(fail_violations, case.rule), "negative fixture should trigger " .. case.rule)
    end)
  end
end)

-- ════════════════════════════════════════════════════════════════════════
-- 拆分 owner 的归属识别（2026-09-04）。
--
-- `lua/ue/dap/` 用平铺的 `_<target>_<concern>.lua` 约定拆分 target owner
-- （既有 `_ios_*.lua`，新增 `_android_policy.lua`）。owner 识别必须认这个约定，
-- 否则拆出来的 owner 会被判成 generic，它**自己的** target 命令字面量会被报成
-- 违例——从而把贡献者推向「加 allowlist」而不是正确归属。
--
-- 同时必须保持精确：通用模块里的 target 字面量**仍然要被拦**。
-- ════════════════════════════════════════════════════════════════════════
t.describe("ue platform boundary: 拆分 owner 归属识别", function()
  local TARGET_LITERAL = 'local cmd = { "adb", "-s", serial }\n'

  local SPLIT_OWNERS = { "lua/ue/dap/android.lua", "lua/ue/dap/_android_policy.lua" }
  local GENERIC_MODULES = {
    "lua/ue/dap/failure.lua", "lua/ue/dap/capability.lua",
    "lua/ue/dap/preflight.lua", "lua/ue/dap/smoke.lua", "lua/ue.lua",
  }

  for _, path in ipairs(SPLIT_OWNERS) do
    t.it(path .. " 作为 target owner 允许自己的 target 字面量", function()
      local violations = boundary.analyze_source(TARGET_LITERAL, path)
      t.assert_false(has_rule(violations, boundary.RULES.target_policy_literal),
        path .. " 是 Android owner，不应因自己的命令字面量被判违例")
    end)
  end

  for _, path in ipairs(GENERIC_MODULES) do
    t.it(path .. " 仍不得含 target 字面量（识别放宽不得过度）", function()
      local violations = boundary.analyze_source(TARGET_LITERAL, path)
      t.assert_true(has_rule(violations, boundary.RULES.target_policy_literal),
        path .. " 是 target-generic，必须继续拦下 target 命令字面量")
    end)
  end

  t.it("下划线前缀不得让任意文件变成 owner", function()
    -- `_progress` / `_common` 没有 target 段，必须仍是 generic。
    for _, path in ipairs({ "lua/ue/dap/_common.lua", "lua/ue/dap/_progress.lua" }) do
      local violations = boundary.analyze_source(TARGET_LITERAL, path)
      t.assert_true(has_rule(violations, boundary.RULES.target_policy_literal),
        path .. " 不含 target 段，不得被识别为 owner")
    end
  end)
end)

t.describe("ue platform boundary: allowlist precision", function()
  t.it("ui-text allowlist does not excuse executable construction in allowlisted files", function()
    local violations =
      boundary.analyze_source(read(FIXTURE_ROOT .. "/allowlist_precision_bad.lua"), "lua/config/keymaps.lua")
    t.assert_true(has_rule(violations, boundary.RULES.host_executable_path))
  end)

  t.it("production report scans every Lua owner with zero active exceptions", function()
    local report = boundary.production_report()
    t.assert_eq(#report.unmatched, 0, boundary.format_report(report))
    t.assert_eq(#report.missing, 0, boundary.format_report(report))
    t.assert_eq(#report.matched, 0, "resolved migrations must not remain active exceptions")
    t.assert_eq(#boundary.baseline, 0, "production baseline must remain empty")
    t.assert_true(#boundary.production_files() > 100, "boundary guard must scan the production Lua tree")
  end)

  t.it("keeps the pre-migration audit as non-active removal evidence", function()
    local required = {
      ["lua/config/clipboard.lua"] = false,
      ["lua/utils/code_search/init.lua"] = false,
      ["lua/ue/index/_build.lua"] = false,
      ["lua/ue/index/_generation.lua"] = false,
      ["lua/utils/ue_goto/semantic_sidecar_libclang.lua"] = false,
      ["lua/ue.lua"] = false,
    }
    for _, entry in ipairs(boundary.initial_audit) do
      if required[entry.file] ~= nil then
        required[entry.file] = true
      end
      t.assert_type(entry.rule, "string")
      t.assert_type(entry.owner, "string")
      t.assert_type(entry.removal_phase, "string")
      t.assert_type(entry.reason, "string")
    end
    for file, present in pairs(required) do
      t.assert_true(present, "initial audit must retain evidence for " .. file)
    end
  end)
end)
