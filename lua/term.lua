-- Terminal helper module
local M = {}

-- Send a line to a terminal buffer (requires terminal_job_id present)
function M.term_send_line(bufnr, line)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  local job = vim.b[bufnr] and vim.b[bufnr].terminal_job_id or nil
  if not job then
    return
  end
  vim.api.nvim_chan_send(job, line .. "\n")
end

-- cd inside the terminal to a directory (uses PowerShell/cmd/bash 'cd')
function M.term_cd(bufnr, dir)
  if not dir or dir == "" then return end
  -- For pwsh/cmd, plain cd works; fnameescape helps spaces.
  M.term_send_line(bufnr, "cd " .. vim.fn.fnameescape(dir))
end

return M
