local t = require("tests.harness")
local cfg = t.bootstrap()
local plugin = vim.fn.stdpath("data") .. "/lazy/snacks.nvim"

local function native(code)
  local dir = vim.fn.tempname() .. "-file-mutations"
  vim.fn.mkdir(dir, "p")
  local script = dir .. "/case.lua"
  local setup = string.format(
    [[
    local cfg, plugin, root = %q, %q, %q
    vim.opt.rtp:prepend(cfg)
    vim.opt.rtp:append(plugin)
    package.path = cfg .. '/lua/?.lua;' .. cfg .. '/lua/?/init.lua;' .. package.path
    vim.o.hidden, vim.o.swapfile, vim.o.shada = true, false, ''
    vim.api.nvim_set_current_dir(root)
    local m, uv, api = require('utils.file_mutations'), vim.uv, vim.api
    local function file(path, text)
      vim.fn.mkdir(vim.fs.dirname(path), 'p')
      vim.fn.writefile({text or 'original'}, path)
      return path
    end
    local function load(path)
      local buf = vim.fn.bufadd(path)
      vim.fn.bufload(buf)
      return buf
    end
    local function await(call)
      local result
      call(function(ok, reason, changed) result = {ok=ok, reason=reason, changed=changed} end)
      assert(vim.wait(6000, function() return result ~= nil end, 5), 'mutation timeout')
      return result
    end
  ]],
    cfg,
    plugin,
    dir
  )
  vim.fn.writefile(vim.split(setup .. code, "\n", { plain = true }), script)
  local result = vim
    .system({ vim.v.progpath, "--headless", "-u", "NONE", "-i", "NONE", "-n", "-l", script }, {
      text = true,
      env = {
        XDG_DATA_HOME = dir .. "/data",
        XDG_STATE_HOME = dir .. "/state",
        XDG_CACHE_HOME = dir .. "/cache",
        NVIM_UE_PROBE_PATH = dir .. "/probes.json",
        NVIM_UE_LOG_DIR = dir .. "/logs",
        NVIM_LOG_FILE = dir .. "/nvim.log",
      },
    })
    :wait(10000)
  vim.fn.delete(dir, "rf")
  t.assert_eq(result.code, 0, (result.stdout or "") .. (result.stderr or ""))
end

