local t = require("tests.harness")
t.bootstrap()

local fixture = [=[
import copy, json, os, pathlib, sys, tempfile
from unittest.mock import patch
sys.dont_write_bytecode=True
sys.path.insert(0,str(pathlib.Path(sys.argv[1]).parent))
import cdb_background_batch as b
v=b.verified
operation=sys.argv[2]
os.environ['NVIM_UE_BATCH_TIER']='1'
os.environ['NVIM_UE_TIER2']='1'
with tempfile.TemporaryDirectory(prefix='background_tier2_') as temporary:
    root=pathlib.Path(temporary).resolve()
    def write(name,text):
        path=root/name;path.parent.mkdir(parents=True,exist_ok=True)
        path.write_text(text,encoding='utf-8');return path
    pch=write('SharedPCH.Engine.h','#pragma once\n')
    compiler=write('bin/clang++.exe','fixture preprocessor identity')
    tool=write('bin/clangd.exe','fixture indexer identity')
    def unit(name,n,engine=1):
        defs=write('Definitions.'+name+'.h','#define UE_IS_ENGINE_MODULE '+str(engine)+'\n#define '+name+'_API\n')
        member=write('Source/'+name+'/Private/File'+str(n)+'.cpp','// member\n')
        wrapper=write('SuperUnity.UBT.'+name+str(n)+'.cpp',
            '// Compiler-authored UBT unity membership; copied into nvim cache.\n#include "'+member.as_posix()+'"\n')
        return {'directory':str(root),'file':str(wrapper),'arguments':[str(compiler),'-std=c++17',
            '-include',str(pch),'-include',str(defs),'-I'+str(root/name),'-c',str(wrapper)],
            'nvim_ue_members':[v.portable_member_path(str(member))],'nvim_ue_module_root':'Source/'+name}
    entries=[unit('Alpha',0),unit('Alpha',1),unit('Beta',0),unit('Beta',1),unit('Gamma',0,0),unit('Gamma',1,0)]
    entries += [{'directory':str(root),'file':str(root/'exact.cpp'),'arguments':['clang++','exact.cpp']},
        {'directory':str(root),'file':str(root/'test.usf'),'arguments':['clang++','test.usf'],
         'nvim_ue_background_route':'shader-compatibility'}]
    before=copy.deepcopy(entries)
    expected=[p for e in entries if v._is_ubt(e) for p in v._tier1_ubt_members(e)]
    calls=[]
    def index(candidate,*args,**kwargs):
        calls.append(candidate.get('nvim_ue_tier'))
        return {'background_compile_success':True,'indexing_complete':True,'exit_code':0,
            'compile_failure_count':0,'member_main_shards':expected,'missing_main_shards':[],'cpu_seconds':1.0}
    def gate(*args,**kwargs):
        return {'ok':operation!='include_fallback','reason':'dependency-set-mismatch' if operation=='include_fallback' else 'equal',
            'seconds':0.01,'only_tier1':[],'only_tier2':[],'dependency_counts':{'tier1':5,'tier2':5},'commands':[]}
    source=write('semantic.json',json.dumps(entries)); store=root/'proof'
    plan_path=root/'plan.json'; published=root/'background.json'; marker=write('marker.json','{}')
    def snapshot():
        return {str(p):(p.read_bytes(),p.stat().st_mtime_ns) for p in root.rglob('*') if p.is_file()}
    with patch.object(v,'_tier1_candidate_index',side_effect=index),patch.object(v,'tier2_include_gate',side_effect=gate),\
         patch.object(v,'_proof_work_root',return_value=root/'private-tier1-work'),patch.object(b,'_owned_job',return_value=None):
        if operation=='grouping':
            os.environ['NVIM_UE_TIER2']='0'
            old=b._identity(entries[:4],'1')
            assert b._chunks(entries,'1')==[[0,1],[2,3],[4,5]]
            os.environ['NVIM_UE_TIER2']='1'
            assert b._chunks(entries,'1')==[[0,1,2,3],[4,5]]
            assert b._identity(entries[:4],'1')!=old
            assert entries==before
        elif operation=='invalid_flag':
            for value in ['', '2','true','01']:
                os.environ['NVIM_UE_TIER2']=value
                try:b.make_plan(source,store,str(tool))
                except ValueError:pass
                else:raise AssertionError('invalid flag accepted '+repr(value))
        elif operation=='partial_module':
            indexes=[0,2,3];selected=[entries[i] for i in indexes]
            identity=b._identity(selected,'1')
            group={'id':identity,'indexes':indexes,'store':str(b._catalog_path(store,'1').parent/identity),
                'ubt_count':len(indexes),'member_count':len(indexes)}
            try:b._group({'mode':'1','legacy_store':str(store),'groups':[group]},entries,identity)
            except ValueError as error:assert 'tier2-partial-module' in str(error)
            else:raise AssertionError('partial module accepted')
        elif operation=='plan_flag':
            plan=b.make_plan(source,store,str(tool)); assert plan['tier2_enabled'] is True
            b._write(plan_path,plan);os.environ['NVIM_UE_TIER2']='0'
            for call in [lambda:b.work(plan_path,plan['groups'][0]['id'],str(tool)),
                    lambda:b.collect(plan_path,[],published,marker,str(tool))]:
                try:call()
                except ValueError as error: assert 'plan-tier2-mismatch' in str(error)
                else:raise AssertionError('flag change accepted')
            plan=b.make_plan(source,store,str(tool));assert 'tier2_enabled' not in plan
            b._write(plan_path,plan);os.environ['NVIM_UE_TIER2']='1'
            try:b._load_plan(plan_path,None)
            except ValueError as error:assert 'plan-tier2-mismatch' in str(error)
            else:raise AssertionError('old/off plan accepted')
        else:
            if operation=='existing_tier1':
                os.environ['NVIM_UE_TIER2']='0'
                v.accelerate_tier1(entries,store,str(tool),timeout=10)
                os.environ['NVIM_UE_TIER2']='1'
            plan=b.make_plan(source,store,str(tool),auto_tier1_large=operation=='auto_large')
            assert any(group['indexes']==[0,1,2,3] for group in plan['groups']),plan
            b._write(plan_path,plan)
            for group in plan['groups']:b.work(plan_path,group['id'],str(tool))
            result=b.collect(plan_path,[g['id'] for g in plan['groups']],published,marker,str(tool))
            assert result['ok'] and result['mode']=='1',result
            output=json.loads(published.read_text())
            assert v._tier1_source_coverage(output)==v._tier1_source_coverage(entries)
            assert entries==before
            assert all('nvim_ue_batch_receipt' not in e for e in output)
            if operation=='include_fallback':
                assert len(output)==5 and all(e.get('nvim_ue_tier')!=2 for e in output),result
            else:
                assert len(output)==4 and sum(e.get('nvim_ue_tier')==2 for e in output)==1,result
                candidate=next(e for e in output if e.get('nvim_ue_tier')==2)
                assert not (pathlib.Path(candidate['nvim_ue_tier1_receipt']).parents[1].parent/'tier1'/'receipts').exists(), 'fixture must cover Tier2-only store'
                receipt=json.loads(pathlib.Path(candidate['nvim_ue_tier1_receipt']).read_text())
                assert receipt['tier']==2 and all(receipt['gates'][name] for name in v._TIER2_GATES)
                if operation=='fourth_gate':
                    receipt['gates']['include_resolution_equal']=False
                    changed=write('tampered.json',json.dumps(receipt));candidate=dict(candidate,
                        nvim_ue_tier1_receipt=str(changed),nvim_ue_tier1_receipt_sha256=b._sha(changed.read_bytes()))
                    try:b._tier1_receipt(entries[:4],candidate)
                    except ValueError:pass
                    else:raise AssertionError('missing fourth gate accepted')
                elif operation in ('definitions_changed','definitions_missing'):
                    defs=root/'Definitions.Beta.h'
                    if operation=='definitions_changed':defs.write_text(defs.read_text()+'// changed\n')
                    else:defs.unlink()
                    reused,metrics=b.reuse_completed(entries,store,str(tool))
                    assert all(e.get('nvim_ue_tier')!=2 for e in reused),metrics
            if operation not in ('definitions_changed','definitions_missing','fourth_gate'):
                stable=snapshot()
                with patch.object(v,'_tier1_candidate_index',side_effect=AssertionError('repeat indexed')),\
                     patch.object(v,'tier2_include_gate',side_effect=AssertionError('repeat preprocessed')),\
                     patch.object(b.subprocess,'Popen',side_effect=AssertionError('repeat spawned')):
                    repeated=b.collect(plan_path,[],published,marker,str(tool))
                    assert not repeated['changed'],repeated
                    pending=b.make_plan(source,store,str(tool),previous_path=plan_path)
                    assert pending['groups']==[],pending
                assert snapshot()==stable,'repeat changed bytes or timestamps'
    print('PASS '+operation)
]=]

local function run(operation)
  local python = vim.fn.exepath("python")
  t.assert_true(python ~= "", "python required")
  local script = vim.fn.tempname() .. "_background_tier2.py"
  vim.fn.writefile(vim.split(fixture, "\n", { plain = true }), script)
  local result = vim.system({ python, "-B", "-I", script,
    vim.fn.stdpath("config") .. "/tools/cdb_background_batch.py", operation }, { text = true }):wait(30000)
  pcall(vim.fn.delete, script)
  t.assert_eq(result.code, 0, (result.stderr or "") .. (result.stdout or ""))
end

t.describe("Tier 2 ordinary background proof publication", function()
  for _, operation in ipairs({ "grouping", "invalid_flag", "partial_module", "plan_flag", "plan_collect", "existing_tier1",
    "include_fallback", "fourth_gate", "definitions_changed", "definitions_missing", "auto_large" }) do
    t.it(operation, function() run(operation) end)
  end
end)
