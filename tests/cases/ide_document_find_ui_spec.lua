local t = require("tests.harness")
local cfg = t.bootstrap()
local plugins = vim.fn.stdpath("data") .. "/lazy"
local python = vim.fn.exepath("python")
if python == "" then
  python = vim.fn.exepath("python3")
end
if python == "" or vim.fn.isdirectory(plugins .. "/snacks.nvim") == 0 or vim.fn.executable("rg") ~= 1 then
  t.skip("current document Find native UI", "installed Python, Snacks and rg required", { native = true })
  return
end

local program = [=[
import json, os, runpy, sys, threading, time
from pathlib import Path
root, plugins, out = map(Path, sys.argv[1:4])
case = sys.argv[4]
helper = runpy.run_path(str(root / 'tools/measure_inlay_hints.py'))
class Session(helper['Nvim']):
    def call(self, method, *args):
        self.sequence += 1
        ident = self.sequence
        self.process.stdin.write(helper['pack']([0, ident, method, args])); self.process.stdin.flush()
        deadline = time.monotonic()+8
        while time.monotonic()<deadline:
            msg = self.messages.get(timeout=max(.01,deadline-time.monotonic())); self.consume(msg)
            if isinstance(msg,list) and msg[:2]==[1,ident]:
                if msg[2]: raise RuntimeError(msg[2])
                return msg[3]
        raise TimeoutError(method)
n = Session(sys.argv[5], os.environ.copy(), out/'stderr.log')
watchdog = threading.Timer(35,lambda:n.process.kill() if n.process.poll() is None else None)
watchdog.daemon=True;watchdog.start()
evidence = {'case':case}
def lua(code,*args): return n.lua(code,*args)
def keys(value): n.call('nvim_input',value)
def wait(code):
    deadline=time.monotonic()+7
    while time.monotonic()<deadline:
        if lua(code):return
        time.sleep(.015)
    raise AssertionError(code+' '+str(lua('return {status=P and F.status(P),notices=Notices,mode=vim.fn.mode()}')))
def settle():
    wait('return P and not P.closed and not P.finder:running() and not P.matcher:running() and F.status(P).state~="debounce" and F.status(P).state~="running"')
    return lua('return F.status(P)')
def close():
    keys('<Esc>');wait('return P.closed and vim.fn.mode()=="n"');time.sleep(.04)
def open(lines,text,cursor=(1,0)):
    lua('''
      local lines,text,cursor=...
      vim.api.nvim_set_current_win(Source.win)
      vim.api.nvim_buf_set_lines(Source.buf,0,-1,false,lines)
      vim.api.nvim_win_set_cursor(Source.win,cursor)
      P=F.open({text=text})
    ''',lines,text,list(cursor))
    return settle()
try:
    n.call('nvim_ui_attach',140,42,{'rgb':True,'ext_linegrid':True})
    lua(r'''
      local root,plugins,out=...
      vim.opt.rtp:prepend(root);vim.opt.rtp:append(plugins..'/snacks.nvim')
      vim.o.hidden=true;vim.o.swapfile=false;vim.o.shada='';vim.o.clipboard='';vim.g.mapleader=' '
      vim.api.nvim_set_current_dir(out)
      assert(vim.fs.normalize(vim.fn.stdpath('state')):find(vim.fs.normalize(out),1,true))
      Notices={};vim.notify=function(msg) Notices[#Notices+1]=tostring(msg) end
      local opts=dofile(root..'/lua/plugins/snacks.lua')[1].opts(nil,{picker={enabled=true}})
      Snacks=require('snacks');Snacks.setup({picker=opts.picker,scroll={enabled=false}})
      dofile(root..'/lua/config/keymaps.lua')
      F=require('utils.document_find')
      Source={win=vim.api.nvim_get_current_win(),buf=vim.api.nvim_get_current_buf()}
    ''',root.as_posix(),plugins.as_posix(),out.as_posix())
    if case=='resume':
        lua(r'''
          local plugins,out=...
          vim.opt.rtp:append(plugins..'/LazyVim');vim.opt.rtp:append(plugins..'/lazy.nvim')
          LazyVim=require('lazyvim.util')
          local specs=dofile(plugins..'/LazyVim/lua/lazyvim/plugins/extras/editor/snacks_picker.lua')
          for _,spec in ipairs(specs) do
            for _,key in ipairs(spec.keys or {}) do
              if key[1]=='<leader>sR' then vim.keymap.set('n',key[1],key[2],{desc=key.desc}) end
            end
          end
          assert(type(vim.fn.maparg(' sR','n',false,true).callback)=='function')
        ''',plugins.as_posix(),out.as_posix())
    if case=='packet':
        open(['Alpha','Beta','source'],'Alpha',(3,0))
        keys('<C-w>Beta<CR>');time.sleep(.06)
        assert lua('return not P.closed and vim.deep_equal(vim.api.nvim_win_get_cursor(Source.win),{3,0})')
        state=settle();assert state['query']=='Beta' and state['count']==1,state
        keys('<CR>');wait('return P.closed and vim.fn.mode()=="n"')
        assert lua('return vim.deep_equal(vim.api.nvim_win_get_cursor(Source.win),{2,0})')
        open(['xAlpha','source'],'Alpha',(2,0))
        keys('<A-w><CR>');time.sleep(.06)
        assert lua('return not P.closed and vim.deep_equal(vim.api.nvim_win_get_cursor(Source.win),{2,0})')
        state=settle();assert state['state']=='empty' and state['modes']['whole_word'],state
        close()
        open(['Alpha','source'],'Alpha|$',(2,0))
        keys('<A-r>');state=settle()
        assert state['state']=='error' and state['reason']=='unsupported-zero-width' and state['count']==0,state
        assert lua('return #P:items()==0 and P.title:find(" · 0 · ",1,true)~=nil')
        evidence['mixed_zero']=state
    elif case=='refresh':
        open(['α Needle Needle','tail'],'Needle',(2,2))
        assert lua('return P.preview.win.buf==Source.buf and vim.deep_equal(vim.api.nvim_win_get_cursor(Source.win),{2,2})')
        lua("vim.api.nvim_buf_set_lines(Source.buf,0,0,false,{'first','second'})")
        wait('return F.status(P).state=="stale" and #P:items()==0')
        keys('<A-v>');time.sleep(.05)
        assert lua('return not P.closed and vim.deep_equal(vim.api.nvim_win_get_cursor(Source.win),{4,2})')
        keys('<F5>');state=settle();assert state['count']==2,state
        keys('<CR>');wait('return P.closed and vim.fn.mode()=="n"')
        assert lua('return vim.deep_equal(vim.api.nvim_win_get_cursor(Source.win),{3,3})')
        keys('<C-o>');time.sleep(.05)
        assert lua('return vim.deep_equal(vim.api.nvim_win_get_cursor(Source.win),{4,2})')
        evidence['fresh']=state
    elif case=='handoff':
        lua('''
          Other=vim.api.nvim_open_win(vim.api.nvim_create_buf(true,false),false,{split='right',win=Source.win})
        ''')
        for kind in ('edit','cursor','window','enter'):
            open(['Needle Needle','tail'],'Needle',(2,1))
            lua('''
              local kind=...
              if kind=='enter' then
                Group=vim.api.nvim_create_augroup('FindOwnedHandoff',{clear=true})
                vim.api.nvim_create_autocmd('WinEnter',{group=Group,callback=function()
                  if P.closed and vim.api.nvim_get_current_win()==Source.win then vim.api.nvim_set_current_win(Other) end
                end})
              else
                local original=P.opts.on_close
                P.opts.on_close=function(...)
                  original(...)
                  if kind=='edit' then vim.api.nvim_buf_set_lines(Source.buf,0,0,false,{'new first'})
                  elseif kind=='cursor' then vim.api.nvim_win_set_cursor(Source.win,{2,0})
                  else vim.api.nvim_set_current_win(Other) end
                end
              end
            ''',kind)
            keys('<CR>');wait('return P.closed and vim.fn.mode()=="n"');time.sleep(.04)
            if kind in ('window','enter'):
                assert lua('return vim.api.nvim_get_current_win()==Other and vim.deep_equal(vim.api.nvim_win_get_cursor(Source.win),{2,1})')
            elif kind=='edit':
                assert lua('return vim.deep_equal(vim.api.nvim_win_get_cursor(Source.win),{3,1})')
            else:
                assert lua('return vim.deep_equal(vim.api.nvim_win_get_cursor(Source.win),{2,0})')
            if kind=='enter':lua('vim.api.nvim_del_augroup_by_id(Group)')
        evidence['kinds']=['edit','cursor','window','WinEnter']
    elif case=='resume':
        open(['Alpha','origin'],'Alpha',(2,1));keys('<A-c>');settle();close()
        lua("vim.api.nvim_buf_set_lines(Source.buf,0,0,false,{'inserted'})")
        keys(' sR')
        wait('P=Snacks.picker.get({source="ue_document_find"})[1];return P and not P.closed')
        state=settle();assert state['count']==1 and state['modes']['case_sensitive'] and not state['closed'],state
        assert lua('return P:current().pos[1]==2 and P.preview.win.buf==Source.buf')
        close()
        lua('''
          Source.buf=vim.api.nvim_create_buf(true,false);vim.api.nvim_set_current_buf(Source.buf)
          vim.api.nvim_buf_set_lines(Source.buf,0,-1,false,{'other','different','α Alpha Alpha'})
        ''')
        keys(' sR');wait('P=Snacks.picker.get({source="ue_document_find"})[1];return P and not P.closed')
        state=settle();assert state['count']==2 and not state['closed'],state
        assert lua('return P:current().buf==Source.buf and vim.deep_equal(P:current().pos,{3,3}) and P.preview.win.buf==Source.buf')
        keys('<CR>');wait('return P.closed and vim.fn.mode()=="n"')
        assert lua('return vim.deep_equal(vim.api.nvim_win_get_cursor(Source.win),{3,3})')
        evidence['new_document']=state
    elif case=='retention':
        # Isolate our owner cycles from LuaJIT trace constants. The other UI
        # journeys and performance checks use the unchanged production JIT.
        # Disable compilation before opening; never flush after observing a leak.
        lua('jit.off()')
        lua('Observed=setmetatable({},{__mode="v"})')
        for i in range(1,6):
            open(['Alpha','origin'],'Alpha',(2,1))
            lua('Observed[...]=P',i);close();lua('P=nil')
        time.sleep(.12)
        retained=lua('''
          collectgarbage('collect');collectgarbage('collect')
          local count=0;for _,p in pairs(Observed) do assert(p.closed);count=count+1 end;return count
        ''')
        assert retained<=1,retained
        evidence['retained_closed']=retained
    elif case=='return':
        open(['foo Needle Needle bar','tail'],'Needle',(1,3))
        keys('<Down><CR>');wait('return P.closed and vim.fn.mode()=="n"')
        assert lua('return vim.deep_equal(vim.api.nvim_win_get_cursor(Source.win),{1,11})')
        keys('``');time.sleep(.05)
        assert lua('return vim.deep_equal(vim.api.nvim_win_get_cursor(Source.win),{1,3})')
        lua("vim.cmd('clearjumps');vim.api.nvim_buf_set_lines(Source.buf,0,-1,false,{'origin','first Needle','second Needle','last'})")
        lua('vim.api.nvim_win_set_cursor(Source.win,{1,2});P=F.open({text="Needle"})');settle()
        keys('<CR>');wait('return P.closed and vim.fn.mode()=="n"')
        assert lua('return vim.deep_equal(vim.api.nvim_win_get_cursor(Source.win),{2,6})')
        lua('P=F.open({text="Needle"})');settle();keys('<Down><CR>');wait('return P.closed and vim.fn.mode()=="n"')
        assert lua('return vim.deep_equal(vim.api.nvim_win_get_cursor(Source.win),{3,7})')
        keys('<C-o>');time.sleep(.05)
        assert lua('return vim.deep_equal(vim.api.nvim_win_get_cursor(Source.win),{2,6})')
        keys('<C-o>');time.sleep(.05)
        assert lua('return vim.deep_equal(vim.api.nvim_win_get_cursor(Source.win),{1,2})')
        jumps=lua('return vim.fn.getjumplist()[1]');assert len(jumps)==3,jumps
        evidence['jumps']=jumps
    else:raise AssertionError(case)
    evidence['status']='passed'
except Exception as error:
    evidence['status']='failed';evidence['error']=str(error)
finally:
    (out/'evidence.json').write_text(json.dumps(evidence,ensure_ascii=False,indent=2),encoding='utf-8')
    if n.process.poll() is None:n.process.kill()
    watchdog.cancel();print(json.dumps(evidence,ensure_ascii=False))
    if evidence['status']!='passed':sys.exit(1)
]=]

local function native(case)
  local out = assert(vim.env.NVIM_TEST_RUN_ROOT) .. "/document-find-ui-" .. case
  vim.fn.mkdir(out, "p")
  local script = out .. "/native.py"
  vim.fn.writefile(vim.split(program, "\n", { plain = true }), script)
  local result = vim
    .system({ python, script, cfg, plugins, out, case, vim.v.progpath }, {
      text = true,
      env = {
        NVIM_APPNAME = "document-find-test",
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

t.describe("current document Find native UI lifecycle", function()
  t.it("same input packet query or word-mode change cannot confirm the old row", function()
    native("packet")
  end)
  t.it("source insertion rejects old coordinates and F5 captures the shifted cursor and text", function()
    native("refresh")
  end)
  t.it("close source edit, cursor change, new window, and WinEnter intent cannot be overwritten", function()
    native("handoff")
  end)
  t.it("actual sR creates fresh owners for changed memory and a newly selected unnamed document", function()
    native("resume")
  end)
  t.it("closed ownership cycles do not retain every previous native picker", function()
    native("retention")
  end)
  t.it("same-line previous-context return and two cross-line finds preserve native history", function()
    native("return")
  end)
end)
