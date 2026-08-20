-- Exact per-buffer compile commands for the synthetic-only clangd database.
--
-- The on-disk CDB intentionally contains only super-unity TUs so clangd's
-- BackgroundIndex work is bounded. Exact commands for open files travel over
-- clangd's compiler-owned compilationDatabaseChanges protocol extension.
local M = {}

local cache = {}
local pending = {}
local delivered = {}

local function explicit_language(command)
  local argv = type(command) == "table" and command.compilationCommand or nil
  if type(argv) ~= "table" then return nil end
  local language
  for index, arg in ipairs(argv) do
    arg = tostring(arg)
    if arg == "-x" then
      language = argv[index + 1] and tostring(argv[index + 1]):lower() or nil
    end
    local joined = arg:match("^%-x(.+)$")
    if joined then language = joined:lower() end
  end
  return language
end

local function compiler_syntax(command)
  local language = explicit_language(command)
  if language == "objective-c++" or language == "objective-c++-header" then
    return "objcpp"
  end
  if language == "objective-c" or language == "objective-c-header" then
    return "objc"
  end
  return nil
end

local function apply_compiler_syntax(bufnr, command)
  if not vim.api.nvim_buf_is_valid(bufnr) or not vim.api.nvim_buf_is_loaded(bufnr) then return end
  local bo = vim.bo[bufnr]
  local target = compiler_syntax(command)
  local owned = vim.b[bufnr].ue_compile_language_syntax
  local compatible = (target == "objcpp" and bo.filetype == "cpp")
    or (target == "objc" and bo.filetype == "c")

  if target and compatible then
    if not owned and bo.syntax == target then return end
    if not owned then vim.b[bufnr].ue_compile_language_previous_syntax = bo.syntax end
    bo.syntax = target
    vim.b[bufnr].ue_compile_language_syntax = target
    return
  end

  if owned then
    if bo.syntax == owned then
      bo.syntax = vim.b[bufnr].ue_compile_language_previous_syntax or ""
    end
    vim.b[bufnr].ue_compile_language_syntax = nil
    vim.b[bufnr].ue_compile_language_previous_syntax = nil
  end
end

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

local function notify(client, method, params, bufnr)
  local called, accepted = pcall(client.notify, client, method, params, bufnr)
  return called and accepted ~= false
end

local function buffer_is_attached(client, bufnr, opts)
  if type(opts.is_attached) == "function" then
    return opts.is_attached(bufnr, client.id) == true
  end
  if not client.id or not vim.api.nvim_buf_is_valid(bufnr)
      or not vim.api.nvim_buf_is_loaded(bufnr) then
    return false
  end
  local ok, attached = pcall(vim.lsp.buf_is_attached, bufnr, client.id)
  return ok and attached == true
end

local function buffer_version(bufnr, opts)
  if type(opts.buffer_version) == "function" then return opts.buffer_version(bufnr) end
  return vim.lsp.util.buf_versions[bufnr] or 0
end

local function language_id(client, bufnr, opts)
  if type(opts.language_id) == "function" then return opts.language_id(bufnr) end
  if type(client.get_language_id) == "function" then
    return client.get_language_id(bufnr, vim.bo[bufnr].filetype)
  end
  return vim.bo[bufnr].filetype
end

local function buffer_text(bufnr, opts)
  if type(opts.buffer_text) == "function" then return opts.buffer_text(bufnr) end
  if type(vim.lsp._buf_get_full_text) == "function" then
    return vim.lsp._buf_get_full_text(bufnr)
  end
  local text = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, true), "\n")
  return vim.bo[bufnr].endofline and (text .. "\n") or text
end

local function delivery_key(client, source, command)
  return table.concat({
    tostring(client.id or client),
    source:lower(),
    norm(command.workingDirectory),
    table.concat(command.compilationCommand or {}, "\0"),
  }, "\1")
end

local function deliver(client, bufnr, source, command, callback, opts)
  opts = opts or {}
  -- UBT deliberately compiles some .cpp/.h files as Objective-C++. Keep their
  -- cpp Tree-sitter parser, but layer Vim's mixed objcpp syntax over constructs
  -- the cpp grammar cannot represent (for example @autoreleasepool/messages).
  apply_compiler_syntax(bufnr, command)
  local live = client and client.id and vim.lsp.get_client_by_id(client.id) or client
  if not live or type(live.notify) ~= "function" then
    callback(false, "clangd-client-stale")
    return
  end
  local key = delivery_key(live, source, command)
  if delivered[key] then
    callback(true, nil, command)
    return
  end

  local reopen = buffer_is_attached(live, bufnr, opts)
  local uri = vim.uri_from_fname(source)
  local close_ok = not reopen or notify(live, "textDocument/didClose", {
    textDocument = { uri = uri },
  }, bufnr)
  local config_ok = notify(live, "workspace/didChangeConfiguration", {
    settings = {
      compilationDatabaseChanges = {
        [source] = command,
      },
    },
  }, bufnr)
  local open_ok = not reopen or notify(live, "textDocument/didOpen", {
    textDocument = {
      version = buffer_version(bufnr, opts),
      uri = uri,
      languageId = language_id(live, bufnr, opts),
      text = buffer_text(bufnr, opts),
    },
  }, bufnr)
  if close_ok and config_ok and open_ok then
    delivered[key] = true
    callback(true, nil, command)
  else
    callback(false, "compile-command-notify-failed")
  end
end

local function consume_command(waiter, command)
  if waiter.opts.syntax_only then
    apply_compiler_syntax(waiter.bufnr, command)
    waiter.callback(true, nil, command)
    return
  end
  deliver(waiter.client, waiter.bufnr, waiter.source, command, waiter.callback, waiter.opts)
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
    consume_command({
      client = client,
      bufnr = bufnr,
      source = source,
      callback = callback,
      opts = opts,
    }, cache[key])
    return
  end
  pending[key] = pending[key] or {}
  pending[key][#pending[key] + 1] = {
    client = client,
    bufnr = bufnr,
    source = source,
    callback = callback,
    opts = opts,
  }
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
          consume_command(waiter, command)
        end
      else
        local reason = ok and decoded and decoded.reason or "compile-command-query-failed"
        for _, waiter in ipairs(waiters) do waiter.callback(false, reason) end
      end
    end)
  end)
end

function M.detect_syntax(bufnr, resolved_cmd, callback)
  callback = callback or function() end
  if type(resolved_cmd) ~= "table" then
    callback(false, "clangd-command-missing")
    return
  end
  M.ensure({ config = { _ue_resolved_cmd = resolved_cmd } }, bufnr, callback, {
    syntax_only = true,
  })
end

function M._reset_for_test()
  cache = {}
  pending = {}
  delivered = {}
end

return M
