local runtime = require("ue.workflows._runtime")

local M = {
  owner = "android.build",
}

local function trim(value)
  return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function project_dir(ctx)
  local uproject = trim(ctx and ctx.uproject)
  if uproject ~= "" then
    return vim.fn.fnamemodify(uproject, ":h")
  end
  return trim(ctx and ctx.project_root)
end

local function gradle_patterns(ctx, join)
  local root = project_dir(ctx)
  if root == "" then
    return {}
  end
  local build_dir = join(root, "Intermediate", "Android", "*", "gradle", "app", "build")
  return {
    join(build_dir, "outputs", "apk", "app-debug.apk"),
    join(build_dir, "outputs", "apk", "debug", "app-debug.apk"),
    join(build_dir, "outputs", "apk", "app-release.apk"),
    join(build_dir, "outputs", "apk", "release", "app-release.apk"),
    join(build_dir, "intermediates", "apk", "app-debug.apk"),
    join(build_dir, "intermediates", "apk", "debug", "app-debug.apk"),
    join(build_dir, "intermediates", "incremental", "packageDebug"),
    join(build_dir, "intermediates", "incremental", "debug", "packageDebug"),
    join(build_dir, "intermediates", "incremental", "packageRelease"),
    join(build_dir, "intermediates", "incremental", "release", "packageRelease"),
    join(build_dir, "intermediates", "app_metadata"),
    join(build_dir, "intermediates", "merged_manifest"),
    join(build_dir, "intermediates", "packaged_manifests"),
  }
end

local function dependencies(request)
  local deps = request.deps or request.context or {}
  return {
    glob = deps.glob or function(pattern)
      local matches = vim.fn.glob(pattern, false, true)
      return type(matches) == "table" and matches or {}
    end,
    delete = deps.delete or function(path)
      return vim.fn.delete(path, "rf") == 0
    end,
    join = deps.join or require("ue.core.fs").join,
    stop_debugger = deps.stop_debugger or function(opts)
      return require("ue.dap").stop_android_debugger(opts)
    end,
    notify = deps.notify or vim.notify,
  }
end

local function cleanup_gradle(ctx, deps)
  local failures = {}
  local removed = {}
  local seen = {}
  for _, pattern in ipairs(gradle_patterns(ctx, deps.join)) do
    for _, path in ipairs(deps.glob(pattern) or {}) do
      if not seen[path] then
        seen[path] = true
        local ok, deleted = pcall(deps.delete, path)
        if ok and deleted ~= false and deleted ~= nil then
          removed[#removed + 1] = path
        else
          failures[#failures + 1] = path
        end
      end
    end
  end
  if #failures > 0 then
    return nil, "Failed to clean stale Gradle artifacts: " .. table.concat(failures, ", "), removed
  end
  return removed
end

local function snapshot(request, ctx)
  return request.snapshot
    or runtime.snapshot({
      operation = request.operation,
      owner = M.owner,
      project = { canonical = trim(ctx.project_root or ctx.engine_root) },
      target = { id = request.target_id },
      configuration = trim(request.payload and request.payload.configuration),
      host = { id = request.host_driver and request.host_driver.id or "" },
      context = {
        engine_root = trim(ctx.engine_root),
        project_root = trim(ctx.project_root),
        uproject = trim(ctx.uproject),
      },
    })
end

function M.run(request)
  local payload = request.payload or {}
  local ctx = payload.context
  if type(ctx) ~= "table" then
    return nil, "Android build workflow requires a resolved project context"
  end
  local frozen = snapshot(request, ctx)
  local deps = dependencies(request)
  local cleanup = deps.stop_debugger({ kill_orphans = true }) or {}

  local removed = {}
  if request.operation ~= "so_build" then
    local clean_err
    removed, clean_err = cleanup_gradle(ctx, deps)
    if not removed then
      return nil, clean_err, frozen
    end
  end

  local parts = {}
  if cleanup.disconnected then
    parts[#parts + 1] = "detached active DAP"
  end
  if cleanup.adapter_killed then
    parts[#parts + 1] = "stopped lldb-dap adapter"
  end
  if tonumber(cleanup.orphan_killed or 0) > 0 then
    parts[#parts + 1] = ("killed %d stale lldb-dap process%s"):format(
      cleanup.orphan_killed,
      cleanup.orphan_killed == 1 and "" or "es"
    )
  end
  if #parts > 0 then
    deps.notify("Android build preflight: " .. table.concat(parts, ", "), vim.log.levels.INFO)
  end
  return {
    ok = true,
    removed = removed,
    cleanup = cleanup,
    snapshot = frozen,
  }
end

function M._cleanup_gradle_for_test(ctx, deps)
  return cleanup_gradle(ctx, deps)
end

return M
