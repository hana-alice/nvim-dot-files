local loggers = {}

local log_date_format = "%FT%H:%M:%SZ%z"
local LARGE = 1e9

local function path_sep()
  if jit then
    local os = string.lower(jit.os)
    if os == "linux" or os == "osx" or os == "bsd" then
      return "/"
    end
  end
  return package.config:sub(1, 1)
end

local function path_join(...)
  return table.concat(vim.tbl_flatten({ ... }), path_sep())
end

local function normalize_log_dir(path)
  path = tostring(path or "")
  if path == "" then
    return ""
  end
  local stat = vim.uv and vim.uv.fs_stat and vim.uv.fs_stat(path) or nil
  if (stat and stat.type == "file") or path:match("%.log$") then
    path = vim.fn.fnamemodify(path, ":h")
  end
  return path
end

local function resolve_log_dir()
  for _, kind in ipairs({ "log", "state", "cache" }) do
    local ok, path = pcall(vim.fn.stdpath, kind)
    if ok then
      path = normalize_log_dir(path)
      if path ~= "" then
        return path
      end
    end
  end
  return path_join(vim.fn.stdpath("config"), "data", "logs")
end

local function install_logger_methods(logger, logfile)
  for level, levelnr in pairs(vim.log.levels) do
    logger[level:lower()] = function(...)
      local argc = select("#", ...)
      if levelnr < logger._level then
        return false
      end
      if argc == 0 then
        return true
      end
      if not logfile then
        return false
      end

      local info = debug.getinfo(2, "Sl")
      local fileinfo = string.format("%s:%s", info.short_src, info.currentline)
      local parts = {
        table.concat({ level, "|", os.date(log_date_format), "|", fileinfo, "|" }, " "),
      }
      for i = 1, argc do
        local arg = select(i, ...)
        if arg == nil then
          table.insert(parts, "<nil>")
        elseif type(arg) == "string" then
          table.insert(parts, arg)
        elseif type(arg) == "table" and arg.__tostring then
          table.insert(parts, arg.__tostring(arg))
        else
          table.insert(parts, vim.inspect(arg))
        end
      end
      logfile:write(table.concat(parts, " "), "\n")
      logfile:flush()
      return true
    end
  end
end

local Logger = {}

function Logger.new(filename, opts)
  opts = opts or {}
  local logger = loggers[filename]
  if logger then
    return logger
  end

  logger = {}
  setmetatable(logger, { __index = Logger })
  loggers[filename] = logger
  logger._level = opts.level or vim.log.levels.WARN

  local logdir = resolve_log_dir()
  local logfile = nil
  logger._filename = path_join(logdir, filename .. ".log")

  local ok_open = pcall(function()
    vim.fn.mkdir(logdir, "p")
    logfile = assert(io.open(logger._filename, "a+"))
  end)

  if ok_open and logfile then
    local log_info = vim.uv and vim.uv.fs_stat and vim.uv.fs_stat(logger._filename) or nil
    if log_info and log_info.size > LARGE then
      vim.schedule(function()
        vim.notify(
          string.format("Nio log is large (%d MB): %s", log_info.size / (1000 * 1000), logger._filename),
          vim.log.levels.WARN
        )
      end)
    end
  else
    logger._filename = ""
  end

  install_logger_methods(logger, logfile)
  return logger
end

function Logger:set_level(level)
  self._level = assert(
    type(level) == "number" and level or vim.log.levels[tostring(level):upper()],
    string.format("Log level must be one of (trace, debug, info, warn, error), got: %q", level)
  )
end

function Logger:get_filename()
  return self._filename
end

return Logger.new("nio")
