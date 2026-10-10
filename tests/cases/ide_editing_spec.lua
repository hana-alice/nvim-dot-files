local t = require("tests.harness")
local cfg = t.bootstrap()

t.describe("ide_editing: audited UE snippets", function()
  t.it("registers UE snippets alongside ordinary C++ and excludes unaudited legacy templates", function()
    local lazyvim = _G.LazyVim
    _G.LazyVim = { cmp = {
      map = function(value)
        return value
      end,
    } }
    local spec = dofile(cfg .. "/lua/plugins/blink.lua")[1]
    local options = spec.opts(nil, {})
    _G.LazyVim = lazyvim
    local snippet_opts = options.sources.providers.snippets.opts
    t.assert_true(vim.tbl_contains(snippet_opts.extended_filetypes.cpp, "unreal"))
    t.assert_true(snippet_opts.filter_snippets("cpp", "friendly-snippets/snippets/cpp.json"))
    t.assert_false(snippet_opts.filter_snippets("unreal", "friendly-snippets/snippets/frameworks/unreal.json"))
    t.assert_true(snippet_opts.filter_snippets("unreal", cfg .. "/snippets/unreal.json"))
    local definitions = vim.json.decode(table.concat(vim.fn.readfile(cfg .. "/snippets/unreal.json"), "\n"))
    t.assert_true(vim.tbl_count(definitions) >= 8)
    local all = vim.json.encode(definitions)
    t.assert_false(all:find("GENERATED_USTRUCT_BODY", 1, true) ~= nil)
    t.assert_false(all:find("WithValidation", 1, true) ~= nil)
  end)

  t.it("native snippet expansion preserves fields and undo restores the original text", function()
    local definitions = vim.json.decode(table.concat(vim.fn.readfile(cfg .. "/snippets/unreal.json"), "\n"))
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "" })
    -- Close the previous undo block before expanding the user's next action.
    vim.bo[buf].undolevels = vim.bo[buf].undolevels
    vim.snippet.expand(definitions["UE property"].body)
    t.assert_contains(vim.api.nvim_buf_get_lines(buf, 0, -1, false)[1], "UPROPERTY(")
    t.assert_true(vim.snippet.active({ direction = 1 }))
    vim.snippet.jump(1)
    vim.snippet.stop()
    vim.cmd("undo")
    t.assert_eq(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"), "")
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
  t.it("log snippet expands with a usable default verbosity on native Neovim", function()
    local definitions = vim.json.decode(table.concat(vim.fn.readfile(cfg .. "/snippets/unreal.json"), "\n"))
    local original = vim.api.nvim_get_current_buf()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(buf)
    vim.snippet.expand(definitions["UE log"].body)
    local text = vim.api.nvim_buf_get_lines(buf, 0, -1, false)[1]
    vim.snippet.stop()
    vim.api.nvim_set_current_buf(original)
    vim.api.nvim_buf_delete(buf, { force = true })
    t.assert_eq(text, 'UE_LOG(LogTemp, Log, TEXT("Message"));')
  end)
end)
