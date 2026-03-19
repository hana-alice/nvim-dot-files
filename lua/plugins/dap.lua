return {
  {
    "mfussenegger/nvim-dap",
    dependencies = {
      "rcarriga/nvim-dap-ui",
      "nvim-neotest/nvim-nio",
    },
    config = function()
      local dap = require("dap")
      local dapui = require("dapui")
      dapui.setup({
        layouts = {
          {
            -- Right panel: variables & watches (widest, most-used)
            elements = {
              { id = "scopes", size = 0.7 },
              { id = "watches", size = 0.3 },
            },
            position = "right",
            size = 60,
          },
          {
            -- Left panel: call stack & breakpoints (navigation context)
            elements = {
              { id = "stacks", size = 0.6 },
              { id = "breakpoints", size = 0.4 },
            },
            position = "left",
            size = 40,
          },
          {
            -- Bottom: REPL + console
            elements = {
              { id = "repl", size = 0.65 },
              { id = "console", size = 0.35 },
            },
            position = "bottom",
            size = 12,
          },
        },
        controls = {
          enabled = true,
          element = "repl",
          icons = {
            pause = "⏸ ",
            play = "▶ ",
            step_into = "⇣ ",
            step_over = "⇥ ",
            step_out = "⇡ ",
            step_back = "⇠ ",
            run_last = "↻ ",
            terminate = "■ ",
            disconnect = "⏏ ",
          },
        },
        icons = {
          expanded = "▾",
          collapsed = "▸",
          current_frame = "→",
        },
        floating = {
          max_height = 0.8,
          max_width = 0.8,
          border = "rounded",
          mappings = {
            ["close"] = { "q", "<Esc>" },
          },
        },
        -- Don't auto-expand lines (crashes LLDB on huge UE binaries)
        expand_lines = false,
        render = {
          -- Truncate long values to keep the panel readable
          max_value_lines = 5,
          max_type_length = 40,
          indent = 2,
        },
      })
      require("ue").setup_dap(dap, dapui)
    end,
  },
}
