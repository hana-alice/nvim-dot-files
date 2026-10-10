local t = require("tests.harness")
local cfg = t.bootstrap()
local plugins = vim.fn.stdpath("data") .. "/lazy"
local python = vim.fn.exepath("python")
if python == "" then
  python = vim.fn.exepath("python3")
end
if python == "" or vim.fn.isdirectory(plugins .. "/snacks.nvim") == 0 then
  t.skip("current document location native UI", "installed Python and Snacks required", { native = true })
  return
end

-- The native UI and picker execute the actual root key callbacks. Only the
-- clipboard provider and notification sink are isolated; no OS clipboard write.
local program = [=[
import hashlib,json,os,runpy,sys,threading,time
from pathlib import Path
root,plugins,out=map(Path,sys.argv[1:4]);case=sys.argv[4]
helper=runpy.run_path(str(root/'tools/measure_inlay_hints.py'))
class Session(helper['Nvim']):
    def call(self,method,*args):
        self.sequence+=1;ident=self.sequence
        self.process.stdin.write(helper['pack']([0,ident,method,args]));self.process.stdin.flush()
        deadline=time.monotonic()+8
        while time.monotonic()<deadline:
            message=self.messages.get(timeout=max(.01,deadline-time.monotonic()));self.consume(message)
            if isinstance(message,list) and message[:2]==[1,ident]:
                if message[2]:raise RuntimeError(message[2])
                return message[3]
        raise TimeoutError(method)
paths=['lua/utils/document_location.lua','lua/utils/file_query.lua','lua/config/keymaps.lua','lua/utils/ue_hub.lua','lua/plugins/snacks.lua']
before={p:hashlib.sha256((root/p).read_bytes()).hexdigest()for p in paths}
n=Session(sys.argv[5],os.environ.copy(),out/'stderr.log')
watchdog=threading.Timer(35,lambda:n.process.kill() if n.process.poll()is None else None)
watchdog.daemon=True;watchdog.start()
evidence={'case':case,'clipboard':'isolated native provider, no OS clipboard','physical_gui':False}
def lua(code,*args):return n.lua(code,*args)
def keys(value):n.call('nvim_input',value)
def wait(code,*args):
    deadline=time.monotonic()+6
    while time.monotonic()<deadline:
        if lua(code,*args):return
        time.sleep(.015)
    raise AssertionError(code+' '+str(lua('return {mode=vim.fn.mode(),cursor=vim.api.nvim_win_get_cursor(Source.win),notices=Notices}')))
def source():
    lua('''
      vim.api.nvim_set_current_win(Source.win)
      Lines={'origin abcdef','aa 中文 target','third line'}
      vim.api.nvim_buf_set_lines(Source.buf,0,-1,false,Lines)
      vim.api.nvim_win_set_cursor(Source.win,{1,4})
      Tick=vim.api.nvim_buf_get_changedtick(Source.buf)
      vim.fn.setreg('a','owned yank');vim.fn.setreg('"','owned unnamed')
    ''')
def input_ready():
    wait('InputWin=nil;for _,w in ipairs(vim.api.nvim_list_wins())do if vim.bo[vim.api.nvim_win_get_buf(w)].filetype=="document_location_input" then InputWin=w end end;return InputWin and vim.fn.mode()=="i"')
def open_input():keys(' fl');input_ready()
def closed():wait('return not vim.api.nvim_win_is_valid(InputWin) and vim.fn.mode()=="n"')
def invariant():
    assert lua('return vim.api.nvim_buf_get_changedtick(Source.buf)==Tick and vim.deep_equal(vim.api.nvim_buf_get_lines(Source.buf,0,-1,false),Lines) and vim.bo[Source.buf].modified and vim.deep_equal(QF,vim.fn.getqflist({id=0,idx=0,items=0,title=0,context=0})) and vim.fn.getreg("a")=="owned yank"')
def hub(query):
    keys(' P')
    wait('Hub=Snacks.picker.get()[1];return Hub and not Hub.closed and not Hub.finder:running() and vim.fn.mode()=="i"')
    keys(query)
    wait('return not Hub.matcher:running() and #Hub:items()==1')
    keys('<CR>');wait('return Hub.closed')
try:
    n.call('nvim_ui_attach',130,42,{'rgb':True,'ext_linegrid':True})
    lua(r'''
      local root,plugins,out=...
      vim.opt.rtp:prepend(root);vim.opt.rtp:append(plugins..'/snacks.nvim')
      vim.o.hidden=true;vim.o.swapfile=false;vim.o.shada='';vim.o.clipboard='';vim.g.mapleader=' '
      vim.api.nvim_set_current_dir(out)
      assert(vim.fs.normalize(vim.fn.stdpath('state')):find(vim.fs.normalize(out),1,true))
      Notices={};vim.notify=function(message)Notices[#Notices+1]=tostring(message)end
      Clip={};vim.g.clipboard={name='owned location provider',copy={['+']=function(v,k)Clip.plus={v,k}end,['*']=function(v,k)Clip.star={v,k}end},paste={['+']=function()return Clip.plus and Clip.plus[1]or {},'v'end,['*']=function()return {},'v'end},cache_enabled=0}
      local opts=dofile(root..'/lua/plugins/snacks.lua')[1].opts(nil,{picker={enabled=true}})
      Snacks=require('snacks');Snacks.setup({picker=opts.picker,input={enabled=true},scroll={enabled=false}})
      Snacks.input.enable()
      dofile(root..'/lua/config/keymaps.lua');require('utils.ue_hub').setup_commands()
      Source={win=vim.api.nvim_get_current_win(),buf=vim.api.nvim_get_current_buf()}
      vim.api.nvim_buf_set_name(Source.buf,out..'/Space 中文 Name.txt')
      BeforeMappings={};for _,k in ipairs({' fl',' fy',' fA',' fY'})do BeforeMappings[k]=vim.fn.maparg(k,'n',false,true).callback;assert(type(BeforeMappings[k])=='function')end
      vim.fn.setqflist({},' ',{title='owned location qf',items={{bufnr=Source.buf,lnum=1,col=2,text='owned result'}}})
      QF=vim.fn.getqflist({id=0,idx=0,items=0,title=0,context=0})
    ''',root.as_posix(),plugins.as_posix(),out.as_posix())
    source()
    if case=='input':
        open_input();keys('2:4<CR>');closed()
        assert lua('return vim.deep_equal(vim.api.nvim_win_get_cursor(Source.win),{2,3}) and vim.api.nvim_get_current_win()==Source.win')
        invariant();keys('<C-o>');wait('return vim.deep_equal(vim.api.nvim_win_get_cursor(Source.win),{1,4})')
        open_input();keys('1:7<CR>');closed()
        assert lua('return vim.deep_equal(vim.api.nvim_win_get_cursor(Source.win),{1,6})')
        keys('``');wait('return vim.deep_equal(vim.api.nvim_win_get_cursor(Source.win),{1,4})')
        open_input();keys('2:4<Esc>');closed()
        assert lua('return vim.deep_equal(vim.api.nvim_win_get_cursor(Source.win),{1,4})')
        for text in ('2:5','0','99','-1'):
            old=lua('return #Notices');open_input();keys(text+'<CR>');closed()
            assert lua('return #Notices>... and vim.deep_equal(vim.api.nvim_win_get_cursor(Source.win),{1,4})',old)
        open_input();keys('3<CR>');closed()
        assert lua('return vim.deep_equal(vim.api.nvim_win_get_cursor(Source.win),{3,0})')
        invariant();assert lua('return vim.fn.getreg(string.char(34))=="owned unnamed"')
        evidence['accepted_same_packet']=True;evidence['invalid_inputs']=4;evidence['single_escape']=True
        evidence['native_returns']=['cross-line Ctrl-O','same-line previous context']
    elif case=='hub_copy':
        hub('当前文档跳到行列');input_ready();keys('2:4<CR>');closed()
        assert lua('return vim.deep_equal(vim.api.nvim_win_get_cursor(Source.win),{2,3})')
        absolute=lua('return require("ue.core.fs").norm(vim.api.nvim_buf_get_name(Source.buf))')
        expected={' fy':'Space 中文 Name.txt',' fA':absolute,' fY':'"'+absolute+'":2:4'}
        for key,value in expected.items():
            keys(key);wait('return vim.fn.getreg(string.char(34))==...',value)
            assert lua('return Clip.plus and Clip.plus[1][1]==...',value)
            invariant()
        for query,key in [('复制相对窗口',' fy'),('复制绝对路径',' fA'),('复制文件路径和行列位置',' fY')]:
            lua("vim.fn.setreg(string.char(34),'old copied value')")
            hub(query);wait('return vim.fn.getreg(string.char(34))==...',expected[key]);invariant()
        roundtrip=lua('return require("utils.file_query").parse(vim.fn.getreg(string.char(34)))')
        assert roundtrip['pos']==[2,3] and roundtrip['pattern']==absolute,roundtrip
        assert lua('for key,callback in pairs(BeforeMappings)do if vim.fn.maparg(key,"n",false,true).callback~=callback then return false end end;return true')
        evidence['real_hub_choices']=4;evidence['real_copy_keys']=3;evidence['quoted_location_roundtrip']=[2,3]
    elif case=='handoff':
        lua("Other=vim.api.nvim_open_win(vim.api.nvim_create_buf(true,false),false,{split='right',win=Source.win})")
        for kind in ('edit','cursor','window'):
            source();open_input();keys('2:4')
            wait('return vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(InputWin),0,1,false)[1]:find("2:4",1,true)~=nil')
            lua('''
              local kind=...
              Group=vim.api.nvim_create_augroup('LocationOwnedHandoff',{clear=true})
              vim.api.nvim_create_autocmd('WinEnter',{group=Group,nested=true,callback=function()
                if vim.api.nvim_get_current_win()~=Source.win then return end
                if kind=='edit' then vim.api.nvim_buf_set_lines(Source.buf,0,-1,false,{'new user text','chosen source view'});vim.api.nvim_win_set_cursor(Source.win,{2,2})
                elseif kind=='cursor' then vim.api.nvim_win_set_cursor(Source.win,{1,5})
                else vim.api.nvim_set_current_win(Other) end
                NewChoice={win=vim.api.nvim_get_current_win(),tick=vim.api.nvim_buf_get_changedtick(Source.buf),cursor=vim.api.nvim_win_get_cursor(Source.win)}
              end})
            ''',kind)
            keys('<CR>');closed();wait('return NewChoice~=nil')
            assert lua('return vim.api.nvim_get_current_win()==NewChoice.win and vim.api.nvim_buf_get_changedtick(Source.buf)==NewChoice.tick and vim.deep_equal(vim.api.nvim_win_get_cursor(Source.win),NewChoice.cursor) and vim.deep_equal(QF,vim.fn.getqflist({id=0,idx=0,items=0,title=0,context=0}))')
            lua('vim.api.nvim_del_augroup_by_id(Group);NewChoice=nil')
        evidence['real_close_callback_choices']=['new source text','new cursor','different window']
    else:raise AssertionError(case)
    after={p:hashlib.sha256((root/p).read_bytes()).hexdigest()for p in paths}
    assert before==after,'source bytes changed during native UI verification'
    evidence.update(status='passed',source_sha256=before,source_bytes_unchanged=True,ui={'ext_linegrid':True,'flushes':n.redraw['flush']})
except Exception as error:
    evidence.update(status='failed',error=str(error))
finally:
    (out/'evidence.json').write_text(json.dumps(evidence,ensure_ascii=False,indent=2),encoding='utf-8')
    if n.process.poll()is None:n.process.kill()
    watchdog.cancel();print(json.dumps(evidence,ensure_ascii=False))
    if evidence['status']!='passed':sys.exit(1)
]=]

