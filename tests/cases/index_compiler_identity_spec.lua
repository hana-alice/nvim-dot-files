local t = require("tests.harness")
t.bootstrap()

local fixture = [=[
import contextlib, copy, io, json, os, pathlib, shutil, sys, tempfile, time
from unittest.mock import patch
sys.dont_write_bytecode = True
sys.path.insert(0, sys.argv[1])
import clangd_query_profile as profile
import cdb_verified_batch as batch
tool = pathlib.Path(sys.argv[2]).resolve()
driver = tool.with_name('clang++.exe')
assert driver.is_file(), 'real installed native driver required'
class OwnedDirectory(tempfile.TemporaryDirectory):
    def cleanup(self):
        deadline = time.monotonic() + 2
        while True:
            try:
                return super().cleanup()
            except PermissionError as error:
                if getattr(error, 'winerror', None) != 32 or time.monotonic() >= deadline:
                    raise
                time.sleep(0.05)
with OwnedDirectory(prefix='compiler_identity_') as temporary:
    root = pathlib.Path(temporary).resolve()
    tools = root / 'extractor/bin'
    tools.mkdir(parents=True)
    native_clangd = tools / 'clangd.exe'
    shutil.copyfile(tool, native_clangd)
    drivers = []
    for name in ('first', 'second'):
        install = root / name
        (install / 'bin').mkdir(parents=True)
        (install / 'lib/clang/22/include').mkdir(parents=True)
        native = install / 'bin/clang++.exe'
        shutil.copyfile(driver, native)
        drivers.append(native)
    unrelated = root / 'unrelated'
    unrelated.mkdir()
    sysroot = root / 'sysroot'
    (sysroot / 'usr/include').mkdir(parents=True)
    source = root / 'main.cpp'
    source.write_text('int compiler_identity;\n')
    entry = {'directory': str(root), 'file': str(source), 'arguments': [
        'clang++.exe', '--target=aarch64-none-linux-android23', '--sysroot=' + str(sysroot),
        '-x', 'c++', '-std=c++17', '-c', str(source)]}
    server = {'query_driver': '**/clang*.exe', 'launch_cwd': root.as_posix(), 'enable_config': False}
    # Inject only an owned temporary-directory I/O failure. Already validated
    # cache routing is supplied to exercise the final gate's exact fallback;
    # no fake compiler or successful native evidence is manufactured.
    exact = [dict(entry), dict(entry, file=str(root / 'second.cpp'))]
    cached = {'accepted': True, 'first_proof_seconds': 1, 'query_profiles': [{}],
        'candidate': dict(entry, nvim_ue_batch_receipt=str(root / 'receipt.json'))}
    checks = []
    def resolution(*args, **kwargs):
        checks.append(True)
        if len(checks) == 1:
            return True
        with patch.object(tempfile, 'TemporaryDirectory', side_effect=OSError('owned-temp-unavailable')):
            with tempfile.TemporaryDirectory():
                raise AssertionError('temporary directory unexpectedly created')
    with patch.object(batch, '_batch_groups', return_value=iter([([0, 1], cached)])), \
         patch.object(batch, '_group_hint', return_value={}), contextlib.redirect_stdout(io.StringIO()), \
         patch.object(batch, '_query_resolution_current', side_effect=resolution):
        reverted, failure = batch.accelerate(exact, root / 'failure-proof', str(tool),
            verify_missing=False, server_profile=server)
    assert len(checks) == 2 and reverted == exact, failure
    assert failure['batch_count'] == 0 and failure['accepted_ubt_count'] == 0, failure
    assert failure['invalidated_reason'] == 'compiler-resolution-changed-during-run', failure
    assert failure['query_resolution_error'] == 'owned-temp-unavailable', failure
    assert failure['groups'][0]['reason'] == failure['invalidated_reason'], failure
    original_env = dict(os.environ)
    os.environ['PATH'] = str(drivers[0].parent)
    first = profile.observe(entry, str(native_clangd), server['query_driver'], root / 'proof/initial',
        launch_cwd=str(root), environment=dict(os.environ), timeout=30)
    assert first['ok'], first
    evidence = first['evidence']
    assert pathlib.Path(evidence['driver']['realpath']) == drivers[0].resolve(), evidence['driver']
    assert 'PATH' not in evidence['compiler_environment'] and 'PATHEXT' not in evidence['compiler_environment']
    before = batch._compiler_environment(server)
    assert 'PATH' not in before and 'PATHEXT' not in before
    os.environ['PATH'] = str(unrelated) + ';' + str(drivers[0].parent)
    assert batch._compiler_environment(server) == before
    assert batch._compiler_environment()['PATH'] != evidence['lookup_environment']['PATH'], 'unproven route must retain PATH'
    equivalent = profile.validate(evidence, entry, str(native_clangd), server['query_driver'], root / 'proof/equivalent',
        launch_cwd=str(root), environment=dict(os.environ), timeout=30)
    assert equivalent['ok'], equivalent
    assert equivalent['evidence']['driver_search_roots'] != evidence['driver_search_roots']
    assert profile.semantic_identity(equivalent['evidence']) == profile.semantic_identity(evidence)
    assert batch._query_resolution_current([evidence], native_clangd, server)
    identities = batch._identities(native_clangd, server_profile=server)
    output = root / 'proof'
    record = {'schema': 1, 'identities': identities, 'query_profiles': [evidence],
        'dependencies': [{'path': str(source), 'sha256': profile._file_hash(source)}],
        'assets': [{'path': str(source), 'sha256': profile._file_hash(source)}],
        'inventories': {str(root): batch._inventory(root, output)}}
    batch._QUERY_RESOLUTION_MEMO.clear()
    assert batch._cache_valid(record, output, {}), 'actual identical resolution must permit cache reuse'
    os.environ['PATH'] = str(drivers[1].parent) + ';' + str(drivers[0].parent)
    assert batch._compiler_environment(server) == before, 'resolution rather than text must reject'
    different = profile.validate(evidence, entry, str(native_clangd), server['query_driver'], root / 'proof/different',
        launch_cwd=str(root), environment=dict(os.environ), timeout=30)
    assert not different['ok'] and different['reason'] == 'query-profile-changed', different
    actual = different['evidence']['driver']
    assert pathlib.Path(actual['realpath']) == drivers[1].resolve(), actual
    assert actual['sha256'] == evidence['driver']['sha256']
    assert actual['version'].splitlines()[0] == evidence['driver']['version'].splitlines()[0]
    assert not batch._query_resolution_current([evidence], native_clangd, server)
    assert not batch._cache_valid(record, output, {}), 'different actual compiler must reject cache reuse'
    os.environ['PATH'] = str(unrelated) + ';' + str(drivers[0].parent)
    changed = dict(os.environ, CPATH=str(unrelated))
    denied = profile.validate(evidence, entry, str(native_clangd), server['query_driver'], root / 'proof/include-env',
        launch_cwd=str(root), environment=changed, timeout=30)
    assert not denied['ok'], 'include environment must remain in semantic identity'
    legacy = copy.deepcopy(evidence)
    legacy['parser_id'] = 'windows-llvm-22.1.5-query-driver-v4'
    denied = profile.validate(legacy, entry, str(native_clangd), server['query_driver'], root / 'proof/legacy',
        launch_cwd=str(root), environment=dict(os.environ))
    assert not denied['ok'] and denied['reason'] == 'invalid-query-evidence', denied
    # A PATH string can stay identical while a newly created application-dir
    # driver changes native SearchPathW resolution. Final proof checks must
    # rediscover even that case instead of relying on environment text alone.
    os.environ['PATH'] = evidence['lookup_environment']['PATH']
    (tools.parent / 'lib/clang/22/include').mkdir(parents=True)
    shadow = tools / 'clang++.exe'
    shutil.copyfile(driver, shadow)
    shadowed = profile.validate(evidence, entry, str(native_clangd), server['query_driver'], root / 'proof/shadow',
        launch_cwd=str(root), environment=dict(os.environ), timeout=30)
    assert not shadowed['ok'] and pathlib.Path(shadowed['evidence']['driver']['realpath']) == shadow.resolve(), shadowed
    assert not batch._query_resolution_current([evidence], native_clangd, server, force=True)
    print(json.dumps({'equivalent_path_reused': True, 'different_actual_path_rejected': True,
        'identical_compiler_bytes_and_version': True, 'include_environment_rejected': True,
        'legacy_profile_rejected': True, 'unproven_route_keeps_path': True,
        'unchanged_path_new_shadow_rejected': True}))
    os.environ.clear()
    os.environ.update(original_env)
]=]

