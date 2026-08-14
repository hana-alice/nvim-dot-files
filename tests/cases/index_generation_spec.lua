local t = require("tests.harness")
t.bootstrap()

local ue = require("ue")
local index = require("ue.index")

local function write_file(path, content)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local f = assert(io.open(path, "wb"))
  f:write(content or "")
  f:close()
end

local function canonical_temp_root(suffix)
  local root = vim.fn.tempname():gsub("\\", "/") .. suffix
  vim.fn.mkdir(root, "p")
  return vim.fs.normalize(vim.uv.fs_realpath(root) or root)
end

local function read_json(path)
  local f = assert(io.open(path, "rb"))
  local decoded = vim.json.decode(f:read("*a"))
  f:close()
  return decoded
end

local function python_command(script, ...)
  local args = { ... }
  local python = vim.fn.exepath("python")
  local cmd
  if python ~= "" then
    cmd = { python, "-I", script }
  else
    local python3 = vim.fn.exepath("python3")
    if python3 ~= "" then
      cmd = { python3, "-I", script }
    else
      local py = vim.fn.exepath("py")
      assert(py ~= "", "python, python3, or py launcher is required")
      cmd = { py, "-3", "-I", script }
    end
  end
  vim.list_extend(cmd, args)
  return cmd
end

local function make_ctx(label)
  local root = vim.fn.tempname():gsub("\\", "/") .. "_" .. label
  local engine_root = root .. "/EngineRoot"
  local project_root = root .. "/ProjectRoot"
  local index_dir = engine_root .. "/.cache/nvim-ue/cdb"
  local active_dir = engine_root .. "/.cache/nvim-ue/clangd/index"
  local semantic_dir = engine_root .. "/.cache/nvim-ue/clangd/background-cdb"
  vim.fn.mkdir(project_root, "p")
  write_file(engine_root .. "/compile_commands.json", '[{"file":"A.cpp","directory":"C:/fake","arguments":["clang++","A.cpp"]}]')
  return {
    _root = root,
    engine_root = engine_root,
    project_root = project_root,
    paths = {
      platform_key = "Android-Test",
      index_dir = index_dir,
      index_state = index_dir .. "/modules.json",
      index_queue = index_dir .. "/queue.json",
      active_index_dir = active_dir,
      active_index = active_dir .. "/Sample.idx",
      current_index = active_dir .. "/Sample.current.idx",
      hot_index = active_dir .. "/Sample.hot.idx",
      full_index = active_dir .. "/Sample.full.idx",
      semantic_cdb_dir = semantic_dir,
      semantic_cdb = semantic_dir .. "/compile_commands.json",
      semantic_current_cdb = semantic_dir .. "/current/compile_commands.json",
      semantic_hot_cdb = semantic_dir .. "/hot/compile_commands.json",
      semantic_full_cdb = semantic_dir .. "/full/compile_commands.json",
    },
  }
end

local function cleanup_ctx(ctx)
  if not ctx then
    return
  end
  local key = ctx.engine_root .. "\31" .. ctx.project_root .. "\31" .. ctx.paths.platform_key
  index._rt.module_state[key] = nil
  index._rt.contexts[key] = nil
  pcall(vim.fn.delete, ctx._root, "rf")
end

local function seed_state(ctx)
  local state = index.ensure_index_state(ctx)
  state.modules = {
    ["module:/A"] = { key = "module:/A", name = "A", tier = "core", kind = "module", dirty = false },
    ["module:/B"] = { key = "module:/B", name = "B", tier = "warm", kind = "module", dirty = false },
    ["module:/C"] = { key = "module:/C", name = "C", tier = "warm", kind = "module", dirty = false },
  }
  state.queue = {}
  state.index_artifacts = {}
  state.index_selection = nil
  state.build = {
    phase = "idle",
    status = "idle",
    started_at = 0,
    finished_at = 0,
    message = "",
    active_index = "",
  }
  return state
end

