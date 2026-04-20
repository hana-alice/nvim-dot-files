-- NvChad-style cheatsheet with tabbed categories
-- Floating window, multi-column grid, color-coded headers
local M = {}
local api = vim.api
local fn = vim.fn

-- ══════════════════════════════════════════════════════════════════════
-- HIGHLIGHT GROUPS
-- ══════════════════════════════════════════════════════════════════════
local hl_groups = {
  CheatTitle     = { fg = "#1e1e2e", bg = "#89b4fa", bold = true },
  CheatTabActive = { fg = "#1e1e2e", bg = "#a6e3a1", bold = true },
  CheatTabInact  = { fg = "#bac2de", bg = "#313244" },
  CheatSection   = { fg = "#1e1e2e", bg = "#45475a" },
  CheatKey       = { fg = "#f38ba8", bg = "#313244", bold = true },
  CheatDesc      = { fg = "#cdd6f4", bg = "#313244" },
  CheatHead1     = { fg = "#1e1e2e", bg = "#f38ba8", bold = true },
  CheatHead2     = { fg = "#1e1e2e", bg = "#fab387", bold = true },
  CheatHead3     = { fg = "#1e1e2e", bg = "#a6e3a1", bold = true },
  CheatHead4     = { fg = "#1e1e2e", bg = "#89b4fa", bold = true },
  CheatHead5     = { fg = "#1e1e2e", bg = "#cba6f7", bold = true },
  CheatHead6     = { fg = "#1e1e2e", bg = "#f9e2af", bold = true },
  CheatHead7     = { fg = "#1e1e2e", bg = "#94e2d5", bold = true },
  CheatHead8     = { fg = "#1e1e2e", bg = "#74c7ec", bold = true },
  CheatBg        = { bg = "#1e1e2e" },
  CheatBorder    = { fg = "#585b70" },
  CheatAscii     = { fg = "#89b4fa", bold = true },
  CheatFooter    = { fg = "#6c7086", italic = true },
}

local heading_hls = {
  "CheatHead1", "CheatHead2", "CheatHead3", "CheatHead4",
  "CheatHead5", "CheatHead6", "CheatHead7", "CheatHead8",
}

local function setup_highlights()
  for name, opts in pairs(hl_groups) do
    local ok = pcall(api.nvim_get_hl_by_name, name, true)
    -- Always set, allow override by colorscheme
    api.nvim_set_hl(0, name, opts)
  end
end

-- ══════════════════════════════════════════════════════════════════════
-- CHEATSHEET DATA
-- ══════════════════════════════════════════════════════════════════════
-- Each tab = { name = "...", sections = { { title = "...", mappings = { {"key", "desc"}, ... } }, ... } }

