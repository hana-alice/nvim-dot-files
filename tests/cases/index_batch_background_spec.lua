local t = require("tests.harness")
t.bootstrap()

local fixture = [=[
import importlib.util, json, os, pathlib, subprocess, sys, tempfile, time
from unittest.mock import patch
tool, operation = sys.argv[1:]
# Existing graph-proof fixtures explicitly exercise the supported strict mode.
os.environ['NVIM_UE_BATCH_TIER'] = 'strict'
spec = importlib.util.spec_from_file_location('background', tool)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
strict_accelerate = module.verified.accelerate

# Insert after strict_accelerate assignment in the existing Lua Python fixture.
# These cases exercise pure scheduler seams; existing operations retain real file/receipt gates.
if operation.startswith('pure_'):
    import copy
    from types import SimpleNamespace
    if operation == 'pure_strip_flags':
        hot = sys.modules['build_hot_super_unity_cdb']
        keep = object()
        cases = [([], []), (['clang++', '-Iinc', '-DVALUE=1', keep], ['clang++', '-Iinc', '-DVALUE=1', keep]),
            (['-mFout', 'x-MFout', '--dependency-file=x', '-M', '-MM'],
             ['-mFout', 'x-MFout', '--dependency-file=x', '-M', '-MM'])]
        for flag in hot.WRITE_ONLY_FLAGS:
            cases.append((['a', flag, 'b'], ['a', 'b']))
        for flag in hot.WRITE_ONLY_FLAGS_WITH_VALUE:
            cases.extend([(['a', flag, 'output', 'b'], ['a', 'b']), (['a', flag], ['a'])])
        for prefix in hot.WRITE_ONLY_PREFIXES:
            cases.append((['a', prefix + 'output', keep], ['a', keep]))
        class Argument:
            def __init__(self, value): self.value = value
            def __str__(self): return self.value
        retained = Argument('-Iinclude')
        cases.append(([Argument('-MF'), 'discard', retained, Argument('-MD'), keep], [retained, keep]))
        for values, expected in cases:
            before = list(values)
            for args in (values, tuple(values)):
                actual = hot.strip_write_only_flags(args)
                assert actual == expected and all(a is b for a, b in zip(actual, expected))
            assert values == before
        print('prefix options, operand precedence, tuple input and original objects preserved')
        sys.exit(0)

    def ubt(index):
        return {'directory': '/fixture', 'file': 'SuperUnity.UBT.%d.cpp' % index,
            'arguments': ['clang++', '-DFIXTURE=1'], 'nvim_ue_module_root': '/module',
            'nvim_ue_members': ['member%d.cpp' % index]}
    exact = {'directory': '/fixture', 'file': 'exact.cpp', 'arguments': ['clang++', 'exact.cpp']}
    shader = {'directory': '/fixture', 'file': 'shader.usf', 'arguments': ['clang++', 'shader.usf']}
    entries = [ubt(0), exact, ubt(1), ubt(2), shader, ubt(3), ubt(4), ubt(5)]
    original = copy.deepcopy(entries)
    if operation == 'pure_upgrade_sequence':
        sequence = {module._tuple_key(entries[0]): [0, 2, 3, 5, 6, 7]}
        requested = []
        def provider():
            requested.append(True)
            return sequence
        for indexes in ([0, 2], [3, 5], [6, 7]):
            assert module._upgrade_sequence(entries, indexes) is None
            assert module._upgrade_sequence(entries, indexes, sequence) is None
            assert module._upgrade_sequence(entries, indexes, sequence_provider=provider) is None
        assert len(requested) == 3
        with patch.object(module, '_tuple_key', wraps=module._tuple_key):
            module._upgrade_sequence(entries, [0, 2], sequence,
                sequence_provider=lambda: (_ for _ in ()).throw(AssertionError('explicit map lost precedence')))
        for indexes, reason, calls in (([], 'order-changed', 0), ([2, 0], 'order-changed', 0),
                ([0, 1], 'tuple-mismatch', 0), ([0, 3], 'sequence-gap', 1),
                ([0, 0], 'sequence-gap', 1)):
            for kwargs in ({}, {'sequences': sequence}, {'sequence_provider': provider}):
                requested.clear()
                try:
                    module._upgrade_sequence(entries, indexes, **kwargs)
                    raise AssertionError(('invalid sequence admitted', indexes))
                except ValueError as error:
                    assert str(error) == 'background-proof-upgrade-' + reason, str(error)
                assert len(requested) == (calls if 'sequence_provider' in kwargs else 0)
        assert entries == original
        print('default, mapping and lazy sequences preserve errors and provider ordering')
        sys.exit(0)

    assert operation == 'pure_reuse_sequences', operation
    packing = {'max_unities': 32, 'budget_factor': 32}
    ranges = [[0, 2], [3, 5], [6, 7]]
    catalog, tuple_calls, applied = [], [], []
    tuple_key = module._tuple_key
    failing = [False]
    def observed_tuple(entry):
        tuple_calls.append(entry['file'])
        if entry is shader and failing[0]:
            failing[0] = False
            raise ValueError('injected incomplete sequence scan')
        return tuple_key(entry)
    def identity(rows, mode): return 'owner-' + rows[0]['file']
    def reset_catalog():
        catalog[:] = [{'id': identity([entries[i] for i in indexes], '1'),
            'store': '/proofs/' + identity([entries[i] for i in indexes], '1'),
            'entry_hashes': [module._json(entries[i]) for i in indexes],
            'packing': dict(packing), 'upgrade_of': []} for indexes in ranges]
    def apply(rows, group, clangd, profile, replacements, records):
        applied.append(group['indexes'])
        return replacements, records, {'id': group['id'], 'accepted': False}
    def run(expected, scans, **kwargs):
        before = copy.deepcopy(entries)
        tuple_calls.clear(); applied.clear()
        rows, _ = module._reuse_completed(entries, '/proofs/legacy', 'unused', None,
            mode=kwargs.pop('mode', '1'), **kwargs)
        assert rows == entries == before and applied == expected, (applied, expected)
        assert tuple_calls.count(exact['file']) == scans, tuple_calls
    # Gate/file work is covered by existing fixture operations. Here each retained
    # original is returned; no receipt, disk path, hashing or native API is used.
    with patch.object(module, '_catalog', side_effect=lambda *args: catalog), \
         patch.object(module, '_sha', side_effect=lambda data: data.decode('utf-8')), \
         patch.object(module, '_cache_only', side_effect=lambda rows, *args:
             (list(rows), module._empty_metrics(rows))), \
         patch.object(module, '_identity', side_effect=identity), \
         patch.object(module, '_catalog_path', return_value=pathlib.PurePosixPath('/proofs/catalog.json')), \
         patch.object(module, 'Path', side_effect=lambda value: SimpleNamespace(
             resolve=lambda: pathlib.PurePosixPath(value))), \
         patch.object(module, '_chunks', side_effect=lambda rows, *args: [list(range(len(rows)))]), \
         patch.object(module, '_upgrade_relationships'), \
         patch.object(module, '_apply_upgrade', side_effect=apply), \
         patch.object(module, '_tuple_key', side_effect=observed_tuple):
        # _empty_metrics needs path suffixes; use fixed fixture-only counts.
        with patch.object(module, '_empty_metrics', return_value={'original_ubt_count': 6,
                'exact_count': 1, 'shader_count': 1, 'other_count': 0, 'groups': []}):
            reset_catalog(); run(ranges, 1)
            run([], 0, include_upgrades=False)
            run([], 0, mode='strict')
            catalog.clear(); run([], 0)
            reset_catalog()
            for group in catalog: group['ubt_count'] = 999
            run([], 0)
            reset_catalog(); failing[0] = True
            run(ranges[1:], 2)  # Failed first scan cannot publish its partial map.
            for entry in entries:
                entry['arguments'].append('-DFRESH_INVOCATION=1')
            reset_catalog(); run(ranges, 1)
            entries[3]['nvim_ue_members'] = ['member2.gen.cpp']
            reset_catalog(); run([ranges[0], ranges[2]], 1)
    print('one successful local scan, lazy exclusions, failed-scan retry and fresh invocation inputs preserved')
    sys.exit(0)


with tempfile.TemporaryDirectory(prefix='background_batch_') as temporary:
    root = pathlib.Path(temporary).resolve()
    source = root / 'semantic.json'
    store = root / 'verified_batches'
    store.mkdir()
    background, marker, plan_path = root / 'background.json', root / 'marker.json', root / 'plan.json'
    entries = []
    count = (96 if operation in ('tier1_auto_limits', 'tier1_auto_tuples') else
        48 if operation in ('tier1_auto_barriers', 'tier1_auto_adoption') else
        33 if operation == 'tier1_auto_bytes' else
        32 if operation.startswith(('tier1_upgrade_', 'tier1_auto_')) else
        2 if operation == 'strict_mixed' else 4)
    for index in range(count):
        suffix = '.gen.cpp' if ((operation == 'strict_mixed' and index == 1)
            or (operation.startswith('tier1_retry_') and index < 2)) else '.cpp'
        member = root / ('member%d' % index + suffix)
        member.write_text('int member%d() { return 1; }\n' % index, encoding='utf-8')
        wrapper = root / ('SuperUnity.UBT.Test.%d.cpp' % index)
        wrapper.write_text('// Compiler-authored UBT unity membership; copied into nvim cache.\n'
            + '#include "' + member.as_posix() + '"\n', encoding='utf-8')
        entries.append({'directory': str(root), 'file': str(wrapper),
            'arguments': ['clang++', '-x', 'c++', str(wrapper)],
            'nvim_ue_module_root': str(root / 'Module'),
            'nvim_ue_members': [module.verified.portable_member_path(str(member))]})
    exact = {'directory': str(root), 'file': str(root / 'exact.cpp'), 'arguments': ['clang++', 'exact.cpp']}
    shader = {'directory': str(root), 'file': str(root / 'test.usf'), 'arguments': ['clang++', 'test.usf'],
        'nvim_ue_background_route': 'shader-compatibility'}
    entries += [exact, shader]
    if operation.startswith('tier1_upgrade_prefix_'):
        prefix_headers = [root / 'ForcedFirst.h', root / 'ForcedSecond.h']
        for index, header in enumerate(prefix_headers):
            header.write_text('#define PREFIX_VALUE_%d 0\n' % index, encoding='utf-8')
        for entry in entries:
            if module.verified._is_ubt(entry):
                entry['arguments'][1:1] = [token for header in prefix_headers
                    for token in ('-include', str(header))]
        if operation == 'tier1_upgrade_prefix_overlay_scope':
            overlay_header = root / 'Shared.h'
            overlay_header.write_text('// owned header\n', encoding='utf-8')
            physical = [overlay_header] + prefix_headers
            physical += [pathlib.Path(entry['file']) for entry in entries if module.verified._is_ubt(entry)]
            physical += [pathlib.Path(module.verified._tier1_ubt_members(entry)[0])
                for entry in entries if module.verified._is_ubt(entry)]
            raw = module.verified._json({'version': 0, 'case-sensitive': False, 'use-external-names': True,
                'fallthrough': True, 'roots': [{'type': 'file', 'name': path.as_posix(),
                    'external-contents': path.as_posix()} for path in physical]}).encode()
            overlay = root / 'header-path-case' / ('header-path-case.' + module._sha(raw) + '.json')
            overlay.parent.mkdir(); overlay.write_bytes(raw)
            for entry in entries:
                if module.verified._is_ubt(entry):
                    entry['arguments'] += ['-ivfsoverlay', str(overlay)]
    source.write_text(json.dumps(entries), encoding='utf-8')
    background.write_text('previous background', encoding='utf-8')
    marker.write_text(json.dumps({'schema': 1, 'kept': 'original marker'}), encoding='utf-8')
    accepted_stores, calls = set(), []

    if operation.startswith('tier1_'):
        os.environ.pop('NVIM_UE_BATCH_TIER', None)
        assert module._mode() == '1', 'production default must be explicit'
        indexed = []
        def candidate_index(candidate, directory, clangd, timeout, server_profile=None):
            indexed.append(dict(candidate))
            assert timeout == 90 and server_profile is None
            if operation.startswith('tier1_retry_'):
                members = candidate['nvim_ue_members']
                classes = {member.lower().endswith('.gen.cpp') for member in members}
                failed = len(classes) > 1 or (operation == 'tier1_retry_child_failed' and classes == {False})
                if failed:
                    return {'background_compile_success': operation == 'tier1_retry_main_shard',
                        'missing_main_shards': [members[0]] if operation == 'tier1_retry_main_shard' else [],
                        'member_main_shards': [], 'indexing_complete': True, 'exit_code': 0,
                        'compile_failure_count': 0 if operation == 'tier1_retry_main_shard' else 1}
            if candidate.get('nvim_ue_tier1_recipe'):
                if operation == 'tier1_upgrade_prefix_timeout':
                    raise subprocess.TimeoutExpired(['clangd-fixture-only'], timeout)
                if operation == 'tier1_upgrade_prefix_rejected':
                    return {'background_compile_success': False, 'missing_main_shards': [],
                        'member_main_shards': [], 'indexing_complete': True, 'exit_code': 0,
                        'compile_failure_count': 1}
            large_upgrade = operation.startswith(('tier1_upgrade_', 'tier1_auto_')) and candidate.get('nvim_ue_tier1_ubt_count', 0) > 8
            if large_upgrade and operation in ('tier1_upgrade_failed_cached', 'tier1_auto_rejected'):
                return {'background_compile_success': False, 'missing_main_shards': [],
                    'member_main_shards': [], 'indexing_complete': True, 'exit_code': 0, 'compile_failure_count': 1}
            if large_upgrade and operation in ('tier1_upgrade_transient_retry', 'tier1_auto_timeout') and sum(
                    row.get('nvim_ue_tier1_ubt_count', 0) > 8 for row in indexed) == 1:
                raise subprocess.TimeoutExpired(['clangd-fixture-only'], 90)
            if operation == 'tier1_failed_cached':
                return {'background_compile_success': False, 'missing_main_shards': [],
                    'member_main_shards': [], 'indexing_complete': True, 'exit_code': 0, 'compile_failure_count': 1}
            if operation == 'tier1_transient_retry' and len(indexed) == 1:
                return {'background_compile_success': False, 'missing_main_shards': [],
                    'member_main_shards': [], 'indexing_complete': False, 'exit_code': 0, 'compile_failure_count': 0}
            return {'background_compile_success': True, 'missing_main_shards': [],
                'member_main_shards': [path for entry in entries if module.verified._is_ubt(entry)
                    for path in module.verified._tier1_ubt_members(entry)]}

        with patch.object(module.verified, '_tier1_candidate_index', side_effect=candidate_index), \
             patch.object(module.verified, 'accelerate', side_effect=AssertionError('strict path used')), \
             patch.object(module, '_owned_job', return_value=None):
            if operation.startswith('tier1_retry_'):
                def artifacts():
                    return {str(path): (path.read_bytes(), path.stat().st_mtime_ns)
                        for path in root.rglob('*') if path.is_file()}
                def coverage(rows):
                    assert rows[-2:] == [exact, shader]
                    assert module.verified._tier1_source_coverage(rows) == module.verified._tier1_source_coverage(entries)
                plan = module.make_plan(source, store, sys.executable)
                assert len(plan['groups']) == 1 and plan['groups'][0]['indexes'] == [0, 1, 2, 3]
                assert not indexed
                module._write(plan_path, plan)
                group = plan['groups'][0]
                worked = module.work(plan_path, group['id'], sys.executable)
                assert worked['ok'] and len(indexed) == 3, worked
                groups = worked['metrics']['groups']
                parent = next(record for record in groups if not record.get('fallback_of'))
                children = [record for record in groups if record.get('fallback_of')]
                assert not parent['accepted'] and len(children) == 2, groups
                assert all(record['fallback_of'] == parent['cache_key'] for record in children)
                assert [record['original_indexes'] for record in children] == [[0, 1], [2, 3]]
                result = module.collect(plan_path, [group['id']], background, marker, sys.executable)
                published = json.loads(background.read_text())
                coverage(published)
                expected = 1 if operation == 'tier1_retry_child_failed' else 2
                assert result['metrics']['batch_count'] == expected, result
                assert len(published) == 6 - expected, published
                assert len(indexed) == 3, 'collect cannot repeat private proof'
                for candidate in published:
                    if candidate.get('nvim_ue_tier1_receipt'):
                        receipt = json.loads(pathlib.Path(candidate['nvim_ue_tier1_receipt']).read_text())
                        assert receipt['fallback_of'] == parent['cache_key']
                before = artifacts()
                with patch.object(subprocess, 'run', side_effect=AssertionError('cache-only process')), \
                     patch.object(subprocess, 'Popen', side_effect=AssertionError('cache-only process')):
                    reused, metrics = module.reuse_completed(entries, store, sys.executable)
                    assert reused == published and metrics['batch_count'] == expected
                    assert module.make_plan(source, store, sys.executable)['groups'] == []
                    repeated = module.collect(plan_path, [group['id']], background, marker, sys.executable)
                    assert not repeated['changed']
                assert before == artifacts() and len(indexed) == 3
                if operation == 'tier1_retry_missing_child':
                    child = children[-1]
                    receipt_index = pathlib.Path(group['store']) / 'tier1' / 'receipts' / (child['cache_key'] + '.json')
                    receipt_index.unlink()
                    before = artifacts()
                    with patch.object(subprocess, 'run', side_effect=AssertionError('cache-only process')), \
                         patch.object(subprocess, 'Popen', side_effect=AssertionError('cache-only process')):
                        reused, metrics = module.reuse_completed(entries, store, sys.executable)
                        coverage(reused)
                        assert metrics['batch_count'] == 1 and reused[1:3] == entries[2:4], metrics
                        retry = module.make_plan(source, store, sys.executable)
                        assert retry['groups'] == [group], retry
                    assert before == artifacts() and len(indexed) == 3
                    module._write(plan_path, retry)
                    module.work(plan_path, group['id'], sys.executable)
                    restored = module.collect(plan_path, [group['id']], background, marker, sys.executable)
                    assert restored['metrics']['batch_count'] == 2 and len(indexed) == 4
                    assert json.loads(background.read_text()) == published
                    assert module.make_plan(source, store, sys.executable)['groups'] == []
                print('failed cross-class parent, independent retry owners, cache-only publication and missing-child recovery verified')
                sys.exit(0)
            if operation.startswith('tier1_auto_'):
                import copy
                packing = {'max_unities': 32, 'budget_factor': 32}
                def update_source():
                    source.write_text(json.dumps(entries), encoding='utf-8')
                def plan(auto=True):
                    return module.make_plan(source, store, sys.executable, auto_tier1_large=auto)
                def parents(value):
                    return [group for group in value['groups'] if group.get('schedule_role') == 'large-first']
                def children(value, parent):
                    return [group for group in value['groups'] if group.get('fallback_of') == parent['id']]
                def artifacts():
                    paths = [background, marker]
                    paths += list((store.parent / 'background-proofs').rglob('*')) + list(store.rglob('*'))
                    return {str(path): (path.read_bytes(), path.stat().st_mtime_ns) for path in paths if path.is_file()}
                def coverage(rows):
                    assert rows[-2:] == [exact, shader]
                    assert module.verified._tier1_source_coverage(rows) == module.verified._tier1_source_coverage(entries)
                def core_group(group):
                    return {key: value for key, value in group.items() if key not in ('schedule_role', 'fallback_of')}
                def assert_parent_shapes(value):
                    admitted = parents(value)
                    assert len(admitted) <= 2
                    selected = set()
                    ordinary = module._chunks(entries, '1')
                    for parent in admitted:
                        indexes = parent['indexes']
                        assert not selected.intersection(indexes), 'automatic parents overlap'
                        selected.update(indexes)
                        assert parent['packing'] == packing and len(indexes) <= 32
                        assert module._chunks([entries[i] for i in indexes], '1', packing) == [list(range(len(indexes)))]
                        for child in children(value, parent):
                            assert child['indexes'] in ordinary and set(child['indexes']).issubset(indexes)
                    assert value['deferred_fallback_count'] == sum('fallback_of' in group for group in value['groups'])
                    assert value['initially_ready_count'] == len(value['groups']) - value['deferred_fallback_count']
                def legacy_owner(indexes):
                    # A real small/explicit receipt qualifies this whole owner.
                    # Its grouping may come from an earlier narrower selection.
                    selected = [entries[i] for i in indexes]
                    identity = module._identity(selected, '1')
                    group = {'id': identity, 'indexes': indexes,
                        'store': str(module._catalog_path(store, '1').parent / identity),
                        'ubt_count': len(indexes), 'member_count': sum(len(row['nvim_ue_members']) for row in selected)}
                    if len(indexes) > 8:
                        group.update(packing=dict(packing), upgrade_of=[])
                    owner_plan = plan(False)
                    owner_plan['groups'] = [group]
                    module._write(plan_path, owner_plan)
                    result = module.work(plan_path, identity, sys.executable)
                    assert result['metrics']['batch_count'] == 1
                    collected = module.collect(plan_path, [identity], background, marker, sys.executable)
                    assert collected['metrics']['accepted_ubt_count'] == len(indexes)
                    rows = json.loads(background.read_text()); coverage(rows)
                    return group, rows

                if operation == 'tier1_auto_limits':
                    ordinary = plan(False)
                    proposed = plan(); assert_parent_shapes(proposed)
                    large = parents(proposed)
                    assert [group['indexes'] for group in large] == [list(range(32)), list(range(32, 64))]
                    assert proposed['groups'][:2] == large
                    assert proposed['deferred_fallback_count'] == 8 and proposed['initially_ready_count'] == 6
                    normal = {group['id']: group for group in ordinary['groups']}
                    for group in proposed['groups'][2:]:
                        assert core_group(group) == normal[group['id']]
                        if group['indexes'][0] >= 64: assert 'fallback_of' not in group
                    assert module.make_plan(source, store, sys.executable) == ordinary
                    assert 'tier1_large_policy' not in ordinary
                    with patch.dict(os.environ, {'NVIM_UE_BATCH_TIER': 'strict'}), \
                         patch.object(module.verified, 'accelerate', wraps=strict_accelerate), \
                         patch.object(subprocess, 'Popen', side_effect=AssertionError('strict planning spawned')):
                        strict_plain = module.make_plan(source, store, sys.executable)
                        assert module.make_plan(source, store, sys.executable, auto_tier1_large=True) == strict_plain
                        assert 'tier1_large_policy' not in strict_plain
                    assert not indexed
                    print('automatic max2 parents preserve ordinary IDs/count limits and leave disabled/strict plans unchanged')
                    sys.exit(0)

                if operation == 'tier1_auto_bytes':
                    first = plan(); assert_parent_shapes(first)
                    assert parents(first)[0]['indexes'] == list(range(32)), '33 tiny UBTs exceeded count limit'
                    entries = entries[:32] + [exact, shader]
                    update_source()  # Isolate the byte limit from the count limit below.
                    for index in range(32):
                        member = pathlib.Path(module.verified._tier1_ubt_members(entries[index])[0])
                        member.write_bytes(b'//' + b' ' * (393216 - 2))
                    exact_limit = plan(); assert_parent_shapes(exact_limit)
                    assert parents(exact_limit)[0]['indexes'] == list(range(32)), '12 MiB boundary must be inclusive'
                    last = pathlib.Path(module.verified._tier1_ubt_members(entries[31])[0])
                    last.write_bytes(last.read_bytes() + b' ')
                    exceeded = plan(); assert_parent_shapes(exceeded)
                    assert parents(exceeded)[0]['indexes'] == list(range(31)), 'byte overflow must not split a fallback atom'
                    unknown = pathlib.Path(module.verified._tier1_ubt_members(entries[0])[0])
                    unknown.unlink()
                    missing = plan(); assert_parent_shapes(missing)
                    assert all(0 not in group['indexes'] for group in parents(missing)), 'unknown-size original entered automatic proof'
                    assert not indexed
                    print('count32 and actual 12,582,912-member-byte limits, +1 and unknown input remain conservative')
                    sys.exit(0)

                if operation == 'tier1_auto_tuples':
                    cwd = root / 'other-cwd'; cwd.mkdir()
                    for index, entry in enumerate(entries[:-2]):
                        family = index // 16
                        if family in (1, 2):
                            original = pathlib.Path(module.verified._tier1_ubt_members(entry)[0])
                            generated = root / ('generated%d.gen.cpp' % index)
                            generated.write_text('int generated%d;\n' % index, encoding='utf-8')
                            member_paths = [generated] if family == 1 else [original, generated]
                            pathlib.Path(entry['file']).write_text('// Compiler-authored UBT unity membership; copied into nvim cache.\n'
                                + ''.join('#include "' + path.as_posix() + '"\n' for path in member_paths), encoding='utf-8')
                            entry['nvim_ue_members'] = [module.verified.portable_member_path(str(path)) for path in member_paths]
                        elif family == 3: entry['nvim_ue_module_root'] = str(root / 'OtherModule')
                        elif family == 4: entry['arguments'].append('-DOTHER_CONTEXT=1')
                        elif family == 5: entry['directory'] = str(cwd)
                    update_source()
                    proposed = plan(); assert_parent_shapes(proposed)
                    assert len(parents(proposed)) == 2
                    for parent in parents(proposed):
                        assert len({index // 16 for index in parent['indexes']}) == 1
                        assert len(parent['indexes']) == 16
                    assert not indexed
                    print('automatic groups retain module, argv, cwd and gen/src/mixed tuple boundaries')
                    sys.exit(0)

                if operation == 'tier1_auto_barriers':
                    owner, baseline = legacy_owner(list(range(8, 12)) + list(range(16, 20)))
                    proposed = plan(); assert_parent_shapes(proposed)
                    assert parents(proposed) and all(not set(range(8, 20)).intersection(group['indexes']) for group in parents(proposed))
                    assert any(group['indexes'] == list(range(20, 48)) for group in parents(proposed))
                    assert module.reuse_completed(entries, store, sys.executable)[0] == baseline and len(indexed) == 1
                    # A distinct private store proves the singleton-before-owner
                    # layout without reusing the noncontiguous owner's catalog.
                    store = root / 'singleton-case' / 'verified_batches'; store.mkdir(parents=True)
                    entries = entries[:17] + [exact, shader]
                    for entry in entries[:7]: entry['nvim_ue_module_root'] = str(root / 'FirstModule')
                    update_source()
                    owner, baseline = legacy_owner(list(range(8, 16)))
                    proposed = plan(); assert_parent_shapes(proposed)
                    large = parents(proposed)
                    assert len(large) == 1 and large[0]['indexes'] == list(range(7, 17))
                    assert large[0]['upgrade_of'] == [owner['id']]
                    assert module.reuse_completed(entries, store, sys.executable)[0] == baseline and len(indexed) == 2
                    print('whole accepted owners, singleton-before-owner and noncontiguous spans preserve existing receipts')
                    sys.exit(0)

                if operation == 'tier1_auto_budget_drift':
                    entries = entries[:15] + [exact, shader]
                    update_source()
                    for entry in entries[:-2]:
                        member = pathlib.Path(module.verified._tier1_ubt_members(entry)[0])
                        member.write_bytes(b'//' + b' ' * (800 * 1024 - 2))
                    ordinary = plan(False)
                    expected = [list(range(start, start + 3)) for start in range(0, 15, 3)]
                    assert [group['indexes'] for group in ordinary['groups']] == expected
                    proposed = plan(); assert_parent_shapes(proposed)
                    assert len(parents(proposed)) == 1
                    parent = parents(proposed)[0]
                    assert parent['indexes'] == list(range(15))
                    fallback = children(proposed, parent)
                    assert [core_group(group) for group in fallback] == ordinary['groups']
                    module._write(plan_path, proposed)
                    # 12,000 KiB fits the parent. The same plan's first child
                    # still fits 3 MiB after a real +300 KiB source edit, while
                    # the whole parent now exceeds its 12 MiB budget.
                    first = pathlib.Path(module.verified._tier1_ubt_members(entries[0])[0])
                    first.write_bytes(first.read_bytes() + b' ' * (300 * 1024))
                    assert module._chunks(entries, '1') == expected
                    before = artifacts()
                    try:
                        module.work(plan_path, parent['id'], sys.executable)
                        raise AssertionError('over-budget parent reached qualification')
                    except ValueError as error:
                        assert str(error) == 'background-proof-group-identity-mismatch'
                    assert not indexed and artifacts() == before
                    collected = module.collect(plan_path, [parent['id']], background, marker, sys.executable)
                    assert collected['ok'] and parent['id'] not in collected['revalidated_completed']
                    assert collected['upgrade_observations'] == [{'id': parent['id'],
                        'original_indexes': parent['indexes'], 'accepted': False,
                        'reason': 'background-proof-group-identity-mismatch'}]
                    assert json.loads(background.read_text()) == entries and not indexed
                    coverage(json.loads(background.read_text()))
                    child = fallback[0]
                    worked = module.work(plan_path, child['id'], sys.executable)
                    assert worked['metrics']['batch_count'] == 1
                    assert len(indexed) == 1 and indexed[0]['nvim_ue_tier1_ubt_count'] == 3
                    admitted = module.collect(plan_path, [parent['id'], child['id']], background, marker, sys.executable)
                    assert admitted['ok'] and admitted['revalidated_completed'] == [child['id']]
                    assert admitted['metrics']['batch_count'] == 1 and admitted['metrics']['accepted_ubt_count'] == 3
                    rows = json.loads(background.read_text()); coverage(rows)
                    assert rows[0]['nvim_ue_tier1_ubt_count'] == 3 and rows[1:] == entries[3:]
                    assert len(indexed) == 1, 'collect retried a stale parent or qualified unrelated fallback jobs'
                    print('source budget drift rejects only the large parent; its unchanged legal fallback can qualify and publish')
                    sys.exit(0)

                ordinary = plan(False)
                proposed = plan(); assert_parent_shapes(proposed)
                large = parents(proposed)
                parent = large[0]
                assert parent['indexes'] == list(range(32)) and parent['upgrade_of'] == []
                fallback = children(proposed, parent)
                assert len(fallback) == 4
                original_groups = {group['id']: group for group in ordinary['groups']}
                assert all(core_group(group) == original_groups[group['id']] for group in fallback)
                assert not indexed
                module._write(plan_path, proposed)

                if operation == 'tier1_auto_forged_links':
                    before = artifacts()
                    cases = []
                    def changed(): return copy.deepcopy(proposed)
                    bad = changed(); bad['groups'][1]['fallback_of'] = '0' * 64; cases.append(bad)
                    bad = changed(); bad['groups'][1]['fallback_of'] = [parent['id'], parent['id']]; cases.append(bad)
                    bad = changed(); bad['groups'][1]['fallback_of'] = bad['groups'][1]['id']; cases.append(bad)
                    bad = changed(); bad['groups'][0]['fallback_of'] = bad['groups'][1]['id']; cases.append(bad)
                    bad = changed(); bad['groups'].append(copy.deepcopy(bad['groups'][1])); cases.append(bad)
                    bad = changed(); bad['groups'][0].pop('schedule_role'); cases.append(bad)
                    bad = changed(); bad['groups'][0]['indexes'].reverse(); cases.append(bad)
                    bad = changed(); partial = bad['groups'][1]; partial['indexes'] = partial['indexes'][:-1]
                    partial['id'] = module._identity([entries[i] for i in partial['indexes']], '1')
                    partial['store'] = str(module._catalog_path(store, '1').parent / partial['id'])
                    partial['ubt_count'] = partial['member_count'] = len(partial['indexes']); cases.append(bad)
                    bad = changed(); overlap = copy.deepcopy(bad['groups'][0]); overlap['indexes'] = list(range(16))
                    overlap['id'] = module._identity(entries[:16], '1'); overlap['store'] = str(module._catalog_path(store, '1').parent / overlap['id'])
                    overlap['ubt_count'] = overlap['member_count'] = 16; bad['groups'].append(overlap); cases.append(bad)
                    bad = changed(); gap = bad['groups'][0]; gap['indexes'].remove(8)
                    gap['id'] = module._identity([entries[i] for i in gap['indexes']], '1')
                    gap['store'] = str(module._catalog_path(store, '1').parent / gap['id'])
                    gap['ubt_count'] = gap['member_count'] = 31
                    for group in bad['groups'][1:]: group['fallback_of'] = gap['id']
                    cases.append(bad)
                    for bad in cases:
                        bad['plan_candidate_count'] = len(bad['groups'])
                        bad['deferred_fallback_count'] = sum('fallback_of' in group for group in bad['groups'])
                        bad['initially_ready_count'] = len(bad['groups']) - bad['deferred_fallback_count']
                        module._write(plan_path, bad)
                        for action in (lambda: module.work(plan_path, bad['groups'][0]['id'], sys.executable),
                                lambda: module.collect(plan_path, [bad['groups'][0]['id']], background, marker, sys.executable)):
                            try:
                                action(); raise AssertionError('forged scheduling plan admitted')
                            except ValueError:
                                pass
                        assert artifacts() == before and not indexed
                    print('real work/collect admission reject forged, cyclic, duplicate, partial, reordered and overlapping family links')
                    sys.exit(0)

                worked = module.work(plan_path, parent['id'], sys.executable)
                assert len(indexed) == 1 and indexed[0]['nvim_ue_tier1_ubt_count'] == 32
                if operation == 'tier1_auto_fresh':
                    # The CLI, rather than work(), persists the --out result.
                    module._write(plan_path.parent / ('result-' + parent['id'] + '.json'), worked)
                    recovered = module.make_plan(source, store, sys.executable,
                        previous_path=plan_path, auto_tier1_large=True)
                    assert_parent_shapes(recovered)
                    assert parent['id'] in [item['id'] for item in recovered['recovered_completed']]
                    assert [group['id'] for group in parents(recovered)] == [parent['id']]
                    assert {group['id'] for group in children(recovered, parent)} == {group['id'] for group in fallback}
                    assert len(indexed) == 1, 'restart requalified a successful uncollected parent'
                    module._write(plan_path, recovered)
                if operation == 'tier1_auto_adoption':
                    owner, baseline = legacy_owner(list(range(24, 40)))
                    reused, active = module.reuse_completed(entries, store, sys.executable)
                    assert reused == baseline, 'the blocking owner must already be selected and published'
                    assert [group['original_indexes'] for group in active['groups'] if group.get('accepted')] == [list(range(24, 40))]
                    module._write(plan_path, proposed)
                    collected = module.collect(plan_path, [parent['id']], background, marker, sys.executable)
                    rows = json.loads(background.read_text()); coverage(rows)
                    assert parent['id'] not in collected['revalidated_completed']
                    assert rows == baseline and collected['metrics']['accepted_ubt_count'] == 16
                    catalog = json.loads(module._catalog_path(store).read_text())
                    assert parent['id'] not in [group['id'] for group in catalog['groups']], \
                        'a proven but unadopted parent must not enter later cache selection'
                    reused, active = module.reuse_completed(entries, store, sys.executable)
                    assert reused == baseline and active['accepted_ubt_count'] == 16
                    assert [group['original_indexes'] for group in active['groups'] if group.get('accepted')] == [list(range(24, 40))]
                    assert len(indexed) == 2, 'collector requalified a covered fallback'
                    print('a valid large receipt gains no scheduling acknowledgment when a new whole owner blocks adoption')
                    sys.exit(0)
                collected = module.collect(plan_path, [parent['id']], background, marker, sys.executable)
                rows = json.loads(background.read_text()); coverage(rows)
                if operation in ('tier1_auto_rejected', 'tier1_auto_timeout'):
                    assert worked['metrics']['batch_count'] == 0 and parent['id'] not in collected['revalidated_completed']
                    assert rows == entries
                    again = plan(); assert_parent_shapes(again)
                    if operation == 'tier1_auto_rejected':
                        assert not parents(again)
                        assert again['groups'] == ordinary['groups'], 'cached rejection must immediately expose original fallback jobs'
                    else:
                        assert parents(again)[0]['id'] == parent['id'], 'timeout cannot be a persistent negative receipt'
                    assert len(indexed) == 1
                    print('large rejection/timeout retains originals; only completed rejection suppresses later parent work')
                    sys.exit(0)
                assert operation == 'tier1_auto_fresh'
                assert worked['metrics']['batch_count'] == 1 and parent['id'] in collected['revalidated_completed']
                assert collected['metrics']['accepted_ubt_count'] == 32 and len(rows) == 3
                assert not any(pathlib.Path(group['store']).exists() for group in fallback), 'fresh parent secretly required child receipts'
                before = artifacts()
                assert plan()['groups'] == []
                recovered_selected = module.make_plan(source, store, sys.executable,
                    previous_path=plan_path, auto_tier1_large=True)
                assert not any(group['id'] == parent['id'] for group in recovered_selected['groups']), \
                    'an already selected parent remained pending after restart'
                assert module.reuse_completed(entries, store, sys.executable)[0] == rows
                repeated = module.collect(plan_path, [parent['id']], background, marker, sys.executable)
                assert not repeated['changed'] and artifacts() == before and len(indexed) == 1
                candidate = pathlib.Path(rows[0]['file']); candidate.write_bytes(candidate.read_bytes() + b'\n// changed\n')
                retained, metrics = module.reuse_completed(entries, store, sys.executable)
                assert retained == entries and metrics['batch_count'] == 0
                invalidated = module.collect(plan_path, [parent['id']], background, marker, sys.executable)
                assert parent['id'] not in invalidated['revalidated_completed'] and json.loads(background.read_text()) == entries
                again = plan()
                assert {core_group(group)['id'] for group in again['groups'] if 'packing' not in group} == set(original_groups)
                assert len(indexed) == 1
                print('fresh parent alone qualifies, collector acknowledges, repeats are read-only, and invalidation restores ordinary fallback definitions')
                sys.exit(0)
            # This source is inserted inside the existing Tier 1 fixture's patched context.
            if operation.startswith('tier1_upgrade_'):
                import copy

                packing = {'max_unities': 32, 'budget_factor': 32}

                def proposal(selected, **changes):
                    value = {'entry_hashes': [module._sha(module._json(entry).encode('utf-8')) for entry in selected],
                        'packing': dict(packing)}
                    value.update(changes)
                    return value

                def native_rows(rows):
                    return [module.verified._native(row) for row in rows]

                def artifact_state():
                    paths = [background, marker]
                    paths += sorted((store.parent / 'background-proofs').rglob('*'))
                    paths += sorted(store.rglob('*'))
                    return {str(path): (path.read_bytes(), path.stat().st_mtime_ns)
                        for path in paths if path.is_file()}

                def assert_coverage(rows):
                    assert module.verified._tier1_source_coverage(rows) == module.verified._tier1_source_coverage(entries)
                    assert rows[-2:] == [exact, shader]
                    source_names = [member for row in rows[:-2] for member in row['nvim_ue_members']]
                    assert len(source_names) == len(set(source_names)) == 32

                if operation == 'tier1_upgrade_legacy_boundary':
                    # Only the second owner is accepted in the legacy/root store. Proposal
                    # [7..15] is singleton 7 plus the WHOLE current owner [8..15]; regrouping
                    # the selected nine originals would incorrectly invent owner [7..14].
                    entries = entries[:16] + entries[-2:]
                    source.write_text(json.dumps(entries), encoding='utf-8')
                    baseline, proof = module.verified.accelerate_tier1(entries[8:16], store,
                        sys.executable, max_group=8, budget_factor=8)
                    assert proof['batch_count'] == 1 and len(indexed) == 1
                    assert not module._catalog_path(store).exists()
                    reused, metrics = module.reuse_completed(entries, store, sys.executable)
                    assert reused == entries[:8] + baseline + [exact, shader]
                    assert metrics['batch_count'] == 1 and metrics['accepted_ubt_count'] == 8
                    request = proposal(entries[7:16])
                    planned = module.make_plan(source, store, sys.executable, tier1_upgrades=[request])
                    upgrades = [group for group in planned['groups'] if group.get('packing')]
                    assert len(upgrades) == 1 and upgrades[0]['indexes'] == list(range(7, 16)), planned
                    group = upgrades[0]
                    assert group['upgrade_of'] == [module._identity(entries[8:16], '1')]
                    module._write(plan_path, planned)
                    worked = module.work(plan_path, group['id'], sys.executable)
                    assert worked['metrics']['batch_count'] == 1 and len(indexed) == 2
                    collected = module.collect(plan_path, [group['id']], background, marker, sys.executable)
                    rows = json.loads(background.read_text())
                    assert rows[:7] == entries[:7] and rows[-2:] == [exact, shader]
                    assert len(rows) == 10 and rows[7]['nvim_ue_tier1_ubt_count'] == 9
                    assert collected['metrics']['batch_count'] == 1 and collected['metrics']['accepted_ubt_count'] == 9
                    assert module.verified._tier1_source_coverage(rows) == module.verified._tier1_source_coverage(entries)
                    before = artifact_state()
                    assert module.reuse_completed(entries, store, sys.executable)[0] == rows
                    repeated = module.collect(plan_path, [group['id']], background, marker, sys.executable)
                    assert not repeated['changed'] and before == artifact_state() and len(indexed) == 2
                    print('full CURRENT owner [8..15] stays whole when upgraded with adjacent singleton 7')
                    sys.exit(0)

                baseline_plan = module.make_plan(source, store, sys.executable)
                expected_chunks = [list(range(start, start + 8)) for start in range(0, 32, 8)]
                assert module._chunks(entries, '1') == expected_chunks
                assert [group['indexes'] for group in baseline_plan['groups']] == expected_chunks
                for group, indexes in zip(baseline_plan['groups'], expected_chunks):
                    selected = [entries[index] for index in indexes]
                    # Existing wire identity is tier + ordered original metadata, without packing.
                    expected_id = module._sha(json.dumps({'tier': 1, 'entries': selected},
                        ensure_ascii=False, separators=(',', ':')).encode('utf-8'))
                    assert group == {'id': expected_id, 'indexes': indexes,
                        'store': str(store.parent / 'background-proofs' / 'tier1' / expected_id),
                        'ubt_count': 8, 'member_count': 8}, group
                module._write(plan_path, baseline_plan)
                old_ids = [group['id'] for group in baseline_plan['groups']]
                for identity in old_ids:
                    worked = module.work(plan_path, identity, sys.executable)
                    assert worked['metrics']['batch_count'] == 1 and worked['metrics']['new_proof_count'] == 1
                baseline_collect = module.collect(plan_path, old_ids, background, marker, sys.executable)
                baseline_rows = json.loads(background.read_text())
                baseline_catalog = json.loads(module._catalog_path(store).read_text())
                assert baseline_collect['metrics']['batch_count'] == 4
                assert baseline_collect['metrics']['accepted_ubt_count'] == 32
                assert len(baseline_rows) == 6 and len(indexed) == 4
                assert [row['nvim_ue_tier1_ubt_count'] for row in baseline_rows[:-2]] == [8] * 4
                assert_coverage(baseline_rows)

                if operation == 'tier1_upgrade_defaults':
                    before = artifact_state()
                    for kwargs in ({}, {'tier1_upgrades': []}, {'tier1_upgrades': [proposal(entries[:8])]}):
                        again = module.make_plan(source, store, sys.executable, **kwargs)
                        assert again['groups'] == [] and again['legacy_batch_count'] == 4
                        reused, metrics = module.reuse_completed(entries, store, sys.executable)
                        assert reused == baseline_rows and metrics['batch_count'] == 4
                    repeated = module.collect(plan_path, old_ids, background, marker, sys.executable)
                    assert not repeated['changed'] and artifact_state() == before and len(indexed) == 4
                    print('default max8 group IDs, accepted output, exact/shader and no-op bytes remain unchanged')
                    sys.exit(0)

                # Insert inside the established tier1_upgrade_* branch AFTER the real flat baseline.
                if operation.startswith('tier1_upgrade_prefix_'):
                    recipe = 'tier1-ordered-absolute-forced-prefix-v1'
                    selected = entries[:8]
                    request = proposal(selected, recipe=recipe)
                    before = artifact_state()
                    calls_before = len(indexed)
                    assert module.make_plan(source, store, sys.executable,
                        tier1_upgrades=[proposal(selected)])['groups'] == []
                    if operation == 'tier1_upgrade_prefix_reject_proposals':
                        invalid = [proposal(entries[:7], recipe=recipe), proposal(entries[:9], recipe=recipe),
                            proposal(entries[:16], recipe=recipe), proposal(list(reversed(selected)), recipe=recipe)]
                        invalid += [dict(request, recipe=value) for value in ('unknown', None, {}, True)]
                        for bad in invalid:
                            try:
                                module.make_plan(source, store, sys.executable, tier1_upgrades=[bad])
                            except ValueError:
                                pass
                            else:
                                raise AssertionError(('invalid recipe proposal accepted', bad))
                            assert artifact_state() == before and len(indexed) == calls_before
                        with patch.dict(os.environ, {'NVIM_UE_BATCH_TIER': 'strict'}):
                            try:
                                module.make_plan(source, store, sys.executable, tier1_upgrades=[request])
                            except ValueError:
                                pass
                            else:
                                raise AssertionError('recipe entered strict mode')
                        print('partial/multiple-owner/unknown recipe proposals reject without writes')
                        sys.exit(0)
                    planned = module.make_plan(source, store, sys.executable, tier1_upgrades=[request])
                    assert len(planned['groups']) == 1
                    group = planned['groups'][0]
                    assert group['indexes'] == list(range(8)) and group['recipe'] == recipe
                    assert group['id'] != old_ids[0] and group['upgrade_of'] == [old_ids[0]]
                    assert artifact_state() == before and len(indexed) == calls_before
                    for field, value in (('recipe', 'unknown'), ('recipe', None), ('id', old_ids[0]),
                                         ('store', str(root / 'foreign-store')), ('upgrade_of', [old_ids[1]])):
                        bad = copy.deepcopy(planned)
                        bad['groups'][0][field] = value
                        try:
                            module._group(bad, entries, bad['groups'][0]['id'])
                        except ValueError:
                            pass
                        else:
                            raise AssertionError(('forged recipe group accepted', field))
                    if operation == 'tier1_upgrade_prefix_parent_binding':
                        partial = entries[:4]
                        partial_id = module._identity(partial, '1')
                        partial_store = module._catalog_path(store).parent / partial_id
                        partial_rows, partial_metrics = module.verified.accelerate_tier1(partial,
                            partial_store, sys.executable, max_group=32, budget_factor=32)
                        assert partial_metrics['batch_count'] == 1 and len(partial_rows) == 1
                        catalog = json.loads(module._catalog_path(store).read_text())
                        descriptor = {'id': partial_id, 'store': str(partial_store),
                            'entry_hashes': proposal(partial)['entry_hashes'], 'packing': dict(packing),
                            'upgrade_of': []}
                        module._write(module._catalog_path(store), dict(catalog, groups=catalog['groups'] + [descriptor]))
                        bad = copy.deepcopy(planned)
                        bad['groups'][0]['upgrade_of'] = [partial_id]
                        current = artifact_state()
                        try:
                            module._group(bad, entries, group['id'])
                        except ValueError:
                            pass
                        else:
                            raise AssertionError('valid partial flat descriptor authorized a whole recipe parent')
                        assert artifact_state() == current and len(indexed) == calls_before + 1
                        assert module.reuse_completed(entries, store, sys.executable)[0] == baseline_rows
                        print('recipe parent must describe the same complete original scope')
                        sys.exit(0)
                    module._write(plan_path, planned)
                    flat_receipt = pathlib.Path(baseline_rows[0]['nvim_ue_tier1_receipt'])
                    if operation == 'tier1_upgrade_prefix_overlay_scope':
                        policy = module.verified._owned_overlay_policy()
                        real_reuse, real_qualify = module._reuse_completed, module.verified.accelerate_tier1
                        owner_checks, qualify_entries = [], []
                        with patch.object(policy, 'validate_owned_overlay', wraps=policy.validate_owned_overlay) as validate:
                            def observe_reuse(*args, **kwargs):
                                previous = validate.call_count
                                try:
                                    return real_reuse(*args, **kwargs)
                                finally:
                                    owner_checks.append(validate.call_count - previous)
                            def observe_qualify(*args, **kwargs):
                                qualify_entries.append(module.verified._TIER1_OVERLAY_SCOPE_DEPTH)
                                assert module.verified._TIER1_OVERLAY_SCOPE_DEPTH == 0
                                assert not module.verified._OWNED_OVERLAY_MEMO and not module.verified._TIER1_BLOB_MEMO
                                return real_qualify(*args, **kwargs)
                            with patch.object(module, '_reuse_completed', side_effect=observe_reuse), \
                                 patch.object(module.verified, 'accelerate_tier1', side_effect=observe_qualify):
                                first = module.work(plan_path, group['id'], sys.executable)
                                assert first['metrics']['new_proof_count'] == 1 and len(indexed) == calls_before + 1
                                current = artifact_state()
                                repeated = module.work(plan_path, group['id'], sys.executable)
                                assert repeated['metrics']['new_proof_count'] == 0 and repeated['metrics']['receipt_reuse']
                                assert artifact_state() == current and len(indexed) == calls_before + 1
                                print('recipe owner physical validations:', owner_checks)
                                assert owner_checks == [1, 1], owner_checks
                                assert qualify_entries == [0, 0] and module.verified._TIER1_OVERLAY_SCOPE_DEPTH == 0
                                overlay_header.unlink()  # Unchanged overlay bytes; the next call must check physical names again.
                                current = artifact_state()
                                try:
                                    module.work(plan_path, group['id'], sys.executable)
                                except ValueError as error:
                                    assert 'current-flat-owner-required' in str(error), error
                                else:
                                    raise AssertionError('next recipe worker reused a stale physical namespace')
                                assert owner_checks[-1] > 0 and len(owner_checks) == 3
                                assert qualify_entries == [0, 0], 'qualification must not run after owner loss'
                                assert artifact_state() == current and len(indexed) == calls_before + 1
                                assert module.verified._TIER1_OVERLAY_SCOPE_DEPTH == 0
                                assert not module.verified._OWNED_OVERLAY_MEMO and not module.verified._TIER1_BLOB_MEMO
                        print('recipe owner checks share one outer scope, leave qualification separate, and recheck next-call names')
                        sys.exit(0)
                    if operation == 'tier1_upgrade_prefix_owner_lost_work':
                        flat_receipt.unlink()
                        current = artifact_state()
                        try:
                            module.work(plan_path, group['id'], sys.executable)
                        except ValueError as error:
                            assert 'current-flat-owner-required' in str(error), error
                        else:
                            raise AssertionError('recipe work survived loss of current flat owner')
                        assert artifact_state() == current and len(indexed) == calls_before
                        print('initial recipe work revalidates its current flat owner')
                        sys.exit(0)
                    premature = module.collect(plan_path, [group['id']], background, marker, sys.executable)
                    assert group['id'] not in premature['revalidated_completed']
                    assert artifact_state() == before and json.loads(background.read_text()) == baseline_rows
                    worked = module.work(plan_path, group['id'], sys.executable)
                    assert worked['metrics']['new_proof_count'] == 1 and len(indexed) == calls_before + 1
                    assert group['id'] not in {row['id'] for row in module._catalog(store)}
                    if operation == 'tier1_upgrade_prefix_owner_expanded_collect':
                        bigger_plan = module.make_plan(source, store, sys.executable,
                                                      tier1_upgrades=[proposal(entries[:16])])
                        bigger = next(row for row in bigger_plan['groups'] if row.get('packing'))
                        bigger_path = root / 'bigger-plan.json'
                        module._write(bigger_path, bigger_plan)
                        assert module.work(bigger_path, bigger['id'], sys.executable)['metrics']['batch_count'] == 1
                        module.collect(bigger_path, [bigger['id']], background, marker, sys.executable)
                        actual = json.loads(background.read_text())
                        assert [row['nvim_ue_tier1_ubt_count'] for row in actual[:-2]] == [16, 8, 8]
                        current = artifact_state()
                        result = module.collect(plan_path, [group['id']], background, marker, sys.executable)
                        assert group['id'] not in result['revalidated_completed']
                        assert json.loads(background.read_text()) == actual and artifact_state() == current
                        assert group['id'] not in {row['id'] for row in module._catalog(store)}
                        assert len(indexed) == calls_before + 2
                        assert_coverage(actual)
                        print('valid recipe proof cannot replace part of a later current16 owner')
                        sys.exit(0)
                    if operation in ('tier1_upgrade_prefix_post_body', 'tier1_upgrade_prefix_post_header'):
                        if operation.endswith('_body'):
                            receipt = json.loads(pathlib.Path(worked['metrics']['groups'][0]['receipt']).read_text())
                            target = pathlib.Path(receipt['candidate']['file'])
                            target.write_bytes(target.read_bytes() + b'\n// changed after work\n')
                        else:
                            target = prefix_headers[0]
                            raw, stamp = target.read_bytes(), target.stat()
                            changed = raw.replace(b' 0', b' 1', 1)
                            assert changed != raw and len(changed) == len(raw)
                            target.write_bytes(changed)
                            os.utime(target, ns=(stamp.st_atime_ns, stamp.st_mtime_ns))
                        current = artifact_state()
                        result = module.collect(plan_path, [group['id']], background, marker, sys.executable)
                        assert group['id'] not in result['revalidated_completed']
                        assert json.loads(background.read_text()) == baseline_rows and artifact_state() == current
                        assert group['id'] not in {row['id'] for row in module._catalog(store)}
                        print('post-work drift cannot persist an adopted recipe preference')
                        sys.exit(0)
                    if operation in ('tier1_upgrade_prefix_rejected', 'tier1_upgrade_prefix_timeout'):
                        assert worked['metrics']['batch_count'] == 0
                        current = artifact_state()
                        result = module.collect(plan_path, [group['id']], background, marker, sys.executable)
                        assert group['id'] not in result['revalidated_completed']
                        assert json.loads(background.read_text()) == baseline_rows and artifact_state() == current
                        assert group['id'] not in {row['id'] for row in module._catalog(store)}
                        again = module.make_plan(source, store, sys.executable, tier1_upgrades=[request])
                        pending = group['id'] in {row['id'] for row in again['groups']}
                        assert pending is operation.endswith('_timeout')
                        assert len(indexed) == calls_before + 1
                        print('negative recipe cache never becomes catalog preference; timeout remains retryable')
                        sys.exit(0)
                    assert worked['metrics']['batch_count'] == 1
                    collected = module.collect(plan_path, [group['id']], background, marker, sys.executable)
                    adopted = json.loads(background.read_text())
                    assert group['id'] in collected['revalidated_completed']
                    assert collected['metrics']['batch_count'] == 4 and collected['metrics']['accepted_ubt_count'] == 32
                    assert adopted[0] != baseline_rows[0] and adopted[1:] == baseline_rows[1:]
                    assert_coverage(adopted)
                    catalog = json.loads(module._catalog_path(store).read_text())
                    assert {row['id'] for row in catalog['groups']} == set(old_ids + [group['id']])
                    module._write(module._catalog_path(store), dict(catalog, groups=list(reversed(catalog['groups']))))
                    assert module.reuse_completed(entries, store, sys.executable)[0] == adopted
                    module.collect(plan_path, [group['id']], background, marker, sys.executable)
                    stable = artifact_state()
                    with patch.object(module.verified, '_tier1_candidate_index', side_effect=AssertionError('repeat indexed')):
                        assert module.reuse_completed(entries, store, sys.executable)[0] == adopted
                        assert module.make_plan(source, store, sys.executable, tier1_upgrades=[request])['groups'] == []
                        repeat_work = module.work(plan_path, group['id'], sys.executable)
                        assert repeat_work['metrics']['new_proof_count'] == 0
                        repeated = module.collect(plan_path, [group['id']], background, marker, sys.executable)
                        assert not repeated['changed'] and group['id'] in repeated['revalidated_completed']
                    assert artifact_state() == stable and len(indexed) == calls_before + 1
                    flat_raw, flat_stamp = flat_receipt.read_bytes(), flat_receipt.stat()
                    flat_receipt.unlink()
                    missing_flat_state = artifact_state()
                    assert module.reuse_completed(entries, store, sys.executable)[0] == adopted
                    assert artifact_state() == missing_flat_state
                    flat_receipt.write_bytes(flat_raw)
                    os.utime(flat_receipt, ns=(flat_stamp.st_atime_ns, flat_stamp.st_mtime_ns))
                    header = prefix_headers[0]
                    raw, stamp = header.read_bytes(), header.stat()
                    changed = raw.replace(b' 0', b' 1', 1)
                    assert changed != raw and len(changed) == len(raw)
                    header.write_bytes(changed)
                    os.utime(header, ns=(stamp.st_atime_ns, stamp.st_mtime_ns))
                    assert header.stat().st_size == stamp.st_size and header.stat().st_mtime_ns == stamp.st_mtime_ns
                    current = artifact_state()
                    assert module.reuse_completed(entries, store, sys.executable)[0] == baseline_rows
                    assert artifact_state() == current
                    flat_receipt.unlink()
                    expected = entries[:8] + baseline_rows[1:]
                    assert module.reuse_completed(entries, store, sys.executable)[0] == expected
                    assert_coverage(expected)
                    assert len(indexed) == calls_before + 1
                    print('recipe adoption/repeat/persisted receipt independence/same-stamp header fallback passed')
                    sys.exit(0)

                request = proposal(entries[:24])
                upgrade_plan = module.make_plan(source, store, sys.executable, tier1_upgrades=[request])
                assert len(upgrade_plan['groups']) == 1, upgrade_plan
                upgrade = upgrade_plan['groups'][0]
                assert upgrade['indexes'] == list(range(24)) and upgrade['ubt_count'] == upgrade['member_count'] == 24
                assert upgrade['packing'] == packing and set(upgrade['upgrade_of']) == set(old_ids[:3])
                assert upgrade['id'] == module._identity(entries[:24], '1')
                assert json.loads(background.read_text()) == baseline_rows and len(indexed) == 4
                module._write(plan_path, upgrade_plan)

                if operation == 'tier1_upgrade_reject_proposals':
                    before = artifact_state()
                    invalid = [
                        proposal(entries[1:25]),                  # Partial first/last owners.
                        proposal(entries[:8] + entries[16:24]),    # Skips a whole middle owner.
                        proposal(list(reversed(entries[:24]))),  # Source order is authority.
                        proposal(entries[:23]),                  # Drops the final owner's member.
                        proposal(entries[:23] + [entries[0]]),   # Duplicate input identity.
                        proposal(entries[:23] + [exact]),
                        proposal(entries[:23] + [shader]),
                        dict(request, entry_hashes=request['entry_hashes'][:-1] + ['0' * 64]),
                    ]
                    invalid += [dict(request, packing=value) for value in (
                        {'max_unities': 0, 'budget_factor': 32},
                        {'max_unities': True, 'budget_factor': 32},
                        {'max_unities': 33, 'budget_factor': 32},
                        {'max_unities': 32, 'budget_factor': 33},
                        {'max_unities': 8, 'budget_factor': 32},
                        {'max_unities': 32, 'budget_factor': 0},
                        {'max_unities': 32},
                    )]
                    for bad in invalid:
                        try:
                            module.make_plan(source, store, sys.executable, tier1_upgrades=[bad])
                            raise AssertionError(('invalid explicit proposal admitted', bad))
                        except ValueError:
                            pass
                        assert artifact_state() == before and len(indexed) == 4
                    raw_source = source.read_bytes()
                    wrapper = pathlib.Path(entries[0]['file'])
                    raw_wrapper = wrapper.read_bytes()
                    for kind in ('module', 'context', 'class'):
                        changed = copy.deepcopy(entries)
                        if kind == 'module':
                            changed[0]['nvim_ue_module_root'] = str(root / 'OtherModule')
                        elif kind == 'context':
                            changed[0]['arguments'].append('-DUPGRADE_CONTEXT_CHANGED=1')
                        else:
                            generated = root / 'member0.gen.cpp'
                            generated.write_text('int generated_member0;\n', encoding='utf-8')
                            changed[0]['nvim_ue_members'] = [module.verified.portable_member_path(str(generated))]
                            wrapper.write_text('// Compiler-authored UBT unity membership; copied into nvim cache.\n'
                                + '#include "' + generated.as_posix() + '"\n', encoding='utf-8')
                        source.write_text(json.dumps(changed), encoding='utf-8')
                        try:
                            try:
                                module.make_plan(source, store, sys.executable, tier1_upgrades=[proposal(changed[:24])])
                                raise AssertionError(('mixed tuple admitted', kind))
                            except ValueError:
                                pass
                        finally:
                            source.write_bytes(raw_source)
                            wrapper.write_bytes(raw_wrapper)
                        assert artifact_state() == before and len(indexed) == 4
                    with patch.dict(os.environ, {'NVIM_UE_BATCH_TIER': 'strict'}):
                        try:
                            module.make_plan(source, store, sys.executable, tier1_upgrades=[request])
                            raise AssertionError('Tier1 packing entered strict mode')
                        except ValueError:
                            pass
                    for field, value in (('store', str(root / 'unbound-store')),
                            ('upgrade_of', ['forged-old-owner'])):
                        tampered = copy.deepcopy(upgrade_plan)
                        tampered['groups'][0][field] = value
                        try:
                            module._group(tampered, entries, upgrade['id'])
                            raise AssertionError(('tampered group accepted', field))
                        except ValueError:
                            pass
                    assert artifact_state() == before and len(indexed) == 4
                    print('explicit malformed proposals and bound-plan tampering reject without changing accepted owners')
                    sys.exit(0)

                if operation == 'tier1_upgrade_claimed_unproved':
                    before = artifact_state()
                    result = module.collect(plan_path, [upgrade['id']], background, marker, sys.executable)
                    assert upgrade['id'] not in result['revalidated_completed'], result
                    assert result['metrics']['batch_count'] == 4 and json.loads(background.read_text()) == baseline_rows
                    assert not result['changed'] and artifact_state() == before and len(indexed) == 4
                    again = module.make_plan(source, store, sys.executable, tier1_upgrades=[request])
                    assert [group['id'] for group in again['groups']] == [upgrade['id']]
                    print('old claimed coverage cannot certify or hide an unproven new large candidate')
                    sys.exit(0)

                if operation == 'tier1_upgrade_order':
                    requests = [proposal(entries[:16]), proposal(entries[8:24])]
                    pair_plan = module.make_plan(source, store, sys.executable, tier1_upgrades=requests)
                    assert {tuple(group['indexes']) for group in pair_plan['groups']} == {tuple(range(16)), tuple(range(8, 24))}
                    module._write(plan_path, pair_plan)
                    for group in pair_plan['groups']:
                        module.work(plan_path, group['id'], sys.executable)
                    ids = [group['id'] for group in pair_plan['groups']]
                    selected_id = module._identity(entries[:16], '1')
                    expected_rows = expected_catalog = None
                    for completion_order in (ids, list(reversed(ids))):
                        module._write(module._catalog_path(store), baseline_catalog)
                        module._write(background, baseline_rows)
                        result = module.collect(plan_path, completion_order, background, marker, sys.executable)
                        rows = json.loads(background.read_text())
                        catalog = json.loads(module._catalog_path(store).read_text())
                        assert result['metrics']['batch_count'] == 3 and result['metrics']['accepted_ubt_count'] == 32
                        assert pathlib.Path(rows[0]['nvim_ue_tier1_receipt']).parents[2].name == selected_id
                        assert [row['nvim_ue_tier1_ubt_count'] for row in rows[:-2]] == [16, 8, 8]
                        assert_coverage(rows)
                        if expected_rows is None:
                            expected_rows, expected_catalog = rows, catalog
                        assert rows == expected_rows and catalog == expected_catalog
                        reversed_catalog = dict(catalog, groups=list(reversed(catalog['groups'])))
                        module._write(module._catalog_path(store), reversed_catalog)
                        reused, metrics = module.reuse_completed(entries, store, sys.executable)
                        assert reused == expected_rows and metrics['batch_count'] == 3
                        module.collect(plan_path, completion_order, background, marker, sys.executable)
                        before = artifact_state()
                        repeated = module.collect(plan_path, list(reversed(completion_order)), background, marker, sys.executable)
                        assert not repeated['changed'] and artifact_state() == before
                    assert len(indexed) == 6
                    print('catalog/completion ordering cannot change overlap selection or repeat-publication bytes')
                    sys.exit(0)

                worked = module.work(plan_path, upgrade['id'], sys.executable)
                assert worked['ok'] and len(indexed) == 5
                result = module.collect(plan_path, [upgrade['id']], background, marker, sys.executable)
                if operation in ('tier1_upgrade_failed_cached', 'tier1_upgrade_transient_retry'):
                    assert worked['metrics']['batch_count'] == 0
                    assert result['metrics']['batch_count'] == 4 and json.loads(background.read_text()) == baseline_rows
                    assert upgrade['id'] not in result['revalidated_completed']
                    again = module.make_plan(source, store, sys.executable, tier1_upgrades=[request])
                    if operation == 'tier1_upgrade_failed_cached':
                        assert upgrade['id'] not in [group['id'] for group in again['groups']], again
                        assert len(indexed) == 5
                        print('deterministic large-candidate rejection is cached while old owners stay selected')
                        sys.exit(0)
                    assert [group['id'] for group in again['groups']] == [upgrade['id']], again
                    module._write(plan_path, again)
                    retry = module.work(plan_path, upgrade['id'], sys.executable)
                    result = module.collect(plan_path, [upgrade['id']], background, marker, sys.executable)
                    assert retry['metrics']['batch_count'] == 1 and len(indexed) == 6

                published = json.loads(background.read_text())
                assert result['metrics']['batch_count'] == 2 and result['metrics']['accepted_ubt_count'] == 32
                assert [row['nvim_ue_tier1_ubt_count'] for row in published[:-2]] == [24, 8]
                assert published[1] == baseline_rows[3] and published[-2:] == [exact, shader]
                assert upgrade['id'] in result['revalidated_completed']
                assert_coverage(published)
                selected = [row for row in result['groups'] if row.get('accepted')]
                assert len(selected) == 2 and sorted(len(row['original_indexes']) for row in selected) == [8, 24]
                catalog = json.loads(module._catalog_path(store).read_text())
                assert set(old_ids + [upgrade['id']]).issubset({group['id'] for group in catalog['groups']})

                if operation == 'tier1_upgrade_fallback':
                    large = pathlib.Path(published[0]['file'])
                    data, info = large.read_bytes(), large.stat()
                    large.write_bytes(data + b'\n// corrupt private candidate\n')
                    fallback, metrics = module.reuse_completed(entries, store, sys.executable)
                    assert fallback == baseline_rows and metrics['batch_count'] == 4
                    large.write_bytes(data)
                    os.utime(large, ns=(info.st_atime_ns, info.st_mtime_ns))
                    recovered, metrics = module.reuse_completed(entries, store, sys.executable)
                    assert recovered == published and metrics['batch_count'] == 2
                    member = pathlib.Path(module.verified._tier1_ubt_members(entries[0])[0])
                    member.write_text('int changed_private_member0() { return 2; }\n', encoding='utf-8')
                    fallback, metrics = module.reuse_completed(entries, store, sys.executable)
                    assert fallback == entries[:8] + baseline_rows[1:]
                    assert metrics['batch_count'] == 3 and metrics['accepted_ubt_count'] == 24
                    assert_coverage(fallback)
                    assert len(indexed) == 5
                    print('large asset failure restores old owners; a changed member invalidates only its old owner')
                    sys.exit(0)

                before = artifact_state()
                calls_before = len(indexed)
                reused, metrics = module.reuse_completed(entries, store, sys.executable)
                assert reused == published and metrics['batch_count'] == 2
                assert module.make_plan(source, store, sys.executable)['groups'] == []
                assert module.make_plan(source, store, sys.executable, tier1_upgrades=[request])['groups'] == []
                repeated = module.collect(plan_path, [upgrade['id']], background, marker, sys.executable)
                assert not repeated['changed'] and artifact_state() == before and len(indexed) == calls_before
                print('whole-owner upgrade and catalog-only reuse preserve unrelated owner and all repeated output bytes')
                sys.exit(0)
            if operation == 'tier1_overlay_scope':
                header = root / 'Shared.h'
                header.write_text('// owned header\n', encoding='utf-8')
                physical = [header] + [pathlib.Path(entry['file']) for entry in entries[:4]]
                physical += [pathlib.Path(module.verified._tier1_ubt_members(entry)[0]) for entry in entries[:4]]
                raw = module.verified._json({'version': 0, 'case-sensitive': False, 'use-external-names': True,
                    'fallthrough': True, 'roots': [{'type': 'file', 'name': path.as_posix(),
                        'external-contents': path.as_posix()} for path in physical]}).encode()
                overlay = root / 'header-path-case' / ('header-path-case.' + module._sha(raw) + '.json')
                overlay.parent.mkdir()
                overlay.write_bytes(raw)
                for index, entry in enumerate(entries[:4]):
                    entry['nvim_ue_module_root'] = str(root / ('Module%d' % (index // 2)))
                    entry['arguments'] += ['-ivfsoverlay', str(overlay)]
                source.write_text(json.dumps(entries), encoding='utf-8')
                plan = module.make_plan(source, store, sys.executable)
                module._write(plan_path, plan)
                assert len(plan['groups']) == 2
                for group in plan['groups']: module.work(plan_path, group['id'], sys.executable)
                policy = module.verified._owned_overlay_policy()
                with patch.object(policy, 'validate_owned_overlay', wraps=policy.validate_owned_overlay) as validate:
                    collected = module.collect(plan_path, [g['id'] for g in plan['groups']],
                        background, marker, sys.executable)
                    assert collected['metrics']['batch_count'] == 2
                    assert validate.call_count == 1, ('collect repeated physical validation', validate.call_count)
                    validate.reset_mock()
                    output, metrics = module.reuse_completed(entries, store, sys.executable)
                    assert metrics['batch_count'] == 2 and validate.call_count == 1
                    validate.reset_mock()
                    for group in plan['groups']:
                        selected = [entries[i] for i in group['indexes']]
                        _, reused = module.verified.reuse_tier1(selected, group['store'], sys.executable)
                        assert reused['batch_count'] == 1
                    assert validate.call_count == 2, 'independent reuse calls must each revalidate physical names'
                    validate.reset_mock()
                    header.unlink()  # Overlay bytes are unchanged; its physical namespace changed.
                    retained, metrics = module.reuse_completed(entries, store, sys.executable)
                    assert retained == entries and metrics['batch_count'] == 0 and validate.call_count > 0
                    header.write_text('// owned header\n', encoding='utf-8')
                    with module.verified.tier1_overlay_scope():
                        module.verified._owned_overlays(entries[0])
                        overlay.write_bytes(raw + b' ')
                        try:
                            module.verified._owned_overlays(entries[1])
                            raise AssertionError('scope reused stale overlay bytes')
                        except ValueError as error:
                            assert str(error) == 'header-overlay-content-hash-mismatch'
                    overlay.write_bytes(raw)
                    validate.reset_mock()
                    _, metrics = module.reuse_completed(entries, store, sys.executable)
                    assert metrics['batch_count'] == 2 and validate.call_count == 1
                assert len(indexed) == 2, 'cache reuse must never repeat private proof'
                print('one physical overlay validation per outer call; later namespace and byte changes rechecked')
                sys.exit(0)
            if operation == 'tier1_byte_budget':
                # More than strict's 80-source ceiling still fits the byte budget.
                expanded = []
                for index, entry in enumerate(entries[:2]):
                    members = []
                    for number in range(41):
                        path = root / ('small%d_%d.cpp' % (index, number))
                        path.write_text('int tiny%d_%d;\n' % (index, number), encoding='utf-8')
                        members.append(path)
                    pathlib.Path(entry['file']).write_text(
                        '// Compiler-authored UBT unity membership; copied into nvim cache.\n'
                        + ''.join('#include "' + path.as_posix() + '"\n' for path in members), encoding='utf-8')
                    expanded.append(dict(entry, nvim_ue_members=[
                        module.verified.portable_member_path(str(path)) for path in members]))
                source.write_text(json.dumps(expanded), encoding='utf-8')
                plan = module.make_plan(source, store, sys.executable)
                assert len(plan['groups']) == 1 and plan['groups'][0]['member_count'] == 82
                assert module._chunks(expanded, 'strict') == []
                assert not indexed
                print('default Tier 1 planning uses byte budget, retaining all 82 members')
                sys.exit(0)

            plan = module.make_plan(source, store, sys.executable)
            assert plan['mode'] == '1' and len(plan['groups']) == 1 and not indexed
            module._write(plan_path, plan)
            group = plan['groups'][0]
            assert pathlib.Path(group['store']).parent == store.parent / 'background-proofs' / 'tier1'
            if operation == 'tier1_mode_isolation':
                with patch.dict(os.environ, {'NVIM_UE_BATCH_TIER': 'strict'}):
                    try:
                        module.work(plan_path, group['id'], sys.executable)
                        raise AssertionError('Tier 1 plan admitted in strict mode')
                    except ValueError as error:
                        assert str(error) == 'background-proof-plan-tier-mismatch'
                    assert module._catalog_path(store) != pathlib.Path(group['store']).parent / 'catalog.json'
                assert not indexed
                print('tier mode binds plans, catalogs and worker admission')
                sys.exit(0)

            worked = module.work(plan_path, group['id'], sys.executable)
            assert worked['ok'] and worked['mode'] == '1' and len(indexed) == 1
            result = module.collect(plan_path, [group['id']], background, marker, sys.executable)
            assert result['ok'] and len(indexed) == 1, 'collect must only reuse the private proof'
            if operation == 'tier1_transient_retry':
                assert result['metrics']['batch_count'] == 0 and json.loads(background.read_text()) == entries
                again = module.make_plan(source, store, sys.executable)
                assert len(again['groups']) == 1 and again['proof_rejected_count'] == 0, again
                module._write(plan_path, again)
                module.work(plan_path, group['id'], sys.executable)
                recovered = module.collect(plan_path, [group['id']], background, marker, sys.executable)
                assert len(indexed) == 2 and recovered['metrics']['batch_count'] == 1, recovered
                print('transient failure remains eligible through collect, catalog and repeated prepare')
                sys.exit(0)
            if operation == 'tier1_failed_cached':
                assert result['metrics']['batch_count'] == 0
                assert json.loads(background.read_text()) == entries
                again = module.make_plan(source, store, sys.executable)
                assert again['groups'] == [] and again['proof_rejected_count'] == 1
                assert len(indexed) == 1
                assert any(record.get('cached') and not record.get('accepted')
                    and record['reason'] == 'tier1-candidate-index-failed' for record in result['groups'])
                print('failed proof cache retains originals and avoids repeated work scheduling')
                sys.exit(0)

            published = json.loads(background.read_text())
            assert len(published) == 3 and published[-2:] == [exact, shader]
            candidate = published[0]
            assert candidate.get('nvim_ue_tier1_receipt') and not candidate.get('nvim_ue_batch_receipt')
            assert result['metrics']['accepted_ubt_count'] == 4
            if operation == 'tier1_member_changed':
                pathlib.Path(module.verified._tier1_ubt_members(entries[0])[0]).write_text(
                    'int changed;\n', encoding='utf-8')
                reused, metrics = module.reuse_completed(entries, store, sys.executable)
                assert reused == entries and metrics['batch_count'] == 0 and len(indexed) == 1
                assert len(module.make_plan(source, store, sys.executable)['groups']) == 1
                print('member bytes invalidate Tier 1 prepare reuse without starting clangd')
            elif operation == 'tier1_receipt_tamper':
                receipt = pathlib.Path(candidate['nvim_ue_tier1_receipt'])
                receipt.write_bytes(receipt.read_bytes() + b' ')
                reused, metrics = module.reuse_completed(entries, store, sys.executable)
                assert reused == entries and metrics['batch_count'] == 0
                result = module.collect(plan_path, [group['id']], background, marker, sys.executable)
                assert json.loads(background.read_text()) == entries and len(indexed) == 1
                print('corrupt content-addressed receipt retains all original commands')
            else:
                stamps = [(path.read_bytes(), path.stat().st_mtime_ns) for path in
                    (background, marker, module._catalog_path(store))]
                reused, metrics = module.reuse_completed(entries, store, sys.executable)
                assert reused == published and metrics['batch_count'] == 1
                assert module.encode_preserving(background, reused).encode('utf-8') == background.read_bytes()
                repeated = module.collect(plan_path, [group['id']], background, marker, sys.executable)
                assert not repeated['changed'] and len(indexed) == 1
                assert stamps == [(path.read_bytes(), path.stat().st_mtime_ns) for path in
                    (background, marker, module._catalog_path(store))]
                assert module.make_plan(source, store, sys.executable)['groups'] == []
                print('plan/work/collect and prepare reuse preserve identical Tier 1 CDB bytes')
        sys.exit(0)

    split_behavior = 'exact'

    def gate(selected, output_dir, clangd, **options):
        calls.append((list(selected), str(output_dir), options))
        ubt_indexes = [index for index, entry in enumerate(selected) if module.verified._is_ubt(entry)]
        accepted = str(output_dir) in accepted_stores
        chunks = module._chunks(selected, 'strict')
        # Inserted at the beginning of the existing strict gate's accepted branch.
        if operation.startswith('strict_split_') and accepted:
            behavior = split_behavior if str(output_dir) != str(store) else 'exact'
            partitions = [[0, 1], [2, 3]]
            if behavior == 'wrong_partition':
                partitions = [[0, 2], [1, 3]]
            elif behavior == 'incomplete':
                partitions = [[0, 1]]
            anchors, consumed, groups = {}, set(), []
            for indexes in partitions:
                label = '-'.join(str(index) for index in indexes)
                wrapper = root / ('SuperUnity.Split.' + label + '.cpp')
                candidate = {'directory': str(root), 'file': str(wrapper),
                    'arguments': ['clang++', str(wrapper)],
                    'nvim_ue_batch_receipt': str(root / ('receipt.' + label + '.json'))}
                if behavior == 'wrong_candidate' and indexes == [0, 1]:
                    # Same native command, different certificate: full candidate object
                    # equality matters, not only argv or the already-covered indexes.
                    candidate['nvim_ue_batch_receipt'] = str(root / 'wrong-receipt.json')
                anchors[min(indexes)] = candidate
                consumed.update(index for index in indexes if index != min(indexes))
                groups.append({'accepted': True, 'original_indexes': indexes, 'cached': True})
            output = [anchors.get(index, entry) for index, entry in enumerate(selected) if index not in consumed]
            return output, {'original_ubt_count': len(ubt_indexes),
                'exact_count': sum(entry == exact for entry in selected),
                'shader_count': sum(entry == shader for entry in selected), 'other_count': 0,
                'batch_count': len(partitions), 'groups': groups}
        if accepted and chunks:
            indexes = chunks[0]
            candidate = {'directory': str(root), 'file': str(root / 'SuperUnity.Batch.cpp'),
                'arguments': ['clang++', 'SuperUnity.Batch.cpp'],
                'nvim_ue_batch_receipt': str(pathlib.Path(output_dir) / 'receipt.json')}
            output = [candidate if index == min(indexes) else entry for index, entry in enumerate(selected)
                if index not in indexes or index == min(indexes)]
            groups = [{'accepted': True, 'original_indexes': indexes, 'cached': True}]
        else:
            output, groups = list(selected), [{'accepted': False, 'original_indexes': chunk,
                'reason': 'admission-rejected:fixture-binding', 'deferred': not options['verify_missing']}
                for chunk in chunks]
        metrics = {'original_ubt_count': len(ubt_indexes), 'exact_count': sum(entry == exact for entry in selected),
            'shader_count': sum(entry == shader for entry in selected), 'other_count': 0,
            'batch_count': int(accepted and bool(chunks)), 'groups': groups}
        return output, metrics

    with patch.object(module.verified, 'accelerate', side_effect=gate), \
         patch.object(module, '_owned_job', return_value=None):
        plan = module.make_plan(source, store, 'clangd')
        module._write(plan_path, plan)
        group = plan['groups'][0]
        if operation.startswith('strict_split_'):
            assert group['indexes'] == [0, 1, 2, 3]
            pathlib.Path(group['store']).mkdir(parents=True)
            accepted_stores.add(group['store'])
            first = module.collect(plan_path, [group['id']], background, marker, 'clangd')
            expected = json.loads(background.read_text())
            assert first['metrics']['batch_count'] == 2 and first['metrics']['accepted_ubt_count'] == 4
            assert len(expected) == 4 and expected[-2:] == [exact, shader]
            catalog_path = module._catalog_path(store)
            catalog = json.loads(catalog_path.read_text())
            assert [row['id'] for row in catalog['groups']] == [group['id']]
            result_path = plan_path.parent / ('result-' + group['id'] + '.json')
            result_path.write_text(json.dumps({'ok': True, 'group_id': group['id'],
                'input_sha256': plan['input_sha256'], 'metrics': {'new_batch_count': 2}}), encoding='utf-8')
            if operation == 'strict_split_exact':
                # The parent plan is complete, but its cache yields two real admitted
                # subgroups. Recovered hints must retain this parent and its catalog.
                recovered = module.make_plan(source, store, 'clangd', previous_path=plan_path)
                assert recovered['plan_candidate_count'] == 0
                assert recovered['groups'] == [group]
                assert recovered['recovered_completed'] == [{'id': group['id'], 'accepted_hint': 2}]
                module._write(plan_path, recovered)
            else:
                # Current baseline is independently reusable through the root store;
                # the completed parent's current result must agree with each owner.
                accepted_stores.add(str(store))
                split_behavior = operation.removeprefix('strict_split_')
            before = [(path.read_bytes(), path.stat().st_mtime_ns) for path in (background, marker, catalog_path)]
            for _ in range(2):
                result = module.collect(plan_path, [group['id']], background, marker, 'clangd')
                assert result['metrics']['batch_count'] == 2 and result['metrics']['accepted_ubt_count'] == 4
                assert json.loads(background.read_text()) == expected and not result['changed']
                assert json.loads(catalog_path.read_text()) == catalog
                assert before == [(path.read_bytes(), path.stat().st_mtime_ns) for path in (background, marker, catalog_path)]
                if operation == 'strict_split_exact':
                    assert result['revalidated_completed'] == [group['id']]
                else:
                    assert group['id'] not in result['revalidated_completed'], result
            assert module.reuse_completed(entries, store, 'clangd')[0] == expected
            assert all(not options['verify_missing'] for _, _, options in calls)
            print('strict split parent/catalog kept; only exact complete child-owner identity reports revalidated: ' + operation)
            sys.exit(0)
        if operation == 'strict_mixed':
            assert plan['mode'] == 'strict' and len(plan['groups']) == 1
            assert group['indexes'] == [0, 1] and group['member_count'] == 2
            assert module._chunks(entries, '1') == [[0, 1]], 'Tier 1 now combines matching src/gen contexts'
            assert module._group(plan, entries, group['id'])[1] == entries[:2]
            missing = root / 'missing-store'
            retained, deferred = module._cache_only(entries, missing, 'clangd', None, 'strict')
            assert retained == entries and not missing.exists()
            assert [record['original_indexes'] for record in deferred['groups']] == [[0, 1]]
            assert deferred['groups'][0]['reason'] == 'verification-not-cached'
            # Only the admission result is mocked: native graph equivalence is
            # exercised by index_verified_batch's source/generated fixtures.
            accepted_stores.add(group['store'])
            pathlib.Path(group['store']).mkdir(parents=True)
            worked = module.work(plan_path, group['id'], 'clangd')
            assert worked['ok'] and worked['metrics']['batch_count'] == 1
            assert calls[-1][2]['verify_missing']
            calls.clear()
            collected = module.collect(plan_path, [group['id']], background, marker, 'clangd')
            assert collected['metrics']['accepted_ubt_count'] == 2
            published = json.loads(background.read_text())
            assert len(published) == 3 and published[-2:] == [exact, shader]
            stamps = [(path.read_bytes(), path.stat().st_mtime_ns)
                      for path in (background, marker, module._catalog_path(store))]
            reused, metrics = module.reuse_completed(entries, store, 'clangd')
            assert reused == published and metrics['batch_count'] == 1
            assert module.make_plan(source, store, 'clangd')['groups'] == []
            repeated = module.collect(plan_path, [group['id']], background, marker, 'clangd')
            assert not repeated['changed']
            assert stamps == [(path.read_bytes(), path.stat().st_mtime_ns)
                              for path in (background, marker, module._catalog_path(store))]
            assert all(not options['verify_missing'] for _, _, options in calls)
            print('strict mixed plan, worker identity, collect and cache-only reuse agree; Tier 1 combines classes')
        elif operation == 'plan':
            stamp = plan_path.stat().st_mtime_ns
            module._write(plan_path, module.make_plan(source, store, 'clangd'))
            assert plan_path.stat().st_mtime_ns == stamp
            assert plan['entry_count'] == 6 and plan['counts']['shader_count'] == 1
            assert group['indexes'] == [0, 1, 2, 3] and 'entries' not in group
            assert plan['plan_candidate_count'] == 1 and plan['proof_accepted_count'] == 0
            assert plan['selector_reuse_status'] == 'zero-hit'
            assert pathlib.Path(group['store']).parent == store.parent / 'background-proofs'
            assert all(not options['verify_missing'] for _, _, options in calls)
            print('small deterministic plan and read-only discovery verified')
        elif operation == 'recover_hints':
            result_path = plan_path.parent / ('result-' + group['id'] + '.json')
            result_path.write_text(json.dumps({'ok': True, 'group_id': group['id'],
                'input_sha256': plan['input_sha256'], 'metrics': {'new_batch_count': 1}}), encoding='utf-8')
            recovered = module.make_plan(source, store, 'clangd', previous_path=plan_path)
            assert recovered['recovered_completed'] == [{'id': group['id'], 'accepted_hint': 1}]
            module._write(plan_path, recovered)
            # Historical ok has no admission power: absent current receipts retain all originals.
            result = module.collect(plan_path, [group['id']], background, marker, 'clangd')
            assert result['metrics']['batch_count'] == 0 and result['revalidated_completed'] == []
            assert json.loads(background.read_text()) == entries
            accepted_stores.add(group['store'])
            pathlib.Path(group['store']).mkdir(exist_ok=True)
            result = module.collect(plan_path, [group['id']], background, marker, 'clangd')
            assert result['revalidated_completed'] == [group['id']]
            assert result['metrics']['batch_count'] == 1
            # Reuse can remove an old accepted group from ordinary candidates;
            # recovery must still enter collect before any remaining proof work.
            again = module.make_plan(source, store, 'clangd', previous_path=plan_path)
            assert again['plan_candidate_count'] == 0
            assert again['recovered_completed'] == [{'id': group['id'], 'accepted_hint': 1}]
            assert again['groups'] == [group]
            module._write(plan_path, again)
            result = module.collect(plan_path, [group['id']], background, marker, 'clangd')
            assert result['revalidated_completed'] == [group['id']]
            assert result['metrics']['batch_count'] == 1
            result_path.write_text(json.dumps({'ok': True, 'group_id': group['id'],
                'input_sha256': 'stale', 'metrics': {'new_batch_count': 1}}), encoding='utf-8')
            assert module.make_plan(source, store, 'clangd', previous_path=plan_path)['recovered_completed'] == []
            print('historical hints require current input and independent receipt revalidation')
        elif operation == 'input_changed':
            before = (background.read_bytes(), marker.read_bytes())
            source.write_text(json.dumps(entries) + ' ', encoding='utf-8')
            for action in (lambda: module.work(plan_path, group['id'], 'clangd'),
                           lambda: module.collect(plan_path, [group['id']], background, marker, 'clangd')):
                try:
                    action()
                    raise AssertionError('changed input admitted')
                except ValueError as error:
                    assert str(error) == 'background-proof-input-changed'
            assert before == (background.read_bytes(), marker.read_bytes())
            print('changed source fails before worker and publication')
        elif operation == 'rejected':
            result = module.work(plan_path, group['id'], 'clangd')
            assert result['ok'] and result['metrics']['batch_count'] == 0
            _, _, options = calls[-1]
            assert options['verify_missing'] and options['max_new_groups'] is None
            assert options['max_group'] == 8 and options['max_sources'] == 80
            result = module.collect(plan_path, [group['id']], background, marker, 'clangd')
            assert result['metrics']['batch_count'] == 0
            assert result['metrics']['collect_accepted_count'] == 0
            assert result['observations']['plan_candidate_count'] == 1
            assert result['observations']['selector_reuse_status'] == 'zero-hit'
            assert json.loads(background.read_text()) == entries
            assert json.loads(marker.read_text())['kept'] == 'original marker'
            print('binding rejection retains every exact, UBT and shader command')
        elif operation == 'reuse_noop':
            pathlib.Path(group['store']).mkdir(parents=True)
            accepted_stores.add(group['store'])
            result = module.collect(plan_path, [group['id']], background, marker, 'clangd')
            assert result['metrics']['batch_count'] == 1 and result['metrics']['accepted_ubt_count'] == 4
            assert result['metrics']['collect_accepted_count'] == 1
            assert result['observations']['proof_accepted_count'] == 1
            published = json.loads(background.read_text())
            assert published[-2:] == [exact, shader] and len(published) == 3
            stamps = [path.stat().st_mtime_ns for path in (background, marker, module._catalog_path(store))]
            # The generator persists the established eight count fields. Pure
            # observations must not oscillate its marker against collect.
            marker_value = json.loads(marker.read_text())
            assert set(marker_value['verified_batches']) == {'original_ubt_count', 'exact_count', 'shader_count',
                'other_count', 'batch_count', 'accepted_ubt_count', 'retained_ubt_count', 'output_entries'}
            module.write_outputs_if_changed([(str(background), json.dumps(published)),
                (str(marker), json.dumps(marker_value))])
            assert stamps == [path.stat().st_mtime_ns for path in (background, marker, module._catalog_path(store))]
            result = module.collect(plan_path, [group['id']], background, marker, 'clangd')
            assert not result['changed']
            assert stamps == [path.stat().st_mtime_ns for path in (background, marker, module._catalog_path(store))]
            reused, metrics = module.reuse_completed(entries, store, 'clangd')
            assert reused == published and metrics['batch_count'] == 1
            assert module.make_plan(source, store, 'clangd')['groups'] == []
            # A narrower prepare cannot partially consume an admitted batch.
            reused, metrics = module.reuse_completed(entries[1:], store, 'clangd')
            assert reused == entries[1:] and metrics['batch_count'] == 0
            assert all(not options['verify_missing'] for _, _, options in calls)
            print('full-group reuse, no-op publication and subset fail-closed verified')
        elif operation == 'overlap':
            accepted_stores.update((str(store), group['store']))
            result = module.collect(plan_path, [group['id']], background, marker, 'clangd')
            assert result['metrics']['batch_count'] == 1 and result['metrics']['accepted_ubt_count'] == 4
            assert not any(directory == group['store'] for _, directory, _ in calls)
            assert len(json.loads(background.read_text())) == 3
            print('legacy accepted originals are never consumed twice')
        elif operation == 'changed_during_collect':
            pathlib.Path(group['store']).mkdir(parents=True)
            accepted_stores.add(group['store'])
            original = module._read_source
            before = (background.read_bytes(), marker.read_bytes())
            seen = [0]
            def mutate(path, expected=None):
                seen[0] += 1
                if seen[0] == 2:
                    source.write_text(json.dumps(entries) + ' ', encoding='utf-8')
                return original(path, expected)
            with patch.object(module, '_read_source', side_effect=mutate):
                try:
                    module.collect(plan_path, [group['id']], background, marker, 'clangd')
                    raise AssertionError('publication allowed racing changed source')
                except ValueError as error:
                    assert str(error) == 'background-proof-input-changed'
            assert before == (background.read_bytes(), marker.read_bytes())
            print('publication rechecks source after cache revalidation')
        elif operation == 'profile':
            try:
                module.work(plan_path, group['id'], 'clangd', {'query_driver': ['other']})
                raise AssertionError('changed profile admitted')
            except ValueError as error:
                assert str(error) == 'background-proof-plan-profile-mismatch'
            print('profile mutation fails closed')
        elif operation == 'rejected_generator_noop':
            background.write_text(json.dumps(entries), encoding='utf-8')
            marker_value = {'schema': 1, 'kept': 'original marker', 'entry_count': 6,
                'native_background_entry_count': 5, 'unity_entry_count': 0,
                'verified_batches': {'original_ubt_count': 4, 'exact_count': 1, 'shader_count': 1,
                    'other_count': 0, 'batch_count': 0, 'accepted_ubt_count': 0,
                    'retained_ubt_count': 4, 'output_entries': 6}}
            marker.write_text(json.dumps(marker_value, indent=2), encoding='utf-8')
            before = [(path.read_bytes(), path.stat().st_mtime_ns) for path in (source, background, marker)]
            result = module.collect(plan_path, [group['id']], background, marker, 'clangd')
            assert not result['changed'], 'catalog-only write must not trigger publication'
            assert before == [(path.read_bytes(), path.stat().st_mtime_ns) for path in (source, background, marker)]
            assert module._catalog_path(store).is_file()
            # Simulate the full generator writing its established JSON style.
            module.write_outputs_if_changed([(str(background), json.dumps(entries))])
            result = module.collect(plan_path, [group['id']], background, marker, 'clangd')
            assert not result['changed']
            assert before == [(path.read_bytes(), path.stat().st_mtime_ns) for path in (source, background, marker)]
            print('rejected proof and catalog-only update preserve generator bytes and timestamps')
        elif operation == 'missing_store':
            missing = root / 'missing-store'
            calls.clear()
            output, metrics = module.reuse_completed(entries, missing, 'clangd')
            assert output == entries and metrics['batch_count'] == 0
            assert not missing.exists() and not calls
            assert metrics['proof_uncached_count'] == 1 and metrics['proof_rejected_count'] == 0
            assert metrics['selector_reuse_status'] == 'zero-hit'
            print('missing advisory proof store remains read-only')
        elif operation in ('publication_failure', 'publication_shape'):
            request_path, result_path = root / 'publication-request.json', root / 'publication-result.json'
            request_path.write_text(json.dumps({'publication_result': str(result_path)}), encoding='utf-8')
            activation = {'ok': True, 'manifest': {'generation_id': 'fixture-generation'},
                'index_selection': {'index_path': 'fixture-index'}, 'publication': {'changed': True}}
            def child_success(command, **options):
                assert command == ['nvim-fixture', '--headless', '-u', 'NONE', '-l', 'publish-fixture.lua', str(request_path)]
                assert options == {'cwd': str(root), 'text': True, 'capture_output': True, 'timeout': 90}
                assert not result_path.exists(), 'previous publication response must not grant activation'
                result_path.write_text(json.dumps(activation), encoding='utf-8')
                return subprocess.CompletedProcess(command, 0, '', '')
            if operation == 'publication_failure':
                result_path.write_text(json.dumps(activation), encoding='utf-8')
                with patch.object(module.subprocess, 'run', return_value=subprocess.CompletedProcess([], 1, '', 'worker failed')):
                    try:
                        module.collect(plan_path, [group['id']], background, marker, 'clangd',
                            publish_request=request_path, nvim='nvim-fixture', publish_worker='publish-fixture.lua')
                        raise AssertionError('failed child admitted stale successful activation')
                    except ValueError as error:
                        assert str(error) == 'background-proof-publication-worker-failed: worker failed'
                assert not result_path.exists()
                before = [(path.read_bytes(), path.stat().st_mtime_ns) for path in (background, marker)]
                with patch.object(module.subprocess, 'run', side_effect=child_success):
                    result = module.collect(plan_path, [group['id']], background, marker, 'clangd',
                        publish_request=request_path, nvim='nvim-fixture', publish_worker='publish-fixture.lua')
                assert not result['changed'] and result['activation'] == activation
                assert before == [(path.read_bytes(), path.stat().st_mtime_ns) for path in (background, marker)]
                print('publication child failure denies activation; retry preserves existing CDB bytes')
            else:
                before = (background.read_bytes(), marker.read_bytes())
                try:
                    module.collect(plan_path, [group['id']], background, marker, 'clangd', publish_request=request_path)
                    raise AssertionError('partial publication options admitted')
                except ValueError as error:
                    assert str(error) == 'background-proof-publication-worker-options-required-together'
                assert before == (background.read_bytes(), marker.read_bytes())
                with patch.object(module.subprocess, 'run', side_effect=child_success):
                    result = module.collect(plan_path, [group['id']], background, marker, 'clangd',
                        publish_request=request_path, nvim='nvim-fixture', publish_worker='publish-fixture.lua')
                assert result['ok'] and result['activation'] == activation
                assert not result['owned_job']
                def child_reject(command, **options):
                    result_path.write_text(json.dumps({'ok': False}), encoding='utf-8')
                    return subprocess.CompletedProcess(command, 0, '', '')
                with patch.object(module.subprocess, 'run', side_effect=child_reject):
                    try:
                        module.collect(plan_path, [group['id']], background, marker, 'clangd',
                            publish_request=request_path, nvim='nvim-fixture', publish_worker='publish-fixture.lua')
                        raise AssertionError('rejected child admitted activation')
                    except ValueError as error:
                        assert str(error) == 'background-proof-publication-worker-rejected'
                print('publication activation shape preserved; partial flags and negative worker result fail closed')
        elif operation == 'rollback':
            pathlib.Path(group['store']).mkdir(parents=True)
            accepted_stores.add(group['store'])
            before = (background.read_bytes(), marker.read_bytes())
            replace = module.os.replace
            def fail_marker(old, new):
                if str(new) == str(marker) and str(old).endswith('.pending'):
                    raise OSError('injected marker publish failure')
                return replace(old, new)
            with patch.object(module.os, 'replace', side_effect=fail_marker):
                try:
                    module.collect(plan_path, [group['id']], background, marker, 'clangd')
                    raise AssertionError('write failure hidden')
                except OSError as error:
                    assert str(error) == 'injected marker publish failure'
            assert before == (background.read_bytes(), marker.read_bytes())
            assert not module._catalog_path(store).exists()
            print('partial publication rolls back CDB, marker and catalog')
        elif operation == 'owned_job':
            if os.name != 'nt':
                assert module._owned_job() is None
                print('Windows job policy guarded by actual host capability')
            else:
                import ctypes
                from ctypes import wintypes
                ready = root / 'owned-job-ready'
                helper = root / 'owned_job.py'
                helper.write_text('''import importlib.util, pathlib, subprocess, sys, time
spec = importlib.util.spec_from_file_location('background', sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
def publish_ready(value):
    path = pathlib.Path(sys.argv[2])
    temporary = path.with_name(path.name + '.tmp')
    temporary.write_text(value)
    temporary.replace(path)
try:
    owned = module._owned_job()
except OSError as error:
    publish_ready('blocked:' + str(error))
    sys.exit(1)
child = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(60)'],
    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
publish_ready(str(child.pid))
time.sleep(60)
''', encoding='utf-8')
                parent = subprocess.Popen([sys.executable, '-I', str(helper), tool, str(ready)],
                    stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                handle = None
                kernel = ctypes.WinDLL('kernel32', use_last_error=True)
                kernel.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
                kernel.OpenProcess.restype = wintypes.HANDLE
                kernel.WaitForSingleObject.argtypes = [wintypes.HANDLE, wintypes.DWORD]
                kernel.CloseHandle.argtypes = [wintypes.HANDLE]
                try:
                    deadline = time.monotonic() + 5
                    while not ready.exists() and parent.poll() is None and time.monotonic() < deadline:
                        time.sleep(0.02)
                    assert ready.exists(), 'owned job parent failed before reporting capability'
                    report = ready.read_text()
                    if report.startswith('blocked:'):
                        assert 'background-proof-job-' in report
                        parent.communicate(timeout=5)
                        assert parent.returncode == 1
                        print('actual nested-job rejection fails closed before spawning work')
                    else:
                        handle = kernel.OpenProcess(0x100000, False, int(report))
                        assert handle, ctypes.get_last_error()
                        parent.kill()
                        parent.communicate(timeout=5)
                        assert kernel.WaitForSingleObject(handle, 5000) == 0, 'owned descendant survived parent exit'
                        print('actual Windows worker termination removes only its job descendants')
                finally:
                    if parent.poll() is None:
                        parent.kill()
                        parent.communicate(timeout=5)
                    if handle:
                        kernel.CloseHandle(handle)
        else:
            raise AssertionError(operation)
]=]

local function run_fixture(operation)
  local python = vim.fn.exepath("python")
  if python == "" then
    python = vim.fn.exepath("python3")
  end
  if python == "" then
    t.skip("后台批处理工具回归需要 Python")
    return
  end
  local path = vim.fn.tempname() .. ".py"
  vim.fn.writefile(vim.split(fixture, "\n", { plain = true }), path)
  local result = vim.system({ python, "-I", path, vim.fn.getcwd() .. "/tools/cdb_background_batch.py", operation },
    { text = true }):wait(30000)
  vim.fn.delete(path)
  t.assert_eq(result.code, 0, result.stderr .. result.stdout)
end

t.describe("后台独立二次批次工具", function()
  for _, operation in ipairs({ "tier1_retry_e2e", "tier1_retry_missing_child", "tier1_retry_child_failed", "tier1_retry_main_shard" }) do
    t.it(operation, function()
      run_fixture(operation)
    end)
  end
  for _, operation in ipairs({ "pure_strip_flags", "pure_upgrade_sequence", "pure_reuse_sequences", "plan", "strict_mixed", "recover_hints", "input_changed", "rejected", "reuse_noop", "overlap", "changed_during_collect", "profile", "rejected_generator_noop", "missing_store", "publication_failure", "publication_shape", "rollback", "owned_job", "strict_split_exact", "strict_split_wrong_candidate", "strict_split_wrong_partition", "strict_split_incomplete" }) do
    t.it(operation, function()
      run_fixture(operation)
    end)
  end
  for _, operation in ipairs({ "tier1_upgrade_prefix_lifecycle", "tier1_upgrade_prefix_overlay_scope", "tier1_upgrade_prefix_parent_binding", "tier1_upgrade_prefix_reject_proposals", "tier1_upgrade_prefix_owner_lost_work", "tier1_upgrade_prefix_owner_expanded_collect", "tier1_upgrade_prefix_post_body", "tier1_upgrade_prefix_post_header", "tier1_upgrade_prefix_rejected", "tier1_upgrade_prefix_timeout", "tier1_e2e", "tier1_failed_cached", "tier1_transient_retry", "tier1_overlay_scope", "tier1_byte_budget", "tier1_mode_isolation", "tier1_member_changed", "tier1_receipt_tamper", "tier1_upgrade_defaults", "tier1_upgrade_accept_reuse", "tier1_upgrade_reject_proposals", "tier1_upgrade_order", "tier1_upgrade_fallback", "tier1_upgrade_claimed_unproved", "tier1_upgrade_failed_cached", "tier1_upgrade_transient_retry", "tier1_upgrade_legacy_boundary" }) do
    t.it(operation, function()
      run_fixture(operation)
    end)
  end
  for _, operation in ipairs({ "tier1_auto_fresh", "tier1_auto_rejected", "tier1_auto_timeout", "tier1_auto_limits",
    "tier1_auto_bytes", "tier1_auto_tuples", "tier1_auto_barriers", "tier1_auto_adoption", "tier1_auto_forged_links", "tier1_auto_budget_drift" }) do
    t.it(operation, function()
      run_fixture(operation)
    end)
  end
end)
