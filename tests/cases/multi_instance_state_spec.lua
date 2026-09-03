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

  -- K61 (2026-09-03 实测)：`M.update` 在本进程没有选中项目时返回
  -- `false, "no project selected in this Neovim session"`。丢弃该返回值的写入方会
  -- 报告成功而实际什么都没落盘，读取方继续解析旧值——这正是
  -- `:UESetAndroidPackage` 报「已设置」而 `<Space>da` 仍 attach 旧包名的机制。
  -- `commit()` 是「写入 + 从读取方同一 bucket 回读验证」的唯一入口。
  t.it("commit 在未选中项目时失败，且不得声称写入成功", function()
    local root = tmpdir()
    local engine = root .. "/engine"
    local state = require("ue.project_state")
    state._reset_for_test()

    t.assert_nil(state.current(engine), "precondition: no selection in this process")
    local ok, err = state.commit(engine, "android_package", "com.example.never")
    t.assert_false(ok, "commit must fail without a selected project")
    t.assert_match(tostring(err), "no project selected")
    t.assert_nil(state.read(engine).android_package, "nothing may be persisted")
    pcall(vim.fn.delete, root, "rf")
  end)

  t.it("commit 成功时值可从读取方 bucket 立刻回读", function()
    local root = tmpdir()
    local engine = root .. "/engine"
    local project = root .. "/Project"
    local uproject = project .. "/Game.uproject"
    write(uproject)
    local state = require("ue.project_state")
    state._reset_for_test()
    assert(state.select(engine, project, uproject, { persist_default = false }))

    t.assert_true(state.commit(engine, "android_package", "com.example.stale"))
    t.assert_eq(state.read(engine).android_package, "com.example.stale")
    -- 纠正一次错误输入后，读取方必须立刻看到新值（无进程内缓存可挡）。
    t.assert_true(state.commit(engine, "android_package", "com.example.fresh"))
    t.assert_eq(state.read(engine).android_package, "com.example.fresh")
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

  t.it("engine target default 是建议不是权威：新 bucket 不自动继承", function()
    local root = tmpdir()
    local engine = root .. "/engine"
    local project_a = root .. "/A"
    local project_b = root .. "/B"
    local uproject_a = project_a .. "/A.uproject"
    local uproject_b = project_b .. "/B.uproject"
    write(uproject_a)
    write(uproject_b)
    local state = require("ue.project_state")
    state._reset_for_test()

    -- Project A explicitly sets a target → engine-level preference mirrors it.
    assert(state.select(engine, project_a, uproject_a))
    assert(state.update_target(engine, "Android", "Test"))
    t.assert_true(state.target_is_set(engine), "A 显式设置后 target_is_set 应为 true")
    local suggestion = state.engine_target_default(engine)
    t.assert_eq(suggestion.target_platform, "Android")
    t.assert_eq(suggestion.target_configuration, "Test")

    -- Switch to fresh project B: suggestion available, but B's own state
    -- MUST NOT inherit it — read_state has no platform, target_is_set false.
    assert(state.select(engine, project_b, uproject_b))
    t.assert_false(state.target_is_set(engine), "新 bucket 不得被视为已设置")
    t.assert_nil(state.read(engine).target_platform, "新 bucket 不得自动继承 platform")
    -- Engine-level suggestion survives the project switch (orthogonal axis).
    local still = state.engine_target_default(engine)
    t.assert_eq(still.target_platform, "Android")

    -- B explicitly sets a different pair → suggestion follows the latest
    -- explicit choice, A's own bucket is untouched.
    assert(state.update_target(engine, "Win64", "Development Editor"))
    t.assert_eq(state.engine_target_default(engine).target_platform, "Win64")
    assert(state.select(engine, project_a, uproject_a))
    t.assert_eq(state.read(engine).target_platform, "Android", "A 的 bucket 不受 B 影响")
    pcall(vim.fn.delete, root, "rf")
  end)

  t.it("explicit UESetPlatform intent binds to the next UESetProject regardless of command order", function()
    local root = tmpdir()
    local engine = root .. "/engine"
    local project_a = root .. "/A"
    local project_b = root .. "/B"
    local project_c = root .. "/C"
    local uproject_a = project_a .. "/A.uproject"
    local uproject_b = project_b .. "/B.uproject"
    local uproject_c = project_c .. "/C.uproject"
    write(uproject_a)
    write(uproject_b)
    write(uproject_c)
    local state = require("ue.project_state")
    state._reset_for_test()

    -- Platform first: no project bucket exists yet, so the explicit pair is
    -- held only by this process until the next project selection.
    assert(state.stage_target(engine, "IOS", "Development"))
    assert(state.select(engine, project_a, uproject_a))
    t.assert_true(state.target_is_set(engine))
    t.assert_eq(state.read(engine).target_platform, "IOS")
    t.assert_eq(state.read(engine).target_configuration, "Development")

    -- Project first: the same API updates the active bucket immediately.
    assert(state.select(engine, project_b, uproject_b))
    assert(state.stage_target(engine, "Mac", "DebugGame"))
    t.assert_eq(state.read(engine).target_platform, "Mac")
    t.assert_eq(state.read(engine).target_configuration, "DebugGame")

    -- A later reversed command order transfers that explicit intent once,
    -- without turning the engine-level suggestion into implicit inheritance.
    assert(state.stage_target(engine, "IOS", "Shipping"))
    assert(state.select(engine, project_c, uproject_c))
    t.assert_eq(state.read(engine).target_platform, "IOS")
    t.assert_eq(state.read(engine).target_configuration, "Shipping")
    assert(state.select(engine, project_a, uproject_a))
    t.assert_eq(state.read(engine).target_configuration, "Development",
      "consumed intent must not leak into a later project switch")

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
