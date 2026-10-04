-- Serializable search intent. Provider names and arguments are data, never
-- arbitrary picker names, Ex commands or shell command strings.
local M = {}
local fs = require("ue.core.fs")

M.limits = { query = 4096, path = 2048, filter = 256, pattern = 2048, roots = 8, filters = 16 }
local SOURCES = { ue_grep_csearch = true, grep = true }
local SCOPES = { workspace = true, project = true, engine = true, module = true, directory = true, file = true }
local CASES = { ignore = true, sensitive = true, smart = true }

local function fields(value, allowed, label)
  if type(value) ~= "table" then
    return nil, label .. " must be an object"
  end
  for key in pairs(value) do
    if not allowed[key] then
      return nil, label .. " contains unsupported field: " .. tostring(key)
    end
  end
  return true
end

local function string_value(value, limit, label, empty)
  if type(value) ~= "string" or #value > limit or value:find("[%z\r\n]") or (not empty and value == "") then
    return nil, "invalid or oversized " .. label
  end
  return value
end

local function list(value, limit, length, label)
  if value == nil then
    return {}
  end
  if type(value) ~= "table" or #value > limit then
    return nil, "too many " .. label
  end
  local out = {}
  for key in pairs(value) do
    if type(key) ~= "number" or key < 1 or key % 1 ~= 0 or key > #value then
      return nil, "invalid " .. label .. " list"
    end
  end
  for _, entry in ipairs(value) do
    local validated, err = string_value(entry, length, label)
    if not validated then
      return nil, err
    end
    out[#out + 1] = validated
  end
  return out
end

function M.canonical(path)
  if type(path) ~= "string" or path == "" then
    return ""
  end
  path = vim.fs.normalize(fs.norm(path))
  return fs.norm(vim.uv.fs_realpath(path) or vim.fn.fnamemodify(path, ":p"))
end

function M.path_key(path)
  return require("utils.platform").driver().path_key(M.canonical(path))
end

function M.context(ctx)
  if not ctx then
    local ok, ue = pcall(require, "ue")
    if ok and type(ue.resolve_context) == "function" then
      local resolved, value = pcall(ue.resolve_context)
      if resolved then
        ctx = value
      end
    end
  end
  ctx = ctx or {}
  local root = M.canonical(ctx.project_root or ctx.engine_root or vim.uv.cwd())
  return { root = root, identity = M.canonical(ctx.uproject or root), engine = M.canonical(ctx.engine_root) }
end

function M.validate(value)
  local ok, err = fields(
    value,
    { version = true, source = true, query = true, project = true, scope = true, mode = true, filters = true },
    "recipe"
  )
  if not ok then
    return nil, err
  end
  if value.version ~= 1 then
    return nil, "unsupported search recipe version"
  end
  if not SOURCES[value.source] then
    return nil, "unsupported search source"
  end
  local query, query_err = string_value(value.query, M.limits.query, "query")
  if not query then
    return nil, query_err
  end
  if value.source == "grep" and query:find("%s+%-%-") then
    return nil, "serialized rg queries cannot contain raw inline arguments"
  end
  for _, object in ipairs({
    { value.project, { root = true, identity = true, engine = true }, "project" },
    { value.scope, { kind = true, roots = true, code_only = true }, "scope" },
    { value.mode, { regex = true, case = true, word = true }, "mode" },
    {
      value.filters,
      {
        include = true,
        exclude = true,
        extensions = true,
        pattern = true,
        hidden = true,
        ignored = true,
        follow = true,
        extra_globs = true,
      },
      "filters",
    },
  }) do
    ok, err = fields(unpack(object))
    if not ok then
      return nil, err
    end
  end
  local project = {}
  for _, key in ipairs({ "root", "identity", "engine" }) do
    local path, path_err = string_value(value.project[key], M.limits.path, "project " .. key, key == "engine")
    if not path or (path ~= "" and not fs.is_absolute_path(path)) then
      return nil, path_err or "project path must be absolute"
    end
    project[key] = path ~= "" and M.canonical(path) or ""
  end
  if not SCOPES[value.scope.kind] then
    return nil, "unsupported search scope"
  end
  local roots, roots_err = list(value.scope.roots, M.limits.roots, M.limits.path, "scope roots")
  if not roots or #roots == 0 then
    return nil, roots_err or "scope roots are empty"
  end
  for index, root in ipairs(roots) do
    if not fs.is_absolute_path(root) then
      return nil, "scope root must be absolute"
    end
    roots[index] = M.canonical(root)
    if
      not fs.path_has_prefix(M.path_key(roots[index]), M.path_key(project.root))
      and not (project.engine ~= "" and fs.path_has_prefix(M.path_key(roots[index]), M.path_key(project.engine)))
    then
      return nil, "scope root belongs to another project"
    end
  end
  if type(value.scope.code_only) ~= "boolean" then
    return nil, "code_only must be boolean"
  end
  if type(value.mode.regex) ~= "boolean" or type(value.mode.word) ~= "boolean" or not CASES[value.mode.case] then
    return nil, "invalid search mode"
  end
  local filters = {}
  for _, key in ipairs({ "include", "exclude", "extensions", "extra_globs" }) do
    filters[key], err = list(value.filters[key], M.limits.filters, M.limits.filter, key)
    if not filters[key] then
      return nil, err
    end
  end
  for _, extension in ipairs(filters.extensions) do
    if #extension > 32 or not extension:match("^[%w_+.-]+$") or extension:sub(1, 1) == "-" then
      return nil, "invalid file extension/type"
    end
  end
  if value.source == "grep" then
    for _, key in ipairs({ "include", "extra_globs" }) do
      for _, glob in ipairs(filters[key]) do
        if glob:sub(1, 1) == "-" then
          return nil, "rg masks cannot begin with an argument prefix"
        end
      end
    end
  end
  if value.source == "ue_grep_csearch" and #filters.extra_globs > 0 then
    return nil, "ordered rg globs cannot execute on csearch"
  end
  filters.pattern, err = string_value(value.filters.pattern or "", M.limits.pattern, "result filter", true)
  if not filters.pattern then
    return nil, err
  end
  for _, key in ipairs({ "hidden", "ignored", "follow" }) do
    if type(value.filters[key]) ~= "boolean" then
      return nil, key .. " must be boolean"
    end
    filters[key] = value.filters[key]
  end
  return {
    version = 1,
    source = value.source,
    query = query,
    project = project,
    scope = { kind = value.scope.kind, roots = roots, code_only = value.scope.code_only },
    mode = { regex = value.mode.regex, case = value.mode.case, word = value.mode.word },
    filters = filters,
  }
end

local function as_list(value)
  return type(value) == "string" and { value } or vim.deepcopy(value or {})
end

local function split_args(query)
  local content, extra = query:match("^(.-)%s+%-%-%s*(.*)$")
  if not extra then
    return query, {}
  end
  -- Match the installed provider's grammar, including quote characters in
  -- argv. This does not interpret shell escapes or strip shell quoting.
  extra = vim.trim(extra:gsub("%s+", " "))
  local args, quote, from = {}, nil, 1
  for index = 1, #extra do
    local character = extra:sub(index, index)
    if character == "'" or character == '"' then
      if quote == character then
        quote = nil
      else
        quote = character
      end
    elseif character == " " and not quote then
      args[#args + 1] = extra:sub(from, index - 1)
      from = index + 1
    end
  end
  if from <= #extra then
    args[#args + 1] = extra:sub(from)
  end
  return vim.trim(content), args
end

local function apply_args(recipe, args)
  local index = 1
  while index <= #args do
    local arg = args[index]
    if arg == "-w" or arg == "--word-regexp" then
      recipe.mode.word = true
    elseif arg == "-F" or arg == "--fixed-strings" then
      recipe.mode.regex = false
    elseif arg == "-s" or arg == "--case-sensitive" then
      recipe.mode.case = "sensitive"
    elseif arg == "-i" or arg == "--ignore-case" then
      recipe.mode.case = "ignore"
    elseif arg == "-S" or arg == "--smart-case" then
      recipe.mode.case = "smart"
    elseif arg == "--hidden" then
      recipe.filters.hidden = true
    elseif arg == "--no-hidden" then
      recipe.filters.hidden = false
    elseif arg == "--no-ignore" then
      recipe.filters.ignored = true
    elseif arg == "-L" or arg == "--follow" then
      recipe.filters.follow = true
    elseif arg == "-g" or arg == "--glob" or arg == "-t" or arg == "--type" then
      index = index + 1
      local value = args[index]
      if not value then
        return nil, "search argument is missing its value"
      end
      if arg == "-t" or arg == "--type" then
        recipe.filters.extensions[#recipe.filters.extensions + 1] = value
      else
        recipe.filters.extra_globs[#recipe.filters.extra_globs + 1] = value
      end
    else
      return nil, "unsupported search argument: " .. tostring(arg)
    end
    index = index + 1
  end
  return true
end

local function compact_globs(values)
  if #values <= M.limits.filters then
    return values
  end
  local extensions = {}
  for _, value in ipairs(values) do
    local extension = value:match("^%*%.([%w_+.-]+)$")
    if not extension then
      return values
    end
    extensions[#extensions + 1] = extension
  end
  -- A positive extension union is one equivalent native rg brace glob. This
  -- retains the existing 25-entry code filter within the 16-mask budget.
  return { "*.{" .. table.concat(extensions, ",") .. "}" }
end

function M.capture(source, opts, state, ctx)
  opts, state = opts or {}, state or {}
  local project = M.context(ctx)
  local query = state.search or opts.search or ""
  local inline_args = {}
  if source == "grep" then
    query, inline_args = split_args(query)
  end
  local roots = opts.ue_scope_roots or opts.dirs
  if not roots or #roots == 0 then
    roots = source == "ue_grep_csearch" and project.engine ~= "" and { project.engine, project.root }
      or { opts.cwd or project.root }
  end
  roots = vim.tbl_map(M.canonical, roots)
  local value = {
    version = 1,
    source = source,
    query = query,
    project = project,
    scope = { kind = opts.ue_scope_kind or "workspace", roots = roots, code_only = opts.code_only ~= false },
    mode = {
      regex = opts.regex ~= false,
      case = source == "ue_grep_csearch" and (opts.case == true and "sensitive" or "ignore") or "smart",
      word = opts.word == true,
    },
    filters = {
      include = as_list(opts.glob),
      exclude = as_list(opts.exclude),
      extensions = as_list(opts.ft),
      pattern = state.pattern or opts.pattern or "",
      hidden = opts.hidden == true,
      ignored = opts.ignored == true,
      follow = opts.follow == true,
      extra_globs = {},
    },
  }
  if source == "ue_grep_csearch" then
    value.mode.regex = opts.regex == true
    value.scope.kind = opts.scoped == true and "module" or value.scope.kind
  end
  local args = as_list(opts.args)
  vim.list_extend(args, inline_args)
  local safe, err = apply_args(value, args)
  if not safe then
    return nil, err
  end
  local positive_only = true
  for _, glob in ipairs(value.filters.extra_globs) do
    if glob:sub(1, 1) == "!" then
      positive_only = false
    end
  end
  if positive_only then
    vim.list_extend(value.filters.include, value.filters.extra_globs)
    value.filters.extra_globs = {}
  end
  if source == "grep" then
    value.filters.include = compact_globs(value.filters.include)
  end
  return M.validate(value)
end

function M.from_picker(picker, ctx)
  if not picker or not picker.opts then
    return nil, "search picker is unavailable"
  end
  local opts = picker.opts
  if opts.ue_search_recipe then
    local base, err = M.validate(opts.ue_search_recipe)
    if not base then
      return nil, err
    end
    local frozen =
      { project_root = base.project.root, uproject = base.project.identity, engine_root = base.project.engine }
    return M.capture(opts.source, opts, picker.input and picker.input.filter, frozen)
  end
  return M.capture(opts.source, opts, picker.input and picker.input.filter, ctx or opts.ue_search_context)
end

local function stable(value)
  if type(value) ~= "table" then
    return vim.json.encode(value)
  end
  if vim.islist(value) then
    local values = {}
    for _, item in ipairs(value) do
      values[#values + 1] = stable(item)
    end
    return "[" .. table.concat(values, ",") .. "]"
  end
  local values = {}
  for _, key in ipairs(vim.tbl_keys(value)) do
    values[#values + 1] = key
  end
  table.sort(values)
  for index, key in ipairs(values) do
    values[index] = vim.json.encode(key) .. ":" .. stable(value[key])
  end
  return "{" .. table.concat(values, ",") .. "}"
end

function M.identity(value)
  local recipe, err = M.validate(value)
  if not recipe then
    return nil, err
  end
  -- Regex escape classes (\S versus \s) remain different under ignore-case.
  if recipe.mode.case == "ignore" and not recipe.mode.regex then
    recipe.query = recipe.query:lower()
  end
  return vim.fn.sha256(stable(recipe))
end

function M.describe(value)
  local recipe, err = M.validate(value)
  if not recipe then
    return "unavailable: " .. tostring(err)
  end
  return ("%s · %s · %s/%s%s · +%d/−%d filters"):format(
    recipe.source == "grep" and "rg" or "csearch",
    recipe.scope.kind,
    recipe.mode.regex and "regex" or "literal",
    recipe.mode.case,
    recipe.mode.word and "/word" or "",
    #recipe.filters.include,
    #recipe.filters.exclude
  )
end

function M.confirm(picker, item, action)
  if item then
    local recipe, err = M.from_picker(picker)
    if recipe then
      require("utils.history_hub").record_recipe(recipe)
    elseif err then
      vim.notify("Search history could not retain these options: " .. err, vim.log.levels.WARN)
    end
  end
  return require("snacks.picker.actions").jump(picker, item, action)
end

function M.save_resume_options(picker)
  if not picker.init_opts then
    return
  end
  -- Native resume already stores input, selection, viewport and toggles. These
  -- custom scope/mask options are not toggles, so preserve only their small data.
  for _, field in ipairs({ "ue_scope_kind", "ue_scope_roots", "dirs", "cwd", "glob", "exclude", "ft", "code_only" }) do
    picker.init_opts[field] = vim.deepcopy(picker.opts[field])
  end
end

function M.grep_finder(opts, ctx)
  local base = opts.ue_search_title or opts.title or "Grep"
  local current_recipe = M.capture("grep", opts, ctx.filter, opts.ue_search_context)
  ctx.picker.opts.ue_search_base_title = current_recipe and (base .. " [" .. M.describe(current_recipe) .. "]") or base
  local native_options
  local proxy = setmetatable({
    opts = function(_, value)
      native_options = ctx:opts(value)
      return native_options
    end,
  }, { __index = ctx })
  local finder = require("snacks.picker.source.grep").grep(opts, proxy)
  if not native_options then
    local ui = require("utils.search_ui")
    local generation = ui.begin(ctx.picker)
    ui.status(ctx.picker, { state = "waiting", complete = false, delivered = 0 }, generation)
    return finder
  end
  return require("utils.search_process").find(native_options, ctx)
end

function M.open_grep(opts, scope_kind, ctx)
  if type(opts) ~= "table" then
    return nil, "search scope is unavailable"
  end
  opts = vim.deepcopy(opts)
  opts.ue_search_context = ctx or M.context()
  -- M.context produces the persistence shape; capture also accepts live ctx.
  if not opts.ue_search_context.project_root then
    local project = opts.ue_search_context
    opts.ue_search_context = { project_root = project.root, uproject = project.identity, engine_root = project.engine }
  end
  opts.ue_scope_kind = scope_kind or opts.ue_scope_kind or "workspace"
  opts.ue_search_title = opts.ue_search_title or opts.title or "Grep"
  opts.confirm = M.confirm
  return require("snacks").picker.grep(opts)
end

function M.run(value)
  local recipe, err = M.validate(value)
  if not recipe then
    return nil, err
  end
  local current = M.context()
  if M.path_key(current.identity) ~= M.path_key(recipe.project.identity) then
    return nil, "This search belongs to another project; open its original project before restoring it"
  end
  for _, root in ipairs(recipe.scope.roots) do
    if not vim.uv.fs_stat(root) then
      return nil, "Original search scope is no longer available: " .. root
    end
  end
  local opts = {
    search = recipe.query,
    pattern = recipe.filters.pattern,
    regex = recipe.mode.regex,
    case = recipe.mode.case == "sensitive",
    word = recipe.mode.word,
    scoped = recipe.scope.kind == "module",
    code_only = recipe.scope.code_only,
    glob = recipe.filters.include,
    exclude = recipe.filters.exclude,
    ft = recipe.filters.extensions,
    hidden = recipe.filters.hidden,
    ignored = recipe.filters.ignored,
    follow = recipe.filters.follow,
    dirs = recipe.scope.roots,
    ue_scope_roots = recipe.scope.roots,
    ue_scope_kind = recipe.scope.kind,
    ue_search_recipe = recipe,
    ue_search_context = {
      project_root = recipe.project.root,
      uproject = recipe.project.identity,
      engine_root = recipe.project.engine,
    },
    title = "Restored search",
    ue_search_title = "Restored search",
  }
  if recipe.source == "ue_grep_csearch" then
    return require("ue").cached_grep(opts)
  end
  opts.args = { recipe.mode.case == "sensitive" and "-s" or recipe.mode.case == "ignore" and "-i" or "-S" }
  if recipe.mode.word then
    opts.args[#opts.args + 1] = "-w"
  end
  for _, glob in ipairs(recipe.filters.extra_globs) do
    vim.list_extend(opts.args, { "-g", glob })
  end
  return M.open_grep(opts, recipe.scope.kind, opts.ue_search_context)
end

return M