local function native(case)
  local out = assert(vim.env.NVIM_TEST_RUN_ROOT) .. "/document-location-ui-" .. case
  vim.fn.mkdir(out, "p")
  local script = out .. "/native.py"
  vim.fn.writefile(vim.split(program, "\n", { plain = true }), script)
  local result = vim
    .system({ python, script, cfg, plugins, out, case, vim.v.progpath }, {
      text = true,
      env = {
        NVIM_APPNAME = "document-location-test",
        NVIM_LOG_FILE = out .. "/nvim.log",
        NVIM_UE_PROBE_PATH = out .. "/probes.json",
        NVIM_UE_LOG_DIR = out .. "/logs",
        XDG_CONFIG_HOME = out .. "/config",
        XDG_DATA_HOME = out .. "/data",
        XDG_STATE_HOME = out .. "/state",
        XDG_CACHE_HOME = out .. "/cache",
      },
    })
    :wait(45000)
  t.assert_eq(result.code, 0, (result.stdout or "") .. (result.stderr or ""))
end

t.describe("current document location native UI", function()
  t.it(
    "same input packet, UTF-8 landing, native returns, Escape and invalid reopening preserve source ownership",
    function()
      native("input")
    end
  )
  t.it("actual Hub chooser and copy keys share quoted byte locations without touching the OS clipboard", function()
    native("hub_copy")
  end)
  t.it("native close callbacks retain new source text, cursor and window choices", function()
    native("handoff")
  end)
end)
