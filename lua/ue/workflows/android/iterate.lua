-- Android SO build → deployment → launch/attach, under one immutable owner.
local runtime = require("ue.workflows._runtime")
local M = {}
local active, last, next_id
next_id = 0

local function trim(value)
  return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

--- Complete missing selections before freezing. Selecting a device/package may
--- yield; only the final ready context is captured for downstream work.
function M.capture(steps, done, alive)
  alive = alive or function()
    return true
  end
  if not alive() then
    return
  end
  if type(steps.resolve_context) ~= "function" or type(steps.target_context) ~= "function" then
    return done(nil, "Android loop requires a resolved project and target context")
  end
  local ctx, err = steps.resolve_context()
  if not ctx or not ctx.project_root then
    return done(nil, err or "Select a UE project first (:UESetProject)")
  end
  local devices = steps.android_device or require("utils.android_device")
  local serial = devices.get()
  if not serial then
    return devices.ensure({ prompt = "Select Android device for SO loop:" }, function(selected)
      if not alive() then
        return
      end
      if not selected then
        return done(nil, "device selection cancelled")
      end
      M.capture(steps, done, alive)
    end)
  end
  local state = ctx.state or (steps.read_state and steps.read_state(ctx.engine_root)) or {}
  local package_name = trim(state.android_package)
  if package_name == "" then
    return (steps.pick_package or require("utils.android_package").pick)({
      adb = devices.adb_executable and devices.adb_executable() or "adb",
      serial = serial,
      prompt = "Android package for SO loop:",
    }, function(picked)
      if not alive() then
        return
      end
      if not picked then
        return done(nil, "package selection cancelled")
      end
      local current = steps.resolve_context()
      if not current or current.project_root ~= ctx.project_root or current.engine_root ~= ctx.engine_root then
        return done(nil, "Project changed during package selection; start the loop again")
      end
      local ok, write_err = steps.update_state_field(ctx.engine_root, "android_package", picked)
      if not ok then
        return done(nil, write_err or "failed to persist Android package")
      end
      if steps.read_state and steps.read_state(ctx.engine_root).android_package ~= picked then
        return done(nil, "Android package write read-back mismatch")
      end
      M.capture(steps, done, alive)
    end)
  end
  local target_ctx, target_err = steps.target_context(ctx, "Android")
  if not target_ctx then
    return done(nil, target_err)
  end
  local host = steps.host_driver or require("utils.platform").driver()
  local _, unavailable = (steps.targets or require("ue.targets")).resolve("Android", "so_build", host)
  if unavailable then
    return done(nil, unavailable.reason or tostring(unavailable))
  end
  local context = vim.deepcopy(ctx)
  context.target, context.configuration = target_ctx.target, target_ctx.configuration
  context.android_serial, context.android_package = serial, package_name
  done(runtime.snapshot({
    operation = "iterate",
    owner = "android.iterate",
    project = ctx.project_root,
    target = "Android",
    configuration = target_ctx.configuration,
    host = { id = host.id },
    device = { serial = serial },
    runtime = { package_name = package_name },
    context = context,
    target_context = target_ctx,
  }))
end

local function debug_launch(done, snapshot, on_stage, owner)
  local raw = runtime.unwrap(snapshot)
  return require("ue.dap").android_dap_launch({
    context = raw.context,
    serial = snapshot.device.serial,
    package_name = snapshot.runtime.package_name,
    configuration = snapshot.configuration,
    owner = owner,
    on_stage = on_stage,
    on_complete = done,
  })
end

--- Only the deployment owner's complete hash-verified marker proves reuse.
function M.deploy_skipped(output)
  for _, line in ipairs(type(output) == "table" and output or {}) do
    local hash = tostring(line):match("^%[UE SO deploy%] unchanged %(sha256=(%x+)%) — skipped$")
    if hash and #hash == 64 then
      return true
    end
  end
  return false
end

