-- Optional private shard refresh before the existing source-reader restart.
local M = {}
local active, exiting, exit_hook = {}, false, nil
local platform = require("utils.platform")

local function key(path)
  return platform.driver().path_key(vim.fs.normalize(path)):gsub("/+$", "")
end

function M.shutdown()
  exiting = true
  for scope, record in pairs(active) do
    record.cancelled = true
    if record.handle then
      -- Keep writer leases until process exit; if Neovim exits first, their
      -- PID ownership makes the existing file_lock reclaimer recover them.
      pcall(record.handle.kill, record.handle, 15)
    else
      record.finish({ ok = false, reason = "editor-exit" })
    end
  end
end

local function request(ctx, deps)
  local paths = ctx and ctx.paths or {}
  if not paths.semantic_cdb or not paths.clangd_dir then return nil, "missing-switch-paths" end
  local directory = vim.fs.dirname(paths.semantic_cdb)
  local config, command
  for _, client in ipairs((deps.get_clients or vim.lsp.get_clients)({ name = "clangd" })) do
    local candidate = client.config or {}
    local argv = candidate._ue_resolved_cmd or candidate.cmd
    if type(argv) == "table" then
      for index = #argv, 1, -1 do
        local arg = argv[index]
        local selected = type(arg) == "string" and arg:match("^%-%-?compile%-commands%-dir=(.+)$")
        if arg == "--compile-commands-dir" or arg == "-compile-commands-dir" then selected = argv[index + 1] end
        if selected then
          local original = selected
          if key(selected) ~= key(directory) then
            -- Resolve only the runtime's session-owned mapping, including a
            -- frozen reader being retired after its guard invalidated inputs.
            original = (deps.original_cdb_dir or require("ue.index.batch_runtime").original_cdb_dir)(selected, client)
          end
          if original and key(original) == key(directory) then config, command = candidate, argv end
          break
        end
      end
    end
    if config then break end
  end
  if not config then return nil, "no-matching-source-reader" end
  local profile, reason = (deps.server_profile or require("ue.index.batch_runtime").server_profile)(command, config)
  if reason then return nil, reason end
  local python = (deps.resolve_python or function()
    return platform.resolve_tool({ name = "python", env = { "UE_PYTHON" },
      driver_candidates = function(driver) return driver.python_candidates() end })
  end)()
  if not python.ok then return nil, "python-unavailable" end
  local argv = { python.path, "-B", "-I", vim.fn.stdpath("config") .. "/tools/clangd_switch_reindex.py",
    "--cdb", paths.semantic_cdb, "--index-dir", vim.fs.joinpath(directory, ".cache", "clangd", "index"),
    "--work-root", vim.fs.joinpath(paths.clangd_dir, "switch-reindex"), "--clangd", command[1],
    "--workers", "2", "--jobs", "8", "--timeout", "600" }
  if profile then vim.list_extend(argv, { "--server-profile", vim.json.encode(profile) }) end
  for _, root in ipairs({ ctx.engine_root and vim.fs.joinpath(ctx.engine_root, "Engine") or "", ctx.project_root or "" }) do
    if root ~= "" then
      for _, name in ipairs({ "Source", "Plugins" }) do
        vim.list_extend(argv, { "--source-root", vim.fs.joinpath(root, name) })
      end
    end
  end
  if deps.baseline_only then argv[#argv + 1] = "--baseline-only" end
  return argv, { text = true, timeout = 615000, cwd = config.cmd_cwd, env = config.cmd_env }
end

function M.summary(result)
  return ("%s; changed=%d; TU=%d; %.3fs%s%s"):format(result.action or "failed",
    result.changed or 0, result.cover_tus or 0, result.seconds or 0,
    result.reason and result.reason ~= "" and ("; reason=" .. tostring(result.reason)) or "",
    result.fallback and ("; fallback=" .. tostring(result.fallback)) or "")
end

--- Deduplicate a scope and resume its original restart once, regardless of outcome.
--- Dependencies keep the process and restart contract headless-testable.
function M.before(ctx, scope, continue, dependencies)
  local deps = dependencies or {}
  if exiting then return false end
  if active[scope] then return false end
  local record = { done = false }
  active[scope] = record
  local notify = deps.notify or vim.notify
  if not deps.suppress_notify then
    notify("Source switch index refresh started (checking baseline and changes)", vim.log.levels.INFO,
      { title = "UE index" })
  end
  local leases = {}
  local release = deps.release or require("ue.file_lock").release
  local function finish(result)
    if record.done then return end
    record.done = true
    active[scope] = nil
    for index = #leases, 1, -1 do pcall(release, leases[index]) end
    leases = {}
    pcall(function()
      local probe = deps.probe or require("utils.probe").record
      probe("cpp-switch-reindex", scope, { changed = result.changed, cover_tus = result.cover_tus,
        seconds = result.seconds, ok = result.ok, action = result.action, reason = result.reason,
        state = result.ok and "ok" or "failed" })
    end)
    if not exiting and not record.cancelled then
      result.fallback = result.ok and "none" or (result.needs_prepare and "prepare-required" or "reader-refresh-dispatched")
      if not deps.suppress_notify then
        notify(M.summary(result), result.ok and vim.log.levels.INFO or vim.log.levels.WARN, { title = "UE index" })
      end
      continue(result)
    end
  end
  record.finish = finish
  local function launch()
    if record.done or record.cancelled or exiting then return end
    local ok, error_value = pcall(function()
      local admission = require("utils.host_admission")
      local allow, reason = (deps.admit or function()
        return admission.admit(admission.current_reading(), 0, admission.options())
      end)()
      if not allow then finish({ ok = false, reason = reason }); return end
      local argv, options = (deps.request or request)(ctx, deps)
      if not argv then finish({ ok = false, reason = options }); return end
      local paths = ctx and ctx.paths or {}
      local lock_paths = deps.lock_paths and deps.lock_paths(ctx) or
        (paths.index_state and paths.active_cdb and {
          paths.index_state .. ".build.lock", require("ue.cdb.paths").targets(ctx)[1] .. ".writer.lock",
        })
      if not lock_paths then finish({ ok = false, reason = "missing-writer-lock-paths" }); return end
      for _, path in ipairs(lock_paths) do
        local lease, lock_reason = (deps.acquire or require("ue.file_lock").acquire)(path)
        if not lease then finish({ ok = false, reason = "writer-busy:" .. tostring(lock_reason) }); return end
        leases[#leases + 1] = lease
      end
      if not exit_hook then
        exit_hook = vim.api.nvim_create_autocmd("VimLeavePre", { callback = M.shutdown })
      end
      record.handle = (deps.system or vim.system)(argv, options, function(result)
        (deps.schedule or vim.schedule)(function()
          local last = (result.stdout or ""):match("([^\r\n]+)[\r\n]*$")
          local decoded_ok, decoded = pcall(vim.json.decode, last or "")
          if not decoded_ok or type(decoded) ~= "table" then decoded = { ok = false, reason = "switch-helper-failed" } end
          if result.code ~= 0 then decoded.ok = false end
          finish(decoded)
        end)
      end)
      pcall(deps.register or require("utils.task_registry").register,
        { name = "Refresh source index shards", group = "index", kind = "system", handle = record.handle })
    end)
    if not ok then finish({ ok = false, reason = tostring(error_value) }) end
  end
  -- The caller's current index phase still owns build.lock until it returns.
  -- Acquiring on the next turn avoids denying our own completed publication.
  if deps.request or (ctx and ctx.paths and ctx.paths.clangd_dir) then
    (deps.schedule or vim.schedule)(launch)
  else
    finish({ ok = false, reason = "missing-switch-paths" })
  end
  return true
end

--- Establish only from the caller's successful prepare completion evidence.
function M.baseline(ctx, scope, callback, dependencies)
  local deps = vim.tbl_extend("force", dependencies or {}, { baseline_only = true, suppress_notify = true })
  return M.before(ctx, scope, callback, deps)
end

function M._reset_for_test()
  M.shutdown()
  -- DI fixtures have no actual child to deliver the terminal callback.
  for _, record in pairs(active) do record.finish({ ok = false, reason = "test-reset" }) end
  exiting = false
end

return M
