local t = require("tests.harness")
local cfg = t.bootstrap()
local plugins = vim.fn.stdpath("data") .. "/lazy"
local python = vim.fn.exepath("python")
if python == "" then
  python = vim.fn.exepath("python3")
end
if python == "" or vim.fn.executable("rg") == 0 or vim.fn.isdirectory(plugins .. "/snacks.nvim") == 0 then
  t.skip("saved investigation native journey", "installed Python, rg and Snacks required", { native = true })
  return
end

-- Actual picker, rg, source/header buffers, dialogs, workbench and terminal jobs.
-- Only project identity and the clipboard provider are isolated boundaries.
local program = [=[
import hashlib,json,os,runpy,sys,threading,time,traceback
from pathlib import Path
root,plugins,out=map(Path,sys.argv[1:4]);case=sys.argv[4];nvim=sys.argv[5]
helper=runpy.run_path(str(root/'tools/measure_inlay_hints.py'))
class Session(helper['Nvim']):
    def call(self,method,*args):
        self.sequence+=1;ident=self.sequence
        self.process.stdin.write(helper['pack']([0,ident,method,args]));self.process.stdin.flush()
        deadline=time.monotonic()+8
        while time.monotonic()<deadline:
            message=self.messages.get(timeout=max(.01,deadline-time.monotonic()));self.consume(message)
            if isinstance(message,list)and message[:2]==[1,ident]:
                if message[2]:raise RuntimeError(message[2])
                return message[3]
        raise TimeoutError(method)
paths=['lua/utils/work_context.lua','lua/utils/work_context_restore.lua','lua/utils/work_context_ui.lua','lua/utils/work_context_store.lua','lua/utils/development_workbench.lua','lua/utils/bottom_panel.lua','lua/utils/document_location.lua','lua/utils/search_recipe.lua','lua/utils/workspace.lua','lua/utils/verification_runs.lua','lua/utils/ue_hub.lua','lua/plugins/snacks.lua','lua/ue/file_lock.lua','lua/ue.lua']
before={p:hashlib.sha256((root/p).read_bytes()).hexdigest()for p in paths}
project=out/'Project';project.mkdir(exist_ok=True)
(project/'Source.cpp').write_text('// UE 调查 InvestigateToken\nint main(){return 0;}\n',encoding='utf-8')
(project/'Header.h').write_text('// InvestigateToken header\n#pragma once\n',encoding='utf-8')
(project/'Other.cpp').write_text('// another task\nint other(){return 0;}\n',encoding='utf-8')
(project/'Investigation.uproject').write_text('{}\n',encoding='utf-8')
sessions=[];n=None
evidence={'case':case,'physical_gui':False,'clipboard':'provider isolated before first use; no clipboard actions'}
watchdog=threading.Timer(50,lambda:[s.process.kill()for s in sessions if s.process.poll()is None]);watchdog.daemon=True;watchdog.start()
def lua(code,*args):return n.lua(code,*args)
def keys(value):n.call('nvim_input',value)
def wait(code,*args):
    deadline=time.monotonic()+8
    while time.monotonic()<deadline:
        if lua(code,*args):return
        time.sleep(.015)
    raise AssertionError(code+' '+str(lua('return {mode=vim.fn.mode(),notices=Notices,buf=vim.api.nvim_get_current_buf(),name=vim.api.nvim_buf_get_name(0),cards=C and C.rows(Project),warm_before=WarmBefore,warm_actual=WarmBefore and {cursor=vim.api.nvim_win_get_cursor(0),mark=vim.api.nvim_buf_get_mark(WarmBefore.buf,string.char(34))}}')))
def start(index):
    global n
    n=Session(nvim,os.environ.copy(),out/('stderr-'+str(index)+'.log'));sessions.append(n)
    n.call('nvim_ui_attach',160,48,{'rgb':True,'ext_linegrid':True})
    lua(r'''
      local root,plugins,out,project=...
      vim.opt.rtp:prepend(root);vim.opt.rtp:append(plugins..'/snacks.nvim')
      vim.o.hidden=true;vim.o.swapfile=false;vim.o.shada='';vim.o.clipboard='';vim.g.mapleader=' '
      Clip={};vim.g.clipboard={name='owned context provider',copy={['+']=function(v)Clip.plus=v end,['*']=function(v)Clip.star=v end},paste={['+']=function()return {},'v'end,['*']=function()return {},'v'end},cache_enabled=0}
      vim.api.nvim_set_current_dir(project)
      assert(vim.fs.normalize(vim.fn.stdpath('state')):find(vim.fs.normalize(out),1,true))
      Notices={};vim.notify=function(message)Notices[#Notices+1]=tostring(message)end
      Project={root=project,identity=project..'/Investigation.uproject',engine=''}
      Target={project='Investigation',project_root=project,uproject=Project.identity,target='InvestigationEditor',platform='Win64',configuration='Development',state={target_platform='Win64',target_configuration='Development'}}
      UE=require('ue');UE.resolve_context=function()return {project_root=Project.root,uproject=Project.identity}end
      require('utils.ue_hub').target=function()return Target end
      local opts=dofile(root..'/lua/plugins/snacks.lua')[1].opts(nil,{picker={enabled=true}})
      Snacks=require('snacks');Snacks.setup({picker=opts.picker,input={enabled=true},scroll={enabled=false}})
      C=require('utils.work_context');Store=require('utils.work_context_store');W=require('utils.development_workbench');R=require('utils.verification_runs');Recipes=require('utils.search_recipe')
      Project=Recipes.context({project_root=Project.root,uproject=Project.identity});Target.project_root=Project.root;Target.uproject=Project.identity
      W.setup();require('utils.unsaved').setup();require('utils.bottom_panel').setup_commands()
      Searches=0;local grep=Snacks.picker.grep;Snacks.picker.grep=function(...)Searches=Searches+1;return grep(...)end
      Saves=0;local save=Store.save;Store.save=function(...)Saves=Saves+1;return save(...)end
      Spawns=0;local system=vim.system;vim.system=function(...)Spawns=Spawns+1;return system(...)end
      local jobstart=vim.fn.jobstart;vim.fn.jobstart=function(...)Spawns=Spawns+1;return jobstart(...)end
      local termopen=vim.fn.termopen;vim.fn.termopen=function(...)Spawns=Spawns+1;return termopen(...)end
      local function up(fn,wanted)for i=1,255 do local k,v=debug.getupvalue(fn,i);if not k then break end;if k==wanted then return v end end;error('missing real helper '..wanted)end
      OpenBuild=up(up(UE.setup,'build_target'),'open_terminal_command')
    ''',root.as_posix(),plugins.as_posix(),out.as_posix(),project.as_posix())
def query():
    lua("P=Recipes.open_grep({search='InvestigateToken',cwd=Project.root,dirs={Project.root},regex=false,case=true,args={'-s'},glob={'*.cpp','*.h'}},'project',Project)")
    wait("return P and not P.closed and not P.finder:running()and not P.matcher:running()and #P:items()==2 and vim.fn.mode()=='i'")
def pick_file(stem,key):
    for _ in range(5):
        if lua('local item=P:current();return item and item.file and vim.fs.basename(vim.fs.normalize(item.file))==...',stem):
            keys(key);wait("return P.closed and vim.fn.mode()=='n'");return
        keys('<C-n>');time.sleep(.03)
    raise AssertionError('missing actual picker file '+stem)
def investigate():
    query();pick_file('Source.cpp','<CR>')
    lua('Source={win=vim.api.nvim_get_current_win(),buf=vim.api.nvim_get_current_buf()}')
    query();pick_file('Header.h','<M-v>')
    lua('Header={win=vim.api.nvim_get_current_win(),buf=vim.api.nvim_get_current_buf(),cursor=vim.api.nvim_win_get_cursor(0)};vim.api.nvim_set_current_win(Source.win)')
    query();keys('<C-q>');wait("return P.closed and vim.fn.mode()=='n'")
    assert lua('return #vim.fn.getqflist()==2')
    keys('ggfI');wait('return vim.deep_equal(vim.api.nvim_win_get_cursor(Source.win),{1,13})')
    lua('Source.cursor=vim.api.nvim_win_get_cursor(Source.win);Source.tick=vim.api.nvim_buf_get_changedtick(Source.buf);OriginalQF=vim.fn.getqflist({id=0,changedtick=0,context=0,items=0});OriginalSearches=Searches')
def workbench(fragment,source):
    lua('''
      local fragment,source=...
      vim.api.nvim_set_current_win(source);Work=W.open({source_win=source});local model=W.model()
      for line,action in pairs(model.actions)do if action.kind==fragment then vim.api.nvim_win_set_cursor(Work,{line,0});return end end
      error('missing workbench action '..fragment)
    ''',fragment,source)
    keys('<CR>')
def input_ready(previous=None):
    wait('local old=...;InputWin=nil;for _,win in ipairs(vim.api.nvim_list_wins())do if win~=old and vim.bo[vim.api.nvim_win_get_buf(win)].filetype=="document_location_input"then InputWin=win end end;return InputWin and vim.fn.mode()=="i"',previous)
    return lua('return InputWin')
def save_card():
    workbench('work_context_save',lua('return Source.win'));input_ready();keys('abandoned draft<Esc>')
    wait('return not vim.api.nvim_win_is_valid(InputWin)and vim.fn.mode()=="n"')
    assert lua('return Saves==0 and #C.rows(Project)==0 and vim.deep_equal(vim.api.nvim_win_get_cursor(Source.win),Source.cursor)and vim.api.nvim_buf_get_changedtick(Source.buf)==Source.tick')
    evidence['single_escape_preserves_source']=True
    workbench('work_context_save',lua('return Source.win'));old=input_ready();keys('<C-u>Investigate token<CR>')
    input_ready(old);keys('<C-u>Check the caller before editing<CR>')
    wait('local rows=C.rows(Project);Card=rows[1];return Card and Card.name=="Investigate token"and Card.note=="Check the caller before editing"and vim.fn.mode()=="n"')
    wait('if not vim.api.nvim_win_is_valid(Work)then return false end;local text=table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(Work),0,-1,false)," ");return text:find("Investigate token",1,true)and text:find("Check the caller before editing",1,true)')
    assert lua('return #Card.files==2 and Card.files[Card.active].line==1 and Card.files[Card.active].col==14 and Card.search.query=="InvestigateToken"and Card.search.mode.case=="sensitive"and vim.deep_equal(vim.api.nvim_win_get_cursor(Source.win),Source.cursor)and vim.api.nvim_buf_get_changedtick(Source.buf)==Source.tick')
    evidence['existing_workbench_updates_after_save_without_reopen']=True
    evidence['saved']=lua('return {id=Card.id,revision=Card.revision,name=Card.name,note=Card.note,files=Card.files,active=Card.active,search=Card.search,has_result=Card.has_result}')
def details(source,resume=False):
    workbench('work_context_resume'if resume else'work_context_details',source)
    if resume:
        wait('Picker=Snacks.picker.get()[1];return Picker and not Picker.closed and Picker.opts.source=="ue_work_context"and not Picker.finder:running()and not Picker.matcher:running()and #Picker:items()>0 and vim.fn.mode()=="i"')
        keys('Investigate token');wait('return not Picker.matcher:running()and #Picker:items()==1')
        keys('<CR>')
    wait('return vim.bo[vim.api.nvim_get_current_buf()].filetype=="ue_work_context"and vim.fn.mode()=="n"')
    lua('DetailsWin=vim.api.nvim_get_current_win();DetailsBuf=vim.api.nvim_get_current_buf();Card=C.rows(Project)[1]')
def active_ready():
    wait('RestoredWin=nil;for _,win in ipairs(vim.api.nvim_tabpage_list_wins(0))do local buf=vim.api.nvim_win_get_buf(win);if vim.bo[buf].buftype==""and vim.fs.basename(vim.fs.normalize(vim.api.nvim_buf_get_name(buf)))=="Source.cpp"then RestoredWin=win end end;return RestoredWin and vim.deep_equal(vim.api.nvim_win_get_cursor(RestoredWin),{1,13})')
def detail_action(kind):
    lua('''
      local kind=...;local model=C.model(Card)
      for line,action in pairs(model.actions)do if action.kind==kind then vim.api.nvim_win_set_cursor(DetailsWin,{line,0});return end end
      error('missing details action '..kind)
    ''',kind)
    keys('<CR>')
def b_task(alive):
    lua('''
      vim.api.nvim_set_current_win(Source.win);vim.cmd.edit(vim.fn.fnameescape(Project.root..'/Other.cpp'))
      B={win=vim.api.nvim_get_current_win(),buf=vim.api.nvim_get_current_buf()}
    ''')
    keys('A UNSAVED_OTHER_TASK<Esc>')
    wait('return vim.bo[B.buf].modified')
    lua('B.tick=vim.api.nvim_buf_get_changedtick(B.buf);B.text=vim.api.nvim_buf_get_lines(B.buf,0,-1,false);vim.fn.setqflist({}," ",{title="other investigation",items={{bufnr=B.buf,lnum=1,col=2,text="unrelated current result"}}});NewQF=vim.fn.getqflist({id=0,changedtick=0,context=0,items=0})')
    if alive:
        lua('''
          local python=...
          Job=OpenBuild({python,'-u','-c','import sys;print("other task alive",flush=True);sys.stdin.readline();print("other task done",flush=True)'},{verification_context=Target,is_current=function()return true end})
          assert(Job and Job>0)
        ''',sys.executable)
        wait('return vim.fn.jobwait({Job},0)[1]==-1')
def protected():
    assert lua('return vim.api.nvim_buf_is_loaded(B.buf)and vim.bo[B.buf].modified and vim.api.nvim_buf_get_changedtick(B.buf)==B.tick and vim.deep_equal(vim.api.nvim_buf_get_lines(B.buf,0,-1,false),B.text)and vim.deep_equal(vim.fn.getqflist({id=NewQF.id,changedtick=0,context=0,items=0}),NewQF)')
def frame(name):
    (out/(name+'.txt')).write_text('\n'.join(''.join(row).rstrip()for row in n.grids.get(1,[])),encoding='utf-8')
try:
    start(1);investigate();save_card()
    persisted=lua('return Store.path(Project)')
    payload=json.loads(Path(persisted).read_text(encoding='utf-8'))
    forbidden={'buf','bufnr','win','tab','jobid','qf_id','qf_tick','run_id','items','text'}
    def metadata_only(value):
        if isinstance(value,dict):
            assert not forbidden.intersection(value),set(value)
            for child in value.values():metadata_only(child)
        elif isinstance(value,list):
            for child in value:metadata_only(child)
    metadata_only(payload);evidence['persisted_metadata']=payload
    if case=='interruption':
        b_task(True);details(lua('return B.win'),resume=True);active_ready()
        assert lua('local text=table.concat(vim.api.nvim_buf_get_lines(DetailsBuf,0,-1,false)," ");return text:find("Investigate token",1,true)and text:find("Check the caller before editing",1,true)and text:find("Source.cpp",1,true)and text:find("Header.h",1,true)and text:find("InvestigateToken",1,true)and Searches==OriginalSearches')
        protected();assert lua('return vim.fn.getqflist({id=0}).id==NewQF.id and vim.fn.jobwait({Job},0)[1]==-1')
        frame('continued-details')
        protected();assert lua('return vim.fn.jobwait({Job},0)[1]==-1')
        detail_action('result')
        wait('return vim.fn.getqflist({id=0}).id==OriginalQF.id and vim.bo[vim.api.nvim_get_current_buf()].buftype=="quickfix"')
        protected()
        lua('vim.fn.setqflist({},"r",{id=OriginalQF.id,title="changed original list",items={{bufnr=B.buf,lnum=1,col=2,text="same id now unrelated"}}});StaleQF=vim.fn.getqflist({id=OriginalQF.id,changedtick=0,context=0,items=0})')
        details(lua('return B.win'));count=lua('return #Notices');detail_action('result')
        wait('return #Notices>...',count)
        assert lua('return vim.deep_equal(vim.fn.getqflist({id=OriginalQF.id,changedtick=0,context=0,items=0}),StaleQF)and vim.api.nvim_get_current_buf()==DetailsBuf')
        protected();assert lua('return vim.fn.jobwait({Job},0)[1]==-1')
        lua('vim.fn.chansend(Job,string.char(13))')
        wait('return R.list({project_root=Project.root})[1].completed')
        assert lua('return R.list({project_root=Project.root})[1].code==0')
        evidence['same_instance']={'source_byte_position':[1,13],'old_results_opened':True,'same_id_replacement_rejected':True,'other_dirty_buffer_preserved':True,'new_qf_preserved':True,'actual_terminal_alive_through_resume':True,'explicit_stdin_exit':0}
    elif case=='restart':
        frame('first-saved');first_card=lua('return {id=Card.id,revision=Card.revision}')
        n.process.kill();n.process.wait(timeout=3)
        start(2)
        lua('vim.cmd.edit(vim.fn.fnameescape(Project.root.."/Other.cpp"));Source={win=vim.api.nvim_get_current_win(),buf=vim.api.nvim_get_current_buf()};vim.fn.setqflist({}," ",{title="fresh instance qf",items={{bufnr=Source.buf,lnum=1,col=2,text="fresh unrelated result"}}});FreshQF=vim.fn.getqflist({id=0,changedtick=0,context=0,items=0});C.refresh(Project,function(rows,err)assert(rows,err);Loaded=true end)')
        wait('return Loaded and #C.rows(Project)==1')
        assert lua('local card=C.rows(Project)[1];return card.id==... and card.revision==select(2,...)',first_card['id'],first_card['revision'])
        baseline=lua('return {spawns=Spawns,saves=Saves,searches=Searches,target=vim.deepcopy(Target)}')
        details(lua('return Source.win'),resume=True);active_ready()
        frame('restart-details')
        lua('WarmBefore={buf=vim.api.nvim_win_get_buf(RestoredWin),cursor=vim.api.nvim_win_get_cursor(RestoredWin),mark=vim.api.nvim_buf_get_mark(vim.api.nvim_win_get_buf(RestoredWin),string.char(34)),tab=vim.api.nvim_get_current_tabpage()}')
        details(lua('return RestoredWin'),resume=True);active_ready()
        assert lua('return vim.api.nvim_get_current_tabpage()~=WarmBefore.tab')
        evidence['warm_resume']=lua('return {before=WarmBefore,cursor=vim.api.nvim_win_get_cursor(RestoredWin),new_tab=vim.api.nvim_get_current_tabpage()}')
        assert lua('local header=vim.fn.bufnr(Project.root.."/Header.h");return (header==-1 or not vim.api.nvim_buf_is_loaded(header))and vim.deep_equal(vim.fn.getqflist({id=0,changedtick=0,context=0,items=0}),FreshQF)and #R.list()==0')
        assert lua('local before=...;return Spawns==before.spawns and Saves==before.saves and Searches==before.searches and vim.deep_equal(Target,before.target)',baseline)
        count=lua('return #Notices');detail_action('result')
        wait('return #Notices>...',count)
        assert lua('return vim.deep_equal(vim.fn.getqflist({id=0,changedtick=0,context=0,items=0}),FreshQF)and Searches==0')
        detail_action('search')
        wait('P=Snacks.picker.get()[1];return P and not P.closed and not P.finder:running()and not P.matcher:running()and #P:items()==2 and Searches==1')
        assert lua('local recipe=Recipes.from_picker(P);return recipe.query=="InvestigateToken"and recipe.scope.kind=="project"and recipe.mode.case=="sensitive"and vim.deep_equal(recipe.filters.include,{"*.cpp","*.h"})')
        keys('<Esc><Esc>');wait('return P.closed')
        evidence['restart']={'same_metadata_id':first_card['id'],'byte_position':[1,13],'only_active_loaded':True,'warm_resume_new_tab_and_details':True,'no_native_ids_or_text_on_disk':True,'old_results_not_bound_to_new_qf':True,'no_auto_spawn_search_save_target':True,'explicit_recipe_rerun':True}
    else:raise AssertionError(case)
    assert lua('return next(Clip)==nil'),'clipboard provider unexpectedly used'
    assert before=={p:hashlib.sha256((root/p).read_bytes()).hexdigest()for p in paths},'runtime changed during native verification'
    evidence.update(status='passed',source_sha256=before,source_bytes_unchanged=True,ui={'ext_linegrid':True,'flushes':sum(s.redraw['flush']for s in sessions)})
except Exception as error:evidence.update(status='failed',error=str(error),trace=traceback.format_exc())
finally:
    (out/'evidence.json').write_text(json.dumps(evidence,ensure_ascii=False,indent=2),encoding='utf-8')
    for session in sessions:
        if session.process.poll()is None:session.process.kill()
    watchdog.cancel();print(json.dumps(evidence,ensure_ascii=False))
    if evidence['status']!='passed':sys.exit(1)
]=]

