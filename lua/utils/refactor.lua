-- Safe client-specific rename/code-action routing. No global LSP handlers.
local M = {}
local api, uv = vim.api, vim.uv or vim.loop
local edits = require("utils.workspace_edit")
local preview = require("utils.rename_preview")
local commands = require("utils.refactor_command")
local active, last_batch, serial = nil, nil, 0

local function notify(message, level)
  vim.notify(message, level or vim.log.levels.INFO, { title = "修改预览" })
end

local function guard_state(client)
  local owned = client._ue_batch_guard
  return owned and owned.guard:status() or nil
end

local function selection(client)
  local root = client.config and client.config.root_dir
  local values = {}
  if root and package.loaded["ue.project_state"] then
    local state = require("ue.project_state").read(root)
    for _, key in ipairs({ "project_root", "uproject", "engine_root", "target_platform", "target_configuration" }) do
      values[key] = state[key]
    end
  end
  return {
    values = values,
    cwd = uv.cwd(),
    root = root,
    command = vim.deepcopy(client.config and (client.config._ue_resolved_cmd or client.config.cmd)),
    batch_scope = client.config and client.config._ue_batch_scope,
    batch_stamp = client.config and client.config._ue_batch_stamp,
  }
end

local function source()
  local buf, win = api.nvim_get_current_buf(), api.nvim_get_current_win()
  local cursor = api.nvim_win_get_cursor(win)
  local mode = api.nvim_get_mode().mode
  local region
  if mode == "v" or mode == "V" then
    local anchor = vim.fn.getpos("v")
    local first, last = { anchor[2], anchor[3] - 1 }, { cursor[1], cursor[2] }
    if first[1] > last[1] or (first[1] == last[1] and first[2] > last[2]) then
      first, last = last, first
    end
    if mode == "V" then
      first[2], last[2] = 0, #api.nvim_buf_get_lines(buf, last[1] - 1, last[1], true)[1]
    end
    region = { start = first, ["end"] = last, linewise = mode == "V" }
  end
  local baseline = {}
  for _, id in ipairs(api.nvim_list_bufs()) do
    if api.nvim_buf_is_loaded(id) then
      baseline[id] = { name = api.nvim_buf_get_name(id), tick = api.nvim_buf_get_changedtick(id) }
    end
  end
  return {
    buf = buf,
    win = win,
    name = api.nvim_buf_get_name(buf),
    tick = api.nvim_buf_get_changedtick(buf),
    cursor = cursor,
    line = api.nvim_buf_get_lines(buf, cursor[1] - 1, cursor[1], true)[1],
    default_name = vim.fn.expand("<cword>"),
    region = region,
    baseline = baseline,
  }
end

local function capture(client, origin)
  return {
    client = client,
    id = client.id,
    encoding = client.offset_encoding or "utf-16",
    origin = origin,
    selection = selection(client),
    guard = guard_state(client),
  }
end

local function source_current(origin)
  return api.nvim_buf_is_valid(origin.buf)
    and api.nvim_buf_is_loaded(origin.buf)
    and api.nvim_buf_get_name(origin.buf) == origin.name
    and api.nvim_buf_get_changedtick(origin.buf) == origin.tick
end

local function current(record, phase)
  local client, origin = record.client, record.origin
  if
    vim.lsp.get_client_by_id(record.id) ~= client
    or (client.is_stopped and client:is_stopped())
    or not vim.lsp.buf_is_attached(origin.buf, record.id)
  then
    return false, "client-detached-or-replaced"
  end
  if
    record.encoding ~= (client.offset_encoding or "utf-16") or not vim.deep_equal(record.selection, selection(client))
  then
    return false, "project-target-or-client-config-changed"
  end
  -- Own text changes may revoke the frozen batch after the first write. The
  -- complete batch is checked before that write; later files use owned versions.
  if phase ~= "applying" then
    if not source_current(origin) then
      return false, "source-changed"
    end
    local guard = guard_state(client)
    if not vim.deep_equal(record.guard, guard) or (guard and guard.state ~= "ready") then
      return false, "coverage-epoch-changed"
    end
  end
  return true
