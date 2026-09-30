local M = {}

function M.capture(opts, resolve_context, target_plan)
  opts = opts or {}
  local ctx, err = resolve_context()
  if not ctx then return nil, err end
  local command, plan_err, plan, driver, target_ctx = target_plan("build", ctx, opts.platform, opts)
  if not command then return nil, plan_err end
  if opts.configuration and opts.configuration ~= "" then
    target_ctx.configuration = opts.configuration
    plan = driver.build_plan(target_ctx, opts.host_driver or require("utils.platform").driver())
    command, plan_err = require("ue.target_tasks").command(plan)
    if not command then return nil, plan_err end
  end
  local export_plan = require("ue.targets._common").with_appended_args(plan, {
    "-WriteOutdatedActions=__BUILDDISPATCH_ACTIONS__",
  })
  local environment = vim.empty_dict()
  for _, key in ipairs({ "NDKROOT", "ANDROID_HOME", "ANDROID_SDK_ROOT", "JAVA_HOME" }) do
    if vim.env[key] and vim.env[key] ~= "" then environment[key] = vim.env[key] end
  end
  return {
    engine_root = ctx.engine_root, project_root = ctx.project_root, uproject = target_ctx.uproject,
    target = target_ctx.target, platform = target_ctx.platform, configuration = target_ctx.configuration,
    build_command = vim.deepcopy(command), build_cwd = plan.cwd or ctx.engine_root,
    export_command = require("ue.target_tasks").command(export_plan), environment = environment,
    p4 = { workspace = ctx.project_root, client = vim.env.P4CLIENT, config = vim.env.P4CONFIG },
  }
end

return M
