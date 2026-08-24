-- ue.index._state — module records, tiers, index state persistence.
-- Extracted verbatim from lua/ue.lua (F1 split phase-1, health-check 2026-07).
-- Loader style: returns function(M, core); shared helpers land on core.h,
-- public API on M. See lua/ue/index/init.lua for the wiring contract.
return function(M, core)
  local fs = require("ue.core.fs")
  local _ufs = fs
  local _uplat = require("utils.platform")
  local _uproc = require("ue.core.proc")
  local RT = core.RT

local INDEX_CORE_MODULES = {
  Core = true,
  CoreUObject = true,
  Engine = true,
  InputCore = true,
  Slate = true,
  SlateCore = true,
  RenderCore = true,
  RHI = true,
  Renderer = true,
  Projects = true,
  ApplicationCore = true,
  UnrealEd = true,
}

local INDEX_ALWAYS_COLD_MODULES = {
  VulkanRHI = true,
  OpenGLDrv = true,
  NullDrv = true,
}

local function unix_now()
  return os.time()
end

local function index_phase_label(phase)
  phase = fs.trim(phase):lower()
  if phase == "current" then
    return "T0"
  elseif phase == "hot" then
    return "HOT"
  elseif phase == "full" then
    return "FULL"
  elseif phase == "idle" or phase == "" then
    return "IDLE"
  end
  return phase:upper()
end

local function module_tier_label(tier)
  tier = fs.trim(tier):lower()
  if tier == "core" then
    return "CORE"
  elseif tier == "cold" then
    return "COLD"
  elseif tier == "warm" then
    return "WARM"
  end
  return tier ~= "" and tier:upper() or "-"
end

local function read_json_file(path, default)
  default = default or {}
  if not _ufs.is_file(path) then
    return vim.deepcopy(default)
  end
  local content = core.deps.read_all(path)
  if not content or content == "" then
    return vim.deepcopy(default)
  end
  local ok, decoded = pcall(vim.json.decode, content)
  if not ok or type(decoded) ~= "table" then
    return vim.deepcopy(default)
  end
  return decoded
end

local function write_json_file(path, value)
  return core.deps.write_all(path, vim.json.encode(value or {}))
end

local function read_text_file(path)
  local content = core.deps.read_all(path)
  if type(content) ~= "string" or content == "" then
    return nil
  end
  return content
end

-- Reverse-map a unity TU path back to the originating module name.
-- UBT emits unity .cpp files at:
--   <root>/Intermediate/Build/<Plat>/<Target>/<Conf>/[<PlatGroup>/]<Module>/Module.<Module>[.gen][.N_of_M].cpp
-- where <root> is Engine/, the project root, or a plugin/platform plugin root.
-- Returns the bare module name (e.g. "AIGraph", "AIModule") or nil.
local function unity_tu_module_name(path)
  if not path or path == "" then
    return nil
  end
  if not path:find("/Intermediate/Build/", 1, true) then
    return nil
  end
  local raw = path:match("/Module%.([^/]+)%.cpp$")
  if not raw then
    return nil
  end
  -- Strip "N_of_M" slice suffix (any trailing ".<digits>_of_<digits>")
  raw = raw:gsub("%.%d+_of_%d+$", "")
  -- Strip ".gen" UHT suffix
  raw = raw:gsub("%.gen$", "")
  if raw == "" then
    return nil
  end
  return raw
end

-- name -> resolved root cache, populated on demand. Keyed by
-- "engine_root|project_root|name" so multiple workspaces don't collide.
local UNITY_MODULE_ROOT_CACHE = {}
local locate_engine_module_root

