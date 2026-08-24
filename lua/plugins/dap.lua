return {
  {
    "mfussenegger/nvim-dap",
    lazy = true,
    dependencies = {
      "rcarriga/nvim-dap-ui",
      "nvim-neotest/nvim-nio",
    },
    config = function()
      local log_isolation = require("workarounds.dap.pid_scoped_logs")
      local ok_logs, log_err = log_isolation.apply(true)
      assert(ok_logs, "failed to isolate nvim-dap logs: " .. tostring(log_err))
      local dap = require("dap")
      local dapui = require("dapui")
      dapui.setup({
        force_buffers = false,
        -- In stacks panel, <CR> / double-click should jump to frame (open),
        -- not try to expand (which frames don't support).
        element_mappings = {
          stacks = {
            open = { "<CR>", "<2-LeftMouse>", "o" },
            expand = "e",
          },
        },
        layouts = {
          {
            -- Left debug rail: locals, call stack, watches.
            elements = {
              { id = "scopes", size = 0.45 },
              { id = "stacks", size = 0.25 },
              { id = "watches", size = 0.30 },
            },
            position = "left",
            size = 54,
          },
        },
        controls = {
          -- Keep the clickable debug controls visible, but attach them to the
          -- left rail so they do not overwrite the right-bottom tab bar.
          enabled = true,
          element = "scopes",
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
