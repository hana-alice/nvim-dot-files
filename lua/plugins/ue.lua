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
      local inherited_on_attach = clangd.on_attach
      local function definition_fallback()
        require("utils.lsp_fallback").definition()
      end
      clangd = vim.tbl_deep_extend("force", clangd, {
        mason = false,
        -- Native vim.lsp resolves root_dir before invoking a cmd factory.
        -- nvim-lspconfig's legacy on_new_config hook is not available on this
        -- path, so build the project-scoped CDB argv from the resolved config.
        cmd = function(dispatchers, config)
          local resolved_cmd = require("ue").clangd_cmd(config.root_dir)
          config._ue_resolved_cmd = resolved_cmd
          return vim.lsp.rpc.start(resolved_cmd, dispatchers, {
            cwd = config.cmd_cwd,
            env = config.cmd_env,
            detached = config.detached,
          })
        end,
        root_dir = function(bufnr, on_dir)
          on_dir(require("ue").clangd_root(bufnr))
        end,
        on_attach = function(client, bufnr)
          if type(inherited_on_attach) == "function" then
            inherited_on_attach(client, bufnr)
          end
          require("ue.clangd_commands").ensure(client, bufnr)
        end,
        keys = {
          {
            "gd",
            definition_fallback,
            desc = "Definition (contextual C++ / LSP fallback)",
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
      clangd.on_new_config = nil

     opts.servers.clangd = clangd
     return opts
   end,
  },
}
