-- tests/cases/ue_watch_csearch_spec.lua
-- ue_watch 的 csearch provider 必须是 RECORD-ONLY —— 绝不写 csearch.idx。
--
-- 背景（D9，2026-06-17）：cindex 把 staged 路径硬编码为 <idx>~，watcher 增量与
-- 用户 :UEPrepare 全量并发会抢同一个 idx~，在 merge/rename 窗口互毁 →
-- `corrupt index: remove` + 0 字节死循环。结论：csearch 索引单写者，写者只能是
-- 用户显式触发的 prepare 家族；watcher 退回记账员（只更新 persistent_dirty）。
--
-- 这些用例是【防回归护栏】：若有人把 watcher 重新接回 csearch 写入（build_index /
-- cindex 调用），静态 + 行为断言都会变红。

local t = require("tests.harness")
t.bootstrap()

local watch = require("utils.ue_watch")

-- ── 静态护栏（防止 csearch 写者复活）──────────────────────────────────────
t.describe("ue_watch csearch provider 静态护栏（D9 单写者）", function()
  local source
  do
    local root = vim.fn.stdpath("config"):gsub("\\", "/")
    local path = root .. "/lua/utils/ue_watch.lua"
    local f = io.open(path, "rb")
    source = f and f:read("*a") or ""
    if f then f:close() end
  end

  -- provider_csearch_add 函数体只允许出现在它自己的实现里，整文件不得再调用
  -- build_index / cindex / 写 .incremental.txt。
  -- provider_csearch_add 函数体只允许出现在它自己的实现里，整文件不得再调用
  -- build_index / cindex / 写 .incremental.txt。注意只匹配【调用】形态
  -- `code_search.build_index(`，doc-comment 里提到该名字（"不得 re-add"）不算违规。
  t.it("不调用 code_search.build_index（写者已退役）", function()
    t.assert_false(source:find("code_search%.build_index%s*%(") ~= nil,
      "ue_watch 不得调用 build_index() —— csearch 写入是 prepare 家族的专属职责")
  end)

  t.it("不再写 -files-from 增量列表 / 不 spawn cindex", function()
    t.assert_false(source:find(".incremental.txt", 1, true) ~= nil,
      "不得再写 <idx>.incremental.txt 临时列表")
    t.assert_false(source:find('local cindex = "cindex"', 1, true) ~= nil,
      "不得再用裸 cindex")
    t.assert_false(source:find("%-files%-from") ~= nil,
      "不得再走 -files-from（那是写者路径）")
  end)

  t.it("doc/header 声明 D9 单写者契约", function()
    t.assert_contains(source, "D9")
    t.assert_contains(source, "persistent_dirty")
  end)
end)

-- ── 行为护栏：provider 是 no-op，绝不触发任何 csearch 写 ────────────────────
t.describe("ue_watch csearch provider 行为（record-only no-op）", function()
  local cs = require("utils.code_search")
  local orig_build = cs.build_index
  local orig_probe = cs.cindex_uefilter_exe

  local function restore()
    cs.build_index = orig_build
    cs.cindex_uefilter_exe = orig_probe
    watch._set_opts_for_test(nil)
  end

  t.it("有 dirty 路径时不调用 build_index（不写索引）", function()
    local called = false
    cs.cindex_uefilter_exe = function() return "cindex-uefilter" end
    cs.build_index = function() called = true end
    local idx = vim.fn.tempname():gsub("\\", "/") .. "/csearch.idx"
    vim.fn.mkdir(vim.fn.fnamemodify(idx, ":h"), "p")
    watch._set_opts_for_test({ csearch_index = idx })

    local ok = watch._provider_csearch_add_for_test({
      "D:/UE/EngineWorktree/Engine/Source/Runtime/VulkanRHI/Private/VulkanCommandBuffer.cpp",
      "D:/UE/EngineWorktree/Engine/Source/Runtime/Renderer/Private/MobileShadingRenderer.cpp",
    })
    t.assert_true(ok, "provider 应返回 true（record-only no-op 成功）")
    t.assert_false(called, "MUST NOT 调用 build_index —— watcher 不是索引器")
    -- 不得留下增量列表临时文件
    t.assert_nil(vim.loop.fs_stat(idx .. ".incremental.txt"),
      "不得写 <idx>.incremental.txt")

    pcall(vim.fn.delete, vim.fn.fnamemodify(idx, ":h"), "rf")
    restore()
  end)

  t.it("空 paths 也是 no-op（不写索引）", function()
    local called = false
    cs.build_index = function() called = true end
    watch._set_opts_for_test({ csearch_index = "/x/csearch.idx" })
    local ok = watch._provider_csearch_add_for_test({})
    t.assert_true(ok)
    t.assert_false(called)
    restore()
  end)
end)

