local t = require("tests.harness")
t.bootstrap()

local fixture = [=[
import contextlib, copy, importlib.util, json, os, pathlib, subprocess, sys, tempfile, time
from unittest.mock import patch
tool, clangd, operation = sys.argv[1:]
spec = importlib.util.spec_from_file_location('verified_batch', tool)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
def cached_only(entries, directory, server_profile=None, max_group=2):
    with patch.object(module, '_prove', side_effect=AssertionError('cache-only proof forbidden')) as proofs, \
         patch.object(module, 'compare_graphs', side_effect=AssertionError('cache-only graph replay forbidden')) as graphs, \
         patch.object(subprocess, 'Popen', side_effect=AssertionError('cache-only process forbidden')) as processes:
        result = module.accelerate(entries, directory, clangd, max_group=max_group, timeout=30,
                                   verify_missing=False, server_profile=server_profile)
        assert proofs.call_count == graphs.call_count == processes.call_count == 0
        assert all(record['run_metrics'] == [] for record in result[1]['groups'])
        return result
with tempfile.TemporaryDirectory(prefix='verified_batch_') as temporary, contextlib.ExitStack() as stack:
    root = pathlib.Path(temporary).resolve()
    if operation == 'intern_records':
        from clangd_index_graph import VERSION
        uri = (root / 'shared.h').as_uri()
        source_record = {'digest': '1234567890abcdef', 'flags': 0, 'direct_includes': []}
        record = {'source': source_record, 'symbols': [], 'relations': [], 'refs': [{
            'symbol_id': 'a' * 16, 'container': '0' * 16, 'kind': 4,
            'location': {'uri': uri, 'start': [1, 2], 'end': [1, 3]}}]}
        first, second, changed = [{uri: copy.deepcopy(record)} for _ in range(3)]
        changed[uri]['refs'][0]['symbol_id'] = 'b' * 16
        before = [module._json(value) for value in (first, second, changed)]
        pool = {}
        # Even an adversarial hash collision must compare exact record content.
        with patch.object(module, 'hash', return_value=0, create=True):
            for graph in (first, second, changed):
                assert module._intern_graph_records(graph, pool) is graph
        assert first is not second and first[uri] is second[uri]
        assert changed[uri] is not first[uri]
        assert len(pool[(uri, 0)]) == 2
        pool.clear()
        assert module.compare_graphs([first, second], first)['accepted']
        rejected = module.compare_graphs([first, changed], first)
        assert not rejected['accepted'] and rejected['reason'] == 'references-removed-or-retargeted', rejected
        assert [module._json(value) for value in (first, second, changed)] == before
        shards = [{'version': VERSION, 'sources': {uri: copy.deepcopy(source_record)},
                   'symbols': [], 'relations': [], 'refs': copy.deepcopy(record['refs']), 'command': None}]
        result = {'background_compile_success': True, 'missing_main_shards': [], 'shards': ['independent.idx']}
        pool = {}
        with patch.object(module, 'read_shard', side_effect=lambda _: copy.deepcopy(shards[0])):
            a = module._graph_result(result, root / 'trigger.cpp', record_pool=pool)
            b = module._graph_result(result, root / 'trigger.cpp', record_pool=pool)
        assert a is not b and a[uri] is b[uri]
        assert module._json(a) == module._json(module.canonical_file_graph(shards))
        print(json.dumps({'operation': operation, 'exact_record_sharing': True,
                          'hash_collision_preserves_different_binding': True, 'serialized_graphs_unchanged': True}))
        sys.exit(0)
    if operation == 'write_race':
        import ctypes
        from ctypes import wintypes
        kernel = ctypes.WinDLL('kernel32', use_last_error=True)
        kernel.CreateFileW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD,
            ctypes.c_void_p, wintypes.DWORD, wintypes.DWORD, wintypes.HANDLE]
        kernel.CreateFileW.restype = wintypes.HANDLE
        kernel.CloseHandle.argtypes = [wintypes.HANDLE]
        helper = root / 'racing_writer.py'
        helper.write_text('''import importlib.util, json, os, pathlib, sys, time
tool, directory = sys.argv[1:]
root = pathlib.Path(directory)
spec = importlib.util.spec_from_file_location('batch', tool)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
replace = os.replace
def gated_replace(source, target):
    (root / 'ready').write_text('ready')
    deadline = time.monotonic() + 15
    while not (root / 'release').exists():
        if time.monotonic() >= deadline:
            raise TimeoutError('race fixture publication gate')
        time.sleep(0.01)
    try:
        return replace(source, target)
    except OSError as error:
        (root / 'sharing-error.json').write_text(json.dumps({'winerror': error.winerror}))
        raise
module.os.replace = gated_replace
module._write(root / 'snapshot.h', b'certified snapshot bytes')
''', encoding='utf-8')
        for identical in (True, False):
            directory = root / ('same' if identical else 'different')
            directory.mkdir()
            child = subprocess.Popen([sys.executable, '-I', str(helper), tool, str(directory)],
                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                creationflags=subprocess.CREATE_NO_WINDOW | subprocess.IDLE_PRIORITY_CLASS)
            handle = None
            try:
                deadline = time.monotonic() + 15
                while not (directory / 'ready').exists():
                    assert child.poll() is None and time.monotonic() < deadline, 'writer never reached publication race'
                    time.sleep(0.01)
                target = directory / 'snapshot.h'
                published = b'certified snapshot bytes' if identical else b'different bytes must not be accepted'
                target.write_bytes(published)
                stamp = target.stat().st_mtime_ns
                # Allow readers like clangd, but deny delete/replace of the
                # winning writer's real Windows file until the loser returns.
                handle = kernel.CreateFileW(str(target), 0x80000000, 3, None, 3, 0x80, None)
                assert handle != ctypes.c_void_p(-1).value, ctypes.get_last_error()
                (directory / 'release').write_text('published and held open')
                stdout, stderr = child.communicate(timeout=20)
                assert json.loads((directory / 'sharing-error.json').read_text())['winerror'] in (5, 32)
                assert (child.returncode == 0) == identical, stderr.decode()
                assert target.read_bytes() == published and target.stat().st_mtime_ns == stamp
                if identical:
                    assert not list(directory.glob('*.tmp')), 'successful race must clean the losing process temporary'
            finally:
                if handle is not None and handle != ctypes.c_void_p(-1).value:
                    kernel.CloseHandle(handle)
                if child.poll() is None:
                    child.kill()
                    child.communicate()
        sys.exit(0)
    source = root / 'Source/Runtime/Sample/Private'
    source.mkdir(parents=True)
    include_root = root / 'Source/Runtime/Sample/Public'
    profile = None
    if operation == 'query_profile':
        compiler = pathlib.Path(clangd).with_name('clang++' + pathlib.Path(clangd).suffix)
        first, second, sysroot = root / 'first', root / 'second', root / 'sysroot'
        for directory in (first, second, sysroot):
            directory.mkdir()
        (first / 'Choice.h').write_text('#pragma once\nconstexpr int chosen = 1;\n')
        (second / 'Choice.h').write_text('#pragma once\nconstexpr int chosen = 2;\n')
        # The actual clang driver reports CPATH as -isystem. Clang then moves
        # the duplicate -I first directory after -I second, changing selection.
        os.environ['CPATH'] = str(first)
        profile = {'query_driver': compiler.as_posix(), 'launch_cwd': root.as_posix(), 'enable_config': False}
    if operation == 'environment':
        external = pathlib.Path(stack.enter_context(tempfile.TemporaryDirectory(prefix='verified_env_'))).resolve()
        for name in ('first', 'second'):
            (external / name).mkdir()
            (external / name / 'Environment.h').write_text('#pragma once\nconstexpr int environment_value = 7;\n')
        first_env = os.path.relpath(external / 'first', root)
        second_env = os.path.relpath(external / 'second', root)
        os.environ['CPATH'] = first_env
    if operation in ('aliases', 'owned_aliases'):
        (include_root / 'Misc').mkdir(parents=True)
        (include_root / 'HAL').mkdir()
        (include_root / 'HAL/Value.h').write_text('#pragma once\nconstexpr int value = 7;\n')
        (include_root / 'Misc/Entry.h').write_text('#pragma once\n#include "../HAL/Value.h"\n')
    bodies = {
        'intern_native': ['#include "Common.h"\nShared make' + str(i) + '() { return {}; }\n' for i in range(2)],
        'intern_contexts': ['int ' + name + '();\n#define CHOOSE ' + name
            + '\n#include "Common.h"\n#undef CHOOSE\nint ' + name + '() { return 1; }\n' for name in ('alpha', 'beta')],
        'distinct_identical': ['#define ITEM ' + name + '\n#include "' + header
            + '"\n#undef ITEM\n' + name + ' make' + name + '() { return {}; }\n'
            for name, header in (('Alpha', 'first.h'), ('Beta', 'second.h'))],
        'same_file_alias': ['#define ITEM ' + name + '\n#include "' + header
            + '"\n#undef ITEM\n' + name + ' make' + name + '() { return {}; }\n'
            for name, header in (('Alpha', 'first.h'), ('Beta', 'second.hpp'))],
        'symlink_alias': ['#define ITEM ' + name + '\n#include "' + header
            + '"\n#undef ITEM\n' + name + ' make' + name + '() { return {}; }\n'
            for name, header in (('Alpha', 'first.h'), ('Beta', 'second.hpp'))],
        'original_reuse': ['int member' + str(i) + '() { return ' + str(i) + '; }\n' for i in range(3)],
        'original_overlap': ['int choose(int) { return 1; }\n',
                             'int choose(double) { return 2; } int caller() { return choose(1); }\n',
                             'int gamma() { return 3; }\n'],
        'group_hints': ['int member' + str(i) + '() { return ' + str(i) + '; }\n' for i in range(5)],
        'pass': ['int alpha() { return 1; }\n', 'int beta() { return 2; }\n'],
        'conflict': ['static int value = 1; int alpha() { return value; }\n',
                     'static int value = 2; int beta() { return value; }\n'],
        'original_error': ['int alpha( { return 1; }\n', 'int beta() { return 2; }\n'],
        'overload': ['int choose(int) { return 1; }\n',
                     'int choose(double) { return 2; } int caller() { return choose(1); }\n'],
        'aliases': ['#include "Misc/Entry.h"\nint alpha() { return value; }\n',
                    '#include "Misc/Entry.h"\nint beta() { return value; }\n'],
        'environment': ['#include "Environment.h"\nint alpha() { return environment_value; }\n',
                        '#include "Environment.h"\nint beta() { return environment_value; }\n'],
        'query_profile': ['#include "Choice.h"\nint alpha() { return chosen; }\n',
                          '#include "Choice.h"\nint beta() { return chosen; }\n'],
        'template_arguments': ['struct ' + name + ''' {
  enum { Base = __COUNTER__ };
  template<int I, typename Dummy = void> struct Link {};
  template<typename Dummy> struct Link<__COUNTER__ - Base, Dummy> {};
};
''' for name in ('Alpha', 'Beta')],
    }.get('aliases' if operation == 'owned_aliases' else operation,
          ['int alpha() { return 1; }\n', 'int beta() { return 2; }\n'])
    entries = []
    for index, body in enumerate(bodies):
        member = source / ('Member' + str(index) + '.cpp')
        member.write_text(body, encoding='utf-8')
        wrapper = root / ('SuperUnity.UBT.' + str(index) + '.cpp')
        wrapper.write_text('// Compiler-authored UBT unity membership; copied into nvim cache.\n'
                           + '#include "' + member.as_posix() + '"\n', encoding='utf-8')
        entry = {'file': str(wrapper), 'directory': str(root),
            'arguments': [str(pathlib.Path(clangd).with_name('clang++' + pathlib.Path(clangd).suffix)),
                          '-std=c++17', '-c', str(wrapper)],
            'nvim_ue_members': [module.portable_member_path(str(member))],
            'nvim_ue_module_root': 'Source/Runtime/Sample'}
        if operation == 'contexts':
            entry['arguments'].insert(1, '-DVALUE=' + str(index))
        if operation in ('aliases', 'owned_aliases'):
            entry['arguments'].insert(1, '-I' + include_root.as_posix())
        if operation == 'query_profile':
            entry['arguments'][1:1] = ['--target=aarch64-none-linux-android23',
                '--sysroot=' + sysroot.as_posix(), '-I' + first.as_posix(), '-I' + second.as_posix()]
            entry.update(directory=root.as_posix(), file=wrapper.as_posix())
        entries.append(entry)
    exact = {'file': str(root / 'exact.cpp'), 'directory': str(root), 'arguments': ['clang++', 'exact.cpp']}
    shader = {'file': str(root / 'shader.ush'), 'directory': str(root), 'arguments': ['clang++', 'shader.ush']}
    entries += [exact, shader]
    if operation in ('owned_aliases', 'owned_system_header', 'owned_unmapped_system'):
        if operation in ('owned_system_header', 'owned_unmapped_system'):
            header = source/'sys/types.h'
            header.parent.mkdir()
            header.write_text('#pragma once\ntypedef int fixture_daddr_t;\n')
            expected_providers = {'fixture_daddr_t': ('<sys/types.h>', header.as_uri())}
            system_includes = ''
            if operation == 'owned_unmapped_system':
                system = root/'system/include'
                system.mkdir(parents=True)
                for filename, name in (('wchar.h','wcstoll_l'), ('unistd.h','sbrk')):
                    system_header = system/filename
                    system_header.write_text('#pragma once\nint '+name+'();\n')
                    system_includes += '#include "'+str(system_header)+'"\n'
                    expected_providers[name] = (system_header.as_uri(), system_header.as_uri())
                unused = source/'Unused.h'
                unused.write_text('// owned name outside the actual dependency closure\n')
            for i, name in enumerate(('alpha', 'beta')):
                (source/('Member'+str(i)+'.cpp')).write_text(
                    '#include <sys/types.h>\n'+system_includes+'fixture_daddr_t '+name+'() { return 1; }\n')
                entries[i]['arguments'].insert(1, '-I'+source.as_posix())
                if operation == 'owned_unmapped_system':
                    entries[i]['arguments'][1:1] = ['-isystem', str(system)]
            physical = [header]
            if operation == 'owned_unmapped_system': physical.append(unused)
        else:
            physical = [include_root/'Misc/Entry.h', include_root/'HAL/Value.h']
        if operation != 'owned_unmapped_system':
            physical += [source/('Member'+str(i)+'.cpp') for i in range(2)]
            physical += [pathlib.Path(e['file']) for e in entries[:2]]
        data = module._json({'version':0, 'case-sensitive':False, 'use-external-names':True,
            'fallthrough':True, 'roots':[{'type':'file', 'name':p.resolve().as_posix(),
                'external-contents':p.resolve().as_posix()} for p in physical]}).encode()
        overlay = root/'header-path-case'/('header-path-case.'+module._sha(data)+'.json')
        overlay.parent.mkdir()
        overlay.write_bytes(data)
        for e in entries[:2]: e['arguments'] += ['-ivfsoverlay', str(overlay)]
    if operation in ('owned_system_header', 'owned_unmapped_system'):
        admit, observed = module._admit, []
        freeze = module._freeze
        def preserve_previous_overlays(*args, **kwargs):
            candidate, files, identity = freeze(*args, **kwargs)
            argv = candidate['arguments']
            inner, outer = [pathlib.Path(argv[i+1]) for i, value in enumerate(argv) if value=='-ivfsoverlay']
            old_outer = outer.with_name('canonical.'+identity[:24]+'.json')
            old_inner = inner.with_name('overlay.'+identity[:24]+'.json')
            assert old_outer != outer and old_inner != inner
            legacy_outer = json.loads(outer.read_bytes())
            for item in legacy_outer['roots']:
                item['name'] = item['name'].replace('/', '\\')
                item['external-contents'] = item['name']
            legacy_inner = json.loads(inner.read_bytes())
            for item in legacy_inner['roots']:
                if item['name']==str(outer):
                    item.update(name=str(old_outer), **{'external-contents':str(old_outer)})
            old_outer.write_text(module._json(legacy_outer))
            old_inner.write_text(module._json(legacy_inner))
            bound = {p:(p.read_bytes(), p.stat().st_mtime_ns) for p in (old_inner, old_outer, inner, outer)}
            repeated = freeze(*args, **kwargs)
            assert repeated == (candidate, files, identity)
            assert all((p.read_bytes(), p.stat().st_mtime_ns)==state for p,state in bound.items())
            assert outer.name=='canonical.'+module._sha(outer.read_bytes())[:24]+'.json'
            assert inner.name=='overlay.'+module._sha(inner.read_bytes())[:24]+'.json'
            return repeated
        def canonical_provider(group, candidate, originals, graph, *args, **kwargs):
            for collected in originals+[graph]:
                for name, (provider, uri) in expected_providers.items():
                    symbols = [s for owned in collected.values() for s in owned['symbols'] if s['name']==name]
                    assert len(symbols)==1, symbols
                    headers = symbols[0]['include_headers']
                    assert headers == [{'header':provider, 'references':1, 'supported_directives':1}], (name, headers)
                    assert symbols[0]['canonical_declaration']['uri'] == uri
                    observed.append(headers)
            if operation == 'owned_unmapped_system':
                argv = candidate['arguments']
                outer = pathlib.Path([argv[i+1] for i,v in enumerate(argv) if v=='-ivfsoverlay'][-1])
                assert {r['name'] for r in json.loads(outer.read_bytes())['roots']} == {header.as_posix()}
            return admit(group, candidate, originals, graph, *args, **kwargs)
        with patch.object(module, '_admit', canonical_provider), \
                patch.object(module, '_freeze', preserve_previous_overlays):
            output, metrics = module.accelerate(entries, root/'proofs', clangd, max_group=2, timeout=30)
        assert metrics['batch_count']==1 and len(observed)==3*len(expected_providers), metrics
        print(json.dumps({'operation':operation, 'providers':observed, 'metrics':metrics}))
        sys.exit(0)
    if operation == 'owned_overlay':
        header = source / 'Header.h'
        header.write_text('#pragma once\nconstexpr int FrozenValue = 7;\nstruct CanonicalType {};\n')
        unused = root / 'unused-watch/Unused.h'
        unused.parent.mkdir()
        unused.write_text('// unrelated mapped input; never a compiler dependency\n')
        for i, name in enumerate(('alpha', 'beta')):
            (source / ('Member' + str(i) + '.cpp')).write_text(
                '#include "' + ('hEaDeR.h' if i == 0 else 'Header.h') + '"\n'
                'static_assert(FrozenValue == 7, "must read frozen bytes");\n'
                'int ' + name + '() { return FrozenValue; }\n')
        physical = [header, unused] + [source / ('Member'+str(i)+'.cpp') for i in range(2)]
        physical += [pathlib.Path(e['file']) for e in entries[:2]]
        overlay_raw = module._json({'version':0, 'case-sensitive':False, 'use-external-names':True,
            'fallthrough':True, 'roots':[{'type':'file', 'name':p.resolve().as_posix(),
                'external-contents':p.resolve().as_posix()} for p in physical]}).encode()
        overlay = root / 'header-path-case' / ('header-path-case.'+module._sha(overlay_raw)+'.json')
        overlay.parent.mkdir()
        overlay.write_bytes(overlay_raw)
        for e in entries[:2]: e['arguments'] += ['-ivfsoverlay', str(overlay)]
        read_bytes = pathlib.Path.read_bytes
        def dependency_reads_only(path):
            assert path.resolve() != unused.resolve(), 'unused mapped content must not be hashed'
            return read_bytes(path)
        policy = module._owned_overlay_policy()
        with patch.object(pathlib.Path, 'read_bytes', dependency_reads_only), \
                patch.object(policy, 'validate_owned_overlay', wraps=policy.validate_owned_overlay) as validated:
            output, metrics = module.accelerate(entries, root/'proofs', clangd, max_group=2, timeout=30)
            assert validated.call_count == 1, 'same overlay bytes require one physical validation per run'
        assert metrics['batch_count'] == 1, metrics
        candidate = output[0]
        assert str(overlay) not in candidate['arguments'], 'candidate must not carry the live overlay'
        receipt = json.loads(pathlib.Path(candidate['nvim_ue_batch_receipt']).read_bytes())
        assert all(str(overlay) in e['arguments'] for e in receipt['original_entries'])
        assert {'path':str(overlay), 'sha256':module._sha(overlay_raw)} in receipt['assets']
        assert not any(pathlib.Path(x['path']).resolve() == unused.resolve()
                       for x in receipt['assets'] + receipt['dependencies'])
        for malformed in [root/'unowned.json', root/'header-path-case'/('header-path-case.'+'0'*64+'.json')]:
            malformed.write_bytes(overlay_raw)
            changed = [dict(e, arguments=e['arguments'][:-1]+[str(malformed)]) for e in entries[:2]]
            with patch.object(subprocess, 'Popen', side_effect=AssertionError('unowned overlay must not compile')):
                rejected, failed = module.accelerate(changed, root/'proofs', clangd, max_group=2, timeout=30)
            assert rejected == changed and failed['batch_count'] == 0, failed
            malformed.unlink()
        record = json.loads(next((root/'proofs/receipts').glob('*.json')).read_bytes())
        assert str(unused.parent) in record['inventories'] or any(
            pathlib.Path(p) in unused.parents for p in record['inventories'])
        before = {p:read_bytes(p) for p in physical if p != unused}
        try:
            for p in before: p.write_text('#error live input escaped into frozen candidate\n')
            overlay.write_bytes(b'not even a valid live overlay any more')
            graph, native, _ = module._index([candidate], root/'proofs/frozen-readcheck', clangd, 30)
            assert native['background_compile_success']
            assert header.as_uri() in graph, graph.keys()
            assert any(s['name']=='CanonicalType' for s in graph[header.as_uri()]['symbols'])
            assert not any('snapshots' in uri or 'hEaDeR.h' in uri for uri in graph), list(graph)
        finally:
            for p, data in before.items(): p.write_bytes(data)
            overlay.write_bytes(overlay_raw)
        unused.write_text('// changed unrelated content without changing lookup names\n')
        with patch.object(pathlib.Path, 'read_bytes', dependency_reads_only), \
                patch.object(policy, 'validate_owned_overlay', wraps=policy.validate_owned_overlay) as validated:
            again, warm = cached_only(entries, root/'proofs')
            assert validated.call_count == 1
        assert again == output and warm['cache_hits'] == 1, warm
        stamp = overlay.stat()
        overlay.write_bytes(overlay_raw+b' ')
        os.utime(overlay, ns=(stamp.st_atime_ns, stamp.st_mtime_ns))
        assert cached_only(entries, root/'proofs')[0] == entries, 'overlay bytes invalidate reuse'
        overlay.write_bytes(overlay_raw)
        extra = unused.parent/'New.h'
        extra.write_text('// newly available lookup name\n')
        assert cached_only(entries, root/'proofs')[0] == entries, 'lookup names invalidate reuse'
        extra.unlink()
        escape = root/'Escape.h'
        escape.write_text('// live file outside the frozen closure\n')
        escaped = dict(candidate, arguments=candidate['arguments']+['-include',str(escape)])
        try:
            module._index([escaped], root/'proofs/no-live-fallback', clangd, 30)
        except ValueError as error:
            assert 'private-index-failed' in str(error), error
        else:
            raise AssertionError('outer canonical overlay must not reopen live filesystem fallback')
        print(json.dumps({'operation':operation, 'metrics':metrics,
            'physical_canonical_uri_with_frozen_bytes':True, 'live_fallback_denied':True,
            'unused_target_content_not_hashed':True, 'metadata_and_lookup_invalidation':True}))
        sys.exit(0)
    if operation in ('intern_native', 'intern_contexts'):
        header = source / 'Common.h'
        header.write_text('#pragma once\n' + ('struct Shared {};\n' if operation == 'intern_native'
                          else 'inline int selected() { return CHOOSE(); }\n'))
        expected_shared = operation == 'intern_native'
        admit = module._admit
        observed_json = []
        def check_readonly(group, candidate, originals, graph, *args, **kwargs):
            uri = header.as_uri()
            assert (originals[0][uri] == originals[1][uri]) == expected_shared
            assert (originals[0][uri] is originals[1][uri]) == expected_shared
            before = [module._json(value) for value in originals]
            result = admit(group, candidate, originals, graph, *args, **kwargs)
            assert [module._json(value) for value in originals] == before, 'admission must not mutate shared records'
            observed_json[:] = before
            return result
        with patch.object(module, '_admit', check_readonly):
            output, metrics = module.accelerate(entries, root / 'proofs', clangd, max_group=2, timeout=30)
        assert metrics['batch_count'] == int(expected_shared), metrics
        if not expected_shared:
            assert output == entries and 'admission-rejected' in metrics['groups'][0]['reason'], metrics
        group_root = pathlib.Path(metrics['proof_directory']) / 'group-0'
        assert [(group_root / ('graph-' + str(i) + '.json')).read_text() for i in range(2)] == observed_json
        ids = module._identities(pathlib.Path(clangd), imported=True)
        pool = {}
        cached = [module._cached_original(entry, ids, root / 'proofs', {}, [], pool) for entry in entries[:2]]
        assert all(value is not None for value in cached)
        assert (cached[0][0][header.as_uri()] is cached[1][0][header.as_uri()]) == expected_shared
        print(json.dumps({'operation': operation, 'shared_record': expected_shared, 'metrics': metrics}))
        sys.exit(0)
    if operation in ('distinct_identical', 'same_file_alias', 'symlink_alias'):
        first, second = source / 'first.h', source / ('second.h' if operation == 'distinct_identical' else 'second.hpp')
        first.write_text('#pragma once\nstruct ITEM {};\n')
        if operation == 'same_file_alias':
            os.link(first, second)
        elif operation == 'symlink_alias':
            os.symlink(first, second)
        else:
            second.write_bytes(first.read_bytes())
        assert os.path.samefile(first, second) == (operation != 'distinct_identical')
        should_merge = operation == 'distinct_identical' or (operation == 'same_file_alias' and os.name == 'nt')
        assert (module._source_identity(first) == module._source_identity(second)) == (not should_merge)
        real = root / 'RealCombined.cpp'
        real.write_text(''.join('#include "' + entry['file'].replace('\\', '/') + '"\n' for entry in entries[:2]))
        real_entry = dict(entries[0], file=str(real), arguments=module.rewritten_arguments(entries[0], str(real)))
        names = set()
        try:
            graph, _, _ = module._index([real_entry], root / 'real-combined', clangd, 30)
            assert should_merge, 'one Clang file identity must not define both types'
            names = {symbol['name'] for node in graph.values() for symbol in node['symbols']}
            assert {'Alpha', 'Beta', 'makeAlpha', 'makeBeta'} <= names, names
        except ValueError as error:
            assert not should_merge and 'compiler-errors' in str(error), str(error)
        output, metrics = module.accelerate(entries, root / 'proofs', clangd, max_group=2, timeout=30)
        print(json.dumps({'operation': operation, 'real_combined_names': sorted(names), 'metrics': metrics}), flush=True)
        record = json.loads(next((root / 'proofs/receipts').glob('*.json')).read_text())
        headers = [item for item in record['dependencies'] if pathlib.Path(item['path']) in (first, second)]
        print(json.dumps({'header_snapshots': headers}), flush=True)
        if operation == 'symlink_alias' and len(headers) == 1:
            # Native canonical URIs can already collapse the symlink to its
            # target before freezing; it must remain one snapshot.
            assert pathlib.Path(headers[0]['path']).resolve() == first.resolve()
        else:
            assert len(headers) == 2
            assert (headers[0]['snapshot'] == headers[1]['snapshot']) == (not should_merge)
        assert metrics['batch_count'] == int(should_merge), metrics
        if not should_merge:
            assert output == entries and 'compiler-errors' in metrics['groups'][0]['reason'], metrics
        else:
            assert module._cache_valid(record, root / 'proofs', {})
            second.unlink()
            try:
                os.symlink(first, second)
            except OSError as error:
                second.write_bytes(first.read_bytes())
                print(json.dumps({'symlink_rebinding_unavailable': str(error)}), flush=True)
            else:
                # Same source bytes and names, but now both paths identify one
                # Clang file. Prove the identity check rejects before even
                # consulting the directory-inventory guard.
                with patch.object(module, '_inventories', side_effect=AssertionError('identity guard must reject first')):
                    assert not module._cache_valid(record, root / 'proofs', {})
                try:
                    module._index([real_entry], root / 'real-rebound', clangd, 30)
                    raise AssertionError('rebinding the same bytes to one identity must lose Beta')
                except ValueError as error:
                    assert 'compiler-errors' in str(error), str(error)
                print(json.dumps({'same_bytes_identity_change_invalidated': True,
                                  'retargeted_real_compiler_rejected': True}), flush=True)
        assert output[-2:] == [exact, shader]
        sys.exit(0)
    if operation in ('original_reuse', 'original_overlap', 'original_unlinked'):
        directory = root / 'proofs'
        original_calls = []
        index_impl = module._index
        def tracked_index(selected, *args, **kwargs):
            if len(selected) == 1 and module._is_ubt(selected[0]):
                original_calls.append(selected[0]['file'])
            return index_impl(selected, *args, **kwargs)
        with patch.object(module, '_index', tracked_index):
            if operation == 'original_overlap':
                # A real overload mismatch rejects A+B; the next proposal B+C
                # shares B within the same invocation and must not re-index it.
                with patch.object(module, '_batch_groups', return_value=iter([([0, 1], None), ([1, 2], None)])):
                    output, metrics = module.accelerate(entries, directory, clangd, max_group=2, timeout=30)
                assert not metrics['groups'][0]['accepted'] and metrics['groups'][1]['accepted'], metrics
                assert metrics['groups'][1]['original_cache_hits'] == 1, metrics
                assert original_calls == [entry['file'] for entry in entries[:3]], original_calls
                assert output[0] == entries[0] and output[-2:] == [exact, shader], output
            elif operation == 'original_unlinked':
                candidate_index = module._candidate_index
                def unlinked(*args, **kwargs):
                    candidate, graph = candidate_index(*args, **kwargs)
                    graph = copy.deepcopy(graph)
                    graph[(source / 'Member0.cpp').as_uri()]['source']['digest'] = 'f' * 16
                    return candidate, graph
                with patch.object(module, '_candidate_index', unlinked):
                    output, metrics = module.accelerate(entries, directory, clangd, max_group=2, timeout=30)
                assert output == entries and metrics['batch_count'] == 0, metrics
                identities = module._identities(pathlib.Path(clangd), imported=True)
                assert not module._original_cache_path(entries[0], identities, directory).exists()
                assert module._original_cache_path(entries[1], identities, directory).is_file()
                assert metrics['groups'][0]['original_cache_unlinked'] == 1, metrics
            else:
                first_output, first_metrics = module.accelerate(entries[:2], directory, clangd, max_group=2, timeout=30)
                assert first_metrics['batch_count'] == 1, first_metrics
                assert first_metrics['groups'][0]['original_cache_misses'] == 2, first_metrics
                output, metrics = module.accelerate(entries[1:3], directory, clangd, max_group=2, timeout=30)
                assert metrics['batch_count'] == 1 and metrics['groups'][0]['original_cache_hits'] == 1, metrics
                assert metrics['groups'][0]['original_cache_misses'] == 1, metrics
                assert original_calls == [entry['file'] for entry in entries[:3]], original_calls
                assert len(metrics['groups'][0]['run_metrics']) == 2, 'only new C and the candidate are charged again'
                identities = module._identities(pathlib.Path(clangd), imported=True)
                entry = entries[1]
                def cached(command=entry, ids=identities):
                    return module._cached_original(command, ids, directory, {}, [])
                assert cached() is not None
                # Reuse is direct-addressed: unrelated or historical proof
                # graphs are not searched or silently treated as originals.
                (directory / 'originals/unrelated.json').write_text('not a cache record')
                assert cached() is not None
                changed = copy.deepcopy(entry)
                changed['arguments'].insert(1, '-DNEW=1')
                assert cached(changed) is None
                for field in ('tool', 'collector', 'server_profile', 'compiler_environment'):
                    changed_ids = dict(identities, **{field: 'different'})
                    assert cached(ids=changed_ids) is None, field
                with patch.dict(os.environ, {'CPATH': str(root / 'another-include')}):
                    assert cached() is None
                member = source / 'Member1.cpp'
                raw, stamp = member.read_bytes(), member.stat()
                member.write_bytes(raw.replace(b'return 1', b'return 9'))
                os.utime(member, ns=(stamp.st_atime_ns, stamp.st_mtime_ns))
                assert cached() is None, 'same mtime is not input-byte identity'
                member.write_bytes(raw)
                added = source / 'new-conditional.h'
                added.write_text('// a newly available lookup name\n')
                assert cached() is None
                added.unlink()
                path = module._original_cache_path(entry, identities, directory)
                raw = path.read_bytes(); record = json.loads(raw)
                if os.name == 'nt':
                    spelling = dict(entry, file=entry['file'].swapcase())
                    assert module._original_main_shard(spelling, record['effective_entry'],
                        [record['main_shard']['path']]) == record['main_shard']
                changed = copy.deepcopy(record)
                changed['effective_entry']['arguments'].insert(1, '-DWRONG_EFFECTIVE=1')
                path.write_text(json.dumps(changed))
                assert cached() is None, 'actual main Cmd is bound to the graph asset'
                path.write_bytes(raw)
                for asset in record['assets']:
                    asset_path = pathlib.Path(asset['path'])
                    content = asset_path.read_bytes()
                    asset_path.write_bytes(content + b' ')
                    assert cached() is None, asset
                    asset_path.write_bytes(content)
                assert cached() is not None
        print(json.dumps({'operation': operation, 'metrics': metrics, 'original_index_calls': original_calls}))
        sys.exit(0)
    if operation == 'group_hints':
        directory = root / 'proofs'
        selected = [entries[i] for i in (0, 1, 3, 4)]
        certified, first = module.accelerate(selected, directory, clangd, max_group=4, timeout=30)
        assert first['batch_count'] == 1, first
        hint_path = directory / 'accepted-groups.json'
        assert hint_path.is_file(), 'successful proof must publish compact accepted-only lookup hints'
        big_hint = json.loads(hint_path.read_text())['groups'][0]
        big_cache = directory / 'receipts' / (big_hint['cache_key'] + '.json')
        read_text = pathlib.Path.read_text
        def forbid_big(path, *args, **kwargs):
            assert path != big_cache, 'over-limit hint must not read the large record'
            return read_text(path, *args, **kwargs)
        with patch.object(pathlib.Path, 'read_text', forbid_big):
            limited, metrics = cached_only(entries, directory, max_group=2)
        assert limited == entries and metrics['batch_count'] == 0, metrics
        # A smaller accepted competitor must never steal members from the
        # larger group just because its hint was serialized first.
        pair, _ = module.accelerate(entries[:2], directory, clangd, max_group=2, timeout=30)
        document = json.loads(hint_path.read_text())
        assert len(document['groups']) == 2, document
        document['groups'].sort(key=lambda item: len(item['entry_hashes']))
        hint_path.write_text(json.dumps(document))
        hint_before = (hint_path.read_bytes(), hint_path.stat().st_mtime_ns)
        unused = directory / 'receipts' / ('f' * 64 + '.json')
        unused.write_text('not a cache record' * 100000)
        def forbid_unused(path, *args, **kwargs):
            assert path != unused, 'accepted hints must not scan arbitrary rejected records'
            return read_text(path, *args, **kwargs)
        with patch.object(pathlib.Path, 'read_text', forbid_unused):
            output, reused = cached_only(entries, directory, max_group=4)
        assert (hint_path.read_bytes(), hint_path.stat().st_mtime_ns) == hint_before, 'cache-only hints are read-only'
        assert output == [certified[0], entries[2], exact, shader], output
        assert reused['accepted_ubt_count'] == 4 and reused['retained_ubt_count'] == 1, reused
        accepted = [g for g in reused['groups'] if g['accepted']]
        assert len(accepted) == 1 and accepted[0]['original_indexes'] == [0,1,3,4], accepted
        assert sorted(m for e in output for m in e.get('nvim_ue_members', [])) == sorted(
            m for e in entries for m in e.get('nvim_ue_members', []))
        single = {'schema': 1, 'groups': [big_hint]}
        for change in ('outside', 'module', 'context', 'duplicate'):
            invalid = copy.deepcopy(single)
            hint = invalid['groups'][0]
            if change == 'outside': hint['cache_key'] = '../outside'
            elif change == 'module': hint['module_root'] = 'different-module'
            elif change == 'context': hint['context_key'] = '0' * 64
            else: hint['entry_hashes'][1] = hint['entry_hashes'][0]
            hint_path.write_text(json.dumps(invalid))
            fallback, _ = cached_only(entries, directory, max_group=4)
            assert fallback == entries, change
        for raw in ('{malformed', json.dumps({'schema': 1, 'groups': [None]}), ' ' * (2 * 1024 * 1024 + 1)):
            hint_path.write_text(raw)
            fallback, _ = cached_only(entries, directory, max_group=4)
            assert fallback == entries
        hint_path.write_text(json.dumps(single))
        for field in ('arguments', 'nvim_ue_module_root'):
            changed = copy.deepcopy(entries)
            if field == 'arguments': changed[3][field].insert(1, '-DCHANGED=1')
            else: changed[3][field] = 'different-module'
            fallback, _ = cached_only(changed, directory, max_group=4)
            assert fallback == changed, field
        # Re-seal the tampered receipt in its cache record: asset hashing alone
        # would pass, but the certified original command set is now different.
        cache_raw = big_cache.read_bytes()
        cache = json.loads(cache_raw)
        receipt_path = pathlib.Path(cache['candidate']['nvim_ue_batch_receipt'])
        receipt_raw = receipt_path.read_bytes()
        receipt = json.loads(receipt_raw)
        receipt['original_entries'][0]['arguments'].insert(1, '-DWRONG_ORIGINAL=1')
        receipt_path.write_text(json.dumps(receipt))
        digest = module._sha(receipt_path.read_bytes())
        cache['candidate']['nvim_ue_batch_receipt_sha256'] = digest
        for asset in cache['assets']:
            if pathlib.Path(asset['path']) == receipt_path: asset['sha256'] = digest
        big_cache.write_text(json.dumps(cache))
        fallback, _ = cached_only(entries, directory, max_group=4)
        assert fallback == entries, 'original receipt commands must match the selected current entries'
        receipt_path.write_bytes(receipt_raw)
        big_cache.write_bytes(cache_raw)
        for invalid in (None, [], 'not-an-object'):
            big_cache.write_text(json.dumps(invalid))
            fallback, _ = cached_only(entries, directory, max_group=4)
            assert fallback == entries, ('cache JSON type', invalid)
            big_cache.write_bytes(cache_raw)
            receipt_path.write_text(json.dumps(invalid))
            cache = json.loads(cache_raw)
            digest = module._sha(receipt_path.read_bytes())
            cache['candidate']['nvim_ue_batch_receipt_sha256'] = digest
            for asset in cache['assets']:
                if pathlib.Path(asset['path']) == receipt_path: asset['sha256'] = digest
            big_cache.write_text(json.dumps(cache))
            fallback, _ = cached_only(entries, directory, max_group=4)
            assert fallback == entries, ('receipt JSON type', invalid)
            receipt_path.write_bytes(receipt_raw)
            big_cache.write_bytes(cache_raw)
        hint_path.write_text(json.dumps(document))
        again, warm = cached_only(entries, directory, max_group=4)
        assert again == output and warm['cache_hits'] == 1, warm
        print(json.dumps({'operation': operation, 'metrics': warm}))
        sys.exit(0)
    if operation == 'indirect':
        unsupported = ['@response.rsp', '--config=hidden.cfg', '-ivfsoverlay=hidden.json',
            '-Xclang=-ivfsoverlay', '-Wp,@response.rsp', '/clang:-fmodule-map-file=hidden.map',
            '-fmodule-file=hidden.pcm', '-fprebuilt-module-path=modules', '-include-pch']
        for argument in unsupported:
            changed = [dict(entry, arguments=entry['arguments'] + [argument]) for entry in entries[:2]]
            output, metrics = module.accelerate(changed, root / 'proofs', clangd, max_group=2, timeout=30)
            assert output == changed and metrics['batch_count'] == 0, metrics
            assert metrics['groups'][0]['reason'].startswith('unsupported-indirect-compiler-input:'), metrics
        assert not list((root / 'proofs').glob('proof-*/group-*')), 'unsupported inputs must not launch compilers'
        sys.exit(0)
    if operation == 'metrics':
        extensions = ['c', 'cc', 'cpp', 'cxx', 'c++', 'glsl', 'usf', 'ush', 'hlsl', 'hlsli',
                      'frag', 'vert', 'metal', 'comp', 'unrecognizedshader', 'txt', 'hpp']
        inputs = [dict(exact, file=str(root / ('file.' + suffix))) for suffix in extensions]
        output, metrics = module.accelerate(inputs, root / 'proofs', clangd)
        assert output == inputs and metrics['exact_count'] == 5 and metrics['shader_count'] == 9, metrics
        assert metrics['other_count'] == 3 and metrics['batch_count'] == 0, metrics
        sys.exit(0)
    if operation == 'reuse_only':
        output, missing = cached_only(entries, root / 'proofs')
        assert output == entries and missing['cache_hits'] == 0 and missing['deferred_group_count'] == 1, missing
        assert missing['groups'][0]['reason'] == 'verification-not-cached', missing
        assert not list((root / 'proofs').glob('proof-*/group-*')), 'cache miss must not create compiler work'
    if operation == 'query_profile':
        original_graph, _, _ = module._index(entries[:1], root / 'no-query', clangd, 30)
        assert (first / 'Choice.h').as_uri() in original_graph
        assert (second / 'Choice.h').as_uri() not in original_graph
        missing, pending = cached_only(entries, root / 'proofs', profile)
        assert missing == entries and pending['deferred_group_count'] == 1, pending
    output, metrics = module.accelerate(entries, root / 'proofs', clangd, max_group=2, timeout=30, server_profile=profile)
    assert output[-2:] == [exact, shader], output
    assert metrics['original_ubt_count'] == 2 and metrics['exact_count'] == 1 and metrics['shader_count'] == 1
    assert metrics['other_count'] == 0
    assert metrics['proof_seconds'] >= 0
    if operation == 'template_arguments':
        assert metrics['batch_count'] == 1, metrics
        receipt = json.loads(pathlib.Path(output[0]['nvim_ue_batch_receipt']).read_text())
        assert receipt['proven_template_arguments'], receipt
        proof_assets = receipt['template_argument_proof_assets']
        assert len(proof_assets) == 2
        record = json.loads(next((root / 'proofs/receipts').glob('*.json')).read_text())
        assert all(asset in record['assets'] for asset in proof_assets)
        proof = json.loads(pathlib.Path(proof_assets[1]['path']).read_text())
        assert proof['ok'] is True
        assert proof['evidence']['entries'] == receipt['effective_entries'] + [receipt['effective_candidate']]
        assert [item['request'] for item in proof['evidence']['requests']] == receipt['proven_template_arguments']
        again, warm = cached_only(entries, root / 'proofs')
        assert again == output and warm['cache_hits'] == 1, warm
        for asset in proof_assets:
            path = pathlib.Path(asset['path'])
            before = path.read_bytes()
            path.write_bytes(before + b' ')
            stale, missing = cached_only(entries, root / 'proofs')
            assert stale == entries and missing['deferred_group_count'] == 1, missing
            path.write_bytes(before)
        cache_path = next((root / 'proofs/receipts').glob('*.json'))
        original_cache = cache_path.read_bytes()
        record['identities']['policy'] = '0' * 64
        cache_path.write_text(json.dumps(record))
        stale, missing = cached_only(entries, root / 'proofs')
        assert stale == entries and missing['deferred_group_count'] == 1, missing
        cache_path.write_bytes(original_cache)
        assert module.validate_receipts([output[0]['nvim_ue_batch_receipt']], clangd)['ok']
    elif operation == 'query_profile':
        assert metrics['batch_count'] == 1, metrics
        receipts = [output[0]['nvim_ue_batch_receipt']]
        receipt = json.loads(pathlib.Path(receipts[0]).read_text())
        assert receipt['server_profile'] == profile and receipt['identities']['server_profile'] == profile
        assert receipt['original_entries'] == [module._native(entry) for entry in entries[:2]]
        implicit_roots = {pathlib.Path(path) for observed in receipt['query_profiles'] for path in observed['implicit_search_roots']}
        assert compiler.resolve().parent.parent in implicit_roots
        assert all(any(pathlib.Path(root) == path or pathlib.Path(root) in path.parents
                       for root in receipt['inventories']) for path in implicit_roots), receipt['inventories']
        dependencies = {item['uri'] for item in receipt['dependencies']}
        assert (second / 'Choice.h').as_uri() in dependencies and (first / 'Choice.h').as_uri() not in dependencies
        assert all('-isystem' in entry['arguments'] for entry in receipt['effective_entries'])
        assert '-isystem' not in output[0]['arguments'], 'raw candidate must not materialize driver-query output'
        assert not module.describe_receipts(receipts)['ok'], 'profile requires an explicit matching request'
        described = module.describe_receipts(receipts, server_profile=profile)
        assert described['ok'] and described['server_profile'] == profile, described
        assert described['query_driver_files'] and described['query_search_roots']
        # Driver discovery scopes have their own nonrecursive watches. They
        # must never become recursive source inventory/watch roots.
        lookup = pathlib.Path(stack.enter_context(tempfile.TemporaryDirectory(prefix='query_lookup_'))).resolve()
        receipt_path = pathlib.Path(receipts[0])
        original_receipt = receipt_path.read_bytes()
        receipt['query_profiles'][0]['driver_search_roots'].append(lookup.as_posix())
        receipt['query_profiles'][0]['driver_candidates'].append((lookup / 'clang++').as_posix())
        receipt_path.write_text(json.dumps(receipt))
        descriptor = module.describe_receipts(receipts, server_profile=profile)
        assert descriptor['ok'] and lookup.as_posix() in descriptor['query_driver_search_roots'], descriptor
        assert not any(pathlib.Path(path) == lookup or pathlib.Path(path) in lookup.parents
                       for path in descriptor['watch_roots']), descriptor
        receipt_path.write_bytes(original_receipt)
        checked = module.validate_receipts(receipts, clangd, server_profile=profile)
        assert checked['ok'] and checked['server_profile'] == profile, checked
        assert checked['compiler_environment']['CPATH'] == str(first)
        again, warm = cached_only(entries, root / 'proofs', profile)
        assert again == output and warm['cache_hits'] == 1, warm
        changed = dict(profile, query_driver='**/clang++.exe')
        fallback, stale = cached_only(entries, root / 'proofs', changed)
        assert fallback == entries and stale['deferred_group_count'] == 1, stale
        assert not module.validate_receipts(receipts, clangd, server_profile=changed)['ok']
        (second / 'Choice.h').write_text('#pragma once\nconstexpr int chosen = 3;\n')
        fallback, stale = cached_only(entries, root / 'proofs', profile)
        assert fallback == entries and stale['deferred_group_count'] == 1, stale
    elif operation == 'reuse_only':
        assert metrics['batch_count'] == 1 and metrics['deferred_group_count'] == 0, metrics
        again, reused = cached_only(entries, root / 'proofs')
        assert again == output and reused['cache_hits'] == 1 and reused['deferred_group_count'] == 0, reused
        dependency = source / 'Member0.cpp'
        original = dependency.read_bytes()
        dependency.write_bytes(original.replace(b'return 1', b'return 3'))
        changed, invalidated = cached_only(entries, root / 'proofs')
        assert changed == entries and invalidated['deferred_group_count'] == 1, invalidated
        assert invalidated['groups'][0]['reason'] == 'verification-not-cached', invalidated
        dependency.write_bytes(original)
        cache_path = next((root / 'proofs/receipts').glob('*.json'))
        cached = json.loads(cache_path.read_text())
        cached['identities']['policy'] = '0' * 64
        cache_path.write_text(json.dumps(cached))
        old_policy, deferred = cached_only(entries, root / 'proofs')
        assert old_policy == entries and deferred['deferred_group_count'] == 1, deferred
        assert deferred['groups'][0]['reason'] == 'verification-not-cached', deferred
    elif operation == 'pass':
        assert len(output) == 3 and metrics['batch_count'] == 1, metrics
        batch = output[0]
        assert batch['nvim_ue_batch_receipt_sha256'] == module._sha(pathlib.Path(batch['nvim_ue_batch_receipt']).read_bytes())
        assert batch['nvim_ue_batch_ubt_count'] == 2
        assert batch['nvim_ue_members'] == entries[0]['nvim_ue_members'] + entries[1]['nvim_ue_members']
        assert '-ivfsoverlay' in batch['arguments']
        paths = [pathlib.Path(batch['file']), pathlib.Path(batch['nvim_ue_batch_receipt']),
                 pathlib.Path(batch['arguments'][batch['arguments'].index('-ivfsoverlay') + 1])]
        before = {str(path): (path.read_bytes(), path.stat().st_mtime_ns) for path in paths}
        again, repeat = module.accelerate(entries, root / 'proofs', clangd, max_group=2, timeout=30)
        assert again == output and repeat['batch_count'] == 1, repeat
        assert before == {str(path): (path.read_bytes(), path.stat().st_mtime_ns) for path in paths}
        assert repeat['baseline_cache_reused'] is True and repeat['cache_hits'] == 1
        record = json.loads(next((root / 'proofs/receipts').glob('*.json')).read_text())
        excluded = (root / 'proofs').resolve()
        assert module._cache_valid(record, excluded, {})
        receipts = [batch['nvim_ue_batch_receipt']]
        described = module.describe_receipts(receipts)
        assert described['ok'] and described['watch_roots'] and str(excluded) in described['exclude_roots']
        validated = module.validate_receipts(receipts, clangd)
        assert validated['ok'] and validated['validation_seconds'] >= 0, validated
        request_path, response_path = root / 'proofs/request.json', root / 'proofs/response.json'
        request_path.write_text(json.dumps(receipts), encoding='utf-8')
        for action in ('--describe-receipts', '--validate-receipts'):
            completed = subprocess.run([sys.executable, '-I', tool, action, str(request_path),
                '--clangd', clangd, '--out', str(response_path)], capture_output=True, timeout=30,
                creationflags=(subprocess.CREATE_NO_WINDOW | subprocess.IDLE_PRIORITY_CLASS) if os.name == 'nt' else 0)
            assert completed.returncode == 0, completed.stderr.decode()
            assert json.loads(response_path.read_text())['ok']
        dependency = source / 'Member0.cpp'
        raw, stamp = dependency.read_bytes(), dependency.stat()
        dependency.write_bytes(raw.replace(b'return 1', b'return 3'))
        os.utime(dependency, ns=(stamp.st_atime_ns, stamp.st_mtime_ns))
        assert not module._cache_valid(record, excluded, {}), 'mtime is not byte proof'
        assert not module.validate_receipts(receipts, clangd)['ok']
        dependency.write_bytes(raw)
        new_header = source / 'new-conditional.h'
        new_header.write_text('// newly available to has_include\n')
        assert not module._cache_valid(record, excluded, {}), 'new include names invalidate proof'
        new_header.unlink()
        for asset in record['assets']:
            path = pathlib.Path(asset['path'])
            raw = path.read_bytes()
            path.write_bytes(raw + b' ')
            assert not module._cache_valid(record, excluded, {}), str(path)
            path.write_bytes(raw)
        assert module._cache_valid(record, excluded, {})
        policy_cache = next((root / 'proofs/receipts').glob('*.json'))
        previous = json.loads(policy_cache.read_text())
        previous['identities']['policy'] = '0' * 64
        policy_cache.write_text(json.dumps(previous), encoding='utf-8')
        replayed, replay_metrics = module.accelerate(entries, root / 'proofs', clangd, max_group=2, timeout=30)
        assert replayed == output and replay_metrics['groups'][0]['graph_replayed'], replay_metrics
        assert replay_metrics['groups'][0]['run_metrics'] == [], 'policy replay must not rerun BackgroundIndex'
        assert module.validate_receipts(receipts, clangd)['ok']
    elif operation == 'environment':
        assert len(output) == 3 and metrics['batch_count'] == 1, metrics
        receipts = [output[0]['nvim_ue_batch_receipt']]
        cache = json.loads(next((root / 'proofs/receipts').glob('*.json')).read_text())
        assert str(external / 'first') in cache['inventories'], cache['inventories']
        described = module.describe_receipts(receipts)
        assert described['ok'] and described['compiler_environment']['CPATH'] == first_env, described
        assert module.validate_receipts(receipts, clangd)['ok']
        before = {str(path): path.read_bytes() for path in root.rglob('*') if path.is_file()}
        os.environ['CPATH'] = second_env
        assert not module._cache_valid(cache, root / 'proofs', {}), 'environment changes must invalidate byte-identical input'
        invalidated = module.validate_receipts(receipts, clangd)
        assert not invalidated['ok'] and invalidated['reason'] == 'receipt-compiler-environment-changed', invalidated
        assert before == {str(path): path.read_bytes() for path in root.rglob('*') if path.is_file()}
        again, repeat = module.accelerate(entries, root / 'proofs', clangd, max_group=2, timeout=30)
        assert repeat['batch_count'] == 1 and repeat['cache_hits'] == 0, repeat
        assert repeat['groups'][0]['run_metrics'], 'environment change requires original compiler recollection'
        assert again[0]['nvim_ue_batch_receipt'] != receipts[0]
        assert module.validate_receipts([again[0]['nvim_ue_batch_receipt']], clangd)['ok']
        os.environ['CPATH'] = ''
        assert str(root) in module._include_roots(entries[:2], []), 'empty include path means compiler cwd'
        assert module._compiler_environment()['CPATH'] == ''
        del os.environ['CPATH']
        assert module._compiler_environment()['CPATH'] is None
    elif operation in ('aliases', 'owned_aliases'):
        assert len(output) == 3 and metrics['batch_count'] == 1, metrics
        assert module.validate_receipts([output[0]['nvim_ue_batch_receipt']], clangd)['ok']
    elif operation == 'contexts':
        assert output == entries and metrics['batch_count'] == 0 and not metrics['groups'], metrics
    else:
        assert output == entries and metrics['batch_count'] == 0, metrics
        assert len(metrics['groups']) == 1 and metrics['groups'][0]['reason'], metrics
        if operation == 'conflict':
            assert 'private-index-failed' in metrics['groups'][0]['reason'], metrics
            assert not list((root / 'proofs/originals').glob('*.json')), 'failed frozen compilation cannot bind original digests to snapshots'
            again, repeat = module.accelerate(entries, root / 'proofs', clangd, max_group=2, timeout=30)
            assert again == entries and repeat['cache_hits'] == 1, repeat
        elif operation == 'original_error':
            assert 'private-index-failed' in metrics['groups'][0]['reason'], metrics
            assert not list((root / 'proofs/receipts').glob('*.json')), 'incomplete original proof cannot be cached'
        elif operation == 'overload':
            assert 'admission-rejected' in metrics['groups'][0]['reason'], metrics
            again, repeat = module.accelerate(entries, root / 'proofs', clangd, max_group=2, timeout=30)
            assert again == entries and repeat['cache_hits'] == 1, repeat
            assert repeat['groups'][0]['cached'] and not repeat['groups'][0]['accepted'], repeat
            unchanged, cached_rejection = cached_only(entries, root / 'proofs')
            assert unchanged == entries and cached_rejection['cache_hits'] == 1, cached_rejection
            assert cached_rejection['deferred_group_count'] == 0 and cached_rejection['groups'][0]['cached'], cached_rejection
            assert cached_rejection['groups'][0]['reason'] == metrics['groups'][0]['reason'], cached_rejection
    print(json.dumps({'operation': operation, 'metrics': metrics}))
]=]

