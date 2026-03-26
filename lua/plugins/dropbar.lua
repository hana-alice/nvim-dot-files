return {
  {
    "Bekaboo/dropbar.nvim",
    enabled = false,
  },
  {
    "nvim-treesitter/nvim-treesitter-context",
    event = "BufReadPost",
    opts = {
      max_lines = 3,
      min_window_height = 20,
      mode = "cursor",
    },
    keys = {
      {
        "[c",
        function() require("treesitter-context").go_to_context(vim.v.count1) end,
        desc = "Jump to context",
        silent = true,
      },
    },
  },
}
