vim.cmd("highlight clear")

if vim.fn.exists("syntax_on") == 1 then
  vim.cmd("syntax reset")
end

vim.o.background = "dark"
vim.o.termguicolors = true
vim.g.colors_name = "ubuntu-terminal"

-- ── Palette ──────────────────────────────────────────────────────────
-- Background family preserved (ubuntu aubergine).
-- Syntax colours: classic Monokai mapping.
--
--   Pink    #F92672 → keywords, control flow, storage class, operators
--   Green   #A6E22E → function names, definitions
--   Blue    #66D9EF → types (italic for built-in)
--   Yellow  #E6DB74 → strings
--   Purple  #AE81FF → numbers, constants, booleans
--   Orange  #FD971F → parameters, decorators, attributes (italic)
--   Grey    #75715E → comments
--   White   #F8F8F2 → plain identifiers, text
local palette = {
  -- backgrounds (unchanged)
  bg = "#300A24",
  bg_dark = "#24081C",
  bg_alt = "#3B102F",
  bg_visual = "#5E2750",
  bg_search = "#E95420",
  bg_incsearch = "#C4A000",

  -- foregrounds — Monokai white
  fg = "#F8F8F2",
  fg_dim = "#C0B8BC",
  fg_comment = "#8F7A86",

  -- Monokai core 7
  pink = "#F92672",
  green = "#A6E22E",
  blue = "#66D9EF",
  yellow = "#E6DB74",
  purple = "#AE81FF",
  orange = "#FD971F",
  comment = "#75715E",

  -- ui accents (keep ubuntu flavour)
  ui_orange = "#E95420",
  violet = "#77216F",
  black = "#2E3436",
  red = "#F92672",
  ui_green = "#8AE234",
  ui_yellow = "#FCE94F",
  ui_blue = "#729FCF",
  magenta = "#AD7FA8",
  cyan = "#34E2E2",
  white = "#D3D7CF",

  -- diagnostics
  error_bg = "#4A1114",
  warn_bg = "#4D3A0D",
  info_bg = "#173552",
  hint_bg = "#103C3F",

  -- diff
  diff_add = "#173218",
  diff_change = "#16273B",
  diff_delete = "#3D1212",
  diff_text = "#5B3110",
}

local function set(group, spec)
  vim.api.nvim_set_hl(0, group, spec)
end

local function link(group, target)
  set(group, { link = target })
end

-- ── Editor chrome ────────────────────────────────────────────────────

set("Normal", { fg = palette.fg, bg = palette.bg })
set("NormalNC", { fg = palette.fg_dim, bg = palette.bg })
set("NormalFloat", { fg = palette.fg, bg = palette.bg_dark })
set("FloatBorder", { fg = palette.ui_orange, bg = palette.bg_dark })
set("FloatTitle", { fg = palette.ui_orange, bg = palette.bg_dark, bold = true })
set("ColorColumn", { bg = palette.bg_alt })
set("CursorColumn", { bg = palette.bg_alt })
set("CursorLine", { bg = palette.bg_alt })
set("CursorLineNr", { fg = palette.ui_orange, bg = palette.bg_alt, bold = true })
set("CursorLineFold", { fg = palette.ui_orange, bg = palette.bg_alt })
set("CursorLineSign", { bg = palette.bg_alt })
set("LineNr", { fg = palette.fg_comment, bg = palette.bg })
set("SignColumn", { bg = palette.bg })
set("VertSplit", { fg = palette.violet, bg = palette.bg })
link("WinSeparator", "VertSplit")
set("StatusLine", { fg = palette.bg, bg = palette.ui_orange, bold = true })
set("StatusLineNC", { fg = palette.fg_dim, bg = palette.bg_alt })
set("TabLine", { fg = palette.fg_dim, bg = palette.bg_alt })
set("TabLineFill", { bg = palette.bg_dark })
set("TabLineSel", { fg = palette.bg, bg = palette.ui_orange, bold = true })
set("Pmenu", { fg = palette.fg, bg = palette.bg_dark })
set("PmenuSel", { fg = palette.bg, bg = palette.ui_orange, bold = true })
set("PmenuSbar", { bg = palette.bg_alt })
set("PmenuThumb", { bg = palette.violet })
set("Visual", { bg = palette.bg_visual })
set("VisualNOS", { bg = palette.bg_visual })
set("Search", { fg = palette.bg, bg = palette.bg_search, bold = true })
set("IncSearch", { fg = palette.bg, bg = palette.bg_incsearch, bold = true })
set("CurSearch", { fg = palette.bg, bg = palette.bg_incsearch, bold = true })
set("MatchParen", { fg = palette.ui_yellow, bg = palette.bg_visual, bold = true })
set("Folded", { fg = palette.fg_dim, bg = palette.bg_alt, italic = true })
set("FoldColumn", { fg = palette.fg_comment, bg = palette.bg })
set("Conceal", { fg = palette.fg_comment, bg = palette.bg })
set("NonText", { fg = palette.fg_comment })
set("Whitespace", { bg = palette.bg_alt })
set("SpecialKey", { fg = palette.fg_comment })
set("Directory", { fg = palette.blue, bold = true })
set("Title", { fg = palette.ui_orange, bold = true })
set("Question", { fg = palette.green, bold = true })
set("MoreMsg", { fg = palette.green, bold = true })
set("WarningMsg", { fg = palette.ui_orange, bold = true })
set("ErrorMsg", { fg = palette.pink, bold = true })
set("ModeMsg", { fg = palette.ui_orange, bold = true })

