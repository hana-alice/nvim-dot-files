-- One explicit maintenance request observes the real prepare completion path.
local M = {}
local pending
local prepare_start, prepare_running

function M.configure(start, running)
  prepare_start, prepare_running = start, running
end

function M.is_running()
  return prepare_running and not not prepare_running() or false
end

function M.prepare(ctx, done)
  if not prepare_start then done(false, "prepare-observer-unavailable"); return false end
  M.run(ctx, prepare_start, prepare_running, done)
  return true
end

local function identity(ctx)
  return table.concat({ ctx.engine_root or "", ctx.project_root or "", (ctx.paths or {}).active_cdb or "" }, "\0")
end

local function finish(ok, reason)
  local request = pending
  if not request then return end
  pending = nil
  request.done(ok, reason)
end

function M.prepared(ctx)
  if pending then
    if identity(ctx) == pending.identity then finish(true)
    else finish(false, "prepare-context-changed") end
  end
end

function M.failed(reason)
  finish(false, reason or "prepare-failed")
end

function M.running(value)
  if value or not pending then return end
  local request = pending
  -- Some successful callers clear running immediately before scheduling delivery.
  vim.schedule(function()
    if pending == request then finish(false, "prepare-did-not-complete") end
  end)
end

function M.run(ctx, start, running, done)
  if pending or running() then done(false, "prepare-already-running"); return end
  pending = { identity = identity(ctx), done = done }
  local request = pending
  local ok, err = pcall(start)
  if not ok then finish(false, tostring(err))
  elseif pending == request and not running() then finish(false, "prepare-not-started") end
end

function M._reset_for_test()
  pending = nil
end

return M
