local t = require("tests.harness")
t.bootstrap()
require("ue")
local index = require("ue.index")
local file_lock = require("ue.file_lock")
local leases = {}

local function write(path, value)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local file = assert(io.open(path, "wb"))
  file:write(value)
  file:close()
end

local function fixture()
  local root = vim.fn.tempname():gsub("\\", "/") .. "_async_subset"
  vim.fn.mkdir(root, "p")
  root = vim.fs.normalize(assert(vim.uv.fs_realpath(root)))
  local ctx = { engine_root = root, project_root = root, paths = {
    platform_key = "subset-test", active_cdb = root .. "/active.json",
    index_dir = root .. "/index", index_cdb_dir = root .. "/index",
    index_state = root .. "/index/modules.json", index_queue = root .. "/index/queue.json",
    index_current_cdb = root .. "/index/current.json", index_hot_cdb = root .. "/index/hot.json",
    current_index = root .. "/index/current.idx", hot_index = root .. "/index/hot.idx",
    semantic_cdb = root .. "/background/compile_commands.json",
    semantic_current_cdb = root .. "/background/current/compile_commands.json",
    semantic_hot_cdb = root .. "/background/hot/compile_commands.json",
  } }
  local entries, keys = {}, {}
  for _, name in ipairs({ "Alpha", "Beta", "Unselected" }) do
    local directory = root .. "/Engine/Source/Runtime/" .. name
    local source = directory .. "/" .. name .. ".cpp"
    write(source, "int " .. name .. "() { return 1; }\n")
    entries[#entries + 1] = { directory = directory, file = name .. ".cpp",
      arguments = { "clang++", "-DFIRST=1", "-DSECOND=2", "-c", name .. ".cpp" } }
    keys[name] = "module:" .. directory
  end
  write(ctx.paths.active_cdb, vim.json.encode(entries))
  return ctx, entries, { keys.Beta, keys.Alpha }
end

local function cleanup(ctx)
  if leases[ctx] then file_lock.release(leases[ctx]); leases[ctx] = nil end
  local key = ctx.engine_root .. "\31" .. ctx.project_root .. "\31" .. ctx.paths.platform_key
  index._rt.module_state[key], index._rt.contexts[key] = nil, nil
  vim.fn.delete(ctx.engine_root, "rf")
end

local function read(path)
  local file = assert(io.open(path, "rb"))
  local value = file:read("*a")
  file:close()
  return value
end

local function request(ctx, keys)
  local stat = assert(vim.uv.fs_stat(ctx.paths.active_cdb))
  leases[ctx] = leases[ctx] or assert(file_lock.acquire(ctx.paths.index_state .. ".build.lock"))
  return { schema = 1, phase = "current", ctx = ctx, selected_keys = keys,
    owner_pid = vim.fn.getpid(), build_lease = leases[ctx],
    input_signature = { size = stat.size, mtime = stat.mtime, ctime = stat.ctime } }
end

local function run_generator(ctx, payload)
  local path = ctx.engine_root .. "/request.json"
  write(path, vim.json.encode(payload))
  local python = vim.fn.exepath("python")
  if python == "" then python = vim.fn.exepath("python3") end
  assert(python ~= "", "Python is required by the controlled CDB generator")
  return vim.system({ python, "-I", vim.fn.stdpath("config") .. "/tools/build_clangd_index.py",
    ctx.paths.index_current_cdb, "--output", ctx.paths.current_index,
    "--background-output", ctx.paths.semantic_current_cdb,
    "--subset-request", path, "--nvim", vim.v.progpath }, { text = true }):wait(30000)
end

-- Each comparison starts with a fresh Unity lookup cache and the real scope
-- dependencies. The golden path deliberately omits the optional name filter.
local function subset_worker(unfiltered)
  local original_core
  for position = 1, 20 do
    local name, value = debug.getupvalue(index.setup, position)
    if name == "core" then original_core = value; break end
  end
  assert(original_core, "index setup core unavailable")
  local worker = setmetatable({}, { __index = index })
  local core = { h = {}, RT = index._rt, deps = original_core.deps }
  require("ue.index._state")(worker, core)
  if unfiltered then
    local classify = core.h.module_key_from_path
    core.h.module_key_from_path = function(ctx, path) return classify(ctx, path) end
  end
  require("ue.index._build")(worker, core)
  return worker, core.h
