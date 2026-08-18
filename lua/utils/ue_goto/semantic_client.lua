-- Async client for the local libclang semantic sidecar.
--
-- The editor owns only process I/O, request snapshots, provenance selection,
-- and UI side effects. Compilation-database reads, dependency scans, and all
-- libclang parse/reparse work happen in the headless sidecar.

local protocol = require("utils.ue_goto.semantic_protocol")
local action_helper = require("utils.ue_goto.semantic_client_actions")
local runtime_helper = require("utils.ue_goto.semantic_client_runtime")

local M = {}

local state = {
  job = nil,
  stdout_tail = "",
  pending = {},
  queued = {},
  next_request_id = 0,
  next_action_token = 0,
  active_action_token = 0,
  ready = false,
  starting = false,
  stopping = false,
  restart_used = false,
  start_options = nil,
  window_contexts = {},
  trace = nil,
  active_notice = nil,
  idle_timer = nil,
  stop_timer = nil,
  action_autocmds = {},
  last_build_fingerprint = nil,
  last_response = nil,
}

local runtime = runtime_helper.install(M, {
  protocol = protocol,
  state = state,
  uv = vim.uv or vim.loop,
  SIDECAR_NAME = "ue-clang-semanticd",
  REQUEST_TIMEOUT_MS = 30000,
  IDLE_EVICT_MS = 30000,
})

local actions = action_helper.install(M, {
  state = state,
  hash_text = runtime.hash_text,
  close_timer = runtime.close_timer,
  emit_trace = runtime.emit_trace,
  unavailable = runtime.unavailable,
  PROGRESS_DELAY_MS = 600,
})

function M._reset_for_test()
  runtime.reset()
  actions.reset()
end

M.PROTOCOL_VERSION = protocol.VERSION
M.TERMINAL = actions.TERMINAL
M.IDLE_EVICT_MS = runtime.IDLE_EVICT_MS
M.REQUEST_TIMEOUT_MS = runtime.REQUEST_TIMEOUT_MS

return M
