local M = {}

local uv = vim.uv or vim.loop

local RULES = {
  direct_os_probe = "direct_os_probe",
  compat_boolean_branch = "compat_boolean_branch",
  target_literal_condition = "target_literal_condition",
  host_executable_path = "host_executable_path",
  target_policy_literal = "target_policy_literal",
  concrete_cross_target_import = "concrete_cross_target_import",
}

M.RULES = RULES

local DIRECT_OS_CALLS = {
  ["vim.fn.has"] = true,
  ["vim.uv.os_uname"] = true,
  ["vim.loop.os_uname"] = true,
}

local OS_PROBE_LITERALS = {
  win32 = true,
  win64 = true,
  mac = true,
  macunix = true,
  linux = true,
  linux64 = true,
  unix = true,
}

local COMPAT_BOOLS = {
  is_windows = true,
  is_mac = true,
  is_linux = true,
}

local TARGET_LITERALS = {
  android = true,
  ios = true,
  win64 = true,
  linux = true,
  linuxarm64 = true,
  mac = true,
}

local HOST_LITERAL_TOKENS = {
  [".exe"] = true,
  ["cmd.exe"] = true,
  ["powershell.exe"] = true,
  ["pwsh"] = true,
  ["pwsh.exe"] = true,
  ["/bin/zsh"] = true,
  ["/bin/sh"] = true,
  ["/usr/bin/xcrun"] = true,
  ["/usr/bin/security"] = true,
  ["/usr/bin/plutil"] = true,
  ["Build.bat"] = true,
  ["RunUAT.bat"] = true,
  ["Build.sh"] = true,
  ["RunUAT.sh"] = true,
  ["clangd-indexer"] = true,
  ["python.exe"] = true,
  ["python3"] = true,
  ["libclang.dll"] = true,
  ["libclang.dylib"] = true,
  ["libclang.so"] = true,
  ["libclang."] = true,
}

local TARGET_POLICY_TOKENS = {
  ["adb"] = true,
  ["gradlew"] = true,
  [".apk"] = true,
  ["Android/"] = true,
  ["ios-deploy"] = true,
  ["idevice_id"] = true,
  ["ideviceinfo"] = true,
  ["xcodebuild"] = true,
  ["codesign"] = true,
  [".ipa"] = true,
  ["IOS/"] = true,
}

local REGISTRY_FIELD_KEYS = {
  id = true,
  target = true,
  platform = true,
  owner = true,
  label = true,
  title = true,
  name = true,
  display_name = true,
}

local UI_FIELD_KEYS = {
  desc = true,
  prompt = true,
  title = true,
  label = true,
  message = true,
  name = true,
}

local STRUCTURAL_ALLOWLISTS = {
  {
    rule = RULES.target_policy_literal,
    file = "lua/ue.lua",
    context = "user_command_declaration",
    reason = "UE command names may mention concrete targets while the facade stays target-agnostic.",
  },
  {
    rule = RULES.target_policy_literal,
    file = "lua/ue.lua",
    context = "ui_text",
    reason = "User-facing prompts and descriptions may describe Android/IOS workflows without owning them.",
  },
  {
    rule = RULES.target_policy_literal,
    file = "lua/config/keymaps.lua",
    context = "ui_text",
    reason = "Keymap descriptions may mention concrete targets as user-facing labels.",
  },
  {
    rule = RULES.target_policy_literal,
    file = "lua/ue.lua",
    context = "registry_table_value",
    reason = "Facade registry data may enumerate target ids for menu/display data.",
  },
  {
    rule = RULES.host_executable_path,
    file = "lua/ue.lua",
    context = "ui_text",
    reason = "User-facing command descriptions may mention host tools without owning executable resolution.",
  },
  {
    rule = RULES.host_executable_path,
    file = "lua/ue/index/_generation.lua",
    context = "tool_resolver_name",
    reason = "A resolver's logical tool id is registry data, not executable construction.",
  },
  {
    rule = RULES.host_executable_path,
    file = "lua/utils/core_health_checks.lua",
    context = "fixture_path",
    reason = "Health-check fixture paths describe injected driver plans and are never executable candidates.",
  },
  {
    rule = RULES.target_policy_literal,
    file = "lua/ue/ai_context.lua",
    context = "ai_context_documentation",
    reason = "Generated operator documentation may describe the captured Android route without owning it.",
  },
  {
    rule = RULES.target_policy_literal,
    file = "lua/ue/build_monitor.lua",
    context = "source_extension_data",
    reason = "Build monitor extension data classifies output tokens and does not select a target workflow.",
  },
  {
    rule = RULES.target_policy_literal,
    file = "lua/ue/dap.lua",
    context = "dap_diagnostic_text",
    reason = "DAP diagnostic display text may name the captured Android transport without executing policy.",
  },
}

