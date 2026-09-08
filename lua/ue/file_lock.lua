-- Cross-process filesystem lease for UE cache writers.
-- Publish an already nonempty directory atomically. Reclaim only the observed
-- token's file, then rmdir (never recursive delete): a delayed reclaimer cannot
-- remove a replacement owner's differently named file or nonempty directory.

local fs = require("ue.core.fs")

local M = {}

local function read_owner(path)
  local name = "owner.json" -- Read old leases, but never publish this fixed name.
  local scan = vim.uv.fs_scandir(path)
  if scan then
    while true do
      local entry = vim.uv.fs_scandir_next(scan)
      if not entry then break end
      if entry:match("^owner%..+%.json$") then name = entry; break end
    end
  end
  local file = io.open(fs.join(path, name), "rb")
  if not file then return nil, name, "unreadable owner record" end
  local raw = file:read("*a")
  file:close()
  local ok, value = pcall(vim.json.decode, raw or "")
  if not ok then return nil, name, "corrupt owner record" end
  if type(value) ~= "table" or not tonumber(value.pid) or tonumber(value.pid) <= 0
      or type(value.token) ~= "string" or value.token == "" then
    return nil, name, "invalid owner record (expected positive PID and token)"
  end
  return value, name
end

local function process_alive(pid)
  pid = tonumber(pid)
  if not pid or pid <= 0 then return false end
  if pid == vim.fn.getpid() then return true end
  if not vim.uv or type(vim.uv.kill) ~= "function" then return true end
  local ok, result, err = pcall(vim.uv.kill, pid, 0)
  if ok and result ~= nil and result ~= false then return true end
  -- Permission failures and unavailable probes do not prove process death.
  return not (ok and tostring(err):find("ESRCH", 1, true))
end

local function recent_unknown_owner(path)
  local stat = vim.uv.fs_stat(path)
  local mtime = stat and stat.mtime
  local seconds = type(mtime) == "table" and tonumber(mtime.sec) or tonumber(mtime)
  return seconds and (os.time() - seconds) < 5
end

local function write_owner(path, owner, name)
  local file = io.open(fs.join(path, name), "wb")
  if not file then return false end
  local wrote = file:write(vim.json.encode(owner))
  local closed = file:close()
  return wrote ~= nil and closed ~= nil
end

---Acquire an exclusive cross-process lease without waiting.
---@return table? handle
---@return string? error
function M.acquire(path)
  path = fs.norm(path)
  if path == "" then return nil, "lock path is empty" end
  fs.ensure_dir(fs.dirname(path))

  local token = table.concat({ vim.fn.getpid(), vim.uv.hrtime(), math.random(1, 2147483646) }, "-")
  local name = "owner." .. token .. ".json"
  local staged = path .. ".pending." .. token
  local created, create_err = vim.uv.fs_mkdir(staged, 448)
  if not created then return nil, create_err end
  local function discard_staged()
    vim.uv.fs_unlink(fs.join(staged, name))
    vim.uv.fs_rmdir(staged)
  end
  if not write_owner(staged, { pid = vim.fn.getpid(), token = token, acquired_at = os.time() }, name) then
    discard_staged()
    return nil, "cannot write lock owner: " .. path
  end

  local owner_diagnostic
  for _ = 1, 2 do
    local ok = vim.uv.fs_rename(staged, path)
    if ok then return { path = path, token = token } end
    local owner, observed_name, owner_err = read_owner(path)
    if owner_err then
      owner_diagnostic = owner_err .. ": " .. fs.join(path, observed_name)
    end
    if (owner and process_alive(owner.pid)) or (not owner and recent_unknown_owner(path)) then
      discard_staged()
      return nil, "owned by live process " .. tostring(owner and owner.pid or "initializing")
    end
    if owner then vim.uv.fs_unlink(fs.join(path, observed_name)) end
    -- A new owner published since read_owner makes rmdir fail with ENOTEMPTY.
    -- Crashes between unlink/rmdir leave an empty, safely replaceable directory.
    vim.uv.fs_rmdir(path)
  end
  discard_staged()
  if owner_diagnostic then
    return nil, "lock preserved: " .. owner_diagnostic
      .. "; inspect the holding process and owner record before manual recovery"
  end
  return nil, "cannot acquire lock: " .. path
end

function M.release(handle)
  if type(handle) ~= "table" or not handle.path or not handle.token then return false end
  local owner, name = read_owner(handle.path)
  if not owner or owner.token ~= handle.token then return false end
  local removed = vim.uv.fs_unlink(fs.join(handle.path, name))
  if not removed then return false end
  vim.uv.fs_rmdir(handle.path)
  return true
end

function M.owner(path)
  return read_owner(fs.norm(path))
end

return M
