-- utils.platform — platform detection + driver registry.
--
-- Public surface (frozen, additive only):
--
--   M.id           string  "windows" | "macos" | "linux"
--   M.is_windows   boolean
--   M.is_mac       boolean
--   M.is_linux     boolean
--   M.driver()     PlatformDriver  (lazy-loaded, cached)
--
-- Old call sites used `require("utils.platform").is_windows` directly;
-- those keep working unchanged. New code that needs OS-specific behaviour
-- should call `require("utils.platform").driver().<method>()`.
--
-- Drivers live in `lua/utils/platform/<id>.lua` and must implement the
-- shape declared by ---@class PlatformDriver below.

local M = {}

local function detect_id()
  if vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1 then
    return "windows"
  end
  if vim.fn.has("mac") == 1 or vim.fn.has("macunix") == 1 then
    return "macos"
  end
  return "linux"
end

M.id         = detect_id()
M.is_windows = M.id == "windows"
M.is_mac     = M.id == "macos"
M.is_linux   = M.id == "linux"

---@class PlatformDriver
---@field id        '"windows"'|'"macos"'|'"linux"'
---@field shell     fun(): string
---@field path_sep  string
---@field list_sep  string
---@field exe_suffix string
---@field open_path fun(path: string)
---@field reveal_file fun(path: string)
---@field default_clangd_candidates fun(): string[]
---@field default_codelldb_paths    fun(): string[]
---@field default_lldb_server_paths fun(): string[]
---@field cmd_quote fun(value: string): string

local _drivers = {}
local _warned_stub = {}

local function load_driver(id)
  local ok, mod = pcall(require, "utils.platform." .. id)
  if not ok then
    if not _warned_stub[id] then
      _warned_stub[id] = true
      vim.schedule(function()
        local lvl = vim.log.levels.WARN
        vim.notify(
          ("utils.platform: driver for %q failed to load (%s); using bare stub")
            :format(id, tostring(mod)),
          lvl
        )
      end)
    end
    return require("utils.platform.stub")
  end
  return mod
end

--- Return the driver for the current platform. Cached after first call.
---@return PlatformDriver
function M.driver()
  if not _drivers[M.id] then
    _drivers[M.id] = load_driver(M.id)
  end
  return _drivers[M.id]
end

--- Test seam: force a different driver by id. Returns the previous driver.
---@param id string
---@return PlatformDriver previous
function M._set_driver_for_test(id)
  local prev = _drivers[M.id]
  _drivers[M.id] = load_driver(id)
  return prev
end

return M
