local t = require("tests.harness")
t.bootstrap()

local tool = vim.fn.stdpath("config") .. "/tools/cdb_unity_receipt.py"

local function write(path, content)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local stream = assert(io.open(path, "wb"))
  stream:write(content)
  stream:close()
end

local function read(path)
  local stream = assert(io.open(path, "rb"))
  local content = stream:read("*a")
  stream:close()
  return content
end

local function json(path)
  return vim.json.decode(read(path))
end

local function python(script, ...)
  local executable = vim.fn.exepath("python")
  if executable == "" then executable = vim.fn.exepath("python3") end
  local command = executable ~= "" and { executable, "-I", script } or { "py", "-3", "-I", script }
  vim.list_extend(command, { ... })
  return vim.system(command, { text = true }):wait()
end

local function run(script, ...)
  local result = python(script, ...)
  t.assert_eq(result.code, 0, result.stderr or result.stdout)
  return result.stdout
end

local function fixture(callback)
  local root = vim.fn.tempname():gsub("\\", "/") .. "_unity_receipt"
  vim.fn.mkdir(root, "p")
  root = vim.fs.normalize(vim.uv.fs_realpath(root) or root)
  local ctx = {
    root = root,
    cdb = root .. "/compile_commands.json",
    pending = root .. "/pending.json",
    unity = root .. "/Module.Sample.cpp",
    driver = root .. "/receipt_probe.py",
  }
  ctx.origin = ctx.cdb .. ".unity-origin.json"
  ctx.receipt = ctx.cdb .. ".unity-receipt.json"
  ctx.dependencies = { ctx.unity, root .. "/flags.rsp", root .. "/nested.rsp", root .. "/Definitions.h", root .. "/Shared.pch" }
  write(root .. "/A.cpp", "int a() { return 1; }\n")
  write(root .. "/B.cpp", "int b() { return 2; }\n")
  write(ctx.unity, '#include "' .. root .. '/A.cpp"\n#include "' .. root .. '/B.cpp"\n')
  write(root .. "/flags.rsp", '-DCHOICE=1 @nested.rsp')
  write(root .. "/nested.rsp", '-Iinclude -include Definitions.h -include-pch Shared.pch')
  write(root .. "/Definitions.h", "#define RECEIPT_FIXTURE 1\n")
  write(root .. "/Shared.pch", "fixture binary dependency\n")
  local entries = {}
  for _, name in ipairs({ "A.cpp", "B.cpp" }) do
    entries[#entries + 1] = { directory = root, file = root .. "/" .. name, arguments = { "clang++", "@flags.rsp", "-c", root .. "/" .. name } }
  end
  write(ctx.cdb, vim.json.encode(entries))
  write(ctx.driver, [=[
import hashlib, importlib.util, json, os, sys
tool_path, root, operation = sys.argv[1:]
spec = importlib.util.spec_from_file_location('receipt', tool_path)
receipt = importlib.util.module_from_spec(spec)
spec.loader.exec_module(receipt)
cdb_path = os.path.join(root, 'compile_commands.json')
with open(cdb_path, encoding='utf-8') as stream:
    cdb = json.load(stream)
if operation == 'capture':
    dependencies = {}
    for name in ('Module.Sample.cpp', 'flags.rsp', 'nested.rsp', 'Definitions.h', 'Shared.pch'):
        path = os.path.join(root, name).replace('\\', '/')
        with open(path, 'rb') as stream:
            dependencies[path] = hashlib.sha256(stream.read()).hexdigest()
    commands = {entry['file']: hashlib.sha256(b''.join(
        str(len(field.encode('utf-8'))).encode('ascii') + b':' + field.encode('utf-8')
        for field in [entry['directory'], entry['file']] + entry['arguments'])).hexdigest()
        for entry in cdb}
    group = {'unity': os.path.join(root, 'Module.Sample.cpp').replace('\\', '/'),
             'members': [entry['file'] for entry in cdb],
             'dependencies': dependencies, 'commands': commands}
    with open(cdb_path + '.unity-origin.json', 'w', encoding='utf-8') as stream:
        json.dump({'schema': 1, 'groups': [group]}, stream)
elif operation == 'verify':
    print(len(receipt.load_verified_groups(cdb_path + '.unity-receipt.json', cdb)))
elif operation == 'hash':
    original = dict(cdb[0])
    output = dict(original, output='different.o')
    changed = dict(original, arguments=original['arguments'] + ['-DCHANGED=1'])
    invalid = dict(original, arguments=original['arguments'] + ['-DA=1\0-DOTHER=1'])
    rejected = False
    try:
        receipt.entry_hash(invalid)
    except ValueError:
        rejected = True
    print(json.dumps({'output_equal': receipt.entry_hash(original) == receipt.entry_hash(output),
                      'semantic_equal': receipt.entry_hash(original) == receipt.entry_hash(changed),
                      'nul_rejected': rejected}))
elif operation == 'cache':
    import builtins
    document = receipt._document(cdb_path + '.unity-origin.json')
    duplicate = dict(document['groups'][0])
    duplicate['unity'] = os.path.join(root, 'Module.Other.cpp').replace('\\', '/')
    with open(duplicate['unity'], 'wb') as stream:
        stream.write(b'// other wrapper\n')
    duplicate['dependencies'] = dict(duplicate['dependencies'])
    duplicate['dependencies'][duplicate['unity']] = hashlib.sha256(b'// other wrapper\n').hexdigest()
    document['groups'].append(duplicate)
    with open(cdb_path + '.unity-receipt.json', 'w', encoding='utf-8') as stream:
        json.dump(document, stream)
    original_open = builtins.open
    counts = {}
    def tracked_open(path, *args, **kwargs):
        key = os.path.normcase(os.path.normpath(path))
        counts[key] = counts.get(key, 0) + 1
        return original_open(path, *args, **kwargs)
    builtins.open = tracked_open
    verified = receipt.load_verified_groups(cdb_path + '.unity-receipt.json', cdb)
    print(json.dumps({'groups': len(verified), 'nested_reads': counts.get(
        os.path.normcase(os.path.normpath(os.path.join(root, 'nested.rsp'))), 0)}))
elif operation == 'split':
    sys.path.insert(0, os.path.dirname(tool_path))
    import build_hot_super_unity_cdb as generator
    text = ' \t\r\n --target=aarch64-linux-android\r\n-std=c++20\n-DNAME="hello world"\r\n-I"C:/with spaces/include"\n-c "C:/source tree/Module.Sample.cpp"\r\n'
    print(json.dumps(generator.split_response_file(text)))
]=])
  run(ctx.driver, tool, root, "capture")
  local ok, failure = pcall(callback, ctx)
  pcall(vim.fn.delete, root, "rf")
  if not ok then error(failure) end
end

local function begin(ctx)
  run(tool, "begin", ctx.cdb, ctx.pending)
  return json(ctx.pending).groups
end

local function seal(ctx)
  run(tool, "seal", ctx.cdb, ctx.pending)
end

local function verified(ctx)
  return tonumber(run(ctx.driver, tool, ctx.root, "verify"))
end

local function generate(ctx, with_receipt)
  local args = { ctx.cdb, ctx.root .. "/out/compile_commands.json" }
  if with_receipt ~= false then vim.list_extend(args, { "--unity-receipt", ctx.receipt }) end
  run(vim.fn.stdpath("config") .. "/tools/build_hot_super_unity_cdb.py", unpack(args))
  return json(args[2])
end

t.describe("unity pipeline receipts", function()
  t.it("accepts actual Lua origin hashes with UTF-8 byte lengths for non-ASCII paths and flags", function()
    fixture(function(ctx)
      local origin = require("ue.cdb.unity_origin")
      local directory = ctx.root .. "/工程"
      local entries, members = {}, {}
      for _, name in ipairs({ "样本一.cpp", "样本二.cpp" }) do
        local path = directory .. "/" .. name
        write(path, "// unicode fixture\n")
        members[#members + 1] = path
        entries[#entries + 1] = {
          directory = directory, file = path,
          arguments = { "clang++", "-D描述=值:冒号", "-I" .. directory, "-c", path },
        }
      end
      write(ctx.unity, '#include "' .. members[1] .. '"\n#include "' .. members[2] .. '"\n')
      write(ctx.cdb, vim.json.encode(entries))
      local dependencies = {}
      for _, path in ipairs(ctx.dependencies) do origin.add_dependency(dependencies, path, read(path)) end
      local captured = origin.finalize({ { unity = ctx.unity, members = members, entries = entries, dependencies = dependencies } }, entries)
      t.assert_eq(#captured.groups, 1)
      t.assert_eq(captured.groups[1].commands[members[1]], origin.entry_hash(entries[1]))
      t.assert_true(origin.write(ctx.cdb, captured))
      t.assert_eq(#begin(ctx), 1, "Lua and Python must hash UTF-8 bytes identically")
      seal(ctx)
      t.assert_eq(verified(ctx), 1)
      t.assert_eq(#generate(ctx), 1)
    end)
  end)

  t.it("carries captured origin through actual response expansion and reuses its sealed evidence", function()
    fixture(function(ctx)
      t.assert_eq(#begin(ctx), 1)
      run(vim.fn.stdpath("config") .. "/tools/replace_i_with_rsp.py", ctx.cdb)
      local entries = json(ctx.cdb)
      t.assert_true(vim.tbl_contains(entries[1].arguments, "-DCHOICE=1"))
      t.assert_false(vim.tbl_contains(entries[1].arguments, "@flags.rsp"))
      seal(ctx)
      t.assert_eq(verified(ctx), 1)
      t.assert_eq(#begin(ctx), 1, "matching sealed evidence must survive transformed argv")
      t.assert_true(vim.deep_equal(json(ctx.receipt).groups[1].dependencies, json(ctx.origin).groups[1].dependencies))
      t.assert_false(vim.deep_equal(json(ctx.receipt).groups[1].commands, json(ctx.origin).groups[1].commands))
    end)
  end)

  t.it("uses a verified transformed receipt to group real wrappers with exact active semantic argv", function()
    fixture(function(ctx)
      begin(ctx)
      run(vim.fn.stdpath("config") .. "/tools/replace_i_with_rsp.py", ctx.cdb)
      seal(ctx)
      local original = json(ctx.cdb)
      local grouped = generate(ctx)
      t.assert_eq(#grouped, 1)
      t.assert_eq(#grouped[1].nvim_ue_members, 2)
      t.assert_match(grouped[1].file, "SuperUnity%.UBT%.")
      local expected = vim.deepcopy(original[1].arguments)
      expected[#expected] = grouped[1].file
      t.assert_true(vim.deep_equal(grouped[1].arguments, expected), "only the source argument may change")
      t.assert_true(vim.deep_equal(json(ctx.cdb), original), "grouping must not modify active commands")
      local fallback = generate(ctx, false)
      t.assert_eq(#fallback, 2)
      for i, entry in ipairs(fallback) do
        t.assert_eq(entry.file, original[i].file)
        t.assert_true(vim.deep_equal(entry.arguments, original[i].arguments))
      end
    end)
  end)

  t.it("keeps every exact source when receipt commands or dependencies become stale or the subset is incomplete", function()
    fixture(function(ctx)
      begin(ctx)
      run(vim.fn.stdpath("config") .. "/tools/replace_i_with_rsp.py", ctx.cdb)
      seal(ctx)
      local original = json(ctx.cdb)
      local changed = vim.deepcopy(original)
      table.insert(changed[1].arguments, "-DCHOICE=2")
      write(ctx.cdb, vim.json.encode(changed))
      local output = generate(ctx)
      t.assert_eq(#output, 2)
      t.assert_true(vim.deep_equal(output[1].arguments, changed[1].arguments))
      write(ctx.cdb, vim.json.encode(original))
      local nested = read(ctx.root .. "/nested.rsp")
      write(ctx.root .. "/nested.rsp", nested .. " -DCHANGED=1")
      output = generate(ctx)
      t.assert_eq(#output, 2)
      t.assert_true(vim.deep_equal(output[2].arguments, original[2].arguments))
      write(ctx.root .. "/nested.rsp", nested)
      write(ctx.cdb, vim.json.encode({ original[1] }))
      output = generate(ctx)
      t.assert_eq(#output, 1)
      t.assert_eq(output[1].file, original[1].file)
      t.assert_true(vim.deep_equal(output[1].arguments, original[1].arguments))
    end)
  end)

  t.it("does not group valid receipts with unequal final contexts or incomplete authored membership", function()
    fixture(function(ctx)
      begin(ctx)
      run(vim.fn.stdpath("config") .. "/tools/replace_i_with_rsp.py", ctx.cdb)
      local entries = json(ctx.cdb)
      table.insert(entries[1].arguments, "-DDIFFERENT_MEMBER=1")
      write(ctx.cdb, vim.json.encode(entries))
      seal(ctx)
      t.assert_eq(verified(ctx), 1, "receipt records the successful pipeline, not context equivalence")
      t.assert_eq(#generate(ctx), 2, "unequal member contexts must keep exact commands")
      table.remove(entries[1].arguments)
      write(ctx.cdb, vim.json.encode(entries))
      local pending = json(ctx.pending)
      pending.groups[1].commands[pending.groups[1].members[2]] = nil
      table.remove(pending.groups[1].members, 2)
      write(ctx.pending, vim.json.encode(pending))
      seal(ctx)
      t.assert_eq(verified(ctx), 1)
      t.assert_eq(#generate(ctx), 2, "consumer must independently check all authored includes")
    end)
  end)

  t.it("splits leading-whitespace multiline response flags without an empty driver token", function()
    fixture(function(ctx)
      local tokens = vim.json.decode(run(ctx.driver, tool, ctx.root, "split"))
      t.assert_true(vim.deep_equal(tokens, {
        "--target=aarch64-linux-android", "-std=c++20", "-DNAME=hello world",
        "-IC:/with spaces/include", "-c", "C:/source tree/Module.Sample.cpp",
      }))
    end)
  end)

  t.it("does not re-sign arbitrary active macro, include, target or PCH edits", function()
    fixture(function(ctx)
      begin(ctx)
      seal(ctx)
      local original = json(ctx.cdb)
      for _, changed in ipairs({ "-DCHOICE=2", "-Ianother", "--target=other", "-include", "-include-pch" }) do
        local entries = vim.deepcopy(original)
        table.insert(entries[1].arguments, changed)
        write(ctx.cdb, vim.json.encode(entries))
        t.assert_eq(verified(ctx), 0, changed)
        t.assert_eq(#begin(ctx), 0, changed .. " must not be blessed by begin")
      end
    end)
  end)

  t.it("rejects changes to unity, response, nested response, header and PCH bytes", function()
    fixture(function(ctx)
      begin(ctx)
      seal(ctx)
      local admitted = read(ctx.pending)
      for _, path in ipairs(ctx.dependencies) do
        local original = read(path)
        write(path, original .. "changed")
        t.assert_eq(verified(ctx), 0, path)
        t.assert_eq(#begin(ctx), 0, path)
        write(ctx.pending, admitted)
        seal(ctx)
        t.assert_eq(#json(ctx.receipt).groups, 0, "seal must recheck bytes")
        write(path, original)
        write(ctx.pending, admitted)
        seal(ctx)
      end
    end)
  end)

  t.it("rejects a missing member during admission, consumption and sealing", function()
    fixture(function(ctx)
      begin(ctx)
      seal(ctx)
      local admitted = read(ctx.pending)
      local entries = json(ctx.cdb)
      table.remove(entries, 2)
      write(ctx.cdb, vim.json.encode(entries))
      t.assert_eq(verified(ctx), 0)
      t.assert_eq(#begin(ctx), 0)
      write(ctx.pending, admitted)
      seal(ctx)
      t.assert_eq(#json(ctx.receipt).groups, 0)
    end)
  end)

  t.it("fails closed for duplicate members, dependencies, unity groups and CDB sources", function()
    fixture(function(ctx)
      local origin = json(ctx.origin)
      local cdb = json(ctx.cdb)
      local variants = {
        function(doc) table.insert(doc.groups[1].members, doc.groups[1].members[1]) end,
        function(doc)
          local dependencies = doc.groups[1].dependencies
          dependencies[ctx.root .. "/./nested.rsp"] = dependencies[ctx.root .. "/nested.rsp"]
        end,
        function(doc) table.insert(doc.groups, vim.deepcopy(doc.groups[1])) end,
        function()
          local entries = vim.deepcopy(cdb)
          table.insert(entries, vim.deepcopy(entries[1]))
          write(ctx.cdb, vim.json.encode(entries))
        end,
      }
      for number, mutate in ipairs(variants) do
        write(ctx.cdb, vim.json.encode(cdb))
        local document = vim.deepcopy(origin)
        mutate(document)
        write(ctx.origin, vim.json.encode(document))
        write(ctx.receipt, vim.json.encode(document))
        t.assert_eq(verified(ctx), 0, "variant " .. number)
        t.assert_eq(#begin(ctx), 0, "variant " .. number)
      end
    end)
  end)

  t.it("missing or malformed evidence admits no groups and malformed pending cannot overwrite a receipt", function()
    fixture(function(ctx)
      begin(ctx)
      seal(ctx)
      local receipt_bytes = read(ctx.receipt)
      write(ctx.pending, '{"schema":1,"groups":false}')
      t.assert_true(python(tool, "seal", ctx.cdb, ctx.pending).code ~= 0)
      t.assert_eq(read(ctx.receipt), receipt_bytes)
      assert(os.remove(ctx.pending))
      t.assert_true(python(tool, "seal", ctx.cdb, ctx.pending).code ~= 0)
      t.assert_eq(read(ctx.receipt), receipt_bytes)
      for _, bad in ipairs({ '{', '{"schema":2,"groups":[]}', '{"schema":1,"schema":1,"groups":[]}', '{"schema":true,"groups":[]}' }) do
        write(ctx.origin, bad)
        write(ctx.receipt, bad)
        t.assert_eq(verified(ctx), 0)
        t.assert_eq(#begin(ctx), 0)
      end
      assert(os.remove(ctx.origin))
      assert(os.remove(ctx.receipt))
      t.assert_eq(verified(ctx), 0)
      t.assert_eq(#begin(ctx), 0)
    end)
  end)

  t.it("keeps sealed bytes and mtime stable when nothing changed", function()
    fixture(function(ctx)
      begin(ctx)
      seal(ctx)
      local bytes = read(ctx.receipt)
      assert(vim.uv.fs_utime(ctx.receipt, 1000000000, 1000000000))
      local before = assert(vim.uv.fs_stat(ctx.receipt))
      begin(ctx)
      seal(ctx)
      local after = assert(vim.uv.fs_stat(ctx.receipt))
      t.assert_eq(read(ctx.receipt), bytes)
      t.assert_true(vim.deep_equal(after.mtime, before.mtime), "identical receipt must not invalidate caches")
    end)
  end)

  t.it("hashes exact semantic argv, ignores output metadata and rejects NUL ambiguity", function()
    fixture(function(ctx)
      local result = vim.json.decode(run(ctx.driver, tool, ctx.root, "hash"))
      t.assert_true(result.output_equal)
      t.assert_false(result.semantic_equal)
      t.assert_true(result.nul_rejected)
    end)
  end)

  t.it("reads shared nested dependencies once across groups", function()
    fixture(function(ctx)
      local result = vim.json.decode(run(ctx.driver, tool, ctx.root, "cache"))
      t.assert_eq(result.groups, 2)
      t.assert_eq(result.nested_reads, 1)
    end)
  end)
end)
