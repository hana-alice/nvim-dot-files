-- Named configurations are independent project-bucket fields. Applying one
-- changes only future invocations; devices and the selected mode stay local.
local fs = require("ue.core.fs")
local targets = require("ue.targets")
local identity = require("ue.target_identity")
local M = {}
local PREFIX = "run_profile_"
local selected = {}
local services = {}
local last_failure

local function dependencies(opts)
  opts = opts or {}
  return {
    state = opts.state or require("ue.project_state"),
    resolve_context = opts.resolve_context or require("ue").resolve_context,
    host_driver = opts.host_driver or require("utils.platform").driver(),
    get_device = opts.get_device or require("utils.android_device").get,
    set_target = opts.set_target or services.set_target,
    environment = opts.environment or function()
      return { configuration = vim.env.UE_TARGET_CONFIGURATION, target = vim.env.UE_BUILD_TARGET }
    end,
    ui_select = opts.ui_select or vim.ui.select,
    input = opts.input or vim.ui.input,
    notify = opts.notify or vim.notify,
  }
end

local function name_key(name)
  name = fs.trim(name)
  if name == "" or #name > 160 or name:find("[%c]") then
    return nil, "Profile name must be 1–160 bytes without control characters"
  end
  return PREFIX .. vim.fn.sha256(name:lower()), name
end

local function project_id(ctx, state)
  return fs.norm(ctx.engine_root):lower() .. "/" .. tostring(state.project_key(ctx.project_root, ctx.uproject))
end

local function context(d)
  local ctx, err = d.resolve_context()
  if not ctx or fs.trim(ctx.engine_root) == "" or fs.trim(ctx.project_root) == "" then
    return nil, err or "Select a UE project first (:UESetProject)"
  end
  local current = d.state.current(ctx.engine_root)
  if not current or current.project_key ~= d.state.project_key(ctx.project_root, ctx.uproject) then
    return nil, "Project selection changed or context has no matching canonical bucket"
  end
  return ctx
end

local function package_keys(platform, state)
  local driver = targets.driver(platform)
  local keys = {}
  local contribution = driver and type(driver.hub) == "function" and driver.hub(state) or {}
  for _, field in ipairs(contribution.fields or {}) do
    -- Persistence addresses come from the target owner. Device fields are
    -- intentionally excluded even if a future contribution adds a state key.
    if field.name == "package" and type(field.state_key) == "string" then
      keys[field.state_key] = true
    end
  end
  return keys
end

local function fields_for(platform, state)
  local values = {}
  for key in pairs(package_keys(platform, state)) do
    values[key] = state[key] or ""
  end
  return values
end

local function facts(ctx, d, field_keys)
  local state = d.state.read(ctx.engine_root)
  local fields, present = {}, {}
  for key in pairs(field_keys or {}) do
    fields[key], present[key] = state[key] or "", state[key] ~= nil
  end
  return {
    project = project_id(ctx, d.state),
    platform = state.target_platform or "",
    configuration = state.target_configuration or "",
    fields = fields,
    present = present,
    mode = selected[project_id(ctx, d.state)] or "debug",
    device = d.get_device(),
    environment = d.environment(),
  }
end

local function validate(profile, ctx, d, applying)
  if type(profile) ~= "table" or profile.version ~= 1 then
    return nil, "Unsupported or corrupt run profile"
  end
  if profile.project ~= project_id(ctx, d.state) then
    return nil, "Profile belongs to another project"
  end
  local key = name_key(profile.name)
  if not key then
    return nil, "Invalid run profile name"
  end
  if profile.mode ~= "debug" and profile.mode ~= "run" then
    return nil, "Unsupported run mode"
  end
  if type(profile.configuration) ~= "string" or not profile.configuration:match("^[%w_%- ]+$") then
    return nil, "Invalid run configuration"
  end
  local driver = targets.driver(profile.platform)
  if not driver then
    return nil, "Unknown profile target"
  end
  if applying then
    local allowed, unavailable = targets.resolve(profile.platform, "build", d.host_driver)
    if not allowed then
      return nil, unavailable.reason
    end
  end
  local env = d.environment()
  if applying and fs.trim(env.configuration) ~= "" and env.configuration ~= profile.configuration then
    return nil, "Configuration environment override conflicts with this profile"
  end
  local desired = {
    project_root = ctx.project_root,
    uproject = ctx.uproject,
    state = { target_configuration = profile.configuration },
  }
  local expected = identity.resolve(desired).target
  if applying and profile.target_name ~= expected then
    return nil, "UBT target identity changed; save this configuration again"
  end
  if type(profile.fields) ~= "table" then
    return nil, "Invalid profile package fields"
  end
  local allowed = package_keys(profile.platform, profile.fields)
  for field, value in pairs(profile.fields) do
    if not allowed[field] or type(value) ~= "string" or #value > 512 or value:find("[%c]") then
      return nil, "Unsupported profile field: " .. tostring(field)
    end
  end
  return key
