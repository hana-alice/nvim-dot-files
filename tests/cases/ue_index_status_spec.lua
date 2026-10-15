local t = require("tests.harness")
t.bootstrap()

local ue = require("ue")
local index = require("ue.index")

-- Exercise the closure used by the public statusline without adding a runtime
-- test API or resolving a real UE project. No index/build operation is invoked.
local function upvalue(fn, wanted)
  for i = 1, math.huge do
    local name, value = debug.getupvalue(fn, i)
    if not name then break end
    if name == wanted then return value, i end
  end
  error("missing statusline upvalue: " .. wanted)
end

local status_token = upvalue(ue.statusline_status, "index_status_token")
local case_id = 0

local function fixture(opts)
  opts = opts or {}
  case_id = case_id + 1
  local run_root = assert(vim.env.NVIM_TEST_RUN_ROOT, "use the isolated tests/run.lua entry")
  local root = run_root:gsub("\\", "/") .. "/ue-index-status-" .. case_id
  local paths = {
    active_cdb = root .. "/compile_commands.json",
    active_index = root .. "/android_debug_3.7.idx",
    current_index = root .. "/android_debug_3.7.current.idx",
    hot_index = root .. "/android_debug_3.7.hot.idx",
    full_index = root .. "/android_debug_3.7.full.idx",
    workspace_db = root .. "/workspace-db",
    platform_key = "android_debug",
  }
  vim.fn.mkdir(paths.workspace_db, "p")
  if not opts.no_cdb then
    if opts.cdb_directory then vim.fn.mkdir(paths.active_cdb, "p")
    else vim.fn.writefile({ "[]" }, paths.active_cdb) end
  end
  for _, phase in ipairs(opts.artifacts or { "full" }) do
    local path = paths[phase .. "_index"]
    if opts.index_directory == phase then vim.fn.mkdir(path, "p")
    else vim.fn.writefile({ "fixture index" }, path) end
  end
  if opts.legacy then vim.fn.writefile({ "legacy fixture" }, paths.active_index) end
  for _, name in ipairs({ "GTAGS", "GRTAGS", "GPATH" }) do
    if opts.missing_db ~= name then
      vim.fn.writefile(opts.empty_db == name and {} or { "fixture database" }, paths.workspace_db .. "/" .. name)
    end
  end
  return { engine_root = root, project_root = root .. "/project", paths = paths }
end

local function summary(phase)
  return {
    status = "idle", phase = phase, phase_label = phase == "current" and "T0" or phase:upper(),
    selected_phase = phase, active = "-", root_dirty = false, dirty = 0,
    queue_count = 0, queued = {}, coverage_level = phase,
    freshness = "fresh", converging = false,
    generation_short = "fixture", selected_module_count = 0,
  }
end

local function with_summary(value, fn)
  local saved_summary = index.index_status_summary
  local saved_cache, saved_ttl = index._rt.status_cache, index._rt.status_ttl
  index.index_status_summary = function() return value end
  index._rt.status_cache, index._rt.status_ttl = {}, 30
  local ok, err = pcall(fn)
  index.index_status_summary = saved_summary
  index._rt.status_cache, index._rt.status_ttl = saved_cache, saved_ttl
  if not ok then error(err, 0) end
end

