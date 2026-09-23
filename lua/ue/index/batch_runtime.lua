-- Startup-only activation of verified frozen batches; original UBT is default.
local M = {}
local uv = vim.uv or vim.loop
local platform = require("utils.platform")
local fs = require("ue.core.fs")
local records, verified_dirs = {}, {}
local recursive_capability, probe_waiters
local direct_capability, direct_waiters
local recursive_backend, direct_backend

local function key(path)
  return platform.driver().path_key(vim.fs.normalize(path))
end

local function fingerprint(path)
  local stat = uv.fs_stat(path)
  if not stat or stat.type ~= "file" then return nil end
  return table.concat({ stat.size, stat.mtime.sec, stat.mtime.nsec, stat.ctime.sec, stat.ctime.nsec }, ":")
end

local function cdb_argument(cmd)
  for position = #cmd, 1, -1 do
    local directory = cmd[position]:match("^%-%-compile%-commands%-dir=(.+)$")
    if directory then return position, key(directory) end
  end
end

local function launch_cwd(config)
  local cwd = config and config.cmd_cwd or uv.cwd()
  if type(cwd) ~= "string" or not fs.is_absolute_path(cwd) then return nil, "invalid-clangd-launch-cwd" end
  local resolved = uv.fs_realpath(cwd)
  if not resolved then return nil, "invalid-clangd-launch-cwd" end
  local lexical = cwd:gsub("\\", "/")
  if (lexical .. "/"):find("/../", 1, true) or (lexical .. "/"):find("/./", 1, true)
      or key(cwd) ~= key(resolved) then
    return nil, "unsupported-clangd-launch-cwd-alias"
  end
  return (vim.fs.normalize(resolved):gsub("\\", "/"))
end

-- Only these non-semantic server options may differ from the proof runner.
-- Unknown options remain on original UBT, rather than silently broadening a
-- certificate when clangd grows a new parsing/indexing option.
local profile_options = {
  ["background-index"] = { bare = true, ["false"] = true },
  ["background-index-priority"] = { background = true },
  ["completion-style"] = { detailed = true },
  ["completion-parse"] = { auto = true },
  ["header-insertion"] = { never = true },
  ["pch-storage"] = { memory = true },
  ["clang-tidy"] = { ["false"] = true },
  ["enable-config"] = { ["false"] = true },
  ["function-arg-placeholders"] = { ["true"] = true },
  ["limit-results"] = { ["200"] = true }, ["limit-references"] = { ["200"] = true },
  ["j"] = { number = true },
  ["log"] = { error = true, info = true, verbose = true },
}

function M.server_profile(command, config)
  if config and config.cmd_env ~= nil then
    if type(config.cmd_env) ~= "table" then return nil, "unsupported-clangd-environment" end
    local names = {}
    for name, value in pairs(config.cmd_env) do
      if type(name) ~= "string" or value == vim.NIL or (type(value) ~= "string" and type(value) ~= "number") then
        return nil, "unsupported-clangd-environment"
      end
      local normalized = platform.driver().environment_key(name)
      if names[normalized] then return nil, "ambiguous-clangd-environment-key" end
      names[normalized] = true
    end
  end
  if type(command) ~= "table" or not vim.islist(command) or #command == 0
      or type(command[1]) ~= "string" or command[1] == "" then
    return nil, "unsupported-clangd-command"
  end
  local query, query_seen, config_disabled, index = nil, false, false, 2
  while index <= #command do
    local argument = command[index]
    if type(argument) ~= "string" then return nil, "unsupported-clangd-command" end
    local name, value = argument:match("^%-%-?([%w%-]+)=(.*)$")
    if not name then name = argument:match("^%-%-?([%w%-]+)$") end
    if name == "query-driver" then
      if query_seen then return nil, "unsupported-clangd-query-driver-duplicate" end
      query_seen = true
      if value == nil then index = index + 1; value = command[index] end
      if type(value) ~= "string" or value:match("^%-") then return nil, "invalid-clangd-query-driver" end
      if value ~= "" then query = value end
    elseif name == "compile-commands-dir" then
      if not value or value == "" then return nil, "unsupported-clangd-compile-commands-dir" end
    else
      local allowed = name and profile_options[name]
      if not allowed then return nil, "unsupported-clangd-option:" .. argument end
      if value == nil and not allowed.bare then index = index + 1; value = command[index] end
      if value == nil then
        if not allowed.bare then return nil, "unsupported-clangd-option:" .. argument end
      elseif not allowed[value] and not (allowed.number and type(value) == "string" and value:match("^%d+$")) then
        return nil, "unsupported-clangd-option:" .. argument
      end
      if name == "enable-config" then config_disabled = value == "false" end
    end
    index = index + 1
  end
  if not query then return nil end
  if not config_disabled then return nil, "uncertified-clangd-query-driver" end
  local cwd, reason = launch_cwd(config)
  if not cwd then return nil, reason end
  return { query_driver = query, launch_cwd = cwd, enable_config = false }
