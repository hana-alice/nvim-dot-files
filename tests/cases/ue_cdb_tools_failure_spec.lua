local t = require("tests.harness")
t.bootstrap()

local function python_case(body)
  local python = require("utils.platform").resolve_tool({
    name = "python",
    driver_candidates = function(driver) return driver.python_candidates() end,
  })
  t.assert_true(python.ok, python.reason)
  local root = vim.fs.normalize(vim.fn.tempname() .. "-cdb-tools")
  vim.fn.mkdir(root, "p")
  local script = root .. "/fixture.py"
  local file = assert(io.open(script, "wb"))
  file:write([=[
import json, pathlib, subprocess, sys
repo, root = map(pathlib.Path, sys.argv[1:3])

def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value), encoding='utf-8')

def snapshot(path):
    return path.read_bytes(), path.stat().st_mtime_ns

def tree_snapshot(path):
    return {str(item.relative_to(path)): snapshot(item) for item in path.rglob('*') if item.is_file()}

def run_tool(script, *args):
    result = subprocess.run([sys.executable, '-B', '-I', str(repo/'tools'/script), *map(str, args)],
                            cwd=root, capture_output=True, text=True, timeout=20)
    number = len(list(root.glob('cli-*.stdout.log')))
    (root/f'cli-{number}.stdout.log').write_text(result.stdout, encoding='utf-8')
    (root/f'cli-{number}.stderr.log').write_text(result.stderr, encoding='utf-8')
    return result

def make_rsp_case(name, command, files):
    folder = root/name
    folder.mkdir()
    for path, text in files.items():
        (folder/path).write_text(text, encoding='utf-8')
    cdb = folder/'compile_commands.json'
    entry = {'directory':str(folder), 'file':str(folder/'A.cpp')}
    entry['arguments' if isinstance(command, list) else 'command'] = command
    write_json(cdb, [entry])
    return folder, cdb

def assert_rsp_failure(cdb, missing=0, read_error=0, cycle=0):
    before = snapshot(cdb)
    result = run_tool('expand_response_cdb.py', cdb)
    assert result.returncode != 0, result.stdout + result.stderr
    assert snapshot(cdb) == before, 'failed expansion changed CDB bytes or mtime'
    for name, count in [('missing_rsp', missing), ('read_error_rsp', read_error), ('cycle_rsp', cycle)]:
        assert f' {name}={count} ' in result.stdout, result.stdout
    return result

def row(folder, name, flag='OLD'):
    return {'directory':str(folder), 'file':str(folder/name),
            'arguments':['clang++', '-D'+flag+'=1', str(folder/name)]}

def make_commit_case(name, changed=False):
    folder = root/name
    live, work = folder/'live', folder/'owned-ue-cdb-prepare'
    key = 'Win64-Fixture-Development'
    old_rows = [row(folder, 'A.cpp')]
    stage, active = work/'compile_commands.json', live/'compile_commands.json'
    write_json(active, old_rows)
    write_json(stage, [row(folder, 'A.cpp', 'NEW')] if changed else old_rows)
    manifest = {'active':key, 'shards':{key:{'entry_count':1, 'source_roots':[], 'mtime':1}}}
    write_json(live/'shards'/(key+'.json'), old_rows)
    write_json(live/'shards/manifest.json', manifest)
    write_json(work/'shards'/(key+'.json'), old_rows)
    write_json(work/'shards/manifest.json', manifest)
    config = {'stage':str(stage), 'active':str(active), 'targets':[str(active)],
              'stage_shards':str(work/'shards'), 'shards':str(live/'shards'),
              'stage_manifest':str(work/'partition.json'), 'manifest':str(live/'partition.json'),
              'partition_dir':str(live/'partition')}
    config_path = work/'transaction.json'
    write_json(config_path, config)
    return folder, live, work, key, config_path

def assert_commit_failure(live, config_path, reason):
    before = tree_snapshot(live)
    result = run_tool('cdb_transaction.py', 'commit', config_path)
    assert result.returncode != 0, result.stdout + result.stderr
    outcome = json.loads(result.stdout)
    assert outcome['ok'] is False, outcome
    assert reason in outcome['reason'], outcome
    assert tree_snapshot(live) == before, 'rejected commit changed published bytes, mtimes or files'
    return outcome
]=], body)
  file:close()
  local result = vim.system({ python.path, "-B", "-I", script, vim.fn.stdpath("config"), root }, { text = true }):wait(30000)
  t.assert_eq(result.code, 0, (result.stderr or "") .. (result.stdout or ""))
end

