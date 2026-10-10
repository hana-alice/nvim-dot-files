local t = require("tests.harness")
t.bootstrap()

local function write(path, raw)
  local file = assert(io.open(path, "wb"))
  assert(file:write(raw)); assert(file:close())
end

local function fixture()
  local path = vim.fn.tempname():gsub("\\", "/") .. ".json"
  local reads = 0
  local helpers = require("ue.index._generation_digest")({}, { h = { read_text_file = function(name)
    reads = reads + 1
    local file = assert(io.open(name, "rb"))
    local raw = file:read("*a"); file:close(); return raw
  end } })
  return path, helpers, function() return reads end
end

local function generation_fixture()
  local path = vim.fn.tempname():gsub("\\", "/") .. ".json"
  write(path, '[{"file":"A.cpp"}]')
  local state = { modules = {}, index_artifacts = {}, build = { status = "ready", message = "previous success" } }
  local ctx = { paths = { semantic_cdb = path }, state = {} }
  local control = { reason = "digest-pending", wakes = 0, launches = 0 }
  local api, core = {}, { RT = { toolchain_identity_override = "test" }, h = {}, deps = {
    core_rt = { dirty_index_roots = {}, start_deferred_clangd = function() control.wakes = control.wakes + 1 end },
    status_root_key = function() return "sample" end,
  } }
  core.h.ensure_index_state = function() return state end
  core.h.base_compile_commands_path = function() return path end
  core.h.index_phase_label = function(value) return value end
  core.h.module_tier_label = function(value) return value end
  core.h.read_text_file = function(name)
    local file = assert(io.open(name, "rb")); local raw = file:read("*a"); file:close(); return raw
  end
  local name = "ue.index._generation_digest"
  local original = require(name)
  package.loaded[name] = function(m, c)
    local helpers = original(m, c)
    helpers.normalized_cdb_digest = function() return control.value, control.reason end
    helpers.normalized_cdb_digest_async = function(_, cb)
      control.launches = control.launches + 1
      control.callback = cb
    end
    return helpers
  end
  local ok, err = pcall(require("ue.index._generation"), api, core)
  package.loaded[name] = original
  assert(ok, err)
  local generation = api.generation_for_context(ctx, { cdb_digest = "confirmed" })
  local artifact = { generation_id = generation.generation_id, build_key = generation.build_key,
    phase = "full", coverage_level = "full", artifact_fingerprint = "artifact", index_path = path,
    background_cdb_path = path, cdb_source_signature = core.h.file_signature(path) }
  state.index_artifacts.full = artifact
  core.h.update_index_selection(state, artifact, generation, "fresh")
  return path, api, ctx, state, control
end

