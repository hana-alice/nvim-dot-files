local t = require("tests.harness")
t.bootstrap()

local origin = require("ue.cdb.unity_origin")
local fs = require("ue.core.fs")

local function fixture()
  local base = fs.norm(vim.fn.fnamemodify(vim.fn.tempname(), ":p"))
  local first, second = base .. "/First.cpp", base .. "/Second.cpp"
  local entries = {
    { directory = base, file = first, arguments = { "clang++", "-DPLATFORM=1", first } },
    { directory = base, file = second, arguments = { "clang++", "-DPLATFORM=1", second } },
  }
  local unity, rsp = base .. "/Module.Sample.cpp", base .. "/Module.Sample.cpp.o.rsp"
  local dependencies = {}
  origin.add_dependency(dependencies, unity, '#include "First.cpp"\r\n#include "Second.cpp"\r\n')
  origin.add_dependency(dependencies, rsp, ' --target=sample -c "Module.Sample.cpp"\r\n')
  return { unity = unity, members = { first, second }, entries = entries, dependencies = dependencies }, entries
end

t.describe("compiler unity origin capture", function()
  t.it("binds raw dependencies, ordered members and post-injection command arguments", function()
    local group, entries = fixture()
    table.insert(entries[1].arguments, 2, "-include")
    table.insert(entries[1].arguments, 3, "SharedPCH.h")
    local captured = origin.finalize({ group }, vim.deepcopy(entries))
    t.assert_eq(captured.schema, 1)
    t.assert_eq(#captured.groups, 1)
    local record = captured.groups[1]
    t.assert_eq(record.members[1], entries[1].file)
    t.assert_eq(record.members[2], entries[2].file)
    local fields = {
      entries[1].directory,
      entries[1].file,
      "clang++",
      "-include",
      "SharedPCH.h",
      "-DPLATFORM=1",
      entries[1].file,
    }
    for index, field in ipairs(fields) do
      fields[index] = tostring(#field) .. ":" .. field
    end
    t.assert_eq(record.commands[entries[1].file], vim.fn.sha256(table.concat(fields)))
    t.assert_eq(record.dependencies[group.unity], vim.fn.sha256('#include "First.cpp"\r\n#include "Second.cpp"\r\n'))
    t.assert_eq(entries[1].nvim_ue_origin, nil, "the native CDB must retain only its original fields")
    entries[1].arguments[2] = "changed-after-capture"
    t.assert_true(record.commands[entries[1].file] ~= origin.entry_hash(entries[1]))
  end)

  t.it("uses the same normalized lookup for parent-relative members without rewriting their commands", function()
    local group, entries = fixture()
    local spelling = entries[1].directory .. "/nested/../First.cpp"
    group.members[1], entries[1].file, entries[1].arguments[3] = spelling, spelling, spelling
    local before = vim.deepcopy(entries)
    local captured = origin.finalize({ group }, vim.deepcopy(entries))
    t.assert_eq(#captured.groups, 1, "parent-relative spellings must use the merged-entry lookup rules")
    t.assert_eq(captured.groups[1].members[1], spelling)
    t.assert_eq(captured.groups[1].commands[spelling], origin.entry_hash(entries[1]))
    t.assert_true(vim.deep_equal(entries, before), "lookup must not rewrite native command bytes")
    local conflicting = vim.deepcopy(entries)
    conflicting[1].arguments[2] = "-DPLATFORM=2"
    t.assert_eq(#origin.finalize({ group }, conflicting).groups, 0)
    local duplicate = vim.deepcopy(entries)
    duplicate[#duplicate + 1] = vim.deepcopy(entries[1])
    duplicate[#duplicate].file = vim.fs.normalize(spelling)
    t.assert_eq(#origin.finalize({ group }, duplicate).groups, 0, "aliases must not hide duplicate sources")
    local malformed = vim.deepcopy(group)
    malformed.entries[1].file = nil
    t.assert_eq(#origin.finalize({ malformed }, entries).groups, 0, "malformed commands must fail closed")
  end)

  for _, case in ipairs({ "missing member", "conflicting member", "duplicate member", "incomplete capture" }) do
    t.it("rejects " .. case, function()
      local group, entries = fixture()
      local merged = vim.deepcopy(entries)
      if case == "missing member" then
        table.remove(merged)
      elseif case == "conflicting member" then
        merged[2].arguments[2] = "-DPLATFORM=2"
      elseif case == "duplicate member" then
        group.members[2], group.entries[2] = group.members[1], group.entries[1]
      else
        group.invalid = true
      end
      t.assert_eq(#origin.finalize({ group }, merged).groups, 0)
    end)
  end

  t.it("rejects missing nested content and dependencies observed with different bytes", function()
    local group, entries = fixture()
    origin.add_dependency(group.dependencies, entries[1].directory .. "/nested.rsp", nil)
    t.assert_eq(#origin.finalize({ group }, entries).groups, 0)
    group, entries = fixture()
    origin.add_dependency(group.dependencies, group.unity, "different contents")
    t.assert_eq(#origin.finalize({ group }, entries).groups, 0)
  end)

  t.it("rejects NUL arguments and duplicate merged sources", function()
    local group, entries = fixture()
    entries[1].arguments[2] = "-DPLATFORM=1\0-injected"
    t.assert_eq(origin.entry_hash(entries[1]), nil)
    t.assert_eq(#origin.finalize({ group }, entries).groups, 0)
    group, entries = fixture()
    entries[#entries + 1] = vim.deepcopy(entries[1])
    t.assert_eq(#origin.finalize({ group }, entries).groups, 0)
  end)

  t.it("uses the same UTF-8 byte-length framing as Python", function()
    local platform = require("utils.platform")
    local python = platform.resolve_tool({
      name = "python",
      driver_candidates = function(driver)
        return driver.python_candidates()
      end,
    })
    t.assert_true(python.ok)
    local entry = {
      directory = "C:/目录 with spaces",
      file = "C:/目录 with spaces/a.cpp",
      arguments = { "clang++", "-DVALUE=a:b", "", "C:/目录 with spaces/a.cpp" },
    }
    local result = vim
      .system({
        python.path,
        "-I",
        "-c",
        [=[
import importlib.util,json,pathlib,sys
spec=importlib.util.spec_from_file_location('receipt',pathlib.Path.cwd()/'tools/cdb_unity_receipt.py')
receipt=importlib.util.module_from_spec(spec);spec.loader.exec_module(receipt)
e=json.loads(sys.stdin.read())
print(receipt.entry_hash(e))
]=],
      }, { text = true, stdin = vim.json.encode(entry), cwd = vim.fn.stdpath("config") })
      :wait(10000)
    t.assert_eq(result.code, 0, result.stderr)
    t.assert_eq(origin.entry_hash(entry), vim.trim(result.stdout))
  end)

  t.it("writes only the external sidecar and leaves unchanged content untouched", function()
    local group, entries = fixture()
    local cdb = vim.fn.tempname() .. ".json"
    local sidecar = cdb .. ".unity-origin.json"
    vim.fn.writefile({ vim.json.encode(entries) }, cdb)
    local before = vim.fn.readfile(cdb, "b")
    local captured = origin.finalize({ group }, entries)
    local ok, err = xpcall(function()
      t.assert_true(origin.write(cdb, captured))
      local first = vim.uv.fs_stat(sidecar)
      t.assert_true(origin.write(cdb, captured))
      local second = vim.uv.fs_stat(sidecar)
      t.assert_true(vim.deep_equal(first.mtime, second.mtime), "identical receipt must not be rewritten")
      t.assert_true(vim.deep_equal(vim.fn.readfile(cdb, "b"), before))
      t.assert_true(vim.deep_equal(vim.json.decode(table.concat(vim.fn.readfile(sidecar, "b"), "\n")), captured))
    end, debug.traceback)
    vim.fn.delete(cdb)
    vim.fn.delete(sidecar)
    if not ok then
      error(err)
    end
  end)
end)

t.describe("RSP dependency capture in the production tokenizer", function()
  local source = table.concat(vim.fn.readfile(vim.fn.stdpath("config") .. "/lua/ue.lua"), "\n")
  local parser = vim.treesitter.get_string_parser(source, "lua")
  local query = vim.treesitter.query.parse(
    "lua",
    [[
    (function_declaration name: (identifier) @name) @function
  ]]
  )
  local wanted = { tokenize_rsp_single_line = true, tokenize_rsp_content = true, extract_unity_includes = true }
  local functions = {}
  for _, match in query:iter_matches(parser:parse()[1]:root(), source, 0, -1) do
    local name, declaration
    for id, nodes in pairs(match) do
      local node = type(nodes) == "table" and nodes[1] or nodes
      local text = vim.treesitter.get_node_text(node, source)
      if query.captures[id] == "name" then
        name = text
      else
        declaration = text
      end
    end
    if wanted[name] then
      functions[name] = declaration
    end
  end
  local function production(files)
    local code = {}
    for _, name in ipairs({ "tokenize_rsp_single_line", "tokenize_rsp_content", "extract_unity_includes" }) do
      code[#code + 1] = assert(functions[name], "production function missing: " .. name)
    end
    code[#code + 1] = "return tokenize_rsp_content, extract_unity_includes"
    local chunk = assert(loadstring(table.concat(code, "\n"), "@production-rsp-origin"))
    setfenv(
      chunk,
      setmetatable({
        trim = vim.trim,
        join = fs.join,
        norm = fs.norm,
        read_all = function(path)
          return files[path]
        end,
        _ufs = {
          is_file = function(path)
            return files[path] ~= nil
          end,
          dirname = fs.dirname,
        },
      }, { __index = _G })
    )
    return chunk()
  end

  t.it("records exact nested bytes and flags missing or truncated expansion without changing tokens", function()
    local base = fs.norm(vim.fn.fnamemodify(vim.fn.tempname(), ":p"))
    local nested = base .. "/nested.rsp"
    local bytes = '  -DONE=1\r\n -I"folder with spaces"\r\n'
    local tokenize = production({ [nested] = bytes })
    local dependencies = {}
    local tokens = tokenize("@nested.rsp @missing.rsp -DEND=1", base, nil, dependencies)
    t.assert_true(vim.deep_equal(tokens, { "-DONE=1", "-Ifolder with spaces", "-DEND=1" }))
    t.assert_eq(dependencies[nested], vim.fn.sha256(bytes))
    t.assert_true(dependencies.invalid)
    local cyclic = production({ [nested] = "@nested.rsp" })
    dependencies = {}
    cyclic("@nested.rsp", base, nil, dependencies)
    t.assert_true(dependencies.invalid, "recursion limit must invalidate capture")
  end)

  t.it("preserves ordered CPP members with mixed extension casing and detects missing members", function()
    local base = fs.norm(vim.fn.fnamemodify(vim.fn.tempname(), ":p"))
    local unity = base .. "/Module.Sample.cpp"
    local names = { "First.cpp", "WorldPartitionMapCheckManager.Cpp", "Third.CPP" }
    local files, expected, lines = {}, {}, {}
    for _, name in ipairs(names) do
      local path = base .. "/" .. name
      files[path], expected[#expected + 1] = "int member;", path
      lines[#lines + 1] = '#include "' .. name .. '"\r\n'
    end
    local text = table.concat(lines)
    files[unity] = text
    local _, extract = production(files)
    local members, raw, complete = extract(unity, base)
    t.assert_true(vim.deep_equal(members, expected), "all CPP suffix cases must retain their original spelling and order")
    t.assert_eq(raw, text)
    t.assert_true(complete)
    files[expected[2]] = nil
    members, raw, complete = extract(unity, base)
    t.assert_true(vim.deep_equal(members, { expected[1], expected[3] }))
    t.assert_eq(raw, text)
    t.assert_false(complete, "a missing mixed-case CPP must invalidate provenance")
  end)

  t.it("retains legacy member extraction while refusing incomplete unity provenance", function()
    local base = fs.norm(vim.fn.fnamemodify(vim.fn.tempname(), ":p"))
    local unity, member = base .. "/Module.Sample.cpp", base .. "/First.cpp"
    local text = '#include "First.cpp"\r\n#include "Missing.cpp"\r\n'
    local _, extract = production({ [unity] = text, [member] = "int first;" })
    local members, raw, complete = extract(unity, base)
    t.assert_true(vim.deep_equal(members, { member }))
    t.assert_eq(raw, text)
    t.assert_false(complete)
  end)
end)
