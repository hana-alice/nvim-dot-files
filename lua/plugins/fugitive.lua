-- vim-fugitive — the elder statesman of nvim git plugins
--
-- Why we have it on top of diffview/neogit/gitsigns:
--   * `:Gedit :0` / `:Gedit HEAD~3:%` — open a *past* version of the
--     current file in a buffer. diffview can't do this; it only shows
--     diffs side-by-side.
--   * `:Git blame` — Fugitive full-file blame navigation.
--     Press `o` on any line to preview that
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

}
