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
--   4. Be safe to call from libuv fast-event callbacks (jobstart on_stdout,
--      timer callbacks). All vim.fn / vim.notify calls go through schedule.
--
-- Public API:
--   Severity emitters (variadic, fmt-string detected when "%s/%d/..." present):
--     log.error(scope, ...) / .warn / .info / .debug / .trace
--   Structured emitter (preferred for machine-readable trail):
--     log.error_ctx(scope, msg, ctx_tbl) / .warn_ctx / .info_ctx / .debug_ctx
--       -- ctx_tbl rendered as " k1=v1 k2=v2"; values vim.inspect-ed if complex.
--   User-facing notify mirror:
--     log.notify_error(scope, msg, opts?)   -- ERROR + vim.notify
--     log.notify(scope, msg, level, opts?)
--   Job wrapping:
--     log.wrap_job(scope, opts) -> table for vim.fn.jobstart {}
--       opts: { cmd, cwd, on_stderr, on_exit, on_stdout, notify_callback_throw }
--       on default we mirror callback exceptions to notify_error so silent
--       breakage is impossible (set notify_callback_throw=false to suppress).
--   Safe-call helpers:
--     log.pcall(scope, fn, ...)  -> ok, ...   (logs traceback on failure)
--     log.xpcall(scope, fn, ...) -> ok, ...   (alias)
--   Scoped logger factory (preferred for module-internal use):
--     local L = log.scoped("ue.dap")
--     L.error("attach failed") ; L.error_ctx("attach failed", {pid=p, code=c})
--     L.notify_error("attach failed")
--   Level control:
--     log.set_level(level)            -- global threshold (default WARN)
--     log.get_level()
--     log.set_scope_level(scope, lvl) -- per-scope override (nil to clear)
--     log.get_scope_level(scope)
--   Inspection:
--     log.path()  -- absolute current log file path (may be nil before resolve)
--     log.open()  -- :tabnew the current log
--     log.clear() -- truncate + rotate .1..N out of the way
--   Setup:
--     log.install_commands() -- :NvimLog / :NvimLogPath / :NvimLogClear /
--                               :NvimLogLevel / :NvimLogScope
--
-- Default threshold: WARN. ERROR/WARN always land; INFO/DEBUG/TRACE are
-- dropped unless raised via :NvimLogLevel debug or log.set_level("info").
--
-- File location: <stdpath('log')>/nvim/nvim-debug.log
--   On Windows that resolves to %LOCALAPPDATA%\nvim-data\nvim\nvim-debug.log
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
local LEVEL_NAME_BY_VALUE = {}
for k, v in pairs(LEVEL_VALUES) do LEVEL_NAME_BY_VALUE[v] = k end

local current_level = vim.log.levels.WARN
local scope_levels = {} -- scope -> level value (override)

-- Rotation policy.
local MAX_BYTES = 2 * 1024 * 1024 -- 2 MB per file. Small enough to grep fast.
local KEEP_FILES = 5              -- nvim-debug.log + .1 .. .5 backups.

local DATE_FMT = "%Y-%m-%dT%H:%M:%S"

-- Portable unpack (LuaJIT/Neovim has both; helper future-proofs reuse).
local tunpack = table.unpack or unpack

-- Lazy-resolved state (initialised on first write, NOT at require time).
local resolved_path
local file_handle
local bytes_written = 0
local rotate_warned = false   -- true once we've already shouted about rotate failure
local pending_buffer = {}     -- lines queued while we're in fast-event context
local pending_flush_scheduled = false

-- ---------------------------------------------------------------------------
-- Path / FS helpers
-- ---------------------------------------------------------------------------

local function path_sep()
  return package.config:sub(1, 1)
end

local function join(a, b)
  if a:sub(-1) == path_sep() or a:sub(-1) == "/" then
    return a .. b
  end
  return a .. path_sep() .. b
end

-- vim.uv.fs_* are safe in fast events; vim.fn.* are not. Prefer uv where we can.
local uv = vim.uv or vim.loop

