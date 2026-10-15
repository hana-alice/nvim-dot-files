local t = require("tests.harness")
local cfg = t.bootstrap()
local installed = vim.fn.stdpath("data") .. "/lazy"

for _, plugin in ipairs({ "lazy.nvim", "LazyVim", "trouble.nvim", "snacks.nvim" }) do
  if vim.fn.isdirectory(installed .. "/" .. plugin) == 0 then
    t.skip("ide_problem_navigation: installed runtime", "Missing installed plugin: " .. plugin, { native = true })
    return
  end
end

-- Load the real LazyVim keymap lifecycle and the real Lazy merged Trouble spec.
-- The bounded runtime omits unrelated project autocmds and UE setup, so these
-- synthetic files cannot start a project indexer or use the user's UE cache.
local function native(code)
  local dir = assert(vim.env.NVIM_TEST_RUN_ROOT) .. "/problem-navigation-" .. tostring(vim.uv.hrtime())
  vim.fn.mkdir(dir, "p")
  local script = dir .. "/case.lua"
  local setup = string.format(
    [[
local cfg, installed, root = %q, %q, %q
local api = vim.api
vim.g.mapleader, vim.g.maplocalleader = ' ', ' '
vim.g.started_with_stdin, vim.g.lazyvim_check_order = true, false
vim.o.hidden, vim.o.swapfile, vim.o.shada = true, false, ''
vim.go.loadplugins = true -- -u NONE disables the actual Lazy startup otherwise.
api.nvim_set_current_dir(root)
vim.opt.rtp:prepend(cfg)
vim.opt.rtp:append(installed .. '/lazy.nvim')
vim.opt.rtp:append(installed .. '/LazyVim')
vim.opt.rtp:append(installed .. '/snacks.nvim')
package.path = cfg .. '/lua/?.lua;' .. cfg .. '/lua/?/init.lua;' .. package.path
assert(vim.fs.normalize(vim.fn.stdpath('data')):find(vim.fs.normalize(root), 1, true))
_G.Snacks = require('snacks')
local base
for _, spec in ipairs(dofile(installed .. '/LazyVim/lua/lazyvim/plugins/editor.lua')) do
  if spec[1] == 'folke/trouble.nvim' then base = spec end
end
assert(base, 'installed LazyVim Trouble spec missing')
base.dir = installed .. '/trouble.nvim'
base.lazy = true
local override = dofile(cfg .. '/lua/plugins/sidebar.lua')[1]
require('lazy').setup({
  spec = {base, override},
  root = root .. '/lazy',
  lockfile = root .. '/lazy-lock.json',
  local_spec = false,
  install = {missing = false},
  checker = {enabled = false},
  change_detection = {enabled = false},
  rocks = {enabled = false},
  pkg = {enabled = false},
})
-- Do not load config.autocmds: only the actual keymap load path is under test.
package.loaded['config.autocmds'] = true
require('lazyvim.config').setup({
  colorscheme = 'habamax',
  news = {lazyvim = false, neovim = false},
  defaults = {autocmds = false, keymaps = true},
})
local notices = {}
vim.notify = function(message, level)
  notices[#notices + 1] = {message = tostring(message), level = level}
end
local function mapping(key)
  local value = vim.fn.maparg(key, 'n', false, true)
  assert(type(value.callback) == 'function', 'missing callback: ' .. key)
  return value
end
local function assert_maps()
  assert(mapping(']q').desc == 'Next quickfix result', vim.inspect(mapping(']q')))
  assert(mapping('[q').desc == 'Previous quickfix result', vim.inspect(mapping('[q')))
end
local function lifecycle(early)
  assert(not package.loaded['config.keymaps'], 'keymaps loaded before lifecycle')
  assert(not require('lazy.core.config').plugins['trouble.nvim']._.loaded)
  if early then
    dofile(cfg .. '/lua/config/keymaps.lua')
    assert_maps()
  end
  api.nvim_exec_autocmds('UIEnter', {modeline = false})
  api.nvim_exec_autocmds('User', {pattern = 'VeryLazy', modeline = false})
  assert(package.loaded['config.keymaps'], 'real VeryLazy did not load root keymaps')
  assert_maps()
  assert(not require('lazy.core.config').plugins['trouble.nvim']._.loaded,
    'quickfix keymaps must not eagerly load Trouble')
  local before = {mapping(']q').callback, mapping('[q').callback}
  require('lazy').load({plugins = {'trouble.nvim'}})
  assert(require('lazy.core.config').plugins['trouble.nvim']._.loaded)
  assert_maps()
  assert(mapping(']q').callback == before[1] and mapping('[q').callback == before[2],
    'lazy.load Trouble replaced the project quickfix callbacks')
end
local function keys(text)
  api.nvim_feedkeys(api.nvim_replace_termcodes(text, true, false, true), 'xt', false)
end
local function fixture()
  local original = api.nvim_get_current_buf()
  local files = {}
  for _, name in ipairs({'BuildA', 'BuildB', 'Other'}) do
    local path = root .. '/' .. name .. '.txt'
    vim.fn.writefile({'one', 'two', 'three', 'four', 'five', 'six'}, path)
    local buf = vim.fn.bufadd(path)
    vim.fn.bufload(buf)
    vim.bo[buf].buflisted = true
    files[name] = buf
  end
  vim.bo[original].buflisted = false
  api.nvim_set_current_buf(files.BuildA)
  local win = api.nvim_get_current_win()
  vim.fn.setqflist({}, ' ', {title = 'Fixture build errors', items = {
    {bufnr = files.BuildA, lnum = 2, col = 1, type = 'E', text = 'first error'},
    {bufnr = files.BuildB, lnum = 3, col = 1, type = 'E', text = 'second error'},
    {bufnr = files.Other, lnum = 4, col = 1, type = 'E', text = 'third error'},
    {bufnr = files.BuildA, lnum = 5, col = 1, type = 'W', text = 'warning'},
    {bufnr = files.BuildB, lnum = 6, col = 1, type = 'W', text = 'last warning'},
  }})
  vim.cmd.cfirst()
  return files, win, vim.fn.getqflist({id = 0, items = 0, title = 0})
end
local function assert_list(expected, idx)
  local actual = vim.fn.getqflist({id = 0, items = 0, title = 0, idx = 0})
  assert(actual.id == expected.id and actual.title == expected.title, 'quickfix owner changed')
  assert(vim.deep_equal(actual.items, expected.items), 'quickfix contents changed')
  assert(actual.idx == idx, 'quickfix index: ' .. actual.idx .. ' expected: ' .. idx)
end
local function assert_location(buf, row)
  assert(api.nvim_get_current_buf() == buf, 'jumped to unrelated buffer')
  assert(api.nvim_win_get_cursor(0)[1] == row, 'wrong source line')
end
local function buffers_sidebar(win)
  local view = assert(require('trouble').open('ue_sidebar_buffers'))
  assert(vim.wait(3000, function()
    return #require('trouble').get_items({mode = 'ue_sidebar_buffers'}) >= 3
  end, 10), 'actual buffers Trouble did not populate: count=' .. view:count()
    .. ' notices=' .. vim.inspect(notices))
  assert(require('trouble').is_open({mode = 'ue_sidebar_buffers'}))
  api.nvim_set_current_win(win)
end
]],
    cfg,
    installed,
    dir
  )
  local body = setup
    .. "\nlocal ok, err = xpcall(function()\n"
    .. code
    .. [[
end, debug.traceback)
if not ok then
  io.stderr:write(tostring(err) .. '\n')
  vim.cmd('cquit 1')
else
  print('PROBLEM_NAVIGATION_NATIVE_OK')
  vim.cmd('qa!')
end
]]
  vim.fn.writefile(vim.split(body, "\n", { plain = true }), script)
  local result = vim
    .system({ vim.v.progpath, "--headless", "-u", "NONE", "-i", "NONE", "-n", "-l", script }, {
      text = true,
      timeout = 15000,
      env = {
        XDG_DATA_HOME = dir .. "/data",
        XDG_STATE_HOME = dir .. "/state",
        XDG_CACHE_HOME = dir .. "/cache",
        NVIM_UE_PROBE_PATH = dir .. "/probes.json",
        NVIM_UE_LOG_DIR = dir .. "/logs",
        NVIM_LOG_FILE = dir .. "/nvim.log",
      },
    })
    :wait()
  vim.fn.delete(dir, "rf")
  local output = (result.stdout or "") .. (result.stderr or "")
  t.assert_eq(result.code, 0, output)
  t.assert_contains(output, "PROBLEM_NAVIGATION_NATIVE_OK")
