local t = require("tests.harness")
t.bootstrap()

local fixture = [=[
import hashlib, importlib.util, json, os, pathlib, subprocess, sys, tempfile
sys.dont_write_bytecode = True
sys.path.insert(0, sys.argv[1])
from cdb_verified_batch import accelerate, portable_member_path
from clangd_batch_activation import activate, normalized_cdb_digest, _lookup_watches
clangd, mode = pathlib.Path(sys.argv[2]), sys.argv[3]
compiler = clangd.with_name('clang++' + clangd.suffix)
target = subprocess.check_output([str(compiler), '-dumpmachine'], text=True,
    creationflags=(subprocess.CREATE_NO_WINDOW | subprocess.IDLE_PRIORITY_CLASS) if os.name == 'nt' else 0).strip()
with tempfile.TemporaryDirectory(prefix='batch_activation_') as temporary:
    root = pathlib.Path(temporary).resolve()
    sources = root / 'Engine/Source/Runtime/Sample'
    sources.mkdir(parents=True)
    sysroot = root / 'sysroot'
    (sysroot / 'usr/include').mkdir(parents=True)
    entries = []
    for n in range(2):
        source = sources / ('Unit' + str(n) + '.cpp')
        source.write_text('int function' + str(n) + '() { return ' + str(n) + '; }\n')
        wrapper = root / ('SuperUnity.UBT.' + str(n) + '.cpp')
        wrapper.write_text('// Compiler-authored UBT unity membership; copied into nvim cache.\n'
                           + '#include "' + source.as_posix() + '"\n')
        entries.append({'directory': str(root), 'file': str(wrapper),
            'arguments': [str(compiler), '--target=' + target, '--sysroot=' + str(sysroot),
                          '-x', 'c++', '-std=c++17', '-c', str(wrapper)],
            'nvim_ue_members': [portable_member_path(str(source))],
            'nvim_ue_module_root': 'Source/Runtime/Sample'})
    original, frozen, info = root / 'compile_commands.json', root / 'frozen.json', root / 'batches.json'
    for path in (original, frozen, info):
        path.write_text('{}')
    background, metrics = accelerate(entries, root / 'proofs', str(clangd), max_group=2, timeout=30)
    assert metrics['batch_count'] == 1, metrics
    original.write_text(json.dumps(entries))
    frozen.write_text(json.dumps(background))
    receipt = pathlib.Path(background[0]['nvim_ue_batch_receipt'])
    info.write_text(json.dumps({'schema': 1, 'original_cdb': str(original), 'verified_cdb': str(frozen),
        'original_sha256': hashlib.sha256(original.read_bytes()).hexdigest(),
        'active_cdb': str(original), 'active_digest': normalized_cdb_digest(original), 'generation_id': 'native-fixture',
        'receipts': [str(receipt)], 'verified_sha256': hashlib.sha256(frozen.read_bytes()).hexdigest(),
        'receipt_hashes': {str(receipt): hashlib.sha256(receipt.read_bytes()).hexdigest()},
        'watch_bases': [str(root / 'Engine/Source')]}))
    described = activate(info, str(clangd))
    assert described['ok'] and described['watch_roots'], described
    assert described['tool_path'] == str(clangd.resolve()), described
    assert str(receipt) in described['watched_files'] and str(info) in described['watched_files']
    assert str(frozen.parent / '.cache') in described['exclude_roots']
    stored = json.loads(receipt.read_text())
    assert all(str(pathlib.Path(asset['path']).resolve()) in described['watched_files']
               for asset in stored['assets']), 'excluded snapshots must retain exact watchers'
    valid = activate(info, str(clangd), validate=True)
    assert valid['ok'], valid
    assert valid['tool_path'] == described['tool_path'], valid
    old = frozen.read_bytes()
    frozen.write_text('[]')
    assert activate(info, str(clangd), validate=True)['reason'] == 'published-batch-cdb-changed'
    frozen.write_bytes(old)
    old_original = original.read_bytes()
    original.write_text('[]')
    assert activate(info, str(clangd), validate=True)['reason'] == 'published-original-cdb-changed'
    original.write_bytes(old_original)
    (sources / 'Unit0.cpp').write_text('int changed() { return 3; }\n')
    assert not activate(info, str(clangd), validate=True)['ok']
    if mode == 'legacy':
        print('ok')
        raise SystemExit(0)
    profile = {'query_driver': clangd.parent.as_posix() + '/clang*',
               'launch_cwd': root.as_posix(), 'enable_config': False}
    background, metrics = accelerate(entries, root / 'query-proofs', str(clangd),
                                     max_group=2, timeout=30, server_profile=profile)
    assert metrics['batch_count'] == 1, metrics
    frozen.write_text(json.dumps(background))
    receipt = pathlib.Path(background[0]['nvim_ue_batch_receipt'])
    publication = json.loads(info.read_text())
    publication.update(receipts=[str(receipt)], verified_sha256=hashlib.sha256(frozen.read_bytes()).hexdigest(),
                       receipt_hashes={str(receipt): hashlib.sha256(receipt.read_bytes()).hexdigest()})
    info.write_text(json.dumps(publication))
    assert not activate(info, str(clangd))['ok'], 'receipt must not authorize an unrequested query profile'
    described = activate(info, str(clangd), server_profile=profile)
    assert described['ok'] and described['server_profile'] == profile, described
    assert described['lookup_roots'], 'driver ancestors require independent direct watches'
    assert str(clangd.with_name('clang++' + clangd.suffix).resolve()) in described['watched_files']
    assert set(described['lookup_roots']).isdisjoint(described['input_roots']), 'lookup roots are not source inventories'
    valid = activate(info, str(clangd), validate=True, server_profile=profile)
    assert valid['ok'] and valid['server_profile'] == profile, valid
    changed_profile = dict(profile, query_driver='different-driver*')
    assert not activate(info, str(clangd), validate=True, server_profile=changed_profile)['ok']
    changed_profile = dict(profile, launch_cwd=sources.as_posix())
    assert not activate(info, str(clangd), validate=True, server_profile=changed_profile)['ok']
    (root / 'lookup').mkdir()
    missing = root / 'lookup/not-created/deeper'
    candidate = missing / 'clang++'
    direct, watched = _lookup_watches([str(missing)], [str(candidate)], [sources])
    assert root / 'lookup' in direct and root in direct, 'nearest existing ancestor and its parent must be watched'
    assert candidate in watched and root / 'lookup/not-created' in watched, 'first missing component must revoke on creation'
    assert all(path.is_dir() for path in direct)
    # A recursive source root covers direct lookups below itself; direct parents
    # must not pretend to cover nested direct lookup directories.
    direct, _ = _lookup_watches([str(sources), str(root / 'lookup')], [], [sources])
    assert sources not in direct and root / 'lookup' in direct
print('ok')
]=]

