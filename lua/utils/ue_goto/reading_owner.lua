-- Owners for explicit reading actions. No compiler selection, global LSP
-- handlers, cursor restoration hooks, or background polling live here.
local M = {}
local epoch, active = 0, nil
local uv = vim.uv or vim.loop

local function path_identity(path)
  if type(path) ~= "string" or path == "" then
    return ""
  end
  return vim.fs.normalize(uv.fs_realpath(path) or path)
end

local function file_signature(path)
  if type(path) ~= "string" or path == "" then
    return nil
  end
  local stat = uv.fs_stat(path)
  return {
    path = path_identity(path),
    size = stat and stat.size,
    sec = stat and stat.mtime and stat.mtime.sec,
    nsec = stat and stat.mtime and stat.mtime.nsec,
  }
end

function M.context(buf)
  local ok, ue = pcall(require, "ue")
  if not ok or type(ue.resolve_context) ~= "function" then
    return nil, {}
  end
  local resolved, ctx = pcall(ue.resolve_context, { bufname = vim.api.nvim_buf_get_name(buf) })
  if not resolved or type(ctx) ~= "table" then
    return nil, {}
  end
  local state, paths = ctx.state or {}, ctx.paths or {}
  local candidates = { paths.active_cdb }
  local ok_paths, cdb_paths = pcall(require, "ue.cdb.paths")
  if ok_paths then
    local ok_targets, targets = pcall(cdb_paths.targets, ctx)
    if ok_targets then
      vim.list_extend(candidates, targets)
    end
  end
  local ok_shards, shards = pcall(require, "ue.cdb.shards")
  if ok_shards then
    local ok_dir, dir = pcall(shards.shards_dir, ctx)
    if ok_dir and type(dir) == "string" then
      candidates[#candidates + 1] = vim.fs.joinpath(dir, "manifest.json")
    end
  end
  local files, seen = {}, {}
  for _, path in ipairs(candidates) do
    if path and not seen[path] then
      seen[path] = true
      files[#files + 1] = file_signature(path)
    end
  end
  local stamp = {
    project = path_identity(ctx.project_root),
    engine = path_identity(ctx.engine_root),
    uproject = path_identity(ctx.uproject),
    platform = state.target_platform,
    configuration = state.target_configuration,
    target = state.target or state.target_name,
    active = file_signature(paths.active_cdb),
    manifest = file_signature(paths.cdb_shards_dir and vim.fs.joinpath(paths.cdb_shards_dir, "manifest.json")),
    state = file_signature(paths.state),
    compiler_inputs = files,
  }
  return ctx, stamp
end

local function client_set(buf)
  local result = {}
  for _, client in ipairs(vim.lsp.get_clients({ bufnr = buf })) do
    result[client.id] = client
  end
  return result
end

function M.cancel()
  epoch = epoch + 1
  local previous = active
  active = nil
  if not previous then
    return
  end
  previous.cancelled = true
  local cleanups = previous.cleanups
  previous.cleanups = {}
  for _, cleanup in ipairs(cleanups) do
    pcall(cleanup)
  end
  for _, id in ipairs(previous.autocmds) do
    pcall(vim.api.nvim_del_autocmd, id)
  end
  if previous.picker and not previous.picker.closed then
    pcall(previous.picker.close, previous.picker)
  end
end

function M.focused(owner)
  local win = vim.api.nvim_get_current_win()
  if win == owner.win and vim.api.nvim_get_current_tabpage() == owner.tab then
    return true
  end
  local picker = owner.picker
  return picker
      and not picker.closed
      and picker.main == owner.win
      and picker.current_win
      and picker:current_win() ~= nil
    or false
end

function M.valid(owner)
  if not owner or owner.cancelled or active ~= owner or owner.epoch ~= epoch then
    return false
  end
  if
    not vim.api.nvim_win_is_valid(owner.win)
    or not vim.api.nvim_buf_is_valid(owner.buf)
    or vim.api.nvim_win_get_tabpage(owner.win) ~= owner.tab
    or vim.api.nvim_win_get_buf(owner.win) ~= owner.buf
    or vim.api.nvim_buf_get_name(owner.buf) ~= owner.path
    or vim.api.nvim_buf_get_changedtick(owner.buf) ~= owner.tick
    or not vim.deep_equal(vim.api.nvim_win_get_cursor(owner.win), owner.cursor)
  then
    return false
  end
  local _, stamp = M.context(owner.buf)
  if not vim.deep_equal(stamp, owner.build) then
    return false
  end
  local clients = client_set(owner.buf)
  if vim.tbl_count(clients) ~= vim.tbl_count(owner.clients) then
    return false
  end
  for id, client in pairs(owner.clients) do
    if clients[id] ~= client or client.offset_encoding ~= owner.encodings[id] then
      return false
    end
  end
  return true
end

function M.current(owner, allow_picker)
  if not M.valid(owner) then
    return false
  end
  return allow_picker and (owner.presenting or owner.handoff or M.focused(owner))
    or (vim.api.nvim_get_current_win() == owner.win and vim.api.nvim_get_current_tabpage() == owner.tab)
end

function M.add_cleanup(owner, cleanup)
  owner.cleanups[#owner.cleanups + 1] = cleanup
  return function()
    for index, value in ipairs(owner.cleanups) do
      if value == cleanup then
        table.remove(owner.cleanups, index)
        break
      end
    end
  end
end

function M.begin()
  M.cancel()
  local buf, win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
  local ctx, build = M.context(buf)
  local cursor = vim.api.nvim_win_get_cursor(win)
  local owner = {
    epoch = epoch,
    win = win,
    buf = buf,
    tab = vim.api.nvim_get_current_tabpage(),
    path = vim.api.nvim_buf_get_name(buf),
    tick = vim.api.nvim_buf_get_changedtick(buf),
    cursor = cursor,
    context = ctx and vim.deepcopy(ctx),
    build = build,
    clients = client_set(buf),
    cleanups = {},
    autocmds = {},
    view = vim.fn.winsaveview(),
  }
  owner.encodings = {}
  for id, client in pairs(owner.clients) do
    owner.encodings[id] = client.offset_encoding
  end
  owner.subject = {
    bufnr = buf,
    path = owner.path,
    uri = vim.uri_from_bufnr(buf),
    line0 = cursor[1] - 1,
    column0 = cursor[2],
    line_text = vim.api.nvim_buf_get_lines(buf, cursor[1] - 1, cursor[1], false)[1],
    document_version = owner.tick,
    changedtick = owner.tick,
  }
  active = owner
  local function focus_changed()
    if active == owner and not owner.presenting and not owner.handoff and not M.current(owner, true) then
      M.cancel()
    end
  end
  owner.autocmds[#owner.autocmds + 1] = vim.api.nvim_create_autocmd({ "WinEnter", "TabEnter", "BufEnter" }, {
    callback = focus_changed,
    desc = "Reject reading responses after a new window or buffer intent",
  })
  owner.autocmds[#owner.autocmds + 1] = vim.api.nvim_create_autocmd(
    { "CursorMoved", "CursorMovedI", "TextChanged", "TextChangedI" },
    {
      buffer = buf,
      callback = function()
        if
          active == owner
          and not owner.presenting
          and (vim.api.nvim_get_current_win() == owner.win or vim.api.nvim_buf_get_changedtick(buf) ~= owner.tick)
        then
          focus_changed()
        end
      end,
      desc = "Invalidate reading actions when their source changes",
    }
  )
  return owner
end

function M.present(owner, create)
  if not M.current(owner, true) then
    return nil
  end
  owner.presenting = true
  local ok, picker = pcall(create)
  owner.presenting = false
  if not ok then
    M.cancel()
    error(picker)
  end
  owner.picker = picker
  return picker
end

-- Closing an owned UI is a transition, not completion. Keep the intent and
-- source snapshot alive until close callbacks have run and are checked again.
function M.close_picker(owner, picker)
  if not M.current(owner, true) then
    return false
  end
  picker = picker or owner.picker
  owner.handoff = true
  local ok = not picker or picker.closed or pcall(picker.close, picker)
  owner.handoff = false
  if not ok or not M.current(owner) then
    if active == owner then
      M.cancel()
    end
    return false
  end
  owner.picker = nil
  return true
end

function M.picker_closed(owner, picker)
  -- Snacks calls on_close before setting picker.closed. Detach first so
  -- cancellation cannot recursively call close on the same picker.
  if owner.picker == picker then
    owner.picker = nil
  end
  if active == owner and not owner.handoff then
    M.cancel()
  end
end

function M.confirm_picker(owner, picker, callback)
  if not M.current(owner, true) then
    return false
  end
  if vim.fn.mode():sub(1, 1) == "i" then
    vim.cmd.stopinsert()
    vim.schedule(function()
      if M.current(owner, true) then
        M.confirm_picker(owner, picker, callback)
      end
    end)
    return true
  end
  if not M.close_picker(owner, picker) then
    return false
  end
  if M.current(owner) then
    callback()
    return true
  end
  return false
end

function M.request(owner, client, method, params, callback)
  if not M.current(owner, true) then
    return false
  end
  local done, timer, remove, request_id = false, nil, nil, nil
  local function finish(err, result)
    if done then
      return
    end
    done = true
    if timer and not timer:is_closing() then
      timer:stop()
      timer:close()
    end
    if remove then
      remove()
    end
    vim.schedule(function()
      if M.current(owner, true) then
        callback(err, result)
      end
    end)
  end
  local function cancel()
    if done then
      return false
    end
    done = true
    if timer and not timer:is_closing() then
      timer:stop()
      timer:close()
    end
    if remove then
      remove()
    end
    if request_id and client.cancel_request then
      pcall(client.cancel_request, client, request_id)
    end
    return true
  end
  local ok, accepted, id = pcall(client.request, client, method, params, finish, owner.buf)
  if not ok or accepted == false then
    finish({ message = "无法发送 " .. method })
    return false
  end
  request_id = id
  if not done then
    remove = M.add_cleanup(owner, cancel)
    timer = vim.defer_fn(function()
      if request_id and client.cancel_request then
        pcall(client.cancel_request, client, request_id)
      end
      finish({ message = "请求超时（覆盖未知）" })
    end, 30000)
  end
  return true, cancel
end

function M.active()
  return active
end

return M
