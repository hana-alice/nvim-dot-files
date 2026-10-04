local t = require("tests.harness")
local cfg = t.bootstrap()

-- Real RPC UI input through repository plugin opts and the actual mapped
-- entrypoints. The existing helper supplies only MessagePack/grid transport.
local native_driver = [=[
import os
from pathlib import Path
import runpy
import subprocess
import sys
import threading
import time

cfg, data, directory, executable, entry = sys.argv[1:]
directory = Path(directory)
helper = runpy.run_path(str(Path(cfg) / 'tools' / 'measure_inlay_hints.py'))
environment = os.environ.copy()
for key in ('XDG_CONFIG_HOME','XDG_DATA_HOME','XDG_STATE_HOME','XDG_CACHE_HOME'):
    environment[key] = str(directory / key.lower())
environment['NVIM_UE_PROBE_PATH'] = str(directory / 'probes.json')
environment['NVIM_UE_LOG_DIR'] = str(directory / 'logs')
environment['NVIM_LOG_FILE'] = str(directory / 'nvim.log')
instance = helper['Nvim'](executable, environment, directory / 'nvim.stderr.log')
watchdog = threading.Timer(12, instance.process.kill)
watchdog.start()
try:
    instance.call('nvim_ui_attach',120,40,{'rgb':True,'ext_linegrid':True})
    instance.lua("""
      local cfg, data, directory = ...
      vim.opt.rtp:prepend(cfg)
      for _, name in ipairs({'snacks.nvim','LazyVim','lazy.nvim'}) do
        vim.opt.rtp:append(data .. '/lazy/' .. name)
      end
      package.path = cfg .. '/lua/?.lua;' .. cfg .. '/lua/?/init.lua;' .. package.path
      vim.o.hidden, vim.o.more, vim.o.swapfile, vim.o.shada = true, false, false, ''
      vim.g.mapleader, vim.g.maplocalleader = ' ', ' '
      Snacks, LazyVim = require('snacks'), require('lazyvim')
      LazyVim.config = require('lazyvim.config')
      -- Capture diagnostic notices in this isolated config. Otherwise native
      -- vim.notify may demand a second hit-enter prompt after the real confirm.
      notices={}
      vim.notify=function(message) notices[#notices+1]=message end
      local opts={dashboard={enabled=false},picker={enabled=true}}
      opts=require('plugins.snacks')[1].opts(nil,opts) or opts
      Snacks.setup(opts)
      require('lazy.core.handler').init()
      dofile(data .. '/lazy/LazyVim/lua/lazyvim/config/keymaps.lua')
      dofile(cfg .. '/lua/config/keymaps.lua')
      assert(require('workarounds.snacks.safe_buffer_delete').status().applied,
        'real plugin setup must install shared delete protection')
      source = directory .. '/Alpha.cpp'
      vim.fn.writefile({'disk Alpha'},source)
      vim.cmd.edit(vim.fn.fnameescape(source))
      source_buf,source_win=vim.api.nvim_get_current_buf(),vim.api.nvim_get_current_win()
      vim.api.nvim_buf_set_lines(source_buf,0,-1,false,{'old unsaved Alpha'})
      vim.fn.writefile({'other disk file'}, directory .. '/Beta.cpp')
      local other=vim.fn.bufadd(directory .. '/Beta.cpp')
      vim.fn.bufload(other);vim.bo[other].buflisted=true
    """,cfg,data,directory.as_posix())
    if entry.startswith('picker'):
        instance.lua("""picker=Snacks.picker.buffers({pattern='Alpha.cpp'});
          assert(vim.wait(2000,function() return picker.list:count()==1 and picker:current().buf==source_buf end,10))""")
        if entry == 'picker_dd':
            instance.lua('vim.api.nvim_set_current_win(picker.list.win.win);vim.cmd.stopinsert()')
    instance.lua("""vim.defer_fn(function()
      vim.api.nvim_buf_set_lines(source_buf,0,-1,false,{'input added during native confirmation'})
      late_edit=true
    end,150)""")
    key={'bc':' bc','bd':' bd','picker_ctrl_x':'<C-x>','picker_dd':'dd'}[entry]
    assert instance.call('nvim_input',key)>0
    deadline=time.monotonic()+4
    while not instance.lua('return late_edit==true'):
        assert time.monotonic()<deadline,'native confirmation timer failed'
        time.sleep(.01)
    screen='\n'.join(''.join(row) for rows in instance.grids.values() for row in rows)
    assert 'Alpha.cpp' in screen and '放弃' in screen and '取消' in screen,screen
    assert instance.lua('return vim.fn.mode(1)')=='r?','must wait in native confirmation'
    assert instance.call('nvim_input','n')>0
    # Let native input dispatch finish the confirmation before another RPC
    # evaluates the result. A nested vim.wait here would delay queued input.
    deadline=time.monotonic()+4
    while instance.lua("return vim.fn.mode(1)=='r?'"):
        assert time.monotonic()<deadline,'native confirmation did not finish'
        time.sleep(.01)
    instance.lua("""
      assert(vim.api.nvim_buf_is_loaded(source_buf) and vim.bo[source_buf].modified)
      assert(vim.api.nvim_buf_get_lines(source_buf,0,-1,false)[1]=='input added during native confirmation')
      assert(vim.fn.readfile(source)[1]=='disk Alpha')
      assert(vim.api.nvim_win_is_valid(source_win),'close must preserve layout')
    """)
    print('IDE_BUFFER_CLOSE_NATIVE_OK '+entry,flush=True)
finally:
    watchdog.cancel()
    # A failed confirmation must not block cleanup on another input key.
    if instance.process.poll() is None:
        instance.process.terminate()
    try:
        instance.process.wait(timeout=3)
    except subprocess.TimeoutExpired:
        instance.process.kill();instance.process.wait(timeout=3)
    for stream in (instance.process.stdin,instance.process.stdout):
        stream.close()
    instance.log.close()
]=]

