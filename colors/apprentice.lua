-- Apprentice — synced from the active Warp terminal theme.
-- Source palette: ~/AppData/Roaming/warp/Warp/data/themes/apprentice.yaml
-- (Apprentice, a dark low-contrast theme by Romain Lafourcade —
--  https://github.com/romainl/Apprentice). Ported to a full Neovim
--  colorscheme: editor chrome + syntax + treesitter/LSP + diagnostics +
--  diff + gitsigns + bufferline + terminal, matching the conventions of
--  colors/ubuntu-terminal.lua.

vim.cmd("highlight clear")

if vim.fn.exists("syntax_on") == 1 then
  vim.cmd("syntax reset")
end

vim.o.background = "dark"
vim.o.termguicolors = true
vim.g.colors_name = "apprentice"

-- ── Palette ──────────────────────────────────────────────────────────
-- The 8 normal + 8 bright terminal colours from apprentice.yaml, plus a
-- few derived UI tones (lifted/darkened backgrounds, low-saturation diff
-- and diagnostic washes) consistent with Apprentice's low-contrast intent.
local palette = {
  -- backgrounds
  bg          = "#262626",  -- Warp background
  bg_dark     = "#1c1c1c",  -- normal black — floats / fill
  bg_alt      = "#303030",  -- cursorline / columns (one step up)
  bg_visual   = "#444444",  -- bright black — visual selection
  bg_search   = "#5f87af",  -- normal blue — search
  bg_incsearch= "#ff8700",  -- bright red(orange) — incsearch accent

  -- foregrounds
  fg          = "#bcbcbc",  -- Warp foreground / cursor
  fg_dim      = "#9e9e9e",
  fg_comment  = "#6c6c6c",  -- normal white — comments / line nr

  -- accent family (Apprentice is cyan-accented, low-contrast)
  cyan        = "#5fafaf",  -- accent (bright cyan == normal cyan family)
  blue        = "#8fafd7",  -- bright blue
  blue_dim    = "#5f87af",  -- normal blue
  green       = "#87af87",  -- bright green
  green_dim   = "#5f875f",  -- normal green
  yellow      = "#ffffaf",  -- bright yellow
  yellow_dim  = "#87875f",  -- normal yellow
  orange      = "#ff8700",  -- bright red (Apprentice uses warm orange for red-bright)
  red         = "#af5f5f",  -- normal red
  magenta     = "#8787af",  -- bright magenta
  magenta_dim = "#5f5f87",  -- normal magenta
  white       = "#ffffff",  -- bright white
  black       = "#1c1c1c",  -- normal black
  grey        = "#444444",  -- bright black

  -- diagnostics (low-sat washes)
  error_bg = "#3a2222",
  warn_bg  = "#3a3322",
  info_bg  = "#22303a",
  hint_bg  = "#223a3a",

  -- diff
  diff_add    = "#22301f",
  diff_change = "#1f2a33",
  diff_delete = "#331f1f",
  diff_text   = "#2a3322",
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
set("FloatBorder", { fg = palette.cyan, bg = palette.bg_dark })
set("FloatTitle", { fg = palette.cyan, bg = palette.bg_dark, bold = true })
set("ColorColumn", { bg = palette.bg_alt })
set("CursorColumn", { bg = palette.bg_alt })
set("CursorLine", { bg = palette.bg_alt })
set("CursorLineNr", { fg = palette.cyan, bg = palette.bg_alt, bold = true })
set("CursorLineFold", { fg = palette.cyan, bg = palette.bg_alt })
set("CursorLineSign", { bg = palette.bg_alt })
set("LineNr", { fg = palette.fg_comment, bg = palette.bg })
set("SignColumn", { bg = palette.bg })
set("VertSplit", { fg = palette.grey, bg = palette.bg })
link("WinSeparator", "VertSplit")
set("StatusLine", { fg = palette.bg_dark, bg = palette.cyan, bold = true })
set("StatusLineNC", { fg = palette.fg_dim, bg = palette.bg_alt })
set("TabLine", { fg = palette.fg_dim, bg = palette.bg_alt })
set("TabLineFill", { bg = palette.bg_dark })
set("TabLineSel", { fg = palette.bg_dark, bg = palette.cyan, bold = true })
set("Pmenu", { fg = palette.fg, bg = palette.bg_dark })
set("PmenuSel", { fg = palette.bg_dark, bg = palette.cyan, bold = true })
set("PmenuSbar", { bg = palette.bg_alt })
set("PmenuThumb", { bg = palette.grey })
set("Visual", { bg = palette.bg_visual })
set("VisualNOS", { bg = palette.bg_visual })
set("Search", { fg = palette.white, bg = palette.bg_search, bold = true })
set("IncSearch", { fg = palette.bg_dark, bg = palette.bg_incsearch, bold = true })
set("CurSearch", { fg = palette.bg_dark, bg = palette.bg_incsearch, bold = true })
set("MatchParen", { fg = palette.yellow, bg = palette.bg_visual, bold = true })
set("Folded", { fg = palette.fg_dim, bg = palette.bg_alt, italic = true })
set("FoldColumn", { fg = palette.fg_comment, bg = palette.bg })
set("Conceal", { fg = palette.fg_comment, bg = palette.bg })
set("NonText", { fg = palette.fg_comment })
set("Whitespace", { fg = palette.grey })
set("SpecialKey", { fg = palette.fg_comment })
set("Directory", { fg = palette.blue, bold = true })
set("Title", { fg = palette.cyan, bold = true })
set("Question", { fg = palette.green, bold = true })
set("MoreMsg", { fg = palette.green, bold = true })
set("WarningMsg", { fg = palette.orange, bold = true })
set("ErrorMsg", { fg = palette.red, bold = true })
set("ModeMsg", { fg = palette.cyan, bold = true })

-- ── Syntax groups (verbatim from romainl/Apprentice colors/apprentice.vim) ──
--   Constant   #ff8700  orange
--   String     #87af87  green
--   Identifier #5f87af  blue
--   Function   #ffffaf  pale yellow
--   Statement  #87afd7  light blue   (Keyword/Conditional link here)
--   PreProc    #5f8787  dim cyan
--   Type       #8787af  muted purple
--   Special    #5f875f  dim green
--   Comment    #6c6c6c  grey
-- Apprentice is deliberately low-contrast; these are the author's choices,
-- not a re-mapping. Extra colours below reuse the same palette tones.

local apr = {
  c_const   = "#ff8700",  -- Constant
  c_string  = "#87af87",  -- String
  c_ident   = "#5f87af",  -- Identifier
  c_func    = "#ffffaf",  -- Function
  c_stmt    = "#87afd7",  -- Statement / Keyword
  c_preproc = "#5f8787",  -- PreProc
  c_type    = "#8787af",  -- Type
  c_special = "#5f875f",  -- Special
}

set("Comment", { fg = palette.fg_comment, italic = true })
set("Constant", { fg = apr.c_const })
set("String", { fg = apr.c_string })
set("Character", { fg = apr.c_string })
set("Number", { fg = apr.c_const })
set("Boolean", { fg = apr.c_const })
set("Float", { fg = apr.c_const })
set("Identifier", { fg = apr.c_ident })
set("Function", { fg = apr.c_func })
set("Statement", { fg = apr.c_stmt })
set("Conditional", { fg = apr.c_stmt })
set("Repeat", { fg = apr.c_stmt })
set("Label", { fg = apr.c_stmt })
set("Operator", { fg = palette.fg })
set("Keyword", { fg = apr.c_stmt })
set("Exception", { fg = apr.c_stmt })
set("PreProc", { fg = apr.c_preproc })
set("Include", { fg = apr.c_preproc })
set("Define", { fg = apr.c_preproc })
set("Macro", { fg = apr.c_preproc })
set("PreCondit", { fg = apr.c_preproc })
set("Type", { fg = apr.c_type })
set("StorageClass", { fg = apr.c_type })
set("Structure", { fg = apr.c_type })
set("Typedef", { fg = apr.c_type })
set("Special", { fg = apr.c_special })
set("SpecialChar", { fg = apr.c_special })
set("Tag", { fg = apr.c_stmt })
set("Delimiter", { fg = palette.fg })
set("SpecialComment", { fg = palette.fg_comment, italic = true })
set("Debug", { fg = apr.c_special })
set("Underlined", { fg = apr.c_ident, underline = true })
set("Ignore", { fg = palette.fg_comment })
set("Error", { fg = palette.white, bg = palette.error_bg, bold = true })
set("Todo", { fg = palette.bg, bg = palette.fg, bold = true })  -- reverse-ish, per upstream

-- ── Diagnostics ──────────────────────────────────────────────────────

set("DiagnosticError", { fg = palette.red })
set("DiagnosticWarn", { fg = palette.orange })
set("DiagnosticInfo", { fg = palette.blue })
set("DiagnosticHint", { fg = palette.cyan })
set("DiagnosticOk", { fg = palette.green })
set("DiagnosticVirtualTextError", { fg = palette.red, bg = palette.error_bg })
set("DiagnosticVirtualTextWarn", { fg = palette.orange, bg = palette.warn_bg })
set("DiagnosticVirtualTextInfo", { fg = palette.blue, bg = palette.info_bg })
set("DiagnosticVirtualTextHint", { fg = palette.cyan, bg = palette.hint_bg })
set("DiagnosticUnderlineError", { undercurl = true, sp = palette.red })
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
set("Removed", { fg = palette.red })

-- ── Git signs ────────────────────────────────────────────────────────

set("GitSignsAdd", { fg = palette.green, bg = palette.bg })
set("GitSignsChange", { fg = palette.blue, bg = palette.bg })
set("GitSignsDelete", { fg = palette.red, bg = palette.bg })

-- ── Misc ─────────────────────────────────────────────────────────────

set("QuickFixLine", { bg = palette.bg_alt, bold = true })
set("LspReferenceText", { bg = palette.bg_alt })
set("LspReferenceRead", { bg = palette.bg_alt })
set("LspReferenceWrite", { bg = palette.bg_visual })

-- ── Treesitter / LSP semantic tokens (aligned to upstream Apprentice) ─
-- Mirror the legacy-group colours so C++ highlighting matches the .vim:
--   keyword/statement → c_stmt (#87afd7)   type → c_type (#8787af)
--   function → c_func (#ffffaf)            identifier/field/var → c_ident/fg
--   string → c_string (#87af87)            constant/number → c_const (#ff8700)
--   preproc/macro → c_preproc (#5f8787)    comment → grey

-- keywords & control flow → statement blue
set("@keyword", { fg = apr.c_stmt })
set("@keyword.function", { fg = apr.c_stmt })
set("@keyword.return", { fg = apr.c_stmt })
set("@keyword.operator", { fg = apr.c_stmt })
set("@keyword.modifier", { fg = apr.c_stmt })
set("@keyword.import", { fg = apr.c_preproc })
set("@conditional", { fg = apr.c_stmt })
set("@repeat", { fg = apr.c_stmt })
set("@exception", { fg = apr.c_stmt })
set("@label", { fg = apr.c_stmt })

-- types → muted purple
set("@type", { fg = apr.c_type })
set("@type.builtin", { fg = apr.c_type })
set("@type.definition", { fg = apr.c_type })
set("@type.qualifier", { fg = apr.c_stmt })
set("@lsp.type.type", { fg = apr.c_type })
set("@lsp.type.type.cpp", { fg = apr.c_type })
set("@lsp.type.class", { fg = apr.c_type })
set("@lsp.type.class.cpp", { fg = apr.c_type })
set("@lsp.type.struct", { fg = apr.c_type })
set("@lsp.type.struct.cpp", { fg = apr.c_type })
set("@lsp.type.enum", { fg = apr.c_type })
set("@lsp.type.enum.cpp", { fg = apr.c_type })
set("@lsp.type.interface", { fg = apr.c_type })
set("@lsp.type.typeParameter", { fg = apr.c_type })
set("@lsp.type.typeParameter.cpp", { fg = apr.c_type })

-- functions & methods → pale yellow
set("@function", { fg = apr.c_func })
set("@function.call", { fg = apr.c_func })
set("@function.method", { fg = apr.c_func })
set("@function.method.call", { fg = apr.c_func })
set("@function.builtin", { fg = apr.c_func })
set("@constructor", { fg = apr.c_type })
set("@lsp.type.function", { fg = apr.c_func })
set("@lsp.type.function.cpp", { fg = apr.c_func })
set("@lsp.type.method", { fg = apr.c_func })
set("@lsp.type.method.cpp", { fg = apr.c_func })

-- namespaces → type purple
set("@module", { fg = apr.c_type })
set("@lsp.type.namespace", { fg = apr.c_type })
set("@lsp.type.namespace.cpp", { fg = apr.c_type })

-- fields & properties → plain fg
set("@field", { fg = palette.fg })
set("@property", { fg = palette.fg })
set("@variable.member", { fg = palette.fg })
set("@lsp.type.property", { fg = palette.fg })
set("@lsp.type.property.cpp", { fg = palette.fg })

-- parameters → identifier blue
set("@parameter", { fg = apr.c_ident })
set("@lsp.type.parameter", { fg = apr.c_ident })
set("@lsp.type.parameter.cpp", { fg = apr.c_ident })

-- variables → fg
set("@variable", { fg = palette.fg })
set("@variable.builtin", { fg = apr.c_stmt })  -- this, self
set("@lsp.type.variable", { fg = palette.fg })
set("@lsp.type.variable.cpp", { fg = palette.fg })

-- constants & enum members → orange
set("@constant", { fg = apr.c_const })
set("@constant.builtin", { fg = apr.c_const })
set("@lsp.type.enumMember", { fg = apr.c_const })
set("@lsp.type.enumMember.cpp", { fg = apr.c_const })

-- macros → preproc cyan
set("@constant.macro", { fg = apr.c_preproc })
set("@lsp.type.macro", { fg = apr.c_preproc })
set("@lsp.type.macro.cpp", { fg = apr.c_preproc })
set("@attribute", { fg = apr.c_special })
set("@attribute.cpp", { fg = apr.c_special })
set("@preproc", { fg = apr.c_preproc })

-- strings & literals
set("@string", { fg = apr.c_string })
set("@string.escape", { fg = apr.c_const })
set("@string.special", { fg = apr.c_const })
set("@character", { fg = apr.c_string })
set("@number", { fg = apr.c_const })
set("@number.float", { fg = apr.c_const })
set("@boolean", { fg = apr.c_const })

-- operators & punctuation
set("@operator", { fg = palette.fg })
set("@punctuation.bracket", { fg = palette.fg })
set("@punctuation.delimiter", { fg = palette.fg })
set("@punctuation.special", { fg = apr.c_stmt })

-- comments → grey italic
set("@comment", { fg = palette.fg_comment, italic = true })
set("@comment.documentation", { fg = palette.fg_comment, italic = true })
set("@comment.note", { fg = palette.fg_comment, italic = true })
set("@comment.todo", { fg = palette.bg, bg = palette.fg, bold = true })
set("@comment.warning", { fg = palette.bg_dark, bg = palette.orange, bold = true })
set("@comment.error", { fg = palette.white, bg = palette.red, bold = true })

-- ── BufferLine ────────────────────────────────────────────────────────

local bl = {
  sel_fg = palette.fg,
  sel_bg = palette.bg_alt,
  vis_fg = palette.fg_dim,
  vis_bg = palette.bg,
  buf_fg = palette.fg_comment,
  buf_bg = palette.bg_dark,
  fill   = palette.bg_dark,
  sep    = palette.grey,
  ind    = palette.cyan,
  mod    = palette.yellow_dim,
  pick   = palette.orange,
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
set("BufferLineHint", { fg = palette.cyan, bg = bl.buf_bg })
set("BufferLineHintSelected", { fg = palette.cyan, bg = bl.sel_bg })
set("BufferLineHintVisible", { fg = palette.cyan, bg = bl.vis_bg })
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
set("BufferLineGroupLabel", { fg = bl.sel_fg, bg = bl.ind, bold = true })
set("BufferLineGroupSeparator", { fg = bl.sep, bg = bl.fill })
set("BufferLineOffsetSeparator", { fg = bl.sep, bg = bl.fill })
set("BufferLineTruncMarker", { fg = bl.buf_fg, bg = bl.fill })

-- ── Terminal colours (verbatim from apprentice.yaml) ─────────────────

vim.g.terminal_color_0  = "#1c1c1c"  -- normal black
vim.g.terminal_color_1  = "#af5f5f"  -- normal red
vim.g.terminal_color_2  = "#5f875f"  -- normal green
vim.g.terminal_color_3  = "#87875f"  -- normal yellow
vim.g.terminal_color_4  = "#5f87af"  -- normal blue
vim.g.terminal_color_5  = "#5f5f87"  -- normal magenta
vim.g.terminal_color_6  = "#5f8787"  -- normal cyan
vim.g.terminal_color_7  = "#6c6c6c"  -- normal white
vim.g.terminal_color_8  = "#444444"  -- bright black
vim.g.terminal_color_9  = "#ff8700"  -- bright red (orange)
vim.g.terminal_color_10 = "#87af87"  -- bright green
vim.g.terminal_color_11 = "#ffffaf"  -- bright yellow
vim.g.terminal_color_12 = "#8fafd7"  -- bright blue
vim.g.terminal_color_13 = "#8787af"  -- bright magenta
vim.g.terminal_color_14 = "#5fafaf"  -- bright cyan
vim.g.terminal_color_15 = "#ffffff"  -- bright white
