local t = require("tests.harness")
t.bootstrap()

local fixture = [=[
import contextlib, importlib.util, io, json, os, pathlib, shlex, subprocess, sys, tempfile
from unittest.mock import patch
tools, operation, clangd = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]
sys.dont_write_bytecode = True
sys.path.insert(0, str(tools))
import cdb_verified_batch as batch

def module(name):
    spec = importlib.util.spec_from_file_location(name, tools / (name + '.py'))
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value

def snapshot(paths):
    return {str(path): (path.read_bytes(), path.stat().st_mtime_ns) for path in paths}

def assert_snapshot(before, message):
    after = snapshot(map(pathlib.Path, before))
    changed = []
    for path, (raw, stamp) in before.items():
        current, current_stamp = after[path]
        if (current, current_stamp) == (raw, stamp):
            continue
        detail = {'path': path, 'bytes_changed': current != raw,
                  'mtime_before': stamp, 'mtime_after': current_stamp}
        if current != raw:
            detail.update(bytes_before=len(raw), bytes_after=len(current),
                          sha256_before=batch._sha(raw), sha256_after=batch._sha(current))
            try:
                previous, present = json.loads(raw), json.loads(current)
                detail['json_equal'] = previous == present
                if isinstance(previous, dict) and isinstance(present, dict):
                    detail['json_changed_keys'] = sorted(key for key in previous.keys() | present.keys()
                        if previous.get(key) != present.get(key))
                elif isinstance(previous, list) and isinstance(present, list):
                    detail['entry_key_order_changes'] = [
                        {'entry': index, 'before': list(old), 'after': list(new)}
                        for index, (old, new) in enumerate(zip(previous, present))
                        if isinstance(old, dict) and isinstance(new, dict) and list(old) != list(new)]
            except (ValueError, UnicodeDecodeError):
                pass
        changed.append(detail)
    assert not changed, message + ': ' + json.dumps(changed, ensure_ascii=False)

with tempfile.TemporaryDirectory(prefix='batch_prepare_') as temporary:
    root = pathlib.Path(temporary).resolve()
    if operation == 'arguments':
        for name in ('build_clangd_index', 'build_full_cdb'):
            positional = [str(root / 'missing.json')]
            if name == 'build_full_cdb': positional.append(str(root / 'active.json'))
            common = ['--background-output', str(root / 'background.json'), '--clangd', sys.executable]
            for flags, expected in (
                (['--batch-proof-limit', '-1'], '--batch-proof-limit must be nonnegative'),
                (['--batch-proof-limit', '2'], '--batch-proof-limit requires --verified-batches'),
                (['--verified-batches', '--batch-proof-limit', '1.5'], 'invalid int value'),
                (['--verified-batches', '--batch-proof-limit', '2', '--reuse-verified-only'],
                 '--batch-proof-limit cannot be combined with'),
                (['--verified-batches', '--batch-proof-limit', '2', '--verified-batch-store', str(root / 'store')],
                 '--batch-proof-limit cannot be combined with'),
            ):
                command = [sys.executable, '-B', '-I', str(tools / (name + '.py'))] + positional + common + flags
                result = subprocess.run(command, capture_output=True, text=True, timeout=10)
                assert result.returncode == 2 and expected in result.stderr, (command, result.stderr)
                assert not list(root.iterdir()), 'argument rejection must precede filesystem changes'
        for limit, verify in ((-1, True), (True, True), (1.5, True), ('2', True), (0, False)):
            try:
                batch.accelerate([], root / 'proofs', '', max_new_groups=limit, verify_missing=verify)
            except ValueError as error:
                assert 'batch-proof-limit' in str(error), error
            else:
                raise AssertionError('invalid qualification mode accepted: ' + repr((limit, verify)))
            assert not list(root.iterdir()), 'API argument rejection must not create a proof store'
        print('both generators and API reject invalid bounded qualification before filesystem changes')
        sys.exit(0)

    compiler = pathlib.Path(clangd).with_name('clang++' + pathlib.Path(clangd).suffix)
    if operation == 'profile_validation':
        import clangd_query_profile as query
        source = root / 'Source/Runtime/Sample/Private'
        source.mkdir(parents=True)
        first, second, sysroot = root / 'first', root / 'second', root / 'sysroot'
        for directory in (first, second, sysroot): directory.mkdir()
        (first / 'Choice.h').write_text('#pragma once\nconstexpr int chosen = 1;\n')
        (second / 'Choice.h').write_text('#pragma once\nconstexpr int chosen = 2;\n')
        os.environ['CPATH'] = str(first)
        profile = {'query_driver': compiler.as_posix(), 'launch_cwd': root.as_posix(), 'enable_config': False}
        entries = []
        for index in range(2):
            member = source / ('Member' + str(index) + '.cpp')
            member.write_text('#include "Choice.h"\nint member' + str(index)
                              + '() { return chosen; }\n// source revision 1\n')
            wrapper = root / ('SuperUnity.UBT.' + str(index) + '.cpp')
            wrapper.write_text('// Compiler-authored UBT unity membership; copied into nvim cache.\n'
                               + '#include "' + member.as_posix() + '"\n')
            entries.append({'directory': root.as_posix(), 'file': wrapper.as_posix(),
                'arguments': [str(compiler), '--target=aarch64-none-linux-android23',
                    '--sysroot=' + sysroot.as_posix(), '-I' + first.as_posix(), '-I' + second.as_posix(),
                    '-std=c++17', '-c', wrapper.as_posix()],
                'nvim_ue_members': [batch.portable_member_path(str(member))],
                'nvim_ue_module_root': 'Source/Runtime/Sample'})
        store = root / 'proofs'
        output, metrics = batch.accelerate(entries, store, clangd, max_group=2,
            timeout=30, server_profile=profile, max_new_groups=1)
        assert metrics['batch_count'] == 1 and metrics['new_proof_count'] == 1, metrics
        receipts = [output[0]['nvim_ue_batch_receipt']]
        receipt = json.loads(pathlib.Path(receipts[0]).read_text())
        assert receipt['identities']['server_profile'] == profile and receipt['query_profiles'], receipt
        dependencies = {item['uri'] for item in receipt['dependencies']}
        assert (second / 'Choice.h').as_uri() in dependencies and (first / 'Choice.h').as_uri() not in dependencies

        def proof_store_state():
            paths = list(store.rglob('*'))
            return {'paths': sorted(path.relative_to(store).as_posix() for path in paths),
                    'files': {path.relative_to(store).as_posix():
                        (batch._sha(path.read_bytes()), path.stat().st_mtime_ns)
                        for path in paths if path.is_file()},
                    'directories': {path.relative_to(store).as_posix(): path.stat().st_mtime_ns
                        for path in [store] + paths if path.is_dir()}}

        before = proof_store_state()
        scratch = []
        real_validate = query.validate
        def observe_query(evidence, entry, executable, query_driver, output_dir, *args, **kwargs):
            directory = pathlib.Path(output_dir).resolve()
            assert directory.is_dir(), 'validation must own an existing scratch directory'
            scratch.append(directory)
            return real_validate(evidence, entry, executable, query_driver, output_dir, *args, **kwargs)
        with patch.object(query, 'validate', observe_query):
            checked = batch.validate_receipts(receipts, clangd, server_profile=profile)
        assert checked['ok'] and checked['reason'] == 'verified-receipts-current', checked
        after = proof_store_state()
        changes = {'added_paths': sorted(set(after['paths']) - set(before['paths'])),
                   'removed_paths': sorted(set(before['paths']) - set(after['paths'])),
                   'changed_files': [path for path, value in before['files'].items() if after['files'].get(path) != value],
                   'changed_directory_mtimes': {path: {'before': value, 'after': after['directories'].get(path)}
                       for path, value in before['directories'].items() if after['directories'].get(path) != value},
                   'scratch': [{'path': str(path), 'inside_store': path == store or store in path.parents,
                                'exists_after_validation': path.exists()} for path in scratch]}
        assert before == after, 'native query validation changed the watched proof store: ' + json.dumps(changes)
        assert scratch and all(path != store and store not in path.parents for path in scratch), changes
        assert all(not path.exists() for path in scratch), 'validation scratch must be removed before returning'
        # The scratch-location repair must not weaken the dependency-byte gate.
        changed = source / 'Member0.cpp'
        raw, stamp = changed.read_bytes(), changed.stat()
        changed.write_bytes(raw.replace(b'source revision 1', b'source revision 2'))
        os.utime(changed, ns=(stamp.st_atime_ns, stamp.st_mtime_ns))
        with patch.object(query, 'validate', side_effect=AssertionError('stale receipt must fail before querying')) as queries:
            stale = batch.validate_receipts(receipts, clangd, server_profile=profile)
        assert not stale['ok'] and stale['reason'] == 'receipt-input-or-asset-changed', stale
        assert queries.call_count == 0 and proof_store_state() == before
        print('native server-profile validation leaves watched proof store unchanged, owns external temporary scratch, rejects true source changes')
        sys.exit(0)

    if operation == 'budget':
        source = root / 'Engine/Source/Runtime/Sample/Private'
        source.mkdir(parents=True)
        wrappers = root / 'stable/super_unity_cpps'
        wrappers.mkdir(parents=True)
        bodies = ['static int value = 1; int alpha() { return value; }\n',
                  'static int value = 2; int beta() { return value; }\n',
                  'int gamma() { return 3; }\n', 'int delta() { return 4; }\n',
                  'int firstContext() { return VALUE; }\n', 'int secondContext() { return VALUE; }\n']
        entries = []
        for index, body in enumerate(bodies):
            member = source / ('Member' + str(index) + '.cpp')
            member.write_text(body)
            wrapper = wrappers / ('SuperUnity.UBT.' + str(index) + '.cpp')
            wrapper.write_text('// Compiler-authored UBT unity membership; copied into nvim cache.\n'
                               + '#include "' + member.as_posix() + '"\n')
            flags = ['-std=c++17', '-c', str(wrapper)]
            if index >= 4: flags.insert(0, '-DVALUE=' + str(index))
            entries.append({'directory': str(source), 'file': str(wrapper),
                'arguments': [str(compiler)] + flags,
                'nvim_ue_members': [batch.portable_member_path(str(member))],
                'nvim_ue_module_root': 'Engine/Source/Runtime/Sample'})
        with patch.object(batch, '_prove', wraps=batch._prove) as proofs:
            output, metrics = batch.accelerate(entries, root / 'proofs', clangd,
                max_group=2, timeout=30, max_new_groups=1)
        assert output == entries and metrics['batch_count'] == 0, metrics
        assert proofs.call_count == metrics['new_proof_count'] == 1, metrics
        assert proofs.call_args.args[0] == entries[:2], 'only the conflicting first candidate may start'
        assert len(metrics['groups']) == 2, metrics
        rejected, deferred = metrics['groups']
        assert rejected['original_indexes'] == [0, 1]
        assert rejected['reason'].startswith('private-index-failed: compiler-errors:'), metrics
        assert deferred['original_indexes'] == [2, 3] and deferred['deferred'], metrics
        assert deferred['reason'] == 'verification-budget-exhausted', metrics
        assert metrics['deferred_group_count'] == 1 and metrics['accepted_ubt_count'] == 0, metrics
        assert output[4:] == entries[4:], 'adjacent incompatible macro contexts must retain original argv'
        assert not (root / 'proofs/accepted-groups.json').exists()
        print('real static collision retained; exhausted budget never starts the next candidate; macro contexts preserved')
        sys.exit(0)

    generators = {name: module(name) for name in ('build_clangd_index', 'build_full_cdb')}
    real_accelerate, real_popen = batch.accelerate, subprocess.Popen
    for name, generator in generators.items():
        scope = root / name
        source = scope / 'Engine/Source/Runtime/Sample/Private'
        source.mkdir(parents=True)
        unity_root = scope / 'Build/Intermediate/Build/Host/Target/Development'
        pch = unity_root / 'Engine/PCH.h'
        pch.parent.mkdir(parents=True)
        pch.write_text('#pragma once\n')
        flags = ['-std=c++17', '-include', str(pch), '-c']
        entries = []
        # The first pair has four members; the later pair has two. The bounded
        # producer should qualify the cheaper complete UBT groups first.
        for index, count in enumerate((2, 2, 1, 1)):
            members = []
            for member_index in range(count):
                member = source / ('Member' + str(index) + '_' + str(member_index) + '.cpp')
                member.write_text('int member' + str(index) + '_' + str(member_index) + '() { return 1; }\n')
                members.append(member)
                entries.append({'directory': str(scope / 'Engine/Source'), 'file': str(member),
                    'arguments': [str(compiler)] + flags + [str(member)]})
            unity = unity_root / 'Sample' / ('Module.Sample.' + str(index) + '.cpp')
            unity.parent.mkdir(exist_ok=True)
            unity.write_text(''.join('#include "' + member.as_posix() + '"\n' for member in members))
            argv = flags + [str(unity)]
            response = subprocess.list2cmdline(argv) if os.name == 'nt' else shlex.join(argv)
            pathlib.Path(str(unity) + '.o.rsp').write_text(response)
        for filename in ('Loose.cpp', 'Shader.usf'):
            path = source / filename
            path.write_text('// exact fallback\n')
            entries.append({'directory': str(source), 'file': str(path),
                'arguments': [str(compiler), '-x', 'c++', '-c', str(path)]})
        input_path = scope / 'input.json'
        input_path.write_text(json.dumps(entries))
        super_dir = scope / 'stable/super_unity_cpps'
        store = super_dir.parent / 'verified_batches'
        output, marker = scope / 'background.json', scope / 'marker.json'
        active = scope / 'active.json'

        def generate(limit=None, compiler_free=False):
            observed = []
            def observe(*args, **kwargs):
                assert kwargs['verify_missing'] is True and kwargs['max_new_groups'] == limit
                result = real_accelerate(*args, **kwargs)
                observed.append(result[1])
                return result
            def generator_only(command, *args, **kwargs):
                assert pathlib.Path(command[0]).resolve() == pathlib.Path(sys.executable).resolve(), command
                return real_popen(command, *args, **kwargs)
            argv = [name, str(input_path)]
            if name == 'build_full_cdb':
                argv += [str(active), '--idx-output', str(marker)]
            else:
                argv += ['--output', str(marker)]
            argv += ['--background-output', str(output), '--super-dir', str(super_dir)]
            if limit is not None:
                argv += ['--verified-batches', '--clangd', clangd, '--batch-size', '2', '--batch-proof-limit', str(limit)]
            captured = io.StringIO()
            with contextlib.ExitStack() as guards:
                guards.enter_context(patch.object(sys, 'argv', argv))
                guards.enter_context(contextlib.redirect_stdout(captured))
                guards.enter_context(patch.object(batch, 'accelerate', observe))
                if compiler_free:
                    proofs = guards.enter_context(patch.object(batch, '_prove', side_effect=AssertionError('unexpected fresh proof')))
                    graphs = guards.enter_context(patch.object(batch, 'compare_graphs', side_effect=AssertionError('unexpected graph replay')))
                    guards.enter_context(patch.object(subprocess, 'Popen', generator_only))
                code = generator.main()
                if compiler_free: assert proofs.call_count == graphs.call_count == 0
            assert code == 0, captured.getvalue()
            return json.loads(output.read_text()), observed[-1] if observed else None

        originals, _ = generate()
        wrappers = [entry for entry in originals if batch._is_ubt(entry)]
        assert len(wrappers) == 4 and len(originals) == 6, originals
        with patch.object(batch, '_prove', wraps=batch._prove) as proofs, \
             patch.object(batch, 'compare_graphs', wraps=batch.compare_graphs) as graphs:
            current, metrics = generate(2)
        assert proofs.call_count == metrics['new_proof_count'] == 1 and graphs.call_count > 0, metrics
        assert metrics['batch_count'] == 1 and metrics['accepted_ubt_count'] == 2, metrics
        assert len(current) == 5 and metrics['retained_ubt_count'] == 2, metrics
        assert metrics['qualification_limit'] == 2 and metrics['deferred_group_count'] == 1, metrics
        assert metrics['groups'][0]['accepted'] and metrics['groups'][0]['run_metrics'], metrics
        assert sum(len(entry['nvim_ue_members']) for entry in proofs.call_args.args[0]) == 2
        assert metrics['groups'][1]['reason'] == 'verification-stage-complete', metrics
        assert sorted(member for entry in current for member in entry['nvim_ue_members']) \
            == sorted(member for entry in originals for member in entry['nvim_ue_members'])
        exact = [entry for entry in originals if not batch._is_ubt(entry)]
        assert [entry for entry in current if not batch._is_ubt(entry) and not entry.get('nvim_ue_batch_receipt')] == exact
        assert json.loads(pathlib.Path(str(output) + '.semantic.json').read_text()) == originals
        counts = json.loads(marker.read_text())['verified_batches']
        assert counts['batch_count'] == 1 and counts['exact_count'] == counts['shader_count'] == 1, counts
        cache_paths = list((store / 'receipts').glob('*.json'))
        assert len(cache_paths) == 1, cache_paths
        record = json.loads(cache_paths[0].read_text())
        candidate = next(entry for entry in current if entry.get('nvim_ue_batch_receipt'))
        receipt = pathlib.Path(candidate['nvim_ue_batch_receipt'])
        assert candidate['nvim_ue_batch_ubt_count'] == 2
        assert batch.validate_receipts([str(receipt)], clangd)['ok']
        hints = store / 'accepted-groups.json'
        assert len(json.loads(hints.read_text())['groups']) == 1
        protected = {pathlib.Path(item['path']) for item in record['assets'] + record['graph_files']}
        protected.update(pathlib.Path(entry['file']) for entry in wrappers)
        protected.update((cache_paths[0], hints, receipt))
        published = [output, marker, pathlib.Path(str(output) + '.semantic.json')]
        if name == 'build_full_cdb': published += [active, pathlib.Path(str(active) + '.indexer')]
        before = snapshot(protected | set(published))
        def store_state():
            paths = list(store.rglob('*'))
            return {'paths': sorted(path.relative_to(store).as_posix() for path in paths),
                    'files': {path.relative_to(store).as_posix():
                        (batch._sha(path.read_bytes()), path.stat().st_mtime_ns)
                        for path in paths if path.is_file()},
                    'directories': {path.relative_to(store).as_posix(): path.stat().st_mtime_ns
                        for path in [store] + paths if path.is_dir()}}
        before_store = store_state()
        assert (pathlib.Path(metrics['proof_directory']) / 'metrics.json').is_file(), \
            'a real new proof must retain its evidence directory and metrics'
        limited, zero = generate(0, compiler_free=True)
        assert limited == current and zero['cache_hits'] == zero['batch_count'] == 1, zero
        assert zero['new_proof_count'] == 0, zero
        assert_snapshot(before, 'zero-budget cached prepare rewrote publication')
        assert store_state() == before_store, 'zero-budget prepare changed proof storage'

        with patch.object(batch, '_prove', wraps=batch._prove) as next_proofs:
            expanded, second = generate(2)
        assert second['cache_hits'] == 1 and second['batch_count'] == 2, second
        assert next_proofs.call_count == second['new_proof_count'] == second['new_batch_count'] == 1, second
        assert zero['groups'][1]['reason'] == 'verification-budget-exhausted', zero
        assert second['accepted_ubt_count'] == 4 and second['retained_ubt_count'] == 0, second
        assert second['deferred_group_count'] == 0 and len(expanded) == 4, second
        assert sorted(member for entry in expanded for member in entry['nvim_ue_members']) \
            == sorted(member for entry in originals for member in entry['nvim_ue_members'])
        assert [entry for entry in expanded if not entry.get('nvim_ue_batch_receipt')] == exact
        assert json.loads(pathlib.Path(str(output) + '.semantic.json').read_text()) == originals
        assert_snapshot({path: value for path, value in before.items()
                         if pathlib.Path(path) in protected and pathlib.Path(path) != hints},
                        'incremental proof rewrote the previously accepted proof')
        assert len(json.loads(hints.read_text())['groups']) == 2
        assert json.loads(marker.read_text())['verified_batches']['batch_count'] == 2
        for path in (store / 'receipts').glob('*.json'):
            item = json.loads(path.read_text())
            protected.update(pathlib.Path(asset['path']) for asset in item['assets'] + item['graph_files'])
            protected.add(path)
        current = expanded
        before = snapshot(protected | set(published))
        before_store = store_state()
        for _ in range(2):
            again, warm = generate(2, compiler_free=True)
            assert again == current and warm['cache_hits'] == 2 and warm['new_proof_count'] == 0, warm
            assert warm['group_hints_status'] == 'loaded' and warm['batch_count'] == 2, warm
            assert warm['new_batch_count'] == 0 and warm['proof_directory'] is None, warm
            assert all(group['run_metrics'] == [] for group in warm['groups']), warm
            assert_snapshot(before, 'unchanged bounded prepare rewrote proof or publication')
            assert store_state() == before_store, 'cached prepare changed watched proof store paths or directory mtimes'
        changed_commands = [dict(entry, arguments=entry['arguments'] + ['-DBUILD_REVISION=2'])
                            if batch._is_ubt(entry) else entry for entry in originals]
        with patch.object(batch, '_prove', side_effect=AssertionError('zero-budget config change must not prove')), \
             patch.object(batch, 'compare_graphs', side_effect=AssertionError('zero-budget config change must not replay')):
            configured, obsolete = batch.accelerate(changed_commands, store, clangd, max_group=2,
                                                    timeout=30, max_new_groups=0)
        assert configured == changed_commands and obsolete['cache_hits'] == obsolete['batch_count'] == 0, obsolete
        assert obsolete['deferred_group_count'] == 2 and obsolete['new_proof_count'] == 0, obsolete
        assert all(group['reason'] == 'verification-budget-exhausted' for group in obsolete['groups']), obsolete
        assert_snapshot(before, 'changed build configuration rewrote cached proof or publication')
        assert store_state() == before_store, 'changed configuration touched proof storage'
        # A same-size edit with restored mtime must invalidate the actual byte
        # proof, even though all CDB commands and wrapper membership remain equal.
        for group in (proofs.call_args.args[0], next_proofs.call_args.args[0]):
            changed = pathlib.Path(batch._validate_ubt(group[0])[0])
            raw, stamp = changed.read_bytes(), changed.stat()
            changed.write_bytes(raw.replace(b'return 1', b'return 7', 1))
            os.utime(changed, ns=(stamp.st_atime_ns, stamp.st_mtime_ns))
        assert not batch._cache_valid(record, store, {}), 'true byte change must reject the old certificate'
        validation = batch.validate_receipts([str(receipt)], clangd)
        assert not validation['ok'] and validation['reason'] == 'receipt-input-or-asset-changed', validation
        fallback, stale = generate(0, compiler_free=True)
        assert fallback == originals and stale['batch_count'] == stale['new_proof_count'] == 0, stale
        assert stale['deferred_group_count'] == 2 and stale['cache_hits'] == 0, stale
        assert all(group['reason'] == 'verification-budget-exhausted' for group in stale['groups']), stale
        assert_snapshot({path: value for path, value in before.items() if pathlib.Path(path) in protected},
                        'stale fallback rewrote protected proof artifacts')
    print('both bounded generators: batches grow 1 to 2; cached zero-budget run and complete warm reuse stay byte-stable; exact/shader coverage and true-stale fallback preserved')
]=]

