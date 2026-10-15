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
  local expected, entry = first_error, vim.deepcopy(first_error)
  local layout = require("utils.layout")
  local tab, source = vim.api.nvim_get_current_tabpage(), vim.api.nvim_get_current_win()
  local handoff = require("utils.layout_handoff")
  local snapshot = handoff.capture(source)
  local protected = layout.routes_to_normal(tab)
  if protected then
    local prior = layout.resolve({ tab = tab, source_win = source, create = false, route_to_normal = true })
    local prior_snapshot = prior and handoff.capture(prior)
    if prior_snapshot then prior_snapshot.active, prior_snapshot.code = false, true end
    if not handoff.load(snapshot, entry.bufnr, prior_snapshot) or first_error ~= expected then return false end
    local win, err = layout.focus({ tab = tab, source_win = source })
    if not win then
      vim.notify(err, vim.log.levels.WARN)
      return false
    end
    if first_error ~= expected or not handoff.revalidate(snapshot,
      { win = win, tab = vim.api.nvim_win_get_tabpage(win), buf = vim.api.nvim_win_get_buf(win), code = true }) then return false end
  elseif vim.bo.buftype ~= "" then
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
  local win = vim.api.nvim_get_current_win()
  local destination = { win = win, tab = vim.api.nvim_win_get_tabpage(win), buf = entry.bufnr, code = protected }
  if vim.api.nvim_buf_is_loaded(entry.bufnr) then destination.tick = vim.api.nvim_buf_get_changedtick(entry.bufnr) end
  local ok, _, err = handoff.handoff(snapshot, destination, function()
    vim.api.nvim_win_set_buf(win, entry.bufnr)
  end)
  if not ok then
    vim.notify("无法跳到构建错误: " .. tostring(err), vim.log.levels.WARN)
    return false
  end
  if first_error ~= expected or not handoff.revalidate(snapshot, destination) then return false end
  local line = math.min(entry.lnum, vim.api.nvim_buf_line_count(entry.bufnr))
  local text = vim.api.nvim_buf_get_lines(entry.bufnr, line - 1, line, false)[1] or ""
  vim.api.nvim_win_set_cursor(win, { line, math.min(math.max((entry.col or 1) - 1, 0), #text) })
  return true
end

function M.setup()
  vim.api.nvim_create_user_command("UEBuildFirstError", M.jump_first,
    { desc = "Jump to the first source error from the latest failed build" })
end

return M
