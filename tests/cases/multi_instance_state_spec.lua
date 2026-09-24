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

local function assert_no_target_temps(path)
  local prefix = vim.fs.basename(path) .. ".tmp."
  for name in vim.fs.dir(vim.fs.dirname(path)) do
    t.assert_false(name:sub(1, #prefix) == prefix, "temporary target publication remains: " .. name)
  end
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

  for _, scenario in ipairs({
    { name = "propagates EPERM without claiming an unpublished field was committed", code = "EPERM" },
    { name = "propagates EACCES without replacing the previous field", code = "EACCES" },
    { name = "propagates unrelated field replacement errors", code = "ENOENT" },
  }) do
    t.it(scenario.name, function()
      local root = tmpdir()
      local engine, project = root .. "/engine", root .. "/Project"
      local state = require("ue.project_state")
      state._reset_for_test()
      assert(state.select(engine, project, project .. "/Game.uproject", { persist_default = false }))
      assert(state.update(engine, "atomic_field", "before"))
      local path = state.project_cache_root(engine) .. "/state-fields/atomic_field.json"
      local before = table.concat(vim.fn.readfile(path), "\n")
      local original_rename = vim.uv.fs_rename
      local attempts, staged = 0, nil
      local ok, err = pcall(function()
        vim.uv.fs_rename = function(from, to, ...)
          if to ~= path then return original_rename(from, to, ...) end
          attempts = attempts + 1
          staged = staged or from
          t.assert_eq(vim.json.decode(table.concat(vim.fn.readfile(from), "\n")).value, "after")
          t.assert_eq(table.concat(vim.fn.readfile(path), "\n"), before, "old JSON must stay intact until replacement")
          return nil, scenario.code .. ": injected replacement failure", scenario.code
        end
        local updated, update_err = state.update(engine, "atomic_field", "after")
        t.assert_false(updated)
        t.assert_eq(attempts, 1)
        t.assert_contains(update_err, scenario.code)
      end)
      vim.uv.fs_rename = original_rename
      if ok then
        t.assert_eq(state.read(engine).atomic_field, "before")
        t.assert_nil(vim.uv.fs_stat(staged), "success or failure must not leak staged JSON")
      end
      pcall(vim.fn.delete, root, "rf")
      if not ok then error(err) end
    end)
  end

  t.it("commits independent fields without a shared revision writer", function()
    local root = tmpdir()
    local engine, project = root .. "/engine", root .. "/Project"
    local state = require("ue.project_state")
    state._reset_for_test()
    assert(state.select(engine, project, project .. "/Game.uproject", { persist_default = false }))
    write(state.revision_path(engine), '{"legacy":"unchanged"}')
    local before = state.revision(engine)
    local jobs = {}
    for index = 1, 4 do
      local code = string.format(
        "local s=require(%q); assert(s.select(%q,%q,%q,{persist_default=false})); "
          .. "vim.fn.writefile({'ready'},%q); assert(vim.wait(10000,function() return vim.fn.filereadable(%q)==1 end,5)); "
          .. "local errors={}; for n=1,400 do local ok,err=s.update(%q,%q,n); if not ok then errors[#errors+1]=err end end; "
          .. "vim.fn.writefile({vim.json.encode({errors=errors})},%q)",
        "ue.project_state", engine, project, project .. "/Game.uproject", root .. "/ready-" .. index,
        root .. "/start", engine, "writer_" .. index, root .. "/result-" .. index .. ".json"
      )
      jobs[index] = vim.system({ vim.v.progpath, "--headless", "-u", "NONE", "-i", "NONE",
        "--cmd", "set rtp+=" .. vim.fn.stdpath("config"), "-c", "lua " .. code, "-c", "qa!" }, { text = true })
    end
    local ready = vim.wait(10000, function()
      for index = 1, 4 do if vim.fn.filereadable(root .. "/ready-" .. index) ~= 1 then return false end end
      return true
    end, 5)
    write(root .. "/start")
    local results = {}
    for index, job in ipairs(jobs) do results[index] = job:wait(30000) end
    local ok, err = pcall(function()
      t.assert_true(ready, "all four native writers must reach the shared start barrier")
      for index, result in ipairs(results) do
        t.assert_eq(result.code, 0, result.stderr)
        t.assert_eq(vim.trim(result.stderr or ""), "", result.stderr)
        local report = vim.json.decode(table.concat(vim.fn.readfile(root .. "/result-" .. index .. ".json"), "\n"))
        t.assert_eq(#report.errors, 0, report.errors[1])
      end
      local persisted = state.read(engine)
      for index = 1, 4 do t.assert_eq(persisted["writer_" .. index], 400) end
      t.assert_true(state.revision(engine) ~= before)
      t.assert_eq(table.concat(vim.fn.readfile(state.revision_path(engine)), "\n"), '{"legacy":"unchanged"}')
    end)
    pcall(vim.fn.delete, root, "rf")
    if not ok then error(err) end
  end)

  t.it("returns a revision from the exact bytes used by the sampled state", function()
    local root = tmpdir()
    local engine, project = root .. "/engine", root .. "/Project"
    local state = require("ue.project_state")
    state._reset_for_test()
    assert(state.select(engine, project, project .. "/Game.uproject", { persist_default = false }))
    assert(state.update(engine, "sample", "before"))
    local before = state.revision(engine)
    local path = state.project_cache_root(engine) .. "/state-fields/sample.json"
    local original_open = io.open
    local changed = false
    local ok, err = pcall(function()
      io.open = function(name, mode)
        local handle, open_err = original_open(name, mode)
        if not handle or name ~= path or mode ~= "rb" or changed then return handle, open_err end
        return {
          read = function(_, ...) return handle:read(...) end,
          close = function()
            local closed = handle:close()
            changed = true
            assert(state.update(engine, "sample", "after"))
            return closed
          end,
        }
      end
      local sampled, revision = state.read(engine)
      t.assert_eq(sampled.sample, "before")
      t.assert_eq(revision, before, "an update after reading must not attach its newer revision to old state")
    end)
    io.open = original_open
    if ok then
      t.assert_true(changed)
      local current, revision = state.read(engine)
      t.assert_eq(current.sample, "after")
      t.assert_true(revision ~= before)
      t.assert_eq(state.revision(engine), revision)
    end
    pcall(vim.fn.delete, root, "rf")
    if not ok then error(err) end
  end)

  t.it("tracks exact field bytes, removals and target pairs without relying on mtimes", function()
    local root = tmpdir()
    local engine, project = root .. "/engine", root .. "/Project"
    local state = require("ue.project_state")
    state._reset_for_test()
    assert(state.select(engine, project, project .. "/Game.uproject", { persist_default = false }))
    assert(state.update(engine, "sample", "alpha"))
    local path = state.project_cache_root(engine) .. "/state-fields/sample.json"
    local raw = table.concat(vim.fn.readfile(path), "\n")
    local changed = raw:gsub('"alpha"', '"bravo"')
    t.assert_eq(#changed, #raw)
    assert(vim.uv.fs_utime(path, 1000000000, 1000000000))
    local before = state.revision(engine)
    local file = assert(io.open(path, "wb"))
    assert(file:write(changed))
    assert(file:close())
    assert(vim.uv.fs_utime(path, 1000000000, 1000000000))
    t.assert_eq(vim.uv.fs_stat(path).size, #raw)
    local after = state.revision(engine)
    t.assert_true(after ~= before, "same size and timestamp must not hide changed JSON bytes")
    t.assert_eq(state.read(engine).sample, "bravo")
    t.assert_eq(state.revision(engine), after, "unchanged reads must have stable signatures")
    assert(state.update(engine, "sample", nil))
    local removed = state.revision(engine)
    t.assert_true(removed ~= after)
    t.assert_nil(state.read(engine).sample)
    assert(state.update_target(engine, "Android", "Test"))
    local paired = state.revision(engine)
    t.assert_true(paired ~= removed)
    local value = state.read(engine)
    t.assert_eq(value.target_platform, "Android")
    t.assert_eq(value.target_configuration, "Test")
    t.assert_nil(vim.uv.fs_stat(state.revision_path(engine)), "no shared nonce file is published")
    pcall(vim.fn.delete, root, "rf")
  end)

  t.it("invalidates the live context cache for external fields and an update during capture", function()
    local root = tmpdir()
    local engine, project = root .. "/engine", root .. "/Project"
    for _, rel in ipairs({ "Binaries", "Build", "Config", "Plugins", "Shaders", "Source" }) do
      vim.fn.mkdir(engine .. "/Engine/" .. rel, "p")
    end
    write(project .. "/Game.uproject")
    local result = child_lua(string.format([=[
      local engine,project=%q,%q
      vim.cmd('cd '..vim.fn.fnameescape(engine))
      local s=require('ue.project_state')
      assert(s.select(engine,project,project..'/Game.uproject',{persist_default=false}))
      assert(s.update(engine,'cache_sample','initial'))
      local ue=require('ue')
      local first=assert(ue.resolve_context())
      assert(first.state.cache_sample=='initial')
      local command=string.format('local s=require(%%q); assert(s.select(%%q,%%q,%%q,{persist_default=false})); assert(s.update(%%q,%%q,%%q))',
        'ue.project_state',engine,project,project..'/Game.uproject',engine,'cache_sample','external')
      local child=vim.system({vim.v.progpath,'--headless','-u','NONE','-i','NONE','--cmd','set rtp+='..vim.fn.stdpath('config'),
        '-c','lua '..command,'-c','qa!'},{text=true}):wait()
      assert(child.code==0 and vim.trim(child.stderr or '')=='',child.stderr)
      assert(ue.resolve_context().state.cache_sample=='external')
      assert(s.update(engine,'cache_sample','captured'))
      local original_read=s.read
      local injected,reads=false,0
      s.read=function(...)
        local value,revision=original_read(...)
        reads=reads+1
        if reads==2 then injected=true; assert(s.update(engine,'cache_sample','newer')) end
        return value,revision
      end
      -- Publish after the state-capture read, before resolve_context stores it.
      local captured=assert(ue.resolve_context())
      s.read=original_read
      assert(injected)
      assert(captured.state.cache_sample=='captured')
      assert(ue.resolve_context().state.cache_sample=='newer')
    ]=], engine, project))
    pcall(vim.fn.delete, root, "rf")
    t.assert_eq(result.code, 0, result.stderr)
    t.assert_eq(vim.trim(result.stderr or ""), "", result.stderr)
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

  t.it("concurrent target writers preserve atomic pairs and report each native publication outcome", function()
    local root = tmpdir()
    local engine = root .. "/engine"
    local project = root .. "/Project"
    local uproject = project .. "/Game.uproject"
    write(uproject)
    local state = require("ue.project_state")
    state._reset_for_test()
    assert(state.select(engine, project, uproject, { persist_default = false }))
    assert(state.update_target(engine, "PriorPlatform", "PriorConfig"))
    local target = state.project_cache_root(engine) .. "/state-fields/target-selection.json"
    local jobs = {}
    for index = 1, 8 do
      local code = string.format([=[
        local s=require('ue.project_state')
        local engine,project,uproject,root,target,index=%q,%q,%q,%q,%q,%d
        assert(s.select(engine,project,uproject,{persist_default=false}))
        vim.fn.writefile({'ready'},root..'/ready-'..index)
        assert(vim.wait(10000,function() return vim.fn.filereadable(root..'/start')==1 end,5))
        local rename,native=vim.uv.fs_rename,{}
        vim.uv.fs_rename=function(from,to,...)
          local ok,err,code=rename(from,to,...)
          if to==target then native[#native+1]={ok=ok==true,error=err or vim.NIL,code=code or vim.NIL} end
          return ok,err,code
        end
        local ok,err=s.update_target(engine,'Platform'..index,'Config'..index)
        vim.uv.fs_rename=rename
        vim.fn.writefile({'done'},root..'/done-'..index)
        assert(vim.wait(10000,function() return vim.fn.filereadable(root..'/read')==1 end,5))
        local current=s.read(engine)
        vim.fn.writefile({vim.json.encode({index=index,pid=vim.fn.getpid(),ok=ok,error=err or vim.NIL,
          native=native,platform=current.target_platform,configuration=current.target_configuration})},
          root..'/result-'..index..'.json')
      ]=], engine, project, uproject, root, target, index)
      jobs[index] = vim.system({
        vim.v.progpath, "--headless", "-u", "NONE", "-i", "NONE",
        "--cmd", "set rtp+=" .. vim.fn.stdpath("config"),
        "-c", "lua " .. code, "-c", "qa!",
      }, { text = true })
    end
    -- Native replacement can fail under contention. Observe its actual return
    -- without substituting filesystem results or serializing the eight writers.
    local ready = vim.wait(10000, function()
      for index = 1, 8 do if vim.fn.filereadable(root .. "/ready-" .. index) ~= 1 then return false end end
      return true
    end, 5)
    write(root .. "/start")
    local finished = vim.wait(10000, function()
      for index = 1, 8 do if vim.fn.filereadable(root .. "/done-" .. index) ~= 1 then return false end end
      return true
    end, 5)
    write(root .. "/read")
    local results = {}
    for index, job in ipairs(jobs) do results[index] = job:wait(15000) end
    local ok, err = pcall(function()
      t.assert_true(ready, "all eight native writers must finish selection before their shared start")
      t.assert_true(finished, "all eight publication attempts must finish before local-state reads")
      local successes = {}
      for index, result in ipairs(results) do
        t.assert_eq(result.code, 0, result.stderr)
        t.assert_eq(vim.trim(result.stderr or ""), "", result.stderr)
        local report = vim.json.decode(table.concat(vim.fn.readfile(root .. "/result-" .. index .. ".json"), "\n"))
        t.assert_eq(report.index, index)
        t.assert_eq(#report.native, 1, "exactly one authoritative replacement attempt per writer")
        local native = report.native[1]
        t.assert_eq(report.ok, native.ok, "API success must match the actual authoritative rename")
        if native.ok then
          t.assert_eq(report.error, vim.NIL)
          t.assert_eq(report.platform, "Platform" .. index)
          t.assert_eq(report.configuration, "Config" .. index)
          successes[report.pid] = report
        else
          t.assert_true(native.code == "EPERM" or native.code == "EACCES",
            "unexpected native publication failure: " .. tostring(native.error))
          t.assert_eq(report.error, native.error, "the actual permission error must propagate unchanged")
          t.assert_eq(report.platform, "PriorPlatform", "failed publication must preserve process-local selection")
          t.assert_eq(report.configuration, "PriorConfig")
        end
      end
      t.assert_true(next(successes) ~= nil, "at least one native writer must publish successfully")
      local persisted = vim.json.decode(table.concat(vim.fn.readfile(target), "\n"))
      local winner = successes[persisted.writer_pid]
      t.assert_type(winner, "table", "final publication must identify a successful writer")
      t.assert_eq(persisted.target_platform, winner.platform)
      t.assert_eq(persisted.target_configuration, winner.configuration, "target pair must belong to that same writer")
      assert_no_target_temps(target)
    end)
    pcall(vim.fn.delete, root, "rf")
    if not ok then error(err) end
  end)

  t.it("a native held target reader preserves atomic publication or reports sharing failure without changing local state", function()
    local root = tmpdir()
    local engine, project = root .. "/engine", root .. "/Project"
    local state = require("ue.project_state")
    state._reset_for_test()
    local handle, path
    local ok, err = pcall(function()
      assert(state.select(engine, project, project .. "/Game.uproject", { persist_default = false }))
      assert(state.update_target(engine, "BeforePlatform", "BeforeConfig"))
      path = state.project_cache_root(engine) .. "/state-fields/target-selection.json"
      handle = assert(io.open(path, "rb"))
      local before = handle:read("*a")
      assert(handle:seek("set", 0))
      local updated, update_err = state.update_target(engine, "DuringPlatform", "DuringConfig")
      local published = vim.json.decode(table.concat(vim.fn.readfile(path), "\n"))
      local local_state = state.read(engine)
      t.assert_eq(handle:read("*a"), before, "held reader must retain its complete original version")
      if updated then
        t.assert_eq(published.target_platform, "DuringPlatform")
        t.assert_eq(published.target_configuration, "DuringConfig")
        t.assert_eq(local_state.target_platform, "DuringPlatform")
        t.assert_eq(local_state.target_configuration, "DuringConfig")
      else
        t.assert_true(type(update_err) == "string"
          and (update_err:match("^EPERM:") ~= nil or update_err:match("^EACCES:") ~= nil),
          "only a native permission/sharing failure is permitted: " .. tostring(update_err))
        t.assert_eq(table.concat(vim.fn.readfile(path), "\n"), before)
        t.assert_eq(published.target_platform, "BeforePlatform")
        t.assert_eq(published.target_configuration, "BeforeConfig")
        t.assert_eq(local_state.target_platform, "BeforePlatform")
        t.assert_eq(local_state.target_configuration, "BeforeConfig")
      end
      assert_no_target_temps(path)
    end)
    if handle then
      local closed, close_err = handle:close()
      if ok and not closed then ok, err = false, close_err end
    end
    if ok then
      ok, err = pcall(function()
        assert(state.update_target(engine, "AfterPlatform", "AfterConfig"))
        local published = vim.json.decode(table.concat(vim.fn.readfile(path), "\n"))
        t.assert_eq(published.target_platform, "AfterPlatform")
        t.assert_eq(published.target_configuration, "AfterConfig")
        t.assert_eq(state.read(engine).target_platform, "AfterPlatform")
        t.assert_eq(state.read(engine).target_configuration, "AfterConfig")
        assert_no_target_temps(path)
      end)
    end
    pcall(vim.fn.delete, root, "rf")
    if not ok then error(err) end
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

  t.it("a delayed stale reclaimer cannot delete a newly acquired lease", function()
    local root = tmpdir()
    local path = root .. "/race.lock"
    local lock = require("ue.file_lock")
    vim.fn.mkdir(path, "p")
    vim.fn.writefile({ vim.json.encode({ pid = 2147483647, token = "stale" }) }, path .. "/owner.json")
    local original_kill = vim.uv.kill
    local competing, entered
    vim.uv.kill = function(pid, signal)
      if pid == 2147483647 and not entered then
        entered = true
        competing = assert(lock.acquire(path))
        return nil, "ESRCH"
      end
      return original_kill(pid, signal)
    end
    local ok, acquired = pcall(lock.acquire, path)
    vim.uv.kill = original_kill
    local owner = lock.owner(path)
    if acquired then lock.release(acquired) end
    if competing then lock.release(competing) end
    pcall(vim.fn.delete, root, "rf")
    t.assert_true(ok)
    t.assert_nil(acquired, "the second stale reclaimer must lose to the new live owner")
    t.assert_eq(owner and owner.token, competing and competing.token)
  end)

  t.it("a crashed owner and an interrupted empty-directory reap remain recoverable", function()
    local root = tmpdir()
    local path = root .. "/crash.lock"
    local result = child_lua(string.format("assert(require('ue.file_lock').acquire(%q))", path))
    t.assert_eq(result.code, 0, result.stderr)
    local lock = require("ue.file_lock")
    local recovered = assert(lock.acquire(path))
    t.assert_true(lock.release(recovered))
    vim.fn.mkdir(path, "p")
    vim.uv.fs_utime(path, os.time() - 10, os.time() - 10)
    local empty_recovered = assert(lock.acquire(path))
    t.assert_true(lock.release(empty_recovered))
    pcall(vim.fn.delete, root, "rf")
  end)

  t.it("a failed process permission probe does not authorize lease reclamation", function()
    local root = tmpdir()
    local path = root .. "/permission.lock"
    vim.fn.mkdir(path, "p")
    vim.fn.writefile({ vim.json.encode({ pid = 2147483646, token = "protected" }) }, path .. "/owner.json")
    local lock, original_kill = require("ue.file_lock"), vim.uv.kill
    vim.uv.kill = function() return nil, "EPERM: operation not permitted" end
    local ok, acquired = pcall(lock.acquire, path)
    vim.uv.kill = original_kill
    local owner = lock.owner(path)
    if acquired then lock.release(acquired) end
    pcall(vim.fn.delete, root, "rf")
    t.assert_true(ok)
    t.assert_nil(acquired)
    t.assert_eq(owner and owner.token, "protected")
  end)

  t.it("unknown nonempty leases stay intact with actionable owner diagnostics", function()
    local root = tmpdir()
    local lock = require("ue.file_lock")
    for index, fixture in ipairs({
      { content = "{", reason = "corrupt owner record" },
      { content = "{}", reason = "invalid owner record" },
      { reason = "unreadable owner record" },
    }) do
      local path = root .. "/unknown" .. index .. ".lock"
      vim.fn.mkdir(path, "p")
      vim.fn.writefile({ "preserve" }, path .. "/evidence.txt")
      if fixture.content then vim.fn.writefile({ fixture.content }, path .. "/owner.json") end
      vim.uv.fs_utime(path, os.time() - 10, os.time() - 10)
      local acquired, err = lock.acquire(path)
      if acquired then lock.release(acquired) end
      t.assert_nil(acquired)
      t.assert_contains(err, fixture.reason)
      t.assert_contains(err, "inspect the holding process")
      t.assert_contains(err, path .. "/owner.json")
      t.assert_eq(vim.fn.readfile(path .. "/evidence.txt")[1], "preserve")
      if fixture.content then t.assert_eq(vim.fn.readfile(path .. "/owner.json")[1], fixture.content) end
    end
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
    -- An exiting writer may have journaled its last delta under lock contention.
    -- Recover through the production reader, then verify the published total too.
    local store = require("utils.probe_store")
    local recovered = assert(store.read(path))
    t.assert_eq(recovered.topics["multi-instance"].records["same-key"].count, 8)
    t.assert_true(store.save(path, { data = recovered, base = recovered }))
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
    local lock = require("ue.file_lock")
    local lease = assert(lock.acquire(path .. ".lock"))
    local jobs, results, released = {}, {}, false
    local ok, err = xpcall(function()
      for index = 1, 8 do
        local dirty = root .. "/Source/File" .. index .. ".cpp"
        -- Production retries take up to 3575ms plus I/O/dispatch time. Wait for
        -- this writer's actual published path, never its in-memory seeded set.
        local code = string.format(
          "local p,own=%q,%q; local w=require(%q); w._set_opts_for_test({dirty_json_path=p}); "
            .. "w._seed_persistent_dirty_for_test({own}); w._save_persistent_dirty_for_test(); "
            .. "vim.fn.writefile({'attempted'},%q); "
            .. "assert(vim.wait(8000,function() local f=io.open(p,'rb'); if not f then return false end; "
            .. "local raw=f:read('*a'); f:close(); local decoded,arr=pcall(vim.json.decode,raw); "
            .. "if not decoded or type(arr)~='table' then return false end; "
            .. "for _,value in ipairs(arr) do if vim.fs.normalize(value):lower()==vim.fs.normalize(own):lower() then return true end end; "
            .. "return false end,10),'dirty path was not published before the persistence deadline')",
          path, dirty, "utils.ue_watch", root .. "/attempted-" .. index
        )
        jobs[index] = vim.system({
          vim.v.progpath, "--headless", "-u", "NONE", "-i", "NONE",
          "--cmd", "set rtp+=" .. vim.fn.stdpath("config"),
          "-c", "lua " .. code, "-c", "qa!",
        }, { text = true })
      end
      -- Every writer encounters a real live lease for longer than the old
      -- unconditional 300ms child lifetime before competing to publish its union.
      local attempted = vim.wait(5000, function()
        for index = 1, 8 do if vim.fn.filereadable(root .. "/attempted-" .. index) ~= 1 then return false end end
        return true
      end, 10)
      if attempted then vim.wait(400, function() return false end, 10) end
      released = lock.release(lease)
      t.assert_true(attempted, "not all dirty writers attempted their first save")
      t.assert_true(released, "parent must release its exact dirty writer lease")
      for index, job in ipairs(jobs) do results[index] = job:wait(10000) end
      for _, result in ipairs(results) do
        t.assert_eq(result.code, 0, result.stderr)
        t.assert_eq(vim.trim(result.stderr or ""), "", result.stderr)
      end
      local seen = {}
      for _, dirty in ipairs(vim.json.decode(table.concat(vim.fn.readfile(path), "\n"))) do
        seen[fs.norm(dirty):lower()] = true
      end
      for index = 1, 8 do
        local dirty = fs.norm(root .. "/Source/File" .. index .. ".cpp"):lower()
        t.assert_true(seen[dirty] == true, "lost dirty watcher path " .. index)
      end
    end, debug.traceback)
    -- Release before joining on every failure path; wait() bounds and reaps
    -- each owned child even when a spawn or an earlier assertion failed.
    if not released then lock.release(lease) end
    for index, job in ipairs(jobs) do if not results[index] then job:wait(10000) end end
    if not ok then error(err) end
    pcall(vim.fn.delete, root, "rf")
  end)
end)