-- ── F2（health-check 2026-07）：dirty set cap 打满必须可见 ──────────────────
-- 现场：批量 git 操作一次性弄脏 1000+ ThirdParty 文件，cap 裁剪静默丢增量，
-- overlay 变 lossy 无任何提示。约束：打满 → WARN 一次 + status().capped=true；
-- clear 后复位。
local t3 = require("tests.harness")
t3.describe("ue_watch: persistent_dirty cap 打满可见（F2）", function()
  local watch = require("utils.ue_watch")
  -- save_persistent_dirty 无落盘路径时 early-return（裁剪也不会跑）——
  -- 用真实临时 dirty.json 路径驱动完整 save 路径。
  local function with_tmp_dirty(fn)
    local dir = vim.fn.tempname():gsub("\\", "/")
    vim.fn.mkdir(dir, "p")
    watch._set_opts_for_test({ dirty_json_path = dir .. "/dirty.json" })
    fn()
    watch.clear_persistent_dirty("test:f2-cleanup")
    watch._set_opts_for_test(nil)
    pcall(vim.fn.delete, dir, "rf")
  end

  t3.it("超 cap 裁剪后 status().capped=true，count==cap", function()
    with_tmp_dirty(function()
      local flood = {}
      for i = 1, 1100 do flood[i] = ("D:/x/f%04d.cpp"):format(i) end
      watch._seed_persistent_dirty_for_test(flood)
      watch._save_persistent_dirty_for_test()
      local st = watch.persistent_dirty_status() or {}
      t3.assert_eq(st.count, st.cap, "裁剪后 count 应等于 cap")
      t3.assert_true(st.capped, "打满后 capped 标志必须为 true（overlay lossy 可见）")
    end)
  end)

  t3.it("clear 后 capped 复位为 false", function()
    with_tmp_dirty(function()
      local flood = {}
      for i = 1, 1100 do flood[i] = ("D:/y/g%04d.cpp"):format(i) end
      watch._seed_persistent_dirty_for_test(flood)
      watch._save_persistent_dirty_for_test()
      watch.clear_persistent_dirty("test:f2-reset")
      local st = watch.persistent_dirty_status() or {}
      t3.assert_eq(st.count, 0)
      t3.assert_false(st.capped, "clear 后 capped 必须复位")
    end)
  end)

  t3.it("未超 cap 时 capped 保持 false", function()
    with_tmp_dirty(function()
      watch._seed_persistent_dirty_for_test({ "D:/z/a.cpp", "D:/z/b.cpp" })
      watch._save_persistent_dirty_for_test()
      local st = watch.persistent_dirty_status() or {}
      t3.assert_eq(st.count, 2)
      t3.assert_false(st.capped)
    end)
  end)

  t3.it("完成增量索引只移除 covered snapshot，保留并发新增 dirty", function()
    with_tmp_dirty(function()
      local path = watch.persistent_dirty_status().path
      watch._seed_persistent_dirty_for_test({ "D:/z/a.cpp", "D:/z/b.cpp" })
      watch._save_persistent_dirty_for_test()
      vim.fn.writefile({ vim.json.encode({ "D:/z/a.cpp", "D:/z/b.cpp", "D:/z/c.cpp" }) }, path)
      t3.assert_true(watch.remove_persistent_dirty({ "D:/z/a.cpp" }, "test:covered"))
      local decoded = vim.json.decode(table.concat(vim.fn.readfile(path), "\n"))
      local seen = {}
      for _, item in ipairs(decoded) do seen[item:lower()] = true end
      t3.assert_false(seen["d:/z/a.cpp"] == true)
      t3.assert_true(seen["d:/z/b.cpp"] == true)
      t3.assert_true(seen["d:/z/c.cpp"] == true)
    end)
  end)

  t3.it("同一路径在 build 开始后再次修改时继续保持 dirty", function()
    with_tmp_dirty(function()
      local dir = vim.fn.fnamemodify(watch.persistent_dirty_status().path, ":h")
      local old_path = dir .. "/old.cpp"
      local changed_path = dir .. "/changed.cpp"
      vim.fn.writefile({ "old" }, old_path)
      vim.fn.writefile({ "changed" }, changed_path)
      local started_at = os.time()
      vim.uv.fs_utime(old_path, started_at - 10, started_at - 10)
      vim.uv.fs_utime(changed_path, started_at, started_at)
      watch._seed_persistent_dirty_for_test({ old_path, changed_path })
      watch._save_persistent_dirty_for_test()
      t3.assert_true(watch.remove_persistent_dirty(
        { old_path, changed_path }, "test:mtime-guard", started_at))
      local decoded = vim.json.decode(table.concat(vim.fn.readfile(
        watch.persistent_dirty_status().path), "\n"))
      local seen = {}
      for _, item in ipairs(decoded) do seen[item:lower()] = true end
      t3.assert_false(seen[old_path:lower()] == true)
      t3.assert_true(seen[changed_path:lower()] == true)
    end)
  end)
end)

