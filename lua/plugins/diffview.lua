-- Diffview.nvim — PR-style review / merge UI for Git
--
-- Why: gitsigns shows hunks inline, but reviewing a whole commit / branch
-- diff / 3-way merge is painful inline. Diffview opens a dedicated tab with
-- a file panel + side-by-side editors, like the GitHub PR view.
--
-- Keymap policy (user rule): all git keys live under <leader>g, single-level only.
-- LazyVim already occupies: gb gB gc gd gD ge gf gg gG gh* gi gI gl gL go gp gP
--                           gr gs gS gY
-- Free letters used here:   gv gV gm gM gn
--
-- Companion plugins:
--   * fugitive.lua          — :Gedit :0, :Git blame, :Gclog (commit→qf)
--   * advanced_git_search   — content/branch/commit pickers (telescope)
--   * gitsigns              — inline hunks + GitLens-style blame virt text
--   * neogit                — full status panel (<leader>gn)
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
      -- All git keymaps go through utils.git_async.launch so the UI
      -- never blocks while diffview spins up + git log/diff runs.
      -- See lua/utils/git_async.lua for the contract.
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
        "<leader>gm",
        function()
          require("utils.git_async").launch({
            name = "Diffview: this file history",
            run  = function() vim.cmd("DiffviewFileHistory %") end,
          })
        end,
        desc = "Diffview: this file history",
      },
      {
        "<leader>gM",
        function()
          require("utils.git_async").launch({
            name = "Diffview: branch history",
            run  = function() vim.cmd("DiffviewFileHistory") end,
          })
        end,
        desc = "Diffview: branch history",
      },
      {
        "<leader>gv",
        function()
          require("utils.git_async").launch({
            name = "Diffview: selection history",
            run  = function() vim.cmd("'<,'>DiffviewFileHistory") end,
          })
        end,
        desc = "Diffview: selection history",
        mode = "v",
      },
      -- Range / arbitrary refs. Prompt is synchronous (user input);
      -- the actual diff dispatch goes through git_async.
      {
        "<leader>gr",
        function()
          require("utils.git_async").prompt_cmd(
            "Diffview range",
            "Diffview range (e.g. main..HEAD or HEAD~3..HEAD): ",
            "HEAD~1..HEAD",
            function(input) return "DiffviewOpen " .. input end
          )()
        end,
        desc = "Diffview: arbitrary range",
      },
      {
        "<leader>gk",
        function()
          require("utils.git_async").prompt_cmd(
            "Diffview commit",
            "Diffview single commit (rev): ",
            "HEAD",
            function(input) return "DiffviewOpen " .. input .. "^!" end
          )()
        end,
        desc = "Diffview: single commit",
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
            -- Toggle stage hunk on selected file (replicates Neogit's `s`).
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
