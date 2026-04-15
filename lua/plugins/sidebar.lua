return {
  {
    "folke/trouble.nvim",
    opts = function(_, opts)
      opts = opts or {}
      local function sidebar_mode(mode)
        mode.focus = true
        mode.warn_no_results = false
        mode.open_no_results = true
        mode.win = vim.tbl_deep_extend("force", { position = "left", size = 40 }, mode.win or {})
        return mode
      end

      opts.modes = vim.tbl_deep_extend("force", opts.modes or {}, {
        ue_sidebar_git_status = sidebar_mode({
          desc = "Sidebar git status",
          source = "ue_sidebar.git_status",
          format = "{text}",
        }),
        ue_sidebar_buffers = sidebar_mode({
          desc = "Sidebar buffers",
          source = "ue_sidebar.buffers",
          format = "{text}",
        }),
        ue_sidebar_symbols = sidebar_mode({
          desc = "Sidebar symbols",
          mode = "symbols",
        }),
        ue_sidebar_diagnostics = sidebar_mode({
          desc = "Sidebar diagnostics",
          mode = "diagnostics",
        }),
        ue_sidebar_qflist = sidebar_mode({
          desc = "Sidebar quickfix",
          mode = "qflist",
        }),
        ue_sidebar_loclist = sidebar_mode({
          desc = "Sidebar location list",
          mode = "loclist",
        }),
        ue_sidebar_todo = sidebar_mode({
          desc = "Sidebar todo",
          source = "ue_sidebar.todo",
          sort = { "filename", "pos" },
          format = "{text}",
        }),
     })
     return opts
   end,
 },
 {
   "folke/which-key.nvim",
   opts = function(_, opts)
     opts = opts or {}
     opts.spec = opts.spec or {}
     vim.list_extend(opts.spec, {
       { "<leader>v", group = "sidebar" },
     })
     return opts
   end,
  },
}
