return {
  -- LazyVim declares Tokyo Night upstream; disable it so the local theme
  -- surface is limited to the entries owned by lua/theme.lua.
  { "folke/tokyonight.nvim", enabled = false },
  {
    "tanvirtin/monokai.nvim",
    lazy = true,
    priority = 1000,
  },
  {
    "sainnhe/sonokai",
    name = "sonokai",
    lazy = true,
    priority = 1000,
    init = function()
      vim.g.sonokai_style = "espresso"
      vim.g.sonokai_better_performance = 0
    end,
  },
  {
    "LazyVim/LazyVim",
    init = function()
      require("highlights").setup()

      vim.api.nvim_create_user_command("ThemePicker", function()
        require("theme").select()
      end, { desc = "Select colorscheme" })

      for _, lhs in ipairs({ "<leader>ut", "<leader>uC" }) do
        vim.keymap.set("n", lhs, "<cmd>ThemePicker<cr>", {
          desc = "UI: Theme picker",
          nowait = true,
        })
      end

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
