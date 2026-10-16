local t = require("tests.harness")
t.bootstrap()

t.describe("frozen batch precise watch scopes", function()
  t.it("keeps inventories recursive and tools/assets direct without excluding producer stores", function()
    local python = vim.fn.exepath("python")
    if python == "" then t.skip("watch scope descriptor", "Python unavailable", { native = true }); return end
    local code = [=[
import hashlib,json,pathlib,sys,tempfile
sys.dont_write_bytecode=True
sys.path.insert(0,sys.argv[1])
import cdb_verified_batch as batch
import clangd_batch_activation as activation
with tempfile.TemporaryDirectory(prefix='batch-watch-scope-') as temporary:
    root=pathlib.Path(temporary).resolve()
    source=root/'source'; source.mkdir()
    store=root/'background-proofs'/'group'; assets=store/'assets'; assets.mkdir(parents=True)
    tool=root/'tools'/'clangd.exe'; tool.parent.mkdir(); tool.write_bytes(b'fixture identity only')
    original=root/'background'/'compile_commands.json'; original.parent.mkdir()
    original.write_text('[]')
    frozen=original.parent/'verified'/'compile_commands.json'; frozen.parent.mkdir(); frozen.write_text('[]')
    asset=assets/'snapshot.h'; asset.write_text('int fixture;')
    receipt=assets/'receipt.json'
    receipt.write_text(json.dumps({'schema':2,'dependencies':[{'path':str(source/'used.h'),'sha256':'fixture'}],
      'assets':[{'path':str(asset),'sha256':'fixture'}], 'inventories':{str(source):{'sha256':'fixture'}},
      'original_entries':[{'file':str(source/'unit.cpp'),'directory':str(source),'arguments':[]}],
      'identities':{'compiler_environment':{},'server_profile':None,'tool_path':str(tool)},
      'server_profile':None,'output_dir':str(store)}))
    info=root/'background'/'batches.json'
    info.write_text(json.dumps({'schema':1,'receipts':[str(receipt)],'receipt_hashes':{str(receipt):'fixture'},
      'original_cdb':str(original),'verified_cdb':str(frozen),'active_cdb':str(original),'generation_id':'fixture'}))
    result=activation.activate(info,str(tool))
    assert result['ok'],result
    recursive=set(map(pathlib.Path,result['watch_roots']))
    direct=set(map(pathlib.Path,result['lookup_roots']))
    assert recursive=={source},('identity parents broadened recursive source inputs',recursive)
    assert result['input_roots']==[str(source)],result
    assert tool.parent in direct and assets in direct and original.parent in direct
    assert store not in set(map(pathlib.Path,result['exclude_roots'])), 'production store exclusion hides true changes'
    watched=set(map(pathlib.Path,result['watched_files']))
    assert receipt in watched and asset in watched and tool in watched
    for filename in batch._COLLECTOR_FILES+batch._POLICY_FILES:
        assert (pathlib.Path(sys.argv[1])/filename).resolve() in watched,('unwatched policy file',filename)
    for path in (source,assets,tool.parent):
        for parent in path.parents:
            assert parent in direct or any(parent==r or r in parent.parents for r in recursive),('lost ancestor',parent)
    # Independent creation at the store changes its directory tree, while a
    # descriptor remains limited to the certified immutable asset file paths.
    scratch=store/'proof-unfinished'; scratch.mkdir(); (scratch/'pending.cpp').write_text('pending')
    assert not any(scratch==r or r in scratch.parents for r in recursive)
    print('watch scopes and ancestor coverage passed')
]=]
    local result = vim.system({ python, "-B", "-I", "-c", code, vim.fn.stdpath("config") .. "/tools" }, { text = true }):wait(10000)
    t.assert_eq(result.code, 0, (result.stderr or "") .. (result.stdout or ""))
  end)
end)
