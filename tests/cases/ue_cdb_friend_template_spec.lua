local t = require("tests.harness")

t.bootstrap()

local fixture = [=[
import copy, hashlib, importlib.util, json, os, pathlib, queue, subprocess, sys, tempfile, threading, time
from unittest.mock import patch
sys.dont_write_bytecode = True
repo, operation, clangd = sys.argv[1:]
repo = pathlib.Path(repo)
sys.path.insert(0, str(repo/'tools'))
path = repo/'lua/workarounds/clangd/friend_template_canonical.py'
spec = importlib.util.spec_from_file_location('friend_prefix',path)
c = importlib.util.module_from_spec(spec); spec.loader.exec_module(c)
with tempfile.TemporaryDirectory(prefix='ue-friend-prefix-') as folder:
    root = pathlib.Path(folder).resolve()
    engine = root/'UE'
    public = engine/'Engine/Source/Runtime/CoreUObject/Public'
    headers = public/'UObject'; headers.mkdir(parents=True)
    globals_header = headers/'UObjectGlobals.h'
    class_header = headers/'Class.h'
    globals_header.write_text('#pragma once\nstruct FObjectInitializer;\nstruct FObjectInitializer { template<class T> friend void InternalConstructor(const FObjectInitializer& X); };\n')
    class_header.write_text('#pragma once\n#include "UObjectGlobals.h"\ntemplate<class T> void InternalConstructor(const FObjectInitializer& X) { T::Build(X); }\nstruct A { static void Build(const FObjectInitializer&) {} };\nstruct B { static void Build(const FObjectInitializer&) {} };\nvoid Sink(void (*)(const FObjectInitializer&));\n#define USE(T) void Use##T() { Sink(&InternalConstructor<T>); }\n')
    approved = {tuple(hashlib.sha256(p.read_bytes()).hexdigest() for p in (globals_header,class_header))}
    compiler = str(pathlib.Path(clangd).with_name('clang++'+pathlib.Path(clangd).suffix)) if clangd else 'clang++'
    def entry(source, *options):
        return {'directory':str(root),'file':str(source),'arguments':[compiler,'-std=c++17','-I',str(public),'-include',str(class_header),*options,'-c',str(source)]}
    a,b = root/'a.cpp',root/'b.cpp'
    a.write_text('#include "'+class_header.as_posix()+'"\nUSE(A)\n')
    b.write_text('#include "'+class_header.as_posix()+'"\nUSE(B)\n')
    if operation == 'guards':
        assert c.supported_version('clangd version 22.1.5 (upstream)')
        for version in ('clangd version 22.1.4','clangd version 22.1.6','clangd version 23.1.0','clang version 22.1.5','unknown'):
            assert not c.supported_version(version)
        assert c.probe_clangd('clangd')[1]=='selected-clangd-unavailable'
        assert c.engine_context(engine)[1]=='unverified-engine-header-bytes'
        # Comments, string literals and a nested namespace cannot admit headers.
        for text in ('// template<class T> friend void InternalConstructor(const FObjectInitializer&);',
                     'const char* x="template<class T> friend void InternalConstructor(const FObjectInitializer&);";',
                     'namespace wrong { template<class T> void InternalConstructor(const FObjectInitializer&); }'):
            globals_header.write_text(text)
            assert c.engine_context(engine)[1]=='unverified-engine-header-bytes'
        base=entry(a,'-Werror','-DKEEP=1','-UOLD')
        before=copy.deepcopy(base)
        transformed,reason=c.transform_entry(base,c.canonical(public))
        assert reason=='added' and base==before
        assert transformed['arguments']==[base['arguments'][0],'-include',str(c.PREFIX),*base['arguments'][1:]]
        assert c.PREFIX.is_absolute() and root not in c.PREFIX.parents
        assert c.transform_entry(transformed,c.canonical(public))==(transformed,'already-first-prefix')
        variants=[(entry(a,'@inputs.rsp'),'unexpanded-response-input'),
                  (entry(a,'-x','c'),'unsupported-language'),
                  (entry(a,'-xobjective-c++'),'unsupported-language'),
                  (entry(a,'-include-pch','real.pch'),'binary-pch-command'),
                  (entry(a,'/YuPCH.h','/FpPCH.pch'),'binary-pch-command'),
                  (entry(a,'-Xclang','-include-pch'),'unsupported-indirect-frontend-input'),
                  (entry(a,'-imacros','macros.h'),'unsupported-indirect-frontend-input'),
                  (entry(root/'shader.hlsl','-x','c++'),'non-c++-source')]
        missing=entry(a); missing['arguments'][3]=str(root/'not-CoreUObject')
        variants.append((missing,'no-coreuobject-include-context'))
        binary=root/'disguised.h'; binary.write_bytes(b'CPCH\x00native-pch')
        variants.append((entry(a,'-include',str(binary)),'binary-forced-input'))
        for original,expected in variants:
            assert c.transform_entry(original,c.canonical(public))==(original,expected),(expected,original)
        pathlib.Path(str(class_header)+'.gch').write_bytes(b'CPCH\0')
        assert c.transform_entry(base,c.canonical(public))[1]=='implicit-binary-pch'
    elif operation == 'stale':
        cdb=root/'compile_commands.json'
        base=entry(a,'-Werror','-DKEEP=1')
        owned=c.transform_entry(base,c.canonical(public))[0]
        def rejected(entries,version='clangd version 22.1.5',context=engine):
            cdb.write_text(json.dumps(entries))
            before=cdb.read_bytes();stamp=cdb.stat().st_mtime_ns
            try:c.apply_policy(cdb,version,context)
            except ValueError as error:assert 'stale-owned-prefix' in str(error),str(error)
            else:raise AssertionError('stale owned prefix was accepted')
            assert cdb.read_bytes()==before and cdb.stat().st_mtime_ns==stamp
        rejected([owned],version='clangd version 23.1.0')
        rejected([owned]) # The fixture headers are not approved in production.
        rejected([owned],context=root/'missing-engine')
        with patch.object(c,'_SUPPORTED_HEADERS',approved):
            for options in (['-x','c'],['@unknown.rsp'],['-include-pch','unknown.pch']):
                stale=copy.deepcopy(owned);stale['arguments'][3:3]=options
                # A prior valid row must not be partially written before failure.
                rejected([entry(b),stale])
            late=entry(a,'-include',str(c.PREFIX))
            duplicate=copy.deepcopy(owned);duplicate['arguments'][3:3]=['-include',str(c.PREFIX)]
            for stale,reason in ((late,'existing-prefix-not-first'),(duplicate,'duplicate-prefix-input')):
                try:c.transform_entry(stale,c.canonical(public))
                except ValueError as error:assert 'stale-owned-prefix' in str(error) and reason in str(error),str(error)
                else:raise AssertionError('invalid prefix placement was accepted')
                rejected([stale])
        for extra in ([],['--skip-reason','unsupported-prepare-step-order']):
            for entries in ([base],[owned]):
                cdb.write_text(json.dumps(entries));before=cdb.read_bytes();stamp=cdb.stat().st_mtime_ns
                result=subprocess.run([sys.executable,str(path),str(cdb),*extra],capture_output=True,text=True,timeout=5)
                if entries==[owned]:
                    assert result.returncode!=0 and 'stale-owned-prefix' in result.stderr,result
                else:assert result.returncode==0,result.stderr
                assert cdb.read_bytes()==before and cdb.stat().st_mtime_ns==stamp
        cdb.write_text(json.dumps([base]));before=cdb.read_bytes();stamp=cdb.stat().st_mtime_ns
        for version,context in (('unknown',engine),('clangd version 22.1.5',engine),('clangd version 22.1.5',root/'missing-engine')):
            result=c.apply_policy(cdb,version,context)
            assert not result['changed'] and result['added']==0 and result['reason']
            assert cdb.read_bytes()==before and cdb.stat().st_mtime_ns==stamp
    elif operation == 'receipt':
        import cdb_unity_receipt as receipt
        import build_hot_super_unity_cdb as grouping
        cdb=root/'compile_commands.json'; original=[entry(a),entry(b)]
        cdb.write_text(json.dumps(original))
        unity=root/'Module.Example.cpp'; unity.write_text(''.join('#include "'+p.as_posix()+'"\n' for p in (a,b)))
        rsp=root/'Module.Example.cpp.o.rsp'; rsp.write_text('original UBT response\n')
        origin={'schema':1,'groups':[{'unity':str(unity),'members':[str(a),str(b)],
                'commands':{e['file']:receipt.entry_hash(e) for e in original},
                'dependencies':{str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in (unity,rsp)}}]}
        pathlib.Path(str(cdb)+'.unity-origin.json').write_text(json.dumps(origin))
        pending=root/'pending.json'; assert receipt.begin(str(cdb),str(pending))==1
        # Explicit fixture-only approval. Production CLI has no override flag.
        with patch.object(c,'_SUPPORTED_HEADERS',approved):
            assert c.apply_policy(cdb,'clangd version 22.1.5',engine)['added']==2
            before=cdb.read_bytes(); stamp=cdb.stat().st_mtime_ns
            assert not c.apply_policy(cdb,'clangd version 22.1.5',engine)['changed']
            assert cdb.read_bytes()==before and cdb.stat().st_mtime_ns==stamp
        final=json.loads(cdb.read_bytes()); assert receipt.seal(str(cdb),str(pending))==1
        sealed=pathlib.Path(str(cdb)+'.unity-receipt.json'); data=json.loads(sealed.read_bytes())
        assert data['groups'][0]['dependencies']==origin['groups'][0]['dependencies']
        assert data['groups'][0]['commands']=={e['file']:receipt.entry_hash(e) for e in final}
        assert grouping.compiler_authored_unity_groups(final,None,receipt.load_verified_groups(sealed,final))
        rebound=grouping.rewritten_arguments(final[0],str(root/'SuperUnity.cpp'))
        assert rebound[1:3]==['-include',str(c.PREFIX)]
        before=sealed.read_bytes();stamp=sealed.stat().st_mtime_ns
        assert receipt.begin(str(cdb),str(pending))==1 and receipt.seal(str(cdb),str(pending))==1
        assert sealed.read_bytes()==before and sealed.stat().st_mtime_ns==stamp
    elif operation == 'pch':
        pa,pb=root/'PCH.A.h',root/'PCH.B.h';pa.write_text('// A\n');pb.write_text('// B\n')
        affected=entry(a);affected['arguments']=[compiler,'-std=c++17','-include',str(c.PREFIX),'-include',str(pa),'-c',str(a)]
        unaffected={'directory':str(root),'file':str(b),'arguments':[compiler,'-std=c++17','-include',str(pb),'-c',str(b)]}
        cdb=root/'compile_commands.json';cdb.write_text(json.dumps([affected,unaffected]))
        before=cdb.read_bytes();recipes=root/'recipes'
        command=[sys.executable,str(repo/'tools/prebuild_pch_v2.py'),str(cdb),'--recipes-dir',str(recipes)]
        assert c.pch_recipes(cdb,command)==0
        assert cdb.read_bytes()==before
        assert not list(recipes.glob('*PCH.A*')) and list(recipes.glob('*PCH.B*'))
        assert '-include-pch' not in json.loads(cdb.read_bytes())[0]['arguments']
    elif operation == 'native':
        import clangd_batch_runner as runner
        version,reason=c.probe_clangd(clangd)
        if reason or not c.supported_version(version):
            print(json.dumps({'unavailable':reason or 'requires tested clangd 22.1.5'}));raise SystemExit(77)
        def references(cdb,header,trigger):
            # Minimal real LSP session, loading the existing private shard cache.
            env=dict(os.environ);env['LOCALAPPDATA']=str(cdb/'native/environment');env['XDG_CACHE_HOME']=str(cdb/'native/environment/cache')
            stderr=(cdb/'query.stderr').open('wb')
            proc=subprocess.Popen([clangd,'--background-index','--enable-config=false','-j=1','--compile-commands-dir='+str(cdb)],
                cwd=cdb,env=env,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=stderr,
                creationflags=(subprocess.CREATE_NO_WINDOW|subprocess.IDLE_PRIORITY_CLASS) if os.name=='nt' else 0)
            messages=queue.Queue()
            def read():
                while True:
                    headers={}
                    while True:
                        line=proc.stdout.readline()
                        if not line:return
                        if line in (b'\r\n',b'\n'):break
                        k,v=line.decode().split(':',1);headers[k.lower()]=v.strip()
                    messages.put(json.loads(proc.stdout.read(int(headers['content-length']))))
            thread=threading.Thread(target=read,daemon=True);thread.start()
            def send(value):
                raw=json.dumps(dict(jsonrpc='2.0',**value)).encode();proc.stdin.write(('Content-Length: %d\r\n\r\n'%len(raw)).encode()+raw);proc.stdin.flush()
            def next_message(deadline):
                while time.monotonic()<deadline:
                    try:value=messages.get(timeout=.1)
                    except queue.Empty:continue
                    if 'id' in value and 'method' in value:send({'id':value['id'],'result':None})
                    return value
                raise AssertionError('LSP timeout')
            try:
                deadline=time.monotonic()+15
                send({'id':1,'method':'initialize','params':{'processId':os.getpid(),'rootUri':cdb.as_uri(),'capabilities':{'window':{'workDoneProgress':True}}}})
                while next_message(deadline).get('id')!=1:pass
                send({'method':'initialized','params':{}})
                send({'method':'textDocument/didOpen','params':{'textDocument':{'uri':trigger.as_uri(),'languageId':'cpp','version':1,'text':trigger.read_text()}}})
                while True:
                    event=next_message(deadline)
                    if event.get('method')=='$/progress' and event['params']['value'].get('kind')=='end':break
                text=header.read_text();line=next(i for i,s in enumerate(text.splitlines()) if s.startswith('template<class T> void InternalConstructor'))
                column=text.splitlines()[line].index('InternalConstructor')
                send({'method':'textDocument/didOpen','params':{'textDocument':{'uri':header.as_uri(),'languageId':'cpp','version':1,'text':text}}})
                send({'id':2,'method':'textDocument/references','params':{'textDocument':{'uri':header.as_uri()},'position':{'line':line,'character':column},'context':{'includeDeclaration':False}}})
                while True:
                    value=next_message(deadline)
                    if value.get('id')==2:break
                assert 'result' in value,value
                result={(x['uri'],x['range']['start']['line']) for x in value['result']}
                send({'id':3,'method':'shutdown','params':None})
                while next_message(deadline).get('id')!=3:pass
                send({'method':'exit','params':None});proc.wait(timeout=3)
                return result
            finally:
                if proc.poll() is None:proc.kill();proc.wait()
                thread.join(timeout=2);stderr.close()
        outcomes={}
        for fixed in (False,True):
            cdb=root/('fixed' if fixed else 'control');cdb.mkdir()
            sources=[];commands=[]
            for name,tag in (('a','A'),('b','B')):
                source=cdb/(name+'.cpp');source.write_text('#include "'+class_header.as_posix()+'"\nUSE('+tag+')\n');sources.append(source)
                wrapper=cdb/('wrapper_'+name+'.cpp');wrapper.write_text('#include "'+source.as_posix()+'"\n')
                commands.append(entry(wrapper))
            trigger=cdb/'trigger.cpp';trigger.write_text('// private trigger\n')
            native_cdb=cdb/'compile_commands.json';native_cdb.write_text(json.dumps(commands))
            if fixed:
                with patch.object(c,'_SUPPORTED_HEADERS',approved):
                    assert c.apply_policy(native_cdb,version,engine)['added']==2
                commands=json.loads(native_cdb.read_bytes())
            for command in commands:
                checked=subprocess.run([x for x in command['arguments'] if x!='-c']+['-fsyntax-only','-Werror'],capture_output=True,text=True,timeout=15,
                    creationflags=(subprocess.CREATE_NO_WINDOW|subprocess.IDLE_PRIORITY_CLASS) if os.name=='nt' else 0)
                assert checked.returncode==0,checked.stderr
            trigger_entry={'directory':str(cdb),'file':str(trigger),'arguments':[compiler,'-std=c++17',str(trigger)]}
            native_cdb.write_text(json.dumps(commands+[trigger_entry]))
            original_headers=[p.read_bytes() for p in (globals_header,class_header)]
            for revision in (None,*sources):
                if revision:
                    with revision.open('a') as stream:stream.write('// only this source changed\n')
                run=runner.run(cdb,cdb/'native',trigger,clangd,timeout=15,jobs=1)
                assert run['background_compile_success'],run
                if revision is None: cold=references(cdb,class_header,trigger)
            hot=references(cdb,class_header,trigger)
            assert [p.read_bytes() for p in (globals_header,class_header)]==original_headers
            expected={(p.as_uri(),1) for p in sources}
            if fixed:assert cold==hot==expected,(cold,hot,expected)
            else:assert hot==set(),hot
            outcomes[str(fixed)]={'cold':sorted(cold),'hot':sorted(hot)}
        print(json.dumps(outcomes))
    else:raise AssertionError(operation)
print('passed '+operation)
]=]

