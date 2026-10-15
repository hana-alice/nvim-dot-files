local t = require("tests.harness")
local root = t.bootstrap()

-- Replay the scan's original real Neovim events. The installed Snacks action
-- runs unchanged; the CodeDiff fixture supplies ownership, not window APIs.
local probes = {
  ["layout-newtab-choice.lua"] = [=[
local root = vim.fn.getcwd():gsub('\\', '/')
local run = (vim.env.NVIM_TEST_RUN_ROOT or root .. '/.tmp/review-gd/scan/layout-newtab-choice-data'):gsub('\\', '/')
vim.fn.mkdir(run, 'p')
local base = vim.fn.stdpath
vim.fn.stdpath = function(kind)
  if kind == 'state' or kind == 'cache' or kind == 'log' then return run .. '/' .. kind end
  return base(kind)
end
vim.env.NVIM_UE_LOG_DIR = run .. '/logs'
vim.env.NVIM_UE_PROBE_PATH = run .. '/probes.json'
vim.opt.rtp:prepend(root)
package.path = root .. '/lua/?.lua;' .. root .. '/lua/?/init.lua;' .. package.path
local api = vim.api
vim.fn.writefile({'local source_symbol = 1', 'return source_symbol'}, run .. '/source.lua')
vim.cmd.edit(vim.fn.fnameescape(run .. '/source.lua'))
local source, source_buf, source_tab = api.nvim_get_current_win(), api.nvim_get_current_buf(), api.nvim_get_current_tabpage()
local choice = api.nvim_create_buf(true, false)
api.nvim_buf_set_name(choice, run .. '/user-choice.lua')
api.nvim_buf_set_lines(choice, 0, -1, false, {'-- user new work selected in a real TabNewEntered callback'})
local layout = require('utils.layout')
layout.register(source, 'code')
layout.register_group('debug', {tab=source_tab, token={}, valid=function() return true end,
  focus=function() api.nvim_set_current_win(source); return source end})
local events, selected, continued = 0, nil, 0
api.nvim_create_autocmd('TabNewEntered', {once=true, callback=function()
  events = events + 1
  api.nvim_set_current_buf(choice)
  selected = api.nvim_get_current_win()
end})
local handled = require('utils.review_goto').definition(function() continued=continued+1 end)
assert(handled and events == 1 and continued == 0, 'cancel old semantic continuation after TabNewEntered choice')
assert(selected == api.nvim_get_current_win())
assert(api.nvim_win_get_buf(selected) == choice, 'new user buffer must remain displayed')
assert(api.nvim_win_get_buf(source) == source_buf and vim.bo[choice].modified)
print('CHOICE_PRESERVED callback_events=' .. events .. ' semantic_continuations=' .. continued
  .. ' chosen_buf=' .. choice .. ' displayed_buf=' .. api.nvim_win_get_buf(selected)
  .. ' original_source_unchanged=true chosen_dirty_buffer_visible=true')
vim.cmd('qa!')
]=],
  ["layout-split-choice.lua"] = [=[
local root=vim.fn.getcwd():gsub('\\','/')
local run=vim.env.NVIM_TEST_RUN_ROOT or root..'/.tmp/review-gd/scan/layout-split-choice-data'
vim.fn.mkdir(run,'p')
local stdpath=vim.fn.stdpath
vim.fn.stdpath=function(kind)
  if kind=='cache' or kind=='state' or kind=='log' then return run..'/'..kind end
  return stdpath(kind)
end
vim.opt.rtp:prepend(root)
package.path=root..'/lua/?.lua;'..root..'/lua/?/init.lua;'..package.path
local api=vim.api
local layout=require('utils.layout')
local source=api.nvim_get_current_win()
layout.register(source,'aux')
vim.cmd.vnew()
local selected=api.nvim_get_current_win()
layout.register(selected,'aux')
api.nvim_set_current_win(source)
local fired=false
api.nvim_create_autocmd('WinNew',{once=true,callback=function()
  fired=true
  layout.register(selected,'code')
  api.nvim_set_current_win(selected)
end})
local win,err=layout.focus({source_win=source,create=true,route_to_normal=false})
assert(fired and not win and api.nvim_get_current_win()==selected,err)
assert(layout.is_code(selected), 'new user role must remain code')
print('CHOICE_PRESERVED WinNew_selected='..selected..' returned='..tostring(win)..' final_focus='..api.nvim_get_current_win())
vim.cmd('qa!')
]=],
  ["lsp-snacks-cursor-repro.lua"] = [=[
local api = vim.api
local root = vim.fn.getcwd():gsub('\\', '/')
vim.opt.rtp:prepend(root)
vim.opt.rtp:prepend('C:/Users/lizeqiang/AppData/Local/nvim-data/lazy/snacks.nvim')
package.path = root .. '/lua/?.lua;' .. root .. '/lua/?/init.lua;' .. package.path
require('snacks')
local fixture = (vim.env.NVIM_TEST_RUN_ROOT or root .. '/.tmp/review-gd/scan/lsp-snacks-fixture'):gsub('\\', '/')
vim.fn.mkdir(fixture, 'p')
vim.fn.writefile({ 'int target();', 'void call() { target(); }' }, fixture .. '/Main.usf')
local review_tab = api.nvim_get_current_tabpage()
local review = api.nvim_get_current_buf()
api.nvim_buf_set_name(review, 'codediff:///' .. fixture .. '///a1b2c3/Main.usf')
api.nvim_buf_set_lines(review, 0, -1, false, { 'int target();', 'void call() { target(); }', 'third', 'fourth' })
vim.bo[review].buftype = 'nowrite'
vim.bo[review].modified = false
local original = api.nvim_get_current_win()
vim.cmd('vsplit')
local modified = api.nvim_get_current_win()
local session = { original_win = original, modified_win = modified,
  original_bufnr = review, modified_bufnr = review, git_root = fixture }
package.loaded['codediff.core.virtual_file'] = { parse_url = function() return fixture, 'a1b2c3', 'Main.usf' end }
package.loaded['codediff.ui.lifecycle'] = {
  get_windows = function(tab) if tab == review_tab then return original, modified end end,
  get_session = function(tab) if tab == review_tab then return session end end,
}
local replacement = api.nvim_create_buf(true, false)
api.nvim_buf_set_name(replacement, fixture .. '/chosen-by-user.usf')
api.nvim_buf_set_lines(replacement, 0, -1, false, { 'line 1', 'line 2', 'line 3', 'line 4' })
vim.bo[replacement].modified = false
local mode = vim.env.SCAN_SNACKS_MODE or 'replace'
local entered, chosen_cursor, chosen_win = 0, { 4, 3 }
api.nvim_create_autocmd('BufEnter', { callback = function(args)
  if api.nvim_get_current_tabpage() ~= review_tab
    and api.nvim_buf_get_name(args.buf):gsub('\\', '/') == fixture .. '/Main.usf' then
    entered = entered + 1
    if mode == 'return-review' then
      api.nvim_set_current_win(original)
      chosen_win = original
    else
      chosen_win = api.nvim_get_current_win()
      api.nvim_win_set_buf(chosen_win, replacement)
    end
    api.nvim_win_set_cursor(chosen_win, chosen_cursor)
  end
end })
api.nvim_set_current_win(original)
api.nvim_win_set_cursor(original, { 4, 3 })
local item = { file = fixture .. '/Main.usf', pos = { 2, 4 } }
local picker = { main = original,
  opts = { jump = { close = false, reuse_win = false, jumplist = false, tagstack = false, match = false } },
  selected = function() return { item } end,
  filter = function() return { current_win = original } end,
}
require('utils.layout').confirm(picker, item, { cmd = 'edit' })
local actual = api.nvim_win_get_cursor(chosen_win)
local result = { mode = mode, entered = entered, expected = chosen_cursor, actual = actual,
  replacement_is_current = api.nvim_win_get_buf(chosen_win) == replacement,
  current_tab_is_review = api.nvim_get_current_tabpage() == review_tab,
  source_buf_preserved = api.nvim_win_get_buf(original) == review }
vim.fn.writefile({ vim.json.encode(result) }, fixture .. '/snacks-' .. mode .. '-result.json')
print(vim.json.encode(result))
assert(entered == 1 and result.source_buf_preserved)
assert(vim.deep_equal(actual, chosen_cursor), 'native jump may not reposition callback-selected document')
assert(mode == 'return-review' and result.current_tab_is_review or mode == 'replace' and result.replacement_is_current)
print('CHOICE_PRESERVED native_jump ' .. mode)
vim.cmd('qa!')
]=],
}

