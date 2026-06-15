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
  local env_hash = vim.fn.environ()
  env_hash.PYTHONHOME = ""
  env_hash.PYTHONPATH = ""
  -- Enable lldb-dap own protocol trace log. Source: lldb-dap
  -- tool/lldb-dap.cpp L644 (getenv "LLDBDAP_LOG"). Captures full DAP
  -- request/response/event stream including state transitions that
  -- nvim-dap log can't see.
  local log_file = vim.fn.stdpath("cache") .. "/lldb-dap-protocol.log"
  -- Truncate previous run's log so each attach session is fresh
  local f = io.open(log_file, "w")
  if f then f:close() end
  env_hash.LLDBDAP_LOG = log_file
  local ok_cfg, cfg = pcall(require, "ue.config")
  if ok_cfg and cfg and cfg.get then
    local pyhome = cfg.get("dap.lldb_dap_python_dir")
    if type(pyhome) == "string" and pyhome ~= "" then
      env_hash.PYTHONHOME = pyhome
    end
    local pypath = cfg.get("dap.lldb_dap_pythonpath")
    if type(pypath) == "string" and pypath ~= "" then
      env_hash.PYTHONPATH = pypath
    end
  end
  -- libuv `uv.spawn` env field requires an ARRAY of "K=V" strings, NOT a
  -- hash map. nvim-dap session.lua L1601 passes our env directly to
  -- uv.spawn without normalization (the normalize path at L137-143 is
  -- only used by the terminal-spawn / runInTerminal route). So we must
  -- produce the array form ourselves here.
  local arr = {}
  for k, v in pairs(env_hash) do
    if k:find("^[^=]*$") then
      arr[#arr + 1] = k .. "=" .. tostring(v)
    end
  end
  return arr
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
  -- Disable nvim-dap's "auto-continue any thread that stops after another is
  -- already stopped" behaviour for the `lldb` config type. lldb-dap 22.1.6
  -- on platform-mode Android attach reports stopOnEntry as ONE `stopped`
  -- event per thread (all with allThreadsStopped=true). nvim-dap interprets
  -- every event after the first as "a NEW thread stopped while another is
  -- already stopped" and fires a per-thread `continue` request — for a UE4
  -- app that floods lldb-dap with ~165 continues, one of which lands on the
  -- entry stop (OK) and the rest return `notStopped`, wedging the session.
  -- Keep every stopped event visible to nvim-dap, but prevent that automatic
  -- fan-out; the user resumes explicitly with F5 after the entry stop.
  -- (Set unconditionally, BEFORE the adapter-already-wired early return.)
  dap.defaults = dap.defaults or {}
  dap.defaults.lldb = dap.defaults.lldb or {}
  dap.defaults.lldb.auto_continue_if_many_stopped = false

  -- Always re-wire the adapter table. We intentionally do NOT short-circuit
  -- when the path is unchanged: env (notably LLDBDAP_LOG) is recomputed per
  -- call via M._lldb_dap_env() and may differ across sessions, so a stale
  -- adapters.lldb.options.env would point the log at a previous run. Re-wiring
  -- is cheap (a table assignment) and keeps env fresh.
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