-- ── Syntax groups (Monokai mapping) ──────────────────────────────────
--   pink   → keyword, control flow, storage, operator
--   green  → function
--   blue   → type (italic for builtin)
--   yellow → string
--   purple → number, constant, boolean
--   orange → parameter, decorator (italic)
--   grey   → comment

set("Comment", { fg = palette.comment, italic = true })
set("Constant", { fg = palette.purple })
set("String", { fg = palette.yellow })
set("Character", { fg = palette.yellow })
set("Number", { fg = palette.purple })
set("Boolean", { fg = palette.purple })
set("Float", { fg = palette.purple })
set("Identifier", { fg = palette.fg })
set("Function", { fg = palette.green })
set("Statement", { fg = palette.pink })
set("Conditional", { fg = palette.pink })
set("Repeat", { fg = palette.pink })
set("Label", { fg = palette.pink })
set("Operator", { fg = palette.pink })
set("Keyword", { fg = palette.pink })
set("Exception", { fg = palette.pink })
set("PreProc", { fg = palette.pink })
set("Include", { fg = palette.pink })
set("Define", { fg = palette.pink })
set("Macro", { fg = palette.blue, italic = true })
set("PreCondit", { fg = palette.pink })
set("Type", { fg = palette.blue, italic = true })
set("StorageClass", { fg = palette.pink, italic = true })
set("Structure", { fg = palette.blue, italic = true })
set("Typedef", { fg = palette.blue, italic = true })
set("Special", { fg = palette.purple })
set("SpecialChar", { fg = palette.purple })
set("Tag", { fg = palette.pink })
set("Delimiter", { fg = palette.fg })
set("SpecialComment", { fg = palette.comment, italic = true })
set("Debug", { fg = palette.pink })
set("Underlined", { fg = palette.green, underline = true })
set("Ignore", { fg = palette.fg_comment })
set("Error", { fg = palette.pink, bg = palette.error_bg, bold = true })
set("Todo", { fg = palette.bg, bg = palette.ui_yellow, bold = true })

-- ── Diagnostics ──────────────────────────────────────────────────────

set("DiagnosticError", { fg = palette.pink })
set("DiagnosticWarn", { fg = palette.orange })
set("DiagnosticInfo", { fg = palette.blue })
set("DiagnosticHint", { fg = palette.cyan })
set("DiagnosticOk", { fg = palette.green })
set("DiagnosticVirtualTextError", { fg = palette.pink, bg = palette.error_bg })
set("DiagnosticVirtualTextWarn", { fg = palette.orange, bg = palette.warn_bg })
set("DiagnosticVirtualTextInfo", { fg = palette.blue, bg = palette.info_bg })
set("DiagnosticVirtualTextHint", { fg = palette.cyan, bg = palette.hint_bg })
set("DiagnosticUnderlineError", { undercurl = true, sp = palette.pink })
set("DiagnosticUnderlineWarn", { undercurl = true, sp = palette.orange })
set("DiagnosticUnderlineInfo", { undercurl = true, sp = palette.blue })
set("DiagnosticUnderlineHint", { undercurl = true, sp = palette.cyan })

-- ── Diff ─────────────────────────────────────────────────────────────

