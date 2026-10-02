-- ue.workflows.android.iterate — one command for the Android inner loop:
-- build SO → hot-deploy → start (under the debugger by default).
--
-- The steps stay separate owners (K46: install, SO replacement and launch are
-- distinct operations); this module only chains them, stops at the first
-- failure and leaves the outcome in the statusline for users who walked away.

local M = {}

---@param steps {build_so:fun(on_exit:fun(code:integer)), deploy_so:fun(on_exit:fun(code:integer)), launch:fun(), set_status:fun(value:string)}
---@param opts? {nodebug?:boolean, now?:fun():number, notify?:fun(msg:string, level?:integer), debug_launch?:fun()}
function M.run(steps, opts)
  opts = opts or {}
  local now = opts.now or function() return vim.uv.hrtime() / 1e9 end
  local started = now()
  local function elapsed() return ("%.0fs"):format(now() - started) end
  local notify = opts.notify or function(msg, level)
    vim.notify("[UEAndroidIterate] " .. msg, level or vim.log.levels.INFO)
  end
  local function fail(msg)
    steps.set_status("LOOP✗")
    notify(msg, vim.log.levels.ERROR)
  end
  local function start()
    -- The deploy leaves the app stopped (K46); start it under the debugger
    -- (wait-for-debugger launch, K39) unless `nodebug` was requested.
    steps.set_status("LOOP✓ " .. elapsed())
    if opts.nodebug then
      notify("deploy ok in " .. elapsed() .. " → launching app")
      return steps.launch()
    end
    notify("deploy ok in " .. elapsed() .. " → launching under the debugger")
    local debug_launch = opts.debug_launch or function() vim.cmd("UEDAPLaunch Android") end
    debug_launch()
  end
  steps.build_so(function(code)
    if code ~= 0 then return fail("stopped: SO build exited " .. code) end
    notify("SO build ok → deploying")
    steps.deploy_so(function(deploy_code)
      if deploy_code ~= 0 then return fail("stopped: deploy exited " .. deploy_code) end
      start()
    end)
  end)
end

function M.setup(steps)
  vim.api.nvim_create_user_command("UEAndroidIterate", function(cmd)
    M.run(steps, { nodebug = cmd.args == "nodebug" })
  end, {
    nargs = "?",
    complete = function() return { "nodebug" } end,
    desc = "Android loop: build SO, hot-deploy it, launch under the debugger (nodebug: plain launch)",
  })
end

return M
