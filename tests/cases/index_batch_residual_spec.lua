local t = require("tests.harness")
t.bootstrap()

-- These are orchestration contracts. Cache answers are explicit test doubles;
-- no native qualification or semantic receipt authority is claimed here.
local fixture = [=[
import copy, json, os, pathlib, subprocess, sys, tempfile
from unittest.mock import patch
sys.path.insert(0, str(pathlib.Path(sys.argv[1]).parent))
import cdb_background_batch as module
operation = sys.argv[2]
clangd = sys.argv[3] if len(sys.argv)>3 else ''
os.environ['NVIM_UE_BATCH_TIER'] = '1'
if operation in ('compose', 'partial_owner', 'native_mixed', 'native_prefix_mixed'):
    # Keep mixed-class pairs available to the residual strict path under test.
    os.environ['NVIM_UE_TIER1_SPLIT_CLASSES'] = '1'

def reject(call, reason):
    try:
        call()
    except ValueError as error:
        assert reason in str(error), str(error)
    else:
        raise AssertionError('expected '+reason)

with tempfile.TemporaryDirectory(prefix='residual_contract_') as temporary:
    root = pathlib.Path(temporary).resolve()
    source, store, plan_path = root/'original.json', root/'verified', root/'plan.json'
    background, marker = root/'background.json', root/'marker.json'
    entries, members = [], []
    native_operation = operation in ('native_mixed', 'native_prefix_mixed')
    files_root = root/'sources' if native_operation else root
    files_root.mkdir(exist_ok=True)
    # One ordinary owner, then three independent residual contexts of sizes 4/6/4.
    contexts = [('ordinary',['src','src'],[1,1]),
            ('pairA',['src','gen'],[2,2]), ('pairB',['src','gen'],[3,3]),
            ('pairC',['src','gen'],[2,2])]
    if native_operation:
        contexts=[('ordinary',['src','src'],[1,1]),('pairA',['src','gen'],[1,1])]
    for context, classes, counts in contexts:
        for member_class, count in zip(classes,counts):
            index = len(entries)
            paths = [files_root/('m%d_%d'%(index,n)+('.gen.cpp' if member_class=='gen' else '.cpp'))
                for n in range(count)]
            for path in paths: path.write_text('int value_'+path.stem.replace('.','_')+';\n')
            wrapper = files_root/('SuperUnity.UBT.%d.cpp'%index)
            wrapper.write_text('// Compiler-authored UBT unity membership; copied into nvim cache.\n'
                + ''.join('#include "'+path.as_posix()+'"\n' for path in paths))
            entries.append(dict(directory=str(files_root), file=str(wrapper),
                arguments=['clang++','-x','c++',str(wrapper)], nvim_ue_module_root=context,
                nvim_ue_members=[module.verified.portable_member_path(str(path)) for path in paths]))
            members.extend(paths)
    exact = dict(directory=str(root),file=str(root/'exact.cpp'),arguments=['clang++','exact.cpp'])
    shader = dict(directory=str(root),file=str(root/'meta.usf'),arguments=['clang++','meta.usf'],
        nvim_ue_background_route='shader-compatibility')
    entries += [exact,shader]
    source.write_text(json.dumps(entries)); background.write_text(json.dumps(entries)); marker.write_text('{}')
    answers, calls, qualified = {}, [], []

    if native_operation:
        compiler=pathlib.Path(clangd).with_name('clang++.exe' if os.name=='nt' else 'clang++')
        assert compiler.is_file(), 'discovered clangd has no colocated actual clang++'
        shared=files_root/'StrictDependency.h'
        shared.write_text('#pragma once\nenum { ResidualValue = 7 };\n')
        prefix_headers = []
        if operation == 'native_prefix_mixed':
            prefix_headers = [files_root/'FirstForced.h', files_root/'SecondForced.h']
            prefix_headers[0].write_text('#define PREFIX_FIRST 7\n')
            prefix_headers[1].write_text('static_assert(PREFIX_FIRST == 7, "forced order");\n'
                + '#define PREFIX_SECOND 11\n')
        for index,entry in enumerate(entries[:4]):
            entry['arguments']=[str(compiler),'-x','c++','-std=c++17','-nostdinc','-nostdinc++',entry['file']]
            if index < 2 and prefix_headers:
                entry['arguments'][1:1] = [token for header in prefix_headers
                    for token in ('-include', str(header))]
                members[index].write_text('int ordinary_prefix%d() { return PREFIX_FIRST + PREFIX_SECOND; }\n' % index)
            if index>=2:
                members[index].write_text('#include "'+shared.as_posix()+'"\n'
                    +'int residual_value%d() { return ResidualValue; }\n'%index)
        source.write_text(module._json(entries))
        plans,works={},{}
        def actual_work(value, mode):
            target=value['groups'][0]
            path=root/(mode+'-plan.json'); module._write(path,value)
            result_path=root/(mode+'-work.json')
            env=dict(os.environ,NVIM_UE_BATCH_TIER=mode)
            completed=subprocess.run([sys.executable,'-B',sys.argv[1],'--worker',str(path),
                '--group',target['id'],'--clangd',clangd,'--out',str(result_path)],
                env=env,capture_output=True,text=True,timeout=360)
            assert completed.returncode==0, completed.stderr+completed.stdout
            result=json.loads(result_path.read_text())
            assert result['ok'] and result['metrics']['new_batch_count']==1, result
            plans[mode]=(path,target)
            works[mode]=result
            return result
        def failure_details(collected):
            target=plans['strict'][1]
            details=dict(collect=collected,worker=works['strict'],receipts=[])
            for path in sorted((pathlib.Path(target['store'])/'receipts').glob('*.json')):
                record=json.loads(path.read_text())
                receipt=record.get('candidate',{}).get('nvim_ue_batch_receipt')
                details['receipts'].append(dict(cache=str(path),accepted=record.get('accepted'),
                    validation=module.verified.validate_receipts([receipt],clangd) if receipt else None,
                    expected_source_inventory=record.get('inventories',{}).get(str(files_root)),
                    current_source_inventory=module.verified._inventory(files_root,pathlib.Path(target['store']))))
            return json.dumps(details)
        tier1=module.make_plan(source,store,clangd)
        assert [row['indexes'] for row in tier1['groups']]==[[0,1]]
        actual_work(tier1,'1')
        result=module.collect(plans['1'][0],[plans['1'][1]['id']],background,marker,clangd)
        assert result['metrics']['batch_count']==1
        first=json.loads(background.read_text())[0]
        module._tier1_receipt(entries[:2],first)
        if operation == 'native_prefix_mixed':
            flat_first, flat_id = first, plans['1'][1]['id']
            recipe = 'tier1-ordered-absolute-forced-prefix-v1'
            request = dict(entry_hashes=[module._sha(module._json(row).encode()) for row in entries[:2]],
                packing=dict(max_unities=32, budget_factor=32), recipe=recipe)
            prefix_plan = module.make_plan(source,store,clangd,tier1_upgrades=[request])
            assert len(prefix_plan['groups']) == 1 and prefix_plan['groups'][0]['indexes'] == [0,1]
            prefix_id = prefix_plan['groups'][0]['id']
            assert prefix_id != flat_id
            proof = actual_work(prefix_plan,'1')
            assert proof['metrics']['new_proof_count'] == proof['metrics']['new_batch_count'] == 1
            adopted = module.collect(plans['1'][0],[prefix_id],background,marker,clangd)
            assert adopted['metrics']['batch_count'] == 1 and prefix_id in adopted['revalidated_completed']
            first = json.loads(background.read_text())[0]
            module._tier1_receipt(entries[:2],first,recipe=recipe)
            assert first != flat_first and first['nvim_ue_members'] == flat_first['nvim_ue_members']
            assert {flat_id,prefix_id} <= {group['id'] for group in module._catalog(store,'1')}
        os.environ['NVIM_UE_BATCH_TIER']='strict'
        strict=module.make_plan(source,store,clangd,residual_strict_limit=1)
        assert [row['indexes'] for row in strict['groups']]==[[2,3]]
        actual_work(strict,'strict')
        result=module.collect(plans['strict'][0],[plans['strict'][1]['id']],background,marker,clangd)
        assert result['metrics']['batch_count']==2 and plans['strict'][1]['id'] in result['revalidated_completed'], failure_details(result)
        expected=json.loads(background.read_text())
        assert len(expected)==4 and expected[0]==first and expected[2:]==[exact,shader]
        assert expected[1]['nvim_ue_batch_receipt'] and module.verified.validate_receipts(
            [expected[1]['nvim_ue_batch_receipt']],clangd)['ok']
        original_coverage=module.verified._tier1_source_coverage(entries)
        assert module.verified._tier1_source_coverage(expected)==original_coverage
        def artifacts():
            return {str(path):(path.read_bytes(),path.stat().st_mtime_ns) for path in root.rglob('*')
                if path.is_file() and (path in (background,marker) or 'background-proofs' in path.parts
                    or path.is_relative_to(store))}
        before=artifacts()
        with patch.object(module.verified,'_prove',side_effect=AssertionError('repeat qualified')), \
                patch.object(subprocess,'Popen',side_effect=AssertionError('repeat spawned native')):
            for mode in ('1','strict'):
                os.environ['NVIM_UE_BATCH_TIER']=mode
                path,target=plans[mode]
                again=module.collect(path,[target['id']],background,marker,clangd)
                assert not again['changed'] and target['id'] in again['revalidated_completed']
                assert json.loads(background.read_text())==expected
            os.environ['NVIM_UE_BATCH_TIER']='1'
            reused,metrics=module.reuse_completed(entries,store,clangd)
            assert reused==expected and metrics['accepted_ubt_count']==4
            assert artifacts()==before
            if operation == 'native_prefix_mixed':
                header = prefix_headers[0]
                raw, stamp = header.read_bytes(), header.stat()
                changed = raw.replace(b' 7', b' 8', 1)
                assert changed != raw and len(changed) == len(raw)
                header.write_bytes(changed)
                os.utime(header,ns=(stamp.st_atime_ns,stamp.st_mtime_ns))
                assert header.stat().st_mtime_ns == stamp.st_mtime_ns and header.stat().st_size == stamp.st_size
                fallback = [flat_first,expected[1],exact,shader]
                assert module.reuse_completed(entries,store,clangd)[0] == fallback
                assert module.verified.validate_receipts([expected[1]['nvim_ue_batch_receipt']],clangd)['ok']
                assert module.verified._tier1_source_coverage(fallback) == original_coverage
                for mode in ('1','strict'):
                    os.environ['NVIM_UE_BATCH_TIER'] = mode
                    path,target = plans[mode]
                    drift = module.collect(path,[target['id']],background,marker,clangd)
                    assert json.loads(background.read_text()) == fallback
                    assert (target['id'] in drift['revalidated_completed']) is (mode == 'strict')
                header.write_bytes(raw)
                os.utime(header,ns=(stamp.st_atime_ns,stamp.st_mtime_ns))
                os.environ['NVIM_UE_BATCH_TIER'] = '1'
                assert module.reuse_completed(entries,store,clangd)[0] == expected
                restored = module.collect(plans['1'][0],[prefix_id],background,marker,clangd)
                assert prefix_id in restored['revalidated_completed'] and json.loads(background.read_text()) == expected
            shared.write_text(shared.read_text()+'// current dependency changed\n')
            retained,metrics=module.reuse_completed(entries,store,clangd)
            assert retained==[first,*entries[2:]] and metrics['batch_count']==1
            assert module.verified._tier1_source_coverage(retained)==original_coverage
            for mode in ('strict','1'):
                os.environ['NVIM_UE_BATCH_TIER']=mode
                path,target=plans[mode]
                after=module.collect(path,[target['id']],background,marker,clangd)
                assert json.loads(background.read_text())==retained
                if mode=='strict': assert target['id'] not in after['revalidated_completed']
            assert not module.verified.validate_receipts([expected[1]['nvim_ue_batch_receipt']],clangd)['ok']
            assert module.verified._TIER1_OVERLAY_SCOPE_DEPTH==0
        print('REAL native mixed families: '+operation+', independent current receipts, immutable repeats and isolated dependency fallback')
        sys.exit(0)

    def group(indexes, mode='strict'):
        selected = [entries[i] for i in indexes]
        identity = module._identity(selected,mode)
        return dict(id=identity,indexes=indexes,store=str(module._catalog_path(store,mode).parent/identity),
            ubt_count=len(indexes),member_count=sum(len(row['nvim_ue_members']) for row in selected))

    def install(indexes, mode='strict', state='accepted', catalog=True):
        value = group(indexes,mode)
        selected = [entries[i] for i in indexes]
        candidate = dict(selected[0],file=str(root/(mode+'-'+value['id']+'.cpp')),
            nvim_ue_members=[member for row in selected for member in row['nvim_ue_members']])
        candidate['arguments'] = ['clang++',candidate['file']]
        receipt = root/(mode+'-'+value['id']+'.receipt.json')
        if mode == '1':
            raw = module._json(dict(schema=1,tier=1,accepted=True,reusable=True,
                original_entries=[module.verified._native(row) for row in selected],
                candidate=module.verified._native(candidate),members=candidate['nvim_ue_members'],
                gates=dict(compile_success=True,main_shards_complete=True,members_equal=True))).encode()
            receipt.write_bytes(raw)
            candidate.update(nvim_ue_tier1_receipt=str(receipt),nvim_ue_tier1_receipt_sha256=module._sha(raw))
        else:
            # Strict receipt validity belongs to the mocked public cache gate.
            candidate['nvim_ue_batch_receipt'] = str(receipt)
        answers[(mode,value['store'])] = (state,candidate)
        if catalog:
            records = module._catalog(store,mode)
            records = [record for record in records if record['id']!=value['id']]
            records.append(dict(id=value['id'],store=value['store'],
                entry_hashes=[module._sha(module._json(row).encode()) for row in selected]))
            module._write(module._catalog_path(store,mode),dict(schema=1,mode=mode,groups=records))
        return value,candidate

    def cache(rows, target, clangd, profile, mode=None, packing=None):
        mode = mode or module._mode()
        assert (module.verified._TIER1_OVERLAY_SCOPE_DEPTH > 0) == (mode == '1'), (mode, module.verified._TIER1_OVERLAY_SCOPE_DEPTH)
        calls.append((mode,str(target),len(rows)))
        ubt = sum(module.verified._is_ubt(row) for row in rows)
        metrics = dict(original_ubt_count=ubt,exact_count=sum(row==exact for row in rows),
            shader_count=sum(row==shader for row in rows),other_count=0,batch_count=0,groups=[])
        state,candidate = answers.get((mode,str(target)),('miss',None))
        if state == 'owner':
            # Inject a revalidated owner at the cache boundary to test the
            # orchestration exclusion independently of eligibility discovery.
            metrics.update(batch_count=1,groups=[dict(original_indexes=[4,5],accepted=True,cached=True)])
            return [*rows[:4],copy.deepcopy(candidate),*rows[6:]],metrics
        chunks = module._chunks(rows,mode)
        if state == 'accepted':
            assert ubt==len(rows)
            indexes=list(range(len(rows)))
            metrics.update(batch_count=1,groups=[dict(original_indexes=indexes,accepted=True,cached=True)])
            return [copy.deepcopy(candidate)],metrics
        metrics['groups']=[dict(original_indexes=indexes,accepted=False,cached=state=='rejected',
            deferred=state!='rejected',reason='test-rejected' if state=='rejected' else 'verification-not-cached') for indexes in chunks]
        return list(rows),metrics

    def plan(limit=1):
        os.environ['NVIM_UE_BATCH_TIER']='strict'
        return module.make_plan(source,store,sys.executable,residual_strict_limit=limit)

    def save(value): module._write(plan_path,value)
    def inventory():
        return {str(path):(path.read_bytes(),path.stat().st_mtime_ns) for path in root.rglob('*') if path.is_file()}

    with patch.object(module,'_cache_only',side_effect=cache), \
            patch.object(subprocess,'Popen',side_effect=AssertionError('non-native contract spawned')), \
            patch.object(module,'_owned_job',return_value=None):
        if operation == 'compose':
            tier1,first=install([0,1],'1'); strict,second=install([4,5])
            before=inventory()
            output,metrics=module.reuse_completed(entries,store,sys.executable)
            assert output==[first,*entries[2:4],second,*entries[6:]]
            assert metrics['batch_count']==2 and metrics['accepted_ubt_count']==4
            assert metrics['families']['1']['accepted_ubt_count']==2
            assert metrics['families']['strict']['accepted_ubt_count']==2
            assert not any(mode=='strict' and count==len(entries) for mode,_,count in calls)
            assert inventory()==before and os.environ['NVIM_UE_BATCH_TIER']=='1'
            ordinary=module.make_plan(source,store,sys.executable)
            assert ordinary['mode']=='1' and all(set(row['indexes'])<={0,1} for row in ordinary['groups'])
            os.environ['NVIM_UE_BATCH_TIER']='strict'
            strict_output,_=module.reuse_completed(entries,store,sys.executable)
            assert strict_output[:2]==entries[:2] and second in strict_output
        elif operation == 'overlap_stale':
            tier1,first=install([0,1],'1'); overlap,_=install([0,1]); strict,second=install([4,5])
            result,metrics=module.reuse_completed(entries,store,sys.executable)
            assert first in result and second in result
            assert not any(mode=='strict' and path==overlap['store'] for mode,path,_ in calls)
            answers[('strict',strict['store'])]=('miss',None)
            result,metrics=module.reuse_completed(entries,store,sys.executable)
            assert result==[first,*entries[2:]] and metrics['families']['strict']['invalidated_group_count']==1
            os.environ['NVIM_UE_BATCH_TIER']='strict'
            value=module.make_plan(source,store,sys.executable); save(value)
            result=module.collect(plan_path,[],background,marker,sys.executable)
            assert result['observations']['families']['strict']['invalidated_group_count']==1
            assert json.loads(background.read_text())==[first,*entries[2:]]
            os.environ['NVIM_UE_BATCH_TIER']='1'
            # A malformed Tier 1 receipt cannot become mixed publication authority.
            pathlib.Path(first['nvim_ue_tier1_receipt']).write_text('{}')
            result,_=module.reuse_completed(entries,store,sys.executable)
            assert first not in result
        elif operation == 'collect':
            tier1,first=install([0,1],'1'); strict,second=install([4,5])
            for mode,current,other in [('strict',strict,'1'),('1',tier1,'strict')]:
                os.environ['NVIM_UE_BATCH_TIER']=mode
                value=module.make_plan(source,store,sys.executable)
                value['groups']=[current]; save(value)
                other_path=module._catalog_path(store,other)
                before=(other_path.read_bytes(),other_path.stat().st_mtime_ns)
                result=module.collect(plan_path,[current['id']],background,marker,sys.executable)
                assert result['ok'] and current['id'] in result['revalidated_completed']
                assert json.loads(background.read_text())==[first,*entries[2:4],second,*entries[6:]]
                assert (other_path.read_bytes(),other_path.stat().st_mtime_ns)==before
                files=inventory()
                repeat=module.collect(plan_path,[current['id']],background,marker,sys.executable)
                assert not repeat['changed'] and inventory()==files
        elif operation == 'ranking':
            value=plan(2)
            assert value['residual_strict_limit']==2
            assert value['residual_strict_policy']==dict(version=1,ordering='members-desc-index')
            assert [row['indexes'] for row in value['groups']]==[[4,5],[2,3]]
            assert value['residual_discovery']['cache_probe_count']==2
            assert not any(mode=='strict' and count==len(entries) for mode,_,count in calls)
            calls.clear()
            only=plan(1)
            assert [row['indexes'] for row in only['groups']]==[[4,5]]
            assert only['residual_discovery']['cache_probe_count']==1
        elif operation == 'eligibility':
            # A third original in this context prevents selecting a partial context.
            entries[6]['nvim_ue_module_root']=entries[4]['nvim_ue_module_root']
            source.write_text(json.dumps(entries))
            assert [row['indexes'] for row in plan(2)['groups']]==[[2,3]]
            members[2].write_bytes(b'x'*(8*393216+1))
            assert plan(2)['groups']==[]
        elif operation == 'invalid_policy':
            for limit in (False,0,3,1.0,'1'):
                reject(lambda:plan(limit),'invalid-residual-strict-limit')
            os.environ['NVIM_UE_BATCH_TIER']='1'
            reject(lambda:module.make_plan(source,store,sys.executable,residual_strict_limit=1),'residual-strict-requires-strict')
            value=plan(); value['residual_strict_policy']['version']=2; save(value)
            reject(lambda:module._load_plan(plan_path,None),'residual-policy-mismatch')
            for missing in ('residual_strict_policy','residual_strict_limit'):
                value=plan(); value.pop(missing); save(value)
                reject(lambda:module._load_plan(plan_path,None),'residual-policy-mismatch')
            value=plan(); value['groups'][0]['store']=str(root/'foreign'); save(value)
            reject(lambda:module._load_plan(plan_path,None),'group-identity-mismatch')
            value=plan(); value['groups']=[group([0,1])]; save(value)
            reject(lambda:module._load_plan(plan_path,None),'residual-scope-mismatch')
            value=plan(); save(value); source.write_text(source.read_text()+' ')
            reject(lambda:module._load_plan(plan_path,None),'input-changed')
        elif operation == 'owners':
            value=plan(); save(value); target=value['groups'][0]
            _,owner=install([4,5],'1',catalog=False)
            answers[('1',str(store))]=('owner',owner)
            reject(lambda:module.work(plan_path,target['id'],sys.executable),'residual-owner-overlap')
            result=module.collect(plan_path,[target['id']],background,marker,sys.executable)
            assert target['id'] not in result['revalidated_completed']
            assert module._catalog(store,'strict')==[]
        elif operation == 'worker_repeat':
            value=plan(); save(value); target=value['groups'][0]
            def accelerate(rows,target_store,clangd,**kwargs):
                qualified.append((copy.deepcopy(rows),kwargs))
                install(target['indexes'],catalog=False)
                return cache(rows,target_store,clangd,None,'strict')
            with patch.object(module.verified,'accelerate',side_effect=accelerate):
                worked=module.work(plan_path,target['id'],sys.executable)
            assert len(qualified)==1 and qualified[0][0]==entries[4:6]
            assert qualified[0][1]['timeout']==90 and qualified[0][1]['max_sources']==80
            result=module.collect(plan_path,[target['id']],background,marker,sys.executable)
            assert target['id'] in result['revalidated_completed']
            again=module.collect(plan_path,[target['id']],background,marker,sys.executable)
            assert target['id'] in again['revalidated_completed'] and not again['changed']
            assert [row['indexes'] for row in plan()['groups']]==[[2,3]]
        elif operation == 'recovery':
            previous=plan(2); save(previous)
            for row in previous['groups']:
                module._write(plan_path.parent/('result-'+row['id']+'.json'),dict(ok=True,mode='strict',
                    group_id=row['id'],input_sha256=previous['input_sha256'],metrics=dict(new_batch_count=1)))
            current=module.make_plan(source,store,sys.executable,previous_path=plan_path,residual_strict_limit=1)
            assert len(current['groups'])==1 and len(current['recovered_completed'])<=1
            assert all(hint['id']==current['groups'][0]['id'] for hint in current['recovered_completed'])
        elif operation == 'rejection_budget':
            rejected,_=install([4,5],state='rejected',catalog=False)
            assert plan()['groups']==[]
            # A current cache miss after header/qualification invalidation is not sticky.
            answers.pop(('strict',rejected['store']))
            assert [row['indexes'] for row in plan()['groups']]==[[4,5]]
        elif operation == 'cursor_progress':
            failed,_=install([4,5],state='rejected',catalog=False)
            first=plan(); assert not first['groups']; save(first)
            assert first['residual_cursor']==1
            for indexes,cursor in [([2,3],2),([6,7],0)]:
                value=module.make_plan(source,store,sys.executable,previous_path=plan_path,residual_strict_limit=1)
                assert [row['indexes'] for row in value['groups']]==[indexes]
                assert value['residual_cursor']==cursor and value['residual_discovery']['cache_probe_count']==1
                save(value)
            answers.pop(('strict',failed['store']))  # Header repair/current gate miss: retry after the cycle.
            repaired=module.make_plan(source,store,sys.executable,previous_path=plan_path,residual_strict_limit=1)
            assert [row['indexes'] for row in repaired['groups']]==[[4,5]]
        elif operation == 'cursor_wrap':
            value=plan(2); save(value)
            wrapped=module.make_plan(source,store,sys.executable,previous_path=plan_path,residual_strict_limit=2)
            assert [row['indexes'] for row in wrapped['groups']]==[[6,7],[4,5]]
            save(wrapped); assert module._load_plan(plan_path,None)[0]==wrapped
            for invalid in (True,-1,3):
                forged=copy.deepcopy(wrapped); forged['residual_cursor']=invalid; save(forged)
                reject(lambda:module._load_plan(plan_path,None),'residual-cursor-mismatch')
            save(value)
            reset=module.make_plan(source,store,sys.executable,previous_path=plan_path,residual_strict_limit=1)
            assert reset['residual_discovery']['start_cursor']==0
            save(value); source.write_text(source.read_text()+' ')
            reset=module.make_plan(source,store,sys.executable,previous_path=plan_path,residual_strict_limit=2)
            assert reset['residual_discovery']['start_cursor']==0
            save(reset); reset['residual_strict_policy']['version']=2; save(reset)
            reset=module.make_plan(source,store,sys.executable,previous_path=plan_path,residual_strict_limit=2)
            assert reset['residual_discovery']['start_cursor']==0
        elif operation == 'cursor_pending':
            value=plan(); save(value); target=value['groups'][0]
            install([4,5],catalog=False)
            module._write(plan_path.parent/('result-'+target['id']+'.json'),dict(ok=True,mode='strict',
                group_id=target['id'],input_sha256=value['input_sha256'],metrics=dict(new_batch_count=1)))
            pending=module.make_plan(source,store,sys.executable,previous_path=plan_path,residual_strict_limit=1)
            assert pending['groups']==value['groups'] and len(pending['recovered_completed'])==1
            assert pending['residual_discovery']['cache_probe_count']==1
            save(pending); answers.pop(('strict',target['store']))
            stale=module.make_plan(source,store,sys.executable,previous_path=plan_path,residual_strict_limit=1)
            assert not stale['groups'] and not stale['recovered_completed']; save(stale)
            forward=module.make_plan(source,store,sys.executable,previous_path=plan_path,residual_strict_limit=1)
            assert [row['indexes'] for row in forward['groups']]==[[2,3]]
            assert forward['residual_discovery']['cache_probe_count']==1
        elif operation == 'scope_failure':
            strict,_=install([4,5])
            def fail(rows,target,clangd,profile,mode=None,packing=None):
                if mode=='1':
                    assert module.verified._TIER1_OVERLAY_SCOPE_DEPTH > 0
                    raise RuntimeError('test gate failure')
                return cache(rows,target,clangd,profile,mode,packing)
            with patch.object(module,'_cache_only',side_effect=fail):
                try: module.reuse_completed(entries,store,sys.executable)
                except RuntimeError as error: assert str(error)=='test gate failure'
                else: raise AssertionError('gate failure swallowed')
            assert module.verified._TIER1_OVERLAY_SCOPE_DEPTH==0
            result,_=module.reuse_completed(entries,store,sys.executable)
            assert len(result)==len(entries)-1
        elif operation == 'partial_owner':
            # Synthetic admission answers exercise whole-parent exclusion, not
            # the native legality of this deliberately broader context.
            for entry in entries[:6]: entry['nvim_ue_module_root']='shared'
            source.write_text(json.dumps(entries))
            tier1,first=install([0,1],'1')
            parent,second=install([0,1,2,3,4,5])
            result,_=module.reuse_completed(entries,store,sys.executable)
            assert result==[first,*entries[2:]]
            # Partial parent overlap must inspect actual admitted owners first.
            # This cache returns one whole parent owner, so it is excluded intact.
            assert sum(mode=='strict' and target==parent['store'] for mode,target,_ in calls)==1
        else:
            raise AssertionError(operation)
        assert module.verified._TIER1_OVERLAY_SCOPE_DEPTH == 0
        print('PASS non-native orchestration '+operation)
]=]

