local t = require("tests.harness")
t.bootstrap()
local smart, git, cs = require("ue.csearch_smart"), require("ue.csearch_git"), require("utils.code_search")
local watch, native = require("utils.ue_watch"), require("utils.ue_watch_native")
local function await(start)
  local values
  start(function(...) values = { n = select("#", ...), ... } end)
  t.assert_true(vim.wait(15000, function() return values ~= nil end, 5), "X2 callback timeout")
  return unpack(values, 1, values.n)
end
local function fixture(body)
  local root = vim.fn.tempname():gsub("\\", "/") .. "-x2"
  vim.fn.mkdir(root, "p")
  local file, index, list = root .. "/Lost.cpp", root .. "/search.idx", root .. "/inputs.files"
  vim.fn.writefile({ "int X2_ORIGINAL_SEARCH_TOKEN = 1;" }, file)
  vim.fn.writefile({ file }, list); vim.fn.writefile({ file }, index .. ".files")
  local ctx = { engine_root = root, project_root = "", paths = { csearch_idx = index } }
  local cs_ctx = { csearch_idx = index, workspace_root = root }
  local head = string.rep("a", 40)
  vim.fn.writefile({ vim.json.encode({ schema = 1, roots = {
    [root] = { top = root, coverage_head = head, dirty = {} },
  } }) }, git.path(ctx))
  local old = { capture = git.capture, recover = git.recover, build = cs.build_index,
    indexed = cs.is_indexed, dirty = watch.persistent_dirty_status, snapshot = watch.snapshot_persistent_dirty,
    system = vim.system }
  git.capture = function(_, cb) cb({ [root] = { top = root, head = head, dirty = { [file] = true } } }, {}) end
  git.recover = function(_, _, _, _, cb) cb({ [file] = true }, nil, {}) end
  watch.persistent_dirty_status = function() return { capped = false } end
  watch.snapshot_persistent_dirty = function() return {} end
  local calls = {}
  cs.build_index = function(_, _, cb, opts)
    calls[#calls + 1] = opts.mode
    vim.schedule(function() cb(true, nil, {}) end)
  end
  local function build()
    return await(function(cb) smart.csearch_smart_build(ctx, cs_ctx, list, cb, {}) end)
  end
  local ok, err = xpcall(function() body(root, file, index, ctx, cs_ctx, calls, build, old) end, debug.traceback)
  watch.stop(); native.set_for_test(nil)
  git.capture, git.recover, cs.build_index, cs.is_indexed = old.capture, old.recover, old.build, old.indexed
  watch.persistent_dirty_status, watch.snapshot_persistent_dirty, vim.system = old.dirty, old.snapshot, old.system
  if not ok then error(err) end
end

t.describe("X2 csearch coverage failures", function()
  t.it("valid native primary plus an unchanged snapshot still skips without rewriting the index", function()
    local tool = cs.cindex_uefilter_exe()
    if not tool or not cs.csearch_exe() then t.skip("native valid-primary skip", "cindex/csearch unavailable", { native = true }); return end
    fixture(function(root, _, index, _, cs_ctx, calls, build)
      local built = vim.system({ tool, "-reset", "-files-from", root .. "/inputs.files" },
        { env = { CSEARCHINDEX = index }, text = true }):wait()
      t.assert_eq(built.code, 0, built.stderr)
      t.assert_true(cs.is_indexed(cs_ctx))
      git.capture = function(_, cb) cb({ [root] = { top = root, head = string.rep("a", 40), dirty = {} } }, {}) end
      local function bytes() local f = assert(io.open(index, "rb")); local raw = f:read("*a"); f:close(); return raw end
      local before = bytes()
      local ok, err, stats = build()
      t.assert_true(ok, err); t.assert_eq(stats.mode, "skip"); t.assert_eq(#calls, 0)
      t.assert_eq(bytes(), before)
    end)
  end)
  t.it("missing primary index with an existing snapshot must reset", function()
    fixture(function(_, _, index, _, _, calls, build)
      t.assert_nil(vim.uv.fs_stat(index))
      local ok, err, stats = build()
      t.assert_true(ok, err); t.assert_eq(stats.mode, "reset"); t.assert_eq(calls[1], "reset")
      t.assert_contains(stats.delta, "primary csearch index")
    end)
  end)
  t.it("corrupt primary framing with the same snapshot must reset", function()
    fixture(function(_, _, index, _, _, calls, build)
      vim.fn.writefile({ string.rep("x", 4096) }, index)
      local ok, err, stats = build()
      t.assert_true(ok, err); t.assert_eq(stats.mode, "reset"); t.assert_eq(calls[1], "reset")
    end)
  end)
  t.it("availability exception is conservative, never skip", function()
    fixture(function(_, _, _, _, _, calls, build)
      cs.is_indexed = function() error("injected unavailable reader") end
      t.assert_true(build()); t.assert_eq(calls[1], "reset")
    end)
  end)
  t.it("capture timeout with a known baseline triggers unavailable/reset and invalidates coverage", function()
    fixture(function(root, _, _, ctx, _, calls, build, old)
      cs.is_indexed = function() return true end
      git.capture = old.capture
      vim.system = function(argv, _, cb)
        t.assert_eq(argv[1], "git")
        vim.schedule(function() cb({ code = 124, stdout = "", stderr = "timeout" }) end)
        return { is_closing = function() return true end }
      end
      local ok, err, stats = build()
      t.assert_true(ok, err); t.assert_eq(stats.mode, "reset"); t.assert_eq(calls[1], "reset")
      t.assert_contains(stats.git_capture_unavailable, "git query failed")
      t.assert_false(stats.git_recovered)
      local data = vim.json.decode(table.concat(vim.fn.readfile(git.path(ctx)), "\n"))
      t.assert_nil(data.roots[root].coverage_head)
      t.assert_true(build()); t.assert_eq(calls[2], "reset", "continued failure cannot become skip")
    end)
  end)
  t.it("declared non-Git new root is optional; missing formerly known Git root is unavailable", function()
    fixture(function(root, _, _, ctx)
      ctx.project_root = root .. "/external"
      local observed = { [root] = { top = root, head = string.rep("a", 40), dirty = {} } }
      local _, bootstrap, unavailable = git.pending(ctx, observed, { [ctx.project_root] = "not a Git worktree" })
      t.assert_false(bootstrap); t.assert_nil(unavailable)
      local _, _, failed = git.pending(ctx, {}, { [root] = "not a Git worktree" })
      t.assert_contains(failed, "not a Git worktree")
    end)
  end)
  t.it("native loss persists across restart, failed recovery retains it, and successful recovery acknowledges only older loss", function()
    fixture(function(root, _, _, _, _, calls, build, old)
      watch.persistent_dirty_status, watch.snapshot_persistent_dirty = old.dirty, old.snapshot
      cs.is_indexed = function() return true end
      local callback, reports = nil, 0
      native.set_for_test({ start = function(_, _, _, cb) callback = cb; return true end,
        stop = function() end, close = function() end })
      local opts = { root = root, dirty_json_path = root .. "/dirty.json",
        on_source_unknown = function() reports = reports + 1 end }
      t.assert_true(watch.start(opts))
      callback(nil, nil, { unknown = true, overflow = true })
      t.assert_true(watch.persistent_dirty_status().capped)
      t.assert_true(vim.uv.fs_stat(opts.dirty_json_path .. ".overflow") ~= nil)
      watch.stop(); watch._set_opts_for_test(nil); t.assert_true(watch.start(opts))
      t.assert_true(watch.persistent_dirty_status().capped, "persisted coverage loss must survive reload")
      local writer = cs.build_index
      cs.build_index = function(_, _, cb) cb(false, "failed recovery", { verification_unavailable = true }) end
      t.assert_false(build()); t.assert_true(watch.persistent_dirty_status().capped)
      cs.build_index = writer
      local started = os.time() + 2
      local ok, err, stats = build()
      t.assert_true(ok, err); t.assert_eq(stats.mode, "add"); t.assert_true(stats.git_recovered)
      t.assert_eq(calls[1], "add")
      t.assert_true(watch.remove_persistent_dirty({}, "X2 completed recovery", started, false, stats.git_recovered))
      t.assert_false(watch.persistent_dirty_status().capped)
      callback(nil, nil, { unknown = true, overflow = true })
      t.assert_true(watch.persistent_dirty_status().capped, "next loss must remain visible")
      t.assert_true(watch.remove_persistent_dirty({}, "second completed recovery", os.time() + 2, false, true))
      t.assert_false(watch.persistent_dirty_status().capped)
      callback(nil, nil, { unknown = true, overflow = true })
      t.assert_true(watch.persistent_dirty_status().capped, "coalesced loss must re-persist after recovery")
      t.assert_true(watch.remove_persistent_dirty({}, "older in-flight build", os.time(), false, true))
      t.assert_true(watch.persistent_dirty_status().capped, "in-flight loss must not be acknowledged")
      t.assert_eq(reports, 2, "source refresh remains coalesced across consecutive loss messages")
    end)
  end)
end)
