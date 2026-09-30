-- gitsigns: inline hunks + on-cursor blame (GitLens-style virtual text)
--
-- Two pieces matter for the VSCode/GitLens experience:
--   1. `current_line_blame = true` — virtual text at end of current line
--      with `author · time · summary`, like GitLens. Toggle with `<leader>uG`
--      (LazyVim built-in) or `:Gitsigns toggle_current_line_blame`.
--   2. `current_line_blame_opts.delay = 200` — quick reveal so it actually
--      feels like hover. Default is 1000ms which feels broken.
--   3. Ordinary-buffer hunk actions use <leader>h; <leader>gh belongs
--      to content search. CodeDiff owns its session buffer mappings.
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
        -- 500ms (was 200): every blame reveal spawns a `git blame -L` child.
        -- On Windows a process spawn costs the MAIN LOOP tens of ms, so
        -- rapid <C-f>/<C-b> scroll pauses at 200ms fired blame spawns almost
        -- back-to-back and stacked onto the K42 watcher loop. 500ms still
        -- feels like hover but skips spawns during paging.
        delay = 500,
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

      -- CRITICAL (K42): do NOT watch the .git dir on this machine. The UE
      -- repos here run git fsmonitor (core.fsmonitor=true). Every git
      -- command drops a fsmonitor cookie file inside .git/, so gitsigns'
      -- gitdir watcher sees a change → refreshes → spawns git → git drops
      -- another cookie → watcher fires again — a self-sustaining spawn loop.
      -- Profiled 2026-07-24 (jit.profile, 8s sample on an idle session):
      -- gitsigns async spawn + repo watcher dominated the main loop
      -- (~1600/4300 samples) — felt as constant <C-f>/<C-b>/picker stutter.
      -- Cost of disabling: external git actions (commit/pull from another
      -- terminal) refresh signs on the next BufWritePost/FocusGained instead
      -- of instantly. Worth it.
      opts.watch_gitdir = vim.tbl_deep_extend("force", opts.watch_gitdir or {}, {
        enable = false,
      })

      -- Linehl/numhl off by default — too noisy in dark themes.
      opts.linehl = false
      opts.numhl = false

      opts.on_attach = function(buffer)
        local gs = require("gitsigns")
        local group = vim.api.nvim_create_augroup("GitReviewGitsigns" .. buffer, { clear = true })
        local installed = false
        local function review_owns_buffer()
          local lifecycle = package.loaded["codediff.ui.lifecycle"]
          return lifecycle and lifecycle.find_tabpage_by_buffer(buffer) ~= nil
        end
        local function in_review()
          local lifecycle = package.loaded["codediff.ui.lifecycle"]
          local session = lifecycle and lifecycle.get_session(vim.api.nvim_get_current_tabpage())
          return session and (session.original_bufnr == buffer or session.modified_bufnr == buffer
            or session.result_bufnr == buffer)
        end
        local function install()
          if installed then return true end
          if not vim.api.nvim_buf_is_valid(buffer) or review_owns_buffer() then return false end
          local function map(lhs, action, desc)
            vim.keymap.set("n", lhs, function()
              if not in_review() then action() end
            end, { buffer = buffer, silent = true, desc = desc })
          end
          local function unstaged_hunk()
            local row = vim.api.nvim_win_get_cursor(0)[1]
            for _, hunk in ipairs(gs.get_hunks(buffer) or {}) do
              local first = math.max(hunk.added.start, 1)
              local last = math.max(first, hunk.added.start + hunk.added.count - 1)
              if row >= first and row <= last then return true end
            end
            vim.notify("当前行没有未暂存 hunk", vim.log.levels.INFO, { title = "Gitsigns" })
            return false
          end
          map("<leader>hs", function()
            -- stage_hunk otherwise toggles an already-staged hunk back out.
            if unstaged_hunk() then gs.stage_hunk() end
          end, "Git: stage current unstaged hunk")
          map("<leader>hu", function()
            require("utils.git_review").open({ staged = true })
          end, "CodeDiff: review staged hunks to unstage")
          map("<leader>hr", function()
            if unstaged_hunk() and vim.fn.confirm("Discard current hunk in this buffer?", "&Discard\n&Cancel", 2) == 1 then
              gs.reset_hunk()
            end
          end, "Git: discard current hunk (confirm)")
          map("<leader>hS", gs.stage_buffer, "Git: stage buffer")
          map("<leader>hp", gs.preview_hunk_inline, "Git: preview hunk")
          map("<leader>hb", function() gs.blame_line({ full = true }) end, "Git: blame line")
          map("<leader>hB", gs.blame, "Git: blame buffer")
          map("]h", function()
            if vim.wo.diff then vim.cmd.normal({ "]c", bang = true }) else gs.nav_hunk("next") end
          end, "Next hunk")
          map("[h", function()
            if vim.wo.diff then vim.cmd.normal({ "[c", bang = true }) else gs.nav_hunk("prev") end
          end, "Previous hunk")
          map("]H", function() gs.nav_hunk("last") end, "Last hunk")
          map("[H", function() gs.nav_hunk("first") end, "First hunk")
          vim.keymap.set({ "o", "x" }, "ih", function()
            if not in_review() then gs.select_hunk() end
          end, { buffer = buffer, silent = true, desc = "Git: select hunk" })
          installed = true
          vim.api.nvim_del_augroup_by_id(group)
          return true
        end
        if install() then return end
        -- Late attachment must not overwrite CodeDiff's registry claims.
        -- Restore ordinary mappings once the session releases this buffer.
        vim.api.nvim_create_autocmd("BufEnter", { group = group, buffer = buffer, callback = install })
        vim.api.nvim_create_autocmd("User", {
          group = group, pattern = "CodeDiffClose", callback = function() vim.schedule(install) end,
        })
        vim.api.nvim_create_autocmd("BufWipeout", {
          group = group, buffer = buffer, once = true,
          callback = function() pcall(vim.api.nvim_del_augroup_by_id, group) end,
        })
      end

      return opts
    end,
  },
}
