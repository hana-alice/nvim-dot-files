local t = require("tests.harness")
t.bootstrap()

local fixture = [=[
import copy, importlib.util, json, os, pathlib, subprocess, sys, tempfile
from unittest.mock import patch
tool, operation = sys.argv[1:]
sys.path.insert(0, str(pathlib.Path(tool).parent))
spec = importlib.util.spec_from_file_location('generated_unity', tool)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
from build_hot_super_unity_cdb import portable_member_path, rewritten_arguments
with tempfile.TemporaryDirectory(prefix='generated_unity_') as temporary:
    root = pathlib.Path(temporary).resolve()
    output = root / 'output'
    marker = '// Compiler-authored UBT unity membership; copied into nvim cache.\n'
    def write(name, text='// source\n'):
        path = root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding='utf-8')
        return path
    def entry(source, *options):
        return {'directory': str(root), 'file': str(source),
                'arguments': ['clang++', '-std=c++17', *options, '-c', str(source)]}
    def unit(name, size=1, suffix='.gen.cpp'):
        members = [write('Inc/Module/' + name + str(i) + suffix) for i in range(size)]
        path = write('SuperUnity.UBT.' + name + '.cpp', marker + ''.join(
            '#include "' + p.as_posix() + '"\n' for p in members))
        value = entry(path)
        value.update(nvim_ue_members=[portable_member_path(str(p)) for p in members],
                     nvim_ue_module_root='Source/Module')
        return value
    def produce(entries, **kwargs):
        before = copy.deepcopy(entries)
        with patch.object(subprocess, 'Popen', side_effect=AssertionError('generation must not run native')):
            result, metrics = module.build_generated_batches(entries, output, **kwargs)
        assert entries == before
        assert metrics['input_entries'] == len(entries) and metrics['output_entries'] == len(result)
        return result, metrics
    if operation == 'merge':
        a,b,c = unit('a',2),unit('b'),unit('c')
        a['arguments'] += ['-o', 'a.o', '-MD', '-MF', 'a.d']
        b['arguments'] += ['-o', 'b.o', '-MMD', '-MFb.d']
        result, metrics = produce([a,b,c])
        assert len(result) == 1 and metrics['secondary_groups'] == 1 and metrics['merged_originals'] == 3
        candidate = result[0]
        assert candidate['nvim_ue_generated_originals'] == [a,b,c]
        assert candidate['nvim_ue_members'] == a['nvim_ue_members']+b['nvim_ue_members']+c['nvim_ue_members']
        assert candidate['nvim_ue_module_root'] == a['nvim_ue_module_root']
        assert candidate['arguments'] == rewritten_arguments(a,candidate['file'])
        text = pathlib.Path(candidate['file']).read_text()
        assert [line for line in text.splitlines() if line.startswith('#include')] == [
            '#include "' + pathlib.Path(e['file']).as_posix() + '"' for e in [a,b,c]]
        assert 'nvim_ue_batch' not in candidate and not list(output.glob('*receipt*'))
    elif operation == 'contexts':
        original_a,original_b = unit('a'),unit('b')
        pch = write('PCH.h'); other = write('Other.h')
        for left,right in [([],['-DVALUE=1']),(['-DVALUE=1','-UVALUE'],['-UVALUE','-DVALUE=1']),
                (['-include',str(pch)],['-include',str(other)]),
                (['-I','first','-I','second'],['-I','second','-I','first']),
                (['-include-pch',str(pch)],['-include-pch',str(other)]),
                ([],['-fno-exceptions'])]:
            a,b=copy.deepcopy([original_a,original_b]);a['arguments'][1:1]=left;b['arguments'][1:1]=right
            result,_=produce([a,b]);assert result==[a,b],(left,right,result)
        for field,value in [('directory',str(root/'other')),('nvim_ue_module_root','Source/Other')]:
            (root/'other').mkdir(exist_ok=True)
            a,b=copy.deepcopy([original_a,original_b]);b[field]=value
            assert produce([a,b])[0]==[a,b]
    elif operation == 'passthrough':
        a,b=unit('a'),unit('b')
        impl=unit('impl',suffix='.cpp');mixed=unit('mixed',2)
        ordinary=write('Inc/Module/ordinary.cpp')
        source=pathlib.Path(mixed['file']);source.write_text(source.read_text().replace(
            (root/'Inc/Module/mixed1.gen.cpp').as_posix(),ordinary.as_posix()))
        mixed['nvim_ue_members'][1]=portable_member_path(str(ordinary))
        exact=entry(write('Exact.cpp'));shader=entry(write('Shader.usf'))
        entries=[impl,a,exact,mixed,b,shader]
        result,_=produce(entries)
        assert result[0]==impl and result[2:]==[exact,mixed,shader]
        assert result[1]['nvim_ue_generated_originals']==[a,b]
    elif operation == 'rejections':
        a,b=unit('a',2),unit('b')
        raw=pathlib.Path(a['file']).read_text()
        for change in [lambda e:e.pop('nvim_ue_members'),
                lambda e:e.update(nvim_ue_members=list(reversed(e['nvim_ue_members']))),
                lambda e:e.update(arguments=e['arguments']+['@unknown.rsp']),
                lambda e:e.update(arguments=e['arguments']+['--config=unknown.cfg']),
                lambda e:e.update(arguments=e['arguments']+['-ivfsoverlay','overlay.yaml']),
                lambda e:e.update(arguments=e['arguments']+[e['file']]),
                lambda e:e.update(arguments=['clang++','-c','missing.cpp']),
                lambda e:e.update(directory=23),
                lambda e:e.update(arguments=None,command='clang++ source.cpp')]:
            bad=copy.deepcopy(a);change(bad)
            assert produce([bad,b])[0]==[bad,b]
        for text in [raw.replace(marker,'// arbitrary wrapper\n'),raw+'#define LEAK 1\n',
                raw.replace('#include "','#include <',1),raw.replace('a0.gen.cpp','missing.gen.cpp')]:
            pathlib.Path(a['file']).write_text(text)
            assert produce([a,b])[0]==[a,b]
        pathlib.Path(a['file']).write_text(raw)
        assert produce([a,a,b])[0]==[a,a,b]
        duplicate=unit('duplicate')
        pathlib.Path(duplicate['file']).write_text(raw)
        duplicate['nvim_ue_members']=a['nvim_ue_members'][:]
        assert produce([a,duplicate,b])[0]==[a,duplicate,b]
        exact=entry(root/'Inc/Module/a0.gen.cpp')
        assert produce([a,b,exact])[0]==[a,b,exact]
        exact['file']='Inc/Module/a0.gen.cpp'
        exact['arguments'][-1]=exact['file']
        assert produce([a,b,exact])[0]==[a,b,exact]
        unknown=entry(write('Unknown.cpp',raw))
        unknown['nvim_ue_members']=a['nvim_ue_members'][:]
        assert produce([a,b,unknown])[0]==[a,b,unknown]
    elif operation in ('owned_overlay', 'overlay_rejections'):
        sys.path.insert(0,str(pathlib.Path(tool).resolve().parents[1]/'lua/workarounds/clangd'))
        import header_path_case
        assert header_path_case.IS_WINDOWS, 'owned overlay generation requires the actual Windows host'
        a,b=unit('a'),unit('b')
        header=write('Header.h','struct HeaderValue {};\n')
        for value in [a,b]: value['arguments'][1:1]=['-I',str(root)]
        cdb=write('compile_commands.json',json.dumps([a,b]))
        policy=header_path_case.apply_policy(cdb,'clangd version 22.1.5')
        overlay=pathlib.Path(policy['overlay'])
        entries=json.loads(cdb.read_text())
        assert all('-ivfsoverlay' in value['arguments'] for value in entries)
        original_bytes=overlay.read_bytes()
        if operation == 'owned_overlay':
            with patch.object(header_path_case,'validate_owned_overlay',
                              wraps=header_path_case.validate_owned_overlay) as validate:
                result,metrics=produce(entries)
                assert validate.call_count==1, 'same overlay was fully validated per TU'
            assert metrics['secondary_groups']==1 and len(result)==1
            candidate=result[0]
            assert candidate['nvim_ue_generated_originals']==entries
            assert candidate['arguments']==rewritten_arguments(entries[0],candidate['file'])
            assert candidate['arguments'].count('-ivfsoverlay')==1
            position=candidate['arguments'].index('-ivfsoverlay')
            assert candidate['arguments'][position+1]==str(overlay)
            assert overlay.read_bytes()==original_bytes
            # A replacement during original collection must invalidate the
            # cached approval before any candidate can be selected.
            read_text=pathlib.Path.read_text
            def change_before_second(path,*args,**kwargs):
                if path==pathlib.Path(entries[1]['file']): overlay.write_bytes(original_bytes+b' ')
                return read_text(path,*args,**kwargs)
            with patch.object(pathlib.Path,'read_text',change_before_second):
                assert produce(entries)[0]==entries
        else:
            foreign=write('ThirdParty.json',original_bytes.decode())
            for options in [['-ivfsoverlay',str(foreign)],
                            ['-ivfsoverlay='+str(overlay)],
                            ['-ivfsoverlay'+str(overlay)],
                            ['-ivfsoverlay'],
                            ['-Xclang','-ivfsoverlay',str(overlay)],
                            ['-Xclang=-ivfsoverlay','-Xclang='+str(overlay)],
                            ['-vfsoverlay',str(overlay)],
                            ['/clang:-ivfsoverlay','/clang:'+str(overlay)],
                            ['--','-ivfsoverlay',str(overlay)],
                            ['-ivfsoverlay',str(overlay),'-ivfsoverlay',str(overlay)]]:
                changed=copy.deepcopy([a,b])
                for value in changed: value['arguments']+=options
                assert produce(changed)[0]==changed, options
            decoded=json.loads(original_bytes)
            decoded['roots'][0]['external-contents']=str(header)
            overlay.write_text(json.dumps(decoded))
            assert produce(entries)[0]==entries, 'tampered owned overlay was accepted'
    elif operation == 'budgets_idempotence':
        entries=[unit(str(i),size) for i,size in enumerate([2,1,2,1,4])]
        result,metrics=produce(entries,max_originals=2,max_sources=3)
        assert len(result)==3 and result[-1]==entries[-1] and metrics['secondary_groups']==2
        assert [len(e['nvim_ue_members']) for e in result]==[3,3,4]
        assert result[0]['nvim_ue_generated_originals']==entries[:2]
        assert result[1]['nvim_ue_generated_originals']==entries[2:4]
        paths=[pathlib.Path(e['file']) for e in result[:2]]
        for path in paths: os.utime(path,ns=(1_000_000_000,1_000_000_000))
        stamps=[p.stat().st_mtime_ns for p in paths];contents=[p.read_bytes() for p in paths]
        again,_=produce(entries,max_originals=2,max_sources=3)
        assert again==result and [p.stat().st_mtime_ns for p in paths]==stamps
        assert [p.read_bytes() for p in paths]==contents
        assert produce(entries,max_originals=1)[0]==entries
        changed=copy.deepcopy(entries);changed[0]['arguments'][1:1]=['-DCHANGED=1']
        produce(changed,max_originals=2,max_sources=3)
        assert [p.read_bytes() for p in paths]==contents
        for kwargs in [{'max_originals':0},{'max_sources':0},{'max_originals':1.5}]:
            try: produce(entries,**kwargs)
            except ValueError: pass
            else: raise AssertionError('invalid budget accepted')
    else: raise AssertionError(operation)
    print(json.dumps({'operation':operation,'status':'passed'}))
]=]