t.describe("ide_file_mutations: explicit file ownership", function()
  t.it("dirty source is rejected before any filesystem change", function()
    native([[
      local source = file(root .. '/Alpha.cpp')
      local buf = load(source)
      api.nvim_buf_set_lines(buf, 0, -1, false, {'unsaved'})
      local plan, err = m.prepare({source})
      assert(not plan and err == 'source-unsaved')
      assert(api.nvim_buf_get_lines(buf, 0, -1, false)[1] == 'unsaved')
      assert(vim.fn.readfile(source)[1] == 'original')
    ]])
  end)

  t.it("dirty loaded descendant blocks directory rename and delete without a tree scan", function()
    native([[
      local source = file(root .. '/Module/Private/Alpha.cpp')
      local buf = load(source)
      api.nvim_buf_set_lines(buf, 0, -1, false, {'unsaved descendant'})
      for _, kind in ipairs({'rename','delete'}) do
        local plan, err = m.prepare({root .. '/Module'}, {kind=kind})
        assert(not plan and err == 'source-unsaved')
      end
      assert(uv.fs_stat(source) and api.nvim_buf_is_loaded(buf))
    ]])
  end)

  t.it("edited, renamed and newly loaded source buffers revoke the frozen action", function()
    native([[
      local source = file(root .. '/Alpha.cpp')
      local plan = assert(m.prepare({source}))
      local buf = load(source)
      local ok, err = m.validate(plan)
      assert(not ok and err == 'source-buffer-added')
      plan = assert(m.prepare({source}))
      api.nvim_buf_set_lines(buf,0,-1,false,{'new input'})
      ok, err = m.validate(plan)
      assert(not ok and err == 'source-buffer-changed')
      vim.bo[buf].modified=false
      plan = assert(m.prepare({source}))
      api.nvim_buf_set_name(buf, root .. '/Different.cpp')
      assert(not m.validate(plan))
    ]])
  end)

  t.it("native replacement of the source or parent invalidates its disk identity", function()
    native([[
      local source = file(root .. '/Alpha.cpp')
      local plan = assert(m.prepare({source}))
      local replacement = file(root .. '/Replacement.cpp','different object')
      assert(uv.fs_rename(source, root .. '/Original.cpp'))
      assert(uv.fs_rename(replacement, source))
      local ok, err = m.validate(plan)
      assert(not ok and err == 'source-changed')
      assert(vim.fn.readfile(source)[1]=='different object')
    ]])
  end)

  t.it("existing destinations and loaded destination buffers are never replaced", function()
    native([[
      local source = file(root .. '/Alpha.cpp','alpha')
      local target = file(root .. '/Beta.cpp','beta')
      local plan = assert(m.prepare({source}))
      local ok, err = m.targets(plan,{target})
      assert(not ok and err == 'destination-exists')
      assert(vim.fn.readfile(target)[1] == 'beta')
      assert(uv.fs_unlink(target))
      local targetbuf = vim.fn.bufadd(target)
      vim.fn.bufload(targetbuf)
      plan = assert(m.prepare({source}))
      ok, err = m.targets(plan,{target})
      assert(not ok and err == 'destination-buffer-exists')
    ]])
  end)

  t.it("a destination created at the native move boundary cannot be overwritten", function()
    native([[
      local source = file(root .. '/Alpha.cpp','alpha')
      local target = root .. '/Beta.cpp'
      local driver = require('utils.platform').driver()
      local original = assert(driver.rename_no_replace)
      driver.rename_no_replace = function(from,to,done)
        file(to,'arrived at commit')
        original(from,to,done)
      end
      local result = await(function(done) m.rename(assert(m.prepare({source})),{target},done) end)
      assert(not result.ok and uv.fs_stat(source))
      assert(vim.fn.readfile(target)[1] == 'arrived at commit')
      assert(vim.fn.readfile(source)[1] == 'alpha')
    ]])
  end)

  t.it("successful Unicode file rename preserves the same buffers, windows, undo and views", function()
    native([[
      local source = file(root .. '/中文 Alpha.cpp','line one')
      local target = root .. '/中文 Beta.cpp'
      local buf = load(source)
      api.nvim_set_current_buf(buf)
      api.nvim_buf_set_lines(buf,0,-1,false,{'edited then saved','second line'})
      vim.cmd.write()
      local before_undo=vim.fn.undotree().seq_last
      api.nvim_win_set_cursor(0,{2,3})
      local first=api.nvim_get_current_win()
      vim.cmd.vsplit()
      local second=api.nvim_get_current_win()
      local second_view=vim.fn.winsaveview()
      vim.cmd.tabnew()
      api.nvim_set_current_buf(buf)
      local third=api.nvim_get_current_win()
      local result=await(function(done) m.rename(assert(m.prepare({source})),{target},done) end)
      assert(result.ok,result.reason)
      assert(not uv.fs_stat(source) and uv.fs_stat(target))
      assert(api.nvim_buf_is_loaded(buf) and api.nvim_win_get_buf(first)==buf and api.nvim_win_get_buf(second)==buf and api.nvim_win_get_buf(third)==buf)
      assert(require('utils.platform').driver().path_key(uv.fs_realpath(api.nvim_buf_get_name(buf)))==require('utils.platform').driver().path_key(uv.fs_realpath(target)))
      assert(vim.fn.undotree().seq_last==before_undo and not vim.bo[buf].modified)
      assert(api.nvim_win_get_cursor(first)[1]==2)
      assert(api.nvim_win_call(second,vim.fn.winsaveview).topline==second_view.topline)
    ]])
  end)

  t.it("successful directory move retains loaded child buffer identities", function()
    native([[
      local source = file(root .. '/Module/Private/Alpha.cpp','module file')
      local buf = load(source)
      api.nvim_set_current_buf(buf)
      local plan = assert(m.prepare({root .. '/Module'},{kind='move'}))
      local result=await(function(done) m.rename(plan,{root .. '/MovedModule'},done) end)
      assert(result.ok,result.reason)
      assert(api.nvim_buf_get_name(buf):gsub('\\','/'):find('/MovedModule/Private/Alpha.cpp',1,true))
      assert(api.nvim_get_current_buf()==buf and api.nvim_buf_is_loaded(buf) and not vim.bo[buf].modified)
      assert(vim.fn.readfile(root .. '/MovedModule/Private/Alpha.cpp')[1]=='module file')
    ]])
  end)

  t.it("renamed existing documents allow ordinary write without reread or an added undo entry", function()
    native([[
      local source=file(root .. '/Alpha.cpp','original A')
      vim.cmd.edit(vim.fn.fnameescape(source))
      local buf=api.nvim_get_current_buf()
      api.nvim_buf_set_lines(buf,0,-1,false,{'saved revision A','second line'})
      vim.cmd.write()
      local undo=vim.fn.undotree()
      local reads=0
      api.nvim_create_autocmd({'BufReadPre','BufReadPost'},{buffer=buf,callback=function() reads=reads+1 end})
      local target=root .. '/中文 Renamed #1%.cpp'
      local result=await(function(done) m.rename(assert(m.prepare({source})),{target},done) end)
      assert(result.ok,result.reason)
      local after=vim.fn.undotree()
      assert(after.seq_last==undo.seq_last and vim.deep_equal(after.entries,undo.entries),'metadata refresh cannot add undo')
      assert(reads==0,'an existing document must not be reread')
      api.nvim_buf_set_lines(buf,0,-1,false,{'new ordinary saved B','second line'})
      local wrote,err=pcall(vim.cmd.write)
      assert(wrote,err)
      assert(api.nvim_get_current_buf()==buf and not vim.bo[buf].modified)
      assert(vim.fn.readfile(target)[1]=='new ordinary saved B')
    ]])
  end)

  t.it("metadata refresh preserves uneven windows in two tabs and a hidden source", function()
    native([[
      local source=file(root .. '/Alpha.cpp','original A')
      vim.cmd.edit(vim.fn.fnameescape(source))
      local buf=api.nvim_get_current_buf()
      api.nvim_buf_set_lines(buf,0,-1,false,{'saved A','second line','third line'});vim.cmd.write()
      api.nvim_win_set_cursor(0,{3,2})
      vim.cmd.vsplit();vim.cmd('vertical resize 17');vim.cmd.split();vim.cmd('resize 6')
      vim.cmd.tabnew();api.nvim_set_current_buf(buf);vim.cmd.vsplit();vim.cmd('vertical resize 29')
      local origin=api.nvim_get_current_win()
      local before={};local wins,tabs=api.nvim_list_wins(),api.nvim_list_tabpages()
      for _,w in ipairs(wins) do before[w]={buf=api.nvim_win_get_buf(w),width=api.nvim_win_get_width(w),height=api.nvim_win_get_height(w),view=api.nvim_win_call(w,vim.fn.winsaveview)} end
      local result=await(function(done) m.rename(assert(m.prepare({source})),{root .. '/Beta.cpp'},done) end)
      assert(result.ok,result.reason)
      assert(api.nvim_get_current_win()==origin and vim.deep_equal(wins,api.nvim_list_wins()) and vim.deep_equal(tabs,api.nvim_list_tabpages()))
      for w,x in pairs(before) do assert(api.nvim_win_get_buf(w)==x.buf and api.nvim_win_get_width(w)==x.width and api.nvim_win_get_height(w)==x.height and vim.deep_equal(api.nvim_win_call(w,vim.fn.winsaveview),x.view),'original layout and view must survive') end
      local hidden=file(root .. '/Hidden.cpp','hidden A')
      local hiddenbuf=load(hidden)
      local tick=api.nvim_buf_get_changedtick(hiddenbuf)
      result=await(function(done) m.rename(assert(m.prepare({hidden})),{root .. '/HiddenMoved.cpp'},done) end)
      assert(result.ok,result.reason)
      assert(api.nvim_buf_get_changedtick(hiddenbuf)==tick and api.nvim_get_current_win()==origin)
      assert(vim.deep_equal(wins,api.nvim_list_wins()) and vim.deep_equal(tabs,api.nvim_list_tabpages()))
      api.nvim_buf_set_lines(hiddenbuf,0,-1,false,{'hidden saved B'})
      local wrote,err=pcall(api.nvim_buf_call,hiddenbuf,vim.cmd.write);assert(wrote,err)
      assert(vim.fn.readfile(root .. '/HiddenMoved.cpp')[1]=='hidden saved B')
    ]])
  end)

  t.it("a truly hidden wipe-on-hide document retains its identity undo and ordinary save", function()
    native([[
      local source=file(root .. '/HiddenWipeAlpha.cpp','original A')
      vim.cmd.edit(vim.fn.fnameescape(source))
      local buf=api.nvim_get_current_buf()
      api.nvim_buf_set_lines(buf,0,-1,false,{'saved A','second line'});vim.cmd.write()
      local undo=vim.fn.undotree();local tick=api.nvim_buf_get_changedtick(buf)
      vim.cmd.enew();vim.cmd.vsplit();vim.cmd('vertical resize 17');vim.cmd.tabnew()
      vim.bo[buf].bufhidden='wipe'
      assert(#vim.fn.win_findbuf(buf)==0,'the document must truly be hidden')
      local origin=api.nvim_get_current_win();local wins=api.nvim_list_wins();local tabs=api.nvim_list_tabpages()
      local events=0
      local observer=api.nvim_create_autocmd({'WinNew','WinEnter','TabNew','TabEnter','TabNewEntered','BufEnter','WinClosed'},{callback=function() events=events+1 end})
      local result=await(function(done) m.rename(assert(m.prepare({source})),{root .. '/HiddenWipeBeta.cpp'},done) end)
      assert(result.ok,result.reason)
      assert(events==0 and api.nvim_get_current_win()==origin)
      assert(vim.deep_equal(wins,api.nvim_list_wins()) and vim.deep_equal(tabs,api.nvim_list_tabpages()))
      assert(api.nvim_buf_is_valid(buf) and api.nvim_buf_is_loaded(buf) and api.nvim_buf_get_changedtick(buf)==tick)
      assert(vim.bo[buf].bufhidden=='wipe','the user hide policy cannot be changed')
      local after=api.nvim_buf_call(buf,vim.fn.undotree)
      assert(after.seq_last==undo.seq_last and vim.deep_equal(after.entries,undo.entries))
      api.nvim_buf_set_lines(buf,0,-1,false,{'new ordinary B','second line'})
      local wrote,err=pcall(api.nvim_buf_call,buf,vim.cmd.write);assert(wrote,err)
      assert(api.nvim_buf_is_valid(buf) and not vim.bo[buf].modified and vim.fn.readfile(root .. '/HiddenWipeBeta.cpp')[1]=='new ordinary B')
      api.nvim_del_autocmd(observer)
    ]])
  end)

  t.it("internal metadata presentation is silent while real naming and user events stay active", function()
    native([[
      local source=file(root .. '/InternalAlpha.cpp','original A')
      vim.cmd.edit(vim.fn.fnameescape(source))
      local buf=api.nvim_get_current_buf()
      local events={'WinNew','WinEnter','TabNew','TabEnter','TabNewEntered','BufEnter','WinClosed'}
      local counts={};local names={pre=0,post=0}
      local ignore=vim.o.eventignore
      local observer=api.nvim_create_autocmd(events,{callback=function(e) counts[e.event]=(counts[e.event] or 0)+1 end})
      api.nvim_create_autocmd('BufFilePre',{buffer=buf,callback=function() names.pre=names.pre+1 end})
      api.nvim_create_autocmd('BufFilePost',{buffer=buf,callback=function() names.post=names.post+1 end})
      local result=await(function(done) m.rename(assert(m.prepare({source})),{root .. '/InternalBeta.cpp'},done) end)
      assert(result.ok,result.reason)
      for _,event in ipairs(events) do assert(not counts[event],'internal presentation cannot dispatch '..event) end
      assert(names.pre==1 and names.post==1,'real file naming events must remain native')
      assert(vim.o.eventignore==ignore,'global event options must remain unchanged')
      vim.cmd.vsplit();vim.cmd.close();vim.cmd.tabnew();vim.cmd.enew();vim.cmd.tabclose()
      for _,event in ipairs(events) do assert((counts[event] or 0)>0,'real user operation must still dispatch '..event) end
      api.nvim_del_autocmd(observer)
      assert(vim.o.eventignore==ignore)
    ]])
  end)

  t.it("real window events after metadata keep new input layout and chosen focus", function()
    native([[
      for _,event in ipairs({'WinNew','WinEnter','BufEnter','WinClosed'}) do
        vim.cmd('tabonly!');vim.cmd('only!');vim.cmd.enew()
        local source=file(root .. '/'..event..'Alpha.cpp','original A')
        vim.cmd.edit(vim.fn.fnameescape(source))
        local buf=api.nvim_get_current_buf()
        local sourcewin=api.nvim_get_current_win()
        vim.cmd.vsplit();vim.cmd.enew()
        local foreign=api.nvim_get_current_win();local foreignbuf=api.nvim_get_current_buf()
        api.nvim_set_current_win(sourcewin)
        local closewin
        if event=='WinClosed' then vim.cmd.vsplit();closewin=api.nvim_get_current_win();api.nvim_set_current_win(sourcewin) end
        local chosen,saved
        api.nvim_create_autocmd(event,{once=true,nested=true,callback=function()
          api.nvim_buf_set_lines(buf,0,-1,false,{'new B from '..event})
          if event=='BufEnter' then api.nvim_set_current_win(foreign)
          else vim.cmd.vsplit() end
          chosen=api.nvim_get_current_win()
          saved={name=api.nvim_buf_get_name(buf),tick=api.nvim_buf_get_changedtick(buf),modified=vim.bo[buf].modified}
        end})
        local result=await(function(done) m.rename(assert(m.prepare({source})),{root .. '/'..event..'Beta.cpp'},done) end)
        assert(result.ok,result.reason)
        assert(not chosen,'internal metadata must not consume the user '..event..' handler')
        if event=='BufEnter' then api.nvim_set_current_win(foreign)
        elseif event=='WinClosed' then api.nvim_win_close(closewin,false)
        else vim.cmd.vsplit() end
        assert(chosen,'the real user '..event..' handler must remain active')
        assert(api.nvim_get_current_win()==chosen,'new chosen focus must survive '..event)
        assert(api.nvim_buf_is_loaded(buf) and api.nvim_buf_get_name(buf)==saved.name)
        assert(api.nvim_buf_get_changedtick(buf)==saved.tick and vim.bo[buf].modified==saved.modified)
        assert(api.nvim_buf_get_lines(buf,0,-1,false)[1]=='new B from '..event)
        assert(api.nvim_win_is_valid(foreign) and api.nvim_win_get_buf(foreign)==foreignbuf)
        assert(vim.fn.readfile(root .. '/'..event..'Beta.cpp')[1]=='original A')
      end
    ]])
  end)

  t.it("a persistent user WinEnter choice remains active after internal metadata", function()
    native([[
        local source=file(root .. '/ForeignAlpha.cpp','original A')
        vim.cmd.edit(vim.fn.fnameescape(source))
        local buf=api.nvim_get_current_buf();local sourcewin=api.nvim_get_current_win()
        vim.cmd.vsplit();local second=api.nvim_get_current_win()
        vim.cmd.vsplit();vim.cmd.enew()
        local chosen=api.nvim_get_current_win();local chosenbuf=api.nvim_get_current_buf()
        api.nvim_buf_set_lines(chosenbuf,0,-1,false,{'foreign user document'})
        local tick=api.nvim_buf_get_changedtick(chosenbuf)
        api.nvim_set_current_win(sourcewin)
        local calls=0
        local handler=api.nvim_create_autocmd('WinEnter',{nested=true,callback=function()
          if api.nvim_get_current_buf()~=buf then return end
          calls=calls+1;api.nvim_set_current_win(chosen)
        end})
        local result=await(function(done) m.rename(assert(m.prepare({source})),{root .. '/ForeignBeta.cpp'},done) end)
        assert(result.ok,result.reason)
        assert(calls==0,'internal metadata cannot fight or consume a persistent user handler')
        api.nvim_set_current_win(second)
        pcall(api.nvim_del_autocmd,handler)
        assert(calls==1,'the later user WinEnter must execute exactly once')
        assert(api.nvim_win_is_valid(chosen) and api.nvim_win_get_buf(chosen)==chosenbuf)
        assert(api.nvim_get_current_win()==chosen,'foreign selection must not be undone by native context restoration')
        assert(api.nvim_buf_get_changedtick(chosenbuf)==tick and vim.bo[chosenbuf].modified)
        assert(api.nvim_buf_get_lines(chosenbuf,0,-1,false)[1]=='foreign user document')
        assert(api.nvim_buf_get_lines(buf,0,-1,false)[1]=='original A')
    ]])
  end)

  t.it("user WinEnter can still take a window with new text after internal metadata", function()
    native([[
      for _,second in ipairs({false,true}) do
        vim.cmd('tabonly!');vim.cmd('only!');vim.cmd.enew()
        local source=file(root .. '/'..tostring(second)..'Alpha.cpp','original A')
        vim.cmd.edit(vim.fn.fnameescape(source))
        local sourcebuf=api.nvim_get_current_buf()
        local sourcewin=api.nvim_get_current_win()
        vim.cmd.vsplit();local existing=api.nvim_get_current_win();api.nvim_set_current_win(sourcewin)
        local user,chosen,saved,handler
        handler=api.nvim_create_autocmd('WinEnter',{nested=true,callback=function()
          if api.nvim_get_current_buf()~=sourcebuf or user then return end
          user=api.nvim_create_buf(true,false);api.nvim_set_current_buf(user)
          api.nvim_buf_set_lines(user,0,-1,false,{'new user B in taken window'})
          chosen=api.nvim_get_current_win()
          saved={name=api.nvim_buf_get_name(user),tick=api.nvim_buf_get_changedtick(user),modified=vim.bo[user].modified,view=vim.fn.winsaveview()}
        end})
        local result=await(function(done) m.rename(assert(m.prepare({source})),{root .. '/'..tostring(second)..'Beta.cpp'},done) end)
        assert(result.ok,result.reason)
        assert(not user,'internal metadata cannot dispatch a takeover callback')
        if second then vim.cmd.vsplit() else api.nvim_set_current_win(existing) end
        api.nvim_del_autocmd(handler)
        assert(user,'the actual user WinEnter handler must run')
        assert(api.nvim_win_is_valid(chosen) and api.nvim_win_get_buf(chosen)==user,'taken window must keep user document')
        assert(api.nvim_get_current_win()==chosen and api.nvim_buf_get_name(user)==saved.name)
        assert(api.nvim_buf_get_changedtick(user)==saved.tick and vim.bo[user].modified==saved.modified)
        assert(vim.deep_equal(vim.fn.winsaveview(),saved.view),'new user view must remain after the user operation')
        assert(api.nvim_buf_get_lines(user,0,-1,false)[1]=='new user B in taken window')
        assert(vim.fn.readfile(root .. '/'..tostring(second)..'Beta.cpp')[1]=='original A')
      end
    ]])
  end)

  t.it("dirty edits during an async move stay loaded and produce a review receipt", function()
    native([[
      local source = file(root .. '/Alpha.cpp')
      local buf = load(source)
      local driver = require('utils.platform').driver()
      local original = assert(driver.rename_no_replace)
      driver.rename_no_replace=function(from,to,done)
        original(from,to,function(ok,err)
          api.nvim_buf_set_lines(buf,0,-1,false,{'arrived during native operation'})
          done(ok,err)
        end)
      end
      local result=await(function(done) m.rename(assert(m.prepare({source})),{root .. '/Beta.cpp'},done) end)
      assert(not result.ok and m.last().state=='needs-review')
      assert(api.nvim_buf_is_loaded(buf) and vim.bo[buf].modified)
      assert(api.nvim_buf_get_lines(buf,0,-1,false)[1]=='arrived during native operation')
      assert(uv.fs_stat(root .. '/Beta.cpp'))
    ]])
  end)

  t.it("async LSP edits require a preview and never apply themselves", function()
    native([[
      local source=file(root .. '/Alpha.cpp','alpha')
      local requested,applied=false,false
      local client={id=47,request=function(_,method,params,done)
        requested=method=='workspace/willRenameFiles'
        vim.defer_fn(function() done(nil,{changes={[params.files[1].oldUri]={{newText='wrong'}}}}) end,20)
        return true,91
      end,cancel_request=function() end}
      vim.lsp.get_clients=function(filter) return filter.method=='workspace/willRenameFiles' and {client} or {} end
      vim.lsp.util.apply_workspace_edit=function() applied=true end
      local result=await(function(done) m.rename(assert(m.prepare({source})),{root .. '/Beta.cpp'},done) end)
      assert(requested and not applied and not result.ok and result.reason=='rename-edits-require-preview')
      assert(uv.fs_stat(source) and not uv.fs_stat(root .. '/Beta.cpp'))
    ]])
  end)

  t.it("target creation after an LSP request is checked before the native commit", function()
    native([[
      local source=file(root .. '/Alpha.cpp','alpha')
      local target=root .. '/Beta.cpp'
      local client={request=function(_,_,_,done)
        vim.defer_fn(function() file(target,'arrived during LSP');done(nil,{}) end,20)
        return true,91
      end,cancel_request=function() end}
      vim.lsp.get_clients=function(filter) return filter.method=='workspace/willRenameFiles' and {client} or {} end
      local result=await(function(done) m.rename(assert(m.prepare({source})),{target},done) end)
      assert(not result.ok and result.reason=='destination-exists')
      assert(vim.fn.readfile(target)[1]=='arrived during LSP' and uv.fs_stat(source))
    ]])
  end)

  t.it("cancel owns only its pending file request and ignores a late reply", function()
    native([[
      local source=file(root .. '/Alpha.cpp')
      local callback,canceled,result
      local client={request=function(_,_,_,done) callback=done;return true,91 end,
        cancel_request=function(_,id) canceled=id end}
      vim.lsp.get_clients=function(filter) return filter.method=='workspace/willRenameFiles' and {client} or {} end
      local plan=assert(m.prepare({source}))
      m.rename(plan,{root .. '/Beta.cpp'},function(ok,reason) result={ok,reason} end)
      m.cancel(plan)
      callback(nil,{})
      assert(canceled==91 and result[1]==false and result[2]=='canceled')
      assert(uv.fs_stat(source) and not uv.fs_stat(root .. '/Beta.cpp'))
    ]])
  end)

  t.it("new dirty descendants after delete confirmation block every side effect", function()
    native([[
      file(root .. '/Module/Alpha.cpp')
      local plan=assert(m.prepare({root .. '/Module'},{kind='delete'}))
      local buf=load(root .. '/Module/Alpha.cpp')
      api.nvim_buf_set_lines(buf,0,-1,false,{'new after confirmation opened'})
      local result=await(function(done) m.delete(plan,done) end)
      assert(not result.ok and uv.fs_stat(root .. '/Module/Alpha.cpp'))
      assert(api.nvim_buf_is_loaded(buf) and api.nvim_buf_get_lines(buf,0,-1,false)[1]=='new after confirmation opened')
      assert(m.last().state=='rejected')
    ]])
  end)

  t.it("changed source identity after isolation is retained and never reaches trash", function()
    native([[
      local source=file(root .. '/Alpha.cpp','frozen source')
      local replacement=file(root .. '/Replacement.cpp','new object before move')
      local driver=require('utils.platform').driver()
      local original=assert(driver.rename_no_replace)
      driver.rename_no_replace=function(from,to,done)
        assert(uv.fs_rename(from,root .. '/PreservedOriginal.cpp'))
        assert(uv.fs_rename(replacement,from))
        original(from,to,done)
      end
      require('utils.file_mutations_trash').run=function() error('changed object must not be trashed') end
      local result=await(function(done) m.delete(assert(m.prepare({source},{kind='delete'})),done) end)
      assert(not result.ok and m.last().state=='needs-review')
      local recovery=m.last().changed[1].recovery
      assert(recovery and vim.fn.readfile(recovery)[1]=='new object before move')
      assert(vim.fn.readfile(root .. '/PreservedOriginal.cpp')[1]=='frozen source')
    ]])
  end)

  t.it("unavailable trash rejects before isolating the original pathname", function()
    native([[
      local source=file(root .. '/Alpha.cpp','original survives')
      require('snacks').explorer.config.trash=false
      local result=await(function(done) m.delete(assert(m.prepare({source},{kind='delete'})),done) end)
      assert(not result.ok and result.reason=='trash-unavailable')
      assert(vim.fn.readfile(source)[1]=='original survives' and m.last().state=='rejected')
    ]])
  end)

  t.it("new dirty descendants at quarantine completion keep the isolated directory and all text", function()
    native([[
      local source=file(root .. '/Module/Alpha.cpp','module original')
      local driver=require('utils.platform').driver()
      local original=assert(driver.rename_no_replace)
      local dirtybuf
      driver.rename_no_replace=function(from,to,done)
        original(from,to,function(ok,err)
          dirtybuf=vim.fn.bufadd(root .. '/Module/New.cpp')
          vim.fn.bufload(dirtybuf)
          api.nvim_buf_set_lines(dirtybuf,0,-1,false,{'new descendant input'})
          done(ok,err)
        end)
      end
      require('utils.file_mutations_trash').run=function() error('changed descendants must not reach trash') end
      local result=await(function(done) m.delete(assert(m.prepare({root .. '/Module'},{kind='delete'})),done) end)
      assert(not result.ok and m.last().state=='needs-review')
      local recovery=m.last().changed[1].recovery
      assert(recovery and vim.fn.readfile(recovery .. '/Alpha.cpp')[1]=='module original')
      assert(api.nvim_buf_is_loaded(dirtybuf) and vim.bo[dirtybuf].modified)
      assert(api.nvim_buf_get_lines(dirtybuf,0,-1,false)[1]=='new descendant input')
    ]])
  end)

  t.it("multi-file move reports completed paths and leaves a newly occupied target untouched", function()
    native([[
      local first=file(root .. '/First.cpp','first')
      local second=file(root .. '/Second.cpp','second')
      vim.fn.mkdir(root .. '/Moved','p')
      local first_target,second_target=root .. '/Moved/First.cpp',root .. '/Moved/Second.cpp'
      local driver=require('utils.platform').driver()
      local original=assert(driver.rename_no_replace)
      local number=0
      driver.rename_no_replace=function(from,to,done)
        number=number+1
        if number==2 then file(to,'late target retained') end
        original(from,to,done)
      end
      local result=await(function(done) m.rename(assert(m.prepare({first,second},{kind='move'})),{first_target,second_target},done) end)
      assert(not result.ok and #result.changed==1 and m.last().state=='needs-review')
      assert(vim.fn.readfile(first_target)[1]=='first' and not uv.fs_stat(first))
      assert(vim.fn.readfile(second)[1]=='second' and vim.fn.readfile(second_target)[1]=='late target retained')
    ]])
  end)

  t.it(
    "a new saved document at the original pathname keeps its name tick and clean state after trash completes",
    function()
      native([[
      local source=file(root .. '/Alpha.cpp','frozen original')
      local buf=load(source)
      api.nvim_set_current_buf(buf)
      local saved
      require('utils.file_mutations_trash').run=function(quarantine,_,done)
        vim.defer_fn(function()
          api.nvim_buf_set_lines(buf,0,-1,false,{'new saved document'})
          api.nvim_buf_call(buf,vim.cmd.write)
          saved={name=api.nvim_buf_get_name(buf),tick=api.nvim_buf_get_changedtick(buf),modified=vim.bo[buf].modified}
          assert(uv.fs_unlink(quarantine))
          done(true)
        end,20)
      end
      local result=await(function(done) m.delete(assert(m.prepare({source},{kind='delete'})),done) end)
      assert(result.ok,result.reason)
      assert(api.nvim_buf_is_loaded(buf) and api.nvim_get_current_buf()==buf)
      assert(api.nvim_buf_get_name(buf)==saved.name and api.nvim_buf_get_changedtick(buf)==saved.tick)
      assert(vim.bo[buf].modified==saved.modified and not saved.modified)
      assert(api.nvim_buf_get_lines(buf,0,-1,false)[1]=='new saved document')
      assert(vim.fn.readfile(source)[1]=='new saved document')
    ]])
    end
  )

  t.it("guarded options patch is lazy, idempotent and restores only its own functions", function()
    native([[
      local w=require('workarounds.snacks.safe_file_actions')
      local called=false
      local previous=function() called=true end
      local opts={picker={sources={explorer={actions={explorer_rename=previous}}}}}
      local actions=opts.picker.sources.explorer.actions
      w.apply(opts)
      local wrapper=actions.explorer_rename
      w.apply(opts)
      assert(actions.explorer_rename==wrapper and not package.loaded['snacks.explorer.actions'])
      local external=function() end
      actions.explorer_move=external
      w.disable()
      assert(actions.explorer_rename==previous and actions.explorer_move==external and not actions.explorer_del)
      wrapper({},nil)
      assert(called,'already-cloned picker actions must restore the previous callback too')
    ]])
  end)

  t.it("a synchronous willRename denial prevents dispatch to the next provider", function()
    native([[
      local source=file(root .. '/Alpha.cpp')
      local calls,finished,cancels=0,0,0
      local first={request=function(_,_,params,done)
        calls=calls+1
        done(nil,{changes={[params.files[1].oldUri]={{newText='requires preview'}}}})
        return true,101
      end,cancel_request=function() cancels=cancels+1 end}
      local second={request=function() calls=calls+1;return true,102 end,cancel_request=function() cancels=cancels+1 end}
      vim.lsp.get_clients=function(filter) return filter and filter.method=='workspace/willRenameFiles' and {first,second} or {} end
      local result=await(function(done) m.rename(assert(m.prepare({source})),{root .. '/Beta.cpp'},function(...)
        finished=finished+1;done(...)
      end) end)
      assert(not result.ok and result.reason=='rename-edits-require-preview')
      assert(calls==1,'synchronous denial must stop subsequent dispatch')
      assert(finished==1 and cancels==0,'completed synchronous replies must not be canceled')
      assert(uv.fs_stat(source) and not uv.fs_stat(root .. '/Beta.cpp'))
    ]])
  end)

  t.it("an unavailable LSP deadline timer rejects once before dispatch and clears its cancel owner", function()
    native([[
      local real_timer=assert(uv.new_timer(),'normal native timer allocation must work')
      real_timer:close()
      local source=file(root .. '/Alpha.cpp','original A')
      local provider={request=function() error('no deadline means no dispatch') end,cancel_request=function() error('no request to cancel') end}
      vim.lsp.get_clients=function(filter) return filter and filter.method=='workspace/willRenameFiles' and {provider} or {} end
      local original=uv.new_timer
      uv.new_timer=function() return nil end -- controlled failure seam, not an OOM/host claim
      local plan=assert(m.prepare({source}))
      local calls,result=0,nil
      local called,err=pcall(m.rename,plan,{root .. '/Beta.cpp'},function(ok,reason) calls=calls+1;result={ok=ok,reason=reason} end)
      uv.new_timer=original
      assert(called,err)
      assert(calls==1 and result and not result.ok and result.reason=='rename-timer-unavailable')
      assert(plan.cancel_requests==nil and plan.finished)
      assert(vim.fn.readfile(source)[1]=='original A' and not uv.fs_stat(root .. '/Beta.cpp'))
    ]])
  end)

  t.it("cancel before a request returns its ID cancels that pending ID once", function()
    native([[
      local source=file(root .. '/Alpha.cpp')
      local plan=assert(m.prepare({source}))
      local calls,cancels,finished,late=0,{},0,nil
      local first={request=function(_,_,_,done)
        calls=calls+1;late=done;m.cancel(plan);return true,101
      end,cancel_request=function(_,id) cancels[#cancels+1]=id end}
      local second={request=function() calls=calls+1;return true,102 end,cancel_request=function() error('never dispatched') end}
      vim.lsp.get_clients=function(filter) return filter and filter.method=='workspace/willRenameFiles' and {first,second} or {} end
      local result=await(function(done) m.rename(plan,{root .. '/Beta.cpp'},function(...)
        finished=finished+1;done(...)
      end) end)
      late(nil,{})
      assert(not result.ok and calls==1 and finished==1)
      assert(#cancels==1 and cancels[1]==101,'the ID arriving after cancellation must be canceled')
      assert(uv.fs_stat(source) and not uv.fs_stat(root .. '/Beta.cpp'))
    ]])
  end)

  t.it("native BufFilePre input and write preserve a new owner during delete naming", function()
    native([[
      local source=file(root .. '/Alpha.cpp','frozen original A')
      local buf=load(source)
      api.nvim_set_current_buf(buf)
      local saved,native_write_ok
      api.nvim_create_autocmd('BufFilePre',{buffer=buf,once=true,callback=function()
        api.nvim_buf_set_lines(buf,0,-1,false,{'new B during native naming'})
        native_write_ok=pcall(api.nvim_buf_call,buf,vim.cmd.write)
        saved={name=api.nvim_buf_get_name(buf),tick=api.nvim_buf_get_changedtick(buf),modified=vim.bo[buf].modified}
      end})
      require('utils.file_mutations_trash').run=function(quarantine,_,done)
        assert(uv.fs_unlink(quarantine));done(true)
      end
      await(function(done) m.delete(assert(m.prepare({source},{kind='delete'})),done) end)
      assert(native_write_ok and saved and not saved.modified)
      assert(api.nvim_buf_is_loaded(buf) and api.nvim_get_current_buf()==buf)
      assert(api.nvim_buf_get_name(buf)==saved.name,'new saved document filename must survive BufFilePre')
      assert(api.nvim_buf_get_changedtick(buf)==saved.tick and vim.bo[buf].modified==saved.modified)
      assert(vim.fn.readfile(source)[1]=='new B during native naming')
      assert(api.nvim_buf_get_lines(buf,0,-1,false)[1]=='new B during native naming')
    ]])
  end)

  t.it("native BufFilePre input and write preserve a new owner during successful disk rename", function()
    native([[
      local source=file(root .. '/Alpha.cpp','frozen original A')
      local target=root .. '/Beta.cpp'
      local buf=load(source)
      api.nvim_set_current_buf(buf)
      local saved,native_write_ok
      api.nvim_create_autocmd('BufFilePre',{buffer=buf,once=true,callback=function()
        api.nvim_buf_set_lines(buf,0,-1,false,{'new B during native naming'})
        native_write_ok=pcall(api.nvim_buf_call,buf,vim.cmd.write)
        saved={name=api.nvim_buf_get_name(buf),tick=api.nvim_buf_get_changedtick(buf),modified=vim.bo[buf].modified}
      end})
      local result=await(function(done) m.rename(assert(m.prepare({source})),{target},done) end)
      assert(native_write_ok and saved and not saved.modified)
      assert(api.nvim_buf_get_name(buf)==saved.name,'saved B must not be retargeted to disk A')
      assert(api.nvim_buf_get_changedtick(buf)==saved.tick and vim.bo[buf].modified==saved.modified)
      assert(vim.fn.readfile(source)[1]=='new B during native naming' and vim.fn.readfile(target)[1]=='frozen original A')
      assert(not result.ok and m.last().state=='needs-review')
    ]])
  end)

  t.it("a native BufFilePre choice of another filename is preserved instead of overwritten", function()
    native([[
      local source=file(root .. '/Alpha.cpp','original A')
      local buf=load(source)
      local foreign=root .. '/ChosenElsewhere.cpp'
      api.nvim_create_autocmd('BufFilePre',{buffer=buf,once=true,callback=function()
        api.nvim_buf_set_name(buf,foreign)
      end})
      local result=await(function(done) m.rename(assert(m.prepare({source})),{root .. '/Beta.cpp'},done) end)
      assert(not result.ok and m.last().state=='needs-review')
      assert(api.nvim_buf_get_name(buf):gsub('\\','/'):find('/ChosenElsewhere.cpp',1,true))
      assert(api.nvim_buf_get_lines(buf,0,-1,false)[1]=='original A')
    ]])
  end)

  t.it("native BufFilePost input and write keep their current filename and saved state", function()
    native([[
      local source=file(root .. '/Alpha.cpp','original A')
      local target=root .. '/Beta.cpp'
      local buf=load(source)
      api.nvim_set_current_buf(buf)
      local saved,write_ok
      api.nvim_create_autocmd('BufFilePost',{buffer=buf,once=true,callback=function()
        api.nvim_buf_set_lines(buf,0,-1,false,{'post event saved B'})
        write_ok=pcall(api.nvim_buf_call,buf,function() vim.cmd.write({bang=true}) end)
        saved={name=api.nvim_buf_get_name(buf),tick=api.nvim_buf_get_changedtick(buf),modified=vim.bo[buf].modified}
      end})
      local result=await(function(done) m.rename(assert(m.prepare({source})),{target},done) end)
      assert(write_ok and not result.ok and m.last().state=='needs-review')
      assert(api.nvim_buf_get_name(buf)==saved.name and api.nvim_buf_get_changedtick(buf)==saved.tick)
      assert(vim.bo[buf].modified==saved.modified and not saved.modified)
      assert(vim.fn.readfile(target)[1]=='post event saved B')
    ]])
  end)

  t.it("a buffer wiped during native naming cannot retarget the replacement buffer", function()
    native([[
      local source=file(root .. '/Alpha.cpp','original A')
      local buf=load(source)
      api.nvim_set_current_buf(buf)
      local replacement=api.nvim_create_buf(true,false)
      api.nvim_buf_set_name(replacement,root .. '/UserChoice.cpp')
      api.nvim_buf_set_lines(replacement,0,-1,false,{'replacement buffer input'})
      local replaced_name=api.nvim_buf_get_name(replacement)
      local replaced_tick=api.nvim_buf_get_changedtick(replacement)
      api.nvim_create_autocmd('BufFilePre',{buffer=buf,once=true,callback=function()
        api.nvim_buf_delete(buf,{force=true})
        api.nvim_set_current_buf(replacement)
      end})
      local result=await(function(done) m.rename(assert(m.prepare({source})),{root .. '/Beta.cpp'},done) end)
      assert(not result.ok and m.last().state=='needs-review')
      assert(api.nvim_get_current_buf()==replacement and api.nvim_buf_get_name(replacement)==replaced_name)
      assert(api.nvim_buf_get_changedtick(replacement)==replaced_tick and vim.bo[replacement].modified)
      assert(api.nvim_buf_get_lines(replacement,0,-1,false)[1]=='replacement buffer input')
    ]])
  end)

  t.it("a nested BufFilePost naming and write belongs to the new document", function()
    native([[
      local source=file(root .. '/Alpha.cpp','original A')
      local target,chosen=root .. '/Beta.cpp',root .. '/ChosenB.cpp'
      local buf=load(source)
      api.nvim_set_current_buf(buf)
      local named,wrote,saved
      api.nvim_create_autocmd('BufFilePost',{buffer=buf,once=true,nested=true,callback=function()
        api.nvim_buf_set_lines(buf,0,-1,false,{'chosen new B'})
        named=pcall(api.nvim_buf_set_name,buf,chosen)
        wrote=pcall(api.nvim_buf_call,buf,vim.cmd.write)
        saved={name=api.nvim_buf_get_name(buf),tick=api.nvim_buf_get_changedtick(buf),modified=vim.bo[buf].modified}
      end})
      local result=await(function(done) m.rename(assert(m.prepare({source})),{target},done) end)
      assert(named and wrote,'old guard must not veto a new Post owner naming call')
      assert(not result.ok and m.last().state=='needs-review')
      assert(api.nvim_buf_get_name(buf)==saved.name and api.nvim_buf_get_changedtick(buf)==saved.tick)
      assert(vim.bo[buf].modified==saved.modified and not saved.modified)
      assert(vim.fn.readfile(chosen)[1]=='chosen new B' and vim.fn.readfile(target)[1]=='original A')
    ]])
  end)

  t.it("a nested Pre naming is kept while the outer old filename assignment is rejected", function()
    native([[
      local source=file(root .. '/Alpha.cpp','original A')
      local target,chosen=root .. '/Beta.cpp',root .. '/ChosenPre.cpp'
      local buf=load(source)
      api.nvim_set_current_buf(buf)
      local named,wrote,saved
      api.nvim_create_autocmd('BufFilePre',{buffer=buf,once=true,nested=true,callback=function()
        api.nvim_buf_set_lines(buf,0,-1,false,{'chosen Pre new B'})
        named=pcall(api.nvim_buf_set_name,buf,chosen)
        wrote=pcall(api.nvim_buf_call,buf,vim.cmd.write)
        saved={name=api.nvim_buf_get_name(buf),tick=api.nvim_buf_get_changedtick(buf),modified=vim.bo[buf].modified}
      end})
      local result=await(function(done) m.rename(assert(m.prepare({source})),{target},done) end)
      assert(named and wrote)
      assert(not result.ok and m.last().state=='needs-review')
      assert(api.nvim_buf_get_name(buf)==saved.name and api.nvim_buf_get_changedtick(buf)==saved.tick)
      assert(vim.bo[buf].modified==saved.modified and not saved.modified)
      assert(vim.fn.readfile(chosen)[1]=='chosen Pre new B' and vim.fn.readfile(target)[1]=='original A')
    ]])
  end)
end)
