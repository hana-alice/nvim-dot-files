local t = require('tests.harness')
t.bootstrap()
local candidate_path = vim.env.NVIM_PREPARE_SCAN_ROOTS_CANDIDATE
local roots = candidate_path and assert(loadfile(candidate_path))() or require('ue.cdb.prepare_scan_roots')
local ue = require('ue')
local scan = require('ue.core.scan_roots')

local function dirs(value)
  return value and value.dirs or value
end

local function write(root, relative, bytes)
  local path = root .. '/' .. relative
  vim.fn.mkdir(vim.fs.dirname(path), 'p')
  local file = assert(io.open(path, 'wb')); file:write(bytes or '// fixture\n'); file:close()
end

local function fixture(body)
  local parent = vim.env.NVIM_PREPARE_SCAN_ROOTS_TEST_ROOT or vim.fn.tempname()
  local directory = vim.fs.normalize(parent .. '-scan-root-' .. tostring(vim.uv.hrtime()))
  vim.fn.mkdir(directory, 'p')
  local ctx = {project_root = directory, engine_root = directory, paths = {cache = directory .. '/cache'}}
  local ok, err = xpcall(function() body(directory, ctx) end, debug.traceback)
  if roots.stop then roots.stop() end
  vim.fn.delete(directory, 'rf')
  if not ok then error(err) end
end

local function equivalent(ctx)
  local expected = ue._project_index_dirs_for_test(ctx)
  local value = roots.collect(ctx)
  t.assert_true(value.ok, value.reason)
  t.assert_type(value.wall_ms, 'number')
  local actual = dirs(value)
  t.assert_true(vim.deep_equal(actual, expected), 'scan-root policy drift: ' .. vim.inspect(actual))
  return actual
end

local function contains(values, wanted)
  return vim.tbl_contains(values, wanted)
end

t.describe('prepare scan-root collection preserves original metadata policy', function()
  t.it('nested project retains anchor defaults and sibling declared module', function()
    fixture(function(root, ctx)
      write(root, 'Source/Client/Client.uproject', '{}')
      write(root, 'Source/Client/Source/Runtime/Runtime.Build.cs')
      write(root, 'Source/Tools/Source/ToolMod/ToolMod.Build.cs')
      write(root, 'Source/Client/Shaders/a.usf')
      write(root, 'Source/JDK/bin/data.txt')
      local result = equivalent(ctx)
      t.assert_true(contains(result, 'Source/Client/Source'))
      t.assert_true(contains(result, 'Source/Client/Shaders'))
      t.assert_true(contains(result, 'Source/Tools/Source/ToolMod'))
      t.assert_false(contains(result, 'Source'))
      t.assert_false(contains(result, 'Source/JDK'))
    end)
  end)

  t.it('ambiguous nested projects never widen into naked Source or undeclared tools', function()
    fixture(function(root, ctx)
      write(root, 'Source/Client/A.uproject', '{}')
      write(root, 'Source/Other/B.uproject', '{}')
      write(root, 'Source/Client/Source/Runtime/Runtime.Build.cs')
      write(root, 'Source/JDK/bin/data.txt')
      local result = equivalent(ctx)
      t.assert_true(scan.is_ambiguous_nested(root))
      t.assert_true(contains(result, 'Source/Client'))
      t.assert_true(contains(result, 'Source/Other'))
      t.assert_false(contains(result, 'Source'))
      t.assert_false(contains(result, 'Source/JDK'))
    end)
  end)

  t.it('two uprojects in one directory remain ambiguous', function()
    fixture(function(root, ctx)
      write(root, 'Source/Client/A.uproject', '{}')
      write(root, 'Source/Client/B.uproject', '{}')
      local result = equivalent(ctx)
      t.assert_true(scan.is_ambiguous_nested(root))
      t.assert_true(contains(result, 'Source/Client'))
      t.assert_false(contains(result, 'Source'))
    end)
  end)

  t.it('standard project retains root defaults and never scans the whole root', function()
    fixture(function(root, ctx)
      write(root, 'Game.uproject', '{}')
      write(root, 'Source/Mod/Mod.Build.cs')
      write(root, 'Shaders/no-declaration.usf')
      write(root, 'Content/Movies/data.txt')
      local result = equivalent(ctx)
      t.assert_true(contains(result, 'Source'))
      t.assert_true(contains(result, 'Shaders'))
      t.assert_true(contains(result, 'Config'))
      t.assert_false(contains(result, ''))
      t.assert_false(contains(result, '.'))
      t.assert_false(contains(result, '/'))
    end)
  end)

  t.it('explicit nonempty whitelist wins without discovered module additions', function()
    fixture(function(root, ctx)
      write(root, 'Source/Client/Client.uproject', '{}')
      write(root, 'Source/Other/Source/Mod/Mod.Build.cs')
      write(root, '.ueprepare-scan-paths', '# comment\r\nSource/Client/Source\r\n  CustomShaders # comment\r\n')
      t.assert_true(vim.deep_equal(equivalent(ctx), {'Source/Client/Source', 'CustomShaders'}))
    end)
  end)

  t.it('empty whitelist falls back to discovery plus the original defaults', function()
    fixture(function(root, ctx)
      write(root, 'Game.uproject', '{}')
      write(root, 'CustomModule/Custom.build.cs')
      write(root, '.ueprepare-scan-paths', '# comment\r\n  \r\n')
      local result = equivalent(ctx)
      t.assert_true(contains(result, 'CustomModule'))
      t.assert_true(contains(result, 'Source'))
      t.assert_true(contains(result, 'Shaders'))
    end)
  end)

  t.it('exclusions and recursive depth bound preserve the unchanged metadata policy', function()
    fixture(function(root, ctx)
      write(root, 'Source/Client/Client.uproject', '{}')
      write(root, 'CustomModule/Custom.BUILD.CS')
      for _, excluded in ipairs(scan.DEFAULT_EXCLUDES) do
        write(root, excluded .. '/Generated/Generated.Build.cs')
      end
      write(root, 'deep/a/b/c/d/e/f/g/Deep.Build.cs')
      local result = equivalent(ctx)
      t.assert_true(contains(result, 'CustomModule'))
      for _, entry in ipairs(result) do
        t.assert_false(entry:find('Generated', 1, true))
        t.assert_false(entry:find('deep/', 1, true))
      end
    end)
  end)

  t.it('parent metadata errors propagate without silently returning a smaller set', function()
    local original = ue._project_index_dirs_for_test
    ue._project_index_dirs_for_test = function() error('deliberate collector failure') end
    local value = roots.collect({project_root = ''})
    ue._project_index_dirs_for_test = original
    t.assert_false(value.ok); t.assert_nil(value.dirs)
    t.assert_contains(value.reason, 'deliberate collector failure')
  end)
end)