local function run_fixture(operation)
  local python = vim.fn.exepath("python")
  if python == "" then python = vim.fn.exepath("python3") end
  if python == "" then
    t.skip("generated SuperUnity producer", "Python unavailable")
    return
  end
  local script = vim.fn.tempname() .. "_generated_unity.py"
  local stream = assert(io.open(script, "wb"))
  stream:write(fixture)
  stream:close()
  local result = vim.system({ python, "-B", "-I", script,
    vim.fn.stdpath("config") .. "/tools/build_super_unity_cdb.py", operation }, { text = true }):wait()
  pcall(vim.fn.delete, script)
  t.assert_eq(result.code, 0, (result.stderr or "") .. (result.stdout or ""))
end

local secondary_fixture = [=[
import copy, importlib.util, json, os, pathlib, subprocess, sys, tempfile
from unittest.mock import patch
tool, operation = sys.argv[1:]
spec = importlib.util.spec_from_file_location('hot_unity', tool)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
with tempfile.TemporaryDirectory(prefix='tier1_chunks_') as temporary:
    root = pathlib.Path(temporary).resolve()
    baseline = 393216
    def unit(name, sizes=(1,), kinds=None, module_name='Sample', options=(), member_names=None):
        members = []
        kinds = kinds or ['src'] * len(sizes)
        for index, (size, kind) in enumerate(zip(sizes, kinds)):
            suffix = '.gen.cpp' if kind == 'gen' else '.cpp'
            member_name = member_names[index] if member_names is not None else name + str(index) + suffix
            member = root / 'Source/Runtime' / module_name / 'Private' / member_name
            member.parent.mkdir(parents=True, exist_ok=True)
            with member.open('wb') as stream: stream.truncate(size)
            members.append(member)
        wrapper = root / ('SuperUnity.UBT.' + name + '.cpp')
        wrapper.write_text('// Compiler-authored UBT unity membership; copied into nvim cache.\n'
            + ''.join('#include "' + member.as_posix() + '"\n' for member in members), encoding='utf-8')
        return {'file': str(wrapper), 'directory': str(root),
            'arguments': ['clang++', '-std=c++17', *options, '-c', str(wrapper)],
            'nvim_ue_members': [module.portable_member_path(str(member)) for member in members],
            'nvim_ue_module_root': 'Source/Runtime/' + module_name}
    def plan(entries, **kwargs):
        before = copy.deepcopy(entries)
        planner = module.strict_unity_chunks if kwargs.pop('strict', False) else module.secondary_unity_chunks
        with patch.object(subprocess, 'Popen', side_effect=AssertionError('chunk planning must not run native')):
            chunks = planner(entries, **kwargs)
        assert entries == before, 'planning mutated original commands or membership'
        assert len([i for chunk in chunks for i in chunk]) == len(set(i for chunk in chunks for i in chunk))
        return chunks
    with patch.dict(os.environ, {}, clear=False):
        os.environ.pop('NVIM_UE_SUPER_UNITY_BUDGET_FACTOR', None)
        if operation in ('triple_key', 'noclass_unchanged'):
            entries = [unit('g0', kinds=['gen']), unit('s0'),
                unit('m0', (1, 1), ['gen', 'src']),
                unit('ctx0', kinds=['gen'], options=['-DVALUE=1']),
                unit('other0', kinds=['gen'], module_name='Other'),
                unit('g1', kinds=['gen']), unit('s1'),
                unit('m1', (1, 1), ['src', 'gen']),
                unit('ctx1', kinds=['gen'], options=['-DVALUE=1']),
                unit('other1', kinds=['gen'], module_name='Other')]
            if operation == 'triple_key':
                assert plan(entries) == [[0, 5], [1, 6], [2, 7], [3, 8], [4, 9]]
            else:
                assert plan(entries, split_member_classes=False) == [[0, 1, 2, 5, 6, 7], [3, 8], [4, 9]]
                assert plan(entries, split_member_classes=False, max_unities=3) == [
                    [0, 1, 2], [3, 8], [4, 9], [5, 6, 7]]
        elif operation == 'noclass_same_stem':
            # The existing wrapper-size parser accepts .cpp only. Exercise
            # .cc/.cxx stem recognition directly without changing that policy.
            assert module._member_stems([
                r'D:\\Source\\Mixed\\Alpha.CPP', '/different/ALPHA.gen.CPP',
                '/source/Beta.CC', '/generated/beta.GEN.cpp', '/source/Gamma.cXx',
                '/ignored/Header.h', '/ignored/Other.c']) == ({'alpha', 'beta', 'gamma'}, {'alpha', 'beta'})
            source = unit('same_source', member_names=['Source/Alpha.CPP'])
            generated = unit('same_generated', kinds=['gen'], member_names=['Inc/aLpHa.GeN.CpP'])
            safe_source, safe_generated = unit('safe_source'), unit('safe_generated', kinds=['gen'])
            for entries in ([source, safe_source, generated, safe_generated],
                            [generated, safe_generated, source, safe_source]):
                assert plan(entries, split_member_classes=False) == [[0, 1, 2, 3]], \
                    'same-stem avoidance must remain opt-in'
                assert plan(entries, split_member_classes=False, avoid_same_stem_pairs=True) == [[0, 1], [2, 3]]
                assert plan([entries[0], entries[2]], split_member_classes=False, avoid_same_stem_pairs=True) == []
            # A later member of either indivisible UBT can cause the conflict.
            multi_source = unit('multi_source', (1, 1), member_names=['Left/First.cpp', 'Left/Second.cpp'])
            multi_generated = unit('multi_generated', (1, 1), ['gen', 'gen'],
                member_names=['Right/Other.gen.cpp', 'Right/sEcOnD.gen.cpp'])
            for entries in ([multi_source, safe_source, multi_generated, safe_generated],
                            [multi_generated, safe_generated, multi_source, safe_source]):
                assert plan(entries, split_member_classes=False, avoid_same_stem_pairs=True) == [[0, 1], [2, 3]], entries
                assert all(len(entries[index]['nvim_ue_members']) == 2 for index in (0, 2))
        elif operation == 'noclass_stem_boundaries':
            names = ['X.cpp', 'A.cpp', 'x.gen.cpp', 'B.cpp', 'Y.cpp', 'y.gen.cpp', 'C.cpp']
            entries = [unit('limit' + str(index), (baseline // 2,), member_names=[name])
                for index, name in enumerate(names)]
            # A conflict closes the current block; subsequent candidates retain
            # original order, byte limits, member limits and UBT count limits.
            assert plan(entries, split_member_classes=False) == [list(range(7))]
            assert plan(entries, split_member_classes=False, avoid_same_stem_pairs=True) == [[0, 1], [2, 3, 4], [5, 6]]
            for limits in ({'budget_factor': 1}, {'max_unities': 2}, {'max_sources': 2}):
                assert plan(entries, split_member_classes=False, avoid_same_stem_pairs=True, **limits) == [[0, 1], [2, 3], [5, 6]], limits
            assert plan(entries, split_member_classes=False, avoid_same_stem_pairs=True, max_unities=1) == []
            oversized = unit('too_large', (baseline + 1,), member_names=['Oversized/X.gen.cpp'])
            assert plan([entries[0], oversized, entries[2], entries[3]],
                split_member_classes=False, avoid_same_stem_pairs=True, budget_factor=1) == [[2, 3]]
        elif operation == 'split_strict_stem_unchanged':
            names = ['X.cpp', 'x.gen.cpp', 'A.cpp', 'B.gen.cpp', 'Y.cpp', 'y.gen.cpp']
            entries = [unit('unchanged' + str(index), member_names=[name]) for index, name in enumerate(names)]
            assert plan(entries, split_member_classes=True, max_unities=2) == [[0, 2], [1, 3]]
            assert plan(entries, strict=True, max_unities=2) == [[0, 2], [1, 3], [4, 5]]
            assert plan(entries[4:], split_member_classes=True) == []
            assert plan(entries[4:], strict=True) == [[0, 1]], 'strict residual policy must remain unchanged'
            mixed = [unit('mixed_left', (1, 1), member_names=['Mixed/X.cpp', 'Mixed/A.gen.cpp']),
                unit('mixed_right', (1, 1), member_names=['Other/X.gen.cpp', 'Other/B.cpp'])]
            assert plan(mixed, split_member_classes=True) == [[0, 1]], 'mixed class packing must remain unchanged'
            assert plan(mixed, strict=True) == [[0, 1]]
        elif operation == 'byte_budget':
            entries = [unit(str(i), (size,)) for i, size in enumerate([200000, 190000, 5000, 200000])]
            assert plan(entries, budget_factor=1) == [[0, 1], [2, 3]]
            exact = [unit('edge' + str(i), (baseline // 2,)) for i in range(3)]
            assert plan(exact, budget_factor=1) == [[0, 1]], 'the exact byte limit is inclusive'
            # The budget is the sum of source bytes, rather than wrapper bytes or member count.
            multi = [unit('many', (1,) * 81), unit('one')]
            assert plan(multi, budget_factor=1) == [[0, 1]], 'legacy 80-source default leaked into Tier 1'
            assert plan([unit('sum0', (100000, 100000)), unit('sum1', (100000, 100000))],
                budget_factor=1) == [], 'all member bytes must count'
        elif operation == 'factor_configuration':
            entries = [unit('a', (baseline,)), unit('b', (baseline,))]
            assert plan([unit('default0', (4 * baseline,)), unit('default1', (4 * baseline,))]) == [[0, 1]], \
                'default factor must permit exactly eight UBT byte budgets'
            assert plan([unit('too0', (5 * baseline,)), unit('too1', (4 * baseline,))]) == [], \
                'the default factor must not exceed eight'
            os.environ['NVIM_UE_SUPER_UNITY_BUDGET_FACTOR'] = '1'
            assert plan(entries) == []
            assert plan(entries, budget_factor=2) == [[0, 1]], 'explicit factor must override environment'
            os.environ['NVIM_UE_SUPER_UNITY_BUDGET_FACTOR'] = '2'
            assert plan(entries) == [[0, 1]]
        elif operation == 'oversized_single':
            entries = [unit('oversized', (baseline + 1,)), unit('small0'), unit('small1')]
            assert plan(entries, budget_factor=1) == [[1, 2]], 'oversized original must stay indivisible'
            assert plan(entries[:1], budget_factor=1) == []
            assert plan(entries[1:2], budget_factor=1) == [], 'single UBT blocks must not be emitted'
            assert plan(entries, budget_factor=1, max_unities=1) == []
        elif operation == 'stable_order':
            entries = [unit(str(i), module_name=('Sample' if i % 2 == 0 else 'Other')) for i in range(10)]
            expected = [[0, 2], [1, 3], [4, 6], [5, 7]]
            assert plan(entries, max_unities=2) == expected
            assert plan(entries, max_unities=2) == expected, 'repeated planning changed source order'
            assert all(chunk == sorted(chunk) for chunk in expected)
        elif operation == 'unknown_size':
            unknown, a, b = unit('unknown'), unit('a'), unit('b')
            missing = next((root / 'Source').rglob('unknown0.cpp'))
            missing.unlink()
            diagnostics = []
            assert plan([unknown, a, b], budget_factor=1, diagnostics=diagnostics) == [[1, 2]]
            assert len(diagnostics) == 1, diagnostics
            record = diagnostics[0]
            assert record['reason'] == 'member-size-unavailable' and record['entry_index'] == 0, record
            assert record['assumed_bytes'] > baseline and record['member'], record
            assert record['file'] == unknown['file'], record
        elif operation == 'strict_leftovers':
            six = [unit('source', (1, 1, 1)), unit('generated', (1, 1, 1), ['gen'] * 3)]
            assert plan(six) == [], 'Tier 1 must retain its member-class boundary'
            assert plan(six, strict=True) == [[0, 1]]
            entries = [unit(str(i), kinds=['src' if i % 2 == 0 else 'gen']) for i in range(6)]
            existing = [[0, 2], [1, 3]]
            assert plan(entries, max_unities=2) == existing
            assert plan(entries, max_unities=2, split_member_classes=False) == [[0, 1], [2, 3], [4, 5]]
            assert plan(entries, strict=True, max_unities=2) == existing + [[4, 5]], \
                'strict planning must retain established groups before consuming only unclaimed originals'
        elif operation == 'strict_boundaries':
            source, generated = unit('src'), unit('gen', kinds=['gen'])
            assert plan([source, generated], strict=True) == [[0, 1]]
            changed_cwd = dict(generated, directory=str(root / 'other-cwd'))
            changed_flags = dict(generated, arguments=generated['arguments'] + ['-DOTHER_CONTEXT=1'])
            changed_module = dict(generated, nvim_ue_module_root='Source/Runtime/Other')
            for changed in (changed_cwd, changed_flags, changed_module):
                assert plan([source, changed], strict=True) == [], changed
            assert plan([source, generated], strict=True, max_unities=1) == []
            multi = [unit('manysrc', (1,) * 40), unit('manygen', (1,) * 41, ['gen'] * 41)]
            assert plan(multi, strict=True, max_sources=80) == [], 'strict planning must preserve its caller member limit'
            assert plan(multi, strict=True, max_sources=81) == [[0, 1]]
            assert plan([source, generated], strict=True, max_sources=1) == []
            edge = [unit('edgesrc', (baseline // 2,)), unit('edgegen', (baseline // 2,), ['gen'])]
            assert plan(edge, strict=True, budget_factor=1) == [[0, 1]], 'byte limit is inclusive'
            too_large = unit('oversizegen', (baseline // 2 + 1,), ['gen'])
            assert plan([edge[0], too_large], strict=True, budget_factor=1) == []
        elif operation == 'strict_residual_closure':
            entries = [unit('a', (2 * baseline,)), unit('b', (baseline,), ['gen']),
                unit('c', (3 * baseline,)), unit('d', (baseline,)), unit('e', (baseline,))]
            assert plan(entries, budget_factor=4) == [[2, 3]]
            chunks = plan(entries, strict=True, budget_factor=4)
            assert chunks == [[2, 3], [0, 4]], chunks
            assert 1 not in [index for chunk in chunks for index in chunk], 'generated singleton must retain its original UBT'
            for chunk in chunks:
                selected = [entries[index] for index in chunk]
                assert plan(selected, strict=True, budget_factor=4) == [list(range(len(selected)))], \
                    'every selected group must pass the worker independent regrouping guard'
        else: raise AssertionError(operation)
    print(json.dumps({'operation': operation, 'status': 'passed'}))
]=]

local function run_secondary_fixture(operation)
  local python = vim.fn.exepath("python")
  if python == "" then python = vim.fn.exepath("python3") end
  if python == "" then
    t.skip("Tier 1 secondary chunk planner", "Python unavailable")
    return
  end
  local script = vim.fn.tempname() .. "_tier1_chunks.py"
  local stream = assert(io.open(script, "wb"))
  stream:write(secondary_fixture)
  stream:close()
  local result = vim.system({ python, "-B", "-I", script,
    vim.fn.stdpath("config") .. "/tools/build_hot_super_unity_cdb.py", operation }, { text = true }):wait()
  pcall(vim.fn.delete, script)
  t.assert_eq(result.code, 0, (result.stderr or "") .. (result.stdout or ""))
end

t.describe("Tier 1 byte-budget secondary UBT planning", function()
  t.it("isolates generated, source and mixed members by module and full compiler context", function()
    run_secondary_fixture("triple_key")
  end)
  t.it("uses inclusive total member bytes without inheriting the old source-count budget", function()
    run_secondary_fixture("byte_budget")
  end)
  t.it("honors the default, environment and explicit byte-budget factor precedence", function()
    run_secondary_fixture("factor_configuration")
  end)
  t.it("preserves indivisible oversized originals and does not emit single UBT blocks", function()
    run_secondary_fixture("oversized_single")
  end)
  t.it("packs interleaved buckets in stable CDB order with the UBT count limit", function()
    run_secondary_fixture("stable_order")
  end)
  t.it("keeps unreadable members outside batches and reports the conservative byte estimate", function()
    run_secondary_fixture("unknown_size")
  end)
end)

t.describe("Tier 1 optional no-class same-stem exclusion", function()
  for _, operation in ipairs({ "noclass_same_stem", "noclass_stem_boundaries", "noclass_unchanged", "split_strict_stem_unchanged" }) do
    t.it(operation, function() run_secondary_fixture(operation) end)
  end
end)

t.describe("strict secondary UBT planning", function()
  t.it("retains established class groups and adds only compatible unclaimed source/generated groups", function()
    run_secondary_fixture("strict_leftovers")
  end)
  t.it("preserves compiler contexts and indivisible byte, member and UBT limits across classes", function()
    run_secondary_fixture("strict_boundaries")
  end)
  t.it("exhausts newly compatible same-class leftovers before forming independently regroupable batches", function()
    run_secondary_fixture("strict_residual_closure")
  end)
end)

t.describe("generated-only secondary UBT batches", function()
  t.it("merges verified generated wrappers while preserving complete originals and member order", function()
    run_fixture("merge")
  end)
  t.it("preserves every compiler context difference including ordered flags, includes and PCH", function()
    run_fixture("contexts")
  end)
  t.it("keeps implementation, mixed, exact and shader entries intact", function()
    run_fixture("passthrough")
  end)
  t.it("rejects damaged, unsupported, duplicate and overlapping inputs without dropping them", function()
    run_fixture("rejections")
  end)
  t.it("respects indivisible budgets and preserves bytes, timestamps and earlier outputs", function()
    run_fixture("budgets_idempotence")
  end)
  if vim.fn.has("win32") == 1 then
    t.it("keeps a validated owned case overlay and caches its byte-bound validation per run", function()
      run_fixture("owned_overlay")
    end)
    t.it("retains originals for third-party, modified or unsupported VFS overlays", function()
      run_fixture("overlay_rejections")
    end)
  else
    t.skip("owned case overlay generated batching", "requires actual Windows overlay production")
  end
end)
