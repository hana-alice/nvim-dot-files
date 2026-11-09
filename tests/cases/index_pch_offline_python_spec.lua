local t = require("tests.harness")
t.bootstrap()

t.describe("offline PCH Python commands and partial receipts", function()
  local python = vim.fn.exepath("python")
  if python == "" then
    python = vim.fn.exepath("python3")
  end
  if python == "" then
    t.skip("Python offline PCH unit suite", "Python unavailable", { native = true })
    return
  end
  -- An executable path may be a Windows Store alias rather than a working
  -- interpreter. The tool needs Python 3.11+ for hashlib.file_digest.
  local invoked, version = pcall(function()
    return vim.system({ python, "-I", "-c", "import sys; sys.exit(sys.version_info < (3, 11))" },
      { text = true }):wait(5000)
  end)
  if not invoked or version.code ~= 0 then
    t.skip("Python offline PCH unit suite", "working Python 3.11+ unavailable", { native = true })
    return
  end

  t.it("passes command, failure receipt reuse, and input invalidation unit tests", function()
    local script = vim.fn.stdpath("config") .. "/tests/py/test_clangd_pch_offline.py"
    local result = vim.system({ python, "-B", "-I", script }, { text = true }):wait(30000)
    t.assert_eq(result.code, 0, (result.stderr or "") .. (result.stdout or ""))
    t.assert_true((result.stderr or ""):find("OK", 1, true) ~= nil, "Python unittest did not finish")
  end)
end)
