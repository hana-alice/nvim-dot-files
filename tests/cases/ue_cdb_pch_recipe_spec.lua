local t = require("tests.harness")
t.bootstrap()

t.describe("PCH recipes cannot publish missing compiler inputs", function()
  t.it("preserves text inputs, repairs proven generated pairs and leaves external PCH intact", function()
    local platform = require("utils.platform")
    local python = platform.resolve_tool({ name = "python",
      driver_candidates = function(driver) return driver.python_candidates() end })
    t.assert_true(python.ok)
    local script = vim.fn.tempname() .. ".py"
    vim.fn.writefile(vim.split([[
import importlib.util,json,pathlib,subprocess,sys,tempfile
spec=importlib.util.spec_from_file_location('pch', pathlib.Path.cwd()/'tools/prebuild_pch_v2.py')
m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
with tempfile.TemporaryDirectory() as folder:
    root=pathlib.Path(folder); header=root/'SharedPCH.Sample.h'; header.write_text('typedef int Sample;')
    source=root/'main.cpp'; source.write_text('int main(){return 0;}')
    cdb=root/'compile_commands.json'
    args=['clang++','-include',header.as_posix(),'-c',source.as_posix()]
    entry={'file':source.as_posix(),'directory':root.as_posix(),'arguments':args}
    cdb.write_text(json.dumps([entry])); original=cdb.read_bytes()
    subprocess.run([sys.executable,str(pathlib.Path(m.__file__)),str(cdb)],check=True,capture_output=True)
    assert cdb.read_bytes()==original, 'recipe generation changed compiler inputs'
    pchdir=root/'.cache/nvim-ue/clangd/pch'; binary=pchdir/'SharedPCH.Sample.pch'
    assert not binary.exists() and (pchdir/'SharedPCH.Sample.rsp').exists()
    polluted=[dict(entry,arguments=args[:3]+['-include-pch',binary.as_posix()]+args[3:])]
    assert m.remove_missing_generated_pch(polluted,str(pchdir))==1
    assert polluted[0]['arguments']==args
    assert m.remove_missing_generated_pch(polluted,str(pchdir))==0
    external=[dict(entry,arguments=args[:3]+['-include-pch',(root/'external.pch').as_posix()]+args[3:])]
    untouched=json.dumps(external)
    assert m.remove_missing_generated_pch(external,str(pchdir))==0
    assert json.dumps(external)==untouched
    binary_only=[dict(entry,arguments=['clang++','-include-pch',binary.as_posix(),'-c',source.as_posix()])]
    assert m.remove_missing_generated_pch(binary_only,str(pchdir))==0
    binary.write_bytes(b'existing binary must not be removed')
    existing=[dict(entry,arguments=args[:3]+['-include-pch',binary.as_posix()]+args[3:])]
    assert m.remove_missing_generated_pch(existing,str(pchdir))==0
print('PCH_RECIPE_OK')
]], "\n", { plain = true }), script)
    local result = vim.system({ python.path, "-I", script }, { text = true, cwd = vim.fn.stdpath("config") }):wait(15000)
    vim.fn.delete(script)
    t.assert_eq(result.code, 0, result.stderr)
    t.assert_contains(result.stdout, "PCH_RECIPE_OK")
  end)
end)
