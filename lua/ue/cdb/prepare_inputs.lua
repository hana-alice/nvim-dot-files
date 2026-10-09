-- Runs only in the preparation inventory subprocess: never scan a large CDB
-- on the editor thread. Unprovable command inputs disable reuse conservatively.
local M = {}
local uv = vim.uv

local function absolute(path, base)
  if type(path) ~= "string" or path == "" or path:find("\0", 1, true) then
    error("invalid input path")
  end
  path = path:gsub("\\", "/")
  if path:find("%$", 1) or path:find("%%[%w_]+%%") then error("unexpanded input path: " .. path) end
  if not path:match("^/") and not path:match("^[A-Za-z]:/") then
    if not base then error("relative path without cwd: " .. path) end
    path = base .. "/" .. path
  end
  return vim.fs.normalize(path)
end

local function json(path)
  local file = assert(io.open(path, "rb"), "cannot read " .. path)
  local data = file:read("*a")
  file:close()
  return vim.json.decode(data)
end

local function collect(request)
  local ctx, paths = request.ctx or {}, (request.ctx or {}).paths or {}
  local roots, seen, products, artifacts, compilers = {}, {}, {}, {}, {}
  local windows = uv.os_uname().sysname:match("Windows") ~= nil
  local function key(path) return windows and path:lower() or path end
  local function covered(path)
    local value = key(path)
    for _, root in ipairs(roots) do
      local parent = key(root.path)
      if value == parent or value:sub(1, #parent + 1) == parent .. "/" then return true end
    end
    return false
  end
  local function root(path)
    path = absolute(path)
    if covered(path) then return end
    local physical = uv.fs_realpath(path)
    local stat = uv.fs_stat(path)
    if not stat or stat.type ~= "directory" then path = vim.fs.dirname(path) end
    while path and not uv.fs_stat(path) do path = vim.fs.dirname(path) end
    if not path then error("no existing watch ancestor") end
    path = absolute(path)
    if not covered(path) then
      for index = #roots, 1, -1 do
        local value, parent = key(roots[index].path), key(path)
        if value:sub(1, #parent + 1) == parent .. "/" then table.remove(roots, index) end
      end
      roots[#roots + 1] = { path = path, recursive = true }
    end
    local resolved = physical or uv.fs_realpath(path)
    if resolved then
      resolved = absolute(resolved)
      if stat and stat.type ~= "directory" then resolved = vim.fs.dirname(resolved) end
      if not covered(resolved) then root(resolved) end
    end
  end
  local function input(path, base)
    path = absolute(path, base)
    if not covered(path) then root(path) end
    -- Resolve even paths covered by a lexical root: junctions may point out.
    if not seen[key(path)] then
      seen[key(path)] = true
      local physical = uv.fs_realpath(path)
      if physical and not covered(absolute(physical)) then root(physical) end
    end
    return path
  end
  local function product(path, required)
    if not path or path == "" then
      if required then error("required product path unavailable") end
      return
    end
    path = absolute(path)
    if products[path] then return end
    local stat = uv.fs_stat(path)
    if not stat or stat.type ~= "file" or stat.size == 0 then
      if required then error("required product missing/empty: " .. path) end
      return
    end
    local identity = { size = stat.size, mtime = stat.mtime, ctime = stat.ctime, ino = tostring(stat.ino) }
    products[path] = identity
    artifacts[#artifacts + 1] = { path = path, identity = identity }
    input(path)
  end
  local function compiler(path, base, executable_only)
    local compiler_key = tostring(base or "") .. "\0" .. path .. tostring(executable_only)
    if compilers[compiler_key] then return end
    compilers[compiler_key] = true
    if not path:find("[/\\]") and not path:match("^[A-Za-z]:") then
      path = vim.fn.exepath(path)
      if path == "" then error("compiler not resolvable") end
    end
    path = input(path, base)
    if not uv.fs_stat(path) then error("compiler missing: " .. path) end
    -- bin's parent covers lib/clang resources and adjacent toolchain files.
    local directory = vim.fs.dirname(path)
    -- Python installations often place python.exe directly in their root;
    -- watching its grandparent would accidentally subscribe to a whole drive.
    root(executable_only and vim.fs.basename(directory):lower() ~= "bin"
      and directory or vim.fs.dirname(directory))
  end
  root(assert(ctx.engine_root, "engine root unavailable"))
  if ctx.project_root then root(ctx.project_root) end
  local config_root = request.config_root or vim.fn.stdpath("config")
  for _, directory in ipairs({ "lua", "tools", "scripts" }) do
    root(absolute(directory, config_root))
  end
  if request.tools_dir then root(request.tools_dir) end
  for _, executable in pairs(request.tools_executables or {}) do
    if type(executable) ~= "string" or executable == "" then error("tool executable unavailable") end
    compiler(executable, nil, true)
  end
  for name, value in pairs(request.environment or {}) do
    if type(value) == "string" and value ~= "" then
      if name:match("INCLUDE") or name == "CPATH" or name == "SDKROOT" or name == "LIBRARY_PATH" then
        local separator = windows and ";" or ":"
        for path in value:gmatch("[^" .. separator .. "]+") do input(path, ctx.engine_root) end
      elseif name == "CL" or name == "_CL_" or name == "CCC_OVERRIDE_OPTIONS" then
        error("compiler environment overrides cannot be inventoried")
      end
    end
  end
  local active = absolute(request.active_cdb or request.active or request.cdb_path or paths.active_cdb)
  local entries = json(active)
  if type(entries) ~= "table" or #entries == 0 then error("empty/invalid CDB") end
  local overlays = {}
  local function overlay(path, cwd)
    path = input(path, cwd)
    if overlays[key(path)] then return end
    overlays[key(path)] = true
    -- Both the owned header-casing overlay and verified-batch VFS writer
    -- serialize JSON. YAML/unknown overlay dialects remain unavailable.
    local value = json(path)
    if type(value) ~= "table" or type(value.roots) ~= "table" then error("unsupported VFS overlay") end
    local base = value["overlay-relative"] == true and vim.fs.dirname(path) or cwd
    local function nodes(node)
      if type(node) ~= "table" then return end
      if node["external-contents"] then input(node["external-contents"], base) end
      if node.type and node.type ~= "file" and node.type ~= "directory" then error("unsupported VFS node") end
      for _, child in pairs(node) do if type(child) == "table" then nodes(child) end end
    end
    nodes(value.roots)
  end
  local separate = {
    ["-I"] = true, ["-isystem"] = true, ["-iquote"] = true, ["-idirafter"] = true,
    ["-include"] = true, ["-include-pch"] = true, ["-imacros"] = true,
    ["-isysroot"] = true, ["--sysroot"] = true, ["-ivfsoverlay"] = true,
    ["-resource-dir"] = true, ["-fmodule-map-file"] = true, ["-fmodule-file"] = true,
    ["-o"] = true, ["-MF"] = true, ["/I"] = true, ["/FI"] = true, ["/Fo"] = true,
  }
  local attached = { "--sysroot=", "-resource-dir=", "-fmodule-map-file=", "-fmodule-file=",
    "-ivfsoverlay=", "-isystem", "-iquote", "-idirafter", "-include-pch", "-include", "-imacros",
    "-I", "/external:I", "/FI", "/Fo", "/I" }
  for _, entry in ipairs(entries) do
    if type(entry.arguments) ~= "table" or #entry.arguments == 0 then error("command-only CDB unsupported") end
    local cwd = absolute(entry.directory)
    input(entry.file, cwd)
    compiler(entry.arguments[1], cwd)
    local index = 2
    while index <= #entry.arguments do
      local token = entry.arguments[index]
      if type(token) ~= "string" then error("invalid argument") end
      if token:sub(1, 1) == "@" then error("unexpanded response file") end
      if separate[token] then
        index = index + 1
        if token == "-ivfsoverlay" then overlay(entry.arguments[index], cwd)
        else input(entry.arguments[index], cwd) end
      else
        local parsed = false
        for _, prefix in ipairs(attached) do
          if token:sub(1, #prefix) == prefix and #token > #prefix then
            if prefix == "-ivfsoverlay=" then overlay(token:sub(#prefix + 1), cwd)
            else input(token:sub(#prefix + 1), cwd) end
            parsed = true
            break
          end
        end
        if not parsed then
          if token:sub(1, 1) ~= "-" and token:sub(1, 1) ~= "/" then
            if token:find("[/\\]") or token:match("%.[%w]+$") then input(token, cwd) end
          elseif token:match("^[A-Za-z]:/") or token:match("^/[^-].*%.[%w]+$") then
            input(token, cwd)
          elseif token:find("[/\\]") or token:match("[A-Za-z]:") then
            error("unrecognized path argument: " .. token)
          end
        end
      end
      index = index + 1
    end
  end
  product(active, true)
  local require_products = request.require_products == true
  for _, path in ipairs(request.targets or { active }) do
    product(path, require_products)
    for _, suffix in ipairs({ ".unity-origin.json", ".unity-receipt.json", ".pipeline-result.json" }) do
      product(path .. suffix, require_products)
    end
    local origin_path = path .. ".unity-origin.json"
    if uv.fs_stat(origin_path) then
      local origin = json(origin_path)
      for _, group in ipairs(origin.groups or {}) do
        input(group.unity)
        for _, member in ipairs(group.members or {}) do input(member) end
        for dependency in pairs(group.dependencies or {}) do input(dependency) end
      end
    end
    local manifest_path = vim.fs.dirname(path) .. "/compile_commands.partition.json"
    product(manifest_path, require_products)
    if uv.fs_stat(manifest_path) then
      for _, group in ipairs(json(manifest_path).groups or {}) do product(group.file, true) end
    end
  end
  for _, name in ipairs({ "index_current_cdb", "index_hot_cdb", "index_full_cdb", "semantic_cdb" }) do
    product(paths[name], require_products)
  end
  for _, name in ipairs({ "semantic_current_cdb", "semantic_hot_cdb", "semantic_full_cdb",
    "index_inject_full_cdb", "shader_cdb", "current_index", "hot_index", "full_index" }) do
    product(paths[name], false)
    if paths[name] then product(paths[name] .. ".manifest.json", false) end
  end
  for _, path in ipairs(request.required_artifacts or {}) do product(path, require_products) end
  local artifact_directories = {}
  local function files(directory, recurse, predicate)
    if not directory then return end
    local physical = uv.fs_realpath(directory)
    if physical then
      local directory_key = key(absolute(physical)) .. tostring(predicate)
      if artifact_directories[directory_key] then return end
      artifact_directories[directory_key] = true
    end
    local scanner = uv.fs_scandir(directory)
    if not scanner then return end
    while true do
      local name, kind = uv.fs_scandir_next(scanner)
      if not name then break end
      local path = directory .. "/" .. name
      if kind == "link" or kind == "unknown" then
        local stat = uv.fs_stat(path)
        if not stat then error("unreadable artifact link: " .. path) end
        kind = stat.type
      end
      if kind == "directory" and recurse then files(path, true, predicate)
      elseif kind == "file" and predicate(name) then product(path, false) end
    end
  end
  files(request.shards_dir or paths.cdb_shards_dir
    or (paths.index_cdb_dir and paths.index_cdb_dir .. "/shards"), false,
    function(name) return name:match("%.json$") end)
  files(request.pch_dir or paths.pch_dir, true, function(name)
    return name:match("recipe") or name:match("%.json$") or name:match("%.pch$")
  end)
  -- Include generated unity sources, VFS overlays and persisted batch proofs;
  -- cache events may be ignored by the editor only when these are stat-bound.
  files(request.semantic_cdb_dir or paths.semantic_cdb_dir
    or (paths.semantic_cdb and vim.fs.dirname(paths.semantic_cdb)), true, function(name)
    return name:match("%.json$") or name:match("%.cpp$") or name:match("%.yaml$")
      or name:match("%.yml$") or name:match("%.h$")
  end)
  for _, name in ipairs({ "index_current_cdb", "index_hot_cdb", "index_full_cdb", "semantic_cdb" }) do
    if paths[name] then product(paths[name] .. ".manifest.json", false) end
  end
  -- Discover junctions without statting every ordinary file. Windows libuv
  -- reports junction dirents as links (verified with fs_symlink junction=true).
  -- Scan every directory, including Build/Intermediate and generated caches;
  -- an unreadable tree or budget exhaustion disables cache instead of guessing.
  local scanned, directory_count = {}, 0
  local function scan(directory)
    local physical = uv.fs_realpath(directory)
    if not physical then error("unresolvable watch directory: " .. directory) end
    local id = key(absolute(physical))
    if scanned[id] then return end
    scanned[id] = true
    directory_count = directory_count + 1
    if directory_count > (request.max_directories or 150000) then error("watch directory scan budget exceeded") end
    local scanner, err = uv.fs_scandir(directory)
    if not scanner then error("unreadable watch directory: " .. directory .. ": " .. tostring(err)) end
    while true do
      local name, kind = uv.fs_scandir_next(scanner)
      if not name then break end
      if name ~= ".git" then
        local child = directory .. "/" .. name
        if kind == "directory" then scan(child)
        elseif kind == "link" or kind == "unknown" then
          local stat = uv.fs_stat(child)
          if not stat then error("unresolvable watch link: " .. child) end
          local target = uv.fs_realpath(child)
          if not target then error("unresolvable physical input: " .. child) end
          input(target)
          if #roots > (request.max_roots or 32) then error("watch root budget exceeded") end
          if stat.type == "directory" then scan(target) end
        end
      end
    end
  end
  local pending = vim.deepcopy(roots)
  for _, item in ipairs(pending) do scan(item.path) end
  -- Links to files can add their parent as a root. Cover siblings and nested
  -- links there too; root count is bounded and physical directories deduped.
  while true do
    local remaining
    for _, item in ipairs(roots) do
      local physical = uv.fs_realpath(item.path)
      if not physical then error("watch root disappeared") end
      if not scanned[key(absolute(physical))] then remaining = item.path; break end
    end
    if not remaining then break end
    scan(remaining)
  end
  table.sort(roots, function(a, b) return a.path < b.path end)
  table.sort(artifacts, function(a, b) return a.path < b.path end)
  if #roots > (request.max_roots or 32) then error("watch root budget exceeded") end
  return { ok = true, roots = roots, products = products, artifacts = artifacts,
    entries = #entries, directories_scanned = directory_count,
    coverage = "explicit argv/origin/VFS inputs and recursively discovered junction targets" }
end

function M.collect(request)
  local ok, result = pcall(collect, request)
  if ok then return result end
  return { ok = false, reason = tostring(result) }
end

-- -l scripts receive request.json in arg[1]; require() has no script argument.
if arg and arg[0] and arg[0]:gsub("\\", "/"):match("/prepare_inputs%.lua$") then
  local ok, request = pcall(json, arg[1])
  io.stdout:write(vim.json.encode(ok and M.collect(request) or { ok = false, reason = tostring(request) }))
end

return M
