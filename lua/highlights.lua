local M = {}

local setup_done = false

local function hl(name)
  local ok, value = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
  if ok and type(value) == "table" and next(value) then
    value.link = nil
    return value
  end
  return nil
end

local function set_from(targets, source, extra)
  local base = hl(source)
  extra = extra or {}
  for _, target in ipairs(targets) do
    if base then
      vim.api.nvim_set_hl(0, target, vim.tbl_extend("force", base, extra))
    else
      local spec = vim.deepcopy(extra)
      spec.link = source
      vim.api.nvim_set_hl(0, target, spec)
    end
  end
end

-- Each profile reuses the active colorscheme's own palette through existing
-- highlight groups. This keeps theme identity while preventing adjacent C/C++
-- roles from collapsing to the same foreground (notably struct/field/parameter).
local THEME_PROFILES = {
  monokai_ristretto = {
    namespace = "Comment",
    type = "Type",
    field = "Tag",
    parameter = "Number",
    variable = "Normal",
    ["function"] = "Function",
    enum_member = "String",
    macro = "Macro",
  },
  ["rider-light"] = {
    namespace = "Include",
    type = "Directory",
    field = "Constant",
    parameter = "LspSignatureActiveParameter",
    variable = "Normal",
    ["function"] = "Function",
    enum_member = "String",
    macro = "Macro",
  },
  ["ubuntu-terminal"] = {
    namespace = "Comment",
    type = "Type",
    field = "Constant",
    parameter = "DiagnosticWarn",
    variable = "Normal",
    ["function"] = "Function",
    enum_member = "String",
    macro = "Keyword",
  },
  unokai = {
    namespace = "Directory",
    type = "Type",
    field = "Identifier",
    parameter = "Constant",
    variable = "Normal",
    ["function"] = "Function",
    enum_member = "String",
    macro = "Macro",
  },
  catppuccin = {
    namespace = "Special",
    type = "Type",
    field = "Identifier",
    parameter = "Character",
    variable = "Normal",
    ["function"] = "Function",
    enum_member = "Constant",
    macro = "Macro",
  },
  ["sonokai-espresso"] = {
    namespace = "Comment",
    type = "Type",
    field = "Identifier",
    parameter = "String",
    variable = "Normal",
    ["function"] = "Function",
    enum_member = "Number",
    macro = "Keyword",
  },
}

local DEFAULT_PROFILE = {
  namespace = "Include",
  type = "Type",
  field = "Identifier",
  parameter = "Constant",
  variable = "Normal",
  ["function"] = "Function",
  enum_member = "Special",
  macro = "Macro",
}

