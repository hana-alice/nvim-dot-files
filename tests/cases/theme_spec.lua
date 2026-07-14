-- Theme registry + local colorscheme contracts.

local t = require("tests.harness")
t.bootstrap()

local function hl(name)
  local ok, value = pcall(vim.api.nvim_get_hl, 0, { name = name })
  if ok then
    return value
  end
  return {}
end

t.describe("theme: porcelain white", function()
  t.it("is listed in :Theme completion", function()
    t.assert_contains(require("theme").complete(), "porcelain-white")
  end)

  t.it("plugin init owns the <leader>ut keymap", function()
    local source = table.concat(vim.fn.readfile(vim.fn.stdpath("config") .. "/lua/plugins/colorscheme.lua"), "\n")
    t.assert_contains(source, 'vim.keymap.set("n", "<leader>ut"')
    t.assert_contains(source, "ThemePicker")
    t.assert_contains(source, "nowait = true")
  end)

  t.it("loads as a pure white, non-beige light colorscheme", function()
    local ok = require("theme").apply("white", { persist = false, silent = true })
    t.assert_true(ok, "white alias should apply porcelain-white")
    t.assert_eq(vim.g.colors_name, "porcelain-white")
    t.assert_eq(vim.o.background, "light")

    t.assert_eq(hl("Normal").bg, 0xFFFFFF, "Normal background must be pure white")
    t.assert_eq(hl("CursorLine").bg, 0xEEF4FF, "CursorLine should be cool blue-white")
    t.assert_eq(hl("Function").fg, 0x0550AE, "Function color should be crisp blue")
    t.assert_eq(hl("String").fg, 0x116329, "String color should stay readable on white")
  end)
end)
