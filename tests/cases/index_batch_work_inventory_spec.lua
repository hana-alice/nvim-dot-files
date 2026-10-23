local t = require("tests.harness")
t.bootstrap()

local fixture = [=[
import importlib.util, json, os, pathlib, subprocess, sys, tempfile
sys.dont_write_bytecode = True
sys.path.insert(0, str(pathlib.Path(sys.argv[1]).parent))
from cdb_verified_batch import _proof_work_root
spec = importlib.util.spec_from_file_location('inventory', sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
case = sys.argv[2]
root = pathlib.Path(tempfile.mkdtemp(prefix='batch_work_inventory_'))
work = root/'work'; work.mkdir()
refs = root/'metadata'; refs.mkdir()
store = refs/'store'; store.mkdir()
bucket = _proof_work_root(store).name
unit = work/bucket/'proof-one'; unit.mkdir(parents=True)
payload = unit/'graph-0.json'; payload.write_text('opaque graph bytes must not be parsed as metadata')
plan = refs/'plan.json'; plan.write_text(json.dumps({'store': str(store)}))
def write(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value))
def observe(): return {'ok': True, 'records': []}
def row(result): return next(item for item in result['units'] if item['path'] == str(unit))
def checked_inventory(*args, **kwargs):
    original = {path:path.read_bytes() for path in (plan,payload)}
    result = m.inventory(*args, **kwargs)
    for path,content in original.items(): assert path.read_bytes()==content, path
    return result
before = {str(p): p.read_bytes() for p in root.rglob('*') if p.is_file()}
if case == 'reference':
    write(refs/'batches.json', {'receipts': [str(store/'assets/receipt.json')]})
    write(store/'assets/receipt.json', {'assets': [{'path':str(store/'assets/migration-certificate.abc.json')}]})
    write(store/'assets/migration-certificate.abc.json', {'graphs': [{'path':str(payload)}]})
    result=m.inventory(work, [refs], observe=observe)
    assert row(result)['category']=='referenced', result
    assert row(result)['logical_bytes']==payload.stat().st_size
    assert row(result)['references'][0]['kind']=='graphs'
elif case == 'historical':
    write(refs/'worker-result.json', {'metrics': {'proof_directory':str(unit)}})
    result=m.inventory(work, [refs], observe=observe)
    assert row(result)['category']=='unreferenced_reclaimable', result
    assert len(row(result)['historical_sources'])==1
    unknown=work/'unmapped'/'proof-one'; unknown.mkdir(parents=True); (unknown/'keep').write_bytes(b'keep')
    result=m.inventory(work, [refs], observe=observe)
    assert next(r for r in result['units'] if r['path']==str(unknown))['category']=='unknown'
elif case == 'active':
    result=m.inventory(work, [refs], [unit], observe=observe)
    assert row(result)['category']=='active'
    lease=refs/'store.background.lock'; lease.mkdir()
    write(lease/'owner.token.json', {'pid':os.getpid(), 'token':'present'})
    result=m.inventory(work, [refs], observe=observe)
    assert row(result)['category']=='active', result
elif case == 'unknown':
    def unavailable(): return {'ok':False, 'reason':'unavailable', 'records':[]}
    assert row(m.inventory(work, [refs], observe=unavailable))['category']=='unknown'
    def running(): return {'ok':True, 'records':[{'pid':123, 'command':'python cdb_background_batch.py --work'}]}
    assert row(m.inventory(work, [refs], observe=running))['category']=='unknown'
    (refs/'broken.json').write_text('{')
    result=m.inventory(work, [refs], observe=observe)
    assert row(result)['category']=='unknown' and result['errors']
elif case == 'lock_unknown':
    lease=refs/'store.background.lock'; lease.mkdir()
    write(lease/'owner.token.json', {'pid':os.getpid()})
    result=m.inventory(work, [refs], observe=observe)
    assert row(result)['category']=='unknown', result
    assert result['activity']['owners_after'][0]['alive'] is None
elif case == 'links':
    outside=root/'outside'; outside.mkdir(); (outside/'secret').write_bytes(b'not part of inventory')
    if os.name=='nt':
        import _winapi
        _winapi.CreateJunction(str(outside), str(unit/'linked'))
    else: (unit/'linked').symlink_to(outside, target_is_directory=True)
    result=m.inventory(work, [refs], observe=observe)
    assert result['skipped_links'] and result['files']==1 and row(result)['category']=='unknown', result
elif case == 'short_aliases':
    if os.name != 'nt': raise SystemExit(77)
    import ctypes
    long = root.resolve()
    buffer = ctypes.create_unicode_buffer(32768)
    length = ctypes.windll.kernel32.GetShortPathNameW(str(long), buffer, len(buffer))
    assert 0 < length < len(buffer), ctypes.get_last_error()
    short = pathlib.Path(buffer.value)
    if short == long: raise SystemExit(77)
    assert str(short) != str(long)
    long_work, short_work = long/'work', short/'work'
    long_refs, short_refs = long/'metadata', short/'metadata'
    long_unit, short_unit = long_work/bucket/'proof-one', short_work/bucket/'proof-one'
    def category(work_path, refs_path, active=()):
        result = checked_inventory(work_path, [refs_path], active, observe=observe)
        assert not result['errors'] and not result['skipped_links'], result
        assert result['work_root'] == str(m.absolute(work_path)), result
        return result['units'][0]['category']
    for work_path, refs_path in ((long_work,long_refs),(short_work,short_refs),
                                (long_work,short_refs),(short_work,long_refs)):
        for store_path in (long_refs/'store', short_refs/'store'):
            write(plan, {'store':str(store_path)})
            assert m.hashlib.sha256(str(m.path_identity(store_path)).encode()).hexdigest()[:24] == _proof_work_root(store_path).name == bucket
            assert category(work_path,refs_path)=='unreferenced_reclaimable'
            write(plan, {'store':str(store_path), 'metrics':{'proof_directory':str(long_unit)}})
            result = checked_inventory(work_path,[refs_path],observe=observe)
            assert result['units'][0]['category']=='unreferenced_reclaimable' and len(result['units'][0]['historical_sources'])==1, result
            for referenced in (long_unit/'graph-0.json', short_unit/'graph-0.json'):
                write(plan, {'store':str(store_path), 'graphs':[{'path':str(referenced)}]})
                assert category(work_path,refs_path)=='referenced'
            write(plan, {'store':str(store_path)})
            assert category(work_path,refs_path,[short_unit])=='active'
            assert category(work_path,refs_path,[long_unit])=='active'
    for store_path in (long_refs/'missing/child', short_refs/'missing/child'):
        assert m.hashlib.sha256(str(m.path_identity(store_path)).encode()).hexdigest()[:24] == _proof_work_root(store_path).name
    command=[sys.executable,'-B',sys.argv[1],'--work-root',str(short_work),'--reference-root',str(short_refs)]
    for output in (long_work/'alias-out.json',long_refs/'alias-out.json'):
        result=subprocess.run(command+['--out',str(output)],capture_output=True,text=True)
        assert result.returncode!=0 and not output.exists(), result
    plan.write_bytes(before[str(plan)])
elif case == 'missing_store':
    missing = store/'missing/child'
    assert not missing.exists()
    assert m.hashlib.sha256(str(m.path_identity(missing)).encode()).hexdigest()[:24] == _proof_work_root(missing).name
elif case == 'identity_links':
    outside=root/'outside'; outside.mkdir(); (outside/'secret').write_bytes(b'not part of inventory')
    link=refs/'linked-store'
    if os.name=='nt':
        import _winapi
        _winapi.CreateJunction(str(outside),str(link))
    else: link.symlink_to(outside,target_is_directory=True)
    original_resolve = pathlib.Path.resolve
    def checked_resolve(path,*args,**kwargs):
        assert not m.absolute(path).is_relative_to(m.absolute(link)), 'attempted to resolve a reparse target'
        return original_resolve(path,*args,**kwargs)
    pathlib.Path.resolve = checked_resolve
    try:
        write(plan, {'store':str(link/'missing')})
        result=checked_inventory(work,[refs],observe=observe)
        assert result['errors'] and row(result)['category']=='unknown', result
        assert result['files']==1 and result['skipped_links'], result
        assert any('reparse-or-symbolic-link' in e['reason'] for e in result['errors']), result
        write(plan, {'store':str(store), 'graphs':[{'path':str(link/'secret')}]})
        result=checked_inventory(work,[refs],observe=observe)
        assert result['errors'] and row(result)['category']=='unknown', result
        assert result['files']==1, result
        outside.rename(root/'moved-outside')
        try: m.path_identity(link/'missing')
        except ValueError as error: assert 'reparse-or-symbolic-link' in str(error)
        else: raise AssertionError('broken reparse ancestor was accepted')
    finally: pathlib.Path.resolve = original_resolve
    plan.write_bytes(before[str(plan)])
elif case == 'cli':
    command=[sys.executable,'-B',sys.argv[1],'--work-root',str(work),'--reference-root',str(refs)]
    result=subprocess.run(command+['--out',str(work/'out.json')],capture_output=True,text=True)
    assert result.returncode!=0 and not (work/'out.json').exists()
    result=subprocess.run(command+['--out',str(root/'report.json'),'--delete'],capture_output=True,text=True)
    assert result.returncode!=0 and not (root/'report.json').exists()
    result=subprocess.run(command+['--out',str(root/'report.json')],capture_output=True,text=True)
    assert result.returncode==0, result.stderr
    report=json.loads((root/'report.json').read_text())
    assert report['dry_run'] is True and report['deletion_supported'] is False
    assert report['files']==1 and report['logical_bytes']==payload.stat().st_size
else: raise AssertionError(case)
for name,content in before.items(): assert pathlib.Path(name).read_bytes()==content
assert payload.exists(), 'dry run deleted evidence'
print('ok')
]=]

t.describe("batch proof TEMP dry-run inventory", function()
  for _, case in ipairs({ "reference", "historical", "active", "unknown", "lock_unknown", "links", "cli",
    "short_aliases", "missing_store", "identity_links" }) do
    local python = vim.fn.exepath("python")
    if python == "" then python = vim.fn.exepath("python3") end
    if python == "" then t.skip(case, "Python unavailable", { native = true }); return end
    local script = vim.fn.tempname() .. "_batch_work_inventory.py"
    local file = assert(io.open(script, "wb"))
    file:write(fixture)
    file:close()
    local result = vim.system({ python, "-B", "-I", script,
      vim.fn.stdpath("config") .. "/tools/cdb_batch_work_inventory.py", case }, { text = true }):wait()
    if case == "short_aliases" and result.code == 77 then
      t.skip(case, "native 8.3 temporary paths unavailable", { native = false })
    else t.it(case, function()
      t.assert_eq(result.code, 0, result.stderr or result.stdout)
      t.assert_eq(vim.trim(result.stdout), "ok")
    end) end
  end
end)