t.describe("UE index statusline artifacts", function()
  for _, phase in ipairs({ "current", "hot", "full" }) do
    t.it(phase .. " selected artifact is ready without the retired idx", function()
      local ctx = fixture({ artifacts = { phase } })
      with_summary(summary(phase), function()
        t.assert_eq(status_token(ctx), "IDX:" .. (phase == "current" and "T0" or phase:upper()))
      end)
    end)
  end

  t.it("only the retired idx cannot make full ready", function()
    local ctx = fixture({ artifacts = {}, legacy = true })
    with_summary(summary("full"), function() t.assert_eq(status_token(ctx), "IDX?") end)
  end)

  t.it("full ready uses its idx when build active_index points to a semantic CDB", function()
    local ctx, value = fixture(), summary("full")
    value.active_index = ctx.paths.active_cdb
    with_summary(value, function() t.assert_eq(status_token(ctx), "IDX:FULL") end)
  end)

  t.it("build active_index semantic CDB cannot hide a missing selected idx", function()
    local ctx = fixture({ artifacts = {}, legacy = true })
    local value = summary("full")
    value.active_index = ctx.paths.active_cdb
    with_summary(value, function() t.assert_eq(status_token(ctx), "IDX?") end)
  end)

  t.it("other phases and retired idx cannot hide missing selected full", function()
    local ctx = fixture({ artifacts = { "current", "hot" }, legacy = true })
    with_summary(summary("full"), function() t.assert_eq(status_token(ctx), "IDX?") end)
  end)

  t.it("full cannot hide a missing selected current", function()
    local ctx = fixture({ artifacts = { "full" }, legacy = true })
    with_summary(summary("current"), function() t.assert_eq(status_token(ctx), "IDX?") end)
  end)

  for _, phase in ipairs({ "absent", "empty" }) do
    t.it(phase .. " selected phase fails closed despite all artifacts", function()
      local ctx = fixture({ artifacts = { "current", "hot", "full" }, legacy = true })
      local value = summary("full")
      value.selected_phase = phase == "empty" and "" or nil
      with_summary(value, function() t.assert_eq(status_token(ctx), "IDX?") end)
    end)
  end

  t.it("missing selected path fails closed", function()
    local ctx = fixture({ legacy = true })
    ctx.paths.full_index = nil
    with_summary(summary("full"), function() t.assert_eq(status_token(ctx), "IDX?") end)
  end)

  t.it("missing active compile commands stays unavailable", function()
    local ctx = fixture({ no_cdb = true, legacy = true })
    with_summary(summary("full"), function() t.assert_eq(status_token(ctx), "IDX?") end)
  end)

  for _, kind in ipairs({ "absent", "empty" }) do
    t.it(kind .. " active compile commands path fails closed", function()
      local ctx = fixture({ legacy = true })
      ctx.paths.active_cdb = kind == "empty" and "" or nil
      with_summary(summary("full"), function() t.assert_eq(status_token(ctx), "IDX?") end)
    end)
  end

  for _, name in ipairs({ "GTAGS", "GRTAGS", "GPATH" }) do
    t.it("missing " .. name .. " stays unavailable", function()
      local ctx = fixture({ missing_db = name, legacy = true })
      with_summary(summary("full"), function() t.assert_eq(status_token(ctx), "IDX?") end)
    end)
    t.it("empty " .. name .. " stays unavailable", function()
      local ctx = fixture({ empty_db = name, legacy = true })
      with_summary(summary("full"), function() t.assert_eq(status_token(ctx), "IDX?") end)
    end)
  end

  t.it("a directory cannot stand in for the selected idx", function()
    local ctx = fixture({ index_directory = "full", legacy = true })
    with_summary(summary("full"), function() t.assert_eq(status_token(ctx), "IDX?") end)
  end)

  t.it("a directory cannot stand in for active compile commands", function()
    local ctx = fixture({ cdb_directory = true, legacy = true })
    with_summary(summary("full"), function() t.assert_eq(status_token(ctx), "IDX?") end)
  end)

  t.it("running still takes precedence over missing artifacts and dirty", function()
    local ctx = fixture({ artifacts = {}, no_cdb = true, missing_db = "GTAGS" })
    local value = summary("full")
    value.status, value.root_dirty, value.dirty = "running", true, 3
    with_summary(value, function() t.assert_eq(status_token(ctx), "IDX:FULL*") end)
  end)

  for _, dirty in ipairs({ 0, 3 }) do
    t.it("dirty count " .. dirty .. " still takes precedence over missing artifacts", function()
      local ctx = fixture({ artifacts = {}, no_cdb = true })
      local value = summary("full")
      value.root_dirty, value.dirty = true, dirty
      with_summary(value, function()
        t.assert_eq(status_token(ctx), dirty > 0 and "IDX!3" or "IDX!R")
      end)
    end)
  end

  t.it("ready token retains the existing TTL cache and rechecks after expiry", function()
    local ctx, value = fixture(), summary("full")
    with_summary(value, function()
      t.assert_eq(status_token(ctx), "IDX:FULL")
      value.selected_phase, value.phase_label = "current", "CURRENT"
      t.assert_eq(status_token(ctx), "IDX:FULL")
      for _, cached in pairs(index._rt.status_cache) do cached.ts = 0 end
      t.assert_eq(status_token(ctx), "IDX?")
    end)
  end)

  t.it("live dirty still overrides a cached ready token", function()
    local ctx, value = fixture(), summary("full")
    with_summary(value, function()
      t.assert_eq(status_token(ctx), "IDX:FULL")
      value.root_dirty, value.dirty = true, 7
      t.assert_eq(status_token(ctx), "IDX!7")
    end)
  end)

  t.it("running retains the existing cached token behavior", function()
    local ctx, value = fixture(), summary("full")
    with_summary(value, function()
      t.assert_eq(status_token(ctx), "IDX:FULL")
      value.status, value.phase_label = "running", "CURRENT"
      t.assert_eq(status_token(ctx), "IDX:FULL")
    end)
  end)

  t.it("public statusline and index_status share the real full generation selection", function()
    local ctx = fixture()
    ctx.paths.index_dir = ctx.engine_root .. "/index-state"
    ctx.paths.index_state = ctx.paths.index_dir .. "/modules.json"
    ctx.paths.index_queue = ctx.paths.index_dir .. "/queue.json"
    ctx.paths.semantic_full_cdb = ctx.engine_root .. "/semantic-full.json"
    vim.fn.writefile({ "[]" }, ctx.paths.semantic_full_cdb)
    ctx.state = {}

    local saved_resolve, resolve_i = upvalue(ue.statusline_status, "resolve_context")
    local saved_index_resolve, index_resolve_i = upvalue(ue.index_status, "resolve_context")
    local saved_notify = vim.notify
    local saved_states, saved_contexts = index._rt.module_state, index._rt.contexts
    local saved_cache, saved_identity = index._rt.status_cache, index._rt.toolchain_identity_override
    index._rt.module_state, index._rt.contexts, index._rt.status_cache = {}, {}, {}
    index._rt.toolchain_identity_override = "statusline fixture toolchain"
    debug.setupvalue(ue.statusline_status, resolve_i, function() return ctx end)
    debug.setupvalue(ue.index_status, index_resolve_i, function() return ctx end)
    vim.notify = function() end
    local ok, err = pcall(function()
      local state = index.ensure_index_state(ctx)
      state.build = { phase = "full", status = "ready", active_index = ctx.paths.semantic_full_cdb }
      local manifest, manifest_err = index.make_index_manifest(ctx, state, "full", ctx.paths.full_index, {}, {
        base_cdb_path = ctx.paths.active_cdb,
        background_cdb_path = ctx.paths.semantic_full_cdb,
        completed_at = 1,
      })
      t.assert_type(manifest, "table", manifest_err)
      state.index_artifacts.full = manifest
      local selected = index.index_status_summary(ctx)
      t.assert_eq(selected.status, "ready")
      t.assert_eq(selected.selected_phase, "full")
      t.assert_eq(selected.active_index, ctx.paths.semantic_full_cdb)
      t.assert_contains(ue.index_status(), "coverage: full base=full freshness=fresh")
      t.assert_contains(ue.statusline_status(), "IDX:FULL")
      t.assert_false(ue.statusline_status():find("IDX?", 1, true))
    end)
    vim.notify = saved_notify
    debug.setupvalue(ue.statusline_status, resolve_i, saved_resolve)
    debug.setupvalue(ue.index_status, index_resolve_i, saved_index_resolve)
    index._rt.module_state, index._rt.contexts = saved_states, saved_contexts
    index._rt.status_cache, index._rt.toolchain_identity_override = saved_cache, saved_identity
    if not ok then error(err, 0) end
  end)
end)