t.describe('prepare input inventory binds pure tool roots without weakening source roots', function()
  local inventory = require('ue.cdb.prepare_inputs')
  local function inputs(body)
    fixture(function(root)
      for _, path in ipairs({'engine/Source/a.cpp', 'config/lua/init.lua',
        'config/tools/tool.py', 'config/scripts/task.lua', 'toolchain/bin/compiler.bin',
        'toolchain/lib/clang/include/builtin.h', 'toolchain/bin/libclang.bin',
        'sdk/include/sdk.h'}) do write(root, path, 'aaaa') end
      local cdb = root .. '/engine/compile_commands.json'
      local request = {ctx = {engine_root = root .. '/engine', project_root = root .. '/engine'},
        config_root = root .. '/config', active_cdb = cdb}
      local function publish(arguments)
        write(root, 'engine/compile_commands.json', vim.json.encode({{
          directory = root .. '/engine', file = root .. '/engine/Source/a.cpp',
          arguments = arguments or {root .. '/toolchain/bin/compiler.bin', '-c', root .. '/engine/Source/a.cpp'},
        }}))
      end
      publish()
      body(root, request, publish)
    end)
  end
  local function find_tools(result, suffix)
    for _, item in ipairs(result.tools or {}) do
      if item.path:sub(-#suffix) == suffix then return item end
    end
  end
  t.it('compiler resource files are identity-bound and only external tool roots are classified', function()
    inputs(function(root, request)
      local result = inventory.collect(request)
      t.assert_true(result.ok, result.reason)
      t.assert_true(vim.tbl_contains(result.tool_roots, root .. '/toolchain'))
      for _, item in ipairs(result.roots) do
        if item.path == root .. '/toolchain' then t.assert_true(item.tool_root)
        else t.assert_nil(item.tool_root) end
      end
      for _, suffix in ipairs({'compiler.bin', 'builtin.h', 'lib/clang/include'}) do
        local item = find_tools(result, suffix)
        t.assert_type(item, 'table', suffix)
        for _, field in ipairs({'size', 'mtime', 'ctime', 'ino', 'dev', 'realpath'}) do
          t.assert_true(item.identity[field] ~= nil, 'missing tool identity ' .. field)
        end
      end
      t.assert_nil(find_tools(result, 'libclang.bin'), 'unused sibling is outside bound input subtrees')
      t.assert_true(inventory.verify_tools(result.tools).ok)
      write(root, 'toolchain/lib/clang/9.0.9/include/nested/legacy.h', 'legacy')
      write(root, 'other/bin/compiler.bin', 'driver')
      write(root, 'other/lib64/clang/23/include/new.h', 'builtin')
      write(root, 'engine/compile_commands.json', vim.json.encode({
        {directory = root .. '/engine', file = root .. '/engine/Source/a.cpp',
          arguments = {root .. '/toolchain/bin/compiler.bin', '-c', root .. '/engine/Source/a.cpp'}},
        {directory = root .. '/engine', file = root .. '/engine/Source/a.cpp',
          arguments = {root .. '/other/bin/compiler.bin', '-c', root .. '/engine/Source/a.cpp'}},
        {directory = root .. '/config', file = root .. '/engine/Source/a.cpp',
          arguments = {root .. '/toolchain/bin/compiler.bin', '-c', root .. '/engine/Source/a.cpp'}},
      }))
      result = inventory.collect(request)
      t.assert_true(result.ok, result.reason)
      t.assert_type(find_tools(result, 'legacy.h'), 'table', 'versioned nested implicit resource')
      t.assert_type(find_tools(result, 'new.h'), 'table', 'second argv driver lib64 resource')
      local resource_trees = 0
      for _, tree in ipairs(result.tool_input_trees) do
        if tree == root .. '/toolchain/lib/clang/include' then resource_trees = resource_trees + 1 end
      end
      t.assert_eq(resource_trees, 2, 'lexical/physical resource trees are not multiplied by command cwd')
      t.assert_true(inventory.verify_tools(result.tools).ok)
    end)
  end)
  t.it('explicit resource and sysroot argv introduce tool roots without classifying engine', function()
    inputs(function(root, request, publish)
      publish({root .. '/toolchain/bin/compiler.bin', '-resource-dir', root .. '/toolchain/lib/clang',
        '--sysroot=' .. root .. '/sdk', '-c', root .. '/engine/Source/a.cpp'})
      local result = inventory.collect(request)
      t.assert_true(result.ok, result.reason)
      t.assert_true(vim.tbl_contains(result.tool_roots, root .. '/sdk'))
      t.assert_type(find_tools(result, 'sdk.h'), 'table')
      publish({root .. '/toolchain/bin/compiler.bin', '--sysroot=' .. root .. '/engine',
        '-c', root .. '/engine/Source/a.cpp'})
      result = inventory.collect(request)
      t.assert_true(result.ok, result.reason)
      t.assert_false(vim.tbl_contains(result.tool_roots, root .. '/engine'))
    end)
  end)
  t.it('same-size used tool rewrite with restored mtime changes ctime and revokes identity', function()
    inputs(function(root, request)
      local result = inventory.collect(request)
      t.assert_true(result.ok, result.reason)
      local item = assert(find_tools(result, 'builtin.h'))
      local stat = assert(vim.uv.fs_stat(item.path))
      vim.wait(20)
      write(root, 'toolchain/lib/clang/include/builtin.h', 'bbbb')
      t.assert_true(vim.uv.fs_utime(item.path, stat.atime.sec + stat.atime.nsec / 1e9,
        stat.mtime.sec + stat.mtime.nsec / 1e9))
      local changed = assert(vim.uv.fs_stat(item.path))
      t.assert_eq(changed.size, stat.size)
      t.assert_false(vim.deep_equal(changed.ctime, stat.ctime), 'host change-time identifies restored-mtime rewrite')
      local verified = inventory.verify_tools(result.tools)
      t.assert_false(verified.ok)
      t.assert_contains(verified.reason, 'tool-changed:')
    end)
  end)
  t.it('new tool directory membership conservatively revokes and missing tool fails closed', function()
    inputs(function(root, request)
      local result = inventory.collect(request)
      t.assert_true(result.ok, result.reason)
      write(root, 'toolchain/unrelated.txt', 'new')
      t.assert_false(inventory.verify_tools(result.tools).ok,
        'new headers/configuration may shadow old inputs, including unknown new files')
      vim.fn.delete(root .. '/toolchain/bin/compiler.bin')
      t.assert_false(inventory.verify_tools(result.tools).ok)
    end)
  end)
  t.it('missing explicit tool directory fails closed instead of ancestor classification', function()
    inputs(function(root, request, publish)
      publish({root .. '/toolchain/bin/compiler.bin', '--gcc-toolchain=' .. root .. '/missing',
        '-c', root .. '/engine/Source/a.cpp'})
      local result = inventory.collect(request)
      t.assert_false(result.ok)
      t.assert_contains(result.reason, 'tool directory unavailable:')
      vim.fn.delete(root .. '/toolchain/lib/clang', 'rf')
      publish()
      result = inventory.collect(request)
      t.assert_false(result.ok, 'unprovable implicit resource inputs must disable reuse')
      t.assert_contains(result.reason, 'compiler resource directory unavailable:')
    end)
  end)
  t.it('origin source members inside a nominal toolchain retain writable barriers', function()
    inputs(function(root, request)
      write(root, 'toolchain/Source/member.cpp', 'source')
      write(root, 'engine/compile_commands.json.unity-origin.json', vim.json.encode({groups = {{
        unity = root .. '/engine/Source/a.cpp', members = {root .. '/toolchain/Source/member.cpp'},
      }}}))
      local result = inventory.collect(request)
      t.assert_true(result.ok, result.reason)
      t.assert_false(vim.tbl_contains(result.tool_roots, root .. '/toolchain'))
    end)
  end)
  t.it('bound tool subtrees retain __pycache__ file and directory identities', function()
    inputs(function(root, request)
      write(root, 'toolchain/lib/clang/include/__pycache__/resource.bin', 'resource')
      write(root, 'toolchain/lib/__pycache__/unrelated.bin', 'unrelated')
      local result = inventory.collect(request)
      t.assert_true(result.ok, result.reason)
      t.assert_type(find_tools(result, 'resource.bin'), 'table')
      local directory = assert(find_tools(result, '__pycache__'))
      t.assert_eq(directory.identity.type, 'directory')
      t.assert_nil(find_tools(result, 'unrelated.bin'), 'unbound tool data need not be snapshotted')
    end)
  end)
  local probe_root = vim.fs.normalize(vim.fn.tempname() .. '-junction-capability')
  vim.fn.mkdir(probe_root .. '/target', 'p')
  local junction_options = {dir = true, junction = vim.uv.os_uname().sysname:match('Windows') ~= nil}
  local junction_supported, junction_reason = vim.uv.fs_symlink(probe_root .. '/target', probe_root .. '/link', junction_options)
  if junction_supported then assert(vim.uv.fs_unlink(probe_root .. '/link')) end
  vim.fn.delete(probe_root, 'rf')
  if not junction_supported then
    t.skip('source __pycache__ junction retains external input coverage',
      'actual host directory-link creation unavailable: ' .. tostring(junction_reason), {native = true})
  else
    t.it('source __pycache__ junction retains external input coverage', function()
      inputs(function(root, request)
        local external, link = root .. '/junction-external', root .. '/engine/Source/__pycache__/linked'
        write(root, 'junction-external/External.h', 'external input')
        vim.fn.mkdir(vim.fs.dirname(link), 'p')
        t.assert_true(vim.uv.fs_symlink(external, link, junction_options))
        local ok, err = xpcall(function()
          local result = inventory.collect(request)
          t.assert_true(result.ok, result.reason)
          local physical = vim.fs.normalize(assert(vim.uv.fs_realpath(external)))
          t.assert_true(vim.iter(result.roots):any(function(item) return item.path == physical end),
            'source caches may contain junctions to real compiler inputs')
        end, debug.traceback)
        assert(vim.uv.fs_unlink(link))
        if not ok then error(err) end
      end)
    end)
  end
end)

t.describe('prepare scan-root handoff retains observation and writer ownership', function()
  local function handoff(body)
    local cache = require('ue.cdb.prepare_cache')
    local old_begin, old_status, old_start, old_running = cache.begin, cache.status, roots.start, ue._prepare_running
    local epoch, observed, started, continued, failed, callback, reuse = 4, false, 0, {}, {}, nil, false
    local lease = {}
    local rt = { prepare_lease = lease, project_index_dirs_cache = {} }
    cache.begin = function(_, _, done) observed = true; done(reuse) end
    cache.status = function() return { epoch = epoch } end
    roots.start = function(_, done)
      t.assert_true(observed, 'observation must precede discovery')
      started = started + 1; callback = done
    end
    ue._prepare_running = true
    local ctx = { project_root = 'C:/Fixture' }
    local state = {
      rt = rt, ctx = ctx, continued = continued, failed = failed,
      set_epoch = function(value) epoch = value end,
      set_reuse = function(value) reuse = value end,
      started = function() return started end,
      deliver = function(dirs, err) callback(dirs, err) end,
      begin = function()
        roots.begin(ctx, {}, rt, lease, function(hit) continued[#continued + 1] = hit end,
          function(err) failed[#failed + 1] = err end)
      end,
    }
    local ok, err = xpcall(function() body(state) end, debug.traceback)
    cache.begin, cache.status, roots.start, ue._prepare_running = old_begin, old_status, old_start, old_running
    if not ok then error(err) end
  end

  t.it('reused evidence and already cached roots launch no new discovery', function()
    handoff(function(s)
      s.set_reuse(true); s.begin()
      t.assert_eq(s.started(), 0); t.assert_eq(s.continued[1], true)
      s.set_reuse(false); s.rt.project_index_dirs_cache['C:/Fixture'] = {'Source'}; s.begin()
      t.assert_eq(s.started(), 0); t.assert_eq(s.continued[2], false)
    end)
  end)
  t.it('successful observed discovery primes the exact original cache', function()
    handoff(function(s)
      s.begin(); t.assert_eq(s.started(), 1)
      local dirs = {'Source', 'Shaders'}; s.deliver(dirs)
      t.assert_true(s.rt.project_index_dirs_cache['C:/Fixture'] == dirs)
      t.assert_eq(s.continued[1], false); t.assert_eq(#s.failed, 0)
    end)
  end)
  t.it('changed epoch rejects results without priming cache or continuing', function()
    handoff(function(s)
      s.begin(); s.set_epoch(5); s.deliver({'Source'})
      t.assert_nil(s.rt.project_index_dirs_cache['C:/Fixture']); t.assert_eq(#s.continued, 0)
      t.assert_eq(#s.failed, 1); t.assert_contains(s.failed[1], 'inputs changed')
    end)
  end)
  t.it('replaced writer lease suppresses a late result', function()
    handoff(function(s)
      s.begin(); s.rt.prepare_lease = {}; s.deliver({'Source'})
      t.assert_nil(s.rt.project_index_dirs_cache['C:/Fixture'])
      t.assert_eq(#s.continued, 0); t.assert_eq(#s.failed, 0)
    end)
  end)
  t.it('late input-evidence callback cannot reuse cached roots or start discovery after lease replacement', function()
    for _, cached in ipairs({false, true}) do
      handoff(function(s)
        local cache, late = require('ue.cdb.prepare_cache'), nil
        cache.begin = function(_, _, done) late = done end
        if cached then s.rt.project_index_dirs_cache['C:/Fixture'] = {'Source'} end
        s.begin(); s.rt.prepare_lease = {}; late(false)
        t.assert_eq(s.started(), 0); t.assert_eq(#s.continued, 0); t.assert_eq(#s.failed, 0)
      end)
    end
  end)
  t.it('worker failure preserves cache and fails the prepare handoff', function()
    handoff(function(s)
      s.begin(); s.deliver(nil, 'worker failed')
      t.assert_nil(s.rt.project_index_dirs_cache['C:/Fixture']); t.assert_eq(#s.continued, 0)
      t.assert_eq(s.failed[1], 'worker failed')
    end)
  end)
end)

-- Native executable and unchanged host admission remain real. The only failure
-- injection is corrupting the small request, then launching the actual worker.
t.describe('prepare scan-root worker never falls back into parent computation', function()
  local function worker_fixture(body)
    fixture(function(root, ctx)
      local system, tempname, collector = vim.system, vim.fn.tempname, ue._project_index_dirs_for_test
      local cancel, parent_calls, native_starts = nil, 0, 0
      vim.fn.tempname = function() return root .. '/worker-request-' .. tostring(vim.uv.hrtime()) end
      ue._project_index_dirs_for_test = function()
        parent_calls = parent_calls + 1
        error('parent synchronous collector must not run during worker start')
      end
      local evidence = {system = system, starts = function() return native_starts end,
        parent_calls = function() return parent_calls end}
      vim.system = function(command, options, callback)
        t.assert_eq(command[1], vim.v.progpath, 'actual native Neovim executable')
        native_starts = native_starts + 1
        return system(command, options, callback)
      end
      local ok, err = xpcall(function()
        cancel = body(root, ctx, evidence, collector)
      end, debug.traceback)
      if cancel then cancel() end
      vim.system, vim.fn.tempname, ue._project_index_dirs_for_test = system, tempname, collector
      if not ok then error(err) end
    end)
  end

  local function await(ctx)
    local done, result, failure, stats, calls = false, nil, nil, nil, 0
    local cancel = roots.start(ctx, function(r, e, s)
      result, failure, stats, calls, done = r, e, s, calls + 1, true
    end)
    local ok = vim.wait(15000, function() return done end, 10)
    if not ok then cancel() end
    t.assert_true(ok, 'real scan-root worker timeout')
    vim.wait(50)
    t.assert_eq(calls, 1, 'only one terminal callback')
    return result, failure, stats, cancel
  end

  t.it('real admitted worker reproduces nested roots without calling parent collector', function()
    worker_fixture(function(root, ctx, evidence, original)
      write(root, 'Source/Client/Client.uproject', '{}')
      write(root, 'Source/Tools/Tool.Build.cs')
      local expected = original(ctx)
      local result, failure, stats, cancel = await(ctx)
      t.assert_nil(failure); t.assert_true(vim.deep_equal(result, expected))
      t.assert_type(stats.worker_ms, 'number')
      t.assert_eq(evidence.starts(), 1); t.assert_eq(evidence.parent_calls(), 0)
      return cancel
    end)
  end)

  t.it('real worker preserves whitelist precedence and path order', function()
    worker_fixture(function(root, ctx, evidence, original)
      write(root, 'Source/Unlisted/Unlisted.Build.cs')
      write(root, '.ueprepare-scan-paths', 'OnlyShaders\nCustom/Source\n')
      local expected = original(ctx)
      local result, failure, _, cancel = await(ctx)
      t.assert_nil(failure); t.assert_true(vim.deep_equal(result, expected))
      t.assert_eq(evidence.starts(), 1); t.assert_eq(evidence.parent_calls(), 0)
      return cancel
    end)
  end)

  t.it('malformed request makes actual worker fail with no synchronous fallback', function()
    worker_fixture(function(_, ctx, evidence)
      vim.system = function(command, options, callback)
        t.assert_eq(command[1], vim.v.progpath)
        local file = assert(io.open(command[#command], 'wb')); file:write('{invalid'); file:close()
        return evidence.system(command, options, callback)
      end
      local result, failure, _, cancel = await(ctx)
      t.assert_nil(result); t.assert_type(failure, 'string')
      t.assert_eq(evidence.parent_calls(), 0)
      return cancel
    end)
  end)

  t.it('spawn error returns one failure without synchronous fallback', function()
    worker_fixture(function(_, ctx, evidence)
      vim.system = function(command)
        t.assert_eq(command[1], vim.v.progpath)
        error('deliberate native spawn seam failure')
      end
      local result, failure, _, cancel = await(ctx)
      t.assert_nil(result); t.assert_contains(failure, 'deliberate native spawn seam failure')
      t.assert_eq(evidence.parent_calls(), 0)
      return cancel
    end)
  end)

  t.it('cancel only stops its actual owned worker and suppresses callback', function()
    worker_fixture(function(_, ctx, evidence)
      local process, kills, calls = nil, 0, 0
      vim.system = function(command, options, callback)
        t.assert_eq(command[1], vim.v.progpath)
        process = evidence.system(command, options, callback)
        local original_kill = process.kill
        process.kill = function(self, signal)
          t.assert_eq(self, process); kills = kills + 1
          return original_kill(self, signal)
        end
        return process
      end
      local cancel = roots.start(ctx, function() calls = calls + 1 end)
      if not vim.wait(15000, function() return process ~= nil end, 1) then
        cancel(); error('cancel test: actual worker did not start')
      end
      cancel(); cancel()
      vim.wait(150)
      t.assert_eq(kills, 1, 'owned worker stopped once')
      t.assert_eq(calls, 0); t.assert_eq(evidence.parent_calls(), 0)
      return cancel
    end)
  end)
end)
