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
---@field shell_entry fun(kind: string): string|nil, string|nil
---@field path_sep  string
---@field list_sep  string
---@field exe_suffix string
---@field open_path fun(path: string)
---@field reveal_file fun(path: string)
---@field default_clangd_candidates fun(): string[]
---@field clangd_indexer_candidates fun(): string[]
---@field python_candidates fun(): string[]
---@field default_lldb_dap_paths    fun(): string[]
---@field default_lldb_server_paths fun(): string[]
---@field cmd_quote fun(value: string): string
---@field host_path fun(path: string): string
---@field shared_library_extension fun(): string
---@field allows_osc52 fun(): boolean
---@field code_search_install_hint fun(config_root: string): string
---@field path_key fun(path: string): string
---@field query_driver_globs fun(): string[]
---@field cdb_compiler_candidates fun(): string[]
---@field lldb_python_relative_paths fun(): string[]
---@field default_target fun(): string
---@field launch_process_plan fun(spec: table): table
---@field follow_file_plan fun(path: string): table|nil, string|nil
---@field debug_log_plan? fun(spec: table): table Windows-only OutputDebugString stream
---@field pch_build_plan? fun(path: string): table Windows-only generated build_pch.bat runner
---@field ue_build_entry fun(engine_root: string): string|table|nil, string|nil
---@field ue_uat_entry fun(engine_root: string): string|table|nil, string|nil
---@field xcrun_entry? fun(): string|table|nil, string|nil macOS-only capability
---@field security_entry? fun(): string|table|nil, string|nil macOS-only capability
---@field plutil_entry? fun(): string|table|nil, string|nil macOS-only capability
---@field folder_picker_plan? fun(prompt?: string): table macOS-only native folder chooser
---@field build_process_snapshot_plan? fun(root_pid?: integer): table macOS-only process-tree heartbeat snapshot
---@field powershell_entry? fun(): string|table|nil, string|nil legacy Windows-only compatibility alias
---@field mixed_eol_guard? fun(): boolean Windows-only fileformat capability
---@field treesitter_compiler_bin? fun(): string Windows-only parser compiler path
---@field windows_ui_config? fun(): boolean Windows-only UI configuration capability
---@field restart_fallback_candidates? fun(cwd: string, env: table): table[]
---@field restart_requires_spawn_reprobe? fun(): boolean
---@field restart_shutdown_delay_ms? fun(): integer

local _drivers = {}
local _warned_stub = {}

local function copy_list(values)
  local out = {}
  for index, value in ipairs(values or {}) do
    out[index] = tostring(value)
  end
  return out
end

local function add_candidate(out, source, candidate, source_key)
  candidate = tostring(candidate or "")
  if candidate == "" then return end
  out[#out + 1] = {
    candidate = vim.fs.normalize(candidate),
    source = source,
    source_key = source_key,
  }
end

local function collect_source_candidates(out, source, source_key, value)
  if type(value) == "function" then
    value = value()
  end
  if type(value) == "string" then
    add_candidate(out, source, value, source_key)
    return
  end
  if type(value) ~= "table" then return end
  for _, item in ipairs(value) do
    if type(item) == "table" then
      add_candidate(out, item.source or source, item.candidate or item.path or item.value, item.source_key or source_key)
    else
      add_candidate(out, source, item, source_key)
    end
  end
end

local function probe_executable(candidate)
  candidate = vim.fs.normalize(tostring(candidate or ""))
  if candidate == "" then
    return nil, "empty-candidate"
  end
  if candidate:find("/", 1, true) or candidate:find("\\", 1, true) then
    if vim.fn.executable(candidate) == 1 then
      return candidate
    end
    return nil, "not-executable"
  end
  local resolved = vim.fn.exepath(candidate)
  if type(resolved) == "string" and resolved ~= "" then
    return vim.fs.normalize(resolved)
  end
  return nil, "not-found-on-path"
end

local function default_config_getter(key)
  local ok, cfg = pcall(require, "ue.config")
  if ok and cfg and type(cfg.get) == "function" then
    return cfg.get(key)
  end
  return nil
end

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

---@param driver table|nil
---@param capability string
---@return table
function M.optional_capability(driver, capability, ...)
  driver = driver or M.driver()
  if type(driver) ~= "table" then
    return {
      ok = false,
      status = "unavailable",
      capability = capability,
      reason = "host-driver-missing",
    }
  end

  local method = driver[capability]
  if type(method) ~= "function" then
    return {
      ok = false,
      status = "unavailable",
      capability = capability,
      host_id = driver.id,
      reason = "host-capability-missing",
    }
  end

  local ok, value, detail = pcall(method, ...)
  if not ok then
    return {
      ok = false,
      status = "unavailable",
      capability = capability,
      host_id = driver.id,
      reason = "host-capability-errored",
      detail = value,
    }
  end

  if value == nil or value == false then
    return {
      ok = false,
      status = "unavailable",
      capability = capability,
      host_id = driver.id,
      reason = "host-capability-unavailable",
      detail = detail,
    }
  end

  return {
    ok = true,
    status = "ok",
    capability = capability,
    host_id = driver.id,
    value = value,
    detail = detail,
  }
end

