-- GTAGS shader owner: build isolated roots, verify parser evidence, publish atomically.
local fs, proc = require('ue.core.fs'), require('ue.core.proc')
local M = {}
local active, active_control, active_handle = false, nil, nil
local uv = vim.uv or vim.loop
local function input_bytes(path)
  if type(path) ~= 'string' then return nil end
  local file = io.open(path, 'rb')
  if not file then return nil end
  local bytes = file:read('*a'); file:close()
  return bytes
end
local function db_ready(dir)
  if type(dir) ~= 'string' or dir == '' then return false end
  for _, name in ipairs({ 'GTAGS', 'GRTAGS', 'GPATH' }) do
    local stat = uv.fs_stat(fs.join(dir, name))
    if not stat or stat.type ~= 'file' or stat.size <= 0 then return false end
  end
  return true
end
local function read_manifest(dir)
  local file = io.open(dir .. '.roots.json', 'rb')
  if not file then return nil end
  local raw = file:read(65537) or ''; file:close()
  if #raw > 65536 then return nil end
  local ok, value = pcall(vim.json.decode, raw)
  if not ok or type(value) ~= 'table' or value.version ~= 1 or type(value.roots) ~= 'table'
      or #value.roots == 0 then return nil end
  for _, root in ipairs(value.roots) do
    if type(root) ~= 'table' or type(root.root) ~= 'string' or type(root.db_dir) ~= 'string'
        or not root.verified or (not root.empty and not db_ready(root.db_dir)) then return nil end
  end
  return value
end
function M.ready(dir, allow_legacy, ctx)
  if type(dir) ~= 'string' then return false end
  local manifest = read_manifest(dir)
  if manifest then
    local covered = {}
    for _, root in ipairs(manifest.roots) do
      local bytes = input_bytes(root.source_list)
      if not bytes or vim.fn.sha256(bytes) ~= root.input_hash then return false end
      covered[fs.norm(root.root)] = true
    end
    if ctx and (not covered[fs.norm(ctx.engine_root)]
        or ctx.project_root and ctx.project_root ~= '' and not covered[fs.norm(ctx.project_root)]) then return false end
    return true
  end
  return allow_legacy and db_ready(dir) or false
