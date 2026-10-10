local t = require("tests.harness")
local root = t.bootstrap()

t.describe("search_precision_ui: native installed picker", function()
  t.it("final cursor, UTF-8 spans, line-only regex, states and post-filter survive real UI replay", function()
    local data = vim.fn.stdpath("data")
    local python = vim.fn.exepath("python")
    local search = require("utils.code_search")
    if
      python == ""
      or not search.csearch_exe()
      or not search.cindex_uefilter_exe()
      or vim.fn.filereadable(data .. "/lazy/snacks.nvim/lua/snacks/init.lua") ~= 1
    then
      return t.skip("native search UI", "requires Python, installed Snacks and csearch tools", { native = true })
    end
    local parent = assert(vim.env.NVIM_TEST_RUN_ROOT)
    local directory = parent .. "/search-native-ui"
    vim.fn.mkdir(directory, "p")
    local result = vim
      .system(
        { python, root .. "/tests/fixtures/search_precision_ui.py", root, directory, vim.v.progpath, data },
        { text = true, timeout = 95000 }
      )
      :wait()
    t.assert_eq(result.code, 0, (result.stdout or "") .. (result.stderr or ""))
    t.assert_contains(result.stdout or "", "SEARCH_PRECISION_UI_OK")
  end)
end)
