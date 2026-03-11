return {
  {
    "folke/snacks.nvim",
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
