local t = require("tests.harness")
local cfg = t.bootstrap()

-- Receipt assertions use fictional business input. Process, terminal, quickfix
-- and buffer-identity assertions use owned real Neovim children/native APIs.
local function native(check)
  local root = vim.fs.normalize(assert(vim.env.NVIM_TEST_RUN_ROOT)):gsub("/$", "")
  local dir = root .. "/verification-runs-" .. tostring(vim.uv.hrtime())
  local absolute = vim.fs.normalize(vim.fn.fnamemodify(dir, ":p")):gsub("/$", "")
  t.assert_true(absolute:sub(1, #root + 1) == root .. "/", "owned fixture escaped test root")
  vim.fn.mkdir(dir, "p")
  local job = vim.fn.jobstart({ vim.v.progpath, "--headless", "--embed", "-u", "NONE", "-i", "NONE", "-n" }, {
    rpc = true,
    env = {
      XDG_DATA_HOME = dir .. "/data",
      XDG_STATE_HOME = dir .. "/state",
      XDG_CACHE_HOME = dir .. "/cache",
      NVIM_UE_PROBE_PATH = dir .. "/probes.json",
      NVIM_UE_LOG_DIR = dir .. "/logs",
      NVIM_LOG_FILE = dir .. "/nvim.log",
    },
  })
  t.assert_true(job > 0, "owned native Neovim did not start")
  local f = {}
  ---@return any
  function f.lua(code, ...)
    return vim.rpcrequest(job, "nvim_exec_lua", code, { ... })
  end
  local ok, err = xpcall(function()
    f.lua(
      [[
      local cfg, root = ...
      vim.opt.rtp:prepend(cfg)
      package.path=cfg..'/lua/?.lua;'..cfg..'/lua/?/init.lua;'..package.path
      api,V=vim.api,require('utils.verification_runs')
      vim.o.hidden,vim.o.swapfile,vim.o.shada=true,false,''
      fixture_root=root
      api.nvim_set_current_dir(root)
      source_path=root..'/Source.cpp'
      vim.fn.writefile({'disk line one','disk line two','disk line three'},source_path)
      vim.cmd.edit(vim.fn.fnameescape(source_path))
      source_buf=api.nvim_get_current_buf()
      -- Native :edit owns the canonical absolute filename, including drive case.
      source_path=api.nvim_buf_get_name(source_buf)
      api.nvim_buf_set_lines(source_buf,0,-1,false,{'dirty source one','你 alpha dirty source','dirty source three'})
      api.nvim_win_set_cursor(0,{2,4})
      log_buf=api.nvim_create_buf(false,true)
      api.nvim_buf_set_name(log_buf,'verification-log://owned')
      api.nvim_buf_set_lines(log_buf,0,-1,false,{'first log','failed compilation'})
      peers={}
      function spec(values)
        return vim.tbl_extend('force',{
          project_root=root..'/ProjectA',engine_root=root..'/Engine',uproject=root..'/ProjectA/Game.uproject',
          target='GameEditor',platform='Win64',configuration='Development',operation='build',label='Fixture build',
          buf=log_buf,name=api.nvim_buf_get_name(log_buf),started_at=100,dirty_count_start=0,
        },values or {})
      end
      function peer()
        local channel=vim.fn.jobstart({vim.v.progpath,'--headless','--embed','-u','NONE','-i','NONE','-n'}, {
          rpc=true,env={NVIM_LOG_FILE=root..'/peer-'..(#peers+1)..'.log'},
        })
        assert(channel>0,'real native peer did not start')
        peers[#peers+1]=channel
        assert(vim.fn.jobwait({channel},0)[1]==-1)
        return channel
      end
      function exit_peer(channel)
        vim.rpcnotify(channel,'nvim_command','qa!')
        local code=vim.fn.jobwait({channel},2000)[1]
        assert(code==0,'native peer did not exit zero: '..tostring(code))
        return code
      end
      function cleanup()
        for _,channel in ipairs(peers) do pcall(vim.fn.jobstop,channel) end
        if #peers>0 then pcall(vim.fn.jobwait,peers,1000) end
      end
      function qf(title,items,context)
        assert(vim.fn.setqflist({},' ',{title=title,items=items or {},context=context or {}})==0)
        return vim.fn.getqflist({id=0}).id
      end
      function evidence()
        local id=assert(V.begin(spec()))
        local list=qf('owned build errors',{{filename=source_path,lnum=2,col=5,type='E',text='owned source error'}},{verification_id=id})
        local receipt=vim.fn.getqflist({id=list,items=0,changedtick=0})
        assert(V.complete(id,{code=1,current=true,qf_id=list,qf_tick=receipt.changedtick,items=receipt.items}))
        return id,list
      end
      function evict()
        for index=1,12 do qf('search '..index,{{text='unrelated search '..index}}) end
      end
      function view()
        return {win=api.nvim_get_current_win(),buf=api.nvim_get_current_buf(),cursor=api.nvim_win_get_cursor(0),
          wins=api.nvim_list_wins(),source=api.nvim_buf_get_lines(source_buf,0,-1,false),
          qf=vim.fn.getqflist({id=0,nr=0,idx=0,title=0,items=0,context=0,changedtick=0})}
      end
      function terminal()
        local buf=api.nvim_create_buf(false,true)
        api.nvim_win_set_buf(0,buf)
        local completed
        local channel=vim.fn.termopen({vim.v.progpath,'--headless','-u','NONE','-i','NONE','-n','-c','qa'}, {
          env={NVIM_LOG_FILE=root..'/terminal.log'},on_exit=function(_,code) completed=code end,
        })
        assert(channel>0,'native terminal did not start')
        peers[#peers+1]=channel
        local name=api.nvim_buf_get_name(buf)
        local id=assert(V.begin(spec({buf=buf,name=name,jobid=channel})))
        assert(vim.wait(2000,function() return completed~=nil end,5),'native terminal did not complete')
        assert(completed==0 and vim.bo[buf].channel==channel and vim.bo[buf].buftype=='terminal')
        assert(V.complete(id,{code=completed,current=true}))
        api.nvim_win_set_buf(0,source_buf)
        return id,buf,channel,name
      end
      return true
    ]],
      cfg,
      dir
    )
    check(f)
  end, debug.traceback)
  pcall(f.lua, "if cleanup then cleanup() end")
  pcall(vim.fn.jobstop, job)
  pcall(vim.fn.jobwait, { job }, 1000)
  vim.fn.delete(absolute, "rf")
  if not ok then
    error(err, 0)
  end
end

t.describe("verification business receipts and native process facts", function()
  t.it("freezes input identity and returns independent snapshots", function()
    native(function(f)
      f.lua([[
        local input=spec({dirty_count_start=3})
        local id=assert(V.begin(input))
        input.project_root='changed caller project';input.label='changed caller label'
        local one=assert(V.get(id))
        assert(one.project_root==spec().project_root and one.label=='Fixture build' and one.dirty_count_start==3)
        one.label='mutated view';one.items[1]={text='injected'}
        assert(V.get(id).label=='Fixture build' and #V.get(id).items==0)
      ]])
    end)
  end)
  t.it("lists newest beginnings rather than older late completions or clock changes", function()
    native(function(f)
      f.lua([[
        local old=assert(V.begin(spec({started_at=999})))
        local newer=assert(V.begin(spec({started_at=1})))
        assert(newer>old)
        assert(V.complete(newer,{code=1,current=true}))
        assert(V.complete(old,{code=0,current=false}))
        local rows=V.list()
        assert(rows[1].id==newer and rows[2].id==old and rows[2].current==false and rows[2].result=='not_current')
      ]])
    end)
  end)
  t.it("filters the captured project and target tuple without relabelling another run", function()
    native(function(f)
      f.lua([[
        local a=assert(V.begin(spec()))
        V.begin(spec({project_root=fixture_root..'/ProjectB'}))
        V.begin(spec({platform='Android'}))
        V.begin(spec({configuration='Debug'}))
        local rows=V.list({project_root=spec().project_root,platform='Win64',configuration='Development'})
        assert(#rows==1 and rows[1].id==a)
        assert(#V.list({project_root=fixture_root..'/ProjectB'})==1)
      ]])
    end)
  end)
  t.it("queries a real live handle and never writes completion into TaskRegistry", function()
    native(function(f)
      f.lua([[
        local channel=peer()
        local registry=require('utils.task_registry')
        local task=assert(registry.register({name='owned test peer',group='fixture',kind='job',handle=channel}))
        local before=vim.deepcopy(registry.get(task))
        local id=assert(V.begin(spec({jobid=channel})))
        assert(V.get(id).process_status=='running' and V.get(id).result=='running')
        assert(V.complete(id,{code=1,current=false}))
        assert(V.get(id).process_status=='running' and V.get(id).result=='not_current')
        V.list()
        assert(vim.deep_equal(before,registry.get(task)))
        exit_peer(channel)
        assert(V.get(id).process_status~='running')
      ]])
    end)
  end)
  t.it("a genuine exit-zero receipt retains dirty-start evidence without certifying current code", function()
    native(function(f)
      f.lua([[
        local channel=peer()
        local id=assert(V.begin(spec({jobid=channel,dirty_count_start=4})))
        local code=exit_peer(channel)
        assert(V.complete(id,{code=code,current=true}))
        local row=assert(V.get(id))
        assert(row.result=='exit_zero' and row.code==0 and row.current==true and row.dirty_count_start==4)
      ]])
    end)
  end)
  t.it("unknown, stale, spawn-failed and cancelled evidence cannot become exit-zero", function()
    native(function(f)
      f.lua([[
        local channel=peer();exit_peer(channel)
        local cases={
          {jobid=channel,receipt={current=true}},
          {jobid=channel,receipt={code=0}},
          {jobid=channel,receipt={code=0,current=false}},
          {jobid=0,receipt={code=0,current=true}},
          {jobid=channel,receipt={code=-1,current=true}},
          {jobid=channel,receipt={code=0,current=true,cancelled=true}},
        }
        for _,case in ipairs(cases) do
          local id=assert(V.begin(spec({jobid=case.jobid})))
          assert(V.complete(id,case.receipt))
          assert(V.get(id).result~='exit_zero')
        end
      ]])
    end)
  end)
  t.it("accepts one completion and ignores a duplicate attempt to paint it green", function()
    native(function(f)
      f.lua([[
        local id=assert(V.begin(spec()))
        assert(V.complete(id,{code=1,current=false,items={{text='original failure'}}}))
        local before=V.get(id)
        assert(V.complete(id,{code=0,current=true,items={{text='replacement'}}})==false)
        assert(vim.deep_equal(before,V.get(id)))
      ]])
    end)
  end)
  t.it("retains sixteen completed records without trimming twenty actually-live records", function()
    native(function(f)
      f.lua([[
        local channel=peer()
        local active={}
        for index=1,20 do active[index]=assert(V.begin(spec({jobid=channel}))) end
        for index=1,30 do local id=assert(V.begin(spec()));assert(V.complete(id,{code=1,current=true})) end
        local rows=V.list()
        assert(#rows==36)
        for _,id in ipairs(active) do assert(V.get(id).process_status=='running') end
        assert(rows[1].id>rows[2].id)
      ]])
    end)
  end)
  t.it("an exited invocation waiting for its receipt survives seventeen newer completions", function()
    native(function(f)
      f.lua([[
        local channel=peer()
        local pending=assert(V.begin(spec({jobid=channel})))
        local code=exit_peer(channel)
        for index=1,17 do local id=assert(V.begin(spec()));assert(V.complete(id,{code=1,current=true})) end
        assert(V.get(pending) and not V.get(pending).completed)
        assert(#V.list()==17)
        assert(V.complete(pending,{code=code,current=true}),'pending receipt was discarded before delivery')
        local rows=V.list()
        assert(#rows==16 and rows[1].id>pending)
      ]])
    end)
  end)
  t.it("bounds diagnostic rows and preserves native buffer plus absolute filename information", function()
    native(function(f)
      f.lua([[
        local input={}
        for index=1,1100 do input[index]={bufnr=source_buf,lnum=2,col=5,type='E',text='error '..index} end
        local id=assert(V.begin(spec()))
        assert(V.complete(id,{code=1,current=true,items=input}))
        local row=assert(V.get(id))
        assert(#row.items==1024 and row.partial and row.omitted_rows==76 and row.item_bytes<=1024*1024)
        assert(row.items[1].bufnr==source_buf and row.items[1].filename==source_path)
        input[1].text='changed owner input';row.items[1].text='changed UI snapshot'
        assert(V.get(id).items[1].text=='error 1')
      ]])
    end)
  end)
  t.it("skips an oversized row, retains later useful evidence, and labels partial output", function()
    native(function(f)
      f.lua([[
        local id=assert(V.begin(spec()))
        assert(V.complete(id,{code=1,current=true,items={{text=string.rep('x',1024*1024)},{text='small retained error'}}}))
        local row=V.get(id)
        assert(row.partial and row.omitted_rows==1 and #row.items==1 and row.items[1].text=='small retained error')
        assert(row.item_bytes<=1024*1024)
      ]])
    end)
  end)
  t.it("emits User changes only for accepted beginnings and completions", function()
    native(function(f)
      f.lua([[
        local events={}
        api.nvim_create_autocmd('User',{pattern='UEWorkbenchChanged',callback=function(args)
          assert(not vim.in_fast_event());events[#events+1]=args.data
        end})
        local id=assert(V.begin(spec()))
        V.get(id);V.list()
        assert(V.complete(id,{code=1,current=false}))
        V.complete(id,{code=0,current=true});V.get(id);V.list()
        assert(#events==2 and events[1].event=='begin' and events[2].event=='complete' and events[2].id==id)
      ]])
    end)
  end)
end)

t.describe("verification-owned native quickfix evidence", function()
  t.it("returns to this invocation's errors after an unrelated search becomes current", function()
    native(function(f)
      f.lua([[
        local id,list=evidence()
        local search=qf('search results',{{text='search row'}})
        local saved=vim.fn.getqflist({id=search,items=0,context=0,title=0})
        local text=api.nvim_buf_get_lines(source_buf,0,-1,false)
        assert(V.show_problems(id))
        assert(vim.fn.getqflist({id=0}).id==list)
        assert(vim.deep_equal(saved,vim.fn.getqflist({id=search,items=0,context=0,title=0})))
        assert(vim.deep_equal(text,api.nvim_buf_get_lines(source_buf,0,-1,false)))
      ]])
    end)
  end)
  t.it("rebuilds its bounded snapshot after native ten-list eviction with a new owned ID", function()
    native(function(f)
      f.lua([[
        local id,old=evidence();evict()
        assert(vim.fn.getqflist({id=old}).id~=old)
        local search=vim.fn.getqflist({id=0,items=0,title=0,context=0})
        assert(V.show_problems(id))
        local row=V.get(id)
        local restored=vim.fn.getqflist({id=row.qf_id,items=0,context=0,changedtick=0})
        assert(row.qf_id~=old and restored.context.verification_id==id and restored.changedtick==row.qf_tick)
        assert(restored.items[1].text=='owned source error' and restored.items[1].col==5)
        assert(vim.deep_equal(search,vim.fn.getqflist({id=search.id,items=0,title=0,context=0})))
      ]])
    end)
  end)
  t.it("rejects same-ID replacement even when its verification marker survives", function()
    native(function(f)
      f.lua([[
        local id,old=evidence()
        local tick=V.get(id).qf_tick
        assert(vim.fn.setqflist({},'r',{id=old,items={{text='different owner content'}},context={verification_id=id}})==0)
        assert(vim.fn.getqflist({id=old,changedtick=0}).changedtick~=tick)
        assert(V.show_problems(id))
        local row=V.get(id)
        assert(row.qf_id~=old)
        assert(vim.fn.getqflist({id=0,items=0}).items[1].text=='owned source error')
        assert(vim.fn.getqflist({id=old,items=0}).items[1].text=='different owner content')
      ]])
    end)
  end)
  t.it("uses the producer's frozen tick instead of accepting a late same-ID fixture read", function()
    native(function(f)
      f.lua([[
        local id=assert(V.begin(spec()))
        local list=qf('build',{{filename=source_path,lnum=2,col=5,text='producer error'}},{verification_id=id})
        local receipt=vim.fn.getqflist({id=list,items=0,changedtick=0})
        vim.fn.setqflist({},'r',{id=list,items={{text='late replacement'}},context={verification_id=id}})
        assert(V.complete(id,{code=1,current=true,qf_id=list,qf_tick=receipt.changedtick,items=receipt.items}))
        assert(V.show_problems(id))
        assert(vim.fn.getqflist({id=0,items=0}).items[1].text=='producer error')
      ]])
    end)
  end)
  t.it("does not borrow another verification marker attached to the same retained ID", function()
    native(function(f)
      f.lua([[
        local id,list=evidence()
        vim.fn.setqflist({},'a',{id=list,context={verification_id=id+100}})
        assert(V.show_problems(id))
        assert(V.get(id).qf_id~=list)
        assert(vim.fn.getqflist({id=list,context=0}).context.verification_id==id+100)
      ]])
    end)
  end)
  t.it("honors Workspace's refusal to evict the user's current oldest full-stack list", function()
    native(function(f)
      f.lua([[
        local id=evidence();evict();vim.cmd('silent chistory 1')
        local before=view()
        local win,err=V.show_problems(id)
        assert(win==nil and type(err)=='string' and err:find('淘汰',1,true))
        assert(vim.deep_equal(before,view()),'failed pin changed the selected search or editor')
      ]])
    end)
  end)
  t.it("a renamed native buffer cannot steal the filename when errors are reconstructed", function()
    native(function(f)
      f.lua([[
        local id=evidence();evict()
        api.nvim_buf_set_name(source_buf,fixture_root..'/Foreign.cpp')
        local text=api.nvim_buf_get_lines(source_buf,0,-1,false)
        assert(V.show_problems(id))
        local item=vim.fn.getqflist({id=0,items=0}).items[1]
        assert(item.bufnr~=source_buf and api.nvim_buf_get_name(item.bufnr)==source_path,
          vim.json.encode({different_buffer=item.bufnr~=source_buf,
            filename_equal=api.nvim_buf_get_name(item.bufnr)==source_path,
            normalized_equal=vim.fs.normalize(api.nvim_buf_get_name(item.bufnr))==vim.fs.normalize(source_path),
            casefold_equal=vim.fs.normalize(api.nvim_buf_get_name(item.bufnr)):lower()==vim.fs.normalize(source_path):lower(),
            receipt_filename_equal=V.get(id).items[1].filename==source_path}))
        assert(vim.deep_equal(text,api.nvim_buf_get_lines(source_buf,0,-1,false)))
      ]])
    end)
  end)
  if vim.fn.has("win32") == 0 then
    t.skip(
      "a forward-slash diagnostic reuses its loaded backslash-named Windows source",
      "Windows filename capability unavailable",
      { native = true }
    )
  else
    t.it("a forward-slash diagnostic reuses its loaded backslash-named Windows source", function()
      native(function(f)
        f.lua([[
          local backslash_name=(source_path:gsub('/','\\'))
          api.nvim_buf_set_name(source_buf,backslash_name)
          local native_name=api.nvim_buf_get_name(source_buf)
          local filename=native_name:gsub('\\','/')
          assert(native_name:find('\\',1,true) and native_name~=filename)
          assert(vim.fs.normalize(native_name)==vim.fs.normalize(filename))
          assert(vim.fn.bufadd(filename)==source_buf and api.nvim_buf_is_loaded(source_buf))
          local id=assert(V.begin(spec()))
          assert(V.complete(id,{code=1,current=true,items={{filename=filename,lnum=3,col=7,type='E',text='slash-preserved compiler error'}}}))
          assert(V.get(id).items[1].bufnr==nil and V.get(id).items[1].filename==filename)
          local text=api.nvim_buf_get_lines(source_buf,0,-1,false)
          assert(V.show_problems(id))
          local item=vim.fn.getqflist({id=0,items=0}).items[1]
          assert(item.bufnr==source_buf and item.lnum==3 and item.col==7)
          vim.cmd('cc 1')
          assert(api.nvim_get_current_buf()==source_buf and vim.deep_equal(api.nvim_win_get_cursor(0),{3,6}))
          assert(api.nvim_buf_get_name(source_buf)==native_name and vim.deep_equal(text,api.nvim_buf_get_lines(source_buf,0,-1,false)))
        ]])
      end)
    end)
  end
end)

t.describe("verification log identity", function()
  t.it("reopens only the captured log buffer without duplicating its existing view", function()
    native(function(f)
      f.lua([[
        local id=assert(V.begin(spec()))
        local win=assert(V.show_log(id))
        assert(api.nvim_win_get_buf(win)==log_buf)
        local count=#api.nvim_list_wins()
        assert(V.show_log(id)==win and #api.nvim_list_wins()==count)
      ]])
    end)
  end)
  t.it("a deleted or renamed log refuses navigation instead of selecting a latest replacement", function()
    native(function(f)
      f.lua([[
        local id=assert(V.begin(spec()))
        api.nvim_buf_set_name(log_buf,'verification-log://foreign')
        local before=view()
        local win,err=V.show_log(id)
        assert(win==nil and type(err)=='string' and vim.deep_equal(before,view()))
        api.nvim_buf_delete(log_buf,{force=true})
        local replacement=api.nvim_create_buf(false,true)
        api.nvim_buf_set_name(replacement,'verification-log://owned')
        require('utils.bottom_panel').register('build',replacement)
        before=view()
        win,err=V.show_log(id)
        assert(win==nil and type(err)=='string' and vim.deep_equal(before,view()))
      ]])
    end)
  end)
  t.it("an exited real terminal retains its channel and can be reopened", function()
    native(function(f)
      f.lua([[
        local id,buf,channel,name=terminal()
        assert(api.nvim_buf_is_loaded(buf) and api.nvim_buf_get_name(buf)==name and vim.bo[buf].channel==channel)
        assert(V.get(id).result=='exit_zero')
        local win=assert(V.show_log(id))
        assert(api.nvim_win_get_buf(win)==buf)
      ]])
    end)
  end)
  t.it("another terminal channel in the same buffer and name cannot inherit the old log credential", function()
    native(function(f)
      f.lua([[
        local id,buf,old,name=terminal()
        local channel=api.nvim_open_term(buf,{})
        api.nvim_chan_send(channel,'new terminal owner\r\n')
        assert(vim.wait(1000,function()
          return table.concat(api.nvim_buf_get_lines(buf,0,-1,false),'\n'):find('new terminal owner',1,true)~=nil
        end,5),'new native terminal did not deliver its output')
        assert(channel~=old and vim.bo[buf].channel==old and api.nvim_buf_get_name(buf)==name)
        local before=view()
        local win,err=V.show_log(id)
        assert(win==nil and type(err)=='string' and vim.deep_equal(before,view()))
      ]])
    end)
  end)
end)
