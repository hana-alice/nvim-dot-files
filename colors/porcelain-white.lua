-- Porcelain White — a neutral, cool-white light theme.
--
-- Design intent: white editor canvas, restrained gray chrome, and saturated
-- but non-neon syntax colors. This is intentionally not a paper/beige theme.

vim.cmd("highlight clear")

if vim.fn.exists("syntax_on") == 1 then
  vim.cmd("syntax reset")
end

vim.o.background = "light"
vim.o.termguicolors = true
vim.g.colors_name = "porcelain-white"

local palette = {
  bg = "#FFFFFF",
  bg_panel = "#F6F8FA",
  bg_subtle = "#F1F4F8",
  bg_gutter = "#F6F8FA",
  bg_cursor = "#EEF4FF",
  bg_visual = "#CCE0FF",
  bg_search = "#FFE66D",
  bg_incsearch = "#FFB454",

  fg = "#0F172A",
  fg_dim = "#475569",
  fg_muted = "#64748B",
  fg_faint = "#94A3B8",

  border = "#D8DEE8",
  border_soft = "#E6EAF0",

  blue = "#1F6FEB",
  blue_deep = "#0550AE",
  cyan = "#007C89",
  green = "#116329",
  green_soft = "#DDF4E5",
  yellow = "#9A6700",
  yellow_soft = "#FFF4CE",
  orange = "#BC4C00",
  red = "#CF222E",
  red_soft = "#FFEBE9",
  purple = "#8250DF",
  pink = "#BF3989",
  teal = "#0E7C86",

  diff_add = "#DDF4E5",
  diff_change = "#DDF0FF",
  diff_delete = "#FFEBE9",
  diff_text = "#B6D7FF",

  black = "#24292F",
  white = "#FFFFFF",
}

local function set(group, spec)
  vim.api.nvim_set_hl(0, group, spec)
end

local function link(group, target)
  set(group, { link = target })
end

-- ── Editor chrome ────────────────────────────────────────────────────

set("Normal", { fg = palette.fg, bg = palette.bg })
set("NormalNC", { fg = palette.fg, bg = palette.bg })
set("NormalFloat", { fg = palette.fg, bg = palette.bg_panel })
set("FloatBorder", { fg = palette.border, bg = palette.bg_panel })
set("FloatTitle", { fg = palette.blue_deep, bg = palette.bg_panel, bold = true })
set("ColorColumn", { bg = palette.bg_subtle })
set("CursorColumn", { bg = palette.bg_cursor })
set("CursorLine", { bg = palette.bg_cursor })
set("CursorLineNr", { fg = palette.blue_deep, bg = palette.bg_cursor, bold = true })
set("CursorLineFold", { fg = palette.fg_muted, bg = palette.bg_cursor })
set("CursorLineSign", { bg = palette.bg_cursor })
set("LineNr", { fg = palette.fg_faint, bg = palette.bg_gutter })
set("LineNrAbove", { fg = palette.fg_faint, bg = palette.bg_gutter })
set("LineNrBelow", { fg = palette.fg_faint, bg = palette.bg_gutter })
set("SignColumn", { bg = palette.bg_gutter })
set("FoldColumn", { fg = palette.fg_faint, bg = palette.bg_gutter })
set("VertSplit", { fg = palette.border_soft, bg = palette.bg })
link("WinSeparator", "VertSplit")
set("StatusLine", { fg = palette.fg, bg = palette.bg_panel })
set("StatusLineNC", { fg = palette.fg_muted, bg = palette.bg_panel })
set("WinBar", { fg = palette.fg, bg = palette.bg, bold = true })
set("WinBarNC", { fg = palette.fg_muted, bg = palette.bg })
set("TabLine", { fg = palette.fg_muted, bg = palette.bg_panel })
set("TabLineFill", { bg = palette.bg_panel })
set("TabLineSel", { fg = palette.fg, bg = palette.bg, bold = true })
set("Pmenu", { fg = palette.fg, bg = palette.bg_panel })
set("PmenuSel", { fg = palette.fg, bg = "#DCEBFF", bold = true })
set("PmenuSbar", { bg = palette.border_soft })
set("PmenuThumb", { bg = palette.border })
set("Visual", { bg = palette.bg_visual })
set("VisualNOS", { bg = palette.bg_visual })
set("Search", { fg = palette.fg, bg = palette.bg_search })
set("IncSearch", { fg = palette.fg, bg = palette.bg_incsearch, bold = true })
set("CurSearch", { fg = palette.fg, bg = palette.bg_incsearch, bold = true })
set("MatchParen", { fg = palette.blue_deep, bg = "#DDF4FF", bold = true })
set("Folded", { fg = palette.fg_muted, bg = palette.bg_subtle, italic = true })
set("Conceal", { fg = palette.fg_muted, bg = palette.bg })
set("NonText", { fg = palette.fg_faint })
set("Whitespace", { fg = palette.border_soft })
set("SpecialKey", { fg = palette.fg_faint })
set("Directory", { fg = palette.blue_deep, bold = true })
set("Title", { fg = palette.blue_deep, bold = true })
set("Question", { fg = palette.green, bold = true })
set("MoreMsg", { fg = palette.green, bold = true })
set("WarningMsg", { fg = palette.orange, bold = true })
set("ErrorMsg", { fg = palette.red, bold = true })
set("ModeMsg", { fg = palette.blue_deep, bold = true })
set("MsgArea", { fg = palette.fg, bg = palette.bg })
set("Cursor", { fg = palette.bg, bg = palette.fg })
set("lCursor", { fg = palette.bg, bg = palette.fg })

