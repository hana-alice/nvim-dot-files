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

-- Mature IDE themes use a few coherent colour families, not one accent per
-- semantic token. These profiles follow that restraint while reusing only the
-- active colorscheme's own palette:
--   * type family: type/class/struct + namespace
--   * data family: field/property + (where suitable) enum member
--   * local family: parameter + ordinary variable
--   * callable and macro families remain distinct
-- The deliberate sharing mirrors Rider, VS Code Dark+/Light+, Catppuccin and
-- the native Monokai/Sonokai role maps. It prevents both same-role ambiguity
-- and the rainbow effect caused by forcing all eight roles to be different.
local THEME_PROFILES = {
  monokai_ristretto = {
    namespace = "Type",
    type = "Type",
    field = "Tag",
    parameter = "Normal",
    variable = "Normal",
    ["function"] = "Function",
    enum_member = "Tag",
    macro = "Number",
  },
  ["rider-light"] = {
    namespace = "Normal",
    type = "Normal",
    field = "Constant",
    parameter = "Normal",
    variable = "Normal",
    ["function"] = "Function",
    enum_member = "Constant",
    macro = "Macro",
  },
  ["ubuntu-terminal"] = {
    namespace = "Type",
    type = "Type",
    field = "Constant",
    parameter = "DiagnosticWarn",
    variable = "Normal",
    ["function"] = "Function",
    enum_member = "Constant",
    macro = "Keyword",
  },
  unokai = {
    namespace = "Type",
    type = "Type",
    field = "Identifier",
    parameter = "Normal",
    variable = "Normal",
    ["function"] = "Function",
    enum_member = "Identifier",
    macro = "Macro",
  },
  catppuccin = {
    namespace = "Type",
    type = "Type",
    field = "Tag",
    parameter = "@variable.parameter",
    variable = "Normal",
    ["function"] = "Function",
    enum_member = "Character",
    macro = "Macro",
  },
  ["sonokai-espresso"] = {
    namespace = "Type",
    type = "Type",
    field = "Identifier",
    parameter = "Normal",
    variable = "Normal",
    ["function"] = "Function",
    enum_member = "Identifier",
    macro = "Macro",
  },
}

local DEFAULT_PROFILE = {
  namespace = "Type",
  type = "Type",
  field = "Identifier",
  parameter = "Normal",
  variable = "Normal",
  ["function"] = "Function",
  enum_member = "Identifier",
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
  -- resolved and applied first, so these fallback captures cannot overwrite
  -- their language-qualified foregrounds.
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
    -- Base roles carry foreground only. Mature schemes reserve font weight
    -- for state (declaration/readonly/deprecated), so dense UE code does not
    -- become a wall of bold and italic identifiers.
    set_role(ROLE_TARGETS[role], source)

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
  -- clangd modifier extmarks sit above token-type extmarks. Mature IDE themes
  -- do not turn every declaration/static/readonly identifier bold or italic;
  -- neutralise those modifiers so dense UE code keeps one calm base weight and
  -- the role foreground remains authoritative. Deprecation is the one state
  -- that benefits from a universal, conventional glyph channel.
  set_style(modifier_targets({
    "declaration",
    "definition",
    "deduced",
    "readonly",
    "static",
    "abstract",
    "virtual",
    "dependentName",
    "defaultLibrary",
    "usedAsMutableReference",
    "usedAsMutablePointer",
    "constructorOrDestructor",
    "userDefined",
    "functionScope",
    "classScope",
    "fileScope",
    "globalScope",
  }), {})
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

  -- Resolve exact C/C++ roles before generic defaults: some mature themes
  -- expose their best role source as a Treesitter capture (Catppuccin's maroon
  -- parameter, for example), and the generic fallback intentionally rewrites
  -- unqualified captures afterwards. The `.c`/`.cpp` groups stay authoritative.
  apply_semantic_roles()

  -- These two local colorschemes already own detailed cross-language maps.
  -- Preserve them; external themes still receive the existing generic defaults.
  if vim.g.colors_name ~= "rider-light" and vim.g.colors_name ~= "ubuntu-terminal" then
    apply_generic_semantic_defaults()
  end
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
