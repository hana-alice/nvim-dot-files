local M = {}

local function trim(value)
  return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function norm(value)
  return trim(value):gsub("\\", "/")
end

local function dirname(path)
  local ufs = require("ue.core.fs")
  return ufs.dirname(path)
end

function M.resolve_legacy_install_script(ctx)
  local configured = trim(vim.g.ue_ios_install_script or vim.env.UE_IOS_INSTALL_SCRIPT)
  local candidates = {}
  if configured ~= "" then
    candidates[#candidates + 1] = vim.fn.expand(configured)
  else
    local project_name = vim.fs.basename(ctx.project_root or "")
    local branch_version = project_name:match("(%d+%.%d+)")
    if branch_version then
      candidates[#candidates + 1] =
        norm(vim.fs.joinpath(vim.fn.expand("~/Documents/temp"), branch_version, "InstallIOSClient.sh"))
    end
  end

  for _, candidate in ipairs(candidates) do
    local stat = vim.uv.fs_stat(candidate)
    if stat and stat.type == "file" and vim.fn.executable(candidate) == 1 then
      return norm(candidate)
    end
  end

  if configured ~= "" then
    return nil, "configured legacy InstallIOSClient.sh is missing or not executable: " .. configured
  end
  return nil, "legacy InstallIOSClient.sh was not found for this branch; set vim.g.ue_ios_install_script"
end

function M.resolve_usb_reset_script(ctx)
  local install_script, install_err = M.resolve_legacy_install_script(ctx)
  if not install_script then
    return nil, install_err
  end
  local reset_script = norm(vim.fs.joinpath(dirname(install_script), "ResetIOSUSB.sh"))
  local stat = vim.uv.fs_stat(reset_script)
  if stat and stat.type == "file" and vim.fn.executable(reset_script) == 1 then
    return reset_script
  end
  return nil, "legacy ResetIOSUSB.sh is missing or not executable: " .. reset_script
end

function M.resolve_legacy_launch_script()
  local script = norm(vim.fs.joinpath(vim.fn.stdpath("config"), "scripts", "ue_ios_legacy_launch.zsh"))
  local stat = vim.uv.fs_stat(script)
  if stat and stat.type == "file" then
    return script
  end
  return nil, "legacy IOS launch helper is missing: " .. script
end

function M.prepare_legacy_install(ctx, driver, target_ctx, deps)
  deps = deps or {}
  local script, script_err = M.resolve_legacy_install_script(ctx)
  if not script then
    return nil, script_err
  end

  local prepared = driver.prepared_signing_identity(ctx.project_root)
  if not prepared.ok then
    return nil, prepared.reason
  end
  if not prepared.found then
    return nil, "prepared signing metadata is missing; run PrepareIOSQADebug.sh"
  end

  local selected = driver.validate_signing_identity(target_ctx.signing_identity)
  if not selected.ok then
    return nil, selected.reason
  end
  if selected.identity.fingerprint ~= prepared.identity.fingerprint then
    return nil, "selected IOS signing identity does not match PrepareIOSQADebug metadata"
  end

  local artifacts = target_ctx.artifacts
  if type(artifacts) ~= "table" or #artifacts == 0 then
    local artifact_err
    artifacts, artifact_err = deps.collect_existing_artifacts(driver, target_ctx)
    if not artifacts or #artifacts == 0 then
      return nil, artifact_err or "no tuple-scoped IOS app exists; run :UEBuildIOS before legacy install"
    end
    for _, artifact in ipairs(artifacts) do
      artifact.metadata = type(artifact.metadata) == "table" and artifact.metadata or {}
      artifact.metadata.source = "legacy-existing-tuple-app"
      artifact.metadata.discovered_for = "legacy-install"
    end
  end

  target_ctx.artifacts = artifacts
  target_ctx.legacy_install_script = script
  target_ctx.legacy_signing = prepared
  return true
end

function M.prepare_legacy_launch(ctx, driver, target_ctx)
  local script, script_err = M.resolve_legacy_launch_script()
  if not script then
    return nil, script_err
  end

  local prepared = driver.prepared_signing_identity(ctx.project_root)
  if not prepared.ok then
    return nil, prepared.reason
  end
  if not prepared.found then
    return nil, "prepared signing metadata is missing; run PrepareIOSQADebug.sh"
  end
  local app = norm(prepared.prepared_app or "")
  local stat = app ~= "" and vim.uv.fs_stat(app) or nil
  if not stat or stat.type ~= "directory" or not vim.uv.fs_stat(vim.fs.joinpath(app, "Info.plist")) then
    return nil, "prepared signed IOS app is unavailable; rerun PrepareIOSQADebug.sh"
  end

  target_ctx.legacy_launch_script = script
  target_ctx.legacy_signing = prepared
  return true
end

function M.with_target_bundle_id(ctx, driver, target_ctx, host_driver, on_done, dependencies)
  dependencies = dependencies or {}
  local artifacts = target_ctx.artifacts
  if target_ctx.device_backend == "legacy-mobiledevice" then
    local signing = target_ctx.legacy_signing or {}
    local validated = driver.validate_bundle_id(signing.bundle_identifier)
    if not validated.ok then
      on_done(nil, nil, validated.reason)
      return
    end
    local installed = driver.validate_bundle_id(target_ctx.bundle_id)
    if installed.ok and installed.bundle_id ~= validated.bundle_id then
      on_done(nil, nil, "installed IOS bundle does not match prepared signing metadata")
      return
    end
    on_done(validated.bundle_id, type(artifacts) == "table" and artifacts or {})
    return
  end
  if type(artifacts) ~= "table" or #artifacts == 0 then
    on_done(nil, nil, "no artifact provenance from a successful package task; run :UEPackage" .. driver.id)
    return
  end
  local selected = driver.select_staged_artifact(artifacts, target_ctx)
  if not selected.ok then
    on_done(nil, nil, selected.reason)
    return
  end
  if type(driver.bundle_id_plan) ~= "function" then
    local validated = type(driver.validate_bundle_id) == "function" and driver.validate_bundle_id(target_ctx.bundle_id)
      or { ok = false }
    if validated.ok then
      on_done(validated.bundle_id, artifacts)
      return
    end
    on_done(nil, nil, "bundle identifier probe is unavailable for the selected staged artifact")
    return
  end
  local probe = driver.bundle_id_plan(selected.app_path, host_driver, target_ctx)
  local task_runner = dependencies.task_runner or require("ue.target_tasks")
  local handle, run_err = task_runner.run(probe, {
    name = "UE " .. driver.id .. " bundle identifier",
    on_exit = function(result)
      if result.code ~= 0 then
        on_done(nil, nil, task_runner.error_message(result))
        return
      end
      local bundle = driver.validate_bundle_id(trim(result.stdout))
      if not bundle.ok then
        on_done(nil, nil, bundle.reason)
        return
      end
      on_done(bundle.bundle_id, artifacts)
    end,
  })
  if not handle then
    on_done(nil, nil, run_err or "bundle identifier probe failed to start")
  end
end

function M.ensure_legacy_launch_device(ctx, target_ctx, deps, on_selected)
  return deps.select_target_device("IOS", {
    preferred_device_id = target_ctx.device_id,
    expected_engine_root = ctx.engine_root,
    expected_project_root = ctx.project_root,
    on_selected = function(device)
      on_selected(device)
    end,
  })
end

return M