local function unity_locate_module_root(engine_root, project_root, name)
  if not name or name == "" then
    return nil
  end
  local key = (engine_root or "") .. "|" .. (project_root or "") .. "|" .. name
  local cached = UNITY_MODULE_ROOT_CACHE[key]
  if cached ~= nil then
    if cached == false then
      return nil
    end
    return cached
  end

  local function check(candidate)
    candidate = fs.norm(candidate)
    if candidate ~= "" and _ufs.is_dir(candidate) then
      return candidate
    end
    return nil
  end

  -- 1) Engine/Source/<Tier>/<Module>
  local hit = locate_engine_module_root(engine_root, name)

  -- 2) Engine plugin: Engine/Plugins/**/<Module>/Source/<Module>
  if not hit and engine_root and engine_root ~= "" then
    local matches = vim.fn.globpath(
      fs.join(engine_root, "Engine", "Plugins"),
      "**/" .. name .. "/Source/" .. name,
      false,
      true
    )
    if type(matches) == "table" then
      for _, m in ipairs(matches) do
        hit = check(m)
        if hit then break end
      end
    end
  end

  -- 3) Engine platforms plugin: Engine/Platforms/*/Plugins/**/<Module>/Source/<Module>
  if not hit and engine_root and engine_root ~= "" then
    local matches = vim.fn.globpath(
      fs.join(engine_root, "Engine", "Platforms"),
      "*/Plugins/**/" .. name .. "/Source/" .. name,
      false,
      true
    )
    if type(matches) == "table" then
      for _, m in ipairs(matches) do
        hit = check(m)
        if hit then break end
      end
    end
  end

  -- 4) Project module: <anchor>/Source/<Module>
  --    Anchor = core.deps.core_rt.project_module_anchor(project_root). Equals project_root
  --    for standard layouts; equals <project_root>/Source/<ProjectName> for the
  --    P4 nested layout where the .uproject lives one level deeper.
  local project_anchor = project_root and project_root ~= "" and core.deps.core_rt.project_module_anchor(project_root) or nil
  if not hit and project_anchor then
    hit = check(fs.join(project_anchor, "Source", name))
  end

  -- 5) Project plugin: <anchor>/Plugins/**/<Module>/Source/<Module>
  if not hit and project_anchor then
    local matches = vim.fn.globpath(
      fs.join(project_anchor, "Plugins"),
      "**/" .. name .. "/Source/" .. name,
      false,
      true
    )
    if type(matches) == "table" then
      for _, m in ipairs(matches) do
        hit = check(m)
        if hit then break end
      end
    end
  end

  UNITY_MODULE_ROOT_CACHE[key] = hit or false
  return hit
end

local function unity_scope_for_path(ctx, path)
  local name = unity_tu_module_name(path)
  if not name then
    return nil
  end
  local root = unity_locate_module_root(ctx.engine_root, ctx.project_root, name)
  if not root then
    return nil
  end
  -- Detect plugin vs module by whether root sits under any /Plugins/ chain
  local kind = "module"
  if fs.norm(root):find("/Plugins/", 1, true) then
    kind = "plugin"
  end
  return {
    kind = kind,
    name = name,
    root = root,
    label = (kind == "plugin" and "Plugin " or "Module ") .. name,
  }
end

local function module_scope_for_path(ctx, path)
  if not ctx then
    return nil
  end
  path = fs.norm(path)
  if path == "" then
    return nil
  end
  return core.deps.plugin_scope_from_root(ctx.project_root, path)
    or core.deps.project_module_scope(ctx.project_root, path)
    or core.deps.plugin_scope_from_root(fs.join(ctx.engine_root, "Engine"), path)
    or core.deps.engine_module_scope(ctx.engine_root, path)
    or unity_scope_for_path(ctx, path)
end

local function module_key(scope)
  if not scope or not scope.root then
    return ""
  end
  return (scope.kind or "module") .. ":" .. fs.norm(scope.root)
end

local function module_tier(scope)
  if not scope then
    return "warm"
  end
  local root = fs.norm(scope.root)
  if INDEX_CORE_MODULES[scope.name or ""] then
    return "core"
  end
  if INDEX_ALWAYS_COLD_MODULES[scope.name or ""] then
    return "cold"
  end
  if root:find("/Developer/") or root:find("/Experimental/") then
    return "cold"
  end
  return "warm"
end

locate_engine_module_root = function(engine_root, name)
  if fs.trim(name) == "" then
    return nil
  end
  local matches = vim.fn.globpath(fs.join(engine_root, "Engine", "Source"), "*/" .. name, false, true)
  if type(matches) == "table" then
    for _, match in ipairs(matches) do
      local candidate = fs.norm(match)
      if _ufs.is_dir(candidate) then
        return candidate
      end
    end
  end
  return nil
