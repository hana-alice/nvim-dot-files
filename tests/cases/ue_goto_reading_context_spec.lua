local t = require("tests.harness")
t.bootstrap()

local semantic = require("utils.ue_goto.semantic_client")
local context = require("utils.ue_goto.reading_context")
local ownership = require("utils.ue_goto.reading_owner")
local commands = require("ue.clangd_commands")
local toolchain = require("utils.ue_goto.semantic_sidecar_libclang").discover_toolchain()

local function write(path, content)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local file = assert(io.open(path, "wb"))
  file:write(type(content) == "table" and vim.json.encode(content) or content)
  file:close()
end

local function fixture(body)
  local root = vim.fs.normalize(vim.fn.tempname() .. "-reading-native")
  vim.fn.mkdir(root, "p")
  root = vim.fs.normalize(vim.uv.fs_realpath(root) or root)
  local source, unrelated, header = root .. "/DifferentOrigin.cpp", root .. "/Unrelated.cpp", root .. "/subject.hpp"
  local semantic_dir = root .. "/.cache/nvim-ue/clangd/background-cdb"
  local header_lines = { "// A comment is not an entity, but still belongs to the compiler TU.",
    "int selected(int);", "int selected(double);", "#if EXACT_CHOICE", "using Arg = int;", "#else",
    "using Arg = double;", "#endif", "inline int header_call(){ return selected(Arg{}); }" }
  write(header, table.concat(header_lines, "\n") .. "\n")
  write(source, '#include "subject.hpp"\nint selected(int){return 1;}\nint selected(double){return 2;}\n')
  write(unrelated, "int unrelated(){return 3;}\n")
  local compile = { directory = root, file = source,
    argv = { toolchain.clangd_path:gsub("clangd([^/]*)$", "clang%1"), "-std=c++17", "-DEXACT_CHOICE=1", "-c", source } }
  local entries = {
    { directory = root, file = source, arguments = compile.argv },
    { directory = root, file = unrelated, arguments = { compile.argv[1], "-std=c++17", "-c", unrelated } },
  }
  write(root .. "/compile_commands.json", entries)
  write(semantic_dir .. "/compile_commands.json", entries)
  vim.fn.mkdir(root .. "/Intermediate/Build/Win64", "p")
  local previous = { buf = vim.api.nvim_get_current_buf(), win = vim.api.nvim_get_current_win(),
    ue = package.loaded.ue, discover = semantic.discover_toolchain, hidden = vim.o.hidden }
  local environment = {
    project_root = root, engine_root = root, cdb_dir = root, cdb_path = root .. "/compile_commands.json",
    active_cdb_path = root .. "/compile_commands.json", active_build_key = "Fixture",
    active_build = {}, build_fingerprint = "native-reading-build",
    clangd_path = toolchain.clangd_path, libclang_path = toolchain.libclang_path,
    evidence_roots = { root .. "/Intermediate/Build/Win64" },
  }
  local buf = vim.api.nvim_create_buf(true, false)
  vim.o.hidden = true
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_buf_set_name(buf, header)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, header_lines)
  vim.bo[buf].filetype, vim.bo[buf].modified = "cpp", false
  vim.api.nvim_win_set_cursor(0, { 9, header_lines[9]:find("selected", 1, true) - 1 })
  package.loaded.ue = {
    resolve_context = function() return { engine_root = root, project_root = root,
      state = { target_platform = "Win64", target_configuration = "Test" },
      paths = { active_cdb = environment.cdb_path } } end,
  }
  semantic.dispose()
  assert(vim.wait(3000, function() return not semantic.status().running end, 10), "previous test sidecar did not stop")
  commands._reset_for_test()
  semantic.discover_toolchain = function() return environment end
  local owner = ownership.begin()
  semantic.note_origin(owner.win, { id = "native-origin", context_id = "native-origin",
    origin_tu = source, cdb_dir = root, compile = compile, subject_membership = { header } }, environment.build_fingerprint)
  local ok, err = xpcall(function()
    body({ root = root, source = source, unrelated = unrelated, header = header, compile = compile,
      owner = owner, buf = buf, environment = environment, semantic_dir = semantic_dir })
  end, debug.traceback)
  ownership.cancel()
  semantic.dispose()
  assert(vim.wait(3000, function() return not semantic.status().running end, 10), "owned test sidecar did not stop")
  semantic.discover_toolchain = previous.discover
  package.loaded.ue, vim.o.hidden = previous.ue, previous.hidden
  if vim.api.nvim_win_is_valid(previous.win) then
    vim.api.nvim_set_current_win(previous.win)
    vim.api.nvim_win_set_buf(previous.win, previous.buf)
  end
  pcall(vim.api.nvim_buf_delete, buf, { force = true })
  commands._reset_for_test()
  vim.fn.delete(root, "rf")
  if not ok then error(err) end
end