local cases = {
  { name = "TabNewEntered document replacement cancels semantic continuation", script = "layout-newtab-choice.lua" },
  { name = "WinNew existing-window choice is retained", script = "layout-split-choice.lua" },
  { name = "native picker preserves same-window replacement cursor", script = "lsp-snacks-cursor-repro.lua", mode = "replace" },
  { name = "native picker preserves original-review cursor after callback return", script = "lsp-snacks-cursor-repro.lua", mode = "return-review" },
}

t.describe("layout_handoff scan regressions", function()
  for index, case in ipairs(cases) do
    t.it(case.name, function()
      local run = root .. "/.tmp/review-gd/n1-layout-regressions/" .. index
      vim.fn.mkdir(run, "p")
      local script = run .. "/probe.lua"
      vim.fn.writefile(vim.split(probes[case.script], "\n", { plain = true }), script)
      local result = vim.system({ vim.v.progpath, "-u", "NONE", "-i", "NONE", "--headless", "-l",
        script }, {
        text = true,
        env = {
          NVIM_TEST_RUN_ROOT = run,
          NVIM_LOG_FILE = run .. "/startup.log",
          XDG_STATE_HOME = run .. "/state",
          XDG_CACHE_HOME = run .. "/cache",
          NVIM_UE_LOG_DIR = run .. "/ue-logs",
          NVIM_UE_PROBE_PATH = run .. "/probes.json",
          SCAN_SNACKS_MODE = case.mode or "",
        },
      }):wait(10000)
      local output = (result.stdout or "") .. (result.stderr or "")
      vim.fn.writefile(vim.split(output, "\n", { plain = true }), run .. "/output.log")
      t.assert_eq(result.code, 0, output)
      t.assert_contains(output, "CHOICE_PRESERVED")
    end)
  end
end)

