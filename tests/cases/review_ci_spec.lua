local t = require("tests.harness")
local cfg = t.bootstrap()

t.describe("review: CI regression entrypoints", function()
  t.it("legacy smoke passes on the actual host", function()
    local result = vim.system({ vim.v.progpath, "--headless", "-l", cfg .. "/scripts/headless_smoke.lua" }, {
      cwd = cfg,
      text = true,
    }):wait(30000)
    t.assert_eq(result.code, 0, (result.stderr or "") .. (result.stdout or ""))
    t.assert_contains(result.stdout or "", "0 failed")
  end)

  t.it("CI runs the full authoritative suite after dependency bootstrap", function()
    local workflow = table.concat(vim.fn.readfile(cfg .. "/.github/workflows/headless.yml"), "\n")
    local bootstrap = workflow:find("scripts/bootstrap_headless_ci.lua", 1, true)
    local full = workflow:find("nvim --headless -l tests/run.lua", 1, true)
    t.assert_true(bootstrap and full and bootstrap < full, "bootstrap must precede the unfiltered full suite")
    t.assert_false(workflow:find("NO_LEGACY:", 1, true), "CI must retain the legacy regression gate")
    t.assert_contains(workflow, "working-directory: nvim/tools/cindex-uefilter")
    t.assert_contains(workflow, "go test -p 1 ./...")
  end)

  t.it("dependency bootstrap refuses a normal local session", function()
    local result = vim.system({ vim.v.progpath, "--headless", "-l", cfg .. "/scripts/bootstrap_headless_ci.lua" }, {
      cwd = cfg,
      env = { CI = "false" },
      text = true,
    }):wait(10000)
    t.assert_true(result.code ~= 0)
    t.assert_contains(result.stderr or "", "run only in an isolated CI environment")
  end)
end)
