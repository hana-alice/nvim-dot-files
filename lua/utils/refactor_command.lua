-- Client-specific command execution and workspace/applyEdit capture lifecycle.
-- The caller owns the UI action/context; this owner never applies returned edits.
local M = {}
local uv = vim.uv or vim.loop
local edits = require("utils.workspace_edit")

local function command_of(item)
  if type(item.command) == "string" then
    return item
  end
  if type(item.command) == "table" then
    return item.command
  end
end

function M.capturable(item, record)
  local command = command_of(item)
  local argument = command and command.arguments and command.arguments[1]
  return record.client.name == "clangd"
    and command
    and command.command == "clangd.applyTweak"
    and not item.edit
    and type(argument) == "table"
    and edits.same_document(argument.file, record.origin.name)
    and type(argument.tweakID) == "string"
end

-- clangd.applyTweak asks the client to apply its actual WorkspaceEdit. Capture
-- one request from an exclusive owned command, reject server-side application,
-- then preview that exact edit. No process-wide handler is changed.
function M.capture(action, record, item, context)
  local alive, current, notify = context.alive, context.current, context.notify
  local present_edit, error_message = context.present_edit, context.error_message
  local client = record.client
  if client._ue_refactor_command then
    notify("该服务器已有待处理的重构命令", vim.log.levels.WARN)
    return
  end
  for _, pending in pairs(client.requests or {}) do
    if pending.method == "workspace/executeCommand" then
      notify("服务器已有其他 executeCommand，无法关联修改预览", vim.log.levels.WARN)
      return
    end
  end
  local valid, why = current(record)
  if not valid or not alive(action) then
    notify(why or "request-cancelled", vim.log.levels.WARN)
    return
  end
  local owner, previous_request, previous_handlers = {}, client.request, client.handlers
  local handlers = vim.tbl_extend("force", previous_handlers or {}, {})
  local marker = ("UERefactor preview only %d:%d"):format(vim.fn.getpid(), action.id)
  local captured, count, permit, finished, abandoned, timer, drain_timer, request_id =
    nil, 0, false, false, false, nil, nil, nil
  client._ue_refactor_command = owner
  local handler = function(_, params, ctx)
    count = count + 1
    local stable = current(record)
    if
      not finished
      and not abandoned
      and alive(action)
      and stable
      and ctx
      and ctx.client_id == client.id
      and type(params) == "table"
      and type(params.edit) == "table"
      and count == 1
    then
      local touches_source = false
      for uri in pairs(params.edit.changes or {}) do
        if edits.same_document(uri, record.origin.name) then
          touches_source = true
        end
      end
      for _, doc in ipairs(params.edit.documentChanges or {}) do
        if doc.textDocument and edits.same_document(doc.textDocument.uri, record.origin.name) then
          touches_source = true
        end
      end
      if touches_source then
        captured = vim.deepcopy(params.edit)
      end
    else
      captured = nil
    end
    return { applied = false, failureReason = marker }
  end
  handlers["workspace/applyEdit"] = handler
  local routed_request = function(self, method, params, callback, buf)
    if method == "workspace/executeCommand" and not permit then
      vim.schedule(function()
        notify("修改预览期间暂不接受同一服务器的另一个 executeCommand", vim.log.levels.WARN)
      end)
      return false, nil
    end
    return previous_request(self, method, params, callback, buf)
  end
  client.handlers, client.request = handlers, routed_request
  local function cleanup()
    if timer then
      pcall(timer.stop, timer)
      pcall(timer.close, timer)
      timer = nil
    end
    if drain_timer then
      pcall(drain_timer.stop, drain_timer)
      pcall(drain_timer.close, drain_timer)
      drain_timer = nil
    end
    if client._ue_refactor_command == owner then
      client._ue_refactor_command = nil
    end
    if client.request == routed_request then
      client.request = previous_request
    end
    if client.handlers == handlers then
      -- Preserve unrelated per-client handler edits made during the request.
      local restored = vim.tbl_extend("force", handlers, {})
      restored["workspace/applyEdit"] = previous_handlers and previous_handlers["workspace/applyEdit"] or nil
      client.handlers = restored
    end
  end
  local function abandon()
    if finished then
      cleanup()
      return
    end
    abandoned, captured = true, nil
    if timer then
      pcall(timer.stop, timer)
      pcall(timer.close, timer)
      timer = nil
    end
    if request_id then
      pcall(client.cancel_request, client, request_id)
    end
    -- LSP cancellation is advisory. The command can send applyEdit later; keep
    -- rejecting it until its actual reply drains, or the client has stopped.
    -- This bounded per-owner poll does no I/O/spawn and emits no ticker toast.
    if not drain_timer then
      drain_timer = uv.new_timer()
      if drain_timer then
        drain_timer:start(
          250,
          250,
          vim.schedule_wrap(function()
            if vim.lsp.get_client_by_id(client.id) ~= client or client:is_stopped() then
              finished = true
              cleanup()
            end
          end)
        )
      else
        notify(
          "等待服务器收尾；客户端停止监测暂不可用，后续修改仍会拒绝",
          vim.log.levels.WARN
        )
      end
    end
  end
  action.cleanups[#action.cleanups + 1] = abandon
  timer = vim.defer_fn(function()
    if finished then
      return
    end
    abandon()
    if alive(action) then
      notify(
        "clangd 命令超时；未应用。等待服务器收尾期间继续拒绝后续修改。",
        vim.log.levels.WARN
      )
    end
  end, 15000)
  local command = command_of(item)
  permit = true
  local ok, accepted, id = pcall(
    client.request,
    client,
    "workspace/executeCommand",
    { command = command.command, arguments = command.arguments },
    function(err)
      if finished then
        return
      end
      finished = true
      cleanup()
      if abandoned or not alive(action) then
        return
      end
      local stable, stale = current(record)
      if not stable then
        notify(stale, vim.log.levels.WARN)
        return
      end
      -- clangd correctly reports -32001 when our preview handler declines
      -- application. Only this operation's exact marker is an expected refusal.
      local expected_refusal = err
        and err.code == -32001
        and type(err.message) == "string"
        and err.message:find(marker, 1, true)
      if err and not expected_refusal then
        notify("clangd: " .. error_message(err), vim.log.levels.WARN)
      elseif count ~= 1 or not captured then
        notify("命令未返回唯一且可关联的文本修改；未应用", vim.log.levels.WARN)
      else
        present_edit(action, record, captured, item.title)
      end
    end,
    record.origin.buf
  )
  permit = false
  request_id = id
  if abandoned and id then
    pcall(client.cancel_request, client, id)
  end
  if not ok or accepted == false then
    finished = true
    cleanup()
    notify("executeCommand: " .. (ok and "request-rejected" or tostring(accepted)), vim.log.levels.WARN)
  elseif id then
    action.requests[#action.requests + 1] = { client = client, id = id }
  end
end

function M.native(action, record, item, context)
  local alive, current, notify = context.alive, context.current, context.notify
  local command = command_of(item)
  if not command or item.edit then
    notify("包含额外 WorkspaceEdit 的复合命令暂未支持安全预览", vim.log.levels.WARN)
    return
  end
  vim.ui.select(
    { "取消", "原生执行（无预览、无整批撤销）" },
    { prompt = item.title .. " — 命令无法预览" },
    function(choice)
      if choice ~= "原生执行（无预览、无整批撤销）" or not alive(action) then
        return
      end
      local stable, why = current(record)
      if not stable then
        notify(why, vim.log.levels.WARN)
        return
      end
      local answer = vim.fn.confirm(
        "服务器命令将通过原生路径执行，不提供修改预览或整批撤销。继续？",
        "执行 (&y)\n取消 (&n)",
        2
      )
      if answer ~= 1 or not alive(action) then
        return
      end
      stable, why = current(record)
      if not stable then
        notify(why, vim.log.levels.WARN)
        return
      end
      record.client:exec_cmd(command, { bufnr = record.origin.buf, client_id = record.id })
    end
  )
end

return M
