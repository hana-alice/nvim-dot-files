local uv = vim.uv or vim.loop

local M = {
  state = nil,
}

local function stat(path)
  if type(path) ~= "string" or path == "" then
    return nil
  end
  return uv.fs_stat(path)
end

local function is_file(path)
  local info = stat(path)
  return info and info.type == "file" or false
end

local function is_dir(path)
  local info = stat(path)
  return info and info.type == "directory" or false
end

local function normalize(path)
  return vim.fs.normalize(path)
end

local function first_path(path)
  if not is_file(path) then
    return nil
  end
  for line in io.lines(path) do
    line = vim.trim(line)
    if line ~= "" then
      return normalize(line)
    end
  end
end

local function cleanup_path(path)
  if type(path) == "string" and path ~= "" then
    pcall(vim.fn.delete, path)
  end
end

local function current_entry()
  local name = vim.api.nvim_buf_get_name(0)
  if is_file(name) then
    name = normalize(name)
    return name, vim.fs.dirname(name)
  end
  if is_dir(name) then
    name = normalize(name)
    return name, name
  end

  local dir = vim.fn.expand("%:p:h")
  if dir == "" or not is_dir(dir) then
    dir = vim.fn.getcwd()
  end
  dir = normalize(dir)
  return dir, dir
end

local function float_config()
  local width = math.max(80, math.floor(vim.o.columns * 0.94))
  local height = math.max(20, math.floor(vim.o.lines * 0.92))
  return {
    relative = "editor",
    border = "rounded",
    style = "minimal",
    width = width,
    height = height,
    row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
  }
end

local function clear_state()
  M.state = nil
end

local function close_window(win)
  if win and vim.api.nvim_win_is_valid(win) then
    pcall(vim.api.nvim_win_close, win, true)
  end
end

local function delete_buffer(buf)
  if buf and vim.api.nvim_buf_is_valid(buf) then
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end
end

local function finish(code)
  local state = M.state
  clear_state()
  if not state then
    return
  end

  local chosen = first_path(state.chooser_file)
  cleanup_path(state.chooser_file)
  cleanup_path(state.cwd_file)

  close_window(state.win)
  delete_buffer(state.buf)

  if state.origin_win and vim.api.nvim_win_is_valid(state.origin_win) then
    pcall(vim.api.nvim_set_current_win, state.origin_win)
  end

  if chosen and is_file(chosen) then
    vim.cmd.edit(vim.fn.fnameescape(chosen))
  elseif code ~= 0 then
    vim.notify("Yazi exited with code " .. code, vim.log.levels.WARN)
  end
end

function M.open_current()
  if vim.fn.executable("yazi") ~= 1 then
    vim.notify("`yazi` is not available in PATH", vim.log.levels.ERROR)
    return
  end

  if M.state and M.state.win and vim.api.nvim_win_is_valid(M.state.win) then
    vim.api.nvim_set_current_win(M.state.win)
    vim.cmd.startinsert()
    return
  end

  local entry, cwd = current_entry()
  local chooser_file = vim.fn.tempname()
  local cwd_file = vim.fn.tempname()
  local origin_win = vim.api.nvim_get_current_win()

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "yazi"

  local win = vim.api.nvim_open_win(buf, true, float_config())
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].statuscolumn = ""
  vim.wo[win].cursorline = false

  M.state = {
    buf = buf,
    win = win,
    chooser_file = chooser_file,
    cwd_file = cwd_file,
    origin_win = origin_win,
  }

  local cmd = { "yazi", "--chooser-file", chooser_file, "--cwd-file", cwd_file, entry }

  -- yazi needs `file` for MIME detection. On Windows it ships with Git.
  local git_usr_bin = "C:\\Program Files\\Git\\usr\\bin"
  local path_patched = false
  if vim.fn.isdirectory(git_usr_bin) == 1 then
    local cur = vim.env.PATH or ""
    if not cur:find(git_usr_bin, 1, true) then
      vim.env.PATH = git_usr_bin .. ";" .. cur
      path_patched = true
    end
  end

  local jobid = vim.fn.termopen(cmd, {
    cwd = cwd,
    on_exit = function(_, code)
      vim.schedule(function()
        finish(code)
      end)
    end,
  })

  if jobid <= 0 then
    cleanup_path(chooser_file)
    cleanup_path(cwd_file)
    clear_state()
    close_window(win)
    delete_buffer(buf)
    vim.notify("Failed to start yazi", vim.log.levels.ERROR)
    return
  end

  M.state.jobid = jobid

  vim.keymap.set("t", "<Esc>", function()
    if M.state and M.state.jobid then
      vim.api.nvim_chan_send(M.state.jobid, "\27")
    end
  end, { buffer = buf, nowait = true, silent = true, desc = "Yazi: Send Escape" })

  vim.cmd.startinsert()
end

return M
