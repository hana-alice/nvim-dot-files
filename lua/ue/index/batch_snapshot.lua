-- Detached observation only; readiness authority stays with batch_runtime.
local M = {}

function M.activation(record, ready)
  if not record then return nil end
  local result = { failed = record.failed == true, ready = record.phase == "ready" and ready(record) == true }
  for _, field in ipairs({ "scope", "attempt", "stamp", "generation", "phase", "reason",
    "pending_helpers", "retry_after", "verified", "published_batch_count" }) do
    local value = record[field]
    if type(value) == "string" or type(value) == "number" or type(value) == "boolean" then result[field] = value end
  end
  result.batch_client_count = 0
  if result.ready then
    for _, client in pairs(record.clients or {}) do
      if client.config and client.config._ue_batch_attempt == record.attempt
          and (not client.is_stopped or not client:is_stopped()) then
        result.batch_client_count = result.batch_client_count + 1
      end
    end
  end
  result.client_batch_tu_count = result.batch_client_count > 0 and (record.published_batch_count or 0) or 0
  return result
end

return M
