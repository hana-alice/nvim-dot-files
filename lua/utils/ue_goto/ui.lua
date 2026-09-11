-- ue_goto.ui — user-facing visual concerns: notice spinner, try_jump,
-- shader-ext detect.
--
-- Each progress handle owns its window, buffer, and expiry timer.

local jumper = require("utils.ue_goto.jumper")
local location = require("utils.ue_goto.location")

local M = {}

-- Shader file extensions we treat as "no LSP, GTAGS-only".
M.SHADER_EXTS = {
  usf = true, ush = true,
  hlsl = true, hlsli = true,
  glsl = true,
  frag = true, vert = true,
  metal = true, comp = true,
}

-- Filetypes where clangd cannot help and gtags is the primary jumper.
-- Currently shader-only on this platform — see ue.lua FT_GTAGS for why
-- .cs/.py are excluded (Windows GNU Global lacks a self-contained
-- parser for them).
M.NON_CLANGD_EXTS = {
  usf = true, ush = true,
  hlsl = true, hlsli = true,
  glsl = true,
  frag = true, vert = true,
  metal = true, comp = true,
}

function M.buf_extension(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" then return "" end
  return (name:match("%.([^./\\]+)$") or ""):lower()
end

-- Progress is an owned native float. Terminal messages still use vim.notify,
-- so notification backend choice does not affect cancellation ownership.
-- No notification replacement IDs or window discovery are involved.
local DEFAULT_LIFETIME_MS = 8000

local active_notices = {}

local function close_all_definition_bubbles()
  for handle in pairs(active_notices) do handle.clear() end
end

function M.progress_notice(initial_msg)
  local lines = vim.split(tostring(initial_msg or ""), "\n", { plain = true })
  local width = 1
  for _, line in ipairs(lines) do width = math.max(width, vim.fn.strdisplaywidth(line)) end
  width = math.min(width, math.max(1, vim.o.columns - 4))
  local height = math.min(#lines, math.max(1, vim.o.lines - vim.o.cmdheight - 4))
  local buffer = vim.api.nvim_create_buf(false, true)
  vim.bo[buffer].bufhidden = "wipe"
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, lines)
  vim.bo[buffer].modifiable = false
  local ok, window = pcall(vim.api.nvim_open_win, buffer, false, {
    relative = "editor", anchor = "SE", row = math.max(1, vim.o.lines - vim.o.cmdheight - 1),
    col = math.max(1, vim.o.columns - 1), width = width, height = height,
    style = "minimal", border = "rounded", title = "LSP definition",
    focusable = false, noautocmd = true,
  })
  if not ok then window = nil end
  local timer
  local handle = {}
  handle.update = function(_msg) end -- retained compatibility shape
  handle.clear = function()
    active_notices[handle] = nil
    if timer then
      pcall(function() timer:stop(); timer:close() end)
      timer = nil
    end
    if window and vim.api.nvim_win_is_valid(window) then pcall(vim.api.nvim_win_close, window, true) end
    window = nil
    if buffer and vim.api.nvim_buf_is_valid(buffer) then pcall(vim.api.nvim_buf_delete, buffer, { force = true }) end
    buffer = nil
  end
  if window then
    active_notices[handle] = true
    timer = vim.defer_fn(handle.clear, DEFAULT_LIFETIME_MS)
  else
    handle.clear()
  end
  handle.finish = function(msg, lifetime_ms, level)
    handle.clear()
    if msg and msg ~= "" then
      pcall(vim.notify, msg, level or vim.log.levels.INFO, {
        title = "LSP definition", timeout = lifetime_ms or 3000, hide_from_history = false,
      })
    end
  end
  return handle
end

-- Explicit reset closes this module's owned notices only.
M.close_all_definition_bubbles = close_all_definition_bubbles

-- try_jump(locations, title): single-location jump or quickfix.
-- Returns:
--   true         — jumped or quickfix populated
--   false        — empty input or qf was empty
--   "open_failed" — single location resolved but show_document failed
--                   (caller should still treat as terminal — we already
--                   notified — but may want to record stats)
function M.try_jump(locations, title)
  if not locations or #locations == 0 then
    return false
  end
  locations = location.dedup_locations(locations)
  if #locations == 1 then
    local ok = jumper.jump(locations[1])
    if ok then return true end
    vim.notify("LSP location could not be opened: " ..
      tostring(locations[1].uri or locations[1].targetUri), vim.log.levels.WARN)
    return "open_failed"
  end
  return location.populate_quickfix(title, locations) and true or false
end

function M.choose_context(contexts, callback)
  vim.ui.select(contexts, {
    prompt = "Multiple proven contexts resolve differently",
    format_item = function(item)
      local tu = tostring(item.label or vim.fn.fnamemodify(item.origin_tu or "", ":t"))
      local definition = item.definition
      if type(definition) == "table" and definition.path then
        return ("%s  →  %s:%s"):format(tu, vim.fn.fnamemodify(tostring(definition.path), ":t"),
          tostring(definition.line or "?"))
      end
      return tu
    end,
  }, callback)
end

return M
