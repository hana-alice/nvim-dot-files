-- Native, destination-exclusive rename. Source identity is the caller's job.
local M = {}
local pending = {}

---@param worker function Self-contained native worker supplied by the host driver.
---@param from string Absolute source path; identity verification belongs to caller.
---@param to string Absolute destination path, atomically required to be absent.
---@param callback fun(ok:boolean, err:string|nil) Scheduled once on the main loop.
---@return boolean queued
---@return string? error
function M.rename(worker, from, to, callback)
  if type(callback) ~= "function" then
    return false, "Native move requires a completion callback"
  end
  local work, completed
  local function complete(ok, err)
    if completed then
      return
    end
    completed = true
    vim.schedule(function()
      if work then
        pending[work] = nil
      end
      if ok == true then
        callback(true, nil)
      else
        callback(false, err or "Native no-replace move failed")
      end
    end)
  end
  if type(from) ~= "string" or type(to) ~= "string" then
    local err = "Native no-replace move requires source and destination paths"
    complete(false, err)
    return false, err
  end
  for _, path in ipairs({ from, to }) do
    if path == "" or #path > 131068 or path:find("\0", 1, true) then
      local err = "Native no-replace move requires bounded paths without NUL bytes"
      complete(false, err)
      return false, err
    end
  end
  local uv = vim.uv or vim.loop
  if not uv.new_work then
    local err = "Native no-replace move requires libuv worker support"
    complete(false, err)
    return false, err
  end
  local created, value = pcall(uv.new_work, worker, complete)
  if not created or not value then
    local err = "Cannot create native move worker: " .. tostring(value)
    complete(false, err)
    return false, err
  end
  work = value
  pending[work] = true
  local called, queued, queue_err = pcall(work.queue, work, from, to)
  if not called or not queued then
    local err = "Cannot queue native move worker: " .. tostring(called and queue_err or queued)
    complete(false, err)
    return false, err
  end
  return true
end

return M
