local map = vim.keymap.set

local function live_grep_with(opts)
  return function()
    LazyVim.pick.open("live_grep", vim.deepcopy(opts or {}))
  end
end

local function live_grep_word_with(opts)
  return function()
    local config = {
      regex = false,
      search = function(picker)
        return picker:word()
      end,
    }
    if opts then
      config = vim.tbl_deep_extend("force", config, vim.deepcopy(opts))
    end
    LazyVim.pick.open("live_grep", config)
  end
end

local function termcodes(keys)
  return vim.api.nvim_replace_termcodes(keys, true, false, true)
end

local function escape_substitute_pattern(text)
  return vim.fn.escape(text or "", [[/\]]):gsub("\n", [[\n]])
end

local function open_substitute(range, pattern)
  local command = string.format(":%ss/\\V%s//gc", range, pattern)
  vim.fn.feedkeys(termcodes(command .. "<Left><Left><Left><Left>"), "n")
end

local function open_word_substitute()
  local word = vim.fn.expand("<cword>")
  if word == nil or word == "" then
    vim.notify("No word under cursor", vim.log.levels.WARN)
    return
  end

  open_substitute("%", [[\<]] .. escape_substitute_pattern(word) .. [[\>]])
end

local function visual_selection_text()
  local lines = vim.fn.getregion(vim.fn.getpos("'<"), vim.fn.getpos("'>"), { type = vim.fn.mode() })
  if type(lines) ~= "table" or vim.tbl_isempty(lines) then
    return ""
  end
  return table.concat(lines, "\n")
end

local function open_visual_substitute()
  local selection = visual_selection_text()
  if selection == "" then
    vim.notify("No selection to replace", vim.log.levels.WARN)
    return
  end

  vim.schedule(function()
    open_substitute("'<,'>", escape_substitute_pattern(selection))
  end)
end

local function open_symbol_picker(opts)
  opts = opts or {}
  return function()
    local snacks = require("snacks")
    local picker_opts = {
      filter = LazyVim.config.kind_filter,
      tree = false,
      auto_confirm = true,
      jump = { tagstack = true, reuse_win = true },
    }
    if vim.g.neovide then
      picker_opts.win = {
        list = {
          keys = {
            ["<LeftMouse>"] = { "confirm", mode = { "n", "x" } },
          },
        },
      }
    end

    if opts.workspace then
      return snacks.picker.lsp_workspace_symbols(vim.tbl_deep_extend("force", picker_opts, {
        supports_live = true,
        live = true,
      }))
    end

    -- Prefer LSP symbols when a capable client is attached and has finished
    -- indexing (responds within a short timeout). Otherwise, fall back to
    -- treesitter for instant results while clangd is still loading.
    local buf = vim.api.nvim_get_current_buf()
    local has_lsp = #vim.lsp.get_clients({ bufnr = buf, method = "textDocument/documentSymbol" }) > 0
    if has_lsp then
      return snacks.picker.lsp_symbols(picker_opts)
    end

    -- No LSP client supports documentSymbol yet — use treesitter
    if vim.api.nvim_buf_get_name(buf) ~= "" then
      local ok = pcall(snacks.picker.treesitter, picker_opts)
      if ok then return end
    end
    vim.notify("No symbols available (LSP loading…)", vim.log.levels.INFO)
  end
end

local function close_current_target()
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_get_current_buf()
  local config = vim.api.nvim_win_get_config(win)
  local is_float = config.relative ~= nil and config.relative ~= ""
  local buftype = vim.bo[buf].buftype
  local buflisted = vim.bo[buf].buflisted
  local win_type = vim.fn.win_gettype(win)
  local is_normal_buffer = buftype == "" and buflisted and win_type == "" and not is_float

  if is_normal_buffer then
    Snacks.bufdelete({ buf = buf })
    return
  end

  local ok = pcall(vim.api.nvim_win_close, win, false)
  if ok then
    return
  end

  Snacks.bufdelete({ buf = buf })
end

-- Comment operator using Neovim's built-in vim._comment module.
-- NOTE: vim._comment is an internal API (underscore-prefixed). We use it here
-- to get operatorfunc-based gc/gcc without depending on a third-party comment
-- plugin. If Neovim ever removes/renames it, replace with gc/gcc from
-- mini.comment or Comment.nvim.  Requires Neovim >= 0.10.
local function comment_operator()
  return require("vim._comment").operator()
end

local function comment_line()
  return require("vim._comment").operator() .. "_"
end

local function comment_textobject()
  require("vim._comment").textobject()
