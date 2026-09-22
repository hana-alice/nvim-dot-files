local t = require("tests.harness")
t.bootstrap()

local tool = vim.fn.stdpath("config") .. "/tools/clangd_index_graph.py"

local fixture = [=[
import copy, importlib.util, pathlib, struct, sys, tempfile, zlib
spec = importlib.util.spec_from_file_location('graph', sys.argv[1])
graph = importlib.util.module_from_spec(spec)
spec.loader.exec_module(graph)
operation = sys.argv[2]
u32 = lambda value: struct.pack('<I', value)
def var(value):
    result = bytearray()
    while value > 127:
        result.append((value & 127) | 128)
        value >>= 7
    return bytes(result + bytes([value]))

A, H, W = 'file:///fixture/A.cpp', 'file:///fixture/Header.h', 'file:///fixture/Batch.cpp'
strings = ['', A, H, 'name', 'scope::', '<int>', '(int n)', '(${1:n})', 'doc text',
           'int', 'int(int)', '"Header.h"', '/fixture', 'clang++', '-std=c++20', '/fixture/A.cpp']
SID, OTHER, CONTAINER = bytes.fromhex('0102030405060708'), b'other-id', b'encloser'
def location(uri, row):
    return var(uri) + var(row) + var(130) + var(row) + var(135)
def symbol(sid):
    # Independent wire fixture in Serialization.cpp writeSymbol order.
    return (sid + bytes([12, 1]) + var(3) + var(4) + var(5)
            + location(1, 257) + location(2, 5) + var(129) + bytes([3])
            + var(6) + var(7) + var(8) + var(9) + var(10)
            + var(2) + var(11) + var((131 << 2) | 3) + var(2) + var((7 << 2) | 1))
def chunks(compressed=False):
    table = b''.join(value.encode() + b'\0' for value in strings)
    return [(b'meta', u32(20)),
            (b'stri', u32(len(table)) + zlib.compress(table) if compressed else u32(0) + table),
            (b'symb', symbol(SID) + symbol(OTHER)),
            (b'refs', SID + var(2) + bytes([4]) + location(1, 6) + CONTAINER
             + bytes([5]) + location(1, 7) + OTHER),
            (b'rela', SID + bytes([0]) + OTHER),
            (b'srcs', bytes([1]) + var(1) + b'12345678' + var(1) + var(2)
             + bytes([0]) + var(2) + b'\0' * 8 + var(0)),
            (b'cmdl', var(12) + var(3) + var(13) + var(14) + var(15))]
def pack(sections):
    body = b'CdIx' + b''.join(tag + u32(len(data)) + data + (b'\0' if len(data) & 1 else b'')
                             for tag, data in sections)
    return b'RIFF' + u32(len(body)) + body
def replace(sections, tag, data):
    return [(key, data if key == tag else value) for key, value in sections]
def rejected(callback):
    try:
        callback()
    except ValueError:
        return
    raise AssertionError('invalid index/graph was accepted')

with tempfile.TemporaryDirectory(prefix='clangd_graph_') as root:
    path = pathlib.Path(root) / 'fixture.idx'
    def read(data):
        path.write_bytes(data)
        return graph.read_shard(path)
    base = read(pack(chunks()))
    if operation == 'fields':
        assert base['version'] == 20
        assert base['symbols'][0] == {
            'id': SID.hex(), 'kind': 12, 'language': 1, 'name': 'name', 'scope': 'scope::',
            'template_specialization_args': '<int>',
            'definition': {'uri': A, 'start': [257, 130], 'end': [257, 135]},
            'canonical_declaration': {'uri': H, 'start': [5, 130], 'end': [5, 135]},
            'references': 129, 'flags': 3, 'signature': '(int n)',
            'completion_snippet_suffix': '(${1:n})', 'documentation': 'doc text',
            'return_type': 'int', 'type': 'int(int)', 'include_headers': [
                {'header': '"Header.h"', 'references': 131, 'supported_directives': 3},
                {'header': H, 'references': 7, 'supported_directives': 1}]}
        assert base['refs'] == [
            {'symbol_id': SID.hex(), 'kind': 4, 'container': CONTAINER.hex(),
             'location': {'uri': A, 'start': [6, 130], 'end': [6, 135]}},
            {'symbol_id': SID.hex(), 'kind': 5, 'container': OTHER.hex(),
             'location': {'uri': A, 'start': [7, 130], 'end': [7, 135]}}]
        assert base['relations'] == [{'subject': SID.hex(), 'predicate': 0, 'object': OTHER.hex()}]
        assert base['sources'] == {
            A: {'flags': 1, 'digest': b'12345678'.hex(), 'direct_includes': [H]},
            H: {'flags': 0, 'digest': '0000000000000000', 'direct_includes': []}}
        assert base['command'] == {'directory': '/fixture',
                                   'arguments': ['clang++', '-std=c++20', '/fixture/A.cpp']}
    elif operation == 'compressed':
        assert read(pack(list(reversed(chunks(True))))) == base
    elif operation == 'truncated':
        complete = pack(chunks(True))
        for length in range(len(complete)):
            rejected(lambda: read(complete[:length]))
        for section in (b'symb', b'refs', b'rela', b'srcs', b'cmdl'):
            data = dict(chunks())[section]
            rejected(lambda: read(pack(replace(chunks(), section, data[:-1]))))
    elif operation == 'version_chunks':
        rejected(lambda: read(pack(replace(chunks(), b'meta', u32(19)))))
        rejected(lambda: read(pack(chunks() + [(b'rela', b'')])) )
        rejected(lambda: read(pack(chunks() + [(b'new!', b'')])) )
        for section in (b'meta', b'stri', b'symb', b'refs', b'rela', b'srcs'):
            rejected(lambda: read(pack([(key, data) for key, data in chunks() if key != section])))
        assert read(pack([(key, data) for key, data in chunks() if key != b'cmdl']))['command'] is None
        rejected(lambda: read(pack(chunks()) + b'extra'))
        bad = pack(chunks()).replace(b'CdIx', b'nope', 1)
        rejected(lambda: read(bad))
    elif operation == 'bad_strings':
        data = dict(chunks())[b'symb']
        rejected(lambda: read(pack(replace(chunks(), b'symb', data[:10] + var(999) + data[11:]))))
        rejected(lambda: read(pack(replace(chunks(), b'symb', data[:10] + b'\xff' * 5 + data[11:]))))
        rejected(lambda: read(pack(replace(chunks(), b'stri', u32(0) + b'unterminated'))))
        rejected(lambda: read(pack(replace(chunks(), b'stri', u32(20) + b'bad zlib'))))
        rejected(lambda: read(pack(replace(chunks(), b'stri', u32(20) + zlib.compress(b'x\0')))))
        rejected(lambda: read(pack(replace(chunks(), b'stri', u32(2) + zlib.compress(b'x\0') + b'junk'))))
        rejected(lambda: read(pack(replace(chunks(), b'cmdl', dict(chunks())[b'cmdl'] + b'\0'))))
    elif operation == 'order':
        base['sources'][A]['direct_includes'] = [H, W]
        before = copy.deepcopy(base)
        reordered = copy.deepcopy(base)
        for key in ('symbols', 'refs', 'relations'):
            reordered[key].reverse()
        for sym in reordered['symbols']:
            sym['include_headers'].reverse()
        reordered['sources'][A]['direct_includes'].reverse()
        reordered['sources'] = dict(reversed(list(reordered['sources'].items())))
        assert graph.canonical_file_graph([reordered, base]) == graph.canonical_file_graph([base])
        assert before == base, 'canonicalization must not mutate caller records'
        assert list(graph.canonical_file_graph([base])) == [A], 'edge placeholder is not a real file'
    elif operation == 'symbol_changes':
        original = graph.canonical_file_graph([base])
        for field, replacement in [('id', OTHER.hex()), ('documentation', 'other docs'),
                                   ('type', 'double(int)'), ('flags', 1), ('references', 130)]:
            changed = copy.deepcopy(base)
            changed['symbols'][0][field] = replacement
            assert graph.canonical_file_graph([changed]) != original, field
        changed = copy.deepcopy(base)
        changed['symbols'][0]['canonical_declaration']['start'][0] += 1
        assert graph.canonical_file_graph([changed]) != original
    elif operation == 'ref_changes':
        original = graph.canonical_file_graph([base])
        for field, replacement in [('symbol_id', OTHER.hex()), ('container', SID.hex()), ('kind', 1)]:
            changed = copy.deepcopy(base)
            changed['refs'][0][field] = replacement
            assert graph.canonical_file_graph([changed]) != original, field
        changed = copy.deepcopy(base)
        changed['refs'][0]['location']['end'][1] += 1
        assert graph.canonical_file_graph([changed]) != original
        changed['refs'].append(copy.deepcopy(changed['refs'][0]))
        assert len(graph.canonical_file_graph([changed])[A]['refs']) == 3, 'multiplicity was lost'
    elif operation == 'relation_source_changes':
        original = graph.canonical_file_graph([base])
        for field, replacement in [('subject', OTHER.hex()), ('predicate', 1), ('object', SID.hex())]:
            changed = copy.deepcopy(base)
            changed['relations'][0][field] = replacement
            assert graph.canonical_file_graph([changed]) != original, field
        for field, replacement in [('flags', 0), ('flags', 3), ('digest', '1111111111111111'),
                                   ('direct_includes', []), ('direct_includes', [H, H])]:
            changed = copy.deepcopy(base)
            changed['sources'][A][field] = replacement
            assert graph.canonical_file_graph([changed]) != original, field
    elif operation == 'ignore':
        wrapper = {'version': 20, 'symbols': [], 'refs': [], 'relations': [], 'command': None,
                   'sources': {W: {'flags': 1, 'digest': '1212121212121212', 'direct_includes': [A]}}}
        assert graph.canonical_file_graph([base, wrapper], {W}) == graph.canonical_file_graph([base])
        for field in ('symbols', 'refs', 'relations'):
            changed = copy.deepcopy(base)
            for key in ('symbols', 'refs', 'relations'):
                if key != field:
                    changed[key] = []
            rejected(lambda: graph.canonical_file_graph([changed], {A}))
    elif operation == 'conflicts':
        changed = copy.deepcopy(base)
        changed['refs'][0]['symbol_id'] = OTHER.hex()
        rejected(lambda: graph.canonical_file_graph([base, changed]))
        changed = copy.deepcopy(base)
        changed['sources'][H]['digest'] = '1111111111111111'
        rejected(lambda: graph.canonical_file_graph([changed]))
        changed = copy.deepcopy(base)
        changed['sources'][A]['digest'] = '0000000000000000'
        rejected(lambda: graph.canonical_file_graph([changed]))
    elif operation == 'structural_keys':
        def leaves(value, path=()):
            if isinstance(value, dict):
                for key, item in value.items():
                    yield from leaves(item, path + (key,))
            elif isinstance(value, list):
                for index, item in enumerate(value):
                    yield from leaves(item, path + (index,))
            else:
                yield path, value
        for field in ('symbols', 'refs', 'relations'):
            record = base[field][0]
            key = graph._record_key(record)
            assert key == graph._record_key(dict(reversed(list(record.items()))))
            for path_, value in leaves(record):
                changed = copy.deepcopy(record)
                parent = changed
                for part in path_[:-1]:
                    parent = parent[part]
                parent[path_[-1]] = value + 1 if isinstance(value, int) else value + '\\"非ASCII'
                assert key != graph._record_key(changed), (field, path_)
            changed = dict(record, extra_field='must not be omitted')
            assert key != graph._record_key(changed)
        first = copy.deepcopy(base['refs'][0])
        second = copy.deepcopy(first)
        first['location']['start'][0] = first['location']['end'][0] = 2
        second['location']['start'][0] = second['location']['end'][0] = 10
        base['refs'] = [second, first]
        assert [r['location']['start'][0] for r in graph.canonical_file_graph([base])[A]['refs']] == [2, 10]
        second = copy.deepcopy(first)
        second['location']['start'], second['location']['end'] = [2], [130, 2, 135]
        assert graph._record_key(first) != graph._record_key(second), 'coordinate array boundaries lost'
    else:
        raise AssertionError(operation)
print('ok')
]=]

