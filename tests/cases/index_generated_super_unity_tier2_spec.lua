local t = require("tests.harness")
t.bootstrap()

local fixture = [=[
import copy, json, pathlib, shutil, sys, tempfile
sys.dont_write_bytecode = True
sys.path.insert(0, str(pathlib.Path(sys.argv[1]).parent))
from build_hot_super_unity_cdb import (portable_member_path, secondary_unity_chunks,
    tier2_unity_chunks, tier2_candidate_spec, tier2_include_gate)
operation, clang = sys.argv[2:]
with tempfile.TemporaryDirectory(prefix='tier2 fixture ') as temporary:
    root = pathlib.Path(temporary).resolve()
    def write(name, body):
        path = root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(body, encoding='utf-8')
        return path
    pch = write('SharedPCH.Engine.h', '#pragma once\n#define PREFIX_SEEN 1\n')
    def unit(module, n=0, size=None, engine=1):
        defs = write('Definitions.'+module+'.h', '#define UE_IS_ENGINE_MODULE '+str(engine)+'\n#define '+module+'_API\n')
        member = write('Source/'+module+'/Private/'+str(n)+'.cpp',
            '// source\n' if size is None else ' ' * size)
        wrapper = write('SuperUnity.UBT.'+module+str(n)+'.cpp', '#include "'+member.as_posix()+'"\n')
        return {'directory': str(root), 'file': str(wrapper),
                'arguments': ['clang++', '-std=c++17', '-include', str(pch),
                              '-include', str(defs), '-I'+str(root/module), '-c', str(wrapper)],
                'nvim_ue_module_root': 'Source/'+module,
                'nvim_ue_members': [portable_member_path(str(member))]}
    if operation == 'whole_modules':
        entries = [unit('A',0), unit('B'), unit('A',1), unit('C')]
        before = copy.deepcopy(entries)
        assert tier2_unity_chunks(entries, max_unities=3) == [[0,1,2]]
        assert tier2_unity_chunks(entries, max_unities=2) == [[1,3]]
        assert entries == before
    elif operation == 'budgets':
        entries = [unit('A',0,200000),unit('A',1,200000),unit('B'),unit('C')]
        assert tier2_unity_chunks(entries,budget_factor=1) == [[2,3]]
        boundary = [unit('D',0,196608),unit('E',0,196608)]
        assert tier2_unity_chunks(boundary,budget_factor=1) == [[0,1]]
        for kwargs in [{'max_unities':0},{'max_unities':True},{'budget_factor':0},{'budget_factor':1.5}]:
            try: tier2_unity_chunks(boundary, **kwargs)
            except ValueError: pass
            else: raise AssertionError(kwargs)
    elif operation == 'contexts':
        a,b = unit('A'),unit('B')
        assert tier2_unity_chunks([a,b]) == [[0,1]]
        for mutate in [lambda e:e['arguments'].insert(1,'-DFEATURE=1'),
                       lambda e:e.update(directory=str(root/'other'))]:
            c=copy.deepcopy(b);mutate(c)
            assert tier2_unity_chunks([a,c]) == []
        c=unit('C',engine=0)
        assert tier2_unity_chunks([a,c]) == []
        second=unit('A',1);second['arguments'].insert(1,'-DFEATURE=1')
        assert tier2_unity_chunks([a,b,second]) == []
        c=copy.deepcopy(b)
        c['arguments'][1:4]=['-include',str(pch),'-std=c++17']
        assert tier2_unity_chunks([a,c]) == []
    elif operation == 'unknown_member':
        a,b,c = unit('A'),unit('B'),unit('C')
        (root/'Source/A/Private/0.cpp').unlink()
        diagnostics=[]
        assert tier2_unity_chunks([a,b,c],diagnostics=diagnostics) == [[1,2]]
        assert diagnostics and 'A' in diagnostics[0]['module']
    elif operation == 'candidate':
        a,b = unit('A'),unit('B')
        candidate,body=tier2_candidate_spec([a,b],root/'output.cpp')
        assert body.count('#include "'+pch.as_posix()+'"') == 1
        assert body.index('Definitions.A.h') < body.index('/A/Private/') < body.index('Definitions.B.h')
        assert '#pragma push_macro("UE_IS_ENGINE_MODULE")' in body
        assert '#undef A_API' in body and '#pragma pop_macro("A_API")' in body
        assert '-include' not in candidate['arguments']
        assert candidate['nvim_ue_members'] == a['nvim_ue_members']+b['nvim_ue_members']
        assert not (root/'output.cpp').exists()
        assert secondary_unity_chunks([a,b],diagnostics=[]) == []
        forbidden=root/'.cache/nvim-ue/private'
        assert not tier2_include_gate([a,b],forbidden,clang)['ok']
        assert not forbidden.exists()
    elif operation in ('gate_equal','gate_shadow'):
        a,b=unit('A'),unit('B')
        if operation == 'gate_shadow':
            write('A/same.h','#pragma once\n#define FROM_A 1\n')
            write('B/same.h','#pragma once\n#define FROM_B 1\n')
            write('Source/A/Private/0.cpp','#include "same.h"\n')
            write('Source/B/Private/0.cpp','#include "same.h"\n')
        result=tier2_include_gate([a,b],root/'private gate',clang,timeout=10)
        assert result['ok'] == (operation=='gate_equal'), json.dumps(result)
        assert len(result['commands']) == 3, json.dumps(result)
        if operation=='gate_shadow':
            assert result['reason']=='dependency-set-mismatch', json.dumps(result)
            assert result['only_tier1'], json.dumps(result)
        print(json.dumps({'ok':result['ok'],'seconds':result['seconds']}))
]=]

local function run(operation, clang)
  local python = vim.fn.exepath("python")
  t.assert_true(python ~= "", "python required")
  local script = vim.fn.tempname() .. ".py"
  vim.fn.writefile(vim.split(fixture, "\n", { plain = true }), script)
  local result = vim.system({ python, "-B", "-I", script,
    vim.fn.stdpath("config") .. "/tools/build_hot_super_unity_cdb.py", operation, clang or "" },
    { text = true }):wait(20000)
  pcall(vim.fn.delete, script)
  t.assert_eq(result.code, 0, (result.stderr or "") .. (result.stdout or ""))
end

t.describe("offline Tier 2 planning and dependency gate", function()
  for _, operation in ipairs({ "whole_modules", "budgets", "contexts", "unknown_member", "candidate" }) do
    t.it(operation, function() run(operation) end)
  end
  local discovered = require("utils.platform").resolve_tool({ name = "clangd", env = { "UE_CLANGD" },
    config_candidates = require("utils.ue_goto.semantic_sidecar_libclang").discover_clangd_candidates() })
  local clang = vim.fn.exepath("clang++")
  if clang == "" and discovered.ok then
    local suffix = vim.fn.has("win32") == 1 and ".exe" or ""
    local sibling = vim.fs.dirname(discovered.path) .. "/clang++" .. suffix
    if vim.fn.executable(sibling) == 1 then clang = sibling end
  end
  if clang == "" then
    t.skip("Tier 2 dependency gate native cases", "clang++ unavailable", { native = true })
    return
  end
  for _, operation in ipairs({ "gate_equal", "gate_shadow" }) do
    t.it(operation, function() run(operation, clang) end)
  end
end)
