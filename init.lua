-- bootstrap lazy.nvim, LazyVim and your plugins
vim.g.mapleader = " "
vim.g.maplocalleader = " "

if vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1 then
  local localappdata = vim.env.LOCALAPPDATA
  if localappdata and localappdata ~= "" then
    local base = localappdata:gsub("\\", "/") .. "/nvim-main"
    vim.env.XDG_DATA_HOME = base
    vim.env.XDG_STATE_HOME = base
    vim.env.XDG_CACHE_HOME = base
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
require("config.options")
require("config.autocmds")
require("config.keymaps")
require("config.windows").setup()
require("ue").setup()
