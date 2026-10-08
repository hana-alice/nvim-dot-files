-- Public reading intent: guarded references/header switch and explicit Peek.
local M = {}
local ownership = require("utils.ue_goto.reading_owner")
local results = require("utils.ue_goto.reading_results")
local last_references
local methods = {
  definition = "textDocument/definition",
  declaration = "textDocument/declaration",
  implementation = "textDocument/implementation",
  type_definition = "textDocument/typeDefinition",
  references = "textDocument/references",
}
local titles = {
  definition = "定义预览",
  declaration = "声明预览",
  implementation = "实现预览",
  type_definition = "类型定义预览",
  references = "引用",
}

local function notify(owner, message)
  if ownership.current(owner, true) then
    vim.notify(message, vim.log.levels.WARN, { title = "代码阅读" })
  end
end

local function begin()
  local owner = ownership.begin()
  local semantic = package.loaded["utils.ue_goto.semantic_client"]
  if semantic and semantic.cancel_action then
    semantic.cancel_action()
  end
  return owner
end

local function current_word()
  local ok, word = pcall(require("utils.ue_goto.symbol").current_symbol)
  return ok and word or nil
end

function M.choose_client(owner, method, callback, clangd_only)
  local clients = {}
  for _, client in pairs(owner.clients) do
    if
      (not clangd_only or tostring(client.name):lower():find("clangd", 1, true))
      and client:supports_method(method, owner.buf)
    then
      clients[#clients + 1] = client
    end
  end
  table.sort(clients, function(left, right)
    return left.id < right.id
  end)
  if #clients == 0 then
    notify(owner, "当前位置没有支持此操作的提供者；覆盖未知")
    return false
  end
  if #clients == 1 then
    callback(clients[1])
    return true
  end
  local snacks = _G.Snacks
  if not snacks then
    local ok, loaded = pcall(require, "snacks")
    if ok then
      snacks = loaded
    end
  end
  if not snacks or not snacks.picker then
    notify(owner, "Snacks picker 不可用")
    return false
  end
  local rows = vim.tbl_map(function(client)
    return { text = client.name .. " #" .. client.id, client = client }
  end, clients)
  ownership.present(owner, function()
    return snacks.picker.pick({
      title = "选择提供者",
      items = rows,
      format = "text",
      preview = "none",
      auto_confirm = false,
      win = {
        input = { keys = { ["<Esc>"] = { "cancel", mode = { "n", "i" } }, ["<C-s>"] = false, ["<C-t>"] = false } },
        list = { keys = { ["<C-s>"] = false, ["<C-t>"] = false } },
      },
      confirm = function(picker, row)
        if not row or not ownership.current(owner, true) then
          return
        end
        ownership.confirm_picker(owner, picker, function()
          callback(row.client)
        end)
      end,
      on_close = function(picker)
        ownership.picker_closed(owner, picker)
      end,
    })
  end)
  return true
end

function M.choose_context(owner, contexts, callback)
  if not ownership.current(owner, true) then
    return false
  end
  local snacks = _G.Snacks
  if not snacks then
    local ok, loaded = pcall(require, "snacks")
    if ok then
      snacks = loaded
    end
  end
  if not snacks or not snacks.picker then
    notify(owner, "Snacks picker 不可用")
    return false
  end
  local rows = vim.tbl_map(function(context)
    return { text = require("utils.ue_goto.ui").context_label(context), context = context }
  end, contexts)
  return ownership.present(owner, function()
    return snacks.picker.pick({
      title = "编译器已证明的上下文存在分歧",
      items = rows,
      format = "text",
      preview = "none",
      auto_confirm = false,
      win = {
        input = { keys = { ["<Esc>"] = { "cancel", mode = { "n", "i" } }, ["<C-s>"] = false, ["<C-t>"] = false } },
        list = { keys = { ["<C-s>"] = false, ["<C-t>"] = false } },
      },
      confirm = function(picker, row)
        if row then
          ownership.confirm_picker(owner, picker, function()
            callback(row.context)
          end)
        end
      end,
      on_close = function(picker)
        ownership.picker_closed(owner, picker)
      end,
    })
  end) ~= nil
end

local function present(owner, locations, opts)
  if not ownership.current(owner, true) then
    return
  end
  local rows, truncated = results.items(locations)
  opts.truncated = opts.truncated or truncated
  return results.open(owner, rows, opts)
end

local function references_gtags(owner, symbol, reason)
  if not ownership.current(owner, true) then
    return
  end
  local ok, ue = pcall(require, "ue")
  if not ok or type(ue.gtags_references_async) ~= "function" then
    notify(owner, "引用提供者未返回结果（" .. tostring(reason) .. "）；覆盖未知")
    return
  end
  local completed = false
  local handle = ue.gtags_references_async(symbol, function(hit, entries)
    completed = true
    if not ownership.current(owner, true) then
      return
    end
    if not hit or type(entries) ~= "table" or #entries == 0 then
      notify(owner, "LSP / GTAGS 未返回引用；覆盖未知，不能据此断言没有引用")
      return
    end
    local locations = {}
    for _, entry in ipairs(entries) do
      locations[#locations + 1] = {
        uri = vim.uri_from_fname(entry.filename),
        _position_encoding = "utf-8",
        range = { start = { line = entry.lnum - 1, character = math.max(0, (entry.col or 1) - 1) } },
      }
    end
    present(owner, locations, { title = "引用 · 文本索引结果", source = "GTAGS" })
  end, {
    context = owner.context,
    collect = true,
    is_current = function()
      return ownership.current(owner, true)
    end,
  })
  if handle and type(handle.kill) == "function" then
    ownership.add_cleanup(owner, function()
      local ok_closing, closing = true, false
      if type(handle.is_closing) == "function" then
        ok_closing, closing = pcall(handle.is_closing, handle)
      end
      if not completed and ok_closing and not closing then
        pcall(handle.kill, handle, 15)
      end
    end)
  end
end

function M.references()
  local owner = begin()
  local started = (vim.uv or vim.loop).hrtime()
  local symbol = current_word()
  if not symbol or symbol == "" then
    notify(owner, "光标处没有符号")
    return false
  end
  local header = require("utils.ue_goto.reading_companion").kind(owner.path) == "header" and owner.context ~= nil
  local function record(proof, state, stage, reason, count)
    if not ownership.current(owner, true) then return end
    local context = proof and proof.context or {}
    last_references = {
      subject = vim.fs.basename(owner.path), donor = vim.fs.basename(context.compile and context.compile.file or context.origin_tu or ""),
      evidence_kind = context.evidence_kind or (proof and "compiler-query" or "-"),
      context_id = context.id or context.context_id,
      compile_digest = proof and proof.compile_digest,
      state = state, stage = stage, reason = reason, location_count = count or 0,
      elapsed_ms = math.floor(((vim.uv or vim.loop).hrtime() - started) / 1000000),
    }
  end
  local function request(proof)
    if not ownership.current(owner, true) then return end
    require("utils.ue_goto.provider").async_lsp_request(owner.buf, methods.references, function(response)
    if not ownership.current(owner, true) then
      return
    end
    local locations = type(response) == "table" and (response.locations or (vim.islist(response) and response)) or {}
    if type(locations) ~= "table" then
      locations = {}
    end
    if #locations > 0 then
      record(proof, "resolved", "references", "provider-locations", #locations)
      present(owner, locations, { title = "引用", source = "LSP" })
    elseif header then
      local reason = type(response) == "table" and response.reason or "missing-provider-response"
      record(proof, "unavailable", "references", reason)
      notify(owner, "头文件引用不可用（" .. tostring(reason) .. "）；覆盖未知")
    else
      references_gtags(owner, symbol, type(response) == "table" and response.reason or "missing-provider-response")
    end
  end, {
    snapshot = owner,
    structured = true,
    proven_header = proof,
    is_current = function()
      return ownership.current(owner, true)
    end,
    register_cancel = function(cancel)
      return ownership.add_cleanup(owner, cancel)
    end,
  })
  end
  if header then
    record(nil, "preparing", "context", "header-origin-pending")
    require("utils.ue_goto.reading_context").resolve_header(owner, function(contexts, callback)
      return M.choose_context(owner, contexts, callback)
    end, function(proof, failure)
      if not ownership.current(owner, true) then return end
      if not proof then
        local reason = failure and failure.reason or "header-origin-unproven"
        record(nil, "unavailable", "context", reason)
        notify(owner, "头文件引用缺少已证明的编译上下文（" .. tostring(reason) .. "）")
        return
      end
      record(proof, "preparing", "command", "compiler-origin-proven")
      request(proof)
    end)
  else
    request()
  end
  return true
end

function M.explain_lines()
  if not last_references then return {} end
  local report = last_references
  local function safe(value)
    return tostring(value or "-"):gsub("\\", "/"):gsub("[%a]:/[^%c]+", "<path>"):gsub("%c", " "):sub(1, 160)
  end
  return {
    "--- references ---",
    string.format("references: subject=%s state=%s stage=%s reason=%s", safe(report.subject), safe(report.state), safe(report.stage), safe(report.reason)),
    string.format("references donor: %s evidence=%s context=%s command=%s", safe(report.donor), safe(report.evidence_kind),
      safe((report.context_id or ""):sub(1, 12)), safe((report.compile_digest or ""):sub(1, 12))),
    string.format("references timing: elapsed_ms=%d locations=%d", report.elapsed_ms, report.location_count),
  }
end

function M.source_header(opts)
  local owner = begin()
  local method = "textDocument/switchSourceHeader"
  local companion = require("utils.ue_goto.reading_companion")
  local function deliver(paths, provider)
    if not ownership.current(owner, true) then return end
    local locations = vim.tbl_map(function(path)
      return { uri = vim.uri_from_fname(path), _position_encoding = "utf-8", range = { start = { line = 0, character = 0 } } }
    end, paths)
    local rows = results.items(locations)
    if #rows == 0 then notify(owner, "对应文件不存在或不是可读文件"); return end
    if (opts and opts.peek) or #rows > 1 then
      results.open(owner, rows, { title = "对应头源文件", source = provider })
    else
      results.jump(owner, rows[1])
    end
  end
  local function provider_fallback()
    return M.choose_client(owner, method, function(client)
    ownership.request(owner, client, method, { uri = owner.subject.uri }, function(err, uri)
      if err then
        notify(owner, "头源查询失败：" .. tostring(err.message))
        return
      end
      if type(uri) ~= "string" or uri == "" or uri:sub(1, 5) ~= "file:" then
        notify(owner, "提供者没有可打开的对应文件；不会猜测配对")
        return
      end
      local decoded, path = pcall(vim.uri_to_fname, uri)
      if decoded then path = vim.fs.normalize(path) end
      local valid, rule
      if decoded then valid, rule = companion.valid_pair(owner.path, path) end
      if not valid then
        notify(owner, "提供者返回了生成文件或非对应头源文件；不会接受该目标")
        return
      end
      if rule == "same-basename" then deliver({ path }, client.name .. " · 同名文件"); return end
      local source = companion.kind(owner.path) == "source" and owner.path or path
      local header = companion.kind(owner.path) == "header" and owner.path or path
      require("utils.ue_goto.reading_context").prove_companion(owner, source, header, function(proven, reason)
        if not ownership.current(owner, true) then return end
        if proven then deliver({ path }, client.name .. " · 编译器 include 证明")
        else notify(owner, "对应关系未被编译器证明（" .. tostring(reason) .. "）") end
      end)
    end)
  end, true)
  end
  companion.known_sources(owner, function(paths)
    if not ownership.current(owner, true) then return end
    if paths then deliver(paths, "active CDB · 同名源文件") else provider_fallback() end
  end)
  return true
end

local function cpp_definition_peek(owner)
  local nav_module = require("utils.ue_goto.semantic_navigation")
  local ext = require("utils.ue_goto.ui").buf_extension(owner.buf)
  if not (nav_module.CPP_SOURCE_EXTS[ext] or nav_module.CPP_HEADER_EXTS[ext]) then
    return false
  end
  local inspection_owner = {}
  local navigation = nav_module.install(inspection_owner, {
    dtrace = function() end,
    jump_to_location = function()
      return false
    end,
    format_jump_msg = function()
      return ""
    end,
    inspection_current = function()
      return ownership.current(owner, true)
    end,
    inspection_choose_context = function(contexts, callback)
      return M.choose_context(owner, contexts, callback)
    end,
  })
  navigation.cpp_definition(current_word(), owner.buf, owner.path, ext, function(proof, failure)
    if not ownership.current(owner, true) then
      return
    end
    if not proof then
      notify(owner, "定义预览不可用：" .. tostring(failure and failure.reason or "unknown"))
      return
    end
    local rows = results.items({ proof.location })
    if rows[1] then
      rows[1].proof_is_current = proof.is_current
    end
    if rows[1] and proof.origin_context then
      rows[1].on_jump = function(win)
        require("utils.ue_goto.semantic_client").note_origin(win, proof.origin_context, proof.build_fingerprint)
      end
    end
    results.open(owner, rows, { title = "定义预览 · 编译器身份已证明", source = proof.provider })
  end)
  return true
end

function M.peek(kind)
  kind = kind or "definition"
  if not methods[kind] then
    vim.notify("未知预览类型：" .. tostring(kind), vim.log.levels.WARN)
    return false
  end
  if kind == "references" then
    return M.references()
  end
  local owner = begin()
  if kind == "definition" and cpp_definition_peek(owner) then
    return true
  end
  return M.choose_client(owner, methods[kind], function(client)
    local params =
      require("utils.ue_goto.semantic_transaction").make_position_params(owner, owner.buf, client.offset_encoding)
    params._position_encoding = nil
    ownership.request(owner, client, methods[kind], params, function(err, value)
      if err then
        notify(owner, "预览请求失败：" .. tostring(err.message))
        return
      end
      present(
        owner,
        require("utils.ue_goto.location").normalize_locations(value, client.offset_encoding),
        { title = titles[kind], source = client.name }
      )
    end)
  end)
end

function M.calls(kind)
  if kind ~= "incoming" and kind ~= "outgoing" then
    return false
  end
  local owner = begin()
  local prepare = "textDocument/prepareCallHierarchy"
  local method = kind == "incoming" and "callHierarchy/incomingCalls" or "callHierarchy/outgoingCalls"
  return M.choose_client(owner, prepare, function(client)
    local params =
      require("utils.ue_goto.semantic_transaction").make_position_params(owner, owner.buf, client.offset_encoding)
    params._position_encoding = nil
    ownership.request(owner, client, prepare, params, function(err, roots)
      if err then
        notify(owner, "调用根查询失败：" .. tostring(err.message))
        return
      end
      if type(roots) ~= "table" or #roots == 0 then
        notify(owner, "当前位置未返回调用根（覆盖未知）")
        return
      end
      local locations, pending, partial = {}, math.min(#roots, 128), #roots > 128
      for index = 1, pending do
        ownership.request(owner, client, method, { item = roots[index] }, function(child_error, calls)
          partial = partial or child_error ~= nil
          for _, call in ipairs(type(calls) == "table" and calls or {}) do
            local item = kind == "incoming" and call.from or call.to
            if type(item) == "table" then
              local ranges = kind == "incoming" and call.fromRanges or { item.selectionRange or item.range }
              for _, range in ipairs(ranges or {}) do
                locations[#locations + 1] =
                  { uri = item.uri, range = range, _position_encoding = client.offset_encoding }
              end
            end
          end
          pending = pending - 1
          if pending == 0 then
            present(owner, locations, {
              title = (kind == "incoming" and "谁调用了它" or "它调用了谁")
                .. (partial and " · 部分请求/范围受限" or ""),
              source = client.name,
              truncated = partial,
            })
          end
        end)
      end
    end)
  end, true)
end

function M.cancel()
  ownership.cancel()
  local semantic = package.loaded["utils.ue_goto.semantic_client"]
  if semantic and semantic.cancel_action then
    semantic.cancel_action()
  end
end

function M.return_to_origin()
  M.cancel()
  return results.return_to_origin()
end

function M.setup_commands()
  vim.api.nvim_create_user_command("UEPeek", function(opts)
    M.peek(opts.args ~= "" and opts.args or nil)
  end, {
    nargs = "?",
    desc = "Preview provider locations without leaving the reading point",
    complete = function()
      return { "definition", "declaration", "implementation", "type_definition", "references" }
    end,
  })
  vim.api.nvim_create_user_command(
    "UEReadCancel",
    M.cancel,
    { desc = "Cancel the current reading request and preview" }
  )
  vim.api.nvim_create_user_command(
    "UEReadReturn",
    M.return_to_origin,
    { desc = "Return to the explicit investigation origin" }
  )
  vim.api.nvim_create_user_command("UERelations", function(opts)
    local relations = require("utils.ue_goto.relations")
    if opts.args == "resume" then
      relations.resume()
    else
      relations.open(opts.args ~= "" and opts.args or "incoming")
    end
  end, {
    nargs = "?",
    desc = "Browse calls or types by expanding one relation at a time",
    complete = function()
      return { "incoming", "outgoing", "base", "derived", "resume" }
    end,
  })
end

return M
