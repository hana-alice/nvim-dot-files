local t = require("tests.harness")
t.bootstrap()

local function short_path(path)
  local python = vim.fn.exepath("python")
  if python == "" then python = vim.fn.exepath("python3") end
  t.assert_true(python ~= "", "Python required for the native 8.3 path probe")
  local code = [=[
import ctypes, json, sys
buffer = ctypes.create_unicode_buffer(32768)
length = ctypes.windll.kernel32.GetShortPathNameW(sys.argv[1], buffer, len(buffer))
assert 0 < length < len(buffer), ctypes.get_last_error()
print(json.dumps(buffer.value))
]=]
  local result = vim.system({ python, "-B", "-I", "-c", code, path }, { text = true }):wait()
  t.assert_eq(result.code, 0, result.stderr)
  return vim.fs.normalize(vim.json.decode(result.stdout))
end

local short_paths_available
if require("utils.platform").driver().path_sep == "\\" then
  local parent = assert(vim.uv.fs_realpath(vim.fn.fnamemodify(vim.fn.tempname(), ":h")))
  short_paths_available = short_path(parent):lower() ~= vim.fs.normalize(parent):lower()
end

local function fixture(callback, root_path)
  local root = root_path or (vim.fs.normalize(vim.fn.tempname()) .. "_batch_publication")
  vim.fn.mkdir(root, "p")
  -- clangd canonicalizes included files, but preserves CDB spelling for mains.
  -- A short TEMP alias would make this fixture test two different URI identities.
  root = vim.fs.normalize(assert(vim.uv.fs_realpath(root)))
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
  local function original(name)
    local entry = row(name)
    local member = entry.file .. ".member.cpp"
    write(member, "int value = 1;\r\n")
    write(entry.file, '#include "' .. member .. '"\r\n')
    return entry
  end
  local originals = { original("A"), original("B"), original("C") }
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
    normalize_cdb_file = function(entry)
      local fs = require("ue.core.fs")
      local file = fs.norm(entry.file)
      return fs.is_absolute_path(file) and file or fs.join(entry.directory, file)
    end }
  require("ue.index._publish")(index, { RT = {}, h = { file_signature = function(path)
    local stat = path and vim.uv.fs_stat(path)
    return stat and { stat.size, stat.mtime.sec, stat.mtime.nsec }
  end }, deps = { read_all = read, write_all = write } })
  local function publish() return index.publish_semantic_cdb(ctx, state, generation) end
  local ok, err = pcall(callback, { originals = originals, ctx = ctx, phase = phase, batch = batch,
    publish = publish, read = read, write = write, json = json, root = root, index = index, state = state,
    tier1 = tier1, original = original })
  vim.fn.delete(root, "rf")
  if not ok then error(err) end
end

if short_paths_available ~= nil then
  t.describe("publication fixture paths", function()
    if not short_paths_available then
      t.skip("uses physical CDB paths for an explicitly short temporary root",
        "8.3 aliases unavailable", { native = false })
      return
    end
    t.it("uses physical CDB paths for an explicitly short temporary root", function()
      local root = vim.fn.tempname() .. "_batch_publication_short"
      vim.fn.mkdir(root, "p")
      local physical = vim.fs.normalize(assert(vim.uv.fs_realpath(root)))
      local short = short_path(root)
      t.assert_true(short:lower() ~= physical:lower())
      fixture(function(f)
        t.assert_eq(f.root, physical)
        for _, entry in ipairs(f.originals) do
          t.assert_eq(entry.directory, physical)
          t.assert_eq(entry.file, vim.fs.normalize(assert(vim.uv.fs_realpath(entry.file))))
        end
        f.phase("full", f.originals)
        t.assert_true(f.publish())
        t.assert_eq(vim.json.decode(f.read(f.ctx.paths.semantic_cdb))[1].directory, physical)
      end, short)
    end)
  end)
end

local function assert_activation_coverage(f)
  local python = vim.fn.exepath("python")
  if python == "" then python = vim.fn.exepath("python3") end
  t.assert_true(python ~= "")
  local code = [=[
import json, sys
sys.dont_write_bytecode = True
sys.path.insert(0, sys.argv[1])
from clangd_batch_activation import _coverage
from pathlib import Path
info = json.loads(Path(sys.argv[2]).read_text(encoding='utf-8'))
receipts = [json.loads(Path(path).read_text(encoding='utf-8')) for path in info['receipts']]
assert all(receipt['schema'] == 2 for receipt in receipts)
_coverage(Path(info['original_cdb']).read_bytes(), Path(info['verified_cdb']).read_bytes(), receipts)
]=]
  local result = vim.system({ python, "-B", "-I", "-c", code, vim.fn.stdpath("config") .. "/tools",
    f.root .. "/batches.json" }, { text = true }):wait()
  t.assert_eq(result.code, 0, result.stderr)
end