local function native(entry)
  local directory = vim.fn.tempname() .. "-buffer-close-native"
  vim.fn.mkdir(directory, "p")
  local script = directory .. "/driver.py"
  vim.fn.writefile(vim.split(native_driver, "\n", { plain = true }), script)
  local result = vim
    .system({
      "python",
      "-I",
      "-B",
      script,
      cfg,
      vim.fn.stdpath("data"),
      directory,
      vim.v.progpath,
      entry,
    }, { text = true, env = { PYTHONIOENCODING = "utf-8" } })
    :wait(20000)
  local details = (result.stdout or "") .. (result.stderr or "")
  vim.fn.delete(directory, "rf")
  t.assert_eq(result.code, 0, details)
  t.assert_contains(result.stdout or "", "IDE_BUFFER_CLOSE_NATIVE_OK", details)
end

local function child(code)
  local script = vim.fn.tempname() .. ".lua"
  vim.fn.writefile(
    vim.split(
      ([=[
vim.opt.rtp:prepend(%q)
package.path = %q .. '/lua/?.lua;' .. package.path
vim.o.hidden, vim.o.swapfile, vim.o.shada = true, false, ''
local close = require('utils.safe_buffer_close')
local notices = {}
vim.notify = function(message) notices[#notices + 1] = message end
local function fixture(name, text, modified)
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(buf, vim.fn.tempname() .. '-' .. name .. '.cpp')
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { text })
  vim.bo[buf].modified = modified == true
  return buf
end
local function kept(buf, text)
  assert(vim.api.nvim_buf_is_loaded(buf), 'source must remain loaded')
  assert(vim.api.nvim_buf_get_lines(buf, 0, -1, false)[1] == text, 'source text changed')
  assert(vim.bo[buf].modified, 'new text must remain dirty')
end
%s
print('IDE_BUFFER_CLOSE_OK')
]=]):format(cfg, cfg, code),
      "\n",
      { plain = true }
    ),
    script
  )
  local result = vim
    .system({ vim.v.progpath, "--headless", "-u", "NONE", "-i", "NONE", "-n", "-l", script }, {
      text = true,
    })
    :wait(10000)
  vim.fn.delete(script)
  t.assert_eq(result.code, 0, (result.stdout or "") .. (result.stderr or ""))
  t.assert_contains((result.stdout or "") .. (result.stderr or ""), "IDE_BUFFER_CLOSE_OK")
