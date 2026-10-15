-- C08/C09: failed publication and failed lazy restore retain their intent.
-- Only private fixture JSON and a mocked nvim-dap store are involved.
local t = require("tests.harness")
t.bootstrap()

local bp = require("ue.dap._persist_bp")
local serial = 0

local function with_fixture(make_initial, body)
  serial = serial + 1
  local base = vim.env.NVIM_TEST_RUN_ROOT or vim.fn.tempname()
  local root = vim.fs.normalize(base .. "/bp-failure-" .. tostring(vim.uv.hrtime()) .. "-" .. serial)
  vim.fn.mkdir(root, "p")
  local path, source = root .. "/breakpoints.json", root .. "/Source.cpp"
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, source)
  local old = {
    ue = package.loaded.ue,
    dap = package.loaded.dap,
    dapbp = package.loaded["dap.breakpoints"],
    defer = vim.defer_fn,
    notify = vim.notify,
    rename = vim.uv.fs_rename,
    open = io.open,
  }
  local fixture = { root = root, path = path, source = source, buf = buf,
    raw = {}, calls = {}, failures = {}, notices = {} }
  local function write(data)
    local fh = assert(io.open(path, "wb"))
    assert(fh:write(vim.json.encode(data)))
    assert(fh:close())
  end
  fixture.write = function(records)
    write({ version = 1, project = "fixture", breakpoints = records })
  end
  fixture.read = function()
    local fh = assert(io.open(path, "rb"))
    local raw = fh:read("*a")
    fh:close()
    return vim.json.decode(raw).breakpoints
  end
  package.loaded.ue = { resolve_context = function()
    return { engine_root = root, project_root = root, paths = { cache = root } }
  end }
  package.loaded.dap = {
    session = function() return nil end,
    sessions = function() return {} end,
    clear_breakpoints = function() fixture.raw = {} end,
  }
  package.loaded["dap.breakpoints"] = {
    get = function() return fixture.raw end,
    set = function(opts, target_buf, line)
      fixture.calls[line] = (fixture.calls[line] or 0) + 1
      if fixture.failures[line] then error("injected set failure at line " .. line) end
      fixture.raw[target_buf] = fixture.raw[target_buf] or {}
      fixture.raw[target_buf][#fixture.raw[target_buf] + 1] = {
        line = line, condition = opts.condition,
        hitCondition = opts.hit_condition, logMessage = opts.log_message,
      }
    end,
  }
  vim.defer_fn = function() return { stop = function() end } end
  vim.notify = function(message, level)
    fixture.notices[#fixture.notices + 1] = { message = message, level = level }
  end
  bp._reset_state_for_test()
  fixture.write(make_initial(fixture))
  local ok, err = xpcall(function() body(fixture) end, debug.traceback)
  bp._reset_state_for_test()
  package.loaded.ue, package.loaded.dap, package.loaded["dap.breakpoints"] = old.ue, old.dap, old.dapbp
  vim.defer_fn, vim.notify, vim.uv.fs_rename = old.defer, old.notify, old.rename
  io.open = old.open
  pcall(vim.api.nvim_buf_delete, buf, { force = true })
  -- Leave fixture files for examination; never remove recovery evidence here.
  if not ok then error(err) end
end

t.describe("persistent breakpoint failure intent", function()
  for _, save_first in ipairs({ true, false }) do
    t.it("C09: live store wins over a failed pending line; save first=" .. tostring(save_first), function()
      with_fixture(function(f) return { [f.source] = { { line = 6, condition = "old" } } } end, function(f)
        f.failures[6] = true
        bp.load()
        f.failures[6] = nil
        package.loaded["dap.breakpoints"].set({ condition = "user edit" }, f.buf, 6)
        if save_first then t.assert_true(bp.save()) end
        bp.restore_for_buf(f.buf)
        t.assert_eq(f.calls[6], 2, "pending must not overwrite a line already set in the live store")
        t.assert_eq(f.raw[f.buf][1].condition, "user edit")
        t.assert_true(bp.save())
        t.assert_eq(f.read()[f.source][1].condition, "user edit")
      end)
    end)
  end
  for _, failed_step in ipairs({ "write", "flush", "close" }) do
    t.it("C08: clear-all survives a failed " .. failed_step .. " before publication", function()
      with_fixture(function(f) return { [f.root .. "/Unopened.cpp"] = { { line = 17 } } } end, function(f)
        bp.clear_all()
        local real_open = io.open
        io.open = function(path, mode)
          local file, err = real_open(path, mode)
          if not file or mode ~= "wb" or not path:find(f.path .. ".tmp.", 1, true) then return file, err end
          return {
            write = function(_, ...)
              if failed_step == "write" then return nil, "injected EIO write" end
              return file:write(...)
            end,
            flush = function()
              if failed_step == "flush" then return nil, "injected EIO flush" end
              return file:flush()
            end,
            close = function()
              local closed, close_err = file:close()
              if failed_step == "close" then return nil, "injected EIO close" end
              return closed, close_err
            end,
          }
        end
        t.assert_false(bp.save())
        t.assert_true(next(f.read()) ~= nil, "failed writer must retain the previous disk state")
        io.open = real_open
        t.assert_true(bp.save())
        t.assert_nil(next(f.read()), "failed write must not consume clear-all intent")
      end)
    end)
  end

  t.it("C08: clear-all survives failed rename, and retires only after successful publication", function()
    with_fixture(function(f)
      return { [f.root .. "/Unopened.cpp"] = { { line = 17 } } }
    end, function(f)
      bp.clear_all()
      local real_rename = vim.uv.fs_rename
      vim.uv.fs_rename = function(from, to, ...)
        if to == f.path then return nil, "EACCES: injected publication failure" end
        return real_rename(from, to, ...)
      end
      t.assert_false(bp.save(), "publication must fail")
      t.assert_true(next(f.read()) ~= nil, "failed publication must leave the previous disk bytes")
      vim.uv.fs_rename = real_rename
      t.assert_true(bp.save(), "the same clear intent must be retryable")
      t.assert_nil(next(f.read()), "retry must clear unopened breakpoints too")
      local foreign = f.root .. "/AnotherWriter.cpp"
      f.write({ [foreign] = { { line = 44 } } })
      t.assert_true(bp.save())
      t.assert_eq(f.read()[foreign][1].line, 44,
        "a consumed clear intent must not erase another writer on later saves")
    end)
  end)

  t.it("C09: failed local set remains pending and succeeds on a later restore", function()
    with_fixture(function(f) return { [f.source] = { { line = 5 } } } end, function(f)
      f.failures[5] = true
      bp.load()
      t.assert_eq(f.calls[5], 1)
      t.assert_eq(#f.notices, 1, "restore failure must be observable")
      t.assert_eq(f.notices[1].level, vim.log.levels.WARN)
      t.assert_true(f.notices[1].message:find("dap.breakpoints.set", 1, true) ~= nil)
      f.failures[5] = nil
      bp.restore_for_buf(f.buf)
      t.assert_eq(f.calls[5], 2, "failed pending entry must be attempted again")
      t.assert_eq(#f.raw[f.buf], 1)
      bp.restore_for_buf(f.buf)
      t.assert_eq(f.calls[5], 2, "successful entry must retire")
    end)
  end)

  t.it("C09: save preserves failed entries and retry does not duplicate partial successes", function()
    with_fixture(function(f)
      return {
        [f.source] = { { line = 5 }, { line = 6, condition = "i==3", hit_condition = "2", log_message = "i={i}" } },
        [f.root .. "/Unopened.cpp"] = { { line = 70 } },
      }
    end, function(f)
      f.failures[6] = true
      bp.load()
      t.assert_eq(f.calls[5], 1)
      t.assert_eq(f.calls[6], 1)
      t.assert_true(bp.save())
      local records = f.read()
      t.assert_eq(#records[f.source], 2, "save must not mistake a failed restore for a user clear")
      t.assert_eq(records[f.source][2].condition, "i==3")
      t.assert_eq(records[f.source][2].hit_condition, "2")
      t.assert_eq(records[f.source][2].log_message, "i={i}")
      t.assert_eq(records[f.root .. "/Unopened.cpp"][1].line, 70)
      f.failures[6] = nil
      bp.restore_for_buf(f.buf)
      t.assert_eq(f.calls[5], 1, "successful partial entry must not be set twice")
      t.assert_eq(f.calls[6], 2, "save must keep the failed entry pending")
      t.assert_eq(#f.raw[f.buf], 2)
      t.assert_true(bp.save())
      bp.restore_for_buf(f.buf)
      t.assert_eq(f.calls[6], 2)
    end)
  end)

  t.it("explicit clear-all cancels failed restore entries", function()
    with_fixture(function(f) return { [f.source] = { { line = 5 } } } end, function(f)
      f.failures[5] = true
      bp.load()
      bp.clear_all()
      t.assert_true(bp.save())
      t.assert_nil(next(f.read()))
      f.failures[5] = nil
      bp.restore_for_buf(f.buf)
      t.assert_eq(f.calls[5], 1, "explicit clear must not retry a cancelled breakpoint")
    end)
  end)
end)
