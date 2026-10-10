local t = require("tests.harness")
t.bootstrap()
local git = require("ue.csearch_git")
local smart = require("ue.csearch_smart")
local cs = require("utils.code_search")
local watch = require("utils.ue_watch")
local function await(start)
  local done, values, count = false
  start(function(...) values = {...}; count = select("#", ...); done = true end)
  t.assert_true(vim.wait(12000, function() return done end, 10), "async Git timeout")
  return unpack(values, 1, count)
end
local function command(root, ...)
  local args = {"git", "-C", root}
  vim.list_extend(args, {...})
  local result = vim.system(args, {text = true}):wait()
  t.assert_eq(result.code, 0, result.stderr or "Git failed")
  return vim.trim(result.stdout or "")
end
local function fixture(fn)
  if vim.fn.executable("git") ~= 1 then t.skip("git unavailable"); return end
  local dir = vim.fn.tempname():gsub("\\", "/")
  vim.fn.mkdir(dir, "p")
  dir = require("ue.core.fs").norm(vim.uv.fs_realpath(dir))
  local repo, bucket = dir .. "/repo", dir .. "/bucket"
  vim.fn.mkdir(repo .. "/Engine", "p"); vim.fn.mkdir(repo .. "/Project", "p"); vim.fn.mkdir(bucket, "p")
  local paths = {}
  for _, name in ipairs({"Keep.cpp", "Modified.cpp", "Deleted.cpp", "Rename.cpp", "Revert.cpp"}) do
    paths[name] = repo .. "/Engine/" .. name
    vim.fn.writefile({"int ORIGINAL_" .. name:gsub("%W", "_") .. " = 1;"}, paths[name])
  end
  paths["Game.cpp"] = repo .. "/Project/Game.cpp"
  vim.fn.writefile({"int GAME = 1;"}, paths["Game.cpp"])
  command(repo, "init")
  command(repo, "add", ".")
  command(repo, "-c", "user.name=Test Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-m", "Fixture baseline")
  local ctx = {engine_root = repo .. "/Engine", project_root = repo .. "/Project",
    paths = {csearch_idx = bucket .. "/csearch.idx"}}
  local original, old_status, old_snapshot = cs.build_index, watch.persistent_dirty_status, watch.snapshot_persistent_dirty
  local calls = {}
  cs.build_index = function(_, list, cb, opts)
    local added = vim.fn.readfile(list)
    local deleted = opts.delete_list and vim.fn.readfile(opts.delete_list) or {}
    calls[#calls + 1] = {mode = opts.mode, added = added, deleted = deleted}
    vim.schedule(function() cb(true, nil, {ms = 1}) end)
  end
  watch.persistent_dirty_status = function() return {capped = false} end
  watch.snapshot_persistent_dirty = function() return {} end
  local function list()
    local out = {}
    for _, path in pairs(paths) do if vim.uv.fs_stat(path) then out[#out + 1] = path end end
    table.sort(out); vim.fn.writefile(out, bucket .. "/workspace.files")
    return bucket .. "/workspace.files", out
  end
  local function build()
    local input = list()
    return await(function(cb) smart.csearch_smart_build(ctx, {workspace_root = repo, csearch_idx = ctx.paths.csearch_idx}, input, cb, {}) end)
  end
  local ok, err = xpcall(function() fn(ctx, repo, paths, calls, build, list) end, debug.traceback)
  cs.build_index, watch.persistent_dirty_status, watch.snapshot_persistent_dirty = original, old_status, old_snapshot
  vim.fn.delete(dir, "rf")
  if not ok then error(err) end
end
local function capped() watch.persistent_dirty_status = function() return {capped = true} end end
local function set_of(items) local out = {}; for _, p in ipairs(items) do out[p] = true end; return out end
local function baseline(ctx) return vim.json.decode(table.concat(vim.fn.readfile(git.path(ctx)), "\n")) end

t.describe("csearch Git overflow recovery", function()
  t.it("真实 Git 完整改动恢复走 add：修改/删除/rename/未跟踪/ignored/ancestor repo", function()
    fixture(function(ctx, repo, paths, calls, build)
      local ok = build(); t.assert_true(ok)
      local saved = baseline(ctx)
      t.assert_eq(saved.roots[ctx.engine_root].coverage_head, command(repo, "rev-parse", "HEAD"))
      t.assert_eq(saved.roots[ctx.project_root].top, repo)
      vim.fn.writefile({"int MODIFIED = 2;"}, paths["Modified.cpp"])
      vim.fn.delete(paths["Deleted.cpp"])
      local old_rename = paths["Rename.cpp"]
      paths["Rename.cpp"] = repo .. "/Engine/Renamed With Spaces.cpp"
      assert(vim.uv.fs_rename(old_rename, paths["Rename.cpp"]))
      paths["Added.cpp"] = repo .. "/Project/Added.cpp"; vim.fn.writefile({"int NEW = 1;"}, paths["Added.cpp"])
      vim.fn.writefile({"Ignored.cpp"}, repo .. "/.gitignore")
      paths["Ignored.cpp"] = repo .. "/Engine/Ignored.cpp"; vim.fn.writefile({"int IGNORED = 1;"}, paths["Ignored.cpp"])
      capped()
      local success, _, stats = build(); t.assert_true(success); t.assert_eq(stats.mode, "add")
      t.assert_true(stats.git_recovered)
      local added, removed = set_of(calls[2].added), set_of(calls[2].deleted)
      t.assert_true(added[paths["Modified.cpp"]]); t.assert_true(added[paths["Rename.cpp"]])
      t.assert_true(added[paths["Added.cpp"]]); t.assert_true(added[paths["Ignored.cpp"]])
      t.assert_true(removed[repo .. "/Engine/Deleted.cpp"]); t.assert_true(removed[old_rename])
      t.assert_false(added[paths["Keep.cpp"]], "clean tracked paths must not be silently re-added")
    end)
  end)
  t.it("上次已索引脏内容随后 revert HEAD：baseline dirty 仍恢复该文件", function()
    fixture(function(_, _, paths, calls, build)
      vim.fn.writefile({"int DIRTY = 1;"}, paths["Revert.cpp"])
      t.assert_true(build())
      vim.fn.writefile({"int ORIGINAL_Revert_cpp = 1;"}, paths["Revert.cpp"])
      capped(); t.assert_true(build())
      t.assert_true(set_of(calls[2].added)[paths["Revert.cpp"]])
    end)
  end)
  t.it("缺记录和不可达 HEAD 保守 reset，不把残缺 dirty 当完整", function()
    fixture(function(ctx, _, _, calls, build)
      t.assert_true(build()); vim.fn.delete(git.path(ctx)); capped(); t.assert_true(build())
      t.assert_eq(calls[2].mode, "reset")
      local saved = baseline(ctx); saved.roots[ctx.engine_root].coverage_head = string.rep("a", 40)
      vim.fn.writefile({vim.json.encode(saved)}, git.path(ctx)); t.assert_true(build())
      t.assert_eq(calls[3].mode, "reset")
    end)
  end)
  t.it("Git 命令失败和非 Git root 保守 reset", function()
    fixture(function(ctx, repo, _, calls, build)
      t.assert_true(build()); capped()
      local original = vim.system
      vim.system = function(argv, options, callback)
        if vim.tbl_contains(argv, "diff") then
          vim.schedule(function() callback({code = 1, stderr = "fixture failure"}) end)
          return {is_closing = function() return true end}
        end
        return original(argv, options, callback)
      end
      local ok, err = pcall(build); vim.system = original; if not ok then error(err) end
      t.assert_eq(calls[2].mode, "reset")
      ctx.project_root = repo .. "/../bucket"
      t.assert_true(build()); t.assert_eq(calls[3].mode, "reset")
    end)
  end)
  t.it("空恢复集也走 add，允许成功后确认旧 overflow", function()
    fixture(function(_, _, _, calls, build)
      t.assert_true(build()); capped()
      local ok, _, stats = build()
      t.assert_true(ok); t.assert_true(stats.git_recovered)
      t.assert_eq(calls[2].mode, "add"); t.assert_eq(#calls[2].added, 0)
    end)
  end)
  t.it("构建跨 HEAD 变化不会提升 coverage HEAD；失败不写记录", function()
    fixture(function(ctx, repo, paths, _, build)
      t.assert_true(build()); local old = baseline(ctx).roots[ctx.engine_root].coverage_head
      local before = await(function(cb) git.capture(ctx, cb) end)
      vim.fn.writefile({"int COMMITTED = 1;"}, paths["Keep.cpp"])
      command(repo, "add", ".")
      command(repo, "-c", "user.name=Test Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-m", "Fixture race")
      t.assert_true(await(function(cb) git.save(ctx, before, true, {}, cb) end))
      t.assert_eq(baseline(ctx).roots[ctx.engine_root].coverage_head, old)
      local bytes = table.concat(vim.fn.readfile(git.path(ctx)), "\n")
      cs.build_index = function(_, _, cb) vim.schedule(function() cb(false, "fixture failure", {}) end) end
      ctx._force_csearch = true
      t.assert_false(build())
      t.assert_eq(table.concat(vim.fn.readfile(git.path(ctx)), "\n"), bytes)
    end)
  end)
  t.it("部分 add 记录 observed HEAD 并保留旧 coverage HEAD 与已覆盖脏路径", function()
    fixture(function(ctx, repo, paths, _, build)
      t.assert_true(build()); local old = baseline(ctx).roots[ctx.engine_root].coverage_head
      vim.fn.writefile({"int COMMITTED = 1;"}, paths["Keep.cpp"])
      command(repo, "add", ".")
      command(repo, "-c", "user.name=Test Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-m", "Fixture partial")
      local before = await(function(cb) git.capture(ctx, cb) end)
      t.assert_true(await(function(cb) git.save(ctx, before, false, {paths["Revert.cpp"]}, cb) end))
      local saved = baseline(ctx).roots[ctx.engine_root]
      t.assert_eq(saved.coverage_head, old)
      t.assert_eq(saved.observed_head, command(repo, "rev-parse", "HEAD"))
      t.assert_true(saved.dirty[paths["Revert.cpp"]])
    end)
  end)
  t.it("tracked assume-unchanged 与 submodule/嵌套仓库源保守补全", function()
    fixture(function(_, repo, paths, calls, build)
      vim.fn.mkdir(repo .. "/Engine/Nested", "p")
      paths["Nested.cpp"] = repo .. "/Engine/Nested/Nested.cpp"
      vim.fn.writefile({"int NESTED = 1;"}, paths["Nested.cpp"])
      command(repo .. "/Engine/Nested", "init")
      command(repo .. "/Engine/Nested", "add", ".")
      command(repo .. "/Engine/Nested", "-c", "user.name=Test Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-m", "Fixture nested baseline")
      command(repo, "add", ".")
      command(repo, "-c", "user.name=Test Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-m", "Fixture gitlink")
      t.assert_match(command(repo, "ls-files", "--stage", "Engine/Nested"), "^160000 ")
      t.assert_true(build())
      command(repo, "update-index", "--assume-unchanged", "Engine/Keep.cpp")
      vim.fn.writefile({"int HIDDEN_EDIT = 1;"}, paths["Keep.cpp"])
      vim.fn.writefile({"int NESTED_CHANGED = 1;"}, paths["Nested.cpp"])
      capped(); t.assert_true(build())
      local added = set_of(calls[2].added)
      t.assert_true(added[paths["Keep.cpp"]]); t.assert_true(added[paths["Nested.cpp"]])
    end)
  end)
  t.it("损坏 baseline 字段回落 reset，成功回调只调用一次", function()
    fixture(function(ctx, _, _, calls, build)
      t.assert_true(build())
      for _, bad in ipairs({"invalid", 17, false}) do
        local saved = baseline(ctx); saved.roots[ctx.engine_root].dirty = bad
        vim.fn.writefile({vim.json.encode(saved)}, git.path(ctx))
        capped(); t.assert_true(build()); t.assert_eq(calls[#calls].mode, "reset")
      end
    end)
  end)
  t.it("Git 完整恢复之后证据发布失败不授权 overflow acknowledgement", function()
    fixture(function(ctx, _, _, _, build)
      t.assert_true(build()); capped()
      local original = git.save
      git.save = function(_, _, _, _, cb) cb(false, false) end
      local ok, err, stats = build(); git.save = original
      t.assert_true(ok, err); t.assert_false(stats.git_recovered); t.assert_false(stats.git_recorded)
    end)
  end)
  t.it("snapshot 发布失败不提升 Git 基线", function()
    fixture(function(ctx, _, _, _, build)
      t.assert_true(build()); capped()
      local original = vim.uv.fs_copyfile
      vim.uv.fs_copyfile = function() return nil, "fixture copy failure" end
      local ok = build(); vim.uv.fs_copyfile = original
      t.assert_false(ok); t.assert_nil(vim.uv.fs_stat(git.path(ctx)))
    end)
  end)
  t.it("capture 的 status 前后 HEAD 不一致则拒绝完整证据", function()
    fixture(function(ctx)
      local original, count = vim.system, 0
      vim.system = function(argv, options, cb)
        if vim.tbl_contains(argv, "--verify") then
          count = count + 1
          if count == 2 then
            vim.schedule(function() cb({code = 0, stdout = string.rep("b", 40) .. "\n"}) end)
            return {}
          end
        end
        return original(argv, options, cb)
      end
      local before = await(function(cb) git.capture(ctx, cb) end)
      vim.system = original
      t.assert_nil(before[ctx.engine_root])
    end)
  end)
  t.it("普通 unchanged skip 不查询 Git，不提升 baseline", function()
    fixture(function(ctx, _, _, calls, build)
      t.assert_true(build())
      local prior, original = table.concat(vim.fn.readfile(git.path(ctx)), "\n"), vim.system
      vim.system = function() error("unchanged skip must not spawn Git") end
      local ok, err, stats = build(); vim.system = original
      t.assert_true(ok, err); t.assert_eq(stats.mode, "skip"); t.assert_eq(#calls, 1)
      t.assert_eq(table.concat(vim.fn.readfile(git.path(ctx)), "\n"), prior)
    end)
  end)
  t.it("缓存 workspace 仍含已删源：异步 stat 后 delete-from 并同步两份清单", function()
    fixture(function(ctx, repo, paths, calls, build, list)
      t.assert_true(build())
      local input = list()
      ctx.paths.workspace_all_list = repo .. "/../bucket/canonical.files"
      vim.fn.writefile({"Engine/Deleted.cpp", "Engine/Keep.cpp"}, ctx.paths.workspace_all_list)
      vim.fn.delete(paths["Deleted.cpp"]); capped()
      local ok, err, stats = await(function(cb)
        smart.csearch_smart_build(ctx, {workspace_root = repo}, input, cb, {})
      end)
      t.assert_true(ok, err); t.assert_true(stats.git_recovered)
      t.assert_true(set_of(calls[2].deleted)[paths["Deleted.cpp"]])
      t.assert_false(set_of(calls[2].added)[paths["Deleted.cpp"]])
      t.assert_false(set_of(vim.fn.readfile(ctx.paths.csearch_idx .. ".files"))[paths["Deleted.cpp"]])
      t.assert_eq(table.concat(vim.fn.readfile(ctx.paths.workspace_all_list), "\n"), "Engine/Keep.cpp")
    end)
  end)
  t.it("真实 watcher overflow 在索引期间 HEAD 变化后保持可见", function()
    fixture(function(ctx, repo, paths, _, build)
      t.assert_true(build())
      local previous_watch = package.loaded["utils.ue_watch"]
      package.loaded["utils.ue_watch"] = nil
      local private_watch = require("utils.ue_watch")
      local dir = require("ue.core.fs").dirname(git.path(ctx))
      private_watch._set_opts_for_test({root = dir, dirty_json_path = dir .. "/dirty.json"})
      local flood = {}; for n = 1, 1100 do flood[n] = dir .. "/Source/f" .. n .. ".cpp" end
      private_watch._seed_persistent_dirty_for_test(flood); private_watch._save_persistent_dirty_for_test()
      local ok, failure = xpcall(function()
        cs.build_index = function(_, _, cb)
          vim.fn.writefile({"int RACED = 1;"}, paths["Keep.cpp"])
          command(repo, "add", ".")
          command(repo, "-c", "user.name=Test Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-m", "Fixture during build")
          vim.schedule(function() cb(true, nil, {ms = 1}) end)
        end
        local success, err, stats = build()
        t.assert_true(success, err); t.assert_false(stats.git_recovered)
        private_watch.remove_persistent_dirty({}, "race", os.time() + 2, false, stats.git_recovered)
        t.assert_true(private_watch.persistent_dirty_status().capped)
      end, debug.traceback)
      private_watch._set_opts_for_test(nil); package.loaded["utils.ue_watch"] = previous_watch
      if not ok then error(failure) end
    end)
  end)
  t.it("non-Git project 要 reset，但 engine 成功 HEAD 仍记录", function()
    fixture(function(ctx, repo, _, calls, build)
      ctx.project_root = repo .. "/../bucket"
      t.assert_true(build())
      local saved = baseline(ctx)
      t.assert_eq(saved.roots[ctx.engine_root].observed_head, command(repo, "rev-parse", "HEAD"))
      t.assert_nil(saved.roots[ctx.project_root].coverage_head)
      capped(); t.assert_true(build()); t.assert_eq(calls[2].mode, "reset")
    end)
  end)
  t.it("Windows 路径比较忽略 casing，输出仍保留 workspace spelling", function()
    if require("utils.platform").driver().path_key("A") ~= "a" then t.skip("case-insensitive host only"); return end
    fixture(function(ctx, _, paths, calls, build)
      local actual = paths["Keep.cpp"]
      paths["Keep.cpp"] = actual:upper()
      t.assert_true(build()); vim.fn.writefile({"int CASE_EDIT = 1;"}, actual)
      capped(); t.assert_true(build())
      t.assert_true(set_of(calls[2].added)[actual:upper()])
    end)
  end)
  t.it("真实 cindex 通过 Git 恢复替换内容并删除旧命中", function()
    if not cs.csearch_exe() or not cs.cindex_uefilter_exe() then t.skip("native csearch unavailable"); return end
    local native_build = cs.build_index
    fixture(function(ctx, repo, paths, _, build)
      cs.build_index = native_build
      local lines = {"int GIT_RECOVERY_ORIGINAL = 1;"}
      for n = 1, 300 do lines[#lines + 1] = ("int filler_%d = %d;"):format(n, n) end
      vim.fn.writefile(lines, paths["Keep.cpp"])
      t.assert_true(build())
      lines[1] = "int GIT_RECOVERY_FRESH = 1;"
      vim.fn.writefile(lines, paths["Keep.cpp"]); vim.fn.delete(paths["Deleted.cpp"])
      capped(); local ok, err, stats = build()
      t.assert_true(ok, err); t.assert_eq(stats.mode, "add"); t.assert_true(stats.git_recovered)
      local function search(token)
        local hits = {}
        await(function(cb)
          cs.stream({workspace_root = repo, csearch_idx = ctx.paths.csearch_idx}, token,
            {regex = false, case = true, code_only = true},
            {on_line = function(file) hits[#hits + 1] = file end, on_done = function() cb() end})
        end)
        return hits
      end
      t.assert_eq(#search("GIT_RECOVERY_FRESH"), 1)
      t.assert_eq(#search("GIT_RECOVERY_ORIGINAL"), 0)
      t.assert_eq(#search("ORIGINAL_Deleted_cpp"), 0)
    end)
  end)
  t.it("先确认删除后 stat 失败：fallback reset 的 canonical 与 snapshot 同步过滤", function()
    fixture(function(ctx, repo, paths, calls, build, list)
      t.assert_true(build())
      local input = list()
      ctx.paths.workspace_all_list = repo .. "/../bucket/canonical.files"
      vim.fn.writefile({"Engine/Deleted.cpp", "Engine/Modified.cpp"}, ctx.paths.workspace_all_list)
      vim.fn.delete(paths["Deleted.cpp"])
      vim.fn.writefile({"int MODIFIED = 7;"}, paths["Modified.cpp"])
      capped()
      local original_keys, original_stat = vim.tbl_keys, vim.uv.fs_stat
      vim.tbl_keys = function(value)
        if value[paths["Deleted.cpp"]] == true and value[paths["Modified.cpp"]] == true then
          return {paths["Deleted.cpp"], paths["Modified.cpp"]}
        end
        return original_keys(value)
      end
      local checked = {}
      vim.uv.fs_stat = function(path, callback)
        if callback and (path == paths["Deleted.cpp"] or path == paths["Modified.cpp"]) then
          checked[#checked + 1] = path
          vim.schedule(function()
            callback(path == paths["Deleted.cpp"] and "ENOENT: fixture missing" or "EACCES: fixture denied", nil)
          end)
          return {}
        end
        return original_stat(path, callback)
      end
      local passed, failure = xpcall(function()
        local ok, err, stats = await(function(cb)
          smart.csearch_smart_build(ctx, {workspace_root = repo}, input, cb, {})
        end)
        t.assert_true(ok, err); t.assert_eq(stats.mode, "reset")
        t.assert_eq(checked[1], paths["Deleted.cpp"]); t.assert_eq(checked[2], paths["Modified.cpp"])
        t.assert_eq(calls[2].mode, "reset")
        t.assert_false(set_of(calls[2].added)[paths["Deleted.cpp"]])
        t.assert_false(set_of(vim.fn.readfile(ctx.paths.csearch_idx .. ".files"))[paths["Deleted.cpp"]])
        t.assert_eq(table.concat(vim.fn.readfile(ctx.paths.workspace_all_list), "\n"), "Engine/Modified.cpp")
      end, debug.traceback)
      vim.tbl_keys, vim.uv.fs_stat = original_keys, original_stat
      if not passed then error(failure) end
    end)
  end)
end)
