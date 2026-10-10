-- File-picker input boundary. External locations use one-based byte columns;
-- Snacks items and Neovim cursors use zero-based byte columns.
local M = {}
local fs = require("ue.core.fs")

local function unquote(value)
  local quote = value:sub(1, 1)
  if (quote == '"' or quote == "'") and value:sub(-1) == quote then
    return value:sub(2, -2)
  end
  return value
end

function M.parse(value)
  local input = vim.trim(tostring(value or ""))
  local path, line, column = input:match("^(.-):(%d+):(%d+)$")
  if not path then
    path, line = input:match("^(.-):(%d+)$")
  end
  path = unquote(path or input)
  local file_like = path:find("[/\\]") or path:match("%.[%w_+%-]+$")
  if line and not file_like then
    path, line, column = unquote(input), nil, nil
  end
  local pos = line and { math.max(1, tonumber(line)), math.max(0, (tonumber(column) or 1) - 1) } or nil
  return { pattern = fs.norm(path), pos = pos }
end

function M.transform(item)
  local out = vim.tbl_extend("force", {}, item)
  if type(item.file) == "string" then
    out.file = fs.norm(item.file)
  end
  if type(item.text) == "string" then
    out.text = item.text:gsub("\\", "/")
  end
  if type(item.cwd) == "string" then
    out.cwd = fs.norm(item.cwd)
  end
  return out
end

function M.filter(picker, filter)
  local parsed = M.parse(filter.pattern)
  filter.pattern = parsed.pattern
  -- This field belongs only to this explicit file picker/matcher. It is not a
  -- global cursor guard and never changes the displayed input or content grep.
  picker.matcher._ue_file_position = parsed.pos
end

function M.on_match(matcher, item)
  local pos = matcher._ue_file_position
  if pos and item.file then
    item.pos = { pos[1], pos[2] }
    item.match_pos = true
  end
end

function M.position_text(path, pos, line_only)
  path = fs.norm(path)
  if path:find("%s") then
    path = '"' .. path .. '"'
  end
  return path
    .. ":"
    .. tostring(pos and pos[1] or 1)
    .. (line_only and "" or (":" .. tostring((pos and pos[2] or 0) + 1)))
end

function M.byte_position(picker, item)
  if item.ue_location and item.ue_location.precision == "line" then
    return item.pos, "line"
  end
  local loc = item.loc
  if not loc then
    return item.pos, "exact"
  end
  local start = loc.range and loc.range.start
  if
    not start
    or type(start.line) ~= "number"
    or type(start.character) ~= "number"
    or start.line < 0
    or start.character < 0
    or start.line % 1 ~= 0
    or start.character % 1 ~= 0
  then
    return item.pos, "line"
  end
  local buffer = item.buf or (item.file and vim.fn.bufnr(item.file))
  if not buffer or buffer <= 0 or not vim.api.nvim_buf_is_loaded(buffer) then
    local preview = picker.preview
    local preview_item = preview and preview.item
    local same_file = preview_item
      and preview_item.file
      and item.file
      and fs.norm(preview_item.file) == fs.norm(item.file)
    buffer = same_file and preview.win and preview.win.buf or nil
  end
  local line = buffer
      and vim.api.nvim_buf_is_loaded(buffer)
      and vim.api.nvim_buf_get_lines(buffer, start.line, start.line + 1, false)[1]
    or nil
  local encoding = loc.encoding
  if not line or not ({ ["utf-8"] = true, ["utf-16"] = true, ["utf-32"] = true })[encoding] then
    return { start.line + 1, 0 }, "line"
  end
  local ok, byte = pcall(vim.str_byteindex, line, encoding, start.character, true)
  if not ok then
    return { start.line + 1, 0 }, "line"
  end
  return { start.line + 1, byte }, "exact"
end

function M.copy(picker, item, kind)
  if not item then
    return
  end
  local utils = require("snacks").picker.util
  utils.resolve(item)
  local path = utils.path(item)
  if not path then
    return
  end
  path = fs.norm(vim.fn.fnamemodify(path, ":p"))
  local root = picker.opts.ue_search_context and picker.opts.ue_search_context.project_root or picker:cwd()
  if not picker.opts.ue_search_context and #(picker.opts.dirs or {}) == 1 then
    root = picker.opts.dirs[1]
  end
  local value = kind == "relative" and fs.relative_to(root, path) or path
  local label = kind .. " path"
  if kind == "position" then
    local pos, precision = M.byte_position(picker, item)
    value = M.position_text(path, pos, precision == "line")
    label = precision == "line" and "path:line (column unavailable)" or "path:line:byte-column"
  end
  vim.fn.setreg('"', value)
  pcall(vim.fn.setreg, "+", value)
  vim.notify("Copied " .. label)
  return value
end

---Add only file-source transforms; callers' existing transforms still run.
function M.options(opts)
  opts = vim.deepcopy(opts or {})
  local old_transform = opts.transform
  opts.transform = function(item, ctx)
    if type(old_transform) == "function" then
      local result = old_transform(item, ctx)
      if result == false then
        return false
      end
      item = type(result) == "table" and result or item
    end
    return M.transform(item)
  end
  opts.filter = opts.filter or {}
  local old_filter = opts.filter.transform
  opts.filter.transform = function(picker, filter)
    local refresh = old_filter and old_filter(picker, filter)
    M.filter(picker, filter)
    return refresh
  end
  opts.matcher = opts.matcher or {}
  local old_match = opts.matcher.on_match
  opts.matcher.on_match = function(matcher, item)
    if old_match then
      old_match(matcher, item)
    end
    M.on_match(matcher, item)
  end
  opts.jump = vim.tbl_extend("force", opts.jump or {}, { match = false })
  return opts
end

return M