-- Historical snapshot captured before this change began removing violations.
-- Keep this separate from BASELINE: resolved entries remain audit evidence but
-- must never be reintroduced as active production exceptions.
local INITIAL_AUDIT = {
  {
    rule = RULES.compat_boolean_branch,
    file = "lua/config/clipboard.lua",
    snippet = 'vim.fn.has("win32")',
    owner = "host-capability",
    removal_phase = "2.4",
    reason = "Clipboard policy directly probed the host OS in generic config.",
  },
  {
    rule = RULES.host_executable_path,
    file = "lua/utils/code_search/init.lua",
    snippet = ".exe / PATH separator / PowerShell vs sh",
    owner = "host-capability",
    removal_phase = "2.5",
    reason = "Code search constructed host executable names and selected shell policy.",
  },
  {
    rule = RULES.compat_boolean_branch,
    file = "lua/ue/index/_build.lua",
    snippet = "_uplat.is_windows",
    owner = "host-tool-resolution",
    removal_phase = "2.6",
    reason = "Index build selected Python candidates through a compatibility boolean.",
  },
  {
    rule = RULES.host_executable_path,
    file = "lua/ue/index/_generation.lua",
    snippet = "clangd-indexer.exe",
    owner = "host-tool-resolution",
    removal_phase = "2.6",
    reason = "Indexer identity embedded WSL and Windows executable candidates.",
  },
  {
    rule = RULES.host_executable_path,
    file = "lua/ue/clangd_commands.lua",
    snippet = "Python312/python.exe",
    owner = "host-tool-resolution",
    removal_phase = "2.6",
    reason = "Clangd command transport duplicated host Python resolution.",
  },
  {
    rule = RULES.host_executable_path,
    file = "lua/utils/ue_goto/semantic_sidecar_libclang.lua",
    snippet = "libclang.dll/dylib/so",
    owner = "host-tool-resolution",
    removal_phase = "2.7",
    reason = "Semantic sidecar selected shared-library suffixes outside the host driver.",
  },
  {
    rule = RULES.target_policy_literal,
    file = "lua/ue.lua",
    snippet = "Android/IOS artifact, script, signing, device and command policy",
    owner = "target-workflow",
    removal_phase = "4-7",
    reason = "The facade retained concrete target policy and workflow state machines.",
  },
}

local BASELINE = {}

local function normalize(path)
  return vim.fs.normalize(path):gsub("\\", "/")
end

