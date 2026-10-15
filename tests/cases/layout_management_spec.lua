local t = require("tests.harness")
local root = t.bootstrap()
local api = vim.api

-- Fixtures supply only owner identity/callbacks; tabs, windows and buffers are real.
local function isolated(fn)
  local saved, owner = package.loaded["utils.layout"], package.loaded["codediff.ui.lifecycle"]
  local saved_bottom = package.loaded["utils.bottom_panel"]
  local sessions, tabs, buffers = {}, {}, {}
  local start = api.nvim_get_current_tabpage()
  for _, tab in ipairs(api.nvim_list_tabpages()) do tabs[tab] = true end
  for _, buf in ipairs(api.nvim_list_bufs()) do buffers[buf] = true end
  package.loaded["codediff.ui.lifecycle"] = { get_session = function(tab) return sessions[tab] end }
  package.loaded["utils.layout"] = nil
  package.loaded["utils.bottom_panel"] = nil
  vim.cmd("tabnew")
  vim.t.ue_layout_project = "layout-management-fixture"
  local ok, err = xpcall(function() fn(require("utils.layout"), api.nvim_get_current_tabpage(), sessions) end, debug.traceback)
  for _, buf in ipairs(api.nvim_list_bufs()) do
    if not buffers[buf] then vim.bo[buf].modified = false end
  end
  for _, tab in ipairs(api.nvim_list_tabpages()) do
    if not tabs[tab] then api.nvim_set_current_tabpage(tab); vim.cmd("tabclose!") end
  end
  if api.nvim_tabpage_is_valid(start) then api.nvim_set_current_tabpage(start) end
  package.loaded["utils.layout"], package.loaded["codediff.ui.lifecycle"] = saved, owner
  package.loaded["utils.bottom_panel"] = saved_bottom
  if not ok then error(err, 0) end
end

local function window(split, role, m)
  if split then vim.cmd("rightbelow vnew") end
  local win, buf = api.nvim_get_current_win(), api.nvim_create_buf(true, false)
  api.nvim_buf_set_lines(buf, 0, -1, false, { "retained content", "second line" })
  vim.bo[buf].modified = false
  api.nvim_win_set_buf(win, buf)
  if role then m.register(win, role) end
  return win, buf
end

local function review(m, sessions)
  vim.cmd("tabnew")
  local tab = api.nvim_get_current_tabpage()
  vim.t.ue_layout_project = "layout-management-fixture"
  local left, left_buf = window()
  local right, right_buf = window(true)
  local panel, panel_buf = window(true)
  vim.bo[panel_buf].buftype = "nofile"
  vim.bo[panel_buf].filetype = "codediff-explorer"
  local session = { original_win = left, modified_win = right, git_root = "fixture-repo",
    original_revision = "base", modified_revision = "topic",
    panel = { data = { pathspec = { "Source/**" }, base_revision = "base", target_revision = "topic" },
      view = { winid = panel, data = { current_file_path = "Source/Selected.cpp" } } } }
  sessions[tab] = session
  m.sync_review(tab, session)
  return tab, session, { left, right, panel }, { left_buf, right_buf, panel_buf }
end

local function debug_group(m)
  vim.cmd("tabnew")
  local tab, token = api.nvim_get_current_tabpage(), {}
  vim.t.ue_layout_project = "layout-management-fixture"
  local win = window(false, "code", m)
  local calls = { focus = 0, restore = 0 }
  local group = m.register_group("debug", { tab = tab, token = token, owner = "fixture-debug-ui",
    valid = function(g) return g.token == token, "debug token replaced" end,
    focus = function(g) t.assert_eq(g.token, token); calls.focus = calls.focus + 1; api.nvim_set_current_win(win); return win end,
    restore = function(g) t.assert_eq(g.token, token); calls.restore = calls.restore + 1; api.nvim_set_current_win(win); return win end })
  return tab, group, win, calls
end

