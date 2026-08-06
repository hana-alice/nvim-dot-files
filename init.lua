-- bootstrap lazy.nvim, LazyVim and your plugins
vim.g.mapleader = " "
vim.g.maplocalleader = " "

local function cleanup_stale_shada_tmp()
  local uv = vim.uv or vim.loop
  local shada_dir = vim.fs.joinpath(vim.fn.stdpath("data"), "shada")
  local scan = uv.fs_scandir(shada_dir)
  if not scan then
    return
  end

  local now = os.time()
  while true do
    local name, kind = uv.fs_scandir_next(scan)
    if not name then
      break
    end
    if kind == "file" and name:match("%.shada%.tmp%.[^/\\]+$") then
      local path = vim.fs.joinpath(shada_dir, name)
      local stat = uv.fs_stat(path)
      local mtime = stat and stat.mtime and stat.mtime.sec
      if mtime and now - mtime > 300 then
        pcall(uv.fs_unlink, path)
      end
    end
  end
end

cleanup_stale_shada_tmp()

-- Initialise the rotating debug logger early so it is available to every
-- subsequent setup call. Eager require also installs :NvimLog* commands.
do
  local ok_log, log = pcall(require, "utils.log")
  if ok_log then
    log.install_commands()
  end
end

-- Diagnostic: main-loop stall probe (100ms tick, records blocks >150ms).
-- Cheap (hrtime arithmetic per tick); evidence via :StallReport / log scope
-- "stall". Started on UIEnter so headless regression runs (-l/--headless,
-- which never attach a UI) don't spin a hot timer.
vim.api.nvim_create_autocmd("UIEnter", {
  once = true,
  callback = function()
    pcall(function()
      require("utils.stall_probe").setup()
    end)
    -- Proactive evidence probes (:UEProbeReport / spec probe-feedback-loop).
    -- Session-start summary: surface pending evidence ONCE so the next
    -- session's first act is READING feedback, not waiting for it.
    pcall(function()
      local probe = require("utils.probe").setup()
      local s = probe.pending_summary()
      if s.records > 0 then
        vim.defer_fn(function()
          vim.notify(
            ("[probe] %d topic(s) / %d record(s) of evidence pending — :UEProbeReport")
              :format(s.topics, s.records),
            vim.log.levels.INFO, { title = "UE", timeout = 6000 })
        end, 1500)
      end
    end)
  end,
})

require("config.neovide").setup()
require("config.snacks_global").setup()
require("config.lazy")
-- NOTE: config.options / config.autocmds / config.keymaps are auto-loaded by
-- LazyVim (options before lazy.setup, autocmds+keymaps on VeryLazy). Do NOT
-- require them here to avoid double execution.
require("config.windows").setup()
require("utils.recent_projects").setup()
require("workarounds").setup({ auto_apply = false })
require("workarounds.lazyvim.close_with_q_invalid_buf").apply()
require("workarounds.neovide.exit_with_gui").apply()
-- NOTE: workarounds.lazy.float_vimresized_invalid_buf removed 2026-07-26 —
-- upstream lazy.nvim float.lua VimResized callback now guards win+buf
-- validity itself (health-check F6; K21 retired).
require("workarounds.clangd.non_file_uri_detach").apply()
require("ue").setup()
