"""Bounded real Snacks/csearch UI replay; no user GUI or project cache access."""
import json
import os
from pathlib import Path
import queue
import runpy
import subprocess
import sys
import threading
import time

root, directory, executable, data = map(Path, sys.argv[1:5])
directory.mkdir(parents=True, exist_ok=True)
helper = runpy.run_path(str(root / 'tools' / 'measure_inlay_hints.py'))


class Session(helper['Nvim']):
    def call(self, method, *arguments):
        self.sequence += 1
        identifier = self.sequence
        self.process.stdin.write(helper['pack']([0, identifier, method, arguments]))
        self.process.stdin.flush()
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            message = self.messages.get(timeout=max(0.01, deadline - time.monotonic()))
            self.consume(message)
            if isinstance(message, list) and message[:2] == [1, identifier]:
                if message[2]:
                    raise RuntimeError(message[2])
                return message[3]
        raise TimeoutError(method)


engine, project = directory / 'engine', directory / 'project'
for relative in ('Engine/Binaries', 'Engine/Build', 'Engine/Config',
                 'Engine/Plugins', 'Engine/Shaders', 'Engine/Source'):
    (engine / relative).mkdir(parents=True, exist_ok=True)
source = project / 'Source/Game/Case.cpp'
source.parent.mkdir(parents=True, exist_ok=True)
lines = ['// alpha then Alpha', '// 你好 alpha then Alpha',
         '// AlphaBeta then Alpha', '// pre Axxa tail', '// Alpha Alpha Alpha']
source.write_text('\n'.join(lines) + '\n', encoding='utf-8')
header = source.with_name('Other.h')
header.write_text('// Alpha header\n', encoding='utf-8')
(project / 'Fixture.uproject').write_text('{}\n', encoding='utf-8')
(source.parent / 'Game.Build.cs').write_text('// module\n', encoding='utf-8')
environment = os.environ.copy()
for key in ('XDG_DATA_HOME', 'XDG_STATE_HOME', 'XDG_CACHE_HOME'):
    environment[key] = str(directory / key.lower())
instance = Session(str(executable), environment, directory / 'nvim.stderr.log')
watchdog = threading.Timer(90, lambda: instance.process.kill() if instance.process.poll() is None else None)
watchdog.daemon = True
watchdog.start()
result = {'scope': 'isolated two-file native indexed UI; no physical frontend', 'cases': {}}


def settle():
    time.sleep(0.12)
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        if instance.lua('return _G.P and not _G.P.closed and not _G.P.finder:running() and not _G.P.matcher:running()'):
            return
        time.sleep(0.01)
    raise TimeoutError('native picker completion')


def close():
    instance.call('nvim_input', '<Esc>')
    time.sleep(0.025)
    instance.lua('for _, p in ipairs(Snacks.picker.get()) do p:close() end')
    time.sleep(0.06)
    instance.lua('vim.api.nvim_set_current_win(_G.original_win); vim.api.nvim_set_current_buf(_G.original_buf)')


def indexed(search, wait=True, **options):
    close()
    options['search'] = search
    instance.lua('assert(require("ue").cached_grep(...))', options)
    time.sleep(0.04)
    instance.lua('_G.P=assert(Snacks.picker.get({source="ue_grep_csearch"})[1])')
    if wait:
        settle()


def choose(line):
    return instance.lua(r'''
        local wanted=...
        for index,item in ipairs(_G.P:items()) do
          if item.pos and item.pos[1]==wanted and vim.fs.basename(item.file)=='Case.cpp' then
            _G.P.list:view(index,index)
            _G.P.list:update({force=true})
            _G.P:show_preview()
            local formatted=_G.P.format(item,_G.P)
            local text={}
            for _,chunk in ipairs(formatted) do if type(chunk[1])=='string' then text[#text+1]=chunk[1] end end
            return {position=item.pos,end_position=item.end_pos,location=item.ue_location,display=table.concat(text),text=item.text}
          end
        end
        error('requested native result absent')
    ''', line)


def confirm():
    instance.call('nvim_input', '<CR>')
    time.sleep(0.15)
    return instance.lua('return {file=vim.fs.basename(vim.api.nvim_buf_get_name(0)),cursor=vim.api.nvim_win_get_cursor(0)}')


