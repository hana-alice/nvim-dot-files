-- ue.dap._common — shared helpers for the per-platform DAP modules.
--
-- Phase H: every platform module needs the same primitives:
--   * find a codelldb adapter executable
--   * spin up nvim-dap with a config when it is loadable
--   * prompt the user for a PID (attach) or binary path (launch)
--
-- Keep these helpers free of any Android-specific assumptions and free
-- of `require("ue")` so the module imports cleanly during setup().

local fs = require("ue.core.fs")

local M = {}

--- Resolve a codelldb adapter executable. Probe order:
---   1. ue.config.get("dap.codelldb_path")            (Phase I)
---   2. utils.platform.driver().default_codelldb_paths()
---   3. ue.dap.codelldb_paths() — vendored install probe
--- Returns the first path that is a readable file, or nil.
function M.find_codelldb()
  -- Step 1: explicit user override (Phase I exercises this once
  -- ue.config grows the key; today get() returns nil → safely skipped).
  local ok_cfg, cfg = pcall(require, "ue.config")
  if ok_cfg and cfg and cfg.get then
    local override = cfg.get("dap.codelldb_path")
    if type(override) == "string" and override ~= "" and fs.is_file(override) then
      return override
    end
  end

  -- Step 2: per-OS defaults from the platform driver
  local ok_plat, plat = pcall(require, "utils.platform")
  if ok_plat and plat and plat.driver then
    local driver = plat.driver()
    if driver and driver.default_codelldb_paths then
      for _, p in ipairs(driver.default_codelldb_paths() or {}) do
        if fs.is_file(p) then return p end
      end
    end
  end

  -- Step 3: vendored install probe (existing behaviour from ue/dap.lua)
  local ok_dap, dap_mod = pcall(require, "ue.dap")
  if ok_dap and dap_mod and dap_mod.codelldb_paths then
    local adapter = dap_mod.codelldb_paths()
    if adapter and fs.is_file(adapter) then return adapter end
  end

  return nil
end

--- Lazy-load nvim-dap. Returns the module or nil + reason.
function M.require_dap()
  local ok, dap = pcall(require, "dap")
  if not ok then return nil, "nvim-dap not installed" end
  return dap, nil
end

--- Prompt synchronously for a PID. Returns the integer or nil.
function M.prompt_pid()
  local s = vim.fn.input("PID to attach: ", "")
  if s == nil or s == "" then return nil end
  local n = tonumber(s)
  if not n then
    vim.notify("Invalid PID: " .. s, vim.log.levels.WARN)
    return nil
  end
  return n
end

--- Prompt synchronously for a binary path. Returns the string or nil.
function M.prompt_binary()
  local p = vim.fn.input("Binary to launch: ", "", "file")
  if p == nil or p == "" then return nil end
  if not fs.is_file(p) then
    vim.notify("Not a readable file: " .. p, vim.log.levels.WARN)
    return nil
  end
  return p
end

--- Build a minimal nvim-dap config table for codelldb. The same shape
--- works for win64/mac/linux/ios native debugging.
---@param opts { name: string, adapter: string, request: 'attach'|'launch', pid?: integer, program?: string, args?: string[], cwd?: string }
function M.codelldb_config(opts)
  local cfg = {
    name    = opts.name,
    type    = "codelldb",
    request = opts.request,
    cwd     = opts.cwd or vim.fn.getcwd(),
  }
  if opts.request == "attach" then
    cfg.pid = opts.pid
  else
    cfg.program = opts.program
    cfg.args    = opts.args or {}
    cfg.stopOnEntry = false
  end
  return cfg
end

--- Run a config via nvim-dap; degrade to a notify when nvim-dap is
--- unavailable so headless smoke tests don't crash.
function M.run(config, fallback_msg)
  local dap, err = M.require_dap()
  if not dap then
    vim.notify((fallback_msg or "DAP unavailable") .. ": " .. err, vim.log.levels.WARN)
    return false
  end
  dap.run(config)
  return true
end

return M
