-- Owner-bound dirty-set persistence. Collection/notification policy stays with
-- the watcher; this module owns the writer lease, atomic I/O, and bounded retry.
local file_lock = require("ue.file_lock")
local M = {}
local MAX_RETRIES = 8

function M.merge_from_disk(owner, path)
  local fd = io.open(path, "rb")
  if not fd then return end
  local content = fd:read("*a")
  fd:close()
  local ok, decoded = pcall(vim.json.decode, content or "")
  if ok and type(decoded) == "table" then
    for _, abs in ipairs(decoded) do
      if type(abs) == "string" and abs ~= "" then
        owner.persistent_dirty[abs:lower()] = abs
      end
    end
  end
end

local function cancel_retry(owner)
  owner.dirty_save_retry_generation = (owner.dirty_save_retry_generation or 0) + 1
  local timer = owner.dirty_save_retry
  owner.dirty_save_retry = nil
  if timer then
    pcall(function() timer:stop() end)
    pcall(function() timer:close() end)
  end
end

local function retry(owner, path, collect, on_saved, warn, reason)
  if owner.dirty_save_retry then return end
  local attempt = (owner.dirty_save_failures or 0) + 1
  owner.dirty_save_failures = attempt
  if attempt > MAX_RETRIES then
    if attempt == MAX_RETRIES + 1 then
      warn("dirty.json save retries exhausted for " .. tostring(path) .. ": " .. tostring(reason))
    end
    return
  end
  local generation = owner.dirty_save_retry_generation
  owner.dirty_save_retry = vim.defer_fn(function()
    if owner.dirty_save_retry_generation ~= generation then return end
    owner.dirty_save_retry = nil
    M.save(owner, path, collect, on_saved, warn)
  end, math.min(1000, 25 * 2 ^ (attempt - 1)))
end

--- Collect under the lease and publish atomically. Callbacks capture the same
--- owner as retries, even after the active watcher changes project.
function M.save(owner, path, collect, on_saved, warn)
  cancel_retry(owner)
  local acquired, lease, lock_err = pcall(file_lock.acquire, path .. ".lock")
  if not acquired or not lease then
    retry(owner, path, collect, on_saved, warn, acquired and lock_err or lease)
    return
  end
  local arr = collect()
  -- Atomic write: tmp + rename. Acquiring the lock created the parent directory.
  local tmp = path .. (".tmp.%d.%s"):format(vim.fn.getpid(), tostring(vim.uv.hrtime()))
  local fd, err = io.open(tmp, "w")
  if not fd then
    file_lock.release(lease)
    retry(owner, path, collect, on_saved, warn, "open failed: " .. tostring(err))
    return
  end
  local wrote_ok, wrote, write_err = pcall(fd.write, fd, vim.json.encode(arr))
  local closed_ok, closed, close_err = pcall(fd.close, fd)
  if not wrote_ok or not wrote or not closed_ok or not closed then
    pcall(vim.fn.delete, tmp)
    file_lock.release(lease)
    retry(owner, path, collect, on_saved, warn, "write/close failed: "
      .. tostring(not wrote_ok and wrote or write_err or not closed_ok and closed or close_err))
    return
  end
  local ok, rename_err = vim.uv.fs_rename(tmp, path)
  file_lock.release(lease)
  if not ok then
    pcall(vim.fn.delete, tmp)
    retry(owner, path, collect, on_saved, warn, "rename failed: " .. tostring(rename_err))
    return
  end
  owner.dirty_save_failures = 0
  on_saved(arr)
end

return M
