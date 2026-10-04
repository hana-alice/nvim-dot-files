-- One close owner for keymaps and picker actions. A discard authorizes only
-- the revision shown by confirmation, never input arriving while it waits.
local M = {}
local pending = {}

local function snapshot(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return nil
  end
  return {
    buf = buf,
    name = vim.api.nvim_buf_get_name(buf),
    tick = vim.api.nvim_buf_get_changedtick(buf),
    modified = vim.bo[buf].modified,
    loaded = vim.api.nvim_buf_is_loaded(buf),
  }
end

local function unchanged(before)
  local now = snapshot(before.buf)
  return now
    and now.name == before.name
    and now.tick == before.tick
    and now.modified == before.modified
    and now.loaded == before.loaded
end

local function warn(message)
  vim.notify(message, vim.log.levels.WARN, { title = "关闭缓冲区" })
end

local function changed()
  warn("缓冲区在关闭期间发生变化，已保留，请重新检查。")
  return false
end

local function restore_windows(buf, windows)
  if not vim.api.nvim_buf_is_loaded(buf) then
    return
  end
  for _, item in ipairs(windows) do
    -- A callback may have deliberately chosen another buffer/window. Restore
    -- only a replacement still owned by this close, without taking focus.
    if vim.api.nvim_win_is_valid(item.win) and vim.api.nvim_win_get_buf(item.win) == item.replacement then
      pcall(vim.api.nvim_win_set_buf, item.win, buf)
      if vim.api.nvim_win_is_valid(item.win) and vim.api.nvim_win_get_buf(item.win) == buf then
        pcall(vim.api.nvim_win_call, item.win, function()
          vim.fn.winrestview(item.view)
        end)
      end
    end
  end
end

local function recovery(before, captured)
  local buf = vim.api.nvim_create_buf(false, false)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, captured.lines)
  vim.b[buf].ue_buffer_close_recovery = {
    source_buf = before.buf,
    source_name = before.name,
    observed_name = captured.name,
    event = captured.event,
    original_tick = before.tick,
    recovered_tick = captured.tick,
  }
  vim.bo[buf].buflisted = true
  vim.bo[buf].filetype = captured.filetype
  vim.bo[buf].endofline = captured.endofline
  vim.bo[buf].fileformat = captured.fileformat
  vim.bo[buf].modified = true
  warn(
    ("关闭回调产生了新文本，已保留到未命名缓冲区 #%d；用 Space w M 找回并检查后保存。"):format(
      buf
    )
  )
  return buf
end

local function deletion_guard(before)
  local ids, captured = {}, nil
  local arm
  local function capture(event)
    local now = snapshot(before.buf)
    if now and now.loaded and (now.tick ~= before.tick or now.name ~= before.name) then
      captured = {
        lines = vim.api.nvim_buf_get_lines(before.buf, 0, -1, false),
        name = now.name,
        tick = now.tick,
        event = event,
        filetype = vim.bo[before.buf].filetype,
        endofline = vim.bo[before.buf].endofline,
        fileformat = vim.bo[before.buf].fileformat,
      }
    end
  end
  arm = function(event)
    if ids[event] then
      pcall(vim.api.nvim_del_autocmd, ids[event])
    end
    ids[event] = vim.api.nvim_create_autocmd(event, {
      buffer = before.buf,
      callback = function()
        capture(event)
        -- Buffer listeners detach before BufUnload. Register a tail guard for
        -- each subsequent phase after handlers that the current phase added.
        -- New same-event handlers are not executed by native Neovim this turn.
        if event == "BufUnload" then
          arm("BufDelete")
          arm("BufWipeout")
        elseif event == "BufDelete" then
          arm("BufWipeout")
        end
      end,
    })
  end
  for _, event in ipairs({ "BufUnload", "BufDelete", "BufWipeout" }) do
    arm(event)
  end
  return function()
    for _, id in pairs(ids) do
      pcall(vim.api.nvim_del_autocmd, id)
    end
    return captured
  end
end

