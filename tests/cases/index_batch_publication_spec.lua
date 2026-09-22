local t = require("tests.harness")
t.bootstrap()

local function fixture(callback)
  local root = vim.fs.normalize(vim.fn.tempname()) .. "_batch_publication"
  vim.fn.mkdir(root, "p")
  local function read(path)
    local file = io.open(path, "rb")
    if not file then return nil end
    local value = file:read("*a"); file:close(); return value
  end
  local function write(path, value)
    local file = assert(io.open(path, "wb")); file:write(value); file:close(); return true
  end
  local function json(path, value)
    write(path, vim.json.encode(value)); return vim.fn.sha256(read(path))
  end
  local function row(name)
    return { directory = root, file = root .. "/" .. name .. ".cpp",
      arguments = { "clang++", "-c", root .. "/" .. name .. ".cpp" } }
  end
  local originals = { row("A"), row("B"), row("C") }
  local ctx = { engine_root = root, project_root = root,
    paths = { active_cdb = root .. "/active.json", semantic_cdb = root .. "/compile_commands.json" } }
  json(ctx.paths.active_cdb, originals)
  local generation = { generation_id = "test", cdb_digest = "test-digest" }
  local state = { index_artifacts = {} }
  local function phase(name, entries, semantic)
    local artifact = { generation_id = "test", background_cdb_path = root .. "/" .. name .. ".json" }
    artifact.background_cdb_hash = json(artifact.background_cdb_path, entries)
    if semantic then
      artifact.semantic_cdb_path = root .. "/" .. name .. "-originals.json"
      artifact.semantic_cdb_hash = json(artifact.semantic_cdb_path, semantic)
    end
    state.index_artifacts[name] = artifact
  end
  local function batch(name, members)
    local candidate = row(name)
    local path = root .. "/" .. name .. "-receipt.json"
    local digest = json(path, { schema = 2, candidate = candidate, original_entries = members })
    candidate.nvim_ue_batch_receipt = path
    candidate.nvim_ue_batch_receipt_sha256 = digest
    return candidate
  end
  local index = { base_compile_commands_path = function() return ctx.paths.active_cdb end,
    normalize_cdb_file = function(entry) return vim.fs.normalize(entry.file) end }
  require("ue.index._publish")(index, { RT = {}, h = { file_signature = function(path)
    local stat = path and vim.uv.fs_stat(path)
    return stat and { stat.size, stat.mtime.sec, stat.mtime.nsec }
  end }, deps = { read_all = read, write_all = write } })
  local function publish() return index.publish_semantic_cdb(ctx, state, generation) end
  local ok, err = pcall(callback, { originals = originals, ctx = ctx, phase = phase, batch = batch,
    publish = publish, read = read, json = json, root = root })
  vim.fn.delete(root, "rf")
  if not ok then error(err) end
end

