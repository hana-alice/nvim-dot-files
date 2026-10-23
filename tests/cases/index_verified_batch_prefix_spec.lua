local t = require("tests.harness")
t.bootstrap()

local fixture = [=[
import copy, json, os, pathlib, subprocess, sys, tempfile
from unittest.mock import patch
tool, operation, clangd = sys.argv[1:]
sys.path.insert(0, str(pathlib.Path(tool).parent))
import cdb_verified_batch as module
import cdb_background_batch as background
os.environ['NVIM_UE_BATCH_TIER'] = 'strict'

def rejected(call, reason):
    try:
        call()
        raise AssertionError('expected rejection: '+reason)
    except ValueError as error:
        assert reason in str(error), str(error)

with tempfile.TemporaryDirectory(prefix='strict_prefix_') as temporary:
    root = pathlib.Path(temporary).resolve()
    source, store = root/'input', root/'store'
    source.mkdir(); store.mkdir()
    headers = [source/name for name in ('Order.h', 'Friend.h', 'Definitions.h')]
    headers[0].write_text('enum PrefixOuter { PrefixValue = 17 };\n'
        'static_assert(__COUNTER__ == 0, "first");\n'
        'static_assert(__INCLUDE_LEVEL__ == 1, "forced depth");\n#define PREFIX_STEP 1\n')
    headers[1].write_text('static_assert(PREFIX_STEP == 1 && __COUNTER__ == 1, "second");\n'
        'class PrefixObject;\ntemplate<class T> void PrefixFriend(const PrefixObject&);\n'
        'struct PrefixBase {};\nstruct PrefixDerived : PrefixBase {};\n'
        '#undef PREFIX_STEP\n#define PREFIX_STEP 2\n')
    headers[2].write_text('static_assert(PREFIX_STEP == 2 && __COUNTER__ == 2, "third");\n'
        'enum { PrefixCaptured = __COUNTER__ };\n')
    executable = pathlib.Path(clangd) if operation == 'native_public' else pathlib.Path(sys.executable)
    compiler = executable.with_name('clang++.exe' if os.name == 'nt' else 'clang++') if clangd else executable
    arguments = [str(compiler), '-std=c++17', '-nostdinc', '-nostdinc++', '-DPREFIX_KEEP=17', '-UPREFIX_OLD', '-c']
    arguments += [value for header in headers for value in ('-include', str(header))]
    group, members = [], []
    for index in range(2):
        member = source/('Member%d'%index + ('.gen.cpp' if index else '.cpp'))
        member.write_text('static_assert(PrefixCaptured == 3 && PREFIX_KEEP == 17, "stable order");\n'
            'int PrefixMember%d() { return PrefixValue; }\n'%index)
        wrapper = source/('SuperUnity.UBT.Prefix.%d.cpp'%index)
        wrapper.write_text('// Compiler-authored UBT unity membership; copied into nvim cache.\n'
            + '#include "'+member.as_posix()+'"\n')
        group.append(dict(directory=str(source), file=str(wrapper), arguments=arguments+[str(wrapper)],
            nvim_ue_module_root='Source/Prefix', nvim_ue_members=[module.portable_member_path(str(member))]))
        members.append(member)
    descriptor = dict(recipe='ordered-absolute-forced-prefix-v1', headers=list(map(str, headers)))
    graphs = [{path.as_uri(): dict(source=dict(digest='1234567890abcdef', flags=0, direct_includes=[]),
        symbols=[], refs=[], relations=[]) for path in headers+[members[index], pathlib.Path(entry['file'])]}
        for index, entry in enumerate(group)]
    original_bytes = {str(path):path.read_bytes() for path in source.iterdir()}

    def freeze(entries=group, native_graphs=graphs, target=store/'assets'):
        return module._freeze(entries, native_graphs, target, 'unit-tool-identity')

    if operation == 'constructor':
        original = copy.deepcopy(group)
        duplicate = copy.deepcopy(group)
        for entry in duplicate:
            entry['arguments'][7:7] = ['-include', str(headers[0])]
        repeated = dict(descriptor, headers=[str(headers[0])]+descriptor['headers'])
        assert module._strict_forced_prefix(duplicate) == (repeated, None)
        candidate, files, identity = freeze(duplicate)
        lines = pathlib.Path(candidate['file']).read_text().splitlines()
        expected = [*repeated['headers'], *(entry['file'] for entry in group)]
        assert lines[1:] == ['#include "'+path.replace('\\','/')+'"' for path in expected]
        assert '-include' not in candidate['arguments']
        assert candidate['arguments'][:7] == module._windows_paths(dict(group[0], arguments=arguments[:7]))['arguments']
        assert candidate['nvim_ue_members'] == [member for entry in group for member in entry['nvim_ue_members']]
        lower = module._candidate_overlays(candidate)[0][1]
        assert lower['fallthrough'] is False and lower['use-external-names'] is False
        paths = {os.path.normcase(os.path.normpath(row['name'])):row for row in lower['roots']}
        for header in headers:
            row = paths[os.path.normcase(os.path.normpath(str(header)))]
            assert pathlib.Path(row['external-contents']).read_bytes() == header.read_bytes()
            frozen = next(item for item in files if item['path'] == str(header))
            assert frozen['file_identity'] == module._source_identity(header)
        before = {str(path):(path.read_bytes(),path.stat().st_mtime_ns) for path in (store/'assets').rglob('*') if path.is_file()}
        assert freeze(duplicate)[2] == identity
        assert before == {str(path):(path.read_bytes(),path.stat().st_mtime_ns) for path in (store/'assets').rglob('*') if path.is_file()}
        assert group == original and all(pathlib.Path(path).read_bytes() == raw for path,raw in original_bytes.items())
        print('pure constructor: duplicates/order, all other flags, unchanged source bytes and physical snapshot identities')

    elif operation == 'unsupported':
        variants = [(['-imacros',str(headers[0])],'unsupported-option'),
            (['--imacros',str(headers[0])],'unsupported-option'), (['--include',str(headers[0])],'unsupported-option'),
            (['--include='+str(headers[0])],'unsupported-option'), (['-Xpreprocessor','-include'],'unsupported-option'),
            (['-Xclang','-include'],'unsupported-option'), (['-Wp,-include,'+str(headers[0])],'unsupported-option'),
            (['-Xassembler','-include'],'unsupported-option'), (['-Xlinker','-include'],'unsupported-option'),
            (['-mllvm','-include'],'unsupported-option'), (['-fdirectives-only'],'unsupported-option'),
            (['-x','c++-cpp-output'],'preprocessed-language'), (['-xc++-cpp-output'],'preprocessed-language'),
            (['/FI'+str(headers[0])],'unsupported-option'), (['-include'+str(headers[0])],'joined-include'),
            (['--'],'end-of-options'), (['-include','relative.h'],'relative-include')]
        for index,(extra,why) in enumerate(variants):
            changed = copy.deepcopy(group)
            for entry in changed:
                entry['arguments'][-1:-1] = extra
            actual, reason = module._strict_forced_prefix(changed)
            assert actual is None and why in reason, (extra,actual,reason)
            candidate, _, _ = freeze(changed, target=store/str(index))
            assert pathlib.Path(candidate['file']).read_text() == '// Verified same-context UBT batch.\n'+''.join(
                '#include "'+entry['file'].replace('\\','/')+'"\n' for entry in changed)
            assert candidate['arguments'].count('-include') == changed[0]['arguments'].count('-include')
        missing = copy.deepcopy(group)
        missing[0]['arguments'].append('-include')
        assert 'missing-include-operand' in module._strict_forced_prefix(missing)[1]
        assert 'invalid-arguments' in module._strict_forced_prefix([dict(group[0],arguments=None)])[1]
        operand = copy.deepcopy(group)
        for entry in operand: entry['arguments'][1:1] = ['-I','-include','-x','c++']
        assert module._strict_forced_prefix(operand) == (descriptor,None), 'ordinary option operands are not forced options'
        candidate = freeze(operand, target=store/'operand')[0]
        assert candidate['arguments'][1:5] == ['-I','-include','-x','c++']
        assert module._forced_prefix_arguments(candidate['arguments'])[0] == [], 'actual forced pairs alone were removed'
        changed = copy.deepcopy(group)
        changed[1]['arguments'][8] = str(headers[1])
        assert 'include-sequences-differ' in module._strict_forced_prefix(changed)[1]
        print('unsupported whole sequence keeps old body/argv; no partial forced stripping')

    elif operation == 'closure':
        incomplete = [{uri:row for uri,row in graph.items() if uri != headers[1].as_uri()} for graph in graphs]
        rejected(lambda: freeze(native_graphs=incomplete), 'forced-prefix-input-outside-frozen-closure')
        for payload in (b'CPCHbinary', b'text\0binary'):
            headers[0].write_bytes(payload)
            rejected(lambda: freeze(target=store/'binary'), 'forced-prefix-nontextual-input')
        headers[0].write_bytes(original_bytes[str(headers[0])])
        for suffix in ('"bad','\nline','\0nul'):
            bad = copy.deepcopy(group)
            for entry in bad: entry['arguments'][8] += suffix
            rejected(lambda: freeze(bad), 'forced-prefix-unrepresentable-include')
        headers[0].unlink()
        try:
            freeze()
            raise AssertionError('unreadable header silently accepted')
        except FileNotFoundError:
            pass
        print('missing sealed root, binary header, unrepresentable path and unreadable input fail closed')

    elif operation == 'identities':
        identities = dict(collector='current', tool='tool', tool_path=str(executable), compiler_environment={})
        expected_old_key = lambda entries: module._sha(module._json(dict(entries=entries, collector='current', tool='tool',
            tool_path=str(executable),compiler_environment={},server_profile=None)).encode())
        assert module._cache_key(group,identities,None) != expected_old_key(group)
        first_key, first_id = module._cache_key(group,identities,None), background._identity(group,'strict')
        candidate,files,frozen_id = freeze()
        with patch.object(module,'_FORCED_PREFIX_RECIPE','ordered-absolute-forced-prefix-next'):
            assert module._cache_key(group,identities,None) != first_key
            assert background._identity(group,'strict') != first_id
            assert freeze()[2] != frozen_id
        no_prefix = copy.deepcopy(group)
        for entry in no_prefix: entry['arguments'] = entry['arguments'][:7]+entry['arguments'][-1:]
        assert module._cache_key(no_prefix,identities,None) == expected_old_key(no_prefix)
        assert background._identity(no_prefix,'strict') == module._sha(background._json(no_prefix).encode())
        assert background._identity(group,'1') == module._sha(background._json(dict(tier=1,entries=group)).encode())
        legacy, files, value = freeze(no_prefix, target=store/'legacy')
        expected_identity = module._sha(module._json(dict(entries=[module._native(e) for e in no_prefix], files=files,
            tool='unit-tool-identity',compiler_environment=module._compiler_environment(None),server_profile=None)).encode())
        assert value == expected_identity
        reordered = copy.deepcopy(group)
        for entry in reordered:
            entry['arguments'][8],entry['arguments'][10] = entry['arguments'][10],entry['arguments'][8]
        assert module._cache_key(reordered,identities,None) != first_key and freeze(reordered)[2] != frozen_id
        assert module._cache_key(group[::-1],identities,None) != first_key
        print('strict recipe/order identities change; legacy/no-prefix and Tier1 preimages remain exact')

    elif operation in ('cache', 'receipt', 'recovery'):
        identities = module._identities(executable, imported=True)
        candidate,files,identity = freeze()
        assets = module._candidate_assets(candidate)
        inventories = module._inventories([str(source)],store,{})
        receipt_path = store/'assets/receipt.contract.json'
        receipt = dict(schema=2, identity=identity, output_dir=str(store), original_entries=[module._native(e) for e in group],
            candidate=module._native(candidate), identities=identities, dependencies=files, inventories=inventories,
            query_profiles=[], server_profile=None, assets=assets, forced_prefix=descriptor)
        receipt_path.write_text(module._json(receipt))
        candidate.update(nvim_ue_batch_receipt=str(receipt_path), nvim_ue_batch_receipt_sha256=module._sha(receipt_path.read_bytes()))
        record = dict(schema=1,accepted=True,reason='unit-contract-only',first_proof_seconds=1,identities=identities,
            dependencies=files,inventories=inventories,query_profiles=[],candidate=candidate,forced_prefix=descriptor,
            assets=assets+[dict(path=str(receipt_path),sha256=candidate['nvim_ue_batch_receipt_sha256'])])
        cache_path = store/'receipts'/(module._cache_key(group,identities,None)+'.json')
        cache_path.parent.mkdir(); cache_path.write_text(module._json(record))
        if operation == 'receipt':
            assert module._cached_group_matches(record,group,store)
            assert module.describe_receipts([receipt_path])['ok']
            assert module.validate_receipts([receipt_path],executable)['ok']
            for field,value in (('forced_prefix',None),('forced_prefix',dict(descriptor,recipe='old')),
                                ('forced_prefix',dict(descriptor,headers=descriptor['headers'][::-1]))):
                forged = copy.deepcopy(receipt)
                if value is None: forged.pop(field)
                else: forged[field] = value
                receipt_path.write_text(module._json(forged))
                assert not module.describe_receipts([receipt_path])['ok']
                assert module.validate_receipts([receipt_path],executable)['reason'] == 'receipt-forced-prefix-mismatch'
                assert not module._cached_group_matches(record,group,store)
            receipt_path.write_text(module._json(receipt))
            with patch.object(module,'_index',side_effect=AssertionError('replay must reject before native')):
                rejected(lambda: module._prove(group,root/'replay',store/'assets',str(executable),'hash',5,{},
                    reused=dict(record,forced_prefix=dict(descriptor,recipe='old')),original_identities=identities),
                    'stored-forced-prefix-mismatch')
            print('synthetic receipt contract: direct activation, group reuse and replay reject wrong recipe')
        elif operation == 'cache':
            def reuse():
                return module.accelerate(group,store,str(executable),verify_missing=False,group_indexes=[0,1])
            with patch.object(module,'_prove',side_effect=AssertionError('cache proof forbidden')), \
                    patch.object(subprocess,'Popen',side_effect=AssertionError('cache native forbidden')), \
                    patch.object(module,'_write',side_effect=AssertionError('cache write forbidden')):
                before = {str(p):(p.read_bytes(),p.stat().st_mtime_ns) for p in store.rglob('*') if p.is_file()}
                output,metrics = reuse()
                assert metrics['cache_hits'] == metrics['batch_count'] == 1 and metrics['new_proof_count'] == 0
                assert before == {str(p):(p.read_bytes(),p.stat().st_mtime_ns) for p in store.rglob('*') if p.is_file()}
                forged = copy.deepcopy(record); forged.pop('forced_prefix'); cache_path.write_text(module._json(forged))
                assert reuse()[1]['batch_count'] == 0
                cache_path.write_text(module._json(record))
                wrapper = pathlib.Path(candidate['file']); raw = wrapper.read_bytes(); state = wrapper.stat()
                wrapper.write_bytes(raw.replace(b'Verified',b'Tampered',1)); os.utime(wrapper,ns=(state.st_atime_ns,state.st_mtime_ns))
                assert reuse()[1]['batch_count'] == 0
                wrapper.write_bytes(raw)
                overlay = pathlib.Path(module._candidate_overlays(candidate)[0][0])
                raw_overlay = overlay.read_bytes(); state = overlay.stat()
                changed = raw_overlay.replace(b'"fallthrough":false',b'"fallthrough":true ',1)
                assert changed != raw_overlay and len(changed) == len(raw_overlay)
                overlay.write_bytes(changed); os.utime(overlay,ns=(state.st_atime_ns,state.st_mtime_ns))
                assert reuse()[1]['batch_count'] == 0
                overlay.write_bytes(raw_overlay)
                forged = copy.deepcopy(record)
                forged['dependencies'][0]['file_identity'] = ['changed-physical-identity']
                cache_path.write_text(module._json(forged))
                assert reuse()[1]['batch_count'] == 0
                cache_path.write_text(module._json(record))
                headers[0].write_text('// changed header\n')
                assert reuse()[1]['batch_count'] == 0
            print('synthetic cache contract: real current gates, no writes/native, recipe/body/header tamper restores originals')
        else:
            input_path, plan_path = root/'semantic.json',root/'plan.json'
            input_path.write_text(module._json(group))
            empty = root/'empty'
            plan = background.make_plan(input_path,empty,str(executable))
            assert len(plan['groups']) == 1
            current = plan['groups'][0]
            old_id = module._sha(background._json(group).encode())
            assert old_id != current['id']
            prior = copy.deepcopy(plan); prior['groups'][0]['id'] = old_id
            prior['groups'][0]['store'] = str(pathlib.Path(current['store']).parent/old_id)
            plan_path.write_text(module._json(prior))
            (root/('result-'+old_id+'.json')).write_text(module._json(dict(ok=True,group_id=old_id,
                input_sha256=plan['input_sha256'],mode='strict',metrics={'new_batch_count':1})))
            assert background.make_plan(input_path,empty,str(executable),previous_path=plan_path)['recovered_completed'] == []
            rejected(lambda: background._group(prior,group,old_id),'background-proof-group-identity-mismatch')
            plan_path.write_text(module._json(plan))
            (root/('result-'+current['id']+'.json')).write_text(module._json(dict(ok=True,group_id=current['id'],
                input_sha256=plan['input_sha256'],mode='strict',metrics={'new_batch_count':1})))
            recovered = background.make_plan(input_path,empty,str(executable),previous_path=plan_path)
            assert recovered['recovered_completed'] == [dict(id=current['id'],accepted_hint=1)]
            print('strict queue derives recipe IDs; old successful result cannot recover into prefix work')

    elif operation == 'native_public':
        input_path, plan_path = root/'semantic.json',root/'plan.json'
        exact = dict(directory=str(source),file=str(source/'exact.cpp'),arguments=[str(compiler),'-c',str(source/'exact.cpp')])
        shader = dict(directory=str(source),file=str(source/'sample.usf'),arguments=[str(compiler),str(source/'sample.usf')],
                      nvim_ue_background_route='shader-compatibility')
        entries = group+[exact,shader]
        input_path.write_text(module._json(entries))
        plan = background.make_plan(input_path,store,clangd)
        plan_path.write_text(module._json(plan))
        assert len(plan['groups']) == 1
        identity = plan['groups'][0]['id']
        worked = background.work(plan_path,identity,clangd)
        assert worked['ok'] and worked['metrics']['new_batch_count'] == 1, worked
        output_path, marker = root/'background.json',root/'marker.json'
        output_path.write_text(module._json(entries)); marker.write_text(module._json(dict(schema=1)))
        collected = background.collect(plan_path,[identity],output_path,marker,clangd)
        assert collected['ok'] and identity in collected['revalidated_completed'], collected
        rows = json.loads(output_path.read_text())
        assert len(rows) == 3 and rows[1:] == [exact,shader]
        receipt = module._read_receipts([rows[0]['nvim_ue_batch_receipt']])[0]
        assert receipt['forced_prefix'] == descriptor and '-include' not in receipt['candidate']['arguments']
        assert module.validate_receipts([rows[0]['nvim_ue_batch_receipt']],clangd)['ok']
        from clangd_index_graph import read_shard
        workroot = pathlib.Path(worked['metrics']['proof_directory'])
        report = json.loads(next(workroot.glob('group-*/candidate/run/run.json')).read_text())
        nodes = {}
        relation_count = 0
        for path in report['shards']:
            shard = read_shard(path)
            own = [(uri,node) for uri,node in shard['sources'].items() if node['digest'] != '0000000000000000']
            assert len(own) == 1 and own[0][0] not in nodes and not own[0][1]['flags'] & 2
            nodes[own[0][0]] = shard
            relation_count += len(shard['relations'])
        roots = [pathlib.Path(row['file']).as_uri() for row in json.loads((pathlib.Path(report['cdb_dir'])/'compile_commands.json').read_text())]
        reached,pending = set(),list(roots)
        while pending:
            uri = pending.pop()
            if uri in reached: continue
            assert uri in nodes, uri
            reached.add(uri); pending.extend(nodes[uri]['sources'])
        assert reached == set(nodes) and len(nodes) == 9 and relation_count > 0
        frozen_before = {str(p):(p.read_bytes(),p.stat().st_mtime_ns) for p in store.parent.rglob('*')
            if p.is_file() and (p == output_path or p == marker or p.is_relative_to(store) or 'background-proofs' in p.parts)}
        with patch.object(module,'_prove',side_effect=AssertionError('repeat started proof')), \
                patch.object(subprocess,'Popen',side_effect=AssertionError('repeat started process')):
            again = background.collect(plan_path,[identity],output_path,marker,clangd)
            assert again['ok'] and identity in again['revalidated_completed']
            assert background.make_plan(input_path,store,clangd)['groups'] == []
        assert all(pathlib.Path(p).read_bytes() == raw and pathlib.Path(p).stat().st_mtime_ns == stamp
                   for p,(raw,stamp) in frozen_before.items())
        headers[0].write_text(headers[0].read_text()+'// invalidate original input\n')
        assert not module.validate_receipts([rows[0]['nvim_ue_batch_receipt']],clangd)['ok']
        assert background.reuse_completed(entries,store,clangd)[0] == entries
        print('REAL native public plan/work/collect: strict graph proof, BaseOf relation, 9/9 Sources closure, immutable repeat and header fallback')
    else:
        raise AssertionError(operation)
]=]

