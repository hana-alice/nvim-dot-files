-- Presentation helpers shared by indexed search and explicit grep. Query and
-- post-result matcher remain separate; nothing here scans or changes scope.
local M = {}
local platform = require("utils.platform")

local function normalize(path)
  return tostring(path or ""):gsub("\\", "/"):gsub("/+$", "")
end

local function comparison(path)
  return platform.driver().path_key(normalize(path))
end

function M.picker_options(opts)
  return vim.tbl_deep_extend("force", {}, opts or {}, { supports_live = true })
end

function M.query(picker)
  return picker.input and picker.input.filter and picker.input.filter.search or ""
end

local function patterns(values)
  if values == nil then
    return {}
  end
  if type(values) == "string" then
    values = { values }
  end
  if type(values) ~= "table" or not vim.islist(values) or #values > 16 then
    return nil, "file filters must contain at most 16 globs"
  end
  local out = {}
  for _, value in ipairs(values) do
    if type(value) ~= "string" or #value > 256 or value:find("[%z\r\n]") then
      return nil, "invalid file glob"
    end
    if value ~= "" then
      value = comparison(value)
      local ok, glob = pcall(vim.glob.to_lpeg, value)
      if not ok then
        return nil, "invalid file glob: " .. value
      end
      out[#out + 1] = { glob = glob, basename = not value:find("/", 1, true) }
    end
  end
  return out
end

local function matches(globs, path, relative)
  for _, entry in ipairs(globs) do
    local candidates = entry.basename and { vim.fs.basename(path) } or { path, relative }
    for _, candidate in ipairs(candidates) do
      if entry.glob:match(candidate) then
        return true
      end
    end
  end
  return false
end

function M.compile_filter(spec)
  spec = spec or {}
  local include, err = patterns(spec.include)
  if not include then
    return nil, err
  end
  local exclude
  exclude, err = patterns(spec.exclude)
  if not exclude then
    return nil, err
  end
  local types, type_set = spec.types or {}, {}
  if type(types) == "string" then
    types = { types }
  end
  if type(types) ~= "table" or not vim.islist(types) or #types > 16 then
    return nil, "file types must contain at most 16 extensions"
  end
  for _, ext in ipairs(types) do
    if type(ext) ~= "string" or #ext > 32 or not ext:match("^[%w_+.-]+$") then
      return nil, "invalid file extension"
    end
    type_set[ext:gsub("^%.", ""):lower()] = true
  end
  local values = spec.roots or (spec.root ~= nil and { spec.root } or {})
  if type(values) ~= "table" or not vim.islist(values) or #values > 16 then
    return nil, "filter scope must contain at most 16 roots"
  end
  local roots = {}
  for _, value in ipairs(values) do
    if type(value) ~= "string" or #value > 4096 or value:find("[%z\r\n]") then
      return nil, "invalid filter root"
    end
    local root = comparison(value)
    if root ~= "" then
      roots[#roots + 1] = root
    end
  end
  table.sort(roots, function(a, b)
    return #a > #b
  end)
  return {
    spec = vim.deepcopy(spec),
    match = function(item)
      local path = comparison(item.file)
      if path == "" then
        return false
      end
      local relative = path
      if #roots > 0 then
        local found = false
        for _, root in ipairs(roots) do
          if path == root or path:sub(1, #root + 1) == root .. "/" then
            relative, found = path:sub(#root + 2), true
            break
          end
        end
        if not found then
          return false
        end
      end
      if next(type_set) then
        local allowed, lower = false, path:lower()
        for ext in pairs(type_set) do
          if lower:sub(-#ext - 1) == "." .. ext then
            allowed = true
            break
          end
        end
        if not allowed then
          return false
        end
      end
      return (#include == 0 or matches(include, path, relative)) and not matches(exclude, path, relative)
    end,
  }
end

function M.filter_item(item, filter)
  return filter == nil or filter.match(item)
end

function M.status_label(meta)
  meta = meta or { state = "waiting" }
  local count = tonumber(meta.delivered) or 0
  local labels = {
    waiting = "等待输入",
    running = "搜索中",
    empty = "已搜索范围内没有结果",
    complete = ("%d 行结果"):format(count),
    truncated = ("前 %d 行 · 结果不完整"):format(count),
    timeout = ("搜索超时 · 已取得 %d 行（不完整）"):format(count),
    canceled = ("已取消 · 已取得 %d 行（不完整）"):format(count),
    error = meta.reason == "invalid-pattern" and "搜索模式无效" or "搜索失败",
    index_unavailable = "索引不可用",
  }
  return labels[meta.state] or "搜索状态未知"
end

function M.scope_summary(scope)
  scope = scope or {}
  local parts = { "范围: " .. tostring(scope.label or "未确认") }
  if scope.excluded and #scope.excluded > 0 then
    parts[#parts + 1] = "排除: " .. table.concat(scope.excluded, ", ")
  end
  if scope.types and #scope.types > 0 then
    parts[#parts + 1] = "类型: " .. table.concat(scope.types, ", ")
  end
  if scope.complete == false then
    parts[#parts + 1] = "范围覆盖未确认"
  end
  return table.concat(parts, " · ")
end

return M
