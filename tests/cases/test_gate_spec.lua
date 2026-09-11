local t = require("tests.harness")
local cfg = t.bootstrap()

t.describe("test gate: honest capability accounting", function()
  t.it("reports skips separately from passing tests", function()
    local isolated = assert(loadfile(cfg .. "/tests/harness/init.lua"))()
    local old_required, old_write = vim.env.NVIM_TEST_REQUIRE_NATIVE, io.write
    local output = {}
    local ok, err = xpcall(function()
      vim.env.NVIM_TEST_REQUIRE_NATIVE = nil
      io.write = function(text) output[#output + 1] = text end
      isolated.skip("native fixture", "tool unavailable", { native = true })
      t.assert_eq(isolated.run({ exit = false }), 0)
      local text = table.concat(output)
      t.assert_contains(text, "SKIP")
      t.assert_contains(text, "0/0 passed, 0 failed, 1 skipped")
      t.assert_false(text:find("OK    native fixture", 1, true))
    end, debug.traceback)
    vim.env.NVIM_TEST_REQUIRE_NATIVE, io.write = old_required, old_write
    if not ok then error(err) end
  end)

  t.it("required native acceptance fails instead of silently skipping", function()
    local isolated = assert(loadfile(cfg .. "/tests/harness/init.lua"))()
    local old_required = vim.env.NVIM_TEST_REQUIRE_NATIVE
    local ok, err = xpcall(function()
      vim.env.NVIM_TEST_REQUIRE_NATIVE = "1"
      isolated.skip("native fixture", "LLVM missing", { native = true })
      local result = isolated.results()[1]
      t.assert_false(result.ok)
      t.assert_false(result.skipped)
      t.assert_contains(result.err, "required native")
      t.assert_contains(result.err, "LLVM missing")
    end, debug.traceback)
    vim.env.NVIM_TEST_REQUIRE_NATIVE = old_required
    if not ok then error(err) end
  end)

  t.it("runner redirects logs and state before loading the suite", function()
    local root = assert(vim.env.NVIM_TEST_RUN_ROOT, "runner must establish an isolation root")
    t.assert_true(vim.fs.normalize(vim.fn.stdpath("state")):find(root, 1, true) == 1)
    t.assert_true(vim.fs.normalize(vim.env.NVIM_UE_PROBE_PATH):find(root, 1, true) == 1)
    local log = assert(loadfile(cfg .. "/lua/utils/log.lua"))()
    log.warn("test-gate", "isolated diagnostic fixture")
    t.assert_true(vim.fs.normalize(log.path()):find(root, 1, true) == 1)
  end)
end)