end

local function begin()
  if active then
    active.cancelled = true
    if active.batch then
      edits.cancel(active.batch)
    end
    for _, cleanup in ipairs(active.cleanups or {}) do
      cleanup()
    end
    for _, request in ipairs(active.requests) do
      pcall(request.client.cancel_request, request.client, request.id)
    end
  end
  preview.close()
  serial = serial + 1
  active = { id = serial, requests = {}, cleanups = {} }
  return active
end

local function alive(action)
  return active == action and not action.cancelled
end

local function request(action, record, method, params, callback)
  local good, reason = current(record)
  if not alive(action) or not good then
    if alive(action) then
      callback({ message = reason or "request-stale" })
    end
    return
  end
  local done = false
  local ok, accepted, id = pcall(record.client.request, record.client, method, params, function(err, result)
    if done then
      return
    end
    done = true
    if not alive(action) then
      return
    end
    local stable, stale = current(record)
    if not stable then
      callback({ message = stale or "request-stale" })
      return
    end
    callback(err, result)
  end, record.origin.buf)
  if not ok or accepted == false then
    if not done then
      done = true
      callback({ message = ok and "request-rejected" or tostring(accepted) })
    end
    return
  end
  if id then
    action.requests[#action.requests + 1] = { client = record.client, id = id }
  end
end

local function position(record)
  local origin = record.origin
  return {
    textDocument = { uri = vim.uri_from_fname(origin.name) },
    position = {
      line = origin.cursor[1] - 1,
      character = vim.str_utfindex(origin.line, record.encoding, origin.cursor[2], false),
    },
  }
end

local function error_message(err)
  return type(err) == "table" and err.message or tostring(err)
end

local function show_evidence(batch)
  local report = edits.report(batch) or {}
  local lines = {
    batch.label,
    "操作：" .. tostring(report.operation or "apply"),
    "结果：" .. tostring(report.state or batch.state),
    "原因：" .. tostring(report.failure or ""),
    "恢复快照保留于当前进程；下方只列本次应用/恢复结果，不写工程文件。",
    "",
  }
  for _, item in ipairs(report.files or {}) do
    lines[#lines + 1] = ("%s  %s%s"):format(item.state, item.path, item.reason and (" — " .. item.reason) or "")
  end
  local buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_lines(buf, 0, -1, true, lines)
  vim.bo[buf].bufhidden, vim.bo[buf].swapfile = "wipe", false
  vim.bo[buf].modified, vim.bo[buf].modifiable = false, false
  api.nvim_open_win(buf, true, {
    relative = "editor",
    width = math.max(30, math.min(vim.o.columns - 4, 110)),
    height = math.max(2, math.min(#lines, vim.o.lines - 6)),
    row = 2,
    col = 2,
    style = "minimal",
    border = "rounded",
  })
  vim.keymap.set("n", "q", "<cmd>close<cr>", { buffer = buf, desc = "Close recovery evidence" })
end

local menu
local function apply(action)
  local batch = action.batch
  if not alive(action) or not batch or batch.state ~= "preview" or action.confirming then
    return
  end
  action.confirming = true
  local answer = vim.fn.confirm(
    ("应用 %s 的全部 %d 个文件？\n修改保留在缓冲区，不自动保存。"):format(
      batch.label,
      #batch.targets
    ),
    "应用 (&y)\n取消 (&n)",
    2
  )
  action.confirming = false
  if answer ~= 1 then
    if alive(action) then
      menu(action)
    end
    return
  end
  if not alive(action) then
    return
  end
  edits.apply(batch, function(ok, reason)
    if not alive(action) then
      return
    end
    last_batch = batch
    if ok then
      notify(
        ("已应用 %d 个文件；修改尚未保存。:UERefactorUndo 可撤销本批次。"):format(#batch.targets)
      )
    else
      notify("未完成修改：" .. tostring(reason), vim.log.levels.ERROR)
      if batch.state == "failed" then
        show_evidence(batch)
      end
    end
  end)
end

local function cancel(action)
  action.cancelled = true
  if action.batch then
    edits.cancel(action.batch)
  end
  for _, cleanup in ipairs(action.cleanups) do
    cleanup()
  end
  preview.close()
end

menu = function(action)
  if not alive(action) or not action.batch or action.batch.state ~= "preview" then
    return
  end
  local items = { { kind = "apply", title = "应用整批（再次确认，保留未保存）" } }
  for _, target in ipairs(action.batch.targets) do
    items[#items + 1] = {
      kind = "file",
      target = target,
      title = ("查看 diff  %s  · %d 处%s"):format(
        target.path,
        target.edit_count,
        target.before.options.modified and " · 已有未保存修改" or ""
      ),
    }
  end
  items[#items + 1] = { kind = "cancel", title = "取消（零修改）" }
  vim.ui.select(items, {
    prompt = action.batch.label .. " — 受影响文件",
    format_item = function(item)
      return item.title
    end,
  }, function(item)
    if not alive(action) or action.batch.state ~= "preview" then
      return
    end
    if not item or item.kind == "cancel" then
      cancel(action)
    elseif item.kind == "apply" then
      apply(action)
    else
      local ok, err = preview.open(action.batch, item.target, {
        back = function()
          menu(action)
        end,
        apply = function()
          apply(action)
        end,
        cancel = function()
          cancel(action)
        end,
      })
      if not ok then
        notify(err, vim.log.levels.ERROR)
        menu(action)
      end
    end
  end)
end

local function present_edit(action, record, edit, label)
  if not alive(action) then
    return
  end
  local prepared = edits.prepare(edit, record.encoding, {
    label = label,
    baseline = record.origin.baseline,
    client = record.client,
    check = function(phase)
      if not alive(action) then
        return false, "request-cancelled"
      end
      return current(record, phase)
    end,
  }, function(batch, reason)
    if not alive(action) then
      return
    end
    if not batch then
      notify("无法准备修改：" .. tostring(reason), vim.log.levels.WARN)
      return
    end
    action.batch = batch
    menu(action)
  end)
  if prepared then
    action.batch = prepared
  end
end

local function ensure(record, action, callback, failed)
  if record.client.name ~= "clangd" then
    callback()
    return
  end
  local finished = false
  require("ue.clangd_commands").ensure(record.client, record.origin.buf, function(ok, reason)
    if finished then
      return
    end
    finished = true
    if not alive(action) then
      return
    end
    local good, stale = current(record)
    if not ok or not good then
      notify(reason or stale, vim.log.levels.WARN)
      if failed then
        failed(reason or stale)
      end
      return
    end
    callback()
  end, {
    is_current = function()
      return alive(action) and current(record)
    end,
  })
end

local command_context = {
  alive = alive,
  current = current,
  notify = notify,
  present_edit = present_edit,
  error_message = error_message,
}

function M.rename(new_name)
  local origin, action = source(), begin()
  local clients = vim.lsp.get_clients({ bufnr = origin.buf, method = "textDocument/rename" })
  if #clients == 0 then
    notify("当前缓冲区没有支持 rename 的语言服务器", vim.log.levels.WARN)
    return
  end
  local chosen = false
  local function use(client)
    if not client or not alive(action) then
      return
    end
    if chosen then
      return
    end
    chosen = true
    local record = capture(client, origin)
    local function rename(name)
      if not name or name == "" then
        cancel(action)
        return
      end
      local params = position(record)
      params.newName = name
      request(action, record, "textDocument/rename", params, function(err, result)
        if err then
          notify("rename: " .. error_message(err), vim.log.levels.WARN)
        elseif not result then
          notify("语言服务器未返回修改")
        else
          present_edit(action, record, result, "Rename → " .. name)
        end
      end)
    end
    local function prompt(result)
      if new_name then
        rename(new_name)
        return
      end
      local default = result and result.placeholder or origin.default_name
      local input_done = false
      vim.ui.input({ prompt = "新名称（下一步预览）: ", default = default }, function(input)
        if input_done then
          return
        end
        input_done = true
        rename(input)
      end)
    end
    ensure(record, action, function()
      if client:supports_method("textDocument/prepareRename", origin.buf) then
        request(action, record, "textDocument/prepareRename", position(record), function(err, result)
          if err or not result then
            notify(err and error_message(err) or "当前位置不可重命名", vim.log.levels.WARN)
            return
          end
          prompt(result)
        end)
      else
        prompt()
      end
    end)
  end
  if #clients == 1 then
    use(clients[1])
  else
    vim.ui.select(clients, {
      prompt = "选择 rename 服务器",
      format_item = function(client)
        return client.name
      end,
    }, use)
  end
  return action
end

local function range_params(record, requested)
  local origin, encoding = record.origin, record.encoding
  local region = requested or origin.region
  if not region then
    local params = position(record)
    params.range, params.position = { start = vim.deepcopy(params.position), ["end"] = params.position }, nil
    return params
  end
  local function encoded(point, inclusive)
    local line = api.nvim_buf_get_lines(origin.buf, point[1] - 1, point[1], true)[1] or ""
    local byte = math.min(#line, point[2])
    if inclusive and byte < #line then
      byte = vim.str_byteindex(line, "utf-32", vim.str_utfindex(line, "utf-32", byte, false) + 1, false)
    end
    return { line = point[1] - 1, character = vim.str_utfindex(line, encoding, byte, false) }
  end
  return {
    textDocument = { uri = vim.uri_from_fname(origin.name) },
    range = {
      start = encoded(region.start),
      ["end"] = encoded(region["end"], not region.linewise and vim.o.selection ~= "exclusive"),
    },
  }
end

local function action_reason(action, record)
  if action.disabled then
    return "不可用：" .. tostring(action.disabled.reason or "server disabled")
  end
  if record and commands.capturable(action, record) then
    return "命令返回修改后预览"
  end
  if action.command then
    return "命令副作用尚不支持预览"
  end
  return nil
end

function M.code_actions(opts)
  opts = opts or {}
  local origin, action = source(), begin()
  local clients = vim.lsp.get_clients({ bufnr = origin.buf, method = "textDocument/codeAction" })
  if #clients == 0 then
    notify("当前缓冲区没有支持 code action 的语言服务器", vim.log.levels.WARN)
    return
  end
  local choices, remaining, errors = {}, #clients, {}
  local choice_made = false
  local function selected(choice)
    if not choice or not alive(action) then
      return
    end
    if choice_made then
      return
    end
    choice_made = true
    local item, record = choice.action, choice.record
    local function display(resolved)
      if resolved.disabled then
        notify(action_reason(resolved), vim.log.levels.WARN)
      elseif commands.capturable(resolved, record) then
        commands.capture(action, record, resolved, command_context)
      elseif resolved.command then
        commands.native(action, record, resolved, command_context)
      elseif resolved.edit then
        present_edit(action, record, resolved.edit, resolved.title or item.title)
      else
        notify("语言服务器未返回可预览的 WorkspaceEdit", vim.log.levels.WARN)
      end
    end
    if action_reason(item) then
      display(item)
    elseif item.edit then
      display(item)
    elseif record.client:supports_method("codeAction/resolve", origin.buf) then
      request(action, record, "codeAction/resolve", item, function(err, resolved)
        if err or not resolved then
          notify("resolve: " .. error_message(err or "empty result"), vim.log.levels.WARN)
        else
          display(resolved)
        end
      end)
    else
      display(item)
    end
  end
  local function finish(record, err, result)
    if not alive(action) then
      return
    end
    if not source_current(origin) then
      notify("source-changed", vim.log.levels.WARN)
      cancel(action)
      return
    end
    if err then
      errors[#errors + 1] = error_message(err)
    end
    for _, item in ipairs(result or {}) do
      if type(item.title) == "string" and (not opts.query or item.title:lower():find(opts.query:lower(), 1, true)) then
        choices[#choices + 1] = { action = item, record = record }
      end
    end
    remaining = remaining - 1
    if remaining > 0 then
      return
    end
    local healthy = {}
    for _, choice in ipairs(choices) do
      local valid, reason = current(choice.record)
      if valid then
        healthy[#healthy + 1] = choice
      else
        errors[#errors + 1] = reason
      end
    end
    choices = healthy
    if #choices == 0 then
      notify(#errors > 0 and table.concat(errors, "; ") or "当前范围没有语言服务器返回的 code action")
      return
    end
    vim.ui.select(choices, {
      prompt = "语言服务器实际返回的操作（修改先预览）",
      kind = "codeaction",
      format_item = function(choice)
        local why = action_reason(choice.action, choice.record)
        return ("%s [%s]%s"):format(choice.action.title, choice.record.client.name, why and (" — " .. why) or "")
      end,
    }, selected)
  end
  for _, client in ipairs(clients) do
    local record = capture(client, origin)
    ensure(record, action, function()
      local params = range_params(record, opts.range)
      local diagnostics = {}
      for _, pull in ipairs({ false, true }) do
        local ns = vim.lsp.diagnostic.get_namespace(client.id, pull)
        for _, diagnostic in ipairs(vim.diagnostic.get(origin.buf, { namespace = ns, lnum = origin.cursor[1] - 1 })) do
          if diagnostic.user_data and diagnostic.user_data.lsp then
            diagnostics[#diagnostics + 1] = diagnostic.user_data.lsp
          end
        end
      end
      params.context = { triggerKind = 1, diagnostics = diagnostics }
      request(action, record, "textDocument/codeAction", params, function(err, result)
        finish(record, err, result)
      end)
    end, function(reason)
      finish(record, { message = reason })
    end)
  end
  return action
end

function M.undo()
  local batch = last_batch
  if not batch then
    notify("当前进程没有可撤销的修改批次")
    return
  end
  local answer = vim.fn.confirm(
    ("撤销 %s 的整批修改？有更新内容时整批拒绝。"):format(batch.label),
    "撤销 (&y)\n取消 (&n)",
    2
  )
  if answer ~= 1 then
    return
  end
  if last_batch ~= batch then
    notify("确认期间出现新的修改批次，已取消撤销，请重新检查", vim.log.levels.WARN)
    return
  end
  edits.undo(batch, function(ok, reason)
    if ok then
      notify("已撤销本批次；原有未保存修改保留")
    else
      notify("未撤销：" .. tostring(reason), vim.log.levels.WARN)
      if batch.state == "undo-failed" then
        show_evidence(batch)
      end
    end
  end)
end

function M.last_batch()
  return last_batch
end
function M.recovery()
  if last_batch then
    show_evidence(last_batch)
  else
    notify("当前进程没有修改批次")
  end
end

function M.setup_commands()
  api.nvim_create_user_command("UERename", function(args)
    M.rename(args.args ~= "" and args.args or nil)
  end, { nargs = "?", desc = "Preview compiler/server-authored rename before applying" })
  api.nvim_create_user_command("UECodeActions", function(args)
    local range
    if args.range > 0 then
      local text = api.nvim_buf_get_lines(0, args.line2 - 1, args.line2, true)[1] or ""
      range = { start = { args.line1, 0 }, ["end"] = { args.line2, #text }, linewise = true }
    end
    M.code_actions({ query = args.args ~= "" and args.args or nil, range = range })
  end, { nargs = "?", range = true, desc = "Show actual server code actions; preview text edits" })
  api.nvim_create_user_command(
    "UERefactorUndo",
    M.undo,
    { desc = "Undo last batch only when all owned versions remain unchanged" }
  )
  api.nvim_create_user_command(
    "UERefactorRecovery",
    M.recovery,
    { desc = "Review retained application/recovery evidence" }
  )
end

return M
