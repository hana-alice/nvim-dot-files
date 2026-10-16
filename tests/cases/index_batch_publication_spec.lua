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
  for _, original in ipairs(originals) do
    local member = original.file .. ".member.cpp"
    write(member, "int value = 1;\r\n")
    write(original.file, '#include "' .. member .. '"\r\n')
  end
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
  local function tier1(name, members)
    local candidate = row(name)
    candidate.nvim_ue_members = {}
    local inputs, body = {}, "// Tier 1 fixture\r\n"
    for _, original in ipairs(members) do
      local member = original.file .. ".member.cpp"
      for _, input in ipairs({ original.file, member }) do
        inputs[#inputs + 1] = { path = input, sha256 = vim.fn.sha256(assert(read(input))) }
      end
      body = body .. '#include "' .. member .. '"\r\n'
    end
    write(candidate.file, body)
    local path = root .. "/" .. name .. "-tier1-receipt.json"
    local receipt = { schema = 1, tier = 1, reusable = true, accepted = true,
      gates = { compile_success = true, main_shards_complete = true, members_equal = true },
      candidate = vim.deepcopy(candidate), candidate_sha256 = vim.fn.sha256(body),
      inputs = inputs, original_entries = members }
    local digest = json(path, receipt)
    candidate.nvim_ue_tier1_receipt = path
    candidate.nvim_ue_tier1_receipt_sha256 = digest
    return candidate, receipt
  end
  local index = { base_compile_commands_path = function() return ctx.paths.active_cdb end,
    normalize_cdb_file = function(entry) return vim.fs.normalize(entry.file) end }
  require("ue.index._publish")(index, { RT = {}, h = { file_signature = function(path)
    local stat = path and vim.uv.fs_stat(path)
    return stat and { stat.size, stat.mtime.sec, stat.mtime.nsec }
  end }, deps = { read_all = read, write_all = write } })
  local function publish() return index.publish_semantic_cdb(ctx, state, generation) end
  local ok, err = pcall(callback, { originals = originals, ctx = ctx, phase = phase, batch = batch,
    publish = publish, read = read, write = write, json = json, root = root, index = index, state = state, tier1 = tier1 })
  vim.fn.delete(root, "rf")
  if not ok then error(err) end
end

t.describe("exactly-once batch publication", function()
  t.it("same-generation ordinary append preflight preserves bytes until the barrier releases", function()
    fixture(function(f)
      f.phase("current", { f.originals[1] })
      t.assert_true(f.publish())
      f.state.index_selection = { generation_id = "test" }
      f.phase("full", f.originals)
      local before = f.read(f.ctx.paths.semantic_cdb)
      local stamp = vim.uv.fs_stat(f.ctx.paths.semantic_cdb).mtime
      f.index._defer_append = true
      local ok, report = f.publish(); t.assert_true(ok); t.assert_true(report.deferred)
      t.assert_eq(f.read(f.ctx.paths.semantic_cdb), before)
      t.assert_true(vim.deep_equal(vim.uv.fs_stat(f.ctx.paths.semantic_cdb).mtime, stamp))
      f.index._defer_append = false
      local published, final = f.publish(); t.assert_true(published); t.assert_true(final.changed)
      t.assert_eq(#vim.json.decode(f.read(f.ctx.paths.semantic_cdb)), 3)
    end)
  end)

  for _, bypass in ipairs({ "generation", "frozen" }) do
    t.it("append preflight bypasses " .. bypass .. " without changing its publication boundary", function()
      fixture(function(f)
        f.phase("current", { f.originals[3] })
        t.assert_true(f.publish())
        f.state.index_selection = { generation_id = bypass == "generation" and "older" or "test" }
        if bypass == "frozen" then
          local candidate = f.batch("AB", { f.originals[1], f.originals[2] })
          f.phase("full", { candidate, f.originals[3] }, f.originals)
        else
          f.phase("full", f.originals)
        end
        f.index._defer_append = true
        local ok, report = f.publish(); t.assert_true(ok); t.assert_true(report.deferred ~= true)
        t.assert_eq(#vim.json.decode(f.read(f.ctx.paths.semantic_cdb)), 1, "bypass preflight is read-only too")
        f.index._defer_append = false
        ok, report = f.publish(); t.assert_true(ok)
        t.assert_true(report.changed)
        t.assert_eq(#vim.json.decode(f.read(f.ctx.paths.semantic_cdb)), 3)
        if bypass == "frozen" then
          t.assert_false(report.ordinary)
          t.assert_true(vim.uv.fs_stat(f.root .. "/batches.json") ~= nil)
        end
      end)
    end)
  end

  t.it("only unchanged unique-file supersets authorize ordinary same-process reload", function()
    fixture(function(f)
      f.phase("current", { f.originals[1] })
      local ok, first = f.publish(); t.assert_true(ok)
      t.assert_false(first.original_append_only)
      f.phase("hot", { f.originals[2] })
      local hot_ok, hot = f.publish(); t.assert_true(hot_ok)
      t.assert_true(hot.original_append_only)
      f.phase("full", f.originals)
      local full_ok, full = f.publish(); t.assert_true(full_ok)
      t.assert_true(full.original_append_only)
      local cached_ok, cached = f.publish(); t.assert_true(cached_ok)
      t.assert_false(cached.changed)
      t.assert_true(cached.original_append_only ~= true)
    end)
  end)

  for _, change in ipairs({ "argv", "directory", "output", "removed", "variant" }) do
    t.it("refuses same-process append classification for " .. change, function()
      fixture(function(f)
        f.phase("full", { f.originals[1], f.originals[2] })
        t.assert_true(f.publish())
        local rows = vim.deepcopy(f.originals)
        if change == "argv" then table.insert(rows[1].arguments, 2, "-DCHANGED=1")
        elseif change == "directory" then rows[1].directory = f.root .. "/other"
        elseif change == "output" then rows[1].output = "other.o"
        elseif change == "removed" then table.remove(rows, 1)
        else
          local variant = vim.deepcopy(rows[1]); table.insert(variant.arguments, 2, "-DVARIANT=1")
          rows[#rows + 1] = variant
        end
        f.phase("full", rows)
        local ok, result = f.publish(); t.assert_true(ok)
        t.assert_false(result.original_append_only)
      end)
    end)
  end

  t.it("receipt-backed growth retains the frozen activation boundary", function()
    fixture(function(f)
      f.phase("current", { f.originals[3] })
      t.assert_true(f.publish())
      local candidate = f.batch("AB", { f.originals[1], f.originals[2] })
      f.phase("full", { candidate, f.originals[3] }, f.originals)
      local ok, result = f.publish(); t.assert_true(ok)
      t.assert_true(result.original_changed)
      t.assert_false(result.original_append_only)
    end)
  end)

  t.it("distinguishes original command changes from frozen-only publication and cached reuse", function()
    fixture(function(f)
      f.phase("full", f.originals)
      local ok, initial = f.publish(); t.assert_true(ok); t.assert_true(initial.original_changed)
      local candidate = f.batch("AB", { f.originals[1], f.originals[2] })
      f.phase("full", { candidate, f.originals[3] }, f.originals)
      local published, frozen = f.publish(); t.assert_true(published)
      t.assert_true(frozen.changed); t.assert_false(frozen.original_changed)
      local reused, cached = f.publish(); t.assert_true(reused)
      t.assert_false(cached.changed); t.assert_false(cached.original_changed)
      local originals = vim.deepcopy(f.originals)
      table.insert(originals[3].arguments, 2, "-DCHANGED=1")
      f.phase("full", { candidate, originals[3] }, originals)
      local changed, report = f.publish(); t.assert_true(changed)
      t.assert_true(report.changed); t.assert_true(report.original_changed)
    end)
  end)

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

t.describe("privately qualified live Tier 1 publication", function()
  t.it("publishes Tier 1 into live CDB without frozen artifacts or unknown clangd fields", function()
    fixture(function(f)
      local candidate = f.tier1("AB", { f.originals[1], f.originals[2] })
      f.phase("full", { candidate, f.originals[3] }, f.originals)
      local ok, report = f.publish(); t.assert_true(ok, report)
      local published = vim.json.decode(f.read(f.ctx.paths.semantic_cdb))
      t.assert_eq(#published, 2)
      t.assert_eq(published[1].file, candidate.file)
      t.assert_nil(published[1].nvim_ue_tier1_receipt)
      t.assert_nil(published[1].nvim_ue_members)
      t.assert_true(report.ordinary)
      t.assert_eq(#report.tier1_fallbacks, 0)
      t.assert_nil(f.read(f.root .. "/verified/compile_commands.json"))
      t.assert_nil(f.read(f.root .. "/batches.json"))
    end)
  end)

  t.it("repeated Tier 1 publication revalidates receipts and preserves bytes and mtime", function()
    fixture(function(f)
      local candidate = f.tier1("AB", { f.originals[1], f.originals[2] })
      f.phase("full", { candidate, f.originals[3] }, f.originals)
      t.assert_true(f.publish())
      assert(vim.uv.fs_utime(f.ctx.paths.semantic_cdb, 1700000000, 1700000000))
      local before, stamp = f.read(f.ctx.paths.semantic_cdb), vim.uv.fs_stat(f.ctx.paths.semantic_cdb).mtime
      local ok, report = f.publish(); t.assert_true(ok, report)
      t.assert_false(report.changed)
      t.assert_false(report.original_changed)
      t.assert_eq(f.read(f.ctx.paths.semantic_cdb), before)
      t.assert_true(vim.deep_equal(vim.uv.fs_stat(f.ctx.paths.semantic_cdb).mtime, stamp))
    end)
  end)

  t.it("receipt tampering cannot bypass verification through the publication cache", function()
    fixture(function(f)
      local candidate, receipt = f.tier1("AB", { f.originals[1], f.originals[2] })
      f.phase("full", { candidate, f.originals[3] }, f.originals)
      t.assert_true(f.publish())
      receipt.accepted = false
      f.json(candidate.nvim_ue_tier1_receipt, receipt)
      local ok, report = f.publish(); t.assert_true(ok, report)
      t.assert_true(report.changed)
      t.assert_eq(report.tier1_fallbacks[1].reason, "tier1-receipt-sha256-mismatch")
      t.assert_true(vim.deep_equal(vim.json.decode(f.read(f.ctx.paths.semantic_cdb)), f.originals))
    end)
  end)

  for _, kind in ipairs({ "member-before-first-publish", "member", "wrapper", "owned-overlay", "missing-input",
    "missing-candidate", "changed-candidate" }) do
    t.it("retains originals when declared Tier 1 content has " .. kind, function()
      fixture(function(f)
        local candidate, receipt = f.tier1("AB", { f.originals[1], f.originals[2] })
        local input = kind == "wrapper" and f.originals[1].file or receipt.inputs[2].path
        if kind == "owned-overlay" then
          input = f.root .. "/owned-overlay.json"
          f.write(input, '{"version":0}\r\n')
          receipt.inputs[#receipt.inputs + 1] = { path = input, sha256 = vim.fn.sha256(f.read(input)) }
          candidate.nvim_ue_tier1_receipt_sha256 = f.json(candidate.nvim_ue_tier1_receipt, receipt)
        elseif kind == "missing-candidate" or kind == "changed-candidate" then input = candidate.file end
        f.phase("full", { candidate, f.originals[3] }, f.originals)
        if kind ~= "member-before-first-publish" then t.assert_true(f.publish()) end
        if kind == "missing-input" or kind == "missing-candidate" then
          t.assert_eq(vim.fn.delete(input), 0)
        else
          local before, stamp = f.read(input), vim.uv.fs_stat(input)
          f.write(input, "!" .. before:sub(2))
          assert(vim.uv.fs_utime(input, stamp.atime.sec, stamp.mtime.sec + stamp.mtime.nsec / 1e9))
          t.assert_eq(vim.uv.fs_stat(input).size, #before)
        end
        local ok, report = f.publish(); t.assert_true(ok, report)
        t.assert_true(vim.deep_equal(vim.json.decode(f.read(f.ctx.paths.semantic_cdb)), f.originals))
        t.assert_eq(#report.tier1_fallbacks, 1)
        t.assert_eq(report.tier1_fallbacks[1].reason,
          (kind == "missing-candidate" or kind == "changed-candidate")
            and "tier1-candidate-content-mismatch" or "tier1-input-content-mismatch")
      end)
    end)
  end

  t.it("a stale full phase cannot restore a batch after current retains changed members", function()
    fixture(function(f)
      local candidate, receipt = f.tier1("AB", { f.originals[1], f.originals[2] })
      f.phase("full", { candidate, f.originals[3] }, f.originals)
      t.assert_true(f.publish())
      f.write(receipt.inputs[2].path, "int value = 2;\r\n")
      f.phase("current", { f.originals[1], f.originals[2] }, { f.originals[1], f.originals[2] })
      local ok, report = f.publish(); t.assert_true(ok, report)
      t.assert_true(vim.deep_equal(vim.json.decode(f.read(f.ctx.paths.semantic_cdb)), f.originals))
      t.assert_eq(report.tier1_fallbacks[1].phase, "full")
      t.assert_eq(report.tier1_fallbacks[1].reason, "tier1-input-content-mismatch")
    end)
  end)

  for _, kind in ipairs({ "missing-inputs", "empty-inputs", "non-list-inputs", "invalid-input-path",
    "invalid-input-hash", "missing-candidate-hash", "invalid-candidate-hash" }) do
    t.it("retains originals when Tier 1 content identity has " .. kind, function()
      fixture(function(f)
        local candidate, receipt = f.tier1("AB", { f.originals[1], f.originals[2] })
        if kind == "missing-inputs" then receipt.inputs = nil
        elseif kind == "empty-inputs" then receipt.inputs = {}
        elseif kind == "non-list-inputs" then receipt.inputs = { invalid = receipt.inputs[1] }
        elseif kind == "invalid-input-path" then receipt.inputs[1].path = ""
        elseif kind == "invalid-input-hash" then receipt.inputs[1].sha256 = "invalid"
        elseif kind == "missing-candidate-hash" then receipt.candidate_sha256 = nil
        elseif kind == "invalid-candidate-hash" then receipt.candidate_sha256 = "invalid" end
        candidate.nvim_ue_tier1_receipt_sha256 = f.json(candidate.nvim_ue_tier1_receipt, receipt)
        f.phase("full", { candidate, f.originals[3] }, f.originals)
        local ok, report = f.publish(); t.assert_true(ok, report)
        t.assert_true(vim.deep_equal(vim.json.decode(f.read(f.ctx.paths.semantic_cdb)), f.originals))
        t.assert_eq(#report.tier1_fallbacks, 1)
      end)
    end)
  end

  t.it("header edits outside receipt inputs preserve accepted Tier 1 publication", function()
    fixture(function(f)
      local candidate = f.tier1("AB", { f.originals[1], f.originals[2] })
      local header = f.root .. "/Header.h"
      f.write(header, "#define HEADER 1\r\n")
      f.phase("full", { candidate, f.originals[3] }, f.originals)
      t.assert_true(f.publish())
      local before = f.read(f.ctx.paths.semantic_cdb)
      f.write(header, "#define HEADER 2\r\n")
      local ok, report = f.publish(); t.assert_true(ok, report)
      t.assert_false(report.changed)
      t.assert_eq(#report.tier1_fallbacks, 0)
      t.assert_eq(f.read(f.ctx.paths.semantic_cdb), before)
    end)
  end)

  for _, kind in ipairs({ "candidate-command", "unaccepted", "missing-gate", "duplicate-original", "missing-original",
    "duplicate-candidate", "missing-semantic" }) do
    t.it("retains authoritative originals when Tier 1 has " .. kind, function()
      fixture(function(f)
        local members = { f.originals[1], f.originals[2] }
        if kind == "duplicate-original" then members = { f.originals[1], f.originals[1] } end
        local candidate, receipt = f.tier1("AB", members)
        if kind == "candidate-command" then table.insert(candidate.arguments, 2, "-DUNPROVEN=1") end
        if kind == "unaccepted" then receipt.accepted = false end
        if kind == "missing-gate" then receipt.gates.main_shards_complete = false end
        candidate.nvim_ue_tier1_receipt_sha256 = f.json(candidate.nvim_ue_tier1_receipt, receipt)
        local semantic = kind == "missing-original" and { f.originals[1], f.originals[3] } or f.originals
        local entries = { candidate, f.originals[3] }
        if kind == "duplicate-candidate" then table.insert(entries, 2, candidate) end
        f.phase("full", entries, kind ~= "missing-semantic" and semantic or nil)
        local ok, report = f.publish(); t.assert_true(ok, report)
        local published = vim.json.decode(f.read(f.ctx.paths.semantic_cdb))
        t.assert_true(vim.deep_equal(published, semantic))
        t.assert_true(#report.tier1_fallbacks > 0)
        t.assert_eq(report.tier1_fallbacks[1].original_source,
          kind == "missing-semantic" and "tier1-receipt-originals" or "phase-semantic-cdb")
        t.assert_nil(f.read(f.root .. "/batches.json"))
      end)
    end)
  end

  t.it("missing semantic and unverifiable Tier 1 receipt retain the prior complete publication", function()
    fixture(function(f)
      f.phase("full", f.originals)
      t.assert_true(f.publish())
      local before = f.read(f.ctx.paths.semantic_cdb)
      local candidate = f.tier1("AB", { f.originals[1], f.originals[2] })
      candidate.nvim_ue_tier1_receipt_sha256 = "tampered"
      f.phase("full", { candidate, f.originals[3] })
      local ok, reason = f.publish(); t.assert_false(ok)
      t.assert_true(reason:find("no verifiable original commands", 1, true) ~= nil)
      t.assert_eq(f.read(f.ctx.paths.semantic_cdb), before)
      t.assert_nil(f.read(f.root .. "/batches.json"))
    end)
  end)

  t.it("full originals and repeated cross-phase candidates cannot revive consumed UBTs", function()
    fixture(function(f)
      local candidate = f.tier1("AB", { f.originals[1], f.originals[2] })
      f.phase("current", { candidate }, { f.originals[1], f.originals[2] })
      f.phase("hot", { candidate }, { f.originals[1], f.originals[2] })
      f.phase("full", f.originals)
      local ok, report = f.publish(); t.assert_true(ok, report)
      local published = vim.json.decode(f.read(f.ctx.paths.semantic_cdb))
      t.assert_eq(#published, 2)
      t.assert_eq(published[1].file, candidate.file)
      t.assert_eq(published[2].file, f.originals[3].file)
      t.assert_eq(#report.tier1_fallbacks, 0)
    end)
  end)

  t.it("overlapping Tier 1 candidates consume each original only once", function()
    fixture(function(f)
      local first = f.tier1("AB", { f.originals[1], f.originals[2] })
      local second = f.tier1("BC", { f.originals[2], f.originals[3] })
      f.phase("current", { first }, { f.originals[1], f.originals[2] })
      f.phase("hot", { second }, { f.originals[2], f.originals[3] })
      f.phase("full", f.originals)
      local ok, report = f.publish(); t.assert_true(ok, report)
      local published = vim.json.decode(f.read(f.ctx.paths.semantic_cdb))
      t.assert_eq(#published, 2)
      t.assert_eq(published[1].file, first.file)
      t.assert_eq(published[2].file, f.originals[3].file)
      t.assert_eq(report.tier1_fallbacks[1].reason, "tier1-original-covered-more-than-once")
    end)
  end)

  t.it("a Tier 1 phase cannot borrow original command authorization from another phase", function()
    fixture(function(f)
      local candidate = f.tier1("AB", { f.originals[1], f.originals[2] })
      f.phase("current", { candidate }, { f.originals[1] })
      f.phase("full", f.originals)
      local ok, report = f.publish(); t.assert_true(ok, report)
      t.assert_true(vim.deep_equal(vim.json.decode(f.read(f.ctx.paths.semantic_cdb)), f.originals))
      t.assert_eq(report.tier1_fallbacks[1].reason, "tier1-phase-original-absent-or-changed")
    end)
  end)

  t.it("Tier 1 live replacement retains different argv variants for an original file", function()
    fixture(function(f)
      local variant = vim.deepcopy(f.originals[1]); table.insert(variant.arguments, 2, "-DVARIANT=1")
      local candidate = f.tier1("AB", { f.originals[1], f.originals[2] })
      local semantic = { f.originals[1], f.originals[2], variant, f.originals[3] }
      f.phase("full", { candidate, variant, f.originals[3] }, semantic)
      local ok, report = f.publish(); t.assert_true(ok, report)
      local published = vim.json.decode(f.read(f.ctx.paths.semantic_cdb))
      t.assert_eq(#published, 3)
      t.assert_eq(published[1].file, candidate.file)
      t.assert_true(vim.deep_equal(published[2], variant))
    end)
  end)

  t.it("mixed strict and Tier 1 phases preserve live coverage and keep strict activation fail closed", function()
    fixture(function(f)
      local strict = f.batch("StrictAB", { f.originals[1], f.originals[2] })
      local live = f.tier1("Tier1AB", { f.originals[1], f.originals[2] })
      f.phase("current", { strict }, { f.originals[1], f.originals[2] })
      f.phase("full", { live, f.originals[3] }, f.originals)
      local ok, report = f.publish(); t.assert_true(ok, report)
      local published = vim.json.decode(f.read(f.ctx.paths.semantic_cdb))
      t.assert_eq(#published, 2)
      t.assert_eq(published[1].file, live.file)
      t.assert_eq(published[2].file, f.originals[3].file)
      local frozen_path = f.root .. "/verified/compile_commands.json"
      local frozen = vim.json.decode(f.read(frozen_path))
      t.assert_eq(#frozen, 2)
      t.assert_eq(frozen[1].file, strict.file)
      t.assert_eq(frozen[2].file, f.originals[3].file)
      local info = vim.json.decode(f.read(f.root .. "/batches.json"))
      t.assert_eq(#info.receipts, 1)
      t.assert_eq(info.receipts[1], strict.nvim_ue_batch_receipt)
      local python = vim.fn.exepath("python")
      if python == "" then python = vim.fn.exepath("python3") end
      t.assert_true(python ~= "")
      local code = [=[
import json, sys
sys.dont_write_bytecode = True
sys.path.insert(0, sys.argv[1])
from clangd_batch_activation import _coverage
from pathlib import Path
original, frozen, receipt = [Path(path).read_text(encoding='utf-8') for path in sys.argv[2:]]
try:
    _coverage(original, frozen, [json.loads(receipt)])
except ValueError:
    print('strict activation coverage correctly rejected mixed live authority')
else:
    raise AssertionError('strict activation consumed Tier 1 live authority without matching originals')
]=]
      local result = vim.system({ python, "-B", "-I", "-c", code, vim.fn.stdpath("config") .. "/tools",
        f.ctx.paths.semantic_cdb, frozen_path, strict.nvim_ue_batch_receipt }, { text = true }):wait()
      t.assert_eq(result.code, 0, result.stderr)
    end)
  end)

  t.it("publishes an actual Python Tier 1 receipt with identical native command identities", function()
    fixture(function(f)
      local python = vim.fn.exepath("python")
      if python == "" then python = vim.fn.exepath("python3") end
      t.assert_true(python ~= "")
      local code = [=[
import json, sys
sys.dont_write_bytecode = True
sys.path.insert(0, sys.argv[1])
from pathlib import Path
from unittest.mock import patch
import cdb_verified_batch as verified
root = Path(sys.argv[2]).resolve()
source = root / 'Source/Runtime/Sample/Private'
source.mkdir(parents=True)
def unit(name):
    member = source / (name + '.cpp')
    member.write_text('int ' + name + '() { return 1; }\n', encoding='utf-8')
    wrapper = root / ('SuperUnity.UBT.' + name + '.cpp')
    wrapper.write_text('// Compiler-authored UBT unity membership; copied into nvim cache.\n'
        + '#include "' + member.as_posix() + '"\n', encoding='utf-8')
    return {'directory': str(root), 'file': str(wrapper),
        'arguments': ['clang++', '-std=c++17', '-c', str(wrapper)],
        'nvim_ue_module_root': 'Source/Runtime/Sample',
        'nvim_ue_members': [verified.portable_member_path(str(member))]}
a, b = unit('alpha'), unit('beta')
c = {'directory': str(root), 'file': str(root / 'C.cpp'),
     'arguments': ['clang++', '-c', str(root / 'C.cpp')]}
entries = [a, b, c]
expected = [path for entry in [a, b] for path in verified._tier1_ubt_members(entry)]
result = {'background_compile_success': True, 'missing_main_shards': [],
          'member_main_shards': expected, 'shards': []}
with patch.object(verified, '_tier1_candidate_index', return_value=result) as indexed:
    output, metrics = verified.accelerate_tier1(entries, root / 'private-proof', sys.executable,
        max_group=8, timeout=1, budget_factor=1)
assert indexed.call_count == 1 and metrics['batch_count'] == 1 and metrics['coverage_complete'], metrics
assert len(output) == 2 and output[0]['nvim_ue_tier1_receipt'], output
(root / 'python-originals.json').write_text(json.dumps(entries), encoding='utf-8')
(root / 'python-background.json').write_text(json.dumps(output), encoding='utf-8')
]=]
      local result = vim.system({ python, "-B", "-I", "-c", code, vim.fn.stdpath("config") .. "/tools", f.root },
        { text = true }):wait()
      t.assert_eq(result.code, 0, result.stderr .. result.stdout)
      local originals = vim.json.decode(f.read(f.root .. "/python-originals.json"))
      local background = vim.json.decode(f.read(f.root .. "/python-background.json"))
      f.json(f.ctx.paths.active_cdb, originals)
      f.phase("full", background, originals)
      local ok, report = f.publish(); t.assert_true(ok, report)
      t.assert_eq(#report.tier1_fallbacks, 0)
      local published = vim.json.decode(f.read(f.ctx.paths.semantic_cdb))
      t.assert_eq(#published, 2)
      for i = 1, 2 do
        t.assert_eq(published[i].directory, background[i].directory)
        t.assert_eq(published[i].file, background[i].file)
        t.assert_true(vim.deep_equal(published[i].arguments, background[i].arguments))
        t.assert_nil(published[i].nvim_ue_tier1_receipt)
      end
      t.assert_nil(f.read(f.root .. "/batches.json"))
      t.assert_nil(f.read(f.root .. "/verified/compile_commands.json"))
      local before = f.read(f.ctx.paths.semantic_cdb)
      local repeated, unchanged = f.publish(); t.assert_true(repeated, unchanged)
      t.assert_false(unchanged.changed)
      t.assert_eq(f.read(f.ctx.paths.semantic_cdb), before)
    end)
  end)
end)