t.describe("ue.index asynchronous generation digest", function()
  t.it("cold large CDB uses an independent worker and does not read on the parent loop", function()
    local path, helpers, reads = fixture()
    write(path, vim.json.encode({ { directory = "C:/sample", file = "A.cpp", command = string.rep("x", 1100000) } }))
    local value, reason = helpers.normalized_cdb_digest(path)
    t.assert_eq(value, nil)
    t.assert_eq(reason, "digest-pending")
    t.assert_eq(reads(), 0)
    local done, result, err = false
    helpers.normalized_cdb_digest_async(path, function(digest, failure)
      result, err, done = digest, failure, true
    end)
    t.assert_true(vim.wait(10000, function() return done end, 10))
    t.assert_eq(err, nil)
    t.assert_true(type(result) == "string" and #result == 64)
    t.assert_eq(reads(), 0)
    t.assert_eq(helpers.normalized_cdb_digest(path), result)
    vim.fn.delete(path)
  end)

  t.it("replacement with equal size and mtime discards an in-flight digest and recomputes", function()
    local path, helpers = fixture()
    write(path, '[{"directory":"C:/sample","file":"A.cpp","arguments":["clang++","A.cpp"]}]')
    assert(vim.uv.fs_utime(path, os.time(), os.time()))
    local old_stat = assert(vim.uv.fs_stat(path))
    local old_identity, old_digest = helpers.cdb_identity(path), helpers.compute_cdb_digest(path)
    local replacement = path .. ".replacement"
    write(replacement, '[{"directory":"C:/sample","file":"B.cpp","arguments":["clang++","B.cpp"]}]')
    assert(vim.uv.fs_utime(replacement, old_stat.atime.sec, old_stat.mtime.sec))
    local callback, launches = nil, 0
    local done, result, failure = false
    -- Invalidate the cache before starting: a new identity is about to arrive.
    assert(vim.uv.fs_rename(replacement, path))
    helpers.normalized_cdb_digest_async(path, function(value, err)
      result, failure, done = value, err, true
    end, { spawn = function(_, _, cb)
      launches = launches + 1
      callback = cb
      return {}
    end })
    -- Replace once more while the mock worker is in flight; its original
    -- result must never reach consumers, even when byte count is unchanged.
    local in_flight_identity = helpers.cdb_identity(path)
    local in_flight_digest = helpers.compute_cdb_digest(path)
    write(replacement, '[{"directory":"C:/sample","file":"D.cpp","arguments":["clang++","D.cpp"]}]')
    assert(vim.uv.fs_utime(replacement, old_stat.atime.sec, old_stat.mtime.sec))
    assert(vim.uv.fs_rename(replacement, path))
    local replaced_identity = helpers.cdb_identity(path)
    t.assert_eq(replaced_identity.size, in_flight_identity.size)
    t.assert_true(vim.deep_equal(replaced_identity.mtime, in_flight_identity.mtime))
    callback({ code = 0, stdout = vim.json.encode({ ok = true, digest = in_flight_digest, identity = in_flight_identity }) })
    t.assert_true(vim.wait(1000, function() return launches == 2 end, 10))
    t.assert_eq(done, false)
    local new_identity, new_digest = helpers.cdb_identity(path), helpers.compute_cdb_digest(path)
    callback({ code = 0, stdout = vim.json.encode({ ok = true, digest = new_digest, identity = new_identity }) })
    t.assert_true(vim.wait(1000, function() return done end, 10))
    t.assert_eq(failure, nil)
    t.assert_eq(result, new_digest)
    t.assert_true(result ~= old_digest and result ~= in_flight_digest)
    t.assert_true(not vim.deep_equal(old_identity, new_identity))
    vim.fn.delete(path)
  end)

  t.it("worker failure reports an error and cannot reuse a previous identity's digest", function()
    local path, helpers = fixture()
    write(path, '[{"file":"A.cpp"}]')
    local old = helpers.compute_cdb_digest(path)
    write(path, '[{"file":"changed.cpp"}]')
    local done, value, failure = false
    helpers.normalized_cdb_digest_async(path, function(digest, err)
      done, value, failure = true, digest, err
    end, { spawn = function(_, _, callback)
      callback({ code = 9, stdout = "", stderr = "explicit worker failure" })
      return {}
    end })
    t.assert_true(vim.wait(1000, function() return done end, 10))
    t.assert_eq(value, nil)
    t.assert_match(failure, "digest%-worker%-failed")
    done = false
    helpers.normalized_cdb_digest_async(path, function(digest, err)
      t.assert_eq(digest, nil)
      t.assert_eq(err, failure)
      done = true
    end, { spawn = function() error("unchanged failed input must not create a retry storm") end })
    t.assert_true(vim.wait(1000, function() return done end, 10))
    t.assert_true(helpers.compute_cdb_digest(path) ~= old)
    vim.fn.delete(path)
  end)

  t.it("a separately verified publication digest clears failure only for its current file identity", function()
    local path, helpers = fixture()
    write(path, '[{"file":"A.cpp"}]')
    local signature = helpers.cdb_identity(path)
    local confirmed = string.rep("a", 64)
    write(path, '[{"file":"changed.cpp"}]')
    t.assert_false(helpers.accept_verified_digest(path, confirmed, signature))
    t.assert_true(helpers.accept_verified_digest(path, confirmed, helpers.cdb_identity(path)))
    t.assert_eq(helpers.normalized_cdb_digest(path), confirmed)
    vim.fn.delete(path)
  end)

  t.it("checks cached identity again when a scheduled callback finally runs", function()
    local path, helpers = fixture()
    write(path, '[{"file":"A.cpp"}]')
    local old = helpers.compute_cdb_digest(path)
    local done, result = false
    helpers.normalized_cdb_digest_async(path, function(value, err)
      t.assert_eq(err, nil)
      result, done = value, true
    end)
    write(path, '[{"file":"B.cpp","arguments":["clang++"]}]')
    t.assert_true(vim.wait(10000, function() return done end, 10))
    t.assert_true(result ~= old)
    t.assert_eq(result, helpers.compute_cdb_digest(path))
    vim.fn.delete(path)
  end)

  t.it("pending generation is not reported as stale persisted artifacts", function()
    local api = {}
    require("ue.index._delivery")(api, { h = {
      ensure_index_state = function() return { index_artifacts = {} } end,
      generation_for_context = function() return { pending = true, generation_id = "" } end,
      read_index_manifest = function() error("pending generation cannot classify manifests") end,
    } })
    t.assert_eq(#api.stale_index_artifacts({ paths = {} }), 0)
  end)

  t.it("failed generation never starts background proof with an empty identity", function()
    local path = vim.fn.tempname():gsub("\\", "/")
    write(path .. ".semantic.json", "[]")
    local queue = require("ue.index.batch_background")
    local saved, launched = queue.start, false
    queue.start = function() launched = true end
    local ok, reason = pcall(function()
      local api = { base_compile_commands_path = function() return path end }
      require("ue.index._batch_background")(api, { h = {
        file_signature = function() return "unchanged" end,
        generation_for_context = function() return { failed = true, generation_id = "", digest_error = "worker failed" } end,
      } })
      api.start_background_batches({}, { enabled = true, background = path })
      t.assert_eq(launched, false)
    end)
    queue.start = saved
    vim.fn.delete(path .. ".semantic.json")
    if not ok then error(reason) end
  end)

  t.it("cold pending snapshot does not claim ready and resumes its deferred reader after verification", function()
    local path, api, ctx, state, control = generation_fixture()
    local before = vim.deepcopy(state.index_selection)
    local snapshot = api.semantic_index_snapshot(ctx)
    t.assert_eq(snapshot.readiness, "pending")
    t.assert_eq(snapshot.generation_id, "")
    t.assert_eq(api.index_status_summary(ctx).status, "pending")
    t.assert_true(vim.deep_equal(before, state.index_selection), "pending must preserve persisted selection history")
    t.assert_eq(control.launches, 1, "snapshot and status must share one consumer continuation")
    control.value, control.reason = "confirmed", nil
    control.callback("confirmed")
    t.assert_eq(control.wakes, 1)
    t.assert_eq(api.semantic_index_snapshot(ctx).readiness, "ready")
    t.assert_eq(state.build.status, "ready")
    vim.fn.delete(path)
  end)

  t.it("digest failure is distinct from pending and never changes persisted build history", function()
    local path, api, ctx, state, control = generation_fixture()
    control.reason = "digest-worker-failed: explicit failure"
    local before = vim.deepcopy(state.build)
    local generation = api.generation_for_context(ctx)
    t.assert_eq(generation.pending, false)
    t.assert_eq(generation.failed, true)
    local summary = api.index_status_summary(ctx)
    t.assert_eq(summary.status, "error")
    t.assert_match(summary.message, "explicit failure")
    t.assert_eq(api.semantic_index_snapshot(ctx).readiness, "failed")
    t.assert_true(vim.deep_equal(before, state.build))
    t.assert_eq(control.launches, 0, "failed identity must not register pending continuations")
    vim.fn.delete(path)
  end)

  t.it("exit cancellation kills only this digest factory's owned worker handle", function()
    local path, helpers = fixture()
    write(path, '[{"file":"A.cpp"}]')
    local killed, callback, returned = 0, nil, false
    helpers.normalized_cdb_digest_async(path, function() returned = true end, { spawn = function(_, _, cb)
      callback = cb
      return { kill = function(_, signal) t.assert_eq(signal, 15); killed = killed + 1 end }
    end })
    helpers.cancel_pending()
    t.assert_eq(killed, 1)
    callback({ code = 9, stdout = "", stderr = "cancelled" })
    vim.wait(20, function() return false end, 10)
    t.assert_eq(returned, false, "exit cancellation must not resume editor work")
    vim.fn.delete(path)
  end)
end)
