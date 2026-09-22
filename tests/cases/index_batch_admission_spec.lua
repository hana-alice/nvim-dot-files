local t = require("tests.harness")
t.bootstrap()

local tool = vim.fn.stdpath("config") .. "/tools/clangd_batch_admission.py"
local fixture = [=[
import copy, importlib.util, pathlib, sys
sys.path.insert(0, str(pathlib.Path(sys.argv[1]).parent))
spec = importlib.util.spec_from_file_location('admission', sys.argv[1])
admission = importlib.util.module_from_spec(spec)
spec.loader.exec_module(admission)
operation = sys.argv[2]
A, H, W = 'file:///A.cpp', 'file:///Header.h', 'file:///Batch.cpp'
SID, CID, ZERO = '0102030405060708', '0807060504030201', '0000000000000000'
def loc(uri, line):
    return {'uri': uri, 'start': [line, 2], 'end': [line, 5]}
empty = {'uri': '', 'start': [0, 0], 'end': [0, 0]}
symbol = {'id': SID, 'kind': 12, 'language': 1, 'name': 'run', 'scope': 'ns::',
          'template_specialization_args': '', 'definition': loc(A, 10),
          'canonical_declaration': loc(H, 2), 'references': 1, 'flags': 8,
          'signature': '()', 'completion_snippet_suffix': '()', 'documentation': '',
          'return_type': 'int', 'type': 'int()', 'include_headers': [
              {'header': '"Header.h"', 'references': 1, 'supported_directives': 1}]}
ref = {'symbol_id': SID, 'location': loc(A, 20), 'kind': 4, 'container': CID}
relation = {'subject': SID, 'predicate': 0, 'object': CID}
def entry(digest, includes=()):
    return {'symbols': [], 'refs': [], 'relations': [],
            'source': {'flags': 0, 'digest': digest, 'direct_includes': list(includes)}}
base = {A: entry('1111111111111111', [H]), H: entry('2222222222222222')}
base[A]['symbols'] = [copy.deepcopy(symbol)]
base[H]['symbols'] = [copy.deepcopy(symbol)]
base[A]['refs'] = [copy.deepcopy(ref)]
base[H]['refs'] = [{'symbol_id': SID, 'location': loc(H, 2), 'kind': 1, 'container': ZERO}]
base[A]['relations'] = [copy.deepcopy(relation)]

def compare(originals=None, candidate=None, **kwargs):
    return admission.compare_graphs(originals if originals is not None else [base],
                                    candidate if candidate is not None else copy.deepcopy(base), **kwargs)
def reject(candidate, reason=None, **kwargs):
    result = compare(candidate=candidate, **kwargs)
    assert result['accepted'] is False, result
    if reason:
        assert result['reason'] == reason, result
    return result

if operation == 'same':
    candidate = copy.deepcopy(base)
    candidate[A]['symbols'].append(copy.deepcopy(symbol))
    candidate[A]['refs'].append(copy.deepcopy(ref))
    candidate[A]['relations'].append(copy.deepcopy(relation))
    candidate[A]['source']['direct_includes'] = [H, H]
    candidate = dict(reversed(list(candidate.items())))
    assert compare([base, copy.deepcopy(base)], candidate)['accepted']
elif operation.startswith('template_'):
    original, candidate = copy.deepcopy(base), copy.deepcopy(base)
    for graph, text in ((original, '<3 - Base, Dummy>'), (candidate, '<9 - Base, Dummy>')):
        for node in graph.values():
            for sym in node['symbols']:
                sym['template_specialization_args'] = text
    absent = copy.deepcopy(original)
    for node in absent.values():
        node['symbols'] = []
    originals = [absent, original, copy.deepcopy(original)]
    snapshot = copy.deepcopy((originals, candidate))
    observed = []
    def proof(request):
        observed.append(copy.deepcopy(request))
        assert request['symbol_id'] == SID
        assert [item['index'] for item in request['originals']] == [1, 2]
        assert all(item['symbols'] == [original[A]['symbols'][0]] for item in request['originals'])
        assert request['candidate'] == [candidate[A]['symbols'][0]]
        # A callback must receive detached evidence, not writable graph nodes.
        request['candidate'][0]['name'] = 'callback-mutated'
        return True
    if operation == 'template_proof':
        pending = compare(originals, candidate)
        assert pending['reason'] == 'template-arguments-require-compiler-proof', pending
        assert len(pending['template_arguments']) == 1
        result = compare(originals, candidate, resolve_template_arguments=proof)
        assert result['accepted'] and len(observed) == 1, result
        assert (originals, candidate) == snapshot
        # Unchanged metadata never needs the new native proof.
        assert compare([original], original, resolve_template_arguments=lambda r: (_ for _ in ()).throw(AssertionError()))['accepted']
    elif operation == 'template_fail_closed':
        for answer in (False, None, 1, 'true'):
            result = compare(originals, candidate, resolve_template_arguments=lambda r: answer)
            assert not result['accepted'], result
        def unavailable(request):
            raise RuntimeError('native compiler unavailable')
        result = compare(originals, candidate, resolve_template_arguments=unavailable)
        assert result['reason'] == 'template-argument-proof-failed', result
    elif operation == 'template_other_gates':
        mutations = [
            lambda g: g[A]['refs'].clear(),
            lambda g: g[A]['refs'][0].update(symbol_id=CID),
            lambda g: g[A]['relations'].clear(),
            lambda g: g[A]['source'].update(digest='changed'),
            lambda g: [sym.update(name='changed') for n in g.values() for sym in n['symbols']],
            lambda g: [sym.update(type='double()') for n in g.values() for sym in n['symbols']],
            lambda g: [sym.update(definition=empty) for n in g.values() for sym in n['symbols']],
        ]
        for mutate in mutations:
            changed = copy.deepcopy(candidate)
            mutate(changed)
            calls = []
            result = compare(originals, changed, resolve_template_arguments=lambda request: calls.append(request) or True)
            assert not result['accepted'] and not calls, result
        extra = copy.deepcopy(candidate)
        extra[A]['refs'].append(dict(ref, location=loc(A, 99)))
        result = compare(originals, extra, resolve_template_arguments=lambda r: True)
        assert result['reason'] == 'added-references-require-original-proof', result
    else:
        raise AssertionError(operation)
elif operation == 'quality':
    candidate = copy.deepcopy(base)
    for entry_ in candidate.values():
        for sym in entry_['symbols']:
            sym['documentation'] = 'more useful documentation'
            sym['flags'] |= 16
            sym['references'] = 999
            sym['include_headers'][0]['references'] = 111
    assert compare(candidate=candidate)['accepted']
    incomplete = copy.deepcopy(base)
    for entry_ in incomplete.values():
        for sym in entry_['symbols']:
            sym['definition'] = copy.deepcopy(empty)
            sym['signature'] = sym['type'] = sym['return_type'] = sym['completion_snippet_suffix'] = ''
            sym['include_headers'] = []
    assert compare([incomplete, base], candidate)['accepted']
elif operation == 'retarget':
    for field, value in [('symbol_id', CID), ('kind', 8), ('container', ZERO)]:
        candidate = copy.deepcopy(base)
        candidate[A]['refs'][0][field] = value
        reject(candidate, 'references-removed-or-retargeted', resolve_original=lambda *args: True)
    candidate = copy.deepcopy(base)
    candidate[A]['refs'] = []
    reject(candidate, 'references-removed-or-retargeted')
elif operation == 'sources':
    candidate = copy.deepcopy(base)
    del candidate[H]
    reject(candidate, 'file-coverage-changed')
    for field, value in [('digest', '3333333333333333'), ('flags', 1), ('direct_includes', [])]:
        candidate = copy.deepcopy(base)
        candidate[A]['source'][field] = value
        reject(candidate, 'source-dependencies-changed')
    candidate = copy.deepcopy(base)
    candidate[A]['source']['flags'] = 2
    reject(candidate, 'invalid-original-or-candidate-graph')
elif operation == 'symbols':
    for field, value in [('type', 'double()'), ('signature', '(int)'), ('return_type', 'double'),
                         ('completion_snippet_suffix', '(${1:x})'), ('name', 'other'), ('scope', ''),
                         ('kind', 1), ('language', 0), ('template_specialization_args', '<int>'),
                         ('flags', 9), ('id', CID)]:
        candidate = copy.deepcopy(base)
        for entry_ in candidate.values():
            for sym in entry_['symbols']:
                sym[field] = value
        reject(candidate)
    candidate = copy.deepcopy(base)
    for entry_ in candidate.values():
        for sym in entry_['symbols']:
            sym['type'] = ''
    reject(candidate, 'symbol-completion-changed')
    candidate = copy.deepcopy(base)
    for entry_ in candidate.values():
        entry_['symbols'] = []
    reject(candidate, 'symbol-identities-changed')
elif operation == 'locations':
    for field in ('definition', 'canonical_declaration'):
        candidate = copy.deepcopy(base)
        for entry_ in candidate.values():
            for sym in entry_['symbols']:
                sym[field] = loc(H, 88)
        reject(candidate)
    original = copy.deepcopy(base)
    original[H]['refs'].append({'symbol_id': SID, 'location': loc(H, 88), 'kind': 1, 'container': ZERO})
    candidate = copy.deepcopy(original)
    for entry_ in candidate.values():
        for sym in entry_['symbols']:
            sym['canonical_declaration'] = loc(H, 88)
    assert compare([original], candidate)['accepted']
    for entry_ in candidate.values():
        for sym in entry_['symbols']:
            sym['definition'] = loc(H, 88)
    reject(candidate, 'symbol-definitions-changed', originals=[original])
elif operation == 'headers_relations':
    candidate = copy.deepcopy(base)
    candidate[A]['relations'].append({'subject': CID, 'predicate': 0, 'object': SID})
    reject(candidate, 'relations-changed')
    candidate[A]['relations'] = []
    reject(candidate, 'relations-changed')
    for field, value in [('header', '"Other.h"'), ('supported_directives', 3)]:
        candidate = copy.deepcopy(base)
        for entry_ in candidate.values():
            for sym in entry_['symbols']:
                sym['include_headers'][0][field] = value
        reject(candidate, 'symbol-include-headers-changed')
elif operation == 'added_refs':
    candidate = copy.deepcopy(base)
    friend = {'symbol_id': SID, 'location': loc(H, 30), 'kind': 9, 'container': ZERO}
    friend2 = dict(friend, location=loc(H, 40))
    candidate[H]['refs'].extend([friend, friend2])
    result = compare([base, copy.deepcopy(base)], candidate)
    assert result['reason'] == 'added-references-require-original-proof', result
    assert len(result['added_refs']) == 2
    assert all(ref_['original_graph_indices'] == [0, 1] for ref_ in result['added_refs'])
    calls = []
    def proof(uri, line, col, sid, indices):
        calls.append((uri, line, col, sid, indices))
        return all(index in {0, 1} for index in indices)
    assert compare([base, copy.deepcopy(base)], candidate, resolve_original=proof)['accepted']
    assert calls == [(H, 30, 2, SID, [0, 1]), (H, 40, 2, SID, [0, 1])]
    assert not compare([base, copy.deepcopy(base)], candidate,
                       resolve_original=lambda uri, line, col, sid, indices: all(i == 0 for i in indices))['accepted']
    assert not compare([base], candidate, resolve_original=lambda *args: 1)['accepted']
    def crash(*args):
        raise RuntimeError('compiler unavailable')
    assert compare([base], candidate, resolve_original=crash)['reason'] == 'original-reference-proof-failed'
elif operation == 'ignore_conflicts':
    candidate = copy.deepcopy(base)
    candidate[W] = entry('4444444444444444', [A])
    candidate[W]['source']['flags'] = 1
    assert compare(candidate=candidate, ignore_files={W})['accepted']
    candidate[W]['symbols'] = [copy.deepcopy(symbol)]
    reject(candidate, 'invalid-original-or-candidate-graph', ignore_files={W})
    conflicting = copy.deepcopy(base)
    conflicting[H]['source']['digest'] = '3333333333333333'
    assert compare([base, conflicting])['reason'] == 'invalid-original-or-candidate-graph'
    assert not compare([])['accepted']
    assert not admission.compare_graphs([{}], {})['accepted']
elif operation == 'context_indices':
    candidate = copy.deepcopy(base)
    extra = dict(ref, location=loc(A, 99))
    candidate[A]['refs'].append(extra)
    header_only = {H: copy.deepcopy(base[H])}
    result = compare([header_only, base], candidate)
    assert result['added_refs'][0]['original_graph_indices'] == [1]
elif operation == 'dependency_union':
    first, second = copy.deepcopy(base), copy.deepcopy(base)
    second[A]['source']['direct_includes'] = []
    assert compare([first, second])['accepted']
    candidate = copy.deepcopy(base)
    candidate[A]['source']['direct_includes'] = []
    reject(candidate, 'source-dependencies-changed', originals=[first, second])
    candidate[A]['source']['direct_includes'] = [H, W]
    reject(candidate, 'source-dependencies-changed', originals=[first, second])
elif operation == 'definition_language':
    forward, body = copy.deepcopy(base), copy.deepcopy(base)
    for entry_ in forward.values():
        for sym in entry_['symbols']:
            sym['language'] = 0
            sym['definition'] = copy.deepcopy(empty)
    for entry_ in body.values():
        for sym in entry_['symbols']:
            sym['language'] = 2
    assert compare([forward, body], copy.deepcopy(body))['accepted']
    assert compare([forward], copy.deepcopy(forward))['accepted']
    candidate = copy.deepcopy(body)
    for entry_ in candidate.values():
        for sym in entry_['symbols']:
            sym['language'] = 1
    reject(candidate, 'symbol-identity-fields-changed', originals=[forward, body])
    reject(copy.deepcopy(forward), 'symbol-identity-fields-changed', originals=[forward, body])
    candidate = copy.deepcopy(body)
    for entry_ in candidate.values():
        for sym in entry_['symbols']:
            sym['definition'] = copy.deepcopy(empty)
    reject(candidate, 'symbol-definitions-changed', originals=[forward, body])
elif operation == 'definition_headers':
    forward, body = copy.deepcopy(base), copy.deepcopy(base)
    for entry_ in forward.values():
        for sym in entry_['symbols']:
            sym['definition'] = copy.deepcopy(empty)
            sym['include_headers'] = [{'header': '"Forward.h"', 'references': 9, 'supported_directives': 1}]
    assert compare([forward, body], copy.deepcopy(body))['accepted']
    candidate = copy.deepcopy(body)
    for entry_ in candidate.values():
        for sym in entry_['symbols']:
            sym['include_headers'] = copy.deepcopy(forward[A]['symbols'][0]['include_headers'])
    reject(candidate, 'symbol-include-headers-changed', originals=[forward, body])
    for entry_ in forward.values():
        for sym in entry_['symbols']:
            sym['include_headers'].append({'header': '"Header.h"', 'references': 3, 'supported_directives': 2})
    candidate = copy.deepcopy(body)
    for entry_ in candidate.values():
        for sym in entry_['symbols']:
            sym['include_headers'][0]['supported_directives'] = 3
    assert compare([forward, body], candidate)['accepted']
    reject(copy.deepcopy(body), 'symbol-include-headers-changed', originals=[forward, body])
    for entry_ in candidate.values():
        for sym in entry_['symbols']:
            sym['include_headers'] = []
    reject(candidate, 'symbol-include-headers-changed', originals=[forward, body])
elif operation == 'provider_reachability':
    provider = 'file:///Provider.h'
    original = copy.deepcopy(base)
    original[provider] = entry('3333333333333333', [H])
    for entry_ in original.values():
        for sym in entry_['symbols']:
            sym['include_headers'][0]['header'] = H
    candidate = copy.deepcopy(original)
    for entry_ in candidate.values():
        for sym in entry_['symbols']:
            sym['include_headers'][0]['header'] = provider
    assert compare([original], candidate)['accepted']
    literal_original = copy.deepcopy(original)
    for entry_ in literal_original.values():
        for sym in entry_['symbols']:
            sym['include_headers'][0]['header'] = '"Header.h"'
    reject(candidate, 'symbol-include-headers-changed', originals=[literal_original])
    for header in ('file:///Unknown.h', A, '"Provider.h"', '<Provider.h>'):
        changed = copy.deepcopy(candidate)
        for entry_ in changed.values():
            for sym in entry_['symbols']:
                sym['include_headers'][0]['header'] = header
        reject(changed, 'symbol-include-headers-changed', originals=[original])
    original[provider]['source']['direct_includes'] = []
    candidate[provider]['source']['direct_includes'] = []
    reject(candidate, 'symbol-include-headers-changed', originals=[original])
elif operation == 'provider_body':
    provider, declaration, body = 'file:///Provider.h', 'file:///Decl.h', 'file:///Body.h'
    original = copy.deepcopy(base)
    original[provider] = entry('3333333333333333', [declaration])
    original[declaration] = entry('4444444444444444')
    original[body] = entry('5555555555555555')
    original[H]['source']['direct_includes'] = [declaration, body]
    for entry_ in original.values():
        for sym in entry_['symbols']:
            sym['canonical_declaration'] = loc(declaration, 2)
            sym['definition'] = loc(body, 4)
            sym['include_headers'][0]['header'] = H
    candidate = copy.deepcopy(original)
    for entry_ in candidate.values():
        for sym in entry_['symbols']:
            sym['include_headers'][0]['header'] = provider
    reject(candidate, 'symbol-include-headers-changed', originals=[original])
    original[provider]['source']['direct_includes'].append(body)
    candidate[provider]['source']['direct_includes'].append(body)
    assert compare([original], candidate)['accepted']
elif operation == 'provider_contexts':
    provider, middle = 'file:///Provider.h', 'file:///Middle.h'
    first = copy.deepcopy(base)
    first[provider] = entry('3333333333333333', [middle])
    first[middle] = entry('4444444444444444')
    for entry_ in first.values():
        for sym in entry_['symbols']:
            sym['include_headers'][0]['header'] = H
    second = copy.deepcopy(first)
    second[provider]['source']['direct_includes'] = []
    second[middle]['source']['direct_includes'] = [H]
    candidate = copy.deepcopy(first)
    candidate[middle]['source']['direct_includes'] = [H]
    for entry_ in candidate.values():
        for sym in entry_['symbols']:
            sym['include_headers'][0]['header'] = provider
    reject(candidate, 'symbol-include-headers-changed', originals=[first, second])
elif operation == 'provider_other_declarations':
    provider = 'file:///Provider.h'
    original = copy.deepcopy(base)
    original[provider] = entry('3333333333333333')
    original[provider]['refs'] = [{'symbol_id': SID, 'location': loc(provider, 8), 'kind': 9, 'container': ZERO}]
    for entry_ in original.values():
        for sym in entry_['symbols']:
            sym['include_headers'][0]['header'] = H
    candidate = copy.deepcopy(original)
    for entry_ in candidate.values():
        for sym in entry_['symbols']:
            sym['include_headers'][0]['header'] = provider
    assert compare([original], candidate)['accepted']
    for field, value in [('symbol_id', CID), ('kind', 12)]:
        changed_original, changed_candidate = copy.deepcopy(original), copy.deepcopy(candidate)
        changed_original[provider]['refs'][0][field] = value
        changed_candidate[provider]['refs'][0][field] = value
        reject(changed_candidate, 'symbol-include-headers-changed', originals=[changed_original])
    middle = 'file:///Middle.h'
    first, second = copy.deepcopy(original), copy.deepcopy(original)
    for graph in (first, second):
        graph[provider]['refs'] = []
        graph[middle] = entry('4444444444444444')
    first[provider]['source']['direct_includes'] = [middle]
    second[middle]['refs'] = [{'symbol_id': SID, 'location': loc(middle, 8), 'kind': 9, 'container': ZERO}]
    candidate = copy.deepcopy(first)
    candidate[middle]['refs'] = copy.deepcopy(second[middle]['refs'])
    for entry_ in candidate.values():
        for sym in entry_['symbols']:
            sym['include_headers'][0]['header'] = provider
    reject(candidate, 'symbol-include-headers-changed', originals=[first, second])
else:
    raise AssertionError(operation)
print('ok')
]=]