set("DiffAdd", { bg = palette.diff_add })
set("DiffChange", { bg = palette.diff_change })
set("DiffDelete", { bg = palette.diff_delete })
set("DiffText", { bg = palette.diff_text, bold = true })
set("Added", { fg = palette.green })
set("Changed", { fg = palette.blue })
set("Removed", { fg = palette.pink })

-- ── Git signs ────────────────────────────────────────────────────────

set("GitSignsAdd", { fg = palette.green, bg = palette.bg })
set("GitSignsChange", { fg = palette.blue, bg = palette.bg })
set("GitSignsDelete", { fg = palette.pink, bg = palette.bg })

-- ── Misc ─────────────────────────────────────────────────────────────

set("QuickFixLine", { bg = palette.bg_alt, bold = true })
set("LspReferenceText", { bg = palette.bg_alt })
set("LspReferenceRead", { bg = palette.bg_alt })
set("LspReferenceWrite", { bg = palette.bg_visual })

-- ── Treesitter / LSP semantic tokens (Monokai) ──────────────────────
-- Monokai assigns roles by semantic meaning, not by syntax category.
-- Treesitter + clangd semantic tokens give us fine-grained C++ control.

-- keywords & control flow → pink
set("@keyword", { fg = palette.pink })
set("@keyword.function", { fg = palette.pink })
set("@keyword.return", { fg = palette.pink })
set("@keyword.operator", { fg = palette.pink })
set("@keyword.modifier", { fg = palette.pink, italic = true })
set("@keyword.import", { fg = palette.pink })
set("@conditional", { fg = palette.pink })
set("@repeat", { fg = palette.pink })
set("@exception", { fg = palette.pink })
set("@label", { fg = palette.pink })

-- types → blue italic (Monokai Pro style)
set("@type", { fg = palette.blue, italic = true })
set("@type.builtin", { fg = palette.blue, italic = true })
set("@type.definition", { fg = palette.green })         -- the name being defined is green (like a function decl)
set("@type.qualifier", { fg = palette.pink, italic = true })  -- const, volatile → pink
set("@lsp.type.type", { fg = palette.blue, italic = true })
set("@lsp.type.type.cpp", { fg = palette.blue, italic = true })
set("@lsp.type.class", { fg = palette.blue, italic = true })
set("@lsp.type.class.cpp", { fg = palette.blue, italic = true })
set("@lsp.type.struct", { fg = palette.blue, italic = true })
set("@lsp.type.struct.cpp", { fg = palette.blue, italic = true })
set("@lsp.type.enum", { fg = palette.blue, italic = true })
set("@lsp.type.enum.cpp", { fg = palette.blue, italic = true })
set("@lsp.type.interface", { fg = palette.blue, italic = true })
set("@lsp.type.typeParameter", { fg = palette.blue, italic = true })
set("@lsp.type.typeParameter.cpp", { fg = palette.blue, italic = true })

-- functions & methods → green
set("@function", { fg = palette.green })
set("@function.call", { fg = palette.green })
set("@function.method", { fg = palette.green })
set("@function.method.call", { fg = palette.green })
set("@function.builtin", { fg = palette.blue })  -- built-in functions closer to type
set("@constructor", { fg = palette.green })
set("@lsp.type.function", { fg = palette.green })
set("@lsp.type.function.cpp", { fg = palette.green })
set("@lsp.type.method", { fg = palette.green })
set("@lsp.type.method.cpp", { fg = palette.green })

-- namespaces → blue italic (they are type-like)
set("@module", { fg = palette.blue, italic = true })
set("@lsp.type.namespace", { fg = palette.blue, italic = true })
set("@lsp.type.namespace.cpp", { fg = palette.blue, italic = true })

