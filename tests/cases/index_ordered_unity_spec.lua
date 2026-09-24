local t = require("tests.harness")
t.bootstrap()

local fixture = [=[
import copy, importlib.util, json, os, pathlib, subprocess, sys, tempfile
from unittest.mock import patch
tool, operation, clangd = sys.argv[1:]
sys.path.insert(0, str(pathlib.Path(tool).parent))
spec = importlib.util.spec_from_file_location('ordered', tool)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
compiler = str(pathlib.Path(clangd).with_name('clang++' + pathlib.Path(clangd).suffix)) if clangd else 'clang++'
with tempfile.TemporaryDirectory(prefix='ordered_unity_') as temporary:
    root = pathlib.Path(temporary).resolve()
    output = root / 'output'
    def write(name, text):
        path = root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding='utf-8')
        return path
    def entry(source, *options):
        return {'directory': str(root), 'file': str(source),
                'arguments': [compiler, '-std=c++17', *options, '-c', str(source)]}
    def unit(name, members, *options):
        path = write(name, ''.join('#include "' + str(p).replace('\\', '/') + '"\n' for p in members))
        return entry(path, *options)
    def compile_entry(value):
        args = [a for a in value['arguments'] if a != '-c'] + ['-fsyntax-only']
        return subprocess.run(args, cwd=value['directory'], capture_output=True, text=True, timeout=15,
            creationflags=(subprocess.CREATE_NO_WINDOW | subprocess.IDLE_PRIORITY_CLASS) if os.name == 'nt' else 0)
    def produce(entries, members, **kwargs):
        before = copy.deepcopy((entries, members))
        with patch.object(subprocess, 'Popen', side_effect=AssertionError('producer must not run native admission')):
            result = module.build_candidates(entries, members, output, **kwargs)
        assert (entries, members) == before
        assert result['classification'] == 'candidate-only' and result['admitted'] is False
        assert all(set(e) == {'directory', 'file', 'arguments'} for e in result['candidates'])
        return result
    if operation == 'specialization':
        import clangd_batch_runner
        from clangd_index_graph import read_shard
        write('Shared.h', '#pragma once\ntemplate<class T> int value();\nstruct Tag {};\nstruct Other {};\n')
        ordinary = write('Normal.cpp', '#include "Shared.h"\nint ordinary() { return value<Tag>(); }\n')
        generated = write('Reflection.gen.cpp', '#include "Shared.h"\ntemplate<> int value<Tag>() { return 7; }\n')
        second = write('Second.cpp', '#include "Shared.h"\nint second() { return value<Other>(); }\n')
        other_generated = write('Other.gen.cpp', '#include "Shared.h"\ntemplate<> int value<Other>() { return 8; }\n')
        # Deliberately misleading wrapper names: only actual member suffixes count.
        a = unit('ActuallyOrdinary.gen.cpp', [ordinary])
        b = unit('GeneratedButPlainName.cpp', [generated])
        c = unit('SecondOrdinary.gen.cpp', [second])
        d = unit('SecondGeneratedPlainName.cpp', [other_generated])
        entries = [a, b, c, d]
        members = {e['file']: [str(p)] for e,p in zip(entries, [ordinary,generated,second,other_generated])}
        for original in entries:
            native = compile_entry(original)
            assert native.returncode == 0, native.stderr
        old = unit('OldOrder.cpp', [pathlib.Path(a['file']), pathlib.Path(b['file'])])
        failed = compile_entry(old)
        assert failed.returncode != 0 and 'specialization' in failed.stderr and 'instantiation' in failed.stderr, failed.stderr
        mixed = unit('OldGeneratedFirst.cpp', [pathlib.Path(e['file']) for e in [b,d,a,c]])
        native = compile_entry(mixed)
        assert native.returncode == 0, native.stderr
        def index_calls(label, commands):
            cdb = root / label
            cdb.mkdir()
            trigger = write(label+'/Trigger.cpp', '// Private BackgroundIndex activation.\n')
            (cdb/'compile_commands.json').write_text(json.dumps(commands+[entry(trigger)]), encoding='utf-8')
            run = clangd_batch_runner.run(cdb, cdb/'native', trigger, clangd, timeout=15, jobs=1)
            assert run['indexing_complete'] and run['background_compile_success'], run
            calls = {}
            for source in (ordinary,second):
                position = [1, source.read_text().splitlines()[1].index('value')]
                refs = {json.dumps(ref,sort_keys=True) for path in run['shards'] for ref in read_shard(path)['refs']
                        if ref['location']['uri']==source.as_uri() and ref['location']['start']==position and ref['kind'] & 4}
                assert len(refs)==1, (label,source,refs)
                calls[source.name] = json.loads(next(iter(refs)))
            return calls
        baseline = index_calls('original-index', [a,c])
        rebound = index_calls('mixed-index', [mixed])
        assert all(baseline[name]['symbol_id'] != rebound[name]['symbol_id'] for name in baseline), (baseline,rebound)
        result = produce(entries, members)
        separate = index_calls('separate-index', result['candidates'] + result['retained_entries'])
        assert separate == baseline, {'baseline':baseline,'old_generated_first':rebound,'candidate':separate}
        assert len(result['candidates']) == 2 and not result['retained_entries']
        assert [g['original_entries'] for g in result['groups']] == [[a,c],[b,d]]
        assert sorted(p for g in result['groups'] for p in g['members']) == sorted(p for ps in members.values() for p in ps)
        stamps = {e['file']: pathlib.Path(e['file']).stat().st_mtime_ns for e in result['candidates']}
        assert produce(entries,members) == result
        assert all(pathlib.Path(path).stat().st_mtime_ns==stamp for path,stamp in stamps.items())
    elif operation == 'macro_order':
        pch = write('PCH.h', '#define UE_IS_ENGINE_MODULE 1\n#define MODE 1\n')
        da = write('Definitions.A.h', '#undef UE_IS_ENGINE_MODULE\n#define UE_IS_ENGINE_MODULE 0\n'
            '#undef MODE\n#define MODE 2\n#define ONLY_A_API\n#define COMMON_API\n#undef TOGGLE\n')
        db = write('Definitions.B.h', '#undef UE_IS_ENGINE_MODULE\n#define UE_IS_ENGINE_MODULE 0\n'
            '#undef MODE\n#define MODE 2\n#define COMMON_API\n#undef TOGGLE\n')
        a_source = write('A.cpp', 'static_assert(UE_IS_ENGINE_MODULE == 0 && MODE == 2 && CLI == 11, "A context");\n'
            '#ifdef TOGGLE\n#error A must see the explicit undef\n#endif\n'
            'ONLY_A_API int alpha() { return 9; }\n')
        b_source = write('B.cpp', 'static_assert(UE_IS_ENGINE_MODULE == 0 && MODE == 2 && CLI == 11, "B context");\n'
            '#ifdef ONLY_A_API\n#error prior member macro leaked\n#endif\n'
            '#ifdef TOGGLE\n#error B must see the explicit undef\n#endif\nCOMMON_API int beta() { return 3; }\n')
        common = ['-DCLI=11', '-DTOGGLE=1', '-include', str(pch)]
        a = unit('UA.cpp', [a_source], *common, '-include', str(da))
        b = unit('UB.cpp', [b_source], *common, '-include', str(db))
        entries = [a, b]; members = {a['file']: [str(a_source)], b['file']: [str(b_source)]}
        for original in entries:
            native = compile_entry(original)
            assert native.returncode == 0, native.stderr
        result = produce(entries, members)
        assert len(result['candidates']) == 1
        candidate = result['candidates'][0]
        assert '-DUE_IS_ENGINE_MODULE=0' not in candidate['arguments']
        assert candidate['arguments'].count('-include') == 1 and str(pch) in candidate['arguments']
        native = compile_entry(candidate)
        assert native.returncode == 0, native.stderr
        tail = unit('AfterBatch.cpp', [pathlib.Path(candidate['file'])], *common)
        with pathlib.Path(tail['file']).open('a') as stream:
            stream.write('static_assert(UE_IS_ENGINE_MODULE == 1 && MODE == 1 && TOGGLE == 1, "restore compiler baseline");\n')
            stream.write('#ifdef ONLY_A_API\n#error final member API leaked\n#endif\n')
        native = compile_entry(tail)
        assert native.returncode == 0, native.stderr
    elif operation == 'unsupported':
        pch = write('PCH.h', '// shared\n')
        a_source = write('A.cpp', 'int alpha;\n'); b_source = write('B.cpp', 'int beta;\n')
        for text, placement in [('#pragma once\n#define A 1\n', 'after'),
                ('#include "Other.h"\n', 'after'), ('#if FLAG\n#define A 1\n#endif\n', 'after'),
                ('#define A 1\n', 'before')]:
            da = write('Definitions.A.h', text); db = write('Definitions.B.h', '#define B 1\n')
            aa = ['-include', str(da), '-include', str(pch)] if placement == 'before' else ['-include', str(pch), '-include', str(da)]
            a = unit('UA.cpp', [a_source], *aa); b = unit('UB.cpp', [b_source], '-include', str(pch), '-include', str(db))
            result = produce([a, b], {a['file']: [str(a_source)], b['file']: [str(b_source)]})
            assert not result['candidates'] and result['retained_entries'] == [a, b], result
            assert result['rejections'] and result['rejections'][0]['reason'], result
        response = write('args.rsp', '-DAMBIGUOUS=1\n')
        a = unit('UA.cpp', [a_source], '@' + str(response)); b = unit('UB.cpp', [b_source], '@' + str(response))
        result = produce([a, b], {a['file']: [str(a_source)], b['file']: [str(b_source)]})
        assert result['retained_entries'] == [a, b] and not result['candidates']
    elif operation == 'budgets_contexts':
        entries=[]; members={}
        for i, size in enumerate([2, 1, 2, 1, 4]):
            files=[write('M'+str(i)+'_'+str(j)+'.cpp', 'int m'+str(i)+'_'+str(j)+';\n') for j in range(size)]
            value=unit('U'+str(i)+'.cpp',files);entries.append(value);members[value['file']]=list(map(str,files))
        exact=entry(write('Exact.cpp','int exact;\n'));shader=entry(write('Shader.usf','// donor\n'))
        entries += [exact,shader]
        result=produce(entries,members,max_originals=2,max_sources=3)
        assert [len(g['original_entries']) for g in result['groups']] == [2,2]
        assert result['retained_entries']==entries[4:]
        assert sum(len(g['members']) for g in result['groups'])==6
        assert all(len(g['members'])<=3 for g in result['groups'])
        for options in (['-fexceptions'],['-DVALUE=2'],['-DVALUE=1','-UVALUE'],['-include',str(write('OtherPCH.h','// other\n'))]):
            a,b=copy.deepcopy(entries[:2]);b['arguments'][1:1]=options
            split=produce([a,b],{a['file']:members[a['file']],b['file']:members[b['file']]})
            assert not split['candidates'] and split['retained_entries']==[a,b]
    elif operation == 'idempotence':
        definition=write('Definitions.A.h','#define FLAG 1\n')
        a_source=write('A.cpp','int alpha;\n');b_source=write('B.cpp','int beta;\n')
        a=unit('UA.cpp',[a_source],'-I',str(root/'first'),'-include',str(definition))
        b=unit('UB.cpp',[b_source],'-I',str(root/'second'),'-include',str(definition))
        entries=[a,b];members={a['file']:[str(a_source)],b['file']:[str(b_source)]}
        first=produce(entries,members);path=pathlib.Path(first['candidates'][0]['file'])
        stamp=path.stat().st_mtime_ns;raw=path.read_bytes()
        second=produce(entries,members)
        assert first==second and path.stat().st_mtime_ns==stamp and path.read_bytes()==raw
        definition.write_text('#define FLAG 2\n')
        changed=produce(entries,members)
        assert changed['candidates'][0]['file'] != str(path) and path.read_bytes()==raw
        assert changed['groups'][0]['original_entries']==entries
    elif operation == 'definition_contexts':
        a_source=write('A.cpp','int alpha;\n');b_source=write('B.cpp','int beta;\n')
        for first,second in [('#define FEATURE 1\n','#define FEATURE 0\n'),
                ('#define FEATURE 1\n',''),('#undef FEATURE\n',''),
                ('#define MODULE_API __attribute__((visibility("default")))\n','#define MODULE_API\n'),
                ('#define URL "http://one"\n','#define URL "http://two"\n')]:
            da=write('Definitions.A.h',first);db=write('Definitions.B.h',second)
            a=unit('UA.cpp',[a_source],'-include',str(da));b=unit('UB.cpp',[b_source],'-include',str(db))
            result=produce([a,b],{a['file']:[str(a_source)],b['file']:[str(b_source)]})
            assert not result['candidates'] and result['retained_entries']==[a,b], (first,second,result)
    elif operation == 'mixed_and_rejections':
        normal=write('Normal.cpp','int ordinary;\n');generated=write('Reflection.gen.cpp','int reflected;\n')
        other=write('Other.gen.cpp','int reflected_other;\n')
        a=unit('Misleading.gen.cpp',[normal,generated]);b=unit('Plain.cpp',[other])
        members={a['file']:[str(normal),str(generated)],b['file']:[str(other)]}
        result=produce([a,b],members)
        assert not result['candidates'] and result['retained_entries']==[a,b]
        assert result['rejections'][0]['entry_index']==0 and 'mixed' in result['rejections'][0]['reason']
        duplicate=produce([a,b],{a['file']:[str(normal)],b['file']:[str(normal)]})
        assert not duplicate['candidates'] and duplicate['retained_entries']==[a,b]
    else:
        raise AssertionError('unknown fixture '+operation)
    print(json.dumps({'operation':operation,'status':'passed'}))
]=]

