-- Multi-instance-safe UE project selection and project-scoped persisted state.
--
-- The active project is captured in this process. selection.json is only the
-- startup default for a future process; another process changing it cannot
-- redirect a live Neovim instance. Project data lives in a canonical-path
-- bucket and JSON updates are serialized + atomically replaced.

local fs = require("ue.core.fs")
local lock = require("ue.file_lock")

local M = {}

local sessions = {}
local session_values = {}
-- One-shot, process-local handoff from an explicit :UESetPlatform to the next
-- :UESetProject. This is what makes the two commands order-independent without
-- turning engine target-default.json into build authority or leaking intent to
-- another live Neovim process.
local staged_targets = {}
local load_values
local SESSION_LOCAL_FIELDS = {
  target_platform = true,
  target_configuration = true,
}

local function engine_key(engine_root)
  local normalized = fs.norm(engine_root)
  return normalized:lower(), normalized
end

local function engine_cache_root(engine_root)
  return fs.join(engine_root, ".cache", "nvim-ue")
end

local function canonical_project(project_root, uproject)
  local canonical = fs.norm(uproject)
  if canonical == "" then canonical = fs.norm(project_root) end
  return canonical
end

function M.project_key(project_root, uproject)
  local canonical = canonical_project(project_root, uproject)
  if canonical == "" then return nil end
  local base = vim.fs.basename(canonical):gsub("%.uproject$", "")
  base = base:gsub("[^%w%._%-]", "_")
  if base == "" then base = "project" end
  return base .. "-" .. vim.fn.sha256(canonical:lower()):sub(1, 16)
end

function M.selector_path(engine_root)
  return fs.join(engine_cache_root(engine_root), "selection.json")
end

local function read_json(path)
  local file = io.open(path, "rb")
  if not file then return nil end
  local raw = file:read("*a")
  file:close()
  local ok, value = pcall(vim.json.decode, raw or "")
  return ok and type(value) == "table" and value or nil
end

local function atomic_write(path, value)
  fs.ensure_dir(fs.dirname(path))
  local suffix = table.concat({ vim.fn.getpid(), vim.uv.hrtime(), math.random(1, 2147483646) }, ".")
  local temp = path .. ".tmp." .. suffix
  local file, err = io.open(temp, "wb")
  if not file then return false, err or ("cannot open " .. temp) end
  file:write(vim.json.encode(value))
  file:flush()
  file:close()
  local ok, rename_err = vim.uv.fs_rename(temp, path)
  if not ok then
    pcall(os.remove, temp)
    return false, rename_err or ("cannot replace " .. path)
  end
  return true
end

local function locked_update(path, transform)
  local lease, err = lock.acquire(path .. ".lock")
  if not lease then return false, "state is being updated by another Neovim: " .. tostring(err) end
  local ok_call, ok, update_err = pcall(function()
    local current = read_json(path) or {}
    local next_value = transform(current) or current
    return atomic_write(path, next_value)
  end)
  lock.release(lease)
  if not ok_call then return false, ok end
  return ok, update_err
end

local function normalize_selection(engine_root, project_root, uproject)
  local _, engine = engine_key(engine_root)
  project_root = fs.norm(project_root)
  uproject = fs.norm(uproject)
  if engine == "" or project_root == "" then return nil, "engine/project root is empty" end
  local key = M.project_key(project_root, uproject)
  return {
    engine_root = engine,
    project_root = project_root,
    uproject = uproject ~= "" and uproject or nil,
    project_key = key,
  }
end

function M.select(engine_root, project_root, uproject, opts)
  opts = opts or {}
  local selection, err = normalize_selection(engine_root, project_root, uproject)
  if not selection then return nil, err end
  if opts.persist_default ~= false then
    local ok, write_err = locked_update(M.selector_path(engine_root), function()
      return {
        engine_root = selection.engine_root,
        project_root = selection.project_root,
        uproject = selection.uproject,
        project_key = selection.project_key,
        updated_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
      }
    end)
    if not ok then return nil, write_err end
  end
  local key = engine_key(engine_root)
  local previous_session = sessions[key]
  local previous_values = session_values[key]
  sessions[key] = selection
  session_values[key] = {}
  local staged = staged_targets[key]
  if staged and type(M.update_target) == "function" then
    local ok, target_err = M.update_target(
      engine_root, staged.target_platform, staged.target_configuration)
    if not ok then
      sessions[key] = previous_session
      session_values[key] = previous_values
      return nil, target_err
    end
    staged_targets[key] = nil
  elseif load_values then
    local persisted = load_values(engine_root, selection)
    for field in pairs(SESSION_LOCAL_FIELDS) do
      session_values[key][field] = persisted[field]
    end
  end
  return vim.deepcopy(selection)
