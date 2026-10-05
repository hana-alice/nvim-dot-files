local t = require("tests.harness")
local cfg = t.bootstrap()
local api = vim.api
local W = require("utils.development_workbench")
local R = require("utils.verification_runs")
local H = require("utils.ue_hub")

local function target(name)
  local root = assert(vim.env.NVIM_TEST_RUN_ROOT) .. "/workbench-" .. name
  return {
    project = name,
    project_root = root,
    uproject = root .. "/" .. name .. ".uproject",
    target = name .. "Editor",
    platform = "Win64",
    configuration = "Development",
    state = { target_platform = "Win64", target_configuration = "Development" },
  }
end

local function begin(project, code)
  local receipt = {}
  local job = vim.fn.jobstart(
    { vim.v.progpath, "--headless", "-u", "NONE", "-i", "NONE", "-c", code == 0 and "qa!" or "cquit " .. code },
    {
      on_exit = function(_, result)
        receipt.code = result
      end,
    }
  )
  t.assert_true(job > 0)
  local spec = vim.tbl_extend("force", project, { jobid = job, operation = "build", label = project.project })
  local id = assert(R.begin(spec))
  return id, job, spec, receipt
end

t.describe("development workbench product continuity", function()
  t.it("current target and next actions share one read-only view without starting checks or jobs", function()
    local project = target("Readonly")
    local original_target, original_system, original_jobstart = H.target, vim.system, vim.fn.jobstart
    local source_win, source_buf = api.nvim_get_current_win(), api.nvim_get_current_buf()
    local buf = api.nvim_create_buf(true, false)
    api.nvim_win_set_buf(source_win, buf)
    api.nvim_buf_set_lines(buf, 0, -1, false, { "owned dirty source text" })
    api.nvim_win_set_cursor(source_win, { 1, 4 })
    local tick, cursor, windows =
      api.nvim_buf_get_changedtick(buf), api.nvim_win_get_cursor(source_win), #api.nvim_list_wins()
    H.target = function()
      return project
    end
    vim.system = function()
      error("workbench spawned a process")
    end
    vim.fn.jobstart = function()
      error("workbench started a job")
    end
    local owned_win
    local ok, err = pcall(function()
      W.setup()
      local model = W.model({ target = project })
      t.assert_eq(model.target.project_root, project.project_root)
      local labels = {}
      for line, action in pairs(model.actions) do
        t.assert_true(line >= 1 and line <= #model.lines)
        t.assert_eq(model.lines[line], action.label)
        labels[#labels + 1] = action.label
      end
      local text = table.concat(labels, "\n")
      for _, label in ipairs({
        "构建当前目标",
        "运行或调试当前目标",
        "检查配置",
        "刷新索引",
        "查看未保存文件",
        "找回窗口",
      }) do
        t.assert_contains(text, label)
      end
      local win = assert(W.open({ source_win = source_win }))
      owned_win = win
      t.assert_eq(W.open({ source_win = source_win }), win)
      W.refresh()
      t.assert_eq(#api.nvim_list_wins(), windows + 1)
      t.assert_eq(api.nvim_win_get_buf(source_win), buf)
      t.assert_eq(api.nvim_buf_get_changedtick(buf), tick)
      t.assert_true(vim.deep_equal(api.nvim_win_get_cursor(source_win), cursor))
      t.assert_true(vim.bo[buf].modified)
      t.assert_true(not vim.bo[api.nvim_win_get_buf(win)].modified)
      t.assert_true(W.close(win))
    end)
    H.target, vim.system, vim.fn.jobstart = original_target, original_system, original_jobstart
    if owned_win and api.nvim_win_is_valid(owned_win) then
      W.close(owned_win)
    end
    if api.nvim_win_is_valid(source_win) then
      api.nvim_win_set_buf(source_win, source_buf)
    end
    if api.nvim_buf_is_valid(buf) then
      api.nvim_buf_delete(buf, { force = true })
    end
    if not ok then
      error(err, 0)
    end
  end)

  t.it("A retains its invocation after B selection and completion order cannot promote an older start", function()
    local a, b = target("FrozenA"), target("FrozenB")
    local first, _, spec, first_receipt = begin(a, 4)
    spec.project_root, spec.platform, spec.configuration = b.project_root, "Other", "Changed"
    local newest, _, _, newest_receipt = begin(a, 0)
    local other, _, _, other_receipt = begin(b, 0)
    t.assert_true(vim.wait(5000, function()
      return newest_receipt.code ~= nil and other_receipt.code ~= nil and first_receipt.code ~= nil
    end, 5))
    t.assert_eq(newest_receipt.code, 0)
    t.assert_eq(other_receipt.code, 0)
    t.assert_eq(first_receipt.code, 4)
    t.assert_true(R.complete(newest, { code = newest_receipt.code, current = true }))
    t.assert_true(R.complete(other, { code = other_receipt.code, current = true }))
    t.assert_true(R.complete(first, { code = first_receipt.code, current = false }))
    local frozen = assert(R.get(first))
    t.assert_eq(frozen.project_root, a.project_root)
    t.assert_eq(frozen.platform, "Win64")
    t.assert_eq(frozen.configuration, "Development")
    t.assert_eq(frozen.result, "not_current")
    local records = R.list({ project_root = a.project_root })
    t.assert_eq(records[1].id, newest)
    t.assert_eq(records[2].id, first)
    local model = W.model({ target = b })
    for _, action in pairs(model.actions) do
      if action.run_id then
        t.assert_eq(action.run_id, other)
      end
    end
    t.assert_contains(table.concat(model.lines, "\n"), "历史退出结果不证明当前代码已验证")
    local unselected = W.model({ target = { platform = "", configuration = "", state = {} } })
    for _, action in pairs(unselected.actions) do
      t.assert_true(action.run_id == nil)
    end
  end)
end)

local python = vim.fn.exepath("python")
if python == "" then
  python = vim.fn.exepath("python3")
end
local clang = vim.fn.exepath("clang")
if clang == "" and vim.fn.executable("C:/Program Files/LLVM/bin/clang.exe") == 1 then
  clang = "C:/Program Files/LLVM/bin/clang.exe"
end

local program = [=[
import hashlib,json,os,runpy,sys,threading,time,traceback
from pathlib import Path
root,out=map(Path,sys.argv[1:3]);case=sys.argv[3];clang=sys.argv[5]
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
paths=['lua/utils/development_workbench.lua','lua/utils/verification_runs.lua','lua/utils/build_verification.lua','lua/ue/build_diagnostics.lua','lua/ue.lua','lua/utils/task_inspector.lua','lua/utils/bottom_panel.lua','lua/utils/workspace.lua']
before={p:hashlib.sha256((root/p).read_bytes()).hexdigest()for p in paths}
n=Session(sys.argv[4],os.environ.copy(),out/'stderr.log')
watchdog=threading.Timer(40,lambda:n.process.kill()if n.process.poll()is None else None)
watchdog.daemon=True;watchdog.start()
evidence={'case':case,'physical_gui':False,'clipboard':'provider isolated before first use; no clipboard actions'}
def lua(code,*args):return n.lua(code,*args)
def keys(value):n.call('nvim_input',value)
def wait(code,*args):
    deadline=time.monotonic()+7
    while time.monotonic()<deadline:
        if lua(code,*args):return
        time.sleep(.015)
    raise AssertionError(code+' '+str(lua('local names={};for _,buf in ipairs(vim.api.nvim_list_bufs())do names[tostring(buf)]=vim.api.nvim_buf_get_name(buf)end;return {notices=Notices,buffer_names=names,mode=vim.fn.mode(),current_win=vim.api.nvim_get_current_win(),current_buf=vim.api.nvim_get_current_buf(),run=Run and R.get(Run),qf=vim.fn.getqflist({id=0,changedtick=0,context=0,items=0}),work_cursor=Work and vim.api.nvim_win_is_valid(Work)and vim.api.nvim_win_get_cursor(Work)}')))
def select(kind,ident):
    lua('''
      local kind,ident=...
      Work=W.open({source_win=Source.win})
      local model=W.model({target=Current})
      for line,action in pairs(model.actions)do
        if action.kind==kind and (kind=='task'and action.task_id==ident or action.run_id==ident)then
          vim.api.nvim_win_set_cursor(Work,{line,0});return
        end
      end
      error('missing native workbench row '..kind)
    ''',kind,ident)
    keys('<CR>')
def source_intact():
    assert lua('return vim.api.nvim_win_is_valid(Source.win)and vim.api.nvim_win_get_buf(Source.win)==Source.buf and vim.api.nvim_buf_get_changedtick(Source.buf)==Source.tick and vim.deep_equal(vim.api.nvim_win_get_cursor(Source.win),Source.cursor)')
try:
    n.call('nvim_ui_attach',150,44,{'rgb':True,'ext_linegrid':True})
    (out/'Alpha').mkdir(exist_ok=True);(out/'Beta').mkdir(exist_ok=True)
    (out/'Alpha'/'Source.cpp').write_text('int main(){return workbench_missing_symbol;}\n',encoding='utf-8')
    lua(r'''
      local root,out=...
      vim.opt.rtp:prepend(root);vim.o.hidden=true;vim.o.swapfile=false;vim.o.shada='';vim.o.clipboard=''
      Clip={};vim.g.clipboard={name='owned workbench provider',copy={['+']=function(v)Clip.plus=v end,['*']=function(v)Clip.star=v end},paste={['+']=function()return {},'v'end,['*']=function()return {},'v'end},cache_enabled=0}
      vim.api.nvim_set_current_dir(out)
      assert(vim.fs.normalize(vim.fn.stdpath('state')):find(vim.fs.normalize(out),1,true))
      Notices={};vim.notify=function(message)Notices[#Notices+1]=tostring(message)end
      local function up(fn,wanted)for i=1,255 do local k,v=debug.getupvalue(fn,i);if not k then break end;if k==wanted then return v end end;error('missing real helper '..wanted)end
      OpenBuild=up(up(require('ue').setup,'build_target'),'open_terminal_command')
      H=require('utils.ue_hub');W=require('utils.development_workbench');R=require('utils.verification_runs');Registry=require('utils.task_registry')
      A={project='Alpha',project_root=out..'/Alpha',uproject=out..'/Alpha/Alpha.uproject',target='AlphaEditor',platform='Win64',configuration='Development',operation='build',state={target_platform='Win64',target_configuration='Development'}}
      B={project='Beta',project_root=out..'/Beta',uproject=out..'/Beta/Beta.uproject',target='BetaEditor',platform='Win64',configuration='Test',operation='build',state={target_platform='Win64',target_configuration='Test'}}
      Current=A;H.target=function()return Current end
      require('utils.unsaved').setup();W.setup();require('utils.bottom_panel').setup_commands()
      vim.cmd.edit(vim.fn.fnameescape(out..'/Alpha/Source.cpp'))
      Source={win=vim.api.nvim_get_current_win(),buf=vim.api.nvim_get_current_buf()}
      vim.api.nvim_win_set_cursor(Source.win,{1,4});Source.cursor=vim.api.nvim_win_get_cursor(Source.win);Source.tick=vim.api.nvim_buf_get_changedtick(Source.buf)
      Work=W.open({source_win=Source.win});assert(Work and W.open({source_win=Source.win})==Work)
      local actual_refresh=W.refresh;Refreshes=0;W.refresh=function(...)Refreshes=Refreshes+1;return actual_refresh(...)end
      vim.wait(50);Refreshes=0;vim.wait(220);assert(Refreshes<=3,'self-refresh loop '..Refreshes);IdleRefreshes=Refreshes
    ''',root.as_posix(),out.as_posix())
    evidence['steady_220ms_refreshes']=lua('return IdleRefreshes')
    source_intact()
    if case=='compiler':
        wrapper="import subprocess,sys,time;time.sleep(.18);r=subprocess.run([sys.argv[1],'-fsyntax-only','-x','c++',sys.argv[2]]);sys.exit(r.returncode)"
        lua('''
          local python,wrapper,clang,out=...
          local panel=require('utils.bottom_panel');local original=panel.show
          panel.show=function(kind,...)
            if kind=='quickfix'and not Replaced then
              Replaced=vim.fn.getqflist({id=0,changedtick=0})
              vim.fn.setqflist({},'r',{title='new search during publication',items={{bufnr=Source.buf,lnum=1,col=1,text='new search row'}}})
            end
            return original(kind,...)
          end
          Job=OpenBuild({python,'-c',wrapper,clang,out..'/Alpha/Source.cpp'},{verification_context=A,quickfix_title='Alpha native compiler failure',quickfix_root=A.project_root,is_current=function()return Current==A end,on_exit=function(code)Exit=code end})
          assert(Job and Job>0)
          Run=R.list({project_root=A.project_root})[1].id
        ''',sys.executable,wrapper,clang,out.as_posix())
        wait('return R.get(Run).completed and Exit~=nil')
        evidence['published_receipt']=lua('local r=R.get(Run);return {result=r.result,code=r.code,exit=Exit,errors=#r.items,swap=Replaced,qf_id=r.qf_id,qf_tick=r.qf_tick}')
        assert lua('local r=R.get(Run);return r.result=="failed"and r.code==Exit and Exit>0 and #r.items>0 and Replaced and r.qf_id==Replaced.id and r.qf_tick==Replaced.changedtick'),evidence['published_receipt']
        expected=lua('Expected=vim.deepcopy(R.get(Run).items[1]);return Expected')
        assert lua('return Expected.filename==vim.fs.normalize(vim.api.nvim_buf_get_name(Source.buf))and Expected.lnum==1 and Expected.col==19 and Expected.type=="E"and Expected.text:find("undeclared identifier",1,true)~=nil'),expected
        frozen=lua('local r=R.get(Run);return {id=r.id,code=r.code,errors=#r.items,result=r.result,original_qf_tick=r.qf_tick,replaced_qf_tick=vim.fn.getqflist({id=r.qf_id,changedtick=0}).changedtick}')
        assert frozen['original_qf_tick']!=frozen['replaced_qf_tick'],frozen
        lua('Current=B;W.refresh();local model=W.model();for _,action in pairs(model.actions)do assert(action.run_id~=Run)end;assert(R.get(Run).project_root==A.project_root);Current=A;W.refresh()')
        select('problems',lua('return Run'))
        wait('local info=vim.fn.getqflist({context=0,items=0});local item=info.items[1];return vim.bo[vim.api.nvim_get_current_buf()].buftype=="quickfix"and info.context.verification_id==Run and item and item.bufnr==Source.buf and item.type==Expected.type and item.text==Expected.text and item.lnum==Expected.lnum and item.col==Expected.col')
        evidence['restored_problem']=lua('local info=vim.fn.getqflist({id=0,context=0,items=0});return {qf_id=info.id,verification_id=info.context.verification_id,item=info.items[1],source_name=vim.api.nvim_buf_get_name(Source.buf)}')
        source_intact();select('log',lua('return Run'))
        wait('return vim.api.nvim_get_current_buf()==R.get(Run).buf')
        evidence['owned_log']=lua('return {buf=vim.api.nvim_get_current_buf(),expected=R.get(Run).buf,channel=vim.bo[vim.api.nvim_get_current_buf()].channel}')
        source_intact()
        lua('vim.api.nvim_set_current_win(Source.win)');keys('A changed<Esc>')
        wait('return vim.g.ue_unsaved_count and vim.g.ue_unsaved_count>0')
        lua(r'W.refresh();local text=table.concat(W.model().lines,"\n");assert(text:find("历史退出结果不证明当前代码已验证",1,true));assert(R.get(Run).result=="failed")')
        lua("vim.api.nvim_buf_set_lines(Source.buf,0,-1,false,{'int main(){return 0;}'});vim.cmd.write();Source.tick=vim.api.nvim_buf_get_changedtick(Source.buf);Source.cursor=vim.api.nvim_win_get_cursor(Source.win)")
        lua('''
          local python,wrapper,clang,out=...
          Job2=OpenBuild({python,'-c',wrapper,clang,out..'/Alpha/Source.cpp'},{verification_context=A,quickfix_title='Alpha native compiler retry',quickfix_root=A.project_root,is_current=function()return Current==A end,on_exit=function(code)Exit2=code end})
          assert(Job2 and Job2>0);Run2=R.list({project_root=A.project_root})[1].id
        ''',sys.executable,wrapper,clang,out.as_posix())
        wait('return R.get(Run2).completed and Exit2~=nil')
        assert lua('return Exit2==0 and R.get(Run2).result=="exit_zero"and R.list({project_root=A.project_root})[1].id==Run2 and R.get(Run).result=="failed"')
        source_intact();lua('Work=W.open({source_win=Source.win});W.refresh()')
        evidence['failed_then_fixed_saved_retry']={'failure':frozen,'retry_exit':0,'own_problem_snapshot_recovered':True,'own_terminal_log':True,'A_after_B_selection':True}
    elif case=='task':
        lua('''
          local python=...
          Job=OpenBuild({python,'-u','-c','import sys;print("owned task output",flush=True);sys.stdin.readline();print("owned task finished",flush=True)'},{verification_context=A,quickfix_title='Workbench inspection fixture',quickfix_root=A.project_root,is_current=function()return true end})
          assert(Job and Job>0)
          for _,task in ipairs(Registry.list())do local entry=Registry.get(task.id);if entry.handle==Job then Task=task.id end end
          assert(Task);Run=R.list({project_root=A.project_root})[1].id;Work=W.open({source_win=Source.win})
        ''',sys.executable)
        wait('return vim.fn.jobwait({Job},0)[1]==-1')
        select('task',lua('return Task'))
        wait('local buf=vim.api.nvim_get_current_buf();return buf==R.get(Run).buf and vim.bo[buf].buftype=="terminal"and vim.bo[buf].channel==Job and table.concat(vim.api.nvim_buf_get_lines(buf,0,-1,false)," "):find("owned task output",1,true)~=nil')
        source_intact()
        assert lua('return vim.fn.jobwait({Job},0)[1]==-1')
        evidence['inspected_task']=lua('return {buf=vim.api.nvim_get_current_buf(),expected=R.get(Run).buf,channel=vim.bo[vim.api.nvim_get_current_buf()].channel,job_running=vim.fn.jobwait({Job},0)[1]==-1}')
        lua('Work=W.open({source_win=Source.win});assert(W.close(Work));assert(vim.fn.jobwait({Job},0)[1]==-1);vim.fn.chansend(Job,string.char(13))')
        wait('return R.list({project_root=A.project_root})[1].completed')
        assert lua('return R.list({project_root=A.project_root})[1].code==0')
        evidence['native_task_inspection']={'Enter_keeps_job_running':True,'close_view_keeps_job_running':True,'explicit_stdin_completion_exit':0}
    else:raise AssertionError(case)
    evidence['source_bytes_unchanged']=before=={p:hashlib.sha256((root/p).read_bytes()).hexdigest()for p in paths}
    assert evidence['source_bytes_unchanged'],'runtime changed during native verification'
    evidence.update(status='passed',source_sha256=before,ui={'ext_linegrid':True,'flushes':n.redraw['flush']})
    (out/'grid.txt').write_text('\n'.join(''.join(row).rstrip()for row in n.grids.get(1,[])),encoding='utf-8')
except Exception as error:evidence.update(status='failed',error=str(error),trace=traceback.format_exc())
finally:
    (out/'evidence.json').write_text(json.dumps(evidence,ensure_ascii=False,indent=2),encoding='utf-8')
    if n.process.poll()is None:n.process.kill()
    watchdog.cancel();print(json.dumps(evidence,ensure_ascii=False))
    if evidence['status']!='passed':sys.exit(1)
]=]

local function native(case)
  local out = assert(vim.env.NVIM_TEST_RUN_ROOT) .. "/workbench-native-" .. case
  vim.fn.mkdir(out, "p")
  local script = out .. "/native.py"
  vim.fn.writefile(vim.split(program, "\n", { plain = true }), script)
  local result = vim
    .system({ python, script, cfg, out, case, vim.v.progpath, clang }, {
      text = true,
      env = {
        NVIM_APPNAME = "workbench-test",
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

t.describe("development workbench real process and UI", function()
  if python == "" or clang == "" then
    t.skip("actual compiler task through workbench", "installed Python and clang required", { native = true })
  else
    t.it(
      "real compiler failure, newer search, owned errors and log, edit/save and retry remain one task history",
      function()
        native("compiler")
      end
    )
  end
  if python == "" then
    t.skip("workbench native task inspection", "installed Python required", { native = true })
  else
    t.it(
      "Enter inspects a real terminal task, singleton view stays bounded and closing it leaves the job alive",
      function()
        native("task")
      end
    )
  end
end)
