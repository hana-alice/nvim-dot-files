local t = require("tests.harness")
t.bootstrap()

local fixture = [=[
import hashlib, importlib.util, json, pathlib, runpy, shutil, sys, tempfile

repository, operation = pathlib.Path(sys.argv[1]), sys.argv[2]
assert not sys.dont_write_bytecode, 'must exercise ordinary Python without -B'
with tempfile.TemporaryDirectory(prefix='index_bytecode_') as temporary:
    root = pathlib.Path(temporary).resolve()
    # Prove this interpreter and temporary filesystem really permit bytecode.
    control = root / 'control.py'
    control.write_text('value = 7\n', encoding='utf-8')
    spec = importlib.util.spec_from_file_location('bytecode_control', control)
    control_module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(control_module)
    assert control_module.value == 7
    assert pathlib.Path(importlib.util.cache_from_source(str(control))).is_file()

    source = root / 'source'
    tools = source / 'tools'
    policy_dir = source / 'lua/workarounds/clangd'
    tools.mkdir(parents=True)
    policy_dir.mkdir(parents=True)
    # Copy source only: existing workstation caches must neither mask the first
    # import nor be changed by this regression.
    for path in (repository / 'tools').glob('*.py'):
        shutil.copyfile(path, tools / path.name)
    shutil.copyfile(repository / 'lua/workarounds/clangd/header_path_case.py',
                    policy_dir / 'header_path_case.py')
    names_before = sorted(str(path.relative_to(source)) for path in source.rglob('*'))

    project = root / 'project'
    project.mkdir()
    header = project / 'Header.h'
    header.write_text('struct HeaderValue {};\n', encoding='utf-8')
    canonical = header.as_posix()
    overlay_bytes = json.dumps({'version': 0, 'case-sensitive': False,
        'use-external-names': True, 'fallthrough': True,
        'roots': [{'type': 'file', 'name': canonical,
                   'external-contents': canonical}]}).encode('utf-8')
    overlay = project / ('header-path-case.' + hashlib.sha256(overlay_bytes).hexdigest() + '.json')
    overlay.write_bytes(overlay_bytes)

    # run_path models direct script startup: the entry script itself does not
    # write bytecode before it can establish the policy for its imports.
    if operation == 'dynamic':
        module = runpy.run_path(str(tools / 'cdb_verified_batch.py'))
        policy = module['_owned_overlay_policy']()
        assert callable(policy.validate_owned_overlay)
        assert policy.validate_owned_overlay(overlay) == {canonical: canonical}
        assert module['_owned_overlay_policy']() is policy
    elif operation == 'ordinary':
        module = runpy.run_path(str(tools / 'build_super_unity_cdb.py'))
        entries = []
        for name in ('a', 'b'):
            member = project / (name + '.gen.cpp')
            member.write_text('int ' + name + ';\n', encoding='utf-8')
            wrapper = project / ('SuperUnity.UBT.' + name + '.cpp')
            wrapper.write_text('// Compiler-authored UBT unity membership; copied into nvim cache.\n'
                + '#include "' + member.as_posix() + '"\n', encoding='utf-8')
            entries.append({'directory': str(project), 'file': str(wrapper),
                'arguments': ['clang++', '-ivfsoverlay', str(overlay), '-c', str(wrapper)],
                'nvim_ue_members': [module['portable_member_path'](str(member))],
                'nvim_ue_module_root': 'Source/Module'})
        output, metrics = module['build_generated_batches'](entries, project / 'output')
        policy = sys.modules['header_path_case']
        assert callable(policy.validate_owned_overlay)
        assert policy.validate_owned_overlay(overlay) == {canonical: canonical}
        assert metrics['secondary_groups'] == 1 and len(output) == 1
        assert output[0]['nvim_ue_generated_originals'] == entries
    else:
        raise AssertionError(operation)
    assert pathlib.Path(policy.__file__).resolve() == policy_dir / 'header_path_case.py'
    caches = [str(path.relative_to(source)) for path in source.rglob('*.pyc')]
    assert not caches, 'first policy import changed proof inventory: ' + repr(caches)
    assert sorted(str(path.relative_to(source)) for path in source.rglob('*')) == names_before
    assert overlay.read_bytes() == overlay_bytes
    print(json.dumps({'operation': operation, 'status': 'passed'}))
]=]

local function run_fixture(operation)
  local python = vim.fn.exepath("python")
  if python == "" then python = vim.fn.exepath("python3") end
  if python == "" then
    t.skip("index policy bytecode", "Python unavailable")
    return
  end
  local script = vim.fn.tempname() .. "_index_bytecode.py"
  local stream = assert(io.open(script, "wb"))
  stream:write(fixture)
  stream:close()
  local result = vim.system({ python, "-I", script, vim.fn.stdpath("config"), operation },
    { text = true }):wait()
  pcall(vim.fn.delete, script)
  t.assert_eq(result.code, 0, (result.stderr or "") .. (result.stdout or ""))
end

t.describe("index proof inventory remains stable on first policy import", function()
  t.it("dynamic owned overlay loader creates no bytecode in isolated source", function()
    run_fixture("dynamic")
  end)
  t.it("generated batching ordinary import validates owned overlays without bytecode", function()
    run_fixture("ordinary")
  end)
end)
