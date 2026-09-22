local t = require("tests.harness")
t.bootstrap()
local shaders = require("ue.cdb.shaders")
local origin = require("ue.cdb.unity_origin")

local function write(path, value)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local file = assert(io.open(path, "wb"))
  file:write(type(value) == "string" and value or vim.json.encode(value)); file:close()
end

local function read(path)
  local file = assert(io.open(path, "rb"))
  local result = file:read("*a"); file:close()
  return result
end

local function command(script, ...)
  local python = require("utils.platform").resolve_tool({ name = "python",
    driver_candidates = function(driver) return driver.python_candidates() end })
  t.assert_true(python.ok)
  local argv = { python.path, "-B", "-I", script }
  vim.list_extend(argv, { ... })
  local result = vim.system(argv, { text = true }):wait(15000)
  t.assert_eq(result.code, 0, result.stderr)
  return result.stdout
end

t.describe("shader augmentation provenance", function()
  t.it("records only inserted donors and preserves native commands for the same absolute or relative source", function()
    local root = vim.fs.normalize(vim.fn.tempname())
    local native = { directory = root, file = root .. "/Native.usf", arguments = { "dxc", "-T", "ps_6_0", "Native.usf" } }
    local entries = { vim.deepcopy(native) }
    local result, added = shaders.augment_table(entries, { native.file, root .. "/Donor.usf", root .. "/Donor.usf" }, {})
    t.assert_eq(result, entries)
    t.assert_eq(#entries, 2)
    t.assert_true(vim.deep_equal(entries[1], native))
    t.assert_type(added, "table")
    t.assert_eq(#added, 1)
    t.assert_eq(added[1].file, root .. "/Donor.usf")
    t.assert_eq(added[1].directory, entries[2].directory)
    t.assert_eq(added[1].command_hash, origin.entry_hash(entries[2]))
    t.assert_nil(entries[2].synthetic_shaders, "native CDB schema must remain standard")
    native.file = "./Native.usf"
    result, added = shaders.augment_table({ native }, { root .. "/Native.usf" }, {})
    t.assert_eq(#result, 1, "cwd-relative native source must not be duplicated or relabeled")
    t.assert_eq(#added, 0)
  end)

  t.it("finalize rejects modified, missing, ambiguous and forged donor identities", function()
    local root = vim.fs.normalize(vim.fn.tempname())
    local entries, added = shaders.augment_table({ { directory = root, file = root .. "/A.cpp",
      arguments = { "clang++", root .. "/A.cpp" } } }, { root .. "/S.usf" }, {})
    t.assert_type(added, "table")
    local valid = origin.finalize({}, entries, added)
    t.assert_eq(#valid.synthetic_shaders, 1)
    for _, mutate in ipairs({
      function(rows) rows[2].arguments[#rows[2].arguments + 1] = "-DCHANGED=1" end,
      function(rows) rows[2].directory = root .. "/other" end,
      function(rows) table.remove(rows, 2) end,
      function(rows) rows[#rows + 1] = vim.deepcopy(rows[2]) end,
    }) do
      local changed = vim.deepcopy(entries); mutate(changed)
      t.assert_eq(#(origin.finalize({}, changed, added).synthetic_shaders or {}), 0)
    end
    local forged = vim.deepcopy(added); forged[1].command_hash = string.rep("a", 64)
    t.assert_eq(#(origin.finalize({}, entries, forged).synthetic_shaders or {}), 0)
    local duplicate = { added[1], added[1] }
    t.assert_eq(#origin.finalize({}, entries, duplicate).synthetic_shaders, 0)
    forged = vim.deepcopy(added); forged[1].directory = root .. "/wrong-cwd"
    t.assert_eq(#origin.finalize({}, entries, forged).synthetic_shaders, 0)
    t.assert_eq(#origin.finalize({}, entries, { false, {} }).synthetic_shaders, 0)
    t.assert_nil(origin.finalize({}, entries).synthetic_shaders, "legacy origins omit the optional field")
  end)

  if vim.fn.executable("fd") ~= 1 and vim.fn.executable("fdfind") ~= 1 then
    t.skip("actual shader discovery", "fd unavailable", { native = true }); return
  end
  t.it("real RSP producer and pipeline seal donors; manual edits, corrupt evidence and ambiguous commands retain them", function()
    local root = vim.fs.normalize(vim.fn.tempname() .. "_shader_receipt")
    local cdb = root .. "/cache/compile_commands.json"
    local tools = vim.fn.stdpath("config") .. "/tools"
    local receipt_tool = tools .. "/cdb_unity_receipt.py"
    local pending, receipt_path = root .. "/pending.json", cdb .. ".unity-receipt.json"
    local ok, err = xpcall(function()
      local member = root .. "/Engine/Source/Sample/A.cpp"
      local wrapper = root .. "/Engine/Intermediate/Build/Android/Fixture/Development/Sample/Module.Sample.cpp"
      local shader = root .. "/Engine/Shaders/Private/Fixture.usf"
      write(member, "int value() { return 1; }\n")
      write(wrapper, '#include "' .. member .. '"\n')
      write(wrapper .. "a8.o.rsp", '-I.\n-c "' .. wrapper .. '"\n')
      write(shader, "float4 Main() : SV_Target { return 0; }\n")
      local ctx = { engine_root = root,
        state = { target_platform = "Android", target_configuration = "Development", target = "Fixture" },
        paths = { active_cdb = cdb, cdb_shards_dir = root .. "/cache/shards", index_cdb_dir = root .. "/cache/index" } }
      local generated, message = require("ue")._ccjson_subprocess_run(ctx, function() end)
      t.assert_true(generated, message)
      local document = vim.json.decode(read(cdb .. ".unity-origin.json"))
      t.assert_type(document.synthetic_shaders, "table")
      t.assert_eq(#document.synthetic_shaders, 1)
      t.assert_eq(document.synthetic_shaders[1].file, shader)
      local probe = root .. "/probe.py"
      write(probe, [=[
import json, sys
sys.path.insert(0, sys.argv[1])
import cdb_unity_receipt as receipt
print(json.dumps(sorted(receipt.load_verified_synthetic_shaders(sys.argv[2], sys.argv[3]))))
]=])
      local function verify()
        return vim.json.decode(command(probe, tools, receipt_path, cdb))
      end
      t.assert_eq(#verify(), 0, "a missing receipt cannot authorize excluding any shader")
      command(receipt_tool, "begin", cdb, pending)
      local staged = vim.json.decode(read(cdb))
      for _, entry in ipairs(staged) do
        if entry.file == shader then vim.list_extend(entry.arguments, { "-I", "." }) end
      end
      write(cdb, staged)
      command(tools .. "/resolve_cdb_paths.py", cdb)
      command(receipt_tool, "seal", cdb, pending)
      local entries = vim.json.decode(read(cdb))
      local donor
      for _, entry in ipairs(entries) do if entry.file == shader then donor = entry end end
      t.assert_true(donor ~= nil, "shader stays in the original/native CDB")
      local hashes = verify()
      t.assert_eq(#hashes, 1)
      t.assert_eq(hashes[1], origin.entry_hash(donor))
      t.assert_false(hashes[1] == document.synthetic_shaders[1].command_hash,
        "seal must bind final transformed argv, not the pre-pipeline identity")
      local sealed = read(receipt_path)
      local before = vim.uv.fs_stat(receipt_path).mtime
      vim.fn.delete(cdb .. ".unity-origin.json")
      command(receipt_tool, "begin", cdb, pending)
      command(receipt_tool, "seal", cdb, pending)
      t.assert_eq(read(receipt_path), sealed)
      t.assert_true(vim.deep_equal(vim.uv.fs_stat(receipt_path).mtime, before))
      t.assert_eq(#verify(), 1, "valid previously sealed commands survive repeated pipeline")
      local final = read(cdb)
      write(cdb .. ".unity-origin.json", { schema = 1, groups = {}, synthetic_shaders = {} })
      command(receipt_tool, "begin", cdb, pending)
      command(receipt_tool, "seal", cdb, pending)
      t.assert_eq(#verify(), 0, "a fresh native command cannot inherit an old donor label even with identical argv")
      t.assert_eq(read(cdb), final, "negative provenance never mutates native commands")
      vim.fn.delete(cdb .. ".unity-origin.json")
      write(receipt_path, sealed)
      donor.arguments[#donor.arguments + 1] = "-DUSER_EDIT=1"
      write(cdb, entries)
      t.assert_eq(#verify(), 0, "hand-edited commands cannot be filtered")
      command(receipt_tool, "begin", cdb, pending)
      command(receipt_tool, "seal", cdb, pending)
      t.assert_eq(#verify(), 0, "a later pipeline must not bless an unbound manual edit")
      write(cdb, final); write(receipt_path, sealed)
      entries = vim.json.decode(final)
      for _, entry in ipairs(entries) do if entry.file == shader then entries[#entries + 1] = vim.deepcopy(entry); break end end
      write(cdb, entries)
      t.assert_eq(#verify(), 0, "duplicate source commands are ambiguous even when byte-identical")
      write(cdb, final); write(receipt_path, '{"schema":1,"groups":[],"synthetic_shaders":"broken"}')
      t.assert_eq(#verify(), 0)
      write(receipt_path, { schema = 1, groups = {} })
      t.assert_eq(#verify(), 0, "legacy receipts do not authorize guessed migration")
      -- Exercise the actual non-RSP writer, including JSON augmentation. Its
      -- prior stage can contain old sealed donor evidence from another source.
      local function upvalue(fn, wanted)
        for index = 1, 100 do
          local name, value = debug.getupvalue(fn, index)
          if not name then break end
          if name == wanted then return value end
        end
        error("missing production upvalue: " .. wanted)
      end
      local export = upvalue(require("ue")._ccjson_subprocess_run, "export_compile_commands_to_engine_root")
      local writer = upvalue(export, "write_compile_commands_targets")
      write(cdb .. ".unity-origin.json", document)
      write(receipt_path, sealed)
      t.assert_true(writer(ctx, final))
      t.assert_eq(#vim.json.decode(read(cdb .. ".unity-origin.json")).synthetic_shaders, 0,
        "non-RSP writer must revoke seeded shader donor authority")
      command(receipt_tool, "begin", cdb, pending)
      command(receipt_tool, "seal", cdb, pending)
      t.assert_eq(#verify(), 0, "non-RSP source must not inherit shader exclusion authority from seeded evidence")
    end, debug.traceback)
    vim.fn.delete(root, "rf")
    if not ok then error(err) end
  end)
end)
