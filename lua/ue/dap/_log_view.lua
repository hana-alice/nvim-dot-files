-- A bounded log history and event-driven projection. Filters never restart the
-- reader; hidden/stopped buffers keep their history, source jump and crash keys.
local M = { MAX_LINES = 12000, MAX_BYTES = 8 * 1024 * 1024, MAX_LINE_BYTES = 64 * 1024 }
local priority = { V = 1, D = 2, I = 3, W = 4, E = 5, F = 6, A = 6, S = 7 }
local logcat = require("utils.android_logcat")

local function clip(line, limit)
  local last = limit
  while last > 0 and line:byte(last + 1) and line:byte(last + 1) >= 128 and line:byte(last + 1) < 192 do
    last = last - 1
  end
  return line:sub(1, last)
end

local function valid(view)
  return view and vim.api.nvim_buf_is_valid(view.buf)
end

local function visible_windows(view)
  local result = {}
  for _, win in ipairs(vim.fn.win_findbuf(view.buf)) do
    if vim.api.nvim_win_is_valid(win) then
      result[#result + 1] = win
    end
  end
  return result
end

local function position(view, win)
  local saved = vim.api.nvim_win_call(win, vim.fn.winsaveview)
  saved.record = view.display[saved.lnum - 1]
  saved.top_record = view.display[saved.topline - 1]
  return saved
end

local function restore_position(view, win, saved)
  local value = vim.deepcopy(saved)
  local index = {}
  for line, id in ipairs(view.display) do
    index[id] = line + 1
  end
  value.lnum = index[saved.record] or math.min(saved.lnum, #view.display + 1)
  value.topline = index[saved.top_record] or math.min(saved.topline, #view.display + 1)
  value.record, value.top_record = nil, nil
  vim.api.nvim_win_call(win, function()
    vim.fn.winrestview(value)
  end)
end

local function matches(view, entry)
  if entry.level and (priority[entry.level] or 1) < (priority[view.level] or 1) then
    return false
  end
  return (view.text == "" or entry.lower:find(view.text:lower(), 1, true) ~= nil)
    and (view.tag == "" or entry.tag:lower():find(view.tag:lower(), 1, true) ~= nil)
end

local function header(view)
  return ("# Logcat · %s · %s · >=%s · 内容:%s · tag:%s · %d/%d条%s%s  | gf 跟随 G 底部 gl 级别 g/ 内容 gt 标签 g0 清除"):format(
    view.running and "读取中" or (view.reason or "已停止"),
    view.follow and "FOLLOW" or "PAUSED",
    view.level,
    view.text ~= "" and view.text or "全部",
    view.tag ~= "" and view.tag or "全部",
    #view.display,
    view.tail - view.head + 1,
    view.dropped > 0 and (" · 已淘汰 " .. view.dropped .. " 条旧记录") or "",
    view.truncated > 0 and (" · 超长行截断 " .. view.truncated) or ""
  )
end

function M.render(view, reset)
  if not valid(view) then
    return
  end
  local readers, saved = visible_windows(view), {}
  local count = vim.api.nvim_buf_line_count(view.buf)
  for _, win in ipairs(readers) do
    local cursor = vim.api.nvim_win_get_cursor(win)
    local reader = view.windows[win] or { follow = view.follow }
    view.windows[win] = reader
    if cursor[1] < count then
      reader.follow, view.follow = false, false
    end
    saved[win] = position(view, win)
    if not reader.follow then
      view.saved_position = saved[win]
    end
  end
  local removed, lines = 0, {}
  if reset then
    view.display = {}
    view.rendered = view.head - 1
  else
    while view.display[removed + 1] and view.display[removed + 1] < view.head do
      removed = removed + 1
    end
    if removed > 0 then
      local remaining = {}
      for i = removed + 1, #view.display do
        remaining[#remaining + 1] = view.display[i]
      end
      view.display = remaining
    end
  end
  for id = math.max(view.head, view.rendered + 1), view.tail do
    local entry = view.raw[id]
    if entry and matches(view, entry) then
      view.display[#view.display + 1] = id
      lines[#lines + 1] = entry.line
    end
  end
  view.rendered = view.tail
  view.rendering = true
  vim.bo[view.buf].modifiable = true
  if reset then
    vim.api.nvim_buf_set_lines(view.buf, 1, -1, false, lines)
  else
    if removed > 0 then
      vim.api.nvim_buf_set_lines(view.buf, 1, removed + 1, false, {})
    end
    if #lines > 0 then
      vim.api.nvim_buf_set_lines(view.buf, -1, -1, false, lines)
    end
  end
  vim.api.nvim_buf_set_lines(view.buf, 0, 1, false, { header(view) })
  vim.bo[view.buf].modifiable, vim.bo[view.buf].modified = false, false
  for _, win in ipairs(readers) do
    if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == view.buf then
      if view.windows[win].follow then
        vim.api.nvim_win_set_cursor(win, { #view.display + 1, 0 })
      else
        restore_position(view, win, saved[win])
      end
    end
  end
  for win in pairs(view.windows) do
    if not vim.api.nvim_win_is_valid(win) then
      view.windows[win] = nil
    end
  end
  view.rendering = false
end

local function schedule(view)
  if view.scheduled then
    return
  end
  view.scheduled = true
  vim.schedule(function()
    view.scheduled = false
    M.render(view)
  end)
end

function M.append(view, lines)
  if not valid(view) then
    return
  end
  for _, value in ipairs(lines or {}) do
    local line = tostring(value):gsub("\r$", "")
    if #line > view.max_line_bytes then
      line = clip(line, view.max_line_bytes) .. " … [line truncated]"
      view.truncated = view.truncated + 1
    end
    view.tail = view.tail + 1
    local entry = {
      line = line,
      lower = line:lower(),
      level = logcat.line_level(line),
      tag = line:match("^%d%d%-%d%d%s+[%d:%.]+%s+%d+%s+%d+%s+%u%s+([^:]+):") or "",
    }
    view.raw[view.tail], view.bytes = entry, view.bytes + #line
    while view.tail - view.head + 1 > view.max_lines or view.bytes > view.max_bytes do
      local old = view.raw[view.head]
      view.bytes = view.bytes - #old.line
      view.raw[view.head], view.head, view.dropped = nil, view.head + 1, view.dropped + 1
    end
  end
  schedule(view)
end

--- Unbuffered jobstart chunks include first/last partial lines. Join once;
--- retain a bounded unfinished line and flush it on reader exit.
function M.feed(view, data)
  if not valid(view) or not data or #data == 0 then
    return
  end
  local lines = {}
  for i, part in ipairs(data) do
    local combined = view.pending .. tostring(part)
    if i < #data then
      lines[#lines + 1] = combined .. (view.pending_truncated and " … [line truncated]" or "")
      view.pending, view.pending_truncated = "", false
    elseif #combined > view.max_line_bytes then
      view.pending, view.pending_truncated = clip(combined, view.max_line_bytes), true
    else
      view.pending = combined
    end
  end
  if #lines > 0 then
    M.append(view, lines)
  end
end

function M.stopped(view, reason)
  if not valid(view) then
    return
  end
  if view.pending ~= "" then
    M.append(view, { view.pending .. (view.pending_truncated and " … [line truncated]" or "") })
    view.pending, view.pending_truncated = "", false
  end
  view.running, view.reason = false, reason or "已停止"
  schedule(view)
end

function M.filter(view, opts)
  if not valid(view) then
    return
  end
  opts = opts or {}
  if opts.level then
    view.level = priority[opts.level] and opts.level or "V"
  end
  if opts.text ~= nil then
    view.text = tostring(opts.text):gsub("[\r\n]", " ")
  end
  if opts.tag ~= nil then
    view.tag = tostring(opts.tag):gsub("[\r\n]", " ")
  end
  M.render(view, true)
end

function M.follow(view, enabled, win)
  if not valid(view) then
    return
  end
  view.follow = enabled ~= false
  view.rendering = true
  for _, reader in ipairs(visible_windows(view)) do
    if not win or win == reader then
      view.windows[reader] = { follow = view.follow }
      if view.follow then
        vim.api.nvim_win_set_cursor(reader, { #view.display + 1, 0 })
      end
    end
  end
  view.rendering = false
  schedule(view)
end

function M.shown(view, win)
  if not valid(view) or not win or not vim.api.nvim_win_is_valid(win) then
    return
  end
  view.windows[win] = view.windows[win] or { follow = view.follow }
  view.rendering = true
  if view.windows[win].follow then
    vim.api.nvim_win_set_cursor(win, { #view.display + 1, 0 })
  elseif view.saved_position then
    restore_position(view, win, view.saved_position)
  end
  view.rendering = false
end

function M.new(opts)
  opts = opts or {}
  local buf = opts.buf or vim.api.nvim_create_buf(false, true)
  local view = {
    buf = buf,
    raw = {},
    head = 1,
    tail = 0,
    rendered = 0,
    display = {},
    bytes = 0,
    pending = "",
    dropped = 0,
    truncated = 0,
    windows = {},
    follow = true,
    running = false,
    level = opts.level or "V",
    text = "",
    tag = "",
    max_lines = opts.max_lines or M.MAX_LINES,
    max_bytes = opts.max_bytes or M.MAX_BYTES,
    max_line_bytes = opts.max_line_bytes or M.MAX_LINE_BYTES,
  }
  vim.bo[buf].buftype, vim.bo[buf].bufhidden, vim.bo[buf].filetype = "nofile", "hide", "log"
  vim.api.nvim_buf_set_name(buf, opts.name or ("ue-dap-logcat://" .. buf))
  vim.b[buf].ue_dap_logcat = true
  logcat.attach(buf)
  local map = function(lhs, callback, description)
    vim.keymap.set("n", lhs, callback, { buffer = buf, nowait = true, silent = true, desc = description })
  end
  map("gf", function()
    M.follow(view, not view.follow, vim.api.nvim_get_current_win())
  end, "Logcat: pause/resume following")
  map("G", function()
    M.follow(view, true, vim.api.nvim_get_current_win())
  end, "Logcat: bottom and resume following")
  map("gl", function()
    M.filter(view, { level = logcat.next_level(view.level) })
  end, "Logcat: filter minimum level without restarting")
  map("g/", function()
    vim.ui.input({ prompt = "Logcat 内容（留空显示全部）: ", default = view.text }, function(text)
      if text ~= nil then
        M.filter(view, { text = text })
      end
    end)
  end, "Logcat: filter retained content")
  map("gt", function()
    vim.ui.input({ prompt = "Logcat tag（留空显示全部）: ", default = view.tag }, function(tag)
      if tag ~= nil then
        M.filter(view, { tag = tag })
      end
    end)
  end, "Logcat: filter retained tags")
  map("g0", function()
    M.filter(view, { level = "V", text = "", tag = "" })
  end, "Logcat: clear filters")
  map("q", function()
    pcall(vim.api.nvim_win_close, 0, true)
  end, "Logcat: hide history; keep reader")
  local group = vim.api.nvim_create_augroup("ue_dap_logcat_view_" .. buf, { clear = true })
  vim.api.nvim_create_autocmd({ "CursorMoved", "WinScrolled" }, {
    group = group,
    buffer = buf,
    callback = function()
      local win = vim.api.nvim_get_current_win()
      if view.rendering or not valid(view) or vim.api.nvim_win_get_buf(win) ~= buf then
        return
      end
      if vim.api.nvim_win_get_cursor(win)[1] < vim.api.nvim_buf_line_count(buf) then
        view.windows[win], view.follow = { follow = false }, false
        view.saved_position = position(view, win)
        schedule(view)
      end
    end,
  })
  vim.api.nvim_create_autocmd("BufWinLeave", {
    group = group,
    buffer = buf,
    callback = function()
      for _, win in ipairs(visible_windows(view)) do
        if not (view.windows[win] and view.windows[win].follow) then
          view.saved_position = position(view, win)
        end
      end
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    buffer = buf,
    once = true,
    callback = function()
      if opts.on_wipe then
        opts.on_wipe()
      end
      pcall(vim.api.nvim_del_augroup_by_id, group)
    end,
  })
  M.render(view, true)
  return view
end

return M
