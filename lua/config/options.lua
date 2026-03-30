vim.g.root_spec = { "cwd" }
vim.g.autoformat = false

local opt = vim.opt

-- Keep sessions from silently restoring a different cwd.
vim.opt.sessionoptions = { "buffers", "tabpages", "winsize", "help", "globals", "skiprtp", "folds" }
vim.opt.list = false
opt.expandtab = true
opt.shiftwidth = 4
opt.softtabstop = 4
opt.tabstop = 4
opt.number = true
opt.relativenumber = false

vim.filetype.add({
  extension = {
    usf = "hlsl",
    ush = "hlsl",
  },
})