end

local function write_field(ctx, key, value, d)
  local ok, err, receipt = d.state.update(ctx.engine_root, key, value, ctx)
  if not ok then
    return nil, err or "Profile field write failed"
  end
  local seen = d.state.read(ctx.engine_root, ctx)[key]
  if not vim.deep_equal(seen, value) then
    return nil, "Profile field read-back mismatch: " .. key, receipt, true
  end
  return true, nil, receipt, true
end

function M.mode(opts)
  local d = dependencies(opts)
  local ctx = context(d)
  return ctx and selected[project_id(ctx, d.state)] or "debug"
end

--- Exact named fields avoid lost updates between unrelated profile writers.
function M.save(name, opts)
  local d = dependencies(opts)
  local key, normalized = name_key(name)
  if not key then
    return nil, normalized
  end
  local ctx, err = context(d)
  if not ctx then
    return nil, err
  end
  local state = d.state.read(ctx.engine_root)
  local configuration = state.target_configuration or ""
  local profile = {
    version = 1,
    name = normalized,
    project = project_id(ctx, d.state),
    platform = state.target_platform or "",
    configuration = configuration,
    target_name = identity.resolve({
      project_root = ctx.project_root,
      uproject = ctx.uproject,
      state = { target_configuration = configuration },
    }).target,
    fields = fields_for(state.target_platform, state),
    mode = opts and opts.mode or M.mode(opts),
  }
  local valid, validate_err = validate(profile, ctx, d, true)
  if not valid then
    return nil, validate_err
  end
  local ok, write_err = write_field(ctx, key, profile, d)
  if not ok then
    return nil, write_err
  end
  return profile
end

