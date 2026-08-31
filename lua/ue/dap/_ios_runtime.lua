-- ue.dap._ios_runtime — freeze one iOS DAP context before async bootstrap.
local M = {}

local function trim(value)
  return vim.trim(tostring(value or ""))
end

local function executable(name, override)
  local candidate = trim(override)
  if candidate ~= "" then
    if vim.fn.executable(candidate) == 1 then
      return vim.fs.normalize(vim.fn.exepath(candidate) ~= "" and vim.fn.exepath(candidate) or candidate)
    end
    return nil
  end
  if vim.fn.executable(name) ~= 1 then
    return nil
  end
  local path = vim.fn.exepath(name)
  return path ~= "" and vim.fs.normalize(path) or nil
end

local function context_from_opts(opts)
  if type(opts.context) == "table" then
    return opts.context
  end
  local explicit = trim(opts.device_id) ~= ""
    and trim(opts.bundle_id) ~= ""
    and trim(opts.device_backend) ~= ""
    and trim(opts.binary) ~= ""
  if explicit then
    return {}
  end
  local ok, resolved, err = pcall(function()
    local value, resolve_err = require("ue").resolve_context()
    return value, resolve_err
  end)
  if not ok then
    return nil, tostring(resolved)
  end
  if not resolved then
    return nil, err or "no UE project context"
  end
  return resolved
end

function M.resolve(opts)
  opts = opts or {}
  local ios_target = require("ue.targets").must_get("IOS")
  local ctx, context_err = context_from_opts(opts)
  if not ctx then
    return nil, context_err
  end
  local state = type(ctx.state) == "table" and ctx.state or {}
  local runtimes = type(state.target_runtime) == "table" and state.target_runtime or {}
  local persisted = type(runtimes.IOS) == "table" and runtimes.IOS or {}
  local device_id = trim(opts.device_id or persisted.device_id)
  local bundle_id = trim(opts.bundle_id or persisted.bundle_id)
  local backend = trim(opts.device_backend or persisted.device_backend)
  if device_id == "" then
    return nil, "run :UESetIOSDevice first (missing persisted device id)"
  end
  if bundle_id == "" then
    return nil, "run :UEInstallIOS first (missing persisted bundle id)"
  end
  if backend ~= "legacy-mobiledevice" and backend ~= "coredevice" then
    return nil, "iOS DAP requires the selected coredevice or legacy-mobiledevice route"
  end

  local uproject = trim(opts.uproject or ctx.uproject or state.uproject)
  local project_dir = trim(opts.cwd or opts.project_dir)
  if project_dir == "" and uproject ~= "" then
    project_dir = vim.fs.dirname(uproject)
  end
  local target = trim(opts.target)
  if target == "" and uproject ~= "" then
    target = vim.fn.fnamemodify(uproject, ":t:r")
  end
  local binary = trim(opts.binary)
  if binary == "" and project_dir ~= "" and target ~= "" then
    local artifacts = ios_target.dap_artifacts({ project_dir = project_dir, target = target })
    binary = artifacts and artifacts.binary or ""
  end
  if binary == "" then
    return nil, "iOS DAP could not resolve the local symbol binary"
  end
  binary = vim.fs.normalize(binary)
  if vim.fn.filereadable(binary) ~= 1 then
    return nil, "local iOS symbol binary is missing: " .. binary
  end
  if project_dir == "" then
    project_dir = vim.fs.dirname(binary)
  end
  if target == "" then
    target = vim.fs.basename(binary)
  end

  local dsym = trim(opts.dsym)
  if dsym == "" then
    local artifacts = ios_target.dap_artifacts({ project_dir = project_dir, target = target })
    dsym = artifacts and artifacts.binary == binary and artifacts.dsym or (binary .. ".dSYM")
  end
  dsym = vim.fs.normalize(dsym)
  if backend == "coredevice" and vim.fn.isdirectory(dsym) ~= 1 and vim.fn.filereadable(dsym) ~= 1 then
    return nil, "local iOS dSYM is missing: " .. dsym
  end

  local tool_names = assert(ios_target.dap_tool_names(backend))
  local tools = {}
  for key, name in pairs(tool_names) do
    local path = executable(name, opts[key])
    if not path then
      return nil, name .. " is not installed or not executable"
    end
    tools[key] = path
  end

  local requested_pid
  if opts.pid ~= nil and trim(opts.pid) ~= "" then
    requested_pid = tonumber(opts.pid)
    if not requested_pid or requested_pid <= 0 or requested_pid % 1 ~= 0 then
      return nil, "iOS DAP pid must be a positive integer"
    end
  end
  return {
    adapter = trim(opts.adapter) ~= "" and vim.fs.normalize(opts.adapter) or nil,
    backend = backend,
    binary = binary,
    bundle_id = bundle_id,
    context = vim.deepcopy(ctx),
    cwd = vim.fs.normalize(project_dir),
    device_id = device_id,
    dsym = dsym,
    project = {
      configuration = trim(opts.configuration or state.configuration),
      project_dir = vim.fs.normalize(project_dir),
      target = target,
      uproject = uproject ~= "" and vim.fs.normalize(uproject) or nil,
    },
    requested_pid = requested_pid,
    source = trim(opts.source or opts.source_path) ~= "" and vim.fs.normalize(opts.source or opts.source_path) or nil,
    source_roots = vim.deepcopy(opts.source_roots or ctx.paths or {}),
    target = target,
    tools = tools,
  }
end

function M.query_adapter(runtime, system_async, callback)
  if trim(runtime.adapter) ~= "" then
    if vim.fn.executable(runtime.adapter) == 1 then
      callback(runtime.adapter)
    else
      callback(nil, "configured lldb-dap is not executable")
    end
    return
  end
  system_async({ runtime.tools.xcrun, "--find", "lldb-dap" }, {}, function(result)
    local adapter = trim(result.stdout)
    if result.code ~= 0 or adapter == "" or vim.fn.executable(adapter) ~= 1 then
      callback(nil, "selected Xcode does not provide an executable lldb-dap")
      return
    end
    callback(vim.fs.normalize(adapter))
  end)
end

return M
