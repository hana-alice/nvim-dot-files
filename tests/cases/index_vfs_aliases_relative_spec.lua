local t = require("tests.harness")
t.bootstrap()

local fixture = [=[
import importlib.util, json, os, pathlib, subprocess, sys, tempfile
tool, clangd = sys.argv[1:]
spec = importlib.util.spec_from_file_location('verified_batch', tool)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
from clangd_vfs_aliases import collect_aliases
root = pathlib.Path(tempfile.mkdtemp(prefix='frozen_relative_')).resolve()
compiler = pathlib.Path(clangd).with_name('clang++.exe')
files = []
def write(name, text):
    path = root/name
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)
    files.append(path)
    return path
left = write('Left/X.h', '#define LEFT_VALUE 7\n')
right = write('Right/X.h', '#define RIGHT_VALUE 11\n')
write('Left/Deep/Peer.h', '#define PEER_VALUE 3\n')
left_entry = write('Left/Deep/More/Entry.h', '#include "../../X.h"\n#include "../Peer.h"\n')
right_entry = write('Right/Sub/Entry.h', '#include "../X.h"\n')
source = write('member.cpp', '#include "'+left_entry.as_posix()+'"\n#include "'+right_entry.as_posix()
    +'"\nstatic_assert(LEFT_VALUE == 7 && RIGHT_VALUE == 11 && PEER_VALUE == 3);\n')
wrapper = write('SuperUnity.UBT.fixture.cpp',
    '// Compiler-authored UBT unity membership; copied into nvim cache.\n#include "'+source.as_posix()+'"\n')
entry = {'file':str(wrapper), 'directory':str(root),
    'arguments':[str(compiler), '-std=c++17', '-nostdinc', '-c', str(wrapper)],
    'nvim_ue_members':[module.portable_member_path(str(source))]}
flags = subprocess.CREATE_NO_WINDOW | subprocess.IDLE_PRIORITY_CLASS
def compile(entry, name):
    argv = [a for a in entry['arguments'] if a != '-c'] + ['-fsyntax-only']
    result = subprocess.run(argv, capture_output=True, creationflags=flags, timeout=30)
    (root/(name+'.stderr.log')).write_bytes(result.stderr)
    return result
assert compile(entry, 'live').returncode == 0
# This fixture supplies its complete, explicit dependency set to the freeze
# builder; it tests lookup, not authorization by a fabricated index graph.
candidate, dependencies, identity = module._freeze([entry], [{p.as_uri():{} for p in files}], root/'assets', 'fixture')
before = compile(candidate, 'closed-before')
assert before.returncode != 0 and b'file not found' in before.stderr, before.stderr
proof = collect_aliases([entry], module._libclang(pathlib.Path(clangd)))
assert proof['ok'], proof
ordinary = next(r for r in proof['evidence']['include_records'] if r['including'].endswith('Right/Sub/Entry.h'))
assert 'alias' not in ordinary, 'ordinary parent lookup needs its directory even without a file alias'
parents = {pathlib.Path(p['target']) for p in proof['directory_aliases']}
assert left_entry.parent in parents and right_entry.parent in parents, proof
fixed = module._alias_overlay([entry], candidate, root, root/'assets', clangd, 60)
closed = module._candidate_overlays(fixed)[0][1]
assert closed['fallthrough'] is False
assert all(item['type']=='file' for item in closed['roots'])
# A read of live bytes, or confusion between the two X.h files, now fails.
left.write_text('#define LEFT_VALUE 99\n')
right.write_text('#define RIGHT_VALUE 99\n')
after = compile(fixed, 'closed-after')
assert after.returncode == 0, after.stderr
for index, (spelling, create_live) in enumerate((('../Unfrozen.h', True), ('../../Missing.h', False))):
    if create_live:
        unmapped = left_entry.parent.parent/'Unfrozen.h'
        unmapped.write_text('#define UNFROZEN_VALUE 1\n')
    frozen_entry = next(p for p in dependencies if pathlib.Path(p['path']) == left_entry)
    pathlib.Path(frozen_entry['snapshot']).write_text('#include "'+spelling+'"\n')
    denied = compile(fixed, 'denied-'+str(index))
    assert denied.returncode != 0 and b'file not found' in denied.stderr, denied.stderr
    if create_live:
        assert unmapped.is_file(), 'the denial must not depend on a missing live file'
print(json.dumps({'root':str(root), 'ordinary_aliases':proof['aliases'],
    'directory_aliases':proof['directory_aliases'], 'closed_after_exit':after.returncode,
    'same_name_and_multi_level':True, 'unfrozen_and_missing_rejected':True}))
]=]

t.describe("frozen including-directory lookup", function()
  local discovered = require("utils.ue_goto.semantic_sidecar_libclang").discover_toolchain()
  local python = vim.fn.exepath("python")
  if not discovered.ok or python == "" or vim.fn.has("win32") ~= 1 then
    t.skip("native frozen relative includes", discovered.reason or "Windows Python unavailable", { native = true })
    return
  end
  t.it("preserves parent lookup and same-name headers while rejecting unfrozen and missing paths", function()
    local script = vim.fn.tempname() .. "_frozen_relative.py"
    vim.fn.writefile(vim.split(fixture, "\n", { plain = true }), script)
    local result = vim.system({ python, "-B", "-I", script,
      vim.fn.stdpath("config") .. "/tools/cdb_verified_batch.py", discovered.clangd_path }, { text = true }):wait()
    t.assert_eq(result.code, 0, (result.stderr or "") .. (result.stdout or ""))
  end)
end)
