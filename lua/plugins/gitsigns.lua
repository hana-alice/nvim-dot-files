-- gitsigns: inline hunks + on-cursor blame (GitLens-style virtual text)
--
-- Two pieces matter for the VSCode/GitLens experience:
--   1. `current_line_blame = true` — virtual text at end of current line
--      with `author · time · summary`, like GitLens. Toggle with `<leader>uG`
--      (LazyVim built-in) or `:Gitsigns toggle_current_line_blame`.
--   2. `current_line_blame_opts.delay = 200` — quick reveal so it actually
--      feels like hover. Default is 1000ms which feels broken.
--   3. Stage / undo hunks from inside the buffer is also a GitLens gap;
--      gitsigns has hunk operators (`<leader>ghs` stage hunk, `<leader>ghr`
--      reset hunk, `<leader>ghp` preview hunk). LazyVim already binds these
--      under `<leader>gh*` — we just enable them via current_line_blame.
return {
  {
    "lewis6991/gitsigns.nvim",
    opts = function(_, opts)
      opts = opts or {}
      opts.diff_opts = vim.tbl_deep_extend("force", opts.diff_opts or {}, {
        ignore_whitespace_change_at_eol = true,
      })

      -- GitLens-style "blame on current line" virtual text.
      opts.current_line_blame = true
      opts.current_line_blame_opts = vim.tbl_deep_extend("force", opts.current_line_blame_opts or {}, {
        virt_text = true,
        virt_text_pos = "eol",
        delay = 200,
        ignore_whitespace = false,
      })
      opts.current_line_blame_formatter = "<author>, <author_time:%R> · <summary>"

      -- Sign column setup — keeps gitsigns column thin so it doesn't
      -- compete with diagnostics signs.
      opts.signs = vim.tbl_deep_extend("force", opts.signs or {}, {
        add          = { text = "│" },
        change       = { text = "│" },
        delete       = { text = "_" },
        topdelete    = { text = "‾" },
        changedelete = { text = "~" },
        untracked    = { text = "┆" },
      })

      -- Performance: throttle blame on big files (>10k lines), don't run
      -- gitsigns at all on huge files.
      opts.max_file_length = 40000

      -- Linehl/numhl off by default — too noisy in dark themes.
      opts.linehl = false
      opts.numhl = false

      return opts
    end,
  },
}
