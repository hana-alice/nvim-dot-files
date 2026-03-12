vim.g.root_spec = { "cwd" }

-- Keep sessions from silently restoring a different cwd.
vim.opt.sessionoptions = { "buffers", "tabpages", "winsize", "help", "globals", "skiprtp", "folds" }
vim.opt.list = false

vim.filetype.add({
  extension = {
    usf = "hlsl",
    ush = "hlsl",
  },
})
