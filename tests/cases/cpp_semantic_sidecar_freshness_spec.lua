local t = require("tests.harness")
t.bootstrap()
local native = require("utils.ue_goto.semantic_sidecar_libclang")
local uv = vim.uv

local function write(path, value)
  local file = assert(io.open(path, "wb"))
  file:write(type(value) == "string" and value or vim.json.encode(value))
  file:close()
end

local function with_pair(body)
  local root = vim.fs.normalize(vim.fn.tempname())
  vim.fn.mkdir(root .. "/shards", "p")
  local pair = {
    merged = root .. "/compile_commands.json",
    active = root .. "/shards/Android-Fixture-Test.json",
    manifest = root .. "/shards/manifest.json",
    key = "Android-Fixture-Test",
    raw = '[{"file":"A.cpp","directory":"/fixture","arguments":["clang++","-DRAW=1","A.cpp"]}]',
    processed = '[{"file":"A.cpp","directory":"/fixture","arguments":["clang++","-DPROCESSED=1","A.cpp"]}]',
  }
  write(pair.merged, pair.processed)
  write(pair.active, pair.raw)
  write(pair.manifest, { active = pair.key, shards = { [pair.key] = { platform = "Android", config = "Test" } } })
  assert(uv.fs_utime(pair.active, 90, 90))
  assert(uv.fs_utime(pair.merged, 100, 100))
  assert(uv.fs_utime(pair.manifest, 113.4, 113.4))
  pair.proof = {
    schema = 1, active_key = pair.key,
    active_cdb_sha256 = vim.fn.sha256(pair.raw),
    merged_cdb_sha256 = vim.fn.sha256(pair.processed),
  }
  function pair.publish(proof)
    write(pair.merged .. ".pipeline-result.json", { schema = 1, provenance = proof or pair.proof })
  end
  function pair.fresh()
    return native.active_cdb_is_fresh(pair.merged, pair.active, pair.manifest)
  end
  local ok, err = xpcall(function() body(pair) end, debug.traceback)
  vim.fn.delete(root, "rf")
  if not ok then error(err) end
end

t.describe("semantic sidecar committed CDB identity", function()
  t.it("accepts the committed processed bytes although copy2 predates selection metadata", function()
    with_pair(function(pair)
      pair.publish()
      t.assert_true(pair.raw ~= pair.processed, "raw and postprocessed command bytes are distinct")
      local fresh, reason = pair.fresh()
      t.assert_true(fresh, reason)
    end)
  end)

  t.it("rejects old merged bytes after a selection switch even with equal timestamps", function()
    with_pair(function(pair)
      pair.publish()
      local switched = pair.active:gsub("Test.json$", "Shipping.json")
      write(switched, pair.raw:gsub("RAW=1", "RAW=2"))
      write(pair.manifest, { active = "Android-Fixture-Shipping", shards = {} })
      assert(uv.fs_utime(switched, 100, 100))
      assert(uv.fs_utime(pair.manifest, 100, 100))
      local fresh, reason = native.active_cdb_is_fresh(pair.merged, switched, pair.manifest)
      t.assert_false(fresh)
      t.assert_eq(reason, "merged-cdb-selection-mismatch")
    end)
  end)

  t.it("rejects a changed selected shard whose size and mtime were preserved after a warm check", function()
    with_pair(function(pair)
      pair.publish()
      t.assert_true(pair.fresh())
      write(pair.active, pair.raw:gsub("RAW=1", "RAW=2"))
      assert(uv.fs_utime(pair.active, 90, 90))
      local fresh, reason = pair.fresh()
      t.assert_false(fresh)
      t.assert_eq(reason, "active-cdb-identity-mismatch")
    end)
  end)

  t.it("rejects changed merged bytes with preserved size and mtime after a warm check", function()
    with_pair(function(pair)
      pair.publish()
      t.assert_true(pair.fresh())
      write(pair.merged, pair.processed:gsub("PROCESSED=1", "PROCESSED=2"))
      assert(uv.fs_utime(pair.merged, 100, 100))
      local fresh, reason = pair.fresh()
      t.assert_false(fresh)
      t.assert_eq(reason, "merged-cdb-identity-mismatch")
    end)
  end)

  t.it("invalid committed evidence cannot fall through to the legacy timestamp gate", function()
    with_pair(function(pair)
      pair.publish({ schema = 1, active_key = pair.key })
      assert(uv.fs_utime(pair.manifest, 100, 100))
      local fresh, reason = pair.fresh()
      t.assert_false(fresh)
      t.assert_eq(reason, "merged-cdb-provenance-invalid")
    end)
  end)

  t.it("preserves legacy stale refusal when no content-bound transaction evidence exists", function()
    with_pair(function(pair)
      local fresh, reason = pair.fresh()
      t.assert_false(fresh)
      t.assert_eq(reason, "merged-cdb-predates-active-selection")
    end)
  end)

  t.it("unreadable selection remains unavailable even with otherwise matching evidence", function()
    with_pair(function(pair)
      pair.publish()
      assert(uv.fs_unlink(pair.manifest))
      local fresh, reason = pair.fresh()
      t.assert_false(fresh)
      t.assert_eq(reason, "active-manifest-unreadable")
    end)
  end)
end)

t.describe("semantic sidecar builtin resource ownership", function()
  t.it("uses the loaded parser's installed resource headers instead of the target GCC toolchain", function()
    local toolchain = native.discover_toolchain()
    t.assert_true(toolchain.ok, toolchain.reason)
    local directory = native.compiler_resource_dir(toolchain)
    t.assert_true(directory ~= nil, "loaded compiler resource headers unavailable")
    local args = assert(native.semantic_parse_args({ "clang++", "--gcc-toolchain=/target-toolchain", "input.cpp" }, toolchain))
    t.assert_eq(args[1], "-resource-dir=" .. directory)
    t.assert_true(vim.tbl_contains(args, "--gcc-toolchain=/target-toolchain"))
  end)

  t.it("preserves an explicit resource directory in both compiler argument forms", function()
    for _, flags in ipairs({ { "-resource-dir=/explicit" }, { "-resource-dir", "/explicit" } }) do
      local argv = { "clang++", "--gcc-toolchain=/target-toolchain" }
      vim.list_extend(argv, flags)
      argv[#argv + 1] = "input.cpp"
      local args = assert(native.semantic_parse_args(argv, { clang_version = "unknown" }))
      t.assert_eq(args[1], argv[2])
      t.assert_eq(args[2], flags[1])
      if #flags == 2 then t.assert_eq(args[3], flags[2]) end
    end
  end)

  t.it("reports missing loaded compiler resources instead of guessing a foreign builtin set", function()
    local args, reason = native.semantic_parse_args({ "clang++", "--gcc-toolchain=/target-toolchain", "input.cpp" }, {
      clang_version = "unknown",
    })
    t.assert_nil(args)
    t.assert_eq(reason, "compiler-resource-dir-unavailable")
  end)
end)