function M.list(opts)
  local d = dependencies(opts)
  local ctx, err = context(d)
  if not ctx then
    return nil, err
  end
  local rows = {}
  for key, value in pairs(d.state.read(ctx.engine_root, ctx)) do
    if key:sub(1, #PREFIX) == PREFIX then
      local expected, validate_err = validate(value, ctx, d)
      if not expected or expected ~= key then
        return nil, validate_err or "Run profile key/name mismatch"
      end
      rows[#rows + 1] = vim.deepcopy(value)
    end
  end
  table.sort(rows, function(a, b)
    return a.name:lower() < b.name:lower()
  end)
  return rows
end

function M.get(name, opts)
  local d = dependencies(opts)
  local key, name_err = name_key(name)
  if not key then
    return nil, name_err
  end
  local ctx, err = context(d)
  if not ctx then
    return nil, err
  end
  local profile = d.state.read(ctx.engine_root, ctx)[key]
  if profile == nil then
    return nil, "Run profile not found: " .. name
  end
  local valid, validate_err = validate(profile, ctx, d)
  if not valid then
    return nil, validate_err
  end
  return vim.deepcopy(profile)
end

function M.delete(name, opts)
  local d = dependencies(opts)
  local profile, err = M.get(name, opts)
  if not profile then
    return nil, err
  end
  local ctx, context_err = context(d)
  if not ctx then
    return nil, context_err
  end
  return write_field(ctx, name_key(profile.name), nil, d)
end

local function changes(profile, before)
  local lines = { "Apply " .. profile.name .. " to this project?", "" }
  local function add(label, old, value)
    lines[#lines + 1] = label .. ": " .. tostring(old or "(none)") .. " → " .. tostring(value or "(none)")
  end
  add("Target", before.platform, profile.platform)
  add("Configuration", before.configuration, profile.configuration)
  add("Mode", before.mode, profile.mode)
  local keys = vim.tbl_keys(profile.fields)
  table.sort(keys)
  for _, key in ipairs(keys) do
    add(key, before.fields[key], profile.fields[key])
  end
  lines[#lines + 1] = "Device stays selected in this instance; active runs keep their snapshot."
  return table.concat(lines, "\n")
end

--- Ordinary fields recover only with their committed receipt. Target setters
--- provide no ownership receipt, so a failed attempt requires explicit review.
local function recover(ctx, before, attempted, target_attempted, d)
  local result = { restored = {}, blocked = {} }
  if target_attempted then
    result.blocked[#result.blocked + 1] = "target (ownership receipt unavailable; review current selection)"
  end
  for _, write in ipairs(attempted) do
    local key, ok, err = write.key, false, "ownership receipt or guarded writer unavailable"
    if write.receipt and type(d.state.compare_update) == "function" then
      ok, err = d.state.compare_update(
        ctx.engine_root,
        key,
        write.receipt,
        before.present[key] and before.fields[key] or nil,
        ctx
      )
    end
    if ok then
      result.restored[#result.restored + 1] = key
    else
      result.blocked[#result.blocked + 1] = key .. " (" .. tostring(err) .. ")"
    end
  end
  return result
end

function M.apply(name, opts, done)
  done = done or function() end
  local d = dependencies(opts)
  local profile, err = M.get(name, opts)
  if not profile then
    return done(false, err)
  end
  local ctx, context_err = context(d)
  if not ctx then
    return done(false, context_err)
  end
  local valid, validate_err = validate(profile, ctx, d, true)
  if not valid then
    return done(false, validate_err)
  end
  if type(d.set_target) ~= "function" then
    return done(false, "Profile target setter is unavailable")
  end
  local before = facts(ctx, d, profile.fields)
  d.ui_select({ "取消", "应用" }, { prompt = changes(profile, before) }, function(choice)
    if choice ~= "应用" then
      return done(false, "cancelled")
    end
    local current = context(d)
    if not current or not vim.deep_equal(before, facts(current, d, profile.fields)) then
      return done(false, "Project, selectors or environment changed during preview; try again")
    end
    local stored = d.state.read(ctx.engine_root, ctx)[name_key(profile.name)]
    if not vim.deep_equal(stored, profile) then
      return done(false, "Saved profile changed during preview; try again")
    end
    local valid, validate_err = validate(profile, ctx, d, true)
    if not valid then
      return done(false, validate_err)
    end
    local attempted, target_attempted = {}, false
    local function fail(reason)
      local recovery = recover(ctx, before, attempted, target_attempted, d)
      last_failure = { reason = reason, project = before.project, recovery = recovery }
      local suffix = #recovery.blocked > 0
          and ("; partial settings require review: " .. table.concat(recovery.blocked, ", "))
        or ""
      done(false, tostring(reason) .. suffix, recovery)
    end
    local keys = vim.tbl_keys(profile.fields)
    table.sort(keys)
    for _, key in ipairs(keys) do
      if before.fields[key] ~= profile.fields[key] then
        local ok, write_err, receipt, wrote = write_field(ctx, key, profile.fields[key], d)
        if wrote then
          attempted[#attempted + 1] = { key = key, receipt = receipt }
        end
        if not ok then
          return fail(write_err)
        end
        if not receipt or type(d.state.compare_update) ~= "function" then
          return fail("Profile field ownership receipt or guarded writer unavailable: " .. key)
        end
      end
    end
    if before.platform ~= profile.platform or before.configuration ~= profile.configuration then
      target_attempted = true
      local called, result, setter_err = pcall(d.set_target, profile.platform, profile.configuration)
      if not called or result == false then
        return fail(setter_err or result or "Target setter failed")
      end
    end
    current = context(d)
    local state = d.state.read(ctx.engine_root)
    if
      not current
      or project_id(current, d.state) ~= before.project
      or state.target_platform ~= profile.platform
      or state.target_configuration ~= profile.configuration
    then
      return fail("Target setter read-back mismatch or project changed")
    end
    for key, value in pairs(profile.fields) do
      if (state[key] or "") ~= value then
        return fail("Profile field read-back mismatch: " .. key)
      end
    end
    selected[before.project] = profile.mode
    done(true, profile)
  end)
end

function M.last_failure()
  return last_failure
end

function M.setup_commands(opts)
  services = opts or {}
  local function report(ok, result)
    if ok then
      vim.notify("Run profile applied: " .. result.name, vim.log.levels.INFO)
    elseif result ~= "cancelled" then
      vim.notify("Run profile not applied: " .. tostring(result), vim.log.levels.ERROR)
    end
  end
  local function choose(prompt, action)
    local rows, err = M.list()
    if not rows then
      return vim.notify(err, vim.log.levels.ERROR)
    end
    if #rows == 0 then
      return vim.notify("No saved profiles; :UERunProfileSave creates one", vim.log.levels.INFO)
    end
    vim.ui.select(rows, {
      prompt = prompt,
      format_item = function(row)
        return row.name .. " · " .. row.platform .. " " .. row.configuration .. " · " .. row.mode
      end,
    }, function(row)
      if row then
        action(row.name)
      end
    end)
  end
  vim.api.nvim_create_user_command("UERunProfile", function(cmd)
    if cmd.args == "" then
      choose("Run profiles", function(name)
        M.apply(name, nil, report)
      end)
    else
      M.apply(cmd.args, nil, report)
    end
  end, { nargs = "*", desc = "Preview and apply a project run profile", force = true })
  vim.api.nvim_create_user_command("UERunProfileSave", function(cmd)
    local d = dependencies()
    local ctx, err = context(d)
    if not ctx then
      return vim.notify(err, vim.log.levels.ERROR)
    end
    local before =
      facts(ctx, d, fields_for(d.state.read(ctx.engine_root).target_platform, d.state.read(ctx.engine_root)))
    local function save(name, mode)
      local current = context(d)
      if not current or not vim.deep_equal(before, facts(current, d, before.fields)) then
        return vim.notify("Project or selectors changed while naming the profile; try again", vim.log.levels.ERROR)
      end
      local profile, save_err = M.save(name, { mode = mode })
      vim.notify(
        profile and ("Run profile saved: " .. profile.name) or tostring(save_err),
        profile and vim.log.levels.INFO or vim.log.levels.ERROR
      )
    end
    vim.ui.select({ "debug", "run" }, { prompt = "Profile run mode:" }, function(mode)
      if not mode then
        return
      end
      if cmd.args ~= "" then
        save(cmd.args, mode)
      else
        vim.ui.input({ prompt = "Run profile name: " }, function(name)
          if name then
            save(name, mode)
          end
        end)
      end
    end)
  end, { nargs = "*", desc = "Save the current project target as a named run profile", force = true })
  vim.api.nvim_create_user_command("UERunProfileDelete", function(cmd)
    local function remove(name)
      local d = dependencies()
      local captured, capture_err = M.get(name)
      local ctx = context(d)
      if not captured or not ctx then
        return vim.notify(capture_err or "No selected project", vim.log.levels.ERROR)
      end
      local project = project_id(ctx, d.state)
      vim.ui.select({ "取消", "删除" }, { prompt = "Delete saved profile " .. name .. "?" }, function(choice)
        if choice ~= "删除" then
          return
        end
        local current = context(d)
        local value = M.get(name)
        if not current or project_id(current, d.state) ~= project or not vim.deep_equal(value, captured) then
          return vim.notify("Project or saved profile changed during deletion preview; try again", vim.log.levels.ERROR)
        end
        local ok, err = M.delete(name)
        vim.notify(
          ok and ("Run profile deleted: " .. name) or tostring(err),
          ok and vim.log.levels.INFO or vim.log.levels.ERROR
        )
      end)
    end
    if cmd.args == "" then
      choose("Delete saved run profile", remove)
    else
      remove(cmd.args)
    end
  end, { nargs = "*", desc = "Delete a saved project run profile", force = true })
end

return M
