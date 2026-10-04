-- One launch/attach attempt. Callbacks describe protocol results; emitting an
-- initialized event is never treated as a successful attach response.
local M = {}
local next_id = 0

function M.new(opts, is_current, cleanup)
  opts = opts or {}
  next_id = next_id + 1
  local operation = { id = next_id, owner = opts.owner or next_id, pending = 0, cancels = {} }

  function operation.current()
    return not operation.cancelled and is_current(operation)
  end

  function operation.stage(name, detail)
    if operation.finished or not operation.current() then
      return
    end
    operation.last_stage = name
    detail = vim.tbl_extend("force", {}, detail or {}, { owner = operation.owner })
    if type(opts.on_stage) == "function" then
      opts.on_stage(name, detail)
    end
  end

  function operation.finish(code, detail)
    if operation.finished then
      return false
    end
    operation.finished = true
    operation.code = code
    detail = vim.tbl_extend("force", { stage = operation.last_stage }, detail or {}, { owner = operation.owner })
    if type(opts.on_complete) == "function" then
      opts.on_complete(code, detail)
    end
    return true
  end

  local function drain()
    if operation.cancelled and operation.pending == 0 and not operation.cleaned then
      operation.cleaned = true
      cleanup(operation)
    end
  end

  -- A pending callback keeps cancellation cleanup behind the device command
  -- that might still arm the global debug-app gate. No stale clear-debug-app
  -- can race a newer attempt because the owner stays busy until this drains.
  function operation.hold()
    operation.pending = operation.pending + 1
    local released = false
    return function()
      if released then
        return
      end
      released = true
      operation.pending = operation.pending - 1
      drain()
    end
  end

  function operation.resource(cancel)
    operation.cancels[#operation.cancels + 1] = cancel
  end

  function operation.abort(reason)
    if operation.cancelled or not is_current(operation) then
      return false
    end
    operation.cancelled = true
    operation.finish(-1, { reason = type(reason) == "string" and reason or "cancelled" })
    for _, stop in ipairs(operation.cancels) do
      pcall(stop)
    end
    drain()
    return true
  end

  function operation.cancel(reason)
    if operation.finished then
      return false
    end
    return operation.abort(reason)
  end

  operation.handle = {
    owner = operation.owner,
    cancel = function(first, second)
      return operation.cancel(second or (type(first) == "string" and first or nil))
    end,
  }
  return operation
end

return M