local tabs = {
  -- ── Tab 1: Basics ──
  {
    name = "Basics",
    sections = {
      {
        title = "Conventions",
        mappings = {
          { "Built-in wins",   "Dup w/ LazyVim → drop ours" },
          { "No mixed case",   "Avoid <ldr>X+ 2-letter combos" },
          { "u prefix shared", "UI toggles + UE runtime" },
          { "<C-/>",           "THE terminal toggle" },
          { "<leader>?",       "This cheatsheet" },
          { "<leader>sk",      "Discover any keymap" },
        },
      },
      {
        title = "Start Here",
        mappings = {
          { "<leader>",         "Open which-key" },
          { "<leader>sk",       "Search keymaps" },
          { "<leader>sh",       "Search help" },
          { "<leader><space>",  "Find files" },
          { "<leader>/",        "Grep project" },
          { "gd / gr",          "Definition / References" },
          { "u / <C-r>",        "Undo / Redo" },
          { ".",                "Repeat last change" },
        },
      },
      {
        title = "Motions",
        mappings = {
          { "h j k l",     "Left Down Up Right" },
          { "w / b / e",   "Word start / prev / end" },
          { "W / B / E",   "WORD start / prev / end" },
          { "0 / ^ / $",   "Line start / first char / end" },
          { "gg / G",      "File start / end" },
          { "42G",         "Go to line 42" },
          { "%",           "Matching bracket" },
          { "f{c} / t{c}", "Find / till char forward" },
          { "F{c} / T{c}", "Find / till char backward" },
          { "; / ,",       "Repeat f/t forward / back" },
          { "{ / }",       "Prev / next paragraph" },
          { "( / )",       "Prev / next sentence" },
          { "zz / zt / zb","Center / top / bottom line" },
          { "<C-d>/<C-u>", "Half page down / up" },
          { "<C-f>/<C-b>", "Full page down / up" },
          { "H / M / L",   "Screen top / mid / bottom" },
          { "<C-o>/<C-i>", "Jump back / forward" },
          { "[c",          "Jump to TS context" },
        },
      },
      {
        title = "Modes",
        mappings = {
          { "i / a",        "Insert before / after" },
          { "I / A",        "Insert line start / end" },
          { "o / O",        "New line below / above" },
          { "<Esc>",        "Back to Normal" },
          { "v / V / <C-v>","Visual char / line / block" },
          { "gv",           "Reselect last visual" },
          { ":",            "Command mode" },
        },
      },
    },
  },
  -- ── Tab 2: Editing ──
  {
    name = "Edit",
    sections = {
      {
        title = "Core Editing",
        mappings = {
          { "x / X",        "Delete char fwd / back" },
          { "r{c}",         "Replace single char" },
          { "R",            "Replace mode" },
          { "s / S",        "Substitute char / line" },
          { "c{motion}",    "Change (delete + insert)" },
          { "cc / C",       "Change line / to end" },
          { "d{motion}",    "Delete" },
          { "dd / D",       "Delete line / to end" },
          { "y{motion}",    "Yank (copy)" },
          { "yy / Y",       "Yank line" },
          { "p / P",        "Paste after / before" },
          { "J",            "Join line below" },
          { "~ / gu / gU",  "Toggle / lower / upper case" },
          { ">> / <<",      "Indent / unindent" },
          { "<C-s>",        "Save file" },
          { "<leader>cf",   "Format" },
          { "<A-j>/<A-k>",  "Move line / selection" },
        },
      },
      {
        title = "Text Objects",
        mappings = {
          { "iw / aw",    "Inner / a word" },
          { "iW / aW",    "Inner / a WORD" },
          { "is / as",    "Inner / a sentence" },
          { "ip / ap",    "Inner / a paragraph" },
          { "i\" / a\"",   "Inner / a double-quoted" },
          { "i' / a'",    "Inner / a single-quoted" },
          { "i) / a)",    "Inner / a parenthesized" },
          { "i] / a]",    "Inner / a bracketed" },
          { "i} / a}",    "Inner / a braced" },
          { "it / at",    "Inner / a tag (HTML/XML)" },
          { "gc / gcc",   "Comment operator / line" },
          { "gco / gcO",  "Comment below / above" },
        },
      },
      {
        title = "Registers / Marks / Macros",
        mappings = {
          { "\"+y / \"+p",  "System clipboard" },
          { "\"_d",        "Delete no register" },
          { "\"0p",        "Paste last yank" },
          { "m{a-z}",     "Set local mark" },
          { "'{mark}",    "Jump to mark line" },
          { "`{mark}",    "Jump to mark exact" },
          { "gi",          "Last insert pos + insert" },
          { "qa / q",     "Start / stop recording" },
          { "@a / @@",    "Play macro / repeat" },
          { "{n}@a",      "Play macro N times" },
        },
      },
    },
  },
  -- ── Tab 3: Search ──
  {
    name = "Search",
    sections = {
      {
        title = "Search & Navigate",
        mappings = {
          { "/text  ?text",    "Search fwd / back" },
          { "n / N",           "Next / prev match" },
          { "* / #",           "Search word fwd / back" },
          { ":noh",            "Clear search highlight" },
          { "gd",              "Definition (TS arity filter → LSP → GTAGS → rg)" },
          { "gr",              "References (LSP→GTAGS)" },
          { "gD",              "Declaration" },
          { "gI",              "Implementation" },
          { "gy",              "Type definition" },
          { "K",               "Hover docs" },
          { "<leader>ss/sS",   "Doc / workspace symbols" },
          { "<C-LeftMouse>",   "Smart jump (gf or gd)" },
        },
      },
      {
        title = "Picker / Grep",
        mappings = {
          { "<leader><space>",  "Find workspace files" },
          { "<leader>fe",       "File tree (project)" },
          { "<leader>ff / fF",  "Project / workspace files" },
          { "<leader>fg",       "Git files (UE-aware)" },
          { "<leader>,",        "Buffers" },
          { "<leader>;",        "All commands" },
          { "<leader>:",        "Command history" },
          { "<leader>fr / fR",  "Recent files" },
          { "<leader>/",        "Grep project" },
          { "<leader>sg / sG",  "Grep workspace code / all" },
          { "<leader>sw / sW",  "Search current word" },
          { "<leader>sy / sY",  "Live grep with prefill" },
          { "<leader>sx / sX",  "Whole-word / case-sensitive" },
          { "<leader>sR",       "Resume last picker (any kind)" },
          { "<leader>s/",       "Resume last grep (after <C-q> pin too)" },
          { "<leader>sk",       "Keymaps" },
          { "<leader>sh",       "Help tags" },
        },
      },
      {
        title = "Search & Replace",
        mappings = {
          { ":s/old/new/g",     "Replace in line" },
          { ":%s/old/new/gc",   "Replace all + confirm" },
          { "<leader>sr",       "Cross-file search/replace" },
          { "<C-q>",            "Picker → quickfix" },
          { "<C-Space>",        "Multi-select in picker" },
          { "<leader>s/",       "Resume grep after <C-q> pin" },
        },
      },
      {
        title = "Inside a Picker",
        mappings = {
          { "<C-q>",            "Send results to quickfix" },
          { "<C-Space>",        "Multi-select toggle" },
          { "<C-j> / <C-k>",    "Down / up" },
          { "<C-d> / <C-u>",    "Half page down / up" },
          { "<C-p> / <C-n>",    "Prev / next history" },
          { "<C-/>",            "Toggle picker help" },
          { "<Tab>",            "Focus list ↔ input" },
          { "<CR> / q / <Esc>", "Confirm / close" },
        },
      },
    },
  },
  -- ── Tab 4: Windows ──
  {
    name = "Window",
    sections = {
      {
        title = "Buffer",
        mappings = {
          { "<S-h> / <S-l>",   "Prev / next buffer" },
          { "<leader>bb",      "Switch to other buffer" },
          { "<leader>bn",      "New buffer" },
          { "<leader>bd",      "Delete buffer" },
          { "<leader>bo",      "Delete other buffers" },
          { "<leader>bD",      "Delete buffer + window" },
          { "<leader>bp",      "Toggle pin buffer" },
        },
      },
      {
        title = "Window",
        mappings = {
          { "<leader>- / |",   "Horizontal / vertical split" },
          { "<C-h/j/k/l>",    "Move between windows" },
          { "<leader>wd",      "Delete window" },
          { "<leader>wm",      "Maximize / restore" },
        },
      },
      {
        title = "Tab",
        mappings = {
          { "<leader><tab><tab>",  "New tab" },
          { "<leader><tab>[ / ]",  "Prev / next tab" },
          { "<leader><tab>d",      "Close tab" },
          { "<leader><tab>o",      "Close other tabs" },
        },
      },
      {
        title = "Terminal",
        mappings = {
          { "<C-/>",            "Toggle root term (LazyVim)" },
          { "<leader>ft / fT",  "Float terminal root / cwd" },
          { "<leader>tc",       "Bottom term + cd to file dir" },
          { "<leader>tp",       "Bottom term + cd to project" },
          { "<leader>te",       "Bottom term + cd to UE engine" },
          { "<Esc>",            "Exit terminal mode" },
        },
      },
    },
  },
  -- ── Tab 5: Folds ──
  {
    name = "Folds",
    sections = {
      {
        title = "Fold Operations",
        mappings = {
          { "zi",         "Toggle fold on/off" },
          { "zc / zo",    "Close / open fold" },
          { "za",         "Toggle fold" },
          { "zC / zO",    "Close / open recursive" },
          { "zA",         "Toggle recursive" },
          { "zM / zR",    "Close all / open all" },
          { "zm / zr",    "More / less fold level" },
          { "zj / zk",    "Next / prev fold" },
        },
      },
      {
        title = "Manual Folds",
        mappings = {
          { "zf{motion}",  "Create fold by motion" },
          { "V select+zf", "Fold visual selection" },
          { "zd / zE",     "Delete fold / all folds" },
        },
      },
      {
        title = "Large File Tips",
        mappings = {
          { "zM → zj/zk",  "Collapse, jump functions" },
          { "zo → zc",     "Open section, close done" },
          { "ma / 'a",     "Mark positions" },
          { "<C-o>",       "Jump back" },
          { ":setlocal foldmethod=indent", "Quick folds" },
        },
      },
    },
  },
  -- ── Tab 6: Tools ──
  {
    name = "Tools",
    sections = {
      {
        title = "Diagnostics / Trouble",
        mappings = {
          { "<leader>xx / xX",  "Diagnostics all / buffer" },
          { "<leader>xQ / xL",  "Quickfix / location list" },
          { "[d / ]d",          "Prev / next diagnostic" },
          { "[e / ]e",          "Prev / next error" },
          { "[w / ]w",          "Prev / next warning" },
          { "<leader>cd",       "Line diagnostics" },
          { "<leader>cl",       "LSP info" },
          { ":copen / :cclose", "Open / close quickfix" },
          { ":cnext / :cprev",  "Navigate quickfix" },
        },
      },
      {
        title = "Left Sidebar",
        mappings = {
          { "<leader>va",  "View menu (1-7 / j/k)" },
          { "<leader>vv",  "Toggle sidebar" },
          { "<leader>vg",  "Git status" },
          { "<leader>vb",  "Open buffers" },
          { "<leader>vs",  "Symbols" },
          { "<leader>vd",  "Diagnostics" },
          { "<leader>vq",  "Quickfix" },
          { "<leader>vt",  "TODO / FIXME" },
        },
      },
      {
        title = "Git",
        mappings = {
          { "]h / [h",        "Next / prev hunk" },
          { "]H / [H",        "Last / first hunk" },
          { "<leader>gg",     "Lazygit" },
          { "<leader>gb",     "Blame line" },
          { "<leader>gf/gl",  "File history / git log" },
          { "<leader>gs/gS",  "Git status / stash" },
          { "<leader>gd/gD",  "Diff hunks / origin" },
          { "<leader>gB/gY",  "Browse / copy URL" },
        },
      },
    },
  },
  -- ── Tab 7: UI ──
  {
    name = "UI",
    sections = {
      {
        title = "Toggles",
        mappings = {
          { "<leader>ut",   "Theme picker" },
          { ":Theme <name>","Set + persist theme" },
          { "<leader>uf",   "Format on save" },
          { "<leader>uF",   "Force format mode" },
          { "<leader>ud",   "Diagnostics" },
          { "<leader>us",   "Spelling" },
          { "<leader>uw",   "Word wrap" },
          { "<leader>uh",   "Inlay hints" },
          { "<leader>uG",   "Git signs" },
          { "<leader>uT",   "Treesitter" },
          { "<leader>uz",   "Zen mode" },
          { "<leader>ur",   "Redraw + clear highlights" },
        },
      },
      {
        title = "Windows Custom",
        mappings = {
          { "<leader>E",     "Reveal in Explorer" },
          { "<leader>oe",    "Same as above" },
          { ":RevealInExplorer", "Direct command" },
        },
      },
      {
        title = "Misc",
        mappings = {
          { "<leader>l",    "Open Lazy plugin manager" },
          { "<leader>qq",   "Quit all" },
          { "<leader>fn",   "New file" },
          { "<leader>un",   "Dismiss notifications" },
          { "<C-a>/<C-x>",  "Increment / decrement" },
          { "gf",           "Go to file under cursor" },
          { "gx",           "Open URL under cursor" },
          { "ZZ / ZQ",      "Save+quit / quit no save" },
        },
      },
    },
  },
  -- ── Tab 8: UE ──
  {
    name = "UE",
    sections = {
      {
        title = "UE Workflow",
        mappings = {
          { "<leader>ue",    "UEPrepare (index + cc)" },
          { "<leader>uc",    "Export compile_commands" },
          { "<leader>uj",    "Set project .uproject" },
          { ":UESetPlatform","Select platform + config" },
          { "<leader>up",    "Show UE paths" },
          { ":UEClearCache", "Clear UE + clangd caches" },
          { ":UEClearCache!","+ rm cc + restart clangd" },
          { ":UEHelp",       "UE command help" },
          { "<leader>?",     "Open this cheatsheet" },
        },
      },
      {
        title = "Build / Run",
        mappings = {
          { "<leader>ub",   "Build (platform from :UESetPlatform)" },
          { "<leader>ui",   "Install APK" },
          { "<leader>ul",   "Launch app (no debug)" },
          { "<leader>ug",   "Toggle app log" },
          { "<leader>uv",   "Toggle Win debug log" },
          { "<leader>uo/uO","Module find file / grep" },
        },
      },
      {
        title = "Typical Flow",
        mappings = {
          { "1. :UESetPlatform",  "Win64 Dev Editor" },
          { "2. :UEPrepare",      "Index + compile_commands" },
          { "3. gd / gr",         "Start working" },
        },
      },
    },
  },
  -- ── Tab 9: DAP ──
  {
    name = "DAP",
    sections = {
      {
        title = "Android DAP",
        mappings = {
          { "<leader>da",   "Attach to Android" },
          { "<leader>dl",   "Launch + auto attach" },
          { "<leader>db",   "Toggle HW breakpoint" },
          { "<leader>dc",   "Continue" },
          { "<leader>dp",   "Pause" },
          { "<leader>dn",   "Step over" },
          { "<leader>di",   "Step in" },
          { "<leader>do",   "Step out" },
        },
      },
      {
        title = "DAP UI",
        mappings = {
          { "<leader>du",   "Toggle DAP UI" },
          { "<leader>dr",   "Toggle REPL" },
          { "<leader>dx",   "Reset layout" },
          { "F9",           "Toggle breakpoint" },
          { "F5",           "Continue" },
          { "F6",           "Pause" },
          { "F10",          "Step over" },
          { ":qa",          "Auto DAP cleanup" },
        },
      },
      {
        title = "Quick Reference",
        mappings = {
          { "Space da",  "Attach" },
          { "Space dl",  "Launch debug" },
          { "Space db",  "Breakpoint" },
          { "Space dc",  "Continue" },
          { "Space dn",  "Step over" },
          { "Space di",  "Step in" },
          { "Space do",  "Step out" },
          { "Space du",  "DAP UI" },
        },
      },
    },
  },
}

