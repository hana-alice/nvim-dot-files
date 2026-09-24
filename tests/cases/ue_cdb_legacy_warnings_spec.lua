local t = require("tests.harness")
t.bootstrap()

local function python_test(body, extra)
  local platform = require("utils.platform")
  local python = platform.resolve_tool({ name = "python",
    driver_candidates = function(driver) return driver.python_candidates() end })
  t.assert_true(python.ok, "Python is required for CDB policy tests")
  local script = vim.fn.tempname() .. ".py"
  local file = assert(io.open(script, "wb"))
  file:write("import sys\nsys.dont_write_bytecode = True\nsys.path.insert(0, sys.argv[1])\n", body)
  file:close()
  local argv = { python.path, "-B", "-I", script,
    vim.fn.stdpath("config") .. "/lua/workarounds/clangd" }
  vim.list_extend(argv, extra or {})
  local result = vim.system(argv, { text = true }):wait(30000)
  os.remove(script)
  t.assert_eq(result.code, 0, result.stderr or result.stdout)
end

local fixture = [=[
import copy
from pathlib import Path
import legacy_android_warnings as policy
CLANGD = 'clangd version 22.1.5'
BUILD = 'Android (build fixture) clang version 9.0.9 (test version input)'
root = str(Path.cwd())
source = str(Path(root) / 'Example.cpp')
base = {'directory': root, 'file': source, 'output': 'unchanged.o',
        'arguments': ['clang++', '--target=aarch64-none-linux-android23', '-std=c++17',
                      '-Wall', '-Werror', '-DKEEP=1', '-IKeep', source]}
def transform(entry, clangd=CLANGD, build=BUILD):
    return policy.transform_entry(entry, clangd, build)
]=]

