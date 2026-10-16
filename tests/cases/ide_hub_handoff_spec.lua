local t = require("tests.harness")
local cfg = t.bootstrap()
local plugins = vim.fn.stdpath("data") .. "/lazy"
local python = vim.fn.exepath("python")
if python == "" then
  python = vim.fn.exepath("python3")
end
if python == "" then
  t.skip("ide_hub_handoff: native UI", "Python RPC host unavailable", { native = true })
  return
end
for _, name in ipairs({ "snacks.nvim", "trouble.nvim" }) do
  if vim.fn.isdirectory(plugins .. "/" .. name) == 0 then
    t.skip("ide_hub_handoff: native UI", "Missing installed plugin: " .. name, { native = true })
    return
  end
end

local program = [=[
import json, os, runpy, sys, time
from pathlib import Path

root, plugins, out = map(Path, sys.argv[1:4])
case = sys.argv[4]
helper = runpy.run_path(str(root / 'tools' / 'measure_inlay_hints.py'))
class Session(helper['Nvim']):
    def call(self, method, *args):
        self.sequence += 1
        ident = self.sequence
        self.process.stdin.write(helper['pack']([0, ident, method, args]))
        self.process.stdin.flush()
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            msg = self.messages.get(timeout=max(.01, deadline-time.monotonic()))
            self.consume(msg)
            if isinstance(msg, list) and msg[:2] == [1, ident]:
                if msg[2]: raise RuntimeError(msg[2])
                return msg[3]
        raise TimeoutError(method)

n = Session(sys.argv[5], os.environ.copy(), out / 'stderr.log')
def lua(code, *args): return n.lua(code, *args)
def keys(value): n.call('nvim_input', value)
def wait(code, label):
    deadline = time.monotonic() + 4
    while time.monotonic() < deadline:
        if lua(code): return
        time.sleep(.015)
    raise AssertionError(label)
def select(query):
    keys(' P')
    wait('Hub=Snacks.picker.get()[1];return Hub and not Hub.closed and not Hub.finder:running() and not Hub.matcher:running() and vim.fn.mode()=="i"', 'real P did not open Hub')
    keys(query)
    wait('return #Hub:items()==1 and Hub:current() and Hub:current().data.label:find(' + json.dumps(query) + ',1,true)~=nil', 'action not selected')
    assert lua('return vim.deep_equal(vim.api.nvim_win_get_cursor(Origin.win),Before.cursor)'), 'picker changed source before confirmation'
def preserved():
    assert lua('return vim.deep_equal(QFBefore,vim.fn.getqflist({id=0,items=0,idx=0,title=0,context=0}))'), 'quickfix was changed'
    assert lua('return vim.api.nvim_win_get_buf(Origin.win)==Origin.buf'), 'source buffer changed'

try:
    n.call('nvim_ui_attach', 120, 40, {'rgb':True, 'ext_linegrid':True})
    lua(r'''
      local root,plugins,out=...
      vim.opt.rtp:prepend(root)
      vim.opt.rtp:append(plugins..'/snacks.nvim')
      vim.opt.rtp:append(plugins..'/trouble.nvim')
      vim.o.hidden=true;vim.o.swapfile=false;vim.o.shada='';vim.g.mapleader=' '
      vim.api.nvim_set_current_dir(out)
      assert(vim.fs.normalize(vim.fn.stdpath('data')):find(out,1,true))
      Notices={};vim.notify=function(msg) Notices[#Notices+1]=tostring(msg) end
      local spec=dofile(root..'/lua/plugins/snacks.lua')[1]
      Snacks=require('snacks');Snacks.setup({picker=spec.opts(nil,{}).picker})
      require('trouble').setup(dofile(root..'/lua/plugins/sidebar.lua')[1].opts(nil,{}))
      require('utils.ue_hub').setup_commands()
      dofile(root..'/lua/config/keymaps.lua')
      assert(type(vim.fn.maparg(' P','n',false,true).callback)=='function')
      vim.fn.writefile({'alpha beta gamma delta','second line','third line'},out..'/Source.txt')
      vim.cmd.edit(vim.fn.fnameescape(out..'/Source.txt'))
      Origin={win=vim.api.nvim_get_current_win(),buf=vim.api.nvim_get_current_buf()}
      vim.cmd.normal({args={'G'},bang=true});vim.cmd.normal({args={'gg'},bang=true})
      vim.api.nvim_win_set_cursor(Origin.win,{1,3})
      Before={cursor=vim.api.nvim_win_get_cursor(Origin.win),tick=vim.api.nvim_buf_get_changedtick(Origin.buf)}
      assert(vim.fn.mode()=='n' and Before.cursor[2]>0 and Before.cursor[2]<#vim.api.nvim_get_current_line()-1)
      vim.diagnostic.set(vim.api.nvim_create_namespace('hub-handoff-owned'),Origin.buf,
        {{lnum=0,col=0,severity=1,message='HANDOFF_OWNED_ERROR'}})
      vim.fn.setqflist({},' ',{title='Owned saved results',items={{bufnr=Origin.buf,lnum=2,col=1,text='owned result'}},context={owner='fixture'}})
      QFBefore=vim.fn.getqflist({id=0,items=0,idx=0,title=0,context=0})
    ''', root.as_posix(), plugins.as_posix(), out.as_posix())
    if case in ('jumps', 'diagnostics'):
        select('Jump history' if case=='jumps' else 'All diagnostics')
        keys('<CR>')
        wait('return Hub.closed', 'Hub did not close')
        if case=='jumps':
            wait('Active=Snacks.picker.get({source="jumps"})[1];return Active and not Active.closed and Active.input.win:valid()',
                 'jump picker missing; source cursor=' + str(lua('return vim.api.nvim_win_get_cursor(Origin.win)')))
        else:
            wait('return require("trouble").is_open("diagnostics") and #require("trouble").get_items("diagnostics")==1', 'diagnostics did not open')
            assert lua('return require("trouble.api")._find_last("diagnostics"):main().buf==Origin.buf'), 'wrong diagnostic main buffer'
        assert lua('return vim.deep_equal(vim.api.nvim_win_get_cursor(Origin.win),Before.cursor)'), 'source cursor changed during handoff'
        assert lua('return vim.api.nvim_buf_get_changedtick(Origin.buf)==Before.tick'), 'source text changed during handoff'
        preserved()
    elif case in ('move', 'edit'):
        select('Jump history')
        lua(r'''
          local kind=...
          vim.api.nvim_create_autocmd('WinEnter',{callback=function()
            if not Hub.closed or vim.api.nvim_get_current_win()~=Origin.win then return end
            if kind=='move' then vim.cmd.normal({args={'l'},bang=true})
            else vim.api.nvim_buf_set_lines(Origin.buf,0,1,false,{'new source input survives'}) end
            Mutation={cursor=vim.api.nvim_win_get_cursor(Origin.win),tick=vim.api.nvim_buf_get_changedtick(Origin.buf)}
            return true
          end})
        ''',case)
        keys('<CR>')
        wait('return Hub.closed and Mutation~=nil', 'native close did not produce the new source state')
        time.sleep(.15)
        assert lua('return #Snacks.picker.get({source="jumps"})==0'), 'stale intent executed after new source input'
        assert lua('return vim.deep_equal(vim.api.nvim_win_get_cursor(Origin.win),Mutation.cursor) and vim.api.nvim_buf_get_changedtick(Origin.buf)==Mutation.tick'), 'new source state was overwritten'
        if case=='move': assert lua('return Mutation.cursor[2]==Before.cursor[2]+1'), 'movement control did not execute'
        else: assert lua('return vim.api.nvim_buf_get_lines(Origin.buf,0,1,false)[1]=="new source input survives" and vim.bo[Origin.buf].modified'), 'edit control was lost'
        preserved()
    elif case=='cancel':
        select('Jump history')
        keys('<Esc><Esc>')
        wait('return Hub.closed', 'Escape did not close Hub')
        time.sleep(.15)
        assert lua('return #Snacks.picker.get({source="jumps"})==0 and require("utils.ue_hub").pending_action()==nil'), 'cancelled Hub dispatched an action'
        preserved()
    else: raise AssertionError('unknown native case')
    print('HUB_HANDOFF_NATIVE_OK ' + case)
finally:
    n.close()
]=]

local function native(case)
  local dir = assert(vim.env.NVIM_TEST_RUN_ROOT) .. "/hub-handoff-" .. tostring(vim.uv.hrtime())
  vim.fn.mkdir(dir, "p")
  local script = dir .. "/case.py"
  vim.fn.writefile(vim.split(program, "\n", { plain = true }), script)
  local result = vim
    .system({ python, script, cfg, plugins, dir, case, vim.v.progpath }, {
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
  t.assert_contains(output, "HUB_HANDOFF_NATIVE_OK " .. case)
end

t.describe("ide_hub_handoff: real Snacks UI and source owner", function()
  t.it("normal P search Enter opens jump history without moving a nonzero source cursor", function()
    native("jumps")
  end)
  t.it("normal P search Enter opens actual diagnostics for the preserved source", function()
    native("diagnostics")
  end)
  t.it("a genuine source movement during picker close revokes the old action", function()
    native("move")
  end)
  t.it("a genuine source edit during picker close revokes the old action and keeps the text", function()
    native("edit")
  end)
  t.it("Escape from the real Hub cannot dispatch a pending action", function()
    native("cancel")
  end)
end)