local function cpp_targets(...)
  local targets = {}
  for _, name in ipairs({ ... }) do
    targets[#targets + 1] = name .. ".c"
    targets[#targets + 1] = name .. ".cpp"
  end
  return targets
end

local ROLE_TARGETS = {
  namespace = cpp_targets("@module", "@lsp.type.namespace"),
  type = cpp_targets(
    "@type",
    "@type.builtin",
    "@type.definition",
    "@lsp.type.type",
    "@lsp.type.class",
    "@lsp.type.struct",
    "@lsp.type.enum",
    "@lsp.type.interface",
    "@lsp.type.typeParameter",
    "@lsp.type.concept"
  ),
  field = cpp_targets("@field", "@property", "@variable.member", "@lsp.type.property"),
  parameter = cpp_targets("@parameter", "@variable.parameter", "@lsp.type.parameter"),
  variable = cpp_targets("@variable", "@lsp.type.variable"),
  ["function"] = cpp_targets(
    "@function",
    "@function.call",
    "@function.builtin",
    "@function.method",
    "@function.method.call",
    "@constructor",
    "@lsp.type.function",
    "@lsp.type.method"
  ),
  enum_member = cpp_targets("@constant", "@constant.builtin", "@lsp.type.enumMember"),
  macro = cpp_targets("@constant.macro", "@function.macro", "@lsp.type.macro"),
}

local ROLE_KINDS = {
  namespace = { "Module" },
  type = { "Class", "Struct", "Interface", "TypeParameter", "Enum" },
  field = { "Field", "Property" },
  parameter = {}, -- LSP CompletionItemKind has no Parameter kind.
  variable = { "Variable" },
  ["function"] = { "Function", "Method", "Constructor" },
  enum_member = { "EnumMember", "Constant" },
  macro = {}, -- LSP CompletionItemKind has no Macro kind.
}

local ROLE_STYLES = {
  namespace = { italic = true },
  type = { bold = true },
  field = {},
  parameter = { italic = true },
  variable = {},
  ["function"] = { bold = true },
  enum_member = { bold = true },
  macro = { bold = true, italic = true },
}

local ROLE_ORDER = {
  "variable",
  "namespace",
  "type",
  "field",
  "parameter",
  "function",
  "enum_member",
  "macro",
}

local function active_profile()
  local name = tostring(vim.g.colors_name or "")
  if name:match("^catppuccin%-") then
    name = "catppuccin"
  elseif name == "sonokai" then
    name = "sonokai-espresso"
  end
  return THEME_PROFILES[name] or DEFAULT_PROFILE
end

local function set_role(targets, source, extra)
  local base = hl(source)
  if not base or (base.fg == nil and base.ctermfg == nil) then
    base = hl("Normal") or {}
  end
  local spec = vim.tbl_extend("force", {
    fg = base.fg,
    ctermfg = base.ctermfg,
  }, extra or {})
  for _, target in ipairs(targets) do
    vim.api.nvim_set_hl(0, target, spec)
  end
end

local function apply_generic_semantic_defaults()
  -- Preserve the pre-existing cross-language defaults. C/C++ exact groups are
  -- applied afterwards and take precedence over these fallback captures.
  set_from({ "@module", "@lsp.type.namespace" }, "Include", { bold = true })
  set_from({
    "@type",
    "@type.builtin",
    "@type.definition",
    "@lsp.type.type",
    "@lsp.type.class",
    "@lsp.type.struct",
    "@lsp.type.enum",
    "@lsp.type.interface",
    "@lsp.type.typeParameter",
  }, "Type", { bold = true })
  set_from({
    "@function",
    "@function.call",
    "@function.builtin",
    "@function.method",
    "@function.method.call",
    "@constructor",
    "@lsp.type.function",
    "@lsp.type.method",
  }, "Function", { bold = true })
  set_from({ "@field", "@property", "@variable.member", "@lsp.type.property" }, "Identifier", { italic = true })
  set_from({ "@parameter", "@variable.parameter", "@lsp.type.parameter" }, "Identifier", { italic = true })
  set_from({ "@constant", "@constant.builtin", "@lsp.type.enumMember" }, "Constant", { bold = true })
  set_from({ "@constant.macro", "@function.macro", "@lsp.type.macro" }, "Macro", { bold = true })
end

local function apply_semantic_roles()
  local profile = active_profile()
  for _, role in ipairs(ROLE_ORDER) do
    local source = profile[role] or DEFAULT_PROFILE[role]
    set_role(ROLE_TARGETS[role], source, ROLE_STYLES[role])

    local completion_targets = {}
    for _, kind in ipairs(ROLE_KINDS[role]) do
      completion_targets[#completion_targets + 1] = "CmpItemKind" .. kind
      completion_targets[#completion_targets + 1] = "BlinkCmpKind" .. kind
    end
    set_role(completion_targets, source)
  end
end

local function set_style(targets, spec)
  for _, target in ipairs(targets) do
    vim.api.nvim_set_hl(0, target, spec)
  end
end

local SEMANTIC_TOKEN_TYPES = {
  "namespace",
  "type",
  "class",
  "struct",
  "enum",
  "interface",
  "typeParameter",
  "concept",
  "property",
  "parameter",
  "variable",
  "function",
  "method",
  "enumMember",
  "macro",
}

local function modifier_targets(modifiers)
  local targets = cpp_targets(unpack(vim.tbl_map(function(modifier)
    return "@lsp.mod." .. modifier
  end, modifiers)))
  for _, token_type in ipairs(SEMANTIC_TOKEN_TYPES) do
    for _, modifier in ipairs(modifiers) do
      vim.list_extend(targets, cpp_targets("@lsp.typemod." .. token_type .. "." .. modifier))
    end
  end
  return targets
end

local function apply_semantic_modifiers()
  -- Modifier extmarks have a higher priority than the token-type extmark.
  -- Keep generic and type-specific variants colourless so they add only a
  -- second visual channel instead of replacing the role foreground.
  set_style(modifier_targets({ "declaration", "definition" }), { bold = true })
  set_style(modifier_targets({ "readonly", "static", "abstract", "virtual" }), { italic = true })
  set_style(modifier_targets({ "deprecated" }), { strikethrough = true })
end

function M.apply()
  set_from({
    "@keyword",
    "@keyword.function",
    "@keyword.return",
    "@keyword.conditional",
    "@keyword.repeat",
    "@keyword.exception",
    "@keyword.import",
    "@keyword.modifier",
    "@type.qualifier",
    "@conditional",
    "@repeat",
    "@exception",
    "@label",
    "@lsp.type.keyword",
    "@lsp.type.keyword.c",
    "@lsp.type.keyword.cpp",
  }, "Keyword", { bold = true })

  set_from({
    "@preproc",
    "@keyword.directive",
    "@keyword.directive.define",
  }, "PreProc", { bold = true })

  -- These two local colorschemes already own detailed cross-language role
  -- maps. Preserve those maps, then apply only the exact C/C++ convergence
  -- groups below. External themes still receive the existing generic defaults.
  if vim.g.colors_name ~= "rider-light" and vim.g.colors_name ~= "ubuntu-terminal" then
    apply_generic_semantic_defaults()
  end
  apply_semantic_roles()
  apply_semantic_modifiers()

  set_from({
    "@attribute",
    "@attribute.c",
    "@attribute.cpp",
  }, "Macro", { bold = true })

  set_from({
    "@comment.documentation",
    "@comment.note",
  }, "Comment", { italic = true })

  set_from({
    "@keyword.hlsl",
    "@type.hlsl",
    "@function.hlsl",
    "@constant.hlsl",
  }, "Keyword", { bold = true })
end

function M.setup()
  if setup_done then
    return
  end
  setup_done = true

  local group = vim.api.nvim_create_augroup("UserSemanticHighlights", { clear = true })
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = group,
    callback = M.apply,
  })

  -- One deferred initial call to apply highlights after the startup colorscheme
  -- has loaded. The ColorScheme autocmd handles all subsequent theme changes.
  vim.schedule(M.apply)
end

return M
