local t = require("tests.harness")
t.bootstrap()

local fixture = [=[
import importlib.util, json, os, pathlib, subprocess, sys, tempfile
spec = importlib.util.spec_from_file_location('inventory', sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
case = sys.argv[2]
root = pathlib.Path(tempfile.mkdtemp(prefix='batch_work_inventory_'))
work = root/'work'; work.mkdir()
refs = root/'metadata'; refs.mkdir()
store = refs/'store'; store.mkdir()
bucket = m.hashlib.sha256(str(store.resolve()).encode()).hexdigest()[:24]
unit = work/bucket/'proof-one'; unit.mkdir(parents=True)
payload = unit/'graph-0.json'; payload.write_text('opaque graph bytes must not be parsed as metadata')
plan = refs/'plan.json'; plan.write_text(json.dumps({'store': str(store)}))
def write(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value))
def observe(): return {'ok': True, 'records': []}
def row(result): return next(item for item in result['units'] if item['path'] == str(unit))
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
  for _, case in ipairs({ "reference", "historical", "active", "unknown", "lock_unknown", "links", "cli" }) do
    t.it(case, function()
      local python = vim.fn.exepath("python")
      if python == "" then python = vim.fn.exepath("python3") end
      if python == "" then t.skip(case, "Python unavailable", { native = true }); return end
      local script = vim.fn.tempname() .. "_batch_work_inventory.py"
      local file = assert(io.open(script, "wb"))
      file:write(fixture)
      file:close()
      local result = vim.system({ python, "-B", "-I", script,
        vim.fn.stdpath("config") .. "/tools/cdb_batch_work_inventory.py", case }, { text = true }):wait()
      t.assert_eq(result.code, 0, result.stderr or result.stdout)
      t.assert_eq(vim.trim(result.stdout), "ok")
    end)
  end
end)
