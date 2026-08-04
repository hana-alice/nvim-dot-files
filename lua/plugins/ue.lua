return {
  {
    "stevearc/conform.nvim",
    opts = {
      formatters_by_ft = {
        c = { "clang_format" },
        cpp = { "clang_format" },
        objc = { "clang_format" },
        objcpp = { "clang_format" },
        hlsl = { "clang_format" },
      },
    },
  },

  {
    "neovim/nvim-lspconfig",
    opts = function(_, opts)
      opts.servers = opts.servers or {}

      local clangd = opts.servers.clangd == true and {} or opts.servers.clangd or {}
      local function definition_fallback()
        require("utils.lsp_fallback").definition()
      end
      clangd = vim.tbl_deep_extend("force", clangd, {
        mason = false,
        cmd = require("ue").clangd_cmd(),
        on_new_config = function(new_config, root_dir)
          new_config.cmd = require("ue").clangd_cmd(root_dir)
        end,
        root_dir = function(bufnr, on_dir)
          on_dir(require("ue").clangd_root(bufnr))
        end,
        keys = {
          {
            "gd",
            definition_fallback,
            desc = "Definition (LSP -> GTAGS)",
            nowait = true,
          },
          {
            "gr",
            function()
              require("utils.lsp_fallback").references()
            end,
            desc = "References (LSP -> GTAGS)",
            nowait = true,
          },
          {
            "<leader>ch",
            "<cmd>LspClangdSwitchSourceHeader<cr>",
            desc = "Switch Source/Header (UE)",
          },
        },
      })

     opts.servers.clangd = clangd
     return opts
   end,
  },
}
