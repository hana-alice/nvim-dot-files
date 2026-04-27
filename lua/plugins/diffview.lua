-- Diffview.nvim — PR-style review / merge UI for Git
--
-- Why: gitsigns shows hunks inline, but reviewing a whole commit / branch
-- diff / 3-way merge is painful inline. Diffview opens a dedicated tab with
-- a file panel + side-by-side editors, like the GitHub PR view.
--
-- Keymap prefix: <leader>gv  (g = git, v = view/diffview)
--   Avoids existing <leader>gd (gitsigns hunk diff) and <leader>gh (LazyVim
--   git submenu). All <leader>gv* are free as of nvim/docs/ue_lazyvim_cheatsheet.md.
return {
  {
    "sindrets/diffview.nvim",
    cmd = {
      "DiffviewOpen",
      "DiffviewClose",
      "DiffviewFileHistory",
      "DiffviewToggleFiles",
      "DiffviewFocusFiles",
      "DiffviewRefresh",
    },
    keys = {
      { "<leader>gv", "<cmd>DiffviewOpen<cr>", desc = "Diffview: working tree" },
      { "<leader>gV", "<cmd>DiffviewClose<cr>", desc = "Diffview: close" },
      { "<leader>gvf", "<cmd>DiffviewFileHistory %<cr>", desc = "Diffview: this file history" },
      { "<leader>gvb", "<cmd>DiffviewFileHistory<cr>", desc = "Diffview: branch history" },
      { "<leader>gvc", "<cmd>DiffviewOpen HEAD~1<cr>", desc = "Diffview: last commit" },
      { "<leader>gvm", "<cmd>DiffviewOpen origin/HEAD...HEAD<cr>", desc = "Diffview: vs origin/HEAD" },
    },
    opts = function()
      local actions = require("diffview.actions")
      return {
        enhanced_diff_hl = true, -- richer color contrast
        use_icons = true,
        view = {
          default = { layout = "diff2_horizontal" },
          merge_tool = {
            layout = "diff3_mixed",
            disable_diagnostics = true,
          },
          file_history = { layout = "diff2_horizontal" },
        },
        file_panel = {
          listing_style = "tree",
          tree_options = { flatten_dirs = true, folder_statuses = "only_folded" },
          win_config = { position = "left", width = 38 },
        },
        keymaps = {
          view = {
            { "n", "q", "<cmd>DiffviewClose<cr>", { desc = "Close diffview" } },
            { "n", "<tab>", actions.select_next_entry, { desc = "Next file" } },
            { "n", "<s-tab>", actions.select_prev_entry, { desc = "Prev file" } },
            -- ] c / [ c stay vim-native (next/prev hunk WITHIN the current file).
            -- ] h / [ h cross file boundary: when at the last hunk of a file,
            -- jump to the first hunk of the next file automatically.
            { "n", "]h", function()
                local prev_line = vim.fn.line(".")
                vim.cmd("normal! ]c")
                if vim.fn.line(".") == prev_line then
                  -- already at last hunk → advance to next file
                  actions.select_next_entry()
                  vim.schedule(function()
                    vim.cmd("normal! gg")
                    pcall(vim.cmd, "normal! ]c")
                  end)
                end
              end, { desc = "Next change (cross file)" } },
            { "n", "[h", function()
                local prev_line = vim.fn.line(".")
                vim.cmd("normal! [c")
                if vim.fn.line(".") == prev_line then
                  actions.select_prev_entry()
                  vim.schedule(function()
                    vim.cmd("normal! G")
                    pcall(vim.cmd, "normal! [c")
                  end)
                end
              end, { desc = "Prev change (cross file)" } },
            -- ] x / [ x conflicts (merge-tool only — no-op outside merge view)
            { "n", "]x", actions.next_conflict, { desc = "Next conflict" } },
            { "n", "[x", actions.prev_conflict, { desc = "Prev conflict" } },
          },
          file_panel = {
            { "n", "q", "<cmd>DiffviewClose<cr>", { desc = "Close diffview" } },
            { "n", "<tab>", actions.select_next_entry, { desc = "Next file" } },
            { "n", "<s-tab>", actions.select_prev_entry, { desc = "Prev file" } },
            { "n", "<cr>", actions.select_entry, { desc = "Open file" } },
            -- j/k → next_entry/prev_entry already defaults from diffview/config.lua
          },
          file_history_panel = {
            { "n", "q", "<cmd>DiffviewClose<cr>", { desc = "Close diffview" } },
            { "n", "<cr>", actions.select_entry, { desc = "Open commit" } },
          },
        },
      }
    end,
  },
}