end

local function index_state_default()
  return {
    version = 2,
    active_module = nil,
    root_dirty = false,
    modules = {},
    queue = {},
    index_artifacts = {},
    index_selection = {},
    build = {
      phase = "idle",
      status = "idle",
      started_at = 0,
      finished_at = 0,
      message = "",
      active_index = "",
    },
    stats = {
      current_runs = 0,
      hot_runs = 0,
      full_runs = 0,
    },
    updated_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
  }
end

local function save_index_state(ctx, state)
  if not ctx or not state then
    return
  end
  state.updated_at = os.date("!%Y-%m-%dT%H:%M:%SZ")
  local key = core.deps.status_root_key(ctx)
  RT.module_state[key] = state
  RT.contexts[key] = ctx
  _ufs.ensure_dir(ctx.paths.index_dir)
  write_json_file(ctx.paths.index_state, state)
  write_json_file(ctx.paths.index_queue, state.queue or {})
end

local function ensure_index_state(ctx)
  local key = core.deps.status_root_key(ctx)
  if key == "" then
    return index_state_default()
  end
  if RT.module_state[key] then
    return RT.module_state[key]
  end
  local state = read_json_file(ctx.paths.index_state, index_state_default())
  if type(state.modules) ~= "table" then
    state.modules = {}
  end
  if type(state.queue) ~= "table" then
    state.queue = {}
  end
  if core.h.normalize_index_state then
    core.h.normalize_index_state(state)
  end
  if state.root_dirty == nil then
    state.root_dirty = false
  end
  if type(state.build) ~= "table" then
    state.build = index_state_default().build
  end
  if type(state.stats) ~= "table" then
    state.stats = index_state_default().stats
  end
  RT.module_state[key] = state
  return state
end

local function ensure_module_record(state, scope)
  if not state or not scope then
    return nil
  end
  local key = module_key(scope)
  if key == "" then
    return nil
  end
  local rec = state.modules[key] or {
    key = key,
    kind = scope.kind or "module",
    name = scope.name or vim.fs.basename(scope.root),
    root = fs.norm(scope.root),
    label = scope.label or ((scope.kind == "plugin" and "Plugin " or "Module ") .. (scope.name or vim.fs.basename(scope.root))),
    tier = module_tier(scope),
    last_opened = 0,
    last_changed = 0,
    last_indexed = 0,
    dirty = false,
    dirty_reason = "",
    hot_score = 0,
  }
  rec.kind = rec.kind or scope.kind or "module"
  rec.name = rec.name or scope.name or vim.fs.basename(scope.root)
  rec.root = fs.norm(rec.root or scope.root)
  rec.label = rec.label or scope.label or rec.name
  rec.tier = module_tier({ name = rec.name, root = rec.root, kind = rec.kind })
  state.modules[key] = rec
  return rec
end

local function seed_core_modules(ctx, state)
  for name, enabled in pairs(INDEX_CORE_MODULES) do
    if enabled then
      local root = locate_engine_module_root(ctx.engine_root, name)
      if root then
        ensure_module_record(state, {
          kind = "module",
          name = name,
          root = root,
          label = "Module " .. name,
        })
      end
    end
  end
end

local function module_record_from_path(ctx, path)
  local scope = module_scope_for_path(ctx, path)
  if not scope then
    return nil, nil
  end
  local state = ensure_index_state(ctx)
  seed_core_modules(ctx, state)
  local rec = ensure_module_record(state, scope)
  save_index_state(ctx, state)
  return rec, state
end

local function module_key_from_path(ctx, path)
  local scope = module_scope_for_path(ctx, path)
  return module_key(scope), scope
end

local function module_score(rec, state)
  if not rec then
    return -100000
  end
  local score = 0
  if rec.tier == "core" then
    score = score + 500
  elseif rec.tier == "cold" then
    score = score - 400
  end
  if state and state.active_module == rec.key then
    score = score + 1000
  end
  if rec.dirty then
    score = score + 300
  end
  local now = unix_now()
  if (tonumber(rec.last_opened) or 0) > 0 then
    local age = now - (tonumber(rec.last_opened) or 0)
    if age < 600 then
      score = score + 200
    elseif age < 3600 then
      score = score + 80
    end
  end
  if (tonumber(rec.last_changed) or 0) > 0 then
    local age = now - (tonumber(rec.last_changed) or 0)
    if age < 600 then
      score = score + 300
    elseif age < 3600 then
      score = score + 120
    end
  end
  score = score + (tonumber(rec.hot_score) or 0)
  return score