-- ── Syntax ───────────────────────────────────────────────────────────

set("Comment", { fg = palette.fg_muted, italic = true })
set("Constant", { fg = palette.purple })
set("String", { fg = palette.green })
set("Character", { fg = palette.green })
set("Number", { fg = palette.orange })
set("Boolean", { fg = palette.purple, bold = true })
set("Float", { fg = palette.orange })
set("Identifier", { fg = palette.fg })
set("Function", { fg = palette.blue_deep })
set("Statement", { fg = palette.pink, bold = true })
set("Conditional", { fg = palette.pink, bold = true })
set("Repeat", { fg = palette.pink, bold = true })
set("Label", { fg = palette.pink })
set("Operator", { fg = palette.fg })
set("Keyword", { fg = palette.pink, bold = true })
set("Exception", { fg = palette.pink, bold = true })
set("PreProc", { fg = palette.purple })
set("Include", { fg = palette.purple, bold = true })
set("Define", { fg = palette.purple })
set("Macro", { fg = palette.purple })
set("PreCondit", { fg = palette.purple })
set("Type", { fg = palette.cyan })
set("StorageClass", { fg = palette.pink, bold = true })
set("Structure", { fg = palette.cyan })
set("Typedef", { fg = palette.cyan })
set("Special", { fg = palette.teal })
set("SpecialChar", { fg = palette.teal })
set("Tag", { fg = palette.blue_deep })
set("Delimiter", { fg = palette.fg_dim })
set("SpecialComment", { fg = palette.fg_muted, italic = true, bold = true })
set("Debug", { fg = palette.orange })
set("Underlined", { fg = palette.blue, underline = true })
set("Ignore", { fg = palette.fg_faint })
set("Error", { fg = palette.red, bg = palette.red_soft, bold = true })
set("Todo", { fg = palette.blue_deep, bg = "#DDF4FF", bold = true })

-- ── Diagnostics ──────────────────────────────────────────────────────

set("DiagnosticError", { fg = palette.red })
set("DiagnosticWarn", { fg = palette.yellow })
set("DiagnosticInfo", { fg = palette.blue })
set("DiagnosticHint", { fg = palette.teal })
set("DiagnosticOk", { fg = palette.green })
set("DiagnosticVirtualTextError", { fg = palette.red, bg = palette.red_soft })
set("DiagnosticVirtualTextWarn", { fg = palette.yellow, bg = palette.yellow_soft })
set("DiagnosticVirtualTextInfo", { fg = palette.blue, bg = "#EAF2FF" })
set("DiagnosticVirtualTextHint", { fg = palette.teal, bg = "#E6F6F7" })
set("DiagnosticUnderlineError", { undercurl = true, sp = palette.red })
set("DiagnosticUnderlineWarn", { undercurl = true, sp = palette.yellow })
set("DiagnosticUnderlineInfo", { undercurl = true, sp = palette.blue })
set("DiagnosticUnderlineHint", { undercurl = true, sp = palette.teal })
set("DiagnosticUnnecessary", { fg = palette.fg_faint, italic = true })
set("DiagnosticDeprecated", { fg = palette.fg_muted, strikethrough = true })

