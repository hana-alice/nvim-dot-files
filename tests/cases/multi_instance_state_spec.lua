-- Multi-instance state isolation: session selection must not leak, while
-- persisted project state must be collision-free and project-bucketed.

local t = require("tests.harness")
t.bootstrap()

local fs = require("ue.core.fs")

local function tmpdir()
  local dir = fs.norm(vim.fn.tempname())
  vim.fn.mkdir(dir, "p")
  return fs.norm(vim.uv.fs_realpath(dir) or dir)
end

local function write(path, content)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  vim.fn.writefile({ content or "{}" }, path)
end

local function child_lua(code)
  return vim.system({
    vim.v.progpath,
    "--headless",
    "-u", "NONE",
    "-i", "NONE",
    "--cmd", "set rtp+=" .. vim.fn.stdpath("config"),
    "-c", "lua " .. code,
    "-c", "qa!",
  }, { text = true }):wait()
end

t.describe("multi-instance project state", function()
  t.it("current project is captured per process even when another process changes the startup default", function()
    local root = tmpdir()
    local engine = root .. "/engine"
    local project_a = root .. "/ProjectA"
    local project_b = root .. "/ProjectB"
    local uproject_a = project_a .. "/A.uproject"
    local uproject_b = project_b .. "/B.uproject"
    write(uproject_a)
    write(uproject_b)

    local state = require("ue.project_state")
    state._reset_for_test()
    assert(state.select(engine, project_a, uproject_a))

    local code = string.format(
      "assert(require(%q).select(%q,%q,%q))",
      "ue.project_state", engine, project_b, uproject_b
    )
    local result = child_lua(code)
    t.assert_eq(result.code, 0, result.stderr)

    local current = state.current(engine)
    t.assert_eq(current.project_root, project_a)
    t.assert_eq(current.uproject, uproject_a)

    state._reset_for_test()
    local next_process_default = state.current(engine)
    t.assert_eq(next_process_default.project_root, project_b)
    t.assert_eq(next_process_default.uproject, uproject_b)
    pcall(vim.fn.delete, root, "rf")
  end)

  t.it("different projects under one engine have different state and cache paths", function()
    local root = tmpdir()
    local engine = root .. "/engine"
    local state = require("ue.project_state")
    state._reset_for_test()

    assert(state.select(engine, root .. "/A", root .. "/A/A.uproject"))
    assert(state.update(engine, "android_package", "com.example.a"))
    local a_path = state.state_path(engine)
    local a_cache = state.project_cache_root(engine)

    assert(state.select(engine, root .. "/B", root .. "/B/B.uproject"))
    assert(state.update(engine, "android_package", "com.example.b"))
    local b_path = state.state_path(engine)
    local b_cache = state.project_cache_root(engine)

    t.assert_true(a_path ~= b_path, "project state path must be bucketed")
    t.assert_true(a_cache ~= b_cache, "project cache root must be bucketed")
    t.assert_eq(state.read(engine).android_package, "com.example.b")

    assert(state.select(engine, root .. "/A", root .. "/A/A.uproject", { persist_default = false }))
    t.assert_eq(state.read(engine).android_package, "com.example.a")
    pcall(vim.fn.delete, root, "rf")
  end)

  t.it("ue context paths follow the process-local project bucket", function()
    local root = tmpdir()
    local engine = root .. "/engine"
    local state = require("ue.project_state")
    local ue = require("ue")
    state._reset_for_test()
    assert(state.select(engine, root .. "/A", root .. "/A/A.uproject", { persist_default = false }))
    local a = ue.cache_paths(engine, "Android-Development")
    assert(state.select(engine, root .. "/B", root .. "/B/B.uproject", { persist_default = false }))
    local b = ue.cache_paths(engine, "Android-Development")
    t.assert_true(a.cache ~= b.cache, "ue.cache_paths leaked across projects")
    t.assert_true(a.active_cdb ~= b.active_cdb, "active CDB leaked across projects")
    t.assert_match(a.cache, "/projects/")
    pcall(vim.fn.delete, root, "rf")
  end)

  t.it("concurrent distinct-field updates preserve every field", function()
    local root = tmpdir()
    local engine = root .. "/engine"
    local project = root .. "/Project"
    local uproject = project .. "/Game.uproject"
    write(uproject)
    local state = require("ue.project_state")
    state._reset_for_test()
    assert(state.select(engine, project, uproject))

    local jobs = {}
    for index = 1, 12 do
      local code = string.format(
        "local s=require(%q); assert(s.select(%q,%q,%q,{persist_default=false})); assert(s.update(%q,%q,%d))",
        "ue.project_state", engine, project, uproject, engine, "field_" .. index, index
      )
      jobs[index] = vim.system({
        vim.v.progpath, "--headless", "-u", "NONE", "-i", "NONE",
        "--cmd", "set rtp+=" .. vim.fn.stdpath("config"),
        "-c", "lua " .. code, "-c", "qa!",
      }, { text = true })
    end
    for _, job in ipairs(jobs) do
      local result = job:wait()
      t.assert_eq(result.code, 0, result.stderr)
      t.assert_eq(vim.trim(result.stderr or ""), "", result.stderr)
    end

    local persisted = state.read(engine)
    for index = 1, 12 do
      t.assert_eq(persisted["field_" .. index], index, "lost concurrent field update " .. index)
    end
    pcall(vim.fn.delete, root, "rf")
  end)

  t.it("target platform changes do not redirect another live process", function()
    local root = tmpdir()
    local engine = root .. "/engine"
    local project = root .. "/Project"
    local uproject = project .. "/Game.uproject"
    write(uproject)
    local state = require("ue.project_state")
    state._reset_for_test()
    assert(state.select(engine, project, uproject))
    assert(state.update(engine, "target_platform", "Android"))
    t.assert_eq(state.read(engine).target_platform, "Android")

    local code = string.format(
      "local s=require(%q); assert(s.select(%q,%q,%q,{persist_default=false})); assert(s.update(%q,%q,%q))",
      "ue.project_state", engine, project, uproject, engine, "target_platform", "Win64"
    )
    local result = child_lua(code)
    t.assert_eq(result.code, 0, result.stderr)
    t.assert_eq(state.read(engine).target_platform, "Android")

    state._reset_for_test()
    t.assert_eq(state.read(engine).target_platform, "Win64")
    pcall(vim.fn.delete, root, "rf")
  end)

  t.it("persisted target platform and configuration never tear across writers", function()
    local root = tmpdir()
    local engine = root .. "/engine"
    local project = root .. "/Project"
    local uproject = project .. "/Game.uproject"
    write(uproject)
    local jobs = {}
    for index = 1, 8 do
      local code = string.format(
        "local s=require(%q); assert(s.select(%q,%q,%q,{persist_default=false})); assert(s.update_target(%q,%q,%q))",
        "ue.project_state", engine, project, uproject, engine, "Platform" .. index, "Config" .. index
      )
      jobs[index] = vim.system({
        vim.v.progpath, "--headless", "-u", "NONE", "-i", "NONE",
        "--cmd", "set rtp+=" .. vim.fn.stdpath("config"),
        "-c", "lua " .. code, "-c", "qa!",
      }, { text = true })
    end
    for _, job in ipairs(jobs) do
      local result = job:wait()
      t.assert_eq(result.code, 0, result.stderr)
      t.assert_eq(vim.trim(result.stderr or ""), "", result.stderr)
    end
    local state = require("ue.project_state")
    state._reset_for_test()
    assert(state.select(engine, project, uproject, { persist_default = false }))
    local persisted = state.read(engine)
    local p_index = persisted.target_platform:match("(%d+)$")
    local c_index = persisted.target_configuration:match("(%d+)$")
    t.assert_eq(p_index, c_index, "target pair was torn across processes")
    pcall(vim.fn.delete, root, "rf")
  end)

  t.it("cross-process lease rejects a second live writer and recovers after release", function()
    local root = tmpdir()
    local lock_path = root .. "/prepare.lock"
    local lock = require("ue.file_lock")
    local owner = assert(lock.acquire(lock_path))
    local code = string.format(
      "local l=require(%q); local h=l.acquire(%q); if h then l.release(h); error(%q) end",
      "ue.file_lock", lock_path, "second writer acquired live lease"
    )
    local result = child_lua(code)
    t.assert_eq(result.code, 0, result.stderr)
    lock.release(owner)
    local next_owner = assert(lock.acquire(lock_path))
    lock.release(next_owner)
    pcall(vim.fn.delete, root, "rf")
  end)

  t.it("global probe counts merge instead of losing concurrent events", function()
    local root = tmpdir()
    local path = root .. "/probes.json"
    local jobs = {}
    for index = 1, 8 do
      local code = string.format(
        "local p=require(%q); p._set_path_for_test(%q); assert(p.record(%q,%q,{writer=%d})); p._flush_for_test(); vim.wait(300)",
        "utils.probe", path, "multi-instance", "same-key", index
      )
      jobs[index] = vim.system({
        vim.v.progpath, "--headless", "-u", "NONE", "-i", "NONE",
        "--cmd", "set rtp+=" .. vim.fn.stdpath("config"),
        "-c", "lua " .. code, "-c", "qa!",
      }, { text = true })
    end
    for _, job in ipairs(jobs) do
      local result = job:wait()
      t.assert_eq(result.code, 0, result.stderr)
    end
    local decoded = vim.json.decode(table.concat(vim.fn.readfile(path), "\n"))
    t.assert_eq(decoded.topics["multi-instance"].records["same-key"].count, 8)
    pcall(vim.fn.delete, root, "rf")
  end)

  t.it("recent-project MRU keeps concurrent distinct roots", function()
    local root = tmpdir()
    local path = root .. "/recent.txt"
    local jobs = {}
    for index = 1, 8 do
      local project = root .. "/project-" .. index
      vim.fn.mkdir(project .. "/.git", "p")
      local code = string.format(
        "vim.env.NVIM_RECENT_PROJECTS_PATH=%q; require(%q).record(%q); vim.wait(300)",
        path, "utils.recent_projects", project
      )
      jobs[index] = vim.system({
        vim.v.progpath, "--headless", "-u", "NONE", "-i", "NONE",
        "--cmd", "set rtp+=" .. vim.fn.stdpath("config"),
        "-c", "lua " .. code, "-c", "qa!",
      }, { text = true })
    end
    for _, job in ipairs(jobs) do
      local result = job:wait()
      t.assert_eq(result.code, 0, result.stderr)
    end
    local seen = {}
    for _, line in ipairs(vim.fn.readfile(path)) do seen[fs.norm(line)] = true end
    for index = 1, 8 do
      t.assert_true(seen[fs.norm(root .. "/project-" .. index)] == true,
        "lost recent project " .. index)
    end
    pcall(vim.fn.delete, root, "rf")
  end)

  t.it("definition cache merges distinct keys from concurrent instances", function()
    local root = tmpdir()
    local engine = root .. "/engine"
    local project = root .. "/Project"
    local uproject = project .. "/Game.uproject"
    write(uproject)
    local jobs = {}
    for index = 1, 8 do
      local code = string.format(
        "package.loaded[%q]={clangd_root=function() return %q end}; "
          .. "local s=require(%q); assert(s.select(%q,%q,%q,{persist_default=false})); "
          .. "local c=require(%q); c.put(%q,nil,{{uri=%q,range={start={line=0,character=0},['end']={line=0,character=1}}}},%q,0); "
          .. "assert(c._flush_for_test(0))",
        "ue", engine, "ue.project_state", engine, project, uproject,
        "utils.ue_goto.cache", "Symbol" .. index, vim.uri_from_fname(project .. "/Source.cpp"), "lsp"
      )
      jobs[index] = vim.system({
        vim.v.progpath, "--headless", "-u", "NONE", "-i", "NONE",
        "--cmd", "set rtp+=" .. vim.fn.stdpath("config"),
        "-c", "lua " .. code, "-c", "qa!",
      }, { text = true })
    end
    for _, job in ipairs(jobs) do
      local result = job:wait()
      t.assert_eq(result.code, 0, result.stderr)
      t.assert_eq(vim.trim(result.stderr or ""), "", result.stderr)
    end

    local state = require("ue.project_state")
    state._reset_for_test()
    assert(state.select(engine, project, uproject, { persist_default = false }))
    local entries_dir = state.project_cache_root(engine) .. "/definition-cache/entries"
    local seen = {}
    for name, kind in vim.fs.dir(entries_dir) do
      if kind == "file" and name:match("%.json$") then
        local record = vim.json.decode(table.concat(vim.fn.readfile(entries_dir .. "/" .. name), "\n"))
        seen[record.key] = true
      end
    end
    for index = 1, 8 do
      t.assert_true(seen["Symbol" .. index] == true, "lost definition-cache key " .. index)
    end
    pcall(vim.fn.delete, root, "rf")
  end)

  t.it("persistent dirty overlay unions concurrent watcher updates", function()
    local root = tmpdir()
    local path = root .. "/dirty.json"
    local jobs = {}
    for index = 1, 8 do
      local dirty = root .. "/Source/File" .. index .. ".cpp"
      local code = string.format(
        "local w=require(%q); w._set_opts_for_test({dirty_json_path=%q}); "
          .. "w._seed_persistent_dirty_for_test({%q}); w._save_persistent_dirty_for_test(); vim.wait(300)",
        "utils.ue_watch", path, dirty
      )
      jobs[index] = vim.system({
        vim.v.progpath, "--headless", "-u", "NONE", "-i", "NONE",
        "--cmd", "set rtp+=" .. vim.fn.stdpath("config"),
        "-c", "lua " .. code, "-c", "qa!",
      }, { text = true })
    end
    for _, job in ipairs(jobs) do
      local result = job:wait()
      t.assert_eq(result.code, 0, result.stderr)
    end
    local seen = {}
    for _, dirty in ipairs(vim.json.decode(table.concat(vim.fn.readfile(path), "\n"))) do
      seen[fs.norm(dirty):lower()] = true
    end
    for index = 1, 8 do
      local dirty = fs.norm(root .. "/Source/File" .. index .. ".cpp"):lower()
      t.assert_true(seen[dirty] == true, "lost dirty watcher path " .. index)
    end
    pcall(vim.fn.delete, root, "rf")
  end)
end)