local split_fixture = [=[
"""Pure orchestration regression: native admission answers are explicit doubles."""
import copy
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from unittest.mock import patch

sys.path.insert(0, str(Path(sys.argv[1]).parent))
import cdb_background_batch as module

operation = sys.argv[2]
os.environ['NVIM_UE_BATCH_TIER'] = 'strict'
with tempfile.TemporaryDirectory(prefix='split_owner_contract_') as temporary:
    root = Path(temporary)
    inputs = root / 'sources'
    inputs.mkdir()
    store = root / 'verified'
    source, plan_path = root / 'source.json', root / 'plan.json'
    output, marker = root / 'background.json', root / 'marker.json'
    entries = []
    count = 8 if operation == 'collect_different_owner' else 4
    for index in range(count):
        member = inputs / ('Member%d.cpp' % index)
        member.write_text('int member%d;\n' % index)
        wrapper = inputs / ('SuperUnity.UBT.Split.%d.cpp' % index)
        wrapper.write_text('// Compiler-authored UBT unity membership; copied into nvim cache.\n'
            + '#include "' + member.as_posix() + '"\n')
        entries.append(dict(directory=str(inputs), file=str(wrapper),
            arguments=['clang++', '-x', 'c++', str(wrapper)], nvim_ue_module_root='Split',
            nvim_ue_members=[module.verified.portable_member_path(str(member))]))
    exact = dict(directory=str(inputs), file=str(inputs / 'Exact.cpp'), arguments=['clang++', 'Exact.cpp'])
    shader = dict(directory=str(inputs), file=str(inputs / 'Meta.usf'), arguments=['clang++', 'Meta.usf'],
        nvim_ue_background_route='shader-compatibility')
    entries += [exact, shader]
    source.write_text(module._json(entries))
    output.write_text(module._json(entries)); marker.write_text('{}')
    header_a = inputs / 'ChildA.h'; header_a.write_text('current')
    calls, answers = [], {}

    def definition(indexes, mode='strict'):
        selected = [entries[index] for index in indexes]
        identity = module._identity(selected, mode)
        return dict(id=identity, indexes=indexes, ubt_count=len(indexes),
            member_count=len(indexes), store=str(module._catalog_path(store, mode).parent / identity))

    def candidate(indexes, target, mode='strict'):
        value = dict(directory=str(inputs), file=str(Path(target) / ('child-' + '-'.join(map(str, indexes)) + '.cpp')),
            arguments=['clang++', 'candidate.cpp'],
            nvim_ue_members=[member for index in indexes for member in entries[index]['nvim_ue_members']])
        receipt = Path(target) / ('receipt-' + '-'.join(map(str, indexes)) + '.json')
        if mode == '1':
            raw = module._json(dict(schema=1, tier=1, accepted=True, reusable=True,
                original_entries=[module.verified._native(entries[index]) for index in indexes],
                candidate=module.verified._native(value), members=value['nvim_ue_members'],
                gates=dict(compile_success=True, main_shards_complete=True, members_equal=True))).encode()
            receipt.write_bytes(raw)
            value.update(nvim_ue_tier1_receipt=str(receipt), nvim_ue_tier1_receipt_sha256=module._sha(raw))
        else:
            value['nvim_ue_batch_receipt'] = str(receipt)
        return value

    def install(indexes, parts, mode='strict', register=True):
        group = definition(indexes, mode)
        Path(group['store']).mkdir(parents=True, exist_ok=True)
        if mode == '1':
            (Path(group['store']) / 'tier1' / 'receipts').mkdir(parents=True)
        owners = [(part, candidate(part, group['store'], mode)) for part in parts]
        answers[(mode, group['store'])] = owners
        if register:
            catalog = module._catalog(store, mode)
            catalog.append(dict(id=group['id'], store=group['store'],
                entry_hashes=[module._sha(module._json(entries[index]).encode()) for index in indexes]))
            module._write(module._catalog_path(store, mode), dict(schema=1, mode=mode, groups=catalog))
        return group, owners

    def gate(rows, target, clangd, mode, **options):
        calls.append((mode, str(target), len(rows)))
        owners = answers.get((mode, str(target)), [])
        replacements, consumed, groups = {}, set(), []
        for indexes, value in owners:
            if operation in ('expire', 'missing', 'oversized') and indexes == [0, 1] and header_a.read_text() != 'current':
                continue
            local = [rows.index(entries[index]) for index in indexes]
            replacements[min(local)] = value
            consumed.update(local[1:])
            groups.append(dict(accepted=True, cached=True, original_indexes=local))
        metrics = dict(original_ubt_count=sum(module.verified._is_ubt(row) for row in rows),
            exact_count=int(exact in rows), shader_count=int(shader in rows), other_count=0,
            batch_count=len(groups), groups=groups)
        return [replacements.get(index, row) for index, row in enumerate(rows) if index not in consumed], metrics

    def strict_gate(rows, target, clangd, **options):
        assert options.get('verify_missing') is False
        assert module.verified._TIER1_OVERLAY_SCOPE_DEPTH == 0
        return gate(rows, target, clangd, 'strict', **options)

    def tier1_gate(rows, target, clangd, **options):
        assert module.verified._TIER1_OVERLAY_SCOPE_DEPTH > 0
        return gate(rows, target, clangd, '1', **options)

    def reuse():
        os.environ['NVIM_UE_BATCH_TIER'] = '1'
        result, metrics = module.reuse_completed(entries, store, sys.executable)
        assert result[-2:] == [exact, shader]
        assert module.verified._tier1_source_coverage(result) == module.verified._tier1_source_coverage(entries)
        return result, metrics

    with patch.object(module.verified, 'accelerate', side_effect=strict_gate), \
            patch.object(module.verified, 'reuse_tier1', side_effect=tier1_gate), \
            patch.object(subprocess, 'Popen', side_effect=AssertionError('pure test spawned')):
        plan = module.make_plan(source, store, sys.executable)
        assert [group['indexes'] for group in plan['groups']] == [list(range(count))]
        if operation == 'collect_different_owner':
            plan['groups'] = [definition(list(range(6)))]
        module._write(plan_path, plan)
        collecting = operation.startswith('collect_')
        parent, owners = install(list(range(6)) if operation == 'collect_different_owner' else [0, 1, 2, 3],
            [[0, 1], [2, 3], [4, 5]] if operation == 'collect_different_owner' else
            [[2, 3]] if operation == 'catalog_receipts' else
            [[0, 1]] if operation in ('partial', 'collect_partial') else [[0, 1], [2, 3]], register=not collecting)
        expected = [owners[0][1], *entries[2:]] if len(owners) == 1 else [owners[0][1], owners[1][1], exact, shader]
        if operation in ('overlap', 'collect_overlap', 'catalog_receipts'):
            tier1_group, tier1 = install([0, 1], [[0, 1]], '1')
            expected = [tier1[0][1], owners[-1][1], exact, shader]
        elif operation in ('claimed', 'collect_claimed'):
            _, existing = install([0, 1], [[0, 1]])
            if not collecting:
                catalog = module._catalog(store, 'strict')
                module._write(module._catalog_path(store, 'strict'), dict(schema=1, mode='strict', groups=catalog[::-1]))
            expected = [existing[0][1], owners[1][1], exact, shader]
        elif operation == 'collect_different_owner':
            old, existing = install([0, 1, 2], [[0, 1, 2]])
            unrelated, extra = install([6, 7], [[6, 7]])
            catalog = sorted(module._catalog(store, 'strict'), key=lambda row: row['id'], reverse=True)
            module._write(module._catalog_path(store, 'strict'), dict(schema=1, mode='strict', groups=catalog))
            prefix = [row['id'] for row in catalog]
            expected = [existing[0][1], entries[3], owners[2][1], extra[0][1], exact, shader]
        elif operation in ('expire', 'missing', 'oversized'):
            before, _ = reuse()
            assert before == expected
            header_a.write_text('changed')
            if operation == 'missing':
                (inputs / 'Member0.cpp').unlink()
            elif operation == 'oversized':
                (inputs / 'Member0.cpp').write_bytes(b'x' * (8 * 393216 + 1))
            expected = [*entries[:2], owners[1][1], exact, shader]
        if collecting:
            os.environ['NVIM_UE_BATCH_TIER'] = 'strict'
            result = module.collect(plan_path, [parent['id']], output, marker, sys.executable)
            actual = json.loads(output.read_text())
            assert actual == expected, (operation, result, actual)
            assert actual[-2:] == [exact, shader]
            assert module.verified._tier1_source_coverage(actual) == module.verified._tier1_source_coverage(entries)
            if operation in ('collect_overlap', 'collect_claimed', 'collect_different_owner'):
                assert parent['id'] not in result['revalidated_completed']
            if operation == 'collect_different_owner':
                assert [row['id'] for row in module._catalog(store, 'strict')] == prefix + [parent['id']]
            if operation == 'collect_partial':
                again, metrics = reuse()
                assert again == expected, (operation, metrics)
            artifacts = {str(path): (path.read_bytes(), path.stat().st_mtime_ns) for path in
                (output, marker, module._catalog_path(store, 'strict'))}
            calls.clear()
            os.environ['NVIM_UE_BATCH_TIER'] = 'strict'
            repeated = module.collect(plan_path, [parent['id']], output, marker, sys.executable)
            assert not repeated['changed'] and json.loads(output.read_text()) == expected
            assert artifacts == {path: (Path(path).read_bytes(), Path(path).stat().st_mtime_ns) for path in artifacts}
            assert sum(mode == 'strict' and target == parent['store'] for mode, target, _ in calls) == 1
        else:
            actual, metrics = reuse()
            assert actual == expected, (operation, metrics, actual)
            assert metrics['families']['strict']['invalidated_group_count'] == 0
            if operation == 'expire':
                header_a.write_text('current')
                restored, _ = reuse()
                assert restored == before, 'same catalog must recover a current child without sticky exclusion'
            if operation == 'catalog_receipts':
                assert not (store / 'tier1' / 'receipts').exists()
                assert [target for mode, target, _ in calls if mode == '1'] == [tier1_group['store']]
                namespace = Path(tier1_group['store']) / 'tier1' / 'receipts'
                namespace.rmdir()
                calls.clear()
                missing, _ = reuse()
                assert missing == [*entries[:2], owners[0][1], exact, shader]
                assert not any(mode == '1' for mode, _, _ in calls)
                namespace.mkdir()
                restored, _ = reuse()
                assert restored == expected, 'recreated catalog namespace must reach the current gate'
        print('PASS explicit cache doubles, actual _cache_only/_replacements: ' + operation)
]=]