end

local function move_cursor_to_mouse()
  local mouse = vim.fn.getmousepos()
  local win = tonumber(mouse.winid) or 0
  if win == 0 or not vim.api.nvim_win_is_valid(win) then
    return false
  end

  local buf = vim.api.nvim_win_get_buf(win)
  local line_count = math.max(vim.api.nvim_buf_line_count(buf), 1)
  local line = math.min(math.max(tonumber(mouse.line) or 1, 1), line_count)
  local text = vim.api.nvim_buf_get_lines(buf, line - 1, line, false)[1] or ""
  local col = math.min(math.max(tonumber(mouse.column) or 1, 1), #text + 1)

  vim.api.nvim_set_current_win(win)
  vim.api.nvim_win_set_cursor(win, { line, col - 1 })
  return true
end

local function open_file_reference_under_cursor()
  local cfile = vim.fn.expand("<cfile>")
  if cfile == nil or cfile == "" then
    return false
  end
  if not (cfile:find("[/\\]") or cfile:find("%.[%w_%-]+$")) then
    return false
  end

  return pcall(vim.cmd.normal, { args = { "gf" }, bang = true })
end

local function ctrl_leftmouse_jump()
  move_cursor_to_mouse()
  if open_file_reference_under_cursor() then
    return
  end
  require("utils.lsp_fallback").definition()
end

local function sidebar_toggle(kind)
  return function()
    require("utils.sidebar").toggle(kind)
  end
end

local function sidebar_pick()
  require("utils.sidebar").pick()
end

local function apply_ue_runtime_overrides()
  local opts = { nowait = true }

  map("n", "<leader>ub", "<cmd>UEBuild<cr>", vim.tbl_extend("force", opts, { desc = "UE: Build (platform from UESetPlatform)" }))
  map("n", "<leader>ug", "<cmd>UELogToggle<cr>", vim.tbl_extend("force", opts, { desc = "UE: Toggle app log" }))
  map("n", "<leader>ui", "<cmd>UEInstallAndroid<cr>", vim.tbl_extend("force", opts, { desc = "UE: Install APK to device" }))
  map("n", "<leader>ul", "<cmd>UELaunch<cr>", vim.tbl_extend("force", opts, { desc = "UE: Launch app (no debugger)" }))
  map("n", "<leader>uL", "<cmd>UELogToggle<cr>", vim.tbl_extend("force", opts, { desc = "UE: Toggle app log" }))
  map("n", "<leader>uD", "<cmd>UEDebugLogToggle<cr>", vim.tbl_extend("force", opts, { desc = "UE: Toggle Windows debug log" }))
  map("n", "<leader>up", "<cmd>UEPaths<cr>", vim.tbl_extend("force", opts, { desc = "UE: Show paths" }))
end

map("n", "gd", function()
  require("utils.lsp_fallback").definition()
end, { desc = "Definition (LSP -> GTAGS)" })

-- Generic background-task manager (list/stop any registered job). Not under
-- <leader>u* (that namespace is UE-specific); this is a general editor feature.
-- <leader>X* sub-keys mirror the DAP <leader>d* style: bare = panel, s = stop
-- one, A = stop all.
map("n", "<leader>X",  "<cmd>Tasks<cr>",       { desc = "Tasks: list / stop background jobs", nowait = true })
map("n", "<leader>Xs", "<cmd>TaskStop<cr>",    { desc = "Tasks: stop one (auto if single)", nowait = true })
map("n", "<leader>XA", "<cmd>TaskStopAll<cr>", { desc = "Tasks: stop all (confirms first)", nowait = true })

-- Eagerly load utils.lsp_fallback so its :UEDef* user_commands
-- (UEDefTrace / UEDefSelfTest / UEDefReload) are registered at startup
-- — otherwise they only appear after the first gd. ~5ms cost.
pcall(require, "utils.lsp_fallback")

vim.keymap.set("n", "<leader>gP", function()
  require("utils.lsp_fallback").jump_to_precise()
end, { desc = "Jump to precise definition (after instant jump)" })

vim.api.nvim_create_user_command("UEDefStatus", function()
  require("utils.lsp_fallback").status()
end, { desc = "Show LSP definition fallback status (debug)" })
map("n", "gr", function()
  require("utils.lsp_fallback").references()
end, { desc = "References (LSP -> GTAGS)" })
map("n", "<C-LeftMouse>", ctrl_leftmouse_jump, { desc = "Mouse: Jump to definition or file" })
map({ "n", "x" }, "gc", comment_operator, { expr = true, desc = "Toggle comment" })
map("n", "gcc", comment_line, { expr = true, desc = "Toggle comment line" })
map("o", "gc", comment_textobject, { desc = "Comment textobject" })
map("n", "gco", "o<esc>Vcx<esc><cmd>normal gcc<cr>fxa<bs>", { desc = "Add Comment Below" })
map("n", "gcO", "O<esc>Vcx<esc><cmd>normal gcc<cr>fxa<bs>", { desc = "Add Comment Above" })
map("n", "<leader>sx", live_grep_with({
  regex = false,
  args = { "--word-regexp" },
}), { desc = "Search: Grep whole word (root)" })
map("n", "<leader>sX", live_grep_with({
  args = { "--case-sensitive" },
}), { desc = "Search: Grep case-sensitive (root)" })
map({ "n", "x" }, "<leader>sy", live_grep_word_with(), { desc = "Search: Live grep word/selection (root)" })
map({ "n", "x" }, "<leader>sY", live_grep_word_with({
  root = false,
}), { desc = "Search: Live grep word/selection (cwd)" })
map("n", "<leader>sr", open_word_substitute, { desc = "Search: Replace current word in buffer" })
map("x", "<leader>sr", open_visual_substitute, { desc = "Search: Replace selection in range" })
map("n", "<leader>ss", open_symbol_picker(), { desc = "Search: Symbols" })
map("n", "<leader>sS", open_symbol_picker({ workspace = true }), { desc = "Search: Workspace Symbols" })
map("n", "<leader>bc", close_current_target, { desc = "Buffer/Window: Smart close current target" })
map("n", "<leader>bn", "<cmd>confirm enew<cr>", { desc = "Buffer: New empty buffer" })
-- Static UE keymaps. Keys that need {nowait=true} are set by
-- apply_ue_runtime_overrides() on VeryLazy (see below).
map("n", "<leader>uB", "<cmd>UEPrepare<cr>", { desc = "UE: Prepare symbols + compile_commands" })
map("n", "<leader>uc", "<cmd>UEExportCompileCommands<cr>", { desc = "UE: Export compile_commands" })
map("n", "<leader>uP", "<cmd>UESetProject<cr>", { desc = "UE: Set project" })
map("n", "<leader>ut", "<cmd>ThemePicker<cr>", { desc = "UI: Theme picker" })
map("n", "<leader>va", sidebar_pick, { desc = "Sidebar: Choose view" })
map("n", "<leader>vv", sidebar_toggle(), { desc = "Sidebar: Toggle last view" })
map("n", "<leader>vb", sidebar_toggle("buffers"), { desc = "Sidebar: Buffers" })
map("n", "<leader>vg", sidebar_toggle("git_status"), { desc = "Sidebar: Git modified files" })
map("n", "<leader>vs", sidebar_toggle("symbols"), { desc = "Sidebar: File symbols" })
map("n", "<leader>vd", sidebar_toggle("diagnostics"), { desc = "Sidebar: Diagnostics" })
map("n", "<leader>vq", sidebar_toggle("qflist"), { desc = "Sidebar: Pinned results" })
map("n", "<leader>vl", sidebar_toggle("loclist"), { desc = "Sidebar: Location list" })
map("n", "<leader>vt", sidebar_toggle("todo"), { desc = "Sidebar: TODO / FIXME" })
map("n", "<leader>?", "<cmd>UECheatsheet<cr>", { desc = "UE: Cheatsheet" })

-- Restart Neovim in the current cwd. Detects Neovide / WezTerm / native
-- terminal and spawns a fresh nvim there before tearing down this one.
-- See lua/utils/restart.lua for the detection contract.
vim.api.nvim_create_user_command("Restart", function(opts)
  local restart = require("utils.restart")
  if opts.bang then
    restart.restart({ force = true })
  else
    -- Wrap with async_launcher so the spawn + qa transition has a
    -- visible placeholder + right-bottom progress entry.
    require("utils.async_launcher").launch({
      name  = "Restart in cwd " .. vim.fn.getcwd(),
      group = "nvim",
      run   = function(report)
        if report then report("detecting client + spawning ...") end
        restart.restart()
      end,
      hold_ms = 50,  -- spawn returns fast; don't block the qa
    })
  end
end, { bang = true, desc = "Restart Neovim in current cwd (! = qa! no prompt)" })

vim.api.nvim_create_user_command("RestartDetect", function()
  require("utils.restart").restart({ dry_run = true })
end, { desc = "Print restart plan without acting (debug)" })

map("n", "<leader>qr", "<cmd>Restart<cr>", { desc = "Quit: Restart Neovim in cwd" })

-- Windows-style paste in cmdline (`:` / `/` / `?`) and insert mode.
-- Default Ctrl+V in cmdline is "literal-insert next key" (rarely useful);
-- in insert mode it's blockwise paste. On Windows users with muscle
-- memory from every other app, Ctrl+V should paste from the system
-- clipboard. Map it to <C-r>+ (insert from + register = system clip).
--
-- Notes:
-- * `c` mode covers `:` Ex-command, `/` and `?` search.
-- * `i` mode covers normal insert; we use <C-r><C-o>+ to insert
--   literally without auto-indent re-flow on multi-line pastes.
-- * Visual-block `<C-v>` is preserved (we don't remap it in normal/x).
-- * We deliberately do NOT remap normal-mode <C-v>; that would break
--   visual-block selection which is a core nvim feature.
map("c", "<C-v>", "<C-r>+", { desc = "Cmdline: paste from system clipboard" })
map("i", "<C-v>", "<C-r><C-o>+", { desc = "Insert: paste from system clipboard (literal)" })

-- DAP keymaps
map("n", "<leader>da", "<cmd>UEDAPAttach android<cr>", { desc = "DAP: Android Attach" })
map("n", "<leader>db", "<cmd>UEDAPToggleBreakpoint<cr>", { desc = "DAP: Toggle Breakpoint" })
map("n", "<leader>dc", "<cmd>UEDAPContinue<cr>", { desc = "DAP: Continue" })
map("n", "<leader>dl", "<cmd>UEDAPLaunch android<cr>", { desc = "DAP: Android Launch Debug" })
map("n", "<leader>dn", "<cmd>UEDAPStepOver<cr>", { desc = "DAP: Step Over" })
map("n", "<leader>dp", "<cmd>UEDAPPause<cr>", { desc = "DAP: Pause" })
map("n", "<leader>dx", "<cmd>UEResetLayout<cr>", { desc = "Reset Layout (DAP or default)" })
-- DAP function-row keys: bind in normal+insert+terminal so they fire from
-- dap-repl (insert/prompt), dapui_watches (insert), terminal logcat windows,
-- and regular code buffers alike. Without this, pressing F5 inside the REPL
-- inserts a literal "<F5>" instead of stepping.
local dap_fkeys = {
  ["<F5>"]   = { cmd = "UEDAPContinue",        desc = "DAP: Continue" },
  ["<F6>"]   = { cmd = "UEDAPPause",           desc = "DAP: Pause" },
  ["<F9>"]   = { cmd = "UEDAPToggleBreakpoint",desc = "DAP: Toggle Breakpoint" },
  ["<F10>"]  = { cmd = "UEDAPStepOver",        desc = "DAP: Step Over" },
  ["<F11>"]  = { cmd = "UEDAPStepIn",          desc = "DAP: Step In (VS/CLion)" },
  ["<S-F11>"]= { cmd = "UEDAPStepOut",         desc = "DAP: Step Out (VS/CLion)" },
}
for lhs, spec in pairs(dap_fkeys) do
  for _, mode in ipairs({ "n", "i", "t", "v" }) do
    vim.keymap.set(mode, lhs, "<Cmd>" .. spec.cmd .. "<CR>", { desc = spec.desc, silent = true })
  end
end
map("n", "<leader>di", "<cmd>UEDAPStepIn<cr>", { desc = "DAP: Step In" })
map("n", "<leader>do", "<cmd>UEDAPStepOut<cr>", { desc = "DAP: Step Out" })
map("n", "<leader>du", "<cmd>UEDAPToggleUI<cr>", { desc = "DAP: Toggle UI" })
map("n", "<leader>dr", "<cmd>UEDAPREPL<cr>", { desc = "DAP: Toggle REPL" })
map("n", "<leader>d1", "<cmd>UEDAPTab repl<cr>", { desc = "DAP Tab: REPL" })
map("n", "<leader>d2", "<cmd>UEDAPTab console<cr>", { desc = "DAP Tab: Console" })
map("n", "<leader>d3", "<cmd>UEDAPTab breakpoints<cr>", { desc = "DAP Tab: Breakpoints" })
map("n", "<leader>d4", "<cmd>UEDAPTab logcat<cr>", { desc = "DAP Tab: Logcat" })
map("n", "<leader>d]", "<cmd>UEDAPNextTab<cr>", { desc = "DAP Tab: Next" })
map("n", "<leader>d[", "<cmd>UEDAPPrevTab<cr>", { desc = "DAP Tab: Previous" })

-- DAP inspect / evaluate / navigate (added 2026-05-21)
--   <leader>dB / dL / dC : conditional bp / logpoint / clear all (capitals
--                          to avoid colliding with the lowercase counterparts
--                          for plain toggle / continue).
--   <leader>de / dw / dh : eval-prompt / watch-add / hover. Visual variants
--                          of dh and dw evaluate the selection instead of
--                          <cword>.
--   <leader>dt           : run-to-cursor (ephemeral bp + continue).
--   <leader>dk / dj      : stack frame up / down (vim-flavored arrow keys).
--   <leader>dR           : restart current frame.
map("n", "<leader>dB", "<cmd>UEDAPCondBreakpoint<cr>",   { desc = "DAP: Conditional Breakpoint" })
map("n", "<leader>dL", "<cmd>UEDAPLogpoint<cr>",         { desc = "DAP: Logpoint" })
map("n", "<leader>dC", "<cmd>UEDAPClearBreakpoints<cr>", { desc = "DAP: Clear all breakpoints" })
map("n", "<leader>de", "<cmd>UEDAPEval<cr>",             { desc = "DAP: Evaluate expression" })
map("n", "<leader>dh", "<cmd>UEDAPHover<cr>",            { desc = "DAP: Hover (eval cword)" })
map("v", "<leader>dh", ":UEDAPHover<cr>",                { desc = "DAP: Hover (eval selection)" })
map("n", "<leader>dw", "<cmd>UEDAPWatchAdd<cr>",         { desc = "DAP: Add cword to Watches" })
map("v", "<leader>dw", ":UEDAPWatchAdd<cr>",             { desc = "DAP: Add selection to Watches" })
-- UE-aware watch templates: prompt for template type via vim.ui.select,
-- then use cword as the expression (or the visual selection in visual mode).
-- Press <leader>dW on an identifier → pick fname/uobject/actor/tarray/raw.
local function _ue_dap_watch_picker()
  local templates = { "fname", "uobject", "actor", "tarray", "raw" }
  local mode = vim.api.nvim_get_mode().mode
  local expr
  if mode == "v" or mode == "V" or mode == "\22" then
    vim.cmd('noautocmd silent normal! "zy')
    expr = vim.fn.getreg("z"):gsub("[\r\n]+", " "):gsub("^%s+", ""):gsub("%s+$", "")
  else
    expr = vim.fn.expand("<cword>")
  end
  if not expr or expr == "" then
    vim.notify("[ue.dap] no expression under cursor", vim.log.levels.WARN)
    return
  end
  vim.ui.select(templates, {
    prompt = "UE Watch template for `" .. expr .. "`:",
  }, function(choice)
    if choice then vim.cmd(("UEDAPWatchUE %s %s"):format(choice, expr)) end
  end)
end
map("n", "<leader>dW", _ue_dap_watch_picker, { desc = "DAP: UE-aware watch (picker)" })
map("v", "<leader>dW", _ue_dap_watch_picker, { desc = "DAP: UE-aware watch (picker, selection)" })
map("n", "<leader>dt", "<cmd>UEDAPRunToCursor<cr>",      { desc = "DAP: Run to cursor" })
map("n", "<leader>dk", "<cmd>UEDAPFrameUp<cr>",          { desc = "DAP: Stack frame up" })
map("n", "<leader>dj", "<cmd>UEDAPFrameDown<cr>",        { desc = "DAP: Stack frame down" })
map("n", "<leader>dR", "<cmd>UEDAPRestartFrame<cr>",     { desc = "DAP: Restart frame" })
map("n", "<leader>ui", "<cmd>UEInstallAndroid<cr>", { desc = "UE: Install APK to device" })

-- Deferred: apply {nowait=true} overrides once LazyVim has finished loading
-- its own <leader>u* mappings, so ours take priority without delay.
-- CRITICAL: if VeryLazy already fired by the time this file loads (which
-- can happen because LazyVim auto-loads config/keymaps.lua ON the
-- VeryLazy event itself), the once-handler would never run. Apply
-- immediately in that case.
if vim.v.vim_did_enter == 1 then
  apply_ue_runtime_overrides()
else
  vim.api.nvim_create_autocmd("User", {
    pattern = "VeryLazy",
    once = true,
    callback = apply_ue_runtime_overrides,
  })
end
