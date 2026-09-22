-- Isolated subset worker. Reuse the editor's classifier without setup/state work.
local uv = vim.uv or vim.loop
local request_path, expected_output, parent_pid, temporary = arg[1], arg[2], tonumber(arg[3]), arg[4]
local owns_temporary = false
local function read(path)
  local file = assert(io.open(path, "rb"))
  local bytes = file:read("*a")
  file:close()
  return bytes
end

local ok, result = xpcall(function()
  assert(type(request_path) == "string" and type(expected_output) == "string"
    and parent_pid and parent_pid > 0 and type(temporary) == "string", "invalid subset worker arguments")
  local function process_alive(pid, label)
    local supported, alive, reason = pcall(uv.kill, pid, 0)
    assert(supported and (alive == 0 or alive == true), "subset " .. label .. " unavailable: " .. tostring(reason or alive))
  end
  local source = debug.getinfo(1, "S").source:sub(2)
  local repo = vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(source)))
  vim.opt.runtimepath:prepend(repo)
  package.path = repo .. "/lua/?.lua;" .. repo .. "/lua/?/init.lua;" .. package.path
  local fs = require("ue.core.fs")
  local platform = require("utils.platform")
  local file_lock = require("ue.file_lock")
  local function key(path) return platform.driver().path_key(vim.fs.normalize(path)) end
  local request = vim.json.decode(read(request_path))
  assert(type(request) == "table" and request.schema == 1, "unsupported subset request schema")
  assert(request.phase == "current" or request.phase == "hot", "unsupported subset phase")
  assert(type(request.owner_pid) == "number" and request.owner_pid > 0 and request.owner_pid == math.floor(request.owner_pid),
    "invalid subset owner PID")
  local lease = request.build_lease
  assert(type(lease) == "table" and type(lease.path) == "string" and fs.is_absolute_path(lease.path)
    and type(lease.token) == "string" and lease.token ~= "", "invalid subset build lease")
  local field = request.phase == "current" and "index_current_cdb" or "index_hot_cdb"
  local ctx, selected = request.ctx, request.selected_keys
  assert(type(ctx) == "table" and type(ctx.paths) == "table", "missing subset context")
  for _, name in ipairs({ "engine_root", "project_root" }) do
    assert(type(ctx[name]) == "string" and fs.is_absolute_path(ctx[name]), "invalid subset " .. name)
  end
  for _, name in ipairs({ "active_cdb", field, "index_cdb_dir" }) do
    assert(type(ctx.paths[name]) == "string" and fs.is_absolute_path(ctx.paths[name]), "invalid subset path: " .. name)
  end
  assert(type(selected) == "table" and vim.islist(selected) and #selected > 0, "missing ordered selected keys")
  local seen = {}
  for _, name in ipairs(selected) do
    assert(type(name) == "string" and name ~= "" and not seen[name], "invalid or duplicate selected key")
    seen[name] = true
  end
  assert(fs.is_absolute_path(expected_output) and key(ctx.paths[field]) == key(expected_output), "subset output does not match requested phase")
  assert(fs.is_absolute_path(temporary) and key(vim.fs.dirname(temporary)) == key(vim.fs.dirname(expected_output))
    and vim.fs.basename(temporary):sub(1, #vim.fs.basename(expected_output) + 8) == vim.fs.basename(expected_output) .. ".subset.",
    "invalid owned subset temporary path")
  local function physical_key(path)
    local resolved = uv.fs_realpath(path)
    if not resolved then
      resolved = vim.fs.joinpath(assert(uv.fs_realpath(vim.fs.dirname(path)), "subset parent unavailable"), vim.fs.basename(path))
    end
    return key(resolved)
  end
  local active_key = physical_key(ctx.paths.active_cdb)
  assert(active_key ~= physical_key(expected_output) and active_key ~= physical_key(temporary), "active CDB must not be a subset output")
  local function current_input()
    process_alive(parent_pid, "parent")
    process_alive(request.owner_pid, "owner")
    local owner = file_lock.owner(lease.path)
    assert(owner and owner.token == lease.token and owner.pid == request.owner_pid, "subset build lease changed")
    local stat = assert(uv.fs_stat(ctx.paths.active_cdb), "active CDB unavailable")
    assert(stat.type == "file", "active CDB must be a file")
    local signature = { size = stat.size, mtime = stat.mtime, ctime = stat.ctime }
    assert(vim.deep_equal(signature, request.input_signature), "active CDB changed during subset generation")
  end
  -- Python creates/owns this file, so finally can remove it even on timeout.
  assert(uv.fs_stat(temporary), "owned subset temporary is missing")
  owns_temporary = true
  current_input()
  local worker_ctx = vim.deepcopy(ctx)
  worker_ctx.paths[field] = temporary
  require("ue") -- sets the original index dependencies; deliberately no setup().
  local output, keys, failure = require("ue.index").write_subset_compile_commands(worker_ctx, request.phase, selected)
  assert(output and not failure, failure or "subset generation failed")
  assert(key(output) == key(temporary) and vim.deep_equal(keys, selected), "subset worker returned a different output or selection")
  current_input()
  local bytes = read(temporary)
  local subset = vim.json.decode(bytes)
  assert(type(subset) == "table" and vim.islist(subset) and #subset > 0, "generated subset must be a nonempty CDB list")
  for _, entry in ipairs(subset) do
    assert(type(entry) == "table" and type(entry.file) == "string" and entry.file ~= ""
      and type(entry.directory) == "string" and entry.directory ~= "", "generated subset has an invalid CDB entry")
    if entry.arguments ~= nil then
      assert(type(entry.arguments) == "table" and vim.islist(entry.arguments) and #entry.arguments > 0
        and type(entry.arguments[1]) == "string" and entry.arguments[1] ~= "", "generated subset has invalid arguments")
      for _, value in ipairs(entry.arguments) do assert(type(value) == "string", "generated subset has a non-string argument") end
    else
      assert(type(entry.command) == "string" and entry.command:find("%S"), "generated subset has no compile command")
    end
  end
  local old_ok, previous = pcall(read, expected_output)
  local changed = not old_ok or previous ~= bytes
  if changed and old_ok then
    local old_json_ok, old_json = pcall(vim.json.decode, previous)
    if old_json_ok and vim.deep_equal(old_json, subset) then changed = false end
  end
  current_input()
  if changed then assert(uv.fs_rename(temporary, expected_output))
  else assert(uv.fs_unlink(temporary)) end
  return { ok = true, output = expected_output, phase = request.phase, selected_keys = keys, changed = changed }
end, debug.traceback)
if not ok then
  if owns_temporary then pcall(uv.fs_unlink, temporary) end
  -- Python also owns cleanup, including timeout and early request failures.
  io.stderr:write("subset generation failed: " .. tostring(result) .. "\n")
  vim.cmd("cquit 1")
else
  io.stdout:write(vim.json.encode(result) .. "\n")
end
