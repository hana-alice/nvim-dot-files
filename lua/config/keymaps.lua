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

map("n", "gd", function()
  require("utils.lsp_fallback").definition()
end, { desc = "Definition (LSP -> GTAGS)" })
map("n", "gr", function()
  require("utils.lsp_fallback").references()
end, { desc = "References (LSP -> GTAGS)" })
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
map("n", "<leader>bn", "<cmd>confirm enew<cr>", { desc = "Buffer: New empty buffer" })
map("n", "<leader>ub", "<cmd>UEBuildAndroid<cr>", { desc = "UE: Build Android Development" })
map("n", "<leader>uB", "<cmd>UEPrepare<cr>", { desc = "UE: Prepare symbols + compile_commands" })
map("n", "<leader>uc", "<cmd>UEExportCompileCommands<cr>", { desc = "UE: Export compile_commands" })
map("n", "<leader>up", "<cmd>UEPaths<cr>", { desc = "UE: Show paths" })
map("n", "<leader>uP", "<cmd>UESetProject<cr>", { desc = "UE: Set project" })
map("n", "<leader>ut", "<cmd>ThemePicker<cr>", { desc = "UI: Theme picker" })
map("n", "<leader>?", "<cmd>UECheatsheet<cr>", { desc = "UE: Cheatsheet" })

-- Android DAP keymaps
map("n", "<leader>da", "<cmd>UEAndroidDAPAttach<cr>", { desc = "DAP: Android Attach" })
map("n", "<F5>", "<cmd>UEAndroidDAPContinue<cr>", { desc = "DAP: Continue" })
map("n", "<F6>", "<cmd>UEAndroidDAPPause<cr>", { desc = "DAP: Pause" })
map("n", "<F9>", "<cmd>UEAndroidDAPToggleBreakpoint<cr>", { desc = "DAP: Toggle Breakpoint" })
map("n", "<F10>", "<cmd>UEAndroidDAPStepOver<cr>", { desc = "DAP: Step Over" })
map("n", "<leader>di", "<cmd>UEAndroidDAPStepIn<cr>", { desc = "DAP: Step In" })
map("n", "<leader>do", "<cmd>UEAndroidDAPStepOut<cr>", { desc = "DAP: Step Out" })
map("n", "<leader>du", "<cmd>UEAndroidDAPToggleUI<cr>", { desc = "DAP: Toggle UI" })
map("n", "<leader>dr", "<cmd>UEAndroidDAPREPL<cr>", { desc = "DAP: Toggle REPL" })
map("n", "<leader>dR", "<cmd>UEResetLayout<cr>", { desc = "Reset Layout (DAP or default)" })
