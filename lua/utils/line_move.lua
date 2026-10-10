local M = {}

-- Expression mappings inspect the live range before leaving Insert or Visual mode.
function M.keys(direction)
  if direction ~= -1 and direction ~= 1 then
    return "<Ignore>"
  end
  local mode = vim.api.nvim_get_mode().mode
  local insert = mode:sub(1, 1) == "i"
  local visual = mode == "v" or mode == "V" or mode == "\22"
  if mode ~= "n" and not insert and not visual then
    return "<Ignore>"
  end
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local first, last = row, row
  if visual then
    local anchor = vim.fn.getpos("v")[2]
    first, last = math.min(first, anchor), math.max(last, anchor)
  end
  local count = insert and 1 or vim.v.count1
  if
    first < 1
    or first - (direction == -1 and count or 0) < 1
    or last + (direction == 1 and count or 0) > vim.api.nvim_buf_line_count(0)
  then
    return "<Ignore>"
  end
  local offset = direction == 1 and "+" .. count or "-" .. (count + 1)
  if visual then
    return ":<C-u>'<,'>move " .. (direction == 1 and "'>" or "'<") .. offset .. "<CR>gv=gv"
  end
  return (insert and "<Esc>" or "") .. "<Cmd>move ." .. offset .. "<CR>==" .. (insert and "gi" or "")
end

return M
