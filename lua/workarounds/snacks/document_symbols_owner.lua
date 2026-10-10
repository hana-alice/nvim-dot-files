-- WORKAROUND
-- name: snacks.document_symbols_owner
-- scope: snacks
-- issue: internal: Snacks 2.31.0 document symbols accept stale positions and its keyed requester cannot cancel via array removal
-- symptom: an outline can jump to old lines after an edit; closing it leaves its request running
-- introduced: 2026-10-04
-- removal_condition: native document-symbol ownership rejects source drift and cancels its actual pending IDs
-- owner: hana-alice
-- enabled: true
-- END WORKAROUND

-- Keep the native symbol conversion, hierarchy and filtering. Only the
-- document picker explicitly tagged by utils.document_symbols uses this
-- request lifetime; workspace symbols and every other caller stay native.
local M = {}
local ownership = require("utils.ue_goto.reading_owner")
local owners = setmetatable({}, { __mode = "k" })
local patched, originals, wrappers

local function request(source, lifetime, async, buf, method, params, callback)
  local owner = lifetime.owner
  local pending, stopped = 1, false
  local cancels, remove_wait = {}, nil
  local function stop()
    if stopped then
      return
    end
    stopped, pending = true, 0
    for cancel in pairs(cancels) do
      pcall(cancel)
    end
    cancels = {}
    if remove_wait then
      remove_wait()
    end
    async:resume()
  end
  lifetime.stop = stop
  remove_wait = ownership.add_cleanup(owner, stop)
  vim.schedule(function()
    if stopped or async:aborted() then
      return
    end
    if not ownership.current(owner, true) then
      if ownership.active() == owner then
        ownership.cancel()
      end
      pending = 0
      async:resume()
      return
    end
    for _, client in ipairs(source.get_clients(buf, method)) do
      if stopped or lifetime.aborted or not ownership.current(owner, true) then
        break
      end
      local arguments = params(client)
      local done, id, cancel = false, nil, nil
      pending = pending + 1
      local function finish(err, result)
        if done then
          return
        end
        done = true
        if cancel then
          cancels[cancel] = nil
        end
        pending = pending - 1
        if not stopped and not lifetime.aborted and not async:aborted() then
          if ownership.current(owner, true) then
            if not err and result then
              callback(client, vim.deepcopy(result), arguments)
            end
          elseif ownership.active() == owner then
            ownership.cancel()
          end
        end
        async:resume()
      end
      local ok, accepted, request_id = pcall(client.request, client, method, arguments, finish, buf)
      id = request_id
      if not ok or accepted == false then
        finish({ message = "documentSymbol request rejected" })
      end
      if not done then
        cancel = function()
          if done then
            return
          end
          done = true
          cancels[cancel] = nil
          if id and client.cancel_request then
            pcall(client.cancel_request, client, id)
          end
        end
        cancels[cancel] = true
        if stopped or lifetime.aborted then
          pcall(cancel)
        end
      end
    end
    pending = pending - 1
    async:resume()
  end)
  while pending > 0 and not async:aborted() do
    async:suspend()
  end
  remove_wait()
  lifetime.stop = nil
end

function M.apply()
  local ok, source = pcall(require, "snacks.picker.source.lsp")
  if not ok then
    return false
  end
  if patched == source then
    return true
  end
  if patched then
    M.disable()
  end
  local Async = require("snacks.picker.util.async")
  originals = { symbols = source.symbols, request = source.request }
  wrappers = {}
  wrappers.symbols = function(opts, ctx)
    local finder = originals.symbols(opts, ctx)
    local owner = type(opts.ue_document_owner) == "function" and opts.ue_document_owner() or nil
    if not owner or opts.workspace or type(finder) ~= "function" then
      return finder
    end
    return function(callback)
      local async = Async.running()
      local lifetime = { owner = owner }
      owners[async] = lifetime
      local function cancel()
        lifetime.aborted = true
        vim.schedule(function()
          if lifetime.stop then
            lifetime.stop()
          end
          owners[async] = nil
        end)
      end
      async:on("abort", cancel):on("error", cancel)
      finder(callback)
      owners[async] = nil
    end
  end
  wrappers.request = function(buf, method, params, callback)
    local async = Async.running()
    local lifetime = owners[async]
    if method ~= "textDocument/documentSymbol" or not lifetime then
      return originals.request(buf, method, params, callback)
    end
    return request(source, lifetime, async, buf, method, params, callback)
  end
  source.symbols, source.request = wrappers.symbols, wrappers.request
  patched = source
  return true
end

function M.disable()
  if not patched then
    return
  end
  for _, lifetime in pairs(owners) do
    if ownership.active() == lifetime.owner then
      ownership.cancel()
    end
  end
  for name, wrapper in pairs(wrappers) do
    if patched[name] == wrapper then
      patched[name] = originals[name]
    end
  end
  owners = setmetatable({}, { __mode = "k" })
  patched, originals, wrappers = nil, nil, nil
end

function M.status()
  return { applied = patched ~= nil }
end

return M
