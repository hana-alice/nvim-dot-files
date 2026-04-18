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
require("ue").setup()
