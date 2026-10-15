local t = require("tests.harness")
t.bootstrap()

local fixture = [=[
import argparse, importlib.util, json, os, pathlib, subprocess, sys, tempfile, time
sys.path.insert(0, str(pathlib.Path(sys.argv[1]).parent))
spec = importlib.util.spec_from_file_location('switch', sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
operation = sys.argv[2]
with tempfile.TemporaryDirectory(prefix='switch_reindex_') as name:
    root = pathlib.Path(name)
    if operation == 'cover':
        edges = {'a': {'b', 'h'}, 'b': {'h'}, 'h': {'a'}}
        assert m.closure('a', edges) == {'a', 'b', 'h'}
        closures = {'a': {'a','b','h'}, 'b': {'b','h'}, 'c': {'c','h','g'}, 'd': {'d','g'}}
        chosen = m.select_cover(closures, {'a','b','h','g'})
        assert 'a' in chosen and 'b' in chosen, 'changed main must be forced even when covered'
        assert chosen == ['a', 'b', 'd'], chosen
        assert m.select_cover(closures, set()) == []
        for mapping, changes in [(closures, {'unreferenced'}), ({}, {'a'})]:
            try: m.select_cover(mapping, changes)
            except ValueError as error: assert str(error) == 'uncovered-changed-files'
            else: raise AssertionError('uncovered changes silently accepted')
        assert m.select_cover({'wide': {'a','b','c','d'}, 'small': {'a'}}, {'a'}) == ['small']
    elif operation == 'split':
        closures = {str(i): set(range(cost)) for i,cost in enumerate([9,8,5,4,3])}
        bins = m.split_lpt(list(closures), closures, 2)
        assert sorted(sum(bins, [])) == sorted(closures)
        assert [sum(len(closures[t]) for t in group) for group in bins] == [16,13]
        assert m.split_lpt(['0'], closures, 2) == [['0']]
        assert m.workers_for(30*m.GIB, 2) == 2 and m.workers_for(15*m.GIB, 2) == 1
        assert m.workers_for(12*m.GIB, 2) == 0 and m.workers_for(3*m.GIB, 1) == 0
    elif operation == 'manifest':
        source = root/'a.cpp'; source.write_text('a')
        paths = {m.norm(source), m.norm(root/'missing')}
        before = m.snapshot(paths)
        manifest = root/'srcs-manifest.json'
        assert m.manifest_state(manifest, before) == ('missing-baseline', set())
        m.save_manifest(manifest, before)
        assert m.manifest_state(manifest, m.snapshot(paths)) == ('none', set())
        source.write_text('changed')
        after = m.snapshot(paths)
        assert m.manifest_state(manifest, after) == ('changed', {m.norm(source)})
        assert json.loads(manifest.read_text()) == before, 'detection must not advance baseline'
        m.save_manifest(manifest, after); source.unlink()
        assert m.manifest_state(manifest, m.snapshot(paths))[1] == {m.norm(source)}
        m.save_manifest(manifest, m.snapshot(paths))
        assert m.manifest_state(manifest, m.snapshot(paths))[0] == 'none'
    elif operation == 'generation':
        cdb=root/'compile_commands.json'; cdb.write_text('[]')
        index=root/'index'; index.mkdir(); shard=index/'a.idx'; shard.write_bytes(b'shard')
        identity=m.generation_identity(cdb,index)
        manifest=root/'manifest.json'; sources={'a':[1,2]}
        m.save_manifest(manifest,sources,identity)
        before=manifest.stat().st_mtime_ns
        m.save_manifest(manifest,sources,identity)
        assert manifest.stat().st_mtime_ns == before, 'no-op baseline must not rewrite'
        assert m.manifest_state(manifest,sources,identity) == ('none',set())
        assert m.manifest_state(manifest,{'a':[2,2]},identity) == ('changed',{'a'})
        cdb.write_text('[{}]')
        assert m.manifest_state(manifest,sources,m.generation_identity(cdb,index))[0] == 'stale-baseline'
        cdb.write_text('[]'); shard.write_bytes(b'new shard')
        assert m.manifest_state(manifest,sources,m.generation_identity(cdb,index))[0] == 'stale-baseline'
        m.save_manifest(manifest,sources)
        assert m.manifest_state(manifest,sources,identity)[0] == 'stale-baseline', 'legacy unbound baseline is not evidence'
    elif operation == 'execute':
        if os.name != 'nt': print('skip:Windows helper locking unavailable'); sys.exit()
        source=root/'Source'; source.mkdir(); main=source/'a.cpp'; main.write_text('int a;')
        header=source/'a.h'; header.write_text('int a;')
        index=root/'index'; index.mkdir(); (index/'a.idx').write_bytes(b'fixture shard identity')
        cdb=root/'compile_commands.json'; cdb.write_text(json.dumps([dict(directory=str(root),file=str(main),arguments=['clang++',str(main)])]))
        m.read_edges=lambda _: {m.norm(main):{m.norm(header)},m.norm(header):set()}
        args=argparse.Namespace(work_root=str(root/'work'),index_dir=str(index),cdb=str(cdb),
            changed_list=None,source_root=[str(source)],baseline_only=False,server_profile=None,
            clangd='fixture-clangd-never-executed',timeout=1,jobs=1,workers=1)
        report=m.execute(args)
        assert not report['ok'] and report['needs_prepare'] and report['reason']=='missing-baseline',report
        assert not (root/'work/srcs-manifest.json').exists(), 'missing old evidence must not advance baseline'
        changes=root/'changes.json'; changes.write_text('[]'); args.changed_list=str(changes)
        assert m.execute(args)['reason']=='missing-baseline', 'an empty changed list cannot bypass generation evidence'
        args.changed_list=None
        args.baseline_only=True; assert m.execute(args)['action']=='baseline'; args.baseline_only=False
        assert m.execute(args)['action']=='none'
        # First actual modification after the successful prepare baseline selects a TU.
        class NoHeadroom:
            reason=''
            def __enter__(self): return self
            def __exit__(self,*_): pass
            def available(self): return 0
        m.OwnedJob=NoHeadroom
        header.write_text('first branch change')
        report=m.execute(args)
        assert report['cover_tus']==1 and report['reason']=='insufficient-commit-headroom',report
        args.baseline_only=True; assert m.execute(args)['ok']; args.baseline_only=False
        baseline=(root/'work/srcs-manifest.json').read_bytes()
        extra=source/'new.h'; extra.write_text('new')
        report=m.execute(args)
        assert not report['ok'] and report['needs_prepare'] and report['uncovered_changed_files']==[m.norm(extra)],report
        assert (root/'work/srcs-manifest.json').read_bytes()==baseline
        args.baseline_only=True; assert m.execute(args)['ok']; args.baseline_only=False
        extra.rename(source/'renamed.h')
        report=m.execute(args)
        assert report['needs_prepare'] and set(report['uncovered_changed_files'])=={m.norm(extra),m.norm(source/'renamed.h')},report
        args.baseline_only=True; assert m.execute(args)['ok']; args.baseline_only=False
        header.unlink(); report=m.execute(args)
        assert report['needs_prepare'] and m.norm(header) in report['uncovered_changed_files'],report
        cdb.write_text('[]'); report=m.execute(args)
        assert report['needs_prepare'] and report['reason']=='stale-baseline',report
    elif operation == 'postworker':
        if os.name != 'nt': print('skip:Windows helper locking/junctions unavailable'); sys.exit()
        source=root/'Source'; source.mkdir(); main=source/'a.cpp'; main.write_text('int a;')
        header=source/'a.h'; header.write_text('int a;')
        index=root/'index'; index.mkdir(); shard=index/'a.idx'; shard.write_bytes(b'old shard')
        cdb=root/'compile_commands.json'; cdb.write_text(json.dumps([dict(directory=str(root),file=str(main),arguments=['clang++',str(main)])]))
        m.read_edges=lambda _: {m.norm(main):{m.norm(header)},m.norm(header):set()}
        args=argparse.Namespace(work_root=str(root/'work'),index_dir=str(index),cdb=str(cdb),changed_list=None,
            source_root=[str(source)],baseline_only=True,server_profile=None,clangd='never-executed',timeout=1,jobs=1,workers=1)
        assert m.execute(args)['ok']; args.baseline_only=False
        class EnoughHeadroom:
            reason=''
            def __enter__(self): return self
            def __exit__(self,*_): pass
            def available(self): return 30*m.GIB
        m.OwnedJob=EnoughHeadroom
        mutation=''
        def worker(*_):
            shard.write_bytes(shard.read_bytes()+b'worker update')
            if mutation=='source': header.write_text('modified during indexing')
            if mutation=='cdb': cdb.write_text('[]')
            return dict(process_wall_seconds=.01,peak_working_set_bytes=0,compile_failure_count=0,background_compile_success=True)
        m.runner.run=worker
        header.write_text('first branch content')
        report=m.execute(args); assert report['ok'] and report['cover_tus']==1,report
        saved=json.loads((root/'work/srcs-manifest.json').read_text())
        assert saved['generation']==m.generation_identity(cdb,index), 'must bind post-worker shards'
        assert m.execute(args)['action']=='none', 'successful shard writes must allow repeated no-op'
        baseline=(root/'work/srcs-manifest.json').read_bytes()
        header.write_text('second branch content'); mutation='source'
        report=m.execute(args)
        assert not report['ok'] and report['needs_prepare'] and report['reason']=='source-changed-during-reindex',report
        assert (root/'work/srcs-manifest.json').read_bytes()==baseline, 'source race must not advance baseline'
        args.baseline_only=True; assert m.execute(args)['ok']; args.baseline_only=False
        baseline=(root/'work/srcs-manifest.json').read_bytes()
        header.write_text('third branch content'); mutation='cdb'
        report=m.execute(args)
        assert not report['ok'] and report['needs_prepare'] and report['reason']=='generation-changed-during-reindex',report
        assert (root/'work/srcs-manifest.json').read_bytes()==baseline
        def timeout(*_): raise TimeoutError('source-inventory-budget-exceeded')
        m.source_inventory=timeout
        report=m.execute(args); assert report['needs_prepare'] and report['reason']=='source-inventory-budget-exceeded',report
    elif operation == 'junction':
        if os.name != 'nt': print('skip:Windows junctions unavailable'); sys.exit()
        import _winapi
        work=root/'work'; work.mkdir(); target=root/'shared'; target.mkdir()
        sentinel=target/'keep.idx'; sentinel.write_bytes(b'persist')
        worker=work/'w0'; (worker/'.cache/clangd').mkdir(parents=True)
        try: _winapi.CreateJunction(str(target), str(worker/'.cache/clangd/index'))
        except OSError as error: print('skip:' + str(error)); sys.exit()
        m.cleanup_worker(worker, work)
        assert not worker.exists() and sentinel.read_bytes() == b'persist'
        worker.mkdir(); (worker/'leftover').mkdir()
        _winapi.CreateJunction(str(target), str(worker/'leftover/unknown-link'))
        m.cleanup_worker(worker, work)
        assert sentinel.read_bytes() == b'persist' and not worker.exists()
        try: m.cleanup_worker(target, work)
        except ValueError: pass
        else: raise AssertionError('cleanup accepted path outside work-root')
        assert sentinel.exists()
    elif operation == 'job':
        if os.name != 'nt': print('skip:Windows Job Objects unavailable'); sys.exit()
        memory=m.Memory(); memory.length=m.C.sizeof(memory)
        if not m.C.windll.kernel32.GlobalMemoryStatusEx(m.C.byref(memory)) or memory.available_commit < m.FLOOR_GIB*m.GIB:
            print('skip:available commit below native guard'); sys.exit()
        with m.OwnedJob() as job:
            process=subprocess.Popen([sys.executable,'-I','-c','import time; time.sleep(30)'])
            assert process.poll() is None
        assert process.wait(timeout=5) != 0, 'job close must terminate owned child'
        assert subprocess.Popen is job.original
    else: raise AssertionError(operation)
print('ok')
]=]

local function run_case(operation)
  local python = vim.fn.exepath("python")
  if python == "" then python = vim.fn.exepath("python3") end
  if python == "" then t.skip(operation, "Python unavailable", { native = true }); return end
  local root = vim.fn.tempname() .. "_switch_reindex"
  vim.fn.mkdir(root, "p")
  local script = root .. "/probe.py"
  local file = assert(io.open(script, "wb"))
  file:write(fixture)
  file:close()
  local result = vim.system({ python, "-B", "-I", script,
    vim.fn.stdpath("config") .. "/tools/clangd_switch_reindex.py", operation }, { text = true }):wait()
  vim.fn.delete(root, "rf")
  t.assert_eq(result.code, 0, result.stderr or result.stdout)
  if (result.stdout or ""):match("^skip:") then
    t.skip(operation, vim.trim(result.stdout), { native = true }); return
  end
  t.assert_eq(vim.trim(result.stdout), "ok")
end

t.describe("private branch switch reindex Python", function()
  for _, case in ipairs({
    { "forces changed mains and uses weighted closure cover", "cover" },
    { "balances all selected TUs with LPT", "split" },
    { "detects baseline none changed and deleted source without premature refresh", "manifest" },
    { "binds baseline to CDB and shard generation without rewriting no-op", "generation" },
    { "fails closed for missing old evidence, added, renamed, deleted and changed CDB inputs", "execute" },
    { "binds post-worker shards and rejects source/CDB races without advancing baseline", "postworker" },
    { "detaches native junction leftovers without deleting shared shard targets", "junction" },
    { "bounds native owned processes and terminates children on Job close", "job" },
  }) do
    t.it(case[1], function() run_case(case[2]) end)
  end
end)
