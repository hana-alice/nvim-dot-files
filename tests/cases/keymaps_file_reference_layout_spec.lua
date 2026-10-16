local t = require("tests.harness")
local cfg = t.bootstrap()
local api = vim.api

local function position_mouse(win)
  vim.cmd.redraw()
  local position = vim.fn.screenpos(win, 1, 1)
  api.nvim_input_mouse("left", "press", "", 0, position.row - 1, position.col - 1)
  api.nvim_input_mouse("left", "release", "", 0, position.row - 1, position.col - 1)
  api.nvim_feedkeys("", "x", false)
  t.assert_eq(vim.fn.getmousepos().winid, win)
end

local function fixture(review, fn)
  local original_tabs = {}
  for _, tab in ipairs(api.nvim_list_tabpages()) do original_tabs[tab] = true end
  local saved = package.loaded["codediff.ui.lifecycle"]
  local tab = api.nvim_get_current_tabpage()
  local old_buffers = {}
  for _, buf in ipairs(api.nvim_list_bufs()) do old_buffers[buf] = true end
  vim.cmd.tabnew()
  local own_tab = api.nvim_get_current_tabpage()
  local session
  package.loaded["codediff.ui.lifecycle"] = { get_session = function(id)
    return id == own_tab and session or nil
  end }
  local root = vim.env.NVIM_TEST_RUN_ROOT .. "/file-reference-" .. vim.uv.hrtime()
  vim.fn.mkdir(root, "p")
  local target, source_path = root .. "/target.h", root .. "/source.txt"
  vim.fn.writefile({ "target", "second" }, target)
  vim.fn.writefile({ "target", "missing.h" }, source_path)
  vim.cmd.edit(vim.fn.fnameescape(source_path))
  vim.bo.suffixesadd, vim.bo.path = ".h", "."
  local source, source_buf = api.nvim_get_current_win(), api.nvim_get_current_buf()
  if review then
    vim.cmd.vsplit()
    local other = api.nvim_get_current_win()
    local buf = api.nvim_create_buf(false, true)
    api.nvim_win_set_buf(other, buf)
    session = { original_win = source, modified_win = other }
    vim.wo[source].diff, vim.wo[other].diff = true, true
    api.nvim_set_current_win(source)
  end
  local ok, err = xpcall(function() fn(source, source_buf, target, session) end, debug.traceback)
  package.loaded["codediff.ui.lifecycle"] = saved
  for _, created in ipairs(api.nvim_list_tabpages()) do
    if not original_tabs[created] then api.nvim_set_current_tabpage(created); vim.cmd("tabclose!") end
  end
  if api.nvim_tabpage_is_valid(tab) then api.nvim_set_current_tabpage(tab) end
  for _, buf in ipairs(api.nvim_list_bufs()) do
    if not old_buffers[buf] then vim.bo[buf].modified = false end
  end
  if not ok then error(err) end
end

