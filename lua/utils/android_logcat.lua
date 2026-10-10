-- utils.android_logcat — make a logcat buffer usable from the keyboard.
--
-- Attached to the DAP logcat buffer: severity highlighting, <CR> to jump to a
-- source location mentioned on the line, `gl` to cycle the minimum level, and
-- `gx` to symbolicate the latest native crash. No timers; highlights are
-- window-local matches and the level filter is applied by adb itself.

local M = {}

M.levels = { "V", "D", "I", "W", "E" }

--- Next minimum level in the V → D → I → W → E → V cycle.
function M.next_level(level)
  for index, name in ipairs(M.levels) do
    if name == level then return M.levels[index % #M.levels + 1] end
  end
  return "I"
end

--- adb logcat filterspec for a minimum level ("V" means no filter).
function M.filter_args(level)
  if not level or level == "V" then return {} end
  return { "*:" .. level }
end

--- Severity letter of a `threadtime` logcat line, or nil.
function M.line_level(line)
  return tostring(line or ""):match("^%d%d%-%d%d%s+[%d:%.]+%s+%d+%s+%d+%s+(%u)%s")
end

--- Source location mentioned on a log line. Recognises UE's
--- `[File:<path>] [Line: <n>]` and plain `<path>.<ext>:<n>` / `<path>.<ext>(<n>)`.
---@return string|nil path, integer|nil line
function M.parse_location(line)
  line = tostring(line or "")
  local file, lnum = line:match("%[File:([^%]]+)%]%s*%[Line:%s*(%d+)%]")
  if not file then
    file, lnum = line:match("([%w_%-%./\\:]+%.[chm]p?p?):(%d+)")
  end
  if not file then
    file, lnum = line:match("([%w_%-%./\\:]+%.[chm]p?p?)%((%d+)%)")
  end
  if not file then return nil end
  return file, tonumber(lnum)
end

local function jump(buf)
  local file, lnum = M.parse_location(vim.api.nvim_get_current_line())
  if not file then
    return vim.notify("No source location on this line", vim.log.levels.INFO)
  end
  local path = vim.fs.normalize(file)
  if vim.fn.filereadable(path) ~= 1 then
    -- Relative engine/project paths: let the project file search resolve it.
    local found = vim.fn.findfile(vim.fs.basename(path), vim.fn.getcwd() .. "/**")
    if found == "" then
      return vim.notify("Source not found on this host: " .. file, vim.log.levels.WARN)
    end
    path = found
  end
  -- Leave the log window in place; open the source in the previous window.
  vim.cmd("wincmd p")
  if vim.api.nvim_get_current_buf() == buf then vim.cmd("aboveleft split") end
  vim.cmd("edit " .. vim.fn.fnameescape(path))
  pcall(vim.api.nvim_win_set_cursor, 0, { lnum or 1, 0 })
end

--- Attach keys and highlights. opts.level: current minimum level;
--- opts.on_cycle(next_level): restart the reader with the new level.
function M.attach(buf, opts)
  opts = opts or {}
  require("utils.bottom_panel").register("logcat", buf)
  local map = function(lhs, rhs, desc)
    vim.keymap.set("n", lhs, rhs, { buffer = buf, nowait = true, silent = true, desc = desc })
  end
  map("<CR>", function() jump(buf) end, "Logcat: jump to source location on this line")
  map("gl", function()
    local nxt = M.next_level(opts.level or "V")
    vim.notify("logcat minimum level: " .. nxt, vim.log.levels.INFO)
    if opts.on_cycle then opts.on_cycle(nxt) end
  end, "Logcat: cycle minimum level")
  map("gx", "<cmd>UEAndroidCrash<cr>", "Logcat: symbolicate latest native crash")
  -- Buffer-local syntax (not window matches): the debug panel window is shared
  -- with the REPL/console buffers, which must not inherit these highlights.
  vim.api.nvim_buf_call(buf, function()
    local head = [[^\d\d-\d\d\s\+[0-9:.]\+\s\+\d\+\s\+\d\+\s\+]]
    vim.cmd("syntax match UELogcatError /" .. head .. [[[EF]\s.*/]])
    vim.cmd("syntax match UELogcatWarn /" .. head .. [[W\s.*/]])
    vim.cmd("highlight default link UELogcatError DiagnosticError")
    vim.cmd("highlight default link UELogcatWarn DiagnosticWarn")
  end)
end

return M
