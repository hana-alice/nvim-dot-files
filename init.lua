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

require("config.lazy")
require("config.windows").setup()
require("ue").setup()
