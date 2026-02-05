-- lua/term.lua
local M = {}

function M.term_send_line(bufnr, line)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  vim.api.nvim_chan_send(
    vim.b[bufnr].terminal_job_id,
    line .. "\n"
  )
end

function M.term_cd(bufnr, dir)
  M.term_send_line(bufnr, "cd " .. vim.fn.fnameescape(dir))
end

return M