-- ── Diff / VCS ───────────────────────────────────────────────────────

set("DiffAdd", { bg = palette.diff_add })
set("DiffChange", { bg = palette.diff_change })
set("DiffDelete", { bg = palette.diff_delete })
set("DiffText", { bg = palette.diff_text, bold = true })
set("Added", { fg = palette.green })
set("Changed", { fg = palette.blue_deep })
set("Removed", { fg = palette.red })

set("GitSignsAdd", { fg = palette.green, bg = palette.bg_gutter })
set("GitSignsChange", { fg = palette.blue, bg = palette.bg_gutter })
set("GitSignsDelete", { fg = palette.red, bg = palette.bg_gutter })
set("GitSignsCurrentLineBlame", { fg = palette.fg_muted, italic = true })

-- ── Misc ─────────────────────────────────────────────────────────────

set("QuickFixLine", { bg = "#EAF2FF", bold = true })
set("LspReferenceText", { bg = "#EAF2FF" })
set("LspReferenceRead", { bg = "#EAF2FF" })
set("LspReferenceWrite", { bg = "#FFEAF6" })
set("LspInlayHint", { fg = palette.fg_muted, bg = palette.bg_subtle, italic = true })
set("LspCodeLens", { fg = palette.fg_muted, italic = true })
set("LspSignatureActiveParameter", { fg = palette.blue_deep, bold = true })

-- ── Treesitter / LSP semantic tokens ────────────────────────────────

set("@keyword", { fg = palette.pink, bold = true })
set("@keyword.function", { fg = palette.pink, bold = true })
set("@keyword.return", { fg = palette.pink, bold = true })
set("@keyword.operator", { fg = palette.pink, bold = true })
set("@keyword.modifier", { fg = palette.pink, bold = true })
set("@keyword.import", { fg = palette.purple, bold = true })
set("@keyword.exception", { fg = palette.pink, bold = true })
set("@keyword.repeat", { fg = palette.pink, bold = true })
set("@keyword.conditional", { fg = palette.pink, bold = true })
set("@conditional", { fg = palette.pink, bold = true })
set("@repeat", { fg = palette.pink, bold = true })
set("@exception", { fg = palette.pink, bold = true })
set("@label", { fg = palette.pink })
set("@lsp.type.keyword", { fg = palette.pink, bold = true })

set("@type", { fg = palette.cyan })
set("@type.builtin", { fg = palette.cyan, bold = true })
set("@type.definition", { fg = palette.cyan })
set("@type.qualifier", { fg = palette.pink, bold = true })
set("@lsp.type.type", { fg = palette.cyan })
set("@lsp.type.type.cpp", { fg = palette.cyan })
set("@lsp.type.class", { fg = palette.cyan })
set("@lsp.type.class.cpp", { fg = palette.cyan })
set("@lsp.type.struct", { fg = palette.cyan })
set("@lsp.type.struct.cpp", { fg = palette.cyan })
set("@lsp.type.enum", { fg = palette.cyan })
set("@lsp.type.enum.cpp", { fg = palette.cyan })
set("@lsp.type.interface", { fg = palette.cyan })
set("@lsp.type.typeParameter", { fg = palette.teal })
set("@lsp.type.typeParameter.cpp", { fg = palette.teal })

set("@function", { fg = palette.blue_deep })
set("@function.call", { fg = palette.blue_deep })
set("@function.method", { fg = palette.blue_deep })
set("@function.method.call", { fg = palette.blue_deep })
set("@function.builtin", { fg = palette.purple, bold = true })
set("@function.macro", { fg = palette.purple })
set("@constructor", { fg = palette.cyan })
set("@lsp.type.function", { fg = palette.blue_deep })
set("@lsp.type.function.cpp", { fg = palette.blue_deep })
set("@lsp.type.method", { fg = palette.blue_deep })
set("@lsp.type.method.cpp", { fg = palette.blue_deep })

set("@module", { fg = palette.cyan })
set("@lsp.type.namespace", { fg = palette.cyan })
set("@lsp.type.namespace.cpp", { fg = palette.cyan })

set("@field", { fg = palette.fg })
set("@property", { fg = palette.fg })
set("@variable.member", { fg = palette.fg })
set("@lsp.type.property", { fg = palette.fg })
set("@lsp.type.property.cpp", { fg = palette.fg })

