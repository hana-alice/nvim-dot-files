-- Build-only diagnostics. Explicit searches keep their original quickfix order.
local M = {}
local first_error

function M.severity(entry)
  local kind = tostring(entry.type or ""):upper()
  if kind == "E" or kind == "W" then return kind end
  local text = tostring(entry.text or ""):lower()
  if text:match("^note%s*:") then return "" end
  if text:find("%f[%a]warning%f[%A]") then return "W" end
  if text:find("%f[%a]error%f[%A]") or text:find("%f[%a]fatal%f[%A]")
    or text:find("undefined reference", 1, true) then return "E" end
  return ""
end

---Stable partition: all errors, all warnings, then contextual/tail output.
function M.ordered(entries)
  local groups = { E = {}, W = {}, [""] = {} }
  for _, entry in ipairs(entries or {}) do
    local copy = vim.deepcopy(entry)
    copy.type = M.severity(copy)
    table.insert(groups[copy.type], copy)
  end
  local result = {}
  for _, kind in ipairs({ "E", "W", "" }) do vim.list_extend(result, groups[kind]) end
  return result
end

function M.clear() first_error = nil end

---Called only by a completed build; no timers or polling.
function M.publish(title, entries, opts)
  M.clear()
  local items = M.ordered(entries)
  if #items == 0 then return false end
  vim.fn.setqflist({}, " ", { title = title, items = items, context = opts and opts.context })
  local receipt = vim.fn.getqflist({ id = 0, items = 0, changedtick = 0 })
  for index, item in ipairs(receipt.items) do
    if items[index]._source_location ~= false and item.type == "E" and item.valid == 1 and item.lnum > 0 then
      first_error = vim.deepcopy(item)
      break
    end
  end
  require("utils.bottom_panel").show("quickfix", nil, { focus = false })
  return true, { qf_id = receipt.id, qf_tick = receipt.changedtick, items = items }
end

function M.summary()
  if not first_error then return "未解析到错误源码位置" end
  local file = vim.api.nvim_buf_get_name(first_error.bufnr)
  return ("首个错误 %s:%d（<leader>uE 跳转）"):format(vim.fn.fnamemodify(file, ":."), first_error.lnum)
end

---Jump from any panel to a code window, even if a search replaced quickfix.
function M.jump_first()
  if not first_error or not vim.api.nvim_buf_is_valid(first_error.bufnr) then
    vim.notify("没有可跳转的构建错误", vim.log.levels.INFO)
    return false
  end
  if vim.bo.buftype ~= "" then
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if vim.bo[vim.api.nvim_win_get_buf(win)].buftype == "" and vim.api.nvim_win_get_config(win).relative == "" then
        vim.api.nvim_set_current_win(win)
        break
      end
    end
  end
  vim.cmd("normal! m'")
  -- Reuse the existing source buffer; :edit would reject or reload dirty
  -- content even when this error already belongs to the current file.
  local ok, err = pcall(vim.api.nvim_win_set_buf, 0, first_error.bufnr)
  if not ok then
    vim.notify("无法跳到构建错误: " .. tostring(err), vim.log.levels.WARN)
    return false
  end
  local line = math.min(first_error.lnum, vim.api.nvim_buf_line_count(0))
  local text = vim.api.nvim_buf_get_lines(0, line - 1, line, false)[1] or ""
  vim.api.nvim_win_set_cursor(0, { line, math.min(math.max((first_error.col or 1) - 1, 0), #text) })
  return true
end

function M.setup()
  vim.api.nvim_create_user_command("UEBuildFirstError", M.jump_first,
    { desc = "Jump to the first source error from the latest failed build" })
end

return M
