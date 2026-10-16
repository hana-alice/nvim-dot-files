local t = require("tests.harness")
t.bootstrap()
local ui = require("utils.search_ui")

local function fast_event(callback)
  local timer = assert(vim.uv.new_timer())
  local done, failure = false, nil
  timer:start(0, 0, function()
    local ok, err = pcall(callback)
    if not ok then
      failure = err
    end
    timer:stop()
    timer:close()
    vim.schedule(function()
      done = true
    end)
  end)
  t.assert_true(vim.wait(2000, function()
    return done
  end, 5))
  if failure then
    error(failure)
  end
end

local function picker()
  local updates = {}
  local value = { opts = {}, title = "Search" }
  value.update_titles = function()
    t.assert_false(vim.in_fast_event(), "window updates must run on the main loop")
    t.assert_true(vim.api.nvim_win_is_valid(vim.api.nvim_get_current_win()))
    updates[#updates + 1] = value.title
  end
  return value, updates
end

t.describe("Search status under native fast events", function()
  t.it("defers real timer callbacks before updating picker windows", function()
    local value, updates = picker()
    local token = ui.begin(value)
    fast_event(function()
      t.assert_true(vim.in_fast_event())
      ui.status(value, { state = "complete", delivered = 3 }, token)
    end)
    t.assert_eq(#updates, 1)
    t.assert_contains(value.title, "3 行结果")
  end)

  t.it("rechecks generation when queued updates reach the main loop", function()
    local value, updates = picker()
    local old = ui.begin(value)
    fast_event(function()
      ui.status(value, { state = "error" }, old)
      local current = ui.begin(value)
      ui.status(value, { state = "complete", delivered = 5 }, current)
    end)
    t.assert_eq(#updates, 1)
    t.assert_eq(value.opts.ue_search_status.delivered, 5)
    t.assert_contains(value.title, "5 行结果")
  end)

  t.it("freezes metadata before a deferred callback can observe mutation", function()
    local value = picker()
    local token = ui.begin(value)
    fast_event(function()
      local metadata = { state = "complete", delivered = 5 }
      ui.status(value, metadata, token)
      metadata.delivered = 999
    end)
    t.assert_eq(value.opts.ue_search_status.delivered, 5)
  end)
end)