local function run_fixture(operation, clangd)
  local python = vim.fn.exepath("python")
  if python == "" then python = vim.fn.exepath("python3") end
  if python == "" then
    t.skip("verified batch Python fixture", "Python unavailable", { native = true })
    return
  end
  local script = vim.fn.tempname() .. "_verified_batch.py"
  local stream = assert(io.open(script, "wb"))
  stream:write(fixture)
  stream:close()
  local result = vim.system({ python, "-I", script,
    vim.fn.stdpath("config") .. "/tools/cdb_verified_batch.py", clangd, operation }, { text = true }):wait()
  pcall(vim.fn.delete, script)
  t.assert_eq(result.code, 0, (result.stderr or "") .. (result.stdout or ""))
end

t.describe("verified compiler-context UBT batching", function()
  local discovered = require("utils.ue_goto.semantic_sidecar_libclang").discover_toolchain()
  if not discovered.ok then
    t.skip("native verified batching", discovered.reason, { native = true })
    return
  end
  t.it("interns exact read-only file records without losing same-URI bindings or changing graph JSON", function()
    run_fixture("intern_records", discovered.clangd_path)
  end)
  t.it("shares identical independent native header records while preserving graph output and cached loads", function()
    run_fixture("intern_native", discovered.clangd_path)
  end)
  t.it("retains distinct same-header bindings and rejects the native merged candidate", function()
    run_fixture("intern_contexts", discovered.clangd_path)
  end)
  t.it("proves a compatible batch, preserves other entries and repeats without artifact rewrites", function()
    run_fixture("pass", discovered.clangd_path)
  end)
  t.it("preserves distinct file identity for byte-identical pragma-once headers", function()
    run_fixture("distinct_identical", discovered.clangd_path)
  end)
  t.it("matches native pragma-once behavior for real hardlinks with different suffixes", function()
    run_fixture("same_file_alias", discovered.clangd_path)
  end)
  local symlink_target = vim.fn.tempname() .. "-snapshot-target.h"
  local symlink_path = symlink_target .. ".alias"
  vim.fn.writefile({ "// actual symlink capability" }, symlink_target)
  local symlink_ok, symlink_error = vim.uv.fs_symlink(symlink_target, symlink_path)
  if symlink_ok then vim.uv.fs_unlink(symlink_path) end
  vim.uv.fs_unlink(symlink_target)
  if symlink_ok then
    t.it("matches native pragma-once behavior for an actual symlink alias", function()
      run_fixture("symlink_alias", discovered.clangd_path)
    end)
  else
    t.skip("native pragma-once symlink alias", "host symlink capability unavailable: " .. tostring(symlink_error))
  end
  t.it("reuses independent original graphs across overlapping groups and invalidates changed identities or assets", function()
    run_fixture("original_reuse", discovered.clangd_path)
  end)
  t.it("reuses a frozen-byte-linked original after a real semantic rejection within one invocation", function()
    run_fixture("original_overlap", discovered.clangd_path)
  end)
  t.it("does not persist originals whose native digest differs from the frozen-byte graph", function()
    run_fixture("original_unlinked", discovered.clangd_path)
  end)
  t.it("proves template values with effective commands and seals proof assets for compiler-free reuse", function()
    run_fixture("template_arguments", discovered.clangd_path)
  end)
  t.it("reuses noncontiguous accepted groups within the hard size limit without reading rejected records", function()
    run_fixture("group_hints", discovered.clangd_path)
  end)
  t.it("retains original UBT commands on static name collision", function()
    run_fixture("conflict", discovered.clangd_path)
  end)
  t.it("retains originals without an incomplete receipt when an original TU has compiler errors", function()
    run_fixture("original_error", discovered.clangd_path)
  end)
  t.it("rejects overload pollution even when the merged compiler accepts it", function()
    run_fixture("overload", discovered.clangd_path)
  end)
  t.it("never batches distinct full compiler contexts", function()
    run_fixture("contexts", discovered.clangd_path)
  end)
  t.it("retains original URI semantics for frozen Windows mixed relative includes", function()
    run_fixture("aliases", discovered.clangd_path)
  end)
  t.it("recollects compiler proof when inherited include environment changes with identical input bytes", function()
    run_fixture("environment", discovered.clangd_path)
  end)
  t.it("rejects untracked response, config, VFS and module inputs before compilation", function()
    run_fixture("indirect", discovered.clangd_path)
  end)
  t.it("counts C/C++ exact entries, known shaders and other entries separately", function()
    run_fixture("metrics", discovered.clangd_path)
  end)
  t.it("defers cache misses and changed proofs without starting compilers or graph replay", function()
    run_fixture("reuse_only", discovered.clangd_path)
  end)
  if vim.fn.has("win32") == 1 then
    t.it("preserves canonical system include spelling through owned frozen overlays", function()
      run_fixture("owned_system_header", discovered.clangd_path)
    end)
    t.it("preserves unmapped system providers while canonicalizing only owned dependency names", function()
      run_fixture("owned_unmapped_system", discovered.clangd_path)
    end)
    t.it("preserves compiler-proven mixed-relative aliases together with an owned canonical overlay", function()
      run_fixture("owned_aliases", discovered.clangd_path)
    end)
    t.it("preserves canonical URIs over frozen bytes for owned identity overlays and invalidates metadata or lookup changes", function()
      run_fixture("owned_overlay", discovered.clangd_path)
    end)
    t.it("certifies a real query-driver header-selection change and guards its receipt profile", function()
      run_fixture("query_profile", discovered.clangd_path)
    end)
    t.it("accepts only identical snapshots published by a concurrent Windows writer holding an open file", function()
      run_fixture("write_race", discovered.clangd_path)
    end)
  else
    t.skip("Windows snapshot publication sharing race", "Windows file sharing semantics unavailable", { native = true })
  end
end)
