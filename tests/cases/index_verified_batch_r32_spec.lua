local t = require("tests.harness")
t.bootstrap()

local fixture = [=[
import copy, json, os, pathlib, sys, tempfile
from unittest.mock import patch
sys.path.insert(0, str(pathlib.Path(sys.argv[1]).parent))
import build_hot_super_unity_cdb as h
import cdb_verified_batch as v
op=sys.argv[2]
with tempfile.TemporaryDirectory(prefix='r32-tier-') as tmp:
    root=pathlib.Path(tmp).resolve()
    def write(name,text):
        p=root/name;p.parent.mkdir(parents=True,exist_ok=True);p.write_text(text,encoding='utf-8');return p
    pch=write('SharedPCH.Engine.h','#pragma once\n')
    tool=write('clangd.exe','fixture identity; never executable')
    compiler=write('clang++.exe','fixture identity; never executable')
    def unit(module,n,text='// source\n',exact=False):
        member=write('Source/'+module+'/Private/'+str(n)+'.cpp',text)
        defs=write('Definitions.'+module+'.h','#define UE_IS_ENGINE_MODULE 1\n')
        source=member if exact else write('SuperUnity.UBT.'+module+str(n)+'.cpp',
            '// Compiler-authored UBT unity membership; copied into nvim cache.\n#include "'+member.as_posix()+'"\n')
        return dict(directory=str(root),file=str(source),arguments=[str(compiler),'-std=c++17','-include',str(pch),
            '-include',str(defs),'-c',str(source)],nvim_ue_members=[h.portable_member_path(str(member))],nvim_ue_module_root='Source/'+module)
    def graph():
        loc=dict(uri=(root/'header.h').as_uri(),start=[1,2],end=[1,6])
        symbol=dict(id='a',name='Thing',scope='',signature='Thing<TPayload>',kind=1,definition=loc,canonical_declaration=loc)
        return {loc['uri']:dict(source=dict(digest='1234',flags=0,direct_includes=[]),
            symbols=[symbol],refs=[dict(symbol_id='a',kind=1,location=loc,container='')],relations=[])}
    if op=='closure_budget':
        entries=[unit('A',n) for n in range(9)]+[unit('B',0),unit('C',0)]
        closures={'Source/A':{'a','shared'},'Source/B':{'b','shared'},'Source/C':{'c'}}
        assert h.tier2_unity_chunks(entries,closure_budget=3,byte_budget=1024,module_closures=closures)==[list(range(10))]
        assert h.tier2_unity_chunks(entries,closure_budget=3,byte_budget=1024,module_closures=closures,
            module_compile_results={'Source/A':False})==[[9,10]]
        assert entries[0]['nvim_ue_members']
    elif op=='definition_conflicts':
        texts=['static int Shared = 1;','namespace { int Shared = 2; }',
            'DEFINE_LOG_CATEGORY_STATIC(Shared, Log, All);','struct Shared { int x; };',
            'class Shared { int x; };','static int Shared() { return 0; }']
        for text in texts:
            entries=[unit('A',0,text),unit('B',0,text),unit('C',0,'static int Other;')]
            chunks=h.tier2_unity_chunks(entries)
            assert chunks==[[0,2]],(text,chunks)
            assert not h.cross_module_definition_conflict(entries)['ok']
        entries=[unit('A',0,'// static int Shared;\nconst char *s="struct Shared {};";\nvoid f(){struct Local{};}'),
            unit('B',0,'void g(){struct Local{};}')]
        assert h.cross_module_definition_conflict(entries)['ok']
        # UHT .gen.cpp: elaborated type specifiers in static object/function declarations
        # name an existing class; they are not file-scope definitions of that class.
        gen=chr(10).join(['class UScriptStruct* F::StaticStruct()','{ static class UScriptStruct* Singleton = nullptr; return Singleton; }','struct alignas(8) Local8 : Base {};'.replace('Local8','Uniq'+'X')])
        entries=[unit('A',0,gen),unit('B',0,gen.replace('UniqX','UniqY'))]
        assert h.cross_module_definition_conflict(entries)['ok'],h.cross_module_definition_conflict(entries)
        assert h.tier2_unity_chunks(entries)==[[0,1]]
        # A real class definition head with base/final is still recorded.
        entries=[unit('A',0,'class API_X Same final : public B {};'),unit('B',0,'class API_X Same final : public B {};')]
        assert not h.cross_module_definition_conflict(entries)['ok']
    elif op.startswith('graph_') and op!='graph_dependency_invalidate':
        a=graph();b=copy.deepcopy(a);u=next(iter(a))
        if op=='graph_superset':
            b[u]['symbols'].append(dict(b[u]['symbols'][0],id='extra'))
            b[u]['source']['direct_includes']=['x','x'];a[u]['source']['direct_includes']=['x']
            b[u]['refs'].append(dict(b[u]['refs'][0],symbol_id='extra'))
            moved=dict(uri=u,start=[3,4],end=[3,9])
            a[u]['refs'].append(dict(a[u]['refs'][0],location=moved))
            b[u]['refs'].append(dict(b[u]['refs'][0],location=moved))
            b[u]['symbols'][0]['canonical_declaration']=moved
            # A's symbol can live in a different own shard in B.
            b['relocated']=dict(source=dict(digest='5678',flags=0,direct_includes=[]),symbols=b[u]['symbols'],refs=[],relations=[])
            a['relocated']=dict(source=dict(digest='5678',flags=0,direct_includes=[]),symbols=[],refs=[],relations=[])
            b[u]['symbols']=[]
        elif op=='graph_forward_row':
            # A keeps a forward-declaration row in another shard; merged B keeps the definition row.
            fwd=dict(uri='fwd',start=[7,6],end=[7,11])
            a['fwd']=dict(source=dict(digest='5678',flags=0,direct_includes=[]),
                symbols=[dict(a[u]['symbols'][0],definition=None,canonical_declaration=fwd)],
                refs=[dict(a[u]['refs'][0],kind=9,location=fwd)],relations=[])
            a[u]['refs'][0]['kind']=10;b[u]['refs'][0]['kind']=10
            b['fwd']=dict(a['fwd'],symbols=[])
        elif op=='graph_decl_unknown':
            b[u]['symbols'][0]['canonical_declaration']=dict(uri=u,start=[9,9],end=[9,12])
        elif op=='graph_signature':b[u]['symbols'][0]['signature']='Thing<TPayloadType>'
        elif op=='graph_counter':b[u]['symbols'][0].update(id='counter473',name='DelayedAutoRegisterHelper473')
        elif op=='graph_typedef':b[u]['symbols']=[]
        elif op=='graph_friend':b[u]['refs']=[]
        elif op=='graph_definition':b[u]['symbols'][0]['definition']=None
        elif op=='graph_relation':a[u]['relations']=[dict(subject='a',predicate=1,object='b')]
        elif op=='graph_large':
            class Counted(list):
                iterations=0
                def __iter__(self):
                    self.iterations+=1
                    return super().__iter__()
            a[u]['refs']=[dict(a[u]['refs'][0],location=dict(uri=u,start=[i,0],end=[i,1])) for i in range(1000)]
            b[u]['refs']=Counted(copy.deepcopy(a[u]['refs']))
        elif op=='graph_target':b[u]['refs'][0]['symbol_id']='missing'
        elif op=='graph_macro':
            a[u]['refs'][0]['symbol_id']='macro-old';b[u]['refs'][0]['symbol_id']='macro-new'
            a[u]['refs'][0]['kind']=4;b[u]['refs'][0]['kind']=4
        options={'macro_sites':{'macro-old':{'#define SAME 1'},'macro-new':{'#define SAME 1'}}} if op=='graph_macro' else {}
        result=v.graph_superset([a],b,**options)
        assert result['ok']==(op in ('graph_superset','graph_macro','graph_large','graph_forward_row')),result
        if op=='graph_large':assert b[u]['refs'].iterations<=6,b[u]['refs'].iterations
    elif op=='exact_c':
        entries=[unit('A',0,exact=True),unit('A',1,exact=True)]
        for entry in entries:
            old=entry['file'];new=pathlib.Path(old).with_suffix('.c');pathlib.Path(old).rename(new)
            entry['file']=str(new);entry['arguments'][-1]=str(new)
            entry['nvim_ue_members']=[h.portable_member_path(str(new))]
        assert h.secondary_unity_chunks(entries,split_member_classes=False)==[[0,1]]
        candidate,body=v._tier1_candidate_spec(entries,root/'assets')
        assert pathlib.Path(candidate['file']).suffix=='.c','C language inference changed'
        cpp=unit('A',2,exact=True)
        assert h.secondary_unity_chunks([entries[0],cpp],split_member_classes=False)==[],'mixed inferred languages'
    elif op=='exact_operands':
        a,b=unit('A',0,exact=True),unit('A',1,exact=True)
        for entry in (a,b):entry['arguments'][1:1]=['-include',entry['file']]
        assert h.compile_context_key(a)!=h.compile_context_key(b),'forced inputs were replaced by SOURCE'
        rewritten=h.rewritten_arguments(a,str(root/'new.cpp'))
        assert rewritten[2]==a['file'] and rewritten[-1]==str(root/'new.cpp'),rewritten
        assert h.secondary_unity_chunks([a,b])==[]
    elif op=='exact_graph_records':
        entry=unit('A',0,exact=True);source=pathlib.Path(entry['file']).as_uri()
        a=graph();a={source:next(iter(a.values()))};a[source]['source']['flags']=1
        b=copy.deepcopy(a);b[source]['source']['flags']=0
        baseline=dict(ok=True,graph=a,original_file=entry['file'],exact=True,excluded=str(root/'proof'),
            dependencies=[],inventories={},publication_directories=[],gates={})
        candidate=dict(file=str(write('candidate.cpp','// wrapper\n')))
        with patch.object(v,'_graph_result',return_value=b):
            result=v._tier1_exact_graph_gate([entry],candidate,{},root/'proof',root/'work',str(tool),10,None,baselines=[baseline])
        assert result['ok'],result
        b[source]['refs']=[]
        with patch.object(v,'_graph_result',return_value=b):
            result=v._tier1_exact_graph_gate([entry],candidate,{},root/'proof',root/'work',str(tool),10,None,baselines=[baseline])
        assert not result['ok'],'exact member reference was ignored'
        # The role-bit clear must not copy whole baseline graphs (real exact
        # baselines are 100-270 MB each) and must not mutate cached baselines.
        assert a[source]['source']['flags']==1
        real_deepcopy=copy.deepcopy
        def guarded(value,*args,**kwargs):
            assert not (isinstance(value,list) and value and isinstance(value[0],dict) and 'graph' in value[0]),'whole baselines deep-copied'
            return real_deepcopy(value,*args,**kwargs)
        b[source]['refs']=a[source]['refs']
        with patch.object(v,'_graph_result',return_value=b),patch('copy.deepcopy',side_effect=guarded):
            result=v._tier1_exact_graph_gate([entry],candidate,{},root/'proof',root/'work',str(tool),10,None,baselines=[baseline])
        assert result['ok'],result
        assert a[source]['source']['flags']==1,'cached baseline mutated'
    elif op in ('exact_success','exact_failure','exact_context','exact_graph_rejection','tier2_exact_metrics'):
        entries=[unit('A',0,exact=True),unit('A',1,exact=True)]
        if op=='exact_context':
            entries[1]['arguments'].insert(1,'-DOTHER=1')
            assert h.secondary_unity_chunks(entries)==[]
        else:
            assert h.secondary_unity_chunks(entries)==[[0,1]]
            expected=[e['file'] for e in entries]
            def index(candidate,*args,**kwargs):
                return dict(background_compile_success=op!='exact_failure',indexing_complete=True,exit_code=0,
                    compile_failure_count=int(op=='exact_failure'),missing_main_shards=[],member_main_shards=expected)
            with patch.object(v,'_tier1_candidate_index',side_effect=index),\
                 patch.object(v,'_merge_original_graph',return_value={}),\
                 patch.object(v,'_tier1_exact_graph_gate',return_value=dict(ok=op!='exact_graph_rejection',reason='ref-location-missing',
                    violation_count=int(op=='exact_graph_rejection'),dependencies=[],evidence=[],inventories={},excluded=str(root))),\
                 patch.object(v,'_proof_work_root',return_value=root/'work'):
                if op=='tier2_exact_metrics':os.environ['NVIM_UE_TIER2']='1'
                out,metrics=v.accelerate_tier1(entries,root/'proof',tool)
                assert len(out)==(1 if op in ('exact_success','tier2_exact_metrics') else 2),metrics
                if op=='tier2_exact_metrics':
                    assert metrics['retained_ubt_count']==0 and metrics['accepted_ubt_count']==0,metrics
                    assert metrics['accepted_exact_count']==2,metrics
                if op=='exact_graph_rejection':
                    with patch.object(v,'_tier1_candidate_index',side_effect=AssertionError('repeat rejected native')):
                        repeated,again=v.reuse_tier1(entries,root/'proof',tool)
                    assert repeated==entries and again['groups'][0]['cached'],again
                if op=='exact_success':
                    assert metrics['retained_ubt_count']==0 and metrics['accepted_exact_count']==2,metrics
                    assert metrics['groups'][0]['gates']['graph_superset']
                    with patch.object(v,'_tier1_candidate_index',side_effect=AssertionError('repeat native')):
                        repeated,_=v.reuse_tier1(entries,root/'proof',tool)
                    assert repeated==out
    elif op in ('module_graph_cache','module_graph_tamper','module_compile_exclusion','module_shard_errors','graph_dependency_invalidate','exact_background'):
        entries=[unit('A',0),unit('A',1),unit('B',0),unit('B',1)]
        if op=='module_compile_exclusion':
            def reject(*args,**kwargs):return dict(background_compile_success=False,indexing_complete=True,
                exit_code=0,compile_failure_count=1,missing_main_shards=[],member_main_shards=[])
            with patch.object(v,'_tier1_candidate_index',side_effect=reject),patch.object(v,'_proof_work_root',return_value=root/'work'):
                v._accelerate_tier1(entries[:2],root/'proof',tool)
            state=v.tier2_planning_state(entries,root/'proof',tool)
            assert state['module_compile_results']['Source/A'] is False,state
            assert h.tier2_unity_chunks(entries,**state)==[]
        elif op=='module_shard_errors':
            def index(commands,directory,*args,**kwargs):
                run=pathlib.Path(directory)/'run/run.json';run.parent.mkdir(parents=True,exist_ok=True)
                run.write_text(json.dumps(dict(indexing_complete=True,exit_code=0,compile_failure_count=0)))
                raise ValueError('private-index-had-errors: actual-source-uri')
            with patch.object(v,'_index',side_effect=index),patch.object(v,'_proof_work_root',return_value=root/'work'):
                try:v._merge_original_graph(entries[:2],root/'proof/tier2',str(tool),10,None)
                except ValueError:pass
                else:raise AssertionError('compile error accepted')
            state=v.tier2_planning_state(entries,root/'proof',tool)
            assert state['module_compile_results'].get('Source/A') is False,state
        elif op=='exact_background':
            import cdb_background_batch as b
            entries=[unit('A',0,exact=True),unit('A',1,exact=True)]
            expected=[e['file'] for e in entries]
            def index(*args,**kwargs):return dict(background_compile_success=True,indexing_complete=True,
                exit_code=0,compile_failure_count=0,missing_main_shards=[],member_main_shards=expected)
            with patch.object(v,'_tier1_candidate_index',side_effect=index),\
                 patch.object(v,'_merge_original_graph',return_value={}),\
                 patch.object(v,'_tier1_exact_graph_gate',return_value=dict(ok=True,dependencies=[],inventories={},excluded=str(root))),\
                 patch.object(v,'_proof_work_root',return_value=root/'work'),patch.object(b,'_owned_job',return_value=None):
                source=write('semantic.json',json.dumps(entries));store=root/'proof'
                plan=b.make_plan(source,store,tool);b._write(root/'plan.json',plan)
                assert len(plan['groups'])==1,plan
                b.work(root/'plan.json',plan['groups'][0]['id'],tool)
                marker=write('marker.json','{}')
                result=b.collect(root/'plan.json',[g['id'] for g in plan['groups']],root/'published.json',marker,tool)
                assert result['ok'],result
                output=json.loads((root/'published.json').read_bytes())
                assert len(output)==1,output
                with patch.object(v,'_tier1_candidate_index',side_effect=AssertionError('repeat native')):
                    repeated=b.collect(root/'plan.json',[],root/'published.json',marker,tool)
                assert not repeated['changed'],repeated
        else:
            header=write('header.h','// header\n')
            calls=[]
            def index(commands,directory,*args,**kwargs):
                calls.append(commands)
                g=graph();g[next(iter(g))]['source']['direct_includes']=[]
                for entry in entries[:2]:
                    member=v._tier1_ubt_members(entry)[0]
                    g[pathlib.Path(member).as_uri()]=dict(source=dict(digest='1234',flags=0,direct_includes=[]),symbols=[],refs=[],relations=[])
                # Native runner has already validated result and graph decoding.
                return g,dict(background_compile_success=True,indexing_complete=True,exit_code=0),commands
            with patch.object(v,'_index',side_effect=index),patch.object(v,'_proof_work_root',return_value=root/'private-work'):
                proof=v._merge_original_graph(entries[:2],root/'proof/tier2',str(tool),10,None)
                assert v._merge_graph_current(proof)
                second=v._merge_original_graph(entries[:2],root/'proof/tier2',str(tool),10,None)
                assert len(calls)==1,len(calls)
                if op=='module_graph_tamper':
                    cache=pathlib.Path(proof['cache_path']);saved=json.loads(cache.read_bytes())
                    next(record for record in saved['graph'].values() if record['symbols'])['symbols']=[]
                    cache.write_text(json.dumps(saved))
                    v._merge_original_graph(entries[:2],root/'proof/tier2',str(tool),10,None)
                    assert len(calls)==2,'tampered graph reused'
                if op=='graph_dependency_invalidate':
                    header.write_text('// changed header\n')
                    assert not v._merge_graph_current(proof)
                    v._merge_original_graph(entries[:2],root/'proof/tier2',str(tool),10,None)
                    assert len(calls)==2,len(calls)
    elif op=='tier2_graph_rejection':
        entries=[unit('A',0),unit('A',1),unit('B',0),unit('B',1)]
        expected=[p for e in entries for p in v._tier1_ubt_members(e)]
        def index(*args,**kwargs):return dict(background_compile_success=True,indexing_complete=True,
            exit_code=0,compile_failure_count=0,missing_main_shards=[],member_main_shards=expected)
        with patch.object(v,'_tier1_candidate_index',side_effect=index),\
             patch.object(v,'tier2_include_gate',return_value=dict(ok=True,reason='equal')),\
             patch.object(v,'_tier2_baselines',return_value=[]),\
             patch.object(v,'_tier2_graph_gate',return_value=dict(ok=False,reason='symbol-missing',violation_count=1,
                dependencies=[],evidence=[],inventories={},excluded=str(root))),\
             patch.object(v,'_proof_work_root',return_value=root/'work'):
            out,m=v.accelerate_tier2(entries,root/'proof',tool)
        assert len(out)==2 and all(e['nvim_ue_tier']==1 for e in out),m
        assert not m['groups'][0]['gates']['graph_superset']
        with patch.object(v,'_tier1_candidate_index',side_effect=AssertionError('repeat rejected native')),\
             patch.object(v,'tier2_include_gate',side_effect=AssertionError('repeat preprocessing')):
            repeated,again=v.reuse_tier2(entries,root/'proof',tool)
        assert repeated==out and again['groups'][0]['cached'],again
    print('PASS',op)
]=]

local function run(operation)
  local script = vim.fn.tempname() .. "_r32.py"
  vim.fn.writefile(vim.split(fixture, "\n", { plain = true }), script)
  local result = vim.system({ vim.fn.exepath("python"), "-B", "-I", script,
    vim.fn.stdpath("config") .. "/tools/cdb_verified_batch.py", operation }, { text = true }):wait(30000)
  pcall(vim.fn.delete, script)
  t.assert_eq(result.code, 0, (result.stderr or "") .. (result.stdout or ""))
end

t.describe("R32 production tier expansion", function()
  for _, operation in ipairs({ "closure_budget", "definition_conflicts", "graph_superset", "graph_forward_row", "graph_decl_unknown", "graph_signature",
    "graph_counter", "graph_typedef", "graph_friend", "graph_definition", "graph_relation", "graph_target", "graph_macro", "graph_large",
    "exact_success", "exact_failure", "exact_context", "exact_graph_rejection", "tier2_exact_metrics", "tier2_graph_rejection", "module_graph_cache",
    "module_compile_exclusion", "module_shard_errors", "module_graph_tamper", "graph_dependency_invalidate", "exact_background", "exact_graph_records", "exact_operands", "exact_c" }) do
    t.it(operation, function() run(operation) end)
  end
end)
