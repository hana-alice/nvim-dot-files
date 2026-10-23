local t = require("tests.harness")
t.bootstrap()

-- API routing/cache contracts only. Native qualification is never fabricated.
local fixture = [=[
import collections, contextlib, copy, hashlib, importlib.util, json, os, pathlib, subprocess, sys, tempfile
from unittest.mock import patch
tool, operation = sys.argv[1:]
spec = importlib.util.spec_from_file_location('explicit_strict', tool)
module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
sha = lambda raw: hashlib.sha256(raw).hexdigest()
with tempfile.TemporaryDirectory(prefix='explicit_strict_contract_') as temporary, contextlib.ExitStack() as stack:
    root = pathlib.Path(temporary).resolve(); source = root / 'Source'; source.mkdir()
    executable = pathlib.Path(sys.executable).resolve(); store = root / 'proofs'
    stack.enter_context(patch.dict(os.environ, {'NVIM_UE_SUPER_UNITY_BUDGET_FACTOR': '8', 'CL': '', '_CL_': '', 'CCC_OVERRIDE_OPTIONS': ''}))
    stack.enter_context(patch.object(subprocess, 'Popen', side_effect=AssertionError('contract test must not launch native')))
    stack.enter_context(patch.object(module, '_proof_work_root', return_value=root / 'work'))
    originals, member_paths = [], []
    for index in range(4):
        suffix = '.gen.cpp' if index >= 2 and operation != 'bisection' else '.cpp'
        member = source / ('Member' + str(index) + suffix)
        member.write_text('int member%d() { return %d; }\n' % (index, index), encoding='utf-8')
        member_paths.append(member)
        wrapper = source / ('SuperUnity.UBT.%d.cpp' % index)
        wrapper.write_text('// Compiler-authored UBT unity membership; copied into nvim cache.\n#include "'
            + member.as_posix() + '"\n', encoding='utf-8')
        originals.append({'directory': str(root), 'file': str(wrapper),
            'arguments': [str(executable), '-std=c++17', '-c', str(wrapper)],
            'nvim_ue_module_root': 'Source/Module', 'nvim_ue_members': [module.portable_member_path(str(member))]})
    exact = {'directory': str(root), 'file': str(root / 'exact.cpp'), 'arguments': [str(executable), 'exact.cpp']}
    shader = {'directory': str(root), 'file': str(root / 'shader.usf'), 'arguments': [str(executable), 'shader.usf']}
    entries = [originals[0], exact, originals[1], shader, originals[2], originals[3]]
    indexes = [0, 2, 4, 5]
    original = copy.deepcopy(entries)
    def call(rows=entries, selected=indexes, output=store, **kwargs):
        return module.accelerate(rows, output, str(executable), group_indexes=selected, **kwargs)
    def forbid_discovery():
        guards = contextlib.ExitStack()
        for name in ('_batch_groups', '_read_group_hints', '_save_group_hints', '_group_hint'):
            guards.enter_context(patch.object(module, name, side_effect=AssertionError('explicit group used '+name)))
        return guards
    def read_state(directory):
        return {str(p): (p.read_bytes(), p.stat().st_mtime_ns) for p in directory.rglob('*') if p.is_file()}

    if operation == 'invalid':
        scenarios = [(entries, value, {}) for value in ([], [0], True, '0,2', [False, 2], [0, 0], [2, 0], [-1, 0], [0, 6], [0, 2.0], [[0], 2])]
        scenarios += [(entries, indexes, options) for options in ({'max_group': 3}, {'max_group': True},
            {'max_group': 1.5}, {'max_sources': 3}, {'max_sources': False}, {'max_sources': 0})]
        scenarios += [(None, indexes, {}), ({}, indexes, {}), ('entries', indexes, {})]
        for bad in (None, [], {'file': None}, dict(exact, arguments=False)):
            rows = copy.deepcopy(entries); rows[1] = bad; scenarios.append((rows, indexes, {}))
        for position in (1, 3): scenarios.append((entries, [0, position], {}))
        for field in ('file', 'directory', 'arguments', 'nvim_ue_members', 'nvim_ue_module_root'):
            rows = copy.deepcopy(entries); rows[2].pop(field); scenarios.append((rows, indexes, {}))
        rows = copy.deepcopy(entries); rows[2]['nvim_ue_module_root'] = 'Other'; scenarios.append((rows, indexes, {}))
        rows = copy.deepcopy(entries); rows[2]['arguments'].insert(1, '-DOTHER=1'); scenarios.append((rows, indexes, {}))
        rows = copy.deepcopy(entries); rows[2]['file'] = str(source / 'SuperUnity.Batch.fake.cpp'); scenarios.append((rows, indexes, {}))
        rows = copy.deepcopy(entries); rows[2]['nvim_ue_members'] = entries[0]['nvim_ue_members']; scenarios.append((rows, indexes, {}))
        read_bytes = pathlib.Path.read_bytes
        def no_tool_read(path):
            assert path.resolve() != executable, 'invalid scope hashed executable'
            return read_bytes(path)
        with patch.object(pathlib.Path, 'read_bytes', no_tool_read), forbid_discovery():
            with patch.object(module, '_validate_ubt', side_effect=AssertionError('invalid limit inspected wrapper/overlay')):
                for number, limit in enumerate((False, 0, None, 1.5, '4')):
                    target = root / ('invalid-source-limit-%d' % number)
                    try: call(output=target, max_sources=limit)
                    except ValueError as error: assert str(error) == 'explicit-group-limits-invalid'
                    else: raise AssertionError('invalid explicit source limit accepted')
                    assert not target.exists()
            for number, (rows, selected, options) in enumerate(scenarios):
                target = root / ('invalid-%d' % number)
                try: call(rows, selected, target, **options)
                except ValueError: pass
                else: raise AssertionError(('invalid selection accepted', number))
                assert not target.exists(), 'invalid selection created output directory'
            # Real matching wrappers with overlapping members still reject.
            wrapper = pathlib.Path(entries[2]['file']); saved = wrapper.read_bytes()
            wrapper.write_bytes(pathlib.Path(entries[0]['file']).read_bytes())
            rows = copy.deepcopy(entries); rows[2]['nvim_ue_members'] = list(rows[0]['nvim_ue_members'])
            try:
                try: call(rows)
                except ValueError as error: assert str(error) == 'overlapping-original-members'
                else: raise AssertionError('overlapping complete wrappers accepted')
            finally: wrapper.write_bytes(saved)
            assert not store.exists()
        print('invalid indexes, original metadata/context, wrapper mismatch and overlap reject before output/tool work')

    elif operation == 'budgets':
        members = member_paths
        for member in members: member.write_bytes(b' ' * (393216 * 2))
        with forbid_discovery():
            output, metrics = call(verify_missing=False)
            assert output == entries and metrics['groups'][0]['original_indexes'] == indexes
            members[-1].write_bytes(members[-1].read_bytes() + b' ')
            try: call(output=root/'over-budget', verify_missing=False)
            except ValueError as error: assert str(error) == 'explicit-group-budget-exceeded'
            else: raise AssertionError('byte budget +1 accepted')
            assert not (root/'over-budget').exists()
            members[-1].write_bytes(b'int value;\n')
            planner, real_stat, missing_reads = module.secondary_unity_chunks, os.stat, []
            def unknown_size(*args, **kwargs):
                def unavailable(path, *rest, **options):
                    if os.path.normcase(os.path.abspath(path)) == os.path.normcase(str(members[-1])):
                        missing_reads.append(os.fspath(path))
                        raise OSError('injected size unavailable')
                    return real_stat(path, *rest, **options)
                with patch.object(os, 'stat', unavailable): return planner(*args, **kwargs)
            with patch.object(module, 'secondary_unity_chunks', side_effect=unknown_size):
                try: call(output=root/'unknown-size', verify_missing=False)
                except ValueError as error: assert str(error) == 'explicit-group-budget-exceeded'
                else: raise AssertionError('unknown source size accepted')
            assert not (root/'unknown-size').exists()
            assert missing_reads, 'the OS failure seam was not exercised'
        print('real byte boundary and unavailable stat preserve the existing conservative planner budget')

    elif operation in ('routing', 'bisection'):
        seen = []
        def rejected_proof(group, *args, **kwargs):
            seen.append(copy.deepcopy(group))
            raise ValueError('admission-rejected: source-reference-retargeted')
        with patch.object(module, '_prove', side_effect=rejected_proof), forbid_discovery():
            output, metrics = call(max_group=4)
        assert seen == [originals] and output == entries and all(a is b for a, b in zip(output, entries))
        assert metrics['new_proof_count'] == 1 and metrics['batch_count'] == 0 and len(metrics['groups']) == 1
        assert metrics['groups'][0]['reason'] == 'admission-rejected: source-reference-retargeted'
        assert entries == original and not (store/'accepted-groups.json').exists()
        seen.clear()
        with patch.object(module, '_prove', side_effect=rejected_proof):
            output, metrics = call(output=root/'default', selected=None, max_group=4)
        expected = [originals, originals[:2], originals[2:]] if operation == 'bisection' else [originals[:2], originals[2:]]
        assert seen == expected and output == entries, seen
        print('explicit exact mixed group runs once; None preserves class-first planning and admission bisection')

    elif operation == 'cache':
        assets = store/'assets'; assets.mkdir(parents=True)
        candidate_file = assets/'SuperUnity.Batch.contract.cpp'
        candidate_file.write_text(''.join('#include "'+member.as_posix()+'"\n' for member in member_paths), encoding='utf-8')
        candidate = dict(originals[0], file=str(candidate_file), arguments=[str(executable), '-std=c++17', '-c', str(candidate_file)],
            nvim_ue_members=[member for row in originals for member in row['nvim_ue_members']], nvim_ue_batch_ubt_count=4)
        identities = module._identities(executable, sha(executable.read_bytes()), imported=True)
        dependencies = [{'path': str(p), 'sha256': sha(p.read_bytes())} for p in sorted(source.iterdir())]
        inventories = module._inventories([str(source)], store, {})
        receipt_path = assets/'receipt.contract.json'
        receipt = {'schema': 2, 'output_dir': str(store), 'original_entries': [module._native(row) for row in originals],
            'candidate': module._native(candidate), 'identities': identities, 'dependencies': dependencies,
            'inventories': inventories, 'query_profiles': [], 'server_profile': None}
        receipt_path.write_text(module._json(receipt), encoding='utf-8')
        candidate.update(nvim_ue_batch_receipt=str(receipt_path), nvim_ue_batch_receipt_sha256=sha(receipt_path.read_bytes()))
        cache = {'schema': 1, 'accepted': True, 'reason': 'unit-cache-contract', 'first_proof_seconds': 1.0,
            'identities': identities, 'dependencies': dependencies, 'inventories': inventories, 'query_profiles': [],
            'original_entries': [module._native(row) for row in originals], 'candidate': candidate,
            'assets': [{'path':str(p),'sha256':sha(p.read_bytes())}for p in (candidate_file,receipt_path)]}
        key = module._cache_key(originals, identities, None)
        expected_key = sha(module._json({'entries': originals, 'collector':identities['collector'], 'tool':identities['tool'],
            'tool_path':identities['tool_path'],'compiler_environment':identities['compiler_environment'],'server_profile':None}).encode())
        assert key == expected_key
        cache_path=store/'receipts'/(key+'.json'); cache_path.parent.mkdir(); cache_path.write_text(module._json(cache))
        with forbid_discovery(), patch.object(module, '_prove', side_effect=AssertionError('cache reuse started proof')), \
                patch.object(module, '_write', side_effect=AssertionError('cache reuse wrote artifact')):
            before=read_state(store)
            for selected in (indexes, tuple(indexes)):
                output, metrics = call(selected=selected, verify_missing=False)
                assert metrics['cache_hits']==metrics['batch_count']==1 and metrics['new_proof_count']==0
                assert output == [dict(sorted(candidate.items())), exact, shader]
                assert output[1] is exact and output[2] is shader
            assert read_state(store)==before
            for changed in (member_paths[0], candidate_file):
                raw=changed.read_bytes(); stamp=changed.stat(); changed.write_bytes(b'X'+raw[1:])
                os.utime(changed,ns=(stamp.st_atime_ns,stamp.st_mtime_ns))
                try:
                    output,metrics=call(verify_missing=False)
                    assert output==entries and metrics['batch_count']==0 and metrics['deferred_group_count']==1
                finally: changed.write_bytes(raw)
            # Resealing bytes cannot make another original group's receipt match.
            raw=receipt_path.read_bytes(); foreign=copy.deepcopy(receipt); foreign['original_entries']=foreign['original_entries'][:2]
            receipt_path.write_text(module._json(foreign)); mutated=copy.deepcopy(cache)
            digest=sha(receipt_path.read_bytes()); mutated['candidate']['nvim_ue_batch_receipt_sha256']=digest
            mutated['assets'][-1]['sha256']=digest; cache_path.write_text(module._json(mutated))
            output,metrics=call(verify_missing=False)
            assert output==entries and metrics['batch_count']==0
            receipt_path.write_bytes(raw); cache_path.write_text(module._json(cache))
            cache_path.unlink()
            partial_key=module._cache_key(originals[:2],identities,None)
            (cache_path.parent/(partial_key+'.json')).write_text(module._json(cache))
            output,metrics=call(verify_missing=False)
            assert output==entries and metrics['batch_count']==0 and metrics['deferred_group_count']==1
        print('exact unchanged cache key, full real cache/group checks, immutable reuse and scoped misses verified; synthetic cache fixture only')
    else:
        raise AssertionError(operation)
]=]

local function run_fixture(operation)
  local python = vim.fn.exepath("python")
  if python == "" then python = vim.fn.exepath("python3") end
  if python == "" then
    t.skip("explicit strict API contract", "Python unavailable", { native = true })
    return
  end
  local script = vim.fn.tempname() .. "_explicit_strict.py"
  local stream = assert(io.open(script, "wb"))
  stream:write(fixture)
  stream:close()
  local result = vim.system({ python, "-B", "-I", script,
    vim.fn.stdpath("config") .. "/tools/cdb_verified_batch.py", operation }, { text = true }):wait()
  pcall(vim.fn.delete, script)
  t.assert_eq(result.code, 0, (result.stderr or "") .. (result.stdout or ""))
end

t.describe("Explicit strict group API contracts", function()
  for _, operation in ipairs({ "invalid", "budgets", "routing", "bisection", "cache" }) do
    t.it(operation, function() run_fixture(operation) end)
  end
end)