-- ══════════════════════════════════════════════════════════════════════
-- RENDERING
-- ══════════════════════════════════════════════════════════════════════
local state = {
  buf = nil,
  win = nil,
  ns = nil,
  current_tab = 1,
}

local function is_valid()
  return state.buf
    and api.nvim_buf_is_valid(state.buf)
    and state.win
    and api.nvim_win_is_valid(state.win)
end

local function close()
  if state.win and api.nvim_win_is_valid(state.win) then
    api.nvim_win_close(state.win, true)
  end
  if state.buf and api.nvim_buf_is_valid(state.buf) then
    api.nvim_buf_delete(state.buf, { force = true })
  end
  state.buf = nil
  state.win = nil
end

local ascii = {
  "                                        ",
  " █▀▀ █░█ █▀▀ ▄▀█ ▀█▀ █▀ █░█ █▀▀ █▀▀ ▀█▀",
  " █▄▄ █▀█ ██▄ █▀█ ░█░ ▄█ █▀█ ██▄ ██▄ ░█░",
  "                                        ",
}

local function render(tab_idx)
  if not is_valid() then return end

  tab_idx = tab_idx or state.current_tab
  state.current_tab = tab_idx

  local buf = state.buf
  local win = state.win
  local ns = state.ns
  local win_w = api.nvim_win_get_width(win)
  local win_h = api.nvim_win_get_height(win)

  -- Clear buffer
  vim.bo[buf].modifiable = true
  api.nvim_buf_clear_namespace(buf, ns, 0, -1)

  -- ── Compute column layout ──
  local tab = tabs[tab_idx]
  if not tab then return end

  -- Find max key+desc width across all sections
  local max_pair_w = 0
  for _, sec in ipairs(tab.sections) do
    for _, m in ipairs(sec.mappings) do
      local w = fn.strdisplaywidth(m[1]) + fn.strdisplaywidth(m[2]) + 6
      if w > max_pair_w then max_pair_w = w end
    end
    local tw = fn.strdisplaywidth(sec.title) + 4
    if tw > max_pair_w then max_pair_w = tw end
  end

  local col_w = math.max(max_pair_w, 30)
  local usable_w = win_w - 4  -- 2 padding each side
  local n_cols = math.max(1, math.floor(usable_w / col_w))
  col_w = math.floor(usable_w / n_cols)

  -- ── Distribute sections into columns ──
  local cards = {}
  for si, sec in ipairs(tab.sections) do
    local card = { title = sec.title, items = sec.mappings, hl_idx = ((si - 1) % #heading_hls) + 1 }
    card.height = 1 + #sec.mappings + 1
    table.insert(cards, card)
  end

  local columns = {}
  local col_heights = {}
  for i = 1, n_cols do
    columns[i] = {}
    col_heights[i] = 0
  end

  for _, card in ipairs(cards) do
    local min_h, min_i = math.huge, 1
    for i = 1, n_cols do
      if col_heights[i] < min_h then
        min_h = col_heights[i]
        min_i = i
      end
    end
    table.insert(columns[min_i], card)
    col_heights[min_i] = col_heights[min_i] + card.height
  end

  -- ── Build lines ──
  local max_col_height = 0
  for i = 1, n_cols do
    max_col_height = math.max(max_col_height, col_heights[i] or 0)
  end
  local total_lines = math.max(win_h, #ascii + 2 + max_col_height + 2)
  local blanks = {}
  for i = 1, total_lines do
    blanks[i] = string.rep(" ", win_w)
  end
  api.nvim_buf_set_lines(buf, 0, -1, false, blanks)

  -- ── ASCII header ──
  local row = 0
  for i, line in ipairs(ascii) do
    local pad = math.floor((win_w - fn.strdisplaywidth(line)) / 2)
    api.nvim_buf_set_extmark(buf, ns, row + i - 1, 0, {
      virt_text = { { string.rep(" ", math.max(0, pad)) .. line, "CheatAscii" } },
      virt_text_pos = "overlay",
    })
  end
  row = row + #ascii

  -- ── Tab bar ──
  local tab_parts = {}
  for ti, t in ipairs(tabs) do
    local label = " " .. ti .. ":" .. t.name .. " "
    local hl = ti == tab_idx and "CheatTabActive" or "CheatTabInact"
    table.insert(tab_parts, { label, hl })
    table.insert(tab_parts, { " ", "CheatBg" })
  end
  -- Center the tab bar
  local tab_total_w = 0
  for _, p in ipairs(tab_parts) do
    tab_total_w = tab_total_w + fn.strdisplaywidth(p[1])
  end
  local tab_pad = math.max(0, math.floor((win_w - tab_total_w) / 2))
  local centered_parts = { { string.rep(" ", tab_pad), "CheatBg" } }
  vim.list_extend(centered_parts, tab_parts)

  api.nvim_buf_set_extmark(buf, ns, row, 0, {
    virt_text = centered_parts,
    virt_text_pos = "overlay",
  })
  row = row + 2 -- gap after tabs

  -- ── Render cards ──
  local content_start = row
  local pad_left = math.max(0, math.floor((win_w - n_cols * col_w) / 2))

  for ci = 1, n_cols do
    local r = content_start
    local col_start = pad_left + (ci - 1) * col_w

    for _, card in ipairs(columns[ci]) do
      -- Section heading
      local title = " " .. card.title .. " "
      local title_w = fn.strdisplaywidth(title)
      local title_pad_l = math.floor((col_w - title_w) / 2)
      local title_pad_r = col_w - title_w - title_pad_l
      local heading_hl = heading_hls[card.hl_idx]

      if r < total_lines then
        api.nvim_buf_set_extmark(buf, ns, r, col_start, {
          virt_text = {
            { string.rep(" ", title_pad_l), "CheatSection" },
            { title, heading_hl },
            { string.rep(" ", title_pad_r), "CheatSection" },
          },
          virt_text_pos = "overlay",
        })
      end
      r = r + 1

      -- Mapping rows
      for _, m in ipairs(card.items) do
        if r >= total_lines then break end
        local key_str = m[1]
        local desc_str = m[2]
        local gap = col_w - 4 - fn.strdisplaywidth(key_str) - fn.strdisplaywidth(desc_str)
        if gap < 1 then gap = 1 end

        api.nvim_buf_set_extmark(buf, ns, r, col_start, {
          virt_text = {
            { "  ", "CheatSection" },
            { key_str, "CheatKey" },
            { string.rep(" ", gap), "CheatSection" },
            { desc_str, "CheatDesc" },
            { "  ", "CheatSection" },
          },
          virt_text_pos = "overlay",
        })
        r = r + 1
      end

      -- Blank between cards
      r = r + 1
    end
  end

  -- ── Footer ──
  local footer = " <Tab>/1-9 切换分类  q/<Esc> 关闭  / 搜索 "
  local footer_row = total_lines - 1
  if footer_row > 0 then
    local fpad = math.max(0, math.floor((win_w - fn.strdisplaywidth(footer)) / 2))
    api.nvim_buf_set_extmark(buf, ns, footer_row, 0, {
      virt_text = { { string.rep(" ", fpad) .. footer, "CheatFooter" } },
      virt_text_pos = "overlay",
    })
  end

  vim.bo[buf].modifiable = false
end

-- ══════════════════════════════════════════════════════════════════════
-- KEYMAPS
-- ══════════════════════════════════════════════════════════════════════
local function setup_keymaps()
  local buf = state.buf
  local opts = { buffer = buf, noremap = true, silent = true }

  vim.keymap.set("n", "q", close, opts)
  vim.keymap.set("n", "<Esc>", close, opts)

  vim.keymap.set("n", "<Tab>", function()
    state.current_tab = (state.current_tab % #tabs) + 1
    render(state.current_tab)
  end, opts)

  vim.keymap.set("n", "<S-Tab>", function()
    state.current_tab = ((state.current_tab - 2) % #tabs) + 1
    render(state.current_tab)
  end, opts)

  -- Number keys 1-9 for direct tab switching
  for i = 1, math.min(#tabs, 9) do
    vim.keymap.set("n", tostring(i), function()
      render(i)
    end, opts)
  end

  -- Scroll keybinds (buffer is non-modifiable but scrollable)
  vim.keymap.set("n", "j", function()
    local ok = pcall(vim.cmd, "normal! j")
  end, opts)
  vim.keymap.set("n", "k", function()
    local ok = pcall(vim.cmd, "normal! k")
  end, opts)
end

-- ══════════════════════════════════════════════════════════════════════
-- OPEN / TOGGLE
-- ══════════════════════════════════════════════════════════════════════
function M.open(tab_idx)
  if is_valid() then
    close()
    return
  end

  setup_highlights()

  -- Create buffer
  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "cheatsheet"

  -- Window dimensions
  local ew = vim.o.columns
  local eh = vim.o.lines
  local w = math.min(math.floor(ew * 0.85), 180)
  local h = math.min(math.floor(eh * 0.80), 50)
  local row = math.floor((eh - h) / 2)
  local col = math.floor((ew - w) / 2)

  local win = api.nvim_open_win(buf, true, {
    relative = "editor",
    width = w,
    height = h,
    row = row,
    col = col,
    style = "minimal",
    border = "rounded",
    title = " Cheatsheet ",
    title_pos = "center",
  })

  vim.wo[win].cursorline = false
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].winhl = "Normal:CheatBg,FloatBorder:CheatBorder"

  state.buf = buf
  state.win = win
  state.ns = api.nvim_create_namespace("cheatsheet")
  state.current_tab = tab_idx or 1

  setup_keymaps()
  render(state.current_tab)

  -- Auto-close on leave
  api.nvim_create_autocmd("BufLeave", {
    buffer = buf,
    once = true,
    callback = function()
      vim.schedule(close)
    end,
  })

  -- Resize handler
  api.nvim_create_autocmd({ "VimResized", "WinResized" }, {
    buffer = buf,
    callback = function()
      if is_valid() then
        -- Update window size
        local new_ew = vim.o.columns
        local new_eh = vim.o.lines
        local new_w = math.min(math.floor(new_ew * 0.85), 180)
        local new_h = math.min(math.floor(new_eh * 0.80), 50)
        api.nvim_win_set_config(state.win, {
          width = new_w,
          height = new_h,
          row = math.floor((new_eh - new_h) / 2),
          col = math.floor((new_ew - new_w) / 2),
          relative = "editor",
        })
        render(state.current_tab)
      end
    end,
  })
end

--- Provide the raw tabs data for extension
M.tabs = tabs

return M
