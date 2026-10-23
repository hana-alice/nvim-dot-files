local t = require("tests.harness")
t.bootstrap()

local fixture = [=[
import collections, copy, json, os, pathlib, sys, tempfile
from unittest.mock import patch
sys.dont_write_bytecode=True
sys.path.insert(0,str(pathlib.Path(sys.argv[1]).parent))
import cdb_verified_batch as v
operation=sys.argv[2]
with tempfile.TemporaryDirectory(prefix='tier2_verified_') as temporary:
    root=pathlib.Path(temporary).resolve()
    def write(name,text):
        path=root/name;path.parent.mkdir(parents=True,exist_ok=True)
        path.write_text(text,encoding='utf-8');return path
    pch=write('SharedPCH.Engine.h','#pragma once\n')
    compiler=write('bin/clang++.exe','fixture preprocessor identity')
    tool=write('bin/clangd.exe','fixture indexer identity')
    def unit(module,n):
        defs=write('Definitions.'+module+'.h','#define UE_IS_ENGINE_MODULE 1\n#define '+module+'_API\n')
        member=write('Source/'+module+'/Private/File'+str(n)+'.cpp','// member\n')
        wrapper=write('SuperUnity.UBT.'+module+str(n)+'.cpp',
            '// Compiler-authored UBT unity membership; copied into nvim cache.\n#include "'+member.as_posix()+'"\n')
        return {'directory':str(root),'file':str(wrapper),'arguments':[str(compiler),'-std=c++17',
            '-include',str(pch),'-include',str(defs),'-I'+str(root/module),'-c',str(wrapper)],
            'nvim_ue_members':[v.portable_member_path(str(member))],'nvim_ue_module_root':'Source/'+module}
    entries=[unit('Alpha',0),unit('Alpha',1),unit('Beta',0),unit('Beta',1)]
    before=copy.deepcopy(entries)
    expected=[p for e in entries for p in v._tier1_ubt_members(e)]
    calls=[]
    def index(candidate,*args,**kwargs):
        calls.append(candidate.get('nvim_ue_tier'))
        bad=candidate.get('nvim_ue_tier')==2 and operation in ('compile_failure','missing_shards')
        return {'background_compile_success':not (bad and operation=='compile_failure'),
            'indexing_complete':True,'exit_code':0,'compile_failure_count':int(bad and operation=='compile_failure'),
            'member_main_shards':[] if bad and operation=='missing_shards' else expected,
            'missing_main_shards':[],'cpu_seconds':1.0}
    def gate(*args,**kwargs):
        if operation=='cache_store':
            assert '/.cache/nvim-ue/' not in str(args[1]).replace('\\','/').lower(),args
        rejected=operation in ('include_failure','negative_reuse','timeout_uncached')
        reason='timeout' if operation=='timeout_uncached' else 'dependency-set-mismatch' if rejected else 'equal'
        return {'ok':not rejected,'reason':reason,
            'seconds':0.01,'only_tier1':['different.h'] if rejected else [],'only_tier2':[],
            'dependency_counts':{'tier1':5,'tier2':5},'commands':[]}
    out=root/'proof'
    if operation=='cache_store':out=root/'.cache/nvim-ue/background-proofs/fixture'
    os.environ.pop('NVIM_UE_TIER2',None)
    if operation=='environment':
        assert not v.tier2_enabled()
        for value in ['0','1']:
            os.environ['NVIM_UE_TIER2']=value
            assert v.tier2_enabled()==(value=='1')
        for value in ['','2','yes','-1','01']:
            os.environ['NVIM_UE_TIER2']=value
            try:v.tier2_enabled()
            except ValueError:pass
            else:raise AssertionError('accepted invalid flag '+repr(value))
    else:
        os.environ['NVIM_UE_TIER2']='1'
        with patch.object(v,'_tier1_candidate_index',side_effect=index),patch.object(v,'tier2_include_gate',side_effect=gate),\
             patch.object(v,'_proof_work_root',return_value=root/'private-tier1-work'):
            output,metrics=v.accelerate_tier2(entries,out,str(tool),timeout=10)
            assert entries==before
            assert v._tier1_source_coverage(output)==v._tier1_source_coverage(entries)
            assert metrics['coverage_complete']
            if operation in ('include_failure','compile_failure','missing_shards','negative_reuse','timeout_uncached'):
                assert len(output)==2,metrics
                assert all(e['nvim_ue_tier']==1 for e in output),output
                assert sum(g.get('tier')==2 and not g['accepted'] for g in metrics['groups'])==1,metrics
                assert calls.count(1)==2,calls
                if operation=='include_failure': assert 2 not in calls,calls
                if operation in ('negative_reuse','timeout_uncached'):
                    snapshots={str(p):(p.read_bytes(),p.stat().st_mtime_ns) for p in root.rglob('*') if p.is_file()}
                    with patch.object(v,'_tier1_candidate_index',side_effect=AssertionError('reuse indexed')),\
                         patch.object(v,'tier2_include_gate',side_effect=AssertionError('reuse preprocessed')):
                        reused,reuse_metrics=v.reuse_tier2(entries,out,str(tool),timeout=10)
                    assert reused==output,reuse_metrics
                    assert {str(p):(p.read_bytes(),p.stat().st_mtime_ns) for p in root.rglob('*') if p.is_file()}==snapshots
                    rejected=[g for g in reuse_metrics['groups'] if g['tier']==2]
                    assert rejected[0]['cached']==(operation=='negative_reuse'),rejected
                    assert rejected[0]['accepted'] is False,rejected
            else:
                assert len(output)==1 and output[0]['nvim_ue_tier']==2,metrics
                candidate=output[0]
                receipt=json.loads(pathlib.Path(candidate['nvim_ue_tier1_receipt']).read_text())
                assert receipt['tier']==2 and receipt['accepted'] and receipt['reusable']
                assert all(receipt['gates'].get(k) is True for k in ['compile_success','main_shards_complete','members_equal','include_resolution_equal'])
                assert all('nvim_ue_batch_receipt' not in e for e in output)
                assert len([i for i in receipt['inputs'] if pathlib.Path(i['path']).name.startswith('Definitions.')])==2
                if operation in ('reuse','definitions_invalidate'):
                    if operation=='definitions_invalidate':
                        with (root/'Definitions.Beta.h').open('a') as stream:stream.write('// changed bytes\n')
                    snapshots={str(p):(p.read_bytes(),p.stat().st_mtime_ns) for p in root.rglob('*') if p.is_file()}
                    with patch.object(v,'_tier1_candidate_index',side_effect=AssertionError('reuse indexed')),\
                         patch.object(v,'tier2_include_gate',side_effect=AssertionError('reuse preprocessed')),\
                         patch.object(v.subprocess,'Popen',side_effect=AssertionError('reuse spawned')):
                        reused,reuse_metrics=v.reuse_tier2(entries,out,str(tool),timeout=10)
                    assert {str(p):(p.read_bytes(),p.stat().st_mtime_ns) for p in root.rglob('*') if p.is_file()}==snapshots
                    if operation=='reuse':
                        assert reused==output,(reused,output,reuse_metrics)
                        assert reuse_metrics['cache_hits']>=1,reuse_metrics
                    else:
                        assert all(e.get('nvim_ue_tier')!=2 for e in reused),reuse_metrics
                elif operation=='default_off':
                    os.environ['NVIM_UE_TIER2']='0'
                    fallback,_=v.accelerate_tier1(entries,root/'disabled',str(tool),timeout=10)
                    assert len(fallback)==2 and all(e['nvim_ue_tier']==1 for e in fallback)
    print('PASS '+operation)
]=]

local function run(operation)
  local python = vim.fn.exepath("python")
  t.assert_true(python ~= "", "python required")
  local script = vim.fn.tempname() .. "_tier2_verified.py"
  vim.fn.writefile(vim.split(fixture, "\n", { plain = true }), script)
  local result = vim.system({ python, "-B", "-I", script,
    vim.fn.stdpath("config") .. "/tools/cdb_verified_batch.py", operation }, { text = true }):wait(30000)
  pcall(vim.fn.delete, script)
  t.assert_eq(result.code, 0, (result.stderr or "") .. (result.stdout or ""))
end

t.describe("Tier 2 private qualification and fallback", function()
  for _, operation in ipairs({ "environment", "success", "include_failure", "compile_failure",
    "missing_shards", "reuse", "definitions_invalidate", "default_off", "negative_reuse", "timeout_uncached",
    "cache_store" }) do
    t.it(operation, function() run(operation) end)
  end
end)
