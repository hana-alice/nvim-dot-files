local t = require("tests.harness")
local root = t.bootstrap()
local api = vim.api

-- Window tests use Neovim's real tab/split/float APIs. No window API is mocked.
local function isolated(fn)
  local saved = package.loaded["utils.layout"]
  local saved_lifecycle = package.loaded["codediff.ui.lifecycle"]
  local sessions = {}
  -- Session fixtures supply ownership only; all window selection is real.
  package.loaded["codediff.ui.lifecycle"] = {
    get_session = function(tab) return sessions[tab] end,
    _test_sessions = sessions,
  }
  local start = api.nvim_get_current_tabpage()
  local tabs, buffers = {}, {}
  for _, tab in ipairs(api.nvim_list_tabpages()) do tabs[tab] = true end
  for _, buf in ipairs(api.nvim_list_bufs()) do buffers[buf] = true end
  vim.cmd("tabnew")
  package.loaded["utils.layout"] = nil
  local ok, err = xpcall(function()
    local layout = require("utils.layout")
    -- Stage-4 startup registers existing normal tabs once. The fresh fixture
    -- module receives that registration explicitly; passive queries are local.
    layout.discover_groups(start)
    fn(layout, api.nvim_get_current_tabpage())
  end, debug.traceback)
  for _, buf in ipairs(api.nvim_list_bufs()) do
    if not buffers[buf] then vim.bo[buf].modified = false end
  end
  for _, tab in ipairs(api.nvim_list_tabpages()) do
    if not tabs[tab] then api.nvim_set_current_tabpage(tab); vim.cmd("tabclose!") end
  end
  if api.nvim_tabpage_is_valid(start) then api.nvim_set_current_tabpage(start) end
  package.loaded["utils.layout"] = saved
  package.loaded["codediff.ui.lifecycle"] = saved_lifecycle
  if not ok then error(err, 0) end
end

local function window(opts)
  opts = opts or {}
  if opts.split then vim.cmd("rightbelow vnew") end
  local buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_lines(buf, 0, -1, false, { opts.text or "window content" })
  vim.bo[buf].buftype = opts.buftype or ""
  vim.bo[buf].filetype = opts.filetype or "lua"
  vim.bo[buf].modified = false
  local win = api.nvim_get_current_win()
  api.nvim_win_set_buf(win, buf)
  return win, buf
end

local function review(m, tab)
  local original, original_buf = window()
  local modified, modified_buf = window({ split = true })
  local panel, panel_buf = window({ split = true, buftype = "nofile", filetype = "codediff-explorer" })
  local session = { original_win = original, modified_win = modified, panel = { view = { winid = panel } } }
  package.loaded["codediff.ui.lifecycle"]._test_sessions[tab] = session
  m.sync_review(tab, session)
  return { original, modified, panel }, { original_buf, modified_buf, panel_buf }
end

local function unchanged(wins, bufs)
  for i, win in ipairs(wins) do t.assert_eq(api.nvim_win_get_buf(win), bufs[i], "review pane " .. i) end
end

