-- Exact per-buffer compile commands for the synthetic-only clangd database.
--
-- The on-disk CDB intentionally contains only super-unity TUs so clangd's
-- BackgroundIndex work is bounded. Exact commands for open files travel over
-- clangd's compiler-owned compilationDatabaseChanges protocol extension.
local M = {}
local platform = require("utils.platform")

local cache = {}
local pending = {}
local delivered = {}
local companions = {}

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
  for position = #cmd, 1, -1 do
    local arg = cmd[position]
    local value = tostring(arg):match("^%-%-compile%-commands%-dir=(.+)$")
    if value then
      value = norm(value)
      local original = require("ue.index.batch_runtime").original_cdb_dir(value, client)
      if original then return original end
      if config._ue_batch_scope or (vim.fs.basename(value) == "verified"
          and vim.fs.basename(vim.fs.dirname(value)) == "background-cdb") then
        return nil, "frozen-cdb-unverified"
      end
      if vim.fs.basename(value) == "background-cdb"
          and (vim.uv or vim.loop).fs_stat(value .. "/compile_commands.json") then
        return value
      end
      return nil
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
  local resolved = platform.resolve_tool({
    name = "python",
    env = { "UE_PYTHON" },
    driver_candidates = function(driver)
      return driver.python_candidates()
    end,
  })
  return resolved.ok and norm(resolved.path) or nil
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
  if waiter.opts.is_current and not waiter.opts.is_current() then
    waiter.callback(false, "stale-request")
    return
  end
  if waiter.opts.syntax_only then
    apply_compiler_syntax(waiter.bufnr, command)
    waiter.callback(true, nil, command)
    return
  end
  deliver(waiter.client, waiter.bufnr, waiter.source, command, waiter.callback, waiter.opts)
end

local function query_command(cdb, source, extra, callback)
  local python = python_command()
  local script = norm(vim.fn.stdpath("config") .. "/tools/query_compile_command.py")
  if not python or not (vim.uv or vim.loop).fs_stat(script) then
    callback(nil, "compile-command-tool-missing")
    return
  end
  local cmd = { python, script, cdb, source }
  vim.list_extend(cmd, extra or {})
  return vim.system(cmd, { text = true }, function(result)
    vim.schedule(function()
      local ok, decoded = pcall(vim.json.decode, result.stdout or "")
      callback(ok and decoded or nil, ok and decoded and decoded.reason or "compile-command-query-failed")
    end)
  end)
end

local function proven_header_command(proof, source, cdb)
  local context = type(proof) == "table" and proof.context or nil
  local response = type(proof) == "table" and proof.response or nil
  local environment = type(proof) == "table" and proof.environment or nil
  if type(context) ~= "table" or type(response) ~= "table" or type(environment) ~= "table"
      or type(proof.is_current) ~= "function" or not proof.is_current()
      or response.op ~= "query" or response.state ~= "resolved"
      or type(response.usr) ~= "string" or response.usr == ""
      or response.context_id ~= (context.id or context.context_id)
      or context.build_fingerprint ~= environment.build_fingerprint
      or norm(environment.cdb_path):lower() ~= norm(cdb):lower()
      or norm(context.cdb_dir):lower() ~= norm(vim.fs.dirname(cdb)):lower() then
    return nil, "header-command-provenance-invalid"
  end
  local model = require("utils.ue_goto.semantic_context")
  if not model.context_supports_subject(context, source) then
    return nil, "header-command-subject-unproven"
  end
  local semantic = require("utils.ue_goto.semantic_client")
  local session = semantic.status().session
  if type(response.compiler_session) ~= "table" or not session
      or not vim.deep_equal(response.compiler_session, session) then
    return nil, "header-command-compiler-session-stale"
  end
  local compiler_evidence
  for _, record in ipairs(response.contexts or {}) do
    if record.context_id == response.context_id and record.state == "resolved"
        and record.usr == response.usr and type(record.compile_command_fingerprint) == "string"
        and record.compile_command_fingerprint ~= "" then
      compiler_evidence = record
    end
  end
  local compile = context.compile
  if not compiler_evidence or type(compile) ~= "table" or type(compile.directory) ~= "string"
      or compile.directory == "" or type(compile.argv) ~= "table" or #compile.argv < 2
      or vim.fn.sha256(vim.json.encode(compile)) ~= proof.compile_digest then
    return nil, "header-command-descriptor-unproven"
  end
  local descriptor = require("utils.ue_goto.reading_compile")
  if not descriptor.matches_native(compile, context.origin_tu, compiler_evidence.compile_command_fingerprint) then
    return nil, "header-command-compiler-descriptor-mismatch"
  end
  return descriptor.rebind(compile, context.origin_tu, source)
end

-- This is explicit file pairing, not semantic TU selection. The caller's
-- immutable reading owner guards the CDB signature and any late result.
function M.find_companion(cdb, source, callback, opts)
  opts = opts or {}
  cdb, source = norm(cdb), norm(source)
  local stat = (vim.uv or vim.loop).fs_stat(cdb)
  if not stat or stat.type ~= "file" then callback(nil, "companion-cdb-unavailable"); return end
  local key = table.concat({ cdb, tostring(stat.size), tostring(stat.mtime.sec),
    tostring(stat.mtime.nsec), vim.fs.basename(source):lower() }, "\0")
  local function finish(value, reason)
    if opts.is_current and not opts.is_current() then return end
    callback(value, reason)
  end
  if companions[key] then finish(vim.deepcopy(companions[key])); return end
  return query_command(cdb, source, { "--companion" }, function(result, reason)
    local candidates = result and result.candidates
    if result and result.state == "resolved" and type(candidates) == "table" then
      if vim.tbl_count(companions) >= 128 then companions = {} end
      companions[key] = candidates
      finish(vim.deepcopy(candidates))
    else
      finish(nil, reason)
    end
  end)
end

function M.ensure(client, bufnr, callback, opts)
  callback = callback or function() end
  opts = opts or {}
  local semantic_dir, authority_error = controlled_cdb_dir(client)
  if not semantic_dir then
    callback(authority_error == nil, authority_error)
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
  if opts.proven_header then
    local command, reason = proven_header_command(opts.proven_header, source, cdb)
    if not command then callback(false, reason); return end
    consume_command({ client = client, bufnr = bufnr, source = source,
      callback = callback, opts = opts }, command)
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

  local extra = {}
  if command_source:lower() ~= source:lower() then
    extra = { "--subject", source }
  end
  query_command(cdb, command_source, extra, function(decoded, query_reason)
      local waiters = pending[key] or {}
      pending[key] = nil
      local command = decoded and decoded.state == "resolved" and decoded.command or nil
      if type(command) == "table"
          and type(command.workingDirectory) == "string"
          and type(command.compilationCommand) == "table" then
        cache[key] = command
        for _, waiter in ipairs(waiters) do
          consume_command(waiter, command)
        end
      else
        local reason = query_reason or "compile-command-query-failed"
        for _, waiter in ipairs(waiters) do waiter.callback(false, reason) end
      end
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
  companions = {}
end

return M
