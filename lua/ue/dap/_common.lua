-- ue.dap._common — shared helpers for the per-platform DAP modules.
--
-- Migrated from codelldb (VS Code extension) to lldb-dap (the DAP
-- executable that ships with LLVM 18+). lldb-dap natively understands
-- DAP `setBreakpoints` requests, so all the hand-written breakpoint
-- and ASLR hacks that codelldb required are gone.
--
-- Resolution priority for the adapter executable:
--   1. ue.config.get("dap.lldb_dap_path")
--   2. utils.platform.driver().default_lldb_dap_paths()
--   3. PATH lookup for "lldb-dap" / "lldb-dap.exe"

local fs = require("ue.core.fs")

local M = {}

local function executable_on_path(name)
  if vim.fn.executable(name) == 1 then
    local p = vim.fn.exepath(name)
    if p and p ~= "" then return p end
  end
  return nil
end

--- Resolve an lldb-dap executable.
--- Returns the first readable file path, or nil.
function M.find_lldb_dap()
  -- 1. explicit user override
  local ok_cfg, cfg = pcall(require, "ue.config")
  if ok_cfg and cfg and cfg.get then
    local override = cfg.get("dap.lldb_dap_path")
    if type(override) == "string" and override ~= "" and fs.is_file(override) then
      return override
    end
  end

  -- 2. per-OS defaults from the platform driver
  local ok_plat, plat = pcall(require, "utils.platform")
  if ok_plat and plat and plat.driver then
    local driver = plat.driver()
    if driver and driver.default_lldb_dap_paths then
      for _, p in ipairs(driver.default_lldb_dap_paths() or {}) do
        if fs.is_file(p) then return p end
      end
    end
  end

  -- 3. PATH lookup
  return executable_on_path("lldb-dap") or executable_on_path("lldb-dap.exe")
end

--- Build the env table that lldb-dap needs at spawn time.
--- By default we sanitize the common Python variables. A polluted
--- PYTHONHOME/PYTHONPATH can make lldb-dap load the wrong Python runtime on
--- Windows; lldb-dap itself does not need the user's shell Python. Advanced
--- users can still opt in to explicit paths through ue.config.
function M._lldb_dap_env()
  local env = vim.fn.environ()
  env.PYTHONHOME = ""
  env.PYTHONPATH = ""
  local ok_cfg, cfg = pcall(require, "ue.config")
  if ok_cfg and cfg and cfg.get then
    local pyhome = cfg.get("dap.lldb_dap_python_dir")
    if type(pyhome) == "string" and pyhome ~= "" then
      env.PYTHONHOME = pyhome
    end
    local pypath = cfg.get("dap.lldb_dap_pythonpath")
    if type(pypath) == "string" and pypath ~= "" then
      env.PYTHONPATH = pypath
    end
  end
  return env
end

--- Lazy-load nvim-dap. Returns the module or nil + reason.
function M.require_dap()
  local ok, dap = pcall(require, "dap")
  if not ok then return nil, "nvim-dap not installed" end
  return dap, nil
end

--- Ensure dap.adapters.lldb is wired to the resolved lldb-dap executable.
--- Idempotent: calling multiple times only mutates the table when the
--- path changes (so users hot-reloading config see the new value).
---
--- We use `type = 'executable'` (stdio) — the simplest transport and
--- the upstream-blessed path. lldb-dap reads DAP requests from stdin
--- and writes responses to stdout; nvim-dap pipes them.
---
--- History: we briefly used `type = 'server'` + `--connection listen://`
--- to dodge llvm/llvm-project#178155 (LLVM 22.x lldb-dap.exe crashes
--- 0xC0000409 in NativeFile ctor on Windows). That bug only triggers
--- on 22.x; 21.1.8 stdio is stable. We now side-load 21.1.8's lldb-dap
--- (see utils/platform/windows.lua default_lldb_dap_paths) and use the
--- straightforward stdio adapter on all platforms.
---@param dap table the nvim-dap module
---@param adapter string absolute path to lldb-dap
function M.ensure_adapter(dap, adapter)
  if not dap or not dap.adapters then return end
  local cur = dap.adapters.lldb
  if type(cur) == "table"
    and cur.type == "executable"
    and cur.command == adapter
    and cur.options ~= nil then
    return
  end
  dap.adapters.lldb = {
    type    = "executable",
    command = adapter,
    name    = "lldb",
    options = {
      env = M._lldb_dap_env(),
    },
  }
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

--- Build a minimal nvim-dap config table for lldb-dap.
---@param opts { name: string, request: 'attach'|'launch', pid?: integer, program?: string, args?: string[], cwd?: string, initCommands?: string[], preRunCommands?: string[] }
function M.lldb_dap_config(opts)
  local cfg = {
    name    = opts.name,
    type    = "lldb",
    request = opts.request,
    cwd     = opts.cwd or vim.fn.getcwd(),
  }
  if opts.request == "attach" then
    cfg.pid = opts.pid
  else
    cfg.program     = opts.program
    cfg.args        = opts.args or {}
    cfg.stopOnEntry = false
  end
  if opts.initCommands   then cfg.initCommands   = opts.initCommands   end
  if opts.preRunCommands then cfg.preRunCommands = opts.preRunCommands end
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
  local adapter = M.find_lldb_dap()
  if not adapter then
    vim.notify("lldb-dap adapter not found on this host", vim.log.levels.ERROR)
    return false
  end
  M.ensure_adapter(dap, adapter)
  dap.run(config)
  return true
end

return M
