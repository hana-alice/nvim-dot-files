vim.g.root_spec = { "cwd" }
vim.g.autoformat = false

local opt = vim.opt

-- Keep sessions from silently restoring a different cwd without replaying fold state.
vim.opt.sessionoptions = { "buffers", "tabpages", "winsize", "help", "globals", "skiprtp" }
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

local fallback_commentstrings = {
  hlsl = "// %s",
  shaderslang = "// %s",
  ini = "; %s",
  dosini = "; %s",
}

local function ensure_commentstring(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  local bo = vim.bo[bufnr]
  if bo.commentstring ~= "" or bo.filetype == "" then
    return
  end

  local commentstring = fallback_commentstrings[bo.filetype]
  if not commentstring then
    local ok, detected = pcall(vim.filetype.get_option, bo.filetype, "commentstring")
    if ok and type(detected) == "string" and detected:find("%%s") then
      commentstring = detected
    end
  end

  if commentstring and commentstring ~= "" then
    bo.commentstring = commentstring
  end
end

local commentstring_group = vim.api.nvim_create_augroup("UECommentstringFallback", { clear = true })
vim.api.nvim_create_autocmd({ "FileType", "BufEnter" }, {
  group = commentstring_group,
  callback = function(args)
    ensure_commentstring(args.buf)
  end,
})

vim.schedule(function()
  pcall(ensure_commentstring, vim.api.nvim_get_current_buf())
end)
