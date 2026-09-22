local t = require("tests.harness")
t.bootstrap()

local function python_test(body, clangd)
  local platform = require("utils.platform")
  if platform.driver().id ~= "windows" then t.skip("Windows header casing", "Windows filesystem required"); return end
  local python = platform.resolve_tool({ name = "python",
    driver_candidates = function(driver) return driver.python_candidates() end })
  t.assert_true(python.ok)
  local path = vim.fn.tempname() .. ".py"
  local file = assert(io.open(path, "wb"))
  file:write([=[
import copy, hashlib, importlib.util, json, os, pathlib, sys, tempfile
from unittest.mock import patch
sys.dont_write_bytecode = True
repo = pathlib.Path(sys.argv[1])
spec = importlib.util.spec_from_file_location('header_case', repo/'lua/workarounds/clangd/header_path_case.py')
c = importlib.util.module_from_spec(spec); spec.loader.exec_module(c)
VERSION = 'clangd version 22.1.5'
with tempfile.TemporaryDirectory(prefix='ue-header-case-') as folder:
    root = pathlib.Path(folder).resolve()
    source = root/'Source'; source.mkdir()
    headers = source/'Include'; headers.mkdir()
    header = headers/'RealHeader.h'; header.write_text('struct RealValue { int value; };\n')
    unit = source/'Unit.cpp'; unit.write_text('#include "realheader.h"\n')
    forced = source/'Forced.h'; forced.write_text('#define FIXTURE_VALUE 1\n')
    output = root/'cache'; output.mkdir()
    cdb = output/'compile_commands.json'
    entry = {'directory':str(source), 'file':str(unit), 'arguments':['clang++', '-I', str(headers).lower(),
        '-iquote', str(headers), '-include', str(forced), '-DKEEP=1', '-c', '--', str(unit)]}
    def save(entries): cdb.write_text(json.dumps(entries), encoding='utf-8')
    save([entry])
]=], body)
  file:close()
  local result = vim.system({ python.path, "-B", "-I", path, vim.fn.stdpath("config"), clangd or "" }, { text = true }):wait()
  os.remove(path)
  if result.code == 77 then t.skip("native header casing", result.stdout, { native = true }); return end
  t.assert_eq(result.code, 0, result.stderr or result.stdout)
end