t.describe("verified batch activation", function()
  local native = require("utils.ue_goto.semantic_sidecar_libclang").discover_toolchain()
  if not native.ok then
    t.skip("native frozen publication validation", native.reason, { native = true })
    return
  end
  local function run_fixture(mode)
    local python = vim.fn.exepath("python")
    if python == "" then python = vim.fn.exepath("python3") end
    if python == "" then t.skip("Python activation fixture", "Python unavailable", { native = true }); return end
    local script = vim.fn.tempname() .. "_batch_activation.py"
    local file = assert(io.open(script, "wb"))
    file:write(fixture)
    file:close()
    local result = vim.system({ python, "-B", "-I", script,
      vim.fn.stdpath("config") .. "/tools", native.clangd_path, mode }, { text = true }):wait()
    pcall(vim.fn.delete, script)
    t.assert_eq(result.code, 0, (result.stderr or "") .. (result.stdout or ""))
    t.assert_eq(vim.trim(result.stdout):match("[^\n]+$"), "ok")
  end
  t.it("watches immutable assets and rejects changed publication or input bytes", function()
    run_fixture("legacy")
  end)
  t.it("requires an explicit matching native query profile and separates direct lookup ancestors from inputs", function()
    if vim.fn.has("win32") ~= 1 then t.skip("native Windows query activation", "Windows query profile required", { native = true }); return end
    run_fixture("query")
  end)
end)
