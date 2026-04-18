-- WORKAROUND
-- name: snacks.projects_picker_freeze
-- scope: snacks
-- issue: internal: snacks projects source uses recent=true → walks vim.v.oldfiles synchronously and calls Snacks.git.get_root() for each, blocking main loop ~30s on UE workspaces.
-- symptom: Pressing `p` (open projects picker) in Neovide freezes Neovim for tens of seconds while it scans hundreds of oldfiles + spawns git per entry.
-- introduced: 2025-04-01
-- removal_condition: snacks.nvim ships an async-iterator projects source, OR upstream switches to a maintained MRU file (no per-entry git spawn).
-- owner: hana-alice
-- enabled: true
-- END WORKAROUND

-- Replaces snacks.picker.sources.projects.finder with a static-list reader
-- backed by utils.recent_projects (an MRU file maintained by autocmds).
-- Returns project dirs instantly — no oldfiles walk, no git spawn.
--
-- Apply contract:
--   apply(opts) — opts is the snacks `opts` table at config-time.
--                 Returns the mutated opts (also mutates in-place).

local M = {}

local applied = false

function M.apply(opts)
  applied = true
  opts = opts or {}
  opts.picker = opts.picker or {}
  opts.picker.sources = opts.picker.sources or {}
  opts.picker.sources.projects = vim.tbl_deep_extend(
    "force", opts.picker.sources.projects or {}, {
      finder = function(_, _)
        local ok, rp = pcall(require, "utils.recent_projects")
        local list = {}
        if ok then
          list = rp.list()
          if #list < 5 then
            -- Lazy bootstrap on first picker open: synchronously walk
            -- top-30 oldfiles to seed the project list.
            pcall(rp.bootstrap_from_oldfiles, 30)
            list = rp.list()
          end
        end
        ---@async
        return function(cb)
          for _, dir in ipairs(list) do
            cb({ file = dir, text = dir, dir = true })
          end
        end
      end,
      patterns = { ".git", ".uproject", ".uplugin", "package.json" },
    }
  )
  return opts
end

function M.disable()
  -- Removing the override at runtime is not meaningful — snacks reads
  -- the source spec at picker-open time. To revert, set enabled=false in
  -- the frontmatter and restart.
end

function M.status()
  return { applied = applied }
end

return M
