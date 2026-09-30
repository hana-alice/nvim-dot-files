local t = require("tests.harness")
t.bootstrap()

local function fixture(frozen, callback)
  local root = vim.fs.normalize(vim.fn.tempname()) .. "_shader_routing"
  vim.fn.mkdir(root, "p")
  local function write(path, value)
    vim.fn.writefile({ vim.json.encode(value) }, path)
    return vim.fn.sha256(table.concat(vim.fn.readfile(path, "b"), "\n"))
  end
  local function read(path)
    local file = io.open(path, "rb")
    if not file then return nil end
    local value = file:read("*a"); file:close(); return value
  end
  local function row(name, route)
    return { file = root .. "/" .. name, directory = root,
      arguments = { "clang++", "-x", "c++-header", root .. "/" .. name },
      nvim_ue_background_route = route }
  end
  local originals = { row("real.cpp"), row("native.usf"), row("donor.ush", "shader-compatibility") }
  local ctx = { engine_root = root, project_root = root,
    paths = { active_cdb = root .. "/active.json", semantic_cdb = root .. "/compile_commands.json" } }
  write(ctx.paths.active_cdb, originals)
  local artifact = { generation_id = "shader-route", background_cdb_path = root .. "/phase.json" }
  local candidate = vim.deepcopy(originals)
  if frozen then
    candidate[1].file = root .. "/SuperUnity.Batch.cpp"
    candidate[1].nvim_ue_batch_receipt = root .. "/receipt.json"
    write(candidate[1].nvim_ue_batch_receipt, { schema = 2, original_entries = { originals[1] },
      candidate = { file = candidate[1].file, directory = candidate[1].directory,
        arguments = candidate[1].arguments } })
    candidate[1].nvim_ue_batch_receipt_sha256 = vim.fn.sha256(read(candidate[1].nvim_ue_batch_receipt))
    artifact.semantic_cdb_path = root .. "/originals.json"
    write(artifact.semantic_cdb_path, originals)
    artifact.semantic_cdb_hash = vim.fn.sha256(read(artifact.semantic_cdb_path))
  end
  write(artifact.background_cdb_path, candidate)
  artifact.background_cdb_hash = vim.fn.sha256(read(artifact.background_cdb_path))
  local index = {
    base_compile_commands_path = function() return ctx.paths.active_cdb end,
    normalize_cdb_file = function(entry) return vim.fs.normalize(entry.file) end,
  }
  require("ue.index._publish")(index, {
    RT = {}, h = { file_signature = function(path)
      local stat = path and vim.uv.fs_stat(path)
      return stat and { stat.size, stat.mtime.sec, stat.mtime.nsec }
    end }, deps = { read_all = read, write_all = function(path, value)
      local file = assert(io.open(path, "wb")); file:write(value); file:close(); return true
    end },
  })
  local ok, err = pcall(callback, index, ctx, { index_artifacts = { full = artifact } },
    { generation_id = "shader-route", cdb_digest = "fixture-digest" }, read, artifact)
  vim.fn.delete(root, "rf")
  if not ok then error(err) end
end