local miss_fixture = [=[
"""Actual local namespace/planner contracts; verifier answers remain explicit doubles."""
from pathlib import Path
import subprocess
import sys
import tempfile
from unittest.mock import patch
sys.path.insert(0, str(Path(sys.argv[1]).parent))
import cdb_background_batch as module
operation = sys.argv[2]
with tempfile.TemporaryDirectory(prefix='tier1_namespace_') as temporary:
    root = Path(temporary)
    store = root / 'store'
    namespace = store / 'tier1' / 'receipts'
    entries = []
    for index in range(10):
        member = root / ('Member%d.cpp' % index)
        member.write_text('int value%d;\n' % index)
        wrapper = root / ('SuperUnity.UBT.Namespace.%d.cpp' % index)
        wrapper.write_text('// Compiler-authored UBT unity membership; copied into nvim cache.\n'
            + '#include "' + member.as_posix() + '"\n')
        entries.append(dict(directory=str(root), file=str(wrapper),
            arguments=['clang++', '-x', 'c++', str(wrapper)], nvim_ue_module_root='Namespace',
            nvim_ue_members=[module.verified.portable_member_path(str(member))]))
    entries.extend(dict(file=str(root / name)) for name in ('Exact.cpp', 'Shader.usf', 'keep.txt'))
    delegated = (list(entries), {'existing_verifier': True})
    profile = {'test_profile': True}
    def call(mode='1', packing=None):
        return module._cache_only(entries, store, sys.executable, profile, mode, packing)
    def absent(packing=None):
        before = tier1.call_count
        output, metrics = call(packing=packing)
        assert tier1.call_count==before, 'absent namespace invoked the receipt verifier'
        assert output == entries and output is not entries
        assert all(actual is expected for actual, expected in zip(output, entries))
        assert [metrics[key] for key in ('original_ubt_count','exact_count','shader_count','other_count')] == [10,1,1,1]
        expected = [list(range(10))] if packing else [list(range(8)), [8,9]]
        assert [group['original_indexes'] for group in metrics['groups']] == expected
        assert all(group['deferred'] and not group['accepted'] and not group['cached']
            and group['reason']=='verification-not-cached' and group['run_metrics']==[]
            and group['original_ubt_count']==len(group['original_indexes']) for group in metrics['groups'])
        assert metrics['batch_count']==metrics['cache_hits']==metrics['new_proof_count']==metrics['new_batch_count']==0
        assert metrics['proof_directory'] is None
    with patch.object(module.verified, 'reuse_tier1', return_value=delegated) as tier1, \
            patch.object(module.verified, 'accelerate', return_value=delegated) as strict, \
            patch.object(subprocess, 'Popen', side_effect=AssertionError('namespace test spawned')):
        if operation in ('absent', 'large'):
            packing = {'max_unities':32, 'budget_factor':32} if operation=='large' else None
            absent(packing)
            assert tier1.call_count==0 and not store.exists()
            if packing:
                namespace.mkdir(parents=True)
                assert call(packing=packing) is delegated
                tier1.assert_called_once_with(entries, store, sys.executable, max_group=32,
                    budget_factor=32, server_profile=profile)
        elif operation in ('lifecycle', 'file'):
            if operation=='lifecycle':
                absent(); assert tier1.call_count==0
                namespace.mkdir(parents=True)
            else:
                namespace.parent.mkdir(parents=True); namespace.write_text('not a directory')
            assert call() is delegated
            tier1.assert_called_once_with(entries, store, sys.executable, max_group=8, server_profile=profile)
            if operation=='lifecycle':
                namespace.rmdir(); absent(); assert tier1.call_count==1
                namespace.mkdir(); assert call() is delegated and tier1.call_count==2
        elif operation=='errors':
            # Only the exception classification is injected, not host capability.
            real_stat = Path.stat
            for error in (PermissionError('denied'), NotADirectoryError('parent'), OSError('io')):
                def fail(path, *args, **kwargs):
                    if path == namespace: raise error
                    return real_stat(path, *args, **kwargs)
                with patch.object(Path, 'stat', fail):
                    assert call() is delegated
            assert tier1.call_count==3
        elif operation=='strict':
            output, metrics = call('strict')
            assert output==entries and tier1.call_count==strict.call_count==0
            store.mkdir()
            assert call('strict') is delegated
            strict.assert_called_once_with(entries, store, sys.executable, max_group=8,
                max_sources=80, verify_missing=False, server_profile=profile)
            assert tier1.call_count==0
        else:
            raise AssertionError(operation)
        print('PASS actual local receipt namespace '+operation)
]=]

