local t = require("tests.harness")
t.bootstrap()

local fixture = [=[
import copy, json, os, pathlib, shutil, subprocess, sys, tempfile, time
sys.dont_write_bytecode = True
sys.path.insert(0, sys.argv[1])
import clangd_query_profile as profile
clangd, mode = pathlib.Path(sys.argv[2]).resolve(), sys.argv[3]
driver = clangd.with_name('clang++.exe')
assert driver.is_file(), 'real installed Clang C++ driver required'
class PrivateDirectory(tempfile.TemporaryDirectory):
    def cleanup(self):
        # A real cloned executable can briefly remain locked after its queries
        # exit. Retry only Windows sharing violations; retain every other error
        # and fail if the owned directory cannot be removed within two seconds.
        deadline = time.monotonic() + 2
        while True:
            try:
                return super().cleanup()
            except PermissionError as error:
                if getattr(error, 'winerror', None) != 32 or time.monotonic() >= deadline:
                    raise
                time.sleep(0.05)
with PrivateDirectory(prefix='query_profile_') as temporary:
    root = pathlib.Path(temporary).resolve()
    sysroot = root / 'private sysroot'
    include = sysroot / 'usr/include'
    include.mkdir(parents=True)
    (include / 'stddef.h').write_text('#define QUERY_PROFILE_HEADER 739\n')
    source = root / 'main.cpp'
    source.write_text('#include <stddef.h>\nint query_profile;\n')
    entry = {'directory': str(root), 'file': str(source), 'arguments': [str(driver),
        '--target=aarch64-none-linux-android23', '--sysroot=' + str(sysroot),
        '-x', 'c++', '-std=c++17', '-DKEEP_ORIGINAL=1', '-c', str(source)]}
    if mode == 'implicit':
        # An identical real compiler, not a fake executable or fabricated host.
        # Empty builtin directory suffices for the empty-input driver query.
        install = root / 'actual compiler'
        (install / 'bin').mkdir(parents=True)
        (install / 'lib/clang/22/include').mkdir(parents=True)
        cloned = install / 'bin/clang++.exe'
        shutil.copyfile(driver, cloned)
        assert profile._file_hash(cloned) == profile._file_hash(driver)
        entry['arguments'][0] = str(cloned)
    allow = '**/clang*.exe,**/clang*'
    def observe(**overrides):
        values = dict(entry=entry, clangd_path=str(clangd), query_driver=allow,
                      output_dir=root / ('proof-' + str(len(list(root.glob('proof-*'))))),
                      launch_cwd=str(root))
        values.update(overrides)
        return profile.observe(**values)
    if mode == 'reject':
        assert observe(launch_cwd=None)['reason'] == 'launch-cwd-required'
        assert observe(query_driver='')['reason'] == 'query-driver-required'
        for flag in ('@args.rsp', '--config=implicit.cfg', '-Xclang', '-specs=custom', '-resource-dir=alternate'):
            bad = copy.deepcopy(entry); bad['arguments'].insert(1, flag)
            assert not observe(entry=bad)['ok'], flag
        bad = copy.deepcopy(entry); bad['arguments'] = [a for a in bad['arguments'] if not a.startswith('--target=')]
        assert not observe(entry=bad)['ok']
        bad = copy.deepcopy(entry); bad['command'] = 'ignored'; del bad['arguments']
        assert not observe(entry=bad)['ok']
        bad = copy.deepcopy(entry); bad['arguments'][2] = '--sysroot=relative'
        assert not observe(entry=bad)['ok']
        assert not list(root.glob('proof-*')), 'unsupported profiles must reject before spawning/writing'
    else:
        result = observe()
        assert result['ok'], result
        evidence = result['evidence']
        assert evidence['driver']['sha256'] and evidence['clangd']['sha256']
        assert evidence['profile']['launch_cwd'] == root.as_posix()
        assert evidence['profile']['query_driver'] == allow
        assert evidence['tuple']['Target'] == 'aarch64-none-linux-android23'
        assert evidence['ordered_includes'] == evidence['observed_includes']
        assert evidence['target'] == evidence['observed_target']
        assert evidence['query']['returncode'] == 0 and evidence['builtin_query']['returncode'] == 0
        assert pathlib.Path(evidence['driver']['path']).parent.parent.as_posix() in evidence['implicit_search_roots']
        assert evidence['clangd_run']['terminated_after_command']
        assert evidence['entry']['arguments'] == entry['arguments'], 'original flags must remain exact'
        if mode == 'observe':
            denied = observe(query_driver='**/this-driver-does-not-exist')
            assert not denied['ok'], denied
            bare = copy.deepcopy(entry); bare['arguments'][0] = 'clang++'
            discovered = observe(entry=bare)
            assert discovered['ok'], discovered
            assert root.as_posix() in discovered['evidence']['driver_search_roots']
            assert (root / 'clang++.exe').as_posix() in discovered['evidence']['driver_candidates']
            assert all((pathlib.Path(path) / 'clang++').as_posix() in discovered['evidence']['driver_candidates']
                       for path in discovered['evidence']['driver_search_roots']), 'suffix-zero candidates can precede application-directory exe'
            assert pathlib.Path(discovered['evidence']['driver']['path']).is_file()
        elif mode == 'validate':
            def validate(record, **overrides):
                kwargs = dict(launch_cwd=str(root)); kwargs.update(overrides)
                return profile.validate(record, entry, str(clangd), allow, root / 'validation', **kwargs)
            verified = validate(evidence)
            assert verified['ok'], verified
            unrelated = dict(os.environ); unrelated['TEMP'] = str(root); unrelated['PROFILE_TEST_SECRET'] = 'not-for-evidence'
            equivalent = validate(evidence, environment=unrelated)
            assert equivalent['ok'], equivalent
            assert 'not-for-evidence' not in json.dumps(equivalent['evidence'])
            forged = copy.deepcopy(evidence); forged['driver']['sha256'] = '0' * 64
            assert not validate(forged)['ok']
            changed = dict(os.environ); changed['CPATH'] = str(include)
            assert not validate(evidence, environment=changed)['ok']
            assert not validate(evidence, launch_cwd=None)['ok']
        elif mode == 'logs':
            log = pathlib.Path(evidence['clangd_run']['stderr_path']).read_text(encoding='utf-8')
            for broken in (log.split('got target:')[0], log + '\n' + log,
                           log.replace('Compile command from CDB is:', 'Generic fallback command is:')):
                try:
                    profile._parse_clangd_output(broken, evidence['entry'], evidence['clangd_run']['cdb_path'])
                except ValueError:
                    pass
                else:
                    raise AssertionError('ambiguous/truncated/fallback evidence accepted')
        elif mode == 'header':
            base = [a for a in entry['arguments'][1:] if a not in ('-c', str(source))]
            def macros(additions):
                command = [evidence['driver']['path'], *base, *additions, '-E', '-dM', str(source)]
                done = subprocess.run(command, capture_output=True, timeout=10, cwd=root)
                assert done.returncode == 0, done.stderr.decode()
                return done.stdout
            additions = [item for path in evidence['ordered_includes'] for item in ('-isystem', path)]
            assert b'QUERY_PROFILE_HEADER' not in macros([])
            assert b'#define QUERY_PROFILE_HEADER 739' in macros(additions)
            assert b'#define KEEP_ORIGINAL 1' in macros(additions)
        elif mode == 'implicit':
            assert evidence['implicit_search_roots'] == [install.as_posix()]
            # Android silently requires a target-specific libc++ directory;
            # neither missing candidate appears in the original -v search log.
            generic = install / 'include/c++/v1'
            target = install / 'include/aarch64-none-linux-android23/c++/v1'
            before = pathlib.Path(evidence['clangd_run']['stderr_path']).read_text(encoding='utf-8')
            assert str(generic) not in before and str(target) not in before
            generic.mkdir(parents=True); target.mkdir(parents=True)
            (generic / 'query-created.hpp').write_text('#define NEW_INSTALL_INCLUDE 1\n')
            changed = profile.validate(evidence, entry, str(clangd), allow, root / 'changed-implicit', launch_cwd=str(root))
            assert not changed['ok'] and changed['reason'] == 'query-profile-changed', changed
            observed = [profile._key(path) for path in changed['evidence']['ordered_includes']]
            assert profile._key(generic) in observed and profile._key(target) in observed
        else:
            raise AssertionError(mode)
print('ok')
]=]