local function run_fixture(operation, clangd)
  local python = vim.fn.exepath("python")
  if python == "" then python = vim.fn.exepath("python3") end
  if python == "" then
    t.skip("ordered Unity Python fixture", "Python unavailable", { native = clangd ~= nil })
    return
  end
  local script = vim.fn.tempname() .. "_ordered_unity.py"
  local stream = assert(io.open(script, "wb"))
  stream:write(fixture)
  stream:close()
  local result = vim.system({ python, "-B", "-I", script,
    vim.fn.stdpath("config") .. "/tools/cdb_ordered_unity.py", operation, clangd or "" }, { text = true }):wait()
  pcall(vim.fn.delete, script)
  t.assert_eq(result.code, 0, (result.stderr or "") .. (result.stdout or ""))
end

t.describe("ordered Unity candidate production without admission", function()
  t.it("preserves unsupported Definitions and response inputs as original commands", function()
    run_fixture("unsupported")
  end)
  t.it("respects both budgets, complete ordered compiler contexts and exact/shader passthrough", function()
    run_fixture("budgets_contexts")
  end)
  t.it("keeps stable artifacts unchanged and preserves previous generations after header changes", function()
    run_fixture("idempotence")
  end)
  t.it("never merges differing feature values, explicit undef/absence or nonempty API replacements", function()
    run_fixture("definition_contexts")
  end)
  t.it("classifies actual generated members and rejects ambiguous overlapping membership", function()
    run_fixture("mixed_and_rejections")
  end)
  local discovered = require("utils.platform").resolve_tool({ name = "clangd", env = { "UE_CLANGD" },
    config_candidates = require("utils.ue_goto.semantic_sidecar_libclang").discover_clangd_candidates() })
  if not discovered.ok then
    t.skip("ordered Unity native regressions", discovered.reason, { native = true })
    return
  end
  t.it("keeps native implementation reference targets unchanged while merging each source class separately", function()
    run_fixture("specialization", discovered.path)
  end)
  t.it("preserves native PCH-then-Definitions values and isolates all touched macros across members", function()
    run_fixture("macro_order", discovered.path)
  end)
end)