--- Accepted work is not success. Completion comes from each actual owner.
function M.run(steps, opts)
  opts = opts or {}
  local notify = opts.notify
    or function(message, level)
      vim.notify("[UEAndroidIterate] " .. message, level or vim.log.levels.INFO)
    end
  if active and (active.status == "running" or active.status == "preparing") then
    notify("A loop is already running; :UEAndroidIterateStop cancels it", vim.log.levels.WARN)
    return nil, "loop-already-running"
  end
  next_id = next_id + 1
  local run = { id = next_id, status = "preparing", stage = "context", results = {} }
  local now = opts.now or function()
    return vim.uv.hrtime() / 1e9
  end
  local started, phase = now(), 0
  active = run
  local function owned()
    return active == run and (run.status == "preparing" or run.status == "running")
  end
  local function elapsed()
    return ("%.0fs"):format(now() - started)
  end
  local function set_status(value)
    if owned() then
      steps.set_status(value)
    end
  end
  local function finish(status, code, detail)
    if not owned() then
      return
    end
    steps.set_status(
      status == "success" and ("LOOP✓ " .. elapsed()) or status == "cancelled" and "LOOP cancelled" or "LOOP✗"
    )
    run.status, run.code, run.detail, run.handle = status, code, detail, nil
    last = run
    active = nil
    pcall(function()
      require("utils.probe").record("android-iterate", status, {
        state = status == "success" and "ok" or status,
        stage = run.stage,
        code = code,
        elapsed = elapsed(),
      })
    end)
    if status == "success" then
      notify(
        "loop completed in "
          .. elapsed()
          .. (
            run.results.deploy_so and run.results.deploy_so.skipped and "; deployment reused verified unchanged SO"
            or ""
          )
      )
    elseif status == "failed" then
      if not opts.nodebug and (run.stage == "debug" or run.stage == "launch" or run.stage == "attach") then
        local failure = require("ue.dap.failure")
        local layered = type(detail) == "table" and detail.failure or nil
        if not layered then
          local reason = type(detail) == "table" and detail.reason or detail
          layered = failure.undetermined(
            "ue.dap",
            "Loop stopped during " .. run.stage .. ": " .. tostring(reason or code),
            "Inspect :UEDAPPreflight and :UEDAPDiag to identify the failing layer",
            failure.observed_evidence("launch/attach completion callback", "exit=" .. tostring(code))
          )
        end
        return notify(failure.format(layered), vim.log.levels.ERROR)
      end
      notify(
        code == -1 and ("stopped: " .. run.stage .. " did not start: " .. tostring(detail or "see previous message"))
          or ("stopped: " .. run.stage .. " exited " .. tostring(code)),
        vim.log.levels.ERROR
      )
    end
  end
  function run:cancel()
    if not owned() then
      return false
    end
    local handle = self.handle
    finish("cancelled", -1, "user cancelled")
    if type(handle) == "table" and type(handle.cancel) == "function" then
      pcall(handle.cancel, handle)
    elseif type(handle) == "number" then
      local registry, found = require("utils.task_registry"), false
      for _, row in ipairs(registry.list()) do
        local record = registry.get(row.id)
        if row.kind == "job" and record and record.handle == handle then
          found = true
          registry.cancel(row.id)
          break
        end
      end
      if not found then
        pcall(vim.fn.jobstop, handle)
      end
    end
    return true
  end
  local invoke
  invoke = function(stage, action, next_step)
    if not owned() then
      return
    end
    phase = phase + 1
    local token, called = phase, false
    run.stage, run.handle = stage, nil
    set_status("LOOP " .. stage .. "…")
    local function done(code, output)
      if not owned() or phase ~= token or called then
        return
      end
      called = true
      local result_stage = stage == "debug" and run.stage or stage
      local lines = type(output) == "table" and vim.islist(output)
      local retained = lines and vim.list_slice(output, math.max(1, #output - 199))
        or type(output) == "table" and vim.deepcopy(output)
        or output
      run.results[result_stage] = {
        code = code,
        output = retained,
        skipped = stage == "deploy_so" and code == 0 and M.deploy_skipped(output) or false,
        omitted_lines = lines and math.max(0, #output - 200) or 0,
      }
      if code ~= 0 then
        return finish("failed", code or -1, output)
      end
      next_step()
    end
    local function on_stage(value, detail)
      if not owned() or phase ~= token or called then
        return
      end
      if value == "launch" or value == "attach" then
        if value == "attach" then
          run.results.launch = { code = 0, output = detail }
        end
        run.stage = value
        set_status("LOOP " .. value .. "…")
      end
    end
    local ok, handle, err = pcall(action, done, run.snapshot, on_stage, run.id, owned)
    if not owned() or phase ~= token or called then
      return
    end
    if not ok then
      return done(-1, handle)
    end
    if handle == nil and err ~= nil then
      return done(-1, err)
    end
    run.handle = handle
  end
  local function start(snapshot, capture_err)
    if not owned() then
      return
    end
    if not snapshot then
      return finish("failed", -1, capture_err)
    end
    run.snapshot, run.status = snapshot, "running"
    invoke("build_so", steps.build_so, function()
      invoke("deploy_so", steps.deploy_so, function()
        if opts.nodebug then
          invoke("launch", steps.launch, function()
            finish("success", 0)
          end)
        else
          invoke("debug", opts.debug_launch or steps.debug_launch or debug_launch, function()
            finish("success", 0)
          end)
        end
      end)
    end)
  end
  if opts.snapshot then
    start(getmetatable(opts.snapshot) == "workflow_snapshot" and opts.snapshot or runtime.snapshot(opts.snapshot))
  else
    local ok, err = pcall(steps.capture or M.capture, steps, start, owned)
    if not ok then
      finish("failed", -1, err)
    end
  end
  return run
end

function M.cancel()
  return active and active:cancel() or false
end

function M.active()
  return active
end

function M.last()
  return last
end

function M.setup(steps)
  vim.api.nvim_create_user_command("UEAndroidIterate", function(cmd)
    M.run(steps, { nodebug = cmd.args == "nodebug" })
  end, {
    nargs = "?",
    complete = function()
      return { "nodebug" }
    end,
    desc = "Android loop: frozen SO build, deploy, then launch/attach",
  })
  vim.api.nvim_create_user_command("UEAndroidIterateStop", function()
    vim.notify(M.cancel() and "Android loop cancelled" or "No Android loop is running", vim.log.levels.INFO)
  end, { desc = "Cancel the current Android loop without starting another stage" })
end

return M