local function run_fixture(operation, clangd)
  local python = vim.fn.exepath("python")
  if python == "" then python = vim.fn.exepath("python3") end
  t.assert_true(python ~= "", "Python is required for CDB generation")
  local script = vim.fn.tempname() .. "_batch_prepare.py"
  local stream = assert(io.open(script, "wb"))
  stream:write(fixture)
  stream:close()
  local result = vim.system({ python, "-B", "-I", script,
    vim.fn.stdpath("config") .. "/tools", operation, clangd or "" }, { text = true }):wait()
  pcall(vim.fn.delete, script)
  t.assert_eq(result.code, 0, (result.stderr or "") .. (result.stdout or ""))
end

t.describe("bounded verified prepare", function()
  t.it("rejects invalid proof budgets and conflicting generator modes before filesystem changes", function()
    run_fixture("arguments")
  end)
  local discovered = require("utils.ue_goto.semantic_sidecar_libclang").discover_toolchain()
  if not discovered.ok then
    t.skip("bounded prepare native compiler proofs", discovered.reason, { native = true })
    return
  end
  t.it("grows native batches through both generators while preserving budget gates, full coverage and stable complete-cache reuse", function()
    run_fixture("integration", discovered.clangd_path)
  end)
  t.it("stops at the proof budget after a native collision and preserves incompatible macro commands", function()
    run_fixture("budget", discovered.clangd_path)
  end)
  if vim.fn.has("win32") == 1 then
    t.it("validates native server-profile receipts without touching watched proof storage and rejects source changes", function()
      run_fixture("profile_validation", discovered.clangd_path)
    end)
  else
    t.skip("native server-profile receipt validation", "reviewed query-driver protocol requires Windows")
  end
end)