-- ── Windows metadata-event flood guard ─────────────────────────────────────
t3.describe("ue_watch project ownership", function()
  t3.it("an already queued old watcher event cannot target the new project", function()
    local root = vim.fn.tempname():gsub("\\", "/")
    local a, b = root .. "/A", root .. "/B"
    vim.fn.mkdir(a, "p")
    vim.fn.mkdir(b, "p")
    local original_wrap, queued = vim.schedule_wrap, nil
    local ok, err = pcall(function()
      vim.schedule_wrap = function(callback)
        queued = callback
        return original_wrap(callback)
      end
      assert(watch.start({ root = a, dirty_json_path = a .. "/dirty.json" }))
      vim.schedule_wrap = original_wrap
      assert(watch.start({ root = b, dirty_json_path = b .. "/dirty.json" }))
      queued(nil, "old.cpp", { rename = true })
      t3.assert_eq(watch.status().pending_adds, 0)
      t3.assert_eq(watch.status().pending_dels, 0)
    end)
    vim.schedule_wrap = original_wrap
    watch.stop()
    watch._set_opts_for_test(nil)
    pcall(vim.fn.delete, root, "rf")
    if not ok then error(err) end
  end)

  t3.it("a contended outgoing save retries its captured bucket after switching", function()
    local root = vim.fn.tempname():gsub("\\", "/")
    local a, b = root .. "/A", root .. "/B"
    vim.fn.mkdir(a, "p")
    vim.fn.mkdir(b, "p")
    local lock = require("ue.file_lock")
    local lease = assert(lock.acquire(a .. "/dirty.json.lock"))
    local original_defer, retry = vim.defer_fn, nil
    local ok, err = pcall(function()
      assert(watch.start({ root = a, dirty_json_path = a .. "/dirty.json" }))
      watch._seed_persistent_dirty_for_test({ a .. "/pending.cpp" })
      vim.defer_fn = function(callback) retry = callback; return {} end
      watch._save_persistent_dirty_for_test()
      vim.defer_fn = original_defer
      t3.assert_type(retry, "function")
      watch.stop()
      assert(watch.start({ root = b, dirty_json_path = b .. "/dirty.json" }))
      lock.release(lease)
      retry()
      t3.assert_true(vim.deep_equal(watch.snapshot_persistent_dirty(), {}))
      t3.assert_true(vim.deep_equal(vim.json.decode(table.concat(vim.fn.readfile(a .. "/dirty.json"))),
        { a .. "/pending.cpp" }))
      t3.assert_eq(vim.fn.filereadable(b .. "/dirty.json"), 0)
    end)
    vim.defer_fn = original_defer
    lock.release(lease)
    watch.stop()
    watch._set_opts_for_test(nil)
    pcall(vim.fn.delete, root, "rf")
    if not ok then error(err) end
  end)

  t3.it("save retries back off, stop at a bound, and recover on a later successful save", function()
    local root = vim.fn.tempname():gsub("\\", "/")
    vim.fn.mkdir(root, "p")
    local lock = require("ue.file_lock")
    local lease = assert(lock.acquire(root .. "/dirty.json.lock"))
    local original_defer, retries, delays = vim.defer_fn, {}, {}
    local ok, err = pcall(function()
      vim.defer_fn = function(callback, delay)
        retries[#retries + 1], delays[#delays + 1] = callback, delay
        return { stop = function() end, close = function() end }
      end
      assert(watch.start({ root = root, dirty_json_path = root .. "/dirty.json" }))
      watch._seed_persistent_dirty_for_test({ root .. "/pending.cpp" })
      watch._save_persistent_dirty_for_test()
      local cursor = 1
      while retries[cursor] and cursor <= 20 do retries[cursor](); cursor = cursor + 1 end
      t3.assert_true(#retries > 1 and #retries <= 10, "retry sequence must be bounded")
      t3.assert_true(delays[2] > delays[1], "persistent contention must back off")
      lock.release(lease)
      watch._save_persistent_dirty_for_test()
      t3.assert_true(vim.deep_equal(vim.json.decode(table.concat(vim.fn.readfile(root .. "/dirty.json"))),
        { root .. "/pending.cpp" }))
    end)
    vim.defer_fn = original_defer
    lock.release(lease)
    watch.stop()
    watch._set_opts_for_test(nil)
    pcall(vim.fn.delete, root, "rf")
    if not ok then error(err) end
  end)

  t3.it("successful save cancels an outstanding retry and suppresses its queued callback", function()
    local root = vim.fn.tempname():gsub("\\", "/")
    vim.fn.mkdir(root, "p")
    local lock = require("ue.file_lock")
    local lease = assert(lock.acquire(root .. "/dirty.json.lock"))
    local original_defer, original_open = vim.defer_fn, io.open
    local queued, cancelled, writes = nil, 0, 0
    local ok, err = pcall(function()
      vim.defer_fn = function(callback)
        queued = callback
        return { stop = function() cancelled = cancelled + 1 end, close = function() end }
      end
      assert(watch.start({ root = root, dirty_json_path = root .. "/dirty.json" }))
      watch._seed_persistent_dirty_for_test({ root .. "/pending.cpp" })
      watch._save_persistent_dirty_for_test()
      lock.release(lease)
      watch._save_persistent_dirty_for_test()
      t3.assert_eq(cancelled, 1)
      io.open = function(path, mode)
        if mode == "w" then writes = writes + 1 end
        return original_open(path, mode)
      end
      queued()
      t3.assert_eq(writes, 0, "an invalidated retry must not start another write")
    end)
    vim.defer_fn, io.open = original_defer, original_open
    lock.release(lease)
    watch.stop()
    watch._set_opts_for_test(nil)
    pcall(vim.fn.delete, root, "rf")
    if not ok then error(err) end
  end)

  for _, failure in ipairs({ "open", "write", "close", "rename" }) do
    t3.it("outgoing bucket survives transient " .. failure .. " failure after lock retry", function()
      local root = vim.fn.tempname():gsub("\\", "/")
      local a, b = root .. "/A", root .. "/B"
      vim.fn.mkdir(a, "p")
      vim.fn.mkdir(b, "p")
      local lock = require("ue.file_lock")
      local lease = assert(lock.acquire(a .. "/dirty.json.lock"))
      local original_defer, original_open, original_rename = vim.defer_fn, io.open, vim.uv.fs_rename
      local retries, injected = {}, false
      local ok, err = pcall(function()
        vim.defer_fn = function(callback)
          retries[#retries + 1] = callback
          return { stop = function() end, close = function() end }
        end
        assert(watch.start({ root = a, dirty_json_path = a .. "/dirty.json" }))
        watch._seed_persistent_dirty_for_test({ a .. "/pending.cpp" })
        watch._save_persistent_dirty_for_test()
        assert(watch.start({ root = b, dirty_json_path = b .. "/dirty.json" }))
        lock.release(lease)
        io.open = function(path, mode)
          if not injected and mode == "w" and path:find(a .. "/dirty.json.tmp.", 1, true) then
            if failure == "open" then injected = true; return nil, "temporary open failure" end
            if failure == "write" or failure == "close" then
              injected = true
              local fd = assert(original_open(path, mode))
              return {
                write = function(_, data)
                  if failure == "write" then return nil, "temporary write failure" end
                  return fd:write(data)
                end,
                close = function()
                  local closed = fd:close()
                  if failure == "close" then return nil, "temporary close failure" end
                  return closed
                end,
              }
            end
          end
          return original_open(path, mode)
        end
        vim.uv.fs_rename = function(from, to)
          if failure == "rename" and not injected and to == a .. "/dirty.json" then
            injected = true; return nil, "temporary rename failure"
          end
          return original_rename(from, to)
        end
        t3.assert_eq(#retries, 1)
        retries[1]()
        t3.assert_true(injected)
        t3.assert_eq(#retries, 2, "transient I/O failure must queue another captured-owner save")
        retries[2]()
        t3.assert_eq(#retries, 2, "successful save must stop retrying")
        t3.assert_true(vim.deep_equal(vim.json.decode(table.concat(vim.fn.readfile(a .. "/dirty.json"))),
          { a .. "/pending.cpp" }))
        t3.assert_eq(vim.fn.filereadable(b .. "/dirty.json"), 0)
      end)
      vim.defer_fn, io.open, vim.uv.fs_rename = original_defer, original_open, original_rename
      lock.release(lease)
      watch.stop()
      watch._set_opts_for_test(nil)
      pcall(vim.fn.delete, root, "rf")
      if not ok then error(err) end
    end)
  end

  t3.it("switching watchers never merges the previous project's dirty set", function()
    local root = vim.fn.tempname():gsub("\\", "/")
    local a, b = root .. "/A", root .. "/B"
    vim.fn.mkdir(a, "p")
    vim.fn.mkdir(b, "p")
    vim.fn.writefile({ vim.json.encode({ a .. "/A.cpp" }) }, a .. "/dirty.json")
    vim.fn.writefile({ vim.json.encode({ b .. "/B.cpp" }) }, b .. "/dirty.json")
    local ok, err = pcall(function()
      assert(watch.start({ root = a, dirty_json_path = a .. "/dirty.json" }))
      t3.assert_true(vim.deep_equal(watch.snapshot_persistent_dirty(), { a .. "/A.cpp" }))
      watch.stop()
      assert(watch.start({ root = b, dirty_json_path = b .. "/dirty.json" }))
      t3.assert_true(vim.deep_equal(watch.snapshot_persistent_dirty(), { b .. "/B.cpp" }), "B inherited A's dirty files")
      watch._save_persistent_dirty_for_test()
      t3.assert_true(vim.deep_equal(vim.json.decode(table.concat(vim.fn.readfile(b .. "/dirty.json"))), { b .. "/B.cpp" }))
    end)
    watch.stop()
    watch._set_opts_for_test(nil)
    pcall(vim.fn.delete, root, "rf")
    if not ok then error(err) end
  end)
end)

-- libuv's Windows backend subscribes LAST_ACCESS / ATTRIBUTES / SECURITY and
-- folds all of them into UV_CHANGE. Files whose content mtime predates the
-- current csearch index are therefore metadata noise, not post-index edits.
t3.describe("ue_watch: Windows metadata change 不污染 dirty overlay", function()
  local should_track = watch._should_track_existing_event_for_test
  local index_mtime = { sec = 200, nsec = 500 }

  t3.it("早于或等于索引的 change 被过滤", function()
    t3.assert_false(should_track({ mtime = { sec = 100, nsec = 0 } },
      { change = true }, index_mtime))
    t3.assert_false(should_track({ mtime = { sec = 200, nsec = 500 } },
      { change = true }, index_mtime))
  end)

  t3.it("索引后的内容修改继续进入 dirty", function()
    t3.assert_true(should_track({ mtime = { sec = 200, nsec = 501 } },
      { change = true }, index_mtime))
    t3.assert_true(should_track({ mtime = { sec = 201, nsec = 0 } },
      { change = true }, index_mtime))
  end)

  t3.it("rename/create 与无索引场景保持保守记录", function()
    t3.assert_true(should_track({ mtime = { sec = 100, nsec = 0 } },
      { rename = true }, index_mtime), "新文件即使保留旧 mtime 也不能漏")
    t3.assert_true(should_track({ mtime = { sec = 100, nsec = 0 } },
      { change = true }, nil), "首次建索引前没有可靠 anchor，必须记录")
    t3.assert_true(should_track({}, { change = true }, index_mtime),
      "stat 缺 mtime 时必须保守记录")
  end)
end)
