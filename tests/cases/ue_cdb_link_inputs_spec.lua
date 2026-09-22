local t = require("tests.harness")
t.bootstrap()

local function upvalue(fn, wanted)
  for index = 1, 100 do
    local name, value = debug.getupvalue(fn, index)
    if name == wanted then return value end
    if not name then break end
  end
  error("missing generator upvalue: " .. wanted)
end

local function fixture(test)
  local root = vim.fs.normalize(vim.fn.tempname())
  local function write(path, content)
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    local file = assert(io.open(path, "wb")); file:write(content); file:close()
  end
  local project = root .. "/Project"
  local build = project .. "/Intermediate/Build/Android/Client/Test"
  local product = "$(ProjectDir)/Binaries/Android/Client-Android-Test-arm64.so"
  local receipt = project .. "/Binaries/Android/Client-Android-Test.target"
  local response = build .. "/Client-Android-Test-arm64.so.response"
  local document = { TargetName = "Client", Platform = "Android", Configuration = "Test",
    Project = "../../Client.uproject", Launch = product,
    BuildProducts = { { Path = product, Type = "Executable" } } }
  write(project .. "/Client.uproject", "{}")
  write(project .. "/Binaries/Android/Client-Android-Test-arm64.so", "fixture product")
  write(receipt, vim.json.encode(document))
  local generator = upvalue(require("ue")._ccjson_subprocess_run, "generate_compile_commands_from_rsp")
  local callbacks = { read = upvalue(generator, "read_all"),
    tokenize = upvalue(generator, "tokenize_rsp_content"), parse = upvalue(generator, "parse_rsp_tokens") }
  local files, rows = {}, {}
  local function compile(relative, target)
    local output = build .. "/" .. relative
    local source = output .. ".cpp"
    local rsp = output .. ".rsp"
    write(source, "int fixture;\n")
    write(rsp, '--target=' .. (target or "aarch64-none-linux-android23")
      .. ' -DKEEP=7 -Ifirst -Isecond -c "' .. source .. '" -o "' .. output .. '"\n')
    files[#files + 1] = rsp
    local row = { rsp = rsp, source = source, output = output }
    rows[#rows + 1] = row
    return row
  end
  local ctx = { engine_root = root, project_root = project, uproject = project .. "/Client.uproject",
    state = { target_platform = "Android", target_configuration = "Test", target = "Client" } }
  local env = { root = root, build = build, ctx = ctx, files = files, rows = rows,
    response = response, receipt = receipt, document = document,
    callbacks = callbacks, write = write, compile = compile, generator = generator }
  function env.plan()
    return require("ue.cdb.link_inputs").plan(ctx, files, callbacks)
  end
  function env.keep(plan, row)
    local tokens = callbacks.tokenize(callbacks.read(row.rsp), root, nil, {})
    local before = vim.deepcopy(tokens)
    local args, source, outputs = callbacks.parse(tokens)
    local original = vim.deepcopy(args)
    local keep, reason = require("ue.cdb.link_inputs").keep(plan, row.rsp, args, outputs, {})
    t.assert_true(vim.deep_equal(tokens, before), "RSP tokens changed")
    t.assert_true(vim.deep_equal(args, original), "selection changed compiler arguments")
    t.assert_eq(source, row.source)
    t.assert_true(vim.deep_equal(args, {
      tokens[1], "-DKEEP=7", "-Ifirst", "-Isecond", "-c",
    }), "existing parser flag order changed")
    return keep, reason
  end
  local ok, err = xpcall(function() test(env) end, debug.traceback)
  vim.fn.delete(root, "rf")
  if not ok then error(err) end
end

t.describe("CDB current linker object ownership", function()
  t.it("removes old Unity and adaptive standalone objects before source ownership is assigned", function()
    fixture(function(f)
      local old = f.compile("Audio/Module.Audio.1_of_3.cppa8.o")
      local current = f.compile("Audio/Module.Audio.1_of_4.cppa8.o")
      local standalone = f.compile("Vulkan/Memory.cppa8.o")
      local unity = f.compile("Vulkan/Module.Vulkan.cppa8.o")
      f.write(f.response, '"Audio/Module.Audio.1_of_4.cppa8.o"\n"Vulkan/Module.Vulkan.cppa8.o"\n')
      local plan = f.plan()
      t.assert_true(plan.enabled, plan.reason)
      t.assert_false(f.keep(plan, old))
      t.assert_true(f.keep(plan, current))
      t.assert_false(f.keep(plan, standalone))
      t.assert_true(f.keep(plan, unity))
      t.assert_eq(#plan.excluded, 2)
    end)
  end)

  for _, scenario in ipairs({ "missing response", "missing receipt", "wrong tuple", "missing nested response",
    "archive", "multiple architectures" }) do
    t.it("preserves originals when " .. scenario .. " prevents complete ownership", function()
      fixture(function(f)
        local old = f.compile("Module/Old.cppa8.o")
        f.compile("Module/Current.cppa8.o")
        f.write(f.response, '"Module/Current.cppa8.o"\n')
        if scenario == "missing response" then os.remove(f.response)
        elseif scenario == "missing receipt" then os.remove(f.receipt)
        elseif scenario == "wrong tuple" then
          f.document.Configuration = "Shipping"; f.write(f.receipt, vim.json.encode(f.document))
        elseif scenario == "missing nested response" then f.write(f.response, '@"missing.rsp"\n')
        elseif scenario == "archive" then f.write(f.response, '"Module/Current.cppa8.o"\n"Module/Other.a"\n')
        else
          f.document.BuildProducts[2] = { Path = "$(ProjectDir)/Binaries/Android/Client-armv7.so", Type = "Executable" }
          f.write(f.receipt, vim.json.encode(f.document))
        end
        local plan = f.plan()
        local keep, reason = f.keep(plan, old)
        t.assert_true(keep)
        t.assert_true(type(reason) == "string" and reason ~= "", "unknown ownership needs an observable reason")
      end)
    end)
  end

  t.it("expands a valid nested response and retains other architecture or unknown object families", function()
    fixture(function(f)
      local old = f.compile("Module/Old.cppa8.o")
      local other_arch = f.compile("Module/Other.cppa7.o", "armv7-none-linux-android23")
      local unrelated = f.compile("Separate/Unlisted.cppa8.o")
      f.compile("Module/Current.cppa8.o")
      f.write(f.response, '@"objects.rsp"\n')
      f.write(f.build .. "/objects.rsp", '"Module/Current.cppa8.o"\n')
      local plan = f.plan()
      t.assert_false(f.keep(plan, old))
      t.assert_true(f.keep(plan, other_arch))
      t.assert_true(f.keep(plan, unrelated))
    end)
  end)

  t.it("retains stale-looking entries when a consumed peer RSP is unavailable", function()
    fixture(function(f)
      local old = f.compile("Module/Old.cppa8.o")
      f.write(f.response, '"Module/Current.cppa8.o"\n')
      local plan = f.plan()
      t.assert_true(f.keep(plan, old))
      t.assert_eq(#plan.gaps, 1)
      t.assert_eq(plan.gaps[1].object, f.build .. "/Module/Current.cppa8.o")
      t.assert_eq(plan.gaps[1].rsp, f.build .. "/Module/Current.cppa8.o.rsp")
    end)
  end)

  t.it("the actual generator gives current Unity ownership priority over an earlier obsolete RSP", function()
    fixture(function(f)
      local old = f.compile("Audio/Module.Audio.1_of_3.cppa8.o")
      local current = f.compile("Audio/Module.Audio.1_of_4.cppa8.o")
      local member = f.root .. "/Source/Member.cpp"
      f.write(member, "int member;\n")
      local body = '// This file is automatically generated at compile-time to include some subset of the user-created cpp files.\n'
        .. '#include "' .. member .. '"\n'
      f.write(old.source, body); f.write(current.source, body)
      f.write(old.rsp, f.callbacks.read(old.rsp):gsub("KEEP=7", "KEEP=1"))
      f.write(f.response, '"Audio/Module.Audio.1_of_4.cppa8.o"\n')
      f.ctx.paths = { active_cdb = f.root .. "/cdb/compile_commands.json",
        cdb_shards_dir = f.root .. "/shards", index_cdb_dir = f.root .. "/index" }
      local restored = {}
      for index = 1, 100 do
        local name, value = debug.getupvalue(f.generator, index)
        if not name then break end
        if name == "collect_rsp_files" or name == "augment_compile_commands_table_with_shaders" then
          restored[index] = value
          debug.setupvalue(f.generator, index, name == "collect_rsp_files"
            and function() return f.files end or function(_, entries) return entries, {} end)
        end
      end
      local ok, err = xpcall(function()
        local count, path = f.generator(f.ctx, function() end)
        t.assert_eq(count, 1, tostring(path))
        local entries = vim.json.decode(f.callbacks.read(path))
        t.assert_eq(entries[1].file, member)
        t.assert_contains(table.concat(entries[1].arguments, " "), "-DKEEP=7")
        local receipt = vim.json.decode(f.callbacks.read(path .. ".unity-origin.json"))
        t.assert_eq(#receipt.groups, 1)
        t.assert_eq(receipt.groups[1].unity, current.source)
        t.assert_true(receipt.groups[1].dependencies[f.response] ~= nil)
      end, debug.traceback)
      for index, value in pairs(restored) do debug.setupvalue(f.generator, index, value) end
      if not ok then error(err) end
    end)
  end)
end)