end

local function sorted_module_records(state)
  local items = {}
  for _, rec in pairs(state.modules or {}) do
    rec._score = module_score(rec, state)
    items[#items + 1] = rec
  end
  table.sort(items, function(a, b)
    if a._score == b._score then
      return (a.name or "") < (b.name or "")
    end
    return a._score > b._score
  end)
  return items
end


M.set_active_module = function(ctx, path)
  local rec, state = module_record_from_path(ctx, path)
  if not rec or not state then
    return nil
  end
  rec.last_opened = unix_now()
  rec.hot_score = math.min((tonumber(rec.hot_score) or 0) + 25, 1000)
  state.active_module = rec.key
  save_index_state(ctx, state)
  return rec
end

M.mark_module_dirty = function(ctx, path, reason)
  local rec, state = module_record_from_path(ctx, path)
  if not rec or not state then
    core.deps.mark_index_dirty(ctx)
    return nil
  end
  rec.dirty = true
  rec.dirty_reason = fs.trim(reason) ~= "" and fs.trim(reason) or "buffer-write"
  rec.last_changed = unix_now()
  rec.hot_score = math.min((tonumber(rec.hot_score) or 0) + 50, 1000)
  core.deps.mark_index_dirty(ctx)
  save_index_state(ctx, state)
  return rec
end

M.clear_module_dirty_flags = function(ctx, keys)
  local state = ensure_index_state(ctx)
  local changed = false
  for _, key in ipairs(keys or {}) do
    local rec = state.modules[key]
    if rec and rec.dirty then
      rec.dirty = false
      rec.dirty_reason = ""
      rec.last_indexed = unix_now()
      changed = true
    end
  end
  local has_dirty = false
  for _, rec in pairs(state.modules or {}) do
    if rec.dirty then
      has_dirty = true
      break
    end
  end
  if not has_dirty then
    core.deps.clear_index_dirty(ctx)
  end
  if changed then
    save_index_state(ctx, state)
  end
end

M.index_phase_paths = function(ctx, phase)
  if phase == "current" then
    return ctx.paths.index_current_cdb, ctx.paths.current_index
  end
  if phase == "hot" then
    return ctx.paths.index_hot_cdb, ctx.paths.hot_index
  end
  return ctx.paths.index_full_cdb, ctx.paths.full_index
end

  -- Shared helpers for sibling loaders (_build/_clangd) + public re-exports
  -- for ue.lua call sites that used these as file-locals before the split.
  core.h.unix_now = unix_now
  core.h.index_phase_label = index_phase_label
  core.h.module_tier_label = module_tier_label
  core.h.read_json_file = read_json_file
  core.h.write_json_file = write_json_file
  core.h.read_text_file = read_text_file
  core.h.ensure_index_state = ensure_index_state
  core.h.save_index_state = save_index_state
  core.h.index_state_default = index_state_default
  core.h.module_record_from_path = module_record_from_path
  core.h.module_key_from_path = module_key_from_path
  core.h.module_score = module_score
  core.h.sorted_module_records = sorted_module_records
  core.h.module_scope_for_path = module_scope_for_path
  core.h.module_key = module_key
  core.h.module_tier = module_tier
  core.h.ensure_module_record = ensure_module_record
  core.h.seed_core_modules = seed_core_modules
  core.h.locate_engine_module_root = locate_engine_module_root
  core.h.unity_tu_module_name = unity_tu_module_name
  core.h.unity_locate_module_root = unity_locate_module_root
  core.h.unity_scope_for_path = unity_scope_for_path
  M.ensure_index_state = ensure_index_state
  M.save_index_state = save_index_state
  M.sorted_module_records = sorted_module_records
  M.module_tier_label = module_tier_label
end