t.describe("exactly-once batch publication", function()
  t.it("keeps published bytes and mtime when current phase only reorders unique unchanged files", function()
    fixture(function(f)
      f.phase("full", f.originals)
      f.phase("current", { f.originals[2] })
      local ok, initial = f.publish(); t.assert_true(ok); t.assert_true(initial.changed)
      local first = vim.json.decode(f.read(f.ctx.paths.semantic_cdb))
      t.assert_eq(first[1].file, f.originals[2].file, "a new publication still prioritizes the current file")
      assert(vim.uv.fs_utime(f.ctx.paths.semantic_cdb, 1700000000, 1700000000))
      local before, stamp = f.read(f.ctx.paths.semantic_cdb), vim.uv.fs_stat(f.ctx.paths.semantic_cdb).mtime
      f.phase("current", { f.originals[1] })
      local reused, report = f.publish(); t.assert_true(reused); t.assert_false(report.changed)
      t.assert_eq(f.read(f.ctx.paths.semantic_cdb), before, "queue order alone must not rewrite a running index")
      t.assert_true(vim.deep_equal(vim.uv.fs_stat(f.ctx.paths.semantic_cdb).mtime, stamp))
    end)
  end)

  t.it("keeps frozen commands and activation metadata unchanged for unique-file phase permutations", function()
    fixture(function(f)
      local candidate = f.batch("AB", { f.originals[1], f.originals[2] })
      f.phase("current", { candidate }, { f.originals[1], f.originals[2] })
      f.phase("hot", { candidate }, { f.originals[1], f.originals[2] })
      f.phase("full", f.originals)
      t.assert_true(f.publish())
      local paths = { f.ctx.paths.semantic_cdb, f.root .. "/verified/compile_commands.json",
        f.root .. "/batches.json" }
      local retained = {}
      for _, path in ipairs(paths) do
        assert(vim.uv.fs_utime(path, 1700000000, 1700000000))
        retained[path] = { bytes = f.read(path), mtime = vim.uv.fs_stat(path).mtime }
      end
      f.phase("current", { f.originals[3] })
      local ok, report = f.publish(); t.assert_true(ok); t.assert_false(report.changed)
      for _, path in ipairs(paths) do
        t.assert_eq(f.read(path), retained[path].bytes)
        t.assert_true(vim.deep_equal(vim.uv.fs_stat(path).mtime, retained[path].mtime))
      end
    end)
  end)

  for _, change in ipairs({ "argv", "output", "added", "removed" }) do
    t.it("publishes actual " .. change .. " changes while retaining current-file priority", function()
      fixture(function(f)
        f.phase("full", f.originals)
        t.assert_true(f.publish())
        local revised = vim.deepcopy(f.originals)
        if change == "argv" then table.insert(revised[2].arguments, 2, "-DNEW_CONTEXT=1")
        elseif change == "output" then revised[2].output = "changed.o"
        elseif change == "added" then
          local added = vim.deepcopy(revised[1]); added.file = f.root .. "/D.cpp"
          added.arguments[#added.arguments] = added.file
          revised[#revised + 1] = added
        else table.remove(revised, 3) end
        f.phase("full", revised)
        f.phase("current", { revised[2] })
        local ok, report = f.publish(); t.assert_true(ok); t.assert_true(report.changed)
        local result = vim.json.decode(f.read(f.ctx.paths.semantic_cdb))
        t.assert_eq(#result, #revised)
        t.assert_true(vim.deep_equal(result[1], revised[2]), "real changes use the new priority order")
      end)
    end)
  end

  for _, alias in ipairs({ false, true }) do
    t.it("preserves order-sensitive same-file variants" .. (alias and " across normalized aliases" or ""), function()
      fixture(function(f)
        local variant = vim.deepcopy(f.originals[1])
        table.insert(variant.arguments, 2, "-DSECOND_CONTEXT=1")
        if alias then variant.file = "./A.cpp" end
        f.phase("full", { f.originals[1], variant, f.originals[2] })
        f.phase("current", { f.originals[1] })
        t.assert_true(f.publish())
        local before = f.read(f.ctx.paths.semantic_cdb)
        f.phase("current", { variant })
        local ok, report = f.publish(); t.assert_true(ok); t.assert_true(report.changed)
        t.assert_true(f.read(f.ctx.paths.semantic_cdb) ~= before)
        t.assert_true(vim.deep_equal(vim.json.decode(f.read(f.ctx.paths.semantic_cdb))[1], variant))
      end)
    end)
  end

  t.it("combines current and hot batches with full originals without indexing their members twice", function()
    fixture(function(f)
      local candidate = f.batch("AB", { f.originals[1], f.originals[2] })
      f.phase("current", { candidate }, { f.originals[1], f.originals[2] })
      f.phase("hot", { candidate }, { f.originals[1], f.originals[2] })
      f.phase("full", f.originals)
      local ok, report = f.publish(); t.assert_true(ok, report)
      t.assert_true(vim.deep_equal(vim.json.decode(f.read(f.ctx.paths.semantic_cdb)), f.originals))
      local frozen = vim.json.decode(f.read(f.root .. "/verified/compile_commands.json"))
      t.assert_eq(#frozen, 2, "batch AB replaces exactly A and B")
      t.assert_eq(frozen[1].file, candidate.file)
      t.assert_true(vim.deep_equal(frozen[2], f.originals[3]))
      local before = f.read(f.root .. "/batches.json")
      local reused, second = f.publish(); t.assert_true(reused); t.assert_false(second.changed)
      t.assert_eq(f.read(f.root .. "/batches.json"), before)
    end)
  end)

  t.it("retains a different command for the same original file and complete semantic fallback coverage", function()
    fixture(function(f)
      local variant = vim.deepcopy(f.originals[1])
      table.insert(variant.arguments, 2, "-DSECOND_CONTEXT=1")
      local semantic = { f.originals[1], f.originals[2], variant, f.originals[3] }
      f.phase("current", { f.batch("AB", { f.originals[1], f.originals[2] }) }, semantic)
      local ok, report = f.publish(); t.assert_true(ok, report)
      local original = vim.json.decode(f.read(f.ctx.paths.semantic_cdb))
      t.assert_true(vim.deep_equal(original, semantic))
      local frozen = vim.json.decode(f.read(f.root .. "/verified/compile_commands.json"))
      t.assert_eq(#frozen, 3)
      t.assert_true(vim.deep_equal(frozen[2], variant), "same filename cannot consume a different argv")
      t.assert_true(vim.deep_equal(frozen[3], f.originals[3]), "unreplaced semantic originals retain coverage")
    end)
  end)

  for _, kind in ipairs({ "overlap", "changed-command", "changed-output", "missing-receipt", "duplicate-member",
    "changed-candidate", "changed-receipt-hash", "malformed-member" }) do
    t.it("rejects " .. kind .. " before replacing a valid publication", function()
      fixture(function(f)
        f.phase("full", f.originals)
        t.assert_true(f.publish())
        local before = f.read(f.ctx.paths.semantic_cdb)
        local members = { vim.deepcopy(f.originals[1]), f.originals[2] }
        if kind == "changed-command" then table.insert(members[1].arguments, 2, "-DDIFFERENT=1") end
        if kind == "changed-output" then members[1].output = "other.o" end
        if kind == "duplicate-member" then members = { f.originals[1], f.originals[1] } end
        if kind == "malformed-member" then members = { "not a command" } end
        local candidate = f.batch("AB", members)
        if kind == "missing-receipt" then vim.fn.delete(candidate.nvim_ue_batch_receipt) end
        if kind == "changed-candidate" then table.insert(candidate.arguments, 2, "-DUNPROVEN=1") end
        if kind == "changed-receipt-hash" then candidate.nvim_ue_batch_receipt_sha256 = "wrong" end
        f.phase("current", { candidate }, { f.originals[1], f.originals[2] })
        if kind == "overlap" then
          f.phase("hot", { f.batch("BC", { f.originals[2], f.originals[3] }) }, { f.originals[2], f.originals[3] })
        end
        local ok = f.publish(); t.assert_false(ok, kind)
        t.assert_eq(f.read(f.ctx.paths.semantic_cdb), before)
        t.assert_nil(f.read(f.root .. "/batches.json"))
      end)
    end)
  end

  t.it("activation rejects duplicate coverage and checks complete command identity without native execution", function()
    local python = vim.fn.exepath("python")
    if python == "" then python = vim.fn.exepath("python3") end
    t.assert_true(python ~= "")
    local code = [=[
import copy, json, sys
sys.dont_write_bytecode = True
sys.path.insert(0, sys.argv[1])
from clangd_batch_activation import _coverage
def row(name):
    return dict(directory='C:/fixture', file='C:/fixture/'+name+'.cpp', arguments=['clang++', '-c', name+'.cpp'])
a, b, c, ab, bc = map(row, ['A', 'B', 'C', 'AB', 'BC'])
receipt = dict(candidate=ab, original_entries=[a, b])
def check(original, frozen, receipts):
    _coverage(json.dumps(original), json.dumps(frozen), receipts)
check([a,b,c], [ab,c], [receipt])
failures = []
cases = [
    ('batch-plus-original', [a,b,c], [ab,a,c], [receipt]),
    ('repeated-batch', [a,b,c], [ab,ab,c], [receipt]),
    ('overlapping-batches', [a,b,c], [ab,bc], [receipt, dict(candidate=bc, original_entries=[b,c])]),
    ('duplicate-receipt-member', [a,c], [ab,c], [dict(candidate=ab, original_entries=[a,a])]),
    ('duplicate-original', [a,a,c], [a,c], []),
    ('changed-output', [dict(a, output='first.o'),b,c], [ab,c], [receipt]),
]
for name, original, frozen, receipts in cases:
    try: check(original, frozen, receipts)
    except ValueError: pass
    else: failures.append(name)
assert not failures, 'accepted invalid coverage: '+', '.join(failures)
variant = copy.deepcopy(a)
variant['arguments'].insert(1, '-DSECOND_CONTEXT=1')
check([a,variant,b,c], [ab,variant,c], [receipt])
print('exactly-once coverage passed')
]=]
    local result = vim.system({ python, "-B", "-I", "-c", code, vim.fn.stdpath("config") .. "/tools" },
      { text = true }):wait()
    t.assert_eq(result.code, 0, result.stderr)
  end)
end)