end

function M.uncertified_profile(command, config)
  local profile, reason = M.server_profile(command, config)
  return reason or (profile and "uncertified-clangd-query-driver" or nil)
end

local function profile_value(value)
  return value ~= vim.NIL and value or nil
end

local function environment_value(value)
  return value ~= nil and value ~= vim.NIL and tostring(value) or nil
end

local function environment_key(name)
  return platform.driver().environment_key(name)
end

local function effective_environment(config)
  local result = {}
  for name, value in pairs(vim.fn.environ()) do result[environment_key(name)] = value end
  for name, value in pairs(config and config.cmd_env or {}) do
    result[environment_key(name)] = environment_value(value)
  end
  return result
end

M.process_environment = effective_environment

local function spawn_overrides(config)
  local effective, inherited, overrides = effective_environment(config), {}, {}
  for name in pairs(vim.fn.environ()) do inherited[environment_key(name)] = name end
  for name in pairs(config.cmd_env or {}) do
    local normalized = environment_key(name)
    overrides[inherited[normalized] or normalized] = effective[normalized]
  end
  return overrides
end

local function environment_matches(expected, actual)
  for name, value in pairs(expected) do
    if environment_value(value) ~= actual[environment_key(name)] then return false end
  end
  return true
end

local function ready(record)
  return record and not record.failed and record.guard and record.guard:status().state == "ready"
end

local function request_reason(record, command, config)
  local profile, reason = M.server_profile(command, config)
  if reason then return reason end
  local cwd, cwd_reason = launch_cwd(config)
  if not cwd then return cwd_reason end
  if not vim.deep_equal(profile, record.server_profile) then return "uncertified-clangd-server-profile" end
  if cwd ~= record.launch_cwd then return "clangd-launch-cwd-changed" end
  if command[1] ~= record.command_executable then return "clangd-executable-changed" end
  if record.compiler_environment and not environment_matches(record.compiler_environment, effective_environment(config)) then
    return "compiler-environment-changed"
  end
end

local function scoped_restart(clients)
  if #clients == 0 then return end
  require("ue.index").maybe_restart_clangd_for_index({
    invalidated_frozen_batch = true,
    get_clients = function() return clients end,
    list_bufs = function() return {} end,
  })
end

local function run_cli(info, clangd, mode, callback, request)
  local python = platform.resolve_tool({ name = "python", env = { "UE_PYTHON" },
    driver_candidates = function(driver) return driver.python_candidates() end })
  if not python.ok then vim.schedule(function() callback({ ok = false, reason = "python-unavailable" }) end); return end
  local command = { python.path, "-B", "-I", vim.fn.stdpath("config") .. "/tools/clangd_batch_activation.py",
    "--info", info, "--clangd", clangd, "--" .. mode }
  if request.server_profile then
    vim.list_extend(command, { "--server-profile", vim.json.encode(request.server_profile) })
  end
  -- Foreground startup proof: one bounded asynchronous child, never UI hashing.
  local handle = vim.system(command, { text = true, timeout = 180000,
    env = request.environment, clear_env = true, cwd = request.launch_cwd }, function(result)
    vim.schedule(function()
      local ok, decoded = pcall(vim.json.decode, result.stdout or "")
      if not ok or type(decoded) ~= "table" then decoded = { ok = false, reason = "activation-helper-failed" } end
      if result.code ~= 0 then
        decoded.ok = false
        decoded.reason = decoded.reason or "activation-helper-failed"
      end
      callback(decoded)
    end)
  end)
  pcall(require("utils.task_registry").register, { name = "Verify frozen index", group = "index", kind = "system", handle = handle })
  return function() pcall(handle.kill, handle, 15) end
end