t.describe("published main context migration", function()
  local function own_shard(own, included)
    local function u32(n)
      local bytes = {}
      for i = 1, 4 do bytes[i] = string.char(n % 256); n = math.floor(n / 256) end
      return table.concat(bytes)
    end
    local function chunk(tag, bytes) return tag .. u32(#bytes) .. bytes .. (#bytes % 2 == 1 and "\0" or "") end
    local strings = "\0" .. vim.uri_from_fname(own) .. "\0"
    local srcs = "\0\1" .. string.rep("\1", 8) .. (included and "\1\2" or "\0")
    if included then
      strings = strings .. vim.uri_from_fname(included) .. "\0"
      srcs = srcs .. "\0\2" .. string.rep("\0", 8) .. "\0"
    end
    -- Invalid symbol payload deliberately proves that fallback reads only
    -- metadata/string table/srcs rather than decoding business records.
    local body = "CdIx" .. chunk("meta", u32(20)) .. chunk("stri", u32(0) .. strings)
      .. chunk("symb", "not decoded") .. chunk("refs", "") .. chunk("rela", "") .. chunk("srcs", srcs)
    return "RIFF" .. u32(#body) .. body
  end
  local function shard(f, file, bytes)
    local cache = f.root .. "/.cache/clangd/index"
    vim.fn.mkdir(cache, "p")
    local path = cache .. "/" .. require("ue.index.shard_name").for_path(file)
    f.write(path, bytes or "old shard")
    return path
  end

  t.it("invalidates only the promoted wrapper member and preserves namesakes headers and unchanged mains", function()
    fixture(function(f)
      local wrapper, unchanged = f.originals[1], f.originals[2]
      f.phase("full", { wrapper, unchanged }); t.assert_true(f.publish())
      local exact = { directory = f.root, file = wrapper.file .. ".member.cpp",
        arguments = { "clang++", "-c", "-DCTX_EXACT", wrapper.file .. ".member.cpp" } }
      local target = shard(f, exact.file)
      local namesake = shard(f, f.root .. "/other/" .. vim.fs.basename(exact.file))
      local header = shard(f, f.root .. "/shared.h")
      local retained = shard(f, unchanged.file)
      local retired = shard(f, wrapper.file)
      f.phase("full", { exact, unchanged })
      local ok, report = f.publish(); t.assert_true(ok, report)
      t.assert_true(report.changed); t.assert_true(report.original_changed)
      t.assert_eq(report.context_migrated.count, 1)
      t.assert_eq(report.context_migrated.removed, 1)
      t.assert_eq(report.context_migrated.missing, 0)
      t.assert_eq(#report.context_migrated.errors, 0)
      t.assert_nil(f.read(target))
      for _, path in ipairs({ namesake, header, retained, retired }) do
        t.assert_eq(f.read(path), "old shard", path)
      end
    end)
  end)

  for _, change in ipairs({ "argv", "directory", "output", "command" }) do
    t.it("invalidates an existing main after its " .. change .. " changes", function()
      fixture(function(f)
        local before = f.originals[1]
        f.phase("full", { before }); t.assert_true(f.publish())
        local path = shard(f, before.file)
        local after = vim.deepcopy(before)
        if change == "argv" then table.insert(after.arguments, 2, "-DCTX_EXACT")
        elseif change == "directory" then after.directory = f.root .. "/other"
        elseif change == "output" then after.output = "changed.o"
        else after.arguments = nil; after.command = 'clang++ -DCTX_EXACT -c "' .. after.file .. '"' end
        f.phase("full", { after })
        local ok, report = f.publish(); t.assert_true(ok, report)
        t.assert_eq(report.context_migrated.count, 1)
        t.assert_eq(report.context_migrated.removed, 1)
        t.assert_nil(f.read(path))
      end)
    end)
  end

  t.it("resolves relative CDB files before deriving the exact shard path", function()
    fixture(function(f)
      f.phase("full", { f.originals[1] }); t.assert_true(f.publish())
      local exact = { directory = f.root, file = "./relative.cpp",
        arguments = { "clang++", "-c", "-DCTX_EXACT", "./relative.cpp" } }
      local path = shard(f, f.root .. "/relative.cpp")
      f.phase("full", { exact })
      local ok, report = f.publish(); t.assert_true(ok, report)
      t.assert_eq(report.context_migrated.removed, 1)
      t.assert_nil(f.read(path))
    end)
  end)

  t.it("does not unlink on cached or reordered unchanged publications", function()
    fixture(function(f)
      f.phase("full", f.originals); t.assert_true(f.publish())
      local path = shard(f, f.originals[1].file)
      local ok, cached = f.publish(); t.assert_true(ok)
      t.assert_false(cached.changed)
      t.assert_eq(cached.context_migrated.count, 0)
      t.assert_eq(f.read(path), "old shard")
      f.phase("full", { f.originals[3], f.originals[2], f.originals[1] })
      local reordered, report = f.publish(); t.assert_true(reordered)
      t.assert_false(report.changed)
      t.assert_eq(report.context_migrated.removed, 0)
      t.assert_eq(f.read(path), "old shard")
    end)
  end)

  t.it("uses the published CDB spelling directly without realpath or reading a shard", function()
    fixture(function(f)
      f.phase("full", { f.originals[1] }); t.assert_true(f.publish())
      local after = vim.deepcopy(f.originals[1])
      after.file = after.file:gsub("/A%.cpp$", "/a.cpp")
      local path = shard(f, after.file, "not a RIFF: fast path must not read this")
      table.insert(after.arguments, 2, "-DCTX_EXACT")
      f.phase("full", { after })
      local realpath, system = vim.uv.fs_realpath, vim.system
      vim.uv.fs_realpath = function() error("fast path must not resolve realpath") end
      vim.system = function() error("fast path must not start a shard reader") end
      local called, ok, report = pcall(f.publish)
      vim.uv.fs_realpath, vim.system = realpath, system
      t.assert_true(called, ok); t.assert_true(ok)
      t.assert_eq(report.context_migrated.removed, 1)
      t.assert_eq(report.context_migrated.removed_by_identity, 0)
      t.assert_eq(report.context_migrated.candidates_read, 0)
      t.assert_eq(report.context_migrated.scan_count, 0)
      t.assert_eq(#report.context_migrated.errors, 0)
      t.assert_nil(f.read(path))
    end)
  end)

  t.it("removes differently spelled shards only when their own node identifies the migrated file", function()
    fixture(function(f)
      f.phase("full", { f.originals[1] }); t.assert_true(f.publish())
      local target = f.root .. "/Member.cpp"
      f.write(target, "// migrated source\n")
      local old = shard(f, f.root .. "/member.cpp", own_shard(target))
      vim.fn.mkdir(f.root .. "/other", "p")
      local other = f.root .. "/other/Member.cpp"
      f.write(other, "// namesake source\n")
      local namesake = shard(f, other, own_shard(other))
      local header = f.root .. "/Header.h"
      f.write(header, "// unrelated header\n")
      local disguised = shard(f, f.root .. "/header/member.cpp", own_shard(header, target))
      local namesake_before, header_before = f.read(namesake), f.read(disguised)
      local exact = { directory = f.root, file = target, arguments = { "clang++", "-c", "-DCTX_EXACT", target } }
      f.phase("full", { exact })
      local ok, report = f.publish(); t.assert_true(ok)
      t.assert_eq(report.context_migrated.removed, 0)
      t.assert_eq(report.context_migrated.removed_by_identity, 1)
      t.assert_eq(report.context_migrated.missing, 0)
      t.assert_eq(report.context_migrated.scan_count, 1)
      t.assert_eq(report.context_migrated.candidates_read, 3)
      t.assert_eq(#report.context_migrated.errors, 0)
      t.assert_nil(f.read(old))
      t.assert_eq(f.read(namesake), namesake_before)
      t.assert_eq(f.read(disguised), header_before, "an included zero-digest node does not authorize deletion")
    end)
  end)

  if short_paths_available ~= nil then
    for _, route in ipairs({ "direct", "own-node fallback" }) do
      local name = "migrates short CDB spelling through " .. route
      if not short_paths_available then
        t.skip(name, "8.3 aliases unavailable", { native = false })
      else t.it(name, function()
        fixture(function(f)
          local short = short_path(f.root)
          t.assert_true(short:lower() ~= f.root:lower())
          f.phase("full", { f.originals[1] }); t.assert_true(f.publish())
          local physical, target = f.root .. "/Member.cpp", short .. "/Member.cpp"
          f.write(physical, "// migrated alias\n")
          t.assert_true(require("ue.index.shard_name").for_path(target)
            ~= require("ue.index.shard_name").for_path(physical))
          local old = shard(f, route == "direct" and target or physical, own_shard(physical))
          local exact = { directory = short, file = target, arguments = { "clang++", "-c", target } }
          f.phase("full", { exact })
          local ok, report = f.publish(); t.assert_true(ok, report)
          t.assert_eq(report.context_migrated.count, 1)
          t.assert_eq(report.context_migrated.removed, route == "direct" and 1 or 0)
          t.assert_eq(report.context_migrated.removed_by_identity, route == "direct" and 0 or 1)
          t.assert_eq(report.context_migrated.scan_count, route == "direct" and 0 or 1)
          t.assert_eq(report.context_migrated.missing, 0)
          t.assert_eq(#report.context_migrated.errors, 0)
          t.assert_nil(f.read(old))
          t.assert_eq(f.read(target), "// migrated alias\n")
        end)
      end) end
    end
  end

  t.it("deletes all proven spelling aliases with one scan and never reads unrelated basenames", function()
    fixture(function(f)
      f.phase("full", { f.originals[1] }); t.assert_true(f.publish())
      local target = f.root .. "/Member.cpp"
      f.write(target, "// source\n")
      local first = shard(f, f.root .. "/member.cpp", own_shard(target))
      local second = shard(f, f.root .. "/MEMBER.cpp", own_shard(target))
      local unrelated = shard(f, f.root .. "/unrelated.h", "not a RIFF")
      f.phase("full", { { directory = f.root, file = target, arguments = { "clang++", "-c", target } } })
      local ok, report = f.publish(); t.assert_true(ok)
      t.assert_eq(report.context_migrated.count, 1)
      t.assert_eq(report.context_migrated.removed_by_identity, 2)
      t.assert_eq(report.context_migrated.candidates_read, 2)
      t.assert_eq(report.context_migrated.scan_count, 1)
      t.assert_eq(#report.context_migrated.errors, 0)
      t.assert_nil(f.read(first)); t.assert_nil(f.read(second))
      t.assert_eq(f.read(unrelated), "not a RIFF")
    end)
  end)

  t.it("preserves malformed fallback candidates and reports identity errors without failing publication", function()
    fixture(function(f)
      f.phase("full", { f.originals[1] }); t.assert_true(f.publish())
      local target = f.root .. "/Member.cpp"
      f.write(target, "// source\n")
      local bad = shard(f, f.root .. "/member.cpp", "not a RIFF")
      f.phase("full", { { directory = f.root, file = target, arguments = { "clang++", "-c", target } } })
      local ok, report = f.publish(); t.assert_true(ok); t.assert_true(report.changed)
      t.assert_eq(report.context_migrated.removed_by_identity, 0)
      t.assert_eq(#report.context_migrated.errors, 1)
      t.assert_eq(f.read(bad), "not a RIFF")
    end)
  end)

  t.it("a fallback with no target shard is missing without errors", function()
    fixture(function(f)
      f.phase("full", { f.originals[1] }); t.assert_true(f.publish())
      local target, other = f.root .. "/Member.cpp", f.root .. "/other/Member.cpp"
      vim.fn.mkdir(f.root .. "/other", "p")
      f.write(target, "// new source\n"); f.write(other, "// different source\n")
      local namesake = shard(f, other, own_shard(other))
      local before = f.read(namesake)
      f.phase("full", { { directory = f.root, file = target, arguments = { "clang++", "-c", target } } })
      local ok, report = f.publish(); t.assert_true(ok)
      t.assert_eq(report.context_migrated.missing, 1)
      t.assert_eq(report.context_migrated.removed_by_identity, 0)
      t.assert_eq(#report.context_migrated.errors, 0)
      t.assert_eq(f.read(namesake), before)
    end)
  end)

  t.it("does not unlink original shards for frozen-only publication changes", function()
    fixture(function(f)
      f.phase("full", f.originals); t.assert_true(f.publish())
      local path = shard(f, f.originals[1].file)
      local candidate = f.batch("AB", { f.originals[1], f.originals[2] })
      f.phase("full", { candidate, f.originals[3] }, f.originals)
      local ok, report = f.publish(); t.assert_true(ok)
      t.assert_true(report.changed); t.assert_false(report.original_changed)
      t.assert_eq(report.context_migrated.removed, 0)
      t.assert_eq(f.read(path), "old shard")
    end)
  end)

  t.it("reports unlink failure while retaining the successfully published CDB", function()
    fixture(function(f)
      f.phase("full", { f.originals[1] }); t.assert_true(f.publish())
      local path = shard(f, f.originals[1].file)
      local after = vim.deepcopy(f.originals[1]); table.insert(after.arguments, 2, "-DCTX_EXACT")
      f.phase("full", { after })
      local unlink = vim.uv.fs_unlink
      vim.uv.fs_unlink = function(value, ...)
        if value == path then return nil, "EPERM: injected unlink failure", "EPERM" end
        return unlink(value, ...)
      end
      local called, ok, report = pcall(f.publish)
      vim.uv.fs_unlink = unlink
      t.assert_true(called, ok); t.assert_true(ok, report)
      t.assert_true(report.changed)
      t.assert_eq(report.context_migrated.count, 1)
      t.assert_eq(report.context_migrated.removed, 0)
      t.assert_eq(#report.context_migrated.errors, 1)
      t.assert_match(report.context_migrated.errors[1].error, "EPERM")
      t.assert_eq(f.read(path), "old shard")
      t.assert_true(vim.deep_equal(vim.json.decode(f.read(f.ctx.paths.semantic_cdb)), { after }))
    end)
  end)

  t.it("retains shards when atomic CDB publication fails", function()
    fixture(function(f)
      f.phase("full", { f.originals[1] }); t.assert_true(f.publish())
      local path = shard(f, f.originals[1].file)
      local before = f.read(f.ctx.paths.semantic_cdb)
      local after = vim.deepcopy(f.originals[1]); table.insert(after.arguments, 2, "-DCHANGED")
      f.phase("full", { after })
      local rename = vim.uv.fs_rename
      vim.uv.fs_rename = function(from, to, ...)
        if to == f.ctx.paths.semantic_cdb then return nil, "EPERM: injected rename failure", "EPERM" end
        return rename(from, to, ...)
      end
      local called, ok = pcall(f.publish)
      vim.uv.fs_rename = rename
      t.assert_true(called); t.assert_false(ok)
      t.assert_eq(f.read(path), "old shard")
      t.assert_eq(f.read(f.ctx.paths.semantic_cdb), before)
    end)
  end)

  t.it("counts missing shards for new mains without removing neighbouring cache entries", function()
    fixture(function(f)
      f.phase("full", { f.originals[1] }); t.assert_true(f.publish())
      local header = shard(f, f.root .. "/keep.h")
      f.phase("full", f.originals)
      local ok, report = f.publish(); t.assert_true(ok)
      t.assert_eq(report.context_migrated.count, 2)
      t.assert_eq(report.context_migrated.missing, 2)
      t.assert_eq(report.context_migrated.removed, 0)
      t.assert_eq(#report.context_migrated.errors, 0)
      t.assert_eq(f.read(header), "old shard")
    end)
  end)

  t.it("invalidates committed live migrations even if later frozen metadata publication fails", function()
    fixture(function(f)
      f.phase("full", f.originals); t.assert_true(f.publish())
      local after = vim.deepcopy(f.originals)
      table.insert(after[3].arguments, 2, "-DCTX_EXACT")
      local path = shard(f, after[3].file)
      local candidate = f.batch("AB", { after[1], after[2] })
      f.phase("full", { candidate, after[3] }, after)
      local rename = vim.uv.fs_rename
      vim.uv.fs_rename = function(from, to, ...)
        if to == f.root .. "/batches.json" then return nil, "EPERM: injected metadata failure", "EPERM" end
        return rename(from, to, ...)
      end
      local called, ok = pcall(f.publish)
      vim.uv.fs_rename = rename
      t.assert_true(called); t.assert_false(ok)
      t.assert_nil(f.read(path), "successful live write must invalidate before a later metadata failure")
      t.assert_true(vim.tbl_contains(vim.json.decode(f.read(f.ctx.paths.semantic_cdb))[3].arguments, "-DCTX_EXACT"))
      local retried, report = f.publish(); t.assert_true(retried)
      t.assert_false(report.original_changed)
      t.assert_eq(report.context_migrated.count, 0)
      t.assert_nil(f.read(path))
    end)
  end)

  t.it("defers migration until the append publication barrier releases", function()
    fixture(function(f)
      f.phase("current", { f.originals[1] }); t.assert_true(f.publish())
      f.state.index_selection = { generation_id = "test" }
      local path = shard(f, f.originals[2].file)
      f.phase("full", f.originals)
      f.index._defer_append = true
      local ok, pending = f.publish(); t.assert_true(ok); t.assert_true(pending.deferred)
      t.assert_eq(f.read(path), "old shard")
      f.index._defer_append = nil
      local published, report = f.publish(); t.assert_true(published)
      t.assert_eq(report.context_migrated.removed, 1)
      t.assert_nil(f.read(path))
    end)
  end)

  t.it("routes a ten MiB 831-main migration to the existing publication worker", function()
    fixture(function(f)
      local rows, paths = {}, {}
      local payload = "-DFIXTURE_PAYLOAD=" .. string.rep("x", 12600)
      for i = 1, 831 do
        local file = f.root .. "/Main" .. i .. ".cpp"
        f.write(file, "// isolated size fixture\n")
        rows[i] = { directory = f.root, file = file, arguments = { "clang++", "-c", payload, file } }
        paths[i] = shard(f, file)
      end
      local previous = vim.json.encode(rows)
      t.assert_true(#previous > 10 * 1024 * 1024)
      f.write(f.ctx.paths.semantic_cdb, previous)
      for i = 1, 2 do table.insert(rows[i].arguments, 2, "-DCTX_EXACT") end
      f.phase("full", rows)
      t.assert_true(f.index.publication_needs_worker(f.ctx, f.state,
        f.ctx.paths.active_cdb, f.root .. "/full.json"))
      local started = vim.uv.hrtime()
      local ok, report = f.publish(); t.assert_true(ok)
      local wall = (vim.uv.hrtime() - started) / 1e6
      t.assert_eq(report.context_migrated.count, 2)
      t.assert_eq(report.context_migrated.removed, 2)
      t.assert_eq(#report.context_migrated.errors, 0)
      for i = 3, #paths do t.assert_eq(f.read(paths[i]), "old shard") end
      local repeated, cached = f.publish(); t.assert_true(repeated)
      t.assert_false(cached.changed); t.assert_eq(cached.context_migrated.removed, 0)
      print("context_migration_large=" .. vim.json.encode({ bytes = #previous, rows = #rows,
        publication_ms = wall, context_migrated = report.context_migrated, worker_selected = true,
        measurement = "headless fixture synchronous body; production dispatcher selects worker" }))
    end)
  end)
end)

t.describe("native published context migration", function()
  local python = vim.fn.exepath("python")
  if python == "" then python = vim.fn.exepath("python3") end
  local discovered = require("utils.ue_goto.semantic_sidecar_libclang").discover_toolchain()
  if python == "" or not discovered.ok then
    t.skip("reindexes a former wrapper member as exact_only through publication",
      python == "" and "Python unavailable" or discovered.reason, { native = true })
    return
  end
  t.it("reindexes a former wrapper member as exact_only through publication", function()
    fixture(function(f)
      local driver = require("utils.platform").driver()
      local function native(path) return (path:gsub("/", driver.path_sep)) end
      vim.fn.mkdir(f.root .. "/src", "p")
      local function row(name, define)
        local file = native(f.root .. "/src/" .. name .. ".cpp")
        return { directory = native(f.root), file = file,
          arguments = { "clang++", "-c", define or "-DWRAPPER", file } }
      end
      f.write(f.root .. "/src/a.cpp", "#ifdef CTX_EXACT\nint exact_only() { return 1; }\n#else\nint wrapper_only() { return 2; }\n#endif\n")
      f.write(f.root .. "/src/wrap.cpp", '#include "a.cpp"\n')
      f.write(f.root .. "/src/trig.cpp", "// phase one trigger\n")
      local wrapper, trigger, exact = row("wrap"), row("trig"), row("a", "-DCTX_EXACT")
      f.phase("full", { wrapper, trigger }); t.assert_true(f.publish())
      local shard_name = require("ue.index.shard_name").for_path(exact.file)
      local code = [=[
import json, pathlib, sys
sys.dont_write_bytecode = True
sys.path.insert(0, sys.argv[1])
from clangd_batch_runner import run
from clangd_index_graph import read_shard
root, clangd, phase, name = pathlib.Path(sys.argv[2]), sys.argv[3], sys.argv[4], sys.argv[5]
result = run(root, root / phase, root / 'src/trig.cpp', clangd, timeout=30, jobs=1)
assert result['background_compile_success'], result.get('error_lines')
target = root / '.cache/clangd/index' / name
assert target.exists(), {'expected': str(target), 'actual': result['shards'], 'clangd': clangd}
shard = read_shard(target)
print(json.dumps({'command': shard['command'] is not None,
    'symbols': sorted(s['name'] for s in shard['symbols']),
    'main_indexed': any('Indexed ' in s and 'a.cpp (' in s for s in result['indexing_log_lines']),
    'positive_flags': [v['flags'] for v in shard['sources'].values() if v['digest'] != '0' * 16]}))
]=]
      local function run(phase)
        local result = vim.system({ python, "-B", "-I", "-c", code,
          vim.fn.stdpath("config") .. "/tools", f.root, discovered.clangd_path, phase, shard_name },
          { text = true, timeout = 45000 }):wait()
        t.assert_eq(result.code, 0, (result.stderr or "") .. (result.stdout or ""))
        return vim.json.decode(result.stdout)
      end
      local first = run("p1")
      t.assert_false(first.command)
      t.assert_true(vim.tbl_contains(first.symbols, "wrapper_only"))
      t.assert_false(vim.tbl_contains(first.symbols, "exact_only"))
      for _, flag in ipairs(first.positive_flags) do t.assert_eq(require("bit").band(flag, 1), 0) end
      local before = assert(f.read(f.root .. "/src/a.cpp"))
      f.phase("full", { exact, trigger })
      local ok, report = f.publish(); t.assert_true(ok, report)
      t.assert_eq(report.context_migrated.count, 1)
      t.assert_eq(report.context_migrated.removed, 1)
      t.assert_eq(#report.context_migrated.errors, 0)
      t.assert_nil(f.read(f.root .. "/.cache/clangd/index/" .. shard_name))
      t.assert_eq(f.read(f.root .. "/src/a.cpp"), before)
      f.write(f.root .. "/src/trig.cpp", "// phase two trigger\n")
      local second = run("p2")
      t.assert_true(second.command)
      t.assert_true(second.main_indexed)
      t.assert_true(vim.tbl_contains(second.symbols, "exact_only"))
      t.assert_false(vim.tbl_contains(second.symbols, "wrapper_only"))
      t.assert_true(vim.tbl_contains(second.positive_flags, 1))
      print("context_migration_native=" .. vim.json.encode({ before = first, after = second,
        context_migrated = report.context_migrated }))
    end)
  end)

  if require("utils.platform").driver().path_key("A") ~= require("utils.platform").driver().path_key("a") then
    t.skip("reindexes lower-case wrapper spelling as upper-case exact through own-node fallback",
      "requires a case-insensitive filesystem", { native = false })
    return
  end
  t.it("reindexes lower-case wrapper spelling as upper-case exact through own-node fallback", function()
    fixture(function(f)
      local sep = require("utils.platform").driver().path_sep
      local function native(path) return (path:gsub("/", sep)) end
      vim.fn.mkdir(f.root .. "/src/sub", "p")
      local physical = f.root .. "/src/sub/casefile.cpp"
      f.write(physical, "#ifdef CTX_EXACT\nint exact_only() { return 1; }\n#else\nint wrapper_only() { return 2; }\n#endif\n")
      f.write(f.root .. "/src/wrap.cpp", '#include "sub/casefile.cpp"\n')
      f.write(f.root .. "/src/trig.cpp", "// trigger phase one\n")
      local function row(name, flag)
        local file = native(f.root .. "/src/" .. name .. ".cpp")
        return { directory = native(f.root), file = file, arguments = { "clang++", "-c", flag or "-DWRAPPER", file } }
      end
      local wrapper, trigger, exact = row("wrap"), row("trig"), row("sub/CASEFILE", "-DCTX_EXACT")
      f.phase("full", { wrapper, trigger }); t.assert_true(f.publish())
      local code = [=[
import json, pathlib, sys
sys.dont_write_bytecode = True
sys.path.insert(0, sys.argv[1])
from clangd_batch_runner import run
from clangd_index_graph import read_shard
root, clangd, phase = pathlib.Path(sys.argv[2]), sys.argv[3], sys.argv[4]
result = run(root, root / phase, root / 'src/trig.cpp', clangd, timeout=30, jobs=1)
assert result['background_compile_success'], result.get('error_lines')
cache = root / '.cache/clangd/index'
targets = [p for p in cache.glob('*.idx') if p.name.lower().startswith('casefile.cpp.')]
assert len(targets) == 1, [p.name for p in targets]
shard = read_shard(targets[0])
print(json.dumps({'shard': targets[0].name, 'files': sorted(p.name for p in cache.glob('*.idx')),
    'symbols': sorted(s['name'] for s in shard['symbols']), 'command': shard['command'] is not None,
    'main_indexed': any('Indexed ' in s and 'casefile.cpp (' in s.lower() for s in result['indexing_log_lines'])}))
]=]
      local function run(phase)
        local result = vim.system({ python, "-B", "-I", "-c", code, vim.fn.stdpath("config") .. "/tools",
          f.root, discovered.clangd_path, phase }, { text = true, timeout = 45000 }):wait()
        t.assert_eq(result.code, 0, (result.stderr or "") .. (result.stdout or ""))
        return vim.json.decode(result.stdout)
      end
      local before = run("case-p1")
      t.assert_true(vim.tbl_contains(before.symbols, "wrapper_only"), vim.json.encode(before)); t.assert_false(before.command)
      t.assert_true(before.shard ~= require("ue.index.shard_name").for_path(exact.file))
      f.phase("full", { exact, trigger })
      local ok, report = f.publish(); t.assert_true(ok)
      t.assert_eq(report.context_migrated.removed, 0)
      t.assert_eq(report.context_migrated.removed_by_identity, 1)
      t.assert_eq(#report.context_migrated.errors, 0)
      local after_delete = {}
      for _, path in ipairs(vim.fn.glob(f.root .. "/.cache/clangd/index/*.idx", false, true)) do
        after_delete[#after_delete + 1] = vim.fs.basename(path)
      end
      t.assert_false(vim.tbl_contains(after_delete, before.shard))
      f.write(f.root .. "/src/trig.cpp", "// trigger phase two\n")
      local after = run("case-p2")
      print("context_migration_case_native=" .. vim.json.encode({ before = before,
        after_delete = after_delete, after = after, context_migrated = report.context_migrated }))
      t.assert_true(vim.tbl_contains(after.symbols, "exact_only"), vim.json.encode(after))
      t.assert_false(vim.tbl_contains(after.symbols, "wrapper_only"))
      t.assert_true(after.main_indexed)
      t.assert_eq(after.shard, require("ue.index.shard_name").for_path(exact.file))
    end)
  end)
end)

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

  for _, layout in ipairs({ "same-phase", "tier1-first", "strict-first", "repeated-phases" }) do
    t.it("projects the same Tier 1 baseline into disjoint strict publication: " .. layout, function()
      fixture(function(f)
        local d, exact = f.original("D"), f.original("Exact")
        local variant = vim.deepcopy(f.originals[1]); table.insert(variant.arguments, 2, "-DVARIANT=1")
        local shader = f.original("Shader"); shader.nvim_ue_background_route = "shader-compatibility"
        local originals = { f.originals[1], f.originals[2], f.originals[3], d, exact, variant, shader }
        local live = f.tier1("Tier1AB", { f.originals[1], f.originals[2] })
        local strict = f.batch("StrictCD", { f.originals[3], d })
        f.json(f.ctx.paths.active_cdb, originals)
        if layout == "same-phase" then
          f.phase("full", { live, strict, exact, variant, shader }, originals)
        elseif layout == "repeated-phases" then
          f.phase("current", { live, strict }, originals)
          f.phase("hot", { live, strict }, originals)
          f.phase("full", originals)
        else
          f.phase(layout == "tier1-first" and "current" or "hot", { live }, { f.originals[1], f.originals[2] })
          f.phase(layout == "strict-first" and "current" or "hot", { strict }, { f.originals[3], d })
          f.phase("full", originals)
        end
        local ok, report = f.publish(); t.assert_true(ok, report)
        t.assert_eq(#report.tier1_fallbacks, 0); t.assert_eq(#report.batch_fallbacks, 0)
        t.assert_eq(report.shader_compatibility_count, 1)
        local published = vim.json.decode(f.read(f.ctx.paths.semantic_cdb))
        local frozen = vim.json.decode(f.read(f.root .. "/verified/compile_commands.json"))
        t.assert_eq(#published, 5); t.assert_eq(#frozen, 4)
        local function find(entries, file)
          for _, entry in ipairs(entries) do if entry.file == file then return entry end end
        end
        t.assert_true(vim.deep_equal(find(published, live.file), find(frozen, live.file)))
        t.assert_nil(find(frozen, live.file).nvim_ue_tier1_receipt)
        t.assert_true(vim.deep_equal(find(frozen, exact.file), exact))
        t.assert_true(vim.deep_equal(find(frozen, variant.file), variant), "different argv survives in both views")
        t.assert_nil(find(frozen, f.originals[2].file)); t.assert_nil(find(frozen, f.originals[3].file))
        t.assert_nil(find(frozen, d.file)); t.assert_nil(find(frozen, shader.file))
        local info = vim.json.decode(f.read(f.root .. "/batches.json"))
        t.assert_eq(#info.receipts, 1); t.assert_eq(info.receipts[1], strict.nvim_ue_batch_receipt)
        assert_activation_coverage(f)
        local retained = {}
        for _, path in ipairs({ f.ctx.paths.semantic_cdb, info.verified_cdb, f.root .. "/batches.json" }) do
          assert(vim.uv.fs_utime(path, 1700000000, 1700000000))
          retained[path] = { bytes = f.read(path), mtime = vim.uv.fs_stat(path).mtime }
        end
        local reused, unchanged = f.publish(); t.assert_true(reused, unchanged)
        t.assert_false(unchanged.changed); t.assert_false(unchanged.original_changed)
        for path, before in pairs(retained) do
          t.assert_eq(f.read(path), before.bytes)
          t.assert_true(vim.deep_equal(vim.uv.fs_stat(path).mtime, before.mtime))
        end
      end)
    end)
  end

  for _, overlap in ipairs({ "full", "partial" }) do
    for _, first in ipairs({ "tier1", "strict" }) do
      t.it("defers a whole " .. overlap .. " strict overlap with " .. first .. " first", function()
        fixture(function(f)
          local members = overlap == "full" and { f.originals[1], f.originals[2] }
            or { f.originals[2], f.originals[3] }
          local strict = f.batch("StrictOverlap", members)
          local live = f.tier1("Tier1AB", { f.originals[1], f.originals[2] })
          f.phase("full", { live, f.originals[3] }, f.originals)
          t.assert_true(f.publish())
          local baseline, baseline_stamp = f.read(f.ctx.paths.semantic_cdb), vim.uv.fs_stat(f.ctx.paths.semantic_cdb).mtime
          f.phase(first == "tier1" and "current" or "hot", { live }, { f.originals[1], f.originals[2] })
          f.phase(first == "strict" and "current" or "hot", { strict }, members)
          f.phase("full", f.originals)
          local ok, report = f.publish(); t.assert_true(ok, report)
          t.assert_false(report.changed, "deferring strict must not restart the existing Tier 1 reader")
          t.assert_eq(f.read(f.ctx.paths.semantic_cdb), baseline)
          t.assert_true(vim.deep_equal(vim.uv.fs_stat(f.ctx.paths.semantic_cdb).mtime, baseline_stamp))
          local published = vim.json.decode(f.read(f.ctx.paths.semantic_cdb))
          t.assert_eq(#published, 2); t.assert_eq(published[1].file, live.file)
          t.assert_true(vim.deep_equal(published[2], f.originals[3]))
          t.assert_eq(#report.tier1_fallbacks, 0)
          t.assert_eq(#report.batch_fallbacks, 1)
          t.assert_eq(report.batch_fallbacks[1].receipt, strict.nvim_ue_batch_receipt)
          t.assert_eq(report.batch_fallbacks[1].reason, "tier1-original-overlap")
          t.assert_true(report.ordinary)
          t.assert_nil(f.read(f.root .. "/verified/compile_commands.json"))
          t.assert_nil(f.read(f.root .. "/batches.json"))
          local before, stamp = f.read(f.ctx.paths.semantic_cdb), vim.uv.fs_stat(f.ctx.paths.semantic_cdb).mtime
          local reused, unchanged = f.publish(); t.assert_true(reused, unchanged); t.assert_false(unchanged.changed)
          t.assert_eq(f.read(f.ctx.paths.semantic_cdb), before)
          t.assert_true(vim.deep_equal(vim.uv.fs_stat(f.ctx.paths.semantic_cdb).mtime, stamp))
        end)
      end)
    end
  end

  t.it("excludes an overlapping strict receipt while preserving a disjoint strict group", function()
    fixture(function(f)
      local d, e = f.original("D"), f.original("E")
      local originals = { f.originals[1], f.originals[2], f.originals[3], d, e }
      local live = f.tier1("Tier1AB", { f.originals[1], f.originals[2] })
      local overlap = f.batch("StrictBC", { f.originals[2], f.originals[3] })
      local strict = f.batch("StrictDE", { d, e })
      f.phase("current", { overlap, strict }, { f.originals[2], f.originals[3], d, e })
      f.phase("full", { live, f.originals[3], d, e }, originals)
      local ok, report = f.publish(); t.assert_true(ok, report)
      t.assert_eq(#report.batch_fallbacks, 1)
      t.assert_eq(report.batch_fallbacks[1].receipt, overlap.nvim_ue_batch_receipt)
      local info = vim.json.decode(f.read(f.root .. "/batches.json"))
      t.assert_eq(#info.receipts, 1); t.assert_eq(info.receipts[1], strict.nvim_ue_batch_receipt)
      local frozen = vim.json.decode(f.read(info.verified_cdb))
      t.assert_eq(#frozen, 3)
      for _, entry in ipairs(frozen) do t.assert_true(entry.file ~= overlap.file) end
      assert_activation_coverage(f)
    end)
  end)

  t.it("rejects a strict candidate command that aliases a Tier 1 candidate", function()
    fixture(function(f)
      local d = f.original("D")
      local originals = { f.originals[1], f.originals[2], f.originals[3], d }
      local live = f.tier1("SameCandidate", { f.originals[1], f.originals[2] })
      f.phase("full", { live, f.originals[3], d }, originals)
      t.assert_true(f.publish())
      local before = f.read(f.ctx.paths.semantic_cdb)
      local strict = f.batch("SameCandidate", { f.originals[3], d })
      f.phase("current", { strict }, { f.originals[3], d })
      local ok, reason = f.publish(); t.assert_false(ok)
      t.assert_eq(reason, "batch command aliases a Tier 1 command")
      t.assert_eq(f.read(f.ctx.paths.semantic_cdb), before)
      t.assert_nil(f.read(f.root .. "/batches.json"))
    end)
  end)

  t.it("stale Tier 1 restores originals in both views while disjoint strict coverage remains exact", function()
    fixture(function(f)
      local d = f.original("D")
      local originals = { f.originals[1], f.originals[2], f.originals[3], d }
      local live, receipt = f.tier1("Tier1AB", { f.originals[1], f.originals[2] })
      local strict = f.batch("StrictCD", { f.originals[3], d })
      f.phase("current", { strict }, { f.originals[3], d })
      f.phase("full", { live, f.originals[3], d }, originals)
      t.assert_true(f.publish())
      f.write(receipt.inputs[2].path, "int value = 2;\r\n")
      local ok, report = f.publish(); t.assert_true(ok, report)
      t.assert_eq(report.tier1_fallbacks[1].reason, "tier1-input-content-mismatch")
      t.assert_eq(#report.batch_fallbacks, 0)
      local published = vim.json.decode(f.read(f.ctx.paths.semantic_cdb))
      local frozen = vim.json.decode(f.read(f.root .. "/verified/compile_commands.json"))
      t.assert_eq(#published, 4); t.assert_eq(#frozen, 3)
      t.assert_eq(frozen[1].file, strict.file)
      t.assert_true(vim.deep_equal(frozen[2], f.originals[1]))
      t.assert_true(vim.deep_equal(frozen[3], f.originals[2]))
      assert_activation_coverage(f)
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

t.describe("Tier 2 ordinary live publication", function()
  local function with_tier2(callback)
    local previous = vim.env.NVIM_UE_TIER2
    vim.env.NVIM_UE_TIER2 = "1"
    local ok, err = pcall(callback)
    vim.env.NVIM_UE_TIER2 = previous
    if not ok then error(err) end
  end
  local function candidate(f)
    local definitions = {}
    for i = 1, 2 do
      local path = f.root .. "/Definitions.Module" .. i .. ".h"
      f.write(path, "#define UE_IS_ENGINE_MODULE 1\n")
      local args = f.originals[i].arguments
      args[#args + 1], args[#args + 2] = "-include", path
      definitions[#definitions + 1] = path
    end
    local entry, receipt = f.tier1("Tier2AB", { f.originals[1], f.originals[2] })
    entry.nvim_ue_tier, receipt.tier = 2, 2
    receipt.gates.include_resolution_equal = true
    for _, path in ipairs(definitions) do
      receipt.inputs[#receipt.inputs + 1] = { path = path, sha256 = vim.fn.sha256(f.read(path)) }
    end
    entry.nvim_ue_tier1_receipt_sha256 = f.json(entry.nvim_ue_tier1_receipt, receipt)
    return entry, receipt, definitions
  end
  t.it("publishes Tier 2 through the ordinary route and repeats without writing", function()
    with_tier2(function()
      fixture(function(f)
        local entry = candidate(f)
        f.json(f.ctx.paths.active_cdb, f.originals)
        f.phase("full", { entry, f.originals[3] }, f.originals)
        local ok, report = f.publish(); t.assert_true(ok, report)
        t.assert_eq(#report.tier1_fallbacks, 0)
        t.assert_true(report.ordinary)
        local rows = vim.json.decode(f.read(f.ctx.paths.semantic_cdb))
        t.assert_eq(#rows, 2); t.assert_eq(rows[1].file, entry.file)
        t.assert_nil(rows[1].nvim_ue_tier1_receipt)
        t.assert_nil(f.read(f.root .. "/batches.json"))
        t.assert_nil(f.read(f.root .. "/verified/compile_commands.json"))
        local bytes, stamp = f.read(f.ctx.paths.semantic_cdb), vim.uv.fs_stat(f.ctx.paths.semantic_cdb).mtime
        local repeated, unchanged = f.publish(); t.assert_true(repeated, unchanged)
        t.assert_false(unchanged.changed)
        t.assert_eq(f.read(f.ctx.paths.semantic_cdb), bytes)
        t.assert_true(vim.deep_equal(vim.uv.fs_stat(f.ctx.paths.semantic_cdb).mtime, stamp))
      end)
    end)
  end)
  for _, kind in ipairs({ "missing-include-gate", "changed-definitions", "missing-definitions", "disabled" }) do
    t.it("retains original commands for Tier 2 " .. kind, function()
      with_tier2(function()
        fixture(function(f)
          local entry, receipt, definitions = candidate(f)
          if kind == "missing-include-gate" then receipt.gates.include_resolution_equal = nil end
          if kind == "missing-definitions" then table.remove(receipt.inputs) end
          entry.nvim_ue_tier1_receipt_sha256 = f.json(entry.nvim_ue_tier1_receipt, receipt)
          if kind == "changed-definitions" then f.write(definitions[1], "// changed\n") end
          if kind == "disabled" then vim.env.NVIM_UE_TIER2 = "0" end
          f.json(f.ctx.paths.active_cdb, f.originals)
          f.phase("full", { entry, f.originals[3] }, f.originals)
          local ok, report = f.publish(); t.assert_true(ok, report)
          t.assert_eq(#report.tier1_fallbacks, 1)
          local rows = vim.json.decode(f.read(f.ctx.paths.semantic_cdb))
          t.assert_eq(#rows, 3)
          for _, row in ipairs(rows) do t.assert_true(row.file ~= entry.file) end
          t.assert_nil(f.read(f.root .. "/batches.json"))
        end)
      end)
    end)
  end
end)
