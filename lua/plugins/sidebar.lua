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
        -- Bottom-pinned tree-grouped quickfix view, used by the picker
        -- "<C-q> pin" action. NOT routed through sidebar_mode() because
        -- it must NOT open in the left sidebar — it lives at the bottom
        -- as a horizontal split, grouped-by-file (trouble's default
        -- qflist mode is already tree-shaped).
        ue_qflist_bottom = {
          desc = "Bottom quickfix tree (pinned picker results)",
          mode = "qflist",
          focus = true,
          warn_no_results = false,
          open_no_results = true,
          win = {
            position = "bottom",
            size = { height = 12 },
          },
        },
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
