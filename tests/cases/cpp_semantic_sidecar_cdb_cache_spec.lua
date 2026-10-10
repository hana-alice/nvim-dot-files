local t = require("tests.harness")
t.bootstrap()
local libclang = require("utils.ue_goto.semantic_sidecar_libclang")
local cache_module = require("utils.ue_goto.semantic_cdb_cache")

local function fixture(body)
  local root = vim.fs.normalize(vim.fn.tempname())
  vim.fn.mkdir(root .. "/selection", "p")
  local f = { root = root, merged = root .. "/compile_commands.json",
    active = root .. "/selection/Build-A.json", manifest = root .. "/selection/manifest.json", source = root .. "/real.cpp" }
  f.entries = { { directory = root, file = f.source, arguments = { "clang++", "-c", f.source, "-DVALUE=1" } } }
  function f.write(path, value)
    local bytes = type(value) == "string" and value or vim.json.encode(value)
    local file = assert(io.open(path, "wb")); file:write(bytes); file:close()
    return bytes
  end
  function f.publish()
    local merged = f.write(f.merged, f.entries)
    local active = f.write(f.active, f.entries)
    f.write(f.manifest, { active = "Build-A" })
    f.write(f.merged .. ".pipeline-result.json", { provenance = { schema = 1, active_key = "Build-A",
      merged_cdb_sha256 = vim.fn.sha256(merged), active_cdb_sha256 = vim.fn.sha256(active) } })
  end
  f.publish()
  local ok, err = xpcall(function() body(f) end, debug.traceback)
  vim.fn.delete(root, "rf")
  if not ok then error(err) end
end

