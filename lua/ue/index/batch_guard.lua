-- A frozen batch acquires authority only after watches precede byte validation.
-- The caller owns receipt parsing, asynchronous verification, publication and
-- fallback/restart. This module never reads CDBs or scans dependency trees.
local M = {}
local fs = require("ue.core.fs")

local protected = {
  ["textDocument/references"] = true,
  ["textDocument/rename"] = true,
  ["textDocument/prepareRename"] = true,
}

local function minimal_roots(roots, maximum, lookup_maximum)
  if type(roots) ~= "table" or not vim.islist(roots) or #roots == 0 then
    return nil, "missing-watch-roots"
  end
  -- Bound the input too, before sorting or deduplication on the UI thread.
  if #roots > maximum + lookup_maximum then return nil, "watch-root-limit" end
  local candidates, recursive_count, direct_count = {}, 0, 0
  for _, root in ipairs(roots) do
    local path, recursive = root, true
    if type(root) == "table" then path, recursive = root.path, root.recursive end
    if type(path) ~= "string" or not (path:match("^%a:[/\\]$") or fs.is_absolute_path(path))
        or type(recursive) ~= "boolean" then
      return nil, "invalid-watch-root"
    end
    if recursive then recursive_count = recursive_count + 1 else direct_count = direct_count + 1 end
    if recursive_count > maximum then return nil, "watch-root-limit" end
    if direct_count > lookup_maximum then return nil, "lookup-watch-root-limit" end
    candidates[#candidates + 1] = { path = path:match("^%a:[/\\]$") and path:sub(1, 2) .. "/" or vim.fs.normalize(path), recursive = recursive }
  end
  table.sort(candidates, function(a, b)
    if a.path == b.path then return a.recursive and not b.recursive end
    return #a.path == #b.path and a.path < b.path or #a.path < #b.path
  end)
  local result = {}
  for _, root in ipairs(candidates) do
    local covered = false
    for _, parent in ipairs(result) do
      if fs.path_has_prefix(root.path, parent.path)
          and (parent.recursive or fs.path_has_prefix(parent.path, root.path)) then
        covered = true; break
      end
    end
    if not covered then result[#result + 1] = root end
  end
  return result
end

local function release(handle)
  if not handle then return end
  if type(handle.stop) == "function" then pcall(handle.stop, handle) end
  if type(handle.close) == "function" then pcall(handle.close, handle) end
end

--- Start with the original semantic CDB still published. The caller may publish
--- the batch only in on_ready, and must restore the original view on_invalidated.
--- String roots are recursive; {path=...,recursive=false} roots watch only
--- driver lookup entries. The factory must attest recursive or direct capability
--- respectively, based on its actual host probe. Direct ancestors never cover
--- descendant watches unless the ancestor is recursive.
--- An asynchronous factory returns pending=true and calls options.on_ready(ok).
--- Verification waits for every installed watch to acknowledge native readiness.
--- close_watches optionally owns shared backend resources, including partial setup.
--- watch_backend(roots) may create a shared factory and close callback after root
--- minimization; it receives exactly the subscriptions that will be registered.
--- verify_async(receipts, callback) returns an optional cancellation function;
--- callback receives {ok=boolean, reason=string?, evidence=any?}.
function M.start(ctx, client, opts)
  opts = opts or {}
  local schedule = opts.schedule or vim.schedule
  local state, epoch, reason = "validating", 1, "verification-pending"
  local watches, pending = {}, {}
  local cancel_verification
  local close_watches = opts.close_watches
  local invalidation_delivered = false
  local guard = {}

  local function stale_error()
    return { code = -32801, message = "Frozen batch unavailable: " .. tostring(reason) }
  end

  local function finish(record, err, result, response_ctx, config)
    if record.done then return end
    record.done = true
    pending[record] = nil
    if state ~= "ready" or record.epoch ~= epoch then err, result = stale_error(), nil end
    if record.handler then record.handler(err, result, response_ctx, config) end
  end

  local function cleanup()
    for _, handle in ipairs(watches) do release(handle) end
    watches = {}
    if close_watches then
      local close = close_watches
      close_watches = nil
      pcall(close)
    end
    if cancel_verification then
      local cancel = cancel_verification
      cancel_verification = nil
      pcall(cancel)
    end
    local active = {}
    for record in pairs(pending) do active[#active + 1] = record end
    for _, record in ipairs(active) do
      if record.id and type(record.client.cancel_request) == "function" then
        pcall(record.client.cancel_request, record.client, record.id)
      end
      pcall(finish, record, stale_error(), nil, { client_id = record.client.id, method = record.method })
    end
  end

  function guard:status()
    return { state = state, epoch = epoch, reason = reason, watch_count = #watches }
  end

  function guard:invalidate(why)
    if state == "invalidated" or state == "stopped" then return end
    -- An fs_event callback can run in fast-event context. Revoke immediately;
    -- filesystem handle disposal, callbacks and fallback run on the main loop.
    state, epoch, reason = "invalidated", epoch + 1, why or "input-changed"
    schedule(function()
      cleanup()
      if state == "invalidated" and not invalidation_delivered then
        invalidation_delivered = true
        if opts.on_invalidated then opts.on_invalidated(reason, guard, ctx) end
      end
    end)
  end

  function guard:stop()
    if state == "stopped" then return end
    state, epoch, reason = "stopped", epoch + 1, "guard-stopped"
    schedule(cleanup)
    -- Keep the old client's methods gated until its owner retires it. Restoring
    -- unguarded methods here could expose stale batch results during restart.
  end

  function guard:attach(target)
    if type(target) ~= "table" or type(target.request) ~= "function" then
      self:invalidate("client-request-unavailable")
      return false
    end
    local previous = target._ue_batch_guard
    if previous and previous.guard == self then return true end
    local request = previous and previous.request or target.request
    local request_sync = previous and previous.request_sync or target.request_sync
    if previous then previous.guard:stop() end
    target._ue_batch_guard = { guard = self, request = request, request_sync = request_sync }
    target.request = function(owner, method, params, handler, bufnr)
      if not protected[method] then return request(owner, method, params, handler, bufnr) end
      if state ~= "ready" then return false, nil end
      handler = handler or (owner.handlers and owner.handlers[method]) or vim.lsp.handlers[method]
      local record = { epoch = epoch, handler = handler, method = method, client = owner }
      pending[record] = true
      local ok, accepted, request_id = pcall(request, owner, method, params, function(err, result, response_ctx, config)
        finish(record, err, result, response_ctx, config)
      end, bufnr)
      if not ok or accepted == false then
        pending[record] = nil
        record.done = true
        if not ok then error(accepted) end
        return accepted, request_id
      end
      record.id = request_id
      return accepted, request_id
    end
    if type(request_sync) == "function" then
      target.request_sync = function(owner, method, params, timeout_ms, bufnr)
        if not protected[method] then return request_sync(owner, method, params, timeout_ms, bufnr) end
        if state ~= "ready" then return nil, "frozen-batch-unavailable" end
        local sent_epoch = epoch
        local result, err = request_sync(owner, method, params, timeout_ms, bufnr)
        if state ~= "ready" or sent_epoch ~= epoch then return nil, "frozen-batch-invalidated" end
        return result, err
      end
    end
    return true
  end

  if client then
    guard:attach(client)
    if state ~= "validating" then return guard end
  end
  if type(opts.verify_async) ~= "function"
      or (type(opts.watch_factory) ~= "function" and type(opts.watch_backend) ~= "function")
      or type(opts.receipts) ~= "table" or next(opts.receipts) == nil then
    guard:invalidate("missing-verification-capability")
    return guard
  end
  local maximum = math.max(1, math.min(32, tonumber(opts.max_roots) or 32))
  local lookup_maximum = math.max(1, math.min(256, tonumber(opts.max_lookup_roots) or 256))
  local roots, roots_error = minimal_roots(opts.roots, maximum, lookup_maximum)
  if not roots then guard:invalidate(roots_error); return guard end
  local watch_factory = opts.watch_factory
  if opts.watch_backend then
    local ok, factory, close = pcall(opts.watch_backend, roots)
    if type(close) == "function" then close_watches = close end
    if not ok or type(factory) ~= "function" then guard:invalidate("input-watch-unavailable"); return guard end
    watch_factory = factory
  end
  local verification_epoch = epoch
  local function verify()
    local ok, cancel = pcall(opts.verify_async, opts.receipts, function(result)
      schedule(function()
        if state ~= "validating" or epoch ~= verification_epoch then return end
        cancel_verification = nil
        if type(result) ~= "table" or result.ok ~= true then
          guard:invalidate(type(result) == "table" and result.reason or "verification-failed")
          return
        end
        state, reason = "ready", "verified"
        if opts.on_ready then
          local ready_ok = pcall(opts.on_ready, guard, result.evidence, ctx)
          if not ready_ok then guard:invalidate("activation-failed") end
        end
      end)
    end)
    if not ok then guard:invalidate("verification-start-failed")
    elseif type(cancel) == "function" then cancel_verification = cancel end
  end
  local next_root, waiting = 1, 0
  local installed, verifying = false, false
  local function maybe_verify()
    if installed and waiting == 0 and not verifying and state == "validating" and epoch == verification_epoch then
      verifying = true
      verify()
    end
  end
  local function install()
    if state ~= "validating" or epoch ~= verification_epoch then return end
    -- The measured 197 direct watches took 106 ms to install synchronously.
    -- Yield between small batches while authority remains unavailable.
    for _ = 1, 16 do
      local root = roots[next_root]
      if not root then installed = true; maybe_verify(); return end
      next_root = next_root + 1
      -- Register the token before the factory: an in-process backend can
      -- acknowledge readiness synchronously, before returning its handle.
      waiting = waiting + 1
      local settled = false
      local function ready(ok)
        if settled or state ~= "validating" or epoch ~= verification_epoch then return end
        settled = true
        waiting = waiting - 1
        if ok ~= true then guard:invalidate("watch-ready-failed"); return end
        if installed then schedule(maybe_verify) end
      end
      local ok, handle, capability = pcall(watch_factory, root.path, function(err)
        guard:invalidate(err and "watch-error" or "input-changed")
      end, { recursive = root.recursive, on_ready = ready })
      local valid_handle = (type(handle) == "table" or type(handle) == "userdata")
        and type(handle.close) == "function"
      if state ~= "validating" then if valid_handle then release(handle) end; return end
      if ok and valid_handle then watches[#watches + 1] = handle end
      local supported = type(capability) == "table"
        and (root.recursive and capability.recursive == true or not root.recursive and capability.direct == true)
      if not ok or not valid_handle or not supported then
        guard:invalidate(root.recursive and "recursive-watch-unavailable" or "direct-watch-unavailable")
        return
      end
      if capability.pending ~= true then ready(true) end
    end
    if next_root > #roots then installed = true; maybe_verify() else schedule(install) end
  end
  install()
  return guard
end

return M