t.describe("header reading native provenance", function()
  if not toolchain.ok then
    t.skip("native donor, forged membership and non-basename inclusion", toolchain.reason, { native = true })
    return
  end

  t.it("transports a native-proven non-basename donor without an exact header CDB entry", function()
    fixture(function(f)
      local done, proof, failure = false, nil, nil
      context.resolve_header(f.owner, nil, function(value, why) done, proof, failure = true, value, why end)
      t.assert_true(vim.wait(15000, function() return done end, 10), "native header proof timed out")
      t.assert_type(proof, "table", vim.inspect(failure))
      t.assert_eq(proof.response.usr, "c:@F@selected#I#")
      t.assert_eq(proof.context.origin_tu, f.source)
      local notifications, exact = {}, nil
      commands.ensure({ id = -31, config = { cmd = { toolchain.clangd_path,
        "--compile-commands-dir=" .. f.semantic_dir } }, notify = function(_, method, params)
        notifications[#notifications + 1] = { method = method, params = params }
        return true
      end }, f.buf, function(ok, reason, value)
        t.assert_true(ok, reason)
        exact = value
      end, { proven_header = proof, is_current = proof.is_current })
      t.assert_type(exact, "table")
      t.assert_eq(exact.compilationCommand[3], "-DEXACT_CHOICE=1")
      t.assert_eq(exact.compilationCommand[#exact.compilationCommand], f.header)
      t.assert_eq(#notifications, 1)
      t.assert_eq(notifications[1].params.settings.compilationDatabaseChanges[f.header], exact)
    end)
  end)

  t.it("rejects a forged origin membership when the compiler TU does not include the header", function()
    fixture(function(f)
      semantic.note_origin(f.owner.win, { id = "forged-origin", origin_tu = f.unrelated, cdb_dir = f.root,
        compile = { directory = f.root, file = f.unrelated,
          argv = { f.compile.argv[1], "-std=c++17", "-c", f.unrelated } },
        subject_membership = { f.header } }, f.environment.build_fingerprint)
      local done, proof, failure = false, nil, nil
      context.resolve_header(f.owner, nil, function(value, why) done, proof, failure = true, value, why end)
      t.assert_true(vim.wait(15000, function() return done end, 10))
      t.assert_nil(proof)
      t.assert_eq(failure.state, "unavailable")
      t.assert_eq(failure.reason, "no-proven-context")
    end)
  end)

  t.it("a native comment cursor proves inclusion but an unrelated active source remains rejected", function()
    fixture(function(f)
      local done, included = false, nil
      context.prove_companion(f.owner, f.source, f.header, function(value) done, included = true, value end)
      t.assert_true(vim.wait(15000, function() return done end, 10))
      t.assert_true(included)
      done, included = false, nil
      context.prove_companion(f.owner, f.unrelated, f.header, function(value) done, included = true, value end)
      t.assert_true(vim.wait(15000, function() return done end, 10))
      t.assert_false(included, "active CDB membership alone cannot prove a header companion")
    end)
  end)

  t.it("accepts compiler-emitted transitive header inclusion", function()
    fixture(function(f)
      write(f.root .. "/bridge.hpp", '#include "subject.hpp"\n')
      write(f.source, '#include "bridge.hpp"\nint selected(int){return 1;}\nint selected(double){return 2;}\n')
      local done, proof, failure = false, nil, nil
      context.resolve_header(f.owner, nil, function(value, why) done, proof, failure = true, value, why end)
      t.assert_true(vim.wait(15000, function() return done end, 10))
      t.assert_type(proof, "table", vim.inspect(failure))
      t.assert_eq(proof.response.usr, "c:@F@selected#I#")
    end)
  end)

  t.it("preserves a lexical alias of an included physical header", function()
    fixture(function(f)
      local alias = f.root .. "/../" .. vim.fs.basename(f.root) .. "/subject.hpp"
      local done, included = false, nil
      context.prove_companion(f.owner, f.source, alias, function(value) done, included = true, value end)
      t.assert_true(vim.wait(15000, function() return done end, 10))
      t.assert_true(included)
    end)
  end)

  t.it("preserves a real case alias on a case-insensitive Windows host", function()
    if vim.fn.has("win32") ~= 1 then t.skip("case-insensitive native header path", "Windows host required"); return end
    fixture(function(f)
      local done, included = false, nil
      context.prove_companion(f.owner, f.source, f.root .. "/SUBJECT.HPP", function(value) done, included = true, value end)
      t.assert_true(vim.wait(15000, function() return done end, 10))
      t.assert_true(included)
    end)
  end)

  t.it("retains the existing textual PCH coverage alongside a real binary PCH flag", function()
    fixture(function(f)
      local pch_header, pch, source = f.root .. "/prelude.hpp", f.root .. "/prelude.pch", f.root .. "/PchOrigin.cpp"
      write(pch_header, "#pragma once\nint from_pch();\n")
      write(source, "int use_pch(){return from_pch();}\n")
      local build = vim.system({ f.compile.argv[1], "-std=c++17", "-x", "c++-header", pch_header, "-o", pch },
        { text = true }):wait(10000)
      t.assert_eq(build.code, 0, tostring(build.stderr))
      local entries = { { directory = f.root, file = source,
        arguments = { f.compile.argv[1], "-std=c++17", "-include-pch", pch, "-include", pch_header, "-c", source } } }
      write(f.environment.cdb_path, entries)
      f.owner = ownership.begin()
      local done, included, reason = false, nil, nil
      context.prove_companion(f.owner, source, pch_header, function(value, why) done, included, reason = true, value, why end)
      t.assert_true(vim.wait(15000, function() return done end, 10))
      t.assert_true(included, reason)
    end)
  end)
end)
