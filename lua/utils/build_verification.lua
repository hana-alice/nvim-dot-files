-- Bind opt-in build executions to evidence; process lifetime stays with its owner.
local M = {}

function M.context(ctx, target, operation)
  if type(ctx) ~= "table" or type(target) ~= "table" then
    return nil
  end
  return {
    project_root = ctx.project_root,
    engine_root = ctx.engine_root,
    uproject = ctx.uproject,
    target = target.target,
    platform = target.platform,
    configuration = target.configuration,
    operation = operation,
  }
end

function M.begin(context, buf, jobid, label)
  if not context then
    return nil
  end
  local identity = {}
  for _, key in ipairs({ "project_root", "engine_root", "uproject", "target", "platform", "configuration", "operation" }) do
    identity[key] = context[key]
  end
  return require("utils.verification_runs").begin(vim.tbl_extend("force", identity, {
    buf = buf,
    name = vim.api.nvim_buf_get_name(buf),
    jobid = jobid,
    label = label,
    started_at = os.time(),
    dirty_count_start = tonumber(vim.g.ue_unsaved_count) or 0,
  }))
end

function M.finish(id, opts)
  local receipt
  if opts.current and opts.code ~= 0 and opts.title then
    local _, published = require("ue.build_diagnostics").publish(opts.title, opts.entries, {
      context = id and { kind = "ue_verification", verification_id = id } or nil,
    })
    receipt = published
  end
  if id then
    require("utils.verification_runs").complete(id, {
      code = opts.code,
      current = opts.current,
      qf_id = receipt and receipt.qf_id,
      qf_tick = receipt and receipt.qf_tick,
      items = receipt and receipt.items or opts.entries,
    })
  end
end

return M