end

t.describe("ide_buffer_close: guarded buffer ownership", function()
  t.it("cancel, confirmation errors and failed saves retain dirty text", function()
    child([[
      local buf = fixture('Cancel', 'keep my edit', true)
      for _, answer in ipairs({0, 3}) do
        vim.fn.confirm = function() return answer end
        assert(not close.delete(buf))
        kept(buf, 'keep my edit')
      end
      vim.fn.confirm = function() error('fixture confirmation failure') end
      assert(not close.delete(buf))
      kept(buf, 'keep my edit')
      vim.fn.confirm = function() return 1 end
      vim.bo[buf].readonly = true
      assert(not close.delete(buf))
      kept(buf, 'keep my edit')
      assert(#notices > 0, 'save failure must explain retention')
    ]])
  end)

  t.it("confirmation input, rename and modified-state drift cancel before destruction", function()
    child([[
      local changes = {
        function(buf) vim.api.nvim_buf_set_lines(buf, 0, -1, false, {'late confirmation edit'}) end,
        function(buf) vim.api.nvim_buf_set_name(buf, vim.fn.tempname() .. '-new-name.cpp') end,
        function(buf) vim.bo[buf].modified = false end,
      }
      for _, change in ipairs(changes) do
        local buf = fixture('Drift', 'original edit', true)
        local name = vim.api.nvim_buf_get_name(buf)
        vim.fn.confirm = function() change(buf); return 2 end
        assert(not close.delete(buf))
        assert(vim.api.nvim_buf_is_loaded(buf))
        if vim.api.nvim_buf_get_name(buf) == name and vim.bo[buf].modified then
          kept(buf, 'late confirmation edit')
        end
      end
    ]])
  end)

  t.it("save closes only after successful write with no later input", function()
    child([[
      local buf = fixture('Saved', 'saved content', true)
      local path = vim.api.nvim_buf_get_name(buf)
      vim.fn.confirm = function() return 1 end
      assert(close.delete(buf))
      assert(not vim.api.nvim_buf_is_loaded(buf))
      assert(vim.fn.readfile(path)[1] == 'saved content')
      vim.fn.delete(path)
      local later = fixture('WritePost', 'save this', true)
      local later_path = vim.api.nvim_buf_get_name(later)
      vim.api.nvim_create_autocmd('BufWritePost', {buffer=later, once=true, callback=function()
        vim.api.nvim_buf_set_lines(later, 0, -1, false, {'input after write'})
      end})
      assert(not close.delete(later))
      kept(later, 'input after write')
      assert(vim.fn.readfile(later_path)[1] == 'save this')
      vim.fn.delete(later_path)
    ]])
  end)

  t.it("hidden buffers and every window of one document close without collapsing layout", function()
    child([[
      local hidden = fixture('Hidden', 'hidden old text', true)
      vim.fn.confirm = function() return 2 end
      assert(close.delete(hidden))
      assert(not vim.api.nvim_buf_is_loaded(hidden))
      local buf = fixture('TwoWindows', 'old text', true)
      local replacement = fixture('Replacement', 'replacement', false)
      vim.api.nvim_set_current_buf(buf)
      vim.cmd('vsplit')
      local first = vim.api.nvim_get_current_win()
      vim.cmd('tab split')
      local count = #vim.api.nvim_list_wins()
      assert(close.delete(buf))
      assert(#vim.api.nvim_list_wins() == count, 'delete must preserve windows')
      for _, win in ipairs(vim.api.nvim_list_wins()) do
        assert(vim.api.nvim_win_get_buf(win) ~= buf)
      end
      assert(vim.api.nvim_win_is_valid(first) and vim.api.nvim_buf_is_loaded(replacement))
    ]])
  end)

  t.it("window replacement edits and bufhidden wipe cannot discard new text", function()
    child([[
      for _, event in ipairs({'BufLeave', 'BufWinLeave', 'BufEnter'}) do
        local buf = fixture('Switch', 'approved old edit', true)
        fixture('Alternate', 'other', false)
        vim.api.nvim_set_current_buf(buf)
        vim.bo[buf].bufhidden = 'wipe'
        vim.fn.confirm = function() return 2 end
        local opts = {once=true, callback=function()
          vim.api.nvim_buf_set_lines(buf, 0, -1, false, {'new ' .. event})
        end}
        if event ~= 'BufEnter' then opts.buffer = buf end
        local id = vim.api.nvim_create_autocmd(event, opts)
        assert(not close.delete(buf))
        kept(buf, 'new ' .. event)
        assert(vim.bo[buf].bufhidden == 'wipe', 'temporary ownership option must restore')
        pcall(vim.api.nvim_del_autocmd, id)
        vim.bo[buf].bufhidden = 'hide'
      end
    ]])
  end)

  t.it("native unload/delete/wipe callbacks retain newly appeared text in dirty recovery buffers", function()
    child([[
      for _, event in ipairs({'BufUnload', 'BufDelete', 'BufWipeout'}) do
        local buf = fixture('Boundary', 'approved old edit', true)
        vim.fn.confirm = function() return 2 end
        local before = {}
        for _, b in ipairs(vim.api.nvim_list_bufs()) do before[b] = true end
        vim.api.nvim_create_autocmd(event, {buffer=buf, once=true, callback=function()
          vim.api.nvim_buf_set_lines(buf, 0, -1, false, {'new ' .. event})
        end})
        assert(not close.delete({buf=buf, wipe=event == 'BufWipeout'}))
        local recovered
        for _, b in ipairs(vim.api.nvim_list_bufs()) do
          if not before[b] and vim.b[b].ue_buffer_close_recovery then recovered = b end
        end
        assert(recovered, event .. ': a recovery document must remain loaded')
        kept(recovered, 'new ' .. event)
        assert(vim.api.nvim_buf_get_name(recovered) == '', 'recovery never overwrites a file owner')
      end
    ]])
  end)

  t.it("unload callback can register later delete callback without bypassing capture", function()
    child([[
      local buf = fixture('LateHandler', 'old approved content', true)
      vim.fn.confirm = function() return 2 end
      vim.api.nvim_create_autocmd('BufUnload', {buffer=buf, once=true, callback=function()
        vim.api.nvim_create_autocmd('BufDelete', {buffer=buf, once=true, callback=function()
          vim.api.nvim_buf_set_lines(buf, 0, -1, false, {'new late delete handler'})
        end})
      end})
      assert(not close.delete(buf))
      local recovered
      for _, b in ipairs(vim.api.nvim_list_bufs()) do
        if vim.b[b].ue_buffer_close_recovery then recovered = b end
      end
      assert(recovered)
      kept(recovered, 'new late delete handler')
    ]])
  end)

  t.it("explicit force still guards subsequent input; unchanged discard does not revive old text", function()
    child([[
      local old = fixture('Discard', 'old abandoned text', true)
      vim.fn.confirm = function() error('explicit force must not ask') end
      assert(close.delete({buf=old, force=true}))
      assert(not vim.api.nvim_buf_is_loaded(old))
      for _, b in ipairs(vim.api.nvim_list_bufs()) do
        assert(not vim.b[b].ue_buffer_close_recovery, 'unchanged discard must not be recovered')
      end
      local buf = fixture('ForceBoundary', 'old force content', true)
      vim.api.nvim_create_autocmd('BufDelete', {buffer=buf, once=true, callback=function()
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, {'new despite force'})
      end})
      assert(not close.delete({buf=buf, force=true}))
      local recovered
      for _, b in ipairs(vim.api.nvim_list_bufs()) do
        if vim.b[b].ue_buffer_close_recovery then recovered = b end
      end
      kept(recovered, 'new despite force')
    ]])
  end)

  t.it("one unified Snacks delete owner covers callable, all/other and reversible patching", function()
    child([[
      local original = function() error('unsafe original called') end
      local snacks = setmetatable({delete=original}, {__call=function(self,...) return self.delete(...) end})
      function snacks.all(opts)
        return snacks.delete(vim.tbl_extend('force', {}, opts or {}, {filter=function() return true end}))
      end
      function snacks.other(opts)
        local current = vim.api.nvim_get_current_buf()
        return snacks.delete(vim.tbl_extend('force', {}, opts or {}, {filter=function(b) return b ~= current end}))
      end
      package.loaded['snacks.bufdelete'] = snacks
      local patch = require('workarounds.snacks.safe_buffer_delete')
      patch.apply(); patch.apply()
      assert(snacks.delete == close.delete and patch.status().applied)
      local current = fixture('Current', 'current dirty content', true)
      local other = fixture('Other', 'other old content', true)
      vim.api.nvim_set_current_buf(current)
      vim.fn.confirm = function() return 2 end
      assert(snacks.other())
      kept(current, 'current dirty content')
      assert(not vim.api.nvim_buf_is_loaded(other))
      assert(snacks({buf=current}))
      local extra = fixture('All', 'all old content', true)
      assert(snacks.all())
      assert(not vim.api.nvim_buf_is_loaded(extra))
      patch.disable(); patch.disable()
      assert(snacks.delete == original and not patch.status().applied)
      patch.apply()
      local subsequent_owner = function() return 'other owner' end
      snacks.delete = subsequent_owner
      patch.disable()
      assert(snacks.delete == subsequent_owner, 'disable must not revert another owner')
    ]])
  end)

  t.it("a frozen force batch cannot discard edits added to another batch member", function()
    child([[
      local first = fixture('BatchFirst', 'first old text', true)
      local second = fixture('BatchSecond', 'second old text', false)
      local third = fixture('BatchThird', 'third keeps its view', false)
      vim.api.nvim_create_autocmd('BufDelete', {buffer=first, once=true, callback=function()
        vim.api.nvim_buf_set_lines(second, 0, -1, false, {'new batch input'})
      end})
      vim.fn.confirm = function() error('force batch should not ask') end
      assert(not close.delete({force=true, filter=function(b) return b == first or b == second or b == third end}))
      kept(second, 'new batch input')
      assert(vim.api.nvim_buf_is_loaded(third), 'drift cancels remaining batch members')
    ]])
  end)

  t.it("consecutive boundary input and renamed ownership recover only this source", function()
    child([[
      local buf = fixture('OldOwner', 'old approved text', true)
      local path = vim.api.nvim_buf_get_name(buf)
      local new_owner
      vim.fn.confirm = function() return 2 end
      vim.api.nvim_create_autocmd('BufUnload', {buffer=buf, once=true, callback=function()
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, {'first new input'})
        vim.api.nvim_buf_set_name(buf, vim.fn.tempname() .. '-renamed.cpp')
        new_owner = vim.api.nvim_create_buf(true, false)
        vim.api.nvim_buf_set_name(new_owner, path)
        vim.api.nvim_buf_set_lines(new_owner, 0, -1, false, {'new file owner stays intact'})
      end})
      vim.api.nvim_create_autocmd('BufDelete', {buffer=buf, once=true, callback=function()
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, {'latest new input'})
        vim.bo[buf].modified = false
        assert(not close.delete(buf), 'reentrant close must not start another discard')
      end})
      assert(not close.delete(buf))
      kept(new_owner, 'new file owner stays intact')
      assert(vim.api.nvim_buf_get_name(new_owner) == path)
      local recovered
      for _, b in ipairs(vim.api.nvim_list_bufs()) do
        if vim.b[b].ue_buffer_close_recovery then recovered = b end
      end
      kept(recovered, 'latest new input')
      assert(vim.b[recovered].ue_buffer_close_recovery.source_name == path)
    ]])
  end)

  t.it("a throwing boundary callback leaves its new source input loaded and visible", function()
    child([[
      local buf = fixture('Throwing', 'old approved text', true)
      vim.api.nvim_set_current_buf(buf)
      fixture('AltForThrow', 'alternate', false)
      vim.fn.confirm = function() return 2 end
      vim.api.nvim_create_autocmd('BufUnload', {buffer=buf, once=true, callback=function()
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, {'keep throwing callback input'})
        error('fixture boundary error')
      end})
      assert(not close.delete(buf))
      kept(buf, 'keep throwing callback input')
      assert(vim.api.nvim_get_current_buf() == buf)
      assert(vim.bo[buf].bufhidden == '')
    ]])
  end)

  t.it("closing a live terminal hides its output while its real job remains running", function()
    child([[
      vim.cmd('enew')
      local buf = vim.api.nvim_get_current_buf()
      local job = vim.fn.jobstart({vim.v.progpath, '--headless', '-u', 'NONE', '-i', 'NONE', '-n',
        '-c', 'lua vim.defer_fn(function() vim.cmd("qa!") end, 5000)'}, {term=true})
      assert(job > 0)
      assert(vim.fn.jobwait({job}, 0)[1] == -1)
      assert(close.delete({buf=buf,force=true}))
      assert(vim.api.nvim_buf_is_loaded(buf), 'running output must stay recoverable')
      assert(not vim.bo[buf].buflisted)
      assert(vim.fn.jobwait({job}, 0)[1] == -1, 'close must not stop the real job')
      vim.fn.jobstop(job)
      vim.fn.jobwait({job}, 1000)
    ]])
  end)

  t.it("abort keeps an intentional third-buffer choice made by replacement callbacks", function()
    child([[
      local buf = fixture('LayoutOwner', 'old approved text', true)
      local alt = fixture('LayoutAlternate', 'alternate text', false)
      local chosen = fixture('UserChoice', 'user chosen view', false)
      vim.api.nvim_set_current_buf(buf)
      vim.cmd('vsplit')
      local owned_win = vim.api.nvim_get_current_win()
      -- Pick this listed alternate as the per-window native '#' target.
      vim.api.nvim_set_current_buf(alt)
      vim.api.nvim_set_current_buf(buf)
      vim.api.nvim_create_autocmd('BufEnter', {buffer=alt, once=true, callback=function()
        vim.api.nvim_buf_set_lines(buf,0,-1,false,{'input while switching'})
        vim.api.nvim_win_set_buf(owned_win,chosen)
      end})
      vim.fn.confirm = function() return 2 end
      assert(not close.delete(buf))
      kept(buf, 'input while switching')
      assert(vim.api.nvim_win_get_buf(owned_win) == chosen, 'rollback must not undo a user view choice')
    ]])
  end)

  t.it("canceling one batch prompt stops later deletes and confirms only once", function()
    child([[
      local first = fixture('CancelBatchFirst', 'first dirty text', true)
      local second = fixture('CancelBatchSecond', 'second dirty text', true)
      local prompts = 0
      vim.fn.confirm = function() prompts=prompts+1; return 3 end
      assert(not close.delete(function(b) return b == first or b == second end))
      assert(prompts == 1)
      kept(first, 'first dirty text')
      kept(second, 'second dirty text')
    ]])
  end)

  for _, entry in ipairs({ "bc", "bd", "picker_ctrl_x", "picker_dd" }) do
    local name = "real " .. entry .. " confirmation protects late input through actual plugin setup"
    if vim.fn.executable("python") == 1 and vim.fn.isdirectory(vim.fn.stdpath("data") .. "/lazy/snacks.nvim") == 1 then
      t.it(name, function()
        native(entry)
      end)
    else
      t.skip(name, "native confirmation requires Python and installed Snacks", { native = true })
    end
  end
end)
