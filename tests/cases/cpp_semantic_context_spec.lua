local t = require("tests.harness")
t.bootstrap()

local sc = require("utils.ue_goto.semantic_context")

local fixture_root = vim.fn.stdpath("config") .. "/tests/fixtures/cpp_semantic_context"

local function read_file(path)
  local f = assert(io.open(path, "rb"))
  local data = f:read("*a")
  f:close()
  return data
end

local function read_json(name)
  return vim.json.decode(read_file(fixture_root .. "/" .. name))
end

local function read_text(name)
  return read_file(fixture_root .. "/" .. name)
end

local function compile_db()
  local db, err = sc.load_compilation_database(read_json("compile_commands.json"))
  t.assert_nil(err)
  return db
end

t.describe("semantic_context: compilation db + fingerprint", function()
  t.it("parses arguments and command entries conservatively", function()
    local db = compile_db()
    t.assert_eq(#db.entries, 4)

    local cmd_entry = db.by_file[sc.match_key("C:/Fixture/src/same_arity_pointer.cpp")]
    t.assert_eq(cmd_entry.argv[1], "clang++")
    t.assert_eq(cmd_entry.argv[#cmd_entry.argv], "C:/Fixture/src/same_arity_pointer.cpp")

    local bad, err = sc.parse_compilation_entry({
      directory = "C:/Fixture/build/win64",
      file = "C:/Fixture/src/bad.cpp",
      command = 'clang++ -I "C:/Fixture/include C:/Fixture/src/bad.cpp',
    })
    t.assert_nil(bad)
    t.assert_eq(err, "unterminated-quote")
  end)

  t.it("fingerprint binds build key, origin tu, exact argv, directory, toolchain, and evidence", function()
    local db = compile_db()
    local compile = db.by_file[sc.match_key("C:/Fixture/src/solo_context.cpp")]

    local ctx1 = assert(sc.make_proven_context({
      project_root = "C:/Fixture",
      active_build_key = "Win64-Development-Editor",
      origin_tu = "C:/Fixture/src/solo_context.cpp",
      compile = compile,
      toolchain_identity = "clang-18",
      evidence = { kind = "ubt-cpp-json", path = "solo_context.cpp.json" },
    }))
    local ctx2 = assert(sc.make_proven_context({
      project_root = "C:/Fixture",
      active_build_key = "Win64-Development-Editor",
      origin_tu = "C:/Fixture/src/solo_context.cpp",
      compile = compile,
      toolchain_identity = "clang-18",
      evidence = { kind = "ubt-cpp-json", path = "solo_context.cpp.json" },
    }))
    local ctx3 = assert(sc.make_proven_context({
      project_root = "C:/Fixture",
      active_build_key = "Win64-Shipping-Editor",
      origin_tu = "C:/Fixture/src/solo_context.cpp",
      compile = compile,
      toolchain_identity = "clang-18",
      evidence = { kind = "ubt-cpp-json", path = "solo_context.cpp.json" },
    }))

    t.assert_eq(ctx1.fingerprint, ctx2.fingerprint)
    t.assert_true(ctx1.fingerprint ~= ctx3.fingerprint, "build key must affect fingerprint")
    t.assert_eq(ctx1.compile.file, "C:/Fixture/src/solo_context.cpp")
    t.assert_eq(ctx1.compile.directory, "C:/Fixture/build/win64")
  end)
end)

t.describe("semantic_context: cpp.json provenance", function()
  t.it("supports nested Data and flat forms", function()
    local nested = assert(sc.parse_cpp_json_record(read_json("same_arity_value.cpp.json")))
    local flat = assert(sc.parse_cpp_json_record(read_json("same_arity_pointer.cpp.json")))

    t.assert_eq(nested.source, "C:/Fixture/src/same_arity_value.cpp")
    t.assert_eq(flat.source, "C:/Fixture/src/same_arity_pointer.cpp")
    t.assert_contains(nested.includes, "C:/Fixture/include/NonSelfContained.h")
    t.assert_contains(flat.includes, "C:/Fixture/include/NonSelfContained.h")
  end)

  t.it("keeps same-arity fixture metadata as distinct proven contexts", function()
    local contexts = sc.proven_contexts_from_cpp_json({
      project_root = "C:/Fixture",
      active_build_key = "Win64-Development-Editor",
      toolchain_identity = "clang-18",
      compile_db = compile_db(),
      header = "C:/Fixture/include/NonSelfContained.h",
      records = {
        {
          record = read_json("same_arity_value.cpp.json"),
          evidence_path = "C:/Fixture/Intermediate/Build/Win64/same_arity_value.cpp.json",
        },
        {
          record = read_json("same_arity_pointer.cpp.json"),
          evidence_path = "C:/Fixture/Intermediate/Build/Win64/same_arity_pointer.cpp.json",
        },
      },
    })

    t.assert_eq(#contexts, 2)
    t.assert_true(contexts[1].fingerprint ~= contexts[2].fingerprint, "same-arity donors must stay distinct")

    local catalog = sc.catalog_contexts(contexts)
    t.assert_eq(catalog.state, "ambiguous-context")
  end)

  t.it("returns resolved / ambiguous-context / unavailable without heuristics", function()
    local db = compile_db()

    local solo = sc.catalog_contexts(sc.proven_contexts_from_cpp_json({
      project_root = "C:/Fixture",
      active_build_key = "Win64-Development-Editor",
      toolchain_identity = "clang-18",
      compile_db = db,
      header = "C:/Fixture/include/SoloHeader.h",
      records = {
        { record = read_json("solo_context.cpp.json"), evidence_path = "solo_context.cpp.json" },
      },
    }))
    t.assert_eq(solo.state, "resolved")
    t.assert_eq(solo.context.origin_tu, "C:/Fixture/src/solo_context.cpp")

    local multi = sc.catalog_contexts(sc.proven_contexts_from_cpp_json({
      project_root = "C:/Fixture",
      active_build_key = "Win64-Development-Editor",
      toolchain_identity = "clang-18",
      compile_db = db,
      header = "C:/Fixture/include/NonSelfContained.h",
      records = {
        { record = read_json("same_arity_value.cpp.json"), evidence_path = "same_arity_value.cpp.json" },
        { record = read_json("same_arity_pointer.cpp.json"), evidence_path = "same_arity_pointer.cpp.json" },
      },
    }))
    t.assert_eq(multi.state, "ambiguous-context")
    t.assert_eq(#multi.contexts, 2)

    local zero = sc.catalog_contexts(sc.proven_contexts_from_cpp_json({
      project_root = "C:/Fixture",
      active_build_key = "Win64-Development-Editor",
      toolchain_identity = "clang-18",
      compile_db = db,
      header = "C:/Fixture/include/NoContext.h",
      records = {
        { record = read_json("solo_context.cpp.json"), evidence_path = "solo_context.cpp.json" },
      },
    }))
    t.assert_eq(zero.state, "unavailable")
  end)

  t.it("requires active-shard membership but uses the merged CDB command", function()
    local merged = compile_db()
    local raw_entries = read_json("compile_commands.json")
    local active_entries = vim.tbl_filter(function(entry)
      return sc.match_key(entry.file) ~= sc.match_key("C:/Fixture/src/solo_context.cpp")
    end, raw_entries)
    local membership_db = assert(sc.load_compilation_database(active_entries))

    local contexts = sc.proven_contexts_from_cpp_json({
      project_root = "C:/Fixture",
      active_build_key = "Win64-Development-Editor",
      toolchain_identity = "clang-18",
      compile_db = merged,
      membership_db = membership_db,
      header = "C:/Fixture/include/SoloHeader.h",
      records = {
        { record = read_json("solo_context.cpp.json"), evidence_path = "solo_context.cpp.json" },
      },
    })

    t.assert_eq(#contexts, 0,
      "dependency evidence cannot promote a source absent from the active shard")
  end)
end)

t.describe("semantic_context: depfile / rsp / unity provenance", function()
  t.it("parses depfiles with continuations, escaped spaces, and drive letters", function()
    local dep = assert(sc.parse_depfile(read_text("android.dep.d")))
    t.assert_eq(dep.target, "C:/Fixture/build/android/Module.Renderer.1_of_2.o")
    t.assert_contains(dep.dependencies, "C:/Fixture/Intermediate/Build/Android/Module.Renderer.1_of_2.cpp")
    t.assert_contains(dep.dependencies, "C:/Fixture/include/Android Header.h")
  end)

  t.it("parses rsp tokens and exact unity include membership", function()
    local tokens = assert(sc.parse_rsp_tokens(read_text("android.rsp")))
    t.assert_eq(sc.rsp_source_file(tokens), "C:/Fixture/Intermediate/Build/Android/Module.Renderer.1_of_2.cpp")

    local members = assert(sc.parse_unity_membership(
      read_text("Module.Renderer.1_of_2.cpp"),
      "C:/Fixture/Intermediate/Build/Android/Module.Renderer.1_of_2.cpp"
    ))
    t.assert_eq(#members, 2)
    t.assert_contains(members, "C:/Fixture/src/android_same_arity_value.cpp")
    t.assert_contains(members, "C:/Fixture/src/android_same_arity_pointer.cpp")
  end)

  t.it("maps clang .d + rsp + unity membership into multiple proven contexts", function()
    local contexts = sc.proven_contexts_from_dep_records({
      project_root = "C:/Fixture",
      active_build_key = "Android-Development-Editor",
      toolchain_identity = "clang-18-android",
      compile_db = compile_db(),
      header = "C:/Fixture/include/Android Header.h",
      records = {
        {
          depfile = read_text("android.dep.d"),
          depfile_path = "C:/Fixture/build/android/android.dep.d",
          rsp = read_text("android.rsp"),
          rsp_path = "C:/Fixture/build/android/android.rsp",
          unity_text = read_text("Module.Renderer.1_of_2.cpp"),
          unity_path = "C:/Fixture/Intermediate/Build/Android/Module.Renderer.1_of_2.cpp",
        },
      },
    })

    t.assert_eq(#contexts, 2)
    t.assert_eq(contexts[1].compile.file, "C:/Fixture/Intermediate/Build/Android/Module.Renderer.1_of_2.cpp")
    t.assert_contains({ contexts[1].origin_tu, contexts[2].origin_tu }, "C:/Fixture/src/android_same_arity_value.cpp")
    t.assert_contains({ contexts[1].origin_tu, contexts[2].origin_tu }, "C:/Fixture/src/android_same_arity_pointer.cpp")

    local catalog = sc.catalog_contexts(contexts)
    t.assert_eq(catalog.state, "ambiguous-context")
  end)
end)

t.describe("semantic_context: window selection reuse", function()
  t.it("reuses only when the exact fingerprint still exists", function()
    local contexts = sc.proven_contexts_from_cpp_json({
      project_root = "C:/Fixture",
      active_build_key = "Win64-Development-Editor",
      toolchain_identity = "clang-18",
      compile_db = compile_db(),
      header = "C:/Fixture/include/SoloHeader.h",
      records = {
        { record = read_json("solo_context.cpp.json"), evidence_path = "solo_context.cpp.json" },
      },
    })

    local selected = sc.remember_window_selection(contexts[1])
    local reused = sc.reuse_window_selection(selected, contexts)
    t.assert_eq(reused.fingerprint, contexts[1].fingerprint)

    local changed = sc.proven_contexts_from_cpp_json({
      project_root = "C:/Fixture",
      active_build_key = "Win64-Shipping-Editor",
      toolchain_identity = "clang-18",
      compile_db = compile_db(),
      header = "C:/Fixture/include/SoloHeader.h",
      records = {
        { record = read_json("solo_context.cpp.json"), evidence_path = "solo_context.cpp.json" },
      },
    })
    t.assert_nil(sc.reuse_window_selection(selected, changed))
  end)
end)
