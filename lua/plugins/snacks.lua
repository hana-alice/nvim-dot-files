local function ue_picker_opts()
  local ok, ue = pcall(require, "ue")
  if not ok then
    return nil
  end
  local opts = ue.picker_options()
  if type(opts) ~= "table" or #opts.dirs == 0 then
    return nil
  end
  return opts
end

local function ue_files()
  local snacks = require("snacks")
  local opts = ue_picker_opts()
  if opts then
    return snacks.picker.files(opts)
  end
  return snacks.picker.files()
end

local function ue_git_files()
  local snacks = require("snacks")
  local opts = ue_picker_opts()
  if opts then
    return snacks.picker.files(opts)
  end
  return snacks.picker.git_files()
end

local function ue_grep()
  local snacks = require("snacks")
  local opts = ue_picker_opts()
  if opts then
    return snacks.picker.grep(opts)
  end
  return snacks.picker.grep()
end

return {
  {
    "folke/snacks.nvim",
    keys = {
      { "<leader>ff", ue_files, desc = "Find Files" },
      { "<leader>fg", ue_git_files, desc = "Find Git Files" },
      { "<leader>sg", ue_grep, desc = "Grep" },
    },
    opts = function(_, opts)
      opts = opts or {}
      opts.picker = opts.picker or {}
      opts.picker.win = opts.picker.win or {}
      opts.picker.win.input = opts.picker.win.input or {}
      opts.picker.win.list = opts.picker.win.list or {}
      opts.picker.win.input.keys = vim.tbl_deep_extend("force", opts.picker.win.input.keys or {}, {
        ["<Tab>"] = { "list_down", mode = { "i", "n" } },
        ["<S-Tab>"] = { "list_up", mode = { "i", "n" } },
        ["<C-Space>"] = { "select_and_next", mode = { "i", "n" } },
      })
      opts.picker.win.list.keys = vim.tbl_deep_extend("force", opts.picker.win.list.keys or {}, {
        ["<Tab>"] = { "list_down", mode = { "n", "x" } },
        ["<S-Tab>"] = { "list_up", mode = { "n", "x" } },
        ["<C-Space>"] = { "select_and_next", mode = { "n", "x" } },
      })
    end,
  },
}
