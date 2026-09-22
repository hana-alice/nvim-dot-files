local t = require("tests.harness")
t.bootstrap()

local function write(path, content)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local handle = assert(io.open(path, "wb"))
  handle:write(content)
  handle:close()
end

local function read(path)
  local handle = assert(io.open(path, "rb"))
  local content = handle:read("*a")
  handle:close()
  return vim.json.decode(content)
end

local discovery = require("utils.ue_goto.semantic_sidecar")._discover_toolchain_for_test()
local python = vim.fn.exepath("python")
if python == "" then python = vim.fn.exepath("python3") end

t.describe("original TU batch binding proof", function()
  if not discovery.ok or python == "" then
    t.skip("real libclang and Python binding fixtures", discovery.reason or "python-not-found", { native = true })
    return
  end

  local function fixture(body)
    local root = vim.fn.tempname():gsub("\\", "/") .. "_batch_bindings"
    vim.fn.mkdir(root, "p")
    root = vim.fs.normalize(vim.uv.fs_realpath(root) or root)
    local ok, err = xpcall(function()
      local header = root .. "/friend 中文.hpp"
      write(header, "#pragma once\nstruct Owner { friend class Target; };\n"
        .. "/* 中文 🦄 */ inline int unicode_probe() { return 1; }\n"
        .. "#if ORIGINAL != 1\n#error original compile macro was lost\n#endif\n")
      local source = '#include "friend 中文.hpp"\nclass Target {};\n'
      write(root .. "/first.cpp", source)
      write(root .. "/second.cpp", source)
      write(root .. "/unrelated.cpp", "int unrelated;\n")
      local entries = {}
      for _, name in ipairs({ "first", "second", "unrelated" }) do
        local path = root .. "/" .. name .. ".cpp"
        entries[#entries + 1] = {
          directory = root, file = path,
          arguments = { "clang++", "-std=c++17", "-DORIGINAL=1", "-I", root, "-c", path, "-o", path .. ".o" },
        }
      end
      local function verify(requests, custom_entries)
        write(root .. "/request.json", vim.json.encode({
          entries = custom_entries or entries, requests = requests, libclang_path = discovery.libclang_path,
        }))
        local result = vim.system({ python, "-I", vim.fn.stdpath("config") .. "/tools/clangd_batch_bindings.py",
          "--request", root .. "/request.json", "--out", root .. "/result.json",
        }, { text = true }):wait(20000)
        t.assert_true(result.code == 0 or result.code == 1, result.stderr or result.stdout)
        local document = read(root .. "/result.json")
        t.assert_eq(result.code, document.ok and 0 or 1)
        return document
      end
      local friend = {
        uri = vim.uri_from_fname(header), line = 1, column = 28,
        symbol_id = "cc7bab6ad027afa9", -- independently known USR c:@S@Target
        kind = 12, container = "a1a58b797690c106", -- Reference|Spelled, c:@S@Owner
        contexts = { 0, 1 },
      }
      body(root, header, entries, friend, verify)
    end, debug.traceback)
    vim.fn.delete(root, "rf")
    if not ok then error(err) end
  end

  t.it("proves a friend binding in every original TU and parses each TU once", function()
    fixture(function(_, _, _, friend, verify)
      local duplicate = vim.deepcopy(friend)
      local result = verify({ friend, duplicate })
      t.assert_true(result.ok, vim.inspect(result))
      t.assert_eq(#result.evidence.translation_units, 2)
      t.assert_eq(#result.evidence.requests, 2)
      for _, request in ipairs(result.evidence.requests) do
        t.assert_eq(#request.contexts, 2)
        for _, context in ipairs(request.contexts) do
          t.assert_true(context.ok)
          t.assert_eq(context.usr, "c:@S@Target")
          t.assert_eq(context.container_usr, "c:@S@Owner")
          t.assert_eq(context.verified_kind, 12)
        end
      end
    end)
  end)

  t.it("requires the expected SymbolID and header membership in every context", function()
    fixture(function(_, _, _, friend, verify)
      local wrong = vim.deepcopy(friend)
      wrong.symbol_id = "0000000000000000"
      local mismatch = verify({ wrong })
      t.assert_false(mismatch.ok)
      t.assert_eq(mismatch.evidence.requests[1].reason, "symbol-id-mismatch")
      local missing = vim.deepcopy(friend)
      missing.contexts = { 0, 2 }
      local absent = verify({ missing })
      t.assert_false(absent.ok)
      t.assert_true(absent.evidence.requests[1].contexts[1].ok)
      t.assert_false(absent.evidence.requests[1].contexts[2].ok)
      missing.contexts = {}
      t.assert_eq(verify({ missing }).reason, "invalid-request")
      missing.contexts = { 99 }
      t.assert_eq(verify({ missing }).reason, "invalid-request")
    end)
  end)

  t.it("retains the driver identity and safely removes the effective command input terminator", function()
    fixture(function(root, _, entries, friend, verify)
      local source = root .. "/driver_input.c"
      write(source, '#include "friend 中文.hpp"\nclass Target {};\n')
      entries[1].file = source
      entries[1].arguments = { vim.fs.dirname(discovery.libclang_path) .. "/clang++", "-std=c++17",
        "-DORIGINAL=1", "--", source }
      friend.contexts = { 0 }
      local result = verify({ friend })
      t.assert_true(result.ok, vim.inspect(result))
      t.assert_eq(result.evidence.requests[1].contexts[1].usr, "c:@S@Target")
      -- Options after -- are inputs, never permission to rewrite the command.
      vim.list_extend(entries[1].arguments, { "-ivfsoverlay", root .. "/missing.json" })
      local invalid = verify({ friend })
      t.assert_false(invalid.ok)
      t.assert_contains(invalid.evidence.translation_units[1].error, "input terminator")
      write(source, '#include "friend 中文.hpp"\n#ifndef _MSC_VER\n#error driver mode lost\n#endif\n')
      entries[1].arguments = { vim.fs.dirname(discovery.libclang_path) .. "/clang-cl",
        "/std:c++17", "/DORIGINAL=1", "/TP", "--", source }
      local cl = verify({ friend })
      t.assert_true(cl.ok, vim.inspect(cl))
    end)
  end)

  t.it("preserves effective target, resource directory, VFS, role, container and UTF-16 positions", function()
    fixture(function(root, header, entries, friend, verify)
      local resource = verify({ friend }).evidence.toolchain.resource_dir
      local original = assert(io.open(header, "rb"))
      local bytes = original:read("*a")
      original:close()
      local frozen = root .. "/frozen.hpp"
      write(frozen, bytes .. "#if !defined(__aarch64__) || __SIZEOF_POINTER__ != 8\n#error target lost\n#endif\n")
      -- Request coordinates are read from the real file; preserve those bytes
      -- while making compiler fallback to it observably fail.
      write(header, bytes .. "#error the effective VFS option was lost\n")
      local overlay = root .. "/overlay.json"
      write(overlay, vim.json.encode({ version = 0, ["use-external-names"] = false,
        roots = { { type = "file", name = header, ["external-contents"] = frozen } },
      }))
      for number = 1, 2 do
        entries[number].arguments = { vim.fs.dirname(discovery.libclang_path) .. "/clang",
          "--driver-mode=g++", "--target=aarch64-none-linux-android23", "-std=c++17",
          "-DORIGINAL=1", "-nostdinc", "-ivfsoverlay", overlay }
        vim.list_extend(entries[number].arguments, number == 1 and { "-resource-dir=" .. resource }
          or { "-resource-dir", resource })
        vim.list_extend(entries[number].arguments, { "--", entries[number].file })
      end
      local prefix = "/* 中文 🦄 */ inline int "
      local unicode = { uri = vim.uri_from_fname(header), line = 2, column = vim.str_utfindex(prefix, "utf-16"),
        symbol_id = "f92d58eb41c6cde3", contexts = { 0, 1 } }
      local result = verify({ friend, unicode })
      t.assert_true(result.ok, vim.inspect(result))
      for _, proof in ipairs(result.evidence.requests[1].contexts) do
        t.assert_eq(proof.usr, "c:@S@Target")
        t.assert_eq(proof.container_usr, "c:@S@Owner")
        t.assert_eq(proof.verified_kind, 12)
      end
      t.assert_eq(result.evidence.requests[2].contexts[1].byte_column, #prefix + 1)
      entries[1].arguments[9] = "-resource-dir=" .. root
      local wrong_resource = verify({ friend })
      t.assert_false(wrong_resource.ok)
    end)
  end)

  t.it("replays the structured effective command from a real clangd main shard", function()
    fixture(function(root, _, entries, friend, verify)
      entries[1].arguments = { vim.fs.dirname(discovery.libclang_path) .. "/clang++",
        "--target=aarch64-none-linux-android23", "-std=c++17", "-DORIGINAL=1", "-nostdinc",
        "-c", entries[1].file }
      write(root .. "/compile_commands.json", vim.json.encode({ entries[1] }))
      local code = [=[
import json, pathlib, sys
sys.path.insert(0, sys.argv[1])
from clangd_batch_runner import run
from clangd_index_graph import read_shard
root = pathlib.Path(sys.argv[2])
entry = json.loads((root / 'compile_commands.json').read_text())[0]
entry.update(directory=str(root.resolve()), file=str(pathlib.Path(entry['file']).resolve()))
(root / 'compile_commands.json').write_text(json.dumps([entry]), encoding='utf-8')
report = run(root, root / 'run', entry['file'], sys.argv[3], timeout=15, jobs=1)
assert report['background_compile_success'], report
commands = [shard['command'] for path in report['shards']
            if (shard := read_shard(path))['command']]
assert len(commands) == 1, commands
entry.update(commands[0])
assert '--' in entry['arguments'], entry
(root / 'effective.json').write_text(json.dumps(entry), encoding='utf-8')
]=]
      local result = vim.system({ python, "-I", "-c", code, vim.fn.stdpath("config") .. "/tools",
        root, discovery.clangd_path }, { text = true }):wait(25000)
      t.assert_eq(result.code, 0, result.stderr)
      friend.contexts = { 0 }
      local proof = verify({ friend }, { read(root .. "/effective.json") })
      t.assert_true(proof.ok, vim.inspect(proof))
      t.assert_eq(proof.evidence.requests[1].contexts[1].actual_symbol_id, friend.symbol_id)
      t.assert_eq(proof.evidence.requests[1].contexts[1].actual_container, friend.container)
      t.assert_eq(proof.evidence.requests[1].contexts[1].verified_kind, 12)
    end)
  end)

  t.it("rejects a correct target with an unproven container or reference role", function()
    fixture(function(_, _, _, friend, verify)
      local changed = vim.deepcopy(friend)
      changed.container = "0000000000000000"
      local owner = verify({ changed })
      t.assert_false(owner.ok)
      t.assert_eq(owner.evidence.requests[1].reason, "container-mismatch")
      changed = vim.deepcopy(friend)
      changed.kind = 10
      local role = verify({ changed })
      t.assert_false(role.ok)
      t.assert_eq(role.evidence.requests[1].reason, "reference-role-unproven")
    end)
  end)

  t.it("converts Chinese and non-BMP UTF-16 positions to exact libclang byte columns", function()
    fixture(function(_, header, _, _, verify)
      local prefix = "/* 中文 🦄 */ inline int "
      local column = vim.str_utfindex(prefix, "utf-16")
      local request = { uri = vim.uri_from_fname(header), line = 2, column = column,
        symbol_id = "f92d58eb41c6cde3", contexts = { 0 }, -- c:@F@unicode_probe#
      }
      local result = verify({ request })
      t.assert_true(result.ok, vim.inspect(result))
      t.assert_eq(result.evidence.requests[1].contexts[1].byte_column, #prefix + 1)
      request.column = vim.str_utfindex("/* 中文 ", "utf-16") + 1
      local split_surrogate = verify({ request })
      t.assert_false(split_surrogate.ok)
      t.assert_contains(split_surrogate.evidence.error, "surrogate")
    end)
  end)

  t.it("rejects real compiler errors and standalone header contexts", function()
    fixture(function(root, header, entries, friend, verify)
      friend.contexts = { 0 }
      table.insert(entries[1].arguments, 2, "-Werror")
      write(root .. "/first.cpp", '#include "friend 中文.hpp"\n#warning diagnostic policy only\n')
      local warning = verify({ friend })
      t.assert_true(warning.ok, vim.inspect(warning))
      t.assert_eq(warning.evidence.translation_units[1].diagnostic_adjustments[1], "-Wno-error")
      t.assert_true(warning.evidence.translation_units[1].diagnostics.warning_count > 0)
      write(root .. "/first.cpp", '#include "friend 中文.hpp"\n#error real compiler error\n')
      local result = verify({ friend })
      t.assert_false(result.ok)
      t.assert_eq(result.evidence.requests[1].reason, "tu-parse-error")
      t.assert_true(result.evidence.translation_units[1].diagnostics.error_count > 0)
      entries[1].file = header
      entries[1].arguments = { "clang++", "-x", "c++-header", header }
      local header_only = verify({ friend }, entries)
      t.assert_false(header_only.ok)
      t.assert_contains(header_only.evidence.translation_units[1].error, "standalone header")
    end)
  end)
end)

local template_fixture = [=[
import copy, hashlib, json, pathlib, subprocess, sys, tempfile
sys.path.insert(0, sys.argv[1])
from clangd_batch_bindings import verify_template_arguments
from clangd_batch_runner import run
from clangd_index_graph import read_shard
mode, clangd, library = sys.argv[2:5]
with tempfile.TemporaryDirectory(prefix='template_proof_') as temporary:
    root = pathlib.Path(temporary).resolve()
    header = root / 'template 中文.hpp'
    header.write_text('''#pragma once
#define BASE(T) static const int CounterBase=__COUNTER__; template<T I,class Dummy=void> struct Link;
#ifdef EXTRA_GAP
#define GAP static const int Gap=__COUNTER__;
#else
#define GAP
#endif
#define FIELD template<class Dummy> struct Link<__COUNTER__ - CounterBase,Dummy>{};
struct Plain { BASE(int) GAP FIELD };
template<int N> struct Generic { BASE(int) GAP FIELD };
struct Wide { BASE(__int128) FIELD };
template<int N> struct Dependent { BASE(int) template<class Dummy> struct Link<__COUNTER__ - CounterBase+N,Dummy>{}; };
struct Pointer { BASE(int) template<class Dummy> struct Link<__COUNTER__ - CounterBase,Dummy*>{}; };
''', encoding='utf-8')
    entries, records, shard_hashes = [], [], {}
    for label, prefix in [('original', ''), ('candidate', 'enum { Noise0=__COUNTER__, Noise1=__COUNTER__ };\n')]:
        source = root / (label + '.cpp')
        source.write_text(prefix + '#include "template 中文.hpp"\n', encoding='utf-8')
        directory = root / label
        directory.mkdir()
        entry = {'directory': str(root), 'file': str(source), 'arguments': [
            str(pathlib.Path(clangd).with_name('clang++')), '--target=aarch64-none-linux-android23',
            '-std=c++17', '-nostdinc', '-c', str(source)]}
        (directory / 'compile_commands.json').write_text(json.dumps([entry]), encoding='utf-8')
        report = run(directory, directory / 'run', source, clangd, timeout=15, jobs=1)
        assert report['background_compile_success'], report
        symbols, commands = {}, []
        for path in report['shards']:
            shard_hashes[path] = hashlib.sha256(pathlib.Path(path).read_bytes()).hexdigest()
            shard = read_shard(path)
            if shard['command']:
                commands.append(shard['command'])
            for symbol in shard['symbols']:
                if symbol['name'] == 'Link' and symbol['template_specialization_args']:
                    symbols[symbol['scope']] = symbol
        assert len(commands) == 1, commands
        entry.update(commands[0])
        assert '--' in entry['arguments'], entry
        entries.append(entry)
        records.append(symbols)
    def request(owner, candidate=True):
        old = records[0][owner + '::']
        new = records[1 if candidate else 0][owner + '::']
        return {'symbol_id': old['id'], 'originals': [{'index': 0, 'symbols': [old]}], 'candidate': [new]}
    def verify(requests, contexts=None):
        return verify_template_arguments(contexts or entries, requests, library)
    def denied(result, reason):
        assert not result['ok'], result
        assert reason in json.dumps(result), result
    plain = request('Plain')
    assert plain['candidate'][0]['id'] == plain['symbol_id']
    assert plain['candidate'][0]['template_specialization_args'] != plain['originals'][0]['symbols'][0]['template_specialization_args']
    if mode == 'positive':
        requests = [plain, request('Generic')]
        envelope = {'action': 'template-arguments', 'entries': entries, 'requests': requests, 'libclang_path': library}
        input_path, output_path = root / 'request.json', root / 'result.json'
        input_path.write_text(json.dumps(envelope), encoding='utf-8')
        completed = subprocess.run([sys.executable, '-I', str(pathlib.Path(sys.argv[1]) / 'clangd_batch_bindings.py'),
            '--request', str(input_path), '--out', str(output_path)], capture_output=True, timeout=15)
        result = json.loads(output_path.read_text())
        assert completed.returncode == 0 and result['ok'], result
        assert result['evidence']['entries'] == entries
        assert len(result['evidence']['translation_units']) == 2, result
        assert '22.1.5' in result['evidence']['toolchain']['version']
        for expected, proof in zip(requests, result['evidence']['requests']):
            assert proof['request'] == expected and proof['ok'], proof
            assert [(c['index'],c['role'],c['ok']) for c in proof['contexts']] == [(0,'original',True),(1,'candidate',True)]
            for context in proof['contexts']:
                facts = context['fact']['arguments']
                assert facts[0]['value'] == '1' and facts[0]['width_bits'] == 32 and facts[0]['signed'] is True
                assert facts[1]['kind'] == 'Type' and facts[1]['parameter_index'] == 0
        # Raw graph source assets are never rewritten by proof extraction.
        assert all(hashlib.sha256(pathlib.Path(p).read_bytes()).hexdigest() == h for p,h in shard_hashes.items())
    else:
        same = [entries[0], entries[0]]
        denied(verify([request('Wide', False)], same), 'unsupported-integral-parameter-type')
        denied(verify([request('Dependent', False)], same), 'unsupported-template-argument-shape')
        denied(verify([request('Pointer', False)], same), 'template-type-parameter-binding-unproven')
        changed = copy.deepcopy(entries)
        changed[1]['arguments'].insert(1, '-DEXTRA_GAP=1')
        denied(verify([plain], changed), 'template-declaration-missing-or-ambiguous')
        wrong_display = copy.deepcopy(plain)
        wrong_display['candidate'][0]['template_specialization_args'] = '<999 - CounterBase, Dummy>'
        denied(verify([wrong_display]), 'template-printed-arguments-mismatch')
        wrong_location = copy.deepcopy(plain)
        wrong_location['candidate'][0]['canonical_declaration']['start'][1] += 1
        denied(verify([wrong_location]), 'template-canonical-declaration-mismatch')
        absent = root / 'absent.cpp'
        absent.write_text('int unrelated;\n', encoding='utf-8')
        absent_entry = {'directory': str(root), 'file': str(absent), 'arguments': ['clang++','-c',str(absent)]}
        two_originals = copy.deepcopy(plain)
        two_originals['originals'].append({'index': 1, 'symbols': copy.deepcopy(plain['originals'][0]['symbols'])})
        denied(verify([two_originals], [entries[0], absent_entry, entries[1]]), 'template-declaration-missing-or-ambiguous')
        two_originals['originals'][1]['index'] = 3
        denied(verify([two_originals]), 'invalid-request')
        duplicate = copy.deepcopy(plain)
        duplicate['originals'].append(copy.deepcopy(duplicate['originals'][0]))
        denied(verify([duplicate]), 'duplicate template context')
        missing = copy.deepcopy(plain)
        missing['originals'] = []
        denied(verify([missing]), 'invalid-request')
        error = copy.deepcopy(entries)
        error[1]['arguments'].insert(1, '-include')
        error[1]['arguments'].insert(2, str(root / 'missing.hpp'))
        denied(verify([plain], error), 'tu-parse-error')
    print(json.dumps({'ok': True, 'mode': mode, 'raw_shards': len(shard_hashes)}))
]=]

t.describe("compiler proof for printed template arguments", function()
  if not discovery.ok or python == "" then
    t.skip("real libclang template argument fixtures", discovery.reason or "python-not-found", { native = true })
    return
  end
  for _, case in ipairs({
    { "positive", "proves equal integral values from real differing graph records in one parse per TU" },
    { "negative", "rejects unsupported types, dependent values, changed bindings, locations and missing contexts" },
  }) do
    t.it(case[2], function()
      local result = vim.system({ python, "-I", "-B", "-c", template_fixture,
        vim.fn.stdpath("config") .. "/tools", case[1], discovery.clangd_path, discovery.libclang_path,
      }, { text = true }):wait(60000)
      t.assert_eq(result.code, 0, result.stderr or result.stdout)
      t.assert_true(vim.json.decode(result.stdout).ok)
    end)
  end
end)
