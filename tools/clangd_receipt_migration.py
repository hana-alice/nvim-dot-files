"""Re-prove archived receipts without granting authority to a legacy hash.

The archive is explicit input. Its collector bytes must reproduce the recorded
identity; current native extraction, RIFF decoding and admission mint authority.
"""
import ast
import copy
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import time


def _hash(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


_IMPORTED_MIGRATION = _hash(__file__)


def _check_imported(proof):
    if proof._IMPORTED_CODE != proof._code_identities() or _hash(__file__) != _IMPORTED_MIGRATION:
        raise ValueError('migration-imported-code-changed')


def _archive_files(sources):
    if sources is None:
        raise ValueError('migration-collector-sources-missing')
    if isinstance(sources, dict):
        files = {name: Path(path).resolve(strict=True) for name, path in sources.items()}
    else:
        root = Path(sources).resolve(strict=True)
        directory = root / 'tools' if (root / 'tools').is_dir() else root
        files = {'cdb_verified_batch.py': directory / 'cdb_verified_batch.py'}
    source = files['cdb_verified_batch.py'].read_bytes()
    tree = ast.parse(source)
    names = None
    for node in tree.body:
        if isinstance(node, ast.Assign) and any(isinstance(t, ast.Name) and t.id == '_COLLECTOR_FILES' for t in node.targets):
            names = ast.literal_eval(node.value)
    if not isinstance(names, tuple) or not names or any(not isinstance(n, str) or Path(n).name != n for n in names):
        raise ValueError('migration-archive-collector-manifest-invalid')
    if not isinstance(sources, dict):
        files.update({name: directory / name for name in names})
    if any(name not in files or not files[name].is_file() for name in names):
        raise ValueError('migration-archive-collector-source-missing')
    return files, hashlib.sha256(b''.join(files[name].read_bytes() for name in names)).hexdigest()


def _check_files(record):
    for field in ('dependencies', 'assets', 'graph_files'):
        items = record.get(field)
        if not isinstance(items, list) or not items:
            raise ValueError('migration-' + field + '-missing')
        for item in items:
            if not isinstance(item, dict) or not item.get('path') or not item.get('sha256'):
                raise ValueError('migration-' + field + '-incomplete')
            path = Path(item['path'])
            if not path.is_file():
                raise ValueError('migration-' + field + '-file-missing')
            if _hash(path) != item['sha256']:
                raise ValueError('migration-' + field + '-sha-changed')
            if field == 'dependencies' and (not item.get('snapshot') or _hash(item['snapshot']) != item['sha256']):
                raise ValueError('migration-snapshot-sha-changed')


def _upgrade_query(old, native, archive_files, helper, clangd, profile, scratch, proof):
    if old.get('schema') != 1 or old.get('parser_id') not in (
            'windows-llvm-22.1.5-query-driver-v4', helper.PARSER_ID):
        raise ValueError('migration-query-parser-unproven')
    path = archive_files.get('clangd_query_profile.py')
    if path is None or _hash(path) != old.get('helper_sha256'):
        raise ValueError('migration-query-helper-source-unproven')
    parser = next((ast.literal_eval(node.value) for node in ast.parse(path.read_bytes()).body
        if isinstance(node, ast.Assign) and any(isinstance(t, ast.Name) and t.id == 'PARSER_ID' for t in node.targets)), None)
    if parser != old['parser_id']:
        raise ValueError('migration-query-parser-source-mismatch')
    result = helper.observe(native, str(clangd), profile['query_driver'], scratch,
        launch_cwd=profile['launch_cwd'], environment=None, timeout=10)
    if result.get('ok') is not True:
        raise ValueError('migration-query-observation-failed: ' + result.get('reason', 'unknown'))
    current = result['evidence']
    keys = tuple(helper.semantic_identity(current))
    for key in keys:
        if key in ('parser_id', 'helper_sha256', 'compiler_environment', 'environment_sha256'):
            continue
        if key not in old or old[key] != current[key]:
            raise ValueError('migration-query-semantic-changed: ' + key)
    environment = old.get('compiler_environment')
    if not isinstance(environment, dict) or old.get('environment_sha256') != proof._sha(proof._json(environment).encode()):
        raise ValueError('migration-query-environment-invalid')
    environment = {key: value for key, value in environment.items() if key not in ('PATH', 'PATHEXT')}
    if environment != current['compiler_environment']:
        raise ValueError('migration-query-environment-changed')
    return current


def _recollect(record, group, output, proof):
    graphs = record['graph_files']
    if len(graphs) != len(group) + 1:
        raise ValueError('migration-graph-count-mismatch')
    parents = {Path(item['path']).resolve().parent for item in graphs}
    if len(parents) != 1:
        raise ValueError('migration-graph-roots-disagree')
    root = next(iter(parents))
    if not root.is_relative_to(output):
        raise ValueError('migration-graph-outside-proof-store')
    pool = {}
    for index, graph_asset in enumerate(graphs):
        original = index < len(group)
        expected = proof._private_command(group[index] if original else record['replay_candidate'])
        directories = [root / ('original-' + str(index))] if original else [root / name for name in
            ('candidate', 'candidate-reordered', 'candidate-aliases', 'candidate-reordered-aliases')]
        selected = None
        for directory in directories:
            report_path = directory / 'run/run.json'
            if not report_path.is_file() or not (directory / 'compile_commands.json').is_file():
                continue
            report = json.loads(report_path.read_text(encoding='utf-8'))
            raw = (directory / 'compile_commands.json').read_bytes()
            commands = json.loads(raw)
            if (proof._sha(raw) == report.get('cdb_sha256') and len(commands) == 2 and commands[0] == expected
                    and report.get('background_compile_success') is True):
                selected = directory, report, commands
                break
        if selected is None:
            raise ValueError('migration-native-cdb-or-riff-report-missing')
        directory, report, commands = selected
        shards = report.get('shards')
        if not isinstance(shards, list) or not shards:
            raise ValueError('migration-native-riff-shards-missing')
        for shard in shards:
            path = Path(shard).resolve()
            if not path.is_relative_to(output) or not path.is_file():
                raise ValueError('migration-native-riff-shard-missing')
        effective = {}
        graph = proof._graph_result(report, Path(commands[-1]['file']), effective, pool if original else None)
        native = proof._effective_entry(group[index] if original else record['replay_candidate'], effective)
        saved_native = record['effective_entries'][index] if original else record['effective_candidate']
        if proof._native(native) != proof._native(saved_native):
            raise ValueError('migration-native-effective-command-mismatch')
        if proof._sha(proof._json(graph).encode()) != graph_asset['sha256']:
            raise ValueError('migration-current-collector-graph-mismatch')
        dependencies = {item['uri']: item for item in record['dependencies']}
        candidate_uri = Path(record['replay_candidate']['file']).resolve().as_uri()
        for uri, node in graph.items():
            if not original and uri == candidate_uri:
                continue
            if uri not in dependencies or node['source']['digest'] == '0000000000000000':
                raise ValueError('migration-graph-source-unbound')
        if not original:
            # Independent source digests were associated with SHA-bound frozen
            # candidate files by the original proof. Recheck that association.
            for asset in graphs[:-1]:
                old_graph = json.loads(Path(asset['path']).read_bytes())
                if any(uri not in graph or node['source']['digest'] != graph[uri]['source']['digest']
                       for uri, node in old_graph.items() if uri not in {Path(e['file']).resolve().as_uri() for e in group}):
                    raise ValueError('migration-original-frozen-source-digest-mismatch')
    pool.clear()


def migrate_cache(record_path, group, output, clangd, server_profile, collector_sources=None):
    """Return a new receipt only after complete live and archived re-proof.

    Legacy cache and receipt files remain untouched. This API runs in a private
    worker, never on the editor main loop; native query scratch is outside store.
    clangd must be an absolute existing executable path; PATH lookup is absent.
    """
    import cdb_verified_batch as proof
    import clangd_query_profile as helper
    started = time.monotonic()
    result = {'ok': False, 'candidate': None, 'cache_path': None}
    try:
        _check_imported(proof)
        clangd = Path(clangd)
        if not clangd.is_absolute() or not clangd.is_file():
            raise ValueError('migration-absolute-existing-clangd-required')
        output = Path(output).resolve()
        path = Path(record_path).resolve()
        if not path.is_relative_to(output / 'receipts'):
            raise ValueError('migration-cache-outside-proof-store')
        legacy_cache_hash = _hash(path)
        record = json.loads(path.read_text(encoding='utf-8'))
        if record.get('schema') != 1 or record.get('accepted') is not True:
            raise ValueError('migration-accepted-cache-required')
        identities = proof._identities(Path(clangd), server_profile=server_profile)
        cache_path = output / 'receipts' / (proof._cache_key(group, identities, identities['server_profile']) + '.json')
        if cache_path.is_file() and cache_path != path:
            current = json.loads(cache_path.read_bytes())
            if (current.get('accepted') is True and current.get('identities') == identities
                    and current.get('migration_source') == {'path': str(path), 'sha256': legacy_cache_hash}
                    and proof._cached_group_matches(current, group, output)
                    and proof._cache_valid(current, output, {}, validate_resolution=False)):
                validation = proof.validate_receipts([current['candidate']['nvim_ue_batch_receipt']], str(clangd),
                    identities['server_profile'])
                _check_imported(proof)
                if (validation.get('ok') is True and proof._identities(clangd, server_profile=server_profile) == identities
                        and _hash(path) == legacy_cache_hash
                        and proof._cache_valid(current, output, {}, validate_resolution=False)):
                    result.update(ok=True, reason='current-migration-reused', candidate=current['candidate'],
                        cache_path=str(cache_path), no_op=True)
                    result['migration_seconds'] = round(time.monotonic() - started, 6)
                    return result
        old_ids = record['identities']
        profile = identities['server_profile']
        if profile is None or old_ids.get('server_profile') != profile:
            raise ValueError('migration-native-query-profile-required')
        for key in ('tool_path', 'tool', 'binding_path', 'binding', 'policy'):
            if key not in old_ids or old_ids[key] != identities[key]:
                raise ValueError('migration-tool-or-policy-changed: ' + key)
        archive_files, collector = _archive_files(collector_sources)
        if collector != old_ids.get('collector'):
            raise ValueError('migration-collector-source-unproven')
        if not proof._cached_group_matches(record, group, output):
            raise ValueError('migration-original-group-mismatch')
        _check_files(record)
        old_environment = old_ids.get('compiler_environment')
        if not isinstance(old_environment, dict) or {k: v for k, v in old_environment.items()
                if k not in ('PATH', 'PATHEXT')} != identities['compiler_environment']:
            raise ValueError('migration-compiler-environment-changed')
        queries = record.get('query_profiles')
        if not isinstance(queries, list) or not queries:
            raise ValueError('migration-query-evidence-missing')
        upgraded = []
        with tempfile.TemporaryDirectory(prefix='nvim-ue-receipt-migration-query-') as scratch:
            for index, observation in enumerate(queries):
                upgraded.append(_upgrade_query(observation, observation['entry'], archive_files, helper,
                    clangd, profile, Path(scratch) / str(index), proof))
        reused = copy.deepcopy(record)
        reused.update(identities=identities, query_profiles=upgraded)
        if not proof._cache_valid(reused, output, {}, validate_resolution=False):
            raise ValueError('migration-input-or-asset-changed')
        _recollect(record, group, output, proof)
        reused['identity'] = proof._sha(proof._json({'legacy': record['identity'], 'identities': identities}).encode())
        invocation = Path(tempfile.mkdtemp(prefix='migration-proof-', dir=output))
        evidence = {'query_profiles': upgraded}
        candidate, detail = proof._prove(group, invocation, output / 'assets', str(clangd), identities['tool'],
            90, evidence, reused=reused, server_profile=profile, original_identities=identities)
        evidence['candidate_order'] = record.get('candidate_order', list(range(len(group))))
        inventory = proof._inventories(proof._include_roots(group, evidence['dependencies'], evidence['effective_entries'],
            extra_roots=proof._query_roots(upgraded)), output, {})
        if inventory != record['inventories'] or not proof._cache_valid(reused, output, {}, validate_resolution=False):
            raise ValueError('migration-input-changed-during-proof')
        if (proof._identities(Path(clangd), server_profile=profile) != identities
                or _archive_files(collector_sources)[1] != collector
                or _hash(path) != legacy_cache_hash):
            raise ValueError('migration-provenance-changed-during-proof')
        _check_imported(proof)
        receipt_path = Path(candidate['nvim_ue_batch_receipt'])
        evidence['assets'] = [a for a in evidence['assets'] if Path(a['path']) != receipt_path]
        for graph_asset in record['graph_files']:
            if graph_asset not in evidence['assets']:
                evidence['assets'].append(graph_asset)
        certificate = invocation / 'migration-certificate.json'
        proof._write(certificate, proof._json({'schema': 1, 'legacy_cache_sha256': _hash(path),
            'legacy_identities': old_ids, 'current_identities': identities,
            'collector_sources': {name: {'path': str(source), 'sha256': _hash(source)} for name, source in archive_files.items()},
            'graphs': record['graph_files'], 'query_profiles': upgraded, 'replayed_admission': detail}))
        evidence['assets'].append({'path': str(certificate), 'sha256': _hash(certificate)})
        receipt = json.loads(receipt_path.read_bytes())
        receipt.update(schema=2, identities=identities, inventories=inventory, assets=evidence['assets'],
            output_dir=str(output), watch_roots=list(inventory))
        proof._write(receipt_path, proof._json(receipt))
        candidate['nvim_ue_batch_receipt_sha256'] = _hash(receipt_path)
        evidence['assets'].append({'path': str(receipt_path), 'sha256': candidate['nvim_ue_batch_receipt_sha256']})
        cache_path = output / 'receipts' / (proof._cache_key(group, identities, profile) + '.json')
        evidence.update(schema=1, identities=identities, inventories=inventory, accepted=True,
            reason='verified-original-tu-union', candidate=candidate, compile_rejection=False,
            first_proof_seconds=record['first_proof_seconds'], migration_source={'path': str(path), 'sha256': _hash(path)})
        proof._write(cache_path, proof._json(evidence))
        proof._save_group_hints(output, [proof._group_hint(group, cache_path.stem)])
        result.update(ok=True, reason='legacy-receipt-reproven', candidate=candidate, cache_path=str(cache_path), detail=detail)
    except (OSError, ValueError, KeyError, TypeError, AttributeError, subprocess.SubprocessError) as error:
        result['reason'] = str(error)
    result['migration_seconds'] = round(time.monotonic() - started, 6)
    return result
