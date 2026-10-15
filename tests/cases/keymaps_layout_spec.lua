local t = require("tests.harness")
local cfg = t.bootstrap()
vim.g.mapleader, vim.g.maplocalleader = " ", " "
require("ue").setup()
dofile(cfg .. "/lua/config/keymaps.lua")

local bindings = {
  { "wN", "UELayout normal" }, { "wR", "UELayout review" }, { "wD", "UELayout debug" },
  { "wL", "UELayout" }, { "wB", "UELayoutRestore" }, { "wV", "UEView" },
  { "wC", "UEView code" }, { "wP", "UEView panel" }, { "w[", "UELayoutBack" },
}

t.describe("keymaps: explicit layout management", function()
  for _, binding in ipairs(bindings) do
    t.it(binding[1] .. " resolves to " .. binding[2], function()
      local map = vim.fn.maparg("<leader>" .. binding[1], "n", false, true)
      t.assert_eq(map.rhs, "<cmd>" .. binding[2] .. "<cr>")
    end)
  end

  t.it("layout commands register idempotently with argument completion", function()
    require("utils.layout_commands").setup()
    require("utils.layout_commands").setup()
    local commands = vim.api.nvim_get_commands({ builtin = false })
    for _, name in ipairs({ "UELayout", "UELayoutRestore", "UELayoutBack", "UEView" }) do
      t.assert_true(commands[name] ~= nil, name)
    end
    t.assert_eq(commands.UELayout.nargs, "?")
    t.assert_eq(commands.UEView.nargs, "?")
    t.assert_eq(table.concat(vim.fn.getcompletion("UELayout ", "cmdline"), ","), "normal,review,debug")
    t.assert_eq(table.concat(vim.fn.getcompletion("UEView ", "cmdline"), ","), "code,panel")
  end)

  t.it("normal-mode input reaches view APIs without altering dirty text", function()
    local layout = require("utils.layout")
    local originals, calls = {}, {}
    for _, name in ipairs({ "switch", "restore_group", "back", "list_groups", "list_views" }) do
      originals[name] = layout[name]
      layout[name] = function(arg)
        calls[#calls + 1] = { name, arg }
        if name == "list_groups" or name == "list_views" then return {} end
        return vim.api.nvim_get_current_win()
      end
    end
    local original_notify = vim.notify
    vim.notify = function() end
    local buf = vim.api.nvim_get_current_buf()
    local old_lines, old_modified = vim.api.nvim_buf_get_lines(buf, 0, -1, false), vim.bo[buf].modified
    local ok, err = pcall(function()
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "layout mapping keeps unsaved text" })
      vim.bo[buf].modified = true
      local tick = vim.api.nvim_buf_get_changedtick(buf)
      local expected = {
        { "switch", "normal" }, { "switch", "review" }, { "switch", "debug" },
        { "list_groups" }, { "restore_group" }, { "list_views" },
        { "list_views", "code" }, { "list_views", "panel" }, { "back" },
      }
      for i, binding in ipairs(bindings) do
        vim.api.nvim_feedkeys(" " .. binding[1], "mx", false)
        t.assert_eq(calls[i][1], expected[i][1], binding[1])
        t.assert_eq(calls[i][2], expected[i][2], binding[1])
      end
      t.assert_eq(#calls, #bindings)
      t.assert_eq(vim.api.nvim_get_current_buf(), buf)
      t.assert_eq(vim.api.nvim_buf_get_changedtick(buf), tick)
      t.assert_true(vim.bo[buf].modified)
    end)
    for name, fn in pairs(originals) do layout[name] = fn end
    vim.notify = original_notify
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, old_lines)
    vim.bo[buf].modified = old_modified
    t.assert_true(ok, tostring(err))
  end)

  t.it("existing debug, workspace and native window navigation remain", function()
    t.assert_eq(vim.fn.maparg("<leader>du", "n", false, true).rhs, "<cmd>UEDAPToggleUI<cr>")
    t.assert_eq(vim.fn.maparg("<leader>wM", "n", false, true).rhs, "<cmd>UEWorkspace<cr>")
    for _, key in ipairs({ "<C-w>h", "<C-w>j", "<C-w>k", "<C-w>l" }) do
      t.assert_eq(vim.fn.maparg(key, "n"), "", key .. " must use native navigation")
    end
  end)
end)
