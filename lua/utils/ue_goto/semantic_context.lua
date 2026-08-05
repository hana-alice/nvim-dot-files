-- utils.ue_goto.semantic_context
--
-- Pure-Lua semantic context model + provenance parsers for contextual C++
-- navigation. This module intentionally stays integration-free: no window
-- jumps, no LSP calls, no sidecar process management. It only normalizes
-- compiler evidence into deterministic, testable context records.

local M = {}

local function is_list(value)
  if vim.islist then
    return vim.islist(value)
  end
  if type(value) ~= "table" then
    return false
  end
  local count = 0
  for k, _ in pairs(value) do
    if type(k) ~= "number" or k < 1 or k % 1 ~= 0 then
      return false
    end
    count = count + 1
  end
  for i = 1, count do
    if value[i] == nil then
      return false
    end
  end
  return true
end

local function copy_list(list)
  local out = {}
  for i, value in ipairs(list or {}) do
    out[i] = value
  end
  return out
end

local function trim(text)
  return tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function stable_encode(value)
  local ty = type(value)
  if ty == "nil" then
    return "null"
  end
  if ty == "boolean" or ty == "number" then
    return tostring(value)
  end
  if ty == "string" then
    return string.format("%q", value)
  end
  if ty ~= "table" then
    return string.format("%q", tostring(value))
  end

  if is_list(value) then
    local parts = {}
    for i = 1, #value do
      parts[i] = stable_encode(value[i])
    end
    return "[" .. table.concat(parts, ",") .. "]"
  end

  local keys = {}
  for key, _ in pairs(value) do
    keys[#keys + 1] = key
  end
  table.sort(keys, function(a, b)
    return tostring(a) < tostring(b)
  end)

  local parts = {}
  for _, key in ipairs(keys) do
    parts[#parts + 1] = stable_encode(tostring(key)) .. ":" .. stable_encode(value[key])
  end
  return "{" .. table.concat(parts, ",") .. "}"
end

local function sha256(payload)
  return vim.fn.sha256(stable_encode(payload))
end

local function normalize_path(path)
  local raw = trim(path)
  if raw == "" then
    return ""
  end

  raw = raw:gsub("\\", "/")
  local prefix = ""
  if raw:match("^%a:/") then
    prefix = raw:sub(1, 2)
    raw = raw:sub(3)
  elseif raw:sub(1, 1) == "/" then
    prefix = "/"
    raw = raw:sub(2)
  end

  local parts = {}
  for part in raw:gmatch("[^/]+") do
    if part == "." or part == "" then
      -- drop
    elseif part == ".." then
      if #parts > 0 and parts[#parts] ~= ".." then
        table.remove(parts)
      elseif prefix == "" then
        parts[#parts + 1] = part
      end
    else
      parts[#parts + 1] = part
    end
  end

  local body = table.concat(parts, "/")
  if prefix == "/" then
    return body == "" and "/" or "/" .. body
  end
  if prefix ~= "" then
    return body == "" and (prefix .. "/") or (prefix .. "/" .. body)
  end
  return body
end

local function match_key(path)
  return normalize_path(path):lower()
end

local function resolve_relative(base_dir, path)
  local candidate = trim(path)
  if candidate == "" then
    return ""
  end
  if candidate:match("^%a:/") or candidate:sub(1, 1) == "/" then
    return normalize_path(candidate)
  end
  local base = normalize_path(base_dir)
  if base == "" then
    return normalize_path(candidate)
  end
  return normalize_path(base .. "/" .. candidate)
end

local function tokenize_shellish(text)
  local tokens = {}
  local current = {}
  local in_quotes = false
  local i = 1
  local len = #text

  local function push_current()
    if #current == 0 then
      return
    end
    tokens[#tokens + 1] = table.concat(current)
    current = {}
  end

  while i <= len do
    local ch = text:sub(i, i)
    if ch == '"' then
      in_quotes = not in_quotes
      i = i + 1
    elseif ch == "\\" then
      local next_ch = text:sub(i + 1, i + 1)
      if next_ch == '"' or next_ch == " " or next_ch == "\t" or next_ch == "\\" then
        current[#current + 1] = next_ch
        i = i + 2
      else
        current[#current + 1] = ch
        i = i + 1
      end
    elseif not in_quotes and ch:match("%s") then
      push_current()
      i = i + 1
    else
      current[#current + 1] = ch
      i = i + 1
    end
  end

  if in_quotes then
    return nil, "unterminated-quote"
  end

  push_current()
  return tokens
end

local function normalize_argv(argv)
  if not is_list(argv) or #argv == 0 then
    return nil, "missing-argv"
  end
  local out = {}
  for i, token in ipairs(argv) do
    if type(token) ~= "string" then
      return nil, "argv-token-not-string"
    end
    out[i] = token
  end
  return out
end

local function dedup_contexts(contexts)
  local seen = {}
  local out = {}
  for _, ctx in ipairs(contexts or {}) do
    if ctx and ctx.fingerprint and not seen[ctx.fingerprint] then
      seen[ctx.fingerprint] = true
      out[#out + 1] = ctx
    end
  end
  table.sort(out, function(a, b)
    return a.fingerprint < b.fingerprint
  end)
  return out
end

local function find_compile_entry(index, path)
  if not index or type(index) ~= "table" then
    return nil
  end
  local by_file = index.by_file or index
  return by_file[match_key(path)]
end

local function includes_path(list, wanted)
  local needle = match_key(wanted)
  for _, path in ipairs(list or {}) do
    if match_key(path) == needle then
      return true
    end
  end
  return false
end

local function source_like(token)
  local lower = token:lower()
  return lower:match("%.c$") ~= nil
    or lower:match("%.cc$") ~= nil
    or lower:match("%.cpp$") ~= nil
    or lower:match("%.cxx$") ~= nil
    or lower:match("%.mm$") ~= nil
end

function M.normalize_path(path)
  return normalize_path(path)
end

function M.match_key(path)
  return match_key(path)
end

function M.parse_compilation_entry(entry)
  if type(entry) ~= "table" then
    return nil, "entry-not-table"
  end

  local directory = normalize_path(entry.directory)
  local file = resolve_relative(directory, entry.file)
  if file == "" then
    return nil, "missing-file"
  end
  if directory == "" then
    return nil, "missing-directory"
  end

  local argv, err
  if entry.arguments ~= nil then
    argv, err = normalize_argv(entry.arguments)
  elseif type(entry.command) == "string" then
    argv, err = tokenize_shellish(entry.command)
    if argv then
      argv, err = normalize_argv(argv)
    end
  else
    err = "missing-command"
  end

  if not argv then
    return nil, err
  end

  return {
    file = file,
    directory = directory,
    argv = argv,
  }
end

function M.load_compilation_database(entries)
  if type(entries) ~= "table" then
    return nil, "entries-not-table"
  end

  local out = {
    entries = {},
    by_file = {},
  }

  for _, entry in ipairs(entries) do
    local parsed = M.parse_compilation_entry(entry)
    if parsed then
      out.entries[#out.entries + 1] = parsed
      out.by_file[match_key(parsed.file)] = parsed
    end
  end

  return out
end

function M.parse_cpp_json_record(decoded)
  if type(decoded) ~= "table" then
    return nil, "cpp-json-not-table"
  end

  local root = decoded.Data
  if type(root) ~= "table" then
    root = decoded
  end

  local source = normalize_path(root.Source)
  if source == "" then
    return nil, "cpp-json-missing-source"
  end
  if type(root.Includes) ~= "table" then
    return nil, "cpp-json-missing-includes"
  end

  local includes = {}
  for _, include in ipairs(root.Includes) do
    if type(include) == "string" and trim(include) ~= "" then
      includes[#includes + 1] = normalize_path(include)
    end
  end

  return {
    source = source,
    pch = normalize_path(root.PCH),
    includes = includes,
  }
end

function M.parse_depfile(text)
  if type(text) ~= "string" or text == "" then
    return nil, "depfile-empty"
  end

  local collapsed = text:gsub("\\\r\n", ""):gsub("\\\n", "")
  local colon_at = nil
  for i = 1, #collapsed do
    local ch = collapsed:sub(i, i)
    if ch == ":" then
      local next_ch = collapsed:sub(i + 1, i + 1)
      if next_ch ~= "/" and next_ch ~= "\\" then
        colon_at = i
        break
      end
    end
  end

  if not colon_at then
    return nil, "depfile-missing-rule"
  end

  local target = normalize_path(trim(collapsed:sub(1, colon_at - 1)))
  local deps_text = collapsed:sub(colon_at + 1)
  local deps = {}
  local current = {}
  local escape = false

  local function push_current()
    if #current == 0 then
      return
    end
    deps[#deps + 1] = normalize_path(table.concat(current))
    current = {}
  end

  for i = 1, #deps_text do
    local ch = deps_text:sub(i, i)
    if escape then
      current[#current + 1] = ch
      escape = false
    elseif ch == "\\" then
      local next_ch = deps_text:sub(i + 1, i + 1)
      if next_ch == " " or next_ch == "\t" or next_ch == "#"
          or next_ch == ":" or next_ch == "\\" then
        escape = true
      else
        current[#current + 1] = ch
      end
    elseif ch:match("%s") then
      push_current()
    else
      current[#current + 1] = ch
    end
  end
  push_current()

  return {
    target = target,
    dependencies = deps,
  }
end

function M.parse_rsp_tokens(text)
  if type(text) ~= "string" or text == "" then
    return nil, "rsp-empty"
  end
  return tokenize_shellish(text)
end

function M.rsp_source_file(tokens)
  if not is_list(tokens) then
    return nil
  end
  for i = #tokens, 1, -1 do
    local token = tokens[i]
    if type(token) == "string" and source_like(token) then
      return normalize_path(token)
    end
  end
  return nil
end

function M.parse_unity_membership(text, unity_path)
  if type(text) ~= "string" then
    return nil, "unity-not-string"
  end

  local unity_dir = normalize_path(unity_path or ""):match("^(.*)/[^/]+$") or ""
  local out = {}
  local seen = {}

  for line in text:gmatch("[^\r\n]+") do
    local include = line:match('^%s*#%s*include%s+"([^"]+)"')
    if include and source_like(include) then
      local resolved = resolve_relative(unity_dir, include)
      local key = match_key(resolved)
      if not seen[key] then
        seen[key] = true
        out[#out + 1] = resolved
      end
    end
  end

  return out
end

function M.make_semantic_context(spec)
  if type(spec) ~= "table" then
    return nil, "context-not-table"
  end

  local project_root = normalize_path(spec.project_root)
  local active_build_key = trim(spec.active_build_key)
  local origin_tu = normalize_path(spec.origin_tu)
  local toolchain_identity = trim(spec.toolchain_identity)
  local compile = spec.compile

  if project_root == "" then
    return nil, "missing-project-root"
  end
  if active_build_key == "" then
    return nil, "missing-active-build-key"
  end
  if origin_tu == "" then
    return nil, "missing-origin-tu"
  end
  if type(compile) ~= "table" then
    return nil, "missing-compile"
  end

  local compile_file = normalize_path(compile.file or origin_tu)
  local directory = normalize_path(compile.directory)
  local argv, argv_err = normalize_argv(compile.argv)
  if compile_file == "" then
    return nil, "missing-compile-file"
  end
  if directory == "" then
    return nil, "missing-compile-directory"
  end
  if not argv then
    return nil, argv_err
  end
  if toolchain_identity == "" then
    return nil, "missing-toolchain-identity"
  end

  local evidence = vim.deepcopy(spec.evidence or {})
  local compile_fingerprint = sha256({
    file = compile_file,
    directory = directory,
    argv = argv,
  })

  local ctx = {
    project_root = project_root,
    active_build_key = active_build_key,
    origin_tu = origin_tu,
    compile = {
      file = compile_file,
      directory = directory,
      argv = argv,
    },
    toolchain_identity = toolchain_identity,
    evidence = evidence,
    compile_command_fingerprint = compile_fingerprint,
  }

  return ctx
end

function M.make_proven_context(spec)
  local ctx, err = M.make_semantic_context(spec)
  if not ctx then
    return nil, err
  end

  if type(ctx.evidence) ~= "table" or trim(ctx.evidence.kind) == "" then
    return nil, "missing-evidence-kind"
  end

  ctx.proven = true
  ctx.kind = "proven-context"
  ctx.fingerprint = sha256({
    project_root = ctx.project_root,
    active_build_key = ctx.active_build_key,
    origin_tu = ctx.origin_tu,
    compile_command_fingerprint = ctx.compile_command_fingerprint,
    compile = ctx.compile,
    toolchain_identity = ctx.toolchain_identity,
    evidence = ctx.evidence,
  })
  ctx.context_id = ctx.fingerprint
  return ctx
end

function M.proven_contexts_from_cpp_json(opts)
  opts = opts or {}
  local compile_db = opts.compile_db
  local membership_db = opts.membership_db or compile_db
  local header = normalize_path(opts.header)
  local records = opts.records or {}
  local contexts = {}

  for _, item in ipairs(records) do
    local parsed = M.parse_cpp_json_record(item.record or item)
    if parsed and includes_path(parsed.includes, header) then
      local compile = find_compile_entry(compile_db, parsed.source)
      local active_member = find_compile_entry(membership_db, parsed.source)
      if compile and active_member then
        local ctx = M.make_proven_context({
          project_root = opts.project_root,
          active_build_key = opts.active_build_key,
          origin_tu = parsed.source,
          compile = compile,
          toolchain_identity = opts.toolchain_identity,
          evidence = {
            kind = "ubt-cpp-json",
            header = header,
            path = normalize_path(item.evidence_path or item.path or ""),
            pch = parsed.pch,
            source = parsed.source,
          },
        })
        if ctx then
          contexts[#contexts + 1] = ctx
        end
      end
    end
  end

  return dedup_contexts(contexts)
end

function M.proven_contexts_from_dep_records(opts)
  opts = opts or {}
  local compile_db = opts.compile_db
  local membership_db = opts.membership_db or compile_db
  local header = normalize_path(opts.header)
  local records = opts.records or {}
  local contexts = {}

  for _, item in ipairs(records) do
    local depfile = item.depfile
    if type(depfile) == "string" then
      depfile = M.parse_depfile(depfile)
    end
    if depfile and includes_path(depfile.dependencies, header) then
      local rsp_tokens = item.rsp_tokens
      if type(rsp_tokens) == "string" then
        rsp_tokens = M.parse_rsp_tokens(rsp_tokens)
      elseif type(item.rsp) == "string" and not rsp_tokens then
        rsp_tokens = M.parse_rsp_tokens(item.rsp)
      end

      local compile_file = normalize_path(item.compile_file or M.rsp_source_file(rsp_tokens) or "")
      local compile = find_compile_entry(compile_db, compile_file)
      local active_member = find_compile_entry(membership_db, compile_file)
      if compile and active_member then
        local unity_members = item.unity_members
        if type(unity_members) == "string" then
          unity_members = M.parse_unity_membership(unity_members, item.unity_path)
        elseif type(item.unity_text) == "string" and not unity_members then
          unity_members = M.parse_unity_membership(item.unity_text, item.unity_path)
        end
        if not is_list(unity_members) or #unity_members == 0 then
          unity_members = { compile_file }
        end

        for _, origin in ipairs(unity_members) do
          local ctx = M.make_proven_context({
            project_root = opts.project_root,
            active_build_key = opts.active_build_key,
            origin_tu = origin,
            compile = compile,
            toolchain_identity = opts.toolchain_identity,
            evidence = {
              kind = "clang-d",
              header = header,
              depfile_path = normalize_path(item.depfile_path or ""),
              rsp_path = normalize_path(item.rsp_path or ""),
              unity_path = normalize_path(item.unity_path or ""),
              compile_file = compile_file,
              unity_members = copy_list(unity_members),
            },
          })
          if ctx then
            contexts[#contexts + 1] = ctx
          end
        end
      end
    end
  end

  return dedup_contexts(contexts)
end

function M.catalog_contexts(contexts)
  local normalized = dedup_contexts(contexts)
  if #normalized == 0 then
    return {
      state = "unavailable",
      contexts = {},
      reason = "no-proven-context",
    }
  end
  if #normalized == 1 then
    return {
      state = "resolved",
      context = normalized[1],
      contexts = normalized,
    }
  end
  return {
    state = "ambiguous-context",
    contexts = normalized,
  }
end

function M.remember_window_selection(context)
  if type(context) ~= "table" or not context.fingerprint then
    return nil
  end
  return {
    fingerprint = context.fingerprint,
  }
end

function M.reuse_window_selection(selection, contexts)
  if type(selection) ~= "table" or trim(selection.fingerprint) == "" then
    return nil
  end
  for _, ctx in ipairs(dedup_contexts(contexts)) do
    if ctx.fingerprint == selection.fingerprint then
      return ctx
    end
  end
  return nil
end

return M