local function ensure_dir_uv(dir)
  local stat = uv.fs_stat(dir)
  if stat and stat.type == "directory" then return true end
  -- Recursive mkdir via uv (mode 0755).
  local parts, acc = {}, ""
  local sep = path_sep()
  -- Normalise: split on both / and \
  for part in dir:gmatch("[^/\\]+") do parts[#parts + 1] = part end
  local is_unc = dir:sub(1, 2) == "\\\\" or dir:sub(1, 2) == "//"
  if is_unc then acc = sep .. sep end
  for i, part in ipairs(parts) do
    if i == 1 and part:match("^[A-Za-z]:$") then
      acc = part .. sep
    else
      acc = (acc == "" or acc:sub(-1) == sep) and (acc .. part) or (acc .. sep .. part)
    end
    local s = uv.fs_stat(acc)
    if not s then
      uv.fs_mkdir(acc, 493) -- 0755
    elseif s.type ~= "directory" then
      return false
    end
  end
  return true
end

-- Resolve once (uses vim.fn -> only safe in main loop; we call this from
-- schedule context only).
local function resolve_path_main()
  if resolved_path then return resolved_path end
  local dir
  local ok, p = pcall(vim.fn.stdpath, "log")
  if ok and p and p ~= "" then
    dir = join(p, "nvim")
  else
    local ok2, c = pcall(vim.fn.stdpath, "cache")
    dir = join(ok2 and c or ".", "log")
  end
  ensure_dir_uv(dir)
  resolved_path = join(dir, "nvim-debug.log")
  return resolved_path
end

-- Stat-based pre-resolve attempt: try with no vim.fn calls (works after
-- resolved_path is set, fails before -- which is fine, the caller will
-- buffer + schedule a flush).
local function resolve_path_fast()
  return resolved_path
end

local function close_handle()
  if file_handle then
    pcall(file_handle.close, file_handle)
    file_handle = nil
  end
end

-- Rotation: drop oldest, shift .N-1->.N down to .1->.2, then active->.1.
-- Returns true on success, false (and remembers) on any rename/remove failure.
local function rotate_files()
  local base = resolved_path
  if not base then return false end
  local all_ok = true
  local oldest = base .. "." .. tostring(KEEP_FILES)
  if uv.fs_stat(oldest) then
    local ok = pcall(os.remove, oldest)
    if not ok then all_ok = false end
  end
  for i = KEEP_FILES - 1, 1, -1 do
    local src = base .. "." .. tostring(i)
    local dst = base .. "." .. tostring(i + 1)
    if uv.fs_stat(src) then
      local ok = pcall(os.rename, src, dst)
      if not ok then all_ok = false end
    end
  end
  if uv.fs_stat(base) then
    local ok = pcall(os.rename, base, base .. ".1")
    if not ok then all_ok = false end
  end
  return all_ok
end

local function open_handle()
  close_handle()
  if not resolved_path then return nil end
  local stat = uv.fs_stat(resolved_path)
  bytes_written = (stat and stat.size) or 0
  if bytes_written >= MAX_BYTES then
    if rotate_files() then
      bytes_written = 0
      rotate_warned = false
    end
  end
  file_handle = io.open(resolved_path, "a")
  return file_handle
end

local function maybe_rotate(extra_bytes)
  if bytes_written + extra_bytes < MAX_BYTES then return end
  close_handle()
  if rotate_files() then
    bytes_written = 0
    rotate_warned = false
  else
    -- Rotate failed (AV/file-lock on Windows is the classic cause). Cap
    -- in-memory counter so we keep trying once per call instead of
    -- spinning the rename loop on every line.
    if not rotate_warned then
      rotate_warned = true
      -- Schedule a user-visible warning so silent unbounded growth is
      -- impossible. We call vim.schedule directly to avoid recursion.
      vim.schedule(function()
        vim.notify(
          "[utils.log] rotate failed; log file may exceed " .. tostring(MAX_BYTES) .. " bytes. "
          .. "Likely cause: another process holds the .1 backup open (AV/editor).",
          vim.log.levels.WARN, { title = "log" }
        )
      end)
    end
    -- Reset bytes counter to a slight overshoot so we re-attempt rotate
    -- only when the next chunk would push us over.
    bytes_written = MAX_BYTES - 1
  end
  open_handle()
end

-- ---------------------------------------------------------------------------
-- Format helpers
-- ---------------------------------------------------------------------------

local function caller_site()
  -- Frame layout (varies with scoped wrapper); search for first frame
  -- outside this file.
  for depth = 3, 8 do
    local info = debug.getinfo(depth, "Sl")
    if not info then break end
    local src = info.short_src or ""
    if src ~= "" and not src:find("utils[/\\]log%.lua$") then
      local idx = src:find("lua[/\\]")
      if idx then src = src:sub(idx) end
      return string.format("%s:%d", src, info.currentline or 0)
    end
  end
  return "?"
end

-- format_payload: variadic -> string.
-- Heuristic for "this is a format string": only treat first arg as fmt when
--   * type==string AND
--   * additional args present AND
--   * first arg contains a recognised format spec like %s %d %q %f %x etc.
-- Bare "%" (e.g. "%LOCALAPPDATA%" in a path) does NOT trigger format.
local FMT_SPEC = "%%[%-+ #0]?%d*%.?%d*[diouxXeEfgGqscp%%]"
local function looks_like_fmt(s)
  return s:find(FMT_SPEC) ~= nil
end

local function inspect_one(v)
  if type(v) == "string" then return v end
  if v == nil then return "<nil>" end
  if type(v) == "number" or type(v) == "boolean" then return tostring(v) end
  return vim.inspect(v, { newline = " ", indent = "" })
end

local function format_payload(...)
  local n = select("#", ...)
  if n == 0 then return "" end
  local first = select(1, ...)
  if type(first) == "string" and n > 1 and looks_like_fmt(first) then
    local ok, s = pcall(string.format, ...)
    if ok then return s end
    -- format failed (mismatched %); fall through to concat.
  end
  local parts = {}
  for i = 1, n do
    parts[i] = inspect_one(select(i, ...))
  end
  return table.concat(parts, " ")
end

-- Render a context table deterministically: " k=v k=v" sorted by key.
local function render_ctx(ctx)
  if not ctx or type(ctx) ~= "table" then return "" end
  local keys = {}
  for k in pairs(ctx) do keys[#keys + 1] = tostring(k) end
  table.sort(keys)
  local parts = {}
  for _, k in ipairs(keys) do
    local v = ctx[k]
    local rendered
    if type(v) == "string" then
      -- Quote if it contains spaces/quotes for grep-friendliness.
      if v:find("[%s\"]") then
        rendered = string.format("%q", v)
      else
        rendered = v
      end
    else
      rendered = inspect_one(v)
    end
    parts[#parts + 1] = k .. "=" .. rendered
  end
  return " " .. table.concat(parts, " ")
end

-- ---------------------------------------------------------------------------
-- Write path (fast-event safe)
-- ---------------------------------------------------------------------------

local function flush_pending()
  pending_flush_scheduled = false
  if #pending_buffer == 0 then return end
  -- Resolve path now that we're back on main loop.
  resolve_path_main()
  if not file_handle then open_handle() end
  if not file_handle then
    pending_buffer = {}
    return
  end
  local lines = pending_buffer
  pending_buffer = {}
  for _, line in ipairs(lines) do
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
end

local function in_fast_event()
  if vim.in_fast_event then return vim.in_fast_event() end
  return false
end

local function enqueue(line)
  pending_buffer[#pending_buffer + 1] = line
  if not pending_flush_scheduled then
    pending_flush_scheduled = true
    vim.schedule(flush_pending)
  end
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
  -- Always go through the queue: it's the simplest way to be uniformly safe
  -- in fast-event context AND preserve emit order across mixed contexts.
  -- Synchronous main-loop callers still see the line on disk by the next
  -- scheduled tick (effectively immediate for users; tests can vim.wait).
  if in_fast_event() or not resolved_path then
    enqueue(line)
    return
  end
  -- Main-loop fast path: write directly so tests/inspection see immediate
  -- results without needing vim.wait.
  if not file_handle then open_handle() end
  if not file_handle then
    enqueue(line)
    return
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

local function effective_level(scope)
  local override = scope and scope_levels[scope]
  if override then return override end
  return current_level
end

local function should_log(level_value, scope)
  return level_value >= effective_level(scope)
end

local function emit(level_name, scope, ...)
  local level_value = LEVEL_VALUES[level_name]
  if not should_log(level_value, scope) then return end
  write_line(level_name, scope or "nvim", format_payload(...))
end

local function emit_ctx(level_name, scope, msg, ctx)
  local level_value = LEVEL_VALUES[level_name]
  if not should_log(level_value, scope) then return end
  local body = (msg or "") .. render_ctx(ctx)
  write_line(level_name, scope or "nvim", body)
end

-- ---------------------------------------------------------------------------
-- Public severity API
-- ---------------------------------------------------------------------------

function M.trace(scope, ...) emit("TRACE", scope, ...) end
function M.debug(scope, ...) emit("DEBUG", scope, ...) end
function M.info(scope, ...)  emit("INFO",  scope, ...) end
function M.warn(scope, ...)  emit("WARN",  scope, ...) end
function M.error(scope, ...) emit("ERROR", scope, ...) end

function M.trace_ctx(scope, msg, ctx) emit_ctx("TRACE", scope, msg, ctx) end
function M.debug_ctx(scope, msg, ctx) emit_ctx("DEBUG", scope, msg, ctx) end
function M.info_ctx(scope, msg, ctx)  emit_ctx("INFO",  scope, msg, ctx) end
function M.warn_ctx(scope, msg, ctx)  emit_ctx("WARN",  scope, msg, ctx) end
function M.error_ctx(scope, msg, ctx) emit_ctx("ERROR", scope, msg, ctx) end

function M.notify(scope, msg, level, opts)
  level = level or vim.log.levels.INFO
  local name = LEVEL_NAME_BY_VALUE[level] or "INFO"
  emit(name, scope, msg)
  pcall(function()
    require("utils.notification_history").record({
      scope = scope,
      title = opts and opts.title,
      message = msg,
      level = level,
    })
  end)
  vim.schedule(function() vim.notify(msg, level, opts) end)
end

function M.notify_error(scope, msg, opts)
  emit("ERROR", scope, msg)
  pcall(function()
    require("utils.notification_history").record({
      scope = scope,
      title = opts and opts.title,
      message = msg,
      level = vim.log.levels.ERROR,
    })
  end)
  vim.schedule(function() vim.notify(msg, vim.log.levels.ERROR, opts) end)
end

-- ---------------------------------------------------------------------------
-- Scoped logger factory
-- ---------------------------------------------------------------------------

local SCOPED_METHODS = {
  trace     = "trace",     debug     = "debug",     info     = "info",
  warn      = "warn",      error     = "error",
  trace_ctx = "trace_ctx", debug_ctx = "debug_ctx", info_ctx = "info_ctx",
  warn_ctx  = "warn_ctx",  error_ctx = "error_ctx",
}

function M.scoped(scope)
  local L = { scope = scope }
  for k, target in pairs(SCOPED_METHODS) do
    L[k] = function(...) return M[target](scope, ...) end
  end
  L.notify_error = function(msg, opts) return M.notify_error(scope, msg, opts) end
  L.notify       = function(msg, level, opts) return M.notify(scope, msg, level, opts) end
  L.wrap_job     = function(opts) return M.wrap_job(scope, opts) end
  L.pcall        = function(fn, ...) return M.pcall(scope, fn, ...) end
  L.xpcall       = function(fn, ...) return M.xpcall(scope, fn, ...) end
  return L
end

-- ---------------------------------------------------------------------------
-- Job wrapper
-- ---------------------------------------------------------------------------

function M.wrap_job(scope, opts)
  opts = opts or {}
  local notify_throw = opts.notify_callback_throw
  if notify_throw == nil then notify_throw = true end
  local user_on_stderr = opts.on_stderr
  local user_on_exit = opts.on_exit
  local user_on_stdout = opts.on_stdout
  local stderr_buf = {}

  local function safe_call(name, fn, ...)
    if not fn then return end
    local ok, err = pcall(fn, ...)
    if not ok then
      local body = string.format("callback %s threw: %s", name, tostring(err))
      emit("ERROR", scope, body)
      if notify_throw then
        vim.schedule(function()
          vim.notify("[" .. scope .. "] " .. body .. " (see :NvimLog)",
            vim.log.levels.ERROR, { title = "log" })
        end)
      end
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
          stderr_tail = "\n  stderr_tail:\n    " .. table.concat({ tunpack(stderr_buf, start) }, "\n    ")
        end
        emit_ctx("ERROR", scope, "job failed", {
          code = code, cmd = cmd_str, cwd = opts.cwd or "?",
        })
        if stderr_tail ~= "" then
          write_line("ERROR", scope, "job stderr_tail" .. stderr_tail)
        end
      end
      stderr_buf = {}
      safe_call("on_exit", user_on_exit, id, code, ev)
    end,
  }
end

-- ---------------------------------------------------------------------------
-- Safe call helpers
-- ---------------------------------------------------------------------------

function M.pcall(scope, fn, ...)
  local args = { ... }
  local ok, err = xpcall(function() return fn(tunpack(args)) end, function(e)
    return debug.traceback(tostring(e), 2)
  end)
  if not ok then
    emit("ERROR", scope, "pcall failed: " .. tostring(err))
    return false, err
  end
  return ok, err
end

M.xpcall = M.pcall

-- ---------------------------------------------------------------------------
-- Level controls
-- ---------------------------------------------------------------------------

local function coerce_level(level)
  if type(level) == "string" then
    return LEVEL_VALUES[level:upper()]
  elseif type(level) == "number" then
    return level
  end
  return nil
end

function M.set_level(level)
  local v = coerce_level(level)
  if v then current_level = v end
end

function M.get_level()
  return LEVEL_NAME_BY_VALUE[current_level] or "WARN"
end

function M.set_scope_level(scope, level)
  if not scope or scope == "" then return end
  if level == nil then
    scope_levels[scope] = nil
    return
  end
  local v = coerce_level(level)
  if v then scope_levels[scope] = v end
end

function M.get_scope_level(scope)
  local v = scope_levels[scope]
  if not v then return nil end
  return LEVEL_NAME_BY_VALUE[v]
end

function M.list_scope_overrides()
  local out = {}
  for s, v in pairs(scope_levels) do
    out[s] = LEVEL_NAME_BY_VALUE[v]
  end
  return out
end

-- ---------------------------------------------------------------------------
-- Inspection
-- ---------------------------------------------------------------------------

function M.path()
  if resolved_path then return resolved_path end
  -- Trigger main-loop resolve if we're called from a safe context.
  if not in_fast_event() then return resolve_path_main() end
  return nil
end

function M.open()
  resolve_path_main()
  if not resolved_path then return end
  if not uv.fs_stat(resolved_path) then
    open_handle()
    if file_handle then file_handle:write("") end
  end
  vim.cmd("tabnew " .. vim.fn.fnameescape(resolved_path))
  vim.bo.buftype = ""
  vim.bo.buflisted = false
  pcall(vim.cmd, "normal! G")
end

function M.clear()
  close_handle()
  resolve_path_main()
  rotate_files()
  bytes_written = 0
  rotate_warned = false
  open_handle()
end

-- ---------------------------------------------------------------------------
-- User commands
-- ---------------------------------------------------------------------------

function M.install_commands()
  pcall(function()
    require("utils.notification_history").install_commands()
  end)

  vim.api.nvim_create_user_command("NvimLog", function() M.open() end,
    { desc = "Open the nvim debug log in a new tab", force = true })

  vim.api.nvim_create_user_command("NvimLogPath", function()
    local p = resolve_path_main()
    vim.notify("nvim debug log: " .. (p or "?"), vim.log.levels.INFO, { title = "log" })
    if p then pcall(vim.fn.setreg, "+", p) end
  end, { desc = "Echo + yank current nvim debug log path", force = true })

  vim.api.nvim_create_user_command("NvimLogClear", function()
    M.clear()
    vim.notify("nvim debug log rotated/cleared", vim.log.levels.INFO, { title = "log" })
  end, { desc = "Rotate the active log out of the way and start fresh", force = true })

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
    force = true,
    desc = "Show or set the global nvim debug log level",
  })

  -- :NvimLogScope                   -- list overrides
  -- :NvimLogScope <scope>           -- show scope's effective level
  -- :NvimLogScope <scope> <level>   -- set override (or 'clear'/'-' to remove)
  vim.api.nvim_create_user_command("NvimLogScope", function(args)
    local parts = {}
    for w in (args.args or ""):gmatch("%S+") do parts[#parts + 1] = w end
    if #parts == 0 then
      local overrides = M.list_scope_overrides()
      local lines = { "scope overrides (global=" .. M.get_level() .. "):" }
      local any = false
      for s, lvl in pairs(overrides) do
        any = true
        lines[#lines + 1] = "  " .. s .. " = " .. lvl
      end
      if not any then lines[#lines + 1] = "  (none)" end
      vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO, { title = "log" })
      return
    end
    local scope = parts[1]
    if #parts == 1 then
      local lvl = M.get_scope_level(scope)
      vim.notify(scope .. " = " .. (lvl or "(inherit " .. M.get_level() .. ")"),
        vim.log.levels.INFO, { title = "log" })
      return
    end
    local lvl = parts[2]:upper()
    if lvl == "CLEAR" or lvl == "-" or lvl == "NIL" then
      M.set_scope_level(scope, nil)
      vim.notify("scope override cleared: " .. scope, vim.log.levels.INFO, { title = "log" })
      return
    end
    if not LEVEL_VALUES[lvl] then
      vim.notify("unknown level: " .. lvl, vim.log.levels.ERROR)
      return
    end
    M.set_scope_level(scope, lvl)
    vim.notify("scope " .. scope .. " -> " .. lvl, vim.log.levels.INFO, { title = "log" })
  end, {
    nargs = "*",
    complete = function(_, line)
      -- Complete level names on second arg.
      local n = 0
      for _ in line:gmatch("%S+") do n = n + 1 end
      if n >= 2 then
        return { "trace", "debug", "info", "warn", "error", "clear" }
      end
      return {}
    end,
    force = true,
    desc = "Show/set per-scope log level overrides",
  })
end

return M
