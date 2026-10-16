local t = require("tests.harness")
local cfg = t.bootstrap()

local confirm_driver = [=[
import os
from pathlib import Path
import queue
import runpy
import subprocess
import sys
import threading
import time

root, directory, executable, scenario = sys.argv[1:]
directory = Path(directory)
helper = runpy.run_path(str(Path(root) / "tools" / "measure_inlay_hints.py"))
environment = os.environ.copy()
for variable in ("XDG_CONFIG_HOME", "XDG_CACHE_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME"):
    environment[variable] = str(directory / variable.lower())

class Session(helper["Nvim"]):
    def call(self, method, *arguments):
        self.sequence += 1
        identifier = self.sequence
        self.process.stdin.write(helper["pack"]([0, identifier, method, arguments]))
        self.process.stdin.flush()
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            message = self.messages.get(timeout=max(0.01, deadline - time.monotonic()))
            self.consume(message)
            if isinstance(message, list) and message[:2] == [1, identifier]:
                if message[2]:
                    raise RuntimeError(message[2])
                return message[3]
        raise TimeoutError(method)

    def screen(self):
        return "\n".join("".join(row) for grid in self.grids.values() for row in grid)

    def wait_for(self, predicate, label):
        deadline = time.monotonic() + 5
        while not predicate():
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError(label + "\n" + self.screen())
            try:
                self.consume(self.messages.get(timeout=min(remaining, 0.05)))
            except queue.Empty:
                pass

instance = Session(executable, environment, directory / "nvim.stderr.log")
def expire():
    instance.process.kill()
    instance.process.wait(timeout=3)
    os._exit(2)
watchdog = threading.Timer(15, expire)
watchdog.daemon = True
watchdog.start()
try:
    instance.call("nvim_ui_attach", 120, 26, {"rgb": True, "ext_linegrid": True})
    instance.lua("""
        local root, directory = ...
        vim.opt.rtp:prepend(root)
        vim.o.swapfile=false; vim.o.shada=''; vim.o.hidden=true
        local api=vim.api
        _G.confirm_source=directory..'/Source.cpp'
        _G.confirm_other=directory..'/Other.cpp'
        vim.fn.writefile({'Old source;'},_G.confirm_source)
        vim.fn.writefile({'Old other;'},_G.confirm_other)
        _G.confirm_a=vim.fn.bufadd(_G.confirm_source); vim.fn.bufload(_G.confirm_a)
        _G.confirm_b=vim.fn.bufadd(_G.confirm_other); vim.fn.bufload(_G.confirm_b)
        api.nvim_set_current_buf(_G.confirm_a)
        local c={id=778,name='ide-confirm-server',offset_encoding='utf-16',config={root_dir=directory},handlers={},flags={}}
        function c:is_stopped() return false end
        function c:supports_method(method) return method~='textDocument/prepareRename' end
        function c:cancel_request() end
        function c:request(method,params,cb)
          local change={range={start={line=0,character=0},['end']={line=0,character=3}},newText='New'}
          cb(nil,{changes={[vim.uri_from_fname(_G.confirm_source)]={change},[vim.uri_from_fname(_G.confirm_other)]={change}}})
          return true,1
        end
        vim.lsp.get_client_by_id=function() return c end
        vim.lsp.get_clients=function() return {c} end
        vim.lsp.buf_is_attached=function() return true end
        _G.confirm_notices={}
        vim.notify=function(message) table.insert(_G.confirm_notices,message) end
        vim.ui.select=function(items,_,cb) _G.confirm_items,_G.confirm_choose=items,cb end
        _G.confirm_refactor=require('utils.refactor')
        _G.confirm_action=_G.confirm_refactor.rename('New')
    """, root, str(directory))
    instance.wait_for(lambda: instance.lua("return _G.confirm_items~=nil"), "file list missing")
    instance.lua("vim.schedule(function() _G.confirm_choose(_G.confirm_items[1]) end)")
    instance.wait_for(lambda: "保留在缓冲区" in instance.screen() and "取消" in instance.screen(), "native confirmation missing")
    prompt = instance.screen()
    assert "全部 2 个文件" in prompt, prompt
    if scenario == "rpc":
        instance.lua("""
          assert(_G.confirm_action.confirming)
          vim.api.nvim_buf_set_lines(_G.confirm_a,0,-1,true,{'USER input during confirmation;'})
        """)
    key = "<CR>" if scenario == "default" else "y"
    assert instance.call("nvim_input", key) > 0
    if scenario != "default":
        instance.wait_for(lambda: instance.lua("return _G.confirm_action.batch.state=='applied' or _G.confirm_action.batch.state=='rejected'"), "batch did not finish")
    state = instance.lua("""
      return {a=vim.api.nvim_buf_get_lines(_G.confirm_a,0,-1,true),
        b=vim.api.nvim_buf_get_lines(_G.confirm_b,0,-1,true),
        a_modified=vim.bo[_G.confirm_a].modified,b_modified=vim.bo[_G.confirm_b].modified,
        disk_a=vim.fn.readfile(_G.confirm_source),disk_b=vim.fn.readfile(_G.confirm_other),
        state=_G.confirm_action.batch.state,notices=_G.confirm_notices}
    """)
    if scenario == "yes":
        assert state["a"] == ["New source;"] and state["b"] == ["New other;"], state
        assert state["a_modified"] and state["b_modified"] and state["state"] == "applied", state
    elif scenario == "rpc":
        assert state["a"] == ["USER input during confirmation;"] and state["b"] == ["Old other;"], state
        assert state["a_modified"] and not state["b_modified"] and state["state"] == "rejected", state
    else:
        assert state["a"] == ["Old source;"] and state["b"] == ["Old other;"], state
        assert not state["a_modified"] and not state["b_modified"], state
    assert state["disk_a"] == ["Old source;"] and state["disk_b"] == ["Old other;"], state
    print("IDE_REFACTOR_CONFIRM_OK " + scenario)
finally:
    watchdog.cancel()
    if instance.process.poll() is None:
        instance.process.terminate()
    try:
        instance.process.wait(timeout=3)
    except subprocess.TimeoutExpired:
        instance.process.kill()
        instance.process.wait(timeout=3)
    for stream in (instance.process.stdin, instance.process.stdout):
        stream.close()
    instance.log.close()
]=]

