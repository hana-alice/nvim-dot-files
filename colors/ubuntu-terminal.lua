vim.cmd("highlight clear")

if vim.fn.exists("syntax_on") == 1 then
  vim.cmd("syntax reset")
end

vim.o.background = "dark"
vim.o.termguicolors = true
vim.g.colors_name = "ubuntu-terminal"

local palette = {
  bg = "#300A24",
  bg_dark = "#24081C",
  bg_alt = "#3B102F",
  bg_visual = "#5E2750",
  bg_search = "#E95420",
  bg_incsearch = "#C4A000",
  fg = "#EEEEEC",
  fg_dim = "#B8ADB5",
  fg_comment = "#8F7A86",
  black = "#2E3436",
  red = "#EF2929",
  green = "#8AE234",
  yellow = "#FCE94F",
  blue = "#729FCF",
  magenta = "#AD7FA8",
  cyan = "#34E2E2",
  white = "#D3D7CF",
  orange = "#E95420",
  violet = "#77216F",
  error_bg = "#4A1114",
  warn_bg = "#4D3A0D",
  info_bg = "#173552",
  hint_bg = "#103C3F",
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

set("Normal", { fg = palette.fg, bg = palette.bg })
set("NormalNC", { fg = palette.fg_dim, bg = palette.bg })
set("NormalFloat", { fg = palette.fg, bg = palette.bg_dark })
set("FloatBorder", { fg = palette.orange, bg = palette.bg_dark })
set("FloatTitle", { fg = palette.orange, bg = palette.bg_dark, bold = true })
set("ColorColumn", { bg = palette.bg_alt })
set("CursorColumn", { bg = palette.bg_alt })
set("CursorLine", { bg = palette.bg_alt })
set("CursorLineNr", { fg = palette.orange, bg = palette.bg_alt, bold = true })
set("CursorLineFold", { fg = palette.orange, bg = palette.bg_alt })
set("CursorLineSign", { bg = palette.bg_alt })
set("LineNr", { fg = palette.fg_comment, bg = palette.bg })
set("SignColumn", { bg = palette.bg })
set("VertSplit", { fg = palette.violet, bg = palette.bg })
link("WinSeparator", "VertSplit")
set("StatusLine", { fg = palette.bg, bg = palette.orange, bold = true })
set("StatusLineNC", { fg = palette.fg_dim, bg = palette.bg_alt })
set("TabLine", { fg = palette.fg_dim, bg = palette.bg_alt })
set("TabLineFill", { bg = palette.bg_dark })
set("TabLineSel", { fg = palette.bg, bg = palette.orange, bold = true })
set("Pmenu", { fg = palette.fg, bg = palette.bg_dark })
set("PmenuSel", { fg = palette.bg, bg = palette.orange, bold = true })
set("PmenuSbar", { bg = palette.bg_alt })
set("PmenuThumb", { bg = palette.violet })
set("Visual", { bg = palette.bg_visual })
set("VisualNOS", { bg = palette.bg_visual })
set("Search", { fg = palette.bg, bg = palette.bg_search, bold = true })
set("IncSearch", { fg = palette.bg, bg = palette.bg_incsearch, bold = true })
set("CurSearch", { fg = palette.bg, bg = palette.bg_incsearch, bold = true })
set("MatchParen", { fg = palette.yellow, bg = palette.bg_visual, bold = true })
set("Folded", { fg = palette.fg_dim, bg = palette.bg_alt, italic = true })
set("FoldColumn", { fg = palette.fg_comment, bg = palette.bg })
set("Conceal", { fg = palette.fg_comment, bg = palette.bg })
set("NonText", { fg = palette.fg_comment })
set("Whitespace", { fg = palette.bg_alt })
set("SpecialKey", { fg = palette.fg_comment })
set("Directory", { fg = palette.blue, bold = true })
set("Title", { fg = palette.orange, bold = true })
set("Question", { fg = palette.green, bold = true })
set("MoreMsg", { fg = palette.green, bold = true })
set("WarningMsg", { fg = palette.orange, bold = true })
set("ErrorMsg", { fg = palette.red, bold = true })
set("ModeMsg", { fg = palette.orange, bold = true })

set("Comment", { fg = palette.fg_comment, italic = true })
set("Constant", { fg = palette.orange })
set("String", { fg = palette.green })
set("Character", { fg = palette.green })
set("Number", { fg = palette.yellow })
set("Boolean", { fg = palette.orange, bold = true })
set("Float", { fg = palette.yellow })
set("Identifier", { fg = palette.fg })
set("Function", { fg = palette.blue, bold = true })
set("Statement", { fg = palette.orange, bold = true })
set("Conditional", { fg = palette.orange, bold = true })
set("Repeat", { fg = palette.orange, bold = true })
set("Label", { fg = palette.magenta, bold = true })
set("Operator", { fg = palette.fg })
set("Keyword", { fg = palette.orange, bold = true })
set("Exception", { fg = palette.red, bold = true })
set("PreProc", { fg = palette.magenta })
set("Include", { fg = palette.magenta, bold = true })
set("Define", { fg = palette.magenta, bold = true })
set("Macro", { fg = palette.magenta, bold = true })
set("PreCondit", { fg = palette.magenta })
set("Type", { fg = palette.yellow, bold = true })
set("StorageClass", { fg = palette.yellow, bold = true })
set("Structure", { fg = palette.yellow, bold = true })
set("Typedef", { fg = palette.yellow, bold = true })
set("Special", { fg = palette.cyan })
set("SpecialChar", { fg = palette.cyan })
set("Tag", { fg = palette.orange })
set("Delimiter", { fg = palette.fg_dim })
set("SpecialComment", { fg = palette.fg_comment, italic = true })
set("Debug", { fg = palette.red })
set("Underlined", { fg = palette.blue, underline = true })
set("Ignore", { fg = palette.fg_comment })
set("Error", { fg = palette.red, bg = palette.error_bg, bold = true })
set("Todo", { fg = palette.bg, bg = palette.yellow, bold = true })

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

set("DiffAdd", { bg = palette.diff_add })
set("DiffChange", { bg = palette.diff_change })
set("DiffDelete", { bg = palette.diff_delete })
set("DiffText", { bg = palette.diff_text, bold = true })
set("Added", { fg = palette.green })
set("Changed", { fg = palette.blue })
set("Removed", { fg = palette.red })

set("GitSignsAdd", { fg = palette.green, bg = palette.bg })
set("GitSignsChange", { fg = palette.blue, bg = palette.bg })
set("GitSignsDelete", { fg = palette.red, bg = palette.bg })

set("QuickFixLine", { bg = palette.bg_alt, bold = true })
set("LspReferenceText", { bg = palette.bg_alt })
set("LspReferenceRead", { bg = palette.bg_alt })
set("LspReferenceWrite", { bg = palette.bg_visual })

vim.g.terminal_color_0 = palette.black
vim.g.terminal_color_1 = "#CC0000"
vim.g.terminal_color_2 = "#4E9A06"
vim.g.terminal_color_3 = "#C4A000"
vim.g.terminal_color_4 = "#3465A4"
vim.g.terminal_color_5 = "#75507B"
vim.g.terminal_color_6 = "#06989A"
vim.g.terminal_color_7 = palette.white
vim.g.terminal_color_8 = "#555753"
vim.g.terminal_color_9 = palette.red
vim.g.terminal_color_10 = palette.green
vim.g.terminal_color_11 = palette.yellow
vim.g.terminal_color_12 = palette.blue
vim.g.terminal_color_13 = palette.magenta
vim.g.terminal_color_14 = palette.cyan
vim.g.terminal_color_15 = palette.fg