local function run_fixture(operation, clangd, contents)
  local python = vim.fn.exepath("python")
  if python == "" then python = vim.fn.exepath("python3") end
  if python == "" then t.skip("residual contracts", "Python unavailable", { native = true }); return end
  local script = vim.fn.tempname() .. "_residual.py"
  local stream = assert(io.open(script, "wb")); stream:write(contents or fixture); stream:close()
  local result = vim.system({ python, "-B", "-I", script,
    vim.fn.stdpath("config") .. "/tools/cdb_background_batch.py", operation, clangd or "" }, { text = true }):wait()
  pcall(vim.fn.delete, script)
  t.assert_eq(result.code, 0, (result.stderr or "") .. (result.stdout or ""))
end

t.describe("Bounded residual strict orchestration", function()
  for _, operation in ipairs({ "compose", "overlap_stale", "collect", "ranking", "eligibility",
    "invalid_policy", "owners", "worker_repeat", "recovery", "rejection_budget", "scope_failure", "partial_owner",
    "cursor_progress", "cursor_wrap", "cursor_pending" }) do
    t.it(operation, function() run_fixture(operation) end)
  end
  for _, operation in ipairs({ "partial", "expire", "missing", "oversized", "overlap", "claimed",
    "collect_partial", "collect_overlap", "collect_claimed", "collect_different_owner", "catalog_receipts" }) do
    t.it("split owner " .. operation, function() run_fixture(operation, nil, split_fixture) end)
  end
  for _, operation in ipairs({ "absent", "large", "lifecycle", "file", "errors", "strict" }) do
    t.it("Tier1 receipt namespace " .. operation, function() run_fixture(operation, nil, miss_fixture) end)
  end
  local discovered = require("utils.ue_goto.semantic_sidecar_libclang").discover_toolchain()
  if not discovered.ok then
    t.skip("mixed residual native proof", discovered.reason, { native = true })
    return
  end
  t.it("combines real public Tier1 and strict receipts and restores only a stale strict pair", function()
    run_fixture("native_mixed", discovered.clangd_path)
  end)
  t.it("combines real prefix and strict receipts with independent fallback and immutable repeat reuse", function()
    run_fixture("native_prefix_mixed", discovered.clangd_path)
  end)
end)
