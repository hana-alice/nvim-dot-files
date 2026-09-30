return {
  {
    "esmuellert/codediff.nvim",
    commit = "09d9ebef2cc5a5c04db7a349cd6c61bdf84ecc8e", -- v4.0.6
    cmd = "CodeDiff",
    dependencies = { "nvim-mini/mini.icons" },
    build = function(plugin)
      -- Lazy's explicit install/build step owns downloads; view opening does not.
      vim.opt.rtp:append(plugin.dir)
      local ok, err = require("codediff.core.installer.libvscode_diff").install({ force = true })
      assert(ok, err)
    end,
    init = function()
      vim.env.VSCODE_DIFF_NO_AUTO_INSTALL = "1"
      vim.env.CODEDIFF_WATCHER_NO_AUTO_INSTALL = "1"
      assert(require("workarounds.codediff.threaded_git").apply())
    end,
    opts = {
      diff = {
        layout = "side-by-side", compact = false, compute_moves = false,
        cycle_hunks_across_files = true,
      },
      -- Saves, focus/tab return, mutations and R refresh without whole-tree polling.
      explorer = { view_mode = "tree", width = 38, untracked = "all", auto_refresh = false,
        line_stats = { enabled = true, count_untracked = false } },
      keymaps = { view = { next_file = "<Tab>", prev_file = "<S-Tab>", toggle_stage = "<leader>hS" } },
    },
    config = function(_, opts)
      require("codediff").setup(opts)
      require("workarounds.codediff.threaded_git").attach()
      require("workarounds.codediff.history_paths").apply()
      require("workarounds.codediff.safe_mutations").apply()
      require("workarounds.codediff.event_refresh").apply()
      require("workarounds.codediff.large_tree").apply()
      require("workarounds.codediff.binary_files").apply()
      require("utils.git_review").setup()
    end,
  },
  {
    "folke/snacks.nvim",
    opts = {
      picker = { sources = {
        git_log = { confirm = function(p, item) require("utils.git_review").confirm_commit(p, item) end },
        git_log_file = { confirm = function(p, item) require("utils.git_review").confirm_commit(p, item) end },
        git_log_line = { confirm = function(p, item) require("utils.git_review").confirm_commit(p, item) end },
        git_status = { confirm = function(p, item) require("utils.git_review").confirm_status(p, item) end },
      } },
    },
  },
}