try:
    instance.call('nvim_ui_attach', 120, 34, {'rgb': True, 'ext_linegrid': True})
    tools = instance.lua(r'''
        local root,directory,data,engine,project,source=...
        vim.opt.rtp:prepend(root)
        vim.opt.rtp:append(data .. '/lazy/snacks.nvim')
        vim.o.swapfile,vim.o.shada,vim.o.hidden=false,'',true
        vim.env.NVIM_UE_PROBE_PATH=directory .. '/ue_probes.json'
        vim.env.NVIM_UE_LOG_DIR=directory .. '/logs'
        vim.notify=function() end
        local spec=dofile(root .. '/lua/plugins/snacks.lua')[1]
        local config=spec.opts(nil,{})
        require('snacks').setup({picker=config.picker})
        assert(require('ue.project_state').select(engine,project,project .. '/Fixture.uproject'))
        vim.api.nvim_set_current_dir(engine)
        vim.cmd.edit(vim.fn.fnameescape(source))
        _G.original_buf,_G.original_win=vim.api.nvim_get_current_buf(),vim.api.nvim_get_current_win()
        local ctx=assert(require('ue').resolve_context())
        local cs=require('utils.code_search')
        return {cindex=assert(cs.cindex_uefilter_exe()),index=ctx.paths.csearch_idx,snacks=Snacks.version}
    ''', root.as_posix(), directory.as_posix(), data.as_posix(), engine.as_posix(), project.as_posix(), source.as_posix())
    index = Path(tools['index'])
    index.parent.mkdir(parents=True, exist_ok=True)
    listing = directory / 'native-input.files'
    listing.write_text(source.as_posix() + '\n' + header.as_posix() + '\n', encoding='utf-8')
    index_environment = environment.copy()
    index_environment['CSEARCHINDEX'] = str(index)
    subprocess.run([tools['cindex'], '-reset', '-files-from', str(listing)],
                   env=index_environment, check=True, timeout=10, capture_output=True)

    indexed('Alpha', case=True)
    item = choose(1)
    landed = confirm()
    assert landed['file'] == 'Case.cpp' and landed['cursor'] == [1, 14], (item, landed)
    assert item['location']['precision'] == 'exact' and item['end_position'] == [1, 19], item
    assert ':15' in item['display'], item
    result['cases']['strict_literal_final_cursor'] = {'item': item, 'landed': landed}

    indexed('Alpha', case=True)
    item = choose(2)
    landed = confirm()
    expected = len('// 你好 alpha then '.encode('utf-8'))
    assert landed['cursor'] == [2, expected], (item, landed, expected)
    result['cases']['utf8_final_byte_cursor'] = {'byte0': expected, 'landed': landed}

    indexed('Alpha', case=True, word=True)
    item = choose(3)
    landed = confirm()
    assert landed['cursor'] == [3, 18], (item, landed)
    result['cases']['whole_word_final_cursor'] = {'landed': landed}

    indexed('A.*a', regex=True, case=True)
    item = choose(4)
    assert item['location']['precision'] == 'line' and item.get('end_position') is None, item
    assert '[行定位]' in item['display'] and '[行定位]' in item['text'], item
    landed = confirm()
    assert landed['cursor'] == [4, 0], (item, landed)
    result['cases']['regex_honest_line_location'] = {'item': item, 'landed': landed}

    indexed('Alpha', max_count=3)
    status = instance.lua('return {metadata=_G.P.opts.ue_search_status,title=_G.P.title,count=#_G.P:items()}')
    assert status['metadata']['state'] == 'truncated' and status['count'] == 3, status
    assert '不完整' in status['title'], status
    result['cases']['truncated_inline'] = status

    # The indexed picker deliberately gates one-character regexes. Use a
    # malformed expression above that threshold; explicit rg also tests '['.
    indexed('Alpha[', regex=True)
    status = instance.lua('return {metadata=_G.P.opts.ue_search_status,title=_G.P.title,count=#_G.P:items()}')
    assert status['metadata']['state'] == 'error' and '无效' in status['title'] and status['count'] == 0, status
    result['cases']['invalid_regex_inline'] = status

    close()
    instance.lua('local opts=require("ue").picker_options();opts.search="[";_G.P=Snacks.picker.grep(opts)')
    settle()
    status = instance.lua('return {metadata=_G.P.opts.ue_search_status,title=_G.P.title,count=#_G.P:items()}')
    assert status['metadata']['state'] == 'error' and '无效' in status['title'] and status['count'] == 0, status
    result['cases']['explicit_rg_invalid_one_character_regex_inline'] = status

    close()
    instance.lua('local opts=require("ue").picker_options();opts.search="A.*a";_G.P=Snacks.picker.grep(opts)')
    settle()
    item = choose(4)
    assert item['position'] == [4, 7] and item['end_position'] == [4, 14], item
    landed = confirm()
    assert landed['cursor'] == [4, 7], (item, landed)
    result['cases']['explicit_rg_regex_proved_native_span'] = {'item': item, 'landed': landed}

    indexed('NO_MATCH_TOKEN_737')
    status = instance.lua('return {metadata=_G.P.opts.ue_search_status,title=_G.P.title,count=#_G.P:items()}')
    assert status['metadata']['state'] == 'empty' and '没有结果' in status['title'], status
    result['cases']['empty_inline'] = status

    indexed('Alpha', ue_scope_kind='project', ue_scope_roots=[project.as_posix()], glob=['Source/**'], ft=['h'])
    status = instance.lua('return {query=_G.P.input.filter.search,metadata=_G.P.opts.ue_search_status,title=_G.P.title,count=#_G.P:items()}')
    assert status['query'] == 'Alpha' and status['count'] == 1 and status['metadata']['visible'] == 1, status
    assert 'Source/**' in status['title'] and 'types:h' in status['title'], status
    result['cases']['relative_path_type_refinement_preserves_query'] = status

    indexed('Alpha', case=True)
    before = instance.lua('return _G.P.input.filter.search')
    instance.call('nvim_input', '<C-g>')
    time.sleep(0.06)
    assert instance.lua('return _G.P.opts.live') is False
    instance.call('nvim_input', 'Alpha')
    settle()
    state = instance.lua('return {query=_G.P.input.filter.search,pattern=_G.P.input.filter.pattern,live=_G.P.opts.live}')
    assert state['query'] == before == 'Alpha' and state['pattern'] == 'Alpha', state
    item = choose(1)
    landed = confirm()
    assert landed['cursor'] == [1, 14], (state, item, landed)
    result['cases']['post_filter_preserves_query_and_strict_position'] = {'state': state, 'landed': landed}

    # Real native lookup results, with producer callback timing explicitly held
    # for 80ms to test that stale UI status cannot supersede the newer intent.
    close()
    instance.lua(r'''
        local cs=require('utils.code_search')
        _G.native_stream=cs.stream
        _G.stream_events={}
        cs.stream=function(ctx,query,options,callbacks)
          local event={query=query,case=options.case,scope=options.path_filter,lines=0,done=0,stopped=false}
          _G.stream_events[#_G.stream_events+1]=event
          local on_line,on_done=callbacks.on_line,callbacks.on_done
          callbacks.on_line=function(...)
            assert(not event.stopped,'native line after stop')
            event.lines=event.lines+1
            on_line(...)
          end
          callbacks.on_done=function(...)
            assert(not event.stopped,'native done after stop')
            event.done=event.done+1
            local arguments={n=select('#',...),...}
            vim.defer_fn(function() on_done(unpack(arguments,1,arguments.n)) end,80)
          end
          local stop=_G.native_stream(ctx,query,options,callbacks)
          return function(reason) event.stopped=true;event.stop_reason=reason;return stop(reason) end
        end
    ''')
    indexed('Alpha', wait=False)
    instance.lua('_G.P:action("ue_grep_toggle_case");_G.P:action("ue_grep_toggle_scope")')
    settle()
    time.sleep(0.15)
    state = instance.lua('return {case=_G.P.opts.case,scoped=_G.P.opts.scoped,query=_G.P.input.filter.search,status=_G.P.opts.ue_search_status,count=#_G.P:items(),events=_G.stream_events}')
    assert state['case'] is True and state['scoped'] is True and state['query'] == 'Alpha', state
    assert state['status']['state'] == 'complete' and state['count'] == 5, state
    assert any(event['stopped'] for event in state['events'][:-1]), state
    result['cases']['same_query_modes_keep_latest_intent'] = state
    instance.lua('require("utils.code_search").stream=_G.native_stream')

    result['snacks'] = tools['snacks']
    result['grid_flushes'] = instance.redraw['flush']
    (directory / 'native-ui.json').write_text(json.dumps(result, indent=2, ensure_ascii=False), encoding='utf-8')
    print('SEARCH_PRECISION_UI_OK ' + json.dumps({'cases': list(result['cases']), 'snacks': tools['snacks'], 'grid_flushes': result['grid_flushes']}, ensure_ascii=False))
finally:
    (directory / 'native-ui.json').write_text(json.dumps(result, indent=2, ensure_ascii=False), encoding='utf-8')
    watchdog.cancel()
    if instance.process.poll() is None:
        instance.process.terminate()
    try:
        instance.process.wait(timeout=3)
    except subprocess.TimeoutExpired:
        instance.process.kill()
        instance.process.wait(timeout=3)
    instance.log.close()
