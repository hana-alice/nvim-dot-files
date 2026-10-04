-- File-operation LSP responses are asynchronous and never directly apply edits.
local M = {}
local uv = vim.uv or vim.loop

local function clients(method)
  return vim.lsp.get_clients({ method = method })
end

local function changes(plan, only)
  local files = {}
  for index, source in ipairs(plan.sources) do
    if not only or only == index then
      files[#files + 1] =
        { oldUri = vim.uri_from_fname(source.path), newUri = vim.uri_from_fname(plan.targets[index].path) }
    end
  end
  return { files = files }
end

local function has_edits(result)
  if result == nil then
    return false
  end
  if type(result) ~= "table" then
    return true
  end
  if result.changes ~= nil and type(result.changes) ~= "table" then
    return true
  end
  if result.documentChanges ~= nil and type(result.documentChanges) ~= "table" then
    return true
  end
  for _, edits in pairs(result.changes or {}) do
    if type(edits) ~= "table" then
      return true
    end
    if #edits > 0 then
      return true
    end
  end
  return #(result.documentChanges or {}) > 0
end

function M.prepare(plan, callback)
  local pending, requests, done = 0, {}, false
  local timer = uv.new_timer()
  local function cancel(request)
    if request.completed or request.canceled then
      return
    end
    request.cancel_requested = true
    if request.id then
      request.canceled = true
      pcall(request.client.cancel_request, request.client, request.id)
    end
  end
  local function clear()
    if timer and not timer:is_closing() then
      timer:stop()
      timer:close()
    end
    for _, request in ipairs(requests) do
      cancel(request)
    end
    requests = {}
    plan.cancel_requests = nil
  end
  local function finish(ok, reason)
    if done then
      return
    end
    done = true
    clear()
    callback(ok, reason)
  end
  plan.cancel_requests = function()
    finish(false, "canceled")
  end
  local providers = clients("workspace/willRenameFiles")
  if #providers > 8 then
    return finish(false, "rename-provider-limit")
  end
  plan.rename_clients = {}
  for _, client in ipairs(clients("workspace/didRenameFiles")) do
    plan.rename_clients[#plan.rename_clients + 1] = client
  end
  local function same(current, expected)
    if #current ~= #expected then
      return false
    end
    for _, provider in ipairs(current) do
      if not vim.tbl_contains(expected, provider) then
        return false
      end
    end
    return true
  end
  plan.providers_current = function()
    return same(clients("workspace/willRenameFiles"), providers)
      and same(clients("workspace/didRenameFiles"), plan.rename_clients)
  end
  if #providers == 0 then
    return finish(true)
  end
  if not timer then
    return finish(false, "rename-timer-unavailable")
  end
  pending = #providers
  timer:start(
    1500,
    0,
    vim.schedule_wrap(function()
      finish(false, "rename-request-timeout")
    end)
  )
  local params = changes(plan)
  for _, client in ipairs(providers) do
    if done then
      return
    end
    -- Native in-process servers may reply or cancel before request returns ID.
    local request = { client = client, completed = false, canceled = false }
    requests[#requests + 1] = request
    local called, accepted, id = pcall(
      client.request,
      client,
      "workspace/willRenameFiles",
      params,
      function(err, result)
        if request.completed then
          return
        end
        request.completed = true
        if done then
          return
        end
        if err then
          return finish(false, "rename-request-error")
        end
        if has_edits(result) then
          return finish(false, "rename-edits-require-preview")
        end
        pending = pending - 1
        if pending == 0 then
          finish(true)
        end
      end,
      0
    )
    request.id = called and accepted and id or nil
    if done or request.cancel_requested then
      cancel(request)
      return
    end
    if not called or not accepted or not id then
      request.completed = true
      return finish(false, "rename-request-unavailable")
    end
  end
end

function M.notify(plan, index)
  for _, client in ipairs(plan.rename_clients or {}) do
    if vim.lsp.get_client_by_id(client.id) == client then
      pcall(client.notify, client, "workspace/didRenameFiles", changes(plan, index))
    end
  end
end

return M
