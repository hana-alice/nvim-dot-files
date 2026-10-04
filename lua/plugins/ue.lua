return {
  {
    "stevearc/conform.nvim",
    opts = {
      formatters_by_ft = {
        c = { "clang_format", lsp_format = "never" },
        cpp = { "clang_format", lsp_format = "never" },
        objc = { "clang_format", lsp_format = "never" },
        objcpp = { "clang_format", lsp_format = "never" },
        hlsl = { "clang_format" },
      },
      formatters = {
        clang_format = {
          command = function() return require("utils.cpp_format").command() end,
          prepend_args = function(_, ctx)
            return require("utils.cpp_format").is_cpp(ctx.buf)
              and { "--style=file", "--fallback-style=none" } or {}
          end,
          condition = function(_, ctx)
            return not require("utils.cpp_format").is_cpp(ctx.buf)
              or require("utils.cpp_format").find_config(ctx.buf) ~= nil
          end,
        },
        ue_epic = {
          inherit = "clang_format",
          command = function() return require("utils.cpp_format").command() end,
          condition = function() return true end,
          prepend_args = function()
            return { "--style=file:" .. require("utils.cpp_format").template, "--fallback-style=none" }
          end,
        },
      },
    },
  },

  {
    "neovim/nvim-lspconfig",
    opts = function(_, opts)
      opts.servers = opts.servers or {}
      -- Measured on a 6007-line fixture with a real clangd and external UI.
      -- Keep LazyVim's buffer-local <leader>uh toggle and bigfile guard.
      opts.inlay_hints = vim.tbl_deep_extend("force", opts.inlay_hints or {}, { enabled = true })

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
          config.cmd_cwd = config.cmd_cwd or (vim.uv or vim.loop).cwd()
          config._ue_spawn_cwd = config.cmd_cwd
          local resolved_cmd = require("ue.index.batch_runtime").configure_process(
            require("ue").clangd_cmd(config.root_dir), config)
          config._ue_resolved_cmd = resolved_cmd
          local rpc = vim.lsp.rpc.start(resolved_cmd, dispatchers, {
            cwd = config.cmd_cwd,
            env = config._ue_batch_spawn_env or config.cmd_env,
            detached = config.detached,
          })
          -- Public RPC hides vim.SystemObj.pid. Bounded async discovery proves
          -- direct-child ownership; failure never blocks the returned RPC.
          pcall(function()
            require("utils.clangd_resource_controller").discover_with_retry(resolved_cmd[1])
          end)
          return rpc
        end,
        root_dir = function(bufnr, on_dir)
          local root = require("ue").clangd_start_root(bufnr)
          if root then
            require("ue.index.batch_recovery").prepare(bufnr, root, on_dir, {
              get_config = function()
                local registered = type(vim.lsp.config) == "table" and vim.lsp.config.clangd
                return type(registered) == "table" and registered or clangd
              end,
            })
          end
        end,
        on_attach = function(client, bufnr)
          if type(inherited_on_attach) == "function" then
            inherited_on_attach(client, bufnr)
          end
          require("ue.clangd_commands").ensure(client, bufnr)
          require("ue.index.batch_recovery").attach(client, bufnr)
        end,
        keys = {
          { "<leader>cI", function() require("snacks").picker.lsp_incoming_calls() end,
            desc = "Incoming calls (谁调用了它)", has = "prepareCallHierarchy" },
          { "<leader>cO", function() require("snacks").picker.lsp_outgoing_calls() end,
            desc = "Outgoing calls (它调用了谁)", has = "prepareCallHierarchy" },
          { "<leader>ss", function() require("snacks").picker.lsp_symbols({ tree = true }) end,
            desc = "Document symbols (当前文件大纲)", has = "documentSymbol" },
          { "<leader>sS", function() require("snacks").picker.lsp_workspace_symbols({ live = true }) end,
            desc = "Workspace symbols (类 / 函数)", has = "workspace/symbol" },
          { "<leader>cB", function() require("utils.ue_goto.type_hierarchy").open("supertypes") end,
            desc = "Type hierarchy: base types (基类)", has = "prepareTypeHierarchy" },
          { "<leader>cD", function() require("utils.ue_goto.type_hierarchy").open("subtypes") end,
            desc = "Type hierarchy: derived types (派生类)", has = "prepareTypeHierarchy" },
          { "<leader>cr", function() require("utils.lsp_fallback").rename() end,
            desc = "Rename symbol (preview)", has = "rename" },
          { "<leader>ca", function() require("utils.lsp_fallback").code_actions() end,
            desc = "Code action (server / preview)", mode = { "n", "x" }, has = "codeAction" },
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