set("@parameter", { fg = palette.fg_dim, italic = true })
set("@variable.parameter", { fg = palette.fg_dim, italic = true })
set("@lsp.type.parameter", { fg = palette.fg_dim, italic = true })
set("@lsp.type.parameter.cpp", { fg = palette.fg_dim, italic = true })

set("@variable", { fg = palette.fg })
set("@variable.builtin", { fg = palette.pink, bold = true })
set("@lsp.type.variable", { fg = palette.fg })
set("@lsp.type.variable.cpp", { fg = palette.fg })

set("@constant", { fg = palette.purple })
set("@constant.builtin", { fg = palette.purple, bold = true })
set("@lsp.type.enumMember", { fg = palette.purple })
set("@lsp.type.enumMember.cpp", { fg = palette.purple })

set("@constant.macro", { fg = palette.purple })
set("@lsp.type.macro", { fg = palette.purple })
set("@lsp.type.macro.cpp", { fg = palette.purple })
set("@attribute", { fg = palette.orange })
set("@attribute.cpp", { fg = palette.orange })
set("@preproc", { fg = palette.purple })

set("@string", { fg = palette.green })
set("@string.escape", { fg = palette.orange, bold = true })
set("@string.special", { fg = palette.orange })
set("@string.regex", { fg = palette.teal })
set("@character", { fg = palette.green })
set("@number", { fg = palette.orange })
set("@number.float", { fg = palette.orange })
set("@boolean", { fg = palette.purple, bold = true })

set("@operator", { fg = palette.fg })
set("@punctuation.bracket", { fg = palette.fg_dim })
set("@punctuation.delimiter", { fg = palette.fg_dim })
set("@punctuation.special", { fg = palette.pink })

set("@comment", { fg = palette.fg_muted, italic = true })
set("@comment.documentation", { fg = palette.fg_muted, italic = true })
set("@comment.note", { fg = palette.blue_deep, italic = true, bold = true })
set("@comment.todo", { fg = palette.blue_deep, bg = "#DDF4FF", bold = true })
set("@comment.warning", { fg = palette.yellow, bg = palette.yellow_soft, bold = true })
set("@comment.error", { fg = palette.red, bg = palette.red_soft, bold = true })

set("@markup.heading", { fg = palette.blue_deep, bold = true })
set("@markup.raw", { fg = palette.green })
set("@markup.link", { fg = palette.blue, underline = true })
set("@markup.link.url", { fg = palette.blue, underline = true })
set("@markup.list", { fg = palette.pink })
set("@markup.quote", { fg = palette.fg_muted, italic = true })

-- ── BufferLine ───────────────────────────────────────────────────────

local bl = {
  sel_fg = palette.fg,
  sel_bg = palette.bg,
  vis_fg = palette.fg_dim,
  vis_bg = palette.bg_panel,
  buf_fg = palette.fg_muted,
  buf_bg = palette.bg_subtle,
  fill = palette.bg_subtle,
  sep = palette.border_soft,
  ind = palette.blue,
  mod = palette.orange,
  pick = palette.pink,
}

