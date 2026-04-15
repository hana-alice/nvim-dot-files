return {
  {
    "lewis6991/gitsigns.nvim",
    opts = function(_, opts)
      opts = opts or {}
     opts.diff_opts = vim.tbl_deep_extend("force", opts.diff_opts or {}, {
       ignore_whitespace_change_at_eol = true,
     })
     return opts
   end,
  },
}