-- fields & properties → plain white (Monokai doesn't colour these)
set("@field", { fg = palette.fg })
set("@property", { fg = palette.fg })
set("@variable.member", { fg = palette.fg })
set("@lsp.type.property", { fg = palette.fg })
set("@lsp.type.property.cpp", { fg = palette.fg })

-- parameters → orange italic (Monokai signature)
set("@parameter", { fg = palette.orange, italic = true })
set("@lsp.type.parameter", { fg = palette.orange, italic = true })
set("@lsp.type.parameter.cpp", { fg = palette.orange, italic = true })

-- variables → white
set("@variable", { fg = palette.fg })
set("@variable.builtin", { fg = palette.orange, italic = true })  -- this, self → orange italic
set("@lsp.type.variable", { fg = palette.fg })
set("@lsp.type.variable.cpp", { fg = palette.fg })

-- constants & enum members → purple
set("@constant", { fg = palette.purple })
set("@constant.builtin", { fg = palette.purple })
set("@lsp.type.enumMember", { fg = palette.purple })
set("@lsp.type.enumMember.cpp", { fg = palette.purple })

-- macros → blue italic (they expand to types/values, distinct from preprocessor)
set("@constant.macro", { fg = palette.blue, italic = true })
set("@lsp.type.macro", { fg = palette.blue, italic = true })
set("@lsp.type.macro.cpp", { fg = palette.blue, italic = true })
set("@attribute", { fg = palette.green })
set("@attribute.cpp", { fg = palette.green })
set("@preproc", { fg = palette.pink })

-- strings & literals
set("@string", { fg = palette.yellow })
set("@string.escape", { fg = palette.purple })    -- \n, \t → purple like numbers
set("@string.special", { fg = palette.purple })
set("@character", { fg = palette.yellow })
set("@number", { fg = palette.purple })
set("@number.float", { fg = palette.purple })
set("@boolean", { fg = palette.purple })

-- operators & punctuation → pink / white
set("@operator", { fg = palette.pink })
set("@punctuation.bracket", { fg = palette.fg })
set("@punctuation.delimiter", { fg = palette.fg })
set("@punctuation.special", { fg = palette.pink })

-- comments → grey italic
set("@comment", { fg = palette.comment, italic = true })
set("@comment.documentation", { fg = palette.comment, italic = true })
set("@comment.note", { fg = palette.comment, italic = true })
set("@comment.todo", { fg = palette.bg, bg = palette.ui_yellow, bold = true })
set("@comment.warning", { fg = palette.bg, bg = palette.orange, bold = true })
set("@comment.error", { fg = palette.bg, bg = palette.pink, bold = true })

-- ── BufferLine ────────────────────────────────────────────────────────
-- Three states: selected (current), visible (shown but not focused),
-- and background (hidden buffers in the tab bar).

local bl = {
  sel_fg = palette.fg,
  sel_bg = "#4A1A3D",          -- lifted aubergine — distinct from editor bg
  vis_fg = palette.fg_dim,
  vis_bg = palette.bg_alt,
  buf_fg = palette.fg_comment,
  buf_bg = palette.bg_dark,
  fill = palette.bg_dark,
  sep = palette.violet,
  ind = palette.ui_orange,        -- indicator accent
  mod = palette.yellow,            -- modified dot (gold)
  pick = palette.pink,
}

-- fill / background strip
set("BufferLineFill", { bg = bl.fill })
set("BufferLineBackground", { fg = bl.buf_fg, bg = bl.buf_bg })
set("BufferLineBuffer", { fg = bl.buf_fg, bg = bl.buf_bg })

-- selected (active buffer)
set("BufferLineBufferSelected", { fg = bl.sel_fg, bg = bl.sel_bg, bold = true })
set("BufferLineIndicatorSelected", { fg = bl.ind, bg = bl.sel_bg })

-- visible (in a split but not focused)
set("BufferLineBufferVisible", { fg = bl.vis_fg, bg = bl.vis_bg })
set("BufferLineIndicatorVisible", { fg = bl.vis_fg, bg = bl.vis_bg })

-- separators
set("BufferLineSeparator", { fg = bl.sep, bg = bl.buf_bg })
set("BufferLineSeparatorSelected", { fg = bl.sep, bg = bl.sel_bg })
set("BufferLineSeparatorVisible", { fg = bl.sep, bg = bl.vis_bg })

-- close buttons
set("BufferLineCloseButton", { fg = bl.buf_fg, bg = bl.buf_bg })
set("BufferLineCloseButtonSelected", { fg = palette.pink, bg = bl.sel_bg })
set("BufferLineCloseButtonVisible", { fg = bl.vis_fg, bg = bl.vis_bg })

-- modified indicator
set("BufferLineModified", { fg = bl.mod, bg = bl.buf_bg })
set("BufferLineModifiedSelected", { fg = bl.mod, bg = bl.sel_bg })
set("BufferLineModifiedVisible", { fg = bl.mod, bg = bl.vis_bg })

-- duplicate name disambiguation
set("BufferLineDuplicate", { fg = bl.buf_fg, bg = bl.buf_bg, italic = true })
set("BufferLineDuplicateSelected", { fg = bl.sel_fg, bg = bl.sel_bg, italic = true })
set("BufferLineDuplicateVisible", { fg = bl.vis_fg, bg = bl.vis_bg, italic = true })

-- numbers
set("BufferLineNumbers", { fg = bl.buf_fg, bg = bl.buf_bg })
set("BufferLineNumbersSelected", { fg = bl.ind, bg = bl.sel_bg, bold = true })
set("BufferLineNumbersVisible", { fg = bl.vis_fg, bg = bl.vis_bg })

-- diagnostics in tab
set("BufferLineDiagnostic", { fg = bl.buf_fg, bg = bl.buf_bg })
set("BufferLineDiagnosticSelected", { fg = palette.blue, bg = bl.sel_bg })
set("BufferLineDiagnosticVisible", { fg = bl.vis_fg, bg = bl.vis_bg })
set("BufferLineError", { fg = palette.pink, bg = bl.buf_bg })
set("BufferLineErrorSelected", { fg = palette.pink, bg = bl.sel_bg })
set("BufferLineErrorVisible", { fg = palette.pink, bg = bl.vis_bg })
set("BufferLineErrorDiagnostic", { fg = palette.pink, bg = bl.buf_bg })
set("BufferLineErrorDiagnosticSelected", { fg = palette.pink, bg = bl.sel_bg })
set("BufferLineErrorDiagnosticVisible", { fg = palette.pink, bg = bl.vis_bg })
set("BufferLineWarning", { fg = palette.orange, bg = bl.buf_bg })
set("BufferLineWarningSelected", { fg = palette.orange, bg = bl.sel_bg })
set("BufferLineWarningVisible", { fg = palette.orange, bg = bl.vis_bg })
set("BufferLineHint", { fg = palette.blue, bg = bl.buf_bg })
set("BufferLineHintSelected", { fg = palette.blue, bg = bl.sel_bg })
set("BufferLineHintVisible", { fg = palette.blue, bg = bl.vis_bg })
set("BufferLineInfo", { fg = palette.blue, bg = bl.buf_bg })
set("BufferLineInfoSelected", { fg = palette.blue, bg = bl.sel_bg })
set("BufferLineInfoVisible", { fg = palette.blue, bg = bl.vis_bg })

-- pick letter
set("BufferLinePick", { fg = bl.pick, bg = bl.buf_bg, bold = true })
set("BufferLinePickSelected", { fg = bl.pick, bg = bl.sel_bg, bold = true })
set("BufferLinePickVisible", { fg = bl.pick, bg = bl.vis_bg, bold = true })

-- tab pages (right side)
set("BufferLineTab", { fg = bl.buf_fg, bg = bl.buf_bg })
set("BufferLineTabSelected", { fg = bl.sel_fg, bg = bl.sel_bg, bold = true })
set("BufferLineTabSeparator", { fg = bl.sep, bg = bl.buf_bg })
set("BufferLineTabSeparatorSelected", { fg = bl.sep, bg = bl.sel_bg })
set("BufferLineTabClose", { fg = palette.pink, bg = bl.buf_bg })

-- group / offset / trunc
set("BufferLineGroupLabel", { fg = bl.sel_fg, bg = bl.ind, bold = true })
set("BufferLineGroupSeparator", { fg = bl.sep, bg = bl.fill })
set("BufferLineOffsetSeparator", { fg = bl.sep, bg = bl.fill })
set("BufferLineTruncMarker", { fg = bl.buf_fg, bg = bl.fill })

-- ── Terminal colours ─────────────────────────────────────────────────

vim.g.terminal_color_0 = palette.black
vim.g.terminal_color_1 = "#CC0000"
vim.g.terminal_color_2 = "#4E9A06"
vim.g.terminal_color_3 = "#C4A000"
vim.g.terminal_color_4 = "#3465A4"
vim.g.terminal_color_5 = "#75507B"
vim.g.terminal_color_6 = "#06989A"
vim.g.terminal_color_7 = palette.white
vim.g.terminal_color_8 = "#555753"
vim.g.terminal_color_9 = palette.pink
vim.g.terminal_color_10 = palette.green
vim.g.terminal_color_11 = palette.yellow
vim.g.terminal_color_12 = palette.blue
vim.g.terminal_color_13 = palette.purple
vim.g.terminal_color_14 = palette.cyan
vim.g.terminal_color_15 = palette.fg
