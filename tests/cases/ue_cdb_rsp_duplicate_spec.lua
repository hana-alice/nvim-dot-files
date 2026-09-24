local t = require("tests.harness")
t.bootstrap()

local function write(path, content)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local file = assert(io.open(path, "wb"))
  file:write(content)
  file:close()
end

local function read_json(path)
  local file = assert(io.open(path, "rb"))
  local content = file:read("*a")
  file:close()
  return vim.json.decode(content)
end

t.describe("RSP duplicate ownership and Unity origin", function()
  if vim.fn.executable("fd") ~= 1 and vim.fn.executable("fdfind") ~= 1 then
    t.skip("real RSP duplicate generation", "fd unavailable", { native = true })
    return
  end

  for _, case in ipairs({
    { name = "identical ordered command", flags = "-DVALUE=1 -Ifirst -Isecond", groups = 1 },
    { name = "different macro", flags = "-DVALUE=2 -Ifirst -Isecond", groups = 0 },
    { name = "different include order", flags = "-DVALUE=1 -Isecond -Ifirst", groups = 0 },
  }) do
    t.it("reuses an earlier entry only for " .. case.name, function()
      local root = vim.fs.normalize(vim.fn.tempname() .. "_rsp_duplicate")
      local source = root .. "/Engine/Source/Demo"
      local build = root .. "/Engine/Intermediate/Build/Android/Fixture/Development/Demo"
      local first, second = source .. "/A.cpp", source .. "/B.cpp"
      local unity = build .. "/Module.Demo.cpp"
      local standalone_rsp, unity_rsp = build .. "/A.cppa8.o.rsp", unity .. "a8.o.rsp"
      local ok, err = xpcall(function()
        write(root .. "/Engine/Source/Fixture.Target.cs", "// Fixture target.\n")
        write(first, "int first;\n")
        write(second, "int second;\n")
        write(unity, '#include "' .. first .. '"\n#include "' .. second .. '"\n')
        write(standalone_rsp, '-DVALUE=1 -Ifirst -Isecond -c "' .. first
          .. '" -o "' .. build .. '/A.o" -MD -MF "' .. build .. '/A.d"\n')
        write(unity_rsp, case.flags .. ' -c "' .. unity .. '" -o "' .. build
          .. '/Module.Demo.o" -MD -MF "' .. build .. '/Module.Demo.d"\n')
        local ctx = {
          engine_root = root,
          state = { target_platform = "Android", target_configuration = "Development", target = "Fixture" },
          paths = { active_cdb = root .. "/cache/compile_commands.json",
            cdb_shards_dir = root .. "/cache/shards", index_cdb_dir = root .. "/cache/index" },
        }
        local generated, path = require("ue")._ccjson_subprocess_run(ctx, function() end)
        t.assert_true(generated, path)
        local entries = read_json(path)
        t.assert_eq(#entries, 2, "duplicate RSP must not duplicate or drop a C++ source")
        local selected = {}
        for _, entry in ipairs(entries) do selected[entry.file] = entry end
        t.assert_true(selected[first] ~= nil and selected[second] ~= nil)
        t.assert_contains(table.concat(selected[first].arguments, " "), "-DVALUE=1")
        local captured = read_json(path .. ".unity-origin.json")
        t.assert_eq(#captured.groups, case.groups,
          "an equivalent earlier source must not invalidate compiler-authored Unity membership")
        if case.groups == 1 then
          local group = captured.groups[1]
          t.assert_true(vim.deep_equal(group.members, { first, second }))
          for _, member in ipairs(group.members) do
            t.assert_eq(group.commands[member], require("ue.cdb.unity_origin").entry_hash(selected[member]))
          end
          t.assert_true(group.dependencies[unity_rsp] ~= nil and group.dependencies[unity] ~= nil)
        end
      end, debug.traceback)
      vim.fn.delete(root, "rf")
      if not ok then error(err) end
    end)
  end
end)
