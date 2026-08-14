-- ue.core.fs — pure path / file utilities lifted out of the monolithic
-- `lua/ue.lua`. Phase B mechanical extraction: every function here was a
-- top-level `local function` in `ue.lua` and is reused via
-- `local norm = require("ue.core.fs").norm` aliases at the original site.
--
-- IMPORTANT: do not change any function signature or observable behaviour
-- in this module. Behavioural changes belong in a follow-up commit so the
-- extraction commit stays a pure code move.

local M = {}

function M.trim(value)
  return vim.trim(tostring(value or ""))
end

function M.norm(path)
  if not path or path == "" then
    return ""
  end
  path = tostring(path):gsub("\\", "/")
  local unc = path:sub(1, 2) == "//"
  path = path:gsub("/+", "/")
  if unc then
    path = "/" .. path
  end
  if #path > 1 and path:sub(-1) == "/" then
    path = path:sub(1, -2)
  end
  return path
end

function M.cwd()
  local uv_cwd = vim.uv and vim.uv.cwd and vim.uv.cwd() or nil
  if uv_cwd and uv_cwd ~= "" then
    return M.norm(uv_cwd)
  end
  return M.norm(vim.fn.getcwd())
end

function M.join(...)
  return M.norm(table.concat(vim.iter({ ... }):flatten():totable(), "/"))
end

function M.dirname(path)
  return M.norm(vim.fs.dirname(path))
end

function M.is_dir(path)
  return vim.fn.isdirectory(path) == 1
end

function M.is_file(path)
  -- Defensive: vim.fn.filereadable raises E976 "Using a Blob as a String"
  -- when called with a Vim Blob value. Trap: Lua's `type()` reports Blob
  -- as "string" (it goes through the same metatable path as Vim strings),
  -- so a `type(path) ~= "string"` guard does NOT filter Blobs. We have to
  -- (a) pcall filereadable as a hard backstop, and (b) coerce via tostring
  -- so the rare Blob source.path frame from lldb-dap doesn't blow up the
  -- whole stackTrace listener.
  if path == nil or path == "" then return false end
  local s = tostring(path)
  if s == "" then return false end
  local ok, ret = pcall(vim.fn.filereadable, s)
  return ok and ret == 1
end

function M.ensure_dir(path)
  if path == "" or M.is_dir(path) then return end

  local last_err
  for attempt = 1, 8 do
    local ok, result = pcall(vim.fn.mkdir, path, "p")
    if M.is_dir(path) then return end
    last_err = ok and ("mkdir returned " .. tostring(result)) or result
    -- mkdir(..., "p") can report E739 when another process creates one of
    -- the intermediate parents.  Retry the remaining suffix after yielding
    -- briefly; a single final is_dir() check is not enough in that race.
    if attempt < 8 then
      vim.wait(math.min(10, attempt * 2))
    end
  end
  error(last_err or ("cannot create directory " .. path))
end

function M.file_stat(path)
  path = M.norm(path)
  if path == "" or not vim.uv or not vim.uv.fs_stat then
    return nil
  end
  return vim.uv.fs_stat(path)
end

function M.file_mtime(path)
  local stat = M.file_stat(path)
  local mtime = stat and stat.mtime or nil
  if type(mtime) == "table" then
    return tonumber(mtime.sec) or 0
  end
  return tonumber(mtime) or 0
end

function M.path_has_prefix(path, prefix)
  path = M.norm(path)
  prefix = M.norm(prefix)
  if prefix == "" then
    return false
  end
  if prefix == "/" then
    return path:sub(1, 1) == "/"
  end
  return path == prefix or path:sub(1, #prefix + 1) == prefix .. "/"
end

function M.is_absolute_path(path)
  path = M.norm(path)
  return path ~= "" and (path:sub(1, 1) == "/" or path:match("^[A-Za-z]:/") or path:match("^//"))
end

function M.split_path(path)
  local parts = {}
  for part in M.norm(path):gmatch("[^/]+") do
    table.insert(parts, part)
  end
  return parts
end

function M.common_ancestor(paths)
  local normalized = {}
  local absolute = true

  for _, path in ipairs(paths or {}) do
    path = M.norm(path)
    if path ~= "" then
      table.insert(normalized, path)
      absolute = absolute and path:sub(1, 1) == "/"
    end
  end

  if #normalized == 0 then
    return ""
  end

  local shared = M.split_path(normalized[1])
  for index = 2, #normalized do
    local parts = M.split_path(normalized[index])
    local keep = 0
    for part_index = 1, math.min(#shared, #parts) do
      if shared[part_index] ~= parts[part_index] then
        break
      end
      keep = part_index
    end
    while #shared > keep do
      table.remove(shared)
    end
    if #shared == 0 then
      break
    end
  end

  if #shared == 0 then
    return absolute and "/" or ""
  end

  local prefix = table.concat(shared, "/")
  if absolute then
    return "/" .. prefix
  end
  return prefix
end

function M.relative_to(root, path)
  root = M.norm(root)
  path = M.norm(path)

  if root == "" then
    return path
  end
  if root == "/" then
    return path
  end
  if path == root then
    return "."
  end
  if not M.path_has_prefix(path, root) then
    return path
  end
  return path:sub(#root + 2)
end

return M