end

local function legacy_selection(engine_root)
  local legacy = read_json(fs.join(engine_cache_root(engine_root), "state.json"))
  if type(legacy) ~= "table" or not legacy.project_root then return nil end
  local selection = normalize_selection(engine_root, legacy.project_root, legacy.uproject)
  if not selection then return nil end
  -- One-time compatibility import. The old state remains untouched so rollback
  -- stays possible; every new write goes only to the project bucket.
  local state_path = fs.join(engine_cache_root(engine_root), "projects", selection.project_key, "state.json")
  if not fs.is_file(state_path) then
    locked_update(state_path, function() return legacy end)
  end
  return selection
end

function M.current(engine_root)
  local key = engine_key(engine_root)
  if sessions[key] then return vim.deepcopy(sessions[key]) end
  local selection = read_json(M.selector_path(engine_root)) or legacy_selection(engine_root)
  if type(selection) ~= "table" or not selection.project_root then return nil end
  local normalized = normalize_selection(engine_root, selection.project_root, selection.uproject)
  if not normalized then return nil end
  sessions[key] = normalized
  session_values[key] = {}
  if load_values then
    local persisted = load_values(engine_root, normalized)
    for field in pairs(SESSION_LOCAL_FIELDS) do
      session_values[key][field] = persisted[field]
    end
  end
  return vim.deepcopy(normalized)
end

function M.project_cache_root(engine_root, selection)
  selection = selection or M.current(engine_root)
  if not selection or not selection.project_key then return nil end
  return fs.join(engine_cache_root(engine_root), "projects", selection.project_key)
end

function M.state_path(engine_root, selection)
  local root = M.project_cache_root(engine_root, selection)
  return root and fs.join(root, "state.json") or nil
end

local function fields_dir(engine_root, selection)
  local root = M.project_cache_root(engine_root, selection)
  return root and fs.join(root, "state-fields") or nil
end

local function field_path(engine_root, selection, key)
  if not tostring(key):match("^[%w_%-]+$") then return nil end
  return fs.join(fields_dir(engine_root, selection), tostring(key) .. ".json")
end

local function target_path(engine_root, selection)
  return fs.join(fields_dir(engine_root, selection), "target-selection.json")
end

-- Engine-level target preference (orthogonal axis, NOT authority).
-- Written on every explicit UESetPlatform; read only as the SUGGESTED default
-- when a project bucket has never had a target set (fresh checkout picker).
-- Deliberately engine-scoped, not global: two engines can have different
-- habitual platforms, and per-spec "preference globals MAY share a
-- last-writer-wins file but SHALL atomic replace". The per-project
-- target-selection.json remains the only authority read_state() honors.
local function engine_target_default_path(engine_root)
  local _, engine = engine_key(engine_root)
  return fs.join(engine_cache_root(engine), "target-default.json")
end

function M.engine_target_default(engine_root)
  local value = read_json(engine_target_default_path(engine_root))
  if type(value) ~= "table" then return nil end
  local platform = value.target_platform
  if type(platform) ~= "string" or platform == "" then return nil end
  return {
    target_platform = platform,
    target_configuration = type(value.target_configuration) == "string"
      and value.target_configuration or nil,
  }
end

--- Whether the ACTIVE project bucket has ever had an explicit target set.
--- Distinguishes "user chose a platform" from "code fell back to a default" —
--- fresh buckets must prompt, not silently build a guessed platform.
function M.target_is_set(engine_root)
  local selection = M.current(engine_root)
  if not selection then return false end
  local value = read_json(target_path(engine_root, selection))
  return type(value) == "table"
    and type(value.target_platform) == "string"
    and value.target_platform ~= ""
end

function M.revision_path(engine_root, selection)
  local root = M.project_cache_root(engine_root, selection)
  return root and fs.join(root, "state.revision.json") or nil
end

