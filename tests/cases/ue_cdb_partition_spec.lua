local t = require("tests.harness")
t.bootstrap()

local function python_test(body)
  local python = require("utils.platform").resolve_tool({ name = "python",
    driver_candidates = function(driver) return driver.python_candidates() end })
  t.assert_true(python.ok, python.error)
  local path = vim.fn.tempname() .. ".py"
  local file = assert(io.open(path, "wb"))
  file:write([=[
import copy, json, pathlib, sys, tempfile
from unittest.mock import patch
sys.path.insert(0, str(pathlib.Path(sys.argv[1]) / 'tools'))
import cdb_partition as partition

def entry(flags, source='Project/Source/ThirdParty/fixture.c'):
    return {'directory': '/workspace', 'file': source, 'arguments': [
        'clang', '--target=aarch64-none-linux-android23', '-x', 'c',
        '-I', 'Project/Intermediate/Build/Android/Client/Inc/Fixture',
        *flags, '-c', source]}

def config(flags):
    row = entry(flags)
    before = copy.deepcopy(row)
    result = partition.classify(row)[2]
    assert row == before, 'classification modified the compiler command'
    return result
]=], body)
  file:close()
  local result = vim.system({ python.path, "-B", "-I", path, vim.fn.stdpath("config") }, { text = true }):wait(15000)
  os.remove(path)
  t.assert_eq(result.code, 0, result.stderr or result.stdout)
end

t.describe("CDB configuration partition", function()
  for _, source in ipairs({
    "Project/Plugins/KuroNetwork/Private/kcp/ikcp.c",
    "Project/Plugins/KuroNetwork/Private/kcp/kurocrc32.c",
    "Project/Plugins/KuroUtility/Private/minizip/ioapi.c",
    "Project/Plugins/KuroUtility/Private/minizip/zip.c",
    "Engine/Plugins/Runtime/Database/SQLiteCore/Private/SQLiteEmbedded.c",
  }) do
    t.it("keeps Test C source without a configuration path: " .. vim.fs.basename(source), function()
      python_test("row = entry(['-D', 'UE_BUILD_TEST=1'], " .. string.format("%q", source) .. ")\n"
        .. "before = copy.deepcopy(row)\n"
        .. "assert partition.classify(row) == ('Android', 'Client', 'Test')\n"
        .. "assert row == before\n")
    end)
  end

  t.it("uses effective ordered standalone and joined macro values", function()
    python_test([=[
for flags in (
    ['-DUE_BUILD_TEST=1'], ['-D', 'UE_BUILD_TEST=1'], ['-DUE_BUILD_TEST'],
    ['-DUE_BUILD_TEST=0', '-D', 'UE_BUILD_TEST=1'],
    ['-DUE_BUILD_TEST=1', '-UUE_BUILD_TEST', '-DUE_BUILD_TEST=1'],
    ['-DUE_BUILD_SHIPPING=1', '-U', 'UE_BUILD_SHIPPING', '-DUE_BUILD_TEST=1'],
    ['-DUE_BUILD_TEST=(1)', '-UUE_BUILD_TEST', '-DUE_BUILD_TEST=1'],
):
    assert config(flags) == 'Test', flags
for flags in (
    [], ['-DUE_BUILD_TEST=0'], ['-DUE_BUILD_TEST=1', '-DUE_BUILD_TEST=0'],
    ['-DUE_BUILD_TEST=1', '-UUE_BUILD_TEST'], ['-DUE_BUILD_TEST=1', '-U', 'UE_BUILD_TEST'],
):
    assert config(flags) is None, flags
assert config(['-DUE_BUILD_DEBUG=1', '-DUE_BUILD_TEST=0']) == 'Debug'
assert config(['-D', 'UE_BUILD_SHIPPING=1']) == 'Shipping'
]=])
  end)

  t.it("leaves ambiguous, conflicting and indirect macro values unknown", function()
    python_test([=[
for flags in (
    ['-DUE_BUILD_DEVELOPMENT=1'], ['-DUE_BUILD_DEBUGGAME=1'],
    ['-DUE_BUILD_TEST=1', '-DUE_BUILD_SHIPPING=1'],
    ['-DUE_BUILD_TEST=1', '-DUE_BUILD_DEVELOPMENT=1'],
    ['-DUE_BUILD_TEST=1', '-DUE_BUILD_DEBUGGAME=1'],
    ['-DUE_BUILD_TEST='], ['-DUE_BUILD_TEST=(1)'], ['-DUE_BUILD_TEST=OTHER'],
    ['-DUE_BUILD_TEST=1', '-DUE_BUILD_SHIPPING=OTHER'],
    ['-DUE_BUILD_TEST=1', '-D'], ['-DUE_BUILD_TEST=1', '-U'],
    ['-DUE_BUILD_TEST=1', '@extra.rsp'],
    ['-DUE_BUILD_TEST=1', '-Wp,-UUE_BUILD_TEST'],
    ['-DUE_BUILD_TEST=1', '-Xclang', '-UUE_BUILD_TEST'],
    ['--', '-DUE_BUILD_TEST=1'],
):
    assert config(flags) is None, flags
]=])
  end)

  t.it("preserves explicit path classification and command provenance", function()
    python_test([=[
row = entry(['-DUE_BUILD_DEVELOPMENT=1', '-include',
    'Project/Intermediate/Build/Android/Client/DebugGame/Fixture/Definitions.Fixture.h'])
before = copy.deepcopy(row)
assert partition.classify(row) == ('Android', 'Client', 'DebugGame')
assert row == before
row = {'directory':'/workspace', 'file':'fixture.c', 'command_syntax':'posix',
    'command':"clang --target=aarch64-none-linux-android23 -D 'UE_BUILD_TEST=1' -c fixture.c"}
before = copy.deepcopy(row)
assert partition.classify(row) == ('Android', None, 'Test')
assert row == before
]=])
  end)

  t.it("selects all five Test C fixtures without copying other configurations or changing commands", function()
    python_test([=[
with tempfile.TemporaryDirectory(prefix='ue-partition-') as folder:
    root = pathlib.Path(folder)
    selected = [entry(['-D', 'UE_BUILD_TEST=1'], name) for name in
        ('ikcp.c', 'kurocrc32.c', 'ioapi.c', 'zip.c', 'SQLiteEmbedded.c')]
    other = entry(['-DUE_BUILD_SHIPPING=1'], 'Shipping.c')
    unknown = entry(['-DUE_BUILD_DEVELOPMENT=1'], 'Ambiguous.c')
    cdb = root/'compile_commands.json'
    cdb.write_text(json.dumps([*selected, other, unknown]), encoding='utf-8')
    with patch.object(sys, 'argv', ['cdb_partition.py', str(cdb), '--active', 'Android/Test', '--quiet']):
        assert partition.main() == 0
    assert json.loads(cdb.read_text(encoding='utf-8')) == selected
    shards = root/'.cache/nvim-ue/cdb/active'
    assert json.loads((shards/'compile_commands.Android-Shipping.json').read_text(encoding='utf-8')) == [other]
    assert json.loads((shards/'compile_commands.Android-unknown.json').read_text(encoding='utf-8')) == [unknown]
]=])
  end)
end)
