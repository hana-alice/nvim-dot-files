local t = require("tests.harness")
local cfg = t.bootstrap()

-- Every store call uses native UV disk I/O and leases in owned isolated state.
-- Failure seams below replace only the named UV callback boundary in a child.
local function native(check, count)
  local root = vim.fs.normalize(assert(vim.env.NVIM_TEST_RUN_ROOT)):gsub("/$", "")
  local dir = root .. "/work-context-store-" .. tostring(vim.uv.hrtime())
  local absolute = vim.fs.normalize(vim.fn.fnamemodify(dir, ":p")):gsub("/$", "")
  t.assert_true(absolute:sub(1, #root + 1) == root .. "/", "owned fixture escaped test root")
  vim.fn.mkdir(dir, "p")
  local jobs, clients = {}, {}
  local ok, err = xpcall(function()
    for index = 1, count or 1 do
      local job = vim.fn.jobstart({ vim.v.progpath, "--headless", "--embed", "-u", "NONE", "-i", "NONE", "-n" }, {
        rpc = true,
        env = {
          XDG_DATA_HOME = dir .. "/data",
          XDG_STATE_HOME = dir .. "/state",
          XDG_CACHE_HOME = dir .. "/cache",
          NVIM_UE_PROBE_PATH = dir .. "/probes-" .. index .. ".json",
          NVIM_UE_LOG_DIR = dir .. "/logs-" .. index,
          NVIM_LOG_FILE = dir .. "/nvim-" .. index .. ".log",
        },
      })
      t.assert_true(job > 0, "native store fixture did not start")
      jobs[#jobs + 1] = job
      local f = {}
      ---@return any
      function f.lua(code, ...)
        return vim.rpcrequest(job, "nvim_exec_lua", code, { ... })
      end
      f.lua(
        [[
        local cfg,root=...
        vim.opt.rtp:prepend(cfg)
        package.path=cfg..'/lua/?.lua;'..cfg..'/lua/?/init.lua;'..package.path
        vim.o.hidden,vim.o.swapfile,vim.o.shada=true,false,''
        S,uv= require('utils.work_context_store'),vim.uv
        vim.fn.mkdir(root..'/Engine','p');vim.fn.mkdir(root..'/ProjectA','p');vim.fn.mkdir(root..'/ProjectB','p')
        vim.fn.writefile({'{}'},root..'/ProjectA/Game.uproject')
        vim.fn.writefile({'{}'},root..'/ProjectB/Game.uproject')
        project={root=root..'/ProjectA',identity=root..'/ProjectA/Game.uproject',engine=root..'/Engine'}
        other={root=root..'/ProjectB',identity=root..'/ProjectB/Game.uproject',engine=root..'/Engine'}
        source=root..'/ProjectA/Source.cpp'
        if vim.fn.filereadable(source)==0 then vim.fn.writefile({'disk text retained'},source) end
        function draft(name)
          return {name=name or 'Investigation A',note='inspect the original error',active=1,
            files={{path=source,line=3,col=5,modified=true,disk={size=19,mtime_sec=100,mtime_nsec=25}}},has_result=true}
        end
        function recipe(owner)
          owner=owner or project
          return {version=1,source='grep',query='literal query',project=owner,
            scope={kind='project',roots={owner.root},code_only=true},mode={regex=false,case='smart',word=true},
            filters={include={'*.cpp'},exclude={'Generated/**'},extensions={},extra_globs={},pattern='',hidden=false,ignored=false,follow=false}}
        end
        function call(method,...)
          local args,count={...},select('#',...)
          local result,err,finished,calls
          calls=0
          local function done(value,failure)
            assert(not vim.in_fast_event(),'store callback escaped main loop')
            calls=calls+1;result,err,finished=value,failure,true
          end
          args[count+1]=done
          S[method](unpack(args,1,count+1))
          assert(not finished,'store callback ran synchronously')
          assert(vim.wait(4000,function() return finished end,5),'store callback timed out')
          assert(calls==1,'store callback repeated')
          return result,err
        end
        function load(owner) return call('load',owner or project) end
        function save(value,opts,owner) return call('save',owner or project,value,opts or {}) end
        function raw(owner)
          local file=io.open(assert(S.path(owner or project)),'rb')
          if not file then return nil end
          local bytes=file:read('*a');file:close();return bytes
        end
        function overwrite(bytes,owner)
          local path=assert(S.path(owner or project))
          vim.fn.mkdir(vim.fs.dirname(path),'p')
          local file=assert(io.open(path,'wb'));assert(file:write(bytes));assert(file:close())
        end
      ]],
        cfg,
        dir
      )
      clients[index] = f
    end
    check(clients, jobs)
  end, debug.traceback)
  for _, job in ipairs(jobs) do
    pcall(vim.fn.jobstop, job)
  end
  if #jobs > 0 then
    pcall(vim.fn.jobwait, jobs, 1000)
  end
  vim.fn.delete(absolute, "rf")
  if not ok then
    error(err, 0)
  end
end

t.describe("work context metadata storage", function()
  t.it("a missing bucket is empty and an asynchronous save roundtrips immutable metadata", function()
    native(function(clients)
      clients[1].lua([[
        assert(#assert(load())==0 and raw()==nil)
        local input=draft();input.search=recipe()
        local copy=vim.deepcopy(input)
        local card=assert(save(input))
        assert(vim.deep_equal(copy,input),'store mutated draft')
        assert(card.id:match('^[%w_-]+$') and card.revision==1 and card.created_at>0 and card.updated_at>0)
        assert(card.files[1].modified and card.has_result and card.search.mode.word)
        input.name='changed caller';card.files[1].line=999
        local rows=assert(load())
        assert(#rows==1 and rows[1].name=='Investigation A' and rows[1].files[1].line==3)
        assert(rows[1].files[1].disk.mtime_nsec==25)
        assert(not raw():find('bufnr',1,true) and not raw():find('jobid',1,true))
      ]])
    end)
  end)
  t.it("independent live instances reread and merge different cards into one project bucket", function()
    native(function(clients)
      for _, f in ipairs(clients) do
        f.lua("assert(#assert(load())==0)")
      end
      local first = clients[1].lua("return assert(save(draft('A')))")
      local second = clients[2].lua("return assert(save(draft('B')))")
      t.assert_true(first.id ~= second.id)
      for _, f in ipairs(clients) do
        local rows = f.lua("return assert(load())")
        t.assert_eq(#rows, 2)
        t.assert_eq(rows[1].id, second.id)
        t.assert_eq(rows[2].id, first.id)
      end
    end, 2)
  end)
  t.it("same-card stale updates and deletes preserve the newer foreign revision", function()
    native(function(clients)
      local old = clients[1].lua("return assert(save(draft('A')))")
      local newer = clients[2].lua(
        "local card=...; return assert(save(draft('newer'),{id=card.id,expected_revision=card.revision}))",
        old
      )
      t.assert_eq(newer.id, old.id)
      t.assert_eq(newer.revision, 2)
      clients[1].lua(
        [[
        local old=...
        local before=raw()
        local result,err=save(draft('stale'),{id=old.id,expected_revision=old.revision})
        assert(result==nil and err:find('revision:',1,true) and raw()==before)
        result,err=call('delete',project,old.id,old.revision)
        assert(result==nil and err:find('revision:',1,true) and raw()==before)
        assert(load()[1].name=='newer')
      ]],
        old
      )
    end, 2)
  end)
  t.it("metadata remains readable after its original process exits without reviving native IDs", function()
    native(function(clients, jobs)
      local old = clients[1].lua("return assert(save(draft('persisted point')))")
      t.assert_true(vim.fn.jobstop(jobs[1]) == 1)
      vim.fn.jobwait({ jobs[1] }, 1000)
      clients[2].lua(
        [[
        local id=...
        local buffers=#vim.api.nvim_list_bufs()
        local cards=assert(load())
        assert(#cards==1 and cards[1].id==id and cards[1].has_result)
        assert(#vim.api.nvim_list_bufs()==buffers,'reading metadata loaded code files')
        local decoded=vim.json.decode(raw())
        assert(decoded.version==1 and decoded.project.identity)
        local forbidden={buf=true,bufnr=true,win=true,tab=true,qf_id=true,jobid=true,run_id=true,text=true,lines=true,errors=true,log=true}
        local function inspect(value)
          for key,child in pairs(value) do
            assert(not forbidden[key],'native evidence leaked into metadata')
            if type(child)=='table' then inspect(child) end
          end
        end
        inspect(decoded)
      ]],
        old.id
      )
    end, 2)
  end)
  t.it("a full sixteen-card bucket refuses additions and permits revision-checked updates", function()
    native(function(clients)
      clients[1].lua([[
        local cards={}
        for index=1,16 do cards[index]=assert(save(draft('card '..index))) end
        local before=raw()
        local extra,err=save(draft('seventeenth'))
        assert(extra==nil and err:find('full:',1,true) and raw()==before)
        local first=cards[1]
        local updated=assert(save(draft('updated existing'),{id=first.id,expected_revision=first.revision}))
        assert(updated.id==first.id and updated.revision==2 and updated.created_at==first.created_at)
        assert(#assert(load())==16 and load()[1].id==first.id)
      ]])
    end)
  end)
  t.it("valid thirty-two-file and byte-boundary cards survive while oversized drafts do not write", function()
    native(function(clients)
      clients[1].lua([[
        local value=draft(string.rep('你',42));value.note=string.rep('n',2048)
        value.files={}
        for index=1,32 do value.files[index]={path=source,line=index,col=1} end
        value.active=32
        local card=assert(save(value))
        assert(#card.files==32 and card.active==32 and #card.name==126 and #card.note==2048)
        local before=raw()
        local invalid={}
        local function bad(change) local copy=vim.deepcopy(value);change(copy);invalid[#invalid+1]=copy end
        bad(function(copy) copy.files[33]={path=source,line=1,col=1} end)
        bad(function(copy) copy.name=string.rep('你',43) end)
        bad(function(copy) copy.note=string.rep('n',2049) end)
        bad(function(copy) copy.files[1].path=project.root..'/'..string.rep('x',2048) end)
        for _,copy in ipairs(invalid) do local result,err=save(copy);assert(result==nil and err and raw()==before) end
      ]])
    end)
  end)
  t.it("cumulative encoded bytes refuse the next valid card without evicting earlier points", function()
    native(function(clients)
      clients[1].lua([[
        local value=draft();value.note=string.rep('n',2048)
        local prefix=project.root..'/'
        local longpath=prefix..string.rep('\\',2048-#prefix)
        value.files={}
        for index=1,32 do value.files[index]={path=longpath,line=1,col=1} end
        value.search=recipe();value.search.query=string.rep('\\',4096);value.search.mode.regex=true
        for _,key in ipairs({'include','exclude','extra_globs'}) do
          value.search.filters[key]={}
          for index=1,16 do value.search.filters[key][index]='*'..string.rep('\\',255) end
        end
        value.search.filters.pattern=string.rep('\\',2048)
        local count=0
        for index=1,16 do
          value.name='large metadata '..index
          local before=raw()
          local card,err=save(value)
          if not card then
            assert(err:find('budget:',1,true),'collection did not enforce byte budget')
            assert(raw()==before and #assert(load())==count and #before<=S.limits.bytes)
            assert(count>0 and count<16)
            return
          end
          count=count+1
        end
        error('encoded byte budget was never reached')
      ]])
    end)
  end)
  t.it("schema validation rejects native references, text and invalid source coordinates", function()
    native(function(clients)
      clients[1].lua([[
        assert(save(draft()))
        local before=raw()
        local mutations={
          function(value) value.buf=vim.api.nvim_get_current_buf() end,
          function(value) value.id='caller chosen identity' end,
          function(value) value.errors={{text='persisted compiler error'}} end,
          function(value) value.files[1].bufnr=1 end,
          function(value) value.files[1].lines={'unsaved text'} end,
          function(value) value.files[1].path='relative.cpp' end,
          function(value) value.files[1].line=0 end,
          function(value) value.files[1].col=0 end,
          function(value) value.files[1].col=1.5 end,
          function(value) value.files[1].modified='true' end,
          function(value) value.files[1].disk.size=-1 end,
          function(value) value.files[1].disk.mtime_nsec=1000000000 end,
          function(value) value.files[1].disk.qf_id=1 end,
          function(value) value.active=2 end,
          function(value) value.has_result=1 end,
          function(value) value.note=false end,
        }
        for _,change in ipairs(mutations) do
          local value=draft();change(value)
          local result,err=save(value)
          assert(result==nil and type(err)=='string' and raw()==before)
        end
        local result,err=save(draft(),{id=load()[1].id})
        assert(result==nil and err:find('revision:',1,true) and raw()==before)
        result,err=save(draft(),{expected_revision=1})
        assert(result==nil and err:find('revision:',1,true) and raw()==before)
      ]])
    end)
  end)
  t.it("only complete allowlisted search intent from the same project is retained", function()
    native(function(clients)
      clients[1].lua([[
        local good=draft();good.search=recipe()
        assert(save(good))
        local before=raw()
        local foreign=draft();foreign.search=recipe(other)
        local result,err=save(foreign)
        assert(result==nil and err:find('project:',1,true) and raw()==before)
        local invalid={
          function(r) r.source='arbitrary-provider' end,
          function(r) r.command='echo executable' end,
          function(r) r.query='query --glob something' end,
          function(r) r.scope.roots={other.root} end,
        }
        for _,change in ipairs(invalid) do
          local value=draft();value.search=recipe();change(value.search)
          local failed,failure=save(value)
          assert(failed==nil and failure:find('schema:',1,true) and raw()==before)
        end
      ]])
    end)
  end)
  t.it("canonical project aliases share a bucket while same-basename checkouts remain distinct", function()
    native(function(clients)
      clients[1].lua([[
        local alias=vim.deepcopy(project)
        alias.root=project.root..'/.'
        alias.identity=project.root..'/./Game.uproject'
        assert(S.key(project)==S.key(alias) and S.path(project)==S.path(alias))
        if vim.fn.has('win32')==1 then
          alias.identity=alias.identity:gsub('/','\\'):upper()
          alias.root=alias.root:gsub('/','\\'):upper()
          assert(S.key(project)==S.key(alias))
        end
        local left=vim.fs.dirname(project.root)..'/One/Game'
        local right=vim.fs.dirname(project.root)..'/Two/Game'
        vim.fn.mkdir(left,'p');vim.fn.mkdir(right,'p')
        vim.fn.writefile({'{}'},left..'/Game.uproject');vim.fn.writefile({'{}'},right..'/Game.uproject')
        local one={root=left,identity=left..'/Game.uproject',engine=project.engine}
        local two={root=right,identity=right..'/Game.uproject',engine=project.engine}
        assert(S.key(one)~=S.key(two))
        assert(save(draft('one'),{},one));assert(save(draft('two'),{},two))
        assert(#assert(load(one))==1 and load(one)[1].name=='one')
        assert(#assert(load(two))==1 and load(two)[1].name=='two')
      ]])
    end)
  end)
  t.it("corrupt, foreign and unsupported collections are never treated as an empty bucket", function()
    native(function(clients)
      clients[1].lua([[
        assert(save(draft()))
        local valid=vim.json.decode(raw())
        local invalid={'{broken json',vim.json.encode({version=1,project=project,cards={}})}
        local function bad(change)
          local copy=vim.deepcopy(valid);change(copy);invalid[#invalid+1]=vim.json.encode(copy)
        end
        -- An empty array is valid; the explicit object shape is not.
        invalid[2]=vim.json.encode({version=1,project=project,cards=vim.empty_dict()})
        bad(function(value) value.version=2 end)
        bad(function(value) value.project=other end)
        bad(function(value) value.cards[1].qf_id=1 end)
        bad(function(value) value.cards[1].revision=0 end)
        bad(function(value) value.cards[2]=vim.deepcopy(value.cards[1]) end)
        bad(function(value) value.jobid=1 end)
        for _,bytes in ipairs(invalid) do
          overwrite(bytes)
          local rows,err=load()
          assert(rows==nil and err:find('corrupt:',1,true))
          local result,failure=save(draft('must not replace'))
          assert(result==nil and failure and raw()==bytes)
        end
      ]])
    end)
  end)
  t.it("the disk file hard budget is checked before decoding or overwriting", function()
    native(function(clients)
      clients[1].lua([[
        local bytes=string.rep('x',S.limits.bytes+1)
        overwrite(bytes)
        local cards,err=load()
        assert(cards==nil and err:find('budget:',1,true))
        local card,failure=save(draft())
        assert(card==nil and failure:find('budget:',1,true) and raw()==bytes)
      ]])
    end)
  end)
  t.it("a real live foreign lease refuses saving until an explicit later retry", function()
    native(function(clients)
      clients[1].lua([[
        assert(save(draft('existing')))
        held=assert(require('ue.file_lock').acquire(assert(S.path(project))..'.lock'))
      ]])
      clients[2].lua([[
        local before=raw()
        local card,err=save(draft('blocked'))
        assert(card==nil and err:find('busy:',1,true) and raw()==before)
      ]])
      clients[1].lua("assert(require('ue.file_lock').release(held))")
      clients[2].lua("assert(save(draft('retry')));assert(#assert(load())==2)")
    end, 2)
  end)
  t.it("revision-checked deletion removes only metadata and leaves source disk and dirty text intact", function()
    native(function(clients)
      clients[1].lua([[
        vim.cmd.edit(vim.fn.fnameescape(source))
        local buf=vim.api.nvim_get_current_buf()
        vim.api.nvim_buf_set_lines(buf,0,-1,false,{'unsaved source stays here'})
        local disk=vim.fn.readfile(source)
        local a=assert(save(draft('delete metadata')));local b=assert(save(draft('retained')))
        assert(call('delete',project,a.id,a.revision))
        local rows=assert(load());assert(#rows==1 and rows[1].id==b.id)
        assert(vim.deep_equal(vim.fn.readfile(source),disk))
        assert(vim.bo[buf].modified and vim.api.nvim_buf_get_lines(buf,0,-1,false)[1]=='unsaved source stays here')
        assert(call('delete',project,b.id,b.revision));assert(#assert(load())==0)
      ]])
    end)
  end)
end)

t.describe("work context operation-local I/O failure evidence", function()
  t.it("a lease API exception returns one asynchronous failure without altering disk", function()
    native(function(clients)
      clients[1].lua([[
        assert(save(draft()))
        local before=raw();local locks=require('ue.file_lock');local acquire=locks.acquire
        locks.acquire=function() error('EIO: owned lease seam') end
        local ok,card,err=pcall(save,draft('lease failure'))
        locks.acquire=acquire
        assert(ok and card==nil and err:find('busy:',1,true) and raw()==before)
        assert(uv.fs_stat(assert(S.path(project))..'.lock')==nil)
      ]])
    end)
  end)
  t.it("an injected write failure preserves previous bytes and releases the real lease", function()
    native(function(clients)
      clients[1].lua([[
        local original=assert(save(draft()))
        local before=raw()
        local write=uv.fs_write
        uv.fs_write=function(_,_,_,done) vim.schedule(function() done('EIO: owned write seam',0) end) end
        local ok,card,err=pcall(save,draft('failed update'),{id=original.id,expected_revision=original.revision})
        uv.fs_write=write
        assert(ok and card==nil and err:find('write:',1,true) and raw()==before)
        assert(uv.fs_stat(assert(S.path(project))..'.lock')==nil)
        assert(save(draft('after failure'),{id=original.id,expected_revision=original.revision}))
      ]])
    end)
  end)
  t.it("an injected atomic rename failure never replaces the previous collection", function()
    native(function(clients)
      clients[1].lua([[
        assert(save(draft()))
        local before=raw();local path=assert(S.path(project))
        local rename=uv.fs_rename
        uv.fs_rename=function(from,to,done)
          if done and to==path then vim.schedule(function() done('EIO: owned rename seam') end);return end
          return rename(from,to,done)
        end
        local ok,card,err=pcall(save,draft('failed publish'))
        uv.fs_rename=rename
        assert(ok and card==nil and err:find('write:',1,true) and raw()==before)
        assert(uv.fs_stat(path..'.lock')==nil and #assert(load())==1)
      ]])
    end)
  end)
  t.it("a prepublication read failure cannot turn an existing bucket into a new empty one", function()
    native(function(clients)
      clients[1].lua([[
        assert(save(draft()))
        local before=raw();local read=uv.fs_read;local failed=false
        uv.fs_read=function(fd,size,offset,done)
          if not failed then failed=true;vim.schedule(function() done('EIO: owned read seam',nil) end);return end
          return read(fd,size,offset,done)
        end
        local ok,card,err=pcall(save,draft('must not overwrite'))
        uv.fs_read=read
        assert(ok and failed and card==nil and err:find('read:',1,true) and raw()==before)
        assert(uv.fs_stat(assert(S.path(project))..'.lock')==nil)
      ]])
    end)
  end)
  t.it("failed published readback rolls back only its proven owned update and reports failure", function()
    native(function(clients)
      clients[1].lua([[
        local original=assert(save(draft()))
        local before=raw();local path=assert(S.path(project))
        local open,rename=uv.fs_open,uv.fs_rename
        local published,failed=false,false
        uv.fs_rename=function(from,to,done)
          if done and to==path then return rename(from,to,function(err) published=not err;done(err) end) end
          return rename(from,to,done)
        end
        uv.fs_open=function(name,flags,mode,done)
          if done and name==path and flags=='r' and published and not failed then
            failed=true;vim.schedule(function() done('EIO: owned readback seam',nil) end);return
          end
          return open(name,flags,mode,done)
        end
        local ok,card,err=pcall(save,draft('unverified'),{id=original.id,expected_revision=original.revision})
        uv.fs_open,uv.fs_rename=open,rename
        assert(ok and published and failed and card==nil and err:find('verify:',1,true) and raw()==before)
        assert(uv.fs_stat(path..'.lock')==nil and load()[1].revision==original.revision)
      ]])
    end)
  end)
  t.it("failed first-publication verification removes only its owned new collection", function()
    native(function(clients)
      clients[1].lua([[
        local path=assert(S.path(project));local open,rename=uv.fs_open,uv.fs_rename
        local published,failed=false,false
        uv.fs_rename=function(from,to,done)
          if done and to==path then return rename(from,to,function(err) published=not err;done(err) end) end
          return rename(from,to,done)
        end
        uv.fs_open=function(name,flags,mode,done)
          if done and name==path and flags=='r' and published and not failed then
            failed=true;vim.schedule(function() done('EIO: owned first-readback seam',nil) end);return
          end
          return open(name,flags,mode,done)
        end
        local ok,card,err=pcall(save,draft())
        uv.fs_open,uv.fs_rename=open,rename
        assert(ok and failed and card==nil and err:find('verify:',1,true) and raw()==nil)
        assert(uv.fs_stat(path..'.lock')==nil and #assert(load())==0)
      ]])
    end)
  end)
  t.it("a foreign postpublication replacement is preserved when rollback ownership cannot be proved", function()
    native(function(clients)
      clients[1].lua([[
        local original=assert(save(draft()))
        local path=assert(S.path(project));local open,rename=uv.fs_open,uv.fs_rename
        local published,replaced,foreign=false,false,nil
        uv.fs_rename=function(from,to,done)
          if done and to==path then return rename(from,to,function(err) published=not err;done(err) end) end
          return rename(from,to,done)
        end
        uv.fs_open=function(name,flags,mode,done)
          if done and name==path and flags=='r' and published and not replaced then
            replaced=true
            local value=vim.json.decode(raw())
            value.cards[1].note='foreign later metadata';value.cards[1].revision=value.cards[1].revision+1
            foreign=vim.json.encode(value);overwrite(foreign)
          end
          return open(name,flags,mode,done)
        end
        local ok,card,err=pcall(save,draft('owned update'),{id=original.id,expected_revision=original.revision})
        uv.fs_open,uv.fs_rename=open,rename
        assert(ok and replaced and card==nil and err:find('verify:',1,true) and raw()==foreign)
        assert(load()[1].note=='foreign later metadata' and uv.fs_stat(path..'.lock')==nil)
      ]])
    end)
  end)
end)
