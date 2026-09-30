local t = require("tests.harness")
t.bootstrap()

local function write(path, content)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local handle = assert(io.open(path, "wb"))
  handle:write(content)
  handle:close()
end

local function read(path)
  local handle = assert(io.open(path, "rb"))
  local content = handle:read("*a")
  handle:close()
  return vim.json.decode(content)
end

local discovery = require("utils.ue_goto.semantic_sidecar")._discover_toolchain_for_test()
local python = vim.fn.exepath("python")
if python == "" then python = vim.fn.exepath("python3") end
local windows = vim.fn.has("win32") == 1
local clang = discovery.libclang_path and (vim.fs.dirname(discovery.libclang_path) .. "/clang++.exe") or ""

t.describe("compiler-proven closed VFS aliases", function()
  if not windows then
    t.skip("Windows mixed-separator native VFS fixtures", "Windows-specific LLVM path behavior")
    return
  end
  if not discovery.ok or python == "" or vim.fn.executable(clang) ~= 1 then
    t.skip("real libclang and clang VFS fixtures", discovery.reason or "native-toolchain-unavailable", { native = true })
    return
  end

  local function owned(argv)
    local command = { python, "-I", "-c",
      "import subprocess,sys; p=subprocess.run(sys.argv[1:], capture_output=True, creationflags=subprocess.CREATE_NO_WINDOW | subprocess.IDLE_PRIORITY_CLASS); sys.stdout.buffer.write(p.stdout); sys.stderr.buffer.write(p.stderr); sys.exit(p.returncode)" }
    vim.list_extend(command, argv)
    return vim.system(command, { text = true }):wait(30000)
  end

  local function fixture(body)
    local root = vim.fn.tempname():gsub("\\", "/") .. "_vfs_aliases"
    vim.fn.mkdir(root, "p")
    root = vim.fs.normalize(vim.uv.fs_realpath(root) or root)
    local ok, err = xpcall(function()
      local function unit(name)
        local public = root .. "/" .. name
        local source = root .. "/" .. name .. ".cpp"
        local target = public .. "/HAL/target.h"
        write(target, "#define FROZEN_VALUE 7\n")
        write(public .. "/Misc/relative.h", '#include "../HAL/target.h"\n')
        write(public .. "/start.h", '#include "Misc/relative.h"\n')
        write(source, '#include "' .. public .. '/start.h"\nstatic_assert(FROZEN_VALUE == 7);\n')
        return {
          directory = root, file = source,
          arguments = { "clang++", "-std=c++17", "-DMUST_KEEP=1", "-c", source, "-o", source .. ".o" },
        }, { source, public .. "/start.h", public .. "/Misc/relative.h", target }, target
      end
      local function collect(entries)
        write(root .. "/request.json", vim.json.encode({ entries = entries, libclang_path = discovery.libclang_path }))
        local result = owned({ python, "-I", vim.fn.stdpath("config") .. "/tools/clangd_vfs_aliases.py",
          "--request", root .. "/request.json", "--out", root .. "/result.json" })
        t.assert_true(result.code == 0 or result.code == 1, result.stderr or result.stdout)
        local document = read(root .. "/result.json")
        t.assert_eq(result.code, document.ok and 0 or 1)
        return document
      end
      body(root, unit, collect)
    end, debug.traceback)
    vim.fn.delete(root, "rf")
    if not ok then error(err) end
  end

  t.it("collects a mixed-slash sibling include from an original compiler TU", function()
    fixture(function(root, unit, collect)
      local entry, _, target = unit("Public")
      local result = collect({ entry })
      t.assert_true(result.ok, vim.inspect(result))
      t.assert_eq(#result.aliases, 1)
      t.assert_eq(vim.fs.normalize(result.aliases[1].alias), root .. "/HAL/target.h")
      t.assert_eq(vim.fs.normalize(result.aliases[1].target), target)
      t.assert_eq(#result.directory_aliases, 1)
      t.assert_eq(vim.fs.normalize(result.directory_aliases[1].alias), root .. "/Public/Misc")
      t.assert_eq(result.directory_aliases[1].alias, result.directory_aliases[1].target)
      t.assert_eq(result.evidence.translation_units[1].parse_code, 0)
      t.assert_eq(result.evidence.translation_units[1].diagnostics.error_count, 0)
      t.assert_eq(result.evidence.include_records[1].spelling, "../HAL/target.h")
      t.assert_eq(vim.fn.filereadable(entry.file .. ".o"), 0)
    end)
  end)

  t.it("rejects contradictory alias targets from otherwise valid original TUs", function()
    fixture(function(_, unit, collect)
      local a = unit("First")
      local b = unit("Second")
      local result = collect({ a, b })
      t.assert_false(result.ok)
      t.assert_eq(#result.aliases, 0)
      t.assert_eq(result.reason, "include-alias-unproven")
      t.assert_contains(result.evidence.translation_units[2].errors[1], "alias-target-collision")
    end)
  end)

  t.it("collects aliases with an effective driver command and trailing source terminator", function()
    fixture(function(root, unit, collect)
      local entry, _, target = unit("Public")
      write(target, "#define FROZEN_VALUE 7\n"
        .. "#if !defined(__aarch64__) || MUST_KEEP != 1\n#error effective context lost\n#endif\n")
      entry.arguments = { clang, "--driver-mode=g++", "--target=aarch64-none-linux-android23",
        "-std=c++17", "-DMUST_KEEP=1", "-nostdinc", "--", entry.file }
      local result = collect({ entry })
      t.assert_true(result.ok, vim.inspect(result))
      t.assert_eq(#result.aliases, 1)
      t.assert_eq(vim.fs.normalize(result.aliases[1].target), target)
      entry.arguments[#entry.arguments + 1] = root .. "/second.cpp"
      local invalid = collect({ entry })
      t.assert_false(invalid.ok)
      t.assert_eq(invalid.reason, "invalid-compilation-context")
      t.assert_contains(invalid.evidence.translation_units[1].error, "input terminator")
    end)
  end)

  t.it("rejects physical alias collisions and original compiler errors", function()
    fixture(function(root, unit, collect)
      local entry = unit("Public")
      write(root .. "/HAL/target.h", "#define DIFFERENT_HEADER 1\n")
      local collision = collect({ entry })
      t.assert_false(collision.ok)
      t.assert_eq(#collision.aliases, 0)
      t.assert_contains(collision.evidence.translation_units[1].errors[1], "alias-collides-with-physical-file")
      write(entry.file, "#error original TU is invalid\n")
      local invalid = collect({ entry })
      t.assert_false(invalid.ok)
      t.assert_eq(invalid.reason, "tu-parse-error")
      t.assert_true(invalid.evidence.translation_units[1].diagnostics.error_count > 0)
    end)
  end)

  t.it("resolves original names to frozen bytes while denying existing unmapped files", function()
    fixture(function(root, unit, collect)
      local entry, files, target = unit("Public")
      local result = collect({ entry })
      t.assert_true(result.ok, vim.inspect(result))
      t.assert_eq(#result.aliases, 1)
      local roots = {}
      for number, file in ipairs(files) do
        local frozen = root .. "/snapshots/" .. number .. ".txt"
        local handle = assert(io.open(file, "rb"))
        write(frozen, handle:read("*a"))
        handle:close()
        roots[#roots + 1] = { type = "file", name = file:gsub("/", "\\"), ["external-contents"] = frozen:gsub("/", "\\") }
      end
      local upper = root .. "/aliases.json"
      local lower = root .. "/snapshot.json"
      local alias = result.aliases[1]
      local directory_alias = result.directory_aliases[1]
      write(upper, vim.json.encode({ version = 0, ["case-sensitive"] = false,
        ["use-external-names"] = true, fallthrough = true,
        roots = {
          { type = "file", name = alias.alias, ["external-contents"] = alias.target },
          { type = "directory-remap", name = directory_alias.alias, ["external-contents"] = directory_alias.target },
        },
      }))
      roots[#roots + 1] = { type = "file", name = upper:gsub("/", "\\"), ["external-contents"] = upper:gsub("/", "\\") }
      local denied = root .. "/denied.cpp"
      local unmapped = root .. "/Public/Misc/existing-unmapped.h"
      write(unmapped, "struct OutsideSnapshot {};\n")
      write(denied, '#include "' .. unmapped .. '"\n')
      roots[#roots + 1] = { type = "file", name = denied:gsub("/", "\\"), ["external-contents"] = denied:gsub("/", "\\") }
      write(lower, vim.json.encode({ version = 0, ["case-sensitive"] = false,
        ["use-external-names"] = false, fallthrough = false, roots = roots,
      }))
      -- The source asserts 7. Any accidental read of live bytes must now fail.
      write(target, "#define FROZEN_VALUE 99\n")
      local function compile(source, upper_enabled)
        local argv = { clang, "-std=c++17", "-fsyntax-only", "-ivfsoverlay", lower }
        if upper_enabled then vim.list_extend(argv, { "-ivfsoverlay", upper }) end
        argv[#argv + 1] = source
        return owned(argv)
      end
      local original_failure = compile(entry.file, false)
      t.assert_eq(original_failure.code, 1)
      t.assert_contains(original_failure.stderr, "file not found")
      local restored = compile(entry.file, true)
      t.assert_eq(restored.code, 0, restored.stderr)
      local closed = compile(denied, true)
      t.assert_eq(closed.code, 1)
      t.assert_contains(closed.stderr, "file not found")
      t.assert_eq(vim.fn.filereadable(unmapped), 1)
    end)
  end)
end)
