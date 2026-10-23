local t = require("tests.harness")
t.bootstrap()

-- These are protocol/receipt contract fixtures, not native capability evidence.
-- The shared runner alone is replaced. Actual independent RIFF bytes go through
-- the production decoder, receipt writer, cache reuse and exclusive lease.
local fixture = [=[
import collections, contextlib, copy, hashlib, io, json, os, pathlib, struct, subprocess, sys, tempfile
from unittest.mock import patch

tool, operation = sys.argv[1:]
sys.path.insert(0, str(pathlib.Path(tool).resolve().parent))
import cdb_verified_batch as module
import cdb_background_batch as background
os.environ['NVIM_UE_BATCH_TIER'] = '1'
sha = lambda raw: hashlib.sha256(raw).hexdigest()
encoded = lambda value: json.dumps(value, sort_keys=True, ensure_ascii=True, separators=(',', ':'))
native = lambda row: {name: row[name] for name in ('directory', 'file', 'arguments')}
key = lambda path: os.path.normcase(str(pathlib.Path(path).resolve()))
u32 = lambda value: struct.pack('<I', value)

def var(value):
    raw = bytearray()
    while value > 127:
        raw.append((value & 127) | 128)
        value >>= 7
    return bytes(raw + bytes([value]))

def riff(path, flags=0, command=None, includes=(), source_uris=(), payload=None):
    # Independent v20 RIFF wire fixture, decoded by the real production reader.
    strings = ['']
    def ref(value):
        if value not in strings: strings.append(value)
        return var(strings.index(value))
    own_uri = pathlib.Path(path).resolve().as_uri()
    include_uris = [pathlib.Path(included).resolve().as_uri() for included in includes]
    source = bytes([flags]) + ref(own_uri) + b'12345678' + var(len(includes))
    source += b''.join(ref(uri) for uri in include_uris)
    for uri in dict.fromkeys(include_uris + list(source_uris)):
        if uri != own_uri:
            source += b'\0' + ref(uri) + b'\0' * 8 + var(0)
    refs = b'\x01' * 8 + var(1) + b'\x04' + ref(own_uri) + var(0) * 4 + b'\0' * 8 if payload == 'refs' else b''
    relations = b'\x01' * 8 + b'\x01' + b'\x02' * 8 if payload == 'relations' else b''
    cmdl = None if command is None else ref(command['directory']) + var(len(command['arguments'])) + b''.join(ref(arg) for arg in command['arguments'])
    table = b''.join(item.encode('utf-8') + b'\0' for item in strings)
    chunks = [(b'meta', u32(20)), (b'stri', u32(0) + table), (b'symb', b''),
        (b'refs', refs), (b'rela', relations), (b'srcs', source)]
    if cmdl is not None: chunks.append((b'cmdl', cmdl))
    body = b'CdIx' + b''.join(tag + u32(len(data)) + data + (b'\0' if len(data) & 1 else b'') for tag, data in chunks)
    return b'RIFF' + u32(len(body)) + body

def rejected(callback):
    try:
        callback()
    except (ValueError, OSError):
        return
    raise AssertionError('invalid cohort or concurrent writer admitted')

with tempfile.TemporaryDirectory(prefix='tier1_cohort_contract_') as temporary, contextlib.ExitStack() as stack:
    root = pathlib.Path(temporary).resolve()
    generation = root / 'generation'
    source = root / 'Source'; source.mkdir()
    driver = str(pathlib.Path(sys.executable).resolve())
    if operation == 'driver_changed':
        # Actual executable bytes copied solely for a file-identity mutation.
        # This file and sys.executable are never launched by these fixtures.
        copied_driver = root / pathlib.Path(driver).name
        copied_driver.write_bytes(pathlib.Path(driver).read_bytes())
        driver = str(copied_driver)
    profile = {'query_driver': driver, 'launch_cwd': root.as_posix(), 'enable_config': False} if operation == 'path_changed' else None
    header = source / 'Shared.h'; header.write_text('#define SHARED_VALUE 1\n', encoding='utf-8')
    alpha, beta, delta = [source / (name + '.cpp') for name in ('alpha', 'beta', 'delta')]
    for path in (alpha, beta, delta):
        path.write_text('#include "Shared.h"\nint ' + path.stem + '() { return SHARED_VALUE; }\n', encoding='utf-8')
    def unit(index, member):
        wrapper = source / ('SuperUnity.UBT.%d.cpp' % index)
        wrapper.write_text('// Compiler-authored UBT unity membership; copied into nvim cache.\n'
            + '#include "' + member.as_posix() + '"\n', encoding='utf-8')
        return {'directory': str(root), 'file': str(wrapper),
            'arguments': [driver, '-std=c++17', '-c', str(wrapper)],
            'nvim_ue_module_root': str(root / ('Module%d' % (index // 2))),
            'nvim_ue_members': [module.portable_member_path(str(member))]}
    entries = [unit(0, alpha), unit(1, beta), unit(2, alpha), unit(3, delta)]
    original_entries = copy.deepcopy(entries)
    cdb = root / 'originals.json'; cdb.write_text(json.dumps(entries), encoding='utf-8')
    plan = background.make_plan(cdb, generation / 'verified_batches', sys.executable)
    specs = plan['groups']
    assert [group['indexes'] for group in specs] == [[0, 1], [2, 3]]
    all_inputs = {entry['file'] for entry in entries} | {str(path) for path in (alpha, beta, delta, header)}
    input_seal = {path: sha(pathlib.Path(path).read_bytes()) for path in all_inputs}
    expected_coverage = collections.Counter(member for entry in entries for member in entry['nvim_ue_members'])
    assert expected_coverage[module.portable_member_path(str(alpha))] == 2
    stack.enter_context(patch.object(subprocess, 'Popen', side_effect=AssertionError('contract fixture must not spawn native processes')))
    stack.enter_context(patch.object(module, '_tier1_candidate_index', side_effect=AssertionError('cohort cannot fabricate two independent runs')))

    def snapshot(directory):
        return {str(path.relative_to(directory)): (path.read_bytes(), path.stat().st_mtime_ns)
            for path in directory.rglob('*') if path.is_file()}

    if operation == 'legacy_receipt':
        # Build an unchanged schema1 receipt without the new commit helper.
        # This is receipt compatibility evidence, not a native compiler claim.
        selected = entries[:2]
        store = root / 'legacy'
        candidate, body = module._tier1_candidate_spec(selected, store / 'tier1/assets')
        pathlib.Path(candidate['file']).parent.mkdir(parents=True)
        pathlib.Path(candidate['file']).write_bytes(body.encode('utf-8'))
        tool_hash = sha(pathlib.Path(sys.executable).read_bytes())
        environment = module._compiler_environment(None)
        expected_key = sha(encoded({'original_entries': [native(row) for row in selected],
            'candidate': native(candidate), 'tool_sha256': tool_hash, 'server_profile': None,
            'compiler_environment': environment}).encode())
        assert module._tier1_cache_key(selected, candidate, tool_hash, None, environment) == expected_key
        # Preserve the canonical wrapper's literal member spelling and order.
        inputs = sorted({entry['file'] for entry in selected} | {alpha.as_posix(), beta.as_posix()})
        receipt = {'schema': 1, 'tier': 1, 'reusable': True, 'cache_key': expected_key,
            'accepted': True, 'reason': 'tier1-compile-shards-members-accepted',
            'gates': {'compile_success': True, 'main_shards_complete': True, 'members_equal': True},
            'inputs': [{'path': path, 'sha256': sha(pathlib.Path(path).read_bytes())} for path in inputs],
            'compile_result': {'indexing_complete': True, 'exit_code': 0, 'compile_failure_count': 0, 'shard_had_errors': False},
            'original_entries': [native(row) for row in selected], 'candidate': native(candidate),
            'candidate_sha256': sha(body.encode('utf-8')), 'members': candidate['nvim_ue_members'],
            'tool_sha256': tool_hash, 'server_profile': None, 'compiler_environment': environment}
        raw = encoded(receipt).encode()
        receipt_dir = store / 'tier1/receipts'; receipt_dir.mkdir()
        receipt_path = receipt_dir / ('receipt.' + sha(raw)[:24] + '.json'); receipt_path.write_bytes(raw)
        (receipt_dir / (expected_key + '.json')).write_text(encoded({'schema': 1, 'tier': 1,
            'cache_key': expected_key, 'accepted': True, 'receipt': str(receipt_path),
            'receipt_sha256': sha(raw)}), encoding='utf-8')
        before = snapshot(root)
        with patch.object(module, 'run', side_effect=AssertionError('legacy receipt launched cohort')), \
                patch.object(module, '_write', side_effect=AssertionError('legacy receipt rewritten')):
            for action in (module.reuse_tier1, module.accelerate_tier1):
                output, metrics = action(selected, store, sys.executable)
                assert metrics['batch_count'] == metrics['cache_hits'] == 1 and len(output) == 1
                assert output[0]['nvim_ue_tier1_receipt'] == str(receipt_path)
                assert pathlib.Path(output[0]['nvim_ue_tier1_receipt']).read_bytes() == raw
        assert snapshot(root) == before and entries == original_entries
        print('legacy schema1 key, immutable receipt bytes, and ordinary reuse remain unchanged')
        sys.exit(0)

    def qualify(seal=None, selected_entries=None, selected_specs=None):
        return module.qualify_tier1_cohort(entries if selected_entries is None else selected_entries,
            specs if selected_specs is None else selected_specs, generation, sys.executable,
            timeout=30, server_profile=profile, position_encoding='utf-8', input_seal=input_seal if seal is None else seal)

    calls, run_reports = [], []
    shard_reads = collections.Counter()
    original_read = pathlib.Path.read_bytes
    def read_bytes(path):
        if path.suffix == '.idx': shard_reads[str(path.resolve())] += 1
        return original_read(path)

    def shared_run(cdb_dir, out_dir, trigger, clangd, timeout=90, jobs=1, server_profile=None,
            *, position_encoding=None, cache_environment=None, require_main_evidence=False):
        cdb_dir, out_dir, trigger = map(lambda path: pathlib.Path(path).resolve(), (cdb_dir, out_dir, trigger))
        assert pathlib.Path(clangd).resolve() == pathlib.Path(sys.executable).resolve()
        assert timeout == 30 and jobs == 1 and position_encoding == 'utf-8' and require_main_evidence
        assert cache_environment is not None and server_profile == profile
        environment = pathlib.Path(cache_environment).resolve()
        calls.append({'cdb_dir': str(cdb_dir), 'trigger': str(trigger), 'cache_environment': str(environment)})
        commands = json.loads((cdb_dir / 'compile_commands.json').read_text(encoding='utf-8'))
        assert len(commands) == 3 and sum(key(row['file']) == key(trigger) for row in commands) == 1
        candidates = [row for row in commands if key(row['file']) != key(trigger)]
        assert len(candidates) == 2 and all(pathlib.Path(row['file']).is_file() for row in candidates)
        if operation == 'ownership':
            before = snapshot(generation)
            rejected(qualify)
            assert snapshot(generation) == before, 'second producer changed the active generation'
        if operation == 'timeout':
            raise subprocess.TimeoutExpired('mock shared producer', timeout)
        cache = cdb_dir / '.cache/clangd/index'; cache.mkdir(parents=True)
        environment.mkdir(parents=True, exist_ok=True)
        out_dir.mkdir(parents=True, exist_ok=True)
        shards = []
        for index, command in enumerate(commands):
            path = cache / (pathlib.Path(command['file']).name + '.fixture.idx')
            included = operation == 'included_only' and key(command['file']) == key(candidates[0]['file'])
            effective_command = copy.deepcopy(command)
            if operation == 'changed_command' and key(command['file']) == key(candidates[0]['file']):
                effective_command['arguments'] = ['-std=c++14' if arg == '-std=c++17' else arg
                    for arg in effective_command['arguments']]
            members = () if key(command['file']) == key(trigger) else ((alpha, beta) if index == 0 else (alpha, delta))
            if operation == 'unreachable': members = ()
            extra_sources = tuple(member.resolve().as_uri() for member in members) if operation == 'sources_only' else ()
            path.write_bytes(riff(command['file'], flags=0 if included else 1, command=None if included else effective_command,
                includes=() if operation == 'sources_only' else members, source_uris=extra_sources))
            shards.append(str(path))
        for path in (alpha, beta, delta, header):
            shard = cache / (path.name + '.fixture.idx')
            includes = () if path == header or operation in ('orphan_refs', 'orphan_relations') else (header,)
            extra_sources = ()
            if path == header:
                if operation == 'cycle': extra_sources = (alpha.resolve().as_uri(),)
                if operation == 'missing_dependency': extra_sources = ((source / 'Missing.h').as_uri(),)
                if operation == 'invalid_uri': extra_sources = ('https://invalid.test/Shared.h',)
            payload = operation.removeprefix('orphan_') if path == header and operation.startswith('orphan_') else None
            shard.write_bytes(riff(path, includes=includes, source_uris=extra_sources, payload=payload))
            shards.append(str(shard))
        effective = 'utf-16' if operation == 'encoding' else 'utf-8'
        main_events = [{'path': key(row['file']), 'seconds': 1.0 + index,
            'line': 'I[00:00:00.000] Indexed ' + row['file'] + ' (1 symbols, 1 refs, 1 files)'}
            for index, row in enumerate(commands)]
        if operation == 'wrong_main_path':
            main_events[0]['path'] = key(root / 'foreign' / pathlib.Path(commands[0]['file']).name)
        token = 'foregroundProgress' if operation == 'wrong_progress' else 'backgroundIndexProgress'
        report = {'background_compile_success': operation != 'shared_failure', 'initialized': True,
            'indexing_complete': True, 'exit_code': 0, 'compile_failure_count': int(operation == 'shared_failure'),
            'shard_had_errors': False, 'missing_main_shards': [], 'shards': shards, 'shard_count': len(shards),
            'shutdown_response': True, 'shutdown_clean': True, 'process_reaped': True,
            'position_encoding': {'requested': 'utf-8', 'standard': effective, 'extension': None,
                'effective': effective, 'source': 'standard'},
            'main_events': main_events,
            'loaded_cdb_events': [{'path': str((root / 'foreign' if operation == 'wrong_loaded_path' else cdb_dir)
                / 'compile_commands.json'), 'seconds': 0.5, 'line': 'I[00:00:00.000] Loaded compilation database from '
                + str((root / 'foreign' if operation == 'wrong_loaded_path' else cdb_dir) / 'compile_commands.json')}],
            'background_progress': {'token': token, 'begins': 1, 'ends': 1, 'pairs': 1, 'open': 0,
                'errors': [], 'complete': True},
            'observed_progress': [{'token': token, 'value': {'kind': 'begin'}},
                {'token': token, 'value': {'kind': 'end'}}],
            'observers': {'eof': {'stdout': True, 'stderr': operation != 'observer_eof'}, 'errors': [], 'joined': True},
            'cdb_sha256': sha((cdb_dir / 'compile_commands.json').read_bytes()),
            'cdb_dir': str(cdb_dir), 'root_uri': cdb_dir.as_uri(),
            'launch_cwd': pathlib.Path(profile['launch_cwd']).as_posix() if profile else cdb_dir.as_posix(), 'server_profile': profile,
            'isolated_environment': {'LOCALAPPDATA': str(environment), 'XDG_CACHE_HOME': str(environment / 'cache'),
                'TEMP': str(environment), 'TMP': str(environment)},
            'command': [str(clangd), '--compile-commands-dir=' + str(cdb_dir), '--background-index',
                '--enable-config=false', '-j=1', '--log=info'] + (['--query-driver=' + profile['query_driver']] if profile else []),
            'indexing_wall_seconds': 8.0, 'process_wall_seconds': 9.0, 'cpu_seconds': 7.0}
        run_reports.append(report)
        return report

    if operation == 'external_store':
        definitions = copy.deepcopy(specs)
        external = root / 'external'
        definitions[0]['store'] = str(external / 'background-proofs/tier1' / definitions[0]['id'])
        before = snapshot(root)
        with patch.object(module, 'run', side_effect=AssertionError('external store launched producer')):
            rejected(lambda: qualify(selected_specs=definitions))
        assert snapshot(root) == before and not external.exists() and not generation.exists()
        print('canonical-looking external stores are rejected before any asset or generation write')
        sys.exit(0)

    if operation == 'runner_init_cleanup':
        import clangd_batch_runner as runner
        native_cdb = root / 'runner-input'; native_cdb.mkdir()
        (native_cdb / 'compile_commands.json').write_text(json.dumps([native(entries[0])]), encoding='utf-8')
        class Process:
            def __init__(self):
                self.returncode = None
                self.kills = self.waits = 0
                self.stdin, self.stdout, self.stderr = io.BytesIO(), io.BytesIO(), io.BytesIO()
            def poll(self): return self.returncode
            def kill(self):
                self.kills += 1
                self.returncode = -9
            def wait(self):
                self.waits += 1
                return self.returncode
        path_open = pathlib.Path.open
        for failure in ('log-open', 'thread-start'):
            process, opened = Process(), []
            out = root / failure
            def open_path(path, *args, **kwargs):
                if failure == 'log-open' and path.name == 'clangd.stderr.log':
                    raise OSError('injected log-open failure')
                stream = path_open(path, *args, **kwargs)
                if path.parent == out: opened.append(stream)
                return stream
            with patch.object(runner.subprocess, 'Popen', return_value=process) as spawn, \
                    patch.object(pathlib.Path, 'open', open_path), contextlib.ExitStack() as lifecycle:
                if failure == 'thread-start':
                    lifecycle.enter_context(patch.object(runner.threading.Thread, 'start',
                        side_effect=RuntimeError('injected thread-start failure')))
                try:
                    runner.run(native_cdb, out, pathlib.Path(entries[0]['file']), sys.executable, timeout=1)
                    raise AssertionError('injected initialization failure was swallowed')
                except (OSError, RuntimeError) as error:
                    assert str(error) == 'injected ' + failure + ' failure', str(error)
            assert opened and all(stream.closed for stream in opened)
            if failure == 'log-open':
                assert spawn.call_count == process.kills == process.waits == 0
            else:
                assert spawn.call_count == process.kills == process.waits == 1 and process.poll() is not None
        print('log setup fails before spawning; thread startup failure reaps the sole owned fake process')
        sys.exit(0)

    if operation == 'scope':
        duplicate = copy.deepcopy(specs); duplicate[1]['indexes'] = list(specs[0]['indexes'])
        cases = [(entries, duplicate), (entries + [{'file': str(root / 'extra.cpp'),
            'directory': str(root), 'arguments': ['clang++', str(root / 'extra.cpp')]}], specs),
            (entries + [{'file': str(root / 'extra.usf'), 'directory': str(root),
                'arguments': ['clang++', str(root / 'extra.usf')],
                'nvim_ue_background_route': 'shader-compatibility'}], specs)]
        with patch.object(module, 'run', side_effect=AssertionError('invalid scope launched producer')):
            for number, (selected_entries, selected_specs) in enumerate(cases):
                target = root / ('invalid-scope-%d' % number)
                definitions = [dict(group, store=str(target / pathlib.Path(group['store']).relative_to(generation)))
                    for group in selected_specs]
                rejected(lambda: module.qualify_tier1_cohort(selected_entries, definitions, target,
                    sys.executable, timeout=30, server_profile=profile, position_encoding='utf-8', input_seal=input_seal))
                assert not list(target.rglob('receipt.*.json'))
        print('overlap and unsupported retained exact/shader scope are rejected before producer work')
        sys.exit(0)

    original_write = module._write
    failed_index = []
    def write(path, content):
        path = pathlib.Path(path)
        if (operation == 'partial_commit' and path.parent == pathlib.Path(specs[1]['store']) / 'tier1/receipts'
                and len(path.stem) == 64 and all(char in '0123456789abcdef' for char in path.stem)):
            failed_index.append(str(path))
            raise OSError('injected second receipt cache-index commit failure')
        return original_write(path, content)

    seal = dict(input_seal)
    if operation == 'seal_missing': seal.pop(str(alpha))
    with patch.object(module, 'run', side_effect=shared_run) as producer, \
            patch.object(module, '_write', side_effect=write), \
            patch.object(module, 'decode_shard', wraps=module.decode_shard) as decoded, \
            patch.object(pathlib.Path, 'read_bytes', read_bytes):
        output, metrics = qualify(seal)
    assert producer.call_count == len(calls) == 1, 'cohort must call the producer once'
    assert entries == original_entries
    assert metrics['coverage_complete'] and module._tier1_source_coverage(output) == expected_coverage
    assert len(metrics['groups']) == 2
    assert all(not record.get('run_metrics') for record in metrics['groups']), 'shared cost was duplicated per group'
    failed = operation in ('shared_failure', 'timeout', 'included_only', 'wrong_main_path', 'wrong_loaded_path', 'changed_command', 'observer_eof', 'wrong_progress')
    if failed:
        assert output == entries and metrics['batch_count'] == 0
        assert all(not record['accepted'] for record in metrics['groups'])
        assert metrics['handoff']['ready'] is False
        assert not list(generation.rglob('receipt.*.json')), 'shared failure fanned out semantic negative receipts'
        for group in specs:
            selected = [entries[index] for index in group['indexes']]
            before = snapshot(generation)
            reused, cached = module.reuse_tier1(selected, group['store'], sys.executable, server_profile=profile)
            assert reused == selected and cached['cache_hits'] == 0 and cached['batch_count'] == 0
            assert snapshot(generation) == before
        print('shared execution or exact-main evidence failure retains all originals without negative fan-out')
        sys.exit(0)

    assert metrics['cohort_run'] == run_reports[0], 'aggregate producer evidence must remain one truthful record'
    if operation == 'partial_commit':
        assert failed_index and output == entries and metrics['batch_count'] == 0 and not metrics['handoff']['ready']
        assert [item['committed'] for item in metrics['partial_commits']] == [True, False]
        assert 'injected second receipt' in metrics['partial_commits'][1]['error']
        with patch.object(module, 'run', side_effect=AssertionError('partial receipt reuse spawned')):
            first, first_metrics = module.reuse_tier1(entries[:2], specs[0]['store'], sys.executable, server_profile=profile)
            second, second_metrics = module.reuse_tier1(entries[2:], specs[1]['store'], sys.executable, server_profile=profile)
        assert len(first) == 1 and first_metrics['batch_count'] == first_metrics['cache_hits'] == 1
        assert second == entries[2:] and second_metrics['batch_count'] == second_metrics['cache_hits'] == 0
        print('partial commit remains diagnostic; only the actually committed individual proof reuses')
        sys.exit(0)

    assert metrics['batch_count'] == 2 and metrics['accepted_ubt_count'] == 4 and len(output) == 2
    assert all(record['accepted'] and record.get('main_evidence_key') for record in metrics['groups'])
    assert len({record['main_evidence_key'] for record in metrics['groups']}) == 2
    assert sum(module._tier1_source_coverage(output).values()) == 4
    assert module._tier1_source_coverage(output)[module.portable_member_path(str(alpha))] == 2
    assert shard_reads and all(count == 1 for count in shard_reads.values()), 'qualification reread shards for a second decode/seal pass'
    assert decoded.call_count == len(shard_reads), 'qualification decoded a shard more than once'
    for index, group in enumerate(specs):
        selected = [entries[position] for position in group['indexes']]
        receipt = json.loads(pathlib.Path(output[index]['nvim_ue_tier1_receipt']).read_bytes())
        candidate = native(output[index])
        expected_key = sha(encoded({'original_entries': [native(row) for row in selected], 'candidate': candidate,
            'tool_sha256': sha(pathlib.Path(sys.executable).read_bytes()), 'server_profile': profile,
            'compiler_environment': module._compiler_environment(profile)}).encode())
        assert receipt['schema'] == receipt['tier'] == 1 and receipt['accepted'] and receipt['reusable']
        assert receipt['cache_key'] == expected_key
        assert receipt['qualification'] == {'kind': 'cohort',
            'evidence_sha256': sha(pathlib.Path(metrics['cohort_evidence']).read_bytes()),
            'main_uri': pathlib.Path(candidate['file']).resolve().as_uri()}
        before = snapshot(generation)
        with patch.object(module, 'run', side_effect=AssertionError('ordinary receipt reuse launched producer')):
            reused, cached = module.reuse_tier1(selected, group['store'], sys.executable, server_profile=profile)
        assert reused == [output[index]] and cached['cache_hits'] == cached['batch_count'] == 1
        assert snapshot(generation) == before
    loader_failures = {'unreachable': 'unreachable-shards', 'orphan_refs': 'unreachable-shards',
        'orphan_relations': 'unreachable-shards', 'missing_dependency': 'missing-dependency-own', 'invalid_uri': 'invalid-source-uri'}
    if operation in ('encoding', 'seal_missing') or operation in loader_failures:
        assert metrics['handoff']['ready'] is False and metrics['handoff']['reason']
        assert metrics['handoff']['manifest'] is None and not (generation / 'cohort-cache.json').exists()
        if operation in loader_failures:
            assert metrics['handoff']['reason'] == 'cohort-handoff-' + loader_failures[operation], metrics['handoff']
            assert metrics['handoff']['loader_seconds'] >= 0
        def reader():
            with module.tier1_cohort_reader_scope(generation, sys.executable, server_profile=profile, position_encoding='utf-8'):
                raise AssertionError('incompatible cache handed to reader')
        rejected(reader)
        print('handoff incompatibility leaves truthful ordinary semantic receipts reusable')
        sys.exit(0)

    if operation in ('path_changed', 'driver_changed', 'header_changed'):
        assert metrics['handoff']['ready'], metrics['handoff']
        def incompatible_reader():
            with module.tier1_cohort_reader_scope(generation, sys.executable, server_profile=profile, position_encoding='utf-8'):
                raise AssertionError('changed driver identity or PATH acquired handoff')
        with contextlib.ExitStack() as changed_identity:
            if operation == 'path_changed':
                changed_identity.enter_context(patch.dict(os.environ,
                    {'PATH': os.environ.get('PATH', '') + os.pathsep + str(root / 'other-driver-search')}))
            elif operation == 'driver_changed':
                driver_path = pathlib.Path(driver)
                raw = driver_path.read_bytes()
                driver_path.write_bytes(raw[:-1] + bytes([raw[-1] ^ 1]))
            else:
                header.write_text('#define SHARED_VALUE 2\n', encoding='utf-8')
            rejected(incompatible_reader)
            for group in specs:
                selected = [entries[index] for index in group['indexes']]
                reused, cached = module.reuse_tier1(selected, group['store'], sys.executable, server_profile=profile)
                assert len(reused) == 1 and cached['batch_count'] == cached['cache_hits'] == 1
        print('handoff header/driver/PATH identity fails closed without redefining existing semantic receipt identity')
        sys.exit(0)

    assert operation in ('success', 'ownership', 'sources_only', 'cycle', 'reader_tampering') and metrics['handoff']['ready'], metrics['handoff']
    assert pathlib.Path(metrics['handoff']['manifest']).is_file()
    manifest_path = pathlib.Path(metrics['handoff']['manifest'])
    manifest = json.loads(manifest_path.read_bytes())
    evidence_path = pathlib.Path(manifest['evidence']['path'])
    evidence = json.loads(evidence_path.read_bytes())
    assert manifest['schema'] == 'tier1-cohort-cache-v2' and evidence['schema'] == 'tier1-cohort-evidence-v2'
    assert manifest['loader_policy'] == evidence['loader_policy'] == 'cdb-mains-all-sources-all-own-v1'
    assert all('sources' in item for item in evidence['shards']) and all('sources' not in item for item in manifest['shards'])
    assert metrics['handoff']['loader']['reachable_count'] == metrics['handoff']['loader']['own_count'] == len(shard_reads)
    if operation == 'reader_tampering':
        original_cdb = (generation / 'compile_commands.json').read_bytes()
        original_evidence, original_manifest = evidence_path.read_bytes(), manifest_path.read_bytes()
        original_receipts = {item['receipt']: pathlib.Path(item['receipt']).read_bytes() for item in manifest['receipts']}
        mutations = ('old_cache_version', 'old_evidence_version', 'missing_sources', 'missing_policy',
            'fake_root', 'cdb_root_removed', 'inventory_removed', 'evidence_hash', 'receipt_evidence',
            'receipt_main', 'disconnected_sources', 'invalid_source_uri', 'missing_dependency')
        for mutation in mutations:
            changed, proof = copy.deepcopy(manifest), copy.deepcopy(evidence)
            if mutation == 'old_cache_version': changed['schema'] = 'tier1-cohort-cache-v1'
            elif mutation == 'old_evidence_version': proof['schema'] = 'tier1-cohort-evidence-v1'
            elif mutation == 'missing_sources': del proof['shards'][0]['sources']
            elif mutation == 'missing_policy': del proof['loader_policy']
            elif mutation == 'fake_root':
                fake = copy.deepcopy(next(iter(changed['mains'].values())))
                changed['mains'][key(header)] = fake
                proof['mains'] = changed['mains']
            elif mutation == 'cdb_root_removed':
                commands = json.loads(original_cdb)[:-1]
                raw = encoded(commands).encode()
                (generation / 'compile_commands.json').write_bytes(raw)
                changed['cdb_sha256'] = proof['cdb_sha256'] = sha(raw)
            elif mutation == 'inventory_removed': changed['shards'].pop()
            elif mutation in ('receipt_evidence', 'receipt_main'):
                item = changed['receipts'][0]
                receipt = json.loads(original_receipts[item['receipt']])
                receipt['qualification']['evidence_sha256' if mutation == 'receipt_evidence' else 'main_uri'] = (
                    '0' * 64 if mutation == 'receipt_evidence' else header.as_uri())
                raw = encoded(receipt).encode(); pathlib.Path(item['receipt']).write_bytes(raw)
                item['receipt_sha256'] = sha(raw)
            elif mutation in ('disconnected_sources', 'invalid_source_uri', 'missing_dependency'):
                for item in proof['shards']:
                    if item['flags'] & 1:
                        item['sources'] = [item['own_uri']]
                if mutation != 'disconnected_sources':
                    proof['shards'][0]['sources'].append('https://invalid.test/X.h' if mutation == 'invalid_source_uri'
                        else (source / 'Missing.h').as_uri())
            proof_raw = encoded(proof).encode(); evidence_path.write_bytes(proof_raw)
            changed['evidence']['sha256'] = '0' * 64 if mutation == 'evidence_hash' else sha(proof_raw)
            manifest_path.write_text(encoded(changed), encoding='utf-8')
            def forged_reader():
                with module.tier1_cohort_reader_scope(generation, sys.executable, server_profile=profile):
                    raise AssertionError('forged reader evidence yielded: ' + mutation)
            with patch.object(module, 'decode_shard', side_effect=AssertionError('reader decoded full graph')):
                rejected(forged_reader)
            (generation / 'compile_commands.json').write_bytes(original_cdb)
            evidence_path.write_bytes(original_evidence); manifest_path.write_bytes(original_manifest)
            for path, raw in original_receipts.items(): pathlib.Path(path).write_bytes(raw)
        print('reader independently rejects thirteen schema, topology, root, inventory and receipt mutations')
    before = snapshot(generation)
    def second_reader():
        with module.tier1_cohort_reader_scope(generation, sys.executable, server_profile=profile, position_encoding='utf-8'):
            raise AssertionError('concurrent cache writer admitted')
    shard_reads.clear()
    with patch.object(pathlib.Path, 'read_bytes', read_bytes), \
            patch.object(module, 'decode_shard', side_effect=AssertionError('reader decoded full graph')), \
            module.tier1_cohort_reader_scope(generation, sys.executable, server_profile=profile, position_encoding='utf-8') as handle:
        assert pathlib.Path(handle['cdb_dir']).resolve() == pathlib.Path(calls[0]['cdb_dir'])
        assert pathlib.Path(handle['trigger']).resolve() == pathlib.Path(calls[0]['trigger'])
        assert pathlib.Path(handle['cache_environment']).resolve() == pathlib.Path(calls[0]['cache_environment'])
        assert handle['position_encoding'] == 'utf-8'
        if operation == 'ownership':
            rejected(second_reader)
            rejected(qualify)
    assert len(shard_reads) == len(manifest['shards']) and all(count == 1 for count in shard_reads.values()), 'reader repeated shard reads'
    # Ownership metadata may truthfully change; immutable CDB/candidate/receipt
    # bytes must not be rewritten by the ownership transition.
    after = snapshot(generation)
    for path, value in before.items():
        if path.endswith('.cpp') or 'receipts' in pathlib.Path(path).parts or path.endswith('compile_commands.json'):
            assert after[path] == value
    print('one shared producer supplies two real-format receipts and a same-path exclusive reader handoff')
]=]

local function run_fixture(operation)
  local python = vim.fn.exepath("python")
  if python == "" then python = vim.fn.exepath("python3") end
  if python == "" then
    t.skip("Tier 1 cohort contract fixture", "Python unavailable", { native = true })
    return
  end
  local script = vim.fn.tempname() .. "_tier1_cohort_contract.py"
  local stream = assert(io.open(script, "wb"))
  stream:write(fixture)
  stream:close()
  local result = vim.system({ python, "-B", "-I", script,
    vim.fn.stdpath("config") .. "/tools/cdb_verified_batch.py", operation }, { text = true }):wait()
  pcall(vim.fn.delete, script)
  t.assert_eq(result.code, 0, (result.stderr or "") .. (result.stdout or ""))
end

t.describe("Tier 1 cohort protocol and receipt contracts", function()
  for _, operation in ipairs({ "legacy_receipt", "success", "scope", "shared_failure", "timeout",
    "included_only", "wrong_main_path", "wrong_loaded_path", "changed_command", "observer_eof", "wrong_progress",
    "encoding", "seal_missing", "partial_commit", "ownership", "external_store", "runner_init_cleanup",
    "path_changed", "driver_changed", "header_changed", "sources_only", "cycle", "unreachable",
    "orphan_refs", "orphan_relations", "missing_dependency", "invalid_uri", "reader_tampering" }) do
    t.it(operation, function()
      run_fixture(operation)
    end)
  end
end)
