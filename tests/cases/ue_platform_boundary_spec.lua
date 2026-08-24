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