local api = vim.api
local observed = { "WinEnter", "TabEnter", "BufEnter", "BufReadPost", "WinNew", "TabNewEntered" }
local function observer_count()
  local count = 0
  for _, event in ipairs(observed) do count = count + #api.nvim_get_autocmds({ event = event }) end
  return count
end

local function isolated(fn)
  local old_layout, old_helper = package.loaded["utils.layout"], package.loaded["utils.layout_handoff"]
  local old_owner = package.loaded["codediff.ui.lifecycle"]
  local start, existing = api.nvim_get_current_tabpage(), {}
  for _, tab in ipairs(api.nvim_list_tabpages()) do existing[tab] = true end
  vim.cmd("tabnew")
  package.loaded["codediff.ui.lifecycle"] = nil
  package.loaded["utils.layout"], package.loaded["utils.layout_handoff"] = nil, nil
  local ok, err = xpcall(function()
    local layout, helper = require("utils.layout"), require("utils.layout_handoff")
    local source = api.nvim_get_current_win()
    layout.register(source, "code")
    fn(layout, helper, source)
  end, debug.traceback)
  for _, tab in ipairs(api.nvim_list_tabpages()) do
    if not existing[tab] then api.nvim_set_current_tabpage(tab); vim.cmd("tabclose!") end
  end
  api.nvim_set_current_tabpage(start)
  package.loaded["utils.layout"], package.loaded["utils.layout_handoff"] = old_layout, old_helper
  package.loaded["codediff.ui.lifecycle"] = old_owner
  if not ok then error(err, 0) end
end