local function run_case(operation)
  local root = vim.fn.tempname():gsub("\\", "/") .. "_batch_admission"
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

t.describe("original TU batch admission", function()
  for _, case in ipairs({
    { "accepts identical sets, reordered graphs and duplicate quality records", "same" },
    { "requires typed compiler evidence for printed template arguments in every declaring TU", "template_proof" },
    { "rejects absent, non-boolean or failed template argument proof", "template_fail_closed" },
    { "never lets template proof bypass other graph gates or unnecessary compiler work", "template_other_gates" },
    { "allows documented quality changes and proven declaration/body enrichment", "quality" },
    { "rejects removed or silently retargeted references despite a positive callback", "retarget" },
    { "rejects missing files, changed dependencies and failed compilation graphs", "sources" },
    { "rejects changed identities, types, signatures and non-documentation flags", "symbols" },
    { "requires original evidence for new declaration or definition locations", "locations" },
    { "preserves relations and valid include suggestions", "headers_relations" },
    { "requires every original context to prove added friend references", "added_refs" },
    { "ignores only empty wrappers and rejects conflicting or absent baselines", "ignore_conflicts" },
    { "passes exactly the original TU indices containing the referenced file", "context_indices" },
    { "preserves the dependency union across original translation units", "dependency_union" },
    { "uses the proven definition language without allowing novel language or lost bodies", "definition_language" },
    { "mirrors definition-preferred header merging while preserving shared directives", "definition_headers" },
    { "admits changed URI providers only through a proven original include closure", "provider_reachability" },
    { "does not replace a body-exposing provider with a declaration-only header", "provider_body" },
    { "does not stitch a provider path from incompatible original TU graphs", "provider_contexts" },
    { "recognizes original noncanonical declarations but not other identities or uses", "provider_other_declarations" },
  }) do
    t.it(case[1], function() run_case(case[2]) end)
  end
end)