t.describe("ue.cdb Windows header path casing", function()
  t.it("gates the selected exact version and rejects stale owned overlays", function()
    python_test([=[
    assert c.supported_version(VERSION)
    for version in ('clangd version 22.1.4', 'clangd version 22.1.6', 'clangd version 23.1.0', 'clang version 22.1.5', ''):
        assert not c.supported_version(version)
        before = cdb.read_bytes(), cdb.stat().st_mtime_ns
        assert not c.apply_policy(cdb, version)['changed']
        assert (cdb.read_bytes(), cdb.stat().st_mtime_ns) == before
    result = c.apply_policy(cdb, VERSION)
    before = cdb.read_bytes(), cdb.stat().st_mtime_ns
    try: c.apply_policy(cdb, 'clangd version 23.1.0')
    except ValueError as error: assert 'stale-owned-overlay' in str(error)
    else: raise AssertionError('unsupported version retained an owned overlay')
    assert (cdb.read_bytes(), cdb.stat().st_mtime_ns) == before
]=])
  end)

  t.it("preserves native header records and source references with the selected clangd", function()
    local platform = require("utils.platform")
    if platform.driver().id ~= "windows" then t.skip("native header casing", "Windows filesystem required"); return end
    local tool = platform.resolve_tool({ name = "clangd", env = { "UE_CLANGD" },
      config_candidates = require("utils.ue_goto.semantic_sidecar_libclang").discover_clangd_candidates() })
    if not tool.ok then t.skip("native header casing", tool.reason, { native = true }); return end
    python_test([=[
    import clangd_batch_runner as runner
    import clangd_index_graph as graph
    clangd = sys.argv[2]
    version, reason = c.probe_clangd(clangd)
    if reason or not c.supported_version(version):
        print(reason or 'requires tested clangd 22.1.5'); raise SystemExit(77)
    compiler = pathlib.Path(clangd).with_name('clang++' + pathlib.Path(clangd).suffix)
    assert compiler.is_file(), 'matching compiler unavailable'
    bad = source/'RealHeader.cpp'
    good = source/'Good.cpp'
    bad.write_text('#include "realheader.h"\nint bad_use(RealValue value) { return value.value; }\n')
    good.write_text('#include "RealHeader.h"\nint good_use(RealValue value) { return value.value; }\n')
    inputs = {p:p.read_bytes() for p in (header,bad,good)}
    rows = [{'directory':str(source), 'file':str(p), 'arguments':[str(compiler), '-std=c++17',
        '-nostdinc', '-Wno-nonportable-include-path', '-I',str(headers), '-c',str(p)]} for p in (bad,good)]
    records = {}
    for fixed in (False,True):
        folder = output/('fixed' if fixed else 'ordinary'); folder.mkdir()
        selected_cdb = folder/'compile_commands.json'; selected_cdb.write_text(json.dumps(rows))
        if fixed:
            assert c.apply_policy(selected_cdb,version)['changed']
        native = runner.run(folder,folder/'native',header,clangd,timeout=20,jobs=1)
        assert native['background_compile_success'], native
        decoded = [graph.read_shard(path) for path in native['shards']]
        own = {uri:shard for shard in decoded for uri,node in shard['sources'].items()
               if node['digest'] != '0000000000000000'}
        records[fixed] = own
        selected_header = own[header.as_uri()]
        if fixed:
            assert {s['name'] for s in selected_header['symbols']} == {'RealValue','value'}
            assert selected_header['refs']
        else:
            assert not selected_header['symbols'] and not selected_header['refs']
    for path in (bad,good):
        assert records[False][path.as_uri()]['refs'] == records[True][path.as_uri()]['refs']
    assert records[False][header.as_uri()]['sources'] == records[True][header.as_uri()]['sources']
    assert all(p.read_bytes() == data for p,data in inputs.items())
]=], tool.path)
  end)

  t.it("maps real names within bounded roots and preserves argv and repeat mtimes", function()
    python_test([=[
    ignored = source/'Content'; ignored.mkdir(); (ignored/'Unused.h').write_text('ignored')
    explicit = ignored/'Explicit'; explicit.mkdir(); named = explicit/'Selected.h'; named.write_text('selected')
    unrelated = root/'Unrelated'; unrelated.mkdir(); (unrelated/'Other.h').write_text('other')
    (headers/'binary.bin').write_bytes(b'not a header')
    entry['arguments'][1:1] = ['-I', str(source), '-I', str(explicit)]
    save([entry]); original = copy.deepcopy(entry)
    before_sources = {p:p.read_bytes() for p in (header,unit,forced,named)}
    result = c.apply_policy(cdb, VERSION)
    overlay = pathlib.Path(result['overlay'])
    mappings = c.validate_owned_overlay(overlay)
    assert mappings[header.as_posix()] == header.as_posix()
    assert named.as_posix() in mappings and unit.as_posix() not in mappings
    assert (ignored/'Unused.h').as_posix() not in mappings
    assert not any('Other.h' in path or 'binary.bin' in path for path in mappings)
    transformed = json.loads(cdb.read_text())[0]
    position = original['arguments'].index('--')
    assert transformed == dict(original, arguments=[*original['arguments'][:position], '-ivfsoverlay', str(overlay), *original['arguments'][position:]])
    assert result['scan_roots'] == 2, result
    prior = {p:(p.read_bytes(),p.stat().st_mtime_ns) for p in (cdb,overlay)}
    repeated = c.apply_policy(cdb, VERSION)
    assert not repeated['changed'] and repeated['overlay'] == str(overlay)
    for p, identity in prior.items(): assert (p.read_bytes(),p.stat().st_mtime_ns) == identity
    assert c.strip_owned(cdb, VERSION)['removed'] == 1
    assert json.loads(cdb.read_text()) == [original]
    assert c.apply_policy(cdb, VERSION)['overlay'] == str(overlay)
    extra = headers/'Added.inl'; extra.write_text('inline int Added() { return 1; }')
    refreshed = c.apply_policy(cdb, VERSION)
    assert refreshed['overlay'] != str(overlay)
    assert extra.as_posix() in c.validate_owned_overlay(refreshed['overlay'])
    for p, value in before_sources.items(): assert p.read_bytes() == value
    third = source/'ThirdParty'; third.mkdir(); third_header=third/'Other.h'; third_header.write_text('third')
    entry['arguments'][1:1]=['-I',str(third),'-I',str(unrelated)]
    save([entry]); scoped=c.apply_policy(cdb,VERSION,scope_roots=[str(source)])
    mappings=c.validate_owned_overlay(scoped['overlay'])
    assert third_header.as_posix() not in mappings and (unrelated/'Other.h').as_posix() not in mappings
    assert scoped['unmapped_thirdparty_roots'] and scoped['unmapped_foreign_roots']
    # Only an explicit basename case mismatch receives an out-of-scope mapping.
    entry['arguments'][1:1]=['-include',str(third_header.with_name('other.h'))]
    entry['file']=str(unit.with_name('unit.cpp')); entry['arguments'][-1]=entry['file']
    save([entry]); scoped=c.apply_policy(cdb,VERSION,scope_roots=[str(source)])
    mappings=c.validate_owned_overlay(scoped['overlay'])
    assert unit.as_posix() in mappings and third_header.as_posix() in mappings
    assert scoped['explicit_case_aliases']==2 and scoped['overlay_bytes']==pathlib.Path(scoped['overlay']).stat().st_size
]=])
  end)

  t.it("fails closed on collisions, foreign overlays, missing forced files and indirect inputs", function()
    python_test([=[
    result = c.apply_policy(cdb, VERSION)
    valid = pathlib.Path(result['overlay']); payload = json.loads(valid.read_text())
    def rejected_payload(value):
        raw = json.dumps(value, sort_keys=True).encode()
        bad = valid.parent/('header-path-case.'+hashlib.sha256(raw).hexdigest()+'.json')
        bad.write_bytes(raw)
        try: c.validate_owned_overlay(bad)
        except (ValueError, OSError): return
        raise AssertionError('invalid mapping accepted')
    collision = copy.deepcopy(payload); collision['roots'].append(copy.deepcopy(collision['roots'][0])); rejected_payload(collision)
    redirected = copy.deepcopy(payload); redirected['roots'][0]['external-contents'] = str(unit); rejected_payload(redirected)
    wrong_case = copy.deepcopy(payload); wrong_case['roots'][0]['name'] = wrong_case['roots'][0]['name'].lower(); wrong_case['roots'][0]['external-contents'] = wrong_case['roots'][0]['name']; rejected_payload(wrong_case)
    unknown = copy.deepcopy(payload); unknown['overlay-relative'] = True; rejected_payload(unknown)
    for options in (['-ivfsoverlay', str(root/'foreign.json')], ['-vfsoverlay',str(root/'foreign.json')],
                    ['/clang:-ivfsoverlay'], ['-Xpreprocessor','-include'], ['-Xclang','-I'], ['@file.rsp'],
                    ['-include',str(root/'missing.h')], ['-I',root.anchor]):
        bad = copy.deepcopy(entry); bad['arguments'][1:1] = options; save([bad])
        before = cdb.read_bytes(), cdb.stat().st_mtime_ns
        try: c.apply_policy(cdb, VERSION)
        except (ValueError,OSError): pass
        else: raise AssertionError(('unsupported command accepted', options))
        assert (cdb.read_bytes(),cdb.stat().st_mtime_ns) == before
    save([entry])
    with patch.object(c, 'MAX_FILES', 1):
        try: c.apply_policy(cdb, VERSION)
        except ValueError as error: assert 'limit' in str(error)
        else: raise AssertionError('mapping file cap ignored')
]=])
  end)

  t.it("preserves the original UBT and shader receipt through both prepare steps", function()
    python_test([=[
    sys.path.insert(0,str(repo/'tools'))
    import cdb_unity_receipt as receipt
    second = source/'Second.cpp'; second.write_text('int second;')
    shader = source/'Fixture.ush'; shader.write_text('// shader')
    unity = source/'Module.Sample.cpp'; unity.write_text('#include "Unit.cpp"\n#include "Second.cpp"\n')
    rsp = source/'sample.rsp'; rsp.write_text('-DKEEP=1')
    originals=[]
    for file in (unit,second,shader):
        row=copy.deepcopy(entry); row['file']=str(file); row['arguments'][-1]=str(file); originals.append(row)
    save(originals)
    origin=pathlib.Path(str(cdb)+'.unity-origin.json')
    origin.write_text(json.dumps({'schema':1,'groups':[{'module':'Sample','unity':str(unity),'members':[str(unit),str(second)],
        'dependencies':{str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in (unity,rsp)},
        'commands':{e['file']:receipt.entry_hash(e) for e in originals[:2]}}],
        'synthetic_shaders':[{'file':str(shader),'directory':str(source),'command_hash':receipt.entry_hash(originals[2])}]}))
    pending=output/'pending.json'; assert receipt.begin(str(cdb),str(pending))==1
    assert c.strip_owned(cdb,VERSION)['removed']==0
    assert c.apply_policy(cdb,VERSION)['changed']
    assert receipt.seal(str(cdb),str(pending))==1
    final=json.loads(cdb.read_text()); sealed=str(cdb)+'.unity-receipt.json'
    assert len(receipt.load_verified_groups(sealed,final))==1
    assert receipt.load_verified_synthetic_shaders(sealed,final)=={receipt.entry_hash(final[2])}
    assert [e['file'] for e in final]==[e['file'] for e in originals]
]=])
  end)

  t.it("connects stripping before friend/PCH and generation before sealing with a stable logical path", function()
    local platform = require("utils.platform")
    if platform.driver().id ~= "windows" then t.skip("Windows prepare wiring", "Windows host required"); return end
    local original = package.loaded["ue.cdb.pipeline"]
    local config = require("ue.config")
    local previous = vim.deepcopy(config.options())
    local path = vim.fn.tempname() .. ".json"
    vim.fn.writefile({ "[]" }, path)
    vim.fn.writefile({ "{}" }, path .. ".unity-origin.json")
    local calls = {}
    local ok, err = pcall(function()
      package.loaded["ue.cdb.pipeline"] = nil
      local pipeline = require("ue.cdb.pipeline")
      config.setup({ cdb = { steps = { "expand_response_cdb.py", "prebuild_pch_v2.py", "resolve_cdb_paths.py" } } })
      pipeline.set_runtime({ clangd_path = function() return "C:/selected/clangd.exe" end,
        jobstart = function(command, tag, opts) calls[#calls + 1] = { command, tag, opts }; return 91 end,
        notify = function() end, log_error = function() end, restart_clangd = function() end })
      pipeline.run(path, { path }, function() end, { _host_admitted = true, defer_restart = true,
        engine_root = "C:/fixture/Engine", project_root = "C:/fixture/Project",
        logical_cdb = "C:/stable/build/compile_commands.json" })
      local cursor = 1
      while pipeline.is_running() do calls[cursor][3].on_exit(); cursor = cursor + 1 end
      local positions = {}
      for i, call in ipairs(calls) do positions[call[2]] = i end
      local strip, apply = positions["ue-pipeline-clangd_header_path_case_strip"], positions["ue-pipeline-clangd_header_path_case"]
      t.assert_true(strip ~= nil and apply ~= nil)
      t.assert_true(positions["ue-pipeline-unity-origin"] < strip)
      t.assert_true(positions["ue-pipeline-expand_response_cdb"] < strip)
      t.assert_true(strip < positions["ue-pipeline-clangd_friend_template_canonical"])
      t.assert_true(positions["ue-pipeline-resolve_cdb_paths"] < apply)
      t.assert_true(apply < positions["ue-pipeline-unity-receipt"])
      for _, i in ipairs({ strip, apply }) do
        t.assert_true(vim.tbl_contains(calls[i][1], "C:/stable/build/compile_commands.json"))
        t.assert_true(vim.tbl_contains(calls[i][1], "C:/selected/clangd.exe"))
        t.assert_true(vim.tbl_contains(calls[i][1], "C:/fixture/Engine"))
        t.assert_true(vim.tbl_contains(calls[i][1], "C:/fixture/Project"))
      end
    end)
    package.loaded["ue.cdb.pipeline"] = original
    config.setup(previous)
    os.remove(path); os.remove(path .. ".unity-origin.json")
    if not ok then error(err) end
  end)

  t.it("migrates only mapped empty header shards once and can restore every moved byte", function()
    python_test([=[
    import struct
    sys.path.insert(0,str(repo/'lua/workarounds/clangd'))
    import header_path_case_cache as cache
    actual_writers=cache._running_clangd()
    assert isinstance(actual_writers,list) and all(isinstance(pid,int) and pid>0 for pid in actual_writers)
    result=c.apply_policy(cdb,VERSION)
    semantic=output/'background-cdb/compile_commands.json'
    folder=semantic.parent/'.cache/clangd/index'; folder.mkdir(parents=True)
    def var(number):
        out=bytearray()
        while number>127: out.append((number&127)|128); number >>= 7
        return bytes(out)+bytes([number])
    def shard(file, main=False, relations=False, flags=None):
        uri=file.as_uri().encode(); table=b'\0'+uri+b'\0'
        chunks=[(b'meta',struct.pack('<I',20)),(b'stri',struct.pack('<I',0)+table),
                (b'symb',b''),(b'refs',b''),(b'rela',b'12345678\0abcdefgh' if relations else b''),
                (b'srcs',bytes([int(main) if flags is None else flags])+var(1)+b'12345678'+var(0))]
        body=b'CdIx'+b''.join(tag+struct.pack('<I',len(data))+data+(b'\0' if len(data)%2 else b'') for tag,data in chunks)
        return b'RIFF'+struct.pack('<I',len(body))+body
    target=folder/'RealHeader.h.0123456789ABCDEF.idx'; target.write_bytes(shard(header))
    relation=folder/'Forced.h.1123456789ABCDEF.idx'; relation.write_bytes(shard(forced,relations=True))
    main=folder/'Unit.cpp.2123456789ABCDEF.idx'; main.write_bytes(shard(unit,main=True))
    malformed=folder/'Bad.h.3123456789ABCDEF.idx'; malformed.write_bytes(b'not RIFF')
    outside=root/'Outside.h'; outside.write_text('outside')
    foreign=folder/'Outside.h.4123456789ABCDEF.idx'; foreign.write_bytes(shard(outside))
    errored=folder/'RealHeader.h.6123456789ABCDEF.idx'; errored.write_bytes(shard(header,flags=2))
    nested=folder/'nested'; nested.mkdir(); (nested/target.name).write_bytes(target.read_bytes())
    initial={p:(p.read_bytes(),p.stat().st_mtime_ns) for p in folder.rglob('*.idx')}
    for outcome in ([12345], OSError('process snapshot unavailable')):
        options={'side_effect':outcome} if isinstance(outcome,Exception) else {'return_value':outcome}
        with patch.object(cache,'_running_clangd',**options), patch.object(cache,'_scan',side_effect=AssertionError('writer gate scanned cache')):
            deferred=cache.migrate(cdb,semantic,folder)
        assert deferred['deferred'] and deferred['status']=='pending' and deferred['migrated']==0
        assert not (folder.parent/'header-path-case-migrations').exists()
        for p,identity in initial.items(): assert (p.read_bytes(),p.stat().st_mtime_ns)==identity
    # A writer appearing while the overlay is checked also prevents scanning.
    with patch.object(cache,'_running_clangd',side_effect=[[],[12345]]), patch.object(cache,'_scan',side_effect=AssertionError('late writer scanned cache')):
        deferred=cache.migrate(cdb,semantic,folder)
    assert deferred['deferred'] and json.loads(pathlib.Path(deferred['manifest']).read_text())['status']=='planning'
    # Isolate remaining byte-migration mechanics from unrelated host processes.
    patch.object(cache,'_running_clangd',return_value=[]).start()
    report=cache.migrate(cdb,semantic,folder)
    assert report['migrated']==1 and not target.exists(),report
    manifest=pathlib.Path(report['manifest']); saved=json.loads(manifest.read_text())
    assert saved['status']=='complete' and len(saved['files'])==1
    backup=pathlib.Path(saved['files'][0]['backup'])
    assert backup.read_bytes()==initial[target][0]
    for p,identity in initial.items():
        if p!=target: assert (p.read_bytes(),p.stat().st_mtime_ns)==identity
    stamp=manifest.stat().st_mtime_ns
    with patch.object(cache,'_scan',side_effect=AssertionError('repeat scanned cache')):
        assert cache.migrate(cdb,semantic,folder)['already_completed']
    assert manifest.stat().st_mtime_ns==stamp
    assert cache.restore(manifest)['restored']==1
    assert target.read_bytes()==initial[target][0]
    # A new policy/key starts with a complete plan; a failed move is retryable.
    other=output/'second-background/compile_commands.json'
    second_cache=other.parent/'.cache/clangd/index'; second_cache.mkdir(parents=True)
    second=second_cache/target.name; second.write_bytes(initial[target][0])
    second_forced=second_cache/'Forced.h.5123456789ABCDEF.idx'; second_forced.write_bytes(shard(forced))
    rename=cache.os.rename; moves=[]
    def deny_second(source,destination):
        moves.append(str(source))
        if len(moves)==2: raise OSError('denied migration')
        return rename(source,destination)
    with patch.object(cache.os,'rename',side_effect=deny_second):
        try: cache.migrate(cdb,other,second_cache)
        except cache.MigrationError as error: pending=pathlib.Path(error.manifest)
        else: raise AssertionError('failed move reported success')
    incomplete=json.loads(pending.read_text())
    assert incomplete['status']=='pending' and len(list((pending.parent/'backup').glob('*.idx')))==1
    assert cache.migrate(cdb,other,second_cache)['migrated']==2
    racing=output/'racing-background/compile_commands.json'; racing_cache=racing.parent/'.cache/clangd/index'
    racing_cache.mkdir(parents=True); racing_file=racing_cache/target.name; racing_file.write_bytes(initial[target][0])
    digest=cache._sha; reads=[]; regenerated=shard(header,relations=True)
    def changed_before_move(path):
        if pathlib.Path(path)==racing_file:
            reads.append(path)
            if len(reads)==2: racing_file.write_bytes(regenerated)
        return digest(path)
    with patch.object(cache,'_sha',side_effect=changed_before_move), patch.object(cache.os,'rename') as move:
        try: cache.migrate(cdb,racing,racing_cache)
        except cache.MigrationError as error: assert 'changed before migration' in str(error)
        else: raise AssertionError('concurrently changed shard was moved')
        move.assert_not_called()
    assert racing_file.read_bytes()==regenerated
    try: cache.migrate(cdb,semantic,root)
    except ValueError: pass
    else: raise AssertionError('foreign cache root accepted')
]=])
  end)

  t.it("runs migration only after successful CDB commit and reports its failure as already committed", function()
    python_test([=[
    sys.path.insert(0,str(repo/'lua/workarounds/clangd'))
    sys.path.insert(0,str(repo/'tools'))
    import header_path_case_cache as cache
    import cdb_transaction as transaction
    stage=output/'stage.json'; stage.write_bytes(cdb.read_bytes())
    entries=json.loads(stage.read_text()); entries[0]['arguments'].insert(1,'-DNEW_COMMAND=1'); stage.write_text(json.dumps(entries))
    semantic=output/'background/compile_commands.json'
    config={'stage':str(stage),'active':str(cdb),'targets':[str(cdb)],
            'stage_shards':str(output/'missing-stage-shards'),'shards':str(output/'shards'),
            'stage_manifest':str(output/'missing-stage-manifest'),'manifest':str(output/'manifest.json'),
            'partition_dir':str(output/'partition'),'semantic_cdb':str(semantic),
            'header_path_case_cache_dir':str(semantic.parent/'.cache/clangd/index')}
    before=cdb.read_bytes()
    with patch.object(transaction.os,'replace',side_effect=OSError('commit denied')), patch.object(cache,'migrate') as migrate:
        try: transaction.commit(config)
        except OSError: pass
        else: raise AssertionError('failed CDB commit accepted')
        migrate.assert_not_called()
    assert cdb.read_bytes()==before
    with patch.object(cache,'migrate',side_effect=OSError('migration denied')):
        failed=transaction.commit(config)
    assert not failed['ok'] and failed['committed'] and 'CDB committed' in failed['reason']
    assert json.loads(cdb.read_text())==entries
    with patch.object(cache,'migrate',return_value={'deferred':True,'migrated':0,'reason':'clangd-writer-present'}):
        deferred=transaction.commit(config)
    assert not deferred['ok'] and deferred['committed'] and 'migration deferred' in deferred['reason']
    assert json.loads(cdb.read_text())==entries
]=])
  end)

  t.it("passes the selected tuple cache and refreshes once for a cache-only successful commit", function()
    local transaction = require("ue.cdb.transaction")
    local root = vim.fs.normalize(vim.fn.tempname() .. "-cache-migration")
    vim.fn.mkdir(root, "p")
    local ctx = { engine_root = root, paths = { active_cdb = root .. "/compile_commands.json",
      cdb_shards_dir = root .. "/shards", semantic_cdb = root .. "/background/compile_commands.json" } }
    vim.fn.writefile({ "[]" }, ctx.paths.active_cdb)
    local refreshes, captured, reported = 0, nil, nil
    local ok, err = pcall(function()
      for _, count in ipairs({ 1, 0 }) do
        transaction.run(ctx, function() end, function(success, _, result)
          t.assert_true(success); reported = result
        end, { _host_admitted = true,
          generate = function(_, _, done) done(true) end,
          pipeline = function(_, _, done) done(true) end,
          partition = function(_, _, done) done(true) end,
          helper = function(config, operation, done)
            captured = config
            if operation == "cleanup" then vim.fn.delete(config.work, "rf") end
            done(true, nil, operation == "commit" and { changed = false, cache_migration = { migrated = count } } or nil)
          end,
          on_committed = function(result)
            refreshes = refreshes + 1
            t.assert_true(result.changed); t.assert_false(result.cdb_changed)
          end,
        })
        t.assert_false(reported.changed, "cache repair must not claim CDB bytes changed")
      end
      t.assert_eq(refreshes, 1)
      t.assert_eq(captured.semantic_cdb, ctx.paths.semantic_cdb)
      t.assert_eq(captured.header_path_case_cache_dir, root .. "/background/.cache/clangd/index")
    end)
    vim.fn.delete(root, "rf")
    if not ok then error(err) end
  end)
end)
