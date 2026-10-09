-- Independent ordinary-phase publisher; never loaded in an editor session.
local source = debug.getinfo(1, "S").source:sub(2)
local repo = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(source)))))
vim.opt.runtimepath:prepend(repo)
package.path = repo .. "/lua/?.lua;" .. repo .. "/lua/?/init.lua;" .. package.path
vim.g.ue_index_worker = true
local function read(path)
  local file = assert(io.open(path, "rb"))
  local raw = file:read("*a"); file:close(); return raw
end
local request = vim.json.decode(read(assert(arg[1])))
local function write(path, value)
  local tmp = path .. "." .. vim.fn.getpid() .. ".tmp"
  local file = assert(io.open(tmp, "wb"))
  assert(file:write(vim.json.encode(value))); assert(file:close())
  local ok, err = vim.uv.fs_rename(tmp, path)
  if not ok then vim.uv.fs_unlink(tmp); error(err) end
end
local ok, result = xpcall(function()
  assert(request.schema == 1, "invalid publication request")
  require("ue")
  local index = require("ue.index")
  local function current()
    local lease = request.opts.lease
    local owner = lease and require("ue.file_lock").owner(lease.path)
    assert(owner and owner.pid == request.opts.owner_pid and owner.token == lease.token, "publication lease changed")
    local alive = vim.uv.kill(request.opts.owner_pid, 0)
    assert(alive == 0 or alive == true, "publication owner exited")
    for path, before in pairs(request.signatures) do
      local stat = vim.uv.fs_stat(path)
      local now = stat and { size = stat.size, mtime = stat.mtime, ctime = stat.ctime,
        dev = string.format("%.17g", stat.dev or 0), ino = string.format("%.17g", stat.ino or 0) } or false
      assert(vim.deep_equal(before, now), "publication input changed: " .. path)
    end
  end
  current()
  index._publication_guard = current
  local generation = index.generation_for_context(request.ctx, { base_cdb_path = request.opts.base_cdb_path, synchronous = true })
  assert(generation.generation_id ~= "", "publication generation unavailable")
  local manifest = assert(index.make_index_manifest(request.ctx, request.state, request.phase,
    request.marker, request.keys, request.opts))
  current()
  local path = request.marker .. ".manifest.json"
  local previous
  if vim.uv.fs_stat(path) then
    local readable, value = pcall(function() return vim.json.decode(read(path)) end)
    if readable then previous = value end
  end
  if not vim.deep_equal(previous, manifest) then write(path, manifest) end
  request.state.index_artifacts[request.phase] = manifest
  local selection = index.select_active_artifact(request.state, generation)
  assert(selection, "publication selection failed")
  local promoted, publication = index.publish_semantic_cdb(request.ctx, request.state, generation)
  assert(promoted, tostring(publication))
  current()
  return { ok = true, manifest = manifest, generation = generation, selection = selection,
    promoted = promoted, publication = publication }
end, debug.traceback)
if not ok then result = { ok = false, reason = tostring(result) } end
local alive = vim.uv.kill(request.opts.owner_pid, 0)
if alive == 0 or alive == true then
  write(request.output, result)
else
  vim.uv.fs_unlink(request.output)
  vim.uv.fs_unlink(assert(arg[1]))
end
if not ok then io.stderr:write(result.reason .. "\n") end
vim.cmd(ok and "qa!" or "cq 1")