t.describe("native compiler resolution identity", function()
  local discovered = require("utils.ue_goto.semantic_sidecar_libclang").discover_toolchain()
  local clangd = vim.env.UE_CLANGD or (discovered.ok and discovered.clangd_path) or vim.fn.exepath("clangd")
  local python = vim.fn.exepath("python")
  if python == "" then python = vim.fn.exepath("python3") end
  if not require("utils.platform").is_windows or clangd == "" or python == "" then
    t.skip("native PATH equivalence", "real Windows clangd and compiler required", { native = true })
    return
  end
  t.it("reuses irrelevant PATH changes and rejects a different real compiler with identical bytes", function()
    local script = vim.fn.tempname() .. "_compiler_identity.py"
    local file = assert(io.open(script, "wb")); file:write(fixture); file:close()
    local result = vim.system({ python, "-B", "-I", script,
      vim.fn.stdpath("config") .. "/tools", clangd }, { text = true }):wait(120000)
    vim.fn.delete(script)
    t.assert_eq(result.code, 0, (result.stderr or "") .. (result.stdout or ""))
    local evidence = vim.json.decode(result.stdout)
    t.assert_eq(evidence.equivalent_path_reused, true)
    t.assert_eq(evidence.different_actual_path_rejected, true)
  end)
end)
