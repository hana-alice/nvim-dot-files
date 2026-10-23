local t = require("tests.harness")
t.bootstrap()

local fixture = [=[
import json, os, pathlib, subprocess, sys, tempfile
from unittest.mock import patch
tool, clangd = sys.argv[1:]
sys.path.insert(0, str(pathlib.Path(tool).parent))
import cdb_background_batch as module
os.environ['NVIM_UE_BATCH_TIER'] = 'strict'

with tempfile.TemporaryDirectory(prefix='native_split_catalog_') as temporary:
    root = pathlib.Path(temporary).resolve()
    sources = root/'sources'; sources.mkdir()
    compiler = pathlib.Path(clangd).with_name('clang++.exe' if os.name=='nt' else 'clang++')
    assert compiler.is_file(), 'actual clangd has no colocated clang++'
    contents = [
        '#define RESIDUAL_LEAK 1\nint split_zero() { return 0; }\n',
        'int original_target();\nint leaked_target();\n#if defined(RESIDUAL_LEAK)\n'
        'int split_one() { return leaked_target(); }\n#else\n'
        'int split_one() { return original_target(); }\n#endif\n',
        'int split_two() { return 2; }\n',
        'int split_three() { return 3; }\n',
    ]
    entries, members = [], []
    for index, text in enumerate(contents):
        member=sources/('Member%d.cpp'%index); member.write_text(text)
        wrapper=sources/('SuperUnity.UBT.Split.%d.cpp'%index)
        wrapper.write_text('// Compiler-authored UBT unity membership; copied into nvim cache.\n'
            + '#include "'+member.as_posix()+'"\n')
        entries.append(dict(directory=str(sources), file=str(wrapper),
            arguments=[str(compiler),'-x','c++','-std=c++17','-nostdinc','-nostdinc++',str(wrapper)],
            nvim_ue_module_root='NativeSplit', nvim_ue_members=[module.verified.portable_member_path(str(member))]))
        members.append(member)
    exact=dict(directory=str(sources),file=str(sources/'Exact.cpp'),arguments=[str(compiler),'Exact.cpp'])
    shader=dict(directory=str(sources),file=str(sources/'Meta.usf'),arguments=[str(compiler),'Meta.usf'],
        nvim_ue_background_route='shader-compatibility')
    entries += [exact,shader]
    source, store, plan_path = root/'source.json',root/'verified',root/'plan.json'
    output, marker, result_path = root/'background.json',root/'marker.json',root/'work.json'
    source.write_text(module._json(entries)); output.write_text(module._json(entries)); marker.write_text('{}')
    plan=module.make_plan(source,store,clangd)
    assert [group['indexes'] for group in plan['groups']]==[[0,1,2,3]], plan
    module._write(plan_path,plan)
    group=plan['groups'][0]
    worked=subprocess.run([sys.executable,'-B',tool,'--worker',str(plan_path),'--group',group['id'],
        '--clangd',clangd,'--out',str(result_path)],capture_output=True,text=True,timeout=600)
    assert worked.returncode==0, worked.stderr+worked.stdout
    result=json.loads(result_path.read_text())
    metrics=result['metrics']
    observation=dict(new_batch_count=metrics['new_batch_count'],new_proof_count=metrics['new_proof_count'],
        index_runner_reports=sum(len(record.get('run_metrics',[])) for record in metrics['groups']),
        groups=[{key:record.get(key) for key in ('original_indexes','accepted','reason','proof_seconds')}
            for record in metrics['groups']])
    print('native_split_actual='+json.dumps(observation),flush=True)
    assert result['ok'] and metrics['new_batch_count']==1, result
    admitted=[record['original_indexes'] for record in metrics['groups'] if record.get('accepted')]
    assert admitted==[[2,3]], observation
    assert {(0,1,2,3),(0,1)}.issubset({tuple(record['original_indexes']) for record in metrics['groups']}), observation
    assert all(not record['accepted'] and record['reason'].startswith('admission-rejected:')
        for record in metrics['groups'] if record['original_indexes'] in ([0,1,2,3],[0,1])), observation
    collected=module.collect(plan_path,[group['id']],output,marker,clangd)
    rows=json.loads(output.read_text())
    assert collected['metrics']['batch_count']==1 and rows[:2]==entries[:2] and rows[-2:]==[exact,shader], collected
    assert len(rows)==5
    candidate=rows[2]
    receipt=module.verified._read_receipts([candidate['nvim_ue_batch_receipt']])[0]
    assert receipt['original_entries']==[module.verified._native(row) for row in entries[2:4]]
    assert module.verified.validate_receipts([candidate['nvim_ue_batch_receipt']],clangd)['ok']
    catalog=module._catalog(store,'strict')
    assert len(catalog)==1 and len(catalog[0]['entry_hashes'])==4, catalog
    coverage=module.verified._tier1_source_coverage(entries)
    assert module.verified._tier1_source_coverage(rows)==coverage
    paths=[output,marker,module._catalog_path(store,'strict')]
    paths += [path for path in pathlib.Path(group['store']).rglob('*') if path.is_file()]
    before={str(path):(path.read_bytes(),path.stat().st_mtime_ns) for path in paths}
    with patch.object(module.verified,'_prove',side_effect=AssertionError('repeat started qualification')), \
            patch.object(subprocess,'Popen',side_effect=AssertionError('repeat launched a process')):
        os.environ['NVIM_UE_BATCH_TIER']='1'
        reused,reuse_metrics=module.reuse_completed(entries,store,clangd)
        assert reused==rows and reuse_metrics['families']['strict']['invalidated_group_count']==0
        os.environ['NVIM_UE_BATCH_TIER']='strict'
        again=module.collect(plan_path,[group['id']],output,marker,clangd)
        assert not again['changed'] and json.loads(output.read_text())==rows
        assert before=={path:(pathlib.Path(path).read_bytes(),pathlib.Path(path).stat().st_mtime_ns) for path in before}
        members[2].write_text(members[2].read_text()+'// invalidate accepted child\n')
        os.environ['NVIM_UE_BATCH_TIER']='1'
        retained,stale=module.reuse_completed(entries,store,clangd)
        assert retained==entries and stale['families']['strict']['invalidated_group_count']==1
        assert module.verified._tier1_source_coverage(retained)==coverage
    print('REAL partial catalog: parent/first pair rejected by graph gate, final pair retained through readonly reuse and repeat collect')
]=]

t.describe("Actual strict split catalog owner", function()
  local python = vim.fn.exepath("python")
  if python == "" then python = vim.fn.exepath("python3") end
  local discovered = require("utils.ue_goto.semantic_sidecar_libclang").discover_toolchain()
  if python == "" or not discovered.ok then
    t.skip("actual partial strict catalog", python == "" and "Python unavailable" or discovered.reason, { native = true })
    return
  end
  t.it("preserves a real accepted child after parent and sibling semantic rejection", function()
    local path = vim.fn.tempname() .. "_native_split_catalog.py"
    local stream = assert(io.open(path, "wb")); stream:write(fixture); stream:close()
    local result = vim.system({ python, "-B", "-I", path,
      vim.fn.stdpath("config") .. "/tools/cdb_background_batch.py", discovered.clangd_path }, { text = true }):wait()
    pcall(vim.fn.delete, path)
    if result.code == 0 then print(result.stdout or "") end
    t.assert_eq(result.code, 0, (result.stderr or "") .. (result.stdout or ""))
  end)
end)