t.describe("layout management ownership and real windows", function()
  t.it("pluggable debug owner opens UI only and discovery reuses the actual token", function()
    isolated(function(m, normal)
      local code, dirty = window(false, "code", m)
      api.nvim_buf_set_lines(dirty, 0, 1, false, { "source unsaved during UI open" })
      local tick, dap_before = api.nvim_buf_get_changedtick(dirty), package.loaded["dap"]
      local absent, reason = m.switch("debug")
      t.assert_nil(absent); t.assert_contains(reason, "owner")
      t.assert_eq(package.loaded["dap"], dap_before)
      local before = #api.nvim_list_tabpages()
      local calls = { open = 0, discover = 0, focus = 0, restore = 0, launch = 0, attach = 0, cancel = 0 }
      local token = {
        launch = function() calls.launch = calls.launch + 1 end,
        attach = function() calls.attach = calls.attach + 1 end,
        cancel = function() calls.cancel = calls.cancel + 1 end,
      }
      local tab, win, group
      local alive = true
      local function register()
        group = m.register_group("debug", { tab = tab, token = token, owner = "pluggable-debug-fixture",
          valid = function(g) return alive and g.token == token, "fixture debug owner token expired" end,
          focus = function(g)
            t.assert_eq(g.token, token); calls.focus = calls.focus + 1; api.nvim_set_current_win(win); return win
          end,
          restore = function(g)
            t.assert_eq(g.token, token); calls.restore = calls.restore + 1; api.nvim_set_current_win(win); return win
          end })
        return group
      end
      m.register_owner("debug", {
        open = function(opts)
          calls.open = calls.open + 1
          t.assert_eq(opts.project, "layout-management-fixture")
          vim.cmd("tabnew")
          tab, win = api.nvim_get_current_tabpage(), api.nvim_get_current_win()
          vim.t.ue_layout_project = opts.project
          m.register(win, "code", { owner = "pluggable-debug-fixture" })
          return register()
        end,
        discover = function()
          calls.discover = calls.discover + 1
          if tab then register() end
        end,
      })
      t.assert_eq(m.switch("debug"), win)
      local id = group.id
      t.assert_eq(calls.open, 1); t.assert_eq(calls.restore, 1)
      t.assert_eq(#api.nvim_list_tabpages(), before + 1)
      for _ = 1, 3 do
        t.assert_eq(m.switch("normal"), code)
        t.assert_eq(api.nvim_get_current_tabpage(), normal)
        t.assert_eq(m.switch("debug"), win)
        t.assert_eq(m.current_group().id, id)
        t.assert_eq(m.current_group().token, token)
      end
      t.assert_eq(calls.open, 1); t.assert_eq(calls.focus, 3)
      t.assert_true(calls.discover > 0)
      t.assert_eq(#api.nvim_list_tabpages(), before + 1)
      t.assert_eq(#api.nvim_tabpage_list_wins(tab), 1)
      t.assert_eq(api.nvim_buf_get_changedtick(dirty), tick)
      t.assert_true(vim.bo[dirty].modified)
      t.assert_eq(calls.launch, 0); t.assert_eq(calls.attach, 0); t.assert_eq(calls.cancel, 0)
      t.assert_eq(package.loaded["dap"], dap_before)
      alive = false
      local invalid, invalid_reason = m.activate_group(id, { restore = true })
      t.assert_nil(invalid); t.assert_eq(invalid_reason, "fixture debug owner token expired")
      t.assert_eq(calls.restore, 1)
    end)
  end)

  t.it("repeated normal review debug normal switches preserve windows and dirty text", function()
    isolated(function(m, normal, sessions)
      local dap_before = package.loaded["dap"]
      local code, dirty = window(false, "code", m)
      api.nvim_buf_set_lines(dirty, 0, 1, false, { "unsaved user edit" })
      local tick = api.nvim_buf_get_changedtick(dirty)
      m.current_group()
      local review_tab, session, wins, bufs = review(m, sessions)
      local debug_tab, group, debug_win, calls = debug_group(m)
      api.nvim_set_current_tabpage(normal)
      for _ = 1, 3 do
        t.assert_eq(m.switch("review"), session.modified_win)
        t.assert_eq(api.nvim_get_current_tabpage(), review_tab)
        t.assert_eq(m.switch("debug"), debug_win)
        t.assert_eq(api.nvim_get_current_tabpage(), debug_tab)
        t.assert_eq(m.restore_group(), debug_win)
        t.assert_eq(m.current_group().token, group.token)
        t.assert_eq(m.switch("normal"), code)
        t.assert_eq(api.nvim_get_current_tabpage(), normal)
      end
      t.assert_eq(calls.focus, 3); t.assert_eq(calls.restore, 3)
      t.assert_eq(api.nvim_buf_get_changedtick(dirty), tick)
      t.assert_true(vim.bo[dirty].modified)
      t.assert_eq(api.nvim_buf_get_lines(dirty, 0, 1, false)[1], "unsaved user edit")
      for i, win in ipairs(wins) do t.assert_eq(api.nvim_win_get_buf(win), bufs[i]) end
      t.assert_eq(#api.nvim_tabpage_list_wins(review_tab), 3)
      t.assert_eq(package.loaded["dap"], dap_before)
    end)
  end)

  t.it("restore adds closed code only, retains resized and newly opened dirty panes", function()
    isolated(function(m)
      local first, first_buf = window(false, "code", m)
      local second, dirty = window(true, "code", m)
      api.nvim_buf_set_lines(dirty, 0, 1, false, { "closed unsaved edit" })
      api.nvim_win_set_cursor(second, { 2, 0 })
      m.current_group()
      api.nvim_win_close(second, true)
      local extra, extra_buf = window(true, "code", m)
      api.nvim_buf_set_lines(extra_buf, 0, 1, false, { "new unsaved pane" })
      api.nvim_win_set_width(extra, 25)
      local width, dirty_tick, extra_tick = api.nvim_win_get_width(extra), api.nvim_buf_get_changedtick(dirty), api.nvim_buf_get_changedtick(extra_buf)
      t.assert_true(m.restore_group() ~= nil)
      t.assert_eq(api.nvim_win_get_buf(first), first_buf)
      t.assert_eq(api.nvim_win_get_buf(extra), extra_buf)
      t.assert_true(api.nvim_win_get_width(extra) > 0 and width > 0)
      t.assert_eq(api.nvim_buf_get_changedtick(dirty), dirty_tick)
      t.assert_eq(api.nvim_buf_get_changedtick(extra_buf), extra_tick)
      t.assert_true(vim.bo[dirty].modified and vim.bo[extra_buf].modified)
      local count = #api.nvim_tabpage_list_wins(0)
      t.assert_true(m.restore_group() ~= nil)
      t.assert_eq(#api.nvim_tabpage_list_wins(0), count)
      local found = 0
      for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
        if api.nvim_win_get_buf(win) == dirty then
          found = found + 1
          t.assert_eq(api.nvim_win_get_cursor(win)[1], 2)
        end
      end
      t.assert_eq(found, 1)
    end)
  end)

  t.it("restore never takes back a repurposed existing window", function()
    isolated(function(m)
      local win, buf = window(false, "code", m)
      m.current_group()
      local replacement = api.nvim_create_buf(true, false)
      api.nvim_win_set_buf(win, replacement)
      t.assert_true(m.restore_group() ~= nil)
      t.assert_eq(api.nvim_win_get_buf(win), replacement)
      t.assert_true(api.nvim_buf_is_valid(buf))
      t.assert_eq(#api.nvim_tabpage_list_wins(0), 1)
    end)
  end)

  t.it("view focus keeps buffers and rejects stale window buffer and role selections", function()
    isolated(function(m)
      local code, code_buf = window(false, "code", m)
      local panel, panel_buf = window(true, "panel", m)
      local aux = window(true, "aux", m)
      local rows = m.list_views()
      t.assert_eq(#rows, 3)
      t.assert_eq(#m.list_views("code"), 1); t.assert_eq(#m.list_views("panel"), 1)
      local row = m.list_views("code")[1]
      t.assert_eq(m.activate_view(row), code)
      t.assert_eq(api.nvim_win_get_buf(code), code_buf)
      t.assert_eq(api.nvim_win_get_buf(panel), panel_buf)
      m.register(code, "panel")
      local win, reason = m.activate_view(row)
      t.assert_nil(win); t.assert_contains(reason, "角色")
      local panel_row = m.list_views("panel")[1]
      api.nvim_win_set_buf(panel_row.win, api.nvim_create_buf(true, false))
      win, reason = m.activate_view(panel_row)
      t.assert_nil(win); t.assert_contains(reason, "buffer")
      m.register(aux, "code")
      local closed
      for _, candidate in ipairs(m.list_views("code")) do if candidate.win == aux then closed = candidate end end
      api.nvim_win_close(aux, true)
      win, reason = m.activate_view(closed)
      t.assert_nil(win); t.assert_contains(reason, "窗口")
    end)
  end)

  t.it("back skips a closed debug group and returns to the last valid group", function()
    isolated(function(m, normal, sessions)
      local code = window(false, "code", m)
      m.current_group()
      local review_tab, session = review(m, sessions)
      local debug_tab = debug_group(m)
      api.nvim_set_current_tabpage(normal)
      m.switch("review"); m.switch("debug"); m.switch("normal")
      api.nvim_set_current_tabpage(debug_tab); vim.cmd("tabclose!")
      api.nvim_set_current_tabpage(normal)
      t.assert_eq(m.back(), session.modified_win)
      t.assert_eq(api.nvim_get_current_tabpage(), review_tab)
      t.assert_eq(m.back(), code)
    end)
  end)

  t.it("review token replacement retains invalid metadata and cannot fake restore", function()
    isolated(function(m, _, sessions)
      local tab, old = review(m, sessions)
      local group = m.current_group()
      local metadata = vim.deepcopy(group.metadata)
      sessions[tab] = vim.tbl_extend("force", {}, old)
      local rows = m.list_groups()
      local row
      for _, item in ipairs(rows) do if item.id == group.id then row = item end end
      t.assert_eq(row.status, "已失效")
      t.assert_contains(row.reason, "重新打开比较")
      t.assert_eq(row.metadata.repo, "fixture-repo")
      t.assert_eq(row.metadata.original_revision, "base")
      t.assert_eq(row.metadata.modified_revision, "topic")
      t.assert_eq(row.metadata.pathspec[1], "Source/**")
      t.assert_eq(row.metadata.selected_path, "Source/Selected.cpp")
      t.assert_true(vim.deep_equal(row.metadata, metadata))
      local current = api.nvim_get_current_win()
      local win, reason = m.activate_group(group.id, { restore = true })
      t.assert_nil(win); t.assert_contains(reason, "重新打开比较")
      t.assert_eq(api.nvim_get_current_win(), current)
      sessions[tab] = nil
      win, reason = m.activate_group(group.id, { restore = true })
      t.assert_nil(win); t.assert_contains(reason, "owner")
    end)
  end)

  t.it("a closed review diff pane reports invalidity without creating a replacement", function()
    isolated(function(m, _, sessions)
      local tab, session = review(m, sessions)
      local group = m.current_group()
      api.nvim_win_close(session.original_win, true)
      local count = #api.nvim_tabpage_list_wins(tab)
      local win, reason = m.activate_group(group.id, { restore = true })
      t.assert_nil(win); t.assert_contains(reason, "diff pane")
      t.assert_eq(#api.nvim_tabpage_list_wins(tab), count)
      t.assert_eq(sessions[tab], session)
      t.assert_eq(m.current_group().id, group.id)
      win, reason = m.restore_group()
      t.assert_nil(win); t.assert_contains(reason, "diff pane")
    end)
  end)
end)

t.describe("layout management owner turnover", function()
  t.it("removed review owner permits a normal group in the same tab", function()
    isolated(function(m, _, sessions)
      local tab = review(m, sessions)
      local old = m.current_group()
      sessions[tab] = nil
      local current = m.current_group()
      t.assert_eq(current.kind, "normal")
      t.assert_true(current.id ~= old.id)
      local win, reason = m.activate_group(old.id, { restore = true })
      t.assert_nil(win); t.assert_contains(reason, "重新打开比较")
      t.assert_true(m.restore_group() ~= nil)
    end)
  end)
end)

t.describe("layout management callback and native owner recovery", function()
  t.it("TabEnter new focus survives group activation without owner focus replay", function()
    isolated(function(m, normal, sessions)
      window(false, "code", m)
      m.current_group()
      local tab, session = review(m, sessions)
      local group = m.current_group()
      api.nvim_set_current_tabpage(normal)
      local autocmd = api.nvim_create_autocmd("TabEnter", { once = true, callback = function()
        api.nvim_set_current_win(session.original_win)
      end })
      local win, reason = m.activate_group(group.id, { restore = true })
      pcall(api.nvim_del_autocmd, autocmd)
      t.assert_nil(win); t.assert_contains(reason, "新窗口")
      t.assert_eq(api.nvim_get_current_tabpage(), tab)
      t.assert_eq(api.nvim_get_current_win(), session.original_win)
    end)
  end)

  for _, mode in ipairs({ "new-pane", "buffer", "tick", "existing-focus" }) do
    t.it("WinNew " .. mode .. " callback retains its new selection during restore", function()
      isolated(function(m)
        local host = window(false, "code", m)
        local removed, retained_buf = window(true, "code", m)
        local existing
        if mode == "existing-focus" then existing = window(true, "code", m) end
        api.nvim_set_current_win(host)
        m.current_group()
        api.nvim_win_close(removed, true)
        api.nvim_set_current_win(host)
        local changed_win, changed_buf
        local autocmd = api.nvim_create_autocmd("WinNew", { once = true, callback = function()
          for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do if win ~= host then changed_win = win end end
          assert(changed_win)
          if mode == "existing-focus" then
            api.nvim_set_current_win(existing)
          elseif mode == "new-pane" then
            changed_buf = api.nvim_create_buf(true, false)
            api.nvim_buf_set_lines(changed_buf, 0, -1, false, { "callback-created pane", "keep cursor" })
            changed_win = api.nvim_open_win(changed_buf, false, { split = "below", win = host })
            api.nvim_win_set_cursor(changed_win, { 2, 0 })
          elseif mode == "buffer" then
            changed_buf = api.nvim_create_buf(true, false)
            api.nvim_buf_set_lines(changed_buf, 0, -1, false, { "user new content", "keep cursor" })
            api.nvim_win_set_buf(host, changed_buf)
            api.nvim_win_set_cursor(host, { 2, 0 })
          else
            api.nvim_buf_set_lines(retained_buf, 0, 1, false, { "callback edit" })
          end
        end })
        local win, reason = m.restore_group()
        pcall(api.nvim_del_autocmd, autocmd)
        if mode == "existing-focus" then
          t.assert_nil(win); t.assert_contains(reason, "新")
          t.assert_eq(api.nvim_get_current_win(), existing)
        elseif mode == "new-pane" then
          t.assert_eq(win, host)
          t.assert_eq(api.nvim_win_get_buf(changed_win), changed_buf)
          t.assert_eq(api.nvim_win_get_cursor(changed_win)[1], 2)
          t.assert_true(vim.bo[changed_buf].modified)
        elseif mode == "buffer" then
          t.assert_nil(win); t.assert_contains(reason, "新")
          t.assert_eq(api.nvim_win_get_buf(host), changed_buf)
          t.assert_eq(api.nvim_win_get_cursor(host)[1], 2)
          t.assert_true(vim.bo[changed_buf].modified)
        else
          t.assert_nil(win); t.assert_contains(reason, "新")
          t.assert_eq(api.nvim_buf_get_lines(retained_buf, 0, 1, false)[1], "callback edit")
          t.assert_true(vim.bo[retained_buf].modified)
        end
      end)
    end)
  end

  for _, mode in ipairs({ "inline", "original", "modified" }) do
    t.it("owner declared " .. mode .. " single visible pane remains valid", function()
      isolated(function(m, tab, sessions)
        local win, buf = window()
        local hidden = api.nvim_create_buf(true, false)
        local session
        if mode == "inline" then
          session = { layout = "inline", original_win = win, modified_win = win, original_bufnr = hidden, modified_bufnr = buf }
        else
          session = { single_pane = true, single_side = mode, [mode .. "_win"] = win, [mode .. "_bufnr"] = buf }
        end
        sessions[tab] = session
        m.sync_review(tab, session)
        t.assert_eq(m.current_group().kind, "review")
        t.assert_eq(m.restore_group(), win)
        t.assert_eq(api.nvim_win_get_buf(win), buf)
        t.assert_true(api.nvim_buf_is_valid(hidden))
      end)
    end)
  end

  t.it("closed bottom host restores retained output through the real owner", function()
    isolated(function(m)
      local code, code_buf = window(false, "code", m)
      local owner = require("utils.bottom_panel")
      local output = api.nvim_create_buf(false, true)
      vim.bo[output].bufhidden = "hide"
      api.nvim_buf_set_lines(output, 0, -1, false, { "old build output" })
      local panel = owner.show("build", output, { focus = false })
      m.current_group()
      api.nvim_win_close(panel, true)
      t.assert_eq(m.restore_group(), code)
      t.assert_eq(api.nvim_win_get_buf(owner.window()), output)
      t.assert_eq(api.nvim_win_get_buf(code), code_buf)
      t.assert_eq(api.nvim_buf_get_lines(output, 0, -1, false)[1], "old build output")
    end)
  end)

  t.it("new bottom host content rejects restoring the closed old output", function()
    isolated(function(m)
      window(false, "code", m)
      local owner = require("utils.bottom_panel")
      local output = api.nvim_create_buf(false, true)
      vim.bo[output].bufhidden = "hide"
      local panel = owner.show("build", output, { focus = false })
      m.current_group()
      api.nvim_win_close(panel, true)
      local newer = api.nvim_create_buf(false, true)
      vim.bo[newer].bufhidden = "hide"
      api.nvim_buf_set_lines(newer, 0, -1, false, { "new user-selected output" })
      local current = owner.show("logcat", newer, { focus = false })
      local win, reason = m.restore_group()
      t.assert_nil(win); t.assert_contains(reason, "底栏已有新内容")
      t.assert_eq(api.nvim_win_get_buf(current), newer)
      t.assert_eq(api.nvim_buf_get_lines(newer, 0, -1, false)[1], "new user-selected output")
    end)
  end)
end)

local function child(name, source, timeout)
  local run_root = vim.fs.joinpath(vim.env.NVIM_TEST_RUN_ROOT or vim.fn.tempname(), "layout-management-" .. name)
  vim.fn.mkdir(run_root, "p")
  local script = run_root .. "/native.lua"
  local wrapper = "local root, run_root = " .. string.format("%q, %q", root, run_root)
    .. "\nvim.opt.rtp:prepend(root)\npackage.path=root..'/lua/?.lua;'..root..'/lua/?/init.lua;'..package.path\n" .. source
  vim.fn.writefile(vim.split(wrapper, "\n", { plain = true }), script)
  local result = vim.system({ vim.v.progpath, "--headless", "-u", "NONE", "-i", "NONE", "-n", "-l", script }, {
    text = true, env = { XDG_CACHE_HOME = run_root .. "/cache", XDG_STATE_HOME = run_root .. "/state" },
  }):wait(timeout or 10000)
  t.assert_eq(result.code, 0, "native child: " .. (result.stderr or ""))
  t.assert_contains(result.stdout or "", "LAYOUT_MANAGEMENT_OK")
end

t.describe("layout management isolated command and job integration", function()
  t.it("first user pane close is captured without opening any layout list", function()
    child("first-close", [=[
local api=vim.api
local host=api.nvim_get_current_win()
local host_buf=api.nvim_create_buf(true,false)
api.nvim_win_set_buf(host,host_buf)
local commands=require('utils.layout_commands')
commands.setup()
-- No list/current_group/UELayout call between setup and the first close.
vim.cmd('vnew')
local pane=api.nvim_get_current_win()
local dirty=api.nvim_create_buf(true,false)
api.nvim_buf_set_name(dirty,run_root..'/retained-new-pane.lua')
api.nvim_buf_set_lines(dirty,0,-1,false,{'user unsaved code','keep this cursor'})
api.nvim_win_set_buf(pane,dirty)
api.nvim_win_set_cursor(pane,{2,0})
assert(vim.bo[dirty].modified)
local tick=api.nvim_buf_get_changedtick(dirty)
api.nvim_win_close(pane,true)
assert(api.nvim_get_current_win()==host)
vim.cmd('UELayoutRestore')
local found=0
for _,win in ipairs(api.nvim_tabpage_list_wins(0)) do
  if api.nvim_win_get_buf(win)==dirty then
    found=found+1
    assert(api.nvim_win_get_cursor(win)[1]==2,'first closed pane cursor lost')
  end
end
assert(found==1,'first closed dirty code pane not restored exactly once')
assert(api.nvim_win_get_buf(host)==host_buf,'original host content changed')
assert(api.nvim_get_current_win()==host,'snapshot observers changed current focus')
assert(api.nvim_buf_get_changedtick(dirty)==tick and vim.bo[dirty].modified,'dirty text changed or saved')
assert(api.nvim_buf_get_lines(dirty,0,-1,false)[1]=='user unsaved code')
api.nvim_del_augroup_by_name('UELayoutGroups') -- Only this isolated child's group.
io.write('LAYOUT_MANAGEMENT_OK\n')
vim.cmd('qa!')
]=])
  end)

  t.it("native command nargs completion and stale select callback identity", function()
    child("commands", [=[
local api=vim.api
package.loaded.snacks={} -- Exercise documented vim.ui.select fallback.
local selects={}
vim.ui.select=function(rows, opts, callback) selects[#selects+1]={rows=rows,opts=opts,callback=callback} end
local notices={}
vim.notify=function(message) notices[#notices+1]=message end
local m=require('utils.layout')
require('utils.layout_commands').setup()
local commands=api.nvim_get_commands({builtin=false})
assert(commands.UELayout.nargs=='?' and commands.UEView.nargs=='?')
assert(commands.UELayoutRestore.nargs=='0' and commands.UELayoutBack.nargs=='0')
local completion=vim.fn.getcompletion('UELayout ', 'cmdline')
table.sort(completion)
assert(vim.deep_equal(completion, {'debug','normal','review'}),vim.inspect(completion))
assert(vim.deep_equal(vim.fn.getcompletion('UEView ', 'cmdline'), {'code','panel'}),'view completion')
vim.cmd('UELayout unknown')
assert(notices[#notices]:find('normal / review / debug',1,true))
assert(not pcall(vim.cmd,'UELayoutRestore extra'))
local first=api.nvim_get_current_tabpage()
local first_win=api.nvim_get_current_win()
m.register(first_win,'code')
vim.cmd('tabnew')
local second=api.nvim_get_current_tabpage()
local second_win=api.nvim_get_current_win()
m.register(second_win,'code')
api.nvim_set_current_tabpage(first)
vim.cmd('UELayout')
local stale=selects[#selects]
vim.cmd('UELayout')
local fresh=selects[#selects]
local target
for _,row in ipairs(fresh.rows) do if row.tab==second then target=row end end
assert(target)
stale.callback(target)
assert(api.nvim_get_current_tabpage()==first, 'superseded selector switched tabs')
fresh.callback(target)
assert(api.nvim_get_current_tabpage()==second, 'fresh selector lost group identity')
vim.cmd('UELayout')
local moved=selects[#selects]
api.nvim_set_current_tabpage(first)
moved.callback(target)
assert(api.nvim_get_current_tabpage()==first,'selector ignored changed source tab')
local buf=api.nvim_win_get_buf(first_win)
vim.cmd('UEView code')
assert(api.nvim_get_current_win()==first_win and api.nvim_win_get_buf(first_win)==buf)
vim.cmd('vnew')
local panel=api.nvim_get_current_win()
m.register(panel,'panel')
vim.cmd('UEView')
local views=selects[#selects]
local code
for _,row in ipairs(views.rows) do if row.win==first_win then code=row end end
m.register(first_win,'panel')
views.callback(code)
assert(api.nvim_get_current_win()==panel, 'stale role callback changed focus')
assert(#notices>=2,'stale selections lacked visible reasons')
vim.cmd('UELayout')
local same_tab=selects[#selects]
vim.cmd('vnew')
local new_focus=api.nvim_get_current_win()
same_tab.callback(target)
assert(api.nvim_get_current_win()==new_focus,'same-tab changed focus was stolen')
vim.cmd('UELayout')
local cancelled=selects[#selects]
cancelled.callback(nil)
cancelled.callback(target)
assert(api.nvim_get_current_win()==new_focus,'cancelled selector was replayed')
vim.cmd('UELayout')
local replaced=selects[#selects]
api.nvim_win_set_buf(new_focus,api.nvim_create_buf(true,false))
replaced.callback(target)
assert(api.nvim_get_current_win()==new_focus,'changed source buffer was ignored')
io.write('LAYOUT_MANAGEMENT_OK\n')
vim.cmd('qa!')
]=])
  end)

  t.it("real running job and registry handle survive layout switches and restoration", function()
    child("job", [=[
local api=vim.api
local registry=require('utils.task_registry')
local worker=run_root..'/worker.lua'
vim.fn.writefile({"vim.defer_fn(function() vim.cmd('qa!') end, 10000)","vim.wait(15000,function() return false end,20)"},worker)
local job=vim.fn.jobstart({vim.v.progpath,'--headless','-u','NONE','-i','NONE','-n','-l',worker})
assert(job>0,'owned worker did not start')
local ok,err=xpcall(function()
  local id=registry.register({name='layout-owned-test-job',group='test',kind='job',handle=job})
  local m=require('utils.layout')
  local tab=api.nvim_get_current_tabpage()
  m.current_group()
  vim.cmd('tabnew')
  local debug_tab=api.nvim_get_current_tabpage()
  local win=api.nvim_get_current_win()
  local token={}
  local calls=0
  m.register_group('debug',{tab=debug_tab,token=token,focus=function(g) assert(g.token==token);calls=calls+1;api.nvim_set_current_win(win);return win end,restore=function(g) assert(g.token==token);return win end})
  api.nvim_set_current_tabpage(tab)
  for _=1,3 do assert(m.switch('debug'));assert(m.restore_group());assert(m.switch('normal'));assert(m.restore_group()) end
  assert(calls==3)
  assert(vim.fn.jobwait({job},0)[1]==-1,'layout stopped owned running task')
  assert(registry.status(id)=='running','registry task no longer running')
  assert(registry.get(id).handle==job,'task handle identity changed')
end,debug.traceback)
vim.fn.jobstop(job) -- Stop only the child this test created, after assertions.
vim.fn.jobwait({job},3000)
assert(ok,err)
io.write('LAYOUT_MANAGEMENT_OK\n')
vim.cmd('qa!')
]=])
  end)
end)

t.describe("layout management installed CodeDiff owner", function()
  local plugins = vim.fs.joinpath(vim.fn.stdpath("data"), "lazy")
  if not vim.uv.fs_stat(plugins .. "/codediff.nvim/lua/codediff/ui/view/init.lua") then
    t.skip("hidden native explorer retains owner references without refresh", "installed CodeDiff unavailable", { native = true })
  else
    t.it("hidden native explorer retains owner references without refresh", function()
      child("review-panel", "local plugins=" .. string.format("%q", plugins) .. "\n" .. [=[
for _,name in ipairs({'snacks.nvim','codediff.nvim'}) do vim.opt.rtp:prepend(plugins..'/'..name) end
require('snacks')
require('codediff.config').setup({})
local api=vim.api
local function write(name, text) local path=run_root..'/'..name;vim.fn.writefile({text},path);return path end
local left_path=write('original.usf','float Before();')
local right_path=write('modified.usf','float After();')
local ready=false
require('codediff.ui.view').create({original={absolute=left_path},modified={absolute=right_path}},'hlsl',function() ready=true end)
assert(vim.wait(4000,function() return ready end,20),'native CodeDiff not ready')
local tab=api.nvim_get_current_tabpage()
local owner=require('codediff.ui.lifecycle')
local session=assert(owner.get_session(tab))
session.panel={name='explorer',data={dir1=run_root,dir2=run_root,status_result={unstaged={},staged={},conflicts={}}}}
require('codediff.ui.view.panel').setup_explorer(tab,{panel=session.panel},session.original_win,session.modified_win)
local panel=assert(session.panel.view)
session.git_root='native-fixture-repo'
session.original_revision='base';session.modified_revision='topic'
session.panel.data.pathspec={'Source/**'}
panel.data.current_file_path='Source/Selected.cpp'
local m=require('utils.layout')
m.sync_review(tab,session)
local group=m.current_group()
local metadata=vim.deepcopy(group.metadata)
local panel_buf=panel.bufnr
local left_buf,right_buf=api.nvim_win_get_buf(session.original_win),api.nvim_win_get_buf(session.modified_win)
local original_refresh=require('codediff.ui.refresh').request
local original_select=panel.on_file_select
local refreshes,selections=0,0
require('codediff.ui.refresh').request=function(...) refreshes=refreshes+1;return original_refresh(...) end
panel.on_file_select=function(...) selections=selections+1;return original_select(...) end
require('codediff.ui.explorer').toggle_visibility(panel)
assert(panel.is_hidden and not api.nvim_win_is_valid(panel.winid),'native explorer not hidden')
assert(m.restore_group(),'native panel restore failed')
assert(api.nvim_win_is_valid(panel.winid) and not panel.is_hidden,'native panel not restored')
assert(panel.bufnr==panel_buf and panel.split.bufnr==panel_buf and api.nvim_win_get_buf(panel.winid)==panel_buf,'native panel buffer identity changed')
assert(owner.get_session(tab)==session,'native owner session replaced')
assert(api.nvim_win_get_buf(session.original_win)==left_buf and api.nvim_win_get_buf(session.modified_win)==right_buf,'diff buffers changed')
assert(refreshes==0 and selections==0,'restore replayed owner business operations')
assert(vim.deep_equal(m.current_group().metadata,metadata),'repo/revisions/pathspec/selection changed')
local commands=require('utils.layout_commands')
commands.setup()
local function ready_picker(picker)
  assert(picker,'native command did not return a picker')
  assert(vim.wait(3000,function() return picker:current() and picker.list.win:valid() end,20),'native command picker not ready')
  return picker
end
local function select_item(picker,predicate)
  for index,item in ipairs(picker:items()) do
    if predicate(item.data) then
      picker.list:move(index,true,true)
      api.nvim_set_current_win(picker.list.win.win)
      picker:action('confirm')
      assert(vim.wait(3000,function() return picker.closed end,20),'native command picker did not close')
      return item
    end
  end
  error('requested native picker item absent')
end
-- Real command picker chooses the actual existing owner panel, not a new buffer.
api.nvim_set_current_win(session.modified_win)
local views=ready_picker(commands.view())
select_item(views,function(row) return row.win==panel.winid end)
assert(vim.wait(1000,function() return api.nvim_get_current_win()==panel.winid end,20),'real UEView confirm did not focus panel')
assert(api.nvim_win_get_buf(panel.winid)==panel_buf,'UEView replaced owner panel buffer')
-- Cancellation permanently invalidates that picker callback.
local cancelled=ready_picker(commands.view())
local cancelled_item=cancelled:current()
cancelled:close()
cancelled.opts.confirm(cancelled,cancelled_item)
vim.wait(100,function() return false end,10)
assert(api.nvim_get_current_win()==panel.winid,'cancelled real picker changed focus')
-- The close hook makes a new user selection before the queued activation.
api.nvim_set_current_win(session.modified_win)
local changed=ready_picker(commands.view())
local original_close=changed.opts.on_close
changed.opts.on_close=function(...)
  if original_close then original_close(...) end
  api.nvim_set_current_win(panel.winid)
end
select_item(changed,function(row) return row.win==session.original_win end)
vim.wait(100,function() return false end,10)
assert(api.nvim_get_current_win()==panel.winid,'queued real picker confirm stole close-hook new focus')
-- UELayout's native picker chooses a retained normal group by identity.
local layouts=ready_picker(commands.layout())
local normal_tab
local chosen=select_item(layouts,function(row)
  if row.kind=='normal' and row.status~='已失效' then normal_tab=row.tab;return true end
end)
assert(chosen and normal_tab)
assert(vim.wait(1000,function() return api.nvim_get_current_tabpage()==normal_tab end,20),'real UELayout confirm lost selected group identity')
io.write('LAYOUT_MANAGEMENT_OK\n')
vim.cmd('qa!')
]=], 15000)
    end)
  end
end)
