local t = require("tests.harness")
t.bootstrap()
local inventory = require("utils.file_inventory")
local function command(root, ...)
  local args = { "git", "--no-optional-locks", "-C", root }
  vim.list_extend(args, { ... })
  local result = vim.system(args, { text = true }):wait()
  t.assert_eq(result.code, 0, result.stderr)
  return result.stdout
end
local function await(start)
  local result
  start(function(...) result = { n = select("#", ...), ... } end)
  t.assert_true(vim.wait(15000, function() return result ~= nil end, 5))
  return unpack(result, 1, result.n)
end
local function fixture(body)
  if vim.fn.executable("git") ~= 1 then t.skip("Git inventory native fixture", "Git unavailable", { native = true }); return end
  local root = vim.fn.tempname():gsub("\\", "/") .. "-inventory-x2"
  vim.fn.mkdir(root .. "/Source/Intermediate", "p"); vim.fn.mkdir(root .. "/Other", "p")
  vim.fn.writefile({ "*", "!*/", "!*.cpp", "!*.h", "!*.c", "!*.xml", "Ignored*" }, root .. "/.gitignore")
  local files = { "Source/Good.Cpp", "Source/Keep.cpp", "Source/Legacy.H", "Source/Legacy.C",
    "Source/Schema.XML", "Source/Ignored.H", "Source/Intermediate/Generated.H", "Other/Outside.H" }
  for _, path in ipairs(files) do vim.fn.writefile({ "int INVENTORY_UPPERCASE_FIXTURE_TOKEN;" }, root .. "/" .. path) end
  command(root, "init"); command(root, "config", "core.ignorecase", "true")
  command(root, "add", "--force", ".")
  body(root, files)
end
t.describe("X2 Git/fd ignore equivalence", function()
  t.it("supplements tracked uppercase extensions without ignored/build/out-of-scope paths or duplicate fd entries", function()
    fixture(function(root)
      local list, err = await(function(cb)
        inventory.supplement_tracked(root, { "Source" }, { "Source/Keep.cpp", "Source/Good.Cpp" }, cb,
          { excludes = { "Intermediate" } })
      end)
      t.assert_true(list ~= nil, err); t.assert_eq(#list, 5)
      for _, path in ipairs({ "Source/Good.Cpp", "Source/Keep.cpp", "Source/Legacy.H", "Source/Legacy.C", "Source/Schema.XML" }) do
        t.assert_true(vim.tbl_contains(list, path), path)
      end
      t.assert_false(vim.tbl_contains(list, "Source/Ignored.H"))
      t.assert_false(vim.tbl_contains(list, "Source/Intermediate/Generated.H"))
      t.assert_false(vim.tbl_contains(list, "Other/Outside.H"))
    end)
  end)
  t.it("uses the actual Git case setting rather than unconditionally rescuing tracked files", function()
    fixture(function(root)
      command(root, "config", "core.ignorecase", "false")
      local list, err = await(function(cb)
        inventory.supplement_tracked(root, { "Source" }, { "Source/Keep.cpp" }, cb, { excludes = { "Intermediate" } })
      end)
      t.assert_true(list ~= nil, err); t.assert_eq(#list, 1)
    end)
  end)
  t.it("the existing synchronous prepare twin receives the same complete scoped inventory", function()
    fixture(function(root)
      local list, err = inventory.supplement_tracked_sync(root, { "Source" }, { "Source/Keep.cpp" },
        { excludes = { "Intermediate" } })
      t.assert_true(list ~= nil, err); t.assert_eq(#list, 5)
      t.assert_true(vim.tbl_contains(list, "Source/Good.Cpp"))
      t.assert_false(vim.tbl_contains(list, "Source/Ignored.H"))
    end)
  end)
  t.it("Git capture error does not publish the partial fd inventory as complete", function()
    fixture(function(root)
      local system = vim.system
      vim.system = function(_, _, cb)
        vim.schedule(function() cb({ code = 124, stdout = "", stderr = "injected timeout" }) end)
        return { is_closing = function() return true end }
      end
      local ok, list, err = pcall(await, function(cb)
        inventory.supplement_tracked(root, { "Source" }, { "Source/Keep.cpp" }, cb)
      end)
      vim.system = system
      if not ok then error(list) end
      t.assert_nil(list); t.assert_contains(err, "unavailable")
    end)
  end)
end)
