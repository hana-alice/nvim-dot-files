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
  local layout = require("utils.layout")
  local tab = state.origin_tab or (state.origin_win and vim.api.nvim_win_is_valid(state.origin_win)
    and vim.api.nvim_win_get_tabpage(state.origin_win))
  local session = tab and layout.sync_review(tab)
  local owner = tab and layout.navigation_owner(tab)
  local active_tab = vim.api.nvim_get_current_tabpage()
  cleanup_path(state.chooser_file)
  cleanup_path(state.cwd_file)

  close_window(state.win)
  delete_buffer(state.buf)

  local function origin_unchanged()
    return state.origin_win and vim.api.nvim_win_is_valid(state.origin_win)
      and vim.api.nvim_win_get_tabpage(state.origin_win) == tab
      and vim.api.nvim_win_get_buf(state.origin_win) == state.origin_buf
      and vim.api.nvim_buf_get_changedtick(state.origin_buf) == state.origin_tick
      and vim.deep_equal(vim.api.nvim_win_get_cursor(state.origin_win), state.origin_cursor)
  end

  if chosen and is_file(chosen) and (owner or state.navigation_owner or session or state.review_session) then
    if not owner or (state.navigation_owner and state.navigation_owner ~= owner)
      or (state.review_session and state.review_session ~= session)
      or active_tab ~= tab or vim.api.nvim_get_current_tabpage() ~= tab
      or not origin_unchanged() then
      return vim.notify("Yazi navigation owner is no longer active", vim.log.levels.WARN)
    end
    local handoff = require("utils.layout_handoff")
    local snapshot = handoff.capture(state.origin_win)
    local target = vim.fn.bufadd(chosen)
    local prior = layout.resolve({ tab = tab, source_win = state.origin_win, create = false, route_to_normal = true })
    local prior_snapshot = prior and handoff.capture(prior)
    if prior_snapshot then prior_snapshot.active, prior_snapshot.code = false, true end
    if not handoff.load(snapshot, target, prior_snapshot) then return end
    local win, err = layout.focus({ tab = tab, source_win = state.origin_win })
    if not win then return vim.notify(err, vim.log.levels.WARN) end
    local destination = { win = win, tab = vim.api.nvim_win_get_tabpage(win), buf = target, code = true }
    if not handoff.revalidate(snapshot, { win = win, tab = destination.tab, buf = vim.api.nvim_win_get_buf(win), code = true }) then return end
    destination.tick = vim.api.nvim_buf_get_changedtick(target)
    local ok, _, failure = handoff.handoff(snapshot, destination, function() vim.api.nvim_win_set_buf(win, target) end)
    if not ok then vim.notify(tostring(failure), vim.log.levels.WARN) end
    return
  end

  if state.origin_win and vim.api.nvim_win_is_valid(state.origin_win) then
    pcall(vim.api.nvim_set_current_win, state.origin_win)
  end

  if chosen and is_file(chosen) then
    vim.cmd.edit(vim.fn.fnameescape(chosen))
  elseif code ~= 0 then
    vim.notify("Yazi exited with code " .. code, vim.log.levels.WARN)
    require("utils.log").warn("yazi", "exited with code %d", code)
  end
end

function M.open_current()
  if vim.fn.executable("yazi") ~= 1 then
    require("utils.log").notify_error("yazi", "`yazi` is not available in PATH")
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
    origin_buf = vim.api.nvim_win_get_buf(origin_win),
    origin_cursor = vim.api.nvim_win_get_cursor(origin_win),
    origin_tick = vim.api.nvim_buf_get_changedtick(vim.api.nvim_win_get_buf(origin_win)),
    origin_tab = vim.api.nvim_get_current_tabpage(),
    review_session = require("utils.layout").sync_review(vim.api.nvim_get_current_tabpage()),
    navigation_owner = require("utils.layout").navigation_owner(vim.api.nvim_get_current_tabpage()),
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
    require("utils.log").notify_error("yazi", "Failed to start yazi (termopen returned " .. tostring(jobid) .. ")")
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
