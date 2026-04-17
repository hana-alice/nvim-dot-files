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

-- Android DAP keymaps
map("n", "<leader>da", "<cmd>UEAndroidDAPAttach<cr>", { desc = "DAP: Android Attach" })
map("n", "<leader>db", "<cmd>UEAndroidDAPToggleBreakpoint<cr>", { desc = "DAP: Toggle Breakpoint" })
map("n", "<leader>dc", "<cmd>UEAndroidDAPContinue<cr>", { desc = "DAP: Continue" })
map("n", "<leader>dl", "<cmd>UEAndroidDAPLaunch<cr>", { desc = "DAP: Android Launch Debug" })
map("n", "<leader>dn", "<cmd>UEAndroidDAPStepOver<cr>", { desc = "DAP: Step Over" })
map("n", "<leader>dp", "<cmd>UEAndroidDAPPause<cr>", { desc = "DAP: Pause" })
map("n", "<leader>dx", "<cmd>UEResetLayout<cr>", { desc = "Reset Layout (DAP or default)" })
map("n", "<F5>", "<cmd>UEAndroidDAPContinue<cr>", { desc = "DAP: Continue" })
map("n", "<F6>", "<cmd>UEAndroidDAPPause<cr>", { desc = "DAP: Pause" })
map("n", "<F9>", "<cmd>UEAndroidDAPToggleBreakpoint<cr>", { desc = "DAP: Toggle Breakpoint" })
map("n", "<F10>", "<cmd>UEAndroidDAPStepOver<cr>", { desc = "DAP: Step Over" })
map("n", "<leader>di", "<cmd>UEAndroidDAPStepIn<cr>", { desc = "DAP: Step In" })
map("n", "<leader>do", "<cmd>UEAndroidDAPStepOut<cr>", { desc = "DAP: Step Out" })
map("n", "<leader>du", "<cmd>UEAndroidDAPToggleUI<cr>", { desc = "DAP: Toggle UI" })
map("n", "<leader>dr", "<cmd>UEAndroidDAPREPL<cr>", { desc = "DAP: Toggle REPL" })
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
