-- Neogit: Magit-style git operation panel for Neovim.
--
-- Single entry point only — user rule: no nested gn{c,p,P,l,b,s} subkeys.
-- Inside the Neogit status buffer everything is one keystroke already
-- (s stage, u unstage, x discard, c commit, P push, p pull, b branch,
--  Z stash, l log, $ command output, ? help).
--
-- Keymap: <leader>gn → Neogit status (the only entry point).
return {
  {
    "NeogitOrg/neogit",
    cmd = { "Neogit" },
    dependencies = {
      "nvim-lua/plenary.nvim",
      "esmuellert/codediff.nvim",
      "folke/snacks.nvim",
    },
    keys = {
      {
        "<leader>gn",
        function()
          require("utils.git_review").neogit()
        end,
        desc = "Neogit (status)",
      },
    },
    opts = {
      diff_viewer = "codediff",
      integrations = {
        codediff = true,
        snacks = true,
        diffview = false,
        telescope = false,
      },
      disable_signs = false,
      disable_hint = false,
      disable_context_highlighting = false,
      disable_commit_confirmation = false,
      auto_refresh = true,
      kind = "tab",
      commit_editor = { kind = "tab" },
      commit_select_view = { kind = "tab" },
      commit_view = {
        kind = "vsplit",
        verify_commit = vim.fn.executable("gpg") == 1,
      },
      log_view = { kind = "tab" },
      rebase_editor = { kind = "auto" },
      reflog_view = { kind = "tab" },
      merge_editor = { kind = "auto" },
      tag_editor = { kind = "auto" },
      preview_buffer = { kind = "floating" },
      popup = { kind = "split" },
      signs = {
        hunk = { "", "" },
        item = { "", "" },
        section = { "", "" },
      },
      mappings = {
        status = {
          ["q"] = "Close",
          ["<esc>"] = "Close",
          -- Defaults already cover: s/u/x stage/unstage/discard, c commit popup,
          -- P push popup, p pull popup, b branch popup, Z stash popup,
          -- l log popup, <tab> toggle section, ? help.
        },
      },
    },
    config = function(_, opts)
      require("neogit").setup(opts)
      require("workarounds.neogit.codediff_v4").apply()
    end,
  },
}
