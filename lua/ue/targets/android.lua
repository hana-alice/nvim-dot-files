local C = require("ue.targets._common")

local M = {
  id = "Android",
  host_operations = {
    windows = {
      build = true,
      so_build = true,
      so_deploy = true,
      install = true,
      launch = true,
      log = true,
      dap_attach = true,
      dap_launch = true,
    },
  },
  runtime = {
    launch = { strategy = "workflow" },
    main_log = { strategy = "android-logcat" },
    debug_log = { strategy = "unavailable" },
  },
}

local HOST_ADAPTERS = {
  windows = require("ue.targets.android_windows"),
}

local function host_adapter(host_driver, operation)
  local host_id = type(host_driver) == "table" and host_driver.id or nil
  local adapter = HOST_ADAPTERS[host_id]
  if adapter then
    return adapter
  end
  return nil, C.unavailable(M.id, operation, "unsupported Android host adapter", {
    host_id = host_id,
  })
end

local function is_file(path)
  local stat = (vim.uv or vim.loop).fs_stat(path)
  return stat and stat.type == "file" or false
end

local function path_has_prefix(path, root)
  path = C.normalize_path(path):lower():gsub("/+$", "")
  root = C.normalize_path(root):lower():gsub("/+$", "")
  return path == root or path:sub(1, #root + 1) == root .. "/"
end

local function so_from_receipt(context)
  local project_dir = C.normalize_path(context.project_dir)
  local target = C.context_target(context)
  local configuration = C.context_configuration(context)
  local binaries_dir = C.join_path(project_dir, "Binaries", M.id)
  local receipt_path = C.join_path(binaries_dir, target .. ".target")
  if not is_file(receipt_path) then
    return nil, false
  end

  local file = io.open(receipt_path, "rb")
  if not file then
    return nil, true
  end
  local content = file:read("*a")
  file:close()

  local ok, receipt = pcall(vim.json.decode, content or "")
  if not ok or type(receipt) ~= "table" then
    return nil, true
  end
  if receipt.TargetName ~= target or receipt.Platform ~= M.id or receipt.Configuration ~= configuration then
    return nil, true
  end

  local expected = {
    [(target .. "-arm64.so"):lower()] = true,
    [(("%s-%s-%s-arm64.so"):format(target, M.id, configuration)):lower()] = true,
  }
  local function resolve_product(raw_path)
    if type(raw_path) ~= "string" then
      return nil
    end
    local normalized = C.normalize_path(raw_path)
    local prefix = "$(ProjectDir)/"
    if normalized:sub(1, #prefix) ~= prefix then
      return nil
    end
    local candidate = C.join_path(project_dir, normalized:sub(#prefix + 1))
    local basename = vim.fs.basename(candidate):lower()
    if not path_has_prefix(candidate, binaries_dir) or not expected[basename] then
      return nil
    end
    return is_file(candidate) and candidate or nil
  end

  local launch = resolve_product(receipt.Launch)
  if launch then
    return launch, true
  end
  local candidates, seen = {}, {}
  for _, product in ipairs(receipt.BuildProducts or {}) do
    if type(product) == "table" and product.Type == "Executable" then
      local candidate = resolve_product(product.Path)
      if candidate and not seen[candidate] then
        seen[candidate] = true
        candidates[#candidates + 1] = candidate
      end
    end
  end
  return #candidates == 1 and candidates[1] or nil, true
end

local function qualified_target_so(context)
  local exact = C.join_path(
    context.project_dir,
    "Binaries",
    M.id,
    ("%s-%s-%s-arm64.so"):format(C.context_target(context), M.id, C.context_configuration(context))
  )
  return is_file(exact) and exact or nil
end

local function fallback_target_so(context)
  local qualified = qualified_target_so(context)
  if C.context_configuration(context) ~= "Development" then return qualified end
  local short = C.join_path(
    context.project_dir, "Binaries", M.id, C.context_target(context) .. "-arm64.so")
  short = is_file(short) and short or nil
  -- With no receipt, two plausible artifacts are ambiguous rather than mtime-ranked.
  if short and qualified and short ~= qualified then return nil end
  return short or qualified
end

function M.find_target_so(context)
  context = context or {}
  local receipt_so, receipt_present = so_from_receipt(context)
  if receipt_present then
    return receipt_so
  end
  return fallback_target_so(context)
end

-- DAP may need symbols for the configuration selected in the engine cache even
-- when `<Target>.target` currently describes a later build of another config.
-- A config-qualified filename is unambiguous, so symbol lookup may consume it;
-- deployment remains stricter and still refuses a receipt mismatch above.
function M.find_symbol_artifact(context)
  context = context or {}
  local receipt_so, receipt_present = so_from_receipt(context)
  if receipt_so then return receipt_so end
  if receipt_present and C.context_configuration(context) == "Development" then
    -- A mismatched current receipt means the generic `<Target>-arm64.so` may
    -- belong to that other configuration. Only a config-qualified file is safe.
    return qualified_target_so(context)
  end
  return fallback_target_so(context)
end

function M.capabilities()
  return C.default_capabilities(M.id, {
    build = true,
  })
end

-- Read only bounded text; callers distinguish absence from a broken policy.
local function read_sdk_text(path)
  local stat, stat_err, code = vim.uv.fs_stat(path)
  if not stat then
    if code == "ENOENT" or code == "ENOTDIR" then return false end
    return nil, "Cannot read SDK configuration: " .. tostring(stat_err)
  end
  local file, open_err = io.open(path, "rb")
  if not file then return nil, "Cannot read SDK configuration: " .. tostring(open_err) end
  local content, read_err = file:read(65537)
  file:close()
  if read_err then return nil, "Cannot read SDK configuration: " .. tostring(read_err) end
  content = content or ""
  if #content > 65536 then return nil, "SDK configuration exceeds 64 KiB" end
  if content:find("\0", 1, true) then return nil, "SDK configuration must be UTF-8 or ASCII" end
  return content:gsub("^\239\187\191", "")
end

-- Private project paths/keys/flags live outside the worktree. Both the policy
-- and selected project's INI are read afresh; nothing is inferred from another checkout.
local function sdk_argument(context)
  local project = C.normalize_path(context.uproject)
  if project == "" then return "" end
  local policy_path = require("ue.config").get("android.sdk_policy_file")
  if type(policy_path) ~= "string" or policy_path == "" then return nil, "SDK policy path is not configured" end
  local raw, policy_err = read_sdk_text(policy_path)
  if raw == false then return "" end
  if not raw then return nil, policy_err end
  local ok, policy = pcall(vim.json.decode, raw)
  if not ok or type(policy) ~= "table" then return nil, "Invalid local SDK policy JSON" end
  if type(policy.config_file) ~= "string" or policy.config_file == ""
      or type(policy.key) ~= "string" or not policy.key:match("^[%w_]+$")
      or type(policy.disable_argument) ~= "string" or not policy.disable_argument:match("^%-[%w_.=%-]+$") then
    return nil, "SDK policy requires config_file, key and a single safe disable_argument"
  end
  local relative = C.normalize_path(policy.config_file)
  if relative:sub(1, 1) == "/" or relative:find(":", 1, true) then
    return nil, "SDK policy config_file must be project-relative"
  end
  for part in relative:gmatch("[^/]+") do
    if part == ".." then return nil, "SDK policy config_file must stay inside the selected project" end
  end
  local content, config_err = read_sdk_text(C.join_path(vim.fs.dirname(project), relative))
  if content == false then return "" end
  if not content then return nil, config_err end
  local selected
  for line in (content .. "\n"):gmatch("(.-)\n") do
    local key, value = line:match("^%s*([^=]+)=(.-)%s*$")
    if key and C.trim(key):lower() == policy.key:lower() then
      value = C.trim(value:gsub("[;#].*$", ""))
      if value ~= "0" and value ~= "1" then return nil, "SDK setting must be 0 or 1" end
      if selected and selected ~= value then return nil, "Conflicting SDK setting values" end
      selected = value
    end
  end
  return selected == "0" and policy.disable_argument or ""
end

function M.build_plan(context, host_driver)
  context = context or {}
  local entry, unavailable = C.resolve_host_entry(host_driver, "ue_build_entry", context, M.id, "build")
  if not entry then
    return unavailable
  end

  local target_name = C.context_target(context)
  local configuration = C.context_configuration(context)
  local sdk_arg, sdk_err = sdk_argument(context)
  if sdk_arg == nil then return C.unavailable(M.id, "build", sdk_err) end
  local args = {
    target_name,
    M.id,
    configuration,
    "-Project=" .. C.trim(context.uproject),
    "-WaitMutex",
    "-FromMsBuild",
  }
  if sdk_arg ~= "" then args[#args + 1] = sdk_arg end
  return C.with_appended_args(entry, args, {
    target = target_name,
    platform = M.id,
    configuration = configuration,
    sdk_disabled = sdk_arg ~= "",
  })
end

function M.so_build_plan(context, host_driver)
  context = context or {}
  if C.trim(context.engine_root) == "" or C.trim(context.uproject) == "" then
    return C.unavailable(M.id, "so-build", "Android SO build requires engine_root and uproject", {
      required = { "engine_root", "uproject" },
    })
  end
  local adapter, unavailable = host_adapter(host_driver, "so-build")
  if not adapter then
    return unavailable
  end
  local adapter_context = C.deepcopy(context)
  local sdk_arg, sdk_err = sdk_argument(context)
  if sdk_arg == nil then return C.unavailable(M.id, "so-build", sdk_err) end
  adapter_context.sdk_argument = sdk_arg
  adapter_context.host_driver = host_driver
  return adapter.so_build_plan(adapter_context)
end

function M.classify_rsp(candidate, context)
  return C.classify_for_platform(M.id, M.id, candidate, context)
end

function M.so_deploy_plan(context, host_driver)
  context = context or {}
  local serial = C.trim(context.device_id or context.serial)
  local package_name = C.trim(context.package_name or context.android_package)
  if serial == "" then
    return C.unavailable(M.id, "so-deploy", "Android device is not selected; run :UESetAndroidDevice")
  end
  if package_name == "" then
    return C.unavailable(M.id, "so-deploy", "Android package is not configured; run :UESetAndroidPackage")
  end

  local source_so = M.find_target_so(context)
  if not source_so then
    return C.unavailable(M.id, "so-deploy", "Android SO not found; run :UEBuildAndroidSO first")
  end
  local adapter, unavailable = host_adapter(host_driver, "so-deploy")
  if not adapter then
    return unavailable
  end
  local adapter_context = C.deepcopy(context)
  adapter_context.device_id = serial
  adapter_context.package_name = package_name
  adapter_context.source_so = source_so
  adapter_context.host_driver = host_driver
  adapter_context.is_file = is_file
  return adapter.so_deploy_plan(adapter_context)
end

local function adapter_plan(operation, context, host_driver)
  context = context or {}
  local serial = C.trim(context.device_id or context.serial)
  local package_name = C.trim(context.package_name or context.android_package)
  if serial == "" then
    return C.unavailable(M.id, operation, "Android device is not selected; run :UESetAndroidDevice")
  end
  if package_name == "" then
    return C.unavailable(M.id, operation, "Android package is not configured; run :UESetAndroidPackage")
  end
  local adapter, unavailable = host_adapter(host_driver, operation)
  if not adapter then
    return unavailable
  end
  local adapter_context = C.deepcopy(context)
  adapter_context.device_id = serial
  adapter_context.package_name = package_name
  adapter_context.host_driver = host_driver
  adapter_context.is_file = is_file
  return adapter[operation .. "_plan"](adapter_context)
end

function M.launch_plan(context, host_driver)
  return adapter_plan("launch", context, host_driver)
end

function M.log_plan(context, host_driver)
  return adapter_plan("log", context, host_driver)
end

function M.install_plan(context, host_driver)
  context = context or {}
  local serial = C.trim(context.device_id or context.serial)
  local apk = C.trim(context.apk or context.artifact)
  if serial == "" then
    return C.unavailable(M.id, "install", "Android device is not selected; run :UESetAndroidDevice")
  end
  if apk == "" then
    return C.unavailable(M.id, "install", "Android APK artifact is missing")
  end
  local adapter, unavailable = host_adapter(host_driver, "install")
  if not adapter then
    return unavailable
  end
  local adapter_context = C.deepcopy(context)
  adapter_context.device_id = serial
  adapter_context.apk = apk
  adapter_context.host_driver = host_driver
  return adapter.install_plan(adapter_context)
end

M.package_plan = C.unsupported_operation(M.id, "package")
M.device_list_plan = C.unsupported_operation(M.id, "device")

function M.preflight_descriptors()
  return {
    {
      stage = "build",
      requires = {
        { host_capability = "ue_build_entry" },
      },
    },
  }
end

return M
