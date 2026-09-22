-- Capture compiler-authored unity provenance separately from the native CDB.
-- Pipeline sealing belongs to the asynchronous producer, after its transforms.
local M = {}
local fs = require("ue.core.fs")

function M.extract_members(unity_file, engine_source_dir, read_all, is_file)
  local content = read_all(unity_file)
  if not content then
    return nil
  end
  local includes, complete = {}, true
  for inc_path in content:gmatch('#include%s+"([^"]+%.[cC][pP][pP])"') do
    local absolute
    if inc_path:match("^[A-Za-z]:") or inc_path:match("^/") then
      absolute = fs.norm(inc_path)
    else
      absolute = fs.norm(fs.join(engine_source_dir, inc_path))
      if not is_file(absolute) then
        absolute = fs.norm(fs.join(fs.dirname(unity_file), inc_path))
      end
    end
    if is_file(absolute) then
      includes[#includes + 1] = absolute
    else
      complete = false
    end
  end
  if #includes > 0 then
    return includes, content, complete
  end
  return nil, content, false
end

function M.entry_hash(entry)
  if
    type(entry) ~= "table"
    or type(entry.directory) ~= "string"
    or type(entry.file) ~= "string"
    or type(entry.arguments) ~= "table"
    or #entry.arguments == 0
  then
    return nil
  end
  if entry.directory == "" or entry.file == "" or entry.arguments[1] == "" then
    return nil
  end
  local fields = { entry.directory, entry.file }
  vim.list_extend(fields, entry.arguments)
  for index, field in ipairs(fields) do
    if type(field) ~= "string" or field:find("\0", 1, true) then
      return nil
    end
    fields[index] = tostring(#field) .. ":" .. field
  end
  return vim.fn.sha256(table.concat(fields))
end

function M.add_dependency(dependencies, path, content)
  path = fs.norm(path)
  if not fs.is_absolute_path(path) or type(content) ~= "string" then
    dependencies.invalid = true
    return
  end
  local ok, hash = pcall(vim.fn.sha256, content)
  if not ok then
    dependencies.invalid = true
    return
  end
  if dependencies[path] and dependencies[path] ~= hash then
    dependencies.invalid = true
  end
  dependencies[path] = hash
end

function M.finalize(groups, merged, synthetic_shaders)
  local hashes, directories = {}, {}
  for _, entry in ipairs(merged or {}) do
    local file = fs.is_absolute_path(entry.file) and entry.file or fs.join(entry.directory or "", entry.file)
    local key = vim.fs.normalize(file):lower()
    if hashes[key] ~= nil then
      hashes[key] = false
    else
      hashes[key] = M.entry_hash(entry) or false
      directories[key] = entry.directory
    end
  end
  local origin = { schema = 1, groups = {} }
  for _, group in ipairs(groups or {}) do
    local dependencies = group.dependencies or {}
    local valid = not group.invalid
      and not dependencies.invalid
      and fs.is_absolute_path(group.unity or "")
      and dependencies[fs.norm(group.unity)] ~= nil
      and #(group.members or {}) > 0
      and #(group.entries or {}) == #group.members
    local commands, seen = {}, {}
    for path, hash in pairs(dependencies) do
      if not fs.is_absolute_path(path) or type(hash) ~= "string" or not hash:match("^%x+$") or #hash ~= 64 then
        valid = false
      end
    end
    for index, member in ipairs(group.members or {}) do
      local entry = group.entries and group.entries[index]
      local hash = M.entry_hash(entry)
      local key = vim.fs.normalize(member):lower()
      if
        not fs.is_absolute_path(member)
        or seen[key]
        or not entry
        or not hash
        or vim.fs.normalize(entry.file):lower() ~= key
        or hashes[key] ~= hash
      then
        valid = false
      end
      seen[key] = true
      commands[member] = hash
    end
    if valid then
      origin.groups[#origin.groups + 1] = {
        unity = fs.norm(group.unity),
        members = vim.deepcopy(group.members),
        dependencies = vim.deepcopy(dependencies),
        commands = commands,
      }
    end
  end
  if synthetic_shaders ~= nil then
    origin.synthetic_shaders = {}
    local candidates, counts = {}, {}
    for _, record in ipairs(type(synthetic_shaders) == "table" and synthetic_shaders or {}) do
      if type(record) == "table" and type(record.file) == "string" then
        local key = vim.fs.normalize(record.file):lower()
        candidates[key], counts[key] = record, (counts[key] or 0) + 1
      end
    end
    for key, record in pairs(candidates) do
      if counts[key] == 1 and fs.is_absolute_path(record.file) and fs.is_absolute_path(record.directory)
          and record.directory == directories[key] and type(record.command_hash) == "string"
          and hashes[key] == record.command_hash then
        origin.synthetic_shaders[#origin.synthetic_shaders + 1] = vim.deepcopy(record)
      end
    end
    table.sort(origin.synthetic_shaders, function(a, b) return a.file < b.file end)
  end
  return origin
end

function M.write(cdb_path, origin)
  local path = cdb_path .. ".unity-origin.json"
  local previous = io.open(path, "rb")
  if previous then
    local content = previous:read("*a")
    previous:close()
    local decoded, value = pcall(vim.json.decode, content or "")
    if decoded and vim.deep_equal(value, origin) then
      return true
    end
  end
  local temporary = path .. ".tmp." .. tostring(vim.fn.getpid()) .. "." .. tostring(vim.uv.hrtime())
  local file, err = io.open(temporary, "wb")
  if not file then
    return false, err
  end
  local wrote, write_err = file:write(vim.json.encode(origin))
  local closed, close_err = file:close()
  if not wrote or not closed then
    pcall(os.remove, temporary)
    return false, write_err or close_err
  end
  local renamed, rename_err = vim.uv.fs_rename(temporary, path)
  if not renamed then
    pcall(os.remove, temporary)
  end
  return renamed ~= nil, rename_err
end

return M
