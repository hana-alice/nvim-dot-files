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

with tempfile.TemporaryDirectory(prefix='background_batch_') as temporary:
    root = pathlib.Path(temporary).resolve()
    source = root / 'semantic.json'
    store = root / 'verified_batches'
    store.mkdir()
    background, marker, plan_path = root / 'background.json', root / 'marker.json', root / 'plan.json'
    entries = []
    for index in range(4):
        member = root / ('member%d.cpp' % index)
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
            if operation == 'tier1_failed_cached':
                return {'background_compile_success': False, 'missing_main_shards': [],
                    'member_main_shards': [], 'indexing_complete': True, 'exit_code': 0, 'compile_failure_count': 1}
            if operation == 'tier1_transient_retry' and len(indexed) == 1:
                return {'background_compile_success': False, 'missing_main_shards': [],
                    'member_main_shards': [], 'indexing_complete': False, 'exit_code': 0, 'compile_failure_count': 0}
            return {'background_compile_success': True, 'missing_main_shards': [],
                'member_main_shards': [path for entry in entries[:4]
                    for path in module.verified._tier1_ubt_members(entry)]}

        with patch.object(module.verified, '_tier1_candidate_index', side_effect=candidate_index), \
             patch.object(module.verified, 'accelerate', side_effect=AssertionError('strict path used')), \
             patch.object(module, '_owned_job', return_value=None):
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

    def gate(selected, output_dir, clangd, **options):
        calls.append((list(selected), str(output_dir), options))
        ubt_indexes = [index for index, entry in enumerate(selected) if module.verified._is_ubt(entry)]
        accepted = str(output_dir) in accepted_stores
        chunks = module.secondary_unity_chunks(selected)
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
        if operation == 'plan':
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
  for _, operation in ipairs({ "plan", "recover_hints", "input_changed", "rejected", "reuse_noop", "overlap", "changed_during_collect", "profile", "rejected_generator_noop", "missing_store", "publication_failure", "publication_shape", "rollback", "owned_job" }) do
    t.it(operation, function()
      run_fixture(operation)
    end)
  end
  for _, operation in ipairs({ "tier1_e2e", "tier1_failed_cached", "tier1_transient_retry", "tier1_overlay_scope", "tier1_byte_budget", "tier1_mode_isolation", "tier1_member_changed", "tier1_receipt_tamper" }) do
    t.it(operation, function()
      run_fixture(operation)
    end)
  end
end)
