-- Diffview.nvim — PR-style review / merge UI for Git
--
-- Why: gitsigns shows hunks inline, but reviewing a whole commit / branch
-- diff / 3-way merge is painful inline. Diffview opens a dedicated tab with
-- a file panel + side-by-side editors, like the GitHub PR view.
--
-- Optional specialist: gv/gV and visual gv stay here. Default review,
-- history/ref pickers and Neogit use CodeDiff via utils.git_review.
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
      -- Keep the existing launch/notification wrapper for optional Diffview.
      {
        "<leader>gv",
        function()
          require("utils.git_async").launch({
            name = "Diffview: working tree",
            run  = function() vim.cmd("DiffviewOpen") end,
          })
        end,
        desc = "Diffview: working tree",
      },
      { "<leader>gV", "<cmd>DiffviewClose<cr>", desc = "Diffview: close" },
      {
        "<leader>gv",
        function()
          -- Visual marks describe the previous completed selection until Esc.
          local anchor, cursor = vim.fn.line("v"), vim.fn.line(".")
          local first, last = math.min(anchor, cursor), math.max(anchor, cursor)
          local win, buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
          vim.cmd.normal({ args = { vim.api.nvim_replace_termcodes("<Esc>", true, false, true) }, bang = true })
          require("utils.git_async").launch({
            name = "Diffview: selection history",
            run  = function()
              -- The deferred launcher must not interpret this range in another file.
              if vim.api.nvim_get_current_win() ~= win or vim.api.nvim_get_current_buf() ~= buf then return end
              vim.cmd(first .. "," .. last .. "DiffviewFileHistory")
            end,
          })
        end,
        desc = "Diffview: selection history",
        mode = "v",
      },
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
        file_history_panel = {
          log_options = {
            -- Show more context per entry: oneline + relative time + author.
            -- These map to git log fields; diffview composes them.
            git = {
              single_file = {
                follow = true,    -- follow renames
                all = false,
                merges = false,
              },
              multi_file = {
                all = false,
                merges = false,
              },
            },
          },
          win_config = { position = "bottom", height = 18 },
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
            -- VSCode-style: j/k navigate file list without leaving panel.
            { "n", "j", actions.next_entry, { desc = "Next file (no open)" } },
            { "n", "k", actions.prev_entry, { desc = "Prev file (no open)" } },
            -- Stash / refresh
            { "n", "R", actions.refresh_files, { desc = "Refresh files" } },
            -- Toggle staging for the selected whole file.
            { "n", "s", actions.toggle_stage_entry, { desc = "Stage / unstage file" } },
          },
          file_history_panel = {
            { "n", "q", "<cmd>DiffviewClose<cr>", { desc = "Close diffview" } },
            { "n", "<cr>", actions.select_entry, { desc = "Open commit" } },
            { "n", "j", actions.next_entry, { desc = "Next commit (no open)" } },
            { "n", "k", actions.prev_entry, { desc = "Prev commit (no open)" } },
            -- Yank commit hash for the entry under cursor.
            { "n", "y", function()
                local lib = require("diffview.lib")
                local view = lib.get_current_view()
                if not view then return end
                local entry = view:infer_cur_file()
                local hash = entry and entry.commit and entry.commit.hash
                if hash then
                  vim.fn.setreg("+", hash)
                  vim.notify("Yanked " .. hash:sub(1, 8))
                end
              end, { desc = "Yank commit hash" } },
          },
        },
      }
    end,
  },
}