local function close_one(opts, before, owned)
  local buf = before.buf
  if not unchanged(before) then
    return changed()
  end
  if before.modified and not opts.force then
    local label = before.name ~= "" and vim.fn.fnamemodify(before.name, ":~:.") or ("[未命名 #" .. buf .. "]")
    local ok, answer =
      pcall(vim.fn.confirm, "保存修改后关闭 " .. label .. "？", "保存 (&y)\n放弃 (&n)\n取消 (&c)", 3)
    if not ok or answer == 0 or answer == 3 then
      return false
    end
    if not unchanged(before) then
      return changed()
    end
    if answer == 1 then
      local wrote, err = pcall(vim.api.nvim_buf_call, buf, function()
        if not unchanged(before) then
          error("保存前缓冲区已变化")
        end
        vim.cmd.write()
      end)
      local saved = snapshot(buf)
      -- Native :write advances changedtick once when clearing 'modified'.
      -- Additional edits (including BufWritePre/Post) require another review.
      if not wrote or not saved or saved.modified then
        warn("保存未完成，缓冲区已保留：" .. tostring(err or "保存后仍有修改"))
        return false
      end
      if saved.name ~= before.name or saved.tick ~= before.tick + 1 or not saved.loaded then
        if saved.loaded then
          -- :write can clear 'modified' after a BufWritePost callback edited
          -- the document. That later revision has not been safely saved.
          vim.bo[buf].modified = true
        end
        return changed()
      end
      before = saved
    elseif answer ~= 2 then
      return false
    end
  end

  local original_hidden = vim.bo[buf].bufhidden
  local function restore()
    if vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].bufhidden == "hide" then
      vim.bo[buf].bufhidden = original_hidden
    end
  end
  owned.restore = restore
  -- A source with bufhidden=wipe/delete/unload must survive replacement events
  -- until this owner has checked their effects. This is local to one operation.
  vim.bo[buf].bufhidden = "hide"
  local windows = {}
  local function abort()
    restore_windows(buf, windows)
    restore()
    return changed()
  end
  if not unchanged(before) then
    return abort()
  end
  local infos = vim.fn.getbufinfo({ buflisted = 1 })
  table.sort(infos, function(a, b)
    return a.lastused > b.lastused
  end)
  local replacement
  for _, info in ipairs(infos) do
    if info.bufnr ~= buf and vim.api.nvim_buf_is_valid(info.bufnr) then
      replacement = info.bufnr
      break
    end
  end
  local wins = vim.fn.win_findbuf(buf)
  if #wins > 0 and not replacement then
    replacement = vim.api.nvim_create_buf(true, false)
  end
  if not unchanged(before) then
    return abort()
  end
  for _, win in ipairs(wins) do
    if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == buf then
      local item = { win = win, replacement = replacement }
      local viewed = pcall(vim.api.nvim_win_call, win, function()
        item.view = vim.fn.winsaveview()
        local alt = vim.fn.bufnr("#")
        if alt > 0 and alt ~= buf and vim.api.nvim_buf_is_valid(alt) and vim.bo[alt].buflisted then
          item.replacement = alt
        end
      end)
      if not viewed or not unchanged(before) then
        return abort()
      end
      windows[#windows + 1] = item
      local switched = pcall(vim.api.nvim_win_set_buf, win, item.replacement)
      if not switched or not unchanged(before) then
        return abort()
      end
    end
  end
  if not unchanged(before) then
    return abort()
  end

  if vim.bo[buf].buftype == "terminal" and vim.bo[buf].channel > 0 then
    local state = vim.fn.jobwait({ vim.bo[buf].channel }, 0)[1]
    if state == -1 then
      -- Unloading a terminal implicitly stops its job. Closing an editor view
      -- must retain that output and lifecycle for Workspace / explicit Stop.
      vim.bo[buf].buflisted = false
      restore()
      return true
    end
  end

  local finish_guard = deletion_guard(before)
  local ok, err = pcall(vim.cmd, (opts.wipe and "bwipeout! " or "bdelete! ") .. buf)
  local captured = finish_guard()
  restore()
  if captured then
    -- Native deletion has already passed its safety check before these events;
    -- never overwrite a recreated buffer/file owner. Retain only new input.
    if not vim.api.nvim_buf_is_loaded(buf) then
      local recovered = recovery(before, captured)
      return false, "recovered", recovered
    end
    return changed()
  end
  if not ok then
    restore_windows(buf, windows)
    warn("无法关闭缓冲区，内容已保留：" .. tostring(err))
    return false
  end
  return true
end

local function run_close(opts, before)
  local buf = before.buf
  if pending[buf] then
    return false
  end
  pending[buf] = true
  local owned = {}
  local ok, result, reason, recovered = pcall(close_one, opts, before, owned)
  if owned.restore then
    pcall(owned.restore)
  end
  pending[buf] = nil
  if not ok then
    warn("关闭未完成，请检查保留的缓冲区：" .. tostring(result))
    return false
  end
  return result, reason, recovered
end

--- Close through the same owner used by Snacks.bufdelete, all/other and pickers.
--- Explicit force authorizes the entry revision; subsequent input stays guarded.
---@param opts? number|table|function
---@return boolean closed, string? reason, integer? recovered_buf
function M.delete(opts)
  opts = opts or {}
  opts = type(opts) == "number" and { buf = opts } or opts
  opts = type(opts) == "function" and { filter = opts } or opts
  if type(opts.filter) == "function" then
    local batch = {}
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.bo[buf].buflisted and opts.filter(buf) then
        batch[#batch + 1] = snapshot(buf)
      end
    end
    for _, before in ipairs(batch) do
      local item = vim.tbl_extend("force", {}, opts, { buf = before.buf, filter = false })
      if not unchanged(before) then
        return changed()
      end
      if not run_close(item, before) then
        -- Cancel or drift ends this explicit batch. Previously closed buffers
        -- stay closed, and remaining documents keep their current revisions.
        return false
      end
    end
    return true
  end
  local buf = opts.file and vim.fn.bufnr(opts.file) or opts.buf or 0
  buf = buf == 0 and vim.api.nvim_get_current_buf() or buf
  local before = snapshot(buf)
  if not before then
    return false
  end
  return run_close(opts, before)
end

return M
