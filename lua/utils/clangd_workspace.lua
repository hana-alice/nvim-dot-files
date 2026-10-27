-- Workspace classification shared by clangd startup and C++ navigation.
--
-- UE buffers keep the controlled CDB/semantic route. Ordinary C/C++
-- workspaces use clangd directly and may keep their compilation database in
-- a CMake build directory. Discovery here is intentionally bounded: inspect
-- declared CMake presets and the immediate children of conventional build
-- roots, never recursively walk a workspace or vendor tree on the UI thread.

local M = {}

local fs = require("ue.core.fs")
local platform = require("utils.platform")

local function path_key(path)
  return platform.driver().path_key(fs.norm(path))
end

local function path_is_inside(path, root)
  local normalized_path = path_key(path)
  local normalized_root = path_key(root):gsub("/+$", "")
  if normalized_path == "" or normalized_root == "" then
    return false
  end
  return normalized_path == normalized_root
    or normalized_path:sub(1, #normalized_root + 1) == normalized_root .. "/"
end

function M.is_path_in_ue_context(path, ctx)
  if type(ctx) ~= "table" then
    return false
  end
  return path_is_inside(path, ctx.engine_root)
    or path_is_inside(path, ctx.project_root)
end

local function read_json(path)
  if not fs.is_file(path) then
    return nil
  end
  local ok_read, lines = pcall(vim.fn.readfile, path, "b")
  if not ok_read then
    return nil
  end
  local text = table.concat(lines, "\n"):gsub("^\239\187\191", "")
  local ok_decode, decoded = pcall(vim.json.decode, text)
  return ok_decode and type(decoded) == "table" and decoded or nil
end

local function preset_table(root)
  local presets = {}
  for _, name in ipairs({ "CMakePresets.json", "CMakeUserPresets.json" }) do
    local doc = read_json(fs.join(root, name))
    for _, preset in ipairs(doc and doc.configurePresets or {}) do
      if type(preset) == "table" and type(preset.name) == "string" then
        presets[preset.name] = preset
      end
    end
  end
  return presets
end

local function inherited_binary_dir(presets, name, visiting)
  local preset = presets[name]
  if not preset or visiting[name] then
    return nil
  end
  visiting[name] = true
  if type(preset.binaryDir) == "string" and preset.binaryDir ~= "" then
    visiting[name] = nil
    return preset.binaryDir
  end
  local parents = type(preset.inherits) == "table" and preset.inherits
    or (type(preset.inherits) == "string" and { preset.inherits } or {})
  for _, parent in ipairs(parents) do
    local inherited = inherited_binary_dir(presets, parent, visiting)
    if inherited then
      visiting[name] = nil
      return inherited
    end
  end
  visiting[name] = nil
  return nil
end

local function expand_binary_dir(root, preset_name, value)
  value = tostring(value or "")
  value = value:gsub("%${sourceDir}", function() return root end)
  value = value:gsub("%${sourceParentDir}", function() return fs.dirname(root) end)
  value = value:gsub("%${sourceDirName}", function() return vim.fs.basename(root) end)
  value = value:gsub("%${presetName}", function() return preset_name end)
  -- Do not guess environment/vendor macro values. A bounded conventional
  -- fallback below still handles common layouts.
  if value == ""
    or value:find("${", 1, true)
    or value:find("$env{", 1, true)
    or value:find("$penv{", 1, true)
  then
    return nil
  end
  if not fs.is_absolute_path(value) then
    value = fs.join(root, value)
  end
  return fs.norm(value)
end

local function add_candidate(candidates, seen, dir, source)
  dir = fs.norm(dir)
  if dir == "" then return end
  local key = path_key(dir)
  if seen[key] then return end
  seen[key] = true
  local cdb = fs.join(dir, "compile_commands.json")
  local stat = (vim.uv or vim.loop).fs_stat(cdb)
  if stat and stat.type == "file" then
    local mtime = stat.mtime
    candidates[#candidates + 1] = {
      dir = dir,
      source = source,
      mtime = type(mtime) == "table" and tonumber(mtime.sec) or tonumber(mtime) or 0,
    }
  end
end

local function add_immediate_build_children(candidates, seen, parent)
  local uv = vim.uv or vim.loop
  local scan = uv.fs_scandir(parent)
  if not scan then return end
  local children = {}
  while #children < 64 do
    local name, kind = uv.fs_scandir_next(scan)
    if not name then break end
    if kind == "directory" then
      children[#children + 1] = name
    end
  end
  table.sort(children)
  for _, name in ipairs(children) do
    add_candidate(candidates, seen, fs.join(parent, name), "build-child:" .. name)
  end
end

function M.find_compile_commands_dir(root)
  root = fs.norm(root)
  if root == "" or not fs.is_dir(root) then
    return nil, "workspace-root-unavailable"
  end

  local root_cdb = fs.join(root, "compile_commands.json")
  if fs.is_file(root_cdb) then
    return root, "workspace-root"
  end

  local candidates, seen = {}, {}
  local presets = preset_table(root)
  local names = vim.tbl_keys(presets)
  table.sort(names)
  for _, name in ipairs(names) do
    local preset = presets[name]
    if preset.hidden ~= true then
      local value = inherited_binary_dir(presets, name, {})
      local dir = value and expand_binary_dir(root, name, value) or nil
      if dir then
        add_candidate(candidates, seen, dir, "cmake-preset:" .. name)
      end
    end
  end

  for _, relative in ipairs({
    "build", "build/debug", "build/Debug", "build/release", "build/Release",
    "out/build", "out/build/debug", "out/build/Debug",
    "cmake-build-debug", "cmake-build-release",
  }) do
    add_candidate(candidates, seen, fs.join(root, relative), "conventional:" .. relative)
  end
  add_immediate_build_children(candidates, seen, fs.join(root, "build"))
  add_immediate_build_children(candidates, seen, fs.join(root, "out", "build"))

  table.sort(candidates, function(a, b)
    if a.mtime ~= b.mtime then
      return a.mtime > b.mtime
    end
    return path_key(a.dir) < path_key(b.dir)
  end)
  local selected = candidates[1]
  if not selected then
    return nil, "compile-database-unavailable"
  end
  return selected.dir, selected.source
end

function M.apply_policy(cmd, root, engine_root)
  -- Calls without a resolved root retain the conservative UE defaults. A
  -- proven ordinary workspace keeps project .clangd and clang-tidy policy.
  if not root or root == "" or engine_root then
    table.insert(cmd, "--clang-tidy=false")
    table.insert(cmd, "--enable-config=false")
    return
  end

  local cdb_dir = M.find_compile_commands_dir(root)
  if cdb_dir then
    table.insert(cmd, "--compile-commands-dir=" .. cdb_dir)
  end
end

return M
