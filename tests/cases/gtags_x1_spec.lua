local t = require('tests.harness')
t.bootstrap()
local gtags = require('ue.gtags')
local fs = require('ue.core.fs')
local function fixture()
  local dir = vim.fn.tempname():gsub('\\', '/') .. '-gtags-x1'
  local engine, project = dir .. '/engine', dir .. '/project'
  vim.fn.mkdir(engine, 'p'); vim.fn.mkdir(project, 'p')
  vim.fn.writefile({ 'float EngineWitness() { return 1; }' }, engine .. '/sample.ush')
  vim.fn.writefile({ 'float ProjectWitness() { return 2; }' }, project .. '/sample.ush')
  vim.fn.writefile({ 'sample.ush' }, dir .. '/engine.files')
  vim.fn.writefile({ 'sample.ush' }, dir .. '/project.files')
  local ctx = { engine_root = engine, project_root = project,
    paths = { workspace_db = dir .. '/db', engine_list = dir .. '/engine.files', project_list = dir .. '/project.files' } }
  local spec = gtags.workspace_spec(ctx)
  spec.first_executable = function() return 'gtags' end
  local calls = {}
  spec.run_lines = function(cmd, opts)
    calls[#calls + 1] = { cmd = cmd, opts = opts }
    if cmd[1] == 'gtags' then
      t.assert_eq(opts.env.GTAGSLABEL, 'hlsl-cpp')
      t.assert_true(opts.env.GTAGSCONF:match('/gtags.conf$') ~= nil)
      t.assert_contains(table.concat(vim.fn.readfile(opts.env.GTAGSCONF), '\n'), '.hlsl.hlsli.glsl:')
      for _, name in ipairs({ 'GTAGS', 'GRTAGS', 'GPATH' }) do vim.fn.writefile({ 'fixture' }, cmd[#cmd] .. '/' .. name) end
      return 0, {}
    end
    local symbol = opts.cwd == engine and 'EngineWitness' or 'ProjectWitness'
    return 0, { symbol .. ' 1 ' .. opts.cwd .. '/sample.ush float ' .. symbol .. '() {' }
  end
  return ctx, spec, calls, dir
end

t.describe('GTAGS X1 parser evidence and independent roots', function()
  t.it('exit zero and nonempty triplet without definitions cannot publish ready', function()
    local ctx, spec = fixture()
    local run = spec.run_lines
    spec.run_lines = function(cmd, opts)
      if cmd[1] == 'global' then return 0, {} end
      return run(cmd, opts)
    end
    local ok, reason = gtags.build_sync(spec)
    t.assert_false(ok); t.assert_contains(reason, 'positive-witness-missing')
    t.assert_false(fs.is_file(ctx.paths.workspace_db .. '.roots.json'))
  end)
  t.it('ignored warning with exit zero is a coverage failure', function()
    local _, spec = fixture()
    local run = spec.run_lines
    spec.run_lines = function(cmd, opts)
      local code, lines = run(cmd, opts)
      if cmd[1] == 'gtags' then return 0, { "Warning: 'other.ush' is out of source tree. ignored." } end
      return code, lines
    end
    local ok, reason = gtags.build_sync(spec)
    t.assert_false(ok); t.assert_contains(reason, 'coverage-missing')
  end)
  t.it('same symbol in a different source cannot satisfy the input witness', function()
    local _, spec = fixture()
    local run = spec.run_lines
    spec.run_lines = function(cmd, opts)
      if cmd[1] == 'global' then return 0, { 'EngineWitness 1 other.ush float EngineWitness() {' } end
      return run(cmd, opts)
    end
    t.assert_false(gtags.build_sync(spec))
  end)
  t.it('both roots are verified before publication and asynchronous query combines them serially', function()
    local ctx, spec, calls = fixture()
    local ok, reason = gtags.build_sync(spec)
    t.assert_true(ok, reason); t.assert_eq(#calls, 4)
    t.assert_true(gtags.ready(ctx.paths.workspace_db))
    t.assert_eq(calls[1].opts.cwd, ctx.engine_root); t.assert_eq(calls[3].opts.cwd, ctx.project_root)
    local queried, completed = {}, nil
    gtags.query_async(ctx, { '-d', '--literal', '--result=grep', 'Shared' }, function(_, opts, cb)
      queried[#queried + 1] = opts.cwd; cb(0, { opts.cwd .. '/sample.ush:1:float Shared() {' })
    end, function(code, lines, result) completed = { code, lines, result } end)
    t.assert_eq(#queried, 2); t.assert_eq(#completed[2], 2)
    t.assert_eq(completed[3].coverage, 'complete')
  end)
  t.it('failed replacement preserves the previous published manifest and database', function()
    local ctx, spec = fixture()
    t.assert_true(gtags.build_sync(spec))
    local before = table.concat(vim.fn.readfile(ctx.paths.workspace_db .. '.roots.json'), '\n')
    spec.run_lines = function() return 2, { 'deliberate failure' } end
    t.assert_false(gtags.build_sync(spec))
    t.assert_eq(table.concat(vim.fn.readfile(ctx.paths.workspace_db .. '.roots.json'), '\n'), before)
    t.assert_true(gtags.ready(ctx.paths.workspace_db))
  end)
  t.it('legacy triplet never claims complete empty coverage', function()
    local ctx = fixture()
    vim.fn.mkdir(ctx.paths.workspace_db, 'p')
    for _, name in ipairs({ 'GTAGS', 'GRTAGS', 'GPATH' }) do vim.fn.writefile({ 'legacy' }, ctx.paths.workspace_db .. '/' .. name) end
    local result
    gtags.query_async(ctx, { '-d', 'Absent' }, function(_, _, cb) cb(0, {}) end,
      function(_, _, value) result = value end)
    t.assert_eq(result.reason, 'coverage-missing'); t.assert_eq(result.coverage, 'partial')
  end)
  t.it('missing database and failed command remain distinct', function()
    local ctx, spec = fixture()
    local result
    gtags.query_async(ctx, {}, function() error('must not spawn') end, function(_, _, value) result = value end)
    t.assert_eq(result.reason, 'unavailable')
    t.assert_true(gtags.build_sync(spec))
    gtags.query_async(ctx, {}, function(_, _, cb) cb(2, { 'error' }) end, function(_, _, value) result = value end)
    t.assert_eq(result.reason, 'command-failed')
  end)
  t.it('empty or missing required root never masquerades as complete GTAGS empty', function()
    local ctx, spec = fixture()
    t.assert_true(gtags.build_sync(spec))
    local path = ctx.paths.workspace_db .. '.roots.json'
    local manifest = vim.json.decode(table.concat(vim.fn.readfile(path), '\n'))
    manifest.roots[2] = nil
    vim.fn.writefile({ vim.json.encode(manifest) }, path)
    local result
    gtags.query_async(ctx, {}, function(_, _, cb) cb(0, {}) end, function(_, _, value) result = value end)
    t.assert_eq(result.coverage, 'partial'); t.assert_eq(result.reason, 'coverage-missing')
    t.assert_false(gtags.ready(ctx.paths.workspace_db, false, ctx))
    manifest.roots = {}
    vim.fn.writefile({ vim.json.encode(manifest) }, path)
    gtags.query_async(ctx, {}, function() error('no validated roots') end, function(_, _, value) result = value end)
    t.assert_eq(result.reason, 'unavailable'); t.assert_false(gtags.ready(ctx.paths.workspace_db))
  end)
  t.it('empty or malformed manifest fails closed without throwing', function()
    local ctx = fixture()
    local path = ctx.paths.workspace_db .. '.roots.json'
    for _, bytes in ipairs({ '', '{"version":1,"roots":[7]}', '{broken' }) do
      vim.fn.writefile({ bytes }, path)
      t.assert_false(gtags.ready(ctx.paths.workspace_db))
      local result
      gtags.query_async(ctx, {}, function() error('invalid manifest must not spawn') end,
        function(_, _, value) result = value end)
      t.assert_eq(result.reason, 'unavailable')
    end
  end)
  t.it('input changes after publication mark query coverage partial', function()
    local ctx, spec = fixture()
    t.assert_true(gtags.build_sync(spec))
    vim.fn.writefile({ 'different.ush' }, ctx.paths.project_list)
    t.assert_false(gtags.ready(ctx.paths.workspace_db))
    local result
    gtags.query_async(ctx, {}, function(_, _, cb) cb(0, {}) end, function(_, _, value) result = value end)
    t.assert_eq(result.coverage, 'partial'); t.assert_eq(result.reason, 'coverage-missing')
  end)
  t.it('input changes during build cannot publish a torn input receipt', function()
    local ctx, spec = fixture()
    local run = spec.run_lines
    spec.run_lines = function(cmd, opts)
      local code, lines = run(cmd, opts)
      if cmd[1] == 'global' then vim.fn.writefile({ 'changed.ush' }, ctx.paths.project_list) end
      return code, lines
    end
    local ok = gtags.build_sync(spec)
    t.assert_false(ok); t.assert_false(fs.is_file(ctx.paths.workspace_db .. '.roots.json'))
  end)
  t.it('a synchronous transport exception releases the writer lease', function()
    local _, spec = fixture()
    local run = spec.run_lines
    spec.run_lines = function() error('transport fault') end
    local ok, reason = gtags.build_sync(spec)
    t.assert_false(ok); t.assert_contains(reason, 'transport fault')
    spec.run_lines = run
    t.assert_true(gtags.build_sync(spec))
  end)
  t.it('completed async cancellation cannot kill a later owned child', function()
    local ctx, spec = fixture()
    local admission = require('utils.host_admission')
    local original = admission.run_when_allowed
    local second_control
    local ok, err = xpcall(function()
      admission.run_when_allowed = function(request)
        local cancel = request.start()
        return true, nil, nil, { cancel = function() if cancel then cancel() end end }
      end
      local done, killed = false, 0
      spec.system = function(cmd, opts, cb)
        local code, lines = spec.run_lines(cmd, opts)
        cb({ code = code, stdout = table.concat(lines, '\n'), stderr = '' })
        return { kill = function() killed = killed + 1 end }
      end
      local accepted, _, old_control = gtags.rebuild_async(spec, function(hit) done = hit end)
      t.assert_true(accepted); t.assert_true(vim.wait(500, function() return done end))
      spec.system = function() return { kill = function() killed = killed + 1 end } end
      local next_accepted
      next_accepted, _, second_control = gtags.rebuild_async(spec, function() end)
      t.assert_true(next_accepted)
      old_control:cancel(); t.assert_eq(killed, 0, 'old control must not kill current child')
      second_control:cancel(); t.assert_eq(killed, 1)
      t.assert_false(gtags.is_running())
    end, debug.traceback)
    if second_control then second_control:cancel() end
    admission.run_when_allowed = original; gtags._reset_for_test()
    if not ok then error(err) end
  end)
  t.it('native real engine and cross-drive project shaders both resolve from private roots', function()
    -- Every root is operator-supplied: this case must not carry a workstation
    -- path of its own, or the public-mirror privacy gate rejects the file.
    local base = vim.env.NVIM_X1_NATIVE_ROOT
    local engine_root = vim.env.NVIM_X1_NATIVE_ENGINE_ROOT
    local project_root = vim.env.NVIM_X1_NATIVE_PROJECT_ROOT
    local project_shader = vim.env.NVIM_X1_NATIVE_PROJECT_SHADER
    local project_symbol = vim.env.NVIM_X1_NATIVE_PROJECT_SYMBOL
    if (base or '') == '' or (engine_root or '') == '' or (project_root or '') == ''
        or (project_shader or '') == '' or (project_symbol or '') == '' then
      t.skip('private native proof requires NVIM_X1_NATIVE_ROOT/_ENGINE_ROOT/_PROJECT_ROOT/_PROJECT_SHADER/_PROJECT_SYMBOL'); return
    end
    vim.fn.mkdir(base, 'p')
    local ctx = { engine_root = engine_root, project_root = project_root,
      paths = { workspace_db = base .. '/db', engine_list = base .. '/engine.files', project_list = base .. '/project.files' } }
    vim.fn.writefile({ 'Engine/Shaders/Private/OctahedralCommon.ush' }, ctx.paths.engine_list)
    vim.fn.writefile({ project_shader }, ctx.paths.project_list)
    local ok, reason = gtags.build_sync(gtags.workspace_spec(ctx))
    t.assert_true(ok, reason)
    for _, symbol in ipairs({ 'ComputeSphericalExcess', project_symbol }) do
      local code, lines = gtags.query_sync(ctx, { '-x', '--literal', symbol }, function(cmd, opts)
        local value = vim.system(cmd, opts):wait()
        return value.code, vim.split(value.stdout or '', '\n', { trimempty = true })
      end)
      t.assert_eq(code, 0); t.assert_true(#lines > 0, symbol .. ' must resolve')
    end
    vim.fn.writefile({ vim.json.encode({ ok = ok, manifest = vim.json.decode(table.concat(vim.fn.readfile(base .. '/db.roots.json'), '\n')) }) }, base .. '/native-module-proof.json')
  end)
end)
