-- Native existing-buffer bookkeeping clears the first-write guard without a
-- reread. Only its hidden presentation suppresses events; real naming does not.
local M = {}
local api = vim.api

local function document(before)
  return api.nvim_buf_is_valid(before.buf)
    and api.nvim_buf_is_loaded(before.buf)
    and api.nvim_buf_get_name(before.buf) == before.name
    and api.nvim_buf_get_changedtick(before.buf) == before.tick
    and vim.bo[before.buf].modified == before.modified
end

local function windows()
  local result = {}
  for _, win in ipairs(api.nvim_list_wins()) do
    result[win] = {
      buf = api.nvim_win_get_buf(win),
      tab = api.nvim_win_get_tabpage(win),
      width = api.nvim_win_get_width(win),
      height = api.nvim_win_get_height(win),
    }
  end
  return result
end

function M.refresh(before, opts)
  opts = opts or {}
  if not before.loaded then
    return true
  end
  local disk = opts.disk and opts.disk() or nil
  local function current()
    return document(before)
      and (not opts.current or opts.current())
      and (not opts.disk or opts.disk() == disk and (not opts.expected or disk == opts.expected))
  end
  if not current() then
    return false, "metadata-document-changed"
  end
  local baseline, origin = windows(), api.nvim_get_current_win()
  local context = baseline
  local float, file_win
  local native_ok, native_err, closed_file, closed_float
  local function close_command()
    local command = { cmd = "close", mods = { noautocmd = true, keepalt = true, keepjumps = true } }
    api.nvim_cmd(command, {})
  end
  local function close_owned(win)
    if not win or not api.nvim_win_is_valid(win) then
      return true
    end
    if context[win] or api.nvim_win_get_buf(win) ~= before.buf or not current() then
      return false
    end
    local ok = pcall(api.nvim_win_call, win, close_command)
    return ok and not api.nvim_win_is_valid(win)
  end
  -- The native buffer context keeps a truly hidden wipe-on-hide document alive
  -- until both owned windows are closed, without changing its hide policy.
  local ok, err = pcall(api.nvim_buf_call, before.buf, function()
    context = windows()
    native_ok, native_err = pcall(function()
      float = api.nvim_open_win(before.buf, false, {
        relative = "editor",
        row = 0,
        col = 0,
        width = 1,
        height = 1,
        style = "minimal",
        hide = true,
        noautocmd = true,
      })
      api.nvim_win_call(float, function()
        local command = {
          cmd = "split",
          args = { before.name },
          magic = { file = false, bar = false },
          mods = {
            tab = api.nvim_tabpage_get_number(0),
            keepalt = true,
            keepjumps = true,
            noautocmd = true,
          },
        }
        api.nvim_cmd(command, {})
        file_win = api.nvim_get_current_win()
        assert(
          not context[file_win] and file_win ~= float and api.nvim_win_get_buf(file_win) == before.buf and current(),
          "metadata owner changed"
        )
        close_command()
        assert(not api.nvim_win_is_valid(file_win), "metadata window still open")
      end)
    end)
    -- A native failure may occur after creating the single file-step window.
    -- Recover only that new source window; user and aucmd handles are not ours.
    if not native_ok and not file_win then
      local candidate
      for _, win in ipairs(api.nvim_list_wins()) do
        if not context[win] and win ~= float then
          if candidate then
            candidate = nil
            break
          end
          candidate = win
        end
      end
      file_win = candidate
    end
    closed_file = close_owned(file_win)
    closed_float = close_owned(float)
  end)
  if not ok then
    return false, "metadata-native: " .. tostring(err)
  end
  if not native_ok then
    return false, "metadata-native: " .. tostring(native_err)
  end
  if not closed_file or not closed_float or not current() or api.nvim_get_current_win() ~= origin then
    return false, "metadata-requires-review"
  end
  local after = windows()
  if not vim.deep_equal(baseline, after) then
    return false, "metadata-requires-review"
  end
  return true
end

return M