t.describe("layout real windows", function()
  t.it("registered code wins over panel and aux anchors", function()
    isolated(function(m, tab)
      local code = window()
      local panel = window({ split = true })
      local aux = window({ split = true })
      t.assert_eq(m.register(code, "code"), code)
      m.register(panel, "panel")
      m.register(aux, "aux")
      t.assert_eq(m.resolve({ tab = tab, source_win = panel, anchor = aux, create = false }), code)
      m.focus({ tab = tab, source_win = panel })
      t.assert_eq(api.nvim_get_current_win(), code)
    end)
  end)

  t.it("unregister removes a protected role and invalid registration fails", function()
    isolated(function(m, tab)
      local win = window()
      m.register(win, "panel")
      t.assert_nil(m.resolve({ tab = tab, source_win = win, create = false }))
      m.unregister(win)
      t.assert_eq(m.resolve({ tab = tab, source_win = win, create = false }), win)
      local invalid, err = m.register(-99, "code")
      t.assert_nil(invalid)
      t.assert_true(err ~= nil)
    end)
  end)

  t.it("floating and winfixbuf code windows cannot be jump destinations", function()
    isolated(function(m, tab)
      local fixed = window()
      vim.wo[fixed].winfixbuf = true
      m.register(fixed, "code")
      local float = api.nvim_open_win(api.nvim_create_buf(false, true), false,
        { relative = "editor", row = 1, col = 1, width = 15, height = 2 })
      m.register(float, "code")
      local code = window({ split = true })
      m.register(code, "code")
      t.assert_eq(m.resolve({ tab = tab, source_win = float, anchor = fixed, create = false }), code)
    end)
  end)

  t.it("cross-tab source and anchor never escape the requested tab", function()
    isolated(function(m, tab)
      local code = window()
      m.register(code, "code")
      vim.cmd("tabnew")
      local foreign = window()
      m.register(foreign, "code")
      t.assert_eq(m.resolve({ tab = tab, source_win = foreign, anchor = foreign, create = false }), code)
      t.assert_eq(api.nvim_win_get_tabpage(code), tab)
    end)
  end)

  t.it("current ordinary editor wins over another marked Snacks main", function()
    isolated(function(m, tab)
      local old = window()
      vim.w[old].snacks_main = true
      local current = window({ split = true })
      api.nvim_set_current_win(current)
      t.assert_eq(m.resolve({ tab = tab, create = false }), current)
    end)
  end)

  t.it("marked history/explorer and floating windows cannot replace normal code", function()
    isolated(function(m, tab)
      local code = window()
      local history = window({ split = true, filetype = "codediff-history" })
      local explorer = window({ split = true, filetype = "codediff-explorer" })
      local float = api.nvim_open_win(api.nvim_create_buf(false, true), false,
        { relative = "editor", row = 1, col = 1, width = 10, height = 2 })
      for _, win in ipairs({ history, explorer, float }) do vim.w[win].snacks_main = true end
      t.assert_eq(m.resolve({ tab = tab, source_win = explorer, create = false }), code)
    end)
  end)

  t.it("all protected panes return nil from a pure selector query", function()
    isolated(function(m, tab)
      local wins = review(m, tab)
      for _, win in ipairs(wins) do vim.w[win].snacks_main = true end
      t.assert_nil(m.resolve({ tab = tab, source_win = wins[1], create = false }))
    end)
  end)

  t.it("closed code registrations are ignored in favor of a live code window", function()
    isolated(function(m, tab)
      local stale = window()
      m.register(stale, "code")
      local live = window({ split = true })
      m.register(live, "code")
      api.nvim_win_close(stale, true)
      t.assert_eq(m.resolve({ tab = tab, source_win = stale, anchor = stale, create = false }), live)
    end)
  end)

  t.it("plain working-file panes stay protected while one normal editing tab is reused", function()
    isolated(function(m, tab)
      local wins, bufs = review(m, tab)
      t.assert_true(m.is_review(tab))
      t.assert_eq(vim.bo[bufs[1]].buftype, "")
      t.assert_eq(vim.bo[bufs[2]].buftype, "")
      t.assert_nil(m.resolve({ tab = tab, source_win = wins[2], create = false }))
      local before = #api.nvim_tabpage_list_wins(tab)
      local tab_count = #api.nvim_list_tabpages()
      api.nvim_set_current_win(wins[2])
      local browser = m.resolve({ tab = tab, source_win = wins[2] })
      t.assert_true(browser ~= wins[1] and browser ~= wins[2] and browser ~= wins[3])
      t.assert_true(api.nvim_win_get_tabpage(browser) ~= tab)
      t.assert_eq(#api.nvim_tabpage_list_wins(tab), before)
      for _, source in ipairs(wins) do
        api.nvim_set_current_win(source)
        t.assert_eq(m.resolve({ tab = tab, source_win = source }), browser)
      end
      t.assert_eq(#api.nvim_tabpage_list_wins(tab), before)
      t.assert_eq(#api.nvim_list_tabpages(), tab_count)
      t.assert_false(vim.wo[browser].diff)
      t.assert_false(vim.wo[browser].scrollbind)
      t.assert_false(vim.wo[browser].cursorbind)
      unchanged(wins, bufs)
    end)
  end)

  t.it("closing normal code reuses its remaining editor without changing review", function()
    isolated(function(m, tab)
      local wins, bufs = review(m, tab)
      local count = #api.nvim_tabpage_list_wins(tab)
      api.nvim_set_current_win(wins[1])
      local browser = m.resolve({ tab = tab, source_win = wins[1] })
      api.nvim_set_current_win(browser)
      local remaining = window({ split = true })
      api.nvim_win_close(browser, true)
      api.nvim_set_current_win(wins[2])
      local replacement = m.resolve({ tab = tab, source_win = wins[2] })
      t.assert_eq(replacement, remaining)
      t.assert_true(api.nvim_win_get_tabpage(replacement) ~= tab)
      t.assert_eq(#api.nvim_tabpage_list_wins(tab), count)
      api.nvim_set_current_win(wins[3])
      t.assert_eq(m.resolve({ tab = tab, source_win = wins[3] }), replacement)
      unchanged(wins, bufs)
    end)
  end)

  t.it("merge result is aux even with an ordinary editable buffer", function()
    isolated(function(m, tab)
      local wins, bufs = review(m, tab)
      local result = window({ split = true })
      local session = { original_win = wins[1], modified_win = wins[2], result_win = result,
        panel = { view = { winid = wins[3] } } }
      package.loaded["codediff.ui.lifecycle"]._test_sessions[tab] = session
      m.sync_review(tab, session)
      local browser = m.resolve({ tab = tab, source_win = result })
      t.assert_true(browser ~= result)
      t.assert_true(api.nvim_win_get_tabpage(browser) ~= tab)
      unchanged(wins, bufs)
    end)
  end)

  t.it("a registered normal editor displaying nowrite content remains reusable", function()
    isolated(function(m, tab)
      local wins, bufs = review(m, tab)
      api.nvim_set_current_win(wins[1])
      local browser = m.resolve({ tab = tab, source_win = wins[1] })
      local revision = api.nvim_create_buf(false, true)
      vim.bo[revision].buftype = "nowrite"
      api.nvim_win_set_buf(browser, revision)
      local count = #api.nvim_tabpage_list_wins(tab)
      local tab_count = #api.nvim_list_tabpages()
      for _, source in ipairs(wins) do
        api.nvim_set_current_win(source)
        t.assert_eq(m.resolve({ tab = tab, source_win = source }), browser)
      end
      t.assert_eq(#api.nvim_tabpage_list_wins(tab), count)
      t.assert_eq(#api.nvim_list_tabpages(), tab_count)
      unchanged(wins, bufs)
    end)
  end)

  t.it("closed review sessions release owned pane roles", function()
    isolated(function(m, tab)
      local wins, bufs = review(m, tab)
      t.assert_true(m.is_review(tab))
      package.loaded["codediff.ui.lifecycle"]._test_sessions[tab] = nil
      t.assert_false(m.is_review(tab))
      t.assert_eq(m.resolve({ tab = tab, source_win = wins[1], create = false }), wins[1])
      t.assert_eq(#api.nvim_tabpage_list_wins(tab), #wins)
      unchanged(wins, bufs)
    end)
  end)
end)

local native = [=[
local root, plugin_root, run_root = ...
vim.opt.rtp:prepend(root)
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path
for _, plugin in ipairs({"snacks.nvim", "codediff.nvim"}) do vim.opt.rtp:prepend(plugin_root .. "/" .. plugin) end
require("snacks")
require("codediff.config").setup({})
local api = vim.api
local layout = require("utils.layout")
local view = require("codediff.ui.view")
local lifecycle = require("codediff.ui.lifecycle")
local function check(value, message) assert(value, message) end
local function write(name, lines)
  local path = run_root .. "/" .. name
  vim.fn.writefile(lines, path)
  return path
end
local paths = {
  write("old.usf", {"float Old();"}), write("new.usf", {"float New();"}),
  write("old2.usf", {"float Older();"}), write("new2.usf", {"float Newer();"}),
}
local function config(a, b)
  return {original={absolute=paths[a]}, modified={absolute=paths[b]}}
end
local ready
view.create(config(1, 2), "hlsl", function() ready=true end)
check(vim.wait(4000, function() return ready end, 20), "real CodeDiff creation timed out")
local tab = api.nvim_get_current_tabpage()
local session = assert(lifecycle.get_session(tab))
local left, right = session.original_win, session.modified_win
-- Render the installed explorer with a bounded directory-comparison fixture.
session.panel={name="explorer",data={dir1=run_root,dir2=run_root,
  status_result={unstaged={},staged={},conflicts={}}}}
require("codediff.ui.view.panel").setup_explorer(tab,{panel=session.panel},left,right)
layout.sync_review(tab,session)
local panel=assert(session.panel and session.panel.view and session.panel.view.winid,"real explorer panel missing")
local panel_buf=api.nvim_win_get_buf(panel)
local left_buf, right_buf = api.nvim_win_get_buf(left), api.nvim_win_get_buf(right)
local left_cursor, right_cursor = api.nvim_win_get_cursor(left), api.nvim_win_get_cursor(right)
local count = #api.nvim_tabpage_list_wins(tab)
local empty={main=left,opts={jump={close=false}},selected=function() return {} end}
layout.confirm(empty,nil,{})
check(#api.nvim_tabpage_list_wins(tab)==count,"empty confirm created a browser")
check(api.nvim_win_get_buf(left)==left_buf and api.nvim_win_get_buf(right)==right_buf
  and api.nvim_win_get_buf(panel)==panel_buf,"empty confirm changed a review window")
local item = {buf=right_buf, pos={1, 4}}
local picker = {
  main=left,
  filter=function() return {current_win=left} end,
  opts={jump={close=false, reuse_win=true, jumplist=false, tagstack=false, match=false}},
  selected=function() return {item} end,
}
local original_opts = vim.deepcopy(picker.opts)
api.nvim_set_current_win(left)
layout.confirm(picker, item, {cmd="drop"})
local browser = api.nvim_get_current_win()
local normal_tab = api.nvim_get_current_tabpage()
local tab_count = #api.nvim_list_tabpages()
check(normal_tab ~= tab, "external confirm did not switch the whole UI to normal")
check(layout.current_group().kind == "normal", "navigation destination is not a normal group")
check(browser ~= left and browser ~= right, "Snacks drop/reuse escaped into a diff pane")
check(api.nvim_win_get_buf(browser) == right_buf, "actual Snacks jump did not open selected buffer")
check(api.nvim_win_get_buf(left) == left_buf and api.nvim_win_get_buf(right) == right_buf, "confirm replaced diff buffer")
check(api.nvim_win_get_buf(panel)==panel_buf,"confirm overwrote real explorer")
check(vim.deep_equal(api.nvim_win_get_cursor(left),left_cursor) and vim.deep_equal(api.nvim_win_get_cursor(right),right_cursor), "confirm moved a diff cursor")
check(#api.nvim_tabpage_list_wins(tab)==count, "confirm added a browser inside review")
check(vim.deep_equal(picker.opts, original_opts), "confirm leaked temporary jump options")
for _=1,3 do
  api.nvim_set_current_win(left)
  layout.confirm(picker,item,{cmd="drop"})
  check(api.nvim_get_current_tabpage()==normal_tab,"confirm failed to reuse normal group")
  check(layout.back()==left,"Back did not restore original review source")
  check(api.nvim_get_current_win()==left,"Back did not preserve original review window")
end
api.nvim_set_current_win(left)
layout.confirm(picker,item,{cmd="drop"})
check(api.nvim_get_current_win()==browser, "repeated confirm did not reuse browser")
check(#api.nvim_tabpage_list_wins(tab)==count, "repeated confirm accumulated review splits")
check(#api.nvim_list_tabpages()==tab_count, "repeated confirm accumulated normal tabs")
check(view.update(tab,config(3,4)), "CodeDiff's own file update rejected")
check(vim.wait(3000, function()
  local s=lifecycle.get_session(tab)
  return s and api.nvim_buf_get_lines(s.modified_bufnr,0,-1,false)[1]=="float Newer();"
end,20), "CodeDiff's own file update did not change its diff group")
session = lifecycle.get_session(tab)
check(session.original_win==left and session.modified_win==right, "CodeDiff changed pane ownership")
check(api.nvim_buf_get_lines(session.original_bufnr,0,-1,false)[1]=="float Older();", "CodeDiff did not update original pane")
check(api.nvim_win_get_buf(browser)==right_buf, "CodeDiff own file selection changed browser")
-- Real review_goto uses the real virtual URL parser, actual file loading and vim.diff.
local revision = api.nvim_create_buf(false,true)
api.nvim_buf_set_name(revision,require("codediff.core.virtual_file").create_url(run_root,"HEAD","new2.usf"))
api.nvim_buf_set_lines(revision,0,-1,false,{"float Newer();"})
vim.bo[revision].buftype="nowrite"
vim.bo[revision].modified=false
api.nvim_win_set_buf(left,revision)
-- The retained lifecycle token must describe the fixture's current panes;
-- otherwise Back correctly rejects an externally repurposed review window.
session.original_bufnr=revision
local goto_review=require("utils.review_goto")
local calls=0
local revision_cursor=api.nvim_win_get_cursor(left)
for _=1,3 do
  api.nvim_set_current_win(left)
  check(goto_review.definition(function() calls=calls+1 end), "revision gd was not handled")
  check(api.nvim_get_current_win()==browser, "revision gd did not reuse browser")
  check(layout.back()==left,"revision gd Back did not restore originating pane")
  check(vim.deep_equal(api.nvim_win_get_cursor(left),revision_cursor),"revision gd moved its source cursor")
end
check(calls==3, "shader gd callback did not execute")
for _=1,3 do
  api.nvim_set_current_win(right)
  check(goto_review.definition(function() calls=calls+1 end), "working review gd was not handled")
  check(api.nvim_get_current_win()==browser, "working gd did not reuse browser")
  check(layout.back()==right,"working gd Back did not restore originating pane")
end
check(calls==6, "working gd callback did not execute")
check(#api.nvim_tabpage_list_wins(tab)==count, "gd accumulated review splits")
check(#api.nvim_list_tabpages()==tab_count, "gd accumulated normal tabs")
check(api.nvim_win_get_buf(left)==revision and api.nvim_win_get_buf(right)==session.modified_bufnr, "gd replaced review panes")
-- Apply the repository's real Snacks options, then dispatch the real keyboard action.
local specs=assert(loadfile(root .. "/lua/plugins/snacks.lua"))()
local options=specs[1].opts(nil,{})
Snacks.config.picker=options.picker
check(options.picker.sources.grep.finder==require("utils.search_recipe").grep_finder, "grep recipe finder was lost")
check(options.picker.confirm==layout.confirm, "default confirm did not use layout")
api.nvim_set_current_win(panel)
local actual=Snacks.picker.pick("files",{
  finder=function() return {{file=paths[4],buf=session.modified_bufnr,pos={1,4}}} end,
  format="file", preview="none", focus="list",
  layout={preset="select"},
  jump={close=true,reuse_win=true,match=false},
  on_close=function() api.nvim_set_current_win(right) end,
})
check(vim.wait(3000,function() return actual:current() ~= nil and actual.list.win:valid() end,20), "actual Snacks picker did not become ready")
api.nvim_set_current_win(actual.list.win.win)
actual:action("confirm")
check(vim.wait(3000,function() return actual.closed and #api.nvim_tabpage_list_wins(tab)==count end,20), "actual confirm did not close picker windows")
check(api.nvim_get_current_win()==browser, "real source keyboard confirm/on_close escaped to diff pane")
check(api.nvim_win_get_buf(left)==revision and api.nvim_win_get_buf(right)==session.modified_bufnr, "real picker overwrote review panes")
check(api.nvim_win_get_buf(panel)==panel_buf,"keyboard confirm overwrote real explorer")
local recipe=require("utils.search_recipe")
api.nvim_set_current_win(panel)
local grep=assert(recipe.open_grep({
  cwd=run_root,dirs={run_root},search="Newer",
  finder=function() return {{file=paths[4],buf=session.modified_bufnr,pos={1,4},text="Newer",line="float Newer();"}} end,
  format="file",preview="none",focus="list",layout={preset="select"},
  jump={close=true,reuse_win=true,match=false},
  on_close=function() api.nvim_set_current_win(right) end,
},"workspace",{project_root=run_root,uproject=run_root .. "/Fixture.uproject",engine_root=run_root}))
check(grep.opts.confirm==recipe.confirm,"grep custom recipe confirm was replaced")
check(vim.wait(3000,function() return grep:current() ~= nil and grep.list.win:valid() end,20),"actual recipe picker not ready")
api.nvim_set_current_win(grep.list.win.win)
grep:action("confirm")
check(vim.wait(3000,function() return grep.closed and #api.nvim_tabpage_list_wins(tab)==count end,20),"recipe picker did not close")
check(api.nvim_get_current_win()==browser,"recipe keyboard confirm escaped to a diff pane")
check(api.nvim_win_get_buf(panel)==panel_buf and api.nvim_win_get_buf(left)==revision
  and api.nvim_win_get_buf(right)==session.modified_bufnr,"recipe confirm replaced review windows")
-- Closing can replace the owner's session without destroying the old browser.
-- That old picker must not perform its queued jump into the new session.
local stale_path=write("stale-selection.usf",{"float Stale();"})
local stale_buf=vim.fn.bufadd(stale_path)
vim.fn.bufload(stale_buf)
local browser_before=api.nvim_win_get_buf(browser)
local active=require("codediff.ui.lifecycle.session").get_active_diffs()
local replacement=vim.tbl_extend("force",{},session)
api.nvim_set_current_win(panel)
local stale=Snacks.picker.pick("files",{
  finder=function() return {{file=stale_path,buf=stale_buf,pos={1,0}}} end,
  format="file",preview="none",focus="list",layout={preset="select"},
  jump={close=true,reuse_win=true,match=false},
  on_close=function()
    active[tab]=replacement
    api.nvim_set_current_win(right)
  end,
})
check(vim.wait(3000,function() return stale:current() ~= nil and stale.list.win:valid() end,20),"stale session picker not ready")
api.nvim_set_current_win(stale.list.win.win)
stale:action("confirm")
check(vim.wait(3000,function() return stale.closed and #api.nvim_tabpage_list_wins(tab)==count end,20),"stale session picker did not close")
check(lifecycle.get_session(tab)==replacement,"close did not replace the session fixture")
check(api.nvim_win_is_valid(browser) and api.nvim_win_get_buf(browser)==browser_before,"old picker opened its item after session replacement")
check(api.nvim_get_current_win()==right,"old picker stole the new session's selection")
check(api.nvim_win_get_buf(panel)==panel_buf and api.nvim_win_get_buf(left)==revision
  and api.nvim_win_get_buf(right)==session.modified_bufnr,"stale picker changed new session panes")
active[tab]=session
-- Ordinary tabs keep Snacks' own selected-window and jump-option behavior.
vim.cmd("tabnew")
local first=api.nvim_get_current_win()
vim.cmd("vnew")
local second=api.nvim_get_current_win()
api.nvim_win_set_buf(second,right_buf)
api.nvim_set_current_win(first)
local normal={main=first,opts=vim.deepcopy(original_opts),selected=function() return {item} end}
local normal_opts=vim.deepcopy(normal.opts)
layout.confirm(normal,item,{cmd="edit"})
check(api.nvim_get_current_win()==second, "ordinary tab lost Snacks reuse_win behavior")
check(vim.deep_equal(normal.opts,normal_opts), "ordinary confirm changed options")
io.write("NATIVE_LAYOUT_OK\n")
vim.cmd("qa!")
]=]

t.describe("layout installed plugin integration", function()
  local plugins = vim.fs.joinpath(vim.fn.stdpath("data"), "lazy")
  if not vim.uv.fs_stat(plugins .. "/snacks.nvim/lua/snacks/init.lua")
    or not vim.uv.fs_stat(plugins .. "/codediff.nvim/lua/codediff/ui/view/init.lua") then
    t.skip("real Snacks, CodeDiff file switching and repeated revision/working gd", "installed plugins unavailable", { native = true })
  else
    t.it("real Snacks, CodeDiff file switching and repeated revision/working gd", function()
      local run_root = vim.fs.joinpath(vim.env.NVIM_TEST_RUN_ROOT or vim.fn.tempname(), "layout-native")
      vim.fn.mkdir(run_root, "p")
      local script = run_root .. "/native.lua"
      local wrapper = "local root, plugins, run_root = " .. string.format("%q, %q, %q", root, plugins, run_root)
        .. "\nlocal function run(...)\n" .. native .. "\nend\nrun(root, plugins, run_root)\n"
      vim.fn.writefile(vim.split(wrapper, "\n", { plain = true }), script)
      local result = vim.system({ vim.v.progpath, "--headless", "-u", "NONE", "-i", "NONE", "-l", script }, {
        text = true, env = { XDG_CACHE_HOME = run_root .. "/cache", XDG_STATE_HOME = run_root .. "/state",
          NVIM_LOG_FILE = run_root .. "/startup.log", NVIM_UE_LOG_DIR = run_root .. "/ue-logs",
          NVIM_UE_PROBE_PATH = run_root .. "/probes.json" },
      }):wait(15000)
      t.assert_eq(result.code, 0, "native child: " .. (result.stderr or ""))
      t.assert_contains(result.stdout or "", "NATIVE_LAYOUT_OK")
    end)
  end
end)
