-- utils.notification_history: in-memory history for user-visible notices.
--
-- This is intentionally not a vim.notify monkey-patch. Callers opt in through
-- utils.log.notify* or explicit record() calls for fidget-only workflows.

local M = {}

local MAX_RECORDS = 200

local state = {
  records = {},
  next_id = 0,
}

local LEVEL_NAME_BY_VALUE = {}
for name, value in pairs(vim.log.levels) do
  if type(value) == "number" then
    LEVEL_NAME_BY_VALUE[value] = tostring(name):upper()
  end
end

local LEVEL_VALUE_BY_NAME = {}
for value, name in pairs(LEVEL_NAME_BY_VALUE) do
  LEVEL_VALUE_BY_NAME[name] = value
end

local function normalize_level(level)
  if type(level) == "number" then
    return level, LEVEL_NAME_BY_VALUE[level] or tostring(level)
  end
  if type(level) == "string" then
    local name = level:upper()
    return LEVEL_VALUE_BY_NAME[name] or vim.log.levels.INFO, name
  end
  return vim.log.levels.INFO, "INFO"
end

local function split_lines(text)
  text = tostring(text or "")
  local out = {}
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    out[#out + 1] = line
  end
  if #out == 0 then
    out[1] = ""
  end
  return out
end

local function fmt_time(ts)
  return os.date("%H:%M:%S", ts or os.time())
end

function M.record(spec)
  spec = spec or {}
  local level, level_name = normalize_level(spec.level)
  local message = tostring(spec.message or "")
  local scope = tostring(spec.scope or spec.title or "nvim")

  state.next_id = state.next_id + 1
  state.records[#state.records + 1] = {
    id = state.next_id,
    timestamp = spec.timestamp or os.time(),
    level = level,
    level_name = level_name,
    scope = scope,
    title = spec.title,
    message = message,
    detail = spec.detail,
  }

  while #state.records > MAX_RECORDS do
    table.remove(state.records, 1)
  end
end

function M.clear()
  state.records = {}
end

function M.list(opts)
  opts = opts or {}
  local limit = tonumber(opts.limit or #state.records) or #state.records
  local out = {}
  for i = #state.records, 1, -1 do
    out[#out + 1] = vim.deepcopy(state.records[i])
    if #out >= limit then
      break
    end
  end
  return out
end

function M.render_lines(opts)
  local rows = M.list(opts)
  local lines = { "Notification History", "" }
  if #rows == 0 then
    lines[#lines + 1] = "(empty)"
    return lines
  end

  for _, rec in ipairs(rows) do
    local header = string.format(
      "[%s] %-5s %-18s #%d",
      fmt_time(rec.timestamp),
      rec.level_name or "?",
      rec.scope or "nvim",
      rec.id or 0
    )
    lines[#lines + 1] = header
    local msg_lines = split_lines(rec.message)
    for _, line in ipairs(msg_lines) do
      lines[#lines + 1] = "  " .. line
    end
    if rec.detail and rec.detail ~= "" then
      for _, line in ipairs(split_lines(rec.detail)) do
        lines[#lines + 1] = "  " .. line
      end
    end
    lines[#lines + 1] = ""
  end
  return lines
end

function M.open(opts)
  vim.cmd("tabnew")
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].buflisted = false
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "notification_history"

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, M.render_lines(opts))
  vim.bo[buf].modifiable = false

  vim.api.nvim_set_current_buf(buf)
  return buf
end

function M.install_commands()
  vim.api.nvim_create_user_command("NotificationHistory", function()
    M.open()
  end, { desc = "Open recent notification history", force = true })

  vim.api.nvim_create_user_command("NotificationHistoryClear", function()
    M.clear()
    vim.notify("notification history cleared", vim.log.levels.INFO, { title = "notifications" })
  end, { desc = "Clear in-memory notification history", force = true })
end

function M._reset_for_test()
  state.records = {}
  state.next_id = 0
end

function M._records_for_test()
  return state.records
end

M._MAX_RECORDS = MAX_RECORDS

return M