load_values = function(engine_root, selection)
  local value = read_json(M.state_path(engine_root, selection)) or {}
  local dir = fields_dir(engine_root, selection)
  if dir and fs.is_dir(dir) then
    -- vim.fn.globpath() can miss files below Neovim's own temporary root on
    -- Windows (the path is rewritten through its short-name form).  libuv's
    -- directory iterator operates on the exact path and is also cheaper here.
    for name, kind in vim.fs.dir(dir) do
      if kind == "file" and name:match("%.json$") and name ~= "target-selection.json" then
        local field = read_json(fs.join(dir, name))
        local key = name:gsub("%.json$", "")
        if type(field) == "table" and tostring(field.updated_at or "") > tostring(value.updated_at or "") then
          value.updated_at = field.updated_at
        end
        if type(field) == "table" and field.present == true then
          value[key] = field.value
        elseif type(field) == "table" and field.present == false then
          value[key] = nil
        end
      end
    end
    local target = read_json(target_path(engine_root, selection))
    if type(target) == "table" then
      value.target_platform = target.target_platform
      value.target_configuration = target.target_configuration
      if tostring(target.updated_at or "") > tostring(value.updated_at or "") then
        value.updated_at = target.updated_at
      end
    end
  end
  value.engine_root = selection.engine_root
  value.project_root = selection.project_root
  value.uproject = selection.uproject
  value.project_key = selection.project_key
  return value
end

function M.read(engine_root)
  local selection = M.current(engine_root)
  if not selection then return {} end
  local value = load_values(engine_root, selection)
  local key = engine_key(engine_root)
  for field in pairs(SESSION_LOCAL_FIELDS) do
    value[field] = session_values[key] and session_values[key][field] or nil
  end
  return value
end

function M.update(engine_root, key, value)
  local selection = M.current(engine_root)
  if not selection then return false, "no project selected in this Neovim session" end
  if SESSION_LOCAL_FIELDS[key] then
    local current = M.read(engine_root)
    return M.update_target(
      engine_root,
      key == "target_platform" and value or current.target_platform,
      key == "target_configuration" and value or current.target_configuration)
  end
  local path = field_path(engine_root, selection, key)
  if not path then return false, "invalid project state field: " .. tostring(key) end
  -- One file per field turns concurrent distinct-key updates into independent
  -- atomic replaces, eliminating JSON read/modify/write loss without a global
  -- critical section. Same-key writes intentionally remain last-writer-wins.
  local ok, err = atomic_write(path, {
    present = value ~= nil,
    value = value,
    updated_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    writer_pid = vim.fn.getpid(),
  })
  if not ok then return false, err end
  return atomic_write(M.revision_path(engine_root, selection), {
    nonce = table.concat({ vim.fn.getpid(), vim.uv.hrtime() }, "-"),
    updated_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
  })
end

function M.update_target(engine_root, platform, configuration)
  local selection = M.current(engine_root)
  if not selection then return false, "no project selected in this Neovim session" end
  local updated_at = os.date("!%Y-%m-%dT%H:%M:%SZ")
  local ok, err = atomic_write(target_path(engine_root, selection), {
    target_platform = platform,
    target_configuration = configuration,
    updated_at = updated_at,
    writer_pid = vim.fn.getpid(),
  })
  if not ok then return false, err end
  -- Mirror the pair into the engine-level preference (suggestion-only; see
  -- engine_target_default). Best-effort: a failed mirror must not fail the
  -- authoritative per-project write.
  pcall(atomic_write, engine_target_default_path(engine_root), {
    target_platform = platform,
    target_configuration = configuration,
    updated_at = updated_at,
    writer_pid = vim.fn.getpid(),
  })
  local session_key = engine_key(engine_root)
  session_values[session_key] = session_values[session_key] or {}
  session_values[session_key].target_platform = platform
  session_values[session_key].target_configuration = configuration
  return atomic_write(M.revision_path(engine_root, selection), {
    nonce = table.concat({ vim.fn.getpid(), vim.uv.hrtime() }, "-"),
    updated_at = updated_at,
  })
end

--- Capture an explicit :UESetPlatform intent independently from project
--- selection. If a project is active, update its authoritative bucket now;
--- either way, apply the same pair once to the next explicit :UESetProject.
--- The one-shot handoff is process-local, so engine target-default.json stays
--- suggestion-only and another Neovim cannot redirect this process.
function M.stage_target(engine_root, platform, configuration)
  local key = engine_key(engine_root)
  staged_targets[key] = {
    target_platform = platform,
    target_configuration = configuration,
  }

  if M.current(engine_root) then
    local ok, err = M.update_target(engine_root, platform, configuration)
    if not ok then staged_targets[key] = nil end
    return ok, err
  end

  local updated_at = os.date("!%Y-%m-%dT%H:%M:%SZ")
  local ok, err = atomic_write(engine_target_default_path(engine_root), {
    target_platform = platform,
    target_configuration = configuration,
    updated_at = updated_at,
    writer_pid = vim.fn.getpid(),
  })
  if not ok then staged_targets[key] = nil end
  return ok, err
end

function M._reset_for_test()
  sessions = {}
  session_values = {}
  staged_targets = {}
end

return M
