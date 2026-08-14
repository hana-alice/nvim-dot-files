-- ue.cdb.source — validate and publish trusted compile database sources.

local fs = require("ue.core.fs")

local M = {}

local function decode(content)
  local ok, entries = pcall(vim.json.decode, tostring(content or ""))
  if not ok or type(entries) ~= "table" then
    return nil, "compile_commands.json is not valid JSON"
  end
  if #entries == 0 then
    return nil, "compile_commands.json has no entries"
  end
  return entries
end

local function owned_roots(ctx)
  local roots, seen = {}, {}
  local function add(path)
    path = fs.norm(path)
    if path ~= "" and not seen[path] then
      seen[path] = true
      roots[#roots + 1] = path
    end
  end
  add(ctx and ctx.engine_root)
  add(ctx and ctx.project_root)
  if ctx and ctx.uproject then add(fs.dirname(ctx.uproject)) end
  return roots
end

local function entry_path(entry)
  local file = fs.norm(type(entry) == "table" and entry.file or "")
  if file == "" then return "" end
  if fs.is_absolute_path(file) then return file end
  return fs.join(type(entry) == "table" and entry.directory or "", file)
end

---@param content string
---@param ctx table
---@param tuple table
---@param driver table?
---@return boolean, table
function M.validate_content(content, ctx, tuple, driver)
  local entries, decode_err = decode(content)
  if not entries then
    return false, { reason = decode_err }
  end

  local roots = owned_roots(ctx or {})
  local foreign = {}
  for _, entry in ipairs(entries) do
    local file = entry_path(entry)
    local owned = false
    for _, root in ipairs(roots) do
      if fs.path_has_prefix(file, root) then
        owned = true
        break
      end
    end
    if not owned then
      foreign[#foreign + 1] = file ~= "" and file or "<missing-file>"
      if #foreign >= 3 then break end
    end
  end
  if #foreign > 0 then
    return false, {
      reason = "compile_commands contains entries outside current engine/project roots: "
        .. table.concat(foreign, ", "),
      entry_count = #entries,
    }
  end

  if type(driver) == "table" and type(driver.validate_semantic_cdb) == "function" then
    local ok, result = pcall(driver.validate_semantic_cdb, entries, tuple or {})
    if not ok then
      return false, { reason = "target CDB validator failed: " .. tostring(result) }
    end
    if type(result) ~= "table" or result.ok ~= true then
      return false, {
        reason = type(result) == "table" and tostring(result.reason or "target tuple evidence missing")
          or "target tuple evidence missing",
        entry_count = #entries,
      }
    end
  end

  return true, { entries = entries, entry_count = #entries }
end

function M.read_valid(path, ctx, tuple, driver)
  local file = io.open(path, "rb")
  if not file then
    return false, { reason = "compile_commands source is unreadable: " .. tostring(path) }
  end
  local content = file:read("*a")
  file:close()
  local ok, info = M.validate_content(content, ctx, tuple, driver)
  if not ok then return false, info end
  info.content = content
  info.path = fs.norm(path)
  return true, info
end

--- Atomically promote a validated pending source on the same filesystem.
function M.promote(pending_path, stable_path, ctx, tuple, driver)
  local ok, info = M.read_valid(pending_path, ctx, tuple, driver)
  if not ok then return false, info end

  local existing = io.open(stable_path, "rb")
  if existing then
    local current = existing:read("*a")
    existing:close()
    if current == info.content then
      pcall(os.remove, pending_path)
      info.path = fs.norm(stable_path)
      info.no_op = true
      return true, info
    end
  end

  fs.ensure_dir(fs.dirname(stable_path))
  local renamed, rename_err = os.rename(pending_path, stable_path)
  if not renamed then
    return false, { reason = "failed to publish semantic CDB: " .. tostring(rename_err) }
  end
  info.path = fs.norm(stable_path)
  info.no_op = false
  return true, info
end

return M