t.describe("native query driver profile", function()
  local clangd = vim.env.UE_CLANGD or vim.fn.exepath("clangd")
  local python = vim.fn.exepath("python")
  if python == "" then python = vim.fn.exepath("python3") end
  if clangd == "" or python == "" or not require("utils.platform").is_windows then
    t.skip("Windows native query profile", "Windows, real clangd and Python required", { native = true })
    return
  end
  local cases = {
    { "reject", "rejects unsupported arguments and missing explicit launch context before spawning" },
    { "observe", "binds native extractor success to actual driver bytes and ordered query output" },
    { "validate", "rediscovers the driver and rejects changed evidence or environment" },
    { "logs", "rejects truncated ambiguous and fallback native logs" },
    { "header", "real query additions change header selection while preserving original flags" },
    { "implicit", "real Android driver discovers newly created unlogged installation headers" },
  }
  for _, case in ipairs(cases) do
    t.it(case[2], function()
      local script = vim.fn.tempname() .. "_query_profile.py"
      local file = assert(io.open(script, "wb")); file:write(fixture); file:close()
      local result = vim.system({ python, "-B", "-I", script,
        vim.fn.stdpath("config") .. "/tools", clangd, case[1] }, { text = true }):wait(45000)
      vim.fn.delete(script)
      t.assert_eq(result.code, 0, (result.stderr or "") .. (result.stdout or ""))
      t.assert_eq(vim.trim(result.stdout), "ok")
    end)
  end
end)
