-- Terminal: Esc to normal mode
vim.keymap.set("t", "<Esc>", [[<C-\><C-n>]], { desc = "Exit terminal mode" })

-- Toggle terminal (single instance), hide by closing window, reuse buffer
local term_buf = nil
local term_win = nil

vim.keymap.set("n", "<leader>tt", function()
  -- 1) 如果终端窗口存在：隐藏（关闭窗口即可，保留 buffer）
  if term_win and vim.api.nvim_win_is_valid(term_win) then
    vim.api.nvim_win_close(term_win, true)
    term_win = nil
    return
  end

  -- 2) 打开（或复用）终端 buffer 到底部分屏
  if not term_buf or not vim.api.nvim_buf_is_valid(term_buf) then
    vim.cmd("botright split | resize 15 | terminal pwsh")
    term_win = vim.api.nvim_get_current_win()
    term_buf = vim.api.nvim_get_current_buf()
  else
    vim.cmd("botright split | resize 15")
    term_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(term_win, term_buf)
  end

  -- 3) 每次显示出来都进入输入模式（满足你“再次打开直接可输命令”）
  vim.cmd("startinsert")

  -- 4) no implicit cd here (pure toggle)
end, { desc = "Terminal: Toggle (pwsh, reuse buffer)" })

-- Back-compat (no cheatsheet entry)
vim.keymap.set("n", "<leader>t", "<leader>tt", { remap = true, silent = true })


-- Ensure terminal window is visible (reuse the same terminal buffer).
-- Unlike <leader>t toggle, this will OPEN if hidden but will NOT close it.
local function ensure_terminal_visible()
  if term_win and vim.api.nvim_win_is_valid(term_win) then
    return term_buf, term_win
  end

  if not term_buf or not vim.api.nvim_buf_is_valid(term_buf) then
    vim.cmd("botright split | resize 15 | terminal pwsh")
    term_win = vim.api.nvim_get_current_win()
    term_buf = vim.api.nvim_get_current_buf()
  else
    vim.cmd("botright split | resize 15")
    term_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(term_win, term_buf)
  end

  vim.cmd("startinsert")
  return term_buf, term_win
end



-- Terminal: explicit cd helpers (no :cd / :lcd)
local function term_send_line(line)
  -- ensure terminal exists and get into its buffer
  local buf, win = ensure_terminal_visible()
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    vim.notify("Terminal not available", vim.log.levels.WARN)
    return
  end
  -- terminal_job_id is buffer-local; make sure we're in that buffer
  vim.api.nvim_set_current_win(win)
  if not vim.b.terminal_job_id then
    vim.notify("Terminal job not ready", vim.log.levels.WARN)
    return
  end
  vim.fn.chansend(vim.b.terminal_job_id, line .. "\r\n")
end

local function term_cd(dir)
  if not dir or dir == "" then return end
  term_send_line('cd "' .. dir .. '"')
end

vim.keymap.set("n", "<leader>tc", function()
  -- cd terminal to current file dir (explicit, not automatic)
  local dir = vim.fn.expand("%:p:h")
  if not dir or dir == "" then
    vim.notify("No current file directory", vim.log.levels.WARN)
    return
  end
  term_cd(dir)
end, { desc = "Terminal: cd to current file dir" })

vim.keymap.set("n", "<leader>tp", function()
  -- cd terminal to UE project root (STRICT: cwd must contain .uproject)
  local cwd = vim.loop.cwd()
  local up = nil
  if type(require("ue").find_nearest_uproject) == "function" then
    up = require("ue").find_nearest_uproject(cwd)
  else
    local matches = vim.fn.globpath(cwd, "*.uproject", false, true)
    if type(matches) == "table" and #matches > 0 then up = matches[1] end
  end
  if not up then
    vim.notify("No .uproject in cwd (your rule: no upward search). :cd to the .uproject dir first.", vim.log.levels.WARN)
    return
  end
  term_cd(cwd)
end, { desc = "Terminal: cd to UE project root (cwd)" })

vim.keymap.set("n", "<leader>te", function()
  -- cd terminal to UE engine root (requires require("ue").ue_roots() to succeed)
  if type(_G.ue_roots) ~= "function" then
    vim.notify('require("ue").ue_roots() not available', vim.log.levels.WARN)
    return
  end
  local project_root, engine_root, err = require("ue").ue_roots()
  if err or not engine_root or engine_root == "" then
    vim.notify("UE engine root not detected. Ensure cwd is .uproject dir.", vim.log.levels.WARN)
    return
  end
  term_cd(engine_root)
end, { desc = "Terminal: cd to UE engine root" })

-- Keymaps
local map = vim.keymap.set

