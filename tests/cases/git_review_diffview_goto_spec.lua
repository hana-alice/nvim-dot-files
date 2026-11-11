local t = require("tests.harness")
local cfg = t.bootstrap()
local lazy = vim.fn.stdpath("data") .. "/lazy/"
for _, name in ipairs({ "lazy.nvim", "LazyVim", "diffview.nvim", "plenary.nvim", "snacks.nvim" }) do
  if vim.fn.isdirectory(lazy .. name) == 0 then
    t.skip("Diffview goto keeps diff panes", "Missing installed plugin: " .. name, { native = true })
    return
  end
end

-- Scratch note: gd inside a Diffview pane replaced that pane's buffer and broke
-- the pair. Diffview tabs are now review owners, so a jump routes to normal.
t.describe("Diffview goto routing", function()
  t.it("jumps from either diff pane into the editing tab and keeps both panes", function()
    require("tests.helpers.git_review_fixture").with_repo(function(f)
      f.baseline("one\ntwo\nthree\n")
      f.write("one changed\ntwo\nthree\n")
      local target = assert(io.open(f.root .. "/target.txt", "wb"))
      target:write("target\n")
      target:close()
      local scratch = vim.fn.tempname()
      vim.fn.mkdir(scratch, "p")
      local script = scratch .. "/diffview_goto.lua"
      local code = string.format([[
local root = %q
local ok, err = xpcall(function()
  vim.api.nvim_exec_autocmds("User", { pattern = "VeryLazy", modeline = false })
  require("lazy").load({ plugins = { "diffview.nvim" } })
  vim.notify = function() end
  vim.cmd.edit(vim.fn.fnameescape(root .. "/review.txt"))
  local editing_tab = vim.api.nvim_get_current_tabpage()
  local lib = require("diffview.lib")
  local map = vim.fn.maparg(" gv", "n", false, true)
  assert(next(map), "missing <leader>gv")
  if map.callback then map.callback() else vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(map.rhs, true, false, true), "nx", false) end
  assert(vim.wait(20000, function()
    local v = lib.get_current_view()
    return v and v.cur_entry and v.cur_layout and v.cur_layout:get_main_win():is_file_open()
  end, 20), "Diffview did not open")
  local view = lib.get_current_view()
  local layout = require("utils.layout")
  assert(layout.group_kind(view.tabpage) == "review", "Diffview tab is not a review owner")
  local panes = {}
  for _, side in ipairs({ "a", "b" }) do
    local win = view.cur_layout[side].id
    panes[#panes + 1] = { win = win, buf = vim.api.nvim_win_get_buf(win) }
  end
  local location = { uri = vim.uri_from_fname(root .. "/target.txt"), range = { start = { line = 0, character = 0 } } }
  for _, pane in ipairs(panes) do
    vim.api.nvim_set_current_tabpage(view.tabpage)
    vim.api.nvim_set_current_win(pane.win)
    assert(require("utils.ue_goto.jumper").jump(location), "jump failed")
    assert(vim.api.nvim_get_current_tabpage() == editing_tab, "jump stayed in the Diffview tab")
    assert(vim.fs.basename(vim.api.nvim_buf_get_name(0)) == "target.txt", "jump target not opened")
    for _, other in ipairs(panes) do
      assert(vim.api.nvim_win_is_valid(other.win), "diff pane closed")
      assert(vim.api.nvim_win_get_buf(other.win) == other.buf, "diff pane buffer replaced")
      assert(vim.wo[other.win].diff, "diff pane lost diff mode")
    end
  end
  vim.api.nvim_set_current_tabpage(view.tabpage)
  vim.cmd("DiffviewClose")
  assert(vim.wait(5000, function() return not vim.api.nvim_tabpage_is_valid(view.tabpage) end, 20))
  assert(layout.group_kind(editing_tab) == "normal", "closed Diffview still owns routing")
  print("DIFFVIEW_GOTO_OK")
end, debug.traceback)
if not ok then io.stderr:write(tostring(err) .. "\n"); vim.cmd("cquit 1") else vim.cmd("qa!") end
]], f.root)
      vim.fn.writefile(vim.split(code, "\n", { plain = true }), script)
      local result = vim.system({ vim.v.progpath, "--headless", "-u", cfg .. "/init.lua", "-i", "NONE", "-n",
        "-c", "lua dofile(" .. string.format("%q", script) .. ")" }, {
        text = true, cwd = f.root, timeout = 60000,
        env = vim.tbl_extend("force", vim.fn.environ(), {
          NVIM_CORE_HEALTH_NO_MUTATE = "1", XDG_STATE_HOME = scratch .. "/state", XDG_CACHE_HOME = scratch .. "/cache",
          NVIM_UE_LOG_DIR = scratch .. "/logs", NVIM_UE_PROBE_PATH = scratch .. "/probes.json",
        }),
      }):wait()
      vim.fn.delete(scratch, "rf")
      t.assert_eq(result.code, 0, tostring(result.stderr))
      t.assert_contains((result.stdout or "") .. (result.stderr or ""), "DIFFVIEW_GOTO_OK")
      t.assert_eq(f.read(), "one changed\ntwo\nthree\n")
    end)
  end)
end)