local function make_manifest(ctx, state, phase, content, keys, completed_at)
  local path = ctx.paths[phase .. "_index"]
  local background_path = ctx.paths["semantic_" .. phase .. "_cdb"]
  write_file(path, content)
  write_file(background_path, vim.json.encode({
    {
      file = background_path:gsub("compile_commands%.json$", "super_unity_cpps/SuperUnity." .. phase .. ".cpp"),
      directory = vim.fs.dirname(background_path),
      arguments = { "clang++", "-c", "SuperUnity." .. phase .. ".cpp" },
    },
  }))
  return index.make_index_manifest(ctx, state, phase, path, keys, {
    completed_at = completed_at,
    base_cdb_path = ctx.engine_root .. "/compile_commands.json",
    background_cdb_path = background_path,
    index_kind = "controlled-background",
  })
end

t.describe("ue.index generation manifests", function()
  t.it("rejects a phase build while another Neovim owns the platform artifacts", function()
    local ctx = make_ctx("foreign_writer")
    local lock = require("ue.file_lock")
    local owner = assert(lock.acquire(ctx.paths.index_state .. ".build.lock"))
    local ok, err = index.build_phase_async(ctx, "current")
    t.assert_false(ok)
    t.assert_contains(tostring(err), "another Neovim")
    lock.release(owner)
    cleanup_ctx(ctx)
  end)

  t.it("hot controlled background CDB adds portable members/module-root metadata without mutating input", function()
    local root = canonical_temp_root("_hot_super_metadata")
    local source_dir = root .. "/Engine/Source/Runtime/Sample/Private"
    local unity_root = root .. "/Build/Intermediate/Build/Android/Target/Development"
    local unity_file = unity_root .. "/Sample/Module.Sample.1_of_1.cpp"
    local grouped_sources = { source_dir .. "/A.cpp", source_dir .. "/B.cpp" }
    local fallback_source = root .. "/Generated/Standalone/Loose.cpp"
    for _, source in ipairs(grouped_sources) do write_file(source, "// grouped\n") end
    write_file(fallback_source, "// fallback\n")
    write_file(unity_file, table.concat({
      '#include "Runtime/Sample/Private/A.cpp"',
      '#include "Runtime/Sample/Private/B.cpp"',
      "",
    }, "\n"))
    write_file(unity_file .. "x.o.rsp", table.concat({
      "--target=x86_64-pc-windows-msvc",
      "-std=c++20",
      '-include "' .. unity_root .. '/Sample/Definitions.Sample.h"',
      "-c",
      '"' .. unity_file .. '"',
      '-o "' .. unity_file .. 'x.o"',
      "-MD",
      '-MF"' .. unity_file .. 'x.d"',
    }, " "))

    local input_entries = {}
    for _, source in ipairs(grouped_sources) do
      input_entries[#input_entries + 1] = {
        directory = root .. "/Engine/Source",
        file = source,
        arguments = {
          "clang++", "--target=x86_64-pc-windows-msvc", "-std=c++20", "-include",
          unity_root .. "/Engine/SharedPCH.Engine.h", "-c", source,
        },
      }
    end
    input_entries[#input_entries + 1] = {
      directory = root,
      file = fallback_source,
      arguments = { "clang++", "-std=c++20", "-c", fallback_source },
    }
    local input = root .. "/compile_commands.json"
    local output = root .. "/out/hot.super.json"
    write_file(input, vim.json.encode(input_entries))

    local result = vim.system(python_command(
      vim.fn.stdpath("config") .. "/tools/build_hot_super_unity_cdb.py",
      input,
      output,
      "--super-dir",
      root .. "/out/super_unity_cpps"
    ), { text = true }):wait()
    t.assert_eq(result.code, 0, result.stderr or result.stdout)

    local output_entries = read_json(output)
    t.assert_eq(#output_entries, 2, "expected one wrapper plus one fallback entry")

    local wrapper, fallback
    for _, entry in ipairs(output_entries) do
      if entry.file:gsub("\\", "/"):find("/super_unity_cpps/SuperUnity.UBT.", 1, true) then
        wrapper = entry
      else
        fallback = entry
      end
    end
    t.assert_true(wrapper ~= nil, "wrapper entry missing")
    t.assert_true(fallback ~= nil, "fallback entry missing")

    t.assert_eq(#wrapper.nvim_ue_members, 2)
    t.assert_eq(wrapper.nvim_ue_members[1], "Source/Runtime/Sample/Private/A.cpp")
    t.assert_eq(wrapper.nvim_ue_members[2], "Source/Runtime/Sample/Private/B.cpp")
    t.assert_eq(wrapper.nvim_ue_module_root, "Source/Runtime/Sample")

    t.assert_eq(#fallback.nvim_ue_members, 1)
    t.assert_eq(fallback.nvim_ue_members[1], "Generated/Standalone/Loose.cpp")
    t.assert_eq(fallback.nvim_ue_module_root, "Generated/Standalone")
    t.assert_false(fallback.nvim_ue_module_root:find(root, 1, true) ~= nil,
      "portable metadata must not contain workspace roots")

    local input_after = read_json(input)
    t.assert_eq(#input_after, 3)
    for _, entry in ipairs(input_after) do
      t.assert_nil(entry.nvim_ue_members, "input compile_commands must stay unmodified")
      t.assert_nil(entry.nvim_ue_module_root, "input compile_commands must stay unmodified")
    end

    pcall(vim.fn.delete, root, "rf")
  end)

  t.it("full background CDB preserves every active source without platform-specific unity discovery", function()
    local root = vim.fn.tempname():gsub("\\", "/") .. "_full_coverage"
    local input = root .. "/compile_commands.json"
    local active = root .. "/out/active.json"
    local background = root .. "/out/background/compile_commands.json"
    local marker = root .. "/out/full.idx"
    local sources = {
      root .. "/Engine/Source/Runtime/VulkanRHI/Private/VulkanCommands.cpp",
      root .. "/Generated/StandaloneTool.cpp",
      root .. "/ThirdParty/Bridge/Bridge.cpp",
    }
    local entries = {}
    for _, source in ipairs(sources) do
      write_file(source, "// fixture\n")
      entries[#entries + 1] = {
        directory = root,
        file = source,
        arguments = { "clang++", "-std=c++20", "-c", source },
      }
    end
    write_file(input, vim.json.encode(entries))

    local script = vim.fn.stdpath("config") .. "/tools/build_full_cdb.py"
    local result = vim.system(python_command(
      script,
      input,
      active,
      "--no-rsp",
      "--no-inject",
      "--max-mods",
      "2",
      "--background-output",
      background,
      "--idx-output",
      marker
    ), { text = true }):wait()

    t.assert_eq(result.code, 0, result.stderr or result.stdout)
    local controlled_background = read_json(background)
    t.assert_eq(#controlled_background, #sources, "unproven unity membership must retain exact per-file TUs")
    local emitted = {}
    for _, entry in ipairs(controlled_background) do
      local normalized_file = entry.file:gsub("\\", "/")
      local body = ""
      if normalized_file:find("/super_unity_cpps/SuperUnity.", 1, true) then
        local f = assert(io.open(entry.file, "rb"))
        body = f:read("*a")
        f:close()
      end
      for _, source in ipairs(sources) do
        if normalized_file == source or body:find(source, 1, true) then
          emitted[source] = (emitted[source] or 0) + 1
        end
      end
    end
    for _, source in ipairs(sources) do
      t.assert_eq(emitted[source], 1, "every active source must occur in exactly one controlled background entry")
    end
    local marker_json = read_json(marker)
    t.assert_eq(marker_json.entry_count, #controlled_background)
    t.assert_eq(marker_json.index_kind, "controlled-background")

    pcall(vim.fn.delete, root, "rf")
  end)

  t.it("groups sources only through unity membership emitted by the active build", function()
    local root = canonical_temp_root("_active_unity")
    local source_dir = root .. "/Engine/Source/Runtime/Sample/Private"
    local unity_root = root .. "/Build/Intermediate/Build/Android/Target/Development"
    local unity_file = unity_root .. "/Sample/Module.Sample.1_of_1.cpp"
    local sources = { source_dir .. "/A.cpp", source_dir .. "/B.cpp" }
    for _, source in ipairs(sources) do write_file(source, "// fixture\n") end
    write_file(unity_file, table.concat({
      '#include "Runtime/Sample/Private/A.cpp"',
      '#include "Runtime/Sample/Private/B.cpp"',
      "",
    }, "\n"))
    write_file(unity_file .. "x.o.rsp", table.concat({
      "--target=x86_64-pc-windows-msvc",
      "-std=c++20",
      '-include "' .. unity_root .. '/Sample/Definitions.Sample.h"',
      "-c",
      '"' .. unity_file .. '"',
      '-o "' .. unity_file .. 'x.o"',
      "-MD",
      '-MF"' .. unity_file .. 'x.d"',
    }, " "))

    local entries = {}
    for _, source in ipairs(sources) do
      entries[#entries + 1] = {
        directory = root .. "/Engine/Source",
        file = source,
        arguments = {
          "clang++", "--target=x86_64-pc-windows-msvc", "-std=c++20", "-include",
          unity_root .. "/Engine/SharedPCH.Engine.h", "-c", source,
        },
      }
    end
    local input = root .. "/compile_commands.json"
    local active = root .. "/out/active.json"
    local background = root .. "/out/background/compile_commands.json"
    local marker = root .. "/out/full.idx"
    write_file(input, vim.json.encode(entries))

    local result = vim.system(python_command(
      vim.fn.stdpath("config") .. "/tools/build_full_cdb.py",
      input, active, "--no-rsp", "--no-inject",
      "--background-output", background, "--idx-output", marker
    ), { text = true }):wait()
    t.assert_eq(result.code, 0, result.stderr or result.stdout)

    local controlled = read_json(background)
    t.assert_eq(#controlled, 1, "one compiler-authored unity group should produce one wrapper")
    t.assert_contains(controlled[1].file:gsub("\\", "/"), "/super_unity_cpps/SuperUnity.UBT.")
    local f = assert(io.open(controlled[1].file, "rb"))
    local body = f:read("*a")
    f:close()
    for _, source in ipairs(sources) do t.assert_contains(body, source) end

    pcall(vim.fn.delete, root, "rf")
  end)

  t.it("normalizes compile_commands content before hashing", function()
    local ctx = make_ctx("normalized_cdb")
    local state = seed_state(ctx)

    write_file(ctx.engine_root .. "/compile_commands.json", [[
[
  { "directory": "C:/fake", "arguments": ["clang++", "B.cpp"], "file": "B.cpp" },
  { "file": "A.cpp", "arguments": ["clang++", "A.cpp"], "directory": "C:/fake" }
]
]])
    local gen_a = index.generation_for_context(ctx)
    local manifest_a = make_manifest(ctx, state, "full", "full-a", {
      "module:/A",
      "module:/B",
    }, 3)

    write_file(ctx.engine_root .. "/compile_commands.json",
      '[{ "arguments":["clang++","A.cpp"],"directory":"C:/fake","file":"A.cpp" },'
      .. '{ "arguments" : [ "clang++" , "B.cpp" ], "file" : "B.cpp", "directory" : "C:/fake" }]')
    local gen_b = index.generation_for_context(ctx)
    local manifest_b = make_manifest(ctx, state, "full", "full-b", {
      "module:/A",
      "module:/B",
    }, 4)

    t.assert_eq(gen_a.generation_id, gen_b.generation_id,
      "entry order and JSON whitespace must not change generation")
    t.assert_eq(manifest_a.cdb_digest, manifest_b.cdb_digest,
      "normalized CDB digest must be stable across equivalent JSON layouts")

    cleanup_ctx(ctx)
  end)

  t.it("records generation, coverage, index hash, and module metadata", function()
    local ctx = make_ctx("manifest")
    local state = seed_state(ctx)

    local manifest = make_manifest(ctx, state, "hot", "hot-index", {
      "module:/A",
      "module:/B",
    }, 42)

    t.assert_eq(manifest.coverage_level, "hot")
    t.assert_eq(manifest.module_count, 2)
    t.assert_eq(manifest.completed_at, 42)
    t.assert_true(type(manifest.generation_id) == "string" and #manifest.generation_id > 0)
    t.assert_true(type(manifest.cdb_digest) == "string" and #manifest.cdb_digest > 0)
    t.assert_true(type(manifest.idx_hash) == "string" and #manifest.idx_hash > 0)
    t.assert_true(type(manifest.background_cdb_hash) == "string" and #manifest.background_cdb_hash > 0)
    t.assert_eq(manifest.index_kind, "controlled-background")
    t.assert_eq(table.concat(manifest.module_names, ","), "A,B")
    t.assert_contains(index.index_manifest_path(ctx.paths.hot_index), ".manifest.json")

    cleanup_ctx(ctx)
  end)

  t.it("changes generation when compile_commands content changes", function()
    local ctx = make_ctx("generation_switch")
    local state = seed_state(ctx)

    local gen_a = index.generation_for_context(ctx)
    write_file(ctx.engine_root .. "/compile_commands.json",
      '[{"file":"A.cpp","directory":"C:/fake","arguments":["clang++","A.cpp","-DNEW=1"]}]')
    local gen_b = index.generation_for_context(ctx)
    local manifest = make_manifest(ctx, state, "current", "current-index", { "module:/A" }, 7)

    t.assert_true(gen_a.generation_id ~= gen_b.generation_id, "compile_commands digest must affect generation")
    t.assert_eq(manifest.generation_id, gen_b.generation_id)

    cleanup_ctx(ctx)
  end)

  t.it("changes generation when injected toolchain identity changes", function()
    local ctx = make_ctx("toolchain_identity")
    local state = seed_state(ctx)

    index._set_toolchain_identity_for_test("toolchain-a")
    local gen_a = index.generation_for_context(ctx)
    local manifest_a = make_manifest(ctx, state, "current", "toolchain-a", { "module:/A" }, 1)

    index._set_toolchain_identity_for_test("toolchain-b")
    local gen_b = index.generation_for_context(ctx)
    local manifest_b = make_manifest(ctx, state, "current", "toolchain-b", { "module:/A" }, 2)

    index._set_toolchain_identity_for_test(nil)

    t.assert_true(gen_a.generation_id ~= gen_b.generation_id,
      "toolchain identity must participate in generation")
    t.assert_true(manifest_a.generation_id ~= manifest_b.generation_id)

    cleanup_ctx(ctx)
  end)
end)

t.describe("ue.index selector monotonicity", function()
  t.it("keeps current work scoped to the active/dirty convergence set", function()
    local ctx = make_ctx("active_module_priority")
    local state = seed_state(ctx)
    state.active_module = "module:/C"

    local selected = index.select_phase_module_keys(ctx, state, "current")
    t.assert_eq(selected[1], "module:/C")
    t.assert_false(vim.tbl_contains(selected, "module:/A"),
      "broad core prewarm belongs to hot/full, not latency-critical current")

    cleanup_ctx(ctx)
  end)

  t.it("keeps full coverage selected when a narrower current build finishes later", function()
    local ctx = make_ctx("selector_full")
    local state = seed_state(ctx)

    local full = make_manifest(ctx, state, "full", "full-index", {
      "module:/A",
      "module:/B",
      "module:/C",
    }, 10)
    local current = make_manifest(ctx, state, "current", "current-index", {
      "module:/A",
    }, 20)
    state.index_artifacts.full = full
    state.index_artifacts.current = current

    local generation = index.generation_for_context(ctx)
    local selected = index.select_active_artifact(state, generation)
    local changed_first = select(1, index.update_index_selection(state, selected, generation, "fresh"))
    local selected_again = index.select_active_artifact(state, generation)
    local changed_second = select(1, index.update_index_selection(state, selected_again, generation, "fresh"))

    t.assert_eq(selected.phase, "full")
    t.assert_true(changed_first, "initial selection should record the full baseline")
    t.assert_false(changed_second, "later narrower artifact must not flip the chosen base")

    cleanup_ctx(ctx)
  end)

  t.it("promotes current to hot to full inside a new generation, then rejects a late narrow completion", function()
    local ctx = make_ctx("selector_order")
    local state = seed_state(ctx)

    local current = make_manifest(ctx, state, "current", "gen2-current", { "module:/A" }, 5)
    local generation = index.generation_for_context(ctx)
    state.index_artifacts.current = current
    t.assert_eq(index.select_active_artifact(state, generation).phase, "current")

    local hot = make_manifest(ctx, state, "hot", "gen2-hot", {
      "module:/A",
      "module:/B",
    }, 6)
    state.index_artifacts.hot = hot
    t.assert_eq(index.select_active_artifact(state, generation).phase, "hot")

    local full = make_manifest(ctx, state, "full", "gen2-full", {
      "module:/A",
      "module:/B",
      "module:/C",
    }, 7)
    state.index_artifacts.full = full
    t.assert_eq(index.select_active_artifact(state, generation).phase, "full")

    local late_current = make_manifest(ctx, state, "current", "late-current", { "module:/A" }, 30)
    state.index_artifacts.current = late_current
    t.assert_eq(index.select_active_artifact(state, generation).phase, "full")

    cleanup_ctx(ctx)
  end)

  t.it("does not replace an existing base with incomparable coverage", function()
    local ctx = make_ctx("selector_incomparable")
    local state = seed_state(ctx)

    local current = make_manifest(ctx, state, "current", "current-ac", {
      "module:/A",
      "module:/C",
    }, 5)
    state.index_artifacts.current = current
    local generation = index.generation_for_context(ctx)
    index.update_index_selection(state, current, generation, "fresh")

    local hot = make_manifest(ctx, state, "hot", "hot-ab", {
      "module:/A",
      "module:/B",
    }, 6)
    state.index_artifacts.hot = hot

    local selected = index.select_active_artifact(state, generation)
    t.assert_eq(selected.artifact_fingerprint, current.artifact_fingerprint,
      "incomparable coverage must not evict the current active base")

    cleanup_ctx(ctx)
  end)

  t.it("switches to the newest generation instead of reusing an older full baseline", function()
    local ctx = make_ctx("selector_new_generation")
    local state = seed_state(ctx)

    local old_full = make_manifest(ctx, state, "full", "old-full", {
      "module:/A",
      "module:/B",
      "module:/C",
    }, 10)
    state.index_artifacts.full = old_full
    local old_generation = index.generation_for_context(ctx)
    t.assert_eq(index.select_active_artifact(state, old_generation).phase, "full")

    write_file(ctx.engine_root .. "/compile_commands.json",
      '[{"file":"A.cpp","directory":"C:/fake","arguments":["clang++","A.cpp","-DGEN=2"]}]')
    local new_current = make_manifest(ctx, state, "current", "new-current", { "module:/A" }, 20)
    state.index_artifacts.current = new_current
    local new_generation = index.generation_for_context(ctx)

    local selected = index.select_active_artifact(state, new_generation)
    t.assert_eq(selected.phase, "current")
    t.assert_eq(selected.generation_id, new_generation.generation_id)

    cleanup_ctx(ctx)
  end)
end)

t.describe("ue.index status summary", function()
  t.it("provides a cheap navigation snapshot and rejects a changed CDB", function()
    local ctx = make_ctx("semantic_snapshot")
    local state = seed_state(ctx)
    local full = make_manifest(ctx, state, "full", "full-navigation", {
      "module:/A", "module:/B", "module:/C",
    }, 12)
    state.index_artifacts.full = full
    local generation = index.generation_for_context(ctx)
    index.update_index_selection(state, full, generation, "fresh")
    local published = index.publish_semantic_cdb(ctx, state, generation)
    t.assert_true(published)

    local ready = index.semantic_index_snapshot(ctx)
    t.assert_eq(ready.readiness, "ready")
    t.assert_eq(ready.coverage_level, "full")
    t.assert_true(ready.complete)

    write_file(ctx.engine_root .. "/compile_commands.json",
      '[{"file":"A.cpp","directory":"C:/fake","arguments":["clang++","A.cpp","-DSTALE=1"]}]')
    local stale = index.semantic_index_snapshot(ctx)
    t.assert_eq(stale.readiness, "stale")
    t.assert_eq(stale.freshness, "stale")

    cleanup_ctx(ctx)
  end)

  t.it("keeps the full controlled background baseline when a later current delta is published", function()
    local ctx = make_ctx("semantic_monotonic_publish")
    local state = seed_state(ctx)
    local generation = index.generation_for_context(ctx)
    local full = make_manifest(ctx, state, "full", "full-marker", {
      "module:/A", "module:/B", "module:/C",
    }, 10)
    state.index_artifacts.full = full
    t.assert_true(index.publish_semantic_cdb(ctx, state, generation))

    local current = make_manifest(ctx, state, "current", "current-marker", {
      "module:/A",
    }, 20)
    state.index_artifacts.current = current
    t.assert_true(index.publish_semantic_cdb(ctx, state, generation))

    local combined_file = assert(io.open(ctx.paths.semantic_cdb, "rb"))
    local combined = vim.json.decode(combined_file:read("*a"))
    combined_file:close()
    local files = {}
    for _, entry in ipairs(combined) do files[#files + 1] = entry.file end
    local joined = table.concat(files, "\n")
    t.assert_contains(joined, "SuperUnity.full.cpp")
    t.assert_contains(joined, "SuperUnity.current.cpp")
    t.assert_contains(files[1], "SuperUnity.current.cpp",
      "narrow fresh overlays should lead the queue without removing full coverage")
    t.assert_eq(#combined, 2, "controlled current delta + full baseline must remain additive")

    cleanup_ctx(ctx)
  end)

  t.it("reports sanitized generation, coverage, base phase, and overlay freshness", function()
    local ctx = make_ctx("status")
    local state = seed_state(ctx)
    state.root_dirty = true
    state.modules["module:/B"].dirty = true
    state.active_module = "module:/A"
    state.build = {
      phase = "hot",
      status = "ready",
      started_at = 1,
      finished_at = 2,
      message = "hot ready",
      active_index = ctx.paths.active_index,
    }
    state.index_artifacts.full = make_manifest(ctx, state, "full", "full-status", {
      "module:/A",
      "module:/B",
      "module:/C",
    }, 12)

    local summary = index.index_status_summary(ctx)

    t.assert_eq(summary.coverage_level, "full")
    t.assert_eq(summary.selected_phase, "full")
    t.assert_eq(summary.selected_module_count, 3)
    t.assert_false(summary.converging, "full baseline should not be marked converging")
    t.assert_eq(summary.freshness, "overlay")
    t.assert_true(type(summary.generation_short) == "string" and #summary.generation_short == 12)
    t.assert_false(summary.generation_short:find("/", 1, true) ~= nil,
      "generation summary must stay sanitized")
    t.assert_false(summary.generation_short:find(ctx.engine_root, 1, true) ~= nil)
    t.assert_false(summary.active_index_name:find(ctx.engine_root, 1, true) ~= nil)
    t.assert_false(summary.coverage_level:find("/", 1, true) ~= nil,
      "coverage summary must not expose absolute paths")

    cleanup_ctx(ctx)
  end)
end)