local function native_watch(root, callback, options)
  local handle = uv.new_fs_event()
  if not handle then return nil end
  local ok, started = pcall(handle.start, handle, root, { recursive = options.recursive }, callback)
  if not ok or not started then handle:close(); return nil end
  return handle, { recursive = options.recursive == true, direct = options.recursive == false }
end

local function watch_backend(roots)
  local factory = platform.driver().input_event_watcher
  if not factory then return native_watch end
  local session, reason = factory(roots)
  if not session then return nil, nil, reason end
  return function(root, callback, options) return session:watch(root, callback, options) end,
    function() session:close() end
end

-- libuv can accept recursive=true on hosts that do not implement recursion.
-- Prove an actual nested event once, using only a small owned temporary tree.
local function probe_recursive(callback)
  local backend = platform.driver().input_event_watcher or native_watch
  if recursive_backend ~= backend then
    if probe_waiters then callback(false); return end
    recursive_backend, recursive_capability = backend, nil
  end
  if recursive_capability ~= nil then callback(recursive_capability); return end
  if probe_waiters then probe_waiters[#probe_waiters + 1] = callback; return end
  probe_waiters = { callback }
  local root = vim.fn.tempname() .. "_frozen_watch_probe"
  local nested, file = root .. "/nested", root .. "/nested/probe"
  local watch, timer, close_watches
  local finished = false
  local function finish(capable)
    if finished then return end
    finished = true
    vim.schedule(function()
      if watch then pcall(watch.stop, watch); pcall(watch.close, watch) end
      if close_watches then pcall(close_watches) end
      if timer then pcall(timer.stop, timer); pcall(timer.close, timer) end
      pcall(uv.fs_unlink, file)
      pcall(uv.fs_rmdir, nested)
      pcall(uv.fs_rmdir, root)
      recursive_capability = capable
      local waiting = probe_waiters or {}
      probe_waiters = nil
      for _, consumer in ipairs(waiting) do consumer(capable) end
    end)
  end
  local ok = pcall(function()
    vim.fn.mkdir(nested, "p")
    local factory
    factory, close_watches = watch_backend({ { path = root, recursive = true } })
    assert(factory)
    timer = assert(uv.new_timer())
    timer:start(10000, 0, function() finish(false) end)
    local function ready(capable)
      if not capable then finish(false); return end
      vim.schedule(function() if not finished then vim.fn.writefile({ "probe" }, file) end end)
    end
    local capability
    watch, capability = factory(root, function(err, filename)
      if err then finish(false)
      elseif filename and filename:gsub("\\", "/") == "nested/probe" then finish(true) end
    end, { recursive = true, on_ready = ready })
    if not watch or not capability or not capability.recursive then finish(false); return end
    if capability.pending ~= true then ready(true) end
  end)
  if not ok then finish(false) end
end

local function probe_direct(callback)
  local backend = platform.driver().input_event_watcher or native_watch
  if direct_backend ~= backend then
    if direct_waiters then callback(false); return end
    direct_backend, direct_capability = backend, nil
  end
  if direct_capability ~= nil then callback(direct_capability); return end
  if direct_waiters then direct_waiters[#direct_waiters + 1] = callback; return end
  direct_waiters = { callback }
  local root = vim.fn.tempname() .. "_frozen_direct_probe"
  local watch, timer, expected, advance, close_watches
  local finished, step = false, 0
  local function finish(capable)
    if finished then return end
    finished = true
    vim.schedule(function()
      if watch then pcall(watch.stop, watch); pcall(watch.close, watch) end
      if close_watches then pcall(close_watches) end
      if timer then pcall(timer.stop, timer); pcall(timer.close, timer) end
      pcall(uv.fs_unlink, root .. "/link")
      pcall(uv.fs_unlink, root .. "/candidate")
      for _, name in ipairs({ "lookup", "renamed", "missing", "target-a", "target-b" }) do
        pcall(uv.fs_rmdir, root .. "/" .. name)
      end
      pcall(uv.fs_rmdir, root)
      direct_capability = capable
      local waiting = direct_waiters or {}
      direct_waiters = nil
      for _, consumer in ipairs(waiting) do consumer(capable) end
    end)
  end
  local actions = {
    function() expected = "candidate"; vim.fn.writefile({ "probe" }, root .. "/candidate") end,
    function() expected = "lookup"; assert(uv.fs_rename(root .. "/lookup", root .. "/renamed")) end,
    function() expected = "missing"; assert(uv.fs_mkdir(root .. "/missing", 448)) end,
    function()
      expected = "link"
      assert(uv.fs_unlink(root .. "/link"))
      assert(uv.fs_symlink(root .. "/target-b", root .. "/link", platform.driver().directory_symlink_options()))
    end,
  }
  advance = function()
    if finished then return end
    step = step + 1
    if not actions[step] then finish(true); return end
    if not pcall(actions[step]) then finish(false) end
  end
  local ok = pcall(function()
    for _, name in ipairs({ "lookup", "target-a", "target-b" }) do vim.fn.mkdir(root .. "/" .. name, "p") end
    assert(uv.fs_symlink(root .. "/target-a", root .. "/link", platform.driver().directory_symlink_options()))
    local factory
    factory, close_watches = watch_backend({ { path = root, recursive = false } })
    assert(factory)
    timer = assert(uv.new_timer())
    timer:start(10000, 0, function() finish(false) end)
    local function ready(capable)
      if not capable then finish(false); return end
      vim.schedule(advance)
    end
    local capability
    watch, capability = factory(root, function(err, filename)
      if err then finish(false)
      elseif expected and filename == expected then expected = nil; vim.schedule(advance) end
    end, { recursive = false, on_ready = ready })
    if not watch or not capability or not capability.direct then finish(false); return end
    if capability.pending ~= true then ready(true) end
  end)
  if not ok then finish(false) end
end

local function flush(record)
  local waiters = record.waiters
  record.waiters = {}
  for _, waiter in ipairs(waiters) do pcall(waiter) end
end

local function fallback(record, reason)
  record.failed, record.reason = true, reason
  for _, id in ipairs(record.autocmds or {}) do pcall(vim.api.nvim_del_autocmd, id) end
  record.autocmds = {}
  flush(record)
  local clients = {}
  for _, client in pairs(record.clients) do clients[#clients + 1] = client end
  (record.opts.restart or scoped_restart)(clients, record.ctx)
  record.clients = {}
end

local function filtered_watch(record, descriptor, backend)
  local watched, excludes, inputs = {}, {}, {}
  for _, path in ipairs(descriptor.watched_files or {}) do watched[key(path)] = true end
  for _, path in ipairs(descriptor.exclude_roots or {}) do excludes[#excludes + 1] = key(path) end
  for _, path in ipairs(descriptor.input_roots or {}) do inputs[#inputs + 1] = key(path) end
  local factory = backend or record.opts.watch_factory or native_watch
  return function(root, callback, options)
    return factory(root, function(err, filename, events)
      if err or not filename then callback(err or "watch-event-without-path"); return end
      local path = key(fs.is_absolute_path(filename) and filename or vim.fs.joinpath(root, filename))
      if watched[path] then callback(nil, filename, events); return end
      for _, excluded in ipairs(excludes) do
        if fs.path_has_prefix(path, excluded) then return end
      end
      for _, input in ipairs(inputs) do
        -- A coalesced ancestor event can represent a rename/delete of the
        -- entire input subtree even when no individual dependency is reported.
        if fs.path_has_prefix(path, input) or fs.path_has_prefix(input, path) then
          callback(nil, filename, events)
          return
        end
      end
    end, options)
  end
end

local function path_list(value, required)
  if value == nil then return not required end
  if type(value) ~= "table" or not vim.islist(value) or (required and #value == 0) then return false end
  for _, path in ipairs(value) do
    if type(path) ~= "string" or not (path:match("^%a:[/\\]$") or fs.is_absolute_path(path)) then return false end
  end
  return true
end

local function watch_sets(descriptor)
  local result = {}
  for _, field in ipairs({ "watch_roots", "lookup_roots", "watched_files", "input_roots", "exclude_roots" }) do
    if not path_list(descriptor[field], field == "watch_roots" or field == "watched_files" or field == "input_roots") then
      return nil
    end
    result[field] = {}
    for _, path in ipairs(descriptor[field] or {}) do result[field][key(path)] = true end
  end
  return result
end

--- Resolve metadata asynchronously before root_dir starts any new clangd.
--- All large reads/hashes remain in the child. Failure is sticky for the small
--- metadata signature, until new publication metadata or a new editor session.
function M.prepare(bufnr, root, on_dir, opts)
  opts = opts or {}
  local get_command = opts.get_command or function(directory) return require("ue").clangd_cmd(directory) end
  local get_config = opts.get_config or function() return opts.config or {} end
  local command, config = get_command(root), get_config()
  local profile, profile_reason = M.server_profile(command, config)
  if profile_reason then on_dir(root); return nil, profile_reason end
  local cwd, cwd_reason = launch_cwd(config)
  if not cwd then on_dir(root); return nil, cwd_reason end
  local environment = effective_environment(config)
  local resolve = opts.resolve_context or function(buffer)
    return require("ue").resolve_context({ bufname = vim.api.nvim_buf_get_name(buffer) })
  end
  local ctx = resolve(bufnr)
  local original = ctx and ctx.paths and ctx.paths.semantic_cdb
  if not original then on_dir(root); return end
  local info = vim.fs.joinpath(vim.fs.dirname(original), "batches.json")
  local stamp = (opts.fingerprint or fingerprint)(info)
  local scope = key(original)
  local previous = records[scope]
  local get_generation = opts.get_generation or function(context)
    return require("ue.index").generation_for_context(context).generation_id
  end
  local generation = stamp and get_generation(ctx) or nil
  if previous and previous.stamp == stamp then
    if previous.generation ~= generation then
      if previous.guard then previous.guard:invalidate("activation-generation-changed")
      else fallback(previous, "activation-generation-changed") end
      on_dir(root)
      return
    end
    local reason = request_reason(previous, command, config)
    if reason then on_dir(root); return nil, reason end
    if previous.failed or ready(previous) then on_dir(root)
    else previous.waiters[#previous.waiters + 1] = function() on_dir(root) end end
    return
  end
  if previous and previous.guard then previous.guard:invalidate("activation-metadata-changed") end
  if previous and previous.cancel_describe then pcall(previous.cancel_describe) end
  if not stamp then records[scope] = nil; on_dir(root); return end
  local record = { ctx = ctx, opts = opts, stamp = stamp, scope = scope, info = info,
    original = original, clients = {}, autocmds = {}, phase = "describing", generation = generation,
    server_profile = vim.deepcopy(profile), launch_cwd = cwd, environment = environment,
    command_executable = command[1], get_config = get_config,
    waiters = { function() on_dir(root) end } }
  records[scope] = record
  local run = opts.run_async or run_cli
  local clangd = opts.clangd or command[1]
  local request = { server_profile = vim.deepcopy(profile), launch_cwd = cwd, environment = vim.deepcopy(environment) }
  local function current()
    return records[scope] == record and not record.failed and (opts.fingerprint or fingerprint)(info) == stamp
      and generation ~= nil and generation ~= "" and get_generation(ctx) == generation
      and not request_reason(record, get_command(root), get_config())
      and vim.deep_equal(environment, effective_environment(get_config()))
  end
  local function reject(reason)
    fallback(record, reason or "activation-unavailable")
  end
  local function described(descriptor)
    if record.phase ~= "describing" then return end
    record.phase = "probing"
    if not current() then reject("activation-metadata-changed"); return end
    if type(descriptor) ~= "table" or descriptor.ok ~= true
        or not path_list(descriptor.watch_roots, true) or #descriptor.watch_roots > 32
        or not path_list(descriptor.lookup_roots, false) or (descriptor.lookup_roots and #descriptor.lookup_roots > 256)
        or not path_list(descriptor.exclude_roots, false) or not path_list(descriptor.watched_files, true)
        or not path_list(descriptor.input_roots, true)
        or type(descriptor.verified_cdb) ~= "string" or type(descriptor.original_cdb) ~= "string"
        or type(descriptor.info_sha256) ~= "string" or descriptor.info_sha256 == ""
        or type(descriptor.compiler_environment) ~= "table"
        or type(descriptor.tool_path) ~= "string" or not fs.is_absolute_path(descriptor.tool_path)
        or descriptor.generation_id ~= generation
        or key(descriptor.original_cdb) ~= scope then
      reject("invalid-activation-descriptor"); return
    end
    if not vim.deep_equal(profile_value(descriptor.server_profile), profile) then
      reject("uncertified-clangd-server-profile"); return
    end
    if not environment_matches(descriptor.compiler_environment, environment) then
      reject("compiler-environment-changed"); return
    end
    record.verified = descriptor.verified_cdb
    record.info_sha256 = descriptor.info_sha256
    record.compiler_environment = descriptor.compiler_environment
    record.tool_path = descriptor.tool_path
    local installed_sets = watch_sets(descriptor)
    local function begin_watching()
      if record.phase ~= "probing" then return end
      record.phase = "validating"
      if not current() then reject("activation-metadata-changed"); return end
      local roots = vim.deepcopy(descriptor.watch_roots)
      for _, path in ipairs(descriptor.lookup_roots or {}) do roots[#roots + 1] = { path = path, recursive = false } end
      record.guard = require("ue.index.batch_guard").start(ctx, nil, {
        receipts = descriptor.receipts or { info }, roots = roots,
        schedule = opts.schedule,
        watch_factory = opts.watch_factory and filtered_watch(record, descriptor) or nil,
        watch_backend = not opts.watch_factory and function(required)
          local factory, close = watch_backend(required)
          return factory and filtered_watch(record, descriptor, factory) or nil, close
        end or nil,
        verify_async = function(_, callback)
          return run(info, clangd, "validate", function(result)
            if not current() or type(result) ~= "table" or result.info_sha256 ~= record.info_sha256
                or result.generation_id ~= generation then
              callback({ ok = false, reason = "activation-metadata-changed" })
            elseif result.tool_path ~= record.tool_path then
              callback({ ok = false, reason = "clangd-executable-changed" })
            elseif not vim.deep_equal(result.compiler_environment, record.compiler_environment) then
              callback({ ok = false, reason = "compiler-environment-changed" })
            elseif not vim.deep_equal(profile_value(result.server_profile), record.server_profile) then
              callback({ ok = false, reason = "uncertified-clangd-server-profile" })
            elseif not vim.deep_equal(watch_sets(result), installed_sets) then
              callback({ ok = false, reason = "activation-watch-inputs-changed" })
            else callback(result) end
          end, request)
        end,
        on_ready = function()
          if not current() then record.guard:invalidate("activation-metadata-changed"); return end
          record.phase = "ready"
          verified_dirs[key(vim.fs.dirname(record.verified))] = record
          flush(record)
        end,
        on_invalidated = function(reason) fallback(record, reason) end,
      })
    end
    local probe = opts.probe_recursive or probe_recursive
    probe(function(capable)
      if record.phase ~= "probing" then return end
      if not current() or not capable then reject("recursive-watch-unavailable"); return end
      if #(descriptor.lookup_roots or {}) == 0 then begin_watching(); return end
      (opts.probe_direct or probe_direct)(function(direct)
        if record.phase ~= "probing" then return end
        if not direct then reject("direct-watch-unavailable"); return end
        begin_watching()
      end)
    end)
  end
  local ok, cancel = pcall(run, info, clangd, "describe", described, request)
  if not ok then reject("activation-helper-unavailable") end
  if type(cancel) == "function" then record.cancel_describe = cancel end
end

--- This is the sole thin call in ue.clangd_cmd; user directory overrides remain
--- intact because only the currently selected original CDB may be substituted.
function M.command(cmd, config)
  local _, reason = M.server_profile(cmd, config)
  if reason then return cmd end
  local position, directory = cdb_argument(cmd)
  if not position then return cmd end
  local record = records[key(vim.fs.joinpath(directory, "compile_commands.json"))]
  if not ready(record) then return cmd end
  if request_reason(record, cmd, config or record.get_config()) then return cmd end
  local result = vim.deepcopy(cmd)
  result[position] = "--compile-commands-dir=" .. vim.fs.dirname(record.verified)
  return result
end

--- Resolve only a directory backed by this session's verified activation, or
--- its already-owned frozen client while fallback retires that process.
function M.original_cdb_dir(verified_dir, client)
  local record = verified_dirs[key(verified_dir)]
  if not record then return nil end
  local config = client and client.config or {}
  local owned = record.guard and config._ue_batch_scope == record.scope
    and config._ue_batch_stamp == record.stamp
  if ready(record) or owned then return vim.fs.dirname(record.original) end
  return nil
end

function M.configure_process(cmd, config)
  config._ue_batch_spawn_env = nil
  if config._ue_batch_env_before then
    local owned = records[config._ue_batch_scope]
    if owned and config._ue_batch_stamp == owned.stamp and cmd[1] == owned.tool_path then
      cmd = vim.deepcopy(cmd)
      cmd[1] = owned.command_executable
    end
    local before = config._ue_batch_env_before
    local restored = vim.deepcopy(config.cmd_env or {})
    for name, installed in pairs(before.installed) do
      if restored[name] == installed then restored[name] = before.value and before.value[name] or nil end
    end
    config.cmd_env = next(restored) ~= nil and restored or (before.value ~= nil and {} or nil)
    config._ue_batch_env_before, config._ue_batch_scope, config._ue_batch_stamp = nil, nil, nil
    config._ue_batch_server_profile, config._ue_batch_launch_cwd = nil, nil
  end
  local profile, profile_reason = M.server_profile(cmd, config)
  config._ue_batch_disabled_reason = profile_reason
  local position, directory = cdb_argument(cmd)
  local record = directory and (verified_dirs[directory] or records[key(vim.fs.joinpath(directory, "compile_commands.json"))])
  if not record then return cmd end
  local reason = profile_reason or request_reason(record, cmd, config)
  if reason then
    -- Reject only this process profile; existing certified clients may remain
    -- valid. Keep every user flag and environment value, including query-driver.
    local original = vim.deepcopy(cmd)
    original[position] = "--compile-commands-dir=" .. vim.fs.dirname(record.original)
    config._ue_batch_disabled_reason = reason
    if reason == "compiler-environment-changed" and record.guard then record.guard:invalidate(reason) end
    return original
  end
  if not ready(record) then
    local original = vim.deepcopy(cmd)
    original[position] = "--compile-commands-dir=" .. vim.fs.dirname(record.original)
    return original
  end
  local cache = vim.fs.joinpath(record.ctx.paths.clangd_dir, "frozen-cache")
  vim.fn.mkdir(cache, "p")
  local installed = { LOCALAPPDATA = cache, XDG_CACHE_HOME = cache }
  for name, value in pairs(record.compiler_environment) do
    if environment_value(value) ~= nil then installed[name] = tostring(value) end
  end
  config._ue_batch_env_before = { value = vim.deepcopy(config.cmd_env), installed = installed }
  config.cmd_env = vim.tbl_extend("force", config.cmd_env or {}, installed)
  config._ue_batch_scope, config._ue_batch_stamp = record.scope, record.stamp
  config._ue_batch_server_profile = vim.deepcopy(profile)
  config._ue_batch_launch_cwd = record.launch_cwd
  config._ue_batch_spawn_env = spawn_overrides(config)
  local frozen = vim.deepcopy(cmd)
  frozen[1] = record.tool_path
  frozen[position] = "--compile-commands-dir=" .. vim.fs.dirname(record.verified)
  return frozen
end

function M.attach(client, bufnr)
  local config = client.config or {}
  if not config._ue_batch_scope then return end
  local record = records[config._ue_batch_scope]
  if not record or record.stamp ~= config._ue_batch_stamp or not record.guard then
    require("ue.index.batch_guard").start({}, client, { on_invalidated = function() scoped_restart({ client }) end })
    return
  end
  if not vim.deep_equal(config._ue_batch_server_profile, record.server_profile)
      or config._ue_batch_launch_cwd ~= record.launch_cwd then
    scoped_restart({ client })
    return
  end
  record.clients[client.id] = client
  record.guard:attach(client)
  if not ready(record) then (record.opts.restart or scoped_restart)({ client }, record.ctx); return end
  if not record.opts.no_buffer_watch and vim.api.nvim_buf_is_valid(bufnr) then
    if vim.bo[bufnr].modified then record.guard:invalidate("live-document-modified"); return end
    client._ue_batch_buffers = client._ue_batch_buffers or {}
    if not client._ue_batch_buffers[bufnr] then
      client._ue_batch_buffers[bufnr] = true
      local id = vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "BufWritePost" }, {
        buffer = bufnr, callback = function() record.guard:invalidate("live-document-changed") end,
      })
      record.autocmds[#record.autocmds + 1] = id
    end
  end
end

function M._reset_for_test()
  for _, record in pairs(records) do
    if record.guard then record.guard:stop() end
    for _, id in ipairs(record.autocmds or {}) do pcall(vim.api.nvim_del_autocmd, id) end
  end
  records, verified_dirs = {}, {}
end

return M
