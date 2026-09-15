local t = require("tests.harness")
t.bootstrap()

local protocol = require("utils.ue_goto.semantic_protocol")
local semantic_sidecar = require("utils.ue_goto.semantic_sidecar")

local cfg = vim.fn.stdpath("config")
local fixture_root = cfg .. "/tests/fixtures/cpp_semantic"

local function read_all(path)
  local fd = assert(io.open(path, "rb"))
  local data = fd:read("*a")
  fd:close()
  return data
end

local function find_marker_position(path, marker, token)
  local line_no = 0
  for line in io.lines(path) do
    line_no = line_no + 1
    if line:find(marker, 1, true) then
      local column = assert(line:find(token, 1, true), "token not found for " .. marker)
      return {
        path = vim.fs.normalize(path),
        line = line_no,
        column = column,
      }
    end
  end
  error("marker not found: " .. marker)
end

local function system_decode(cmd, stdin)
  local result = vim.system(cmd, {
    cwd = cfg,
    stdin = stdin,
    text = true,
  }):wait()

  local frames = {}
  for line in (result.stdout or ""):gmatch("[^\r\n]+") do
    frames[#frames + 1] = vim.json.decode(line)
  end
  return result, frames
end

local function sidecar_cmd()
  return {
    vim.v.progpath,
    "--headless",
    "-u",
    "NONE",
    "-l",
    cfg .. "/scripts/ue_clang_semanticd.lua",
  }
end

local function build_compile_commands(root)
  local entries = {
    {
      file = vim.fs.normalize(root .. "/direct.cpp"),
      args = { "clang++", "-std=c++20", "-c", vim.fs.normalize(root .. "/direct.cpp") },
    },
    {
      file = vim.fs.normalize(root .. "/caller.cpp"),
      args = { "clang++", "-std=c++20", "-c", vim.fs.normalize(root .. "/caller.cpp") },
    },
    {
      file = vim.fs.normalize(root .. "/overlay.cpp"),
      args = { "clang++", "-std=c++20", "-c", vim.fs.normalize(root .. "/overlay.cpp") },
    },
    {
      file = vim.fs.normalize(root .. "/donor_one.cpp"),
      args = {
        "clang++",
        "-std=c++20",
        "-DSEMANTIC_USE_ONE=1",
        "-c",
        vim.fs.normalize(root .. "/donor_one.cpp"),
      },
    },
    {
      file = vim.fs.normalize(root .. "/donor_two.cpp"),
      args = {
        "clang++",
        "-std=c++20",
        "-DSEMANTIC_USE_ONE=0",
        "-c",
        vim.fs.normalize(root .. "/donor_two.cpp"),
      },
    },
    {
      file = vim.fs.normalize(root .. "/invalid.cpp"),
      args = { "clang++", "-std=c++20", "-c", vim.fs.normalize(root .. "/invalid.cpp") },
    },
  }

  local out = {}
  for _, entry in ipairs(entries) do
    out[#out + 1] = {
      directory = vim.fs.normalize(root),
      file = entry.file,
      arguments = entry.args,
    }
  end
  local cdb_path = root .. "/compile_commands.json"
  assert(vim.fn.writefile({ vim.json.encode(out) }, cdb_path) == 0)
  return vim.fs.normalize(cdb_path)
end

local function portable_suffix(root, relative)
  local tail = (relative:gsub("\\", "/"))
  if tail == "" then
    return vim.fs.basename(root)
  end
  return table.concat({ vim.fs.basename(root), tail }, "/")
end

local function write_controlled_cdb(root, name, members, files)
  local cdb_path = vim.fs.normalize(root .. "/" .. name)
  local entries = {}
  for _, file in ipairs(files) do
    local absolute = vim.fs.normalize(root .. "/" .. file.name)
    local args = { "clang++", "-std=c++20" }
    for _, arg in ipairs(file.extra_args or {}) do
      args[#args + 1] = arg
    end
    args[#args + 1] = "-c"
    args[#args + 1] = absolute
    entries[#entries + 1] = {
      directory = vim.fs.normalize(root),
      file = absolute,
      arguments = args,
      nvim_ue_module_root = portable_suffix(root, ""),
      nvim_ue_members = vim.tbl_map(function(member)
        return portable_suffix(root, member)
      end, members),
    }
  end
  assert(vim.fn.writefile({ vim.json.encode(entries) }, cdb_path) == 0)
  return cdb_path
end

local function with_temp_fixture(fn)
  local tmp = vim.fs.normalize(vim.fn.tempname())
  assert(vim.fn.mkdir(tmp, "p") == 1)
  local files = {
    "direct.hpp",
    "direct.cpp",
    "caller.cpp",
    "overlay.cpp",
    "contextual.hpp",
    "donor_one.cpp",
    "donor_two.cpp",
    "invalid.hpp",
    "invalid.cpp",
    "expected_entities.json",
  }
  for _, name in ipairs(files) do
    local src = fixture_root .. "/" .. name
    local dst = tmp .. "/" .. name
    assert(vim.fn.writefile(vim.split(read_all(src), "\n", { plain = true }), dst) == 0)
  end
  build_compile_commands(tmp)
  local ok, result = pcall(fn, tmp)
  pcall(vim.fn.delete, tmp, "rf")
  if not ok then error(result) end
  return result
end

t.describe("semantic_protocol", function()
  t.it("rejects malformed requests", function()
    local ok, err = protocol.validate_request({ v = protocol.VERSION, op = "query" })
    t.assert_false(ok)
    t.assert_contains(err, "request.id")
  end)

  t.it("accepts lookup-definition request/response and validates handshake ops", function()
    local request_ok, request_err = protocol.validate_request({
      v = protocol.VERSION,
      id = "lookup-1",
      op = "lookup-definition",
      usr = "c:@F@target#",
      subject = "D:/fixture/source.cpp",
      cdb_paths = { "D:/fixture/current/compile_commands.json" },
      document_version = 3,
      overlays = {
        { path = "D:/fixture/source.cpp", contents = "int main();\n", version = 3 },
      },
    })
    t.assert_true(request_ok, tostring(request_err))

    local response_ok, response_err = protocol.validate_response({
      v = protocol.VERSION,
      id = "lookup-1",
      op = "lookup-definition",
      ok = true,
      state = "resolved",
      usr = "c:@F@target#",
      declaration = { path = "D:/fixture/header.hpp", line = 8, column = 3 },
      definition = { path = "D:/fixture/source.cpp", line = 42, column = 1 },
      metrics = {},
    })
    t.assert_true(response_ok, tostring(response_err))

    local handshake_ok, handshake_err = protocol.validate_response({
      v = protocol.VERSION,
      id = "hello",
      op = "handshake",
      ok = true,
      capabilities = {
        query_states = { "resolved", "unavailable" },
        ops = { "handshake", "lookup-definition", "query", "shutdown" },
      },
    })
    t.assert_true(handshake_ok, tostring(handshake_err))

    local bad_handshake_ok, bad_handshake_err = protocol.validate_response({
      v = protocol.VERSION,
      id = "hello",
      op = "handshake",
      ok = true,
      capabilities = { ops = { "handshake", "bogus-op" } },
    })
    t.assert_false(bad_handshake_ok)
    t.assert_contains(bad_handshake_err, "invalid op")
  end)

  t.it("recovers after invalid NDJSON input", function()
    local frames = {}
    local errors = {}
    local decoder = protocol.new_decoder({
      on_frame = function(frame)
        frames[#frames + 1] = frame
      end,
      on_error = function(frame)
        errors[#errors + 1] = frame
      end,
    })

    decoder:push('{"v":1,"id":"bad","op":"query"}' .. "\n")
    decoder:push('{"v":1,"id":"ok","op":"handshake"}' .. "\n")
    decoder:finish()

    t.assert_eq(#errors, 1)
    t.assert_eq(errors[1].error.code, "invalid-request")
    t.assert_eq(#frames, 1)
    t.assert_eq(frames[1].op, "handshake")
  end)

  t.it("enforces the same frame bound for complete and split lines and recovers at the next newline", function()
    local oversized = protocol.encode({ v = 1, id = "too-large", op = "stats",
      padding = string.rep("x", protocol.MAX_LINE_BYTES) })
    local valid = protocol.encode({ v = 1, id = "after-large", op = "stats" })
    for _, chunks in ipairs({ { oversized .. valid }, { oversized:sub(1, -2), "\n" .. valid } }) do
      local frames, errors = {}, {}
      local decoder = protocol.new_decoder({
        on_frame = function(frame) frames[#frames + 1] = frame end,
        on_error = function(frame) errors[#errors + 1] = frame end,
      })
      for _, chunk in ipairs(chunks) do decoder:push(chunk) end
      decoder:finish()
      t.assert_eq(#errors, 1)
      t.assert_eq(errors[1].error.code, "line-too-long")
      t.assert_eq(#frames, 1)
      t.assert_eq(frames[1].id, "after-large")
    end
  end)
end)

t.describe("semantic_sidecar discovery", function()
  t.it("resource owners can dispose independently", function()
    local sidecar = semantic_sidecar.new({ toolchain = { clangd_candidates = { "missing-review-toolchain" } } })
    t.assert_type(sidecar.tu_store, "table")
    t.assert_type(sidecar.definitions, "table")
    sidecar.definitions.lookup_cache.example = { last_used = 1 }
    sidecar.tu_store:shutdown()
    t.assert_true(sidecar.definitions.lookup_cache.example ~= nil)
    sidecar.definitions:evict()
    t.assert_eq(vim.tbl_count(sidecar.definitions.lookup_cache), 0)
    sidecar:shutdown()
  end)

  t.it("definition evidence cannot be satisfied by a declaration-only frame", function()
    local ok, reason = protocol.validate_response({
      v = protocol.VERSION, id = "declaration-only", op = "lookup-definition",
      ok = true, state = "resolved", declaration = { path = "/fixture/a.h", line = 1, column = 1 }, metrics = {},
    })
    t.assert_false(ok)
    t.assert_contains(reason, "requires definition")
  end)

  t.it("identity and definition evidence require explicit canonical identity", function()
    local frame = {
      v = protocol.VERSION, id = "identity", op = "query", ok = true, state = "resolved",
      declaration = { path = "/fixture/a.h", line = 1, column = 1 }, metrics = {},
    }
    t.assert_false(protocol.validate_response(frame))
    frame.usr = "c:@F@f#"
    t.assert_true(protocol.validate_response(frame))
    frame.declaration.path = ""
    t.assert_false(protocol.validate_response(frame))
    frame.declaration.path = "/fixture/a.h"
    local declaration = frame.declaration
    frame.declaration = nil
    t.assert_false(protocol.validate_response(frame))
    frame.declaration = declaration
    frame.op, frame.definition, frame.usr = "lookup-definition", frame.declaration, nil
    t.assert_false(protocol.validate_response(frame))
    frame.usr = "c:@F@f#"
    t.assert_true(protocol.validate_response(frame))
  end)

  t.it("reports unavailable with structured probes when libclang cannot be found", function()
    local toolchain = semantic_sidecar._discover_toolchain_for_test({
      clangd_candidates = { "definitely-missing-clangd" },
      libclang_candidates = { vim.fs.normalize(cfg .. "/missing/libclang.dll") },
    })
    t.assert_false(toolchain.ok)
    t.assert_eq(toolchain.reason, "libclang-not-found")
    t.assert_true(#toolchain.probes.clangd_candidates >= 1)
  end)
end)

t.describe("semantic sidecar integration", function()
  local discovery = semantic_sidecar._discover_toolchain_for_test()
  if not discovery.ok then
    t.skip("real libclang fixtures", discovery.reason, { native = true })
    return
  end

  t.it("reloads native CDB commands on file changes and clears handles on full eviction", function()
    with_temp_fixture(function(root)
      local source = root .. "/command-change.cpp"
      vim.fn.writefile({ "#ifdef NEW", "using Arg=int;", "#else", "using Arg=long;", "#endif",
        "int choose(int) { return 1; }", "int choose(long) { return 2; }",
        "int caller() { return choose(Arg{}); } // QUERY:command-change" }, source)
      local function write_command(extra)
        local arguments = { "clang++", "-std=c++20", source }
        if extra then table.insert(arguments, 2, extra) end
        vim.fn.writefile({ vim.json.encode({ { directory = root, file = source, arguments = arguments } }) },
          root .. "/compile_commands.json")
      end
      write_command()
      local sidecar = semantic_sidecar.new()
      local request = { id = "command-change", query = find_marker_position(source, "QUERY:command-change", "choose"),
        contexts = { { id = "cdb-only", origin_tu = source, cdb_dir = root } } }
      local first = sidecar:handle_query(request)
      t.assert_eq(first.usr, "c:@F@choose#L#")
      write_command("-DNEW")
      local second = sidecar:handle_query(request)
      t.assert_eq(second.usr, "c:@F@choose#I#")
      sidecar:handle_evict({ id = "all", all = true })
      t.assert_eq(vim.tbl_count(sidecar.tu_store.cdbs), 0)
      write_command()
      t.assert_eq(sidecar:handle_query(request).usr, "c:@F@choose#L#")
      sidecar:shutdown()
    end)
  end)

  t.it("keeps malformed controlled records as incomplete coverage before definition lookup", function()
    with_temp_fixture(function(root)
      local entries = {}
      for _, name in ipairs({ "one", "two" }) do
        local source = root .. "/" .. name .. ".cpp"
        vim.fn.writefile({ "int duplicate() { return 1; }" }, source)
        entries[#entries + 1] = { directory = root, file = source,
          arguments = name == "one" and { "clang++", source } or nil,
          nvim_ue_module_root = vim.fs.basename(root), nvim_ue_members = { source } }
      end
      local path = root .. "/controlled-rejected.json"
      vim.fn.writefile({ vim.json.encode(entries) }, path)
      local sidecar = semantic_sidecar.new()
      local request = { id = "rejected", usr = "c:@F@duplicate#", subject = entries[1].file, cdb_paths = { path } }
      local response = sidecar:handle_lookup_definition(request)
      t.assert_eq(response.state, "unavailable")
      t.assert_eq(response.reason, "lookup-cdb-incomplete")
      t.assert_false(response.coverage.complete)
      t.assert_eq(response.coverage.rejected[1].index, 2)
      t.assert_eq(response.coverage.rejected[1].reason, "missing-command")
      t.assert_eq(vim.tbl_count(sidecar.definitions.lookup_cache), 0)
      entries[2].arguments = { "clang++", entries[2].file }
      vim.fn.writefile({ vim.json.encode(entries) }, path)
      response = sidecar:handle_lookup_definition(request)
      t.assert_eq(response.reason, "multiple-definitions")
      t.assert_eq(#response.contexts, 2)
      sidecar:shutdown()
    end)
  end)

  t.it("rejects incomplete merged CDB evidence in catalog and source proof", function()
    with_temp_fixture(function(root)
      vim.fn.writefile({ vim.json.encode({
        { directory = root, file = root .. "/direct.cpp", arguments = { "clang++", root .. "/direct.cpp" } },
        { directory = root, file = root .. "/rejected.cpp" },
      }) }, root .. "/compile_commands.json")
      local sidecar = semantic_sidecar.new()
      local responses = {
        sidecar:handle_prove({ id = "prove-incomplete", source = root .. "/direct.cpp", cdb_dir = root }),
        sidecar:handle_catalog({ id = "catalog-incomplete", header = root .. "/direct.hpp",
          cdb_dir = root, evidence_roots = { root }, active_build = {} }),
      }
      for _, response in ipairs(responses) do
        t.assert_eq(response.state, "unavailable")
        t.assert_eq(response.reason, "merged-cdb-incomplete")
        t.assert_eq(response.coverage.rejected[1].index, 2)
        t.assert_eq(response.coverage.rejected[1].reason, "missing-command")
      end
      t.assert_eq(#responses[2].contexts, 0)
      sidecar:shutdown()
    end)
  end)

  t.it("bounds real stdin frames without waiting for EOF and serves subsequent requests", function()
    local frames, tail, exited = {}, "", false
    local job = vim.fn.jobstart(sidecar_cmd(), {
      stdin = "pipe", stdout_buffered = false,
      on_stdout = function(_, data)
        tail = tail .. table.concat(data, "\n")
        while true do
          local newline = tail:find("\n", 1, true)
          if not newline then break end
          local line = tail:sub(1, newline - 1)
          tail = tail:sub(newline + 1)
          if line ~= "" then frames[#frames + 1] = vim.json.decode(line) end
        end
      end,
      on_exit = function() exited = true end,
    })
    local ok, err = xpcall(function()
      t.assert_true(job > 0)
      vim.fn.chansend(job, protocol.encode({ v = 1, id = "interactive", op = "stats" }))
      t.assert_true(vim.wait(3000, function() return #frames == 1 end, 5), "response must arrive while stdin stays open")
      local oversized = protocol.encode({ v = 1, id = "oversized", op = "stats",
        padding = string.rep("x", protocol.MAX_LINE_BYTES) })
      vim.fn.chansend(job, oversized .. protocol.encode({ v = 1, id = "after-limit", op = "stats" }))
      t.assert_true(vim.wait(3000, function() return #frames >= 3 end, 5))
      t.assert_eq(frames[2].error.code, "line-too-long")
      t.assert_eq(frames[3].id, "after-limit")
      vim.fn.chansend(job, protocol.encode({ v = 1, id = "done", op = "shutdown" }))
      t.assert_true(vim.wait(2000, function() return exited end, 5))
    end, debug.traceback)
    if not exited then pcall(vim.fn.jobstop, job) end
    if not ok then error(err) end
  end)

  for _, changed_file in ipairs({ "source", "include" }) do
    t.it("warm TU observes saved " .. changed_file .. " changes without a CDB or overlay change", function()
      with_temp_fixture(function(root)
        local source, header = root .. "/saved.cpp", root .. "/saved.hpp"
        local lines = {
          '#include "saved.hpp"',
          "void selected(int) {} void selected(double) {}",
          "void caller() { Value value = 0; selected(value); } // QUERY:saved",
        }
        assert(vim.fn.writefile({ "using Value = int;" }, header) == 0)
        assert(vim.fn.writefile(lines, source) == 0)
        local sidecar = semantic_sidecar.new()
        local ok, err = xpcall(function()
          local request = {
            v = protocol.VERSION, id = "saved-query", op = "query",
            query = find_marker_position(source, "QUERY:saved", "selected"),
            contexts = { {
              id = "saved", origin_tu = source, cdb_dir = root,
              compile = { directory = root, file = source, argv = { "clang++", "-std=c++20", "-c", source } },
            } },
          }
          local first = sidecar:handle_request(request)
          t.assert_eq(first.state, "resolved")
          if changed_file == "include" then
            assert(vim.fn.writefile({ "using Value = double;" }, header) == 0)
          else
            lines[3] = lines[3]:gsub("selected%(value%)", "selected(0.5)")
            assert(vim.fn.writefile(lines, source) == 0)
          end
          local second = sidecar:handle_request(request)
          t.assert_eq(second.state, "resolved")
          t.assert_true(second.usr ~= first.usr, "saved file must change the selected overload")
        end, debug.traceback)
        sidecar:shutdown()
        if not ok then error(err) end
      end)
    end)
  end

  t.it("proves active membership while using the post-processed merged command", function()
    with_temp_fixture(function(root)
      local merged_path = vim.fs.normalize(root .. "/compile_commands.json")
      local active_path = vim.fs.normalize(root .. "/active-build.json")
      local entries = vim.json.decode(read_all(merged_path))
      assert(vim.fn.writefile({ vim.json.encode(entries) }, active_path) == 0)
      assert(vim.fn.writefile({ vim.json.encode(entries) }, merged_path) == 0)

      local sidecar = semantic_sidecar.new()
      local source = vim.fs.normalize(root .. "/direct.cpp")
      local resolved = sidecar:handle_request({
        v = protocol.VERSION,
        id = "prove-active",
        op = "prove",
        source = source,
        cdb_dir = vim.fs.normalize(root),
        cdb_path = merged_path,
        active_cdb_path = active_path,
        context_id = "ctx-active",
      })
      t.assert_eq(resolved.state, "resolved")
      t.assert_eq(resolved.compile.file, source)
      t.assert_true(vim.deep_equal(resolved.compile.argv, entries[1].arguments))

      local raw_active = vim.deepcopy(entries)
      table.insert(raw_active[1].arguments, 2, "-DRAW_ACTIVE_ONLY=1")
      assert(vim.fn.writefile({ vim.json.encode(raw_active) }, active_path) == 0)
      assert(vim.fn.writefile({ vim.json.encode(entries) }, merged_path) == 0)
      local postprocessed = sidecar:handle_request({
        v = protocol.VERSION,
        id = "prove-postprocessed",
        op = "prove",
        source = source,
        cdb_dir = vim.fs.normalize(root),
        cdb_path = merged_path,
        active_cdb_path = active_path,
        context_id = "ctx-postprocessed",
      })
      t.assert_eq(postprocessed.state, "resolved")
      t.assert_true(vim.deep_equal(postprocessed.compile.argv, entries[1].arguments),
        "clangd's merged CDB command is the query authority")
      t.assert_false(vim.tbl_contains(postprocessed.compile.argv, "-DRAW_ACTIVE_ONLY=1"),
        "raw shard arguments prove membership but are not the post-processed command")

      local without_source = vim.list_slice(entries, 2)
      assert(vim.fn.writefile({ vim.json.encode(without_source) }, active_path) == 0)
      assert(vim.fn.writefile({ vim.json.encode(entries) }, merged_path) == 0)
      local rejected = sidecar:handle_request({
        v = protocol.VERSION,
        id = "prove-not-active",
        op = "prove",
        source = source,
        cdb_dir = vim.fs.normalize(root),
        cdb_path = merged_path,
        active_cdb_path = active_path,
        context_id = "ctx-not-active",
      })
      t.assert_eq(rejected.state, "unavailable")
      t.assert_eq(rejected.reason, "active-compile-command-missing")
      sidecar:shutdown()
    end)
  end)

  t.it("handshake and query flow returns resolved, ambiguous, invalid, overlay, stats, and protocol recovery frames", function()
    with_temp_fixture(function(root)
      local source_pick = find_marker_position(root .. "/direct.cpp", "QUERY:source_pick", "pick")
      local header_pick = find_marker_position(root .. "/direct.hpp", "QUERY:header_pick", "pick")
      local contextual_pick = find_marker_position(root .. "/contextual.hpp", "QUERY:contextual_pick", "dispatch")
      local invalid_pick = find_marker_position(root .. "/invalid.hpp", "QUERY:invalid_call", "missing_symbol")
      local overlay_pick = find_marker_position(root .. "/overlay.cpp", "QUERY:overlay_pick", "pick")

      local overlay_text = read_all(root .. "/overlay.cpp"):gsub("Widget value;", "Another value;")

      local stdin = table.concat({
        '{"v":1,"id":"oops","op":"query"}',
        vim.json.encode({ v = 1, id = "hello", op = "handshake" }),
        vim.json.encode({
          v = 1,
          id = "source",
          op = "query",
          query = vim.tbl_extend("force", source_pick, { document_version = 1 }),
          contexts = {
            {
              id = "ctx-source",
              origin_tu = vim.fs.normalize(root .. "/direct.cpp"),
              cdb_dir = vim.fs.normalize(root),
            },
          },
        }),
        vim.json.encode({
          v = 1,
          id = "header",
          op = "query",
          query = vim.tbl_extend("force", header_pick, { document_version = 1 }),
          contexts = {
            {
              id = "ctx-header",
              origin_tu = vim.fs.normalize(root .. "/direct.cpp"),
              cdb_dir = vim.fs.normalize(root),
            },
          },
        }),
        vim.json.encode({
          v = 1,
          id = "overlay-cold",
          op = "query",
          query = vim.tbl_extend("force", overlay_pick, { document_version = 1 }),
          contexts = {
            {
              id = "ctx-overlay",
              origin_tu = vim.fs.normalize(root .. "/overlay.cpp"),
              cdb_dir = vim.fs.normalize(root),
            },
          },
        }),
        vim.json.encode({
          v = 1,
          id = "overlay-reparse",
          op = "query",
          query = vim.tbl_extend("force", overlay_pick, { document_version = 2 }),
          contexts = {
            {
              id = "ctx-overlay",
              origin_tu = vim.fs.normalize(root .. "/overlay.cpp"),
              cdb_dir = vim.fs.normalize(root),
            },
          },
          overlays = {
            {
              path = vim.fs.normalize(root .. "/overlay.cpp"),
              contents = overlay_text,
              version = 2,
            },
          },
        }),
        vim.json.encode({
          v = 1,
          id = "overlay-same-contents",
          op = "query",
          query = vim.tbl_extend("force", overlay_pick, { document_version = 3 }),
          contexts = {
            {
              id = "ctx-overlay",
              origin_tu = vim.fs.normalize(root .. "/overlay.cpp"),
              cdb_dir = vim.fs.normalize(root),
            },
          },
          overlays = {
            {
              path = vim.fs.normalize(root .. "/overlay.cpp"),
              contents = overlay_text,
              version = 3,
            },
          },
        }),
        vim.json.encode({
          v = 1,
          id = "ambiguous",
          op = "query",
          query = vim.tbl_extend("force", contextual_pick, { document_version = 1 }),
          contexts = {
            {
              id = "ctx-one",
              origin_tu = vim.fs.normalize(root .. "/donor_one.cpp"),
              cdb_dir = vim.fs.normalize(root),
            },
            {
              id = "ctx-two",
              origin_tu = vim.fs.normalize(root .. "/donor_two.cpp"),
              cdb_dir = vim.fs.normalize(root),
            },
          },
        }),
        vim.json.encode({
          v = 1,
          id = "invalid",
          op = "query",
          query = vim.tbl_extend("force", invalid_pick, { document_version = 1 }),
          contexts = {
            {
              id = "ctx-invalid",
              origin_tu = vim.fs.normalize(root .. "/invalid.cpp"),
              cdb_dir = vim.fs.normalize(root),
            },
          },
        }),
        vim.json.encode({ v = 1, id = "stats", op = "stats" }),
        vim.json.encode({ v = 1, id = "bye", op = "shutdown" }),
        "",
      }, "\n")

      local result, frames = system_decode(sidecar_cmd(), stdin)
      t.assert_eq(result.code, 0, "sidecar exit code")
      t.assert_true(#frames >= 10, "expected protocol responses")

      local by_id = {}
      local protocol_errors = 0
      for _, frame in ipairs(frames) do
        if frame.op == "protocol-error" then
          protocol_errors = protocol_errors + 1
        elseif frame.id ~= nil and frame.id ~= vim.NIL then
          by_id[frame.id] = frame
        end
      end

      t.assert_eq(protocol_errors, 1)
      t.assert_true((result.stderr or ""):find('"op":"handshake"', 1, true) == nil,
        "stderr must not contain protocol stdout frames")

      local hello = by_id.hello
      t.assert_true(hello.ok)
      t.assert_eq(
        vim.fs.basename(hello.toolchain.libclang_path),
        vim.fs.basename(discovery.libclang_path),
        "parent and sidecar may resolve the same loader library through different absolute aliases"
      )

      local source = by_id.source
      t.assert_eq(source.state, "resolved")
      t.assert_true(source.definition.path:find("direct.cpp", 1, true) ~= nil)
      t.assert_true(source.declaration.path:find("direct.hpp", 1, true) ~= nil)
      t.assert_eq(source.cursor_role, "reference")
      t.assert_eq(source.canonical_identity.usr, source.usr)
      t.assert_true(source.metrics.cold_parse_ms >= 0)
      t.assert_true(type(source.metrics.compile_command_fingerprints[1]) == "string")
      t.assert_true(source.metrics.compile_commands == nil,
        "metrics/log surface must not expose compile argv or workspace paths")

      local header = by_id.header
      t.assert_eq(header.state, "resolved")
      t.assert_eq(header.usr, source.usr, "header-in-context must resolve to same entity identity")

      local overlay_cold = by_id["overlay-cold"]
      local overlay_reparse = by_id["overlay-reparse"]
      t.assert_eq(overlay_cold.state, "resolved")
      t.assert_eq(overlay_reparse.state, "resolved")
      t.assert_true(overlay_reparse.epoch > overlay_cold.epoch, "overlay change must increment TU epoch")
      t.assert_true(overlay_reparse.usr ~= overlay_cold.usr, "overlay should change overload identity")
      t.assert_true(overlay_reparse.metrics.reparse_ms >= 0)
      local overlay_same = by_id["overlay-same-contents"]
      t.assert_eq(overlay_same.state, "resolved")
      t.assert_eq(overlay_same.epoch, overlay_reparse.epoch,
        "document version alone must not reparse identical contents")
      t.assert_eq(overlay_same.document_version, 3,
        "response version must still follow the request snapshot")
      t.assert_eq(overlay_same.metrics.query_kinds[1].kind, "warm")

      local ambiguous = by_id.ambiguous
      t.assert_eq(ambiguous.state, "ambiguous-context")
      t.assert_eq(#ambiguous.contexts, 2)
      t.assert_true(ambiguous.contexts[1].usr ~= ambiguous.contexts[2].usr,
        "two proven contexts must stay distinct by semantic identity")

      local invalid = by_id.invalid
      t.assert_eq(invalid.state, "invalid-semantic-context")
      t.assert_contains(invalid.reason, "invalid")
      t.assert_true(#(invalid.contexts[1].diagnostics or {}) >= 1)

      local stats = by_id.stats
      t.assert_true(stats.ok)
      t.assert_true(stats.metrics.tu_count >= 1)
      t.assert_true(stats.metrics.process_rss_bytes >= 0)
      t.assert_true(#stats.tus >= 1)

      local shutdown = by_id.bye
      t.assert_true(shutdown.ok)
      t.assert_true(shutdown.shutdown)
    end)
  end)

  t.it("resolves default, cv-ref, template, ADL, inherited, no-arg, and same-arity calls by compiler identity", function()
    with_temp_fixture(function(root)
      local sidecar = semantic_sidecar.new()
      local cases = {
        { id = "zero", query = "QUERY:zero", token = "zero", def = "DEF:zero" },
        { id = "default", query = "QUERY:default", token = "with_default", def = "DEF:with_default" },
        { id = "cvref-mutable", query = "QUERY:cvref_mutable", token = "refpick", def = "DEF:refpick_mutable" },
        { id = "cvref-const", query = "QUERY:cvref_const", token = "refpick", def = "DEF:refpick_const" },
        { id = "template-nontemplate", query = "QUERY:template_nontemplate", token = "templated", def = "DEF:templated_widget" },
        { id = "template-generic", query = "QUERY:template_generic", token = "templated", def = "DEF:templated_generic", def_file = "direct.hpp" },
        { id = "adl", query = "QUERY:adl", token = "adl_pick", def = "DEF:adl_pick" },
        { id = "inherited", query = "QUERY:inherited", token = "inherited", def = "DEF:inherited" },
        { id = "virtual-derived", query = "QUERY:virtual_derived_static", token = "dyn_pick", def = "DEF:virtual_derived" },
        { id = "virtual-base", query = "QUERY:virtual_base_static", token = "dyn_pick", def = "DEF:virtual_base" },
        { id = "same-arity-widget", query = "QUERY:source_pick", token = "pick", def = "int pick(Widget value) {" },
        { id = "type-alias", query = "QUERY:type_alias", token = "WidgetAlias", def = "DEF:widget_alias", def_file = "direct.hpp" },
        { id = "constructor", query = "QUERY:constructor", token = "Entity", def = "DEF:entity_ctor" },
        { id = "field", query = "QUERY:field", token = "field", def = "DEF:entity_field", def_file = "direct.hpp" },
        { id = "variable", query = "QUERY:variable", token = "global_value", def = "DEF:global_value" },
        { id = "enum-member", query = "QUERY:enum_member", token = "Red", def = "DEF:enum_red", def_file = "direct.hpp" },
        { id = "namespace-alias", query = "QUERY:namespace_alias", token = "fixture_alias", def = "DEF:namespace_target", def_file = "direct.hpp", def_token = "fixture_alias_target" },
        { id = "macro", query = "QUERY:macro", token = "FIXTURE_SCALE", def = "DEF:macro_scale", def_file = "direct.hpp" },
        { id = "template-specialization", query = "QUERY:template_specialization", token = "identity", def = "DEF:identity_widget_specialization", def_file = "direct.hpp" },
        { id = "operator", query = "QUERY:operator", token = "+ 3", def = "DEF:entity_plus", def_token = "operator+" },
        { id = "destructor", query = "QUERY:destructor", token = "~Entity", def = "DEF:entity_dtor", def_token = "~Entity" },
      }
      local by_id = {}
      for _, case in ipairs(cases) do
        local query = find_marker_position(root .. "/direct.cpp", case.query, case.token)
        local def_file = case.def_file or "direct.cpp"
        local expected = find_marker_position(root .. "/" .. def_file, case.def, case.def_token or case.token)
        local response = sidecar:handle_request({
          v = protocol.VERSION,
          id = case.id,
          op = "query",
          query = vim.tbl_extend("force", query, { document_version = 1 }),
          contexts = {
            { id = "ctx-language-rules", origin_tu = root .. "/direct.cpp", cdb_dir = root },
          },
        })
        t.assert_eq(response.state, "resolved", case.id .. " must resolve")
        t.assert_true(type(response.usr) == "string" and response.usr ~= "", case.id .. " must expose USR")
        t.assert_eq(response.cursor_role, "reference")
        t.assert_eq(vim.fs.normalize(response.definition.path), vim.fs.normalize(root .. "/" .. def_file))
        t.assert_eq(response.definition.line, expected.line, case.id .. " definition line")
        by_id[case.id] = response
      end
      t.assert_true(by_id["cvref-mutable"].usr ~= by_id["cvref-const"].usr,
        "cv/ref overloads must have distinct compiler identities")
      t.assert_true(by_id["template-nontemplate"].usr ~= by_id["template-generic"].usr,
        "non-template and template specializations must have distinct compiler identities")
      t.assert_true(by_id["virtual-derived"].usr ~= by_id["virtual-base"].usr,
        "derived-static and base-static virtual calls must keep distinct identities")
      sidecar:shutdown()
    end)
  end)

  t.it("keeps canonical USR when an origin TU can see only the header declaration", function()
    with_temp_fixture(function(root)
      local sidecar = semantic_sidecar.new()
      local declaration = find_marker_position(
        root .. "/direct.hpp", "DECL:pick_widget", "pick")
      local response = sidecar:handle_request({
        v = protocol.VERSION,
        id = "declaration-only-origin",
        op = "query",
        query = vim.tbl_extend("force", declaration, { document_version = 1 }),
        contexts = {
          { id = "ctx-caller", origin_tu = root .. "/caller.cpp", cdb_dir = root },
        },
      })

      t.assert_eq(response.state, "resolved")
      t.assert_true(type(response.usr) == "string" and response.usr ~= "")
      t.assert_eq(response.cursor_role, "declaration")
      t.assert_eq(vim.fs.normalize(response.declaration.path),
        vim.fs.normalize(root .. "/direct.hpp"))
      t.assert_true(response.definition == nil,
        "libclang must not invent a body absent from the selected origin TU AST")
      sidecar:shutdown()
    end)
  end)

  t.it("rejects recovery AST identities and reparses after a missing include is supplied", function()
    with_temp_fixture(function(root)
      local source = root .. "/recovery.cpp"
      vim.fn.writefile({ '#include "missing.hpp"', 'int pick(long) { return 0; }',
        'int test() { return pick(1); }' }, source)
      local sidecar = semantic_sidecar.new()
      local ctx = { id = "recovery", origin_tu = source, cdb_dir = root,
        compile = { file = source, directory = root, argv = { "clang++", "-std=c++20", source } } }
      local query = { path = source, line = 3, column = 21 }
      local before = sidecar.tu_store:_resolve_context(ctx, query, {})
      t.assert_eq(before.state, "invalid-semantic-context")
      t.assert_eq(before.reason, "invalid-tu-diagnostics")
      t.assert_true(#before.diagnostics > 0)
      vim.fn.writefile({ "inline int pick(int) { return 1; }" }, root .. "/missing.hpp")
      local after, meta = sidecar.tu_store:_resolve_context(ctx, query, {})
      t.assert_eq(after.state, "resolved")
      t.assert_eq(after.usr, "c:@F@pick#I#")
      t.assert_eq(meta.query_kind, "reparse")
      sidecar:shutdown()
    end)
  end)

  t.it("resolves relative compiler paths against the TU working directory and tracks includes", function()
    with_temp_fixture(function(root)
      vim.fn.mkdir(root .. "/inc", "p")
      local header = root .. "/inc/cfg.hpp"
      vim.fn.writefile({ "inline int relative(int) { return 0; }" }, header)
      local source = root .. "/relative.cpp"
      vim.fn.writefile({ "#include <cfg.hpp>", "int caller() { return relative(1); }" }, source)
      local sidecar = semantic_sidecar.new()
      local ctx = { id = "relative", origin_tu = source, cdb_dir = root,
        compile = { file = source, directory = root,
          argv = { "clang++", "-std=c++20", "-Iinc", "relative.cpp" } } }
      local query = { path = source, line = 2, column = 23 }
      local cold = sidecar.tu_store:_resolve_context(ctx, query, {})
      t.assert_eq(cold.definition.path, vim.fs.normalize(header))
      local entry = sidecar.tu_store:_ensure_tu(ctx, {})
      t.assert_true(type(entry.file_signatures[vim.fs.normalize(header)]) == "string")
      vim.fn.writefile({ "", "inline int relative(int) { return 0; }" }, header)
      local changed, meta = sidecar.tu_store:_resolve_context(ctx, query, {})
      t.assert_eq(changed.definition.path, vim.fs.normalize(header))
      t.assert_eq(changed.definition.line, 2)
      t.assert_eq(meta.query_kind, "reparse")
      sidecar:shutdown()
    end)
  end)

  t.it("bounds definition cache independently of TU count and evicts the least recently used entry", function()
    with_temp_fixture(function(root)
      local source = root .. "/bounded.cpp"
      vim.fn.writefile({ "int first() { return 1; }", "int second() { return 2; }",
        "int third() { return 3; }" }, source)
      local cdb = write_controlled_cdb(root, "bounded.json", { "bounded.cpp" }, { { name = "bounded.cpp" } })
      local sidecar = semantic_sidecar.new({ max_tus = 1, max_lookup_entries = 2 })
      local function lookup(name)
        local response = sidecar:handle_lookup_definition({ id = name, usr = "c:@F@" .. name .. "#",
          subject = source, cdb_paths = { cdb } })
        t.assert_eq(response.state, "resolved")
        t.assert_true(response.metrics.lookup_cache_entries <= 2)
        return response
      end
      lookup("first")
      lookup("second")
      t.assert_true(lookup("first").metrics.cache_hit)
      lookup("third")
      t.assert_true(lookup("first").metrics.cache_hit)
      t.assert_false(lookup("second").metrics.cache_hit)
      sidecar:shutdown()
    end)
  end)

  t.it("isolates definition cache entries by subject module context", function()
    with_temp_fixture(function(root)
      local entries = {}
      for _, name in ipairs({ "a", "b" }) do
        local source = root .. "/" .. name .. ".cpp"
        vim.fn.writefile({ "int same() { return 1; }" }, source)
        entries[#entries + 1] = { directory = root, file = source,
          arguments = { "clang++", "-std=c++20", source },
          nvim_ue_module_root = "module-" .. name,
          nvim_ue_members = { root .. "/" .. name .. ".hpp" } }
      end
      local cdb = root .. "/cache-modules.json"
      vim.fn.writefile({ vim.json.encode(entries) }, cdb)
      local sidecar = semantic_sidecar.new()
      local request = { id = "module-a", usr = "c:@F@same#", subject = root .. "/a.hpp", cdb_paths = { cdb } }
      local first = sidecar:handle_lookup_definition(request)
      t.assert_eq(first.state, "resolved")
      request.subject = root .. "/b.hpp"
      local second = sidecar:handle_lookup_definition(request)
      t.assert_eq(second.state, "resolved")
      t.assert_eq(second.definition.path, root .. "/b.cpp")
      t.assert_false(second.metrics.cache_hit)
      t.assert_true(sidecar:handle_lookup_definition(request).metrics.cache_hit)
      sidecar:shutdown()
    end)
  end)

  t.it("does not prove a unique definition from a partial module scan", function()
    with_temp_fixture(function(root)
      vim.fn.writefile({ "int partial() { return 1; }" }, root .. "/partial.cpp")
      local cdb = write_controlled_cdb(root, "partial.json", { "partial.cpp" }, {
        { name = "partial.cpp" }, { name = "absent.cpp" },
      })
      local sidecar = semantic_sidecar.new()
      local request = { id = "partial", usr = "c:@F@partial#", subject = root .. "/partial.cpp", cdb_paths = { cdb } }
      local response = sidecar:handle_lookup_definition(request)
      t.assert_eq(response.state, "unavailable")
      t.assert_eq(response.reason, "lookup-incomplete-contexts")
      t.assert_eq(vim.tbl_count(sidecar.definitions.lookup_cache), 0)
      vim.fn.writefile({ '#include "missing-lookup.hpp"', "int unrelated() { return 0; }" }, root .. "/absent.cpp")
      response = sidecar:handle_lookup_definition(request)
      t.assert_eq(response.reason, "lookup-incomplete-contexts")
      t.assert_eq(vim.tbl_count(sidecar.definitions.lookup_cache), 0)
      local has_diagnostics = false
      for _, context in ipairs(response.contexts) do
        has_diagnostics = has_diagnostics or #(context.diagnostics or {}) > 0
      end
      t.assert_true(has_diagnostics)
      vim.fn.writefile({ "// include repaired" }, root .. "/missing-lookup.hpp")
      response = sidecar:handle_lookup_definition(request)
      t.assert_eq(response.state, "resolved")
      sidecar.definitions.lookup_cache = {}
      local collect = sidecar.definitions._collect_usr_definition
      sidecar.definitions._collect_usr_definition = function(self, ...)
        local definitions, meta = collect(self, ...)
        meta.error_code = 1
        return definitions, meta
      end
      response = sidecar:handle_lookup_definition(request)
      t.assert_eq(response.reason, "lookup-incomplete-contexts")
      t.assert_eq(vim.tbl_count(sidecar.definitions.lookup_cache), 0)
      sidecar:shutdown()
    end)
  end)

  t.it("lookup-definition resolves declaration to the unique body and warm hits cache without rereading CDB/TUs", function()
    with_temp_fixture(function(root)
      local sidecar = semantic_sidecar.new()
      local sidecar_libclang = require("utils.ue_goto.semantic_sidecar_libclang")
      local declaration = find_marker_position(root .. "/direct.hpp", "DECL:pick_widget", "pick")
      local query = sidecar:handle_request({
        v = protocol.VERSION,
        id = "lookup-query",
        op = "query",
        query = vim.tbl_extend("force", declaration, { document_version = 1 }),
        contexts = {
          { id = "ctx-caller", origin_tu = root .. "/caller.cpp", cdb_dir = root },
        },
      })
      t.assert_eq(query.state, "resolved")
      t.assert_eq(query.cursor_role, "declaration")
      t.assert_true(query.definition == nil)

      local controlled = write_controlled_cdb(root, "controlled-module.json", {
        "direct.hpp",
        "direct.cpp",
        "caller.cpp",
      }, {
        { name = "caller.cpp" },
        { name = "direct.cpp" },
      })
      local expected = find_marker_position(root .. "/direct.cpp", "int pick(Widget value) {", "pick")
      local first = sidecar:handle_request({
        v = protocol.VERSION,
        id = "lookup-first",
        op = "lookup-definition",
        usr = query.usr,
        subject = vim.fs.normalize(root .. "/caller.cpp"),
        cdb_paths = { controlled },
        document_version = 1,
      })
      t.assert_eq(first.state, "resolved")
      t.assert_false(first.metrics.cache_hit)
      t.assert_eq(first.metrics.shim_abi_version, 1)
      t.assert_eq(first.document_version, 1)
      t.assert_eq(vim.fs.normalize(first.definition.path), vim.fs.normalize(root .. "/direct.cpp"))
      t.assert_eq(first.definition.line, expected.line)
      local stats_after_first = sidecar:handle_request({
        v = protocol.VERSION, id = "lookup-stats-first", op = "stats",
      })
      local tu_count_after_first = stats_after_first.metrics.tu_count

      local original_read_controlled = sidecar.definitions._read_controlled_cdb
      local original_ensure_tu = sidecar.tu_store._ensure_tu
      local original_ensure_shim = sidecar_libclang.ensure_cursor_shim
      sidecar.definitions._read_controlled_cdb = function()
        error("warm cache must not reread controlled cdb")
      end
      sidecar.tu_store._ensure_tu = function()
        error("warm cache must not rebuild translation units")
      end
      sidecar_libclang.ensure_cursor_shim = function()
        error("warm cache must not recompile or reload cursor shim")
      end
      local second = sidecar:handle_request({
        v = protocol.VERSION,
        id = "lookup-second",
        op = "lookup-definition",
        usr = query.usr,
        subject = vim.fs.normalize(root .. "/caller.cpp"),
        cdb_paths = { controlled },
        document_version = 9,
      })
      sidecar.definitions._read_controlled_cdb = original_read_controlled
      sidecar.tu_store._ensure_tu = original_ensure_tu
      sidecar_libclang.ensure_cursor_shim = original_ensure_shim

      t.assert_eq(second.state, "resolved")
      t.assert_true(second.metrics.cache_hit)
      t.assert_eq(second.metrics.query_kinds[1].kind, "warm-cache")
      t.assert_eq(second.subject, vim.fs.normalize(root .. "/caller.cpp"))
      t.assert_eq(second.document_version, 9)
      t.assert_eq(vim.fs.normalize(second.definition.path), vim.fs.normalize(first.definition.path))
      local stats_after_second = sidecar:handle_request({
        v = protocol.VERSION, id = "lookup-stats-second", op = "stats",
      })
      t.assert_eq(stats_after_second.metrics.tu_count, tu_count_after_first)

      local source_path = root .. "/direct.cpp"
      local contents = read_all(source_path)
      local fd = assert(io.open(source_path, "wb"))
      fd:write("// saved source changed\n" .. contents)
      fd:close()
      local after_save = sidecar:handle_request({
        v = protocol.VERSION, id = "lookup-saved", op = "lookup-definition",
        usr = query.usr, subject = root .. "/caller.cpp", cdb_paths = { controlled },
      })
      t.assert_eq(after_save.state, "resolved")
      t.assert_false(after_save.metrics.cache_hit)
      t.assert_eq(after_save.definition.line, first.definition.line + 1)

      local evicted = sidecar:handle_request({
        v = protocol.VERSION, id = "lookup-evict", op = "evict", all = true,
      })
      t.assert_eq(evicted.metrics.lookup_cache_entries, 0)
      local third = sidecar:handle_request({
        v = protocol.VERSION,
        id = "lookup-third",
        op = "lookup-definition",
        usr = query.usr,
        subject = vim.fs.normalize(root .. "/caller.cpp"),
        cdb_paths = { controlled },
        document_version = 1,
      })
      t.assert_false(third.metrics.cache_hit)
      sidecar:shutdown()
    end)
  end)

  t.it("lookup-definition returns structured unavailable when no module context defines the USR", function()
    with_temp_fixture(function(root)
      local sidecar = semantic_sidecar.new()
      local declaration = find_marker_position(root .. "/direct.hpp", "DECL:pick_widget", "pick")
      local query = sidecar:handle_request({
        v = protocol.VERSION,
        id = "lookup-none-query",
        op = "query",
        query = vim.tbl_extend("force", declaration, { document_version = 1 }),
        contexts = {
          { id = "ctx-caller", origin_tu = root .. "/caller.cpp", cdb_dir = root },
        },
      })
      local controlled = write_controlled_cdb(root, "controlled-caller-only.json", {
        "direct.hpp",
        "caller.cpp",
      }, {
        { name = "caller.cpp" },
      })
      local response = sidecar:handle_request({
        v = protocol.VERSION,
        id = "lookup-none",
        op = "lookup-definition",
        usr = query.usr,
        subject = vim.fs.normalize(root .. "/caller.cpp"),
        cdb_paths = { controlled },
        document_version = 1,
      })
      t.assert_eq(response.state, "unavailable")
      t.assert_eq(response.reason, "definition-not-found")
      local stats = sidecar:handle_request({
        v = protocol.VERSION, id = "lookup-none-stats", op = "stats",
      })
      t.assert_eq(stats.metrics.lookup_cache_entries, 0,
        "negative module evidence must not be cached across subjects")
      sidecar:shutdown()
    end)
  end)

  t.it("lookup-definition fails closed on multiple distinct definitions", function()
    with_temp_fixture(function(root)
      local duplicate_text = read_all(root .. "/direct.cpp")
        :gsub("int pick%(", "int pick(", 1)
        :gsub("return 11;", "return 111;", 1)
      assert(vim.fn.writefile(vim.split(duplicate_text, "\n", { plain = true }),
        root .. "/direct_duplicate.cpp") == 0)

      local sidecar = semantic_sidecar.new()
      local declaration = find_marker_position(root .. "/direct.hpp", "DECL:pick_widget", "pick")
      local query = sidecar:handle_request({
        v = protocol.VERSION,
        id = "lookup-multi-query",
        op = "query",
        query = vim.tbl_extend("force", declaration, { document_version = 1 }),
        contexts = {
          { id = "ctx-caller", origin_tu = root .. "/caller.cpp", cdb_dir = root },
        },
      })
      local controlled = write_controlled_cdb(root, "controlled-multi.json", {
        "direct.hpp",
        "direct.cpp",
        "direct_duplicate.cpp",
        "caller.cpp",
      }, {
        { name = "caller.cpp" },
        { name = "direct.cpp" },
        { name = "direct_duplicate.cpp" },
      })
      local response = sidecar:handle_request({
        v = protocol.VERSION,
        id = "lookup-multi",
        op = "lookup-definition",
        usr = query.usr,
        subject = vim.fs.normalize(root .. "/caller.cpp"),
        cdb_paths = { controlled },
        document_version = 1,
      })
      t.assert_eq(response.state, "unavailable")
      t.assert_eq(response.reason, "multiple-definitions")
      t.assert_eq(#response.definitions, 2)
      local stats = sidecar:handle_request({
        v = protocol.VERSION, id = "lookup-multi-stats", op = "stats",
      })
      t.assert_eq(stats.metrics.lookup_cache_entries, 0,
        "ambiguous module evidence must not be cached across subjects")
      sidecar:shutdown()
    end)
  end)

  t.it("requires every proven context to resolve before asserting a shared identity", function()
    with_temp_fixture(function(root)
      local source = root .. "/mixed-context.cpp"
      vim.fn.writefile({ '#ifdef BROKEN', '#include "missing-context.hpp"', '#endif',
        'int selected() { return 1; }', 'int caller() { return selected(); }' }, source)
      local sidecar = semantic_sidecar.new()
      local healthy = { id = "healthy", origin_tu = source, cdb_dir = root,
        compile = { file = source, directory = root, argv = { "clang++", source } } }
      local broken = vim.deepcopy(healthy)
      broken.id = "broken"
      table.insert(broken.compile.argv, 2, "-DBROKEN")
      local request = { v = protocol.VERSION, id = "mixed-context", op = "query",
        query = { path = source, line = 5, column = 23 }, contexts = { healthy, broken } }
      local response = sidecar:handle_request(request)
      t.assert_eq(response.state, "invalid-semantic-context")
      t.assert_eq(response.reason, "invalid-tu-diagnostics")
      t.assert_eq(#response.contexts, 2)
      t.assert_eq(response.contexts[1].state, "resolved")
      t.assert_true(#response.diagnostics > 0)
      t.assert_true(response.definition == nil)
      broken.compile.directory = root .. "/absent-working-directory"
      response = sidecar:handle_request(request)
      t.assert_eq(response.state, "unavailable")
      t.assert_eq(response.reason, "compile-working-directory-unavailable")
      t.assert_eq(#response.contexts, 2)
      t.assert_true(response.definition == nil)
      sidecar:shutdown()
    end)
  end)

  t.it("preserves per-context unresolved evidence instead of collapsing to the first failure", function()
    with_temp_fixture(function(root)
      local sidecar = semantic_sidecar.new()
      local invalid_pick = find_marker_position(root .. "/invalid.hpp", "QUERY:invalid_call", "missing_symbol")
      local response = sidecar:handle_request({
        v = protocol.VERSION,
        id = "invalid-mixed",
        op = "query",
        query = vim.tbl_extend("force", invalid_pick, { document_version = 1 }),
        contexts = {
          { id = "ctx-invalid", origin_tu = root .. "/invalid.cpp", cdb_dir = root },
          { id = "ctx-missing-file", origin_tu = root .. "/direct.cpp", cdb_dir = root },
        },
      })

      t.assert_eq(response.state, "invalid-semantic-context")
      t.assert_eq(response.reason, "multiple-context-failures")
      t.assert_eq(#response.contexts, 2)
      local reasons = {}
      for _, context in ipairs(response.contexts) do
        reasons[context.reason] = true
      end
      t.assert_true(reasons["invalid-empty-usr"])
      t.assert_true(reasons["invalid-cursor"])
      t.assert_true(#(response.diagnostics or {}) >= #(response.contexts[1].diagnostics or {}))
      sidecar:shutdown()
    end)
  end)

  t.it("bounds live translation units with LRU and explicit idle eviction", function()
    with_temp_fixture(function(root)
      local sidecar = semantic_sidecar.new({ max_tus = 1, idle_evict_ms = 60000 })
      local first_query = find_marker_position(root .. "/direct.cpp", "QUERY:source_pick", "pick")
      local second_query = find_marker_position(root .. "/contextual.hpp", "QUERY:contextual_pick", "dispatch")
      local first = sidecar:handle_request({
        v = protocol.VERSION,
        id = "lru-first",
        op = "query",
        query = vim.tbl_extend("force", first_query, { document_version = 1 }),
        contexts = {
          { id = "ctx-lru-first", origin_tu = root .. "/direct.cpp", cdb_dir = root },
        },
      })
      t.assert_eq(first.state, "resolved")
      local second = sidecar:handle_request({
        v = protocol.VERSION,
        id = "lru-second",
        op = "query",
        query = vim.tbl_extend("force", second_query, { document_version = 1 }),
        contexts = {
          { id = "ctx-lru-second", origin_tu = root .. "/donor_one.cpp", cdb_dir = root },
        },
      })
      t.assert_eq(second.state, "resolved")
      local stats = sidecar:handle_request({ v = protocol.VERSION, id = "lru-stats", op = "stats" })
      t.assert_eq(stats.metrics.tu_count, 1)
      t.assert_eq(stats.tus[1].context_id, "ctx-lru-second")
      local evicted = sidecar:handle_request({
        v = protocol.VERSION, id = "lru-evict", op = "evict", all = true,
      })
      t.assert_eq(evicted.evicted, 1)
      t.assert_eq(evicted.metrics.tu_count, 0)
      sidecar:shutdown()
    end)
  end)

  t.it("catalogs only active-build cpp.json evidence backed by the real CDB", function()
    with_temp_fixture(function(root)
      local right_dir = root .. "/Intermediate/Build/Win64/x64/FixtureTarget/Development/Module"
      local wrong_dir = root .. "/Intermediate/Build/Win64/Server/Development/Source/FixtureTarget/Module"
      assert(vim.fn.mkdir(right_dir, "p") == 1)
      assert(vim.fn.mkdir(wrong_dir, "p") == 1)
      local right_evidence = {
        Data = {
          Source = vim.fs.normalize(root .. "/direct.cpp"),
          PCH = vim.fs.normalize(root .. "/FixturePCH.h.pch"),
          Includes = { vim.fs.normalize(root .. "/direct.hpp") },
        },
      }
      local wrong_evidence = {
        Data = {
          Source = vim.fs.normalize(root .. "/donor_two.cpp"),
          PCH = vim.fs.normalize(root .. "/FixturePCH.h.pch"),
          Includes = { vim.fs.normalize(root .. "/direct.hpp") },
        },
      }
      assert(vim.fn.writefile({ vim.json.encode(right_evidence) }, right_dir .. "/direct.cpp.json") == 0)
      assert(vim.fn.writefile({ vim.json.encode(wrong_evidence) }, wrong_dir .. "/donor_two.cpp.json") == 0)

      local sidecar = semantic_sidecar.new()
      local response = sidecar:handle_request({
        v = protocol.VERSION,
        id = "catalog",
        op = "catalog",
        header = vim.fs.normalize(root .. "/direct.hpp"),
        cdb_dir = vim.fs.normalize(root),
        project_root = vim.fs.normalize(root),
        engine_root = vim.fs.normalize(root),
        active_build_key = "Win64-FixtureTarget-Development",
        active_build = {
          platform = "Win64",
          target = "FixtureTarget",
          configuration = "Development",
        },
        evidence_roots = { vim.fs.normalize(root .. "/Intermediate") },
      })
      t.assert_eq(response.state, "resolved")
      t.assert_eq(#response.contexts, 1)
      t.assert_eq(vim.fs.normalize(response.contexts[1].origin_tu),
        vim.fs.normalize(root .. "/direct.cpp"))
      t.assert_eq(response.contexts[1].evidence_kind, "ubt-cpp-json")
      sidecar:shutdown()
    end)
  end)

  t.it("reconstructs and queries a compiler-emitted depfile, rsp, and unity context", function()
    with_temp_fixture(function(root)
      local evidence_dir = root .. "/Intermediate/Build/Android/FixtureTarget/Development/Module"
      assert(vim.fn.mkdir(evidence_dir, "p") == 1)
      local unity = vim.fs.normalize(evidence_dir .. "/Module.Fixture.cpp")
      local depfile = unity .. "x64.d"
      local rsp = unity .. "x64.o.rsp"
      local direct = vim.fs.normalize(root .. "/direct.cpp")
      local header = vim.fs.normalize(root .. "/direct.hpp")
      assert(vim.fn.writefile({ '#include "' .. direct:gsub("\\", "/") .. '"' }, unity) == 0)
      assert(vim.fn.writefile({
        unity:gsub("\\", "/") .. "x64.o: "
          .. unity:gsub("\\", "/") .. " "
          .. direct:gsub("\\", "/") .. " "
          .. header:gsub("\\", "/"),
      }, depfile) == 0)
      assert(vim.fn.writefile({
        '-std=c++20 -c "' .. unity:gsub("\\", "/") .. '"',
      }, rsp) == 0)

      local sidecar = semantic_sidecar.new()
      local catalog = sidecar:handle_request({
        v = protocol.VERSION,
        id = "android-catalog",
        op = "catalog",
        header = header,
        cdb_dir = vim.fs.normalize(root),
        project_root = vim.fs.normalize(root),
        engine_root = vim.fs.normalize(root),
        active_build_key = "Android-FixtureTarget-Development",
        active_build = {},
        evidence_roots = { vim.fs.normalize(root .. "/Intermediate") },
      })
      t.assert_eq(catalog.state, "resolved")
      t.assert_eq(#catalog.contexts, 1)
      t.assert_eq(catalog.contexts[1].evidence_kind, "clang-d-rsp-unity")
      t.assert_eq(vim.fs.normalize(catalog.contexts[1].origin_tu), unity)
      t.assert_eq(catalog.contexts[1].compile.argv[#catalog.contexts[1].compile.argv], unity)

      local query = find_marker_position(header, "QUERY:header_pick", "pick")
      local response = sidecar:handle_request({
        v = protocol.VERSION,
        id = "android-query",
        op = "query",
        query = vim.tbl_extend("force", query, { document_version = 1 }),
        contexts = { catalog.contexts[1] },
      })
      t.assert_eq(response.state, "resolved")
      t.assert_true(type(response.usr) == "string" and response.usr ~= "")
      t.assert_eq(vim.fs.normalize(response.definition.path), direct)
      sidecar:shutdown()
    end)
  end)
end)