local function native(case)
  local out = assert(vim.env.NVIM_TEST_RUN_ROOT) .. "/work-context-native-" .. case
  vim.fn.mkdir(out, "p")
  local script = out .. "/native.py"
  vim.fn.writefile(vim.split(program, "\n", { plain = true }), script)
  local result = vim
    .system({ python, script, cfg, plugins, out, case, vim.v.progpath }, {
      text = true,
      env = {
        NVIM_APPNAME = "work-context-native",
        NVIM_LOG_FILE = out .. "/nvim.log",
        NVIM_UE_PROBE_PATH = out .. "/probes.json",
        NVIM_UE_LOG_DIR = out .. "/logs",
        XDG_CONFIG_HOME = out .. "/config",
        XDG_DATA_HOME = out .. "/data",
        XDG_STATE_HOME = out .. "/state",
        XDG_CACHE_HOME = out .. "/cache",
      },
    })
    :wait(60000)
  t.assert_eq(result.code, 0, (result.stdout or "") .. (result.stderr or ""))
end

t.describe("saved investigation real user journey", function()
  t.it(
    "an interrupted investigation retains files, byte positions, conditions and owned results while preserving another task",
    function()
      native("interruption")
    end
  )
  t.it("a second Neovim restores metadata lazily and reruns the saved query only on explicit choice", function()
    native("restart")
  end)
end)