t.describe("keymaps layout file reference", function()
  t.it("debug gf switches to normal while retaining the debug source window", function()
    fixture(false, function(source, source_buf, target)
      local layout = require("utils.layout")
      local tab = api.nvim_win_get_tabpage(source)
      local token = {}
      layout.register_group("debug", { tab = tab, token = token, main = source })
      layout.register(source, "code", { owner = "debug" })
      t.assert_true(require("utils.file_reference").open())
      t.assert_true(api.nvim_get_current_tabpage() ~= tab)
      t.assert_eq(vim.fs.normalize(api.nvim_buf_get_name(0)), vim.fs.normalize(target))
      t.assert_eq(api.nvim_win_get_buf(source), source_buf)
      t.assert_eq(#api.nvim_tabpage_list_wins(tab), 1)
    end)
  end)
  t.it("ordinary gf keeps native suffixesadd and source window", function()
    fixture(false, function(source, _, target)
      t.assert_true(require("utils.file_reference").open())
      t.assert_eq(api.nvim_get_current_win(), source)
      t.assert_eq(vim.fs.normalize(api.nvim_buf_get_name(0)), vim.fs.normalize(target))
    end)
  end)

  t.it("review gf uses code, preserves dirty hidden targets and native Ctrl-O", function()
    fixture(true, function(source, source_buf, target, session)
      local target_buf = vim.fn.bufadd(target)
      vim.fn.bufload(target_buf)
      api.nvim_buf_set_lines(target_buf, 0, -1, false, { "unsaved target", "second" })
      vim.bo[target_buf].modified = true
      local paired = api.nvim_win_get_buf(session.modified_win)
      t.assert_true(require("utils.file_reference").open())
      local code = api.nvim_get_current_win()
      t.assert_true(code ~= source and code ~= session.modified_win)
      t.assert_true(api.nvim_win_get_tabpage(code) ~= api.nvim_win_get_tabpage(source))
      t.assert_eq(#api.nvim_tabpage_list_wins(api.nvim_win_get_tabpage(source)), 2)
      t.assert_eq(api.nvim_get_current_buf(), target_buf)
      t.assert_eq(api.nvim_buf_get_lines(target_buf, 0, 1, false)[1], "unsaved target")
      t.assert_true(vim.bo[target_buf].modified)
      t.assert_eq(api.nvim_win_get_buf(source), source_buf)
      t.assert_eq(api.nvim_win_get_buf(session.modified_win), paired)
      local count = #api.nvim_tabpage_list_wins(0)
      vim.cmd.normal({ args = { api.nvim_replace_termcodes("<C-O>", true, false, true) }, bang = true })
      t.assert_eq(api.nvim_get_current_buf(), source_buf)
      api.nvim_set_current_win(source)
      t.assert_true(require("utils.file_reference").open())
      t.assert_eq(api.nvim_get_current_win(), code)
      t.assert_eq(#api.nvim_tabpage_list_wins(0), count)
    end)
  end)

  t.it("failed review gf restores an existing code document and view", function()
    fixture(true, function(source, source_buf)
      local code = assert(require("utils.layout").resolve({ source_win = source }))
      local old = api.nvim_create_buf(true, false)
      api.nvim_buf_set_lines(old, 0, -1, false, { "kept", "dirty", "document" })
      api.nvim_win_set_buf(code, old)
      api.nvim_win_set_cursor(code, { 2, 1 })
      api.nvim_set_current_win(source)
      api.nvim_win_set_cursor(source, { 2, 0 })
      t.assert_false(require("utils.file_reference").open())
      t.assert_eq(api.nvim_win_get_buf(code), old)
      t.assert_true(vim.deep_equal(api.nvim_win_get_cursor(code), { 2, 1 }))
      t.assert_eq(api.nvim_get_current_win(), source)
      t.assert_eq(api.nvim_win_get_buf(source), source_buf)
    end)
  end)

  t.it("review gf uses the source window cwd without changing the code cwd", function()
    fixture(true, function(source, _, target)
      local code = assert(require("utils.layout").resolve({ source_win = source }))
      api.nvim_set_current_win(source)
      api.nvim_win_call(source, function()
        vim.cmd.lcd(vim.fn.fnameescape(vim.fs.dirname(target)))
        vim.bo.path = ""
      end)
      local number, tab = api.nvim_win_get_number(code), api.nvim_tabpage_get_number(api.nvim_win_get_tabpage(code))
      local previous = { vim.fn.getcwd(number, tab), vim.fn.haslocaldir(number, tab) }
      t.assert_true(require("utils.file_reference").open())
      local after = { vim.fn.getcwd(number, tab), vim.fn.haslocaldir(number, tab) }
      t.assert_eq(vim.fs.normalize(previous[1]), vim.fs.normalize(after[1]))
      t.assert_eq(previous[2], after[2])
      t.assert_eq(vim.fs.normalize(api.nvim_buf_get_name(0)), vim.fs.normalize(target))
    end)
  end)

  t.it("review layout switch callback changing source cancels before file open", function()
    fixture(true, function(source, source_buf, target)
      local group = api.nvim_create_augroup("test_file_reference_stale", { clear = true })
      api.nvim_create_autocmd("TabEnter", { group = group, once = true, callback = function()
        api.nvim_buf_set_lines(source_buf, 0, 1, false, { "new owner text" })
      end })
      local ok, err = pcall(require("utils.file_reference").open)
      api.nvim_del_augroup_by_id(group)
      t.assert_true(ok, tostring(err))
      t.assert_eq(api.nvim_buf_get_lines(source_buf, 0, 1, false)[1], "new owner text")
      for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
        t.assert_false(vim.fs.normalize(api.nvim_buf_get_name(api.nvim_win_get_buf(win))) == vim.fs.normalize(target))
      end
    end)
  end)

  t.it("the configured Ctrl-mouse callback uses code for a file reference", function()
    dofile(cfg .. "/lua/config/keymaps.lua")
    fixture(true, function(source, source_buf, target, session)
      api.nvim_buf_set_lines(source_buf, 0, 1, false, { "target.h" })
      local mapping = vim.fn.maparg("<C-LeftMouse>", "n", false, true)
      position_mouse(source)
      local old = package.loaded["utils.lsp_fallback"]
      local definitions = 0
      package.loaded["utils.lsp_fallback"] = { definition = function() definitions = definitions + 1 end }
      local ok, err = pcall(mapping.callback)
      package.loaded["utils.lsp_fallback"] = old
      t.assert_true(ok, tostring(err))
      t.assert_eq(definitions, 0)
      t.assert_true(api.nvim_get_current_win() ~= source and api.nvim_get_current_win() ~= session.modified_win)
      t.assert_eq(vim.fs.normalize(api.nvim_buf_get_name(0)), vim.fs.normalize(target))
      t.assert_eq(api.nvim_win_get_buf(source), source_buf)
    end)
  end)

  t.it("Ctrl-mouse consumes a stale layout transition without requesting definition on its replacement", function()
    dofile(cfg .. "/lua/config/keymaps.lua")
    fixture(true, function(source, source_buf)
      api.nvim_buf_set_lines(source_buf, 0, 1, false, { "target.h" })
      local mapping = vim.fn.maparg("<C-LeftMouse>", "n", false, true)
      position_mouse(source)
      local old = package.loaded["utils.lsp_fallback"]
      local definitions = 0
      package.loaded["utils.lsp_fallback"] = { definition = function() definitions = definitions + 1 end }
      local id = api.nvim_create_autocmd("TabEnter", { once = true, callback = function()
        api.nvim_buf_set_lines(source_buf, 0, 1, false, { "new owner text" })
      end })
      local ok, err = pcall(mapping.callback)
      pcall(api.nvim_del_autocmd, id)
      package.loaded["utils.lsp_fallback"] = old
      t.assert_true(ok, tostring(err))
      t.assert_eq(definitions, 0)
      t.assert_eq(api.nvim_buf_get_lines(source_buf, 0, 1, false)[1], "new owner text")
    end)
  end)

  t.it("native gf load callback keeps a newly selected foreign tab", function()
    fixture(true, function(source, source_buf, target)
      vim.cmd.tabnew()
      local foreign, foreign_tab = api.nvim_get_current_win(), api.nvim_get_current_tabpage()
      api.nvim_set_current_win(source)
      local group = api.nvim_create_augroup("test_file_reference_tab", { clear = true })
      local fired = false
      api.nvim_create_autocmd("BufReadPost", { group = group, once = true, pattern = "*target.h", callback = function()
        fired = true
        api.nvim_set_current_win(foreign)
      end })
      local ok, err = pcall(require("utils.file_reference").open)
      api.nvim_del_augroup_by_id(group)
      local selected = api.nvim_get_current_win()
      api.nvim_set_current_tabpage(foreign_tab)
      vim.cmd("tabclose!")
      api.nvim_set_current_win(source)
      t.assert_true(ok, tostring(err))
      t.assert_true(fired, "target BufReadPost did not run")
      t.assert_eq(selected, foreign)
      t.assert_eq(api.nvim_win_get_buf(source), source_buf)
    end)
  end)
end)
