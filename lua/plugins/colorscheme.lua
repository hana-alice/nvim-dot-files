return {
  { "folke/tokyonight.nvim", lazy = true, priority = 1000 },
  {
    "rebelot/kanagawa.nvim",
    lazy = true,
    priority = 1000,
    opts = function(_, opts)
      opts = opts or {}
      opts.theme = "dragon"
      opts.background = vim.tbl_extend("force", opts.background or {}, {
        dark = "dragon",
      })
      return opts
    end,
  },
  {
    "tanvirtin/monokai.nvim",
    lazy = true,
    priority = 1000,
  },
  {
    "LazyVim/LazyVim",
    init = function()
      require("highlights").setup()

      vim.api.nvim_create_user_command("ThemePicker", function()
        require("theme").select()
      end, { desc = "Select colorscheme" })

      vim.api.nvim_create_user_command("Theme", function(opts)
        if opts.args == "" then
          require("theme").select()
          return
        end
        require("theme").apply(opts.args)
      end, {
        nargs = "?",
        complete = function()
          return require("theme").complete()
        end,
        desc = "Select or set colorscheme",
      })
    end,
    opts = function(_, opts)
     opts.colorscheme = function()
       require("theme").load_startup()
     end
     return opts
   end,
  },
}