t.describe("ue.cdb legacy Android warning compatibility", function()
  t.it("requires proven clangd, build compiler, Android target and C++17 language", function()
    python_test(fixture .. [=[
for clangd in ('clangd version 22.1.5', 'clangd version 22.1.6'):
    assert transform(base, clangd=clangd)[1] == 'added', clangd
for clangd in ('', 'clangd version 21.1.5', 'clangd version 22.2.0', 'clangd version 23.1.1', 'clangd version 23.2.0',
               'clangd version 24.1.0', 'clang version 23.1.1'):
    assert transform(base, clangd=clangd)[0] == base, clangd
for build in ('', 'clang version 9.0.9', 'Android clang version 9.0.8',
              'Android clang version 9.0.90', 'Android clang version 14.0.7', 'Android clang version 22.1.5'):
    assert transform(base, build=build)[0] == base, build
for option in ('--target=x86_64-pc-windows-msvc', '--target=arm64-apple-ios',
               '--target=aarch64-linux-gnu', '-std=c++14', '-std=c++20', '-std=gnu++17', '-xc', '-xobjective-c++'):
    variant = {**base, 'arguments': base['arguments'][:-1] + [option, source]}
    assert transform(variant)[0] == variant, option
for omitted in ('--target=aarch64-none-linux-android23', '-std=c++17'):
    variant = {**base, 'arguments': [arg for arg in base['arguments'] if arg != omitted]}
    assert transform(variant)[0] == variant, omitted
for suffix in ('.c', '.h', '.usf'):
    path = str(Path(root) / ('Example' + suffix))
    variant = {**base, 'file': path, 'arguments': base['arguments'][:-1] + [path]}
    assert transform(variant)[0] == variant, suffix
    variant['arguments'].insert(1, '-xc++')
    assert transform(variant)[1] == 'added', suffix
for indirect in (['@original.rsp'], ['-Xclang', '-std=c++20'],
                 ['-Xpreprocessor', '-DKEEP=2'], ['-Wp,-DKEEP=2']):
    variant = {**base, 'arguments': base['arguments'][:-1] + indirect + [source]}
    assert transform(variant)[0] == variant, indirect
separate = {**base, 'arguments': ['clang++', '-target', 'armv7-none-linux-androideabi23',
                                 '-std', 'c++17', '-x', 'c++', '-Werror', source]}
assert transform(separate)[1] == 'added'
]=])
  end)

  t.it("adds only the two warning demotions without mutating input or option operands", function()
    python_test(fixture .. [=[
expected = ['-Wno-error=vla-cxx-extension', '-Wno-error=unused-but-set-variable']
for args in (base['arguments'], base['arguments'][:-1] + ['--', source],
             base['arguments'][:-1] + ['-include', source],
             base['arguments'] + ['-include', 'forced.h', '-o', 'Object.o']):
    variant = {**base, 'arguments': args}
    original = copy.deepcopy(variant)
    result, reason = transform(variant)
    assert reason == 'added' and variant == original
    assert result['arguments'] == [args[0], *expected, *args[1:]]
    assert {k:v for k,v in result.items() if k != 'arguments'} == {k:v for k,v in original.items() if k != 'arguments'}
    assert transform(result)[0] == result
    assert result['arguments'].count('-Werror') == 1
    for flag in expected: assert result['arguments'].count(flag) == 1
]=])
  end)

  t.it("requires effective global Werror and respects ordered global controls", function()
    python_test(fixture .. [=[
args = [arg for arg in base['arguments'][:-1] if arg != '-Werror']
for controls in ([], ['-Wno-error'], ['-Werror', '-Wno-error'],
                 ['-Wno-error', '-Werror', '-Wno-error'], ['-Werror=vla-cxx-extension']):
    variant = {**base, 'arguments': [*args, *controls, source]}
    result, reason = transform(variant)
    assert result == variant and reason == 'no-global-werror', controls
for controls in (['-Werror'], ['-Wno-error', '-Werror'],
                 ['-Werror', '-Wno-error', '-Werror']):
    variant = {**base, 'arguments': [*args, *controls, source]}
    result, reason = transform(variant)
    assert reason == 'added', controls
    assert result['arguments'] == [args[0], *policy.FLAGS, *args[1:], *controls, source]
    assert transform(result)[0] == result
]=])
  end)

  t.it("respects each explicit warning group and its parents independently", function()
    python_test(fixture .. [=[
groups = (('vla-cxx-extension', ('vla', 'vla-extension')),
          ('unused-but-set-variable', ('unused',)))
for index, (group, parents) in enumerate(groups):
    own = '-Wno-error=' + group
    other = '-Wno-error=' + groups[1-index][0]
    for name in (group, *parents):
        for prefix in ('-W', '-Wno-', '-Werror=', '-Wno-error=', '-Wfatal-errors=', '-Wno-fatal-errors='):
            control = prefix + name
            variant = {**base, 'arguments': base['arguments'][:-1] + [control, source]}
            result, reason = transform(variant)
            assert reason == 'added' and result['arguments'] == [variant['arguments'][0], other, *variant['arguments'][1:]], control
            assert transform(result)[0] == result, control
for controls in (['-Werror=vla-cxx-extension', '-Werror=unused-but-set-variable'],
                 ['-Wno-vla', '-Wno-unused'], ['-w'], ['-Wno-everything']):
    variant = {**base, 'arguments': base['arguments'][:-1] + controls + [source]}
    assert transform(variant)[0] == variant, controls
unrelated = {**base, 'arguments': base['arguments'][:-1] + ['-Werror=return-type', source]}
assert transform(unrelated)[1] == 'added'
for prefix in ('-W', '-Wno-', '-Werror=', '-Wno-error='):
    variant = {**base, 'arguments': base['arguments'][:-1] + [prefix + 'unused-variable', source]}
    result, reason = transform(variant)
    assert reason == 'added'
    assert result['arguments'] == [variant['arguments'][0], *policy.FLAGS, *variant['arguments'][1:]]
]=])
  end)

  t.it("preserves pedantic VLA choices without blocking the independent unused warning policy", function()
    python_test(fixture .. [=[
for control in ('-pedantic', '-pedantic-errors', '-Wpedantic', '-Wno-pedantic',
                '-Werror=pedantic', '-Wno-error=pedantic'):
    variant = {**base, 'arguments': base['arguments'][:-1] + [control, source]}
    result, reason = transform(variant)
    assert reason == 'added'
    assert result['arguments'] == [variant['arguments'][0], '-Wno-error=unused-but-set-variable',
                                   *variant['arguments'][1:]], control
    assert transform(result)[0] == result, control
]=])
  end)

  t.it("leaves unproven compiler CDB bytes and mtimes unchanged", function()
    python_test(fixture .. [=[
import json, os, tempfile
with tempfile.TemporaryDirectory(prefix='legacy-warning-cdb-') as folder:
    path = Path(folder) / 'compile_commands.json'
    path.write_text(json.dumps([base], indent=2))
    os.utime(path, ns=(1000000000000000000, 1000000000000000000))
    before, stamp = path.read_bytes(), path.stat().st_mtime_ns
    for version in (CLANGD, 'clangd version 23.1.1', 'clangd version 24.1.0', CLANGD):
        result = policy.apply_policy(path, version)
        assert result['changed'] is False and result['added'] == 0 and result['entries'] == 1
        assert path.read_bytes() == before and path.stat().st_mtime_ns == stamp
]=])
  end)

  t.it("adds the selected-tool pipeline step only while enabled", function()
    local policy = require("workarounds.clangd.legacy_android_warnings")
    local applied = policy.status().applied
    local ok, err = pcall(function()
      local original = { name = "previous", command = { "original" } }
      local steps = { original }
      policy.disable()
      policy.configure_steps(steps, "/selected/python", "/staged/cdb.json", "/selected/clangd")
      t.assert_eq(#steps, 1)
      policy.apply()
      policy.apply()
      policy.configure_steps(steps, "/selected/python", "/staged/cdb.json", "")
      t.assert_eq(#steps, 1)
      policy.configure_steps(steps, "/selected/python", "/staged/cdb.json", "/selected/clangd")
      t.assert_eq(#steps, 2)
      t.assert_eq(steps[1], original)
      t.assert_true(vim.deep_equal(steps[2].command, { "/selected/python", "-u", "-I",
        vim.fn.stdpath("config") .. "/lua/workarounds/clangd/legacy_android_warnings.py",
        "/staged/cdb.json", "--clangd", "/selected/clangd" }))
    end)
    if applied then policy.apply() else policy.disable() end
    if not ok then error(err) end
  end)

  t.it("preserves registry disable before the pipeline is first loaded", function()
    local script = vim.fn.tempname() .. ".lua"
    vim.fn.writefile({
      "vim.opt.rtp:prepend(" .. string.format("%q", vim.fn.stdpath("config")) .. ")",
      "local registry = require('workarounds')",
      "registry.setup({ auto_apply = false })",
      "local name = 'clangd.legacy_android_warnings'",
      "assert(package.loaded['ue.cdb.pipeline'] == nil)",
      "assert(registry.disable(name))",
      "require('ue.cdb.pipeline')",
      "local status = registry.status(name)",
      "assert(status.enabled == false and status.applied == false and status.runtime.applied == false)",
      "local policy = require('workarounds.clangd.legacy_android_warnings')",
      "local steps = {}",
      "policy.configure_steps(steps, '/selected/python', '/staged/cdb.json', '/selected/clangd')",
      "assert(#steps == 0)",
      "assert(registry.enable(name))",
      "status = registry.status(name)",
      "assert(status.enabled and status.applied and status.runtime.applied)",
      "policy.configure_steps(steps, '/selected/python', '/staged/cdb.json', '/selected/clangd')",
      "assert(#steps == 1)",
    }, script)
    local result = vim.system({ vim.v.progpath, "--headless", "-u", "NONE", "-l", script },
      { text = true }):wait(10000)
    os.remove(script)
    t.assert_eq(result.code, 0, result.stderr or result.stdout)
  end)
end)

t.describe("legacy Android warning native evidence", function()
  local discovery = require("utils.ue_goto.semantic_sidecar")._discover_toolchain_for_test()
  local compiler
  if discovery.ok then
    local bin = vim.fs.dirname(discovery.clangd_path)
    for _, name in ipairs({ "clang++", "clang++.exe" }) do
      local path = bin .. "/" .. name
      if vim.fn.filereadable(path) == 1 and vim.fn.executable(path) == 1 then compiler = path; break end
    end
  end
  if not compiler then
    t.skip("real LLVM compiler warning contrast", discovery.reason or "matching clang++ unavailable", { native = true })
    return
  end

  t.it("retains both warnings and still rejects an undeclared identifier", function()
    python_test(fixture .. [=[
import subprocess, tempfile
compiler, clangd = sys.argv[2:4]
version = subprocess.run([clangd, '--version'], capture_output=True, text=True, timeout=5)
assert version.returncode == 0 and policy.supported_version(version.stdout), version.stdout
with tempfile.TemporaryDirectory(prefix='legacy-warning-native-') as folder:
    source = Path(folder) / 'Warnings.cpp'
    source.write_text('int legacy(int n) { int assigned = 0; assigned = n; int values[n]; values[0] = n; return values[0]; }\n')
    entry = {'directory':folder, 'file':str(source), 'arguments':[compiler,
        '--target=aarch64-none-linux-android23', '-std=c++17', '-Wall', '-Werror', '-fsyntax-only', str(source)]}
    original = source.read_bytes()
    def run(args): return subprocess.run(args, cwd=folder, capture_output=True, text=True, timeout=10)
    before = run(entry['arguments'])
    assert before.returncode != 0, before.stderr
    for group in ('vla-cxx-extension', 'unused-but-set-variable'): assert group in before.stderr, before.stderr
    sibling = {**entry, 'arguments': entry['arguments'][:-1] + ['-Wno-unused-variable', str(source)]}
    sibling_before = run(sibling['arguments'])
    assert sibling_before.returncode != 0 and '-Wunused-but-set-variable' in sibling_before.stderr, sibling_before.stderr
    repaired, reason = policy.transform_entry(sibling, version.stdout, BUILD)
    assert reason == 'added' and all(flag in repaired['arguments'] for flag in policy.FLAGS)
    sibling_after = run(repaired['arguments'])
    assert sibling_after.returncode == 0 and '-Wunused-but-set-variable' in sibling_after.stderr, sibling_after.stderr
    for parent, child in (('unused', 'unused-but-set-variable'), ('vla', 'vla-cxx-extension'),
                          ('vla-extension', 'vla-cxx-extension')):
        explicit = {**entry, 'arguments': entry['arguments'][:-1] + ['-Wno-' + parent, str(source)]}
        before_parent = run(explicit['arguments'])
        assert '-W' + child not in before_parent.stderr, before_parent.stderr
        respected, reason = policy.transform_entry(explicit, version.stdout, BUILD)
        assert reason == 'added' and '-Wno-error=' + child not in respected['arguments']
        after_parent = run(respected['arguments'])
        assert after_parent.returncode == 0 and '-W' + child not in after_parent.stderr, after_parent.stderr
    without_error = [arg for arg in entry['arguments'][:-1] if arg != '-Werror']
    for controls in ([], ['-Werror', '-Wno-error']):
        permissive = {**entry, 'arguments': [*without_error, *controls, str(source)]}
        unchanged, reason = policy.transform_entry(permissive, version.stdout, BUILD)
        assert unchanged == permissive and reason == 'no-global-werror'
        result = run(unchanged['arguments'])
        assert result.returncode == 0 and 'warning:' in result.stderr, result.stderr
    ordered = {**entry, 'arguments': [*without_error, '-Wno-error', '-Werror', str(source)]}
    assert run(ordered['arguments']).returncode != 0
    corrected, reason = policy.transform_entry(ordered, version.stdout, BUILD)
    assert reason == 'added' and run(corrected['arguments']).returncode == 0
    adjusted, reason = policy.transform_entry(entry, version.stdout, BUILD)
    assert reason == 'added'
    after = run(adjusted['arguments'])
    assert after.returncode == 0, after.stderr
    for group in ('vla-cxx-extension', 'unused-but-set-variable'): assert group in after.stderr, after.stderr
    assert 'warning:' in after.stderr and source.read_bytes() == original
    for control in ('-pedantic', '-pedantic-errors', '-Werror=pedantic'):
        strict_entry = {**entry, 'arguments': entry['arguments'][:-1] + [control, str(source)]}
        assert run(strict_entry['arguments']).returncode != 0
        preserved, reason = policy.transform_entry(strict_entry, version.stdout, BUILD)
        assert reason == 'added' and '-Wno-error=vla-cxx-extension' not in preserved['arguments']
        strict = run(preserved['arguments'])
        assert strict.returncode != 0 and 'error:' in strict.stderr and '-Wvla-cxx-extension' in strict.stderr, strict.stderr
    for group in ('vla-cxx-extension', 'unused-but-set-variable'):
        explicit = {**entry, 'arguments': entry['arguments'][:-1] + ['-Werror=' + group, str(source)]}
        preserved, reason = policy.transform_entry(explicit, version.stdout, BUILD)
        assert reason == 'added' and '-Wno-error=' + group not in preserved['arguments']
        strict = run(preserved['arguments'])
        assert strict.returncode != 0 and '-Werror,-W' + group in strict.stderr, strict.stderr
        assert source.read_bytes() == original
    source.write_bytes(original + b'int unrelated(int unused_parameter) { return 0; }\n')
    other_warning = run([adjusted['arguments'][0], '-Wunused-parameter', *adjusted['arguments'][1:]])
    assert other_warning.returncode != 0 and '-Werror,-Wunused-parameter' in other_warning.stderr, other_warning.stderr
    source.write_bytes(original + b'int invalid() { return missing_identifier; }\n')
    failure = run(adjusted['arguments'])
    assert failure.returncode != 0 and 'undeclared identifier' in failure.stderr, failure.stderr
]=], { compiler, discovery.clangd_path })
  end)

  t.it("probes a real nonlegacy driver once and does not accept it as NDK r21", function()
    python_test(fixture .. [=[
import json, tempfile
from unittest.mock import patch
compiler = Path(sys.argv[2]).resolve()
root = compiler.parent.parent
with tempfile.TemporaryDirectory(prefix='legacy-warning-driver-') as folder:
    path = Path(folder) / 'compile_commands.json'
    entries = []
    for name in ('First.cpp', 'Second.cpp'):
        source = str(Path(folder) / name)
        entries.append({'directory':folder, 'file':source, 'arguments':[str(compiler),
            '--gcc-toolchain=' + str(root), '--sysroot=' + str(root / 'sysroot'),
            '--target=aarch64-none-linux-android23', '-std=c++17', '-Werror', source]})
    path.write_text(json.dumps(entries, indent=2))
    before, stamp = path.read_bytes(), path.stat().st_mtime_ns
    actual_run = policy.subprocess.run
    with patch.object(policy.subprocess, 'run', wraps=actual_run) as probe:
        result = policy.apply_policy(path, CLANGD)
        assert probe.call_count == 1, (probe.call_count, result, entries)
        assert probe.call_args.args[0] == [str(compiler), '--version']
    assert not result['changed'] and result['added'] == 0
    assert result['outcomes']['unsupported-build-compiler'] == 2
    assert path.read_bytes() == before and path.stat().st_mtime_ns == stamp
    entries[0]['arguments'][2] = '--sysroot=' + str(root / 'foreign-sysroot')
    path.write_text(json.dumps(entries[:1]))
    with patch.object(policy.subprocess, 'run', wraps=actual_run) as probe:
        result = policy.apply_policy(path, CLANGD)
        probe.assert_not_called()
    assert not result['changed'] and result['outcomes']['unproven-build-compiler'] == 1
]=], { compiler })
  end)
end)