set("BufferLineFill", { bg = bl.fill })
set("BufferLineBackground", { fg = bl.buf_fg, bg = bl.buf_bg })
set("BufferLineBuffer", { fg = bl.buf_fg, bg = bl.buf_bg })
set("BufferLineBufferSelected", { fg = bl.sel_fg, bg = bl.sel_bg, bold = true })
set("BufferLineIndicatorSelected", { fg = bl.ind, bg = bl.sel_bg })
set("BufferLineBufferVisible", { fg = bl.vis_fg, bg = bl.vis_bg })
set("BufferLineIndicatorVisible", { fg = bl.vis_fg, bg = bl.vis_bg })
set("BufferLineSeparator", { fg = bl.sep, bg = bl.buf_bg })
set("BufferLineSeparatorSelected", { fg = bl.sep, bg = bl.sel_bg })
set("BufferLineSeparatorVisible", { fg = bl.sep, bg = bl.vis_bg })
set("BufferLineCloseButton", { fg = bl.buf_fg, bg = bl.buf_bg })
set("BufferLineCloseButtonSelected", { fg = palette.red, bg = bl.sel_bg })
set("BufferLineCloseButtonVisible", { fg = bl.vis_fg, bg = bl.vis_bg })
set("BufferLineModified", { fg = bl.mod, bg = bl.buf_bg })
set("BufferLineModifiedSelected", { fg = bl.mod, bg = bl.sel_bg })
set("BufferLineModifiedVisible", { fg = bl.mod, bg = bl.vis_bg })
set("BufferLineDuplicate", { fg = bl.buf_fg, bg = bl.buf_bg, italic = true })
set("BufferLineDuplicateSelected", { fg = bl.sel_fg, bg = bl.sel_bg, italic = true })
set("BufferLineDuplicateVisible", { fg = bl.vis_fg, bg = bl.vis_bg, italic = true })
set("BufferLineNumbers", { fg = bl.buf_fg, bg = bl.buf_bg })
set("BufferLineNumbersSelected", { fg = bl.ind, bg = bl.sel_bg, bold = true })
set("BufferLineNumbersVisible", { fg = bl.vis_fg, bg = bl.vis_bg })
set("BufferLineError", { fg = palette.red, bg = bl.buf_bg })
set("BufferLineErrorSelected", { fg = palette.red, bg = bl.sel_bg })
set("BufferLineErrorVisible", { fg = palette.red, bg = bl.vis_bg })
set("BufferLineWarning", { fg = palette.orange, bg = bl.buf_bg })
set("BufferLineWarningSelected", { fg = palette.orange, bg = bl.sel_bg })
set("BufferLineWarningVisible", { fg = palette.orange, bg = bl.vis_bg })
set("BufferLineHint", { fg = palette.teal, bg = bl.buf_bg })
set("BufferLineHintSelected", { fg = palette.teal, bg = bl.sel_bg })
set("BufferLineHintVisible", { fg = palette.teal, bg = bl.vis_bg })
set("BufferLineInfo", { fg = palette.blue, bg = bl.buf_bg })
set("BufferLineInfoSelected", { fg = palette.blue, bg = bl.sel_bg })
set("BufferLineInfoVisible", { fg = palette.blue, bg = bl.vis_bg })
set("BufferLinePick", { fg = bl.pick, bg = bl.buf_bg, bold = true })
set("BufferLinePickSelected", { fg = bl.pick, bg = bl.sel_bg, bold = true })
set("BufferLinePickVisible", { fg = bl.pick, bg = bl.vis_bg, bold = true })
set("BufferLineTab", { fg = bl.buf_fg, bg = bl.buf_bg })
set("BufferLineTabSelected", { fg = bl.sel_fg, bg = bl.sel_bg, bold = true })
set("BufferLineTabSeparator", { fg = bl.sep, bg = bl.buf_bg })
set("BufferLineTabSeparatorSelected", { fg = bl.sep, bg = bl.sel_bg })
set("BufferLineTabClose", { fg = palette.red, bg = bl.buf_bg })
set("BufferLineGroupLabel", { fg = palette.white, bg = bl.ind, bold = true })
set("BufferLineGroupSeparator", { fg = bl.sep, bg = bl.fill })
set("BufferLineOffsetSeparator", { fg = bl.sep, bg = bl.fill })
set("BufferLineTruncMarker", { fg = bl.buf_fg, bg = bl.fill })

-- ── Common plugin surfaces ───────────────────────────────────────────

set("TelescopeNormal", { fg = palette.fg, bg = palette.bg_panel })
set("TelescopeBorder", { fg = palette.border, bg = palette.bg_panel })
set("TelescopePromptNormal", { fg = palette.fg, bg = palette.bg })
set("TelescopePromptBorder", { fg = palette.border, bg = palette.bg })
set("TelescopePromptTitle", { fg = palette.white, bg = palette.blue, bold = true })
set("TelescopeResultsTitle", { fg = palette.fg, bg = palette.bg_panel })
set("TelescopePreviewTitle", { fg = palette.white, bg = palette.green, bold = true })
set("TelescopeSelection", { bg = "#DCEBFF", bold = true })
set("TelescopeMatching", { fg = palette.pink, bold = true })

set("SnacksPicker", { fg = palette.fg, bg = palette.bg_panel })
set("SnacksPickerBorder", { fg = palette.border, bg = palette.bg_panel })
set("SnacksPickerInput", { fg = palette.fg, bg = palette.bg })
set("SnacksPickerInputBorder", { fg = palette.border, bg = palette.bg })
set("SnacksPickerSelection", { bg = "#DCEBFF", bold = true })
set("SnacksPickerMatch", { fg = palette.pink, bold = true })
set("SnacksPickerDir", { fg = palette.fg_muted })
set("SnacksPickerFile", { fg = palette.fg })

