-- Explicit scope and masks for indexed results. No scans or background jobs.
local M = {}
local fs = require("ue.core.fs")

function M.roots(ctx)
  local roots, seen = {}, {}
  for _, root in ipairs({ ctx.project_root or "", ctx.engine_root or "" }) do
    root = fs.norm(root)
    if root ~= "" and not seen[root] then
      roots[#roots + 1], seen[root] = root, true
    end
  end
  return roots
end

function M.path_filter(roots)
  if not roots or #roots == 0 then
    return nil
  end
  local parts = {}
  for _, root in ipairs(roots) do
    root = fs.norm(root)
    local escaped = root:gsub("([\\%^%$%.%|%?%*%+%(%)%[%]%{%}])", "\\%1")
    local stat = vim.uv.fs_stat(root)
    parts[#parts + 1] = "^" .. escaped .. (stat and stat.type == "file" and "$" or "/")
  end
  local driver = require("utils.platform").driver()
  local ignore_case = driver.path_key("A") == driver.path_key("a")
  return (ignore_case and "(?i)" or "") .. "(" .. table.concat(parts, "|") .. ")"
end

function M.title(base, options)
  local label = options.ue_scope_kind or "workspace"
  local masks = {}
  if #(options.glob or {}) > 0 then
    masks[#masks + 1] = "include:" .. table.concat(options.glob, ",")
  end
  if #(options.exclude or {}) > 0 then
    masks[#masks + 1] = "exclude:" .. table.concat(options.exclude, ",")
  end
  if #(options.ft or {}) > 0 then
    masks[#masks + 1] = "types:" .. table.concat(options.ft, ",")
  end
  return base
    .. " [indexed scope: "
    .. label
    .. "]"
    .. (#masks > 0 and (" [" .. table.concat(masks, "; ") .. "]") or "")
end

function M.choose_scope(picker, ctx, module, source_path, update)
  local options = { { label = "Workspace: indexed Project + Engine", kind = "workspace", roots = M.roots(ctx) } }
  for _, item in ipairs({
    { label = "Project: indexed project files", kind = "project", root = ctx.project_root },
    { label = "Engine: indexed engine files", kind = "engine", root = ctx.engine_root },
    {
      label = "Current directory: indexed files",
      kind = "directory",
      root = source_path ~= "" and vim.fs.dirname(source_path) or nil,
    },
    { label = "Current file: indexed file", kind = "file", root = source_path ~= "" and source_path or nil },
    { label = "Current module/plugin: indexed files", kind = "module", root = module and module.root },
  }) do
    if item.root then
      item.roots = { item.root }
      options[#options + 1] = item
    end
  end
  vim.ui.select(options, {
    prompt = "Search scope",
    format_item = function(item)
      return item.label
    end,
  }, function(item)
    if not item or picker.closed then
      return
    end
    picker.opts.ue_scope_kind, picker.opts.ue_scope_roots = item.kind, item.roots
    picker.opts.scoped = item.kind == "module"
    update(picker)
    picker.list:set_target()
    picker:find()
  end)
end

local function split(value)
  local result = {}
  for _, entry in ipairs(vim.split(value or "", ",", { plain = true, trimempty = true })) do
    entry = vim.trim(entry)
    if entry ~= "" then
      result[#result + 1] = entry
    end
  end
  return result
end

function M.masks(picker, update)
  local values = {}
  local fields = {
    { "glob", "Include files: comma-separated globs (empty = all)" },
    { "exclude", "Exclude files: comma-separated globs (empty = none)" },
    { "ft", "File extensions: comma-separated (empty = all indexed types)" },
  }
  local function step(index)
    if picker.closed then
      return
    end
    local field = fields[index]
    if not field then
      local filter, err = require("utils.code_search.picker").compile_filter({
        include = values.glob,
        exclude = values.exclude,
        types = values.ft,
      })
      if not filter then
        vim.notify(err, vim.log.levels.WARN)
        return
      end
      picker.opts.glob, picker.opts.exclude, picker.opts.ft = values.glob, values.exclude, values.ft
      update(picker)
      picker.list:set_target()
      picker:find()
      return
    end
    vim.ui.input({ prompt = field[2], default = table.concat(picker.opts[field[1]] or {}, ",") }, function(value)
      if value == nil or picker.closed then
        return
      end
      values[field[1]] = split(value)
      step(index + 1)
    end)
  end
  step(1)
end

return M
