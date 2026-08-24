local Common = require("ue.workflows.ios.common")

local M = {
  owner = "ios.setup",
  operation = "setup",
}

function M.setup(opts, deps)
  opts = opts or {}
  local settled = false
  local function finish(ok, detail)
    if settled then
      return
    end
    settled = true
    if type(opts.on_done) == "function" then
      opts.on_done(ok, detail)
    end
  end
  local function fail(message)
    deps.target_error("ue.ios.setup", message)
    finish(false, message)
  end
  local ctx, err = deps.resolve_context()
  if not ctx or not ctx.project_root then
    fail(err or "No project configured. Run :UESetProject [path]")
    return
  end
  local setup_engine_root = ctx.engine_root
  local setup_project_root = ctx.project_root
  if deps.target_platform(setup_engine_root, nil) ~= "IOS" then
    if not deps.set_platform("IOS", { stage_next = false }) then
      fail("failed to set IOS target")
      return
    end
  end

  deps.select_ios_signing_certificate("", false, {
    require_prepared = true,
    expected_engine_root = setup_engine_root,
    expected_project_root = setup_project_root,
    on_error = function(setup_err)
      finish(false, setup_err)
    end,
    on_selected = function(identity)
      deps.select_target_device("IOS", {
        auto_select_single = true,
        expected_engine_root = setup_engine_root,
        expected_project_root = setup_project_root,
        on_error = function(setup_err)
          finish(false, setup_err)
        end,
        on_selected = function(device, driver)
          local current = deps.resolve_context()
          if not deps.target_context_matches(current, setup_engine_root, setup_project_root) then
            fail("project changed during IOS setup; rerun :UEPrepare")
            return
          end
          if device.backend == "legacy-mobiledevice" then
            local script, script_err = Common.resolve_legacy_install_script(current)
            if not script then
              fail(script_err)
              return
            end
          end
          local runtime, update_err = deps.update_target_runtime(setup_engine_root, driver.id, {
            setup_verified_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
            setup_signing_fingerprint = identity.fingerprint,
          })
          if not runtime then
            fail(update_err)
            return
          end
          vim.notify(
            ("IOS setup ready: signing/private key and %s device route verified; UEPrepare will continue with Apple compiler semantics"):format(
              device.backend or "coredevice"
            ),
            vim.log.levels.INFO
          )
          finish(true, {
            device = device,
            signing_identity = identity,
          })
        end,
      })
    end,
  })
end

function M.run(request)
  local payload = request.payload or {}
  return M.setup(payload.opts, request.deps)
end

return M
