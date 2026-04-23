-- Rider 2026 Light (IntelliJ Light editor scheme + New UI Light chrome)
-- Hand-derived from JetBrains/intellij-community master (Light.xml +
-- Light.theme.json), the same color scheme Rider 2026 ships as
-- "IntelliJ Light" / New UI Light. Self-contained, no plugin required.

vim.cmd("highlight clear")

if vim.fn.exists("syntax_on") == 1 then
  vim.cmd("syntax reset")
end

vim.o.background = "light"
vim.o.termguicolors = true
vim.g.colors_name = "rider-light"

-- ── Palette ──────────────────────────────────────────────────────────
-- Editor chrome: IntelliJ Light editor scheme + New UI Light tool window.
-- Syntax: IntelliJ Light DEFAULT_* attributes, transcribed from Light.xml.
local palette = {
  -- backgrounds
  bg            = "#FFFFFF", -- TEXT.background
  bg_dim        = "#F7F8FA", -- New UI sidebar / float
  bg_alt        = "#FCFAED", -- CARET_ROW_COLOR (cursor line)
  bg_gutter     = "#F2F2F2", -- GUTTER_BACKGROUND
  bg_visual     = "#A6D2FF", -- SELECTION_BACKGROUND
  bg_search     = "#FFE959", -- TEXT_SEARCH_RESULT_ATTRIBUTES
  bg_warn       = "#F5EAC1", -- WARNING_ATTRIBUTES
  bg_caret_id   = "#EDEBFC", -- IDENTIFIER_UNDER_CARET
  bg_write_id   = "#FCE8F4", -- WRITE_IDENTIFIER_UNDER_CARET
  bg_match      = "#93D9D9", -- MATCHED_BRACE_ATTRIBUTES
  bg_diff_mod   = "#C2D8F2", -- DIFF_MODIFIED
  bg_diff_add   = "#DDFAE0", -- New UI VCS-added (Rider tone)
  bg_diff_del   = "#F7C8C8", -- New UI VCS-removed (Rider tone)
  bg_diff_text  = "#A0BDF8", -- CombinedDiff selected active

  -- foregrounds
  fg            = "#080808", -- TEXT.foreground
  fg_dim        = "#3D3D3D", -- DOC_COMMENT_TAG_VALUE
  fg_comment    = "#8C8C8C", -- DEFAULT_LINE_COMMENT / DEFAULT_BLOCK_COMMENT
  fg_lineno     = "#ADADAD", -- LINE_NUMBERS_COLOR
  fg_lineno_cur = "#000000",
  fg_folded     = "#414D41", -- FOLDED_TEXT_ATTRIBUTES.foreground

  -- syntax (DEFAULT_* in Light.xml)
  blue_kw       = "#0033B3", -- DEFAULT_KEYWORD                bold
  blue_num      = "#1750EB", -- DEFAULT_NUMBER
  blue_attr     = "#174AD4", -- DEFAULT_ATTRIBUTE / XPATH.KEYWORD
  blue_entity   = "#174BE6", -- DEFAULT_ENTITY
  green_string  = "#067D17", -- DEFAULT_STRING
  green_escape  = "#0037A6", -- DEFAULT_VALID_STRING_ESCAPE
  red_invalid   = "#0067D1", -- DEFAULT_INVALID_STRING_ESCAPE.fg (kept as-is)
  purple_const  = "#871094", -- DEFAULT_CONSTANT, INSTANCE_FIELD, STATIC_FIELD
  purple_global = "#830091", -- JS.GLOBAL_VARIABLE
  teal_fn       = "#00627A", -- DEFAULT_FUNCTION_DECLARATION
  teal_param    = "#007E8A", -- TYPE_PARAMETER_NAME_ATTRIBUTES (#7e8a)
  teal_local    = "#2A8C7C", -- JS.LOCAL_VARIABLE
  teal_recv     = "#008A91", -- GO_METHOD_RECEIVER (#8a91)
  yellow_meta   = "#9E880D", -- DEFAULT_METADATA / annotations
  brown_pkg     = "#805900", -- GO_PACKAGE
  red_template  = "#7F0000", -- TEMPLATE_VARIABLE_ATTRIBUTES
  red_error     = "#F50000", -- WRONG_REFERENCES_ATTRIBUTES
  link          = "#006DCC", -- HYPERLINK_ATTRIBUTES (#6dcc)
  todo          = "#0088DE", -- TODO_DEFAULT_ATTRIBUTES (#8dde)

  -- diagnostics (Rider gutter / inspection)
  diag_error    = "#E51400",
  diag_warn     = "#A98307",
  diag_info     = "#3574F0",
  diag_hint     = "#808080",
  diag_ok       = "#1E8E3E",

  -- chrome accents (New UI Light)
  border        = "#EBECF0",
  border_strong = "#C9CCD6",
  accent        = "#3574F0", -- New UI primary blue
  status_bg     = "#F7F8FA",
  status_fg     = "#000000",
  selected_inactive_bg = "#D4D4D4",
  pmenu_sel_bg  = "#D4E2FF", -- list selected (New UI)

  -- terminal ANSI (Rider terminal defaults, light)
  black         = "#000000",
  red           = "#CD3131",
  green         = "#00BC00",
  yellow        = "#949800",
  blue          = "#0451A5",
  magenta       = "#BC05BC",
  cyan          = "#0598BC",
  white         = "#555555",
  bright_black  = "#666666",
  bright_white  = "#A5A5A5",
}

local function set(group, spec)
  vim.api.nvim_set_hl(0, group, spec)
end

local function link(group, target)
  set(group, { link = target })
end

-- ── Editor chrome ────────────────────────────────────────────────────

set("Normal",          { fg = palette.fg, bg = palette.bg })
set("NormalNC",        { fg = palette.fg, bg = palette.bg })
set("NormalFloat",     { fg = palette.fg, bg = palette.bg_dim })
set("FloatBorder",     { fg = palette.border_strong, bg = palette.bg_dim })
set("FloatTitle",      { fg = palette.accent, bg = palette.bg_dim, bold = true })
set("ColorColumn",     { bg = palette.bg_alt })
set("CursorColumn",    { bg = palette.bg_alt })
set("CursorLine",      { bg = palette.bg_alt })
set("CursorLineNr",    { fg = palette.fg_lineno_cur, bg = palette.bg_alt, bold = true })
set("CursorLineFold",  { fg = palette.fg_lineno_cur, bg = palette.bg_alt })
set("CursorLineSign",  { bg = palette.bg_alt })
set("LineNr",          { fg = palette.fg_lineno, bg = palette.bg_gutter })
set("LineNrAbove",     { fg = palette.fg_lineno, bg = palette.bg_gutter })
set("LineNrBelow",     { fg = palette.fg_lineno, bg = palette.bg_gutter })
set("SignColumn",      { bg = palette.bg_gutter })
set("FoldColumn",      { fg = palette.fg_lineno, bg = palette.bg_gutter })
set("VertSplit",       { fg = palette.border, bg = palette.bg })
link("WinSeparator",   "VertSplit")
set("StatusLine",      { fg = palette.status_fg, bg = palette.status_bg })
set("StatusLineNC",    { fg = palette.fg_comment, bg = palette.status_bg })
set("WinBar",          { fg = palette.fg, bg = palette.bg, bold = true })
set("WinBarNC",        { fg = palette.fg_comment, bg = palette.bg })
set("TabLine",         { fg = palette.fg_comment, bg = palette.bg_gutter })
set("TabLineFill",     { bg = palette.bg_gutter })
set("TabLineSel",      { fg = palette.fg, bg = palette.bg, bold = true })
set("Pmenu",           { fg = palette.fg, bg = palette.bg_dim })
set("PmenuSel",        { fg = palette.fg, bg = palette.pmenu_sel_bg, bold = true })
set("PmenuSbar",       { bg = palette.border })
set("PmenuThumb",      { bg = palette.border_strong })
set("Visual",          { bg = palette.bg_visual })
set("VisualNOS",       { bg = palette.bg_visual })
set("Search",          { fg = palette.fg, bg = palette.bg_search })
set("IncSearch",       { fg = palette.fg, bg = "#FFC800", bold = true })
set("CurSearch",       { fg = palette.fg, bg = "#FFC800", bold = true })
set("MatchParen",      { bg = palette.bg_match, bold = true })
set("Folded",          { fg = palette.fg_folded, bg = "#E9F5E6", italic = true })
set("Conceal",         { fg = palette.fg_comment, bg = palette.bg })
set("NonText",         { fg = "#C0C0C0" })
set("Whitespace",      { fg = "#D4D4D4" })
set("SpecialKey",      { fg = "#C0C0C0" })
set("Directory",       { fg = palette.blue_attr, bold = true })
set("Title",           { fg = palette.accent, bold = true })
set("Question",        { fg = palette.green_string, bold = true })
set("MoreMsg",         { fg = palette.green_string, bold = true })
set("WarningMsg",      { fg = palette.diag_warn, bold = true })
set("ErrorMsg",        { fg = palette.diag_error, bold = true })
set("ModeMsg",         { fg = palette.fg, bold = true })
set("MsgArea",         { fg = palette.fg, bg = palette.bg })
set("Cursor",          { fg = palette.bg, bg = palette.fg })
set("lCursor",         { fg = palette.bg, bg = palette.fg })

-- ── Syntax groups (IntelliJ Light DEFAULT_* mapping) ────────────────
-- keyword  → blue_kw bold
-- number   → blue_num bold
-- string   → green_string
-- type     → fg (Rider doesn't tint type names by default)
-- function → teal_fn
-- const    → purple_const italic
-- field    → purple_const
-- comment  → fg_comment italic

set("Comment",         { fg = palette.fg_comment, italic = true })
set("Constant",        { fg = palette.purple_const, italic = true })
set("String",          { fg = palette.green_string })
set("Character",       { fg = palette.green_string })
set("Number",          { fg = palette.blue_num, bold = true })
set("Boolean",         { fg = palette.blue_kw, bold = true })
set("Float",           { fg = palette.blue_num, bold = true })
set("Identifier",      { fg = palette.fg })
set("Function",        { fg = palette.teal_fn })
set("Statement",       { fg = palette.blue_kw, bold = true })
set("Conditional",     { fg = palette.blue_kw, bold = true })
set("Repeat",          { fg = palette.blue_kw, bold = true })
set("Label",           { fg = palette.fg })
set("Operator",        { fg = palette.fg })
set("Keyword",         { fg = palette.blue_kw, bold = true })
set("Exception",       { fg = palette.blue_kw, bold = true })
set("PreProc",         { fg = palette.blue_kw, bold = true })
set("Include",         { fg = palette.blue_kw, bold = true })
set("Define",          { fg = palette.blue_kw, bold = true })
set("Macro",           { fg = palette.yellow_meta })
set("PreCondit",       { fg = palette.blue_kw, bold = true })
set("Type",            { fg = palette.fg })
set("StorageClass",    { fg = palette.blue_kw, bold = true })
set("Structure",       { fg = palette.fg })
set("Typedef",         { fg = palette.fg })
set("Special",         { fg = palette.green_escape })
set("SpecialChar",     { fg = palette.green_escape })
set("Tag",             { fg = palette.blue_attr })
set("Delimiter",       { fg = palette.fg })
set("SpecialComment",  { fg = palette.fg_comment, italic = true, bold = true })
set("Debug",           { fg = palette.diag_warn })
set("Underlined",      { fg = palette.link, underline = true })
set("Ignore",          { fg = palette.fg_lineno })
set("Error",           { fg = palette.diag_error, bold = true })
set("Todo",            { fg = palette.todo, italic = true, bold = true })

-- ── Diagnostics ──────────────────────────────────────────────────────

set("DiagnosticError",  { fg = palette.diag_error })
set("DiagnosticWarn",   { fg = palette.diag_warn })
set("DiagnosticInfo",   { fg = palette.diag_info })
set("DiagnosticHint",   { fg = palette.diag_hint })
set("DiagnosticOk",     { fg = palette.diag_ok })
set("DiagnosticVirtualTextError", { fg = palette.diag_error, bg = "#FCE4E4" })
set("DiagnosticVirtualTextWarn",  { fg = palette.diag_warn,  bg = palette.bg_warn })
set("DiagnosticVirtualTextInfo",  { fg = palette.diag_info,  bg = "#E4ECFB" })
set("DiagnosticVirtualTextHint",  { fg = palette.diag_hint,  bg = "#EFEFEF" })
set("DiagnosticUnderlineError", { undercurl = true, sp = palette.diag_error })
set("DiagnosticUnderlineWarn",  { undercurl = true, sp = palette.diag_warn })
set("DiagnosticUnderlineInfo",  { undercurl = true, sp = palette.diag_info })
set("DiagnosticUnderlineHint",  { undercurl = true, sp = palette.diag_hint })
set("DiagnosticUnnecessary",    { fg = palette.fg_lineno, italic = true })
set("DiagnosticDeprecated",     { fg = palette.fg_comment, strikethrough = true })

-- ── Diff / VCS ───────────────────────────────────────────────────────

set("DiffAdd",     { bg = palette.bg_diff_add })
set("DiffChange",  { bg = palette.bg_diff_mod })
set("DiffDelete",  { bg = palette.bg_diff_del })
set("DiffText",    { bg = palette.bg_diff_text, bold = true })
set("Added",       { fg = palette.diag_ok })
set("Changed",     { fg = palette.blue_attr })
set("Removed",     { fg = palette.diag_error })

set("GitSignsAdd",       { fg = "#62B543", bg = palette.bg_gutter })
set("GitSignsChange",    { fg = "#3574F0", bg = palette.bg_gutter })
set("GitSignsDelete",    { fg = "#DB5860", bg = palette.bg_gutter })
set("GitSignsAddNr",     { fg = "#62B543" })
set("GitSignsChangeNr",  { fg = "#3574F0" })
set("GitSignsDeleteNr",  { fg = "#DB5860" })

-- ── Misc ─────────────────────────────────────────────────────────────

set("QuickFixLine",      { bg = palette.bg_caret_id })
set("LspReferenceText",  { bg = palette.bg_caret_id })
set("LspReferenceRead",  { bg = palette.bg_caret_id })
set("LspReferenceWrite", { bg = palette.bg_write_id })
set("LspInlayHint",      { fg = "#888888", bg = "#EEEEEE", italic = true })
set("LspCodeLens",       { fg = palette.fg_comment, italic = true })
set("LspSignatureActiveParameter", { fg = palette.teal_param, bold = true })

-- ── Treesitter / LSP semantic tokens (IntelliJ Light) ───────────────
-- IntelliJ tints by *role* not syntax category:
--   keywords/control-flow  → blue_kw bold
--   number/boolean         → blue_num bold
--   string                 → green_string
--   function declaration   → teal_fn
--   function call          → fg (DEFAULT_FUNCTION_CALL is empty)
--   instance/static field  → purple_const (italic on static)
--   constant/enum member   → purple_const italic
--   parameter              → fg
--   type / type-param      → fg  (type-param sometimes teal_param)
--   namespace/module       → fg
--   metadata/annotation    → yellow_meta
--   macro                  → yellow_meta

-- keywords & control flow
set("@keyword",            { fg = palette.blue_kw, bold = true })
set("@keyword.function",   { fg = palette.blue_kw, bold = true })
set("@keyword.return",     { fg = palette.blue_kw, bold = true })
set("@keyword.operator",   { fg = palette.blue_kw, bold = true })
set("@keyword.modifier",   { fg = palette.blue_kw, bold = true })
set("@keyword.import",     { fg = palette.blue_kw, bold = true })
set("@keyword.exception",  { fg = palette.blue_kw, bold = true })
set("@keyword.repeat",     { fg = palette.blue_kw, bold = true })
set("@keyword.conditional",{ fg = palette.blue_kw, bold = true })
set("@conditional",        { fg = palette.blue_kw, bold = true })
set("@repeat",             { fg = palette.blue_kw, bold = true })
set("@exception",          { fg = palette.blue_kw, bold = true })
set("@label",              { fg = palette.fg })
set("@lsp.type.keyword",   { fg = palette.blue_kw, bold = true })

-- types: plain fg in Rider light (no tint by default)
set("@type",               { fg = palette.fg })
set("@type.builtin",       { fg = palette.blue_kw, bold = true })
set("@type.definition",    { fg = palette.fg })
set("@type.qualifier",     { fg = palette.blue_kw, bold = true })
set("@lsp.type.type",      { fg = palette.fg })
set("@lsp.type.type.cpp",  { fg = palette.fg })
set("@lsp.type.class",     { fg = palette.fg })
set("@lsp.type.class.cpp", { fg = palette.fg })
set("@lsp.type.struct",    { fg = palette.fg })
set("@lsp.type.struct.cpp",{ fg = palette.fg })
set("@lsp.type.enum",      { fg = palette.fg })
set("@lsp.type.enum.cpp",  { fg = palette.fg })
set("@lsp.type.interface", { fg = palette.fg })
set("@lsp.type.typeParameter",     { fg = palette.teal_param })
set("@lsp.type.typeParameter.cpp", { fg = palette.teal_param })

-- functions & methods
set("@function",                 { fg = palette.teal_fn })
set("@function.call",            { fg = palette.fg })
set("@function.method",          { fg = palette.teal_fn })
set("@function.method.call",     { fg = palette.fg })
set("@function.builtin",         { fg = palette.blue_kw, bold = true })
set("@function.macro",           { fg = palette.yellow_meta })
set("@constructor",              { fg = palette.teal_fn })
set("@lsp.type.function",        { fg = palette.teal_fn })
set("@lsp.type.function.cpp",    { fg = palette.teal_fn })
set("@lsp.type.method",          { fg = palette.teal_fn })
set("@lsp.type.method.cpp",      { fg = palette.teal_fn })
set("@lsp.typemod.function.declaration", { fg = palette.teal_fn })
set("@lsp.typemod.method.declaration",   { fg = palette.teal_fn })
set("@lsp.typemod.function.defaultLibrary", { fg = palette.blue_kw, bold = true })

-- namespaces / modules
set("@module",                   { fg = palette.fg })
set("@lsp.type.namespace",       { fg = palette.fg })
set("@lsp.type.namespace.cpp",   { fg = palette.fg })

-- fields & properties → purple
set("@field",                    { fg = palette.purple_const })
set("@property",                 { fg = palette.purple_const })
set("@variable.member",          { fg = palette.purple_const })
set("@lsp.type.property",        { fg = palette.purple_const })
set("@lsp.type.property.cpp",    { fg = palette.purple_const })
set("@lsp.typemod.property.static", { fg = palette.purple_const, italic = true })

-- parameters → plain fg
set("@parameter",                { fg = palette.fg })
set("@variable.parameter",       { fg = palette.fg })
set("@lsp.type.parameter",       { fg = palette.fg })
set("@lsp.type.parameter.cpp",   { fg = palette.fg })

-- variables
set("@variable",                 { fg = palette.fg })
set("@variable.builtin",         { fg = palette.blue_kw, bold = true })
set("@lsp.type.variable",        { fg = palette.fg })
set("@lsp.type.variable.cpp",    { fg = palette.fg })
set("@lsp.typemod.variable.static",   { fg = palette.purple_const, italic = true })
set("@lsp.typemod.variable.readonly", { fg = palette.purple_const, italic = true })
set("@lsp.typemod.variable.global",   { fg = palette.purple_global })

-- constants & enum members
set("@constant",                 { fg = palette.purple_const, italic = true })
set("@constant.builtin",         { fg = palette.blue_kw, bold = true })
set("@lsp.type.enumMember",      { fg = palette.purple_const, italic = true })
set("@lsp.type.enumMember.cpp",  { fg = palette.purple_const, italic = true })

-- macros & attributes
set("@constant.macro",           { fg = palette.yellow_meta })
set("@lsp.type.macro",           { fg = palette.yellow_meta })
set("@lsp.type.macro.cpp",       { fg = palette.yellow_meta })
set("@attribute",                { fg = palette.yellow_meta })
set("@attribute.cpp",            { fg = palette.yellow_meta })
set("@preproc",                  { fg = palette.blue_kw, bold = true })

-- strings & literals
set("@string",                   { fg = palette.green_string })
set("@string.escape",            { fg = palette.green_escape, bold = true })
set("@string.special",           { fg = palette.green_escape, bold = true })
set("@string.regex",             { fg = palette.green_escape })
set("@character",                { fg = palette.green_string })
set("@number",                   { fg = palette.blue_num, bold = true })
set("@number.float",             { fg = palette.blue_num, bold = true })
set("@boolean",                  { fg = palette.blue_kw, bold = true })

-- operators & punctuation
set("@operator",                 { fg = palette.fg })
set("@punctuation.bracket",      { fg = palette.fg })
set("@punctuation.delimiter",    { fg = palette.fg })
set("@punctuation.special",      { fg = palette.blue_kw })

-- comments
set("@comment",                  { fg = palette.fg_comment, italic = true })
set("@comment.documentation",    { fg = palette.fg_comment, italic = true })
set("@comment.note",             { fg = palette.todo, italic = true, bold = true })
set("@comment.todo",             { fg = palette.todo, italic = true, bold = true })
set("@comment.warning",          { fg = palette.diag_warn, italic = true, bold = true })
set("@comment.error",            { fg = palette.diag_error, italic = true, bold = true })

-- markup
set("@markup.heading",           { fg = palette.blue_kw, bold = true })
set("@markup.strong",            { bold = true })
set("@markup.italic",            { italic = true })
set("@markup.underline",         { underline = true })
set("@markup.strikethrough",     { strikethrough = true })
set("@markup.link",              { fg = palette.link, underline = true })
set("@markup.link.url",          { fg = palette.link, underline = true })
set("@markup.raw",               { fg = palette.green_string, bg = palette.bg_dim })
set("@markup.list",              { fg = palette.blue_kw })
set("@markup.quote",             { fg = palette.fg_comment, italic = true })

-- ── BufferLine (light, Rider-tab feel) ───────────────────────────────

local bl = {
  sel_fg = palette.fg,
  sel_bg = palette.bg,
  vis_fg = palette.fg,
  vis_bg = "#EBECF0",
  buf_fg = palette.fg_comment,
  buf_bg = palette.bg_gutter,
  fill   = palette.bg_gutter,
  sep    = palette.border,
  ind    = palette.accent,
  mod    = palette.diag_warn,
  pick   = palette.diag_error,
}

set("BufferLineFill",                  { bg = bl.fill })
set("BufferLineBackground",            { fg = bl.buf_fg, bg = bl.buf_bg })
set("BufferLineBuffer",                { fg = bl.buf_fg, bg = bl.buf_bg })
set("BufferLineBufferSelected",        { fg = bl.sel_fg, bg = bl.sel_bg, bold = true })
set("BufferLineIndicatorSelected",     { fg = bl.ind,    bg = bl.sel_bg })
set("BufferLineBufferVisible",         { fg = bl.vis_fg, bg = bl.vis_bg })
set("BufferLineIndicatorVisible",      { fg = bl.vis_fg, bg = bl.vis_bg })
set("BufferLineSeparator",             { fg = bl.sep, bg = bl.buf_bg })
set("BufferLineSeparatorSelected",     { fg = bl.sep, bg = bl.sel_bg })
set("BufferLineSeparatorVisible",      { fg = bl.sep, bg = bl.vis_bg })
set("BufferLineCloseButton",           { fg = bl.buf_fg, bg = bl.buf_bg })
set("BufferLineCloseButtonSelected",   { fg = palette.diag_error, bg = bl.sel_bg })
set("BufferLineCloseButtonVisible",    { fg = bl.vis_fg, bg = bl.vis_bg })
set("BufferLineModified",              { fg = bl.mod, bg = bl.buf_bg })
set("BufferLineModifiedSelected",      { fg = bl.mod, bg = bl.sel_bg })
set("BufferLineModifiedVisible",       { fg = bl.mod, bg = bl.vis_bg })
set("BufferLineDuplicate",             { fg = bl.buf_fg, bg = bl.buf_bg, italic = true })
set("BufferLineDuplicateSelected",     { fg = bl.sel_fg, bg = bl.sel_bg, italic = true })
set("BufferLineDuplicateVisible",      { fg = bl.vis_fg, bg = bl.vis_bg, italic = true })
set("BufferLineNumbers",               { fg = bl.buf_fg, bg = bl.buf_bg })
set("BufferLineNumbersSelected",       { fg = bl.ind, bg = bl.sel_bg, bold = true })
set("BufferLineNumbersVisible",        { fg = bl.vis_fg, bg = bl.vis_bg })
set("BufferLineDiagnostic",            { fg = bl.buf_fg, bg = bl.buf_bg })
set("BufferLineDiagnosticSelected",    { fg = palette.diag_info, bg = bl.sel_bg })
set("BufferLineDiagnosticVisible",     { fg = bl.vis_fg, bg = bl.vis_bg })
set("BufferLineError",                 { fg = palette.diag_error, bg = bl.buf_bg })
set("BufferLineErrorSelected",         { fg = palette.diag_error, bg = bl.sel_bg })
set("BufferLineErrorVisible",          { fg = palette.diag_error, bg = bl.vis_bg })
set("BufferLineErrorDiagnostic",         { fg = palette.diag_error, bg = bl.buf_bg })
set("BufferLineErrorDiagnosticSelected", { fg = palette.diag_error, bg = bl.sel_bg })
set("BufferLineErrorDiagnosticVisible",  { fg = palette.diag_error, bg = bl.vis_bg })
set("BufferLineWarning",               { fg = palette.diag_warn, bg = bl.buf_bg })
set("BufferLineWarningSelected",       { fg = palette.diag_warn, bg = bl.sel_bg })
set("BufferLineWarningVisible",        { fg = palette.diag_warn, bg = bl.vis_bg })
set("BufferLineHint",                  { fg = palette.diag_hint, bg = bl.buf_bg })
set("BufferLineHintSelected",          { fg = palette.diag_hint, bg = bl.sel_bg })
set("BufferLineHintVisible",           { fg = palette.diag_hint, bg = bl.vis_bg })
set("BufferLineInfo",                  { fg = palette.diag_info, bg = bl.buf_bg })
set("BufferLineInfoSelected",          { fg = palette.diag_info, bg = bl.sel_bg })
set("BufferLineInfoVisible",           { fg = palette.diag_info, bg = bl.vis_bg })
set("BufferLinePick",                  { fg = bl.pick, bg = bl.buf_bg, bold = true })
set("BufferLinePickSelected",          { fg = bl.pick, bg = bl.sel_bg, bold = true })
set("BufferLinePickVisible",           { fg = bl.pick, bg = bl.vis_bg, bold = true })
set("BufferLineTab",                   { fg = bl.buf_fg, bg = bl.buf_bg })
set("BufferLineTabSelected",           { fg = bl.sel_fg, bg = bl.sel_bg, bold = true })
set("BufferLineTabSeparator",          { fg = bl.sep, bg = bl.buf_bg })
set("BufferLineTabSeparatorSelected",  { fg = bl.sep, bg = bl.sel_bg })
set("BufferLineTabClose",              { fg = palette.diag_error, bg = bl.buf_bg })
set("BufferLineGroupLabel",            { fg = bl.sel_fg, bg = bl.ind, bold = true })
set("BufferLineGroupSeparator",        { fg = bl.sep, bg = bl.fill })
set("BufferLineOffsetSeparator",       { fg = bl.sep, bg = bl.fill })
set("BufferLineTruncMarker",           { fg = bl.buf_fg, bg = bl.fill })

-- ── Common plugin surfaces (Rider-ish light tints) ──────────────────

-- Telescope / Snacks pickers
set("TelescopeNormal",     { fg = palette.fg, bg = palette.bg_dim })
set("TelescopeBorder",     { fg = palette.border_strong, bg = palette.bg_dim })
set("TelescopePromptNormal",   { bg = palette.bg })
set("TelescopePromptBorder",   { fg = palette.border_strong, bg = palette.bg })
set("TelescopePromptTitle",    { fg = palette.bg, bg = palette.accent, bold = true })
set("TelescopeResultsTitle",   { fg = palette.fg, bg = palette.bg_dim })
set("TelescopePreviewTitle",   { fg = palette.bg, bg = palette.diag_ok, bold = true })
set("TelescopeSelection",      { bg = palette.pmenu_sel_bg, bold = true })
set("TelescopeMatching",       { fg = palette.diag_error, bold = true })

set("SnacksPicker",            { fg = palette.fg, bg = palette.bg_dim })
set("SnacksPickerBorder",      { fg = palette.border_strong, bg = palette.bg_dim })
set("SnacksPickerInput",       { bg = palette.bg })
set("SnacksPickerInputBorder", { fg = palette.border_strong, bg = palette.bg })
set("SnacksPickerSelection",   { bg = palette.pmenu_sel_bg, bold = true })
set("SnacksPickerMatch",       { fg = palette.diag_error, bold = true })
set("SnacksPickerDir",         { fg = palette.fg_comment })
set("SnacksPickerFile",        { fg = palette.fg })

-- which-key
set("WhichKey",        { fg = palette.blue_kw })
set("WhichKeyGroup",   { fg = palette.purple_const })
set("WhichKeyDesc",    { fg = palette.fg })
set("WhichKeySeparator", { fg = palette.fg_comment })
set("WhichKeyFloat",   { bg = palette.bg_dim })

-- nvim-cmp / blink
set("CmpItemAbbr",            { fg = palette.fg })
set("CmpItemAbbrMatch",       { fg = palette.diag_error, bold = true })
set("CmpItemAbbrMatchFuzzy",  { fg = palette.diag_error })
set("CmpItemKindFunction",    { fg = palette.teal_fn })
set("CmpItemKindMethod",      { fg = palette.teal_fn })
set("CmpItemKindKeyword",     { fg = palette.blue_kw })
set("CmpItemKindVariable",    { fg = palette.fg })
set("CmpItemKindClass",       { fg = palette.purple_const })
set("CmpItemKindStruct",      { fg = palette.purple_const })
set("CmpItemKindInterface",   { fg = palette.purple_const })
set("CmpItemKindField",       { fg = palette.purple_const })
set("CmpItemKindProperty",    { fg = palette.purple_const })
set("CmpItemKindEnumMember",  { fg = palette.purple_const, italic = true })
set("CmpItemKindConstant",    { fg = palette.purple_const, italic = true })
set("CmpItemKindEnum",        { fg = palette.purple_const })
set("CmpItemKindText",        { fg = palette.green_string })

-- gitsigns inline
set("GitSignsCurrentLineBlame", { fg = palette.fg_comment, italic = true })

-- mini.indentscope / indent-blankline
set("IndentBlanklineChar",          { fg = "#E5E5E5" })
set("IndentBlanklineContextChar",   { fg = palette.fg_lineno })
set("IblIndent",                    { fg = "#E5E5E5" })
set("IblScope",                     { fg = palette.fg_lineno })

-- nvim-tree / neo-tree
set("NeoTreeNormal",       { fg = palette.fg, bg = palette.bg_dim })
set("NeoTreeNormalNC",     { fg = palette.fg, bg = palette.bg_dim })
set("NeoTreeRootName",     { fg = palette.purple_const, bold = true })
set("NeoTreeDirectoryName",{ fg = palette.fg })
set("NeoTreeDirectoryIcon",{ fg = palette.yellow_meta })
set("NeoTreeFileName",     { fg = palette.fg })
set("NeoTreeIndentMarker", { fg = "#E5E5E5" })
set("NeoTreeGitAdded",     { fg = palette.diag_ok })
set("NeoTreeGitModified",  { fg = palette.blue_attr })
set("NeoTreeGitDeleted",   { fg = palette.diag_error })
set("NeoTreeGitUntracked", { fg = palette.diag_warn })

-- Notify / noice / lualine integration handled by their own modules.

-- ── Terminal colours ─────────────────────────────────────────────────

vim.g.terminal_color_0  = palette.black
vim.g.terminal_color_1  = palette.red
vim.g.terminal_color_2  = palette.green
vim.g.terminal_color_3  = palette.yellow
vim.g.terminal_color_4  = palette.blue
vim.g.terminal_color_5  = palette.magenta
vim.g.terminal_color_6  = palette.cyan
vim.g.terminal_color_7  = palette.white
vim.g.terminal_color_8  = palette.bright_black
vim.g.terminal_color_9  = "#CD3131"
vim.g.terminal_color_10 = "#14CE14"
vim.g.terminal_color_11 = "#B5BA00"
vim.g.terminal_color_12 = "#0451A5"
vim.g.terminal_color_13 = "#BC05BC"
vim.g.terminal_color_14 = "#0598BC"
vim.g.terminal_color_15 = palette.bright_white

-- ── Filetype-specific syntax depth (preserve Rider素净 base) ─────────
-- Rider keeps the editor素净 by tinting *declarations* and leaving
-- *call sites* / *parameters* / *types* uncolored. The blocks below add
-- depth where Neovim treesitter exposes more granularity than IntelliJ
-- tokens — without overriding the C#-style decisions above.

-- ── Markdown (heading levels, code, links) ──────────────────────────
set("@markup.heading.1.markdown",  { fg = palette.blue_kw,     bold = true })
set("@markup.heading.2.markdown",  { fg = palette.purple_const, bold = true })
set("@markup.heading.3.markdown",  { fg = palette.teal_fn,     bold = true })
set("@markup.heading.4.markdown",  { fg = palette.blue_attr,   bold = true })
set("@markup.heading.5.markdown",  { fg = palette.yellow_meta, bold = true })
set("@markup.heading.6.markdown",  { fg = palette.fg_dim,      bold = true })
set("@markup.heading.1.marker.markdown", { fg = palette.blue_kw,     bold = true })
set("@markup.heading.2.marker.markdown", { fg = palette.purple_const, bold = true })
set("@markup.heading.3.marker.markdown", { fg = palette.teal_fn,     bold = true })
set("@markup.heading.4.marker.markdown", { fg = palette.blue_attr,   bold = true })
set("@markup.heading.5.marker.markdown", { fg = palette.yellow_meta, bold = true })
set("@markup.heading.6.marker.markdown", { fg = palette.fg_dim,      bold = true })
set("@markup.raw.markdown",        { fg = palette.green_string })
set("@markup.raw.block.markdown",  { fg = palette.green_string, bg = palette.bg_dim })
set("@markup.raw.delimiter.markdown", { fg = palette.fg_comment })
set("@markup.list.markdown",       { fg = palette.blue_kw, bold = true })
set("@markup.list.checked.markdown",   { fg = palette.diag_ok })
set("@markup.list.unchecked.markdown", { fg = palette.fg_comment })
set("@markup.link.label.markdown_inline", { fg = palette.link })
set("@markup.link.url.markdown_inline",   { fg = palette.green_string, underline = true })
set("@punctuation.special.markdown",      { fg = palette.blue_kw })
set("@markup.quote.markdown",      { fg = palette.fg_comment, italic = true })
set("markdownH1",  { fg = palette.blue_kw,     bold = true })
set("markdownH2",  { fg = palette.purple_const, bold = true })
set("markdownH3",  { fg = palette.teal_fn,     bold = true })
set("markdownH4",  { fg = palette.blue_attr,   bold = true })
set("markdownH5",  { fg = palette.yellow_meta, bold = true })
set("markdownH6",  { fg = palette.fg_dim,      bold = true })
set("markdownCode",        { fg = palette.green_string, bg = palette.bg_dim })
set("markdownCodeBlock",   { fg = palette.green_string, bg = palette.bg_dim })
set("markdownLinkText",    { fg = palette.link, underline = true })
set("markdownUrl",         { fg = palette.green_string, underline = true })

-- ── HTML / XML (WebStorm-ish: tag teal, attr blue, value green) ─────
set("@tag",                        { fg = palette.teal_fn })
set("@tag.builtin",                { fg = palette.teal_fn, bold = true })
set("@tag.attribute",              { fg = palette.blue_attr })
set("@tag.delimiter",              { fg = palette.fg_comment })
set("@tag.html",                   { fg = palette.teal_fn })
set("@tag.attribute.html",         { fg = palette.blue_attr })
set("@tag.delimiter.html",         { fg = palette.fg_comment })
set("@string.special.url.html",    { fg = palette.link, underline = true })
set("htmlTag",         { fg = palette.fg_comment })
set("htmlEndTag",      { fg = palette.fg_comment })
set("htmlTagName",     { fg = palette.teal_fn })
set("htmlArg",         { fg = palette.blue_attr })
set("htmlString",      { fg = palette.green_string })
set("htmlSpecialChar", { fg = palette.green_escape, bold = true })
set("xmlTag",          { fg = palette.teal_fn })
set("xmlTagName",      { fg = palette.teal_fn })
set("xmlEndTag",       { fg = palette.teal_fn })
set("xmlAttrib",       { fg = palette.blue_attr })

-- ── CSS / SCSS (WebStorm: prop blue, value purple, selector teal) ───
set("@property.css",               { fg = palette.blue_attr })
set("@type.css",                   { fg = palette.teal_fn })
set("@type.tag.css",               { fg = palette.teal_fn })
set("@string.css",                 { fg = palette.green_string })
set("@number.css",                 { fg = palette.blue_num, bold = true })
set("@function.css",               { fg = palette.teal_fn })
set("@constant.css",               { fg = palette.purple_const })
set("@attribute.css",              { fg = palette.purple_const, italic = true })
set("@punctuation.delimiter.css",  { fg = palette.fg })

-- ── JSON / YAML / TOML (key/string distinction) ─────────────────────
set("@property.json",              { fg = palette.purple_const })
set("@string.json",                { fg = palette.green_string })
set("@number.json",                { fg = palette.blue_num, bold = true })
set("@boolean.json",               { fg = palette.blue_kw, bold = true })
set("@constant.builtin.json",      { fg = palette.blue_kw, bold = true }) -- null
set("@property.yaml",              { fg = palette.purple_const })
set("@string.yaml",                { fg = palette.green_string })
set("@number.yaml",                { fg = palette.blue_num, bold = true })
set("@boolean.yaml",               { fg = palette.blue_kw, bold = true })
set("@type.yaml",                  { fg = palette.yellow_meta }) -- !!tags / anchors
set("@property.toml",              { fg = palette.purple_const })
set("@type.toml",                  { fg = palette.blue_kw, bold = true }) -- [section]
set("yamlBlockMappingKey", { fg = palette.purple_const })
set("yamlPlainScalar",     { fg = palette.green_string })
set("yamlFlowString",      { fg = palette.green_string })
set("jsonKeyword",         { fg = palette.purple_const })
set("jsonString",          { fg = palette.green_string })
set("jsonNumber",          { fg = palette.blue_num, bold = true })
set("jsonBoolean",         { fg = palette.blue_kw, bold = true })
set("jsonNull",            { fg = palette.blue_kw, bold = true })

-- ── Lua (LuaLS modifiers + telescope LazyVim feel) ──────────────────
-- Module table fields (M.foo) → purple like other fields
set("@variable.member.lua",        { fg = palette.purple_const })
set("@property.lua",               { fg = palette.purple_const })
-- self in Lua → keyword-blue (matches `this` in C-family treatment)
set("@variable.builtin.lua",       { fg = palette.blue_kw, bold = true })
-- vim.* / require / pcall etc. → fg keep, but builtin functions teal
set("@function.builtin.lua",       { fg = palette.blue_kw, bold = true })
-- LuaLS semantic tokens
set("@lsp.type.namespace.lua",     { fg = palette.fg })
set("@lsp.type.function.lua",      { fg = palette.teal_fn })
set("@lsp.type.method.lua",        { fg = palette.teal_fn })
set("@lsp.type.property.lua",      { fg = palette.purple_const })
set("@lsp.typemod.variable.global.lua", { fg = palette.purple_global })

-- ── Python (PyCharm: self purple-italic, decorator yellow, kwarg fg)─
set("@variable.builtin.python",    { fg = palette.blue_kw, bold = true }) -- self/cls
set("@function.builtin.python",    { fg = palette.blue_kw, bold = true })
set("@attribute.python",           { fg = palette.yellow_meta }) -- @decorator
set("@string.documentation.python",{ fg = palette.green_string, italic = true })
set("@type.builtin.python",        { fg = palette.blue_kw, bold = true })

-- ── JavaScript / TypeScript (WebStorm: this italic, jsx tag teal) ───
set("@variable.builtin.javascript",{ fg = palette.blue_kw, bold = true }) -- this/super
set("@variable.builtin.typescript",{ fg = palette.blue_kw, bold = true })
set("@type.builtin.javascript",    { fg = palette.blue_kw, bold = true })
set("@type.builtin.typescript",    { fg = palette.blue_kw, bold = true })
set("@constructor.tsx",            { fg = palette.teal_fn })
set("@constructor.jsx",            { fg = palette.teal_fn })
set("@tag.tsx",                    { fg = palette.teal_fn })
set("@tag.jsx",                    { fg = palette.teal_fn })
set("@tag.attribute.tsx",          { fg = palette.blue_attr })
set("@tag.attribute.jsx",          { fg = palette.blue_attr })
set("@string.regexp",              { fg = palette.green_escape })
set("@punctuation.special.regex",  { fg = palette.blue_kw, bold = true })

-- ── C / C++ (CLion-light: namespace fg, concept teal, label fg) ─────
-- Note: keep @function.call as fg per Rider/CLion design. Do not染.
set("@lsp.type.concept",           { fg = palette.teal_fn, italic = true })
set("@lsp.type.concept.cpp",       { fg = palette.teal_fn, italic = true })
set("@lsp.typemod.method.static",  { fg = palette.teal_fn, italic = true })
set("@lsp.typemod.method.static.cpp", { fg = palette.teal_fn, italic = true })
set("@lsp.typemod.function.static",{ fg = palette.teal_fn, italic = true })
set("@lsp.typemod.method.deprecated",   { strikethrough = true })
set("@lsp.typemod.function.deprecated", { strikethrough = true })
set("@lsp.typemod.variable.deprecated", { strikethrough = true })
set("@lsp.typemod.method.abstract",     { italic = true })
set("@lsp.typemod.method.virtual",      { italic = true })
set("@lsp.type.unknown",           { fg = palette.fg, undercurl = true, sp = palette.diag_warn })
set("@constructor.cpp",            { fg = palette.fg }) -- `new Foo()`: Foo stays type-fg
set("@module.cpp",                 { fg = palette.fg })

-- ── Rust (rust-analyzer semantic) ───────────────────────────────────
set("@lsp.type.lifetime.rust",     { fg = palette.purple_const, italic = true })
set("@lsp.type.selfKeyword.rust",  { fg = palette.blue_kw, bold = true })
set("@lsp.type.derive.rust",       { fg = palette.yellow_meta })
set("@lsp.typemod.macro.rust",     { fg = palette.yellow_meta })
set("@variable.builtin.rust",      { fg = palette.blue_kw, bold = true })

-- ── Go (gopls semantic) ─────────────────────────────────────────────
set("@variable.builtin.go",        { fg = palette.blue_kw, bold = true })
set("@function.builtin.go",        { fg = palette.blue_kw, bold = true })
set("@module.go",                  { fg = palette.brown_pkg })
set("@lsp.type.namespace.go",      { fg = palette.brown_pkg })
set("@lsp.typemod.variable.readonly.go", { fg = palette.purple_const, italic = true })

-- ── Diff filetype (when viewing .diff/.patch as buffer) ─────────────
set("@diff.plus",                  { fg = palette.diag_ok })
set("@diff.minus",                 { fg = palette.diag_error })
set("@diff.delta",                 { fg = palette.blue_attr })
set("diffAdded",       { fg = palette.diag_ok })
set("diffRemoved",     { fg = palette.diag_error })
set("diffChanged",     { fg = palette.blue_attr })
set("diffLine",        { fg = palette.purple_const, bold = true })
set("diffFile",        { fg = palette.fg, bold = true })
set("diffNewFile",     { fg = palette.diag_ok, bold = true })
set("diffOldFile",     { fg = palette.diag_error, bold = true })
set("diffSubname",     { fg = palette.fg_comment })
set("diffIndexLine",   { fg = palette.fg_comment, italic = true })

-- ── Git filetypes (commit / rebase / config) ────────────────────────
set("gitcommitSummary",        { fg = palette.fg, bold = true })
set("gitcommitOverflow",       { fg = palette.diag_error, bold = true })
set("gitcommitComment",        { fg = palette.fg_comment, italic = true })
set("gitcommitHeader",         { fg = palette.purple_const, bold = true })
set("gitcommitBranch",         { fg = palette.teal_fn, bold = true })
set("gitcommitDiscardedType",  { fg = palette.diag_error })
set("gitcommitSelectedType",   { fg = palette.diag_ok })
set("@string.special.url.gitcommit", { fg = palette.link, underline = true })

-- ── Vimdoc / help ───────────────────────────────────────────────────
set("@markup.heading.1.vimdoc",    { fg = palette.blue_kw, bold = true })
set("@markup.heading.2.vimdoc",    { fg = palette.purple_const, bold = true })
set("@markup.heading.3.vimdoc",    { fg = palette.teal_fn, bold = true })
set("@label.vimdoc",               { fg = palette.purple_const })
set("helpHyperTextJump", { fg = palette.link, underline = true })
set("helpExample",       { fg = palette.green_string })
set("helpHeader",        { fg = palette.blue_kw, bold = true })
set("helpSectionDelim",  { fg = palette.fg_comment })

-- ── Shell scripts (bash/zsh: variables purple, builtins blue) ───────
set("@variable.bash",              { fg = palette.purple_const })
set("@function.builtin.bash",      { fg = palette.blue_kw, bold = true })
set("@string.special.bash",        { fg = palette.green_escape, bold = true })
set("bashStatement",   { fg = palette.blue_kw, bold = true })
set("shStatement",     { fg = palette.blue_kw, bold = true })
set("shVariable",      { fg = palette.purple_const })
set("shDerefSimple",   { fg = palette.purple_const })

-- ── SQL ─────────────────────────────────────────────────────────────
set("@keyword.sql",                { fg = palette.blue_kw, bold = true })
set("@type.builtin.sql",           { fg = palette.blue_kw, bold = true })
set("@function.builtin.sql",       { fg = palette.teal_fn })
set("@variable.sql",               { fg = palette.fg })

-- ── Regex ───────────────────────────────────────────────────────────
set("@operator.regex",             { fg = palette.blue_kw, bold = true })
set("@constant.character.regex",   { fg = palette.purple_const })
set("@string.special.regex",       { fg = palette.green_escape, bold = true })

-- ── Generic LSP semantic modifiers (apply across languages) ─────────
set("@lsp.mod.deprecated",         { strikethrough = true })
set("@lsp.mod.readonly",           { italic = true })
set("@lsp.mod.defaultLibrary",     { fg = palette.blue_kw, bold = true })
set("@lsp.typemod.variable.defaultLibrary", { fg = palette.blue_kw, bold = true })
set("@lsp.typemod.class.defaultLibrary",    { fg = palette.fg })
set("@lsp.typemod.type.defaultLibrary",     { fg = palette.fg })
