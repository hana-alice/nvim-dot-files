local t = require("tests.harness")
t.bootstrap()

local ue = require("ue")

local function experiment(fn)
  local root = vim.fn.tempname():gsub("\\", "/")
  local db = root .. "/db"
  vim.fn.mkdir(db, "p")
  for _, name in ipairs({ "GTAGS", "GRTAGS", "GPATH" }) do
    vim.fn.writefile({ "fixture" }, db .. "/" .. name)
  end
  local context = { engine_root = root, project_root = root, paths = { workspace_db = db } }
  local original = ue._async.run_lines
  local pending, calls = nil, 0
  ue._async.run_lines = function(_, options, callback)
    calls = calls + 1
    t.assert_eq(options.cwd, root)
    pending = callback
    return 17
  end
  local ok, err = xpcall(function()
    fn(context, function()
      t.assert_true(pending ~= nil, "a frozen context must reach the transport")
      pending(0, { "Source/File.cpp:4:Used();" })
    end, function()
      return calls
    end)
  end, debug.traceback)
  ue._async.run_lines = original
  vim.fn.delete(root, "rf")
  if not ok then
    error(err)
  end
end

t.describe("GTAGS references ownership before delivery", function()
  t.it("collect returns source locations without changing quickfix or windows", function()
    experiment(function(context, deliver)
      local id = vim.fn.getqflist({ id = 0 }).id
      local windows = vim.api.nvim_list_wins()
      local called = false
      ue.gtags_references_async("Used", function(hit, entries, metadata)
        called = true
        t.assert_true(hit)
        t.assert_eq(entries[1].filename, context.project_root .. "/Source/File.cpp")
        t.assert_eq(entries[1].lnum, 4)
        t.assert_eq(metadata.source, "GTAGS")
        t.assert_eq(metadata.coverage, "unknown")
      end, {
        context = context,
        collect = true,
        is_current = function()
          return true
        end,
      })
      deliver()
      t.assert_true(called)
      t.assert_eq(vim.fn.getqflist({ id = 0 }).id, id)
      t.assert_true(vim.deep_equal(vim.api.nvim_list_wins(), windows))
    end)
  end)

  t.it("an expired request cannot mutate quickfix before its callback guard", function()
    experiment(function(context, deliver)
      local current, called = true, false
      local id = vim.fn.getqflist({ id = 0 }).id
      local win = vim.api.nvim_get_current_win()
      ue.gtags_references_async("Used", function()
        called = true
      end, {
        context = context,
        is_current = function()
          return current
        end,
      })
      current = false
      deliver()
      t.assert_false(called)
      t.assert_eq(vim.fn.getqflist({ id = 0 }).id, id)
      t.assert_eq(vim.api.nvim_get_current_win(), win)
    end)
  end)

  t.it("an invalid owner rejects work before spawning", function()
    experiment(function(context, _, calls)
      ue.gtags_references_async("Used", function()
        error("expired callback")
      end, {
        context = context,
        is_current = function()
          return false
        end,
      })
      t.assert_eq(calls(), 0)
    end)
  end)
end)