t.describe("layout_handoff operation lifetime", function()
  t.it("error removes every operation observer", function()
    isolated(function(_, helper, source)
      local snapshot, before = helper.capture(source), observer_count()
      local ok, _, err = helper.handoff(snapshot, nil, function() error("operation failure") end)
      t.assert_false(ok)
      t.assert_contains(err, "operation failure")
      t.assert_eq(observer_count(), before)
    end)
  end)

  t.it("same-window buffer choice cancels and removes observers", function()
    isolated(function(_, helper, source)
      local snapshot = helper.capture(source)
      local target, choice = api.nvim_create_buf(true, false), api.nvim_create_buf(true, false)
      api.nvim_buf_set_lines(choice, 0, -1, false, { "one", "two", "three", "four" })
      vim.bo[choice].modified = false
      local callback = api.nvim_create_autocmd("BufEnter", { callback = function(ev)
        if ev.buf == target then
          api.nvim_win_set_buf(source, choice)
          api.nvim_win_set_cursor(source, { 4, 2 })
        end
      end })
      local before = observer_count()
      local ok = helper.handoff(snapshot, { win = source, tab = snapshot.tab, buf = target, code = true },
        function() api.nvim_win_set_buf(source, target) end)
      t.assert_false(ok)
      t.assert_eq(api.nvim_win_get_buf(source), choice)
      t.assert_true(vim.deep_equal(api.nvim_win_get_cursor(source), { 4, 2 }))
      t.assert_eq(observer_count(), before)
      api.nvim_del_autocmd(callback)
    end)
  end)

  t.it("own buffer transition succeeds with observers removed", function()
    isolated(function(_, helper, source)
      local snapshot, before = helper.capture(source), observer_count()
      local target = api.nvim_create_buf(true, false)
      local ok = helper.handoff(snapshot, { win = source, tab = snapshot.tab, buf = target, code = true },
        function() api.nvim_win_set_buf(source, target) end)
      t.assert_true(ok)
      t.assert_eq(api.nvim_win_get_buf(source), target)
      t.assert_eq(observer_count(), before)
    end)
  end)

  t.it("owner replacement invalidates source before next action", function()
    isolated(function(layout, helper, source)
      local sessions, tab = {}, api.nvim_get_current_tabpage()
      package.loaded["codediff.ui.lifecycle"] = { get_session = function(id) return sessions[id] end }
      sessions[tab] = { original_win = source, modified_win = source }
      layout.sync_review(tab)
      local snapshot = helper.capture(source)
      sessions[tab] = { original_win = source, modified_win = source }
      local called, before = false, observer_count()
      local ok = helper.handoff(snapshot, nil, function() called = true end)
      t.assert_false(ok)
      t.assert_false(called)
      t.assert_eq(observer_count(), before)
    end)
  end)

  t.it("destination role replacement cancels before positional writes", function()
    isolated(function(layout, helper, source)
      local snapshot, called = helper.capture(source), false
      local destination = { win = source, tab = snapshot.tab, buf = snapshot.buf, code = true }
      layout.register(source, "aux")
      local ok = helper.revalidate(snapshot, destination)
      t.assert_false(ok)
      local valid = helper.handoff(snapshot, destination, function() called = true end)
      t.assert_false(valid)
      -- The next stage must not run when its expected role is already lost.
      t.assert_false(called)
    end)
  end)

  for _, change in ipairs({ "role", "registry owner" }) do
    t.it("source " .. change .. " replacement cancels before a separate destination action", function()
      isolated(function(layout, helper, source)
        local owner = {}
        layout.register(source, "code", { owner = owner })
        local snapshot = helper.capture(source)
        vim.cmd("vnew")
        local target = api.nvim_get_current_win()
        layout.register(target, "code")
        local destination = { win = target, tab = api.nvim_get_current_tabpage(),
          buf = api.nvim_win_get_buf(target), code = true }
        if change == "role" then
          layout.register(source, "aux", { owner = owner })
        else
          layout.register(source, "code", { owner = {} })
        end
        local called, before = false, observer_count()
        local ok = helper.handoff(snapshot, destination, function() called = true end)
        t.assert_false(called, "stale source ownership must reject the next stage before its action")
        t.assert_false(ok)
        t.assert_eq(observer_count(), before)
        t.assert_eq(api.nvim_get_current_win(), target)
      end)
    end)
  end

  t.it("WinNew auxiliary registration cancels the created code split", function()
    isolated(function(layout, helper, source)
      local snapshot, chosen = helper.capture(source), nil
      local target = api.nvim_create_buf(true, false)
      local callback = api.nvim_create_autocmd("WinNew", { callback = function()
        chosen = api.nvim_get_current_win()
        layout.register(chosen, "aux")
      end })
      local before = observer_count()
      local win = helper.open_window(snapshot, target, { split = "right", win = source })
      t.assert_nil(win, "callback-owned aux window may not become the old code destination")
      t.assert_true(chosen and api.nvim_win_is_valid(chosen))
      t.assert_false(layout.is_code(chosen, snapshot.tab))
      t.assert_eq(api.nvim_win_get_buf(source), snapshot.buf)
      t.assert_eq(observer_count(), before)
      api.nvim_del_autocmd(callback)
    end)
  end)

  t.it("TabNewEntered registry owner cancels before blank-buffer assignment", function()
    isolated(function(layout, helper, source)
      local snapshot, chosen = helper.capture(source), nil
      local target, owner = api.nvim_create_buf(true, false), {}
      local callback = api.nvim_create_autocmd("TabNewEntered", { callback = function()
        chosen = api.nvim_get_current_win()
        layout.register(chosen, "code", { owner = owner })
      end })
      local before = observer_count()
      local win = helper.new_tab(snapshot, target)
      t.assert_nil(win, "callback-owned normal window may not receive the old blank buffer")
      t.assert_true(chosen and api.nvim_win_is_valid(chosen))
      t.assert_eq(api.nvim_get_current_win(), chosen)
      t.assert_eq(api.nvim_win_get_buf(chosen), snapshot.buf)
      t.assert_eq(api.nvim_win_get_buf(source), snapshot.buf)
      t.assert_eq(observer_count(), before)
      api.nvim_del_autocmd(callback)
    end)
  end)
end)
