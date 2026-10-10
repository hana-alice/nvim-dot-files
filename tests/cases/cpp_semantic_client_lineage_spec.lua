local t = require("tests.harness")
t.bootstrap()

local client = require("utils.ue_goto.semantic_client")
local model = require("utils.ue_goto.semantic_context")

local function write(path, value)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local bytes = type(value) == "table" and vim.json.encode(value) or value
  local file = assert(io.open(path, "wb"))
  file:write(bytes)
  file:close()
  return bytes
end

local function fixture(body, toolchain)
  client.dispose()
  assert(vim.wait(3000, function() return not client.status().running end, 10))
  client._reset_for_test()
  local root = vim.fs.normalize(vim.fn.tempname() .. "-source-lineage")
  vim.fn.mkdir(root, "p")
  root = vim.fs.normalize(vim.uv.fs_realpath(root) or root)
  local previous = { buffer = vim.api.nvim_get_current_buf(), hidden = vim.o.hidden, request = client.request }
  local f = { root = root, source = root .. "/DistinctOrigin.cpp", header = root .. "/subject.hpp", ops = {} }
  local lines = { "int selected();", "inline int use(){return selected();}" }
  write(f.header, table.concat(lines, "\n") .. "\n")
  write(f.source, '#include "subject.hpp"\nint selected(){return 1;}\n')
  local compiler = toolchain and toolchain.clangd_path:gsub("clangd([^/]*)$", "clang%1") or "clang++"
  f.compile = { directory = root, file = f.source,
    argv = { compiler, "-std=c++17", "-DFIXTURE_SELECTION=1", "-c", f.source } }
  f.environment = { project_root = root, engine_root = root, cdb_dir = root,
    cdb_path = root .. "/compile_commands.json", active_cdb_path = root .. "/selection/Build-A.json",
    active_manifest_path = root .. "/selection/manifest.json", build_fingerprint = "fixture-build",
    active_build_key = "Build-A", active_build = {}, evidence_roots = { root .. "/Intermediate/Build" } }
  vim.fn.mkdir(f.environment.evidence_roots[1], "p")
  local entries = { { directory = root, file = f.source, arguments = f.compile.argv } }
  local merged = write(f.environment.cdb_path, entries)
  local active = write(f.environment.active_cdb_path, entries)
  write(f.environment.active_manifest_path, { active = "Build-A" })
  write(f.environment.cdb_path .. ".pipeline-result.json", { provenance = { schema = 1, active_key = "Build-A",
    active_cdb_sha256 = vim.fn.sha256(active), merged_cdb_sha256 = vim.fn.sha256(merged) } })
  f.buffer = vim.api.nvim_create_buf(true, false)
  vim.o.hidden = true
  vim.api.nvim_set_current_buf(f.buffer)
  vim.api.nvim_buf_set_name(f.buffer, f.header)
  vim.api.nvim_buf_set_lines(f.buffer, 0, -1, false, lines)
  vim.bo[f.buffer].filetype, vim.bo[f.buffer].modified = "cpp", false
  local column = assert(lines[2]:find("selected", 1, true))
  vim.api.nvim_win_set_cursor(0, { 2, column - 1 })
  f.snapshot = client.begin_action(f.buffer)
  f.spec = { snapshot = f.snapshot, path = f.header, line = 2, column = column, environment = f.environment }
  f.candidate = { id = "source-candidate", origin_tu = f.source, compile = vim.deepcopy(f.compile),
    cdb_dir = root, subject_membership = { f.source }, source_exact_candidate = true,
    evidence_kind = "clangd-source-exact-command" }
  function f.note_candidate()
    client.note_origin(f.snapshot.winid, f.candidate, f.environment.build_fingerprint)
  end
  function f.proof()
    return { state = "resolved", context_id = "source-proof", origin_tu = f.source,
      compile = vim.deepcopy(f.compile), document_version = f.snapshot.document_version }
  end
  function f.entity()
    return { state = "resolved", context_id = "source-proof", origin_tu = f.source, usr = "usr:selected",
      declaration = { path = f.header, line = 1, column = 1 },
      definition = { path = f.source, line = 2, column = 1 }, document_version = f.snapshot.document_version }
  end
  function f.resolve()
    client.resolve_header(f.spec, function(response, reason) f.done, f.response, f.reason = true, response, reason end)
    if toolchain then t.assert_true(vim.wait(15000, function() return f.done end, 10), "native lineage timed out") end
  end
  function f.next_header()
    -- Simulate only the coordinator's completed jump committing its result.
    client.note_origin(f.snapshot.winid, f.response.origin_context, f.environment.build_fingerprint)
    f.header = f.root .. "/Another.hpp"
    local next_lines = { "int selected();", "inline int another_use(){return selected();}" }
    write(f.header, table.concat(next_lines, "\n") .. "\n")
    vim.api.nvim_buf_set_name(f.buffer, f.header)
    vim.api.nvim_buf_set_lines(f.buffer, 0, -1, false, next_lines)
    vim.bo[f.buffer].modified = false
    local next_column = assert(next_lines[2]:find("selected", 1, true))
    vim.api.nvim_win_set_cursor(0, { 2, next_column - 1 })
    f.snapshot = client.begin_action(f.buffer)
    f.spec.snapshot, f.spec.path, f.spec.column = f.snapshot, f.header, next_column
    f.done, f.response, f.reason = false, nil, nil
  end
  f.note_candidate()
  if toolchain then
    f.environment.clangd_path, f.environment.libclang_path = toolchain.clangd_path, toolchain.libclang_path
    f.environment.toolchain_identity = toolchain.toolchain_identity
  end
  client.request = function(op, fields, callback, environment, snapshot)
    f.ops[#f.ops + 1] = { op = op, fields = vim.deepcopy(fields) }
    if toolchain then return previous.request(op, fields, callback, environment, snapshot) end
    return f.reply(op, fields, callback)
  end
  local ok, err = xpcall(function() body(f) end, debug.traceback)
  client.request = previous.request
  client.dispose()
  assert(vim.wait(3000, function() return not client.status().running end, 10))
  client._reset_for_test()
  vim.api.nvim_set_current_buf(previous.buffer)
  pcall(vim.api.nvim_buf_delete, f.buffer, { force = true })
  vim.o.hidden = previous.hidden
  vim.fn.delete(root, "rf")
  if not ok then error(err) end
end

t.describe("cpp semantic client: source exact candidate", function()
  t.it("requires fresh exact proof before one header query and returns membership without committing it", function()
    fixture(function(f)
      f.reply = function(op, fields, callback)
        if op == "prove" then
          t.assert_eq(fields.source, f.source)
          t.assert_eq(fields.cdb_path, f.environment.cdb_path)
          t.assert_eq(fields.active_cdb_path, f.environment.active_cdb_path)
          t.assert_eq(fields.active_manifest_path, f.environment.active_manifest_path)
          callback(f.proof())
        else
          t.assert_eq(op, "query")
          t.assert_eq(#fields.contexts, 1)
          t.assert_eq(fields.contexts[1].origin_tu, f.source)
          t.assert_eq(fields.query.path, f.header)
          t.assert_eq(fields.query.line, f.spec.line)
          t.assert_eq(fields.query.column, f.spec.column)
          t.assert_false(model.context_supports_subject(fields.contexts[1], f.header))
          callback(f.entity())
        end
      end
      f.resolve()
      t.assert_eq(#f.ops, 2)
      t.assert_eq(f.response.state, "resolved")
      t.assert_true(model.context_supports_subject(f.response.origin_context, f.header))
      t.assert_eq(f.response.origin_context.evidence_kind, "source-exact-compiler-inclusion")
      t.assert_true(f.response.origin_context.source_exact_candidate)
      t.assert_nil(client.window_origin(f.snapshot.winid, f.environment.build_fingerprint),
        "inspection resolution must not commit window lineage")
    end)
  end)

  t.it("a committed header result carries only the original source candidate to the next unproven header", function()
    fixture(function(f)
      f.reply = function(op, fields, callback)
        if op == "prove" then callback(f.proof())
        else
          t.assert_eq(op, "query")
          t.assert_eq(#fields.contexts, 1)
          t.assert_eq(fields.contexts[1].origin_tu, f.source)
          t.assert_false(model.context_supports_subject(fields.contexts[1], f.header))
          callback(f.entity())
        end
      end
      f.resolve()
      local first_header = f.header
      f.next_header()
      f.resolve()
      t.assert_eq(#f.ops, 4)
      t.assert_eq(f.ops[3].op, "prove")
      t.assert_eq(f.ops[4].op, "query")
      t.assert_eq(f.ops[4].fields.query.path, f.header)
      t.assert_true(model.context_supports_subject(f.response.origin_context, first_header))
      t.assert_true(model.context_supports_subject(f.response.origin_context, f.header))
      t.assert_true(f.response.origin_context.source_exact_candidate)
      t.assert_nil(client.window_origin(f.snapshot.winid, f.environment.build_fingerprint))
    end)
  end)

  for _, failure in ipairs({ "descriptor-mismatch", "merged-cdb-selection-mismatch" }) do
    t.it("a carried source candidate must pass fresh proof again: " .. failure, function()
      fixture(function(f)
        f.reply = function(op, _, callback)
          callback(op == "prove" and f.proof() or f.entity())
        end
        f.resolve()
        f.next_header()
        f.reply = function(op, _, callback)
          t.assert_eq(op, "prove")
          if failure == "descriptor-mismatch" then
            local proof = f.proof()
            proof.compile.argv[3] = "-DFIXTURE_SELECTION=2"
            callback(proof)
          else callback({ state = "unavailable", reason = failure }) end
        end
        f.resolve()
        t.assert_eq(#f.ops, 3)
        t.assert_eq(f.response.reason,
          failure == "descriptor-mismatch" and "source-exact-compile-descriptor-mismatch" or failure)
        t.assert_nil(f.response.origin_context)
      end)
    end)
  end

  for _, failure in ipairs({ "empty-proof", "empty-compile", "merged-cdb-selection-mismatch", "semantic sidecar request timed out" }) do
    t.it("rejects candidate before header query: " .. failure, function()
      fixture(function(f)
        f.reply = function(op, _, callback)
          t.assert_eq(op, "prove")
          if failure == "empty-proof" then callback(nil)
          elseif failure == "empty-compile" then local proof = f.proof(); proof.compile = nil; callback(proof)
          else callback({ state = "unavailable", reason = failure }) end
        end
        f.resolve()
        t.assert_eq(#f.ops, 1)
        t.assert_eq(f.response.state, "unavailable")
        local expected = failure == "empty-proof" and "source-exact-proof-unavailable"
          or failure == "empty-compile" and "source-exact-compile-descriptor-mismatch" or failure
        t.assert_eq(f.response.reason, expected)
      end)
    end)
  end

  t.it("uses descriptor values across object key order and refuses altered argv", function()
    fixture(function(f)
      f.reply = function(op, _, callback)
        if op == "prove" then
          local proof = f.proof()
          proof.compile = { argv = proof.compile.argv, file = proof.compile.file, directory = proof.compile.directory }
          callback(proof)
        else
          t.assert_eq(op, "query")
          callback(f.entity())
        end
      end
      f.resolve()
      t.assert_eq(f.response.state, "resolved")
      f.note_candidate()
      f.done, f.response = false, nil
      f.reply = function(op, _, callback)
        t.assert_eq(op, "prove")
        local proof = f.proof()
        proof.compile.argv[3] = "-DFIXTURE_SELECTION=2"
        callback(proof)
      end
      f.resolve()
      t.assert_eq(#f.ops, 3)
      t.assert_eq(f.response.reason, "source-exact-compile-descriptor-mismatch")
    end)
  end)

  t.it("re-catalogs an actual nonmember and preserves the rejection evidence", function()
    fixture(function(f)
      f.reply = function(op, _, callback)
        if op == "prove" then callback(f.proof())
        elseif op == "query" then callback({ state = "invalid-semantic-context", reason = "invalid-query-file-not-in-tu" })
        else
          t.assert_eq(op, "catalog")
          callback({ state = "unavailable", reason = "no-proven-context" })
        end
      end
      f.resolve()
      t.assert_eq(#f.ops, 3)
      t.assert_eq(f.ops[3].op, "catalog")
      t.assert_eq(f.response.reason, "no-proven-context")
      t.assert_eq(f.response.source_candidate_failure.reason, "invalid-query-file-not-in-tu")
      t.assert_nil(f.response.origin_context)
      t.assert_nil(client.window_origin(f.snapshot.winid, f.environment.build_fingerprint))
    end)
  end)

  for _, failure in ipairs({ "invalid-cursor", "semantic sidecar stopping" }) do
    t.it("keeps a header query failure instead of treating it as inclusion: " .. failure, function()
      fixture(function(f)
        f.reply = function(op, _, callback)
          if op == "prove" then callback(f.proof())
          else
            t.assert_eq(op, "query")
            if failure == "invalid-cursor" then callback({ state = "invalid-semantic-context", reason = failure })
            else callback(nil, failure) end
          end
        end
        f.resolve()
        t.assert_eq(#f.ops, 2)
        t.assert_eq(f.response.reason, failure)
        t.assert_nil(f.response.origin_context)
      end)
    end)
  end

  for _, stage in ipairs({ "prove", "query" }) do
    t.it("stale " .. stage .. " cannot replace newer window lineage", function()
      fixture(function(f)
        f.reply = function(op, _, callback)
          if op == "prove" and stage == "query" then callback(f.proof()); return end
          t.assert_eq(op, stage)
          f.pending = callback
        end
        f.resolve()
        client.cancel_action()
        client.note_origin(f.snapshot.winid, { origin_tu = f.root .. "/Newer.cpp", subject_membership = { f.header } },
          f.environment.build_fingerprint)
        f.pending(stage == "prove" and f.proof() or f.entity())
        t.assert_nil(f.response)
        t.assert_eq(f.reason, "superseded")
        t.assert_eq(client.window_origin(f.snapshot.winid, f.environment.build_fingerprint).origin_tu, f.root .. "/Newer.cpp")
      end)
    end)
  end

  t.it("keeps normal member reuse ahead of the source candidate path", function()
    fixture(function(f)
      f.candidate.subject_membership = { f.source, f.header }
      f.note_candidate()
      f.reply = function(op, _, callback) t.assert_eq(op, "query"); callback(f.entity()) end
      f.resolve()
      t.assert_eq(#f.ops, 1)
      t.assert_eq(f.response.state, "resolved")
    end)
  end)

  for _, invalid in ipairs({ "unmarked", "incomplete", "header-origin", "different-build" }) do
    t.it("does not upgrade unsupported window lineage: " .. invalid, function()
      fixture(function(f)
        if invalid == "unmarked" then f.candidate.source_exact_candidate = nil
        elseif invalid == "incomplete" then f.candidate.compile.argv = {}
        elseif invalid == "header-origin" then
          f.candidate.origin_tu, f.candidate.compile.file = f.header, f.header
        end
        f.note_candidate()
        if invalid == "different-build" then f.environment.build_fingerprint = "new-build" end
        f.reply = function(op, _, callback)
          t.assert_eq(op, "catalog")
          callback({ state = "unavailable", reason = "no-proven-context" })
        end
        f.resolve()
        t.assert_eq(#f.ops, 1)
        t.assert_eq(f.response.reason, "no-proven-context")
      end)
    end)
  end
end)

t.describe("cpp semantic client: native source exact candidate", function()
  local toolchain = require("utils.ue_goto.semantic_sidecar_libclang").discover_toolchain()
  if not toolchain.ok then
    t.skip("native candidate inclusion and selection-switch refusal", toolchain.reason, { native = true })
    return
  end

  t.it("resolves a non-basename header through the exact source command and real compiler inclusion", function()
    fixture(function(f)
      f.resolve()
      t.assert_eq(#f.ops, 2)
      t.assert_eq(f.ops[1].op, "prove")
      t.assert_eq(f.ops[2].op, "query")
      t.assert_eq(#f.ops[2].fields.contexts, 1)
      t.assert_eq(f.response.state, "resolved", vim.inspect(f.response))
      t.assert_contains(f.response.usr, "selected")
      t.assert_eq(f.response.origin_context.origin_tu, f.source)
      t.assert_eq(f.response.origin_context.evidence_kind, "source-exact-compiler-inclusion")
      t.assert_true(model.context_supports_subject(f.response.origin_context, f.header))
      t.assert_nil(client.window_origin(f.snapshot.winid, f.environment.build_fingerprint))
    end, toolchain)
  end)

  t.it("a carried source command proves native inclusion separately for two different headers", function()
    fixture(function(f)
      write(f.root .. "/Another.hpp", "int selected();\ninline int another_use(){return selected();}\n")
      write(f.source, '#include "subject.hpp"\n#include "Another.hpp"\nint selected(){return 1;}\n')
      f.resolve()
      t.assert_eq(f.response.state, "resolved")
      local first_header = f.header
      f.next_header()
      f.resolve()
      t.assert_eq(#f.ops, 4)
      t.assert_eq(f.ops[3].op, "prove")
      t.assert_eq(f.ops[4].op, "query")
      t.assert_eq(#f.ops[4].fields.contexts, 1)
      t.assert_eq(f.response.state, "resolved", vim.inspect(f.response))
      t.assert_true(model.context_supports_subject(f.response.origin_context, first_header))
      t.assert_true(model.context_supports_subject(f.response.origin_context, f.header))
      t.assert_true(f.response.origin_context.source_exact_candidate)
    end, toolchain)
  end)

  t.it("a carried source command is rejected after selection changes before a second header query", function()
    fixture(function(f)
      f.resolve()
      t.assert_eq(f.response.state, "resolved")
      f.next_header()
      f.environment.active_cdb_path = f.root .. "/selection/Build-B.json"
      write(f.environment.active_cdb_path, { { directory = f.root, file = f.source, arguments = f.compile.argv } })
      write(f.environment.active_manifest_path, { active = "Build-B" })
      f.resolve()
      t.assert_eq(#f.ops, 3)
      t.assert_eq(f.ops[3].op, "prove")
      t.assert_eq(f.response.state, "unavailable")
      t.assert_eq(f.response.reason, "merged-cdb-selection-mismatch")
      t.assert_nil(f.response.origin_context)
    end, toolchain)
  end)

  t.it("rejects old merged content after a real active selection switch before querying the header", function()
    fixture(function(f)
      f.environment.active_cdb_path = f.root .. "/selection/Build-B.json"
      write(f.environment.active_cdb_path, { { directory = f.root, file = f.source, arguments = f.compile.argv } })
      write(f.environment.active_manifest_path, { active = "Build-B" })
      f.resolve()
      t.assert_eq(#f.ops, 1)
      t.assert_eq(f.ops[1].op, "prove")
      t.assert_eq(f.response.state, "unavailable")
      t.assert_eq(f.response.reason, "merged-cdb-selection-mismatch")
      t.assert_nil(f.response.origin_context)
    end, toolchain)
  end)

  t.it("an existing but non-included header goes back to catalog without gaining membership", function()
    fixture(function(f)
      write(f.source, "int unrelated(){return 1;}\n")
      f.resolve()
      t.assert_eq(#f.ops, 3)
      t.assert_eq(f.ops[3].op, "catalog")
      t.assert_eq(f.response.state, "unavailable")
      t.assert_eq(f.response.source_candidate_failure.reason, "invalid-query-file-not-in-tu")
      t.assert_nil(f.response.origin_context)
      t.assert_nil(client.window_origin(f.snapshot.winid, f.environment.build_fingerprint))
    end, toolchain)
  end)
end)
