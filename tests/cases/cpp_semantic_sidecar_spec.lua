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

local function with_temp_fixture(fn)
  local tmp = vim.fs.normalize(vim.fn.tempname())
  assert(vim.fn.mkdir(tmp, "p") == 1)
  local files = {
    "direct.hpp",
    "direct.cpp",
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
end)

t.describe("semantic_sidecar discovery", function()
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
    t.it("SKIP real libclang fixture unavailable", function()
      io.write("SKIP cpp_semantic_sidecar: " .. tostring(discovery.reason) .. "\n")
      t.assert_true(true)
    end)
    return
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
      t.assert_eq(hello.toolchain.libclang_path, discovery.libclang_path)

      local source = by_id.source
      t.assert_eq(source.state, "resolved")
      t.assert_true(source.definition.path:find("direct.cpp", 1, true) ~= nil)
      t.assert_true(source.declaration.path:find("direct.hpp", 1, true) ~= nil)
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
        { id = "same-arity-widget", query = "QUERY:source_pick", token = "pick", def = "int pick(Widget value) {" },
      }
      local by_id = {}
      for _, case in ipairs(cases) do
        local query = find_marker_position(root .. "/direct.cpp", case.query, case.token)
        local def_file = case.def_file or "direct.cpp"
        local expected = find_marker_position(root .. "/" .. def_file, case.def, case.token)
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
        t.assert_eq(vim.fs.normalize(response.definition.path), vim.fs.normalize(root .. "/" .. def_file))
        t.assert_eq(response.definition.line, expected.line, case.id .. " definition line")
        by_id[case.id] = response
      end
      t.assert_true(by_id["cvref-mutable"].usr ~= by_id["cvref-const"].usr,
        "cv/ref overloads must have distinct compiler identities")
      t.assert_true(by_id["template-nontemplate"].usr ~= by_id["template-generic"].usr,
        "non-template and template specializations must have distinct compiler identities")
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
