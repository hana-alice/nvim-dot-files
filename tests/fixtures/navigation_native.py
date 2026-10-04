"""Explicit native navigation acceptance; Windows clipboard tested on this host.

Run from the repo root. No user GUI input or full UE prepare/index is performed.
Small fixture compiler answers are real; UE context/readiness/prepare are seams.
180 ms delays control delivery of native replies, not measured UE latency.
"""
import json
import os
from pathlib import Path
import runpy
import shutil
import subprocess
import threading
import time

cfg = Path.cwd()
directory = cfg / '.tmp' / 'ide-product-navigation' / 'implementation'
directory.mkdir(parents=True, exist_ok=True)
helper = runpy.run_path(str(cfg / 'tools' / 'measure_inlay_hints.py'))
environment = os.environ.copy()
for name in ('XDG_CONFIG_HOME', 'XDG_DATA_HOME', 'XDG_STATE_HOME', 'XDG_CACHE_HOME'):
    environment[name] = str(directory / name.lower())
plugin_data = (Path(os.environ['LOCALAPPDATA']) / 'nvim-data').as_posix()
clangd = None
instance = helper['Nvim'](shutil.which('nvim'), environment, directory / 'nvim.stderr.log')
watchdog = threading.Timer(55, instance.process.kill)
watchdog.start()
report = {'fixture_only': True, 'physical_frontend_measured': False, 'experiments': {}}

def lua(code, *args):
    (directory / 'last-call.txt').write_text(code[:200], encoding='utf-8')
    return instance.lua(code, *args)

def screen(name):
    rows = []
    for grid, content in sorted(instance.grids.items()):
        rows.append(f'grid {grid}')
        rows.extend(''.join(row).rstrip() for row in content)
    (directory / (name + '.txt')).write_text('\n'.join(rows), encoding='utf-8')

