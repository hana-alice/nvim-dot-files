local t = require("tests.harness")
t.bootstrap()

-- The native branch is separate from the pure contracts; no receipt fixture is
-- presented as compiler qualification. Normal native discovery/skip rules apply.
local fixture = [=[
import copy, hashlib, importlib.util, json, os, pathlib, subprocess, sys, tempfile
from unittest.mock import patch

tool, operation, clangd = sys.argv[1:]
sys.path.insert(0, str(pathlib.Path(tool).parent))
import cdb_ordered_batch as ordered
import cdb_verified_batch as verified
import cdb_background_batch as background
sha = lambda raw: hashlib.sha256(raw).hexdigest()
with tempfile.TemporaryDirectory(prefix='ordered_strict_contract_') as temporary:
    root = pathlib.Path(temporary).resolve()
    compiler = str(pathlib.Path(clangd).with_name('clang++'+pathlib.Path(clangd).suffix)) if clangd else 'clang++'
    def write(name, text):
        path = root / name; path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding='utf-8'); return path
    entries = []
    for index, label in enumerate(('A','B')):
        member = write('Source/'+label+'/Member.gen.cpp', label+'_API int value_'+label+'() { return '+str(index)+'; }\n')
        definitions = write('Source/'+label+'/Definitions.'+label+'.h', '#define '+label+'_API\n')
        wrapper = write('Source/'+label+'/SuperUnity.UBT.'+label+'.cpp', '// Compiler-authored UBT unity membership; copied into nvim cache.\n#include "'+member.as_posix()+'"\n')
        entries.append(dict(directory=str(root), file=str(wrapper),
            arguments=[compiler,'-std=c++17','-include',str(definitions),'-c',str(wrapper)],
            nvim_ue_module_root='Source/'+label,nvim_ue_members=[verified.portable_member_path(str(member))]))
    def rejects(call, fragment=None):
        try: call()
        except (ValueError, OSError, EOFError) as error:
            if fragment: assert fragment in str(error), str(error)
        else: raise AssertionError('invalid input accepted')

    if operation == 'validation':
        with patch.object(subprocess,'Popen',side_effect=AssertionError('pure contract started native')):
            selected,members = ordered.validate_group(entries,[0,1],8,80,verified)
            assert selected == [0,1] and sum(map(len,members.values())) == 2
            rejects(lambda: verified._explicit_group_indexes(entries,[0,1],8,80),'context-mismatch')
            for indexes in ([],[0],[1,0],[0,0],[False,1],[0,2]):
                rejects(lambda: ordered.validate_group(entries,indexes,8,80,verified))
            rejects(lambda: ordered.validate_group(entries,[0,1],True,80,verified))
            rejects(lambda: ordered.validate_group(entries,[0,1],8,1,verified),'budget')
            changed=copy.deepcopy(entries); changed[1]['file']=changed[0]['file']
            rejects(lambda: ordered.validate_group(changed,[0,1],8,80,verified),'path-collision')
            first=next(iter(members.values()))[0]
            wrapper=pathlib.Path(entries[1]['file']); wrapper.write_text('// Compiler-authored UBT unity membership; copied into nvim cache.\n#include "'+pathlib.Path(first).as_posix()+'"\n')
            changed=copy.deepcopy(entries);changed[1]['nvim_ue_members']=entries[0]['nvim_ue_members'][:]
            rejects(lambda: ordered.validate_group(changed,[0,1],8,80,verified),'overlap')
    elif operation == 'parser_identity':
        overlay=write('overlay.json','{}'); row=copy.deepcopy(entries[0])
        row['arguments'][1:1]=['-ivfsoverlay',str(overlay)]
        bound={'path':str(overlay),'sha256':sha(overlay.read_bytes())}
        common,search,definitions=ordered.parse_entry(row,bound)
        assert common[1:3]==['-ivfsoverlay',str(overlay)] and len(definitions)==1
        assert row['arguments'][1:3]==['-ivfsoverlay',str(overlay)]
        rejects(lambda: ordered.parse_entry(row,dict(bound,path=str(root/'other.json'))),'binding')
        bad=copy.deepcopy(row);bad['arguments'][1:3]=['-ivfsoverlay='+str(overlay)]
        rejects(lambda: ordered.parse_entry(bad,bound),'shape')
        before=ordered.descriptor(ordered.RECIPE)
        rejects(lambda: ordered.descriptor('unknown'),'unsupported')
        altered=copy.deepcopy(before['code_assets']);altered[0]['sha256']='0'*64
        with patch.object(ordered,'code_assets',return_value=altered):
            rejects(lambda: ordered.descriptor(ordered.RECIPE),'changed-since-import')
        assert ordered.descriptor(ordered.RECIPE)==before
    elif operation == 'graph_codec':
        graph={'file:///a':{'source':{'flags':1,'digest':'1234567890abcdef','direct_includes':[]},'symbols':[{'name':'尾','id':'abc'}],'refs':[],'relations':[]}}
        asset=ordered.save_graph(root/'graphs',graph)
        canonical=verified._json(graph).encode()
        assert asset['logical_sha256']==sha(canonical) and asset['logical_size']==len(canonical)
        assert asset['sha256']==sha(pathlib.Path(asset['path']).read_bytes())
        assert ordered.read_graph(asset)==graph
        stamp=pathlib.Path(asset['path']).stat().st_mtime_ns
        assert ordered.save_graph(root/'graphs',graph)==asset
        assert pathlib.Path(asset['path']).stat().st_mtime_ns==stamp
        rejects(lambda: ordered.save_graph(root/'too-small',graph,logical_limit=2),'logical-byte-limit')
        rejects(lambda: ordered.save_graph(root/'too-small-physical',graph,physical_limit=1),'physical-byte-limit')
        rejects(lambda: ordered.read_graph(dict(asset,logical_sha256='0'*64)),'logical-identity')
        rejects(lambda: ordered.read_graph(asset,logical_limit=2),'record-or-budget')
        path=pathlib.Path(asset['path']);raw=path.read_bytes();path.write_bytes(raw[:-1])
        rejects(lambda: ordered.read_graph(asset),'physical-size')
        truncated=dict(asset,size=len(raw)-1,sha256=sha(raw[:-1]))
        rejects(lambda: ordered.read_graph(truncated))
        assert not list(root.rglob('*.tmp'))
    elif operation == 'tier1_identity':
        # Establish a cache-validation fixture only; no native qualification is claimed.
        rows=copy.deepcopy(entries)
        for row in rows:
            row['nvim_ue_module_root']='Source/Common'
            row['arguments']=[compiler,'-std=c++17','-c',row['file']]
        store=root/'tier1';candidate,body=verified._tier1_candidate_spec(rows,store/'assets')
        verified._write(pathlib.Path(candidate['file']),body)
        inputs=verified._tier1_inputs(rows);environment=verified._compiler_environment(None);tool_hash='a'*64
        key=verified._tier1_cache_key(rows,candidate,tool_hash,None,environment)
        gates=dict(compile_success=True,main_shards_complete=True,members_equal=True)
        receipt=dict(schema=1,tier=1,reusable=True,cache_key=key,accepted=True,reason='fixture-cache-contract',gates=gates,
            inputs=inputs,original_entries=[verified._native(row) for row in rows],candidate=verified._native(candidate),
            members=candidate['nvim_ue_members'],tool_sha256=tool_hash,server_profile=None,compiler_environment=environment,
            candidate_sha256=sha(body.encode()))
        verified._tier1_write_receipt(store,receipt,{})
        before={str(p):(p.read_bytes(),p.stat().st_mtime_ns) for p in store.rglob('*') if p.is_file()}
        with patch.object(subprocess,'Popen',side_effect=AssertionError('cache check started native')):
            first,error=verified._tier1_cached(rows,candidate,body,store,key,inputs,tool_hash,None,environment)
            assert first and first['accepted'] and error is None
            with patch.object(verified,'_IMPORTED_CODE',dict(collector='changed',policy='changed')):
                assert verified._tier1_cache_key(rows,candidate,tool_hash,None,environment)==key
                second,error=verified._tier1_cached(rows,candidate,body,store,key,inputs,tool_hash,None,environment)
                assert second==first and error is None
            bad=copy.deepcopy(inputs);bad[0]['sha256']='0'*64
            assert verified._tier1_cached(rows,candidate,body,store,key,bad,tool_hash,None,environment)[0] is None
        assert {str(p):(p.read_bytes(),p.stat().st_mtime_ns) for p in store.rglob('*') if p.is_file()}==before
        with patch.dict(os.environ,{},clear=False):
            os.environ.pop('NVIM_UE_BATCH_TIER',None)
            assert background._mode()=='1'
    elif operation == 'background_contract':
        source=write('commands.json',json.dumps(entries))
        store=root/'proofs'/'legacy'
        with patch.object(subprocess,'Popen',side_effect=AssertionError('pure contract started native')):
            with patch.dict(os.environ,{'NVIM_UE_BATCH_TIER':'1'}):
                original=background.make_plan(source,store,'')
                assert original['mode']=='1' and original['groups']==[]
                assert background._identity(entries,'1')==sha(background._json({'tier':1,'entries':entries}).encode())
                assert background._identity(entries,'strict')==sha(background._json(entries).encode())
                rejects(lambda: background.make_plan(source,store,'',strict_recipe=ordered.RECIPE,group_indexes=[0,1]),'requires-strict')
                rejects(lambda: background.make_plan(source,store,'',group_indexes=[0,1]),'request-required')
            with patch.dict(os.environ,{'NVIM_UE_BATCH_TIER':'strict'}):
                plan=background.make_plan(source,store,'',strict_recipe=ordered.RECIPE,group_indexes=[0,1])
                assert len(plan['groups'])==1 and plan['strict_recipe']==ordered.RECIPE
                group,selected=background._group(plan,entries,plan['groups'][0]['id'])
                assert selected==entries and group['indexes']==[0,1]
                assert pathlib.Path(group['store']).parent==background._catalog_path(store,'strict',ordered.RECIPE).parent
                assert pathlib.Path(group['store']).parent!=background._catalog_path(store,'strict').parent
                opts=background._strict_recipe_options(group)
                output,metrics=background._cache_only(entries,group['store'],'',None,'strict',**opts)
                assert output==entries and not any(r.get('accepted') for r in metrics['groups'])
                bad=copy.deepcopy(plan);bad['groups'][0]['indexes']=[1,0]
                rejects(lambda: background._group(bad,entries,group['id']),'indexes')
                bad=copy.deepcopy(plan);bad['groups'][0]['strict_limits']['max_sources']=1
                rejects(lambda: background._group(bad,entries,group['id']),'budget')
                bad=copy.deepcopy(plan);bad['groups'][0]['strict_recipe']='unknown'
                rejects(lambda: background._group(bad,entries,group['id']),'unsupported')
                rejects(lambda: background.make_plan(source,store,'',strict_recipe=ordered.RECIPE,
                    group_indexes=[0,1],residual_strict_limit=1),'exclusive')
                empty={'claimed':set(),'records':[]}
                assert not background._ordered_owner_overlap(group,empty,empty)
                assert background._ordered_owner_overlap(group,{'claimed':{0}},empty)
                old={'claimed':{0,1},'records':[{'accepted':True,'original_indexes':[0,1]}]}
                assert background._ordered_owner_overlap(group,empty,old)
                old['records'][0]['strict_recipe']=ordered.RECIPE
                assert not background._ordered_owner_overlap(group,empty,old)
                changed=copy.deepcopy(ordered.descriptor(ordered.RECIPE)['code_assets']);changed[0]['sha256']='f'*64
                with patch.object(ordered,'code_assets',return_value=changed):
                    rejects(lambda: background._group(plan,entries,group['id']),'changed-since-import')
    elif operation == 'native':
        assert clangd, 'native clangd required'
        for entry in entries:
            entry['directory']=str(root/'Source')
        source=write('commands.json',json.dumps(entries))
        marker=write('marker.json','{}'); destination=write('background.json',json.dumps(entries))
        os.environ['NVIM_UE_BATCH_TIER']='strict'
        plan=background.make_plan(source,root/'proofs'/'legacy',clangd,
            strict_recipe=ordered.RECIPE,group_indexes=[0,1])
        plan_path=write('plan.json',json.dumps(plan)); group=plan['groups'][0]
        # The shared producer hook must issue its ordinary strict receipt. A
        # candidate-only return or a fabricated fixture receipt is insufficient.
        output,metrics=verified.accelerate(entries,group['store'],clangd,group_indexes=[0,1],
            strict_recipe=ordered.RECIPE,timeout=30)
        assert metrics['batch_count']==1 and len(output)==1, metrics
        assert 'nvim_ue_module_root' not in output[0]
        receipt=json.loads(pathlib.Path(output[0]['nvim_ue_batch_receipt']).read_bytes())
        assert receipt['schema']==2 and receipt['ordered_recipe']['name']==ordered.RECIPE
        assert receipt['ordered_originals']==[{'file':entry['file'],'module_root':entry['nvim_ue_module_root'],
            'members':entry['nvim_ue_members']} for entry in entries]
        assert receipt['original_entries']==[verified._native(row) for row in entries]
        assert verified.validate_receipts([output[0]['nvim_ue_batch_receipt']],clangd)['ok']
        current={str(p):(p.read_bytes(),p.stat().st_mtime_ns) for p in pathlib.Path(group['store']).rglob('*') if p.is_file()}
        with patch.object(verified,'_index',side_effect=AssertionError('repeat qualification indexed again')):
            repeat,cached=verified.accelerate(entries,group['store'],clangd,group_indexes=[0,1],
                strict_recipe=ordered.RECIPE,verify_missing=False,timeout=30)
        assert repeat==output and cached['cache_hits']==1
        assert {str(p):(p.read_bytes(),p.stat().st_mtime_ns) for p in pathlib.Path(group['store']).rglob('*') if p.is_file()}==current
        with patch.object(verified,'_index',side_effect=AssertionError('collect/reuse started compiler')):
            result=background.collect(plan_path,[group['id']],destination,marker,clangd)
            assert result['ok'] and result['metrics']['batch_count']==1, result
            catalog=background._catalog_path(plan['legacy_store'],'strict',ordered.RECIPE)
            assert json.loads(catalog.read_text())['groups'][0]['strict_recipe']==ordered.RECIPE
            ordinary=json.loads(background._catalog_path(plan['legacy_store'],'strict').read_text())
            assert ordinary['groups']==[]
            with patch.dict(os.environ,{'NVIM_UE_BATCH_TIER':'1'}):
                reused,reused_metrics=background.reuse_completed(entries,plan['legacy_store'],clangd)
            assert reused==output and reused_metrics['batch_count']==1
            stamps={str(p):p.stat().st_mtime_ns for p in (root/'proofs').rglob('*') if p.is_file()}
            again=background.collect(plan_path,[group['id']],destination,marker,clangd)
            assert not again['changed'] and again['revalidated_completed']==[group['id']]
            assert {str(p):p.stat().st_mtime_ns for p in (root/'proofs').rglob('*') if p.is_file()}==stamps
    else:
        raise AssertionError(operation)
    print(json.dumps({'operation':operation,'status':'passed','native':operation=='native'}))
]=]

