-- utils.log: rotating file logger for the user's nvim configuration.
--
-- Goals:
--   1. Persist every error/warning surfaced by our config so future debug
--      sessions (mine, the AI's) have ground truth instead of "user said
--      they saw an error somewhere".
--   2. Stay decoupled from any plugin's logging (noice, snacks, nvim-nio).
--      We do NOT monkey-patch vim.notify -- that fights with noice/snacks
--      and produces a "vim.notify was overridden" beep on Windows.
--   3. Bound disk usage: rotate at MAX_BYTES, keep KEEP_FILES backups.
--
-- Public API:
--   log.error(scope, fmt, ...) / log.warn / log.info / log.debug / log.trace
--     -- variadic; if first arg after scope contains "%" we string.format,
--        otherwise we concat with spaces.
--   log.notify_error(scope, msg, opts?)
--     -- writes ERROR line to log AND vim.notify(..., ERROR). Replacement
--        for the dozens of bare vim.notify(..., ERROR) call sites.
--   log.notify(scope, msg, level, opts?)
--     -- general variant; level defaults to INFO.
--   log.wrap_job(scope, opts) -> table suitable to splat into jobstart {}
--     -- captures stderr lines and on non-zero exit logs them with cmd/cwd.
--        opts: { cmd, cwd, on_stderr (user), on_exit (user) }.
--   log.pcall(scope, fn, ...) -> ok, ...
--     -- wraps pcall; on failure logs ERROR with traceback.
--   log.xpcall(scope, fn, ...) -- same with xpcall + traceback.
--   log.set_level(level)  -- runtime threshold (default WARN written;
--                            INFO+DEBUG+TRACE dropped unless raised).
--   log.path() -- absolute current log file path.
--   log.open() -- :tabnew the current log.
--   log.clear() -- truncate + rotate .1..N out of the way.
--
-- File location: vim.fn.stdpath("log") .. "/nvim-debug.log"
--   On Windows that is %LOCALAPPDATA%\nvim-data\log\nvim-debug.log.
--   Backups: nvim-debug.log.1 (newest backup) ... nvim-debug.log.5 (oldest).

local M = {}

local LEVEL_NAMES = { "TRACE", "DEBUG", "INFO", "WARN", "ERROR" }
local LEVEL_VALUES = {
  TRACE = vim.log.levels.TRACE,
  DEBUG = vim.log.levels.DEBUG,
  INFO  = vim.log.levels.INFO,
  WARN  = vim.log.levels.WARN,
  ERROR = vim.log.levels.ERROR,
}

-- Default threshold: WARN. ERROR/WARN always land; INFO/DEBUG/TRACE skipped
-- unless user raises via log.set_level("debug") or :NvimLogLevel debug.
local current_level = vim.log.levels.WARN

-- Rotation policy.
local MAX_BYTES = 2 * 1024 * 1024 -- 2 MB per file. Small enough to grep fast.
local KEEP_FILES = 5              -- nvim-debug.log + .1 .. .5 backups.

local DATE_FMT = "%Y-%m-%dT%H:%M:%S"

local resolved_path -- cached log file path
local file_handle   -- cached io.open handle (append mode)
local bytes_written = 0

local function path_sep()
  return package.config:sub(1, 1)
end

local function join(a, b)
  if a:sub(-1) == path_sep() or a:sub(-1) == "/" then
    return a .. b
  end
  return a .. path_sep() .. b
end

local function ensure_dir(dir)
  if vim.fn.isdirectory(dir) == 0 then
    pcall(vim.fn.mkdir, dir, "p")
  end
end

local function resolve_path()
  if resolved_path then return resolved_path end
  local dir
  local ok, p = pcall(vim.fn.stdpath, "log")
  if ok and p and p ~= "" then
    dir = join(p, "nvim")
  else
    dir = join(vim.fn.stdpath("cache"), "log")
  end
  ensure_dir(dir)
  resolved_path = join(dir, "nvim-debug.log")
  return resolved_path
end

local function close_handle()
  if file_handle then
    pcall(file_handle.close, file_handle)
    file_handle = nil
  end
end

-- Move existing backups one slot older, drop the oldest, then rename
-- the active log to .1. Caller must ensure the active handle is closed.
local function rotate_files()
  local base = resolve_path()
  -- Drop the oldest.
  local oldest = base .. "." .. tostring(KEEP_FILES)
  if vim.fn.filereadable(oldest) == 1 then
    pcall(os.remove, oldest)
  end
  -- Shift .N-1 -> .N down to .1 -> .2.
  for i = KEEP_FILES - 1, 1, -1 do
    local src = base .. "." .. tostring(i)
    local dst = base .. "." .. tostring(i + 1)
    if vim.fn.filereadable(src) == 1 then
      pcall(os.rename, src, dst)
    end
  end
  -- Active -> .1.
  if vim.fn.filereadable(base) == 1 then
    pcall(os.rename, base, base .. ".1")
  end
end

local function open_handle()
  close_handle()
  local p = resolve_path()
  -- Honour existing size on first open so we rotate at the right boundary.
  local stat = vim.uv and vim.uv.fs_stat and vim.uv.fs_stat(p) or nil
  bytes_written = (stat and stat.size) or 0
  if bytes_written >= MAX_BYTES then
    rotate_files()
    bytes_written = 0
  end
  file_handle = io.open(p, "a")
  return file_handle
end

local function maybe_rotate(extra_bytes)
  if bytes_written + extra_bytes < MAX_BYTES then return end
  close_handle()
  rotate_files()
  bytes_written = 0
  open_handle()
end

local function caller_site()
  -- Skip frames: 1 = this fn, 2 = level fn (error/warn/...), 3 = real caller.
  local info = debug.getinfo(4, "Sl")
  if not info then return "?" end
  local src = info.short_src or "?"
  -- Strip everything before "lua/" so paths stay short and stable.
  local idx = src:find("lua[/\\]")
  if idx then src = src:sub(idx) end
  return string.format("%s:%d", src, info.currentline or 0)
end

local function format_payload(...)
  local n = select("#", ...)
  if n == 0 then return "" end
  local first = select(1, ...)
  if type(first) == "string" and first:find("%%") and n > 1 then
    -- format-style; if format fails fall back to concat.
    local ok, s = pcall(string.format, ...)
    if ok then return s end
  end
  local parts = {}
  for i = 1, n do
    local v = select(i, ...)
    if type(v) == "string" then
      parts[i] = v
    elseif v == nil then
      parts[i] = "<nil>"
    else
      parts[i] = vim.inspect(v, { newline = " ", indent = "" })
    end
  end
  return table.concat(parts, " ")
end

local function write_line(level_name, scope, body)
  local line = string.format(
    "%s %s [%s] %s | %s\n",
    os.date(DATE_FMT),
    level_name,
    scope or "?",
    body,
    caller_site()
  )
  if not file_handle then
    open_handle()
    if not file_handle then return end
  end
  maybe_rotate(#line)
  if not file_handle then return end
  local ok = pcall(function()
    file_handle:write(line)
    file_handle:flush()
  end)
  if ok then
    bytes_written = bytes_written + #line
  end
end

local function should_log(level_value)
  return level_value >= current_level
end

local function emit(level_name, scope, ...)
  local level_value = LEVEL_VALUES[level_name]
  if not should_log(level_value) then return end
  write_line(level_name, scope or "nvim", format_payload(...))
end

function M.trace(scope, ...) emit("TRACE", scope, ...) end
function M.debug(scope, ...) emit("DEBUG", scope, ...) end
function M.info(scope, ...)  emit("INFO",  scope, ...) end
function M.warn(scope, ...)  emit("WARN",  scope, ...) end
function M.error(scope, ...) emit("ERROR", scope, ...) end

function M.notify(scope, msg, level, opts)
  level = level or vim.log.levels.INFO
  -- map level back to name for log file
  local name = "INFO"
  for k, v in pairs(LEVEL_VALUES) do
    if v == level then name = k; break end
  end
  emit(name, scope, msg)
  vim.schedule(function()
    vim.notify(msg, level, opts)
  end)
end

function M.notify_error(scope, msg, opts)
  -- Always write to log regardless of current_level (ERROR is highest).
  emit("ERROR", scope, msg)
  vim.schedule(function()
    vim.notify(msg, vim.log.levels.ERROR, opts)
  end)
end

-- Wrap a vim.fn.jobstart-style options table so that:
--   * stderr lines are buffered and logged on non-zero exit
--   * on_exit non-zero is logged with cmd/cwd/exit code
--   * exceptions inside user callbacks are caught + logged
function M.wrap_job(scope, opts)
  opts = opts or {}
  local user_on_stderr = opts.on_stderr
  local user_on_exit = opts.on_exit
  local user_on_stdout = opts.on_stdout
  local stderr_buf = {}

  local function safe_call(name, fn, ...)
    if not fn then return end
    local ok, err = pcall(fn, ...)
    if not ok then
      emit("ERROR", scope, string.format("callback %s threw: %s", name, tostring(err)))
    end
  end

  return {
    on_stdout = user_on_stdout and function(id, data, ev)
      safe_call("on_stdout", user_on_stdout, id, data, ev)
    end or nil,

    on_stderr = function(id, data, ev)
      if data then
        for _, line in ipairs(data) do
          if line and line ~= "" then
            stderr_buf[#stderr_buf + 1] = line
          end
        end
      end
      safe_call("on_stderr", user_on_stderr, id, data, ev)
    end,

    on_exit = function(id, code, ev)
      if code and code ~= 0 then
        local cmd = opts.cmd
        local cmd_str = type(cmd) == "table" and table.concat(cmd, " ") or tostring(cmd or "?")
        local stderr_tail = ""
        if #stderr_buf > 0 then
          local start = math.max(1, #stderr_buf - 30)
          stderr_tail = "\n  stderr_tail:\n    " .. table.concat({ unpack(stderr_buf, start) }, "\n    ")
        end
        emit("ERROR", scope, string.format(
          "job exited code=%d cmd=%s cwd=%s%s",
          code, cmd_str, tostring(opts.cwd or "?"), stderr_tail
        ))
      end
      stderr_buf = {}
      safe_call("on_exit", user_on_exit, id, code, ev)
    end,
  }
end

function M.pcall(scope, fn, ...)
  local args = { ... }
  local ok, err = xpcall(function() return fn(unpack(args)) end, function(e)
    return debug.traceback(tostring(e), 2)
  end)
  if not ok then
    emit("ERROR", scope, "pcall failed: " .. tostring(err))
    return false, err
  end
  return ok, err
end

function M.set_level(level)
  if type(level) == "string" then
    local v = LEVEL_VALUES[level:upper()]
    if v then current_level = v end
  elseif type(level) == "number" then
    current_level = level
  end
end

function M.get_level()
  for _, name in ipairs(LEVEL_NAMES) do
    if LEVEL_VALUES[name] == current_level then return name end
  end
  return "WARN"
end

function M.path()
  return resolve_path()
end

function M.open()
  local p = resolve_path()
  if vim.fn.filereadable(p) == 0 then
    -- Touch so the open command does not bail.
    open_handle()
    if file_handle then file_handle:write("") end
  end
  vim.cmd("tabnew " .. vim.fn.fnameescape(p))
  vim.bo.buftype = ""
  vim.bo.buflisted = false
  pcall(vim.cmd, "normal! G")
end

function M.clear()
  close_handle()
  rotate_files()
  bytes_written = 0
  open_handle()
end

-- Install user commands. Idempotent: safe to call from init multiple times.
function M.install_commands()
  vim.api.nvim_create_user_command("NvimLog", function() M.open() end,
    { desc = "Open the nvim debug log in a new tab" })
  vim.api.nvim_create_user_command("NvimLogPath", function()
    local p = resolve_path()
    vim.notify("nvim debug log: " .. p, vim.log.levels.INFO, { title = "log" })
    vim.fn.setreg("+", p)
  end, { desc = "Echo + yank current nvim debug log path" })
  vim.api.nvim_create_user_command("NvimLogClear", function()
    M.clear()
    vim.notify("nvim debug log rotated/cleared", vim.log.levels.INFO, { title = "log" })
  end, { desc = "Rotate the active log out of the way and start fresh" })
  vim.api.nvim_create_user_command("NvimLogLevel", function(args)
    local lvl = (args.args or ""):upper()
    if lvl == "" then
      vim.notify("current log level: " .. M.get_level(), vim.log.levels.INFO, { title = "log" })
      return
    end
    if not LEVEL_VALUES[lvl] then
      vim.notify("unknown level: " .. lvl .. " (trace|debug|info|warn|error)", vim.log.levels.ERROR)
      return
    end
    M.set_level(lvl)
    vim.notify("log level -> " .. lvl, vim.log.levels.INFO, { title = "log" })
  end, {
    nargs = "?",
    complete = function() return { "trace", "debug", "info", "warn", "error" } end,
    desc = "Show or set the nvim debug log level",
  })
end

-- Eager open so the path exists immediately and rotation pre-checks run.
open_handle()

return M
