local t = require("tests.harness")
t.bootstrap()

local fixture = [=[
import copy, json, os, pathlib, subprocess, sys, tempfile
from unittest.mock import patch
tool, operation, clangd = sys.argv[1:]
sys.path.insert(0, str(pathlib.Path(tool).resolve().parent))
import cdb_background_batch as background
verified = background.verified
os.environ['NVIM_UE_BATCH_TIER'] = '1'
os.environ.pop('NVIM_UE_TIER1_SPLIT_CLASSES', None)
os.environ.pop('NVIM_UE_SUPER_UNITY_BUDGET_FACTOR', None)

def rejected(action):
    try:
        action()
    except ValueError:
        return
    raise AssertionError('invalid class policy admitted')

with tempfile.TemporaryDirectory(prefix='tier1_noclass_') as temporary:
    root = pathlib.Path(temporary).resolve()
    generation = root / 'generation'
    store = generation / 'verified_batches'
    source, plan_path = root / 'semantic.json', root / 'plan.json'
    published, marker = root / 'background.json', root / 'marker.json'
    def unit(index, module=0, member_name=None, text=None):
        suffix = '.cpp' if index % 4 < 2 else '.gen.cpp'
        member = root / (member_name or ('member%d' % index + suffix))
        member.parent.mkdir(parents=True, exist_ok=True)
        member.write_text(text if text is not None else 'int member%d() { return %d; }\n' % (index, index), encoding='utf-8')
        wrapper = root / ('SuperUnity.UBT.Test.%d.cpp' % index)
        wrapper.write_text('// Compiler-authored UBT unity membership; copied into nvim cache.\n'
            + '#include "' + member.as_posix() + '"\n', encoding='utf-8')
        return {'directory': str(root), 'file': str(wrapper),
            'arguments': ['clang++', '-x', 'c++', '-std=c++17', str(wrapper)],
            'nvim_ue_module_root': str(root / ('Module%d' % module)),
            'nvim_ue_members': [verified.portable_member_path(str(member))]}
    entries = [unit(index) for index in range(4)]
    source.write_text(json.dumps(entries), encoding='utf-8')
    def snapshot():
        return {str(path.relative_to(root)): (path.read_bytes(), path.stat().st_mtime_ns)
            for path in root.rglob('*') if path.is_file()}
    def chunks(): return background._chunks(entries, '1')
    def audit_retry(rows, metrics, child_indexes):
        assert metrics['coverage_complete'] and verified._tier1_source_coverage(rows) == verified._tier1_source_coverage(entries), metrics
        records = metrics['groups']
        assert len(records) == 1 + len(child_indexes), records
        parent = records[0]
        parent_indexes = [index for index, entry in enumerate(entries) if verified._is_ubt(entry)]
        assert parent['original_indexes'] == parent_indexes and not parent['accepted'], parent
        parent_receipt = json.loads(pathlib.Path(parent['receipt']).read_text(encoding='utf-8'))
        parent_key = parent_receipt['cache_key']
        assert parent_key and not parent_receipt['accepted'] and parent_receipt['reason'] == parent['reason'], parent_receipt
        children = records[1:]
        assert [record['original_indexes'] for record in children] == child_indexes, children
        for child in children:
            receipt = json.loads(pathlib.Path(child['receipt']).read_text(encoding='utf-8'))
            assert child['fallback_of'] == receipt['fallback_of'] == parent_key, (child, receipt)
            assert receipt['cache_key'] != parent_key and receipt['accepted'] == child['accepted'], receipt
            assert receipt['original_entries'] == [verified._native(entries[index]) for index in child['original_indexes']], receipt
        return parent_key, children

    if operation == 'default_mixed':
        assert chunks() == [[0, 1, 2, 3]]
        rows, metrics = verified.reuse_tier1(entries, store, sys.executable)
        assert rows == entries and metrics['batch_count'] == 0
        assert [group['original_indexes'] for group in metrics['groups']] == chunks()
        assert all(group['deferred'] for group in metrics['groups'])
        # The low-level API retains its class-splitting default for other callers.
        assert background.secondary_unity_chunks(entries) == [[0, 1], [2, 3]]
    elif operation == 'split_rollback':
        os.environ['NVIM_UE_TIER1_SPLIT_CLASSES'] = '1'
        assert chunks() == [[0, 1], [2, 3]]
        rows, metrics = verified.reuse_tier1(entries, store, sys.executable)
        assert rows == entries and [group['original_indexes'] for group in metrics['groups']] == chunks()
    elif operation == 'invalid_policy':
        for value in ('', 'invalid', '-1', '2', '0.5', 'true'):
            os.environ['NVIM_UE_TIER1_SPLIT_CLASSES'] = value
            rejected(chunks)
            rejected(lambda: verified.reuse_tier1(entries, store, sys.executable))
    elif operation == 'strict_unchanged':
        expected = background._chunks(entries, 'strict')
        assert expected == [[0, 1], [2, 3]], expected
        for value in ('0', '1', 'invalid'):
            os.environ['NVIM_UE_TIER1_SPLIT_CLASSES'] = value
            assert background._chunks(entries, 'strict') == expected
            assert background.strict_unity_chunks(entries, max_sources=80, max_unities=8) == expected
        (root / 'StrictX.h').write_text('#pragma once\nstruct StrictX {};\n', encoding='utf-8')
        pair = [unit(10, member_name='StrictX.cpp', text='#include "StrictX.h"\nint strict_source(StrictX*) { return 1; }\n'),
            unit(11, member_name='StrictX.gen.cpp', text='#include "StrictX.h"\nint strict_generated(StrictX*) { return 2; }\n')]
        assert background._chunks(pair, 'strict') == [[0, 1]], 'strict residual grouping changed for a same-stem pair'
        assert verified._explicit_group_indexes(pair, [0, 1], 8, 80) == [0, 1], \
            'strict explicit grouping must preserve its existing independent proof policy'
    elif operation == 'cohort_shared_policy':
        entries += [unit(index, 1) for index in range(4, 8)]
        source.write_text(json.dumps(entries), encoding='utf-8')
        specs = background.make_plan(source, store, sys.executable)['groups']
        assert [spec['indexes'] for spec in specs] == chunks() == [list(range(4)), list(range(4, 8))]
        assert [spec['indexes'] for spec in verified._cohort_specs(entries, specs, generation)] == chunks()
        os.environ['NVIM_UE_TIER1_SPLIT_CLASSES'] = '1'
        assert chunks() == [[0, 1], [2, 3], [4, 5], [6, 7]]
        rejected(lambda: verified._cohort_specs(entries, specs, generation))
        os.environ['NVIM_UE_TIER1_SPLIT_CLASSES'] = 'invalid'
        rejected(lambda: verified._cohort_specs(entries, specs, generation))
    elif operation == 'stem_shared_policy':
        entries = [unit(0, member_name='Source/X.cpp'), unit(1),
            unit(2, member_name='Inc/x.gen.cpp'), unit(3)]
        entries += [unit(index, 1) for index in range(4, 8)]
        source.write_text(json.dumps(entries), encoding='utf-8')
        expected = [list(range(4)), list(range(4, 8))]
        assert chunks() == expected
        assert background.secondary_unity_chunks(entries, **verified.tier1_grouping_options()) == expected
        specs = background.make_plan(source, store, sys.executable)['groups']
        assert [spec['indexes'] for spec in specs] == expected
        rows, metrics = verified.reuse_tier1(entries, store, sys.executable)
        assert rows == entries and [group['original_indexes'] for group in metrics['groups']] == expected
        assert background.secondary_unity_chunks(entries, split_member_classes=False,
            avoid_same_stem_pairs=True) == [[0, 1], [2, 3], [4, 5, 6, 7]], 'same-stem exclusion must remain available explicitly'
        with patch.object(subprocess, 'Popen', side_effect=AssertionError('cohort packing guard starts native work')):
            assert [spec['indexes'] for spec in verified._cohort_specs(entries, specs, generation)] == expected
    elif operation == 'retry_transient':
        def successful(candidate, directory, executable, timeout, server_profile=None):
            paths = [line[len('#include "'):-1] for line in pathlib.Path(candidate['file']).read_text().splitlines()
                if line.startswith('#include "')]
            return {'background_compile_success': True, 'indexing_complete': True, 'exit_code': 0,
                'compile_failure_count': 0, 'member_main_shards': paths, 'missing_main_shards': []}
        with patch.object(subprocess, 'Popen', side_effect=AssertionError('mock timeout starts native work')), \
             patch.object(verified, '_tier1_candidate_index', side_effect=subprocess.TimeoutExpired('fixture', 15)):
            _, timed_out = verified.accelerate_tier1(entries, store, sys.executable, timeout=15)
        assert timed_out['batch_count'] == 0 and timed_out['cache_hits'] == 0, timed_out
        with patch.object(subprocess, 'Popen', side_effect=AssertionError('mock recovery starts native work')), \
             patch.object(verified, '_tier1_candidate_index', side_effect=successful) as indexed:
            recovered, metrics = verified.accelerate_tier1(entries, store, sys.executable, timeout=15)
        assert metrics['batch_count'] == 1 and metrics['cache_hits'] == 0 and indexed.call_count == 1, metrics
        assert metrics['groups'][0]['accepted'] and metrics['coverage_complete'] and len(recovered) == 1, metrics
    elif operation.startswith('retry_'):
        if operation == 'retry_singleton':
            entries = entries[:3]
        if operation == 'retry_global_indexes':
            exact, shader = root / 'Exact.cpp', root / 'Shader.usf'
            exact.write_text('int exact_value() { return 1; }\n', encoding='utf-8')
            shader.write_text('// shader\n', encoding='utf-8')
            passthrough = lambda path: {'file': str(path), 'directory': str(root), 'arguments': ['clang++', str(path)]}
            exact_entry, shader_entry = passthrough(exact), passthrough(shader)
            entries = [exact_entry, *entries[:2], shader_entry, *entries[2:]]
            expected_children = [[1, 2], [4, 5]]
        else:
            expected_children = [[0, 1]] + ([[2, 3]] if len(entries) == 4 else [])
        parent_member_count = sum(len(entry.get('nvim_ue_members', [])) for entry in entries)
        originals = copy.deepcopy(entries)
        real_match = verified._tier1_members_match
        def candidate_members(group, candidate, **kwargs):
            matches, expected = real_match(group, candidate, **kwargs)
            if operation == 'retry_members' and len(group) == len(entries):
                return False, expected
            return matches, expected
        def candidate_run(candidate, directory, executable, timeout, server_profile=None):
            members = candidate['nvim_ue_members']
            paths = [line[len('#include "'):-1] for line in pathlib.Path(candidate['file']).read_text().splitlines()
                if line.startswith('#include "')]
            parent = len(members) == parent_member_count
            if parent and operation == 'retry_invalid_own':
                raise ValueError('tier1-invalid-own-shard: fixture.idx')
            source_child = all(not member.lower().endswith('.gen.cpp') for member in members)
            compile_failed = (parent and operation not in ('retry_missing_main', 'retry_missing_member_main')) or (
                not parent and (operation == 'retry_children_fail' or operation == 'retry_child_failure' and source_child))
            return {'background_compile_success': not compile_failed,
                'indexing_complete': True, 'exit_code': 0, 'compile_failure_count': int(compile_failed),
                'shard_had_errors': compile_failed,
                'member_main_shards': paths[:-1] if parent and operation == 'retry_missing_member_main' else paths,
                'missing_main_shards': ['missing-parent-main.cpp'] if parent and operation == 'retry_missing_main' else []}
        with patch.object(subprocess, 'Popen', side_effect=AssertionError('mock gate fixture must not spawn native work')), \
             patch.object(verified, '_tier1_members_match', side_effect=candidate_members), \
             patch.object(verified, '_tier1_candidate_index', side_effect=candidate_run) as indexed:
            rows, metrics = verified.accelerate_tier1(entries, store, sys.executable, timeout=15)
        assert entries == originals, 'fallback qualification mutated originals'
        parent_key, children = audit_retry(rows, metrics, expected_children)
        if operation == 'retry_invalid_own':
            assert metrics['groups'][0]['reason'] == 'tier1-invalid-own-shard: fixture.idx', metrics
            parent_receipt = json.loads(pathlib.Path(metrics['groups'][0]['receipt']).read_text(encoding='utf-8'))
            assert parent_receipt['reusable'] is False, 'an exception without a completed native result cannot establish a permanent rejection'
        expected_calls = len(expected_children) + (operation != 'retry_members')
        assert indexed.call_count == expected_calls, 'fallback must qualify each child once and never recurse'
        accepted = [child for child in children if child['accepted']]
        expected_batches = 0 if operation == 'retry_children_fail' else 1 if operation in ('retry_singleton', 'retry_child_failure') else 2
        assert len(accepted) == metrics['batch_count'] == expected_batches, metrics
        assert metrics['accepted_ubt_count'] == expected_batches * 2, metrics
        assert len(rows) == len(entries) - expected_batches, rows
        if operation == 'retry_children_fail':
            assert rows == entries and all(not child['accepted'] for child in children)
        elif operation == 'retry_child_failure':
            assert rows[:2] == entries[:2] and rows[2]['nvim_ue_members'] == entries[2]['nvim_ue_members'] + entries[3]['nvim_ue_members'], rows
        elif operation == 'retry_singleton':
            assert rows[1] == entries[2], 'singleton generated UBT must retain its original command'
        elif operation == 'retry_global_indexes':
            assert rows[0] == exact_entry and rows[2] == shader_entry, 'fallback dropped exact or shader passthrough'
        if operation in ('retry_compile', 'retry_missing_main', 'retry_missing_member_main', 'retry_warm_reuse', 'retry_partial_reuse'):
            before = snapshot()
            with patch.object(subprocess, 'Popen', side_effect=AssertionError('warm fallback starts a process')), \
                 patch.object(verified, '_tier1_candidate_index', side_effect=AssertionError('warm fallback requalifies')), \
                 patch.object(verified, '_write', side_effect=AssertionError('warm fallback writes artifacts')):
                warm_rows, warm_metrics = verified.accelerate_tier1(entries, store, sys.executable, timeout=15)
                reused, reuse_metrics = verified.reuse_tier1(entries, store, sys.executable, timeout=15)
            assert warm_rows == reused == rows, (warm_metrics, reuse_metrics)
            for repeat in (warm_metrics, reuse_metrics):
                assert repeat['cache_hits'] == 3 and repeat['batch_count'] == 2 and repeat['new_proof_count'] == 0, repeat
                assert [record['original_indexes'] for record in repeat['groups']] == [list(range(4)), *expected_children], repeat
            assert snapshot() == before, 'warm fallback changed artifact bytes or mtimes'
            if operation == 'retry_partial_reuse':
                pathlib.Path(children[1]['receipt']).unlink()
                before = snapshot()
                with patch.object(subprocess, 'Popen', side_effect=AssertionError('partial reuse starts a process')), \
                     patch.object(verified, '_tier1_candidate_index', side_effect=AssertionError('partial reuse requalifies')), \
                     patch.object(verified, '_write', side_effect=AssertionError('partial reuse writes artifacts')):
                    partial, partial_metrics = verified.reuse_tier1(entries, store, sys.executable, timeout=15)
                assert partial == [rows[0], *entries[2:]], partial
                assert partial_metrics['batch_count'] == 1 and partial_metrics['deferred_group_count'] == 1, partial_metrics
                assert partial_metrics['new_proof_count'] == 0 and partial_metrics['coverage_complete'], partial_metrics
                assert partial_metrics['groups'][-1]['deferred'] and partial_metrics['groups'][-1]['original_indexes'] == [2, 3]
                assert snapshot() == before, 'missing-child read-only lookup changed artifact bytes or mtimes'
    elif operation == 'native_same_stem_header':
        compiler = pathlib.Path(clangd).with_name('clang++' + pathlib.Path(clangd).suffix)
        assert compiler.is_file(), 'native same-stem test requires the actual matching clang++ compiler'
        header = root / 'X.h'
        header.write_text('struct X { int value; };\n', encoding='utf-8')
        entries = [unit(0, member_name='X.cpp', text='#include "X.h"\nint source_x(X* p) { return p->value; }\n'),
            unit(1, member_name='Safe.cpp'),
            unit(2, member_name='X.gen.cpp', text='#include "X.h"\nint generated_x(X* p) { return p->value; }\n'),
            unit(3, member_name='Safe.gen.cpp')]
        for entry in entries:
            entry['arguments'][0] = str(compiler)
        def compile_file(path):
            return subprocess.run([str(compiler), '-x', 'c++', '-std=c++17', '-fsyntax-only', str(path)],
                text=True, capture_output=True, timeout=15)
        for entry in entries:
            compiled = compile_file(entry['file'])
            assert compiled.returncode == 0, compiled.stdout + compiled.stderr
        old_candidate = verified._tier1_candidate(entries, root / 'old-candidate')
        failed = compile_file(old_candidate['file'])
        assert failed.returncode != 0 and 'redefinition' in failed.stderr, failed.stdout + failed.stderr
        source.write_text(json.dumps(entries), encoding='utf-8')
        assert chunks() == [[0, 1, 2, 3]], 'default planning must preserve the cross-class opportunity before qualification'
        plan = background.make_plan(source, store, clangd)
        assert [group['indexes'] for group in plan['groups']] == [[0, 1, 2, 3]], plan
        rows, metrics = verified.accelerate_tier1(entries, store, clangd, timeout=15)
        parent_key, children = audit_retry(rows, metrics, [[0, 1], [2, 3]])
        assert metrics['groups'][0]['reason'] == 'tier1-candidate-index-failed', metrics
        assert metrics['batch_count'] == 2 and metrics['accepted_ubt_count'] == 4 and metrics['retained_ubt_count'] == 0, metrics
        assert len(rows) == 2 and all(child['accepted'] and all(child['gates'].values()) for child in children), metrics
        assert metrics['new_proof_count'] == 3, metrics
        for row in rows:
            receipt = json.loads(pathlib.Path(row['nvim_ue_tier1_receipt']).read_text(encoding='utf-8'))
            assert receipt['accepted'] and receipt['fallback_of'] == parent_key, receipt
            compiled = compile_file(row['file'])
            assert compiled.returncode == 0, compiled.stdout + compiled.stderr
        before = snapshot()
        with patch.object(subprocess, 'Popen', side_effect=AssertionError('native fallback warm path starts a process')), \
             patch.object(verified, '_write', side_effect=AssertionError('native fallback warm path writes artifacts')):
            warm, warm_metrics = verified.accelerate_tier1(entries, store, clangd, timeout=15)
            reused, reuse_metrics = verified.reuse_tier1(entries, store, clangd, timeout=15)
        assert warm == reused == rows and warm_metrics['cache_hits'] == reuse_metrics['cache_hits'] == 3
        assert snapshot() == before, 'native fallback warm reuse changed bytes or mtimes'
        print('native-retry-evidence: ' + json.dumps({'cold': metrics, 'warm': warm_metrics, 'reuse': reuse_metrics,
            'parent_receipt': json.loads(pathlib.Path(metrics['groups'][0]['receipt']).read_text(encoding='utf-8'))}))
    elif operation in ('native_plan_work_collect_noop', 'native_split_catalog_migration'):
        published.write_text('[]', encoding='utf-8')
        marker.write_text('{}', encoding='utf-8')
        def run_work(group):
            result_path = root / ('worker-result-' + group['id'] + '.json')
            completed = subprocess.run([sys.executable, '-B', '-I', tool, '--worker', str(plan_path),
                '--group', group['id'], '--clangd', clangd, '--out', str(result_path)],
                text=True, capture_output=True, timeout=15)
            assert completed.returncode == 0, (completed.stdout, completed.stderr)
            worked = json.loads(result_path.read_text(encoding='utf-8'))
            assert worked['ok'] and worked['metrics']['batch_count'] == 1, worked
            assert worked['metrics']['new_proof_count'] == 1, worked
            record = worked['metrics']['groups'][0]
            assert record['accepted'] and all(record['gates'].values()), record
        if operation == 'native_split_catalog_migration':
            os.environ['NVIM_UE_TIER1_SPLIT_CLASSES'] = '1'
            old = background.make_plan(source, store, clangd)
            assert [group['indexes'] for group in old['groups']] == [[0, 1], [2, 3]]
            background._write(plan_path, old)
            for group in old['groups']:
                run_work(group)
            old_result = background.collect(plan_path, [group['id'] for group in old['groups']],
                published, marker, clangd)
            assert old_result['metrics']['batch_count'] == 2 and old_result['metrics']['accepted_ubt_count'] == 4
            assert len(json.loads(published.read_text(encoding='utf-8'))) == 2
            assert len(background._catalog(store, '1')) == 2
            del os.environ['NVIM_UE_TIER1_SPLIT_CLASSES']
            # Receipts remain valid for the same local inputs. Only obsolete
            # full-input catalog boundaries must stop claiming the new chunk.
            before = snapshot()
            old_receipts = set()
            with patch.object(subprocess, 'Popen', side_effect=AssertionError('old receipt starts native work')):
                for group in old['groups']:
                    selected = [entries[index] for index in group['indexes']]
                    local_output, local_metrics = verified.reuse_tier1(selected, group['store'], clangd)
                    assert local_metrics['batch_count'] == local_metrics['cache_hits'] == 1
                    old_receipts.add(local_output[0]['nvim_ue_tier1_receipt'])
            assert len(old_receipts) == 2 and snapshot() == before
        plan = background.make_plan(source, store, clangd)
        assert len(plan['groups']) == 1 and plan['groups'][0]['indexes'] == [0, 1, 2, 3]
        assert plan['proof_accepted_count'] == 0 and plan['proof_uncached_count'] == 1
        background._write(plan_path, plan)
        # Replanning unfinished work retains the same pending identity, without writes.
        before = snapshot()
        pending = background.make_plan(source, store, clangd, previous_path=plan_path)
        assert pending['groups'] == plan['groups'] and snapshot() == before
        run_work(plan['groups'][0])
        result = background.collect(plan_path, [plan['groups'][0]['id']], published, marker, clangd)
        assert result['ok'] and result['metrics']['batch_count'] == 1, result
        assert result['metrics']['accepted_ubt_count'] == 4, result
        output = json.loads(published.read_text(encoding='utf-8'))
        assert len(output) == 1 and output[0].get('nvim_ue_tier1_receipt')
        assert verified._tier1_source_coverage(output) == verified._tier1_source_coverage(entries)
        catalog = background._catalog(store, '1')
        assert sum(group['id'] == plan['groups'][0]['id'] for group in catalog) == 1
        if operation == 'native_plan_work_collect_noop':
            assert len(catalog) == 1
        # Guard against native work on the accepted read-only reuse path.
        before = snapshot()
        with patch.object(subprocess, 'Popen', side_effect=AssertionError('repeat starts native work')):
            again = background.make_plan(source, store, clangd, previous_path=plan_path)
            assert again['groups'] == [], again
            assert again['proof_accepted_count'] == 1 and again['proof_uncached_count'] == 0, again
            reused, metrics = background.reuse_completed(entries, store, clangd)
            assert reused == output and metrics['batch_count'] == 1, metrics
        assert snapshot() == before, 'accepted repeat changed artifact bytes or timestamps'
        if operation == 'native_split_catalog_migration':
            os.environ['NVIM_UE_TIER1_SPLIT_CLASSES'] = '1'
            before = snapshot()
            with patch.object(subprocess, 'Popen', side_effect=AssertionError('rollback starts native work')):
                assert chunks() == [[0, 1], [2, 3]]
                rollback = background.make_plan(source, store, clangd)
                # Both split groups already have historical receipts: zero
                # pending work, two accepted owners, no repeat qualification.
                assert rollback['groups'] == [] and rollback['proof_accepted_count'] == 2, rollback
                split_output, split_metrics = background.reuse_completed(entries, store, clangd)
                assert split_metrics['batch_count'] == 2 and len(split_output) == 2
                assert {row['nvim_ue_tier1_receipt'] for row in split_output} == old_receipts
            assert snapshot() == before, 'rollback rewrote preserved receipts or other artifacts'
    else:
        raise AssertionError(operation)
    print(operation + ': passed')
]=]

