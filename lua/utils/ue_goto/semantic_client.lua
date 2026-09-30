-- Composition root: editor actions, environment invalidation, and compiler transport.
local protocol = require("utils.ue_goto.semantic_protocol")
local environment = require("utils.ue_goto.semantic_environment")
local compiler_session = require("utils.ue_goto.semantic_session")
local action_helper = require("utils.ue_goto.semantic_client_actions")
local runtime_helper = require("utils.ue_goto.semantic_client_runtime")

local M = {}
local transport = {}
local last_environment
local REQUEST_TIMEOUT_MS = 32000
local transport_state = {
  stdout_tail = "", pending = {}, queued = {}, next_request_id = 0,
  ready = false, starting = false, stopping = false, restart_used = false,
}
local action_state = {
  next_action_token = 0, active_action_token = 0, window_contexts = {}, action_autocmds = {},
}
local runtime = runtime_helper.install(transport, {
  protocol = protocol, state = transport_state, uv = vim.uv or vim.loop,
  SIDECAR_NAME = "ue-clang-semanticd", REQUEST_TIMEOUT_MS = REQUEST_TIMEOUT_MS,
  IDLE_EVICT_MS = 30000,
})

local function compiler_options(options)
  return options and compiler_session.requested(options)
end

function M.request(op, fields, callback, options, snapshot)
  local is_current = snapshot and function() return M.snapshot_is_current(snapshot) end or nil
  return transport.request(op, fields, callback, compiler_options(options), is_current)
end

M.cancel_queued_actions = transport.cancel_queued_actions
M.set_trace = transport.set_trace
M.index_snapshot_is_current = environment.index_snapshot_is_current
local actions = action_helper.install(M, {
  state = action_state, hash_text = runtime.hash_text,
  emit_trace = runtime.emit_trace, unavailable = runtime.unavailable,
})

function M.discover_toolchain(bufnr, opts)
  local current, err = environment.read(bufnr, opts)
  if not current then return nil, err end
  local transition = environment.transition(last_environment, current)
  if transition ~= "reuse" then
    M.clear_contexts()
    if transport.status().running then
      if transition == "restart" then
        transport.restart(compiler_options(current))
      else
        transport.request("evict", { all = true }, function() end, compiler_options(current))
      end
    end
  end
  last_environment = current
  return current
end

function M.status()
  local status = transport.status()
  status.build_fingerprint = last_environment and last_environment.build_fingerprint
  return status
end

function M.stop()
  M.cancel_action()
  transport.stop()
end

function M.dispose()
  M.cancel_action()
  M.clear_contexts()
  transport.stop()
  last_environment = nil
end

function M._reset_for_test()
  M.cancel_action()
  actions.reset()
  runtime.reset()
  last_environment = nil
end

M._consume_stdout_for_test = transport._consume_stdout_for_test
M._inject_pending_for_test = transport._inject_pending_for_test
M._expire_pending_for_test = transport._expire_pending_for_test
M._set_process_for_test = transport._set_process_for_test
M._discover_controlled_phase_manifests_for_test = environment.controlled_phase_manifests
M.PROTOCOL_VERSION = protocol.VERSION
M.TERMINAL = actions.TERMINAL
M.IDLE_EVICT_MS = runtime.IDLE_EVICT_MS
M.REQUEST_TIMEOUT_MS = REQUEST_TIMEOUT_MS
return M
