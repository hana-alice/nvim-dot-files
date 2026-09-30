local t = require("tests.harness")
t.bootstrap()

local function write(path, content)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local handle = assert(io.open(path, "wb"))
  handle:write(content)
  handle:close()
end

local function json(path)
  local handle = assert(io.open(path, "rb"))
  local value = vim.json.decode(handle:read("*a"))
  handle:close()
  return value
end

local discovery = require("utils.ue_goto.semantic_sidecar")._discover_toolchain_for_test()
local python = vim.fn.exepath("python")
if python == "" then python = vim.fn.exepath("python3") end
local fd = vim.fn.exepath("fd")
if fd == "" then fd = vim.fn.exepath("fdfind") end
local suffix = vim.fn.has("win32") == 1 and ".exe" or ""
local clang = discovery.clangd_path and (vim.fs.dirname(discovery.clangd_path) .. "/clang++" .. suffix) or ""

t.describe("RSP compiler macros and UCLASS event parameters", function()
  if not discovery.ok or python == "" or fd == "" or vim.fn.executable(clang) ~= 1 then
    t.skip("real RSP producer and native UCLASS fixture", "clang, Python, or fd unavailable", { native = true })
    return
  end

  local function fixture(explicit, body)
    local root = vim.fs.normalize(vim.fn.tempname() .. "_rsp_uclass")
    vim.fn.mkdir(root, "p")
    root = vim.fs.normalize(vim.uv.fs_realpath(root) or root)
    local ok, err = xpcall(function()
      local dir = root .. "/Engine/Source/Demo"
      local build = root .. "/Engine/Intermediate/Build/Android/Fixture/Development/Demo"
      write(root .. "/Engine/Source/Fixture.Target.cs", "// Native regression target.\n")
      write(dir .. "/ObjectMacros.h", [[#define BODY_INNER(A,B,C,D) A##B##C##D
#define BODY_COMBINE(A,B,C,D) BODY_INNER(A,B,C,D)
#if defined(__INTELLISENSE__)
#define UCLASS(...)
#else
#define UCLASS(...) BODY_COMBINE(CURRENT_FILE_ID,_,__LINE__,_PROLOG)
#endif
]])
      write(dir .. "/Fixture.generated.h", [[#define CURRENT_FILE_ID Fixture_h
#define Fixture_h_4_PROLOG Fixture_h_7_EVENT_PARMS
#define Fixture_h_7_EVENT_PARMS struct Fixture_eventFire_Parms { int value; };
]])
      write(dir .. "/Fixture.h", '#include "ObjectMacros.h"\n#include "Fixture.generated.h"\n\n'
        .. 'UCLASS()\nclass Fixture { public: void Fire(int); };\n')
      local member = dir .. "/Fixture.gen.cpp"
      write(member, '#include "Fixture.h"\n#if KEEP_ORIGINAL != 37\n#error lost explicit RSP macro\n#endif\n'
        .. 'void Fixture::Fire(int value) { Fixture_eventFire_Parms parms{value}; (void)parms; }\n')
      local wrapper = build .. "/Module.Demo.cpp"
      write(wrapper, '#include "' .. member .. '"\n')
      write(build .. "/Module.Demo.cppa8.o.rsp", '-std=c++17\n-DKEEP_ORIGINAL=37\n-c\n'
        .. (explicit and '-D__INTELLISENSE__\n' or '')
        .. '"' .. wrapper .. '"\n-o "' .. root .. '/must-not-write.o"\n')
      local ctx = { engine_root = root,
        state = { target_platform = "Android", target_configuration = "Development", target = "Fixture" },
        paths = { active_cdb = root .. "/cache/compile_commands.json", cdb_shards_dir = root .. "/cache/shards",
          index_cdb_dir = root .. "/cache/index" },
      }
      local generated, path = require("ue")._ccjson_subprocess_run(ctx, function() end)
      t.assert_true(generated, path)
      t.assert_eq(path, ctx.paths.active_cdb)
      local entries = json(path)
      local entry
      for _, candidate in ipairs(entries) do
        if vim.fs.normalize(candidate.file) == member then entry = candidate end
      end
      t.assert_true(entry ~= nil, "real RSP generator did not emit the Unity member")
      local count = 0
      for _, argument in ipairs(entry.arguments) do
        if argument == "-D__INTELLISENSE__" then count = count + 1 end
      end
      local function compile()
        write(root .. "/native-request.json", vim.json.encode({ entry = entry, clang = clang }))
        write(root .. "/native.py", [=[import json, os, subprocess, sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
from build_hot_super_unity_cdb import strip_write_only_flags
request = json.loads(Path(sys.argv[2]).read_text(encoding='utf-8'))
entry = request['entry']
argv = [request['clang']] + [a for a in strip_write_only_flags(entry['arguments'][1:]) if a != '-c'] + ['-fsyntax-only']
flags = subprocess.CREATE_NO_WINDOW | subprocess.IDLE_PRIORITY_CLASS if os.name == 'nt' else 0
run = subprocess.run(argv, cwd=entry['directory'], capture_output=True, timeout=20, creationflags=flags)
Path(sys.argv[3]).write_text(json.dumps({'code': run.returncode, 'stderr': run.stderr.decode('utf-8', 'replace'), 'argv': argv}), encoding='utf-8')
]=])
        local result = vim.system({ python, "-I", root .. "/native.py", vim.fn.stdpath("config") .. "/tools",
          root .. "/native-request.json", root .. "/native-result.json" }, { text = true }):wait(25000)
        t.assert_eq(result.code, 0, result.stderr)
        return json(root .. "/native-result.json")
      end
      body(entry, count, compile, ctx)
      t.assert_eq(vim.fn.filereadable(root .. "/must-not-write.o"), 0)
    end, debug.traceback)
    vim.fn.delete(root, "rf")
    if not ok then error(err) end
  end

  t.it("does not invent IntelliSense mode when the RSP omits it", function()
    fixture(false, function(entry, count, _, ctx)
      t.assert_eq(count, 0, "RSP generation must not change UCLASS preprocessing")
      t.assert_true(vim.tbl_contains(entry.arguments, "-DKEEP_ORIGINAL=37"))
      local origin = json(ctx.paths.active_cdb .. ".unity-origin.json")
      t.assert_eq(#origin.groups, 1, "real generation must retain compiler-authored Unity provenance")
    end)
  end)

  t.it("native compilation retains UCLASS PROLOG and generated EVENT_PARMS", function()
    fixture(false, function(_, _, compile)
      local result = compile()
      t.assert_eq(result.code, 0, result.stderr)
    end)
  end)

  t.it("preserves an explicit user IntelliSense macro and reports its real compiler error", function()
    fixture(true, function(entry, count, compile)
      t.assert_eq(count, 1, "explicit RSP define must be retained once without automatic duplication")
      t.assert_true(vim.tbl_contains(entry.arguments, "-DKEEP_ORIGINAL=37"))
      local result = compile()
      t.assert_eq(result.code, 1)
      t.assert_contains(result.stderr, "unknown type name 'Fixture_eventFire_Parms'")
    end)
  end)
end)

t.describe("legacy Definitions macro injection", function()
  if not discovery.ok or python == "" or vim.fn.executable(clang) ~= 1 then
    t.skip("native empty macro replacement", "clang or Python unavailable", { native = true })
    return
  end

  local function check(mode)
    local root = vim.fs.normalize(vim.fn.tempname() .. "_definitions_macro")
    vim.fn.mkdir(root, "p")
    local ok, err = xpcall(function()
      write(root .. "/check.py", [=[import json, os, subprocess, sys
from pathlib import Path
root, tool, clang, mode = Path(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4]
header, source, cdb = root/'Definitions.Fixture.h', root/'fixture.cpp', root/'compile_commands.json'
header.write_text('''#define EMPTY_API
#define EMPTY_SPACES    
#define EMPTY_BLOCK /* empty replacement */
#define EMPTY_LINE // empty replacement
#define ONE 1
#define VALUE /* keep value */ 37 // trailing comment
#define REMOVE 1
#undef REMOVE
#define ORIGINAL_VALUE
''')
source.write_text('''#define STRING_INNER(value) #value
#define STRING(value) STRING_INNER(value)
#if !defined(EMPTY_API) || !defined(EMPTY_SPACES) || !defined(EMPTY_BLOCK) || !defined(EMPTY_LINE)
#error empty replacements must remain defined
#endif
static_assert(sizeof(STRING(EMPTY_API)) == 1);
static_assert(sizeof(STRING(EMPTY_SPACES)) == 1);
static_assert(sizeof(STRING(EMPTY_BLOCK)) == 1);
static_assert(sizeof(STRING(EMPTY_LINE)) == 1);
static_assert(ONE == 1 && VALUE == 37 && ORIGINAL_VALUE == 1);
#ifdef REMOVE
#error undef must remain unset
#endif
EMPTY_API void exported();
EMPTY_BLOCK void block_exported();
EMPTY_LINE void line_exported();
''')
original = [{'directory':str(root), 'file':str(source), 'arguments':[
    clang, '-std=c++17', '-DORIGINAL_VALUE', '-include', header.as_posix(), '-c', str(source)]}]
cdb.write_text(json.dumps(original, indent=2))
inputs = {path:path.read_bytes() for path in (header, source)}
flags = subprocess.CREATE_NO_WINDOW | subprocess.IDLE_PRIORITY_CLASS if os.name == 'nt' else 0
def inject():
    command = [sys.executable, '-B', '-I', tool, str(cdb)]
    if mode == 'exact': command.append('--preserve-exact')
    result = subprocess.run(command, capture_output=True, timeout=15, creationflags=flags)
    assert result.returncode == 0, result.stderr.decode('utf-8', 'replace')
before, stamp = cdb.read_bytes(), cdb.stat().st_mtime_ns
inject()
if mode == 'exact':
    assert cdb.read_bytes() == before and cdb.stat().st_mtime_ns == stamp
    assert json.loads(cdb.read_text()) == original
else:
    arguments = json.loads(cdb.read_text())[0]['arguments']
    command = [arg for arg in arguments if arg != '-c'] + ['-fsyntax-only']
    native = subprocess.run(command, cwd=root, capture_output=True, timeout=15, creationflags=flags)
    assert native.returncode == 0, native.stderr.decode('utf-8', 'replace')
    for name in ('EMPTY_API', 'EMPTY_SPACES', 'EMPTY_BLOCK', 'EMPTY_LINE'):
        assert '-D' + name + '=' in arguments and '-D' + name not in arguments
    assert '-DONE=1' in arguments and '-DVALUE=37' in arguments and '-UREMOVE' in arguments
    assert arguments.count('-DORIGINAL_VALUE') == 1 and '-DORIGINAL_VALUE=' not in arguments
    assert '-include' not in arguments
    before, stamp = cdb.read_bytes(), cdb.stat().st_mtime_ns
    inject()
    assert cdb.read_bytes() == before and cdb.stat().st_mtime_ns == stamp
assert all(path.read_bytes() == data for path, data in inputs.items())
print(json.dumps({'mode':mode, 'passed':True}))
]=])
      local result = vim.system({ python, "-B", "-I", root .. "/check.py", root,
        vim.fn.stdpath("config") .. "/tools/inject_definitions_to_cdb.py", clang, mode }, { text = true }):wait(40000)
      t.assert_eq(result.code, 0, (result.stderr or "") .. (result.stdout or ""))
    end, debug.traceback)
    vim.fn.delete(root, "rf")
    if not ok then error(err) end
  end

  t.it("compiles empty API replacements while retaining defined, explicit values and undef semantics", function()
    check("legacy")
  end)
  t.it("keeps preserve-exact argv, bytes and mtime unchanged", function()
    check("exact")
  end)
end)
