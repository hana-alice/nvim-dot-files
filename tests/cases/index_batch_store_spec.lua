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

with tempfile.TemporaryDirectory(prefix='batch_store_') as temporary:
    root = pathlib.Path(temporary).resolve()
    if operation == 'arguments':
        for name in ('build_clangd_index', 'build_full_cdb'):
            positional = [str(root / 'missing.json')]
            if name == 'build_full_cdb': positional.append(str(root / 'active.json'))
            common = ['--background-output', str(root / 'background.json'), '--clangd', sys.executable]
            for flags, store, expected in (
                ([], str(root / 'store'), 'requires --verified-batches and --reuse-verified-only'),
                (['--verified-batches'], str(root / 'store'), 'requires --verified-batches and --reuse-verified-only'),
                (['--reuse-verified-only'], str(root / 'store'), 'requires --verified-batches and --reuse-verified-only'),
                (['--verified-batches', '--reuse-verified-only'], 'relative/store', 'nonempty absolute path'),
                (['--verified-batches', '--reuse-verified-only'], '', 'nonempty absolute path'),
                (['--verified-batches', '--reuse-verified-only'], '   ', 'nonempty absolute path'),
            ):
                command = [sys.executable, '-B', '-I', str(tools / (name + '.py'))] + positional + common
                result = subprocess.run(command + flags + ['--verified-batch-store', store],
                    capture_output=True, text=True, timeout=10)
                assert result.returncode == 2 and expected in result.stderr, (command, result.stderr)
                assert not list(root.iterdir()), 'argument rejection must precede filesystem changes'
        print('both generators reject unsafe store arguments before reading inputs')
        sys.exit(0)

    source = root / 'Engine/Source/Runtime/Sample/Private'
    source.mkdir(parents=True)
    unity_root = root / 'Build/Intermediate/Build/Host/Target/Development'
    pch = unity_root / 'Engine/PCH.h'
    pch.parent.mkdir(parents=True)
    pch.write_text('#pragma once\n')
    compiler = pathlib.Path(clangd).with_name('clang++' + pathlib.Path(clangd).suffix)
    flags = ['-std=c++17', '-include', str(pch), '-c']
    entries = []
    for i in range(3):
        member = source / ('Member' + str(i) + '.cpp')
        member.write_text('int member' + str(i) + '() { return ' + str(i) + '; }\n')
        unity = unity_root / 'Sample' / ('Module.Sample.' + str(i) + '.cpp')
        unity.parent.mkdir(exist_ok=True)
        unity.write_text('#include "' + member.as_posix() + '"\n')
        argv = flags + [str(unity)]
        response = subprocess.list2cmdline(argv) if os.name == 'nt' else shlex.join(argv)
        pathlib.Path(str(unity) + '.o.rsp').write_text(response)
        entries.append({'directory': str(root / 'Engine/Source'), 'file': str(member),
            'arguments': [str(compiler)] + flags + [str(member)]})
    for name in ('Loose.cpp', 'Shader.usf'):
        path = source / name
        path.write_text('// exact fallback\n')
        entries.append({'directory': str(source), 'file': str(path),
            'arguments': [str(compiler), '-x', 'c++', '-c', str(path)]})
    input_path = root / 'input.json'
    input_path.write_text(json.dumps(entries))
    super_dir = root / 'stable/super_unity_cpps'
    store = root / 'external-proof'
    generators = {name: module(name) for name in ('build_clangd_index', 'build_full_cdb')}
    last_metrics = []
    real_accelerate, real_popen = batch.accelerate, subprocess.Popen

    def observe(*args, **kwargs):
        assert kwargs['verify_missing'] is False
        result = real_accelerate(*args, **kwargs)
        last_metrics.append(result[1])
        return result

    def generator_only(command, *args, **kwargs):
        assert pathlib.Path(command[0]).resolve() == pathlib.Path(sys.executable).resolve(), command
        return real_popen(command, *args, **kwargs)

    def generate(name, selected_store=None, verify=False):
        directory = root / name
        directory.mkdir(exist_ok=True)
        output, marker = directory / 'background.json', directory / 'marker.json'
        argv = [name, str(input_path)]
        if name == 'build_full_cdb':
            argv += [str(directory / 'active.json'), '--idx-output', str(marker)]
        else:
            argv += ['--output', str(marker)]
        argv += ['--background-output', str(output), '--super-dir', str(super_dir)]
        if verify:
            argv += ['--verified-batches', '--reuse-verified-only', '--clangd', clangd, '--batch-size', '2']
        if selected_store is not None:
            argv += ['--verified-batch-store', str(selected_store)]
        captured = io.StringIO()
        with patch.object(sys, 'argv', argv), contextlib.redirect_stdout(captured), \
             patch.object(batch, 'accelerate', observe), \
             patch.object(batch, '_prove', side_effect=AssertionError('generator started a fresh proof')), \
             patch.object(batch, 'compare_graphs', side_effect=AssertionError('generator replayed a graph')), \
             patch.object(subprocess, 'Popen', generator_only):
            code = generators[name].main()
        assert code == 0, captured.getvalue()
        return output, marker, json.loads(output.read_text())

    # Exercise both complete generator pipelines before qualifying their real wrappers.
    baseline = {}
    for name in generators:
        baseline[name] = generate(name)[2]
    originals = baseline['build_clangd_index']
    assert originals == baseline['build_full_cdb'] and len(originals) == 5
    wrappers = [e for e in originals if batch._is_ubt(e)]
    assert len(wrappers) == 3
    pair = [wrappers[0], wrappers[2]]  # Deliberately noncontiguous in the full CDB.
    candidates, proven = batch.accelerate(pair, store, clangd, max_group=2, timeout=30)
    assert proven['accepted_ubt_count'] == 2 and proven['batch_count'] == 1, proven
    receipt = pathlib.Path(candidates[0]['nvim_ue_batch_receipt'])
    payload = json.loads(receipt.read_text())
    protected = {pathlib.Path(row['path']) for row in payload['assets']} | {receipt}
    protected.update(pathlib.Path(e['file']) for e in wrappers)
    snapshot = lambda paths: {str(p): (p.read_bytes(), p.stat().st_mtime_ns) for p in paths}
    before = snapshot(protected)
    original_members = sorted(m for e in originals for m in e['nvim_ue_members'])
    for name in generators:
        output, marker, current = generate(name, store, True)
        assert len(current) == 4 and current[0] == candidates[0]
        assert current[1:] == [e for e in originals if e not in pair]
        assert sorted(m for e in current for m in e['nvim_ue_members']) == original_members
        assert json.loads(pathlib.Path(str(output) + '.semantic.json').read_text()) == originals
        assert last_metrics[-1]['cache_hits'] == 1 and last_metrics[-1]['accepted_ubt_count'] == 2
        counts = json.loads(marker.read_text())
        assert counts['verified_batches']['batch_count'] == 1
        assert counts['verified_batches']['exact_count'] == 1 and counts['verified_batches']['shader_count'] == 1
        published = snapshot([output, marker, pathlib.Path(str(output) + '.semantic.json')])
        assert generate(name, store, True)[2] == current
        assert snapshot(map(pathlib.Path, published)) == published, 'unchanged repeat rewrote published artifacts'
        assert snapshot(protected) == before, 'reuse rewrote receipt, frozen assets, or UBT wrappers'
        # The omitted option still uses the existing default; an absent external store defers too.
        for absent in (None, root / 'not-qualified'):
            assert generate(name, absent, True)[2] == originals
            assert last_metrics[-1]['accepted_ubt_count'] == 0 and last_metrics[-1]['deferred_group_count'] > 0
    # A real dependency edit invalidates the stored proof; no compiler or replay is permitted.
    changed = source / 'Member0.cpp'
    changed.write_text(changed.read_text() + '// newer source revision\n')
    for name in generators:
        assert generate(name, store, True)[2] == originals
        assert last_metrics[-1]['accepted_ubt_count'] == 0 and last_metrics[-1]['deferred_group_count'] > 0
    assert snapshot(protected) == before
    print('both generators: native proof, noncontiguous reuse, exact/shader coverage, unchanged repeat, missing/stale fallback')
]=]

local function run_fixture(operation, clangd)
  local python = vim.fn.exepath("python")
  if python == "" then python = vim.fn.exepath("python3") end
  t.assert_true(python ~= "", "Python is required for CDB generation")
  local script = vim.fn.tempname() .. "_batch_store.py"
  local stream = assert(io.open(script, "wb"))
  stream:write(fixture)
  stream:close()
  local result = vim.system({ python, "-B", "-I", script,
    vim.fn.stdpath("config") .. "/tools", operation, clangd or "" }, { text = true }):wait()
  pcall(vim.fn.delete, script)
  t.assert_eq(result.code, 0, (result.stderr or "") .. (result.stdout or ""))
end

t.describe("external verified batch store", function()
  t.it("requires absolute nonempty paths and explicit cache-only verification before generator work", function()
    run_fixture("arguments")
  end)
  local discovered = require("utils.ue_goto.semantic_sidecar_libclang").discover_toolchain()
  if not discovered.ok then
    t.skip("external store native proof and both generator pipelines", discovered.reason, { native = true })
    return
  end
  t.it("reuses native noncontiguous proofs through both generators and preserves fallback coverage and artifact identity", function()
    run_fixture("integration", discovered.clangd_path)
  end)
end)
