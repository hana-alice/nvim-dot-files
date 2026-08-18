-- Exact per-buffer compile commands for the synthetic-only clangd database.
--
-- The on-disk CDB intentionally contains only super-unity TUs so clangd's
-- BackgroundIndex work is bounded. Exact commands for open files travel over
-- clangd's compiler-owned compilationDatabaseChanges protocol extension.
local M = {}

local cache = {}
local pending = {}

local function norm(path)
  return vim.fs.normalize(tostring(path or ""))
end

local function controlled_cdb_dir(client)
  local config = client and client.config or {}
  local cmd = type(config._ue_resolved_cmd) == "table" and config._ue_resolved_cmd
    or (type(config.cmd) == "table" and config.cmd or {})
  for _, arg in ipairs(cmd) do
    local value = tostring(arg):match("^%-%-compile%-commands%-dir=(.+)$")
    if value then
      value = norm(value)
      if vim.fs.basename(value) == "background-cdb"
          and (vim.uv or vim.loop).fs_stat(value .. "/compile_commands.json") then
        return value
      end
    end
  end
  return nil
end

local function base_cdb(semantic_dir)
  local platform_dir = vim.fs.dirname(semantic_dir)
  local project_bucket = vim.fs.dirname(vim.fs.dirname(platform_dir))
  local root = semantic_dir
  for _ = 1, 4 do root = vim.fs.dirname(root) end
  for _, candidate in ipairs({
    project_bucket .. "/cdb/active/" .. vim.fs.basename(platform_dir) .. "/compile_commands.json",
    root .. "/compile_commands.json",
    root .. "/Engine/compile_commands.json",
  }) do
    local stat = (vim.uv or vim.loop).fs_stat(candidate)
    if stat and stat.type == "file" then return norm(candidate), stat end
  end
  return nil
end

local function python_command()
  for _, candidate in ipairs({
    vim.env.UE_PYTHON or "",
    vim.fn.expand("~/AppData/Local/Programs/Python/Python312/python.exe"),
    vim.fn.expand("~/AppData/Local/Programs/Python/Python313/python.exe"),
    vim.fn.exepath("python"),
    vim.fn.exepath("python3"),
  }) do
    if candidate and candidate ~= "" then
      local path = norm(candidate)
      if (vim.uv or vim.loop).fs_stat(path) then return path end
    end
  end
  return nil
end

local function deliver(client, source, command, callback)
  local live = client and client.id and vim.lsp.get_client_by_id(client.id) or client
  if not live or type(live.notify) ~= "function" then
    callback(false, "clangd-client-stale")
    return
  end
  local called, accepted = pcall(live.notify, live, "workspace/didChangeConfiguration", {
    settings = {
      compilationDatabaseChanges = {
        [source] = command,
      },
    },
  })
  if called and accepted ~= false then
    callback(true)
  else
    callback(false, "compile-command-notify-failed")
  end
end

function M.ensure(client, bufnr, callback, opts)
  callback = callback or function() end
  opts = opts or {}
  local semantic_dir = controlled_cdb_dir(client)
  if not semantic_dir then
    callback(true)
    return
  end
  bufnr = bufnr == 0 and vim.api.nvim_get_current_buf() or bufnr
  local source = norm(vim.api.nvim_buf_get_name(bufnr))
  local command_source = norm(opts.compile_command_source or source)
  local cdb, stat = base_cdb(semantic_dir)
  if source == "" or not cdb then
    callback(false, source == "" and "subject-path-missing" or "base-compile-database-missing")
    return
  end
  local signature = table.concat({
    tostring(stat.size or 0),
    tostring(stat.mtime and stat.mtime.sec or 0),
    tostring(stat.mtime and stat.mtime.nsec or 0),
  }, ":")
  local key = table.concat({ cdb, signature, source:lower(), command_source:lower() }, "\0")
  if cache[key] then
    deliver(client, source, cache[key], callback)
    return
  end
  pending[key] = pending[key] or {}
  pending[key][#pending[key] + 1] = { client = client, source = source, callback = callback }
  if #pending[key] > 1 then return end

  local python = python_command()
  local script = norm(vim.fn.stdpath("config") .. "/tools/query_compile_command.py")
  if not python or not (vim.uv or vim.loop).fs_stat(script) then
    local waiters = pending[key]
    pending[key] = nil
    for _, waiter in ipairs(waiters) do waiter.callback(false, "compile-command-tool-missing") end
    return
  end
  local cmd = { python, script, cdb, command_source }
  if command_source:lower() ~= source:lower() then
    cmd[#cmd + 1] = "--subject"
    cmd[#cmd + 1] = source
  end
  vim.system(cmd, { text = true }, function(result)
    vim.schedule(function()
      local waiters = pending[key] or {}
      pending[key] = nil
      local ok, decoded = pcall(vim.json.decode, result.stdout or "")
      local command = ok and decoded and decoded.state == "resolved" and decoded.command or nil
      if type(command) == "table"
          and type(command.workingDirectory) == "string"
          and type(command.compilationCommand) == "table" then
        cache[key] = command
        for _, waiter in ipairs(waiters) do
          deliver(waiter.client, waiter.source, command, waiter.callback)
        end
      else
        local reason = ok and decoded and decoded.reason or "compile-command-query-failed"
        for _, waiter in ipairs(waiters) do waiter.callback(false, reason) end
      end
    end)
  end)
end

function M._reset_for_test()
  cache = {}
  pending = {}
end

return M
