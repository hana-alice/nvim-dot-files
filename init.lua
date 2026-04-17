-- bootstrap lazy.nvim, LazyVim and your plugins
vim.g.mapleader = " "
vim.g.maplocalleader = " "

-- Windows: redirect data/state/cache into %LOCALAPPDATA%\nvim-main so we have
-- a single, clean nvim runtime directory next to the config dir.
--
-- IMPORTANT: the AUTHORITATIVE setup is a Windows USER environment variable
-- (XDG_DATA_HOME / XDG_STATE_HOME / XDG_CACHE_HOME / NVIM_LOG_FILE), set via
-- scripts/set_xdg_env.ps1. Doing it there guarantees nvim picks the right
-- paths BEFORE init.lua runs (otherwise the early-init log file leaks into
-- %LOCALAPPDATA%\nvim-data\log).
--
-- The block below stays as a fallback for fresh machines where the env vars
-- have not been installed yet — it still keeps stdpath('data'/'state'/'cache')
-- pointing at nvim-main, just not the pre-init log.
--
-- This check runs before runtimepath/XDG is configured, so we cannot
-- require("utils.platform") here — use inline vim.fn.has() instead.
if vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1 then
  local localappdata = vim.env.LOCALAPPDATA
  if localappdata and localappdata ~= "" then
    local base = localappdata:gsub("\\", "/") .. "/nvim-main"
    vim.env.XDG_DATA_HOME = vim.env.XDG_DATA_HOME or base
    vim.env.XDG_STATE_HOME = vim.env.XDG_STATE_HOME or base
    vim.env.XDG_CACHE_HOME = vim.env.XDG_CACHE_HOME or base
  end
end

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

require("config.neovide").setup()
require("config.snacks_global").setup()
require("config.lazy")
-- NOTE: config.options / config.autocmds / config.keymaps are auto-loaded by
-- LazyVim (options before lazy.setup, autocmds+keymaps on VeryLazy). Do NOT
-- require them here to avoid double execution.
require("config.windows").setup()
require("ue").setup()
