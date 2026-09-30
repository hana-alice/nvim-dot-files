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
