local t = require("tests.harness")
t.bootstrap()

t.describe("ide_continuity: restart cancellation", function()
  t.it("cancelled unsaved confirmation creates no replacement process", function()
    local restart = require("utils.restart")
    local detect, spawn, select = restart.detect, vim.uv.spawn, vim.ui.select
    local spawns = 0
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].buftype = ""
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "unsaved work" })
    vim.bo[buf].modified = true
    restart.detect = function()
      return { cmd = vim.v.progpath, args = {}, cwd = vim.fn.getcwd(), client = "test", reason = "test" }
    end
    vim.uv.spawn = function()
      spawns = spawns + 1
      return nil, "test blocks launch"
    end
    vim.ui.select = function(_, _, done)
      done(nil)
    end
    local ok, err = pcall(restart.restart, {})
    restart.detect, vim.uv.spawn, vim.ui.select = detect, spawn, select
    t.assert_true(ok, err)
    t.assert_eq(spawns, 0)
    t.assert_eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false)[1], "unsaved work")
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
  t.it("confirmation invalidated by another edit cannot save or launch", function()
    local restart = require("utils.restart")
    local detect, spawn, select = restart.detect, vim.uv.spawn, vim.ui.select
    local spawns = 0
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].buftype = ""
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "old" })
    vim.bo[buf].modified = true
    restart.detect = function()
      return { cmd = vim.v.progpath, args = {}, cwd = vim.fn.getcwd(), client = "test", reason = "test" }
    end
    vim.uv.spawn = function()
      spawns = spawns + 1
      return nil, "test blocks launch"
    end
    vim.ui.select = function(items, _, done)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "new work" })
      done(items[1])
    end
    local ok, err = pcall(restart.restart, {})
    restart.detect, vim.uv.spawn, vim.ui.select = detect, spawn, select
    t.assert_true(ok, err)
    t.assert_eq(spawns, 0)
    t.assert_true(vim.bo[buf].modified)
    t.assert_eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false)[1], "new work")
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end)
