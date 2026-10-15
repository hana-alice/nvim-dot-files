local t = require("tests.harness")
t.bootstrap()
local fixture = require("ue.index.prepare_fixture")
local ue = require("ue")
local index = require("ue.index")
local locks = require("ue.file_lock")

local function with_context(run)
  local root = vim.fs.normalize(vim.fn.tempname()) .. "_prepare_fixture"
  vim.fn.mkdir(root, "p")
  root = vim.fs.normalize(vim.uv.fs_realpath(root))
  local paths = {}
  for _, name in ipairs({ "index_dir", "index_state", "index_queue", "index_cdb_dir",
    "index_current_cdb", "index_hot_cdb", "index_full_cdb", "active_cdb",
    "current_index", "hot_index", "full_index", "semantic_cdb",
    "semantic_current_cdb", "semantic_hot_cdb", "semantic_full_cdb", "runtime_dir" }) do
    paths[name] = root .. "/" .. name
  end
  vim.fn.mkdir(paths.runtime_dir, "p")
  local ctx = { engine_root = root .. "_source", project_root = root .. "_project", paths = paths, state = {} }
  vim.fn.writefile({ vim.json.encode({ { directory = root, file = root .. "/source.cpp", arguments = { "clang++", "source.cpp" } } }) }, paths.active_cdb)
  local previous = vim.g.ue_prepare_headless
  vim.g.ue_prepare_headless = 1
  local ok, err = xpcall(function() run(ctx, root) end, debug.traceback)
  vim.g.ue_prepare_headless = previous
  vim.fn.delete(root, "rf")
  if not ok then error(err) end
end

t.describe("isolated prepare integration fixture", function()
  t.it("requires explicit headless flag", function()
    with_context(function(ctx, root)
      vim.g.ue_prepare_headless = 0
      local value, err = fixture.validate(ctx, root)
      t.assert_nil(value); t.assert_match(err, "headless")
    end)
  end)

  t.it("rejects a private root inside the real source checkout", function()
    with_context(function(ctx, root)
      ctx.engine_root = root
      local value, err = fixture.validate(ctx, root)
      t.assert_nil(value); t.assert_match(err, "overlaps")
    end)
  end)

  t.it("checks optional writable paths as well as required paths", function()
    with_context(function(ctx, root)
      ctx.paths.extra_output = root .. "_outside/file"
      local value, err = fixture.validate(ctx, root)
      t.assert_nil(value); t.assert_match(err, "extra_output")
    end)
  end)

  t.it("rejects parent traversal and missing mandatory paths", function()
    with_context(function(ctx, root)
      ctx.paths.index_state = root .. "/../outside.json"
      t.assert_nil((fixture.validate(ctx, root)))
      ctx.paths.index_state = nil
      t.assert_nil((fixture.validate(ctx, root)))
    end)
  end)

  t.it("limits copied input by actual decoded entry count", function()
    with_context(function(ctx, root)
      local entries = {}
      for number = 1, 31 do entries[number] = { file = "source" .. number .. ".cpp" } end
      vim.fn.writefile({ vim.json.encode(entries) }, ctx.paths.active_cdb)
      t.assert_nil((fixture.validate(ctx, root)))
      local value = fixture.validate(ctx, root, { input_limit = 194 })
      t.assert_eq(value.input_count, 31)
      t.assert_nil((fixture.validate(ctx, root, { input_limit = 257 })))
    end)
  end)

  t.it("public entry holds the real prepare lease and reaches delivery with private context", function()
    with_context(function(ctx, root)
      local original, called = index.schedule_prepare_delivery, false
      index.schedule_prepare_delivery = function(actual)
        called = true
        t.assert_eq(actual, ctx)
        t.assert_true(ue._prepare_running)
        t.assert_eq(locks.owner(ctx.paths.runtime_dir .. "/prepare.lock").pid, vim.fn.getpid())
        t.assert_eq(ctx._headless_index_fixture.input_count, 1)
      end
      local ok, result, info = xpcall(function() return ue._prepare_index_fixture_for_test(ctx, root) end, debug.traceback)
      index.schedule_prepare_delivery = original
      if not ok then error(result) end
      t.assert_true(result); t.assert_true(called)
      t.assert_eq(info.input_count, 1)
      t.assert_false(ue._prepare_running)
      t.assert_nil(locks.owner(ctx.paths.runtime_dir .. "/prepare.lock"))
    end)
  end)

  t.it("delivery exception releases the real prepare lease", function()
    with_context(function(ctx, root)
      local original = index.schedule_prepare_delivery
      index.schedule_prepare_delivery = function() error("fixture-delivery-failed") end
      local ok, result, err = xpcall(function() return ue._prepare_index_fixture_for_test(ctx, root) end, debug.traceback)
      index.schedule_prepare_delivery = original
      if not ok then error(result) end
      t.assert_false(result); t.assert_match(err, "fixture%-delivery%-failed")
      t.assert_false(ue._prepare_running)
      t.assert_nil(locks.owner(ctx.paths.runtime_dir .. "/prepare.lock"))
    end)
  end)

  t.it("an existing real prepare lease rejects fixture before scheduling", function()
    with_context(function(ctx, root)
      local lease = assert(locks.acquire(ctx.paths.runtime_dir .. "/prepare.lock"))
      local ok, result, err = xpcall(function() return ue._prepare_index_fixture_for_test(ctx, root) end, debug.traceback)
      locks.release(lease)
      if not ok then error(result) end
      t.assert_false(result)
      t.assert_type(err, "string")
      t.assert_nil(ctx._headless_index_fixture)
    end)
  end)
end)