end

t.describe("ide_problem_navigation: installed Trouble and native quickfix", function()
  for _, entry in ipairs({ "quickfix", "location", "trouble" }) do
    t.it("debug " .. entry .. " switches to normal and preserves the owned source", function()
      native(string.format([[
        lifecycle(false)
        local files,owner,list=fixture()
        local tab=api.nvim_get_current_tabpage()
        local original,cursor=api.nvim_win_get_buf(owner),api.nvim_win_get_cursor(owner)
        local layout=require('utils.layout')
        local token={}
        layout.register_group('debug',{tab=tab,token=token,main=owner})
        layout.register(owner,'code',{owner='debug'})
        local entry=%q
        if entry=='quickfix' then
          keys(']q')
          assert_list(list,2)
        elseif entry=='location' then
          vim.fn.setloclist(owner,{},' ',{items={{bufnr=files.BuildB,lnum=3,col=1}}})
          local id=vim.fn.getloclist(owner,{id=0}).id
          vim.cmd.lopen()
          keys('<CR>')
          assert(vim.fn.getloclist(owner,{id=0}).id==id)
        else
          local view=assert(require('trouble').open('ue_sidebar_qflist'))
          assert(vim.wait(3000,function() return view.win:valid() end,10))
          view.opts.keys['<cr>'].action(view,{item={buf=files.BuildB,pos={3,0},filename=api.nvim_buf_get_name(files.BuildB)}})
        end
        assert(api.nvim_get_current_tabpage()~=tab)
        assert_location(files.BuildB,3)
        assert(api.nvim_win_get_buf(owner)==original and vim.deep_equal(api.nvim_win_get_cursor(owner),cursor))
        assert(layout.navigation_owner(tab)==token)
      ]],entry))
    end)
  end
  for _, early in ipairs({ false, true }) do
    t.it((early and "early keymap load" or "normal VeryLazy load") .. " survives first Trouble load", function()
      native(("lifecycle(%s)\n"):format(tostring(early)) .. [[
        local files, win, list = fixture()
        buffers_sidebar(win)
        keys(']q')
        assert_location(files.BuildB, 3)
        assert_list(list, 2)
        keys('[q')
        assert_location(files.BuildA, 2)
        assert_list(list, 1)
        assert(require('trouble').is_open({mode = 'ue_sidebar_buffers'}))
      ]])
    end)
  end

  t.it("native mapping counts advance the current list while an unrelated sidebar remains open", function()
    native([[
      lifecycle(false)
      local files, win, list = fixture()
      buffers_sidebar(win)
      keys('2]q')
      assert_location(files.Other, 4)
      assert_list(list, 3)
      keys('2[q')
      assert_location(files.BuildA, 2)
      assert_list(list, 1)
      assert(require('trouble').is_open({mode = 'ue_sidebar_buffers'}))
    ]])
  end)

  t.it("a later search list becomes the explicit quickfix owner without changing the saved build list", function()
    native([[
      lifecycle(false)
      local files, win, build = fixture()
      buffers_sidebar(win)
      vim.fn.setqflist({}, ' ', {title = 'Fixture search results', items = {
        {bufnr = files.Other, lnum = 1, col = 1, text = 'search first'},
        {bufnr = files.BuildA, lnum = 6, col = 1, text = 'search second'},
      }})
      vim.cmd.cfirst()
      local search = vim.fn.getqflist({id = 0, items = 0, title = 0})
      assert(search.id ~= build.id)
      keys(']q')
      assert_location(files.BuildA, 6)
      assert_list(search, 2)
      local saved = vim.fn.getqflist({id = build.id, items = 0, title = 0})
      assert(vim.deep_equal(saved.items, build.items) and saved.title == build.title)
      vim.cmd.colder()
      vim.cmd.cfirst()
      keys(']q')
      assert_location(files.BuildB, 3)
      assert_list(build, 2)
    ]])
  end)

  t.it("list boundaries and an empty list report warnings without changing buffers, positions or entries", function()
    native([[
      lifecycle(false)
      local files, win, list = fixture()
      buffers_sidebar(win)
      local function rejected(key, idx)
        local buf, cursor, count = api.nvim_get_current_buf(), api.nvim_win_get_cursor(0), #notices
        keys(key)
        assert(api.nvim_get_current_buf() == buf and vim.deep_equal(api.nvim_win_get_cursor(0), cursor),
          'failed navigation moved the editor')
        assert_list(list, idx)
        assert(#notices == count + 1 and notices[#notices].level == vim.log.levels.WARN,
          'failed navigation did not report one warning')
      end
      rejected('[q', 1)
      vim.cmd.clast()
      rejected(']q', 5)
      vim.fn.setqflist({}, ' ', {title = 'Fixture empty list', items = {}})
      list = vim.fn.getqflist({id = 0, items = 0, title = 0})
      rejected(']q', 0)
      rejected('[q', 0)
      assert_location(files.BuildB, 6)
    ]])
  end)

  t.it("review quickfix Enter and counted navigation keep list ID and auxiliary panes", function()
    native([[
      lifecycle(false)
      local files, owner, list = fixture()
      local original = api.nvim_win_get_buf(owner)
      vim.cmd('vsplit')
      local aux = api.nvim_get_current_win()
      api.nvim_win_set_buf(aux, files.BuildB)
      local tab = api.nvim_get_current_tabpage()
      local session={original_win=owner,modified_win=aux}
      package.loaded['codediff.ui.lifecycle'] = {get_session=function(t)
        if t == tab then return session end
      end}
      api.nvim_set_current_win(owner)
      vim.o.switchbuf='useopen,usetab,uselast'
      keys(']q')
      local code = api.nvim_get_current_win()
      assert(code ~= owner and code ~= aux)
      assert(api.nvim_win_get_tabpage(code)~=tab and #api.nvim_tabpage_list_wins(tab)==2)
      assert_location(files.BuildB,3)
      assert_list(list,2)
      assert(api.nvim_win_get_buf(owner)==original and api.nvim_win_get_buf(aux)==files.BuildB)
      local cursor=api.nvim_win_get_cursor(aux)
      api.nvim_set_current_win(owner)
      vim.cmd.copen()
      local panel=api.nvim_get_current_win()
      assert(vim.wo[panel].winfixbuf)
      api.nvim_win_set_cursor(panel,{4,0})
      keys('<CR>')
      assert(api.nvim_get_current_win()==code)
      assert_location(files.BuildA,5)
      assert_list(list,4)
      assert(vim.deep_equal(api.nvim_win_get_cursor(aux),cursor))
      assert(vim.o.switchbuf=='useopen,usetab,uselast')
      keys('2[q')
      assert_location(files.BuildB,3)
      assert_list(list,2)
      keys('100]q')
      assert_location(files.BuildB,6)
      assert_list(list,5)
      keys('100[q')
      assert_location(files.BuildA,2)
      assert_list(list,1)
    ]])
  end)

  t.it("review quickfix boundaries do not create a browser or move focus", function()
    native([[
      lifecycle(false)
      local files, owner, list=fixture()
      vim.cmd('vsplit')
      local aux=api.nvim_get_current_win()
      local tab=api.nvim_get_current_tabpage()
      local session={original_win=owner,modified_win=aux}
      package.loaded['codediff.ui.lifecycle']={get_session=function(t)
        if t==tab then return session end
      end}
      api.nvim_set_current_win(owner)
      local n=#api.nvim_tabpage_list_wins(tab)
      keys('[q')
      assert(api.nvim_get_current_win()==owner and #api.nvim_tabpage_list_wins(tab)==n)
      assert_list(list,1)
      vim.fn.setqflist({},' ',{items={}})
      keys(']q')
      assert(api.nvim_get_current_win()==owner and #api.nvim_tabpage_list_wins(tab)==n)
    ]])
  end)

  t.it("review loclist Enter keeps owner and ID and supports pattern and virtual columns", function()
    native([[
      lifecycle(false)
      local files, owner=fixture()
      api.nvim_buf_set_lines(files.BuildA,0,-1,false,{'one','\tvalue','  match here','last'})
      vim.bo[files.BuildA].modified=false
      local before=api.nvim_win_get_cursor(owner)
      vim.cmd('vsplit')
      local aux=api.nvim_get_current_win()
      local tab=api.nvim_get_current_tabpage()
      local session={original_win=owner,modified_win=aux}
      package.loaded['codediff.ui.lifecycle']={get_session=function(t)
        if t==tab then return session end
      end}
      vim.fn.setloclist(owner,{},' ',{title='Owned locations',items={
        {bufnr=files.BuildA,lnum=2,col=9,vcol=1,text='tabbed'},
        {bufnr=files.BuildA,pattern='^  match here$',text='pattern'},
        {bufnr=files.BuildA,lnum=0,col=0,valid=0,text='invalid but file'},
      }})
      local list=vim.fn.getloclist(owner,{id=0,items=0})
      api.nvim_set_current_win(owner)
      vim.cmd.lopen()
      local panel=api.nvim_get_current_win()
      assert(vim.wo[panel].winfixbuf)
      api.nvim_win_set_cursor(panel,{1,0})
      keys('<CR>')
      local code=api.nvim_get_current_win()
      assert(code~=owner and code~=aux)
      assert(api.nvim_win_get_tabpage(code)~=tab)
      assert_location(files.BuildA,2)
      assert(api.nvim_win_get_cursor(code)[2]==1)
      assert(vim.deep_equal(api.nvim_win_get_cursor(owner),before))
      api.nvim_set_current_win(panel)
      api.nvim_win_set_cursor(panel,{2,0})
      keys('<CR>')
      assert(api.nvim_get_current_win()==code)
      assert_location(files.BuildA,3)
      local actual=api.nvim_win_call(panel,function() return vim.fn.getloclist(panel,{id=0,idx=0,items=0,filewinid=0}) end)
      assert(actual.id==list.id and actual.idx==2 and actual.filewinid==owner)
      assert(vim.deep_equal(actual.items,list.items))
      assert(vim.fn.getloclist(code,{id=0}).id~=list.id,'normal window must not share the native owner list ID')
      assert(vim.deep_equal(api.nvim_win_get_cursor(owner),before))
      api.nvim_set_current_win(panel)
      api.nvim_win_set_cursor(panel,{3,0})
      keys('<CR>')
      assert_location(files.BuildA,3)
      assert(api.nvim_win_get_cursor(code)[2]==2,'native invalid-file entry must move to first nonblank')
      actual=api.nvim_win_call(panel,function() return vim.fn.getloclist(panel,{id=0,idx=0,filewinid=0}) end)
      assert(actual.idx==3 and actual.id==list.id and actual.filewinid==owner)
    ]])
  end)

  t.it("loclist native and protected Enter agree on invalid entries and byte columns", function()
    native([[
      lifecycle(false)
      local files, owner=fixture()
      local items={
        {bufnr=files.BuildA,lnum=3,col=4,text='byte'},
        {bufnr=files.BuildA,lnum=0,col=0,valid=0,text='invalid file'},
        {valid=0,text='message only'},
        {bufnr=files.BuildA,pattern='unmatched-location-pattern',text='missing pattern'},
      }
      api.nvim_buf_set_lines(files.BuildA,0,-1,false,{'one','two','  three','four'})
      vim.bo[files.BuildA].modified=false
      vim.fn.setloclist(owner,{},' ',{items=items})
      local expected={}
      for row=1,4 do
        vim.cmd.ll({count=row})
        expected[row]=api.nvim_win_get_cursor(owner)
      end
      local before=api.nvim_win_get_cursor(owner)
      vim.cmd('vsplit')
      local aux=api.nvim_get_current_win()
      local tab=api.nvim_get_current_tabpage()
      local session={original_win=owner,modified_win=aux}
      package.loaded['codediff.ui.lifecycle']={get_session=function(t)
        if t==tab then return session end
      end}
      api.nvim_set_current_win(owner)
      vim.cmd.lopen()
      local panel=api.nvim_get_current_win()
      local id=vim.fn.getloclist(panel,{id=0}).id
      local code
      for row=1,4 do
        api.nvim_set_current_win(panel)
        api.nvim_win_set_cursor(panel,{row,0})
        keys('<CR>')
        if row~=3 then code=api.nvim_get_current_win() end
        assert(vim.deep_equal(api.nvim_win_get_cursor(code),expected[row]),vim.inspect({row,expected[row],api.nvim_win_get_cursor(code)}))
        local list=api.nvim_win_call(panel,function() return vim.fn.getloclist(panel,{id=0,idx=0,filewinid=0}) end)
        assert(list.idx==row and list.id==id and list.filewinid==owner)
        assert(vim.deep_equal(api.nvim_win_get_cursor(owner),before))
        if row==3 then assert(api.nvim_get_current_win()==panel,'message-only entry must stay in list') end
      end
    ]])
  end)

  for _, mode in ipairs({'ue_sidebar_buffers','ue_sidebar_qflist','ue_sidebar_loclist',
    'ue_sidebar_diagnostics','ue_sidebar_symbols','ue_sidebar_todo','ue_qflist_bottom'}) do
    t.it("review Trouble " .. mode .. " routes existing aux target despite foreign main", function()
      native(string.format([[
        lifecycle(false)
        local files, owner=fixture()
        vim.cmd('vsplit')
        local aux=api.nvim_get_current_win()
        api.nvim_win_set_buf(aux,files.BuildB)
        local tab=api.nvim_get_current_tabpage()
        local foreign
        vim.cmd('tabnew')
        foreign=api.nvim_get_current_win()
        require('trouble.view.main').set({win=foreign,buf=api.nvim_get_current_buf(),cursor={1,0},filename=''})
        api.nvim_set_current_tabpage(tab)
        local session={original_win=owner,modified_win=aux}
        package.loaded['codediff.ui.lifecycle']={get_session=function(t)
          if t==tab then return session end
        end}
        local view=assert(require('trouble').open(%q))
        assert(vim.wait(3000,function() return view.win:valid() end,10))
        local main=require('trouble.view.main')
        main.set({win=foreign,buf=api.nvim_win_get_buf(foreign),cursor={1,0},filename=''})
        local item={buf=files.BuildB,pos={3,0},filename=api.nvim_buf_get_name(files.BuildB)}
        view.opts.keys['<cr>'].action(view,{item=item})
        local code=api.nvim_get_current_win()
        assert(code~=owner and code~=aux and api.nvim_win_get_tabpage(code)~=tab)
        assert_location(files.BuildB,3)
        assert(vim.wo[view.win.win].winfixbuf)
        assert(api.nvim_win_get_buf(owner)==files.BuildA and api.nvim_win_get_buf(aux)==files.BuildB)
      ]],mode))
    end)
  end

  t.it("Trouble custom jump keys preserve close and split with a nowrite browser", function()
    native([[
      lifecycle(false)
      local files,owner=fixture()
      vim.cmd('vsplit')
      local aux=api.nvim_get_current_win()
      local tab=api.nvim_get_current_tabpage()
      local session={original_win=owner,modified_win=aux}
      package.loaded['codediff.ui.lifecycle']={get_session=function(t) if t==tab then return session end end}
      local layout=require('utils.layout')
      local browser=assert(layout.resolve({tab=tab,source_win=owner}))
      local revision=api.nvim_create_buf(false,true)
      vim.bo[revision].buftype='nowrite'
      api.nvim_win_set_buf(browser,revision)
      local normal_tab=api.nvim_win_get_tabpage(browser)
      for _,key in ipairs({'<cr>','<2-leftmouse>','<c-s>','<c-v>','o'}) do
        api.nvim_set_current_win(owner)
        local view=assert(require('trouble').open('ue_sidebar_qflist'))
        assert(vim.wait(3000,function() return view.win:valid() end,10))
        local before=#api.nvim_tabpage_list_wins(normal_tab)
        view.opts.keys[key].action(view,{item={buf=files.BuildB,pos={3,0},filename=api.nvim_buf_get_name(files.BuildB)}})
        assert_location(files.BuildB,3)
        assert(api.nvim_get_current_win()~=owner and api.nvim_get_current_win()~=aux)
        if key=='<c-s>' or key=='<c-v>' then
          assert(#api.nvim_tabpage_list_wins(normal_tab)==before+1,'split key did not preserve native split in normal tab')
        elseif key=='o' then
          assert(not view.win:valid(),'jump_close did not close Trouble')
        end
        if view.win:valid() then view:close() end
      end
      assert(api.nvim_win_get_buf(owner)==files.BuildA and api.nvim_win_get_buf(aux)==files.BuildA)
    ]])
  end)

  t.it("quickfix focus callbacks changing list ownership cancel the protected jump", function()
    native([[
      lifecycle(false)
      local files,owner,list=fixture()
      vim.cmd('vsplit')
      local aux=api.nvim_get_current_win()
      local tab=api.nvim_get_current_tabpage()
      local session={original_win=owner,modified_win=aux}
      package.loaded['codediff.ui.lifecycle']={get_session=function(t) if t==tab then return session end end}
      local code=assert(require('utils.layout').resolve({tab=tab,source_win=owner}))
      local before=api.nvim_win_get_buf(code)
      api.nvim_set_current_win(owner)
      local fired=false
      api.nvim_create_autocmd('WinEnter',{callback=function()
        if api.nvim_get_current_win()==code and not fired then
          fired=true
          vim.fn.setqflist({},' ',{title='New owner during focus',items={{bufnr=files.Other,lnum=6,col=1}}})
        end
      end})
      keys(']q')
      assert(fired and api.nvim_win_get_buf(code)==before,'new list navigated with stale request')
      assert(vim.fn.getqflist({id=0}).id~=list.id)
    ]])
  end)

  t.it("quickfix navigation keeps native advancement when every entry is invalid", function()
    native([[
      lifecycle(false)
      local files,owner=fixture()
      vim.fn.setqflist({},' ',{items={
        {bufnr=files.BuildA,lnum=1,col=1,valid=0},
        {bufnr=files.BuildB,lnum=3,col=1,valid=0},
      }})
      vim.cmd.cc({count=1})
      vim.cmd.cnext()
      local expected=vim.fn.getqflist({id=0,idx=0,items=0,title=0})
      vim.cmd.cc({count=1})
      vim.cmd('vsplit')
      local aux=api.nvim_get_current_win()
      local tab=api.nvim_get_current_tabpage()
      local session={original_win=owner,modified_win=aux}
      package.loaded['codediff.ui.lifecycle']={get_session=function(t) if t==tab then return session end end}
      api.nvim_set_current_win(owner)
      keys(']q')
      assert_location(files.BuildB,3)
      assert_list(expected,expected.idx)
    ]])
  end)

  t.it("loclist BufEnter replacement cancels positioning and keeps native owner and list ID", function()
    native([[
      lifecycle(false)
      local files,owner=fixture()
      vim.cmd('vsplit')
      local aux=api.nvim_get_current_win()
      local tab=api.nvim_get_current_tabpage()
      local session={original_win=owner,modified_win=aux}
      package.loaded['codediff.ui.lifecycle']={get_session=function(t) if t==tab then return session end end}
      local code=assert(require('utils.layout').resolve({tab=tab,source_win=owner}))
      local replacement=api.nvim_create_buf(true,false)
      api.nvim_buf_set_lines(replacement,0,-1,false,{'new selection','second','third','fourth'})
      vim.fn.setloclist(owner,{},' ',{items={{bufnr=files.BuildB,lnum=3,col=5}}})
      local before=vim.fn.getloclist(owner,{id=0,items=0})
      api.nvim_set_current_win(owner)
      vim.cmd.lopen()
      local panel=api.nvim_get_current_win()
      local fired=false
      api.nvim_create_autocmd('BufEnter',{buffer=files.BuildB,callback=function()
        if not fired and api.nvim_get_current_win()==code then
          fired=true
          api.nvim_set_current_buf(replacement)
          api.nvim_win_set_cursor(code,{1,0})
        end
      end})
      assert(require('utils.problem_navigation').enter()==false,'cancelled action must report false')
      assert(fired and api.nvim_get_current_win()==code and api.nvim_win_get_buf(code)==replacement)
      assert(vim.deep_equal(api.nvim_win_get_cursor(code),{1,0}),'old loclist cursor overwrote new work')
      local actual=api.nvim_win_call(panel,function() return vim.fn.getloclist(panel,{id=0,idx=0,items=0,filewinid=0}) end)
      assert(actual.id==before.id and actual.idx==1 and actual.filewinid==owner)
      assert(vim.deep_equal(actual.items,before.items),'native list contents changed')
      assert(api.nvim_win_get_buf(owner)==files.BuildA and api.nvim_win_get_buf(aux)==files.BuildA)
    ]])
  end)

  t.it("loclist focus callbacks rewriting the same ID cancel stale destination content", function()
    native([[
      lifecycle(false)
      local files,owner=fixture()
      vim.cmd('vsplit')
      local aux=api.nvim_get_current_win()
      local tab=api.nvim_get_current_tabpage()
      local session={original_win=owner,modified_win=aux}
      package.loaded['codediff.ui.lifecycle']={get_session=function(t) if t==tab then return session end end}
      local code=assert(require('utils.layout').resolve({tab=tab,source_win=owner}))
      local before=api.nvim_win_get_buf(code)
      vim.fn.setloclist(owner,{},' ',{items={{bufnr=files.BuildB,lnum=3,col=1}}})
      local id=vim.fn.getloclist(owner,{id=0}).id
      api.nvim_set_current_win(owner)
      vim.cmd.lopen()
      local panel=api.nvim_get_current_win()
      local fired=false
      api.nvim_create_autocmd('WinEnter',{callback=function()
        if api.nvim_get_current_win()==code and not fired then
          fired=true
          vim.fn.setloclist(owner,{},'r',{id=id,items={{bufnr=files.Other,lnum=6,col=1}}})
        end
      end})
      keys('<CR>')
      assert(fired and api.nvim_win_get_buf(code)==before,'same-ID replacement list navigated')
      assert(api.nvim_win_call(panel,function() return vim.fn.getloclist(panel,{id=0,filewinid=0}).filewinid end)==owner)
      assert(api.nvim_win_get_buf(owner)==files.BuildA and api.nvim_win_get_buf(aux)==files.BuildA)
    ]])
  end)

  for _, mutation in ipairs({'tab','source','role'}) do
    t.it("Trouble target BufReadPost " .. mutation .. " changes cancel before native window replacement", function()
      native(string.format([[
        lifecycle(false)
        local files,owner=fixture()
        vim.cmd('vsplit')
        local aux=api.nvim_get_current_win()
        local tab=api.nvim_get_current_tabpage()
        local session={original_win=owner,modified_win=aux}
        package.loaded['codediff.ui.lifecycle']={get_session=function(t) if t==tab then return session end end}
        local layout=require('utils.layout')
        local code=assert(layout.resolve({tab=tab,source_win=owner}))
        local before=api.nvim_win_get_buf(code)
        vim.cmd('tabnew')
        local foreign=api.nvim_get_current_win()
        api.nvim_set_current_tabpage(tab)
        local view=assert(require('trouble').open('ue_sidebar_qflist'))
        assert(vim.wait(3000,function() return view.win:valid() end,10))
        local source=view.win.win
        local path=root..'/TroubleUnread.txt'
        vim.fn.writefile({'unread target','second line'},path)
        local mutation=%q
        local fired=false
        local replacement=api.nvim_create_buf(false,true)
        api.nvim_create_autocmd('BufReadPost',{pattern=path,callback=function()
          fired=true
          if mutation=='tab' then
            api.nvim_set_current_win(foreign)
          elseif mutation=='source' then
            vim.wo[source].winfixbuf=false
            api.nvim_win_set_buf(source,replacement)
            vim.wo[source].winfixbuf=true
          else
            layout.register(code,'aux',{owner='new destination owner'})
          end
        end})
        local count=#notices
        view.opts.keys['<cr>'].action(view,{item={filename=path,pos={2,0}}})
        assert(fired,'actual installed Trouble did not load target')
        assert(api.nvim_win_get_buf(code)==before,'stale Trouble target replaced code')
        assert(api.nvim_win_get_buf(owner)==files.BuildA and api.nvim_win_get_buf(aux)==files.BuildA)
        assert(#notices==count+1 and notices[#notices].level==vim.log.levels.WARN)
        if mutation=='tab' then assert(api.nvim_get_current_win()==foreign,'cancellation stole new tab focus') end
        if mutation=='source' then assert(api.nvim_win_get_buf(source)==replacement,'cancellation revived old source') end
        for _,autocmd in ipairs(api.nvim_get_autocmds({event={'TabEnter','WinEnter','BufReadPost'}})) do
          assert(autocmd.desc~='Problem navigation target-load intent','load intent watcher leaked')
        end
      ]],mutation))
    end)
  end
end)