---@param capability string
---@param driver? table
---@return boolean
function M.supports_capability(capability, driver)
  return M.optional_capability(driver, capability).ok == true
end

---@param base string
---@param env? table
---@param driver? PlatformDriver
---@return string[]
function M.go_tool_candidates(base, env, driver)
  driver = driver or M.driver()
  env = env or vim.env
  local suffix = tostring(driver.exe_suffix or "")
  local list_sep = tostring(driver.list_sep or ":")
  local name = tostring(base or "") .. suffix
  local candidates = {}
  local function add(path)
    if path and path ~= "" then
      candidates[#candidates + 1] = vim.fs.normalize(path)
    end
  end

  add(vim.fn.exepath(base))
  if suffix ~= "" then
    add(vim.fn.exepath(base .. suffix))
  end
  add(env.GOBIN and (env.GOBIN .. "/" .. name) or nil)
  for _, root in ipairs(vim.split(env.GOPATH or "", list_sep, { plain = true, trimempty = true })) do
    add(root .. "/bin/" .. name)
  end
  add(env.USERPROFILE and (env.USERPROFILE .. "/go/bin/" .. name) or nil)
  add(env.HOME and (env.HOME .. "/go/bin/" .. name) or nil)
  return candidates
end

---@param driver? PlatformDriver
---@param env? table
---@return string[]
function M.java_debugger_candidates(driver, env)
  driver = driver or M.driver()
  env = env or vim.env
  local name = "jdb" .. tostring(driver.exe_suffix or "")
  local candidates = {}
  local resolved = vim.fn.exepath(name)
  if resolved and resolved ~= "" then candidates[#candidates + 1] = resolved end
  if env.JAVA_HOME and env.JAVA_HOME ~= "" then
    candidates[#candidates + 1] = vim.fs.joinpath(env.JAVA_HOME, "bin", name)
  end
  candidates[#candidates + 1] = name
  return candidates
end

---@param clangd_path string
---@param driver? PlatformDriver
---@return string[]
function M.libclang_candidates(clangd_path, driver)
  driver = driver or M.driver()
  local suffix = tostring(driver.shared_library_extension() or ".so"):gsub("^%.", "")
  local bin_dir = vim.fs.dirname(vim.fs.normalize(tostring(clangd_path or "")))
  local parent = vim.fs.dirname(bin_dir)
  return {
    vim.fs.normalize(vim.fs.joinpath(bin_dir, "libclang." .. suffix)),
    vim.fs.normalize(vim.fs.joinpath(parent, "lib", "libclang." .. suffix)),
    vim.fs.normalize(vim.fs.joinpath(parent, "lib64", "libclang." .. suffix)),
    "libclang." .. suffix,
  }
end

---@param spec table
---@return table
function M.resolve_tool(spec)
  spec = spec or {}
  local driver = spec.driver or M.driver()
  local config_getter = spec.config_getter or default_config_getter
  local probe = spec.probe or probe_executable
  local candidates = {}
  local diagnostics = {}

  for _, env_name in ipairs(spec.env or {}) do
    local value = vim.env[env_name]
    if type(value) == "string" and value ~= "" then
      collect_source_candidates(candidates, "env", env_name, value)
    end
  end
  collect_source_candidates(candidates, "env", nil, spec.env_candidates)

  for _, config_key in ipairs(spec.config or {}) do
    collect_source_candidates(candidates, "config", config_key, config_getter(config_key))
  end
  collect_source_candidates(candidates, "config", nil, spec.config_candidates)

  if type(spec.driver_candidates) == "function" then
    collect_source_candidates(candidates, "driver", driver and driver.id or nil, spec.driver_candidates(driver))
  else
    collect_source_candidates(candidates, "driver", driver and driver.id or nil, spec.driver_candidates)
  end

  for _, item in ipairs(candidates) do
    local resolved, reason = probe(item.candidate, item, driver)
    diagnostics[#diagnostics + 1] = {
      source = item.source,
      source_key = item.source_key,
      candidate = item.candidate,
      resolved = resolved,
      available = resolved ~= nil,
      reason = resolved and nil or reason,
    }
    if resolved then
      return {
        ok = true,
        status = "ok",
        tool = spec.name,
        host_id = driver and driver.id or nil,
        path = resolved,
        candidate = item.candidate,
        source = item.source,
        source_key = item.source_key,
        diagnostics = diagnostics,
      }
    end
  end

  return {
    ok = false,
    status = "unavailable",
    tool = spec.name,
    host_id = driver and driver.id or nil,
    reason = spec.reason or "tool-not-found",
    diagnostics = diagnostics,
    candidates = copy_list(vim.tbl_map(function(item) return item.candidate end, candidates)),
  }
end

--- Test seam: force a different driver by id. Returns the previous driver.
---@param id string
---@return PlatformDriver previous
function M._set_driver_for_test(id)
  local prev = _drivers[M.id]
  _drivers[M.id] = load_driver(id)
  return prev
end

---Return a concrete fixture through the same registry loader without mutating
---the active host selection. Production callers must use `driver()`.
---@param id string
---@return PlatformDriver
function M._driver_for_test(id)
  return load_driver(id)
end

return M
