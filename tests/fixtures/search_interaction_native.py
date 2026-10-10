"""Bounded Snacks input/result/history replay with an isolated native RPC UI."""
import json
import os
from pathlib import Path
import runpy
import subprocess
import sys
import threading
import time


def main():
    root, out, plugins, executable = [Path(value).resolve() for value in sys.argv[1:5]]
    out.mkdir(parents=True, exist_ok=True)
    engine, project = out / 'Engine', out / 'Project Space'
    for rel in ('Engine/Build', 'Engine/Binaries', 'Engine/Source', 'Engine/Config', 'Engine/Plugins', 'Engine/Shaders'):
        (engine / rel).mkdir(parents=True, exist_ok=True)
    files = {
        project / 'Fixture.uproject': '{}\n',
        project / 'Source/Game/Game.Build.cs': '// module\n',
        project / 'Source/Game/Alpha.cpp': 'int Alpha = 1;\n// 中文 Alpha\n// alpha then Alpha\n',
        project / 'Source/Game/Alpha.h': '// Alpha header\n',
        project / 'Source/Game/Space Name.cpp': '// Alpha\n',
        project / 'Config/Default.ini': '; ConfigNeedle\n',
    }
    for path, content in files.items():
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding='utf-8')
    helper = runpy.run_path(str(root / 'tools/measure_inlay_hints.py'))
    environment = os.environ.copy()
    for kind in ('DATA', 'STATE', 'CACHE'):
        environment['XDG_' + kind + '_HOME'] = str(out / kind.lower())
    environment['NVIM_UE_PROBE_PATH'] = str(out / 'probes.json')
    environment['NVIM_UE_LOG_DIR'] = str(out / 'logs')
    environment['NVIM_LOG_FILE'] = str(out / 'nvim.log')
    session = helper['Nvim'](str(executable), environment, out / 'stderr.log')
    watchdog = threading.Timer(70, lambda: session.process.kill() if session.process.poll() is None else None)
    watchdog.daemon = True
    watchdog.start()
    evidence = {}

    def wait_picker():
        deadline = time.monotonic() + 6
        time.sleep(0.08)
        while time.monotonic() < deadline:
            if session.lua('return P and not P.closed and not P.finder:running() and not P.matcher:running()'):
                return
            time.sleep(0.02)
        raise TimeoutError('native picker did not complete')

    def close():
        session.call('nvim_input', '<Esc>')
        time.sleep(0.03)
        session.lua('for _,p in ipairs(Snacks.picker.get()) do p:close() end; if vim.api.nvim_win_is_valid(Origin.win) then vim.api.nvim_set_current_win(Origin.win) end')
        time.sleep(0.05)

    def files_picker(pattern):
        close()
        session.lua('local opts=require("ue").picker_project_options(); opts.pattern=...; P=Snacks.picker.files(opts)', pattern)
        wait_picker()

    def count():
        return session.lua('return #P:items()')

    def grep(query):
        close()
        session.lua('local opts=require("ue").picker_options(); opts.search=...; P=require("utils.search_recipe").open_grep(opts,"workspace")', query)
        wait_picker()

    try:
        session.call('nvim_ui_attach', 120, 36, {'rgb': True, 'ext_linegrid': True})
        tools = session.lua(r'''
          local root,out,plugins,engine,project=...
          vim.opt.rtp:prepend(root); vim.opt.rtp:append(plugins .. '/snacks.nvim'); vim.opt.rtp:append(plugins .. '/trouble.nvim')
          vim.o.swapfile=false; vim.o.shada=''; vim.o.hidden=true
          Clipboard=''
          vim.g.clipboard={name='isolated test clipboard',cache_enabled=0,
            copy={['+']=function(lines) Clipboard=table.concat(lines,'\n') end,['*']=function(lines) Clipboard=table.concat(lines,'\n') end},
            paste={['+']=function() return {vim.split(Clipboard,'\n'),'v'} end,['*']=function() return {vim.split(Clipboard,'\n'),'v'} end}}
          Notifications={}; vim.notify=function(text) Notifications[#Notifications+1]=tostring(text) end
          Spec=dofile(root .. '/lua/plugins/snacks.lua')[1]; Config=Spec.opts(nil,{})
          local snacks=require('snacks'); snacks.setup({picker=Config.picker})
          assert(require('ue.project_state').select(engine,project,project .. '/Fixture.uproject'))
          vim.api.nvim_set_current_dir(engine)
          vim.cmd.edit(vim.fn.fnameescape(project .. '/Source/Game/Alpha.cpp'))
          Origin={win=vim.api.nvim_get_current_win(),buf=vim.api.nvim_get_current_buf()}
          local ctx=assert(require('ue').resolve_context())
          return {index=ctx.paths.csearch_idx,cindex=require('utils.code_search').cindex_uefilter_exe()}
        ''', root.as_posix(), out.as_posix(), plugins.as_posix(), engine.as_posix(), project.as_posix())
        alpha = project / 'Source/Game/Alpha.cpp'
        patterns = [alpha.as_posix(), str(alpha).replace('/', '\\'), 'Source/Game/Alpha.cpp', r'Source\Game\Alpha.cpp',
                    '"' + alpha.as_posix() + '"', 'Space Name.cpp']
        for pattern in patterns:
            files_picker(pattern)
            names = session.lua('local out={};for _,item in ipairs(P:items()) do out[#out+1]=vim.fs.basename(item.file) end;return out')
            if pattern == 'Space Name.cpp':
                assert 'Space Name.cpp' in names, (pattern, names)
            else:
                assert count() == 1, (pattern, names)
        evidence['copied_paths'] = {'inputs': len(patterns), 'matched': len(patterns)}

        for pattern, target, cursor in [
            ('Alpha.cpp:2:11', alpha, [2, 10]),
            ('"' + str(alpha).replace('/', '\\') + '":2:11', alpha, [2, 10]),
            ('"' + (project / 'Source/Game/Space Name.cpp').as_posix() + '":1:4', project / 'Source/Game/Space Name.cpp', [1, 3]),
        ]:
            files_picker(pattern)
            session.call('nvim_input', '<CR>')
            time.sleep(0.16)
            location = session.lua('return {file=vim.api.nvim_buf_get_name(0):gsub("\\\\","/"),cursor=vim.api.nvim_win_get_cursor(0)}')
            assert location['file'].lower() == target.as_posix().lower(), location
            assert location['cursor'] == cursor, (pattern, location)
        evidence['byte_location_roundtrip'] = {'inputs': 3, 'utf8_byte_column0': 10}

        files_picker('Alpha.cpp:2:11')
        session.call('nvim_input', '<C-y>')
        time.sleep(0.08)
        copied = session.lua('return vim.fn.getreg(\'"\')')
        assert copied.endswith(':2:11'), copied
        files_picker(copied)
        session.call('nvim_input', '<CR>')
        time.sleep(0.12)
        assert session.lua('return vim.api.nvim_win_get_cursor(0)') == [2, 10]
        evidence['native_copy_position'] = {'key': 'Ctrl-Y', 'roundtrip_cursor0': [2, 10], 'clipboard': 'isolated provider; physical OS clipboard untested'}

        index = Path(tools['index'])
        index.parent.mkdir(parents=True, exist_ok=True)
        inventory = out / 'indexed.files'
        inventory.write_text('\n'.join(path.as_posix() for path in files if path.suffix in ('.cpp', '.h', '.cs', '.ini')) + '\n', encoding='utf-8')
        index_environment = environment.copy()
        index_environment['CSEARCHINDEX'] = str(index)
        build = subprocess.run([tools['cindex'], '-reset', '-files-from', str(inventory)], env=index_environment,
                               capture_output=True, text=True, timeout=12)
        assert build.returncode == 0, build.stderr
        close()
        session.lua('assert(require("ue").cached_grep({search="Alpha"})); P=Snacks.picker.get({source="ue_grep_csearch"})[1]')
        time.sleep(0.18)
        session.lua('P=assert(Snacks.picker.get({source="ue_grep_csearch"})[1],vim.inspect(Notifications))')
        wait_picker()
        close()
        grep('ConfigNeedle')
        assert count() == 1
        close()
        session.lua('P=require("utils.history_hub").resume_search()')
        wait_picker()
        restored = session.lua('return {source=P.opts.source,search=P.input.filter.search,count=#P:items()}')
        assert restored == {'source': 'grep', 'search': 'ConfigNeedle', 'count': 1}, restored
        evidence['newest_native_search_resume'] = restored

        grep('[')
        invalid = session.lua('return {count=#P:items(),state=P.opts.ue_search_status.state,title=P.title}')
        assert invalid['count'] == 0 and invalid['state'] == 'error', invalid
        grep('NoSuchFixtureNeedle')
        empty = session.lua('return {count=#P:items(),state=P.opts.ue_search_status.state,title=P.title}')
        assert empty['count'] == 0 and empty['state'] == 'empty', empty
        evidence['invalid_distinct_from_empty'] = {'invalid': invalid, 'empty': empty}

        grep('Alpha -- -w -s -g *.cpp')
        before = count()
        session.call('nvim_input', '<CR>')
        time.sleep(0.2)
        stored = session.lua('local out={};for _,entry in ipairs(require("utils.history_hub").load()) do if entry.recipe then out[#out+1]=entry end end; return out')
        assert stored and stored[0]['recipe']['mode'] == {'regex': True, 'case': 'sensitive', 'word': True}, stored
        assert stored[0]['recipe']['filters']['include'] == ['*.cpp'], stored
        close()
        session.lua('P=assert(require("utils.history_hub").rerun(...))', stored[0])
        wait_picker()
        assert count() == before, (before, count())
        evidence['recipe_rg_roundtrip'] = {'before': before, 'after': count(), 'source': 'grep'}

        close()
        session.lua(r'''
          local project=...
          assert(require('ue').cached_grep({search='Alpha',case=true,word=true,scoped=true,
            ue_scope_kind='module',ue_scope_roots={project .. '/Source/Game'},glob={'*.cpp'},pattern='file:Alpha.cpp$'}))
        ''', project.as_posix())
        time.sleep(0.18)
        session.lua('P=assert(Snacks.picker.get({source="ue_grep_csearch"})[1],vim.inspect(Notifications))')
        wait_picker()
        indexed_before = count()
        assert indexed_before == 3, indexed_before
        session.call('nvim_input', '<CR>')
        time.sleep(0.18)
        indexed_entry = session.lua('for _,entry in ipairs(require("utils.history_hub").load()) do if entry.recipe and entry.recipe.source=="ue_grep_csearch" then return entry end end')
        assert indexed_entry['recipe']['mode'] == {'regex': False, 'case': 'sensitive', 'word': True}, indexed_entry
        assert indexed_entry['recipe']['scope']['kind'] == 'module', indexed_entry
        assert indexed_entry['recipe']['filters']['pattern'] == 'file:Alpha.cpp$', indexed_entry
        close()
        session.lua('assert(require("utils.history_hub").rerun(...))', indexed_entry)
        time.sleep(0.18)
        session.lua('P=assert(Snacks.picker.get({source="ue_grep_csearch"})[1])')
        wait_picker()
        assert count() == indexed_before
        session.call('nvim_input', '<C-g>')
        time.sleep(0.12)
        retained = session.lua('return {live=P.opts.live,query=P.input.filter.search,pattern=P.input.filter.pattern}')
        assert retained == {'live': False, 'query': 'Alpha', 'pattern': 'file:Alpha.cpp$'}, retained
        evidence['recipe_csearch_roundtrip_and_refine'] = {'before': indexed_before, 'after': count(), 'retained': retained}

        session.lua('P.opts.ue_scope_kind="file";P.opts.ue_scope_roots={...};P.opts.scoped=false;P.opts.glob={"*.cpp"};P.input:set("",nil);P:find()', alpha.as_posix())
        wait_picker()
        close()
        session.lua('P=assert(require("utils.history_hub").resume_search())')
        wait_picker()
        indexed_resume = session.lua('return {kind=P.opts.ue_scope_kind,roots=P.opts.ue_scope_roots,glob=P.opts.glob,rows=#P:items()}')
        assert indexed_resume['kind'] == 'file' and indexed_resume['roots'] == [alpha.as_posix()], indexed_resume
        assert indexed_resume['glob'] == ['*.cpp'] and indexed_resume['rows'] == 3, indexed_resume
        evidence['csearch_custom_scope_native_resume'] = indexed_resume

        close()
        session.lua('local opts=require("ue").picker_options();opts.glob=require("ue").GLOBS_CODE;opts.search="Alpha -- -g !*.h";P=require("utils.search_recipe").open_grep(opts,"workspace")')
        wait_picker()
        ordered_before = count()
        assert ordered_before == 4, ordered_before
        ordered_recipe = session.lua('return assert(require("utils.search_recipe").from_picker(P))')
        assert len(ordered_recipe['filters']['include']) == 1, ordered_recipe
        assert ordered_recipe['filters']['extra_globs'] == ['!*.h'], ordered_recipe
        close()
        session.lua('P=assert(require("utils.search_recipe").run(...))', ordered_recipe)
        wait_picker()
        assert count() == ordered_before, (ordered_before, count())
        evidence['ordered_glob_code_union_roundtrip'] = {'before': ordered_before, 'after': count(), 'builtin_code_masks_compacted': True}

        session.lua('P.input:set(nil,"Alpha -- -i -w -g *.cpp");P:find()')
        time.sleep(0.24)  # native input's live throttle is 200 ms
        wait_picker()
        updated = session.lua('return assert(require("utils.search_recipe").from_picker(P))')
        assert updated['query'] == 'Alpha' and updated['mode']['case'] == 'ignore' and updated['mode']['word'], updated
        assert updated['filters']['extra_globs'] == ['!*.h', '*.cpp'], updated
        assert 'regex/ignore/word' in session.lua('return P.title')
        updated_before = count()
        assert updated_before > 0, session.lua('return {source=P.opts.source,live=P.opts.live,status=P.opts.ue_search_status,query=P.input.filter.search,pattern=P.input.filter.pattern,finder=#P.finder.items,title=P.title,notifications=Notifications}')
        close()
        session.lua('P=assert(require("utils.search_recipe").run(...))', updated)
        wait_picker()
        assert count() == updated_before, (updated_before, count(), updated)
        evidence['restored_rg_updated_flags'] = {'before': updated_before, 'after': count(), 'mode': updated['mode'], 'query_only': updated['query']}

        session.lua('P.opts.glob={"*.cpp"};P.opts.ue_scope_kind="directory";P.opts.ue_scope_roots={...};P.opts.dirs=P.opts.ue_scope_roots;P:find()', (project / 'Source/Game').as_posix())
        wait_picker()
        scoped_before = count()
        close()
        session.lua('P=assert(require("utils.history_hub").resume_search())')
        wait_picker()
        resumed_scope = session.lua('return {kind=P.opts.ue_scope_kind,roots=P.opts.ue_scope_roots,glob=P.opts.glob,rows=#P:items()}')
        assert resumed_scope['kind'] == 'directory' and resumed_scope['glob'] == ['*.cpp'], resumed_scope
        assert resumed_scope['rows'] == scoped_before, resumed_scope
        evidence['custom_scope_mask_native_resume'] = resumed_scope

        files_picker('Space Name.cpp')
        session.lua('vim.api.nvim_buf_set_lines(Origin.buf,0,1,false,{"// retained unsaved source"})')
        session.call('nvim_input', '<M-v>')
        time.sleep(0.15)
        split = session.lua('local regular=0;for _,win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do if vim.api.nvim_win_get_config(win).relative=="" then regular=regular+1 end end;return {windows=regular,dirty=vim.bo[Origin.buf].modified,line=vim.api.nvim_buf_get_lines(Origin.buf,0,1,false)[1],name=vim.fs.basename(vim.api.nvim_buf_get_name(0))}')
        assert split['windows'] == 2 and split['dirty'] and split['line'] == '// retained unsaved source', split
        assert split['name'] == 'Space Name.cpp', split
        evidence['native_alt_v_split'] = split
        session.lua('vim.api.nvim_win_close(0,true);vim.api.nvim_set_current_win(Origin.win)')

        close()
        session.lua('require("trouble").setup(dofile(... .. "/lua/plugins/sidebar.lua")[1].opts(nil,{}));require("utils.sidebar").open("buffers");vim.api.nvim_set_current_win(Origin.win)', root.as_posix())
        time.sleep(0.15)
        grep('Alpha')
        rows = count()
        session.call('nvim_input', '<C-q>')
        time.sleep(0.18)
        pinned = session.lua('return {sidebar=require("utils.sidebar").is_open("buffers"),source=vim.api.nvim_get_current_win()==Origin.win,rows=#vim.fn.getqflist(),pickers=#Snacks.picker.get()}')
        assert pinned == {'sidebar': True, 'source': True, 'rows': rows, 'pickers': 0}, pinned
        evidence['passive_pin'] = pinned

        evidence['grid'] = {'flushes': session.redraw['flush'], 'line_updates': session.redraw['grid_line']}
        (out / 'evidence.json').write_text(json.dumps(evidence, ensure_ascii=False, indent=2), encoding='utf-8')
        print(json.dumps({'ok': True, 'cases': evidence}, ensure_ascii=False))
    finally:
        watchdog.cancel()
        if session.process.poll() is None:
            session.process.terminate()
        try:
            session.process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            session.process.kill()
            session.process.wait(timeout=3)
        session.log.close()


if __name__ == '__main__':
    main()