local function run_fixture(operation, clangd)
  local python = vim.fn.exepath("python")
  if python == "" then python = vim.fn.exepath("python3") end
  if python == "" then
    t.skip("Tier 1 mixed-class fixture", "Python unavailable", { native = true })
    return
  end
  local path = vim.fn.tempname() .. ".py"
  vim.fn.writefile(vim.split(fixture, "\n", { plain = true }), path)
  local result = vim.system({ python, "-B", "-I", path,
    vim.fn.getcwd() .. "/tools/cdb_background_batch.py", operation, clangd or "" }, { text = true }):wait(60000)
  vim.fn.delete(path)
  t.assert_eq(result.code, 0, result.stderr .. result.stdout)
end

t.describe("Tier 1 source/generated grouping", function()
  for _, operation in ipairs({ "default_mixed", "split_rollback", "invalid_policy", "strict_unchanged", "cohort_shared_policy", "stem_shared_policy" }) do
    t.it(operation, function() run_fixture(operation) end)
  end
  for _, operation in ipairs({ "retry_compile", "retry_missing_main", "retry_missing_member_main", "retry_members", "retry_invalid_own", "retry_child_failure", "retry_children_fail", "retry_singleton", "retry_global_indexes", "retry_warm_reuse", "retry_partial_reuse", "retry_transient" }) do
    t.it(operation, function() run_fixture(operation) end)
  end
  local discovered = require("utils.ue_goto.semantic_sidecar_libclang").discover_toolchain()
  if not discovered.ok then
    t.skip("native mixed-class plan/work/collect", discovered.reason, { native = true })
    return
  end
  for _, operation in ipairs({ "native_plan_work_collect_noop", "native_split_catalog_migration", "native_same_stem_header" }) do
    t.it(operation, function() run_fixture(operation, discovered.clangd_path) end)
  end
end)
