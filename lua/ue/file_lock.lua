-- Cross-process filesystem lease for UE cache writers.
-- Directory creation is atomic on every supported host. The owner record lets
-- a later process reclaim a lease after the owning Neovim has exited.

local fs = require("ue.core.fs")

local M = {}

local function owner_path(path)
  return fs.join(path, "owner.json")
end

local function read_owner(path)
  local file = io.open(owner_path(path), "rb")
  if not file then return nil end
  local raw = file:read("*a")
  file:close()
  local ok, value = pcall(vim.json.decode, raw or "")
  return ok and type(value) == "table" and value or nil
end

local function process_alive(pid)
  pid = tonumber(pid)
  if not pid or pid <= 0 then return false end
  if pid == vim.fn.getpid() then return true end
  if not vim.uv or type(vim.uv.kill) ~= "function" then return true end
  local ok, result = pcall(vim.uv.kill, pid, 0)
  return ok and result ~= nil and result ~= false
end

local function recent_unknown_owner(path)
  local stat = vim.uv.fs_stat(path)
  local mtime = stat and stat.mtime
  local seconds = type(mtime) == "table" and tonumber(mtime.sec) or tonumber(mtime)
  return seconds and (os.time() - seconds) < 5
end

local function write_owner(path, owner)
  local file = io.open(owner_path(path), "wb")
  if not file then return false end
  file:write(vim.json.encode(owner))
  file:close()
  return true
end

---Acquire an exclusive cross-process lease without waiting.
---@return table? handle
---@return string? error
function M.acquire(path)
  path = fs.norm(path)
  if path == "" then return nil, "lock path is empty" end
  fs.ensure_dir(fs.dirname(path))

  for _ = 1, 2 do
    local ok, err = vim.uv.fs_mkdir(path, 448)
    if ok then
      local token = table.concat({ vim.fn.getpid(), vim.uv.hrtime(), math.random(1, 2147483646) }, "-")
      local owner = { pid = vim.fn.getpid(), token = token, acquired_at = os.time() }
      if not write_owner(path, owner) then
        pcall(vim.fn.delete, path, "rf")
        return nil, "cannot write lock owner: " .. path
      end
      return { path = path, token = token }
    end

    local owner = read_owner(path)
    if (owner and process_alive(owner.pid)) or (not owner and recent_unknown_owner(path)) then
      return nil, "owned by live process " .. tostring(owner and owner.pid or "initializing")
    end
    pcall(vim.fn.delete, path, "rf")
    if err and not fs.is_dir(path) then
      -- Retry once after reclaiming a stale directory.
    end
  end
  return nil, "cannot acquire lock: " .. path
end

function M.release(handle)
  if type(handle) ~= "table" or not handle.path or not handle.token then return false end
  local owner = read_owner(handle.path)
  if not owner or owner.token ~= handle.token then return false end
  return pcall(vim.fn.delete, handle.path, "rf")
end

function M.owner(path)
  return read_owner(fs.norm(path))
end

return M
