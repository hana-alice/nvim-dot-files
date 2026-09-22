local t = require("tests.harness")
t.bootstrap()

local fixture = [=[
import json, os, pathlib, stat, sys, tempfile
from unittest.mock import patch
sys.path.insert(0, str(pathlib.Path(sys.argv[1]).parent))
from cdb_verified_batch import _inventory as actual, _json, _sha
Path = pathlib.Path

# Preserve the pre-optimization behavior as the comparison oracle.
def reference(path, excluded):
    path = Path(path)
    if not path.is_dir():
        return {'exists': False, 'sha256': None}
    records, pending, visited = [], [path], set()
    while pending:
        directory = pending.pop()
        resolved = directory.resolve()
        if resolved == excluded or excluded in resolved.parents or resolved in visited:
            continue
        visited.add(resolved)
        with os.scandir(directory) as iterator:
            for item in sorted(iterator, key=lambda item: item.name):
                child = Path(item.path)
                if child == excluded or excluded in child.parents:
                    continue
                kind = 'directory' if item.is_dir() else 'file'
                link = os.readlink(child) if item.is_symlink() else ''
                records.append((str(child.relative_to(path)), kind, link))
                if item.is_dir():
                    pending.append(child)
    return {'exists': True, 'sha256': _sha(_json(sorted(records)).encode())}

def outcome(function, root, excluded):
    try:
        return {'value': function(root, excluded)}
    except OSError as error:
        return {'exception': type(error).__name__, 'errno': error.errno,
                'winerror': getattr(error, 'winerror', None)}

results, links = [], []
with tempfile.TemporaryDirectory(prefix='index_inventory_') as temporary:
    base = Path(temporary).resolve()
    assert base.parent == Path(tempfile.gettempdir()).resolve()
    tree, excluded = base / 'MixedRoot', base / 'MixedRoot/Excluded'
    (tree / 'MixedDir').mkdir(parents=True)
    (tree / 'MixedDir/Value.H').write_text('content')
    excluded.mkdir()
    (excluded / 'omitted.h').write_text('omitted')
    (tree / 'file.h').write_text('file')

    def compare(name, root=tree, omitted=excluded):
        expected, observed = outcome(reference, root, omitted), outcome(actual, root, omitted)
        assert observed == expected, (name, expected, observed)
        results.append({'name': name, 'equal': True})
        return observed

    try:
        initial = compare('preserves ordinary records and excluded subtrees')
        (tree / 'new.h').write_text('new')
        assert compare('detects new directory entries') != initial
        (tree / 'new.h').unlink()
        assert compare('restores the digest after directory entry removal') == initial
        (tree / 'MixedDir/Value.H').rename(tree / 'MixedDir/value.h')
        assert compare('preserves case-only rename sensitivity') != initial
        compare('preserves missing roots', base / 'missing')
        compare('preserves non-directory roots', tree / 'file.h')
        compare('preserves exclusion of the root itself', excluded)
        compare('preserves relative-root behavior', Path(os.path.relpath(tree, Path.cwd())))
        for name in ('\u0130', 'i\u0307'):
            (tree / name).mkdir()
            (tree / name / (name + '.h')).write_text(name)
        compare('uses Path-compatible Unicode case identity')
        try:
            for name, target, directory in [('file-link.h', tree / 'file.h', False),
                ('directory-link', tree / 'MixedDir', True), ('cycle-link', tree, True),
                ('excluded-link', excluded, True), ('broken-link', tree / 'absent', False)]:
                link = tree / name
                os.symlink(target, link, target_is_directory=directory)
                links.append((link, False))
        except OSError as error:
            results.append({'name': 'native symbolic-link inventory', 'skip': str(error), 'native': True})
        else:
            compare('preserves real file, directory, broken, cyclic and excluded symlinks')
            compare('preserves a symbolic-link root', tree / 'directory-link')
        if os.name == 'nt':
            import _winapi
            for name, target in [('directory-junction', tree / 'MixedDir'), ('cycle-junction', tree),
                                  ('excluded-junction', excluded)]:
                link = tree / name
                _winapi.CreateJunction(str(target), str(link))
                links.append((link, True))
                assert os.lstat(link).st_file_attributes & stat.FILE_ATTRIBUTE_REPARSE_POINT
            compare('preserves real Windows junctions, cycles and excluded targets')
            compare('preserves a Windows junction root', tree / 'directory-junction')
        else:
            results.append({'name': 'Windows junction inventory', 'skip': 'Windows junction semantics unavailable'})
        original_scan, failures = os.scandir, []
        for number, function in enumerate((reference, actual)):
            local = base / ('vanished-' + str(number))
            victim = local / 'victim'
            victim.mkdir(parents=True)
            class DisappearingScan:
                def __init__(self, path):
                    self.path, self.iterator = Path(path), original_scan(path)
                def __enter__(self):
                    return self.iterator
                def __exit__(self, *args):
                    self.iterator.close()
                    if self.path == local:
                        victim.rmdir()
            with patch.object(os, 'scandir', DisappearingScan):
                failures.append(outcome(function, local, excluded))
        assert failures[0] == failures[1] and failures[0]['exception'] == 'FileNotFoundError', failures
        results.append({'name': 'preserves native errors when a child disappears after enumeration', 'equal': True})
        failures = []
        for function in (reference, actual):
            with patch.object(os, 'scandir', side_effect=PermissionError(13, 'fixture denied')):
                failures.append(outcome(function, tree, excluded))
        assert failures[0] == failures[1] and failures[0]['exception'] == 'PermissionError', failures
        results.append({'name': 'propagates inventory permission errors', 'equal': True})
    finally:
        # Remove only owned link entries before TemporaryDirectory cleans its
        # verified temporary root; never recurse through a link or junction.
        for link, junction in reversed(links):
            assert link.parent == tree
            if junction:
                os.rmdir(link)
            else:
                link.unlink()
        assert base.resolve().parent == Path(tempfile.gettempdir()).resolve()
print(json.dumps(results))
]=]

t.describe("verified batch include inventory", function()
  local python = vim.fn.exepath("python")
  if python == "" then python = vim.fn.exepath("python3") end
  if python == "" then
    t.skip("inventory behavior fixture", "Python unavailable", { native = true })
    return
  end
  local script = vim.fn.tempname() .. "_index_inventory.py"
  local stream = assert(io.open(script, "wb"))
  stream:write(fixture)
  stream:close()
  local result = vim.system({ python, "-B", "-I", script,
    vim.fn.stdpath("config") .. "/tools/cdb_verified_batch.py" }, { text = true }):wait()
  pcall(vim.fn.delete, script)
  if result.code ~= 0 then
    t.it("runs the complete inventory comparison fixture", function()
      t.assert_eq(result.code, 0, (result.stderr or "") .. (result.stdout or ""))
    end)
    return
  end
  for _, check in ipairs(vim.json.decode(result.stdout)) do
    if check.skip then
      t.skip(check.name, check.skip, { native = check.native })
    else
      t.it(check.name, function() t.assert_eq(check.equal, true) end)
    end
  end
end)
