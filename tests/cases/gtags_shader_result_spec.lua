local t = require('tests.harness')
t.bootstrap()
local ue, gtags, proc = require('ue'), require('ue.gtags'), require('ue.core.proc')
local function with_context(run)
  local root = vim.fn.tempname():gsub('\\', '/') .. '-shader-result'
  vim.fn.mkdir(root .. '/engine/Engine/Shaders', 'p'); vim.fn.mkdir(root .. '/project/Shaders', 'p')
  local source = root .. '/project/Shaders/source.ush'
  vim.fn.writefile({ 'float Caller() { return Wanted(); }' }, source)
  vim.cmd('edit ' .. vim.fn.fnameescape(source))
  local ctx = { engine_root = root .. '/engine', project_root = root .. '/project',
    paths = { workspace_db = root .. '/db', engine_list = root .. '/engine.files', project_list = root .. '/project.files' } }
  vim.fn.writefile({ 'Engine/Shaders/Witness.ush' }, ctx.paths.engine_list)
  vim.fn.writefile({ 'Shaders/Witness.ush' }, ctx.paths.project_list)
  for _, path in ipairs({ ctx.engine_root .. '/Engine/Shaders/Witness.ush', ctx.project_root .. '/Shaders/Witness.ush' }) do
    vim.fn.writefile({ 'float Witness() { return 1; }' }, path)
  end
  local spec = gtags.workspace_spec(ctx); spec.first_executable = function() return 'gtags' end
  spec.run_lines = function(cmd, opts)
    if cmd[1] == 'gtags' then
      for _, name in ipairs({ 'GTAGS', 'GRTAGS', 'GPATH' }) do vim.fn.writefile({ 'fixture' }, cmd[#cmd] .. '/' .. name) end
      return 0, {}
    end
    local path = opts.cwd == ctx.engine_root and '/Engine/Shaders/Witness.ush' or '/Shaders/Witness.ush'
    return 0, { 'Witness 1 ' .. opts.cwd .. path .. ' float Witness() {' }
  end
  t.assert_true(gtags.build_sync(spec))
  local slot, resolver
  for i = 1, 40 do
    local name, value = debug.getupvalue(ue.gtags_definition_async, i)
    if name == 'resolve_context' then slot, resolver = i, value; break end
    if not name then break end
  end
  t.assert_true(slot ~= nil)
  local original_run, original_tool = ue._async.run_lines, proc.first_executable
  debug.setupvalue(ue.gtags_definition_async, slot, function() return ctx end)
  local ok, err = xpcall(function() run(ctx, function(value)
    debug.setupvalue(ue.gtags_definition_async, slot, function() return value, 'no UE context' end)
  end) end, debug.traceback)
  ue._async.run_lines, proc.first_executable = original_run, original_tool
  debug.setupvalue(ue.gtags_definition_async, slot, resolver)
  if not ok then error(err) end
end

t.describe('shader asynchronous production completion', function()
  t.it('rg empty reports the rg backend and retains GTAGS evidence', function()
    with_context(function()
      local result, calls = nil, 0
      proc.first_executable = function() return 'rg' end
      ue._async.run_lines = function(_, _, cb) calls = calls + 1; cb(0, {}) end
      ue.gtags_definition_async('Wanted', function(ok, value) t.assert_false(ok); result = value end)
      t.assert_eq(calls, 3); t.assert_eq(result.backend, 'rg'); t.assert_eq(result.reason, 'empty')
      t.assert_eq(result.coverage, 'partial'); t.assert_eq(result.previous.backend, 'gtags')
      t.assert_eq(result.previous.reason, 'empty'); t.assert_eq(result.previous.coverage, 'complete')
    end)
  end)
  t.it('missing rg after a GTAGS miss is unavailable rather than GTAGS empty', function()
    with_context(function()
      proc.first_executable = function() return nil end
      ue._async.run_lines = function(_, _, cb) cb(0, {}) end
      local result
      ue.gtags_definition_async('Wanted', function(_, value) result = value end)
      t.assert_eq(result.backend, 'rg'); t.assert_eq(result.reason, 'unavailable')
    end)
  end)
  t.it('command errors keep their backend instead of becoming empty', function()
    with_context(function()
      proc.first_executable = function() return 'rg' end
      ue._async.run_lines = function(_, _, cb) cb(2, { 'process error' }) end
      local result
      ue.gtags_definition_async('Wanted', function(_, value) result = value end)
      t.assert_eq(result.reason, 'command-failed'); t.assert_eq(result.backend, 'rg')
      t.assert_eq(result.previous.reason, 'command-failed')
    end)
  end)
  t.it('missing UE context has an explicit unavailable result without spawning', function()
    with_context(function(_, set)
      set(nil); ue._async.run_lines = function() error('must not spawn') end
      local result
      ue.gtags_definition_async('Wanted', function(_, value) result = value end)
      t.assert_eq(result.backend, 'none'); t.assert_eq(result.reason, 'unavailable')
      t.assert_eq(result.detail, 'no UE context')
    end)
  end)
  t.it('late GTAGS results cannot jump after switching buffers', function()
    with_context(function(ctx)
      local callbacks = {}
      ue._async.run_lines = function(_, _, cb) callbacks[#callbacks + 1] = cb end
      local done = false
      ue.gtags_definition_async('Wanted', function() done = true end)
      local destination = ctx.project_root .. '/Shaders/Wanted.ush'
      vim.fn.writefile({ 'float Wanted() { return 1; }' }, destination)
      local other = vim.api.nvim_create_buf(true, false); vim.api.nvim_set_current_buf(other)
      callbacks[1](0, { destination .. ':1:float Wanted() {' })
      callbacks[2](0, {})
      t.assert_eq(vim.api.nvim_get_current_buf(), other); t.assert_false(done)
    end)
  end)
end)
