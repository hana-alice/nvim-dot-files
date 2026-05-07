-- vim-fugitive — the elder statesman of nvim git plugins
--
-- Why we have it on top of diffview/neogit/gitsigns:
--   * `:Gedit :0` / `:Gedit HEAD~3:%` — open a *past* version of the
--     current file in a buffer. diffview can't do this; it only shows
--     diffs side-by-side.
--   * `:Git blame` — full-file scrollable blame view (gitsigns only
--     gives one-line popups). Press `o` on any line to preview that
--     commit, `<cr>` to open it.
--   * `:Gclog` / `:0Gclog` — populate quickfix with commits affecting
--     the file or selection. Faster than diffview for "find the commit
--     that introduced this line".
--   * `:Gvdiffsplit HEAD~2` — quick two-pane diff against arbitrary ref
--     without the diffview tab ceremony.
--
-- Loaded lazily on commands. Doesn't fight with neogit (different UX:
-- neogit is a status panel, fugitive is a command-line surface).
return {
  {
    "tpope/vim-fugitive",
    cmd = {
      "G",
      "Git",
      "Gedit",
      "Gsplit",
      "Gvsplit",
      "Gtabedit",
      "Gread",
      "Gwrite",
      "Gdiff",
      "Gdiffsplit",
      "Gvdiffsplit",
      "Gclog",
      "Glgrep",
      "Ggrep",
      "GBrowse",
      "GMove",
      "GRename",
      "GDelete",
      "GRemove",
    },
    keys = {
      -- All wrapped in git_async.launch so the first invocation
      -- (which lazy-loads fugitive + spawns git) doesn't freeze the UI.
      {
        "<leader>g0",
        function()
          require("utils.git_async").launch({
            name = "Fugitive: open :0 (staged)",
            run  = function() vim.cmd("Gedit :0") end,
          })
        end,
        desc = "Fugitive: open staged version of file",
      },
      {
        "<leader>gB",
        function()
          require("utils.git_async").launch({
            name = "Fugitive: full-file blame",
            run  = function() vim.cmd("Git blame") end,
          })
        end,
        desc = "Fugitive: full-file blame view",
      },
      {
        "<leader>gl",
        function()
          require("utils.git_async").launch({
            name = "Fugitive: this file commits → qf",
            run  = function() vim.cmd("0Gclog") end,
          })
        end,
        desc = "Fugitive: commits touching this file (qf)",
      },
      {
        "<leader>gL",
        function()
          require("utils.git_async").launch({
            name = "Fugitive: all commits → qf",
            run  = function() vim.cmd("Gclog") end,
          })
        end,
        desc = "Fugitive: all commits (qf)",
      },
    },
  },

  -- Snacks picker for commits, branches, reflog, etc.
  -- Everything it surfaces opens the diff in *diffview* (already
  -- installed), so the visual layer stays consistent.
  --
  -- IMPORTANT: this plugin's setup entrypoint is per-picker-backend
  -- (`advanced_git_search.snacks` / `.telescope` / `.fzf`), NOT a
  -- generic `advanced_git_search.setup`. We use snacks since it's
  -- already the rest of this config's picker backend.
  {
    "aaronhallaert/advanced-git-search.nvim",
    cmd = { "AdvancedGitSearch" },
    dependencies = {
      "sindrets/diffview.nvim",
      "tpope/vim-fugitive",
      "folke/snacks.nvim",
    },
    keys = {
      {
        "<leader>gh",
        function()
          require("utils.git_async").launch({
            name = "Git: search commits by content",
            run  = function() vim.cmd("AdvancedGitSearch search_log_content") end,
          })
        end,
        desc = "Git: search commits by content",
      },
      {
        "<leader>gH",
        function()
          require("utils.git_async").launch({
            name = "Git: search commits by content (this file)",
            run  = function() vim.cmd("AdvancedGitSearch search_log_content_file") end,
          })
        end,
        desc = "Git: search commits by content (this file)",
      },
      {
        "<leader>gx",
        function()
          require("utils.git_async").launch({
            name = "Git: diff this file vs branch",
            run  = function() vim.cmd("AdvancedGitSearch diff_branch_file") end,
          })
        end,
        desc = "Git: diff this file against branch",
      },
      {
        "<leader>gX",
        function()
          require("utils.git_async").launch({
            name = "Git: diff this file vs commit",
            run  = function() vim.cmd("AdvancedGitSearch diff_commit_file") end,
          })
        end,
        desc = "Git: diff this file against commit",
      },
      {
        "<leader>gC",
        function()
          require("utils.git_async").launch({
            name = "Git: checkout from reflog",
            run  = function() vim.cmd("AdvancedGitSearch checkout_reflog") end,
          })
        end,
        desc = "Git: checkout from reflog",
      },
      {
        "<leader>gA",
        function()
          require("utils.git_async").launch({
            name = "Git: advanced search palette",
            run  = function() vim.cmd("AdvancedGitSearch") end,
          })
        end,
        desc = "Git: advanced search (all actions)",
      },
    },
    opts = {
      diff_plugin = "diffview",
      git_flags = {},
      git_diff_flags = {},
      show_builtin_git_pickers = false,
      entry_default_author_or_date = "author",
      keymaps = {
        toggle_date_author = "<C-w>",
        open_commit_in_browser = "<C-o>",
        copy_commit_hash = "<C-y>",
        show_entire_commit = "<C-e>",
      },
    },
    config = function(_, opts)
      require("advanced_git_search.snacks").setup(opts)
    end,
  },
}