local function run_case(operation)
  local root = vim.fn.tempname():gsub("\\", "/") .. "_index_graph"
  vim.fn.mkdir(root, "p")
  local script = root .. "/probe.py"
  local file = assert(io.open(script, "wb"))
  file:write(fixture)
  file:close()
  local executable = vim.fn.exepath("python")
  if executable == "" then executable = vim.fn.exepath("python3") end
  local command = executable ~= "" and { executable, "-I", script } or { "py", "-3", "-I", script }
  vim.list_extend(command, { tool, operation })
  local ok, result = pcall(function() return vim.system(command, { text = true }):wait() end)
  vim.fn.delete(root, "rf")
  t.assert_true(ok, tostring(result))
  t.assert_eq(result.code, 0, result.stderr or result.stdout)
  t.assert_eq(vim.trim(result.stdout), "ok")
end

t.describe("clangd RIFF file graph", function()
  for _, case in ipairs({
    { "decodes every v20 record field and multi-byte varints", "fields" },
    { "accepts compressed strings and arbitrary chunk ordering", "compressed" },
    { "rejects truncated containers and individual record sections", "truncated" },
    { "rejects wrong versions, unknown/duplicate chunks and trailing data", "version_chunks" },
    { "rejects invalid string references, varints and compressed streams", "bad_strings" },
    { "normalizes record order without mutating or inventing files", "order" },
    { "preserves symbol identity, docs, types, flags and locations", "symbol_changes" },
    { "distinguishes reference targets, containers, roles and ranges", "ref_changes" },
    { "distinguishes relations, include edges, digests and source flags", "relation_source_changes" },
    { "allows ignoring empty wrappers and refuses nonempty graphs", "ignore" },
    { "refuses conflicting duplicate shards and ambiguous own nodes", "conflicts" },
    { "keeps every record field in structural keys and orders coordinates deterministically", "structural_keys" },
  }) do
    t.it(case[1], function() run_case(case[2]) end)
  end
end)
