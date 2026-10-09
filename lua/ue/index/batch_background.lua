-- Continuous private proof queue; production activation still belongs to batch_runtime.
local M = {}
local sessions = {}
local admission = require("utils.host_admission")
local locks = require("ue.file_lock")

local function read_json(path)
  local stat = vim.uv.fs_stat(path)
  if not stat or stat.size > 4194304 then return nil end
  local file = io.open(path, "rb")
  if not file then return nil end
  local raw = file:read("*a")
  file:close()
  local ok, value = pcall(vim.json.decode, raw)
  return ok and value or nil
end

local function signature(path)
  local stat = vim.uv.fs_stat(path)
  return stat and { size = stat.size, mtime = stat.mtime, ctime = stat.ctime } or nil
end

function M.status(scope)
  return sessions[scope]
end

function M.stop(scope)
  local record = sessions[scope]
  if not record or record.stopped then return end
  record.stopped = true
  if record.timer then record.timer:stop(); record.timer:close(); record.timer = nil end
  local controls = {}
  for _, control in pairs(record.controls) do controls[#controls + 1] = control end
  for _, control in ipairs(controls) do control:cancel() end
  -- Worker Job Objects close their owned descendants when the worker exits.
  if record.running == 0 and record.finish then record.finish("stopped") end
end

--- Injectable queue: never reads the CDB on the main loop, only small metadata.
function M.start(spec, opts)
  opts = opts or {}
  local now = opts.now or function() return vim.uv.hrtime() / 1e6 end
  local schedule = opts.schedule or vim.schedule
  local read = opts.read_json or read_json
  local acquire, release = opts.acquire or locks.acquire, opts.release or locks.release
  local prior = sessions[spec.scope]
  local identity = { clangd = spec.clangd, profile = spec.profile, env = spec.env }
  if prior and not prior.stopped and not prior.finished_at and vim.deep_equal(prior.signature, spec.signature)
      and vim.deep_equal(prior.identity, identity) and prior.current() then return prior end
  if prior and prior.running > 0 then M.stop(spec.scope); return nil, "previous-proof-exiting" end
  local lease, err = acquire(spec.store .. ".background.lock")
  if not lease then return nil, err end
  local record = { scope = spec.scope, signature = spec.signature, identity = identity, lease = lease, controls = {},
    running = 0, next_group = 1, completed = {}, accepted = 0, rejected = 0,
    last_publish = now(), published_count = 0, started_at = os.time(), phase = "planning" }
  sessions[spec.scope] = record
  local current = opts.current or function()
    return not record.stopped and vim.deep_equal(signature(spec.source), spec.signature)
      and (not spec.current or spec.current())
  end
  record.current = current
  local run = opts.run or function(command, callback)
    local handle = vim.system(command, { text = true, cwd = spec.cwd, env = spec.env, clear_env = true },
      function(result) schedule(function() callback(result) end) end)
    pcall(function() require("utils.task_registry").register({ name = "SuperUnity proof", group = "ue",
      kind = "system", handle = handle, started_at = os.time() }) end)
    return function() pcall(handle.kill, handle, 15) end
  end
  local function finish(reason)
    if record.finished_at then return end
    record.phase, record.reason = "finished", reason
    record.finished_at = os.time()
    if record.timer then record.timer:stop(); record.timer:close(); record.timer = nil end
    release(lease)
    if record.publish_lease then release(record.publish_lease); record.publish_lease = nil end
    if opts.on_done then opts.on_done(record) end
  end
  record.finish = finish
  local function log_error(reason)
    record.error = reason
    pcall(function() require("utils.log").warn_ctx("ue.index", "background proof retained originals",
      { reason = reason, scope = spec.scope }) end)
  end
  local serial = 0
  local function launch(arguments, callback, before_start)
    serial = serial + 1
    local slot = serial
    record.running = record.running + 1
    local command = { spec.python, "-u", spec.script }
    vim.list_extend(command, arguments)
    vim.list_extend(command, { "--clangd", spec.clangd })
    if spec.profile then vim.list_extend(command, { "--server-profile", vim.json.encode(spec.profile) }) end
    local completed = false
    local function done(result)
      if completed then return end
      completed = true
      record.controls[slot] = nil
      record.running = record.running - 1
      if record.stopped then
        if record.running == 0 then finish("stopped") end
        return
      end
      callback(result)
    end
    local _, _, _, control = (opts.admit or admission.run_when_allowed)({ name = "SuperUnity proof",
      start = function()
        if not current() then schedule(function() done({ code = 1, stderr = "proof-input-changed" }) end); return end
        if before_start and not before_start() then
          schedule(function() done({ code = 1, stderr = "proof-publication-writer-busy" }) end); return
        end
        return run(command, done)
      end,
      on_cancel = function() done({ code = 1, stderr = "proof-cancelled" }) end,
      on_error = function(reason) done({ code = 1, stderr = tostring(reason) }) end,
      on_defer = function(reason) record.deferred_reason = reason end,
    })
    if not completed then record.controls[slot] = control end
  end
  local pump, arm
  local publishing = false
  local groups = {}
  local max_workers = math.max(1, math.min(2, opts.max_workers or 2))
  local interval = opts.publish_interval_ms or 120000
  local function publish()
    if publishing or record.running > 0 or #record.completed == record.published_count then return false end
    local phase_lease
    publishing, record.phase = true, "collecting"
    local arguments = { "--collect", spec.plan, "--completed", vim.json.encode(record.completed),
      "--background", spec.background, "--marker", spec.marker, "--out", spec.collect_result }
    if spec.publication_request then
      vim.list_extend(arguments, { "--publish-request", spec.publication_request_path,
        "--nvim", spec.nvim, "--publish-worker", spec.publication_worker })
    end
    launch(arguments, function(result)
      publishing = false
      local delivered = false
      if result.code == 0 and current() then
        local collected = read(spec.collect_result)
        if collected and collected.ok then
          local ok, failure = pcall(spec.publish, collected)
          if not ok then log_error(tostring(failure)) else delivered = true end
        else log_error("invalid-proof-collection") end
      else log_error(result.stderr or "proof-collection-failed") end
      if delivered then
        record.published_count, record.last_publish = #record.completed, now()
        record.publications = (record.publications or 0) + 1
      end
      if phase_lease then release(phase_lease) end
      record.publish_lease = nil
      if delivered then pump() else arm(5000) end
    end, function()
      phase_lease = acquire(spec.publish_lock)
      record.publish_lease = phase_lease
      if phase_lease and spec.publication_request then
        local payload = vim.deepcopy(spec.publication_request)
        payload.lease, payload.owner_pid, payload.source_sha256 = phase_lease, vim.fn.getpid(), record.input_sha256
        local file = io.open(spec.publication_request_path, "wb")
        if not file then return false end
        local wrote, closed = file:write(vim.json.encode(payload)), file:close()
        if not wrote or not closed then return false end
      end
      return phase_lease ~= nil
    end)
    return true
  end
  arm = function(delay)
    if record.timer or record.stopped then return end
    local timer = (opts.timer_factory or vim.uv.new_timer)()
    record.timer = timer
    timer:start(delay, 0, function()
      timer:stop(); timer:close(); record.timer = nil
      schedule(pump)
    end)
  end
  pump = function()
    if record.stopped then return end
    if not current() then
      record.stopped = true
      local controls = {}
      for _, control in pairs(record.controls) do
        if not control.started then controls[#controls + 1] = control end
      end
      for _, control in ipairs(controls) do control:cancel() end
      if record.running == 0 then finish("proof-input-changed") end
      return
    end
    local all_done = record.next_group > #groups
    if record.running == 0 and (all_done or now() - record.last_publish >= interval) and publish() then return end
    if all_done then
      if record.running == 0 then finish("queue-complete") end
      return
    end
    if publishing then return end
    record.phase = "proving"
    -- Drain running workers before publication; do not keep adding work beyond
    -- the coalescing deadline, which would otherwise starve publication.
    if #record.completed > record.published_count and now() - record.last_publish >= interval then return end
    while record.running < max_workers and record.next_group <= #groups do
      local group = groups[record.next_group]
      record.next_group = record.next_group + 1
      local output = spec.control_dir .. "/result-" .. group.id .. ".json"
      launch({ "--worker", spec.plan, "--group", group.id, "--out", output }, function(result)
        if result.code == 0 then
          local value = read(output)
          if value and value.ok and value.metrics then
            record.completed[#record.completed + 1] = group.id
            record.accepted = record.accepted + (value.metrics.new_batch_count or 0)
            record.rejected = record.rejected + (value.metrics.new_proof_count or 0) - (value.metrics.new_batch_count or 0)
          else log_error("invalid-proof-result") end
        else log_error(result.stderr or "private-proof-failed") end
        pump()
      end)
    end
  end
  launch({ "--plan", spec.source, "--store", spec.store, "--out", spec.plan }, function(result)
    local plan = result.code == 0 and read(spec.plan) or nil
    if not current() or not plan or plan.schema ~= 1 or type(plan.groups) ~= "table" then
      finish(result.stderr or "invalid-proof-plan"); return
    end
    groups = plan.groups
    record.input_sha256 = plan.input_sha256
    record.group_count = #groups
    pump()
  end)
  return record
end

vim.api.nvim_create_autocmd("VimLeavePre", { callback = function()
  for scope in pairs(sessions) do M.stop(scope) end
end })

return M
