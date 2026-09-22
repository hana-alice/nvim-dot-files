local t = require("tests.harness")
t.bootstrap()

local function python_test(body)
  local platform = require("utils.platform")
  local python = platform.resolve_tool({ name = "python",
    driver_candidates = function(driver) return driver.python_candidates() end })
  t.assert_true(python.ok, "Python is required for pure CDB tests")
  local script = vim.fn.tempname() .. ".py"
  local file = assert(io.open(script, "wb"))
  file:write("import sys\nsys.dont_write_bytecode = True\nsys.path.insert(0, sys.argv[1])\n", body)
  file:close()
  local result = vim.system({ python.path, "-B", "-I", script,
    vim.fn.stdpath("config") .. "/tools" }, { text = true }):wait()
  os.remove(script)
  t.assert_eq(result.code, 0, result.stderr or result.stdout)
end

t.describe("ue.cdb diagnostic compatibility", function()
  t.it("admits only the selected clangd version without launching a compiler in tests", function()
    python_test([=[
from unittest.mock import patch
from types import SimpleNamespace
import clangd_diagnostic_compat as c
for version in ('clangd version 22.1.0', 'clangd version 22.1.5 (source)', 'clangd version 22.1.99'):
    assert c.supported_version(version)
for version in ('clang version 22.1.5', 'clangd version 21.1.5', 'clangd version 22.2.0', 'clangd version 23.1.0', 'clangd version 22.1', ''):
    assert not c.supported_version(version)
with patch.object(c.subprocess, 'run', return_value=SimpleNamespace(returncode=0, stdout='clangd version 22.1.5', stderr='')) as run:
    output, reason = c.probe_clangd(sys.executable)
    assert reason is None and c.supported_version(output)
    assert run.call_args.args[0] == [sys.executable, '--version']
    assert run.call_args.kwargs['timeout'] == 5 and run.call_count == 1
with patch.object(c.subprocess, 'run', side_effect=OSError('selected executable unavailable')) as run:
    assert c.probe_clangd(sys.executable)[1].startswith('selected-clangd-probe-failed')
    assert run.call_count == 1
with patch.object(c.subprocess, 'run') as run:
    assert c.probe_clangd('clangd')[1] == 'selected-clangd-unavailable'
    assert c.probe_clangd('')[1] == 'selected-clangd-unavailable'
    run.assert_not_called()
]=])
  end)

  t.it("adds one option before source or terminator and respects language and explicit controls", function()
    python_test([=[
import copy
from pathlib import Path
import clangd_diagnostic_compat as c
root = str(Path.cwd())
source = str(Path(root) / 'Example.cpp')
base = {'directory': root, 'file': source, 'output': 'unchanged.o',
        'arguments': ['clang++', '--target=aarch64-none-linux-android23', '-std=c++17', '-Werror', '-DKEEP=1', '-IKeep', source]}
snapshot = copy.deepcopy(base)
out, reason = c.transform_entry(base)
assert reason == 'added' and base == snapshot
assert out['arguments'] == [base['arguments'][0], c.FLAG, *base['arguments'][1:]]
assert {k:v for k,v in out.items() if k != 'arguments'} == {k:v for k,v in base.items() if k != 'arguments'}
assert out['arguments'].count('-Werror') == 1 and out['arguments'].count(c.FLAG) == 1
assert c.transform_entry(out) == (out, 'explicit-diagnostic-control')
terminated = {**base, 'arguments': base['arguments'][:-1] + ['--', source]}
terminated_args = c.transform_entry(terminated)[0]['arguments']
assert terminated_args[1] == c.FLAG and terminated_args[-2:] == ['--', source]
# A final token spelling the source may instead be a required option operand.
for arguments in (base['arguments'][:-1] + ['-include', source],
                  base['arguments'][:-1], base['arguments'] + ['-O0']):
    variant = {**base, 'arguments': arguments}
    updated, reason = c.transform_entry(variant)
    assert reason == 'added' and updated['arguments'] == [arguments[0], c.FLAG, *arguments[1:]]
    if '-include' in arguments:
        assert updated['arguments'][updated['arguments'].index('-include') + 1] == source
separate = {**base, 'arguments': ['clang++', '-target', 'armv7-none-linux-androideabi23', '-std', 'c++17', '-x', 'c++', '-Werror', source]}
assert c.transform_entry(separate)[1] == 'added'
for control in ('-Werror=', '-Wno-error=', '-Wfatal-errors=', '-Wno-fatal-errors=', '-W', '-Wno-'):
    variant = {**base, 'arguments': base['arguments'][:-1] + [control + c.GROUP, source]}
    assert c.transform_entry(variant) == (variant, 'explicit-diagnostic-control')
for option in ('-w', '-Wno-everything'):
    variant = {**base, 'arguments': base['arguments'][:-1] + [option, source]}
    assert c.transform_entry(variant) == (variant, 'warnings-disabled')
for option in ('--target=x86_64-pc-windows-msvc', '--target=arm64-apple-ios', '-std=c++14', '-std=c++20', '-xobjective-c++', '-xc'):
    variant = {**base, 'arguments': base['arguments'][:-1] + [option, source]}
    assert c.transform_entry(variant)[0] == variant
restored = {**base, 'arguments': ['clang++', '--target=arm64-apple-ios', '-std=c++20', '-xc', *base['arguments'][1:-1], '-xc++', source]}
assert c.transform_entry(restored)[1] == 'added'
variant = {**base, 'file': str(Path(root) / 'Example.c'), 'arguments': base['arguments'][:-1] + [str(Path(root) / 'Example.c')]}
assert c.transform_entry(variant)[0] == variant
shader = {**base, 'file': str(Path(root) / 'Donor.usf'), 'arguments': ['clang++', '-x', 'c++', '-std=c++17', str(Path(root) / 'Donor.usf')]}
assert c.transform_entry(shader) == (shader, 'unsupported-target')
]=])
  end)

  t.it("keeps repeated CDB bytes and mtime and seals final unity and shader commands", function()
    python_test([=[
import hashlib, json, os, tempfile
from pathlib import Path
import clangd_diagnostic_compat as c
import cdb_unity_receipt as receipt
import build_hot_super_unity_cdb as groups
with tempfile.TemporaryDirectory(prefix='ue-cdb-diag-') as folder:
    root = Path(folder).resolve()
    a, b, shader = [root / name for name in ('A.cpp', 'B.cpp', 'Donor.usf')]
    for p in (a,b,shader): p.write_text('// unchanged build source\n')
    unity, rsp = root / 'Module.Example.cpp', root / 'Module.Example.cpp.o.rsp'
    unity.write_text(''.join('#include "' + p.as_posix() + '"\n' for p in (a,b)))
    rsp.write_text('original compiler-authored flags\n')
    def entry(p): return {'directory':str(root), 'file':str(p), 'arguments':['clang++','--target=aarch64-none-linux-android23','-std=c++17','-x','c++','-Werror',str(p)]}
    original = list(map(entry,(a,b,shader)))
    cdb = root / 'compile_commands.json'
    cdb.write_text(json.dumps(original, indent=2))
    origin = Path(str(cdb)+'.unity-origin.json')
    origin.write_text(json.dumps({'schema':1, 'groups':[{'unity':str(unity),'members':list(map(str,(a,b))),
        'dependencies':{str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in (unity,rsp)},
        'commands':{e['file']:receipt.entry_hash(e) for e in original[:2]}}],
        'synthetic_shaders':[{'file':str(shader),'directory':str(root),'command_hash':receipt.entry_hash(original[2])}]}))
    unchanged = {p:p.read_bytes() for p in (a,b,shader,unity,rsp,origin)}
    pending = root / 'pending.json'
    assert receipt.begin(str(cdb), str(pending)) == 1
    initial = cdb.read_bytes(); initial_stat = cdb.stat().st_mtime_ns
    assert not c.apply_policy(cdb,'clangd version 21.1.0')['changed']
    assert cdb.read_bytes() == initial and cdb.stat().st_mtime_ns == initial_stat
    assert c.apply_policy(cdb,'clangd version 22.1.5')['added'] == 3
    final = json.loads(cdb.read_text()); content = cdb.read_bytes()
    assert len(final)==len(original) and [e['file'] for e in final]==[e['file'] for e in original]
    os.utime(cdb, ns=(1000000000000000000,1000000000000000000))
    stamp = cdb.stat().st_mtime_ns
    assert not c.apply_policy(cdb,'clangd version 22.1.5')['changed']
    assert cdb.read_bytes() == content and cdb.stat().st_mtime_ns == stamp
    assert receipt.seal(str(cdb),str(pending)) == 1
    sealed = str(cdb)+'.unity-receipt.json'
    verified = receipt.load_verified_groups(sealed,final)
    result = groups.compiler_authored_unity_groups(final,None,verified)
    assert len(result)==1 and result[0][1]==[0,1] and result[0][2]=='exact'
    rewritten = groups.rewritten_arguments(final[0],str(root/'SuperUnity.cpp'))
    assert rewritten.count(c.FLAG)==1 and '-Werror' in rewritten
    assert receipt.load_verified_synthetic_shaders(sealed,final)=={receipt.entry_hash(final[2])}
    for p,data in unchanged.items(): assert p.read_bytes()==data
    sealed_path = Path(sealed)
    sealed_bytes = sealed_path.read_bytes()
    os.utime(sealed_path, ns=(1000000000000000000,1000000000000000000))
    sealed_stamp = sealed_path.stat().st_mtime_ns
    assert receipt.begin(str(cdb), str(pending)) == 1
    assert receipt.seal(str(cdb), str(pending)) == 1
    assert sealed_path.read_bytes()==sealed_bytes and sealed_path.stat().st_mtime_ns==sealed_stamp
    digest = receipt.complete(str(cdb))['digest']
    assert not receipt.complete(str(cdb))['changed']
    assert receipt.complete(str(cdb))['digest']==digest
]=])
  end)

  t.it("passes the actual runtime selection and never supplies alternative binaries", function()
    local original_pipeline = package.loaded["ue.cdb.pipeline"]
    local platform = require("utils.platform")
    local config = require("ue.config")
    local previous_options = vim.deepcopy(config.options())
    local original_resolve = platform.resolve_tool
    local path = vim.fn.tempname() .. ".json"
    vim.fn.writefile({ "[]" }, path)
    local calls, selections = {}, {}
    local selected = "/selected/clangd"
    local ok, err = pcall(function()
      package.loaded["ue.cdb.pipeline"] = nil
      local pipeline = require("ue.cdb.pipeline")
      config.setup({ cdb = { steps = { "clangd_diagnostic_compat.py" } } })
      platform.resolve_tool = function(spec)
        if spec.name ~= "clangd" then return original_resolve(spec) end
        selections[#selections + 1] = vim.deepcopy(spec)
        return { ok = false }
      end
      pipeline.set_runtime({ clangd_path = function() return selected end,
        jobstart = function(cmd, _, opts)
          calls[#calls + 1] = { cmd = cmd, opts = opts }
          return 12
        end,
        notify = function() end, log_error = function() end, restart_clangd = function() end })
      pipeline.run(path, { path }, function() end, { _host_admitted = true, defer_restart = true })
      local index = 1
      while pipeline.is_running() do calls[index].opts.on_exit(); index = index + 1 end
      t.assert_eq(#selections, 1)
      t.assert_true(vim.deep_equal(selections[1].config_candidates, { selected }))
      t.assert_nil(selections[1].env)
      t.assert_nil(selections[1].driver_candidates)
      local command = calls[1].cmd
      t.assert_eq(command[#command - 1], "--clangd")
      t.assert_eq(command[#command], selected)
    end)
    platform.resolve_tool = original_resolve
    package.loaded["ue.cdb.pipeline"] = original_pipeline
    config.setup(previous_options)
    os.remove(path)
    if not ok then error(err) end
  end)
end)