local helpers = [[
vim.o.hidden = true
local api, uv = vim.api, vim.uv
local edit = require('utils.workspace_edit')
local dir = vim.fn.tempname()
vim.fn.mkdir(dir, 'p')
local function file(name, bytes, load)
  local path = dir .. '/' .. name
  local fd = assert(uv.fs_open(path, 'w', 384))
  assert(uv.fs_write(fd, bytes, 0))
  assert(uv.fs_close(fd))
  local buf
  if load ~= false then buf = vim.fn.bufadd(path); vim.fn.bufload(buf) end
  return {path=path, uri=vim.uri_from_fname(path), buf=buf}
end
local function lines(item) return api.nvim_buf_get_lines(item.buf, 0, -1, true) end
local function text_edit(new, line, first, last)
  return {range={start={line=line or 0,character=first or 0},['end']={line=line or 0,character=last or 3}},newText=new}
end
local function await(start)
  local done, values
  start(function(...) values={...}; done=true end)
  assert(vim.wait(5000,function() return done end,10), 'asynchronous operation timed out')
  return unpack(values)
end
local function prepare(changes, opts)
  local batch, reason = await(function(cb) edit.prepare(changes,'utf-16',opts or {},cb) end)
  assert(batch, tostring(reason)); return batch
end
local function apply(batch) return await(function(cb) edit.apply(batch, cb) end) end
local function undo(batch) return await(function(cb) edit.undo(batch, cb) end) end
local function disk(item)
  local fd = assert(uv.fs_open(item.path,'r',0))
  local bytes=assert(uv.fs_read(fd,assert(uv.fs_fstat(fd)).size,0)); uv.fs_close(fd)
  return bytes
end
local function fake_client(item, name)
  local client={id=777, name=name or 'test-server', offset_encoding='utf-16', config={root_dir=dir}, handlers={}, requests={},
    server_capabilities={},flags={}}
  function client:is_stopped() return false end
  function client:supports_method(method) return method~='textDocument/prepareRename' end
  function client:cancel_request() end
  vim.lsp.get_client_by_id=function(id) return id==777 and client or nil end
  vim.lsp.get_clients=function() return {client} end
  vim.lsp.buf_is_attached=function() return true end
  api.nvim_set_current_buf(item.buf)
  api.nvim_win_set_cursor(0,{1,0})
  return client
end
vim.notify=function() end
]]

local function child(code, timeout)
  local script = vim.fn.tempname() .. ".lua"
  vim.fn.writefile(
    vim.split(
      ("vim.opt.rtp:prepend(%q)\n%s\n%s\nvim.fn.delete(dir,'rf')\nprint('IDE_REFACTOR_OK')"):format(cfg, helpers, code),
      "\n",
      { plain = true }
    ),
    script
  )
  local result = vim
    .system({ vim.v.progpath, "--headless", "-u", "NONE", "-i", "NONE", "-n", "-l", script }, { text = true })
    :wait(timeout or 12000)
  vim.fn.delete(script)
  t.assert_eq(result.code, 0, (result.stdout or "") .. (result.stderr or ""))
  t.assert_contains((result.stdout or "") .. (result.stderr or ""), "IDE_REFACTOR_OK")
end