local function run_fixture(operation, clangd)
  local python = vim.fn.exepath("python")
  if python == "" then python = vim.fn.exepath("python3") end
  if python == "" then
    t.skip("ordered strict Python fixture", "Python unavailable", { native = clangd ~= nil })
    return
  end
  local script = vim.fn.tempname() .. "_ordered_batch.py"
  local stream = assert(io.open(script, "wb"))
  stream:write(fixture)
  stream:close()
  local result = vim.system({ python, "-B", "-I", script,
    vim.fn.stdpath("config") .. "/tools/cdb_ordered_batch.py", operation, clangd or "" }, { text = true }):wait()
  pcall(vim.fn.delete, script)
  t.assert_eq(result.code, 0, (result.stderr or "") .. (result.stdout or ""))
end

t.describe("explicit ordered strict batch", function()
  t.it("validates generated whole owners without relaxing ordinary same-context groups", function()
    run_fixture("validation")
  end)
  t.it("preserves exact owned-overlay operands and recipe-local code identity", function()
    run_fixture("parser_identity")
  end)
  t.it("bounds gzip storage and binds physical bytes and canonical graph identity", function()
    run_fixture("graph_codec")
  end)
  t.it("keeps ordinary Tier1 receipts and default mode independent of strict collector hashes", function()
    run_fixture("tier1_identity")
  end)
  t.it("routes only explicit ordered requests through a separate catalog and rejects owner overlap", function()
    run_fixture("background_contract")
  end)
  local discovered = require("utils.platform").resolve_tool({ name = "clangd", env = { "UE_CLANGD" },
    config_candidates = require("utils.ue_goto.semantic_sidecar_libclang").discover_clangd_candidates() })
  if not discovered.ok then
    t.skip("ordered strict native qualification", discovered.reason, { native = true })
    return
  end
  t.it("issues and reuses a normal strict receipt after independent native graph qualification", function()
    run_fixture("native", discovered.path)
  end)
end)