local function run_fixture(operation, clangd)
  local python = require("utils.platform").resolve_tool({ name = "python",
    driver_candidates = function(driver) return driver.python_candidates() end })
  if not python.ok then t.skip("friend-template fixture", python.reason, { native = operation == "native" }); return end
  local script = vim.fn.tempname() .. "_friend.py"
  local file = assert(io.open(script, "wb")); file:write(fixture); file:close()
  local result = vim.system({ python.path, "-B", "-I", script,
    vim.fn.stdpath("config"), operation, clangd or "" }, { text = true }):wait()
  os.remove(script)
  if result.code == 77 then t.skip("friend-template native compiler", result.stdout, { native = true }); return end
  t.assert_eq(result.code, 0, (result.stderr or "") .. (result.stdout or ""))
end

t.describe("UE friend-template first forced declaration", function()
  t.it("rejects unknown headers, versions, languages, response and binary PCH inputs", function() run_fixture("guards") end)
  t.it("fails stale owned prefixes without changing user arguments or partially writing the CDB", function() run_fixture("stale") end)
  t.it("preserves final Unity receipt bindings, argument order and repeated bytes", function() run_fixture("receipt") end)
  t.it("keeps only affected entries textual while retaining other PCH recipes", function() run_fixture("pch") end)
  t.it("orders the asynchronous step before recipes and supports disabling it", function()
    local workaround = require("workarounds.clangd.friend_template_canonical")
    workaround.apply()
    local steps = {
      { name = "expand_response_cdb", command = { "python", "expand.py" } },
      { name = "clangd_diagnostic_compat", command = { "python", "diagnostic.py" } },
      { name = "prebuild_pch_v2", command = { "python", "prebuild_pch_v2.py", "stage.json" } },
    }
    workaround.configure_steps(steps, "python", "stage.json", "/selected/clangd", "/resolved/UE")
    t.assert_eq(steps[3].name, "clangd_friend_template_canonical")
    t.assert_eq(steps[4].name, "prebuild_pch_v2")
    t.assert_true(vim.tbl_contains(steps[3].command, "/selected/clangd"))
    t.assert_true(vim.tbl_contains(steps[4].command, "--pch-command"))
    workaround.disable()
    local unchanged = vim.deepcopy(steps)
    workaround.configure_steps(steps, "python", "stage.json", "/selected/clangd", "/resolved/UE")
    t.assert_true(vim.deep_equal(steps, unchanged))
    workaround.apply()
  end)
  t.it("keeps the compatibility step inside the actual pipeline receipt transaction", function()
    local original = package.loaded["ue.cdb.pipeline"]
    local config = require("ue.config")
    local previous = vim.deepcopy(config.options())
    local path = vim.fn.tempname() .. ".json"
    vim.fn.writefile({ "[]" }, path)
    vim.fn.writefile({ '{"schema":1,"groups":[]}' }, path .. ".unity-origin.json")
    local calls = {}
    local ok, err = pcall(function()
      package.loaded["ue.cdb.pipeline"] = nil
      local pipeline = require("ue.cdb.pipeline")
      config.setup({ cdb = { steps = { "expand_response_cdb.py", "clangd_diagnostic_compat.py", "prebuild_pch_v2.py" } } })
      pipeline.set_runtime({ clangd_path = function() return "/selected/clangd" end,
        jobstart = function(command, _, opts)
          calls[#calls + 1] = { command = command, opts = opts }
          return 19
        end,
        notify = function() end, log_error = function() end, restart_clangd = function() end })
      pipeline.run(path, { path }, function() end,
        { _host_admitted = true, defer_restart = true, engine_root = "/resolved/UE" })
      local cursor = 1
      while pipeline.is_running() do calls[cursor].opts.on_exit(); cursor = cursor + 1 end
      local order, prefix_command = {}, nil
      for _, call in ipairs(calls) do
        local command = call.command
        if vim.tbl_contains(command, "begin") then order[#order + 1] = "begin"
        elseif vim.tbl_contains(command, "seal") then order[#order + 1] = "seal"
        elseif vim.tbl_contains(command, "complete") then order[#order + 1] = "complete"
        elseif vim.tbl_contains(command, "--pch-command") then order[#order + 1] = "pch"
        else
          for _, arg in ipairs(command) do
            if arg:match("expand_response_cdb%.py$") then order[#order + 1] = "expand"
            elseif arg:match("clangd_diagnostic_compat%.py$") then order[#order + 1] = "diagnostic"
            elseif arg:match("friend_template_canonical%.py$") then
              order[#order + 1] = "prefix"; prefix_command = command
            end
          end
        end
      end
      local expected = { "begin", "expand", "diagnostic", "prefix" }
      if type(require("utils.platform").driver().pch_build_plan) == "function" then expected[#expected + 1] = "pch" end
      vim.list_extend(expected, { "seal", "complete" })
      t.assert_true(vim.deep_equal(order, expected), vim.inspect(order))
      t.assert_true(vim.tbl_contains(prefix_command, "/resolved/UE"))
      t.assert_true(vim.tbl_contains(prefix_command, "/selected/clangd"))
    end)
    package.loaded["ue.cdb.pipeline"] = original
    config.setup(previous)
    os.remove(path); os.remove(path .. ".unity-origin.json")
    if not ok then error(err) end
  end)
  t.it("preserves precise native references after cold indexing and cached source changes", function()
    local tool = require("utils.platform").resolve_tool({ name = "clangd", env = { "UE_CLANGD" },
      config_candidates = require("utils.ue_goto.semantic_sidecar_libclang").discover_clangd_candidates() })
    if not tool.ok then t.skip("friend-template native compiler", tool.reason, { native = true }); return end
    run_fixture("native", tool.path)
  end)
end)