try:
    instance.call('nvim_ui_attach', 120, 40, {'rgb': True, 'ext_linegrid': True})
    setup = (cfg / 'tests' / 'fixtures' / 'navigation_native.lua').read_text(encoding='utf-8')
    report['setup'] = lua(setup, cfg.as_posix(), directory.as_posix(), plugin_data, clangd)
    clangd = report['setup']['clangd']
    tag_result = subprocess.run([shutil.which('gtags')], cwd=directory / 'fixture', capture_output=True, text=True, timeout=10)
    assert tag_result.returncode == 0, tag_result.stderr
    report['gtags_version'] = subprocess.check_output([shutil.which('global'), '--version'], text=True).splitlines()[0]
    report['clangd_version'] = subprocess.check_output([clangd, '--version'], text=True).splitlines()[0]

    lua("nav.at(3,'selected'); vim.fn.setqflist({},' ',{title='Build owner',items={{filename=nav.source,lnum=4,text='build sentinel'}}}); nav.qf=vim.fn.getqflist({id=0}).id; vim.cmd('UEPeek declaration')")
    report['experiments']['peek_single'] = lua('return nav.wait_picker()')
    assert report['experiments']['peek_single']['auto_confirm'] is False
    assert report['experiments']['peek_single']['source'] and report['experiments']['peek_single']['preview']
    screen('peek-single')
    instance.call('nvim_input', '<Esc>')
    lua("assert(vim.wait(1000,function() return #Snacks.picker.get()==0 end,10)); assert(vim.fn.getqflist({id=0}).id==nav.qf)")

    lua("nav.at(3,'selected'); vim.cmd('UEPeek definition')")
    report['experiments']['compiler_definition_peek'] = lua('return nav.wait_picker()')
    assert report['experiments']['compiler_definition_peek']['source']
    instance.call('nvim_input', '<CR>')
    report['experiments']['peek_enter'] = lua("assert(vim.wait(1000,function() return vim.api.nvim_win_get_cursor(nav.win)[1]==2 end,10)); return {cursor=vim.api.nvim_win_get_cursor(nav.win),returned=require('utils.ue_goto.reading').return_to_origin()}")
    assert report['experiments']['peek_enter']['returned']

    for method, action in [('textDocument/references', "require('utils.ue_goto.reading').references()"),
                           ('textDocument/switchSourceHeader', "require('utils.ue_goto.reading').source_header()")]:
        for switch_tab in (False, True):
            lua("nav.at(3,'selected'); nav.delay[...]=180", method)
            previous = lua('return nav.received[...] or 0', method)
            delivered = lua('return nav.delivered[...] or 0', method)
            lua(action)
            lua("local method,previous=...; assert(vim.wait(1000,function() return (nav.received[method] or 0)>previous end,10))", method, previous)
            other = lua('return nav.other(...)', switch_tab)
            result = lua("local method,previous=...; assert(vim.wait(1000,function() return (nav.delivered[method] or 0)>previous end,10)); return {source=vim.api.nvim_win_get_buf(nav.win)==nav.buf,other=vim.api.nvim_get_current_win()==nav.other_win and vim.api.nvim_get_current_buf()==nav.other_buf,dirty=vim.bo[nav.other_buf].modified,pickers=#Snacks.picker.get(),qf=vim.fn.getqflist({id=0}).id==nav.qf}", method, delivered)
            assert all(result[key] for key in ('source', 'other', 'dirty', 'qf')) and result['pickers'] == 0, result
            report['experiments'][method.rsplit('/', 1)[1] + ('_tab_late' if switch_tab else '_window_late')] = result
            lua('nav.clean_other()')
        lua('nav.delay[...]=0', method)

    lua("nav.at(3,'selected'); require('utils.ue_goto.reading').references()")
    report['experiments']['normal_references'] = lua('return nav.wait_picker()')
    assert report['experiments']['normal_references']['source']
    instance.call('nvim_input', '<C-q>')
    report['experiments']['pin'] = lua("assert(vim.wait(1000,function()return vim.fn.getqflist({nr='$'}).nr>1 end,10)); local saved=vim.fn.getqflist({nr='$',items=1,title=1,context=1}); return {source=vim.api.nvim_win_get_buf(nav.win)==nav.buf,picker=#Snacks.picker.get(),title=vim.fn.getqflist({title=1}).title,saved_title=saved.title,saved_items=#saved.items,saved_source=saved.context.source}")
    assert report['experiments']['pin']['source'] and report['experiments']['pin']['picker'] == 1
    assert report['experiments']['pin']['saved_items'] == 3 and report['experiments']['pin']['saved_source'] == 'LSP'
    instance.call('nvim_input', '<Esc>')

    lua("nav.at(6,'selected'); nav.gtags_delay=180; require('utils.ue_goto.reading').references(); assert(vim.wait(2000,function() return (nav.gtags_received or 0)>0 end,10)); nav.other(true)")
    result = lua("assert(vim.wait(2000,function() return (nav.gtags_delivered or 0)>0 end,10)); return {gtags_started=nav.gtags_started,hits=nav.gtags_hits,pickers=#Snacks.picker.get(),other=vim.api.nvim_get_current_win()==nav.other_win,dirty=vim.bo[nav.other_buf].modified,kill=nav.gtags_kill}")
    assert result['gtags_started'] > 0 and result['hits'] > 0 and result['pickers'] == 0 and result['other'] and result['dirty'], result
    report['experiments']['native_gtags_late_tab'] = result
    lua('nav.clean_other(); nav.gtags_delay=0')
    lua("nav.at(6,'selected'); require('utils.ue_goto.reading').references()")
    report['experiments']['native_gtags_normal'] = lua('return nav.wait_picker()')
    assert 'GTAGS' in report['experiments']['native_gtags_normal']['title']
    instance.call('nvim_input', '<Esc>')

    report['experiments']['native_gtags_owned_cancel'] = lua("nav.at(6,'selected'); local previous=nav.gtags_started; require('utils.ue_goto.reading').references(); assert(vim.wait(2000,function() return nav.gtags_started>previous end,1)); local h=nav.gtags_handle; local was_open=not h:is_closing(); local kills=nav.gtags_kill; require('utils.ue_goto.reading').cancel(); assert(vim.wait(2000,function()return h:is_closing() end,5)); return {was_open=was_open,kill_requests=nav.gtags_kill-kills,closed=h:is_closing(),pickers=#Snacks.picker.get(),native_result=h._state.result and {code=h._state.result.code,signal=h._state.result.signal} or nil}")
    assert report['experiments']['native_gtags_owned_cancel']['was_open'] and report['experiments']['native_gtags_owned_cancel']['kill_requests'] == 1 and report['experiments']['native_gtags_owned_cancel']['closed']

    lua("nav.at(4,'root'); vim.cmd('UERelations outgoing')")
    report['experiments']['relation_root'] = lua('return nav.wait_picker()')
    before = lua("return #nav.trace")
    instance.call('nvim_input', '<Right>')
    lua("local s=require('utils.ue_goto.relations').session(); assert(vim.wait(1000,function() return #s.roots[1].children==1 end,10))")
    instance.call('nvim_input', '<Tab><Right>')
    report['experiments']['relation_three_layers'] = lua("local r=require('utils.ue_goto.relations'); local s=r.session(); assert(vim.wait(1000,function() return #s.roots[1].children[1].children==1 end,10)); return {rows=#r.rows(s),names={s.roots[1].item.name,s.roots[1].children[1].item.name,s.roots[1].children[1].children[1].item.name},source=vim.api.nvim_win_get_buf(nav.win)==nav.buf}")
    assert report['experiments']['relation_three_layers']['names'] == ['root', 'middle', 'selected']
    screen('relation-three-layers')
    instance.call('nvim_input', '<M-u>')
    report['experiments']['relation_parent'] = lua("return {name=Snacks.picker.get()[1]:current().node.item.name}")
    assert report['experiments']['relation_parent']['name'] == 'root'
    instance.call('nvim_input', '<Tab>')
    instance.call('nvim_input', '<Left>')
    lua("local r=require('utils.ue_goto.relations'); assert(vim.wait(1000,function() return #r.rows(r.session())==2 end,10))")
    instance.call('nvim_input', '<Esc>')
    lua("vim.cmd('UERelations resume')")
    report['experiments']['relation_resume'] = lua('return nav.wait_picker()')
    assert report['experiments']['relation_resume']['count'] == 2
    instance.call('nvim_input', '<Esc>')

    lua("nav.at(5,'recursive'); vim.cmd('UERelations outgoing')")
    lua('return nav.wait_picker()')
    instance.call('nvim_input', '<Right>')
    report['experiments']['native_cycle'] = lua("local r=require('utils.ue_goto.relations'); local s=r.session(); assert(vim.wait(1000,function() return #s.roots[1].children==1 end,10)); return {cycle=s.roots[1].children[1].state,rows=#r.rows(s)}")
    assert report['experiments']['native_cycle']['cycle'] == 'cycle'
    instance.call('nvim_input', '<Esc>')

    for kind, line, word, names in [('base', 8, 'Leaf', ['Leaf', 'Derived', 'Base']), ('derived', 9, 'Base', ['Base', 'Derived', 'Leaf'])]:
        lua("local kind,line,word=...; nav.at(line,word); vim.cmd('UERelations '..kind)", kind, line, word)
        lua('return nav.wait_picker()')
        instance.call('nvim_input', '<Right>')
        lua("local r=require('utils.ue_goto.relations'); assert(vim.wait(1000,function()return #r.session().roots[1].children>0 end,10))")
        instance.call('nvim_input', '<Tab><Right>')
        result = lua("local r=require('utils.ue_goto.relations');local s=r.session(); assert(vim.wait(1000,function()return #s.roots[1].children[1].children>0 end,10));return {rows=#r.rows(s),names={s.roots[1].item.name,s.roots[1].children[1].item.name,s.roots[1].children[1].children[1].item.name}}")
        assert result['names'] == names, result
        report['experiments'][kind + '_three_layers'] = result
        instance.call('nvim_input', '<Esc>')

    lua("nav.at(4,'root'); nav.delay['callHierarchy/outgoingCalls']=180; vim.cmd('UERelations outgoing')")
    lua('return nav.wait_picker()')
    instance.call('nvim_input', '<Right>')
    lua("assert(vim.wait(1000,function()return require('utils.ue_goto.relations').session().roots[1].state=='loading' end,5))")
    instance.call('nvim_input', '<Left><Esc>')
    report['experiments']['relations_pending_resume'] = lua("local r=require('utils.ue_goto.relations');local s=r.session();assert(vim.wait(1000,function()return #Snacks.picker.get()==0 end,5));local state=s.roots[1].state;assert(r.resume());return {cancelled=nav.lsp_cancel>0,state=state,rows=#r.rows(s)}")
    assert report['experiments']['relations_pending_resume']['state'] == 'unexpanded'
    instance.call('nvim_input', '<Right>')
    lua("local r=require('utils.ue_goto.relations');assert(vim.wait(1000,function()return #r.session().roots[1].children==1 end,10))")
    instance.call('nvim_input', '<Esc>')

    lua("nav.at(2,'selected');vim.wait(150,function()return false end,10)")
    report['experiments']['owned_context_before_confirm'] = lua("local owned=require('utils.ue_goto.reading_owner');local o=owned.begin();nav.context_owner=o;nav.context_snapshot=require('utils.ue_goto.semantic_client').begin_action(nav.buf,{is_current=function()return owned.current(o,true) end});nav.delay['textDocument/symbolInfo']=180;require('utils.ue_goto.reading').choose_context(o,{{label='Context One',origin_tu=nav.source},{label='Context Two',origin_tu=nav.source}},function(c)nav.context_selected=c;local params=require('utils.ue_goto.semantic_transaction').make_position_params(o,o.buf,nav.client.offset_encoding);params._position_encoding=nil;owned.request(o,nav.client,'textDocument/symbolInfo',params,function(err,response)local item=response and response[1];nav.context_dispatch_valid=not err and item and item.usr and require('utils.ue_goto.semantic_client').snapshot_is_current(nav.context_snapshot);nav.context_dispatch_usr=item and item.usr and vim.fn.sha256(item.usr) end)end);return {current=owned.current(o,true),semantic=require('utils.ue_goto.semantic_client').snapshot_is_current(nav.context_snapshot)}")
    report['experiments']['owned_context_picker'] = lua('return nav.wait_picker()')
    instance.call('nvim_input', '<CR>')
    report['experiments']['owned_context_confirm'] = lua("assert(vim.wait(1000,function()return nav.context_selected~=nil and nav.context_dispatch_valid end,10));vim.wait(250,function()return false end,10);return {label=nav.context_selected.label,current=require('utils.ue_goto.reading_owner').current(nav.context_owner,true),semantic=require('utils.ue_goto.semantic_client').snapshot_is_current(nav.context_snapshot),next_native_callback=nav.context_dispatch_valid==true,next_usr_hash=nav.context_dispatch_usr}")
    assert report['experiments']['owned_context_confirm']['current'] and report['experiments']['owned_context_confirm']['semantic']
    assert report['experiments']['owned_context_confirm']['next_native_callback']
    lua("nav.delay['textDocument/symbolInfo']=0")

    lua("nav.at(3,'selected'); nav.header_buf=vim.fn.bufadd(nav.header);vim.fn.bufload(nav.header_buf);nav.header_lines=vim.api.nvim_buf_get_lines(nav.header_buf,0,-1,false);vim.cmd('UEPeek definition')")
    lua('return nav.wait_picker()')
    lua("vim.api.nvim_buf_set_lines(nav.header_buf,0,0,false,{'// new dependency input'})")
    instance.call('nvim_input', '<CR>')
    report['experiments']['compiler_peek_dependency_stale'] = lua("vim.wait(50,function()return false end,5);return {source=vim.api.nvim_win_get_buf(nav.win)==nav.buf,cursor=vim.api.nvim_win_get_cursor(nav.win),dirty=vim.bo[nav.header_buf].modified,pickers=#Snacks.picker.get()}")
    assert report['experiments']['compiler_peek_dependency_stale']['cursor'] == [3, 22]
    instance.call('nvim_input', '<Esc>')
    lua("vim.api.nvim_buf_set_lines(nav.header_buf,0,-1,false,nav.header_lines);vim.bo[nav.header_buf].modified=false")

    # Native compiler coordinates pass through the guarded copy action and the
    # real file query adapter. Preserve the external clipboard after this run.
    lua("nav.at(3,'selected');nav.old_clipboard=vim.fn.getreg('+');require('utils.ue_goto.reading').references()")
    lua('return nav.wait_picker()')
    copied = lua("local p=Snacks.picker.get()[1];local index;for i,row in ipairs(p:items())do if row.loc.range.start.line==6 then index=i;break end end;assert(index);p.list:move(p.list.reverse and p:count()-index+1 or index,true);assert(p:current().loc.range.start.line==6);nav.expected_unicode={7,assert(nav.lines[7]:find('selected',1,true))-1};return {row=index,expected=nav.expected_unicode}")
    instance.call('nvim_input', '<C-y>')
    report['experiments']['unicode_copy'] = lua("assert(vim.wait(1000,function()return vim.fn.getreg(string.char(34))~='' end,10));nav.copied=vim.fn.getreg(string.char(34));local parsed=require('utils.file_query').parse(nav.copied);return {position=parsed.pos,expected=nav.expected_unicode,clipboard=vim.fn.getreg('+')==nav.copied}")
    assert report['experiments']['unicode_copy']['position'] == copied['expected']
    instance.call('nvim_input', '<Esc>')
    lua("nav.at(3,'selected');nav.file_picker=Snacks.picker.pick(require('utils.file_query').options({title='Native file position roundtrip',items={{file=nav.source,text=nav.source}},format='file',preview='file',auto_confirm=false,layout={preset='telescope'},jump={close=true,reuse_win=false},win={input={keys={['<Esc>']={'cancel',mode={'n','i'}}}}}}))")
    lua('return nav.wait_picker()')
    instance.call('nvim_input', '<C-v>')
    lua("assert(vim.wait(1000,function()return Snacks.picker.get()[1].input:get()==nav.copied end,10))")
    instance.call('nvim_input', '<CR>')
    report['experiments']['unicode_copy_open'] = lua("assert(vim.wait(1000,function()return vim.deep_equal(vim.api.nvim_win_get_cursor(nav.win),nav.expected_unicode) end,10));return {cursor=vim.api.nvim_win_get_cursor(nav.win),source=vim.api.nvim_win_get_buf(nav.win)==nav.buf}")

    # One A11 journey, including the actual latest explicit-rg resume.
    lua("nav.at(3,'selected');require('utils.search_recipe').open_grep({cwd=nav.root,dirs={nav.root},search='',live=true,code_only=false,ignored=true,hidden=true,title='Native journey grep'},'project',nav.context)")
    lua("assert(vim.wait(1000,function()local p=Snacks.picker.get()[1];return p and p:current_win()=='input' end,10))")
    instance.call('nvim_input', 'middle')
    lua('return nav.wait_picker()')
    instance.call('nvim_input', '<Esc><Esc>')
    lua("assert(vim.wait(1000,function()return #Snacks.picker.get()==0 end,10));nav.file_picker=Snacks.picker.pick(require('utils.file_query').options({title='Journey file position',items={{file=nav.source,text=nav.source,pos={7,35}}},format='file',preview='file',auto_confirm=false,layout={preset='telescope'},jump={close=true,reuse_win=false}}))")
    lua('return nav.wait_picker()')
    instance.call('nvim_input', '<C-y>')
    instance.call('nvim_input', '<C-v>')
    lua("assert(vim.wait(1000,function()return Snacks.picker.get()[1].input:get()==vim.fn.getreg('+') end,10))")
    instance.call('nvim_input', '<CR>')
    lua("assert(vim.wait(1000,function()return vim.deep_equal(vim.api.nvim_win_get_cursor(nav.win),{7,35}) end,10));vim.cmd('UEPeek references')")
    lua('return nav.wait_picker()')
    lua("vim.api.nvim_set_current_win(nav.win);nav.other(false);vim.api.nvim_buf_set_lines(nav.other_buf,1,1,false,{'continued unrelated input'});vim.cmd('UEReadCancel');require('utils.history_hub').resume_search()")
    lua('return nav.wait_picker()')
    report['experiments']['a11_complete_journey'] = lua("local p=Snacks.picker.get()[1];local recipe=require('utils.search_recipe').from_picker(p);return {source=recipe.source,query=recipe.query,source_preserved=vim.api.nvim_win_get_buf(nav.win)==nav.buf,cursor=vim.api.nvim_win_get_cursor(nav.win),other_preserved=vim.api.nvim_win_get_buf(nav.other_win)==nav.other_buf,other_dirty=vim.bo[nav.other_buf].modified,other_lines=vim.api.nvim_buf_line_count(nav.other_buf),qf_preserved=vim.fn.getqflist({id=0}).id==nav.qf,command_calls=5,confirm_calls=1,text_input_calls=1,typed_characters=6,copy_calls=1,paste_calls=1}")
    journey = report['experiments']['a11_complete_journey']
    assert journey['source'] == 'grep' and journey['query'] == 'middle' and journey['cursor'] == [7,35]
    assert all(journey[key] for key in ('source_preserved', 'other_preserved', 'other_dirty', 'qf_preserved')) and journey['other_lines'] == 2
    instance.call('nvim_input', '<Esc><Esc>')
    lua("assert(vim.wait(1000,function()return #Snacks.picker.get()==0 end,10));nav.clean_other()")

    lua("nav.at(120);nav.scene={};for i=1,2 do vim.cmd.vsplit();local w=vim.api.nvim_get_current_win();local b=vim.api.nvim_create_buf(true,false);vim.api.nvim_win_set_buf(w,b);vim.api.nvim_buf_set_lines(b,0,-1,false,{'unrelated scene input '..i});nav.scene[#nav.scene+1]={win=w,buf=b} end;vim.cmd.tabnew();local w=vim.api.nvim_get_current_win();local b=vim.api.nvim_get_current_buf();vim.api.nvim_buf_set_lines(b,0,-1,false,{'second tab new input'});nav.scene[#nav.scene+1]={win=w,buf=b};vim.api.nvim_set_current_win(nav.win);vim.wo.foldmethod='manual';vim.cmd('30,55fold');vim.api.nvim_win_set_cursor(nav.win,{120,9});vim.cmd('normal! zt');nav.origin_view=vim.fn.winsaveview();nav.fold_before=vim.fn.foldclosed(30);require('utils.ue_goto.reading').source_header();assert(vim.wait(1000,function()return vim.api.nvim_win_get_buf(nav.win)==nav.header_buf end,10))")
    report['experiments']['investigation_view_folds'] = lua("local returned=require('utils.ue_goto.reading').return_to_origin();local view=vim.fn.winsaveview();local dirty=true;for _,r in ipairs(nav.scene)do dirty=dirty and vim.bo[r.buf].modified end;return {returned=returned,view_same=vim.deep_equal(view,nav.origin_view),fold_before=nav.fold_before,fold_after=vim.fn.foldclosed(30),dirty_preserved=dirty,tabs=#vim.api.nvim_list_tabpages(),splits=#vim.api.nvim_tabpage_list_wins(vim.api.nvim_win_get_tabpage(nav.win))}")
    assert report['experiments']['investigation_view_folds']['returned'] and report['experiments']['investigation_view_folds']['view_same']
    assert report['experiments']['investigation_view_folds']['fold_after'] == report['experiments']['investigation_view_folds']['fold_before']
    lua("require('utils.ue_goto.reading').source_header();assert(vim.wait(1000,function()return vim.api.nvim_win_get_buf(nav.win)==nav.header_buf end,10));vim.api.nvim_buf_set_lines(nav.buf,0,0,false,{'// new investigation input'})")
    report['experiments']['investigation_new_input'] = lua("local returned=require('utils.ue_goto.reading').return_to_origin();return {returned=returned,cursor=vim.api.nvim_win_get_cursor(nav.win),line=vim.api.nvim_buf_get_lines(nav.buf,0,1,false)[1],dirty=vim.bo[nav.buf].modified,topline=vim.fn.winsaveview().topline}")
    assert report['experiments']['investigation_new_input']['returned'] and report['experiments']['investigation_new_input']['cursor'] == [121,9]
    lua("require('utils.ue_goto.reading').source_header();assert(vim.wait(1000,function()return vim.api.nvim_win_get_buf(nav.win)==nav.header_buf end,10));vim.cmd.vsplit();nav.layout_new=vim.api.nvim_get_current_win();local b=vim.api.nvim_create_buf(true,false);vim.api.nvim_win_set_buf(nav.layout_new,b);vim.api.nvim_buf_set_lines(b,0,-1,false,{'deliberate new layout'})")
    report['experiments']['investigation_layout_change'] = lua("local returned=require('utils.ue_goto.reading').return_to_origin();return {refused=not returned,active=vim.api.nvim_get_current_win()==nav.layout_new,dirty=vim.bo[vim.api.nvim_get_current_buf()].modified}")
    assert all(report['experiments']['investigation_layout_change'].values())
    report['trace_methods'] = lua("return vim.tbl_map(function(v)return v.method end,nav.trace)")
    report['native_identity'] = lua('return nav.native_identity')
    lua("require('utils.ue_goto.reading').cancel(); require('utils.ue_goto.semantic_client').stop(); nav.client:stop(true)")
    report['native_ui'] = {'width': 120, 'height': 40, 'redraw': instance.redraw}
    report['passed'] = True
except Exception as error:
    report['failure'] = str(error)
    try:
        report['debug'] = instance.lua("local p=Snacks.picker.get()[1];return {messages=nav.messages,last_close=nav.last_close,context_cancelled=nav.context_owner and nav.context_owner.cancelled,pickers=#Snacks.picker.get(),mode=vim.fn.mode(),win=vim.api.nvim_get_current_win(),picker=p and {source=p.opts.source,current=p:current_win(),input_win=p.input.win.win,list_win=p.list.win.win,input=p.input:get(),search=p.input.filter.search,count=p:count()}}")
    except Exception:
        pass
    raise
finally:
    watchdog.cancel()
    try:
        instance.lua("if nav and nav.old_clipboard then pcall(vim.fn.setreg,'+',nav.old_clipboard) end")
    except Exception:
        pass
    (directory / 'native-reading-report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8')
    print(json.dumps(report, ensure_ascii=False))
    try:
        instance.close()
    except OSError:
        pass
