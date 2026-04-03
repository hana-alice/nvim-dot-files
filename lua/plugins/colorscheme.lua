return {
  { "folke/tokyonight.nvim", lazy = true, priority = 1000 },
  { "catppuccin/nvim", name = "catppuccin", lazy = true, priority = 1000 },
  { "ellisonleao/gruvbox.nvim", name = "gruvbox", lazy = true, priority = 1000 },
  { "rebelot/kanagawa.nvim", name = "kanagawa", lazy = true, priority = 1000 },
  {
    "ribru17/bamboo.nvim",
    name = "bamboo",
    lazy = true,
    priority = 1000,
    opts = {},
    config = function(_, opts)
      require("bamboo").setup(opts)
    end,
  },
  {
    "olimorris/onedarkpro.nvim",
    lazy = true,
    priority = 1000,
  },
  { "savq/melange-nvim", name = "melange", lazy = true, priority = 1000 },
  { "everviolet/nvim", name = "Evergarden", lazy = true, priority = 1000 },
  { "projekt0n/github-nvim-theme", lazy = true, priority = 1000 },
  { "rose-pine/neovim", name = "rose-pine", lazy = true, priority = 1000 },
  { "EdenEast/nightfox.nvim", lazy = true, priority = 1000 },
  { "Mofiqul/vscode.nvim", lazy = true, priority = 1000 },
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
    end,
  },
}
