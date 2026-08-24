local M = {
  owner = "ios.signing",
  operation = "signing",
}

function M.select(query, clear, opts, deps)
  opts = type(opts) == "table" and opts or { on_selected = opts }
  local function fail(message)
    deps.target_error("ue.ios.signing", message)
    if type(opts.on_error) == "function" then
      opts.on_error(message)
    end
  end

  query = deps.trim(query or "")
  local ctx, err = deps.resolve_context()
  if not ctx or not ctx.project_root then
    fail(err or "No project configured. Run :UESetProject [path]")
    return
  end
  if clear then
    if query ~= "" then
      fail("bang clears the selection and cannot be combined with an identity")
      return
    end
    local ok, update_err = deps.update_state_field(ctx.engine_root, "ios_signing_identity", nil)
    if not ok then
      fail(update_err)
      return
    end
    deps.reset_context_cache()
    vim.notify("IOS signing certificate selection cleared", vim.log.levels.INFO)
    return true
  end

  local host_driver = require("utils.platform").driver()
  local driver, unavailable = require("ue.targets").resolve("IOS", "package", host_driver)
  if not driver then
    fail(unavailable.reason)
    return
  end

  local prepared_identity
  if query == "" then
    local prepared = driver.prepared_signing_identity(ctx.project_root)
    if not prepared.ok then
      fail(prepared.reason .. "; rerun PrepareIOSQADebug.sh or pass an identity explicitly")
      return
    end
    if opts.require_prepared and not prepared.found then
      fail("prepared signing metadata is missing; rerun PrepareIOSQADebug.sh, then rerun :UEPrepare")
      return
    end
    if prepared.found then
      prepared_identity = prepared.identity
      query = prepared.identity.fingerprint
    end
  end

  local plan = driver.signing_identity_list_plan(ctx, host_driver)
  if type(plan) ~= "table" or plan.ok == false then
    fail(plan and plan.reason or "signing identity probe is unavailable")
    return
  end

  local function persist(identity)
    if
      opts.expected_engine_root
      and not deps.target_context_matches(deps.resolve_context(), opts.expected_engine_root, opts.expected_project_root)
    then
      fail("project changed during IOS setup; rerun :UEPrepare")
      return
    end
    local validated = driver.validate_signing_identity(identity)
    if not validated.ok then
      fail(validated.reason)
      return
    end
    identity = validated.identity
    local target_ctx, context_err = deps.target_context(ctx, "IOS", {
      signing_identity = identity,
    })
    if not target_ctx then
      fail(context_err)
      return
    end
    deps.run_target_preflight(driver, "build", target_ctx, host_driver, function(ok, preflight_err)
      if not ok then
        fail("IOS signing access preflight failed: " .. tostring(preflight_err))
        return
      end
      if
        opts.expected_engine_root
        and not deps.target_context_matches(
          deps.resolve_context(),
          opts.expected_engine_root,
          opts.expected_project_root
        )
      then
        fail("project changed during IOS setup; rerun :UEPrepare")
        return
      end
      local value = {
        fingerprint = identity.fingerprint,
        name = identity.name,
        selected_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        selected_from = prepared_identity and "PrepareIOSQADebug" or "keychain",
      }
      local updated, update_err = deps.update_state_field(ctx.engine_root, "ios_signing_identity", value)
      if not updated then
        fail(update_err)
        return
      end
      deps.reset_context_cache()
      local suffix = prepared_identity and " from PrepareIOSQADebug metadata" or ""
      vim.notify(
        "IOS signing certificate and private-key access verified for the current project" .. suffix,
        vim.log.levels.INFO
      )
      if type(opts.on_selected) == "function" then
        opts.on_selected(identity)
      end
    end)
  end

  local handle, run_err = require("ue.target_tasks").run(plan, {
    name = "UE IOS signing identity discovery",
    on_exit = function(result)
      if result.code ~= 0 then
        fail(require("ue.target_tasks").error_message(result))
        return
      end
      local parsed =
        driver.parse_signing_identities(tostring(result.stdout or "") .. "\n" .. tostring(result.stderr or ""))
      if not parsed.ok then
        fail(parsed.reason)
        return
      end
      if #parsed.identities == 0 then
        fail("no valid code-sign identity found in the current keychain")
        return
      end
      if query ~= "" then
        local resolved = driver.resolve_signing_identity(parsed.identities, query)
        if not resolved.ok then
          fail(resolved.reason)
          return
        end
        persist(resolved.identity)
        return
      end
      vim.ui.select(parsed.identities, {
        prompt = "Select IOS code-sign identity:",
        format_item = function(identity)
          return ("%s [%s]"):format(identity.name, identity.fingerprint)
        end,
      }, function(identity)
        if not identity then
          fail("IOS signing identity selection cancelled")
          return
        end
        persist(identity)
      end)
    end,
  })
  if not handle then
    fail(run_err or "signing identity probe failed to start")
  end
  return handle
end

function M.run(request)
  local payload = request.payload or {}
  return M.select(payload.query, payload.clear, payload.opts, request.deps)
end

return M