-- ========== Git keymaps ==========
-- Status / UI
map("n", "<leader>gg", "<cmd>Git<cr>", { desc = "Git: status (fugitive)" })
map("n", "<leader>gl", function()
  -- Open LazyGit in a large floating terminal.
  -- If this is a UE project (require("ue").ue_roots() works), prefer engine_root as the starting directory.
  -- Then resolve the actual git toplevel from that directory; if not a git repo, fallback to nvim cwd git root.
  local function git_root(dir)
    if not dir or dir == "" then return nil end
    local out = vim.fn.systemlist({ "git", "-C", dir, "rev-parse", "--show-toplevel" })
    if vim.v.shell_error ~= 0 or not out or not out[1] or out[1] == "" then
      return nil
    end
    return out[1]
  end

  local start_dir = vim.loop.cwd()
  if type(_G.ue_roots) == "function" then
    local pr, er, err = require("ue").ue_roots()
    if not err and er and er ~= "" then
      start_dir = er
    elseif not err and pr and pr ~= "" then
      start_dir = pr
    end
  end

  local repo = git_root(start_dir) or git_root(vim.loop.cwd())
  if not repo then
    vim.notify("LazyGit: 当前目录与引擎目录都不是 git repo（找不到 .git）。", vim.log.levels.WARN)
    return
  end

  -- Create floating window
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "lazygit"

  local ui = vim.api.nvim_list_uis()[1]
  local width = math.floor(ui.width * 0.90)
  local height = math.floor(ui.height * 0.90)
  local row = math.floor((ui.height - height) / 2)
  local col = math.floor((ui.width - width) / 2)

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row = row,
    col = col,
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
  })

  -- Close helpers
  local function close()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end

  vim.keymap.set("n", "q", close, { buffer = buf, nowait = true, silent = true })
  vim.keymap.set("n", "<Esc>", close, { buffer = buf, nowait = true, silent = true })

  -- Start lazygit with explicit cwd=repo
  local job = vim.fn.termopen({ "lazygit" }, {
    cwd = repo,
    on_exit = function()
      vim.schedule(close)
    end,
  })

  if job <= 0 then
    vim.notify("LazyGit: termopen failed (is lazygit in PATH?)", vim.log.levels.ERROR)
    close()
    return
  end

  -- terminal mode mappings
  vim.cmd("startinsert")
  vim.keymap.set("t", "<Esc>", [[<C-\><C-n>]], { buffer = buf, silent = true })
end, { desc = "Git: LazyGit (float, UE->engine root, resolve git root)" })
map("n", "<leader>gD", "<cmd>DiffviewOpen<cr>", { desc = "Git: Diffview open" })
map("n", "<leader>gq", "<cmd>DiffviewClose<cr>", { desc = "Git: Diffview close" })
map("n", "<leader>gF", "<cmd>DiffviewFileHistory %<cr>", { desc = "Git: File history (current)" })
map("n", "<leader>gH", "<cmd>DiffviewFileHistory<cr>", { desc = "Git: Repo history" })

-- Gitsigns (hunks/blame)
map("n", "]c", function()
  local gs = package.loaded.gitsigns
  if gs then gs.next_hunk() end
end, { desc = "Git: next hunk" })

map("n", "[c", function()
  local gs = package.loaded.gitsigns
  if gs then gs.prev_hunk() end
end, { desc = "Git: prev hunk" })

map({ "n", "v" }, "<leader>hs", function()
  local gs = package.loaded.gitsigns
  if not gs then return end
  local m = vim.fn.mode()
  if m == "v" or m == "V" or m == "\22" then
    gs.stage_hunk({ vim.fn.line("."), vim.fn.line("v") })
  else
    gs.stage_hunk()
  end
end, { desc = "Git: stage hunk" })

map({ "n", "v" }, "<leader>hr", function()
  local gs = package.loaded.gitsigns
  if not gs then return end
  local m = vim.fn.mode()
  if m == "v" or m == "V" or m == "\22" then
    gs.reset_hunk({ vim.fn.line("."), vim.fn.line("v") })
  else
    gs.reset_hunk()
  end
end, { desc = "Git: reset hunk" })

map("n", "<leader>hp", function()
  local gs = package.loaded.gitsigns
  if gs then gs.preview_hunk() end
end, { desc = "Git: preview hunk" })

map("n", "<leader>hb", function()
  local gs = package.loaded.gitsigns
  if gs then gs.blame_line({ full = true }) end
end, { desc = "Git: blame line (full)" })

map("n", "<leader>hB", function()
  local gs = package.loaded.gitsigns
  if gs then gs.toggle_current_line_blame() end
end, { desc = "Git: toggle inline blame" })

map("n", "<leader>hd", function()
  local gs = package.loaded.gitsigns
  if gs then gs.diffthis() end
end, { desc = "Git: diff this" })

map("n", "<leader>hD", function()
  local gs = package.loaded.gitsigns
  if gs then gs.diffthis("~") end
end, { desc = "Git: diff this (against ~)" })

-- LSP keymaps (set on attach later)
-- ========== Completion ==========
local cmp = require("cmp")

-- Session helpers
vim.keymap.set("n", "<leader>ss", "<cmd>SessionSave<cr>", { desc = "Session: Save" })
vim.keymap.set("n", "<leader>sr", "<cmd>SessionRestore<cr>", { desc = "Session: Restore (cwd)" })
vim.keymap.set("n", "<leader>sd", "<cmd>SessionDelete<cr>", { desc = "Session: Delete (cwd)" })
vim.keymap.set("n", "<leader>sf", "<cmd>SessionSearch<cr>", { desc = "Session: Search" })