t.describe("ue.cdb Python failure publication", function()
  t.it("rejects nested and second top-level missing response paths without rewriting", function()
    python_case([=[
for name, command, outer in [
    ('nested', 'clang-cl @outer.rsp', '/DOUTER=1 @missing.rsp'),
    ('second-top', 'clang-cl @outer.rsp @missing.rsp', '/DOUTER=1'),
]:
    folder, cdb = make_rsp_case(name, command, {'outer.rsp':outer})
    result = assert_rsp_failure(cdb, missing=1)
    assert (folder/'missing.rsp').as_posix().lower() in result.stderr.replace('\\', '/').lower(), result.stderr
]=])
  end)

  t.it("counts distinct missing paths even when several are in one response", function()
    python_case([=[
folder, cdb = make_rsp_case('missing-paths', 'clang-cl @outer.rsp @missing-b.rsp', {
    'outer.rsp':'@missing-a.rsp @missing-b.rsp @missing-a.rsp'})
result = assert_rsp_failure(cdb, missing=2)
for name in ('missing-a.rsp', 'missing-b.rsp'):
    assert name in result.stderr, result.stderr
]=])
  end)

  t.it("reports a nested read error separately from missing paths", function()
    python_case([=[
folder, cdb = make_rsp_case('read-error', 'clang-cl @outer.rsp', {'outer.rsp':'@unreadable.rsp'})
(folder/'unreadable.rsp').mkdir()
result = assert_rsp_failure(cdb, read_error=1)
assert 'unreadable.rsp' in result.stderr, result.stderr
]=])
  end)

  t.it("rejects response cycles and preserves valid entries in the same CDB", function()
    python_case([=[
folder, cdb = make_rsp_case('cycle', 'clang-cl @a.rsp', {
    'a.rsp':'/DA=1 @b.rsp', 'b.rsp':'/DB=1 @a.rsp', 'valid.rsp':'/DVALID=1'})
entries = json.loads(cdb.read_text())
entries.append({'directory':str(folder), 'file':str(folder/'B.cpp'), 'command':'clang-cl @valid.rsp'})
write_json(cdb, entries)
result = assert_rsp_failure(cdb, cycle=1)
assert 'response-file cycle' in result.stderr, result.stderr
]=])
  end)

  t.it("expands complete repeated branches and leaves a repeat run untouched", function()
    python_case([=[
folder, cdb = make_rsp_case('complete', 'clang-cl /DEXTRA=1 @outer.rsp @second.rsp', {
    'outer.rsp':'/DOUTER=1 @shared.rsp @shared.rsp @empty.rsp',
    'shared.rsp':'/DSHARED=1 /I"some dir" /Fo "a.obj"', 'empty.rsp':'', 'second.rsp':'/DSECOND=1'})
result = run_tool('expand_response_cdb.py', cdb)
assert result.returncode == 0, result.stderr
entry, = json.loads(cdb.read_text())
assert entry['arguments'] == ['clang-cl', '/DEXTRA=1', '/DOUTER=1', '/DSHARED=1', '-Isome dir',
                              '/DSHARED=1', '-Isome dir', '/DSECOND=1'], entry
assert 'command' not in entry, entry
before = snapshot(cdb)
result = run_tool('expand_response_cdb.py', cdb)
assert result.returncode == 0, result.stderr
assert snapshot(cdb) == before, 'already-expanded input was rewritten'
]=])
  end)

  t.it("rejects missing responses from structured arguments", function()
    python_case([=[
for name, arguments, files in [
    ('args-top-missing', ['clang-cl', '@valid.rsp', '@missing.rsp'], {'valid.rsp':'/DVALID=1'}),
    ('args-nested-missing', ['clang-cl', '@outer.rsp'], {'outer.rsp':'/DOUTER=1 @missing.rsp'}),
]:
    folder, cdb = make_rsp_case(name, arguments, files)
    result = assert_rsp_failure(cdb, missing=1)
    assert 'missing.rsp' in result.stderr, result.stderr
]=])
  end)

  t.it("rejects response cycles from structured arguments", function()
    python_case([=[
folder, cdb = make_rsp_case('args-cycle', ['clang-cl', '/DBEFORE=1', '@a.rsp', '/DAFTER=1'], {
    'a.rsp':'@b.rsp', 'b.rsp':'@a.rsp'})
result = assert_rsp_failure(cdb, cycle=1)
assert 'response-file cycle' in result.stderr, result.stderr
]=])
  end)

  t.it("expands structured arguments in order and skips arguments without response tokens", function()
    python_case([=[
folder, cdb = make_rsp_case('args-complete',
    ['clang-cl', '/DORDER=0', '@outer.rsp', '/DORDER=2', '@shared.rsp', '/DORDER=4'], {
        'outer.rsp':'/DORDER=1 @shared.rsp', 'shared.rsp':'/DSHARED=1 /I"some dir"'})
result = run_tool('expand_response_cdb.py', cdb)
assert result.returncode == 0, result.stdout + result.stderr
entry, = json.loads(cdb.read_text())
assert entry['arguments'] == ['clang-cl', '/DORDER=0', '/DORDER=1', '/DSHARED=1', '-Isome dir',
                              '/DORDER=2', '/DSHARED=1', '-Isome dir', '/DORDER=4'], entry
before = snapshot(cdb)
result = run_tool('expand_response_cdb.py', cdb)
assert result.returncode == 0, result.stdout + result.stderr
assert snapshot(cdb) == before, 'expanded structured arguments were rewritten'
folder, cdb = make_rsp_case('args-untouched', ['clang-cl', '-DMAIL=user@example.com', '/Ikeep'], {})
entries = json.loads(cdb.read_text())
entries[0].update(command='clang-cl @unselected-missing.rsp', metadata='keep')
write_json(cdb, entries)
before = snapshot(cdb)
result = run_tool('expand_response_cdb.py', cdb)
assert result.returncode == 0, result.stdout + result.stderr
assert snapshot(cdb) == before, 'pure structured arguments were modified'
]=])
  end)

  t.it("fails closed on invalid UTF-8 rather than replacing required response bytes", function()
    python_case([=[
for name, command in [('command-decode', 'clang-cl @outer.rsp'),
                       ('args-decode', ['clang-cl', '@outer.rsp'])]:
    folder, cdb = make_rsp_case(name, command, {'outer.rsp':'/DOUTER=1 @invalid.rsp'})
    (folder/'invalid.rsp').write_bytes(b'/DINVALID=\xff\n')
    result = assert_rsp_failure(cdb, read_error=1)
    assert 'invalid.rsp' in result.stderr and 'decode' in result.stderr, result.stderr
]=])
  end)

  t.it("rejects declared raw counts for both unchanged and changed final commands", function()
    python_case([=[
for changed in (False, True):
    folder, live, work, key, config = make_commit_case('count-'+str(changed), changed)
    manifest_path = work/'shards/manifest.json'
    manifest = json.loads(manifest_path.read_text())
    manifest['shards'][key]['entry_count'] = 2
    write_json(manifest_path, manifest)
    outcome = assert_commit_failure(live, config, 'shard entry_count mismatch')
    assert 'declared=2, actual=1' in outcome['reason'], outcome
    assert key+'.json' in outcome['reason'], outcome
]=])
  end)

  t.it("checks every declared shard and rejects invalid count metadata", function()
    python_case([=[
for count in (2, True, '1', None):
    folder, live, work, key, config = make_commit_case('sibling-'+repr(count))
    other = 'Android-Fixture-Development'
    write_json(work/'shards'/(other+'.json'), [row(folder, 'B.cpp')])
    manifest_path = work/'shards/manifest.json'
    manifest = json.loads(manifest_path.read_text())
    manifest['shards'][other] = {'entry_count':count, 'source_roots':[]}
    write_json(manifest_path, manifest)
    outcome = assert_commit_failure(live, config, 'shard entry_count mismatch')
    assert other+'.json' in outcome['reason'], outcome
]=])
  end)

  t.it("compares counts with raw shards while allowing postprocessing compression", function()
    python_case([=[
folder, live, work, key, config = make_commit_case('valid-raw-count', changed=True)
raw_rows = [row(folder, 'A.cpp'), row(folder, 'B.cpp')]
write_json(work/'shards'/(key+'.json'), raw_rows)
manifest_path = work/'shards/manifest.json'
manifest = json.loads(manifest_path.read_text())
manifest['shards'][key]['entry_count'] = 2
write_json(manifest_path, manifest)
result = run_tool('cdb_transaction.py', 'commit', config)
assert result.returncode == 0, result.stdout + result.stderr
assert json.loads(result.stdout)['ok'] is True, result.stdout
assert len(json.loads((live/'compile_commands.json').read_text())) == 1
assert json.loads((live/'shards'/(key+'.json')).read_text()) == raw_rows
assert json.loads((live/'shards/manifest.json').read_text())['shards'][key]['entry_count'] == 2
before = tree_snapshot(live)
result = run_tool('cdb_transaction.py', 'commit', config)
assert result.returncode == 0, result.stdout + result.stderr
assert json.loads(result.stdout)['changed'] is False, result.stdout
assert tree_snapshot(live) == before, 'identical repeat commit rewrote published artifacts'
]=])
  end)
end)
