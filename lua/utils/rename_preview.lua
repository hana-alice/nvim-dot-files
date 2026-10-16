-- Native read-only diff windows owned by one refactor preview.
local M = {}
local api = vim.api
local active

function M.close()
  local view = active
  if not view then
    return
  end
  active = nil
  local current = api.nvim_get_current_win()
  local was_owned = view.windows[current] == api.nvim_win_get_buf(current)
  for win, buf in pairs(view.windows) do
    if api.nvim_win_is_valid(win) and api.nvim_win_get_buf(win) == buf then
      pcall(api.nvim_win_close, win, true)
    end
  end
  for _, buf in ipairs(view.buffers) do
    if api.nvim_buf_is_valid(buf) and #vim.fn.win_findbuf(buf) == 0 then
      pcall(api.nvim_buf_delete, buf, { force = true })
    end
  end
  if was_owned and api.nvim_win_is_valid(view.source_win) then
    api.nvim_set_current_win(view.source_win)
  end
end

local function scratch(lines, title)
  local buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_name(buf, title)
  api.nvim_buf_set_lines(buf, 0, -1, true, lines)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modified = false
  vim.bo[buf].readonly = true
  vim.bo[buf].modifiable = false
  return buf
end

--- q returns to the file list; a confirms the whole batch; Escape cancels.
function M.open(batch, target, callbacks)
  M.close()
  local view = { source_win = api.nvim_get_current_win(), windows = {}, buffers = {} }
  active = view
  local ok, err = pcall(function()
    local prefix = ("ue-refactor://%d/%d/"):format(vim.fn.getpid(), vim.uv.hrtime())
    local before = scratch(target.before.lines, prefix .. "before/" .. vim.fs.basename(target.path))
    local after = scratch(target.after, prefix .. "after/" .. vim.fs.basename(target.path))
    view.buffers = { before, after }
    vim.cmd("tab split")
    local left = api.nvim_get_current_win()
    api.nvim_win_set_buf(left, before)
    view.windows[left] = before
    vim.cmd("diffthis")
    vim.cmd("rightbelow vsplit")
    local right = api.nvim_get_current_win()
    api.nvim_win_set_buf(right, after)
    view.windows[right] = after
    vim.cmd("diffthis")
    for _, buf in ipairs(view.buffers) do
      local function finish(callback)
        M.close()
        if callback then
          callback()
        end
      end
      vim.keymap.set("n", "q", function()
        finish(callbacks.back)
      end, { buffer = buf, desc = "Back to refactor files" })
      vim.keymap.set("n", "a", function()
        finish(callbacks.apply)
      end, { buffer = buf, desc = "Confirm whole refactor batch" })
      vim.keymap.set("n", "<Esc>", function()
        finish(callbacks.cancel)
      end, { buffer = buf, desc = "Cancel refactor batch" })
    end
    vim.notify(
      batch.label .. " — 左：当前内容；右：预览。q 文件列表，a 确认整批，Esc 取消",
      vim.log.levels.INFO,
      { title = "修改预览" }
    )
  end)
  if not ok then
    M.close()
    return false, tostring(err)
  end
  return true
end

return M
