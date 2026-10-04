-- A naming call invokes real BufFilePre/BufFilePost callbacks. Observe only
-- this buffer and this call; revoke before assignment when a callback creates
-- another document revision/name/disk owner. Never suppress native events.
local M = {}
local api = vim.api

local function snapshot(buf)
  if not api.nvim_buf_is_valid(buf) then
    return nil
  end
  return {
    name = api.nvim_buf_get_name(buf),
    tick = api.nvim_buf_get_changedtick(buf),
    loaded = api.nvim_buf_is_loaded(buf),
    modified = vim.bo[buf].modified,
  }
end

local function same(now, before)
  return now
    and now.loaded == before.loaded
    and now.name == before.name
    and now.tick == before.tick
    and now.modified == before.modified
end

function M.rename(before, target, opts)
  opts = opts or {}
  local revoked = false
  local disk_before = opts.disk and opts.disk() or nil
  local function current()
    return same(snapshot(before.buf), before)
      and (not opts.current or opts.current())
      and (not opts.disk or opts.disk() == disk_before)
  end
  if not current() then
    return false, "document-changed-before-name"
  end
  -- Keep this frame (no tail call): the guard belongs only to this exact API
  -- invocation, never to a user's nested setter from either naming event.
  local function assign()
    api.nvim_buf_set_name(before.buf, target)
  end
  -- Registered after existing callbacks. Native Neovim does not execute a
  -- same-event handler newly registered by one of those callbacks this turn.
  local guard = api.nvim_create_autocmd("BufFilePre", {
    buffer = before.buf,
    callback = function()
      local native, owner = debug.getinfo(2, "f"), debug.getinfo(3, "f")
      if not native or native.func ~= api.nvim_buf_set_name or not owner or owner.func ~= assign then
        return
      end
      if not current() then
        revoked = true
        error("file mutation: document changed during native naming", 0)
      end
    end,
  })
  local ok, err = pcall(assign)
  pcall(api.nvim_del_autocmd, guard)
  if not ok then
    return false, revoked and "document-changed-during-name" or ("buffer-name: " .. tostring(err))
  end
  local after = snapshot(before.buf)
  local named = after
    and (
      target == "" and after.name == ""
      or target ~= ""
        and (opts.same_path and opts.same_path(after.name, target) or not opts.same_path and after.name == target)
    )
  if
    not after
    or not named
    or after.tick ~= before.tick
    or after.modified ~= before.modified
    or after.loaded ~= before.loaded
    or opts.current and not opts.current()
  then
    -- BufFilePost has already happened. Its newer input/name remains intact.
    return false, "document-changed-after-name"
  end
  return true
end

return M
