local t = require("tests.harness")
local cfg = t.bootstrap()
local sequence = 0

local function native(check, shared)
  sequence = sequence + 1
  local directory = shared or ((vim.env.NVIM_TEST_RUN_ROOT or vim.fn.tempname()) .. "/work-context-" .. sequence)
  vim.fn.mkdir(directory, "p")
  local job = vim.fn.jobstart({ vim.v.progpath, "--headless", "--embed", "-u", "NONE", "-i", "NONE", "-n" }, {
    rpc = true,
    env = {
      XDG_STATE_HOME = directory .. "/state",
      NVIM_UE_PROBE_PATH = directory .. "/probe.json",
      NVIM_LOG_FILE = directory .. "/nvim.log",
      NVIM_UE_LOG_DIR = directory .. "/logs",
    },
  })
  t.assert_true(job > 0, "isolated native Neovim unavailable")
  local function lua(code, ...)
    return vim.rpcrequest(job, "nvim_exec_lua", code, { ... })
  end
  lua(
    [[
    local cfg, directory = ...
    vim.opt.rtp:prepend(cfg)
    package.path = cfg .. '/lua/?.lua;' .. cfg .. '/lua/?/init.lua;' .. package.path
    vim.o.hidden, vim.o.swapfile, vim.o.shada, vim.o.more = true, false, '', false
    Root = directory .. '/project'
    vim.fn.mkdir(Root, 'p')
    local function file(name, lines)
      local path = Root .. '/' .. name
      if vim.fn.filereadable(path) == 0 then vim.fn.writefile(lines, path) end
      return path
    end
    Identity = file('Owned.uproject', {'{}'})
    APath = file('A.cpp', {'中文 FindCall()', 'saved line two', 'callback line three', 'last line'})
    BPath = file('B.cpp', {'interrupted disk version', 'line two'})
    HeaderPath = file('A.h', {'header one', 'header two'})
    HiddenPath = file('Unrelated.cpp', {'unrelated loaded file'})
    Recipes = require('utils.search_recipe')
    Project = Recipes.context({ project_root = Root, uproject = Identity })
    package.loaded['ue'] = { resolve_context = function()
      return { project_root = Project.root, uproject = Project.identity, engine_root = Project.engine }
    end }
    C = require('utils.work_context')
    S = require('utils.work_context_store')
    Hub = require('utils.ue_hub')
    Messages = {}; vim.notify = function(value) Messages[#Messages + 1] = tostring(value) end
    vim.api.nvim_cmd({cmd='edit',args={APath},magic={file=false,bar=false}}, {})
    AWin, ABuf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
    vim.api.nvim_win_set_cursor(AWin,{1,7})
    Recipe = {version=1,source='grep',query='FindCall',project=Project,
      scope={kind='project',roots={Project.root},code_only=true},
      mode={regex=false,case='sensitive',word=false},
      filters={include={},exclude={},extensions={},pattern='',hidden=false,ignored=false,follow=false,extra_globs={}}}
    function query()
      vim.fn.setqflist({}, ' ', {title='owned search A',items={{bufnr=ABuf,lnum=1,col=8,text='saved search hit'}},
        context={kind='ue_workspace_pin',version=1,recipe=Recipe}})
      return vim.fn.getqflist({id=0,changedtick=0,items=0})
    end
    function await(start)
      local result, message, finished
      start(function(value, err) result,message,finished=value,err,true end)
      assert(vim.wait(4000,function() return finished end,10), 'owned async store completion')
      return result,message
    end
    function save(opts)
      opts = vim.tbl_extend('force',{name='调查 A',note='next quoted "step" | :qall!',project=Project},opts or {})
      local capture, err = C.capture(opts); assert(capture,err)
      local card, save_err = await(function(done) C.save(capture,{},done) end)
      assert(card,save_err)
      return card,capture
    end
    function interrupt()
      vim.api.nvim_cmd({cmd='edit',args={BPath},magic={file=false,bar=false}}, {})
      BWin, BBuf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
      vim.api.nvim_buf_set_lines(BBuf,0,-1,false,{'dirty B remains', 'new task line'})
      BTick = vim.api.nvim_buf_get_changedtick(BBuf)
      vim.fn.setqflist({},' ',{title='unrelated B result',items={{bufnr=BBuf,lnum=1,text='B result'}}})
      BQF = vim.fn.getqflist({id=0,changedtick=0,items=0})
    end
    function preserved()
      return vim.api.nvim_win_is_valid(BWin) and vim.api.nvim_win_get_buf(BWin)==BBuf and vim.bo[BBuf].modified
        and vim.api.nvim_buf_get_changedtick(BBuf)==BTick
        and vim.api.nvim_buf_get_lines(BBuf,0,-1,false)[1]=='dirty B remains'
        and vim.deep_equal(BQF,vim.fn.getqflist({id=0,changedtick=0,items=0}))
    end
  ]],
    cfg,
    directory
  )
  local ok, err = pcall(check, { lua = lua, directory = directory })
  pcall(vim.fn.jobstop, job)
  pcall(vim.fn.jobwait, { job }, 1000)
  if not ok then
    error(err, 0)
  end
  return directory
end

local function all(result, keys)
  for _, name in ipairs(keys or vim.tbl_keys(result)) do
    t.assert_true(result[name], name)
  end
end

t.describe("ide_work_context: explicit metadata capture", function()
  t.it("captures visible named sources with UTF-8 byte positions; a hidden unrelated file is excluded", function()
    native(function(f)
      local result = f.lua([[
        local header=vim.fn.bufadd(HeaderPath);vim.fn.bufload(header)
        local win=vim.api.nvim_open_win(header,false,{split='right',win=AWin})
        vim.api.nvim_win_set_cursor(win,{2,3})
        local hidden=vim.fn.bufadd(HiddenPath);vim.fn.bufload(hidden)
        query()
        local capture=assert(C.capture({name='visible',project=Project}))
        local encoded=vim.json.encode(capture.draft)
        return {files=#capture.draft.files,byte=capture.draft.files[1].col,
          active=capture.draft.active,query=capture.draft.search.query,
          metadata_only=not encoded:find('bufnr',1,true) and not encoded:find('qf_id',1,true)
            and not encoded:find('changedtick',1,true),live_result=capture.live.result.id>0,
          hidden_excluded=not encoded:find('Unrelated.cpp',1,true),no_text=not encoded:find('saved line two',1,true)}
      ]])
      t.assert_eq(result.files, 2)
      t.assert_eq(result.byte, 8)
      t.assert_eq(result.active, 1)
      t.assert_eq(result.query, "FindCall")
      all(result, { "metadata_only", "live_result", "hidden_excluded", "no_text" })
    end)
  end)

  t.it("rejects unnamed/URI sources and includes only explicitly selected hidden associations", function()
    native(function(f)
      local result = f.lua([[
        local hidden=vim.fn.bufadd(HiddenPath);vim.fn.bufload(hidden)
        local capture=assert(C.capture({name='explicit',project=Project,files={hidden}}))
        vim.cmd.enew()
        local unnamed, unnamed_err=C.capture({name='no name',project=Project})
        vim.api.nvim_buf_set_name(0,'owned://uri')
        local uri, uri_err=C.capture({name='uri',project=Project})
        return {count=#capture.draft.files,hidden=capture.draft.files[2].path:find('Unrelated.cpp',1,true)~=nil,
          unnamed=unnamed==nil,uri=uri==nil,unnamed_err=unnamed_err,uri_err=uri_err}
      ]])
      t.assert_eq(result.count, 2)
      all(result, { "hidden", "unnamed", "uri" })
      t.assert_contains(result.unnamed_err, "命名")
      t.assert_contains(result.uri_err, "命名")
    end)
  end)

  t.it("only a complete same-project recipe associates current results; stale verification markers do not", function()
    native(function(f)
      local result = f.lua([[
        query()
        local valid=assert(C.capture({name='valid',project=Project}))
        local other=vim.deepcopy(Recipe);other.project.identity=Project.root..'/Different.uproject'
        vim.fn.setqflist({},'r',{items={{bufnr=ABuf,lnum=1,text='foreign query'}},context={recipe=other}})
        local foreign=assert(C.capture({name='foreign',project=Project}))
        local runs=require('utils.verification_runs')
        local id=runs.begin({project_root=Project.root,operation='owned fixture'})
        query()
        local qf=vim.fn.getqflist({id=0,changedtick=0})
        runs.complete(id,{code=0,qf_id=qf.id,qf_tick=qf.changedtick,items={}})
        vim.fn.setqflist({},'r',{items={{bufnr=ABuf,lnum=2,text='replacement'}},context={verification_id=id,recipe=Recipe}})
        local replaced=assert(C.capture({name='replacement',project=Project}))
        return {valid=valid.draft.search~=nil and valid.live.result~=nil,
          foreign=foreign.draft.search==nil and not foreign.draft.has_result,
          stale_run=replaced.draft.search==nil and not replaced.draft.has_result and replaced.live.result==nil}
      ]])
      all(result)
    end)
  end)
end)

t.describe("ide_work_context: native interrupted editor recovery", function()
  t.it("save A then dirty B/new quickfix; restore only A in a new tab without replaying query or results", function()
    native(function(f)
      local result = f.lua([[
        query();local card=save()
        interrupt()
        local before_tabs=#vim.api.nvim_list_tabpages()
        local win,err=C.restore(card,{project=Project,source_win=BWin})
        return {opened=win~=nil,err=err,own_tab=#vim.api.nvim_list_tabpages()==before_tabs+1,
          same_a=win and vim.api.nvim_win_get_buf(win)==ABuf,
          exact_byte=win and vim.deep_equal(vim.api.nvim_win_get_cursor(win),{1,7}),b=preserved(),
          note=C.active(Project).note==card.note,header_lazy=vim.fn.bufnr(HeaderPath)==-1,
          original_result=C.result_status(card)~=nil}
      ]])
      all(result, { "opened", "own_tab", "same_a", "exact_byte", "b", "note", "header_lazy", "original_result" })
    end)
  end)

  t.it("loaded dirty A is reused without disk reload or save, with an explicit historical-coordinate notice", function()
    native(function(f)
      local result = f.lua([[
        local card=save()
        vim.api.nvim_buf_set_lines(ABuf,1,2,false,{'new unsaved A text'})
        local tick=vim.api.nvim_buf_get_changedtick(ABuf)
        interrupt()
        local win,notice=C.restore(card,{project=Project,source_win=BWin})
        return {opened=win~=nil,same_buf=win and vim.api.nvim_win_get_buf(win)==ABuf,
          dirty=vim.bo[ABuf].modified,text=vim.api.nvim_buf_get_lines(ABuf,1,2,false)[1]=='new unsaved A text',
          same_tick=vim.api.nvim_buf_get_changedtick(ABuf)==tick,b=preserved(),notice=notice}
      ]])
      all(result, { "opened", "same_buf", "dirty", "text", "same_tick", "b" })
      t.assert_contains(result.notice, "历史坐标")
    end)
  end)

  t.it("cold and repeated warm restoration use the saved byte position without false callback refusal", function()
    native(function(f)
      local result = f.lua([[
        local card=save()
        interrupt()
        vim.api.nvim_buf_delete(ABuf,{force=false})
        local outcomes={}
        for index=1,3 do
          local win,err=C.restore(card,{project=Project,source_win=BWin})
          outcomes[index]=win~=nil and vim.deep_equal(vim.api.nvim_win_get_cursor(win),{1,7}) and err==nil
          if not outcomes[index] then error('repeat '..index..' '..tostring(err)..' cursor='..vim.inspect(vim.api.nvim_win_get_cursor(0))) end
        end
        return {cold=outcomes[1],warm=outcomes[2],repeat_warm=outcomes[3],b=preserved()}
      ]])
      all(result)
    end)
  end)

  t.it("cold BufReadPost edits remain the active document even when the callback clears modified", function()
    native(function(f)
      local result = f.lua([[
        local card=save();interrupt()
        vim.api.nvim_buf_delete(ABuf,{force=false})
        local read_buf=vim.fn.bufadd(APath)
        vim.api.nvim_create_autocmd('BufReadPost',{buffer=read_buf,once=true,callback=function(ev)
          vim.api.nvim_buf_set_lines(ev.buf,0,-1,false,
            {'new read callback input','new line two','new line three','new line four'})
          vim.bo[ev.buf].modified=false
        end})
        local win,notice=C.restore(card,{project=Project,source_win=BWin})
        return {refused=win==nil,notice=notice,same_buf=vim.api.nvim_get_current_buf()==read_buf,
          text=vim.api.nvim_buf_get_lines(read_buf,0,-1,false)[1]=='new read callback input',
          clean=not vim.bo[read_buf].modified,
          no_saved_coordinate=not vim.deep_equal(vim.api.nvim_win_get_cursor(0),{1,7}),b=preserved()}
      ]])
      all(result, { "refused", "same_buf", "text", "clean", "no_saved_coordinate", "b" })
      t.assert_contains(result.notice, "新输入")
    end)
  end)

  t.it("BufEnter cursor-only intent survives and does not receive the saved coordinate afterward", function()
    native(function(f)
      local result = f.lua([[
        local card=save();interrupt()
        local handlers=#vim.api.nvim_get_autocmds({event='BufEnter'})
        vim.api.nvim_create_autocmd('BufEnter',{buffer=ABuf,once=true,callback=function()
          vim.api.nvim_win_set_cursor(0,{3,2})
        end})
        local win,notice=C.restore(card,{project=Project,source_win=BWin})
        return {refused=win==nil,notice=notice,cursor=vim.deep_equal(vim.api.nvim_win_get_cursor(0),{3,2}),
          b=preserved(),observer_removed=#vim.api.nvim_get_autocmds({event='BufEnter'})==handlers}
      ]])
      all(result, { "refused", "cursor", "b", "observer_removed" })
      t.assert_contains(result.notice, "回调")
    end)
  end)

  t.it("a tab-entry callback's text with modified cleared is preserved instead of retargeted", function()
    native(function(f)
      local result = f.lua([[
        local card=save();interrupt()
        local userbuf
        vim.api.nvim_create_autocmd('TabNewEntered',{once=true,callback=function()
          userbuf=vim.api.nvim_get_current_buf()
          vim.api.nvim_buf_set_lines(userbuf,0,-1,false,{'callback owns this document'})
          vim.bo[userbuf].modified=false
        end})
        local win,notice=C.restore(card,{project=Project,source_win=BWin})
        return {refused=win==nil,notice=notice,same_buf=vim.api.nvim_get_current_buf()==userbuf,
          text=vim.api.nvim_buf_get_lines(userbuf,0,-1,false)[1]=='callback owns this document',b=preserved()}
      ]])
      all(result, { "refused", "same_buf", "text", "b" })
      t.assert_contains(result.notice, "新输入")
    end)
  end)

  t.it("BufLeave input in the new empty editor vetoes only the old restore assignment", function()
    native(function(f)
      local result = f.lua([[
        local card=save();interrupt()
        local userbuf
        vim.api.nvim_create_autocmd('BufLeave',{callback=function(ev)
          if vim.api.nvim_buf_get_name(ev.buf)=='' and vim.bo[ev.buf].buftype=='' and ev.buf~=BBuf then
            userbuf=ev.buf
            vim.api.nvim_buf_set_lines(userbuf,0,-1,false,{'new callback input'})
            vim.api.nvim_win_set_cursor(0,{1,2})
          end
        end})
        local win,notice=C.restore(card,{project=Project,source_win=BWin})
        return {refused=win==nil,notice=notice,same_buf=vim.api.nvim_get_current_buf()==userbuf,
          visible=userbuf and #vim.fn.win_findbuf(userbuf)>0,
          text=userbuf and vim.api.nvim_buf_get_lines(userbuf,0,-1,false)[1]=='new callback input',
          cursor=vim.deep_equal(vim.api.nvim_win_get_cursor(0),{1,2}),b=preserved()}
      ]])
      all(result, { "refused", "same_buf", "visible", "text", "cursor", "b" })
      t.assert_contains(result.notice, "新输入")
    end)
  end)

  t.it("missing bracketed filenames cannot pattern-match a different loaded buffer", function()
    native(function(f)
      local result = f.lua([[
        local path=Root..'/source1.cpp';vim.fn.writefile({'wrong owner'},path)
        local wrong=vim.fn.bufadd(path);vim.fn.bufload(wrong)
        local card=save();interrupt()
        local changed=vim.deepcopy(card);changed.files[1].path=Root..'/source[1].cpp'
        local published,err=await(function(done)S.save(Project,{name=changed.name,note=changed.note,
          files=changed.files,active=1},{id=card.id,expected_revision=card.revision},done)end)
        assert(published,err)
        assert(await(function(done)C.refresh(Project,done)end))
        local selected=C.rows(Project)[1]
        local before=#vim.api.nvim_list_tabpages()
        local win,notice=C.restore(selected,{project=Project,source_win=BWin})
        return {refused=win==nil,notice=notice,no_tab=#vim.api.nvim_list_tabpages()==before,
          wrong_text=vim.api.nvim_buf_get_lines(wrong,0,-1,false)[1]=='wrong owner',b=preserved()}
      ]])
      all(result, { "refused", "no_tab", "wrong_text", "b" })
      t.assert_contains(result.notice, "不存在")
    end)
  end)

  t.it("invalid saved line or UTF-8 interior column opens the file but reports position unavailable", function()
    native(function(f)
      local result = f.lua([[
        local card=save();interrupt()
        local changed=vim.deepcopy(card.files);changed[1].col=2
        local published=assert(await(function(done)S.save(Project,{name=card.name,note=card.note,files=changed,active=1},
          {id=card.id,expected_revision=card.revision},done)end))
        assert(await(function(done)C.refresh(Project,done)end))
        local win,notice=C.restore(C.rows(Project)[1],{project=Project,source_win=BWin})
        return {opened=win~=nil,notice=notice,b=preserved()}
      ]])
      all(result, { "opened", "b" })
      t.assert_contains(result.notice, "保存位置不可用")
      t.assert_contains(result.notice, "UTF-8")
    end)
  end)
end)

t.describe("ide_work_context: cache, revision and exact result ownership", function()
  t.it("self note/add CAS retains the same valid historical result; external revisions expire it", function()
    native(function(f)
      local result = f.lua([[
        query();local card=save();local original=assert(C.result_status(card))
        local note=assert(await(function(done)C.edit_note({card=card,note='next update'},done)end))
        local kept_note=C.result_status(note)
        vim.api.nvim_cmd({cmd='edit',args={HeaderPath},magic={file=false,bar=false}}, {})
        local appended=assert(await(function(done)C.append_current({card=note,project=Project},done)end))
        local kept_append=C.result_status(appended)
        local foreign=assert(await(function(done)S.save(Project,{name=appended.name,note='external metadata',
          files=appended.files,active=appended.active,search=appended.search,has_result=true},
          {id=appended.id,expected_revision=appended.revision},done)end))
        assert(await(function(done)C.refresh(Project,done)end))
        local current=C.rows(Project)[1]
        local expired,err=C.result_status(current)
        local stale,stale_err=await(function(done)C.edit_note({card=appended,note='stale'},done)end)
        return {note=kept_note and kept_note.id==original.id,append=kept_append and kept_append.id==original.id,
          appended=#appended.files==2,external=expired==nil,err=err,stale=stale==nil,
          revision=C.rows(Project)[1].revision==foreign.revision,stale_err=stale_err}
      ]])
      all(result, { "note", "append", "appended", "external", "stale", "revision" })
      t.assert_contains(result.err, "版本")
      t.assert_contains(result.stale_err, "版本")
    end)
  end)

  t.it("replaced original quickfix and explicit recipe reassociation never borrow unrelated current results", function()
    native(function(f)
      local result = f.lua([[
        query();local card=save();local original=assert(C.result_status(card))
        vim.fn.setqflist({},'r',{id=original.id,items={{bufnr=ABuf,lnum=2,text='replacement row'}}})
        local before=vim.fn.getqflist({id=0,changedtick=0,items=0})
        local win,err=C.show_result(card)
        local recipe=vim.deepcopy(Recipe);recipe.query='OtherCall'
        local updated=assert(await(function(done)C.associate_search({card=card,recipe=recipe},done)end))
        return {refused=win==nil,err=err,qf_same=vim.deep_equal(before,vim.fn.getqflist({id=0,changedtick=0,items=0})),
          no_old_result=C.result_status(updated)==nil,query=updated.search.query}
      ]])
      all(result, { "refused", "qf_same", "no_old_result" })
      t.assert_eq(result.query, "OtherCall")
      t.assert_contains(result.err, "原结果已修改")
    end)
  end)

  t.it("a real delayed load callback cannot leave a successful save permanently loading", function()
    native(function(f)
      local result = f.lua([[
        local card=save();assert(await(function(done)C.refresh(Project,done)end))
        local original=S.load;local held
        S.load=function(project,done)original(project,function(cards,err)held=function()done(cards,err)end end)end
        C.refresh(Project,function()end)
        assert(vim.wait(3000,function()return held~=nil end,10))
        local loading=C.status(Project).state=='loading'
        local updated=assert(await(function(done)C.edit_note({card=card,note='new note'},done)end))
        held();S.load=original
        return {was_loading=loading,settled=C.status(Project).state=='ready',
          new_revision=C.rows(Project)[1].revision==updated.revision}
      ]])
      all(result)
    end)
  end)

  t.it("metadata publication emits the existing Workbench event while pure cache reads do not", function()
    native(function(f)
      local result = f.lua([[
        local events=0
        vim.api.nvim_create_autocmd('User',{pattern='UEWorkbenchChanged',callback=function()events=events+1 end})
        local card=save()
        local published=events>0
        local count=events
        C.active(Project);C.status(Project);C.rows(Project)
        return {published=published,pure=events==count}
      ]])
      all(result)
    end)
  end)

  t.it("project selection without source edits invalidates a pending save's activation but not its metadata", function()
    native(function(f)
      local result = f.lua([[
        local capture=assert(C.capture({name='late A',project=Project}))
        local original=S.save;local held
        S.save=function(project,draft,opts,done)original(project,draft,opts,function(card,err)
          held=function()done(card,err)end
        end)end
        local completed
        C.save(capture,{},function(card)completed=card end)
        assert(vim.wait(3000,function()return held~=nil end,10))
        local tick=vim.api.nvim_buf_get_changedtick(ABuf)
        local cursor=vim.api.nvim_win_get_cursor(AWin)
        local generation=Hub.selection_generation()
        Hub.selection_changed()
        held();S.save=original
        return {metadata=completed~=nil and #C.rows(Project)==1,not_active=C.active(Project)==nil,
          source_same=vim.api.nvim_buf_get_changedtick(ABuf)==tick and vim.deep_equal(vim.api.nvim_win_get_cursor(AWin),cursor),
          generation=Hub.selection_generation()==generation+1,owner_expired=not C.owned(capture.source)}
      ]])
      all(result)
    end)
  end)

  t.it("a new native Neovim reads metadata only and never reuses old quickfix IDs or text", function()
    local directory, id
    directory = native(function(f)
      id = f.lua([[
        query()
        local header=vim.fn.bufadd(HeaderPath);vim.fn.bufload(header)
        local card=save({files={header}})
        return card.id
      ]])
    end)
    native(function(f)
      local result = f.lua(
        [[
        local expected=...
        -- Deliberately create a new process's qf with the same native id 1.
        interrupt()
        assert(await(function(done)C.refresh(Project,done)end))
        local card=C.rows(Project)[1]
        local ref,ref_err=C.result_status(card)
        local win,notice=C.restore(card,{project=Project,source_win=BWin})
        local stored=assert(S.path(Project))
        local raw=table.concat(vim.fn.readfile(stored),'\n')
        return {same_card=card.id==expected,metadata_note=card.note=='next quoted "step" | :qall!',
          metadata_query=card.search.query=='FindCall',no_live_ref=ref==nil,ref_err=ref_err,
          restored=win~=nil and vim.deep_equal(vim.api.nvim_win_get_cursor(win),{1,7}),
          header_lazy=vim.fn.bufnr(HeaderPath)==-1,b=preserved(),
          no_native_ids=not raw:find('qf_id',1,true) and not raw:find('bufnr',1,true) and not raw:find('run_id',1,true)}
      ]],
        id
      )
      all(result, {
        "same_card",
        "metadata_note",
        "metadata_query",
        "no_live_ref",
        "restored",
        "header_lazy",
        "b",
        "no_native_ids",
      })
      t.assert_contains(result.ref_err, "实例")
    end, directory)
  end)
end)