t.describe("semantic sidecar: positive parsed CDB cache", function()
  t.it("identical metadata cannot hide changed bytes or make a new receipt reuse old decoded argv", function()
    fixture(function(f)
      local old_stat, old_read = libclang.uv.fs_stat, libclang.read_all
      local fixed = assert(old_stat(f.merged))
      local sidecar = require("utils.ue_goto.semantic_sidecar").new()
      local real_reads = 0
      -- Only the file-metadata input is held constant. Content and SHA256 are real.
      libclang.uv.fs_stat = function(path, ...)
        if libclang.normalize(path) == f.merged then return vim.deepcopy(fixed) end
        return old_stat(path, ...)
      end
      libclang.read_all = function(path)
        if path == f.merged then real_reads = real_reads + 1 end
        return old_read(path)
      end
      local request = { id = "constant-metadata", source = f.source, cdb_dir = f.root,
        cdb_path = f.merged, active_cdb_path = f.active, active_manifest_path = f.manifest }
      local ok, err = xpcall(function()
        local first = sidecar:handle_prove(request)
        t.assert_eq(first.state, "resolved")
        local old_signature = sidecar.compilation_databases.entries[f.merged].signature
        local old_digest = sidecar.compilation_databases.entries[f.merged].digest
        local reads_before = real_reads
        f.entries[1].arguments[4] = "-DVALUE=2"
        f.write(f.merged, f.entries)
        local refused = sidecar:handle_prove(request)
        t.assert_eq(refused.state, "unavailable")
        t.assert_eq(refused.reason, "merged-cdb-identity-mismatch")
        t.assert_true(real_reads > reads_before, "freshness must re-read even identical metadata")
        f.publish() -- legitimate new content-bound transaction receipt
        local next_proof = sidecar:handle_prove(request)
        t.assert_eq(next_proof.state, "resolved")
        t.assert_true(vim.tbl_contains(next_proof.compile.argv, "-DVALUE=2"))
        local refreshed = sidecar.compilation_databases.entries[f.merged]
        t.assert_eq(refreshed.signature, old_signature)
        t.assert_true(refreshed.digest ~= old_digest, "parsed input reuse must bind the actual digest")
      end, debug.traceback)
      libclang.uv.fs_stat, libclang.read_all = old_stat, old_read
      sidecar:shutdown()
      if not ok then error(err) end
    end)
  end)

  t.it("shares at most two complete inputs between prove and catalog without caching context outcomes", function()
    fixture(function(f)
      local sidecar = require("utils.ue_goto.semantic_sidecar").new()
      local old_decode, reads = vim.json.decode, 0
      vim.json.decode = function(bytes, ...)
        if bytes:find('"arguments"', 1, true) then reads = reads + 1 end
        return old_decode(bytes, ...)
      end
      local request = { id = "first", source = f.source, cdb_dir = f.root, cdb_path = f.merged,
        active_cdb_path = f.active, active_manifest_path = f.manifest }
      local ok, err = xpcall(function()
        local first = sidecar:handle_prove(request)
        t.assert_eq(first.state, "resolved")
        t.assert_eq(reads, 2)
        first.compile.argv[#first.compile.argv] = "-DPOISONED=1"
        local second = sidecar:handle_prove(request)
        t.assert_true(vim.tbl_contains(second.compile.argv, "-DVALUE=1"))
        t.assert_false(vim.tbl_contains(second.compile.argv, "-DPOISONED=1"))
        sidecar:handle_catalog(vim.tbl_extend("force", request, { header = f.root .. "/subject.h", evidence_roots = {} }))
        t.assert_eq(reads, 2)
        t.assert_eq(vim.tbl_count(sidecar.compilation_databases.entries), 2)
      end, debug.traceback)
      vim.json.decode = old_decode
      sidecar:shutdown()
      if not ok then error(err) end
    end)
  end)

  t.it("rejects changed bytes with preserved size and mtime after a warm proof", function()
    fixture(function(f)
      local sidecar = require("utils.ue_goto.semantic_sidecar").new()
      local request = { id = "first", source = f.source, cdb_dir = f.root, cdb_path = f.merged,
        active_cdb_path = f.active, active_manifest_path = f.manifest }
      t.assert_eq(sidecar:handle_prove(request).state, "resolved")
      local before = assert(vim.uv.fs_stat(f.merged))
      f.entries[1].arguments[4] = "-DVALUE=2"
      f.write(f.merged, f.entries)
      assert(vim.uv.fs_utime(f.merged, before.atime.sec, before.mtime.sec + before.mtime.nsec / 1e9))
      local response = sidecar:handle_prove(request)
      t.assert_eq(response.state, "unavailable")
      t.assert_eq(response.reason, "merged-cdb-identity-mismatch")
      sidecar:shutdown()
    end)
  end)

  t.it("still rejects changed selection before consulting a warm parsed dataset", function()
    fixture(function(f)
      local sidecar = require("utils.ue_goto.semantic_sidecar").new()
      local request = { id = "first", source = f.source, cdb_dir = f.root, cdb_path = f.merged,
        active_cdb_path = f.active, active_manifest_path = f.manifest }
      t.assert_eq(sidecar:handle_prove(request).state, "resolved")
      f.write(f.manifest, { active = "Build-B" })
      local response = sidecar:handle_prove(request)
      t.assert_eq(response.state, "unavailable")
      t.assert_eq(response.reason, "merged-cdb-selection-mismatch")
      sidecar:shutdown()
    end)
  end)

  t.it("does not retain unreadable or incomplete datasets and recovers after correction", function()
    fixture(function(f)
      local cache = cache_module.new()
      f.write(f.merged, "invalid-json")
      t.assert_nil(cache:load(f.merged))
      t.assert_eq(vim.tbl_count(cache.entries), 0)
      f.write(f.merged, { f.entries[1], { file = "missing-argv.cpp" } })
      local partial = cache:load(f.merged)
      t.assert_false(partial.complete)
      t.assert_eq(vim.tbl_count(cache.entries), 0)
      f.write(f.merged, f.entries)
      t.assert_true(cache:load(f.merged).complete)
      t.assert_eq(vim.tbl_count(cache.entries), 1)
    end)
  end)

  t.it("invalidates compiled argv when content changes with preserved mtime and bounds LRU at two", function()
    fixture(function(f)
      local cache = cache_module.new()
      cache:load(f.merged)
      local stat = assert(vim.uv.fs_stat(f.merged))
      f.entries[1].arguments[4] = "-DVALUE=2"
      f.write(f.merged, f.entries)
      assert(vim.uv.fs_utime(f.merged, stat.atime.sec, stat.mtime.sec + stat.mtime.nsec / 1e9))
      t.assert_true(vim.tbl_contains(cache:load(f.merged).entries[1].argv, "-DVALUE=2"))
      cache:load(f.active)
      local third = f.root .. "/third.json"
      f.write(third, f.entries)
      cache:load(third)
      t.assert_eq(vim.tbl_count(cache.entries), 2)
      t.assert_nil(cache.entries[f.merged])
      cache:clear()
      t.assert_eq(vim.tbl_count(cache.entries), 0)
    end)
  end)

  t.it("a dataset changed during decode cannot enter the positive cache", function()
    fixture(function(f)
      local cache = cache_module.new()
      local old_decode = vim.json.decode
      vim.json.decode = function(bytes, ...)
        local result = old_decode(bytes, ...)
        f.entries[1].arguments[#f.entries[1].arguments + 1] = "-DCHANGED=1"
        f.write(f.merged, f.entries)
        return result
      end
      local ok, err = xpcall(function()
        local db, reason = cache:load(f.merged)
        t.assert_nil(db)
        t.assert_eq(reason, "cdb-changed-during-read")
        t.assert_eq(vim.tbl_count(cache.entries), 0)
      end, debug.traceback)
      vim.json.decode = old_decode
      if not ok then error(err) end
    end)
  end)
end)