end

local function unity_entry(ctx, name, directory)
  directory = directory or (ctx.engine_root .. "/Engine/Intermediate/Build/Test/" .. name)
  local source = directory .. "/Module." .. name .. ".cpp"
  write(source, "// Classification fixture only.\n")
  return { directory = directory, file = source,
    arguments = { "clang++", "-DFIRST=1", "-DSECOND=2", "-c", source } }
end

local function classified_subset(ctx, entries, keys, unfiltered, phase)
  write(ctx.paths.active_cdb, vim.json.encode(entries))
  local worker = subset_worker(unfiltered)
  local globpath, calls = vim.fn.globpath, {}
  vim.fn.globpath = function(root, pattern, ...)
    calls[#calls + 1] = { root = root, pattern = pattern }
    return globpath(root, pattern, ...)
  end
  local ok, output, _, reason = pcall(worker.write_subset_compile_commands, ctx, phase or "hot", keys)
  vim.fn.globpath = globpath
  assert(ok, output)
  assert(output, reason)
  return vim.json.decode(read(output)), calls
end

local function lookup_count(calls, name)
  local count = 0
  for _, call in ipairs(calls) do
    if call.pattern:find(name, 1, true) then count = count + 1 end
  end
  return count
end

t.describe("index subset runs outside the editor thread", function()
  t.it("cold subsets skip only impossible ordinary Unity names and retain the original ordered output", function()
    local ctx, entries, keys = fixture()
    local ok, failure = pcall(function()
      entries[#entries + 1] = unity_entry(ctx, "Alpha")
      entries[#entries + 1] = unity_entry(ctx, "MissingOrdinary")
      local golden, previous = classified_subset(ctx, entries, keys, true)
      local actual, current = classified_subset(ctx, entries, keys, false)
      t.assert_true(vim.deep_equal(golden, { entries[2], entries[1], entries[4] }))
      t.assert_true(vim.deep_equal(actual, golden), "selection order and every argv must match the original path")
      t.assert_true(lookup_count(previous, "MissingOrdinary") > 0, "golden must exercise the cold lookup")
      t.assert_eq(lookup_count(current, "MissingOrdinary"), 0)
      t.assert_true(lookup_count(current, "Alpha") > 0, "selected Unity still uses original discovery")
    end)
    cleanup(ctx)
    if not ok then error(failure) end
  end)

  t.it("same-name plugin roots retain discovery precedence and direct scope wins before Unity filtering", function()
    local ctx, entries, keys = fixture()
    local ok, failure = pcall(function()
      local plugin = ctx.engine_root .. "/Engine/Plugins/Extras"
      local same_name = plugin .. "/Alpha/Source/Alpha"
      local only_plugin = ctx.engine_root .. "/Engine/Plugins/OnlyPlugin/Source/OnlyPlugin"
      vim.fn.mkdir(same_name, "p")
      vim.fn.mkdir(only_plugin, "p")
      entries[#entries + 1] = unity_entry(ctx, "Alpha")
      entries[#entries + 1] = unity_entry(ctx, "NotASelectedName", plugin .. "/Intermediate/Build/Test")
      entries[#entries + 1] = unity_entry(ctx, "OnlyPlugin")
      keys = { "plugin:" .. same_name, "plugin:" .. plugin, "plugin:" .. only_plugin, keys[1] }
      local golden = classified_subset(ctx, entries, keys, true)
      local actual, calls = classified_subset(ctx, entries, keys, false)
      t.assert_true(vim.deep_equal(golden, { entries[5], entries[6], entries[2] }),
        "Alpha must keep the engine-first lookup; the direct plugin scope must win despite the TU name")
      t.assert_true(vim.deep_equal(actual, golden))
      t.assert_true(lookup_count(calls, "Alpha") > 0)
      t.assert_eq(lookup_count(calls, "NotASelectedName"), 0)
      t.assert_true(lookup_count(calls, "OnlyPlugin") > 0)
    end)
    cleanup(ctx)
    if not ok then error(failure) end
  end)

  t.it("case differences are conservative and unusual Unity names or malformed selections retain fallback", function()
    local ctx, entries, keys = fixture()
    local ok, failure = pcall(function()
      entries[#entries + 1] = unity_entry(ctx, "ALPHA")
      entries[#entries + 1] = unity_entry(ctx, "Odd-Name")
      -- A legacy CDB spelling may contain glob syntax even though '*' cannot
      -- be a native Windows filename. Classification must keep its old meaning.
      local wildcard = vim.deepcopy(entries[4])
      wildcard.file = wildcard.file:gsub("Module%.ALPHA", "Module.Al*")
      wildcard.arguments[#wildcard.arguments] = wildcard.file
      entries[#entries + 1] = wildcard
      local golden = classified_subset(ctx, entries, keys, true)
      local actual, calls = classified_subset(ctx, entries, keys, false)
      t.assert_true(vim.deep_equal(actual, golden))
      t.assert_true(lookup_count(calls, "ALPHA") > 0, "case-only differences cannot justify skipping discovery")
      t.assert_true(lookup_count(calls, "Odd-Name") > 0, "non-identifiers must use the original fallback")
      t.assert_true(lookup_count(calls, "Al*") > 0, "glob names must retain their original matching behavior")
      entries[#entries + 1] = unity_entry(ctx, "OtherMissing")
      for _, unknown in ipairs({ "unparseable-selected-key", "module:" .. ctx.engine_root .. "/Odd-Name" }) do
        local selected = vim.list_extend(vim.deepcopy(keys), { unknown })
        golden = classified_subset(ctx, entries, selected, true)
        actual, calls = classified_subset(ctx, entries, selected, false)
        t.assert_true(vim.deep_equal(actual, golden))
        t.assert_true(lookup_count(calls, "OtherMissing") > 0, "an unknown key shape disables pruning")
      end
    end)
    cleanup(ctx)
    if not ok then error(failure) end
  end)

  t.it("full subsets and callers without a name filter retain all original classification behavior", function()
    local ctx, entries, keys = fixture()
    local ok, failure = pcall(function()
      ctx.paths.index_full_cdb = ctx.paths.index_cdb_dir .. "/full.json"
      entries[#entries + 1] = unity_entry(ctx, "MissingOrdinary")
      local golden = classified_subset(ctx, entries, keys, true, "full")
      local actual, calls = classified_subset(ctx, entries, keys, false, "full")
      t.assert_true(vim.deep_equal(golden, entries))
      t.assert_true(vim.deep_equal(actual, golden))
      t.assert_true(lookup_count(calls, "MissingOrdinary") > 0)
    end)
    cleanup(ctx)
    if not ok then error(failure) end
  end)

  t.it("current/hot hand off small requests without reading or decoding the active CDB", function()
    local ctx, _, keys = fixture()
    local saved = { open = io.open, system = vim.system, select = index.select_phase_module_keys,
      subset = index.write_subset_compile_commands, queued = index.try_start_queued_build,
      notify = vim.notify, job = index._rt.job }
    local ok, failure = pcall(function()
      index._rt.job = nil
      index.select_phase_module_keys = function() return keys end
      index.write_subset_compile_commands = function() error("subset work ran on the editor thread") end
      index.try_start_queued_build = function() end
      vim.notify = function() end
      io.open = function(path, ...)
        t.assert_true(vim.fs.normalize(path) ~= ctx.paths.active_cdb,
          "the editor must not open the large active CDB while dispatching")
        return saved.open(path, ...)
      end
      local pending, command
      vim.system = function(cmd, _, callback)
        command, pending = cmd, callback
        return {}
      end
      for _, phase in ipairs({ "current", "hot" }) do
        t.assert_true(index.build_phase_async(ctx, phase))
        t.assert_contains(command[2], "build_clangd_index.py")
        local function argument(flag)
          for position, value in ipairs(command) do
            if value == flag then return command[position + 1] end
          end
        end
        t.assert_true(argument("--nvim") ~= nil)
        local file = assert(saved.open(assert(argument("--subset-request")), "rb"))
        local raw = file:read("*a")
        file:close()
        t.assert_true(#raw < 16384, "only a small selection request crosses the editor boundary")
        local request = vim.json.decode(raw)
        t.assert_eq(request.phase, phase)
        t.assert_true(vim.deep_equal(request.selected_keys, keys))
        t.assert_eq(request.ctx.paths.active_cdb, ctx.paths.active_cdb)
        pending({ code = 1, stdout = "", stderr = "subset helper failed" })
        t.assert_true(vim.wait(1000, function() return index._rt.job == nil end, 10))
        t.assert_eq(index.ensure_index_state(ctx).build.status, "error")
        t.assert_nil(vim.uv.fs_stat(ctx.paths.semantic_cdb), "failed subset must not publish")
      end
    end)
    io.open, vim.system, vim.notify = saved.open, saved.system, saved.notify
    index.select_phase_module_keys, index.write_subset_compile_commands = saved.select, saved.subset
    index.try_start_queued_build, index._rt.job = saved.queued, saved.job
    cleanup(ctx)
    if not ok then error(failure) end
  end)

  t.it("the real worker retains selection order and exact argv without modifying active input", function()
    local ctx, entries, keys = fixture()
    local ok, failure = pcall(function()
      local original, stat = read(ctx.paths.active_cdb), vim.uv.fs_stat(ctx.paths.active_cdb)
      local payload = request(ctx, keys)
      local result = run_generator(ctx, payload)
      t.assert_eq(result.code, 0, result.stderr .. result.stdout)
      local subset = vim.json.decode(read(ctx.paths.index_current_cdb))
      t.assert_true(vim.deep_equal(subset, { entries[2], entries[1] }),
        "worker must use the existing classifier and preserve argv/order")
      local output_stat = vim.uv.fs_stat(ctx.paths.index_current_cdb)
      t.assert_eq(read(ctx.paths.active_cdb), original)
      t.assert_true(vim.deep_equal(vim.uv.fs_stat(ctx.paths.active_cdb).mtime, stat.mtime))
      t.assert_nil(vim.uv.fs_stat(ctx.paths.index_state), "worker must not load/save an editor ledger")
      result = run_generator(ctx, payload)
      t.assert_eq(result.code, 0, result.stderr .. result.stdout)
      t.assert_true(vim.deep_equal(vim.uv.fs_stat(ctx.paths.index_current_cdb).mtime, output_stat.mtime),
        "unchanged selected bytes must not be rewritten")
      t.assert_eq(read(ctx.paths.active_cdb), original)
    end)
    cleanup(ctx)
    if not ok then error(failure) end
  end)

  t.it("stale input and failed selection preserve the previous subset and publication", function()
    local ctx, _, keys = fixture()
    local ok, failure = pcall(function()
      write(ctx.paths.index_current_cdb, "previous-subset")
      write(ctx.paths.semantic_current_cdb, "previous-publication")
      local payload = request(ctx, keys)
      write(ctx.paths.active_cdb, read(ctx.paths.active_cdb) .. " \n")
      local result = run_generator(ctx, payload)
      t.assert_true(result.code ~= 0)
      t.assert_contains(result.stderr, "active CDB changed")
      t.assert_eq(read(ctx.paths.index_current_cdb), "previous-subset")
      t.assert_eq(read(ctx.paths.semantic_current_cdb), "previous-publication")
      payload = request(ctx, { "module:" .. ctx.engine_root .. "/Missing" })
      result = run_generator(ctx, payload)
      t.assert_true(result.code ~= 0)
      t.assert_contains(result.stderr, "No compile_commands entries matched")
      t.assert_eq(read(ctx.paths.index_current_cdb), "previous-subset")
      t.assert_eq(read(ctx.paths.semantic_current_cdb), "previous-publication")
      t.assert_eq(#vim.fn.glob(ctx.paths.index_current_cdb .. ".subset.*", false, true), 0)
    end)
    cleanup(ctx)
    if not ok then error(failure) end
  end)

  t.it("a replaced build lease prevents a delayed worker from publishing", function()
    local ctx, _, keys = fixture()
    local ok, failure = pcall(function()
      write(ctx.paths.index_current_cdb, "previous-subset")
      local payload = request(ctx, keys)
      local old = leases[ctx]
      t.assert_true(file_lock.release(old))
      leases[ctx] = assert(file_lock.acquire(old.path))
      t.assert_true(leases[ctx].token ~= old.token)
      local result = run_generator(ctx, payload)
      t.assert_true(result.code ~= 0)
      t.assert_contains(result.stderr, "lease")
      t.assert_eq(read(ctx.paths.index_current_cdb), "previous-subset")
      t.assert_eq(file_lock.owner(old.path).token, leases[ctx].token)
      t.assert_eq(#vim.fn.glob(ctx.paths.index_current_cdb .. ".subset.*", false, true), 0)
    end)
    cleanup(ctx)
    if not ok then error(failure) end
  end)

  t.it("the subset function reports a failed output write instead of returning a successful path", function()
    local ctx, _, keys = fixture()
    local slot, original
    for position = 1, 40 do
      local name, value = debug.getupvalue(index.write_subset_compile_commands, position)
      if not name then break end
      if name == "write_json_file" then slot, original = position, value; break end
    end
    local ok, failure = pcall(function()
      t.assert_true(slot ~= nil)
      write(ctx.paths.index_current_cdb, "previous-subset")
      debug.setupvalue(index.write_subset_compile_commands, slot, function() return false end)
      local output, _, reason = index.write_subset_compile_commands(ctx, "current", keys)
      t.assert_nil(output)
      t.assert_contains(reason, "Failed to write subset")
      t.assert_eq(read(ctx.paths.index_current_cdb), "previous-subset")
    end)
    if slot then debug.setupvalue(index.write_subset_compile_commands, slot, original) end
    cleanup(ctx)
    if not ok then error(failure) end
  end)

  t.it("an exited editor owner cannot publish even while its Python parent remains alive", function()
    local ctx, _, keys = fixture()
    local dead_lease
    local ok, failure = pcall(function()
      write(ctx.paths.index_current_cdb, "previous-subset")
      local payload = request(ctx, keys)
      local script = ctx.engine_root .. "/lease-owner.lua"
      write(script, [[
vim.opt.runtimepath:prepend(arg[1])
local lease = assert(require("ue.file_lock").acquire(arg[2]))
io.stdout:write(vim.json.encode({ owner_pid = vim.fn.getpid(), build_lease = lease }))
]])
      local child = vim.system({ vim.v.progpath, "--headless", "-u", "NONE", "-i", "NONE", "-n", "-l",
        script, vim.fn.stdpath("config"), ctx.engine_root .. "/dead-editor.lock" }, { text = true }):wait(10000)
      t.assert_eq(child.code, 0, child.stderr)
      local owner = vim.json.decode(child.stdout)
      dead_lease = owner.build_lease
      payload.owner_pid, payload.build_lease = owner.owner_pid, owner.build_lease
      local result = run_generator(ctx, payload)
      t.assert_true(result.code ~= 0)
      t.assert_contains(result.stderr, "subset owner unavailable")
      t.assert_eq(read(ctx.paths.index_current_cdb), "previous-subset")
      t.assert_eq(#vim.fn.glob(ctx.paths.index_current_cdb .. ".subset.*", false, true), 0)
    end)
    if dead_lease then file_lock.release(dead_lease) end
    cleanup(ctx)
    if not ok then error(failure) end
  end)

  t.it("an empty or corrupt temporary result never replaces the previous subset", function()
    local ctx, _, keys = fixture()
    local ok, failure = pcall(function()
      write(ctx.paths.index_current_cdb, "previous-subset")
      local payload = request(ctx, keys)
      local path, temporary = ctx.engine_root .. "/request.json", ctx.paths.index_current_cdb .. ".subset.failed.tmp"
      write(path, vim.json.encode(payload))
      -- Inject a producer fault; the real publication worker must reject it.
      local broken_producer = [[lua package.loaded.ue = true; package.loaded["ue.index"] = {
        write_subset_compile_commands = function(context, phase, selected)
          return context.paths["index_" .. phase .. "_cdb"], selected
        end }]]
      for _, bytes in ipairs({ "", "{", "[]", "{}", '[{"file":"x.cpp","directory":"x","arguments":[]}]' }) do
        write(temporary, bytes)
        local result = vim.system({ vim.v.progpath, "--headless", "-u", "NONE", "-i", "NONE", "-n",
          "--cmd", broken_producer, "-l", vim.fn.stdpath("config") .. "/tools/build_index_subset.lua",
          path, ctx.paths.index_current_cdb, tostring(vim.fn.getpid()), temporary }, { text = true }):wait(10000)
        t.assert_true(result.code ~= 0)
        t.assert_eq(read(ctx.paths.index_current_cdb), "previous-subset")
        t.assert_nil(vim.uv.fs_stat(temporary))
      end
    end)
    cleanup(ctx)
    if not ok then error(failure) end
  end)
end)