local function workspace_relative(path)
  local cwd = normalize(vim.fn.getcwd())
  path = normalize(path)
  if path:sub(1, #cwd + 1) == cwd .. "/" then
    return path:sub(#cwd + 2)
  end
  return path
end

local function read_file(path)
  local lines = vim.fn.readfile(path)
  return table.concat(lines, "\n")
end

local function string_value(text)
  local trimmed = text:gsub("^%[=*%[", ""):gsub("%]=*%]$", "")
  trimmed = trimmed:gsub('^"', ""):gsub('"$', "")
  trimmed = trimmed:gsub("^'", ""):gsub("'$", "")
  return trimmed
end

local function named_children(node)
  local out = {}
  for child in node:iter_children() do
    if child:named() then
      out[#out + 1] = child
    end
  end
  return out
end

local function child_text(node, bufnr, index)
  local children = named_children(node)
  local child = children[index]
  if not child then
    return nil
  end
  return vim.treesitter.get_node_text(child, bufnr)
end

local function field_key(node, bufnr)
  if not node or node:type() ~= "field" then
    return nil
  end
  return child_text(node, bufnr, 1)
end

local function line_col(node)
  local row, col = node:range()
  return row + 1, col + 1
end

local function nearest_parent(node, wanted)
  local cur = node
  while cur do
    if cur:type() == wanted then
      return cur
    end
    cur = cur:parent()
  end
  return nil
end

local function is_condition_node(node)
  local cur = node
  while cur do
    local parent = cur:parent()
    if not parent then
      return false
    end
    local t = parent:type()
    if t == "if_statement" or t == "elseif_clause" or t == "while_statement" then
      return true
    end
    cur = parent
  end
  return false
end

local function is_behavior_branch_node(node, bufnr)
  if is_condition_node(node) then
    return true
  end
  local cur = node:parent()
  while cur do
    if cur:type() == "binary_expression" then
      local text = vim.treesitter.get_node_text(cur, bufnr)
      if text:find(" and ", 1, true) or text:find(" or ", 1, true) then
        return true
      end
    end
    if cur:type() == "statement" or cur:type() == "function_call" then
      break
    end
    cur = cur:parent()
  end
  return false
end

local function owner_kind(path)
  if path:match("^lua/utils/platform/") then
    return "host_owner"
  end
  if path == "lua/ue/targets/init.lua" then
    return "target_registry"
  end
  if path == "lua/ue/targets/path_hints.lua" then
    return "target_policy_registry"
  end
  if path:match("^lua/ue/targets/") then
    return "target_owner"
  end
  if path == "lua/ue/workflows/init.lua" or path == "lua/ue/workflows/bootstrap.lua" then
    return "workflow_registry"
  end
  if path == "lua/ue/workflows/_runtime.lua" then
    return "workflow_runtime"
  end
  if path:match("^lua/ue/workflows/") then
    return "workflow_owner"
  end
  if path == "lua/ue/dap/platforms.lua" then
    return "dap_registry"
  end
  local dap_target = path:match("^lua/ue/dap/([%w_]+)%.lua$")
  -- Split target owners follow this directory's flat `_<target>_<concern>.lua`
  -- convention (see `_ios_*.lua`, `_android_policy.lua`), so strip a leading
  -- underscore and keep only the target segment before classifying. Without this
  -- a split owner would be judged "generic" and its own target command literals
  -- would be reported as boundary violations — pushing contributors toward an
  -- allowlist instead of the correct ownership.
  if dap_target then
    dap_target = dap_target:gsub("^_", ""):match("^([%a%d]+)") or dap_target
  end
  if dap_target and ({ android = true, ios = true, mac = true, win64 = true, linux = true })[dap_target] then
    return "dap_target_owner"
  end
  if path == "lua/utils/android_device.lua" then
    return "workflow_device_owner"
  end
  if path == "lua/ue/ai_context.lua" then
    return "target_report_owner"
  end
  return "generic"
end

local function owner_target(path)
  local part = path:match("^lua/ue/targets/([^/]+)%.lua$")
    or path:match("^lua/ue/workflows/([^/]+)/")
    or path:match("^lua/ue/dap/([^/]+)%.lua$")
  if path == "lua/utils/android_device.lua" then
    return "android"
  end
  if not part then
    return nil
  end
  part = part:lower()
  -- Accept the flat split-owner convention (`_ios_session`, `_android_policy`):
  -- the target name follows an optional leading underscore.
  part = part:gsub("^_", "")
  if part:find("android", 1, true) == 1 then
    return "android"
  end
  if part:find("ios", 1, true) == 1 then
    return "ios"
  end
  if part:find("win64", 1, true) == 1 then
    return "win64"
  end
  if part:find("linux", 1, true) == 1 then
    return "linux"
  end
  if part:find("mac", 1, true) == 1 then
    return "mac"
  end
  return part
end

local function parse_source(source, relative_path)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].filetype = "lua"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(source, "\n", { plain = true }))
  local parser = vim.treesitter.get_parser(buf, "lua")
  local tree = parser:parse()[1]
  return {
    buf = buf,
    root = tree:root(),
    source = source,
    relative_path = relative_path,
    owner_kind = owner_kind(relative_path),
    owner_target = owner_target(relative_path),
  }
end

local function destroy_parse(parsed)
  pcall(vim.api.nvim_buf_delete, parsed.buf, { force = true })
end

local function walk(node, fn)
  fn(node)
  for child in node:iter_children() do
    walk(child, fn)
  end
end

local function dot_text(node, bufnr)
  return vim.treesitter.get_node_text(node, bufnr)
end

local function is_call_named(node, bufnr, expected)
  if not node or node:type() ~= "function_call" then
    return false
  end
  local name = node:named_child(0)
  if not name then
    return false
  end
  return dot_text(name, bufnr) == expected
end

local function string_argument(node, bufnr, index)
  if not node or node:type() ~= "function_call" then
    return nil
  end
  local args = node:named_child(1)
  if not args or args:type() ~= "arguments" then
    return nil
  end
  local named = named_children(args)
  local arg = named[index]
  if not arg or arg:type() ~= "string" then
    return nil
  end
  return string_value(vim.treesitter.get_node_text(arg, bufnr)), arg
end

local function registry_table_value(node, parsed)
  if node:type() ~= "string" then
    return false
  end
  local field = node:parent()
  if not field or field:type() ~= "field" then
    return false
  end
  local key = field_key(field, parsed.buf)
  if not key or not REGISTRY_FIELD_KEYS[key] then
    return false
  end
  return nearest_parent(field, "table_constructor") ~= nil
end

local function user_command_declaration(node, parsed)
  if node:type() ~= "string" then
    return false
  end
  local args = node:parent()
  if not args or args:type() ~= "arguments" then
    return false
  end
  local call = args:parent()
  if not is_call_named(call, parsed.buf, "vim.api.nvim_create_user_command") then
    return false
  end
  local named = named_children(args)
  return named[1] == node
end

local function ui_text(node, parsed)
  if node:type() ~= "string" then
    return false
  end
  local parent = node:parent()
  if parent and parent:type() == "field" then
    local key = field_key(parent, parsed.buf)
    if key and UI_FIELD_KEYS[key] then
      return true
    end
  end
  local args = parent and parent:type() == "arguments" and parent or nil
  if args then
    local call = args:parent()
    if is_call_named(call, parsed.buf, "vim.notify") or is_call_named(call, parsed.buf, "vim.fn.input") then
      return true
    end
  end
  return false
end

local function string_has(node, parsed, needle)
  if node:type() ~= "string" then
    return false
  end
  return string_value(vim.treesitter.get_node_text(node, parsed.buf)):find(needle, 1, true) ~= nil
end

local function tool_resolver_name(node, parsed)
  if node:type() ~= "string" then
    return false
  end
  local field = node:parent()
  if not field or field:type() ~= "field" or field_key(field, parsed.buf) ~= "name" then
    return false
  end
  local call = nearest_parent(field, "function_call")
  if not call then
    return false
  end
  local name = call:named_child(0)
  local text = name and dot_text(name, parsed.buf) or ""
  return text == "platform.resolve_tool" or text == "_uplat.resolve_tool"
end

local function fixture_path(node, parsed)
  return string_has(node, parsed, "/fixture/")
end

local function ai_context_documentation(node, parsed)
  return string_has(node, parsed, "<Space>uA") and string_has(node, parsed, "<serial>")
end

local function source_extension_data(node, parsed)
  if not string_has(node, parsed, ".ipa") then
    return false
  end
  local field = node:parent()
  return field ~= nil and field:type() == "field" and nearest_parent(field, "table_constructor") ~= nil
end

local function dap_diagnostic_text(node, parsed)
  return string_has(node, parsed, "adb forward --list:") or string_has(node, parsed, "device-side (adb)")
end

local ALLOWLIST_CONTEXTS = {
  registry_table_value = registry_table_value,
  user_command_declaration = user_command_declaration,
  ui_text = ui_text,
  tool_resolver_name = tool_resolver_name,
  fixture_path = fixture_path,
  ai_context_documentation = ai_context_documentation,
  source_extension_data = source_extension_data,
  dap_diagnostic_text = dap_diagnostic_text,
}

local function is_allowlisted(rule, parsed, node)
  for _, entry in ipairs(STRUCTURAL_ALLOWLISTS) do
    if entry.rule == rule and entry.file == parsed.relative_path then
      local predicate = ALLOWLIST_CONTEXTS[entry.context]
      if predicate and predicate(node, parsed) then
        return true, entry
      end
    end
  end
  return false, nil
end

local function make_violation(rule, parsed, node, message)
  local line, col = line_col(node)
  local snippet = vim.treesitter.get_node_text(node, parsed.buf)
  return {
    rule = rule,
    file = parsed.relative_path,
    line = line,
    col = col,
    snippet = snippet,
    owner = parsed.owner_kind,
    owner_target = parsed.owner_target,
    message = message,
  }
end

local function add_violation(out, seen, violation)
  local key = table.concat({ violation.rule, violation.file, violation.line, violation.col, violation.snippet }, "|")
  if seen[key] then
    return
  end
  seen[key] = true
  out[#out + 1] = violation
end

local function match_host_literal(value)
  for token in pairs(HOST_LITERAL_TOKENS) do
    if token == ".exe" then
      local lower = value:lower()
      if lower:match("%.exe$") or lower:match("%.exe[%s,;:\"']") then
        return token
      end
    elseif value:find(token, 1, true) then
      return token
    end
  end
  return nil
end

local function match_target_policy_literal(value)
  for token in pairs(TARGET_POLICY_TOKENS) do
    if value:find(token, 1, true) then
      return token
    end
  end
  return nil
end

local function direct_os_probe(parsed, node)
  if parsed.owner_kind == "host_owner" then
    return nil
  end
  if node:type() == "function_call" then
    local name = node:named_child(0)
    local call_name = name and dot_text(name, parsed.buf) or nil
    if not call_name or not DIRECT_OS_CALLS[call_name] then
      return nil
    end
    if call_name == "vim.fn.has" then
      local value = string_argument(node, parsed.buf, 1)
      if not value or not OS_PROBE_LITERALS[value] then
        return nil
      end
    end
    return make_violation(
      RULES.direct_os_probe,
      parsed,
      node,
      "direct OS probing belongs to host platform drivers only"
    )
  end
  if node:type() == "dot_index_expression" and dot_text(node, parsed.buf) == "jit.os" then
    return make_violation(
      RULES.direct_os_probe,
      parsed,
      node,
      "direct OS probing belongs to host platform drivers only"
    )
  end
  return nil
end

local function compat_boolean_branch(parsed, node)
  if parsed.owner_kind == "host_owner" then
    return nil
  end
  if not is_behavior_branch_node(node, parsed.buf) then
    return nil
  end
  if node:type() ~= "identifier" and node:type() ~= "dot_index_expression" then
    return nil
  end
  if node:type() == "identifier" and node:parent() and node:parent():type() == "dot_index_expression" then
    return nil
  end
  local text = nil
  if node:type() == "identifier" then
    text = vim.treesitter.get_node_text(node, parsed.buf)
  else
    text = dot_text(node, parsed.buf):match("([%a_][%w_]*)$")
  end
  if not text or not COMPAT_BOOLS[text] then
    return nil
  end
  return make_violation(
    RULES.compat_boolean_branch,
    parsed,
    node,
    "compatibility booleans must not drive generic behavior branches"
  )
end

local function binary_uses_target_literal(node, bufnr)
  if node:type() ~= "binary_expression" then
    return false
  end
  local left = node:named_child(0)
  local right = node:named_child(1)
  local function target_value(child)
    if not child then
      return nil
    end
    if child:type() == "string" then
      local value = string_value(vim.treesitter.get_node_text(child, bufnr)):lower()
      return TARGET_LITERALS[value] and value or nil
    end
    if child:type() == "identifier" then
      local value = vim.treesitter.get_node_text(child, bufnr):lower()
      return TARGET_LITERALS[value] and value or nil
    end
    if child:type() == "dot_index_expression" then
      local value = dot_text(child, bufnr):match("([%a_][%w_]*)$")
      value = value and value:lower() or nil
      return value and TARGET_LITERALS[value] and value or nil
    end
    return nil
  end
  return target_value(left) or target_value(right)
end

local function target_literal_condition(parsed, node)
  if
    parsed.owner_kind == "target_owner"
    or parsed.owner_kind == "target_policy_registry"
    or parsed.owner_kind == "workflow_owner"
    or parsed.owner_kind == "dap_target_owner"
    or parsed.owner_kind == "workflow_device_owner"
    or parsed.owner_kind == "target_report_owner"
  then
    return nil
  end
  if not is_condition_node(node) then
    return nil
  end
  local value = binary_uses_target_literal(node, parsed.buf)
  if not value then
    return nil
  end
  return make_violation(
    RULES.target_literal_condition,
    parsed,
    node,
    "generic layers must not branch on concrete target literals"
  )
end

local function host_executable_path(parsed, node)
  if parsed.owner_kind == "host_owner" or node:type() ~= "string" then
    return nil
  end
  local value = string_value(vim.treesitter.get_node_text(node, parsed.buf))
  local token = match_host_literal(value)
  if not token then
    return nil
  end
  if parsed.owner_kind == "target_owner" and parsed.owner_target == "win64" and token == ".exe" then
    return nil
  end
  local allowed = is_allowlisted(RULES.host_executable_path, parsed, node)
  if allowed then
    return nil
  end
  return make_violation(
    RULES.host_executable_path,
    parsed,
    node,
    "host executable or path construction must live in host capability owners"
  )
end

local function target_policy_literal(parsed, node)
  if node:type() ~= "string" then
    return nil
  end
  if
    parsed.owner_kind == "host_owner"
    or parsed.owner_kind == "target_owner"
    or parsed.owner_kind == "target_policy_registry"
    or parsed.owner_kind == "workflow_owner"
    or parsed.owner_kind == "dap_target_owner"
    or parsed.owner_kind == "workflow_device_owner"
    or parsed.owner_kind == "target_report_owner"
  then
    return nil
  end
  local value = string_value(vim.treesitter.get_node_text(node, parsed.buf))
  local token = match_target_policy_literal(value)
  if not token then
    return nil
  end
  local allowed = is_allowlisted(RULES.target_policy_literal, parsed, node)
  if allowed then
    return nil
  end
  return make_violation(
    RULES.target_policy_literal,
    parsed,
    node,
    "target-specific policy literals must move to target owners or precise UI/registry contexts"
  )
end

local function require_target(text)
  if text:match("^utils%.platform%.[%w_]+$") and text ~= "utils.platform.shell" and text ~= "utils.platform.init" then
    return "host"
  end
  if text:match("^ue%.targets%.[%w_]+$") and text ~= "ue.targets._common" and text ~= "ue.targets.contract" then
    if text == "ue.targets.path_hints" then
      return nil
    end
    return "target"
  end
  if
    text:match("^ue%.workflows%.")
    and text ~= "ue.workflows.init"
    and text ~= "ue.workflows.bootstrap"
    and text ~= "ue.workflows._runtime"
  then
    return "workflow"
  end
  return nil
end

local function import_target_id(text)
  local tail = text:match("^ue%.targets%.([%w_]+)$") or text:match("^ue%.workflows%.([%w_]+)")
  if not tail then
    return nil
  end
  tail = tail:lower()
  if tail:find("android", 1, true) == 1 then
    return "android"
  end
  if tail:find("ios", 1, true) == 1 then
    return "ios"
  end
  if tail:find("win64", 1, true) == 1 then
    return "win64"
  end
  if tail:find("linux", 1, true) == 1 then
    return "linux"
  end
  if tail:find("mac", 1, true) == 1 then
    return "mac"
  end
  return tail
end

local function concrete_cross_target_import(parsed, node)
  if node:type() ~= "function_call" then
    return nil
  end
  local value, arg_node = string_argument(node, parsed.buf, 1)
  if not value or not is_call_named(node, parsed.buf, "require") then
    return nil
  end
  local kind = require_target(value)
  if not kind then
    return nil
  end
  if parsed.owner_kind == "target_registry" and kind == "target" then
    return nil
  end
  if parsed.owner_kind == "workflow_registry" and kind == "workflow" then
    return nil
  end
  if parsed.owner_kind == "generic" then
    return make_violation(
      RULES.concrete_cross_target_import,
      parsed,
      arg_node,
      "generic layers must not import concrete host/target owners"
    )
  end
  if parsed.owner_kind == "target_owner" and kind == "workflow" then
    return make_violation(
      RULES.concrete_cross_target_import,
      parsed,
      arg_node,
      "target drivers must not depend on workflow owners"
    )
  end
  if (parsed.owner_kind == "target_owner" or parsed.owner_kind == "workflow_owner") and kind ~= "host" then
    local imported = import_target_id(value)
    if imported and imported ~= parsed.owner_target then
      return make_violation(
        RULES.concrete_cross_target_import,
        parsed,
        arg_node,
        "target owners must not import another concrete target owner"
      )
    end
  end
  return nil
end

local DETECTORS = {
  direct_os_probe,
  compat_boolean_branch,
  target_literal_condition,
  host_executable_path,
  target_policy_literal,
  concrete_cross_target_import,
}

function M.analyze_source(source, relative_path)
  local parsed = parse_source(source, normalize(relative_path))
  local out = {}
  local seen = {}
  walk(parsed.root, function(node)
    for _, detector in ipairs(DETECTORS) do
      local violation = detector(parsed, node)
      if violation then
        add_violation(out, seen, violation)
      end
    end
  end)
  table.sort(out, function(a, b)
    if a.file ~= b.file then
      return a.file < b.file
    end
    if a.line ~= b.line then
      return a.line < b.line
    end
    if a.rule ~= b.rule then
      return a.rule < b.rule
    end
    return a.col < b.col
  end)
  destroy_parse(parsed)
  return out
end

function M.analyze_file(path)
  local relative = workspace_relative(path)
  return M.analyze_source(read_file(path), relative)
end

function M.scan_files(paths)
  local out = {}
  for _, path in ipairs(paths) do
    local violations = M.analyze_file(path)
    for _, violation in ipairs(violations) do
      out[#out + 1] = violation
    end
  end
  return out
end

function M.production_files()
  local cwd = normalize(vim.fn.getcwd())
  local files = vim.fn.glob(cwd .. "/lua/**/*.lua", false, true)
  table.sort(files)
  return files
end

function M.production_report()
  local violations = M.scan_files(M.production_files())
  local unmatched = {}
  local matched = {}
  for _, violation in ipairs(violations) do
    local found = false
    for _, baseline in ipairs(BASELINE) do
      if
        baseline.rule == violation.rule
        and baseline.file == violation.file
        and violation.snippet:find(baseline.snippet, 1, true)
      then
        matched[#matched + 1] = {
          baseline = baseline,
          violation = violation,
        }
        found = true
        break
      end
    end
    if not found then
      unmatched[#unmatched + 1] = violation
    end
  end
  local missing = {}
  for _, baseline in ipairs(BASELINE) do
    local found = false
    for _, pair in ipairs(matched) do
      if pair.baseline == baseline then
        found = true
        break
      end
    end
    if not found then
      missing[#missing + 1] = baseline
    end
  end
  return {
    violations = violations,
    matched = matched,
    unmatched = unmatched,
    missing = missing,
  }
end

function M.format_report(report)
  local lines = { "UE platform architecture boundary report" }
  for _, pair in ipairs(report.matched) do
    local base = pair.baseline
    local hit = pair.violation
    lines[#lines + 1] = string.format(
      "- baseline %s %s:%d owner=%s removal=%s :: %s",
      base.rule,
      hit.file,
      hit.line,
      base.owner,
      base.removal_phase,
      base.reason
    )
  end
  for _, violation in ipairs(report.unmatched) do
    lines[#lines + 1] =
      string.format("- unexpected %s %s:%d :: %s", violation.rule, violation.file, violation.line, violation.snippet)
  end
  for _, baseline in ipairs(report.missing) do
    lines[#lines + 1] = string.format("- missing baseline %s %s :: %s", baseline.rule, baseline.file, baseline.snippet)
  end
  return table.concat(lines, "\n")
end

M.allowlists = STRUCTURAL_ALLOWLISTS
M.initial_audit = INITIAL_AUDIT
M.baseline = BASELINE

return M
