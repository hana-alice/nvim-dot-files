-- Neogit: Magit-style git operation panel for Neovim.
--
-- Why both neogit + diffview + lazygit?
--   * lazygit  : terminal-based, fastest for staged-by-staged commit & rebase.
--   * neogit   : in-Neovim status panel, stage hunks WITH lsp/treesitter context,
--                jump straight into a buffer, drives diffview for diffs.
--   * diffview : pure diff/PR review surface. neogit hands diff rendering to it.
--
-- Keymap layout (avoids existing <leader>g{d,h,v,...}):
--   <leader>gn   -> open Neogit status (toggle)
--   <leader>gN   -> Neogit in a new tab (full-screen)
--   <leader>gnc  -> commit
--   <leader>gnp  -> pull
--   <leader>gnP  -> push
--   <leader>gnl  -> log
--   <leader>gnb  -> branch popup
--   <leader>gns  -> stash popup
return {
  {
    "NeogitOrg/neogit",
    cmd = { "Neogit" },
    dependencies = {
      "nvim-lua/plenary.nvim",
      "sindrets/diffview.nvim", -- already installed; reused for diff rendering
      "nvim-telescope/telescope.nvim", -- optional; falls back to vim.ui.select if absent
    },
    keys = {
      { "<leader>gn", function() require("neogit").open() end, desc = "Neogit (status)" },
      { "<leader>gN", function() require("neogit").open({ kind = "tab" }) end, desc = "Neogit (tab)" },
      { "<leader>gnc", function() require("neogit").open({ "commit" }) end, desc = "Neogit commit" },
      { "<leader>gnp", function() require("neogit").open({ "pull" }) end, desc = "Neogit pull" },
      { "<leader>gnP", function() require("neogit").open({ "push" }) end, desc = "Neogit push" },
      { "<leader>gnl", function() require("neogit").open({ "log" }) end, desc = "Neogit log" },
      { "<leader>gnb", function() require("neogit").open({ "branch" }) end, desc = "Neogit branches" },
      { "<leader>gns", function() require("neogit").open({ "stash" }) end, desc = "Neogit stash" },
    },
    opts = {
      -- Use diffview for the diff surface (1 hunk -> opens diffview tab).
      integrations = {
        diffview = true,
        telescope = true,
      },
      -- Disable signs in the status buffer; gitsigns already paints buffers.
      disable_signs = false,
      disable_hint = false,
      disable_context_highlighting = false,
      disable_commit_confirmation = false,
      -- Auto-refresh status buffer on focus.
      auto_refresh = true,
      -- Where the status window opens; "tab" = full screen, "split" = horizontal,
      -- "vsplit", "floating" also work. Default split keeps current layout intact.
      kind = "tab",
      -- Commit editor uses a floating window so it doesn't disturb your layout.
      commit_editor = {
        kind = "tab",
      },
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
      -- Sign column markers in the status buffer.
      signs = {
        hunk = { "", "" },
        item = { "", "" },
        section = { "", "" },
      },
      -- Override the status buffer mappings only where needed; keep defaults.
      mappings = {
        status = {
          ["q"] = "Close",
          ["<esc>"] = "Close",
          -- "<tab>" already toggles section folding by default
          -- "s" stage, "u" unstage, "x" discard, "c" commit popup, "P" push popup, "p" pull popup
          -- ":" command, "?" help
        },
      },
    },
    config = function(_, opts)
      require("neogit").setup(opts)
    end,
  },
}