local function run_fixture(operation, clangd)
  local python = vim.fn.exepath("python")
  if python == "" then python = vim.fn.exepath("python3") end
  if python == "" then t.skip("strict forced prefix", "Python unavailable", { native = true }); return end
  local script = vim.fn.tempname() .. "_strict_prefix.py"
  local stream = assert(io.open(script, "wb"))
  stream:write(fixture)
  stream:close()
  local result = vim.system({ python, "-B", "-I", script,
    vim.fn.stdpath("config") .. "/tools/cdb_verified_batch.py", operation, clangd or "" }, { text = true }):wait()
  pcall(vim.fn.delete, script)
  t.assert_eq(result.code, 0, (result.stderr or "") .. (result.stdout or ""))
end

t.describe("Strict ordered forced-prefix construction", function()
  for _, operation in ipairs({ "constructor", "unsupported", "closure", "identities", "receipt", "cache", "recovery" }) do
    t.it(operation, function() run_fixture(operation) end)
  end
  local discovered = require("utils.ue_goto.semantic_sidecar_libclang").discover_toolchain()
  if not discovered.ok then
    t.skip("public strict prefix native proof", discovered.reason, { native = true })
    return
  end
  t.it("qualifies and collects a real ordered-prefix batch through the public strict queue", function()
    run_fixture("native_public", discovered.clangd_path)
  end)
end)