t.describe("compiler-owned shader compatibility routing", function()
  t.it("both phase generators carry only sealed exact donor identities and retain changed commands", function()
    local root = vim.fs.normalize(vim.fn.tempname()) .. "_shader_phase"
    vim.fn.mkdir(root, "p")
    local function write(path, value) vim.fn.writefile({ vim.json.encode(value) }, path) end
    local tools = vim.fn.stdpath("config") .. "/tools/"
    local python = vim.fn.exepath("python")
    if python == "" then python = vim.fn.exepath("python3") end
    t.assert_true(python ~= "", "Python is required for CDB generation")
    local function run(script, ...)
      local command = { python, "-B", "-I", tools .. script }
      vim.list_extend(command, { ... })
      local result = vim.system(command, { text = true }):wait()
      t.assert_eq(result.code, 0, result.stderr or result.stdout)
    end
    local input = root .. "/input.json"
    local native = { directory = root, file = root .. "/native.usf",
      arguments = { "clang++", "-x", "c++-header", root .. "/native.usf" } }
    local entries, added = require("ue.cdb.shaders").augment_table(
      { native }, { native.file, root .. "/donor.ush" }, {})
    for _, entry in ipairs(entries) do vim.fn.writefile({ "float ShaderValue;" }, entry.file) end
    write(input, entries)
    require("ue.cdb.unity_origin").write(input, require("ue.cdb.unity_origin").finalize({}, entries, added))
    local pending = root .. "/pending.json"
    local ok, err = pcall(function()
      run("cdb_unity_receipt.py", "begin", input, pending)
      run("cdb_unity_receipt.py", "seal", input, pending)
      for _, changed in ipairs({ false, true }) do
        local current = vim.deepcopy(entries)
        if changed then table.insert(current[2].arguments, 2, "-DEXPLICIT_SHADER_CONTEXT=1") end
        write(input, current)
        for _, phase in ipairs({ "full", "current" }) do
          local output, marker = root .. "/" .. phase .. ".json", root .. "/" .. phase .. ".idx"
          local common = { "--background-output", output, "--unity-receipt", input .. ".unity-receipt.json" }
          if phase == "full" then
            run("build_full_cdb.py", input, root .. "/active.json", "--idx-output", marker, unpack(common))
          else
            run("build_clangd_index.py", input, "--output", marker, unpack(common))
          end
          local rows = vim.json.decode(table.concat(vim.fn.readfile(output), "\n"))
          t.assert_eq(#rows, 2, "phase semantic coverage must retain both commands")
          local routed = 0
          for _, entry in ipairs(rows) do
            if entry.nvim_ue_background_route then
              routed = routed + 1
              t.assert_eq(entry.file, current[2].file, "pre-existing native shader must never be routed by suffix")
            end
          end
          t.assert_eq(routed, changed and 0 or 1)
          local counts = vim.json.decode(table.concat(vim.fn.readfile(marker), "\n"))
          t.assert_eq(counts.native_background_entry_count, changed and 2 or 1)
        end
      end
    end)
    vim.fn.delete(root, "rf")
    if not ok then error(err) end
  end)

  t.it("keeps native shader commands and removes only proven donor tasks from the background view", function()
    fixture(false, function(index, ctx, state, generation, read, artifact)
      local ok, report = index.publish_semantic_cdb(ctx, state, generation)
      t.assert_true(ok)
      local published = vim.json.decode(read(ctx.paths.semantic_cdb))
      t.assert_eq(#published, 2)
      t.assert_match(published[2].file, "native%.usf$")
      t.assert_eq(report.shader_compatibility_count, 1)
      t.assert_eq(#vim.json.decode(read(ctx.paths.active_cdb)), 3, "active exact commands must retain shader compatibility")
      t.assert_eq(#vim.json.decode(read(artifact.background_cdb_path)), 3, "phase coverage evidence remains complete")
      local reused, second = index.publish_semantic_cdb(ctx, state, generation)
      t.assert_true(reused); t.assert_false(second.changed)
      t.assert_eq(second.shader_compatibility_count, 1)
    end)
  end)

  t.it("applies identical routing to guarded frozen and unguarded original databases", function()
    fixture(true, function(index, ctx, state, generation, read, artifact)
      t.assert_true(index.publish_semantic_cdb(ctx, state, generation))
      local info = vim.json.decode(read(vim.fs.dirname(ctx.paths.semantic_cdb) .. "/batches.json"))
      t.assert_eq(#vim.json.decode(read(info.original_cdb)), 2)
      t.assert_eq(#vim.json.decode(read(info.verified_cdb)), 2)
      t.assert_eq(#vim.json.decode(read(artifact.semantic_cdb_path)), 3, "native semantic source retains full commands")
      t.assert_eq(info.original_sha256, vim.fn.sha256(read(info.original_cdb)))
      t.assert_eq(info.verified_sha256, vim.fn.sha256(read(info.verified_cdb)))
    end)
  end)
end)
