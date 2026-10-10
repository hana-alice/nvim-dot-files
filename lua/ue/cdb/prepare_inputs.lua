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

local function tool_identity_value(path, stat, physical)
  if not stat or (stat.type ~= "file" and stat.type ~= "directory") or not physical
    or type(stat.size) ~= "number" or type(stat.mtime) ~= "table"
    or type(stat.mtime.sec) ~= "number" or type(stat.mtime.nsec) ~= "number"
    or type(stat.ctime) ~= "table" or type(stat.ctime.sec) ~= "number" or stat.ctime.sec == 0
    or type(stat.ctime.nsec) ~= "number" or stat.ino == nil or stat.ino == 0
    or stat.dev == nil then error("tool identity unavailable: " .. path) end
  return { type = stat.type, size = stat.size, mtime = stat.mtime, ctime = stat.ctime,
    ino = tostring(stat.ino), dev = tostring(stat.dev), realpath = absolute(physical) }
end

local function tool_identity(path)
  return tool_identity_value(path, uv.fs_stat(path), uv.fs_realpath(path))
end

local function collect(request)
  local ctx, paths = request.ctx or {}, (request.ctx or {}).paths or {}
  local roots, seen, products, artifacts, compilers, resolved_inputs = {}, {}, {}, {}, {}, {}
  local tools, tool_files, tool_roots, tool_root_seen, writable_inputs = {}, {}, {}, {}, {}
  local explicit_inputs, resource_dirs, tool_input_trees, selected_toolchain = {}, {}, {}, nil
  local header_directories, compiler_config_dirs = {}, {}
  local compiler_resource_seen = {}
  local windows = uv.os_uname().sysname:match("Windows") ~= nil
  local function key(path) return windows and path:lower() or path end
  local function beneath(path, parent)
    path, parent = key(path), key(parent)
    return path == parent or path:sub(1, #parent + 1) == parent .. "/"
  end
  local function writable(path, base)
    path = absolute(path, base)
    writable_inputs[#writable_inputs + 1] = path
    local physical = uv.fs_realpath(path)
    if physical then writable_inputs[#writable_inputs + 1] = absolute(physical) end
  end
  local function tool_file(path)
    path = absolute(path)
    if tool_files[key(path)] then return end
    local identity = tool_identity(path)
    tool_files[key(path)] = true
    tools[#tools + 1] = { path = path, identity = identity }
  end
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
    -- Many commands repeat the same include/toolchain paths. This inventory
    -- only grows coverage; resolving each identical operand once preserves it.
    local operand = tostring(base or "") .. "\0" .. tostring(path)
    if resolved_inputs[operand] then return resolved_inputs[operand] end
    path = absolute(path, base)
    explicit_inputs[key(path)] = path
    if not covered(path) then root(path) end
    -- Resolve even paths covered by a lexical root: junctions may point out.
    if not seen[key(path)] then
      seen[key(path)] = true
      local physical = uv.fs_realpath(path)
      if physical and not covered(absolute(physical)) then root(physical) end
    end
    resolved_inputs[operand] = path
    return path
  end
  local function tool_root(path, base, resource, input_tree)
    path = input(path, base)
    local stat = uv.fs_stat(path)
    if not stat or stat.type ~= "directory" then error("tool directory unavailable: " .. path) end
    for _, directory in ipairs({ path, absolute(assert(uv.fs_realpath(path))) }) do
      if not tool_root_seen[key(directory)] then
        tool_root_seen[key(directory)] = true
        tool_roots[#tool_roots + 1] = directory
      end
    end
    tool_file(path)
    if resource then resource_dirs[key(path)] = path end
    if resource or input_tree then
      local tree = resource and path .. "/include" or path
      tool_input_trees[#tool_input_trees + 1] = tree
      local physical = uv.fs_realpath(tree)
      if physical then tool_input_trees[#tool_input_trees + 1] = absolute(physical) end
    end
  end
  local function header_input(path, base)
    path = input(path, base)
    header_directories[key(path)] = path
  end
  local function readonly_tool(path)
    local candidate = false
    for _, directory in ipairs(tool_roots) do
      if beneath(path, directory) then candidate = true; break end
    end
    if not candidate then return false end
    for _, directory in ipairs(writable_inputs) do
      if beneath(path, directory) or beneath(directory, path) then return false end
    end
    return true
  end
  local function tool_input(path)
    if not readonly_tool(path) then return false end
    for _, tree in ipairs(tool_input_trees) do if beneath(path, tree) then return true end end
    return false
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
    writable(path)
    input(path)
  end
  local function compiler_resources(path)
    if compiler_resource_seen[key(path)] then return end
    compiler_resource_seen[key(path)] = true
    -- argv drivers can differ from the selected LLVM. Conservatively bind all
    -- installed resource versions beside both the lexical and physical driver;
    -- directory identities also revoke reuse when a new version is installed.
    local found, searched = false, {}
    for _, binary in ipairs({ path, absolute(assert(uv.fs_realpath(path))) }) do
      local directory = vim.fs.dirname(vim.fs.dirname(binary))
      for _, base in ipairs({ "lib/clang", "lib64/clang" }) do
        local resource_base = absolute(directory .. "/" .. base)
        if not searched[key(resource_base)] then
          searched[key(resource_base)] = true
          local stat = uv.fs_stat(resource_base)
          if stat and stat.type == "directory" then
            tool_root(resource_base)
            local function resource(candidate)
              local include = uv.fs_stat(candidate .. "/include")
              if include and include.type == "directory" then
                tool_root(candidate, nil, true)
                found = true
              end
            end
            resource(resource_base)
            local scanner = assert(uv.fs_scandir(resource_base), "compiler resource scan unavailable: " .. resource_base)
            while true do
              local name = uv.fs_scandir_next(scanner)
              if not name then break end
              resource(resource_base .. "/" .. name)
            end
          end
        end
      end
    end
    if found then return end
    -- Nonstandard layouts must be proved by the actual driver. This executes
    -- once per driver in the inventory worker, never on the cache-hit/UI path.
    local ok, result = pcall(function()
      return vim.system({ path, "-print-resource-dir" }, { text = true, timeout = 3000 }):wait()
    end)
    local resource = ok and result.code == 0 and vim.trim(result.stdout or "") or ""
    if resource == "" or resource:find("[\r\n]") then
      error("compiler resource directory unavailable: " .. path)
    end
    tool_root(resource, nil, true)
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
    tool_file(path)
    -- bin's parent covers lib/clang resources and adjacent toolchain files.
    local directory = vim.fs.dirname(path)
    if not executable_only then
      compiler_config_dirs[key(directory)] = true
      compiler_config_dirs[key(absolute(assert(uv.fs_realpath(directory))))] = true
    end
    -- Python installations often place python.exe directly in their root;
    -- watching its grandparent would accidentally subscribe to a whole drive.
    tool_root(executable_only and vim.fs.basename(directory):lower() ~= "bin"
      and directory or vim.fs.dirname(directory))
    if not executable_only then compiler_resources(path) end
  end
  writable(assert(ctx.engine_root, "engine root unavailable"))
  root(assert(ctx.engine_root, "engine root unavailable"))
  if ctx.project_root then writable(ctx.project_root); root(ctx.project_root) end
  local config_root = request.config_root or vim.fn.stdpath("config")
  for _, directory in ipairs({ "lua", "tools", "scripts" }) do
    writable(directory, config_root)
    root(absolute(directory, config_root))
  end
  if request.tools_dir then writable(request.tools_dir); root(request.tools_dir) end
  for _, executable in pairs(request.tools_executables or {}) do
    if type(executable) ~= "string" or executable == "" then error("tool executable unavailable") end
    compiler(executable, nil, true)
  end
  if request.clangd_path then
    -- Reuse the sidecar's selected toolchain, only in this inventory worker.
    -- Loading libclang and discovering built-in resources never runs on the UI.
    local config = request.config_root or vim.fn.stdpath("config")
    package.path = config .. "/lua/?.lua;" .. config .. "/lua/?/init.lua;" .. package.path
    local libclang = require("utils.ue_goto.semantic_sidecar_libclang")
    local toolchain = libclang.discover_toolchain({ clangd_candidates = { request.clangd_path } })
    if not toolchain.ok then error(toolchain.reason) end
    input(toolchain.libclang_path)
    tool_file(toolchain.libclang_path)
    local clang
    for _, candidate in ipairs(libclang.sibling_clang_candidates(toolchain.clangd_path)) do
      clang = libclang.resolve_executable(candidate)
      if clang then break end
    end
    if not clang then error("selected clang unavailable") end
    compiler(clang)
    local resource_dir = assert(libclang.compiler_resource_dir(toolchain), "selected resource directory unavailable")
    tool_root(resource_dir, nil, true)
    selected_toolchain = { clangd = toolchain.clangd_path, clang = clang,
      libclang = toolchain.libclang_path, resource_dir = resource_dir }
  end
  for name, value in pairs(request.environment or {}) do
    if type(value) == "string" and value ~= "" then
      if name:match("INCLUDE") or name == "CPATH" or name == "SDKROOT" or name == "LIBRARY_PATH" then
        local separator = windows and ";" or ":"
        for path in value:gmatch("[^" .. separator .. "]+") do header_input(path, ctx.engine_root) end
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
    ["--gcc-toolchain"] = true, ["-gcc-toolchain"] = true,
    ["-resource-dir"] = true, ["-fmodule-map-file"] = true, ["-fmodule-file"] = true,
    ["-o"] = true, ["-MF"] = true, ["/I"] = true, ["/FI"] = true, ["/Fo"] = true,
  }
  local attached = { "--gcc-toolchain=", "-gcc-toolchain=", "--gcc-install-dir=",
    "--sysroot=", "-resource-dir=", "-fmodule-map-file=", "-fmodule-file=",
    "-ivfsoverlay=", "-isystem", "-iquote", "-idirafter", "-include-pch", "-include", "-imacros",
    "-I", "/external:I", "/FI", "/Fo", "/I" }
  local attached_prefixes = {}
  local header_options = { ["-I"] = true, ["-isystem"] = true, ["-iquote"] = true,
    ["-idirafter"] = true, ["/I"] = true, ["/external:I"] = true }
  local tool_options = { ["-resource-dir"] = true, ["-resource-dir="] = true,
    ["--gcc-toolchain"] = true, ["--gcc-toolchain="] = true,
    ["-gcc-toolchain"] = true, ["-gcc-toolchain="] = true,
    ["--gcc-install-dir="] = true, ["--sysroot"] = true,
    ["--sysroot="] = true, ["-isysroot"] = true }
  for _, entry in ipairs(entries) do
    if type(entry.arguments) ~= "table" or #entry.arguments == 0 then error("command-only CDB unsupported") end
    local cwd = absolute(entry.directory)
    writable(entry.file, cwd)
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
        elseif tool_options[token] then tool_root(entry.arguments[index], cwd, token == "-resource-dir", true)
        elseif header_options[token] then header_input(entry.arguments[index], cwd)
        else input(entry.arguments[index], cwd) end
      else
        local parsed = false
        local prefix = attached_prefixes[token]
        if prefix == nil then
          for _, candidate in ipairs(attached) do
            if token:sub(1, #candidate) == candidate and #token > #candidate then
              prefix = candidate
              break
            end
          end
          attached_prefixes[token] = prefix or false
        end
        if prefix then
          if prefix == "-ivfsoverlay=" then overlay(token:sub(#prefix + 1), cwd)
          elseif tool_options[prefix] then tool_root(token:sub(#prefix + 1), cwd, prefix == "-resource-dir=", true)
          elseif header_options[prefix] then header_input(token:sub(#prefix + 1), cwd)
          else input(token:sub(#prefix + 1), cwd) end
          parsed = true
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
        writable(group.unity)
        input(group.unity)
        for _, member in ipairs(group.members or {}) do writable(member); input(member) end
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
  -- Bind explicit operands/dependencies and their directory membership. The
  -- existing junction discovery below also binds designated input subtrees:
  -- an unknown implicit header dependency must not silently lose protection.
  local function bind_input(path)
    if not readonly_tool(path) then return end
    tool_file(path) -- unavailable explicit tool input must fail closed
    if header_directories[key(path)] and uv.fs_stat(path).type == "directory" then
      tool_input_trees[#tool_input_trees + 1] = path
      tool_input_trees[#tool_input_trees + 1] = absolute(assert(uv.fs_realpath(path)))
    end
    local parent = vim.fs.dirname(path)
    while parent and readonly_tool(parent) do
      tool_file(parent)
      local next_parent = vim.fs.dirname(parent)
      if next_parent == parent then break end
      parent = next_parent
    end
  end
  for _, path in pairs(explicit_inputs) do bind_input(path) end
  for _, directory in pairs(resource_dirs) do
    local include = directory .. "/include"
    input(include)
    bind_input(include)
    local scanner = assert(uv.fs_scandir(include), "resource headers unavailable: " .. include)
    while true do
      local name = uv.fs_scandir_next(scanner)
      if not name then break end
      -- This additional resource enumeration is one level only. The existing
      -- junction scan retains conservative protection for implicit headers.
      local path = input(include .. "/" .. name)
      bind_input(path)
    end
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
    if tool_input(directory) then tool_file(directory) end
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
        elseif kind == "file" then
          if compiler_config_dirs[key(directory)] and name:lower():match("%.cfg$") then
            -- Default configs can add @files and external input directories.
            -- Until those arguments are inventoried, no capsule is provable.
            error("compiler configuration inputs unavailable: " .. child)
          end
          if tool_input(child) then tool_file(child) end
        elseif kind == "link" or kind == "unknown" then
          local stat = uv.fs_stat(child)
          if not stat then error("unresolvable watch link: " .. child) end
          local target = uv.fs_realpath(child)
          if not target then error("unresolvable physical input: " .. child) end
          input(target)
          if tool_input(child) and stat.type == "file" then tool_file(child) end
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
  -- Owned products are stat-bound below, and their events have always been
  -- excluded from the input epoch. Keep their staging bursts out of the kernel
  -- queue too: direct parents observe replacement/new siblings; all other
  -- existing directories retain recursive observation. Root-level additions
  -- invalidate the capsule before any newly created subtree can be reused.
  local subscriptions = {}
  local owned_cache = absolute(ctx.engine_root) .. "/.cache/nvim-ue"
  local function subscribe(directory)
    if key(directory) == key(owned_cache) then return end
    if key(owned_cache):sub(1, #directory + 1) ~= key(directory) .. "/" then
      subscriptions[#subscriptions + 1] = { path = directory, recursive = true }
      return
    end
    subscriptions[#subscriptions + 1] = { path = directory, recursive = false }
    local scanner = assert(uv.fs_scandir(directory), "unreadable watch parent: " .. directory)
    while true do
      local name, kind = uv.fs_scandir_next(scanner)
      if not name then break end
      if name ~= ".git" then
        local child = directory .. "/" .. name
        if kind == "link" or kind == "unknown" then
          local stat = assert(uv.fs_stat(child), "unresolvable watch child: " .. child)
          kind = stat.type
        end
        if kind == "directory" then subscribe(child) end
      end
    end
  end
  for _, item in ipairs(roots) do
    if key(item.path) == key(absolute(ctx.engine_root)) then subscribe(item.path)
    else subscriptions[#subscriptions + 1] = item end
  end
  roots = subscriptions
  local classified_tool_roots = {}
  for _, item in ipairs(roots) do
    if readonly_tool(item.path) then
      item.tool_root = true
      tool_file(item.path)
      classified_tool_roots[#classified_tool_roots + 1] = item.path
    end
  end
  table.sort(roots, function(a, b) return a.path < b.path end)
  table.sort(artifacts, function(a, b) return a.path < b.path end)
  table.sort(tools, function(a, b) return a.path < b.path end)
  table.sort(classified_tool_roots)
  if #roots > (request.max_roots or 32) then error("watch root budget exceeded") end
  return { ok = true, roots = roots, products = products, artifacts = artifacts,
    tools = tools, tool_roots = classified_tool_roots, toolchain = selected_toolchain,
    executables = request.tools_executables, tool_input_trees = tool_input_trees,
    entries = #entries, directories_scanned = directory_count,
    coverage = "explicit argv/origin/VFS inputs and recursively discovered junction targets" }
end

function M.collect(request)
  local ok, result = pcall(collect, request)
  if ok then return result end
  return { ok = false, reason = tostring(result) }
end

function M.verify_tools(tools)
  if type(tools) ~= "table" or #tools == 0 then return { ok = false, reason = "tool-identities-unavailable" } end
  local files, directories = 0, 0
  for _, item in ipairs(tools) do
    if type(item) ~= "table" or type(item.path) ~= "string" or type(item.identity) ~= "table" then
      return { ok = false, reason = "tool-identity-invalid" }
    end
    local ok, identity = pcall(tool_identity, item.path)
    if not ok or not vim.deep_equal(identity, item.identity) then
      return { ok = false, reason = "tool-changed:" .. item.path }
    end
    if identity.type == "file" then files = files + 1 else directories = directories + 1 end
  end
  return { ok = true, tools_verified = #tools, files_verified = files, directories_verified = directories }
end

-- A bounded libuv metadata proof avoids spawning another editor on every hit.
-- Both queries run in libuv's worker pool; no filesystem IO blocks the UI.
function M.verify_tools_async(tools, done)
  local cursor, verified, files, directories, finished = 0, 0, 0, 0, false
  local function finish(value)
    if finished then return end
    finished = true
    vim.schedule(function() done(value) end)
  end
  if type(tools) ~= "table" or #tools == 0 then
    finish({ ok = false, reason = "tool-identities-unavailable" }); return
  end
  local function next_tool()
    if finished then return end
    cursor = cursor + 1
    local item = tools[cursor]
    if not item then return end
    if type(item) ~= "table" or type(item.path) ~= "string" or type(item.identity) ~= "table" then
      finish({ ok = false, reason = "tool-identity-invalid" }); return
    end
    local function changed() finish({ ok = false, reason = "tool-changed:" .. item.path }) end
    local queued, handle = pcall(uv.fs_stat, item.path, function(err, stat)
      if finished then return end
      if err or not stat then changed(); return end
      local resolved, request = pcall(uv.fs_realpath, item.path, function(resolve_err, physical)
        if finished then return end
        if resolve_err or not physical then changed(); return end
        local ok, observed = pcall(tool_identity_value, item.path, stat, physical)
        if not ok or not vim.deep_equal(observed, item.identity) then changed(); return end
        verified = verified + 1
        if observed.type == "file" then files = files + 1 else directories = directories + 1 end
        if verified == #tools then
          finish({ ok = true, tools_verified = verified, files_verified = files, directories_verified = directories })
        else next_tool() end
      end)
      if not resolved or not request then changed() end
    end)
    if not queued or not handle then changed() end
  end
  for _ = 1, math.min(8, #tools) do next_tool() end
end

-- -l scripts receive request.json in arg[1]; require() has no script argument.
if arg and arg[0] and arg[0]:gsub("\\", "/"):match("/prepare_inputs%.lua$") then
  local ok, request = pcall(json, arg[1])
  local result = ok and (request.verify_tools and M.verify_tools(request.verify_tools) or M.collect(request))
    or { ok = false, reason = tostring(request) }
  io.stdout:write(vim.json.encode(result))
end

return M
