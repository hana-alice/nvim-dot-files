-- Small durable observations; this file never grants proof or activation authority.
local M = {}

function M.path(scope)
  if type(scope) ~= "string" or not require("ue.core.fs").is_absolute_path(scope) then return nil end
  return vim.fs.dirname(vim.fs.dirname(scope)) .. "/background-control/queue-state.json"
end

function M.read(path)
  local stat = path and vim.uv.fs_stat(path)
  if not stat or stat.size > 65536 then return nil end
  local file = io.open(path, "rb")
  if not file then return nil end
  local raw = file:read("*a"); file:close()
  local ok, value = pcall(vim.json.decode, raw)
  return ok and type(value) == "table" and value.schema == 1 and value or nil
end

function M.alive(pid)
  if not tonumber(pid) then return nil end
  local ok, result, err = pcall(vim.uv.kill, tonumber(pid), 0)
  if ok and result ~= nil and result ~= false then return true end
  if ok and tostring(err):find("ESRCH", 1, true) then return false end
  return nil -- Permission/unavailable is not proof of exit.
end

function M.snapshot(record, opts)
  opts = opts or {}
  local pending = 0
  for _, count in pairs(record.pending_accepted or {}) do pending = pending + count end
  return { schema = 1, scope = record.scope, phase = record.phase, reason = record.reason,
    error = record.error, persistence_error = record.persistence_error,
    deferred_reason = record.deferred_reason, owner_pid = record.owner_pid,
    owner_alive = (opts.alive or M.alive)(record.owner_pid), owner_check = "pid-only",
    queue_active = not record.stopped and not record.finished_at,
    started_at = record.started_at, finished_at = record.finished_at,
    last_proof = vim.deepcopy(record.last_proof), last_collect = vim.deepcopy(record.last_collect),
    last_collect_success = vim.deepcopy(record.last_collect_success),
    pending_accepted_count = pending, planned_candidates = record.group_count or 0,
    proof_accepted = record.accepted or 0, proof_rejected = record.rejected or 0,
    proof_uncached = record.uncached or 0, cached_accepted = record.cached_accepted or 0,
    cached_rejected = record.cached_rejected or 0, cached_uncached = record.cached_uncached or 0,
    collect_accepted = record.collect_accepted or 0, selector_reuse = record.selector_reuse,
    input_sha256 = record.input_sha256 }
end

function M.write(path, value)
  if not path then return true end
  local encoded = vim.json.encode(value)
  local previous = M.read(path)
  if previous and vim.deep_equal(previous, value) then return true end
  local temporary = path .. "." .. vim.fn.getpid() .. ".tmp"
  local file, err = io.open(temporary, "wb")
  if not file then return false, err end
  local wrote, closed = file:write(encoded), file:close()
  if not wrote or not closed then return false, "queue-summary-write-failed" end
  return vim.uv.fs_rename(temporary, path)
end

function M.summary(scope)
  local value = M.read(M.path(scope))
  if not value or value.scope ~= scope then return nil end
  value.owner_alive = M.alive(value.owner_pid)
  if value.queue_active and value.owner_alive == false then
    value.phase, value.reason, value.queue_active = "orphaned", "proof-owner-exited", false
  end
  return value
end

function M.append(ctx, lines)
  local path = ctx.paths and ctx.paths.semantic_cdb
  if not path then return end
  local summary = require("ue.index.batch_background").summary(vim.fs.dirname(path) .. "/full/compile_commands.json.semantic.json")
  if not summary then return end
  local proof, collect = summary.last_proof or {}, summary.last_collect or {}
  local alive = summary.owner_alive == true and "alive" or summary.owner_alive == false and "exited" or "unknown"
  lines[#lines + 1] = ("  batches: %s owner=%s (%s; pid-only) pending accepted=%d"):format(
    summary.phase or "unknown", tostring(summary.owner_pid or "?"), alive, summary.pending_accepted_count or 0)
  lines[#lines + 1] = ("    last proof=%s (%s); last collect=%s (%s)"):format(
    tostring(proof.completed_at or "-"), proof.outcome or "-", tostring(collect.finished_at or collect.started_at or "-"), collect.outcome or "-")
  if summary.error or summary.persistence_error then
    lines[#lines + 1] = "    reason: " .. tostring(summary.error or summary.persistence_error)
  end
end

return M
