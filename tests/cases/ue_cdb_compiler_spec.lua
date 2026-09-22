local t = require("tests.harness")
t.bootstrap()

local platform = require("utils.platform")
local suffix = platform.driver().exe_suffix
local selected = require("utils.ue_goto.semantic_sidecar")._discover_toolchain_for_test()
local clang = selected.clangd_path and vim.fs.normalize(vim.fs.dirname(selected.clangd_path) .. "/clang++" .. suffix) or ""
local available = clang ~= "" and vim.fn.executable(clang) == 1
local root = available and vim.fs.dirname(vim.fs.dirname(clang)) or vim.fs.normalize(vim.fn.tempname())

local function args()
  return { "--target=aarch64-none-linux-android23", "--gcc-toolchain=" .. root,
    "--sysroot=" .. root .. "/sysroot", "-DKEEP=7", "-Ifirst", "-Isecond" }
end

local function resolve(arguments)
  local before = vim.deepcopy(arguments)
  local compiler, info = require("ue.cdb.compiler").resolve(arguments, root)
  t.assert_true(vim.deep_equal(arguments, before), "compiler resolution must not mutate argv")
  return compiler, info
end

local function fallback(arguments, reason)
  local compiler, info = resolve(arguments)
  t.assert_eq(compiler, "clang++")
  t.assert_eq(info.source, "fallback")
  t.assert_eq(info.reason, reason)
end

t.describe("RSP compiler identity", function()
  if available then
    t.it("resolves the driver from explicit Android build roots without changing flags", function()
      local compiler, info = resolve(args())
      t.assert_eq(compiler, clang)
      t.assert_eq(info.source, "ubt-android-toolchain-layout")
      t.assert_eq(info.reason, "resolved")
      t.assert_eq(info.toolchain, root)
    end)

    t.it("accepts separated options and the final overriding target and roots", function()
      local compiler = resolve({ "--target=x86_64-pc-windows-msvc", "--gcc-toolchain=/old",
        "--sysroot=/old/sysroot", "-target", "aarch64-none-linux-android23",
        "--gcc-toolchain", root, "--sysroot", root .. "/sysroot" })
      t.assert_eq(compiler, clang)
    end)

    t.it("does not let an unrelated NDKROOT choose the compiler", function()
      local previous = vim.env.NDKROOT
      local ok, err = xpcall(function()
        for _, value in ipairs({ root .. "/unrelated-ndk", root .. "/other-ndk" }) do
          vim.env.NDKROOT = value
          t.assert_eq(resolve(args()), clang)
        end
      end, debug.traceback)
      vim.env.NDKROOT = previous
      if not ok then error(err) end
    end)
  else
    t.skip("existing compiler identity", "selected clangd has no executable clang++ sibling", { native = true })
  end

  t.it("keeps the fallback without an explicit target or for non-Android targets", function()
    fallback({ "--gcc-toolchain=" .. root, "--sysroot=" .. root .. "/sysroot" }, "target-unavailable")
    local input = args()
    input[#input + 1] = "--target=x86_64-pc-windows-msvc"
    fallback(input, "target-not-android")
    input[#input] = "--target=aarch64-notandroid-linux-gnu"
    fallback(input, "target-not-android")
    input[#input] = "--target=aarch64-android-linux-gnu"
    fallback(input, "target-not-android")
  end)

  t.it("does not interpret text after the argument terminator as options", function()
    fallback({ "--", unpack(args()) }, "target-unavailable")
  end)

  t.it("keeps the fallback for absent, malformed, relative or conflicting roots", function()
    fallback({ "--target=aarch64-none-linux-android23" }, "toolchain-unavailable")
    local input = args()
    input[3] = "-DNO_SYSROOT=1"
    fallback(input, "sysroot-unavailable")
    input = args()
    input[#input + 1] = "--gcc-toolchain"
    fallback(input, "toolchain-unavailable")
    input = args()
    input[2], input[3] = "--gcc-toolchain=relative", "--sysroot=relative/sysroot"
    fallback(input, "toolchain-not-absolute")
    input = args()
    input[3] = "--sysroot=relative/sysroot"
    fallback(input, "sysroot-not-absolute")
    input = args()
    input[3] = "--sysroot=" .. root .. "/other/sysroot"
    fallback(input, "toolchain-sysroot-mismatch")
  end)

  t.it("keeps the fallback if the explicit toolchain lacks its compiler", function()
    local missing = vim.fs.normalize(vim.fn.tempname()) .. "/missing-compiler"
    fallback({ "--target=aarch64-none-linux-android23", "--gcc-toolchain=" .. missing,
      "--sysroot=" .. missing .. "/sysroot" }, "compiler-unavailable")
  end)

  local fd = vim.fn.executable("fd") == 1 or vim.fn.executable("fdfind") == 1
  if not available or not fd then
    t.skip("real RSP generator compiler identity", "existing compiler or fd unavailable", { native = true })
    return
  end

  t.it("the real RSP generator carries the resolved driver into commands and origin hashes", function()
    local fixture = vim.fs.normalize(vim.fn.tempname() .. "_rsp_compiler")
    local function write(path, content)
      vim.fn.mkdir(vim.fs.dirname(path), "p")
      local file = assert(io.open(path, "wb"))
      file:write(content)
      file:close()
    end
    local function read_json(path)
      return vim.json.decode(table.concat(vim.fn.readfile(path), "\n"))
    end
    local ok, err = xpcall(function()
      local source = fixture .. "/Engine/Source/Demo/Member.cpp"
      local build = fixture .. "/Engine/Intermediate/Build/Android/Fixture/Development/Demo"
      local unity = build .. "/Module.Demo.cpp"
      write(fixture .. "/Engine/Source/Fixture.Target.cs", "// Fixture target.\n")
      write(source, "int member;\n")
      write(unity, '#include "' .. source .. '"\n')
      write(build .. "/Module.Demo.cppa8.o.rsp", '--target=aarch64-none-linux-android23 '
        .. '--gcc-toolchain="' .. root .. '" --sysroot="' .. root .. '/sysroot" '
        .. '-DKEEP=7 -Ifirst -Isecond -c "' .. unity .. '"\n')
      local ctx = { engine_root = fixture,
        state = { target_platform = "Android", target_configuration = "Development", target = "Fixture" },
        paths = { active_cdb = fixture .. "/cache/compile_commands.json",
          cdb_shards_dir = fixture .. "/cache/shards", index_cdb_dir = fixture .. "/cache/index" },
      }
      local generated, path = require("ue")._ccjson_subprocess_run(ctx, function() end)
      t.assert_true(generated, path)
      local entries = read_json(path)
      t.assert_eq(#entries, 1)
      t.assert_eq(entries[1].arguments[1], clang)
      t.assert_eq(entries[1].file, source)
      local expected = { clang }
      vim.list_extend(expected, args())
      vim.list_extend(expected, { "-c", source })
      t.assert_true(vim.deep_equal(entries[1].arguments, expected), "generator changed other arguments")
      local origin = read_json(path .. ".unity-origin.json")
      t.assert_eq(#origin.groups, 1)
      t.assert_eq(origin.groups[1].commands[source], require("ue.cdb.unity_origin").entry_hash(entries[1]))
    end, debug.traceback)
    vim.fn.delete(fixture, "rf")
    if not ok then error(err) end
  end)
end)
