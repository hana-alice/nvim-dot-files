local M = {
  owner = "ios.semantic",
  operation = "semantic_cdb",
}

function M.ios_setup_is_ready(ctx, dependencies)
  dependencies = dependencies or {}
  local state_reader = dependencies.read_state
  local state = state_reader(ctx.engine_root)
  local signing = type(state.ios_signing_identity) == "table" and state.ios_signing_identity or {}
  local runtimes = type(state.target_runtime) == "table" and state.target_runtime or {}
  local runtime = type(runtimes.IOS) == "table" and runtimes.IOS or {}
  if
    tostring(signing.fingerprint or ""):match("^%s*$")
    or tostring(runtime.device_id or ""):match("^%s*$")
    or tostring(runtime.device_backend or ""):match("^%s*$")
    or tostring(runtime.setup_verified_at or ""):match("^%s*$")
    or runtime.setup_signing_fingerprint ~= signing.fingerprint
  then
    return false
  end

  local driver = dependencies.driver or require("ue.targets").must_get("IOS")
  local prepared = driver.prepared_signing_identity(ctx.project_root)
  if not (prepared.ok == true and prepared.found == true and prepared.identity.fingerprint == signing.fingerprint) then
    return false
  end
  if runtime.device_backend == "legacy-mobiledevice" then
    local resolve_install_script = dependencies.resolve_legacy_install_script
    if type(resolve_install_script) ~= "function" then
      return false
    end
    local script = resolve_install_script(ctx)
    if not script then
      return false
    end
  end
  return true
end

local function tuple_matches(ctx, target_ctx, evidence)
  if type(evidence) ~= "table" then
    return false
  end
  return evidence.project_root == ctx.project_root
    and evidence.uproject == ctx.uproject
    and evidence.target == target_ctx.target
    and evidence.platform == target_ctx.platform
    and evidence.configuration == target_ctx.configuration
    and tostring(evidence.completed_at or "") ~= ""
end

function M.apple_build_evidence_matches(ctx, target_ctx, dependencies)
  dependencies = dependencies or {}
  local state_reader = dependencies.read_state
  local evidence = state_reader(ctx.engine_root).apple_semantic_build
  if tuple_matches(ctx, target_ctx, evidence) then
    return true, evidence
  end

  local driver = dependencies.driver or require("ue.targets").driver(target_ctx.platform)
  if not driver or type(driver.build_receipt_evidence) ~= "function" then
    return false, "no target-specific UBT receipt recovery is available"
  end
  local recovered, recovery_err = driver.build_receipt_evidence(target_ctx)
  if type(recovered) ~= "table" then
    return false, recovery_err
  end
  recovered = vim.deepcopy(recovered)
  recovered.project_root = ctx.project_root
  recovered.uproject = ctx.uproject
  if not tuple_matches(ctx, target_ctx, recovered) then
    return false, "recovered UBT receipt does not match the current project tuple"
  end

  local state_writer = dependencies.update_state_field
  local recorded, record_err = state_writer(ctx.engine_root, "apple_semantic_build", recovered)
  if not recorded then
    return false, "successful UBT receipt found but could not persist build evidence: " .. tostring(record_err)
  end
  local notify = dependencies.notify or vim.notify
  notify(
    ("Recovered successful %s %s build evidence from UBT receipt."):format(
      target_ctx.platform,
      target_ctx.configuration
    ),
    vim.log.levels.INFO,
    { title = "UEPrepare" }
  )
  return true, recovered
end

function M.prepare(ctx, opts, on_done, deps)
  opts = opts or {}
  on_done = on_done or function() end
  local target_ctx, target_err = deps.target_context(ctx)
  if not target_ctx then
    on_done(false, target_err)
    return nil
  end

  local host_driver = require("utils.platform").driver()
  local targets = require("ue.targets")
  if not targets.supports(target_ctx.platform, "semantic_cdb", host_driver) then
    on_done(true, { skipped = true })
    return true
  end

  local evidence_ok, evidence_err = M.apple_build_evidence_matches(ctx, target_ctx, {
    read_state = deps.read_state,
    update_state_field = deps.update_state_field,
    driver = require("ue.targets").driver(target_ctx.platform),
  })
  if not evidence_ok then
    local message = ("No successful %s %s build evidence for the current tuple; run <leader>ub and wait for it to finish, then run :UEPrepare."):format(
      target_ctx.platform,
      target_ctx.configuration
    )
    if tostring(evidence_err or "") ~= "" then
      message = message .. " " .. tostring(evidence_err)
    end
    on_done(false, message)
    return nil
  end

  local expected = {
    engine_root = ctx.engine_root,
    project_root = ctx.project_root,
  }
  local function generate()
    if deps.ue_build_running() then
      on_done(false, "UE build started while UEPrepare was preparing Apple semantic evidence")
      return
    end
    deps.generate_semantic_cdb_after_build(function(ok, info)
      on_done(ok, info)
    end, expected)
  end
  local function after_setup()
    if opts._clangd_verified then
      generate()
      return
    end
    deps.run_clangd_preflight(function(ok, preflight_err)
      if not ok then
        on_done(false, preflight_err)
        return
      end
      generate()
    end)
  end

  if
    target_ctx.platform == "IOS"
    and not M.ios_setup_is_ready(ctx, {
      read_state = deps.read_state,
      driver = require("ue.targets").must_get("IOS"),
      resolve_legacy_install_script = deps.resolve_legacy_install_script,
    })
  then
    deps.setup_ios({
      on_done = function(ok, setup_err)
        if not ok then
          on_done(false, setup_err, true)
          return
        end
        after_setup()
      end,
    })
    return
  end

  after_setup()
end

function M.run(request)
  local payload = request.payload or {}
  return M.prepare(request.context, payload.opts, payload.on_done, request.deps)
end

return M
