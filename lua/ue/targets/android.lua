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

local function find_target_so(context)
  local receipt_so, receipt_present = so_from_receipt(context)
  if receipt_present then
    return receipt_so
  end
  local exact = C.join_path(
    context.project_dir,
    "Binaries",
    M.id,
    ("%s-%s-%s-arm64.so"):format(C.context_target(context), M.id, C.context_configuration(context))
  )
  return is_file(exact) and exact or nil
end

function M.capabilities()
  return C.default_capabilities(M.id, {
    build = true,
  })
end

function M.build_plan(context, host_driver)
  context = context or {}
  local entry, unavailable = C.resolve_host_entry(host_driver, "ue_build_entry", context, M.id, "build")
  if not entry then
    return unavailable
  end

  local target_name = C.context_target(context)
  local configuration = C.context_configuration(context)
  return C.with_appended_args(entry, {
    target_name,
    M.id,
    configuration,
    "-Project=" .. C.trim(context.uproject),
    "-WaitMutex",
    "-FromMsBuild",
  }, {
    target = target_name,
    platform = M.id,
    configuration = configuration,
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

  local source_so = find_target_so(context)
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
