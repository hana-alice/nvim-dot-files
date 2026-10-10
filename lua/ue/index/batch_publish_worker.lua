-- Isolated publisher: all large CDB reads, hashes and merges stay in this child.
local source = debug.getinfo(1, "S").source:sub(2)
local repo = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(source)))))
vim.opt.runtimepath:prepend(repo)
package.path = repo .. "/lua/?.lua;" .. repo .. "/lua/?/init.lua;" .. package.path
vim.g.ue_index_worker = true -- This isolated publisher owns synchronous CDB work.
local function read(path)
  local file = assert(io.open(path, "rb"))
  local raw = file:read("*a"); file:close()
  return raw
end
local request = vim.json.decode(read(assert(arg[1])))
local generation
local ok, result = xpcall(function()
  assert(request.schema == 1, "invalid background publication request")
  require("ue") -- Installs the original index dependencies without editor setup.
  local index, fs = require("ue.index"), require("ue.core.fs")
  local function current()
    local owner = require("ue.file_lock").owner(request.lease.path)
    assert(owner and owner.pid == request.owner_pid and owner.token == request.lease.token, "publication lease changed")
    local alive = vim.uv.kill(request.owner_pid, 0)
    assert(alive == 0 or alive == true, "publication owner exited")
    local stat = assert(vim.uv.fs_stat(request.base), "publication base missing")
    local stamp = table.concat({ stat.size, stat.mtime.sec, stat.mtime.nsec }, ":")
    assert(stamp == request.base_signature, "publication base changed")
    assert(vim.fn.sha256(read(request.source)) == request.source_sha256, "publication semantic input changed")
  end
  current()
  local ctx = request.ctx
  generation = index.generation_for_context(ctx, { base_cdb_path = request.base, synchronous = true })
  assert(generation.generation_id == request.generation_id, "publication generation changed")
  local state = index.ensure_index_state(ctx)
  local previous = assert(state.index_artifacts.full, "publication full baseline missing")
  assert(previous.generation_id == generation.generation_id, "publication baseline changed")
  local manifest = index.make_index_manifest(ctx, state, "full", request.marker, previous.module_keys, {
    base_cdb_path = request.base, background_cdb_path = request.background,
    semantic_cdb_path = request.source, index_kind = "controlled-background", completed_at = os.time(), synchronous = true,
  })
  current()
  if not vim.deep_equal(previous, manifest) then
    local path = request.marker .. ".manifest.json"
    local temporary = path .. ".publication." .. vim.fn.getpid()
    local file = assert(io.open(temporary, "wb"))
    assert(file:write(vim.json.encode(manifest))); assert(file:close())
    assert(vim.uv.fs_rename(temporary, path), "publication manifest write failed")
  end
  state.index_artifacts.full = manifest
  local selection = index.select_active_artifact(state, generation)
  assert(selection, "publication coverage selection failed")
  index.update_index_selection(state, selection, generation, "fresh")
  local promoted, publication = index.publish_semantic_cdb(ctx, state, generation)
  assert(promoted, tostring(publication))
  current()
  return { ok = true, manifest = manifest, index_selection = state.index_selection, publication = publication,
    generation_id = generation.generation_id, generation = generation, scope = fs.norm(ctx.paths.semantic_cdb) }
end, debug.traceback)
if not ok then result = { ok = false, reason = tostring(result), generation = generation,
  requested_generation = request.generation, requested_generation_id = request.generation_id } end
local path = assert(request.publication_result)
local temporary = path .. "." .. vim.fn.getpid() .. ".tmp"
local file = assert(io.open(temporary, "wb")); assert(file:write(vim.json.encode(result))); assert(file:close())
assert(vim.uv.fs_rename(temporary, path))
if not ok then io.stderr:write(result.reason .. "\n") end
vim.cmd(ok and "qa!" or "cq 1")