end
function M.output_paths(dir)
  local manifest = read_manifest(dir)
  local paths = manifest and { dir .. '.roots.json' } or {}
  for _, root in ipairs(manifest and manifest.roots or { { db_dir = dir } }) do
    if not root.empty then
      for _, name in ipairs({ 'GTAGS', 'GRTAGS', 'GPATH' }) do paths[#paths + 1] = fs.join(root.db_dir, name) end
    end
  end
  return paths
end
function M.workspace_spec(ctx)
  return { db_dir = ctx.paths.workspace_db, label = 'UE shader GTAGS rebuild', roots = {
    { root = ctx.engine_root, filelist = ctx.paths.engine_list, label = 'engine' },
    { root = ctx.project_root, filelist = ctx.paths.project_list, label = 'project' },
  } }
end
function M.plan(spec)
  local gtags = (spec.first_executable or proc.first_executable)({ 'gtags' })
  if not gtags then return nil, 'gtags not found in PATH' end
  if not fs.is_file(spec.filelist) then return nil, 'GTAGS input list missing: ' .. tostring(spec.filelist) end
  if vim.fn.getfsize(spec.filelist) == 0 then return { skip = true } end
  local source = debug.getinfo(1, 'S').source:gsub('^@', '')
  local conf = spec.conf_path or fs.join(vim.fn.fnamemodify(source, ':h:h:h'), 'tools', 'gtags', 'gtags.conf')
  if not fs.is_file(conf) then return nil, 'GTAGS shader configuration missing: ' .. conf end
  return { command = { gtags, '-f', spec.filelist, '--skip-unreadable', '--skip-symlink', spec.db_dir },
    cwd = spec.root, env = { GTAGSCONF = conf, GTAGSLABEL = 'hlsl-cpp' } }
end
-- Bounded witnesses prove parser functionality; they never prune the build input.
local function witnesses(spec)
  local list = io.open(spec.filelist, 'rb')
  if not list then return nil, 'input list unreadable' end
  local samples, examined = {}, 0
  for path in list:lines() do
    path = path:gsub('\r$', '')
    if path:lower():match('%.u[ss][hf]$') or path:lower():match('%.hlsl$') or path:lower():match('%.glsl$') then
      examined = examined + 1
      local full = path:match('^%a:[/\\]') or path:match('^[/\\]')
      full = full and path or fs.join(spec.root, path)
      local file = io.open(full, 'rb')
      if file then
        local text = file:read(262144) or ''; file:close()
        local token = text:match('[%a_][%w_<>]*%s+([%a_][%w_]*)%s*%([^;{}]-%)%s*{')
          or text:match('%f[%a]struct%s+([%a_][%w_]*)%s*{')
          or text:match('#%s*define%s+([%a_][%w_]*)')
        if token then samples[#samples + 1] = { symbol = token, file = fs.norm(full) } end
      end
      if #samples >= 2 or examined >= 32 then break end
    end
  end
  list:close()
  if #samples == 0 then return nil, 'no positive shader witness within 32 files / 256 KiB per file' end
  return samples
end
local function query_command(root, args)
  local cmd = { 'global', '--path-style=absolute' }; vim.list_extend(cmd, args)
  return cmd, { cwd = root.root, env = { GTAGSROOT = root.root, GTAGSDBPATH = root.db_dir }, text = true }
end
local function check_output(spec, code, output)
  if code ~= 0 then return false, 'gtags exit=' .. tostring(code) .. ': ' .. output end
  local lower = output:lower()
  if lower:find('ignored', 1, true) or lower:find('unreadable', 1, true) or lower:find('out of source tree', 1, true) then
    return false, 'coverage-missing: ' .. output
  end
  if not db_ready(spec.db_dir) then return false, 'GTAGS database files missing' end
  return true
end
local function witness_hit(sample, code, output)
  if code ~= 0 then return false end
  -- Compare the exact source path, including paths with spaces.
  local prefix = sample.symbol .. '%s+%d+%s+'
  local target = fs.norm(sample.file):lower()
  for line in output:gmatch('[^\r\n]+') do
    local rest = line:match('^' .. prefix .. '(.*)')
    if rest and fs.norm(rest:sub(1, #sample.file)):lower() == target
        and rest:sub(#sample.file + 1, #sample.file + 1):match('%s') then return true end
  end
  return false
end
local function build_roots(spec)
  local token = tostring(vim.fn.getpid()) .. '-' .. tostring(uv.hrtime())
  local roots = {}
  for i, input in ipairs(spec.roots or { spec }) do
    if input.root and input.root ~= '' then
      roots[#roots + 1] = vim.tbl_extend('force', input, { db_dir = spec.db_dir .. '.build-' .. token .. '/' .. i,
        first_executable = spec.first_executable })
    end
  end
  return roots
end
local function freeze_input(root)
  local bytes = input_bytes(root.filelist)
  if not bytes then return false, 'GTAGS input list unreadable: ' .. tostring(root.filelist) end
  root.source_list, root.input_hash = root.filelist, vim.fn.sha256(bytes)
  fs.ensure_dir(root.db_dir)
  local path = fs.join(root.db_dir, 'input.files')
  local file, err = io.open(path, 'wb')
  if not file then return false, tostring(err) end
  local wrote = file:write(bytes); local closed = file:close()
  if not wrote or not closed then return false, 'GTAGS input snapshot write failed' end
  root.filelist = path
  -- The declared shader inventory includes GLSL, which the checked-in label
  -- omitted. Keep the shared config read-only and freeze its effective langmap.
  local source = debug.getinfo(1, 'S').source:gsub('^@', '')
  local config = input_bytes(fs.join(vim.fn.fnamemodify(source, ':h:h:h'), 'tools', 'gtags', 'gtags.conf'))
  if not config then return false, 'GTAGS shader configuration missing' end
  config = config:gsub('%.hlsl%.hlsli:', '.hlsl.hlsli.glsl:')
  root.conf_path = fs.join(root.db_dir, 'gtags.conf')
  local conf_file, conf_err = io.open(root.conf_path, 'wb')
  if not conf_file then return false, tostring(conf_err) end
  local conf_wrote = conf_file:write(config); local conf_closed = conf_file:close()
  if not conf_wrote or not conf_closed then return false, 'GTAGS configuration snapshot write failed' end
  return true
end
local function publish(spec, roots)
  local selected = {}
  for _, root in ipairs(roots) do
    local bytes = input_bytes(root.source_list)
    if not bytes or vim.fn.sha256(bytes) ~= root.input_hash then return false, 'GTAGS input changed during build' end
    if root.verified then selected[#selected + 1] = { root = root.root, db_dir = root.db_dir,
      filelist = root.filelist, source_list = root.source_list, input_hash = root.input_hash,
      verified = true, empty = root.empty, witnesses = root.witnesses } end
  end
  local path = spec.db_dir .. '.roots.json'; fs.ensure_dir(fs.dirname(path))
  local staged = path .. '.pending-' .. tostring(uv.hrtime())
  local file, err = io.open(staged, 'wb')
  if not file then return false, tostring(err) end
  local wrote = file:write(vim.json.encode({ version = 1, roots = selected })); local closed = file:close()
  if not wrote or not closed then return false, 'GTAGS manifest write failed' end
  local ok, rename_err = uv.fs_rename(staged, path)
  return ok and true or false, rename_err or 'GTAGS roots verified and published'
end
local function probe(ok, reason)
  pcall(function()
    local p = require('utils.probe')
    p.observe('shader-gtags', 'root-positive-witness-2026-10-14-X1')
    p.record('shader-gtags', ok and 'verified' or 'failed', {
      state = ok and 'ok' or 'failed', reason = tostring(reason or ''):sub(1, 4096) })
  end)
end
-- Explicit UEPrepareSync twin only.
function M.build_sync(spec)
  if active then return false, 'GTAGS rebuild is already queued or running' end
  local lease, lease_err = require('ue.file_lock').acquire(spec.db_dir .. '.writer-lock')
  if not lease then return false, 'GTAGS writer busy: ' .. tostring(lease_err) end
  local function finish(ok, message)
    require('ue.file_lock').release(lease)
    probe(ok, message)
    return ok, message
  end
  local protected, result, message = xpcall(function()
    local roots = build_roots(spec)
    if #roots == 0 then return finish(false, 'GTAGS effective roots missing') end
    local run_lines = spec.run_lines or function(command, opts)
      local result = vim.system(command, opts):wait()
      return result.code, vim.split((result.stdout or '') .. (result.stderr or ''), '\n', { trimempty = true })
    end
    for _, root in ipairs(roots) do
      local frozen, freeze_err = freeze_input(root)
      if not frozen then return finish(false, freeze_err) end
      local plan, err = M.plan(root)
      if not plan then return finish(false, err) end
      if plan.skip then root.verified, root.empty = true, true end
      if not plan.skip then
        local samples, sample_err = witnesses(root)
        if not samples then return finish(false, sample_err) end
        fs.ensure_dir(root.db_dir)
        local code, lines = run_lines(plan.command, { cwd = plan.cwd, env = plan.env, text = true })
        local ok, build_err = check_output(root, code, table.concat(lines or {}, '\n'))
        if not ok then return finish(false, build_err) end
        for _, sample in ipairs(samples) do
          local cmd, opts = query_command(root, { '-x', '--literal', sample.symbol })
          local query_code, query_lines = run_lines(cmd, opts)
        if query_code ~= 0 then
          return finish(false, 'global validation command failed: exit=' .. tostring(query_code)
            .. ' ' .. table.concat(query_lines or {}, '\n'))
        end
          if not witness_hit(sample, query_code, table.concat(query_lines or {}, '\n')) then
            local reason = 'positive-witness-missing: ' .. sample.symbol .. ' in ' .. sample.file
            return finish(false, reason)
          end
        end
        root.verified, root.witnesses = true, samples
      end
    end
    local ok, message = publish(spec, roots)
    return finish(ok, message)
  end, debug.traceback)
  if not protected then return finish(false, result) end
  return result, message
end
function M.rebuild_async(spec, callback)
  spec = spec or {}
  if active then return false, 'GTAGS rebuild is already queued or running' end
  active = true
  local lease, completed
  local function finish(ok, message)
    if completed then return end
    completed, active, active_control, active_handle = true, false, nil, nil
    if lease then require('ue.file_lock').release(lease); lease = nil end
    probe(ok, message)
    if callback then callback(ok, message) end
  end
  local admission = require('utils.host_admission')
  local started, _, start_err, control = admission.run_when_allowed({
    name = spec.label or 'GTAGS rebuild',
    start = function()
      if not spec.db_dir then finish(false, 'GTAGS database path missing'); return end
      local lock_err
      lease, lock_err = require('ue.file_lock').acquire(spec.db_dir .. '.writer-lock')
      if not lease then finish(false, 'GTAGS writer busy: ' .. tostring(lock_err)); return end
      local roots, index = build_roots(spec), 0
      if #roots == 0 then finish(false, 'GTAGS effective roots missing'); return end
      local system = spec.system or vim.system
      local function spawn(command, opts, cb)
        local ok, handle = pcall(system, command, opts, function(result)
          vim.schedule(function()
            if completed then return end
            local resumed, err = xpcall(function() cb(result) end, debug.traceback)
            if not resumed then finish(false, err) end
          end)
        end)
        if not ok or not handle then finish(false, 'GTAGS spawn failed: ' .. tostring(handle)); return end
        active_handle = handle
        pcall(function() require('utils.task_registry').register({ name = spec.label or 'GTAGS rebuild',
          group = 'ue', kind = 'system', handle = handle, started_at = os.time() }) end)
      end
      local next_root
      next_root = function()
        index = index + 1
        local root = roots[index]
        if not root then local ok, message = publish(spec, roots); finish(ok, message); return end
        local frozen, freeze_err = freeze_input(root)
        if not frozen then finish(false, freeze_err); return end
        local plan, err = M.plan(root)
        if not plan then finish(false, err); return end
        if plan.skip then root.verified, root.empty = true, true; next_root(); return end
        local samples, sample_err = witnesses(root)
        if not samples then finish(false, sample_err); return end
        fs.ensure_dir(root.db_dir)
        spawn(plan.command, { cwd = plan.cwd, env = plan.env, text = true }, function(result)
          local ok, build_err = check_output(root, result.code, (result.stdout or '') .. (result.stderr or ''))
          if not ok then finish(false, build_err); return end
          local n = 0
          local function verify_next()
            n = n + 1
            local sample = samples[n]
            if not sample then root.verified, root.witnesses = true, samples; next_root(); return end
            local cmd, opts = query_command(root, { '-x', '--literal', sample.symbol })
            spawn(cmd, opts, function(query)
              if query.code ~= 0 then
                finish(false, 'global validation command failed: exit=' .. tostring(query.code)
                  .. ' ' .. tostring(query.stderr or '')); return
              end
              if not witness_hit(sample, query.code, query.stdout or '') then
                finish(false, 'positive-witness-missing: ' .. sample.symbol .. ' in ' .. sample.file); return
              end
              verify_next()
            end)
          end
          verify_next()
        end)
      end
      next_root()
      return function()
        if completed then return end
        if active_handle and active_handle.kill then pcall(active_handle.kill, active_handle, 15) end
        finish(false, 'GTAGS rebuild cancelled')
      end
    end,
    on_error = function(err) finish(false, 'GTAGS admission failed: ' .. tostring(err)) end,
    on_cancel = function() finish(false, 'GTAGS rebuild cancelled before start') end,
  })
  if active then active_control = control end
  if started and start_err then return false, tostring(start_err), control end
  return true, started and 'running' or 'queued', control
end
local function query_roots(ctx)
  local dir = ctx.paths and ctx.paths.workspace_db
  if not dir then return {}, 'unavailable' end
  local manifest = read_manifest(dir)
  if manifest then
    local covered, roots, stale = {}, {}, false
    for _, root in ipairs(manifest.roots) do
      if fs.norm(root.root) ~= fs.norm(ctx.engine_root) and fs.norm(root.root) ~= fs.norm(ctx.project_root) then
        return {}, 'unavailable'
      end
      covered[fs.norm(root.root)] = true
      local bytes = input_bytes(root.source_list)
      if not bytes or vim.fn.sha256(bytes) ~= root.input_hash then stale = true end
      if not root.empty then roots[#roots + 1] = root end
    end
    local complete = covered[fs.norm(ctx.engine_root)]
      and (not ctx.project_root or ctx.project_root == '' or covered[fs.norm(ctx.project_root)])
    return roots, complete and not stale and 'complete' or 'partial'
  end
  if db_ready(dir) then return { { root = ctx.engine_root, db_dir = dir } }, 'partial' end
  return {}, 'unavailable'
end
function M.query_async(ctx, args, run_lines, callback)
  local roots, coverage = query_roots(ctx)
  local lines, index, failed = {}, 0, false
  local function next_query()
    index = index + 1
    local root = roots[index]
    if not root then
      local reason = failed and 'command-failed' or #roots == 0 and 'unavailable' or coverage == 'unavailable' and 'unavailable'
        or #lines > 0 and 'resolved' or coverage == 'partial' and 'coverage-missing' or 'empty'
      callback(failed and -1 or 0, lines, { backend = #roots == 0 and 'none' or 'gtags', reason = reason, coverage = coverage }); return
    end
    local cmd, opts = query_command(root, args)
    run_lines(cmd, opts, function(code, output)
      if code ~= 0 and code ~= 1 then failed = true else vim.list_extend(lines, output or {}) end
      next_query()
    end)
  end
  next_query()
end
function M.query_sync(ctx, args, run_lines)
  local roots, coverage = query_roots(ctx)
  local lines = {}
  for _, root in ipairs(roots) do
    local cmd, opts = query_command(root, args)
    local code, result = run_lines(cmd, opts)
    if code ~= 0 and code ~= 1 then return code, {}, coverage end
    vim.list_extend(lines, result or {})
  end
  return 0, lines, coverage
end
function M.is_running() return active end
function M._reset_for_test()
  if active_control then active_control:cancel() end
  active, active_control, active_handle = false, nil, nil
end
M._db_ready_for_test = db_ready
return M