set("WhichKey", { fg = palette.blue_deep })
set("WhichKeyGroup", { fg = palette.purple })
set("WhichKeyDesc", { fg = palette.fg })
set("WhichKeySeparator", { fg = palette.fg_muted })
set("WhichKeyFloat", { bg = palette.bg_panel })

set("CmpItemAbbr", { fg = palette.fg })
set("CmpItemAbbrMatch", { fg = palette.blue_deep, bold = true })
set("CmpItemAbbrMatchFuzzy", { fg = palette.blue_deep })
set("CmpItemKindFunction", { fg = palette.blue_deep })
set("CmpItemKindMethod", { fg = palette.blue_deep })
set("CmpItemKindKeyword", { fg = palette.pink })
set("CmpItemKindVariable", { fg = palette.fg })
set("CmpItemKindClass", { fg = palette.cyan })
set("CmpItemKindStruct", { fg = palette.cyan })
set("CmpItemKindInterface", { fg = palette.cyan })
set("CmpItemKindField", { fg = palette.fg })
set("CmpItemKindProperty", { fg = palette.fg })
set("CmpItemKindEnumMember", { fg = palette.purple })
set("CmpItemKindConstant", { fg = palette.purple })
set("CmpItemKindEnum", { fg = palette.cyan })
set("CmpItemKindText", { fg = palette.green })

set("IndentBlanklineChar", { fg = palette.border_soft })
set("IndentBlanklineContextChar", { fg = palette.fg_faint })
set("IblIndent", { fg = palette.border_soft })
set("IblScope", { fg = palette.fg_faint })

-- ── Filetype depth ──────────────────────────────────────────────────

set("@markup.heading.1.markdown", { fg = palette.blue_deep, bold = true })
set("@markup.heading.2.markdown", { fg = palette.purple, bold = true })
set("@markup.heading.3.markdown", { fg = palette.cyan, bold = true })
set("@markup.raw.block.markdown", { fg = palette.green, bg = palette.bg_panel })
set("@markup.link.url.markdown_inline", { fg = palette.blue, underline = true })
set("@markup.quote.markdown", { fg = palette.fg_muted, italic = true })

set("@tag", { fg = palette.blue_deep })
set("@tag.attribute", { fg = palette.purple })
set("@tag.delimiter", { fg = palette.fg_muted })
set("@property.json", { fg = palette.blue_deep })
set("@property.yaml", { fg = palette.blue_deep })
set("@property.toml", { fg = palette.blue_deep })
set("@variable.member.lua", { fg = palette.fg })
set("@property.lua", { fg = palette.fg })
set("@function.builtin.lua", { fg = palette.purple, bold = true })
set("@variable.builtin.python", { fg = palette.pink, bold = true })
set("@attribute.python", { fg = palette.orange })
set("@variable.builtin.javascript", { fg = palette.pink, bold = true })
set("@variable.builtin.typescript", { fg = palette.pink, bold = true })
set("@lsp.type.concept.cpp", { fg = palette.teal, italic = true })
set("@constructor.cpp", { fg = palette.cyan })
set("@lsp.mod.deprecated", { strikethrough = true })
set("@lsp.mod.readonly", { italic = true })
set("@lsp.mod.defaultLibrary", { fg = palette.purple, bold = true })

-- ── Terminal colours ────────────────────────────────────────────────

vim.g.terminal_color_0 = palette.black
vim.g.terminal_color_1 = palette.red
vim.g.terminal_color_2 = palette.green
vim.g.terminal_color_3 = palette.yellow
vim.g.terminal_color_4 = palette.blue_deep
vim.g.terminal_color_5 = palette.purple
vim.g.terminal_color_6 = palette.teal
vim.g.terminal_color_7 = palette.fg_muted
vim.g.terminal_color_8 = palette.fg_dim
vim.g.terminal_color_9 = "#A40E26"
vim.g.terminal_color_10 = "#0A7F2E"
vim.g.terminal_color_11 = "#B88600"
vim.g.terminal_color_12 = palette.blue
vim.g.terminal_color_13 = "#A371F7"
vim.g.terminal_color_14 = "#159AA2"
vim.g.terminal_color_15 = palette.white