t.describe("ide_refactor: 审阅后的整批修改与恢复", function()
  local native_platform = require("utils.platform")
  local python = native_platform.resolve_tool({
    name = "python",
    env = { "UE_PYTHON" },
    driver_candidates = function(driver)
      return driver.python_candidates()
    end,
  })
  for _, scenario in ipairs({ "yes", "default", "rpc" }) do
    local title = "native UI confirmation: " .. scenario
    if not python.ok then
      t.skip(title, "Python unavailable for attached UI driver", { native = true })
    else
      t.it(title, function()
        local directory = vim.fn.tempname()
        vim.fn.mkdir(directory, "p")
        local script = directory .. "/confirm.py"
        vim.fn.writefile(vim.split(confirm_driver, "\n", { plain = true }), script)
        local result = vim
          .system(
            { python.path, script, cfg, directory, vim.v.progpath, scenario },
            { text = true, env = { PYTHONIOENCODING = "utf-8" } }
          )
          :wait(20000)
        vim.fn.delete(directory, "rf")
        t.assert_eq(result.code, 0, (result.stdout or "") .. (result.stderr or ""))
        t.assert_contains((result.stdout or "") .. (result.stderr or ""), "IDE_REFACTOR_CONFIRM_OK " .. scenario)
      end)
    end
  end
  t.it("native baseline demonstrates partial application on the second-file exception", function()
    child([[
      local a,b=file('A.cpp','Old a;\n'),file('B.cpp','Old b;\n')
      local original=api.nvim_buf_set_text
      api.nvim_buf_set_text=function(buf,...)
        if buf==b.buf then error('controlled second-file failure') end
        return original(buf,...)
      end
      local ok=pcall(vim.lsp.util.apply_workspace_edit,{documentChanges={
        {textDocument={uri=a.uri},edits={text_edit('New')}},
        {textDocument={uri=b.uri},edits={text_edit('New')}}}},'utf-16')
      api.nvim_buf_set_text=original
      assert(not ok and lines(a)[1]=='New a;' and lines(b)[1]=='Old b;')
      assert(disk(a)=='Old a;\n' and disk(b)=='Old b;\n')
    ]])
  end)

  t.it("read-only preparation and cancellation retain dirty buffers and disk", function()
    child([[
      local a,b=file('A.cpp','Old a;\n'),file('B.cpp','Old b;\n',false)
      api.nvim_buf_set_lines(a.buf,0,-1,true,{'Old dirty;'})
      local tick=api.nvim_buf_get_changedtick(a.buf)
      local batch=prepare({changes={[a.uri]={text_edit('New')},[b.uri]={text_edit('New')}}})
      assert(batch.state=='preview' and #batch.targets==2)
      assert(api.nvim_buf_get_changedtick(a.buf)==tick and vim.bo[a.buf].modified)
      assert(lines(a)[1]=='Old dirty;' and disk(a)=='Old a;\n')
      assert(vim.fn.bufloaded(b.path)==0)
      assert(edit.cancel(batch))
      local ok=apply(batch); assert(not ok and lines(a)[1]=='Old dirty;')
      assert(disk(b)=='Old b;\n')
    ]])
  end)

  t.it("unversioned batch applies to two native buffers without saving; undo restores dirty overlay", function()
    child([[
      local a,b=file('A.cpp','Old a;\n'),file('B.cpp','Old b;\n',false)
      api.nvim_buf_set_lines(a.buf,0,-1,true,{'Old dirty;'})
      local batch=prepare({changes={[a.uri]={text_edit('New')},[b.uri]={text_edit('New')}}})
      assert(apply(batch))
      b.buf=vim.fn.bufnr(b.path)
      assert(lines(a)[1]=='New dirty;' and lines(b)[1]=='New b;')
      assert(vim.bo[a.buf].modified and vim.bo[b.buf].modified)
      assert(disk(a)=='Old a;\n' and disk(b)=='Old b;\n')
      assert(undo(batch))
      assert(lines(a)[1]=='Old dirty;' and vim.bo[a.buf].modified)
      assert(lines(b)[1]=='Old b;' and not vim.bo[b.buf].modified)
    ]])
  end)

  t.it("every versioned document is checked, including version zero and second file", function()
    child([[
      local a,b=file('A.cpp','Old a;\n'),file('B.cpp','Old b;\n')
      vim.lsp.util.buf_versions[a.buf]=0
      vim.lsp.util.buf_versions[b.buf]=9
      local function request(version)
        return {documentChanges={
          {textDocument={uri=a.uri,version=0},edits={text_edit('New')}},
          {textDocument={uri=b.uri,version=version},edits={text_edit('New')}}}}
      end
      local rejected,reason=await(function(cb) edit.prepare(request(8),'utf-16',{},cb) end)
      assert(not rejected and reason=='document-version-stale')
      local batch=prepare(request(9))
      vim.lsp.util.buf_versions[b.buf]=10
      local ok=apply(batch)
      assert(not ok and lines(a)[1]=='Old a;' and lines(b)[1]=='Old b;')
      assert(not vim.bo[a.buf].modified and not vim.bo[b.buf].modified)
    ]])
  end)

  t.it("Unicode UTF-16, CRLF and BOM use native edit semantics and preserve file options", function()
    child([[
      local a=file('A.cpp','\239\187\191// 😀 Old 中文\r\nOld value;\r\n')
      local old_options={vim.bo[a.buf].fileformat,vim.bo[a.buf].bomb,vim.bo[a.buf].endofline}
      local batch=prepare({changes={[a.uri]={text_edit('New',0,6,9),text_edit('New',1,0,3)}}})
      assert(batch.targets[1].after[1]=='// 😀 New 中文')
      assert(apply(batch))
      assert(lines(a)[1]=='// 😀 New 中文' and lines(a)[2]=='New value;')
      assert(vim.deep_equal(old_options,{vim.bo[a.buf].fileformat,vim.bo[a.buf].bomb,vim.bo[a.buf].endofline}))
      assert(disk(a)=='\239\187\191// 😀 Old 中文\r\nOld value;\r\n')
      assert(undo(batch) and lines(a)[1]=='// 😀 Old 中文')
    ]])
  end)

  t.it("target edits, rename, disappearance and readonly changes reject the whole batch", function()
    child([[
      for _,change in ipairs({
        function(b) api.nvim_buf_set_lines(b.buf,0,-1,true,{'user input;'}) end,
        function(b) api.nvim_buf_set_name(b.buf,b.path..'.renamed') end,
        function(b) vim.fn.delete(b.path) end,
        function(b) vim.bo[b.buf].readonly=true end,
        function(b) vim.bo[b.buf].modifiable=false end}) do
        local a,b=file('A'..tostring(math.random())..'.cpp','Old a;\n'),file('B'..tostring(math.random())..'.cpp','Old b;\n')
        local batch=prepare({changes={[a.uri]={text_edit('New')},[b.uri]={text_edit('New')}}})
        change(b)
        assert(not apply(batch))
        assert(lines(a)[1]=='Old a;' and not vim.bo[a.buf].modified)
      end
    ]])
  end)

  t.it("same-size disk write with restored mtime is rejected by byte digest", function()
    child([[
      local a,b=file('A.cpp','Old a;\n'),file('B.cpp','Old b;\n')
      local batch=prepare({changes={[a.uri]={text_edit('New')},[b.uri]={text_edit('New')}}})
      local stat=assert(uv.fs_stat(b.path))
      local fd=assert(uv.fs_open(b.path,'w',384)); uv.fs_write(fd,'Old z;\n',0); uv.fs_close(fd)
      uv.fs_utime(b.path,stat.atime.sec,stat.mtime.sec+stat.mtime.nsec/1e9)
      assert(not apply(batch))
      assert(lines(a)[1]=='Old a;' and lines(b)[1]=='Old b;' and disk(b)=='Old z;\n')
    ]])
  end)

  t.it("client/context/coverage checker revocation and request baseline reject old results", function()
    child([[
      local a=file('A.cpp','Old a;\n')
      local valid=true
      local baseline={[a.buf]={name=api.nvim_buf_get_name(a.buf),tick=api.nvim_buf_get_changedtick(a.buf)}}
      local batch=prepare({changes={[a.uri]={text_edit('New')}}},{check=function() return valid,'coverage-epoch-changed' end})
      valid=false
      local ok,reason=apply(batch)
      assert(not ok and reason=='coverage-epoch-changed' and lines(a)[1]=='Old a;')
      api.nvim_buf_set_lines(a.buf,0,-1,true,{'Old later;'})
      local rejected,why=await(function(cb)
        edit.prepare({changes={[a.uri]={text_edit('New')}}},'utf-16',{baseline=baseline},cb)
      end)
      assert(not rejected and why=='target-changed-during-request')
    ]])
  end)

  t.it("target loaded and edited during an unversioned request cannot replace a missing baseline", function()
    child([[
      local a,b=file('A.cpp','Old a;\n'),file('B.cpp','Old b;\n',false)
      local baseline={[a.buf]={name=api.nvim_buf_get_name(a.buf),tick=api.nvim_buf_get_changedtick(a.buf)}}
      b.buf=vim.fn.bufadd(b.path); vim.fn.bufload(b.buf)
      api.nvim_buf_set_lines(b.buf,0,-1,true,{'USER Old target;'})
      vim.lsp.buf_is_attached=function() return true end
      local batch,reason=await(function(cb)
        edit.prepare({changes={[b.uri]={text_edit('New')}}},'utf-16',{baseline=baseline,client={id=1}},cb)
      end)
      assert(not batch and reason=='target-loaded-or-recreated-during-request')
      assert(lines(b)[1]=='USER Old target;' and vim.bo[b.buf].modified and disk(b)=='Old b;\n')
    ]])
  end)

  t.it("resource operations, duplicate documents, overlapping ranges and surrogate halves fail closed", function()
    child([[
      local a=file('A.cpp','😀 Old\n')
      local invalid={
        {documentChanges={{kind='create',uri=a.uri..'.new'}}},
        {documentChanges={{kind='rename',oldUri=a.uri,newUri=a.uri..'.new'}}},
        {documentChanges={{kind='delete',uri=a.uri}}},
        {documentChanges={{textDocument={uri=a.uri},edits={text_edit('X',0,3,6)}},
          {textDocument={uri=a.uri},edits={text_edit('Y',0,3,6)}}}},
        {changes={[a.uri]={text_edit('X',0,3,6),text_edit('Y',0,4,6)}}},
        {changes={[a.uri]={text_edit('X',0,1,2)}}},
        {changes={['untitled:buffer']={text_edit('X')}}}}
      for _,workspace in ipairs(invalid) do
        local batch=await(function(cb) edit.prepare(workspace,'utf-16',{},cb) end)
        assert(not batch and lines(a)[1]=='😀 Old' and not vim.bo[a.buf].modified)
      end
    ]])
  end)

  t.it("second-file native API failure restores the first snapshot and original modified flags", function()
    child([[
      local a,b=file('A.cpp','Old a;\n'),file('B.cpp','Old b;\n')
      api.nvim_buf_set_lines(a.buf,0,-1,true,{'Old dirty;'})
      local batch=prepare({changes={[a.uri]={text_edit('New')},[b.uri]={text_edit('New')}}})
      local original=api.nvim_buf_set_text
      api.nvim_buf_set_text=function(buf,...)
        if buf==b.buf then error('controlled second-file failure') end
        return original(buf,...)
      end
      local ok=apply(batch)
      api.nvim_buf_set_text=original
      assert(not ok and batch.state=='failed')
      assert(lines(a)[1]=='Old dirty;' and vim.bo[a.buf].modified)
      assert(lines(b)[1]=='Old b;' and not vim.bo[b.buf].modified)
      assert(batch.evidence.files[1].state=='restored' and batch.evidence.files[2].state=='untouched')
    ]])
  end)

  t.it("new input during failure is retained with explicit blocked-recovery evidence", function()
    child([[
      local a,b=file('A.cpp','Old a;\n'),file('B.cpp','Old b;\n')
      local batch=prepare({changes={[a.uri]={text_edit('New')},[b.uri]={text_edit('New')}}})
      local original=api.nvim_buf_set_text
      api.nvim_buf_set_text=function(buf,...)
        if buf==b.buf then
          original(a.buf,0,0,0,0,{'USER '})
          error('second-file failure after new input')
        end
        return original(buf,...)
      end
      assert(not apply(batch))
      api.nvim_buf_set_text=original
      assert(lines(a)[1]=='USER New a;' and vim.bo[a.buf].modified)
      assert(lines(b)[1]=='Old b;' and not vim.bo[b.buf].modified)
      assert(batch.evidence.files[1].state=='recovery-blocked')
      assert(batch.targets[1].before.lines[1]=='Old a;' and batch.targets[1].after[1]=='New a;')
    ]])
  end)

  t.it("re-entry and a new input within the native write cannot impersonate owned text", function()
    child([[
      local a,b=file('A.cpp','Old a;\n'),file('B.cpp','Old b;\n')
      local batch=prepare({changes={[a.uri]={text_edit('New')},[b.uri]={text_edit('New')}}})
      local original=api.nvim_buf_set_text
      local reentered
      api.nvim_buf_set_text=function(buf,...)
        if buf==a.buf then
          edit.apply(batch,function(ok) reentered=ok end)
          original(buf,...)
          original(buf,0,0,0,0,{'USER '})
        else original(buf,...) end
      end
      assert(not apply(batch))
      api.nvim_buf_set_text=original
      assert(reentered==false and lines(a)[1]=='USER New a;' and lines(b)[1]=='Old b;')
      assert(batch.evidence.files[1].state=='recovery-blocked')
    ]])
  end)

  t.it("undo refuses newer input or disk changes before undoing any file", function()
    child([[
      for _,change in ipairs({
        function(b) api.nvim_buf_set_lines(b.buf,0,-1,true,{'USER new content;'}) end,
        function(b) local fd=uv.fs_open(b.path,'w',384); uv.fs_write(fd,'external contents\n',0); uv.fs_close(fd) end}) do
        local a,b=file('A'..tostring(math.random())..'.cpp','Old a;\n'),file('B'..tostring(math.random())..'.cpp','Old b;\n')
        local batch=prepare({changes={[a.uri]={text_edit('New')},[b.uri]={text_edit('New')}}})
        assert(apply(batch))
        change(b)
        local prior=lines(b)[1]
        assert(not undo(batch))
        assert(lines(a)[1]=='New a;' and lines(b)[1]==prior)
        assert(vim.bo[a.buf].modified)
      end
    ]])
  end)

  t.it("failed undo exposes its latest recovery evidence and preserves new input", function()
    child([[
      local a,b=file('A.cpp','Old a;\n'),file('B.cpp','Old b;\n')
      local batch=prepare({changes={[a.uri]={text_edit('New')},[b.uri]={text_edit('New')}}})
      assert(apply(batch))
      local original=api.nvim_buf_set_text
      api.nvim_buf_set_text=function(buf,...)
        if buf==b.buf then original(a.buf,0,0,0,0,{'USER '}); error('controlled undo failure') end
        return original(buf,...)
      end
      assert(not undo(batch))
      api.nvim_buf_set_text=original
      local report=edit.report(batch)
      assert(report.operation=='undo' and report.state=='failed' and report.files[1].state=='recovery-blocked')
      assert(batch.state=='undo-failed')
      assert(batch.evidence.files[1].state=='applied','original successful application record must remain')
      assert(lines(a)[1]=='USER Old a;' and lines(b)[1]=='New b;')
      assert(batch.targets[1].before.lines[1]=='Old a;' and batch.targets[1].after[1]=='New a;')
    ]])
  end)

  t.it("undo freezes the named batch and refuses a newer batch completed during confirmation", function()
    child([[
      local a=file('A.cpp','Old source;\n')
      local client=fake_client(a)
      local refactor=require('utils.refactor')
      function client:request(method,params,cb)
        assert(method=='textDocument/rename')
        cb(nil,{changes={[a.uri]={text_edit(params.newName)}}}); return true,1
      end
      vim.ui.select=function(items,_,cb) cb(items[1]) end
      vim.fn.confirm=function() return 1 end
      refactor.rename('New')
      assert(vim.wait(5000,function() local b=refactor.last_batch(); return b and b.state=='applied' end,10))
      local first=refactor.last_batch()
      local undo_prompt
      vim.fn.confirm=function(message)
        if message:find('撤销 ',1,true)==1 then
          undo_prompt=message
          refactor.rename('Third')
          assert(vim.wait(5000,function() return refactor.last_batch()~=first and refactor.last_batch().state=='applied' end,10))
        end
        return 1
      end
      refactor.undo()
      vim.wait(100)
      assert(undo_prompt:find('Rename → New',1,true))
      assert(lines(a)[1]=='Third source;' and refactor.last_batch().state=='applied')
      assert(first.state=='applied' and vim.bo[a.buf].modified)
    ]])
  end)

  t.it("minimal native span covers multi-line insert/delete and Unicode while preserving outer marks", function()
    child([[
      local fixtures={
        {{'Old'}, {range={start={line=0,character=3},['end']={line=0,character=3}},newText='\nextra'}},
        {{'Old','extra'}, {range={start={line=0,character=3},['end']={line=1,character=5}},newText=''}},
        {{'prefix','Old','tail'}, {range={start={line=1,character=0},['end']={line=1,character=3}},newText='😀\n中文'}},
        {{'😀 tail'},text_edit('😄',0,0,2)},
        {{''},text_edit('first\nsecond',0,0,0)}}
      for index,fixture in ipairs(fixtures) do
        local a=file('A'..index..'.cpp',table.concat(fixture[1],'\n')..'\n')
        local batch=prepare({changes={[a.uri]={fixture[2]}}})
        assert(apply(batch) and vim.deep_equal(lines(a),batch.targets[1].after))
        assert(undo(batch) and vim.deep_equal(lines(a),fixture[1]))
      end
      local a=file('Mark.cpp','prefix\nOld\ntail\n')
      api.nvim_buf_set_mark(a.buf,'m',3,0,{})
      local batch=prepare({changes={[a.uri]={text_edit('New',1,0,3)}}})
      assert(apply(batch) and api.nvim_buf_get_mark(a.buf,'m')[1]==3)
    ]])
  end)

  t.it("native read-only diff closes only owned windows and retains dirty source splits", function()
    child([[
      local a=file('A.cpp','Old a;\n')
      api.nvim_set_current_buf(a.buf)
      api.nvim_buf_set_lines(a.buf,0,-1,true,{'Old dirty;'})
      vim.cmd('vsplit')
      local wins=api.nvim_list_wins()
      local buffer_count=#api.nvim_list_bufs()
      local batch=prepare({changes={[a.uri]={text_edit('New')}}})
      local ui=require('utils.rename_preview')
      assert(ui.open(batch,batch.targets[1],{}))
      for _,win in ipairs(api.nvim_tabpage_list_wins(0)) do
        local buf=api.nvim_win_get_buf(win)
        assert(vim.bo[buf].readonly and not vim.bo[buf].modifiable and not vim.bo[buf].modified)
      end
      ui.close()
      assert(#api.nvim_list_wins()==#wins and lines(a)[1]=='Old dirty;' and vim.bo[a.buf].modified)
      assert(#api.nvim_list_bufs()==buffer_count,'preview must not leave anonymous buffers behind')
      for _,win in ipairs(wins) do assert(api.nvim_win_is_valid(win) and api.nvim_win_get_buf(win)==a.buf) end
    ]])
  end)

  t.it("rename requests use captured UTF-16 position, reject duplicate response, cancel with zero writes", function()
    child([[
      local a=file('A.cpp','😀 Old a;\n')
      local client=fake_client(a)
      api.nvim_win_set_cursor(0,{1,5})
      local menus,choices=0
      vim.ui.select=function(items,_,cb) menus=menus+1; choices={items,cb} end
      function client:request(method,params,cb)
        assert(method=='textDocument/rename' and params.position.character==3 and params.newName=='New')
        local response={changes={[a.uri]={text_edit('New',0,3,6)}}}
        cb(nil,response); cb(nil,response)
        return true,1
      end
      require('utils.refactor').rename('New')
      assert(vim.wait(3000,function() return choices end,10))
      assert(menus==1 and lines(a)[1]=='😀 Old a;')
      choices[2](nil)
      assert(lines(a)[1]=='😀 Old a;' and not vim.bo[a.buf].modified)
    ]])
  end)

  t.it("rename preview refuses changed client, source name, encoding, project and guard epoch", function()
    child([[
      local refactor=require('utils.refactor')
      for _,change in ipairs({
        function(a,c) vim.lsp.get_client_by_id=function() return {} end end,
        function(a,c) api.nvim_buf_set_name(a.buf,a.path..'.renamed') end,
        function(a,c) c.offset_encoding='utf-8' end,
        function(a,c) c.config.root_dir=dir..'/OtherProject' end,
        function(a,c) c.guard_epoch=2 end}) do
        local a=file('A'..tostring(math.random())..'.cpp','Old a;\n')
        local client=fake_client(a)
        client.guard_epoch=1
        client._ue_batch_guard={guard={status=function() return {state='ready',epoch=client.guard_epoch} end}}
        local cb
        function client:request(_,_,callback) cb=callback; return true,1 end
        local menus=0
        vim.ui.select=function() menus=menus+1 end
        refactor.rename('New')
        change(a,client)
        cb(nil,{changes={[a.uri]={text_edit('New')}}})
        vim.wait(100)
        assert(menus==0 and lines(a)[1]=='Old a;' and not vim.bo[a.buf].modified)
      end
    ]])
  end)

  t.it("actual editable code-action titles are selected and previewed without invented transforms", function()
    child([[
      local a=file('A.cpp','Old a;\n')
      local client=fake_client(a)
      local action_menu,preview_menu
      vim.ui.select=function(items,opts,cb)
        if opts.kind=='codeaction' then action_menu={items,cb} else preview_menu={items,cb} end
      end
      function client:request(method,params,cb)
        assert(method=='textDocument/codeAction')
        assert(params.range.start.character==0 and params.context.triggerKind==1)
        cb(nil,{{title='Compiler Insert Declaration',kind='refactor.rewrite',edit={changes={[a.uri]={text_edit('New')}}}},
          {title='Disabled real action',disabled={reason='server says no'}}})
        return true,1
      end
      require('utils.refactor').code_actions()
      assert(action_menu and #action_menu[1]==2)
      assert(action_menu[1][1].action.title=='Compiler Insert Declaration')
      action_menu[2](action_menu[1][1]); action_menu[2](action_menu[1][1])
      assert(vim.wait(3000,function() return preview_menu end,10))
      preview_menu[2](nil)
      assert(lines(a)[1]=='Old a;' and not vim.bo[a.buf].modified)
    ]])
  end)

  t.it("cancelled native command picker and confirmation cannot execute a stale action", function()
    child([[
      local a=file('A.cpp','Old a;\n')
      local client=fake_client(a)
      local refactor=require('utils.refactor')
      local action_menu,native_menu,executions
      executions=0
      vim.ui.select=function(items,opts,cb)
        if opts.kind=='codeaction' then action_menu={items,cb} else native_menu={items,cb} end
      end
      function client:request(method,_,cb)
        if method=='textDocument/codeAction' then cb(nil,{{title='Actual native command',command='server.nativeOperation'}})
        else cb(nil,nil) end
        return true,1
      end
      function client:exec_cmd() executions=executions+1 end
      vim.fn.confirm=function() return 1 end
      refactor.code_actions(); action_menu[2](action_menu[1][1])
      local old_native_menu=native_menu
      refactor.rename('Another')
      old_native_menu[2]('原生执行（无预览、无整批撤销）')
      assert(executions==0,'cancelled picker executed a stale native command')
      refactor.code_actions(); action_menu[2](action_menu[1][1])
      vim.fn.confirm=function() refactor.rename('Another'); return 1 end
      native_menu[2]('原生执行（无预览、无整批撤销）')
      assert(executions==0,'cancelled confirmation executed a stale native command')
      assert(lines(a)[1]=='Old a;' and not vim.bo[a.buf].modified)
    ]])
  end)

  t.it("a detached action server settles without hiding a healthy server's real actions", function()
    child([[
      local a=file('A.cpp','Old a;\n')
      local first=fake_client(a)
      local second={id=778,name='second-server',offset_encoding='utf-16',config={root_dir=dir},handlers={},requests={},flags={},server_capabilities={}}
      function second:is_stopped() return false end
      function second:supports_method() return true end
      function second:cancel_request() end
      local connected={[first.id]=first,[second.id]=second}
      vim.lsp.get_client_by_id=function(id) return connected[id] end
      vim.lsp.get_clients=function() return {first,second} end
      local healthy={title='Healthy actual action',edit={changes={[a.uri]={text_edit('New')}}}}
      function first:request(_,_,cb) cb(nil,{healthy}); return true,1 end
      local respond
      function second:request(_,_,cb) respond=cb; return true,2 end
      local choices,menu_count
      menu_count=0
      vim.ui.select=function(items,opts,cb)
        if opts.kind=='codeaction' then choices=items; menu_count=menu_count+1 end
      end
      require('utils.refactor').code_actions()
      connected[second.id]=nil
      respond(nil,{{title='Detached stale action'}}); respond(nil,{healthy})
      assert(menu_count==1 and #choices==1 and choices[1].action.title=='Healthy actual action')
      assert(lines(a)[1]=='Old a;' and not vim.bo[a.buf].modified)
    ]])
  end)

  t.it("clangd applyTweak captures its actual applyEdit, restores scoped handlers, then previews", function()
    child([[
      local a=file('A.cpp','Old a;\n')
      local client=fake_client(a,'clangd')
      package.loaded['ue.clangd_commands']={ensure=function(_,_,cb) cb(true) end}
      local old_handler=function() error('old handler must not apply during capture') end
      client.handlers['workspace/applyEdit']=old_handler
      local command={title='Extract actual expression',command='clangd.applyTweak',
        arguments={{file=a.uri,selection={start={line=0,character=0},['end']={line=0,character=3}},tweakID='ExtractVariable'}}}
      local command_menu,preview_menu,rejected
      vim.ui.select=function(items,opts,cb)
        if opts.kind=='codeaction' then command_menu={items,cb} else preview_menu={items,cb} end
      end
      function client:request(method,params,cb)
        if method=='textDocument/codeAction' then cb(nil,{command})
        elseif method=='workspace/executeCommand' then
          assert(params.command=='clangd.applyTweak')
          rejected=client.handlers['workspace/applyEdit'](nil,{edit={changes={[a.uri]={text_edit('New')}}}},{client_id=client.id})
          cb({code=-32001,message='edits were not applied: '..rejected.failureReason})
        else error(method) end
        return true,1
      end
      local original_request=client.request
      require('utils.refactor').code_actions()
      command_menu[2](command_menu[1][1])
      assert(vim.wait(3000,function() return preview_menu end,10))
      assert(rejected.applied==false and client.handlers['workspace/applyEdit']==old_handler)
      assert(client.request==original_request and not client._ue_refactor_command)
      assert(lines(a)[1]=='Old a;' and not vim.bo[a.buf].modified)
      preview_menu[2](nil)
    ]])
  end)

  t.it("scoped command rejects multiple applyEdits/concurrent command and cancellation restores client", function()
    child([[
      local a=file('A.cpp','Old a;\n')
      local client=fake_client(a,'clangd')
      package.loaded['ue.clangd_commands']={ensure=function(_,_,cb) cb(true) end}
      local old_handler=function() end
      client.handlers['workspace/applyEdit']=old_handler
      local command={title='Extract actual expression',command='clangd.applyTweak',arguments={{file=a.uri,tweakID='ExtractVariable'}}}
      local menu,execute_cb,preview_count
      preview_count=0
      vim.ui.select=function(items,opts,cb)
        if opts.kind=='codeaction' then menu={items,cb} else preview_count=preview_count+1 end
      end
      function client:request(method,params,cb)
        if method=='textDocument/codeAction' then cb(nil,{command})
        elseif method=='workspace/executeCommand' then execute_cb=cb end
        return true,1
      end
      local original_request=client.request
      local refactor=require('utils.refactor')
      refactor.code_actions(); menu[2](menu[1][1])
      assert(client._ue_refactor_command)
      assert(client:request('workspace/executeCommand',{},function() error('should reject') end)==false)
      local response=client.handlers['workspace/applyEdit'](nil,{edit={changes={[a.uri]={text_edit('New')}}}},{client_id=client.id})
      client.handlers['workspace/applyEdit'](nil,{edit={changes={[a.uri]={text_edit('Bad')}}}},{client_id=client.id})
      execute_cb({code=-32001,message='edits were not applied: '..response.failureReason})
      assert(client.handlers['workspace/applyEdit']==old_handler and client.request==original_request and preview_count==0)
      refactor.code_actions(); menu[2](menu[1][1])
      assert(client._ue_refactor_command)
      function client:request(method,_,cb) if method=='textDocument/rename' then cb(nil,nil) end; return true,2 end
      local new_request=client.request
      refactor.rename('New')
      assert(client.handlers['workspace/applyEdit']~=old_handler and client._ue_refactor_command)
      local late=client.handlers['workspace/applyEdit'](nil,{edit={changes={[a.uri]={text_edit('LATE')}}}},{client_id=client.id})
      assert(late.applied==false and lines(a)[1]=='Old a;')
      execute_cb({code=-32800,message='cancelled'})
      assert(client.handlers['workspace/applyEdit']==old_handler and not client._ue_refactor_command)
      assert(client.request==new_request, 'foreign replacement must not be overwritten')
      assert(lines(a)[1]=='Old a;' and not vim.bo[a.buf].modified)
    ]])
  end)

  t.it("command timeout keeps a rejecting tombstone until the late response drains exactly once", function()
    child([[
      local a=file('A.cpp','Old a;\n')
      local client=fake_client(a,'clangd')
      package.loaded['ue.clangd_commands']={ensure=function(_,_,cb) cb(true) end}
      local applied=0
      local old_handler=function(_,params) applied=applied+1; vim.lsp.util.apply_workspace_edit(params.edit,'utf-16'); return {applied=true} end
      client.handlers['workspace/applyEdit']=old_handler
      local command={title='Extract real expression',command='clangd.applyTweak',arguments={{file=a.uri,tweakID='ExtractVariable'}}}
      local menu,response,expire,preview_count
      preview_count=0
      vim.ui.select=function(items,opts,cb)
        if opts.kind=='codeaction' then menu={items,cb} else preview_count=preview_count+1 end
      end
      local original_defer=vim.defer_fn
      vim.defer_fn=function(fn,delay)
        if delay==15000 then expire=fn; return uv.new_timer() end
        return original_defer(fn,delay)
      end
      function client:request(method,_,cb)
        if method=='textDocument/codeAction' then cb(nil,{command})
        elseif method=='workspace/executeCommand' then response=cb end
        return true,1
      end
      local original_request=client.request
      require('utils.refactor').code_actions(); menu[2](menu[1][1])
      expire()
      local late=client.handlers['workspace/applyEdit'](nil,{edit={changes={[a.uri]={text_edit('LATE')}}}},{client_id=client.id})
      assert(late.applied==false and applied==0 and lines(a)[1]=='Old a;')
      assert(client:request('workspace/executeCommand',{},function() end)==false)
      response({code=-32001,message='edits were not applied: '..late.failureReason})
      response(nil)
      assert(client.request==original_request and client.handlers['workspace/applyEdit']==old_handler)
      assert(not client._ue_refactor_command and preview_count==0 and applied==0)
      vim.defer_fn=original_defer
    ]])
  end)

  local platform = require("utils.platform")
  local clangd = platform.resolve_tool({
    name = "clangd",
    env = { "UE_CLANGD" },
    driver_candidates = function(driver)
      return driver.default_clangd_candidates()
    end,
  })
  if not clangd.ok then
    t.skip("native clangd rename and applyTweak preview", "clangd executable unavailable", { native = true })
  else
    t.it("real clangd returns cross-file rename and extract edits; preview/apply/undo retain disk", function()
      child(
        ([[
        local messages={}
        vim.notify=function(message) messages[#messages+1]=message end
        local header=file('Refactor.h','#pragma once\nint SharedValue();\n')
        local source=file('Refactor.cpp','#include "Refactor.h"\nint SharedValue(){ return 3; }\nint Use(){ return SharedValue() + 4; }\n')
        local commands={{directory=dir,file=source.path,arguments={'clang++','-std=c++17','-c',source.path}}}
        file('compile_commands.json',vim.json.encode(commands)..'\n',false)
        vim.bo[source.buf].filetype='cpp'; vim.bo[header.buf].filetype='cpp'
        api.nvim_set_current_buf(source.buf)
        local diagnostics, initialized={}
        local source_ready,header_ready=false,false
        local id=assert(vim.lsp.start({name='clangd',cmd={%q,'--enable-config=false','--background-index=false'},
          root_dir=dir,on_init=function() initialized=true end,
          handlers={['textDocument/publishDiagnostics']=function(_,params)
            diagnostics[params.uri]=params.diagnostics
            if edit.same_document(params.uri,source.path) then source_ready=true end
            if edit.same_document(params.uri,header.path) then header_ready=true end
          end}}))
        local client=assert(vim.lsp.get_client_by_id(id))
        local native_result
        local native_request=client.request
        function client:request(method,params,cb,buf)
          return native_request(self,method,params,function(err,result,...)
            if method=='textDocument/rename' then native_result=result end
            cb(err,result,...)
          end,buf)
        end
        assert(vim.lsp.buf_attach_client(header.buf,id))
        assert(vim.wait(15000,function() return initialized and source_ready and header_ready end,20),'both attached native ASTs must be ready')
        for uri,values in pairs(diagnostics) do
          if edit.same_document(uri,source.path) or edit.same_document(uri,header.path) then
            assert(#values==0,vim.inspect(values))
          end
        end
        local refactor=require('utils.refactor')
        local items,choose
        vim.ui.select=function(list,opts,cb)
          if opts.kind=='codeaction' then
            local selected
            for _,choice in ipairs(list) do
              local command=type(choice.action.command)=='table' and choice.action.command or choice.action
              if command.command=='clangd.applyTweak' and command.arguments[1].tweakID=='ExtractVariable' then selected=choice end
            end
            assert(selected,'real ExtractVariable action absent: '..vim.inspect(list))
            cb(selected)
          else items,choose=list,cb end
        end
        api.nvim_win_set_cursor(0,{2,4})
        refactor.rename('RenamedValue')
        assert(vim.wait(15000,function() return items~=nil end,20),'rename preview unavailable: '..table.concat(messages,'; ')..vim.inspect(native_result))
        local rename_batch
        assert(#items>=4,'expected two compiler-authored targets')
        -- Preview initially leaves both real files and buffers unchanged.
        assert(lines(source)[2]:find('SharedValue',1,true) and lines(header)[2]:find('SharedValue',1,true))
        vim.fn.confirm=function() return 1 end
        choose(items[1])
        assert(vim.wait(5000,function() local b=refactor.last_batch(); return b and b.state=='applied' end,10))
        rename_batch=refactor.last_batch()
        assert(#rename_batch.targets==2)
        assert(lines(source)[2]:find('RenamedValue',1,true) and lines(header)[2]:find('RenamedValue',1,true))
        assert(disk(source):find('SharedValue',1,true) and disk(header):find('SharedValue',1,true))
        refactor.undo()
        assert(vim.wait(5000,function() return rename_batch.state=='undone' end,10))
        assert(lines(source)[2]:find('SharedValue',1,true) and lines(header)[2]:find('SharedValue',1,true))
        assert(not vim.bo[source.buf].modified and not vim.bo[header.buf].modified)
        items,choose=nil,nil
        -- Allow didChange/undo delivery to reach clangd before requesting actions.
        vim.wait(150)
        api.nvim_win_set_cursor(0,{3,18})
        local previous_handler=client.handlers['workspace/applyEdit']
        refactor.code_actions({range={start={3,18},['end']={3,33}}})
        assert(vim.wait(15000,function() return items~=nil end,20),'applyTweak preview unavailable: '..table.concat(messages,'; '))
        assert(client.handlers['workspace/applyEdit']==previous_handler and not client._ue_refactor_command)
        assert(lines(source)[3]=='int Use(){ return SharedValue() + 4; }')
        choose(items[1])
        assert(vim.wait(5000,function() return refactor.last_batch()~=rename_batch and refactor.last_batch().state=='applied' end,10))
        local extracted=refactor.last_batch()
        assert(table.concat(lines(source),'\n'):find('auto ',1,true),'real ExtractVariable edit not applied')
        assert(disk(source):find('return SharedValue() + 4;',1,true))
        refactor.undo()
        assert(vim.wait(5000,function() return extracted.state=='undone' end,10))
        assert(lines(source)[3]=='int Use(){ return SharedValue() + 4; }' and not vim.bo[source.buf].modified)
        client:stop(true)
        assert(vim.wait(5000,function() return vim.lsp.get_client_by_id(id)==nil end,10))
      ]]):format(clangd.path),
        60000
      )
    end)
  end
end)
