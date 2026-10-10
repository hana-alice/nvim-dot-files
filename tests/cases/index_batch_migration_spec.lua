local t = require("tests.harness")
t.bootstrap()

local fixture = [=[
import contextlib, hashlib, io, json, os, pathlib, shutil, subprocess, sys, tempfile, time
sys.dont_write_bytecode = True
config, clangd, mode = sys.argv[1:4]
if mode == 'import_changed':
    sys.path.insert(0, str(pathlib.Path(config) / 'tools'))
    import cdb_verified_batch as proof
    import clangd_receipt_migration as migration
    target = pathlib.Path(config) / 'tools' / sys.argv[4]
    target.write_bytes(target.read_bytes() + b'\n# owned import mutation\n')
    result = migration.migrate_cache('', [], '', pathlib.Path(clangd), None)
    assert not result['ok'] and result['reason'] == 'migration-imported-code-changed', result
    raise SystemExit()
if mode == 'old':
    archive = pathlib.Path(sys.argv[5])
    sys.path.insert(0, str(archive / 'tools'))
    import cdb_verified_batch as proof
    root = pathlib.Path(sys.argv[4])
    entries = json.loads((root / 'entries.json').read_text())
    server = json.loads((root / 'server.json').read_text())
    result, metrics = proof.accelerate(entries, root / 'proof', clangd, max_group=2, timeout=30,
        server_profile=server)
    assert metrics['batch_count'] == 1, metrics
    (root / 'proof/old-result.json').write_text(json.dumps(result))
    raise SystemExit()
sys.path.insert(0, str(pathlib.Path(config) / 'tools'))
import cdb_verified_batch as proof
import clangd_receipt_migration as migration
class OwnedDirectory(tempfile.TemporaryDirectory):
    def cleanup(self):
        deadline = time.monotonic() + 2
        while True:
            try: return super().cleanup()
            except PermissionError:
                if time.monotonic() >= deadline: raise
                time.sleep(0.05)
with OwnedDirectory(prefix='receipt_migration_') as temporary:
    root = pathlib.Path(temporary).resolve()
    # Build an actual legacy-format native producer in an owned archive. Its
    # source bytes are independently hashed; clean checkouts need no .tmp data.
    archive = root / 'archive'
    (archive / 'tools').mkdir(parents=True)
    for original in (pathlib.Path(config) / 'tools').glob('*.py'):
        shutil.copyfile(original, archive / 'tools' / original.name)
    for name in proof._POLICY_FILES:
        original = (pathlib.Path(config) / 'tools' / name).resolve()
        target = (archive / 'tools' / name).resolve()
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(original, target)
    helper = archive / 'tools/clangd_query_profile.py'
    helper.write_text(helper.read_text().replace('query-driver-v5', 'query-driver-v4').replace(
        "'COMPILER_PATH', 'WindowsSdkDir'", "'COMPILER_PATH', 'PATH', 'PATHEXT', 'WindowsSdkDir'"))
    collector = archive / 'tools/cdb_verified_batch.py'
    collector.write_text(collector.read_text().replace(
        "if server_profile is None or name not in ('PATH', 'PATHEXT')", '').replace(
        'group, originals, assets, tool_hash, server_profile, timings=timings)',
        'list(reversed(group)), originals, assets, tool_hash, server_profile, timings=timings)').replace(
        'evidence.update(dependencies=files, identity=identity, replay_candidate=candidate)',
        'evidence.update(dependencies=files, identity=identity, replay_candidate=candidate, candidate_order=list(reversed(range(len(group)))))'))
    (root / 'bin').mkdir()
    (root / 'lib/clang/22/include').mkdir(parents=True)
    (root / 'usr/include').mkdir(parents=True)
    driver = root / 'bin/clang++.exe'
    shutil.copyfile(pathlib.Path(clangd).with_name('clang++.exe'), driver)
    entries = []
    for index in range(2):
        member = root / ('member%d.cpp' % index)
        member.write_text('int value%d() { return %d; }\n' % (index, index))
        wrapper = root / ('SuperUnity.UBT.%d.cpp' % index)
        wrapper.write_text('// Compiler-authored UBT unity membership; copied into nvim cache.\n'
            + '#include "' + member.as_posix() + '"\n')
        entries.append({'file': str(wrapper), 'directory': str(root),
            'arguments': [str(driver), '--target=aarch64-none-linux-android23', '--sysroot=' + root.as_posix(), '-std=c++17', '-c', str(wrapper)],
            'nvim_ue_members': [proof.portable_member_path(str(member))],
            'nvim_ue_module_root': 'Source/Runtime/MigrationFixture'})
    server = {'enable_config': False, 'query_driver': '**/clang*.exe', 'launch_cwd': root.as_posix()}
    (root / 'entries.json').write_text(json.dumps(entries))
    (root / 'server.json').write_text(json.dumps(server))
    child = subprocess.run([sys.executable, '-B', '-I', __file__, config, clangd, 'old', str(root), str(archive)],
        capture_output=True, text=True, timeout=100)
    assert child.returncode == 0, child.stdout + child.stderr
    output = root / 'proof'
    paths = list((output / 'receipts').glob('*.json'))
    assert len(paths) == 1, paths
    old_path = paths[0]
    old_bytes = old_path.read_bytes()
    record = json.loads(old_bytes)
    assert record['candidate_order'] == [1, 0], record
    # The legacy producer actually indexed the reversed include wrapper; this
    # is native order evidence, rather than edited acceptance metadata.
    candidate_body = pathlib.Path(record['replay_candidate']['file']).read_text()
    assert candidate_body.index(entries[1]['file'].replace('\\', '/')) < candidate_body.index(entries[0]['file'].replace('\\', '/'))
    assert record['query_profiles'][0]['parser_id'].endswith('-v4'), record['query_profiles']
    run = lambda: migration.migrate_cache(old_path, entries, output, pathlib.Path(clangd), server, archive)
    # Modifications are confined to this fixture's owned native driver copy.
    driver_bytes = driver.read_bytes()
    driver.write_bytes(driver_bytes + b'\0')
    changed = run()
    assert not changed['ok'], changed
    assert 'driver' in changed['reason'] or 'sha' in changed['reason'], changed
    driver.write_bytes(driver_bytes)
    dependency = pathlib.Path(record['dependencies'][0]['path'])
    dependency_bytes = dependency.read_bytes()
    dependency.write_bytes(dependency_bytes + b'\n')
    changed = run()
    assert not changed['ok'] and 'dependencies-sha-changed' in changed['reason'], changed
    dependency.write_bytes(dependency_bytes)
    graph = pathlib.Path(record['graph_files'][0]['path'])
    graph_bytes = graph.read_bytes()
    graph.unlink()
    missing = run()
    assert not missing['ok'] and 'graph_files-file-missing' in missing['reason'], missing
    graph.write_bytes(graph_bytes)
    # Removed native shard is independently rejected although the old graph
    # and its SHA remain intact.
    report = json.loads((graph.parent / 'original-0/run/run.json').read_text())
    shard = pathlib.Path(report['shards'][0])
    shard_bytes = shard.read_bytes()
    shard.unlink()
    missing = run()
    assert not missing['ok'] and ('riff-shard-missing' in missing['reason'] or 'input-or-asset-changed' in missing['reason']), missing
    shard.write_bytes(shard_bytes)
    migrated = run()
    assert migrated['ok'], migrated
    assert old_path.read_bytes() == old_bytes, 'legacy record was overwritten'
    current = json.loads(pathlib.Path(migrated['cache_path']).read_bytes())
    assert current['candidate_order'] == [1, 0], current
    assert current['identities'] == proof._identities(pathlib.Path(clangd), server_profile=server)
    assert all(q['parser_id'].endswith('-v5') for q in current['query_profiles'])
    assert proof._cached_group_matches(current, entries, output), current
    assert proof.validate_receipts([migrated['candidate']['nvim_ue_batch_receipt']], clangd, server)['ok']
    with contextlib.redirect_stdout(io.StringIO()):
        cached, metrics = proof.accelerate(entries, output, clangd, max_group=2, verify_missing=False, server_profile=server)
    assert metrics['cache_hits'] == 1 and metrics['batch_count'] == 1, metrics
    def snapshot():
        return {str(p.relative_to(output)): (hashlib.sha256(p.read_bytes()).hexdigest(), p.stat().st_mtime_ns)
                for p in output.rglob('*') if p.is_file()}
    before = snapshot()
    repeated = run()
    assert repeated['ok'] and repeated['no_op'], repeated
    assert snapshot() == before, 'repeated migration rewrote or created artifacts'
    graph.write_bytes(graph_bytes + b' ')
    assert not proof._cache_valid(current, output, {}, validate_resolution=False)
    assert not proof.validate_receipts([migrated['candidate']['nvim_ue_batch_receipt']], clangd, server)['ok']
    graph.unlink()
    assert not proof._cache_valid(current, output, {}, validate_resolution=False)
    assert not proof.validate_receipts([migrated['candidate']['nvim_ue_batch_receipt']], clangd, server)['ok']
    graph.write_bytes(graph_bytes)
    for filename in ('cdb_verified_batch.py', 'clangd_receipt_migration.py'):
        with tempfile.TemporaryDirectory(prefix='owned_import_change_') as changed_dir:
            changed_root = pathlib.Path(changed_dir)
            shutil.copytree(archive, changed_root / 'copy')
            # Use current unmodified producer modules before the import-only
            # mutation; both cdb and migration module identity are exercised.
            for original in (pathlib.Path(config) / 'tools').glob('*.py'):
                shutil.copyfile(original, changed_root / 'copy/tools' / original.name)
            child = subprocess.run([sys.executable, '-B', '-I', __file__, str(changed_root / 'copy'),
                clangd, 'import_changed', filename], capture_output=True, text=True, timeout=20)
            assert child.returncode == 0, child.stdout + child.stderr
    print(json.dumps({'migrated': True, 'compiler_changed_rejected': True,
        'dependency_changed_rejected': True, 'graph_missing_rejected': True,
        'riff_missing_rejected': True, 'legacy_preserved': True}))
]=]

t.describe("archived verified batch migration", function()
  local found = require("utils.ue_goto.semantic_sidecar_libclang").discover_toolchain()
  local clangd = vim.env.UE_CLANGD or (found.ok and found.clangd_path) or vim.fn.exepath("clangd")
  local python = vim.fn.exepath("python")
  if python == "" then python = vim.fn.exepath("python3") end
  if not require("utils.platform").is_windows or clangd == "" or python == "" then
    t.skip("archived native proof migration", "real Windows native compiler required", { native = true })
    return
  end
  t.it("re-proves v4 RIFF and rejects changed compiler, dependency and missing graphs", function()
    local script = vim.fn.tempname() .. "_receipt_migration.py"
    local file = assert(io.open(script, "wb")); file:write(fixture); file:close()
    local result = vim.system({ python, "-B", "-I", script,
      vim.fn.stdpath("config"), clangd, "test" }, { text = true }):wait(180000)
    vim.fn.delete(script)
    t.assert_eq(result.code, 0, (result.stderr or "") .. (result.stdout or ""))
    local evidence = vim.json.decode(result.stdout)
    t.assert_eq(evidence.migrated, true)
    t.assert_eq(evidence.legacy_preserved, true)
  end)
end)
