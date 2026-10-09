-- Process-local prepare evidence. Watches precede generation; no disk cache can
-- acquire this authority after a restart or a gap in input observation.
local M = {}
local uv = vim.uv or vim.loop
local fs = require("ue.core.fs")
local record
local hits, misses = 0, 0
local leave_registered = false
local last_miss_reason

local function stable(value)
  if type(value) ~= "table" then return type(value) .. ":" .. tostring(value) end
  local keys, parts = vim.tbl_keys(value), {}
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  for _, key in ipairs(keys) do
    local encoded, encoded_key = stable(value[key]), stable(key)
    parts[#parts + 1] = tostring(#encoded_key) .. ":" .. encoded_key .. tostring(#encoded) .. ":" .. encoded
  end
  return "{" .. table.concat(parts) .. "}"
end

function M.signature(ctx)
  local state = ctx.state or {}
  local configuration_files = {}
  for _, name in ipairs({ "init.lua", "lazy-lock.json", ".luarc.json" }) do
    local path = fs.join(vim.fn.stdpath("config"), name)
    local file = io.open(path, "rb")
    if file then configuration_files[name] = vim.fn.sha256(file:read("*a")); file:close() end
  end
  return vim.fn.sha256(stable({ engine_root = ctx.engine_root, project_root = ctx.project_root,
    uproject = ctx.uproject, paths = ctx.paths, target = state.target, target_name = state.target_name,
    platform = state.target_platform, configuration = state.target_configuration,
    apple_semantic_build = state.apple_semantic_build,
    config = require("ue.config").options(), environment = vim.fn.environ(),
    clangd = require("ue").clangd_cmd(), nvim = vim.v.progpath, configuration_files = configuration_files,
  }))
end

local function identity(path)
  local stat = uv.fs_stat(path)
  if not stat or stat.type ~= "file" then return nil end
  return { size = stat.size, mtime = stat.mtime, ctime = stat.ctime, ino = tostring(stat.ino) }
end

local function root_identity(path)
  local stat = uv.fs_stat(path)
  return stat and { type = stat.type, ino = tostring(stat.ino), dev = tostring(stat.dev),
    realpath = uv.fs_realpath(path) } or nil
end

local function stop_timer(name)
  local timer = record and record[name]
  if timer then timer:stop(); timer:close(); record[name] = nil end
end

function M.stop()
  if not record then return end
  stop_timer("seal_timer"); stop_timer("background_timer")
  if record.group then record.group:close() end
  record.ready, record.reason = false, "watch-stopped"
  record = nil
end

local function invalidate(current, why)
  current.epoch = current.epoch + 1
  current.ready, current.reason = false, why
end

function M.invalidate(reason)
  if record then invalidate(record, reason or "observation-unknown") end
end

-- These are owned derived outputs, never source/build inputs. Their identities
-- are checked separately, including ctime, after every reuse candidate.
local function output_event(root, name, events)
  if events.stable_directory_write then return true end
  local path = fs.join(root, name):lower()
  return path:find("/.cache/nvim-ue/", 1, true) ~= nil or path:match("/%.cache/nvim%-ue$") ~= nil
    or path:find("/__pycache__/", 1, true) ~= nil
end

local function collect(ctx, required, done, admitted)
  if not admitted then
    return require("utils.host_admission").run_when_allowed({ name = "UE prepare input evidence",
      start = function() return collect(ctx, required, done, true) end,
      on_error = function(reason) done(nil, tostring(reason)) end,
      on_cancel = function() done(nil, "input-evidence-cancelled") end,
    })
  end
  local targets = require("ue.cdb.paths").targets(ctx)
  local platform = require("utils.platform")
  local python = platform.resolve_tool({ name = "python", env = { "UE_PYTHON" },
    driver_candidates = function(driver) return driver.python_candidates() end })
  local clangd = require("ue").clangd_cmd()[1]
  local request = { ctx = ctx, active = targets[1], targets = targets,
    shards_dir = require("ue.cdb.shards").shards_dir(ctx),
    pch_dir = fs.join(fs.dirname(targets[1]), ".cache", "nvim-ue", "clangd", "pch"),
    tools_dir = require("ue.config").get("cdb.tools_dir"), require_products = required,
    environment = vim.fn.environ(), tools_executables = { vim.v.progpath,
      python.ok and python.path or "", vim.fn.exepath(clangd) ~= "" and vim.fn.exepath(clangd) or clangd } }
  local path = vim.fn.tempname() .. "-prepare-inputs.json"
  local file = io.open(path, "wb")
  if not file then done(nil, "input-request-write-failed"); return end
  local ok, encoded = pcall(vim.json.encode, request)
  if not ok then file:close(); os.remove(path); done(nil, "input-request-encode-failed"); return end
  file:write(encoded); file:close()
  local script = vim.fn.stdpath("config") .. "/lua/ue/cdb/prepare_inputs.lua"
  local spawned, handle = pcall(vim.system, { vim.v.progpath, "--headless", "-u", "NONE", "-i", "NONE",
    "-l", script, path }, { text = true, timeout = 60000 }, function(result)
    vim.schedule(function()
      os.remove(path)
      local decoded, value = pcall(vim.json.decode, result.stdout or "")
      if result.code ~= 0 or not decoded or not value.ok then
        done(nil, decoded and value.reason or result.stderr or "input-inventory-failed")
      else done(value) end
    end)
  end)
  if not spawned then os.remove(path); done(nil, tostring(handle)); return end
  pcall(require("utils.task_registry").register, {
    name = "UE prepare input evidence", group = "ue", kind = "system", handle = handle,
  })
end

function M.status()
  local current = record
  return { ready = current and current.ready or false, hits = hits, misses = misses,
    epoch = current and current.epoch, reason = current and current.reason or "no-successful-prepare",
    roots = current and current.roots, last_event = current and current.last_event,
    last_miss_reason = last_miss_reason,
    background_pending = current and current.background_timer ~= nil or false }
end

local function reusable(ctx, current)
  if not current or not current.ready or not current.group or current.group.phase ~= "running" then return false end
  if current.signature ~= M.signature(ctx) then invalidate(current, "configuration-or-environment-changed"); return false end
  for path, previous in pairs(current.root_identities or {}) do
    if not vim.deep_equal(root_identity(path), previous) then invalidate(current, "watch-root-replaced"); return false end
  end
  for _, artifact in ipairs(current.artifacts or {}) do
    if not vim.deep_equal(identity(artifact.path), artifact.identity) then
      invalidate(current, "artifact-changed:" .. artifact.path); return false
    end
  end
  return true
end

-- done(true) reuses the last successfully published products. Misses always
-- invoke the original complete path; unavailable native coverage never guesses.
function M.begin(ctx, opts, done)
  opts = opts or {}
  pcall(function() require("utils.probe").observe("prepare-path", "input-epoch-fast-2026-10-09-P") end)
  if not leave_registered then
    leave_registered = true
    vim.api.nvim_create_autocmd("VimLeavePre", { callback = M.stop })
  end
  local current = record
  -- Yield before testing the epoch so already queued native callbacks can revoke
  -- it. This is not a native stream barrier; unknown/error remains fail-closed.
  vim.defer_fn(function()
    if not opts.force_csearch and not opts.force_cdb_restart and current and current.ready then
      local locks = require("ue.file_lock")
      local lease = locks.acquire(require("ue.cdb.paths").targets(ctx)[1] .. ".writer.lock")
      if lease then
        local hit = reusable(ctx, current) and (not opts.cache_ready or opts.cache_ready())
        locks.release(lease)
        if hit then hits = hits + 1; done(true); return end
      else invalidate(current, "cdb-writer-busy") end
    end
    misses = misses + 1
    last_miss_reason = current and current.reason or "no-successful-prepare"
    M.stop()
    current = { epoch = 0, ready = false, reason = "collecting-input-roots", signature = M.signature(ctx) }
    record = current
    collect(ctx, false, function(value, err)
      if record ~= current then done(false); return end
      if not value then current.reason = err; done(false); return end
      current.roots, current.artifacts = value.roots, value.artifacts
      local driver = require("utils.platform").driver()
      if type(driver.input_event_watcher) ~= "function" then current.reason = "native-watch-unavailable"; done(false); return end
      local group, watch_err = driver.input_event_watcher(value.roots)
      if not group then current.reason = watch_err; done(false); return end
      current.group = group
      local pending, finished = #value.roots, false
      local function finish()
        if finished then return end
        finished = true
        current.start_epoch = current.epoch
        current.root_identities = {}
        for _, root in ipairs(current.roots) do
          local observed = root_identity(root.path)
          if not observed then invalidate(current, "watch-root-missing")
          else current.root_identities[root.path] = observed end
        end
        if group.phase == "running" then current.reason = "awaiting-successful-prepare" end
        done(false)
      end
      for _, root in ipairs(value.roots) do
        local handle, reason = group:watch(root.path, function(event_err, name, events)
          if record ~= current then return end
          if event_err or not name or (events and (events.unknown or events.overflow)) then
            invalidate(current, "watch-unknown:" .. tostring(event_err or "overflow"))
          elseif not output_event(root.path, name, events or {}) then
            current.last_event = fs.join(root.path, name)
            invalidate(current, "input-event")
          end
        end, { recursive = root.recursive, on_ready = function(ready, reason)
          if not ready then invalidate(current, "watch-unhealthy:" .. tostring(reason)) end
          pending = pending - 1
          if pending == 0 then finish() end
        end })
        if not handle then invalidate(current, "watch-install:" .. tostring(reason)); group:close(); finish(); break end
      end
    end)
  end, 100)
end

-- Seal only after the controlled products have finished publishing. This waits
-- for generators, not clangd's potentially hours-long BackgroundIndex queue.
function M.complete(ctx)
  local current = record
  if not current or not current.group or current.group.phase ~= "running" then return end
  stop_timer("seal_timer")
  local attempts = 0
  local function settle()
    if record ~= current then return end
    local index = require("ue.index")
    local status = index.index_status_summary(ctx)
    local rt = index._rt
    if status.status == "error" or status.status == "interrupted" then current.reason = "controlled-delivery-failed"; return end
    if rt.job or next(rt.timers or {}) or (status.queue_count or 0) > 0 then
      attempts = attempts + 1
      if attempts > 1200 then current.reason = "controlled-delivery-timeout"; return end
      local timer = uv.new_timer(); current.seal_timer = timer
      timer:start(250, 0, vim.schedule_wrap(function() stop_timer("seal_timer"); settle() end))
      return
    end
    if current.epoch ~= current.start_epoch then current.reason = "inputs-changed-during-prepare"; return end
    collect(ctx, true, function(value, err)
      if record ~= current then return end
      if not value then current.reason = err; return end
      if current.group.phase ~= "running" then current.reason = "watch-unhealthy-at-seal"; return end
      if current.epoch ~= current.start_epoch then current.reason = "input-event-during-seal"; return end
      if current.signature ~= M.signature(ctx) then current.reason = "configuration-changed-during-seal"; return end
      if not vim.deep_equal(current.roots, value.roots) then current.reason = "input-roots-changed-during-seal"; return end
      current.artifacts, current.ready, current.reason = value.artifacts, true, "unchanged-inputs"
    end)
  end
  settle()
end

-- One deadline per successful capsule. Repeated prepare calls cannot postpone
-- the next P4 proof forever, and do not re-run current/hot/full immediately.
function M.continue_background(ctx)
  if not record or record.background_timer then return end
  local current = record
  local timer = uv.new_timer(); current.background_timer = timer
  timer:start(require("ue.config").get("index.idle_cold_ms") or 120000, 0, vim.schedule_wrap(function()
    if record ~= current then return end
    stop_timer("background_timer")
    current.ready, current.reason = false, "background-proof-publishing"
    require("ue.index").schedule_index_phase(ctx, "full", 50, { protect = true })
    M.complete(ctx)
  end))
end

return M
