-- WORKAROUND
-- name: codediff.event_refresh
-- scope: codediff
-- issue: internal: v4.0.6 polls full Git status every 500ms without its optional watcher
-- symptom: Large worktrees are continuously rescanned while idle, including hidden history tabs
-- introduced: 2026-09-29
-- removal_condition: upstream provides event-only refresh for every session kind
-- owner: hana-alice
-- enabled: true
-- END WORKAROUND

local M = {}
local refresh, attach

local function event_only(controller)
  controller.watch_generation = (controller.watch_generation or 0) + 1
  if controller.unsubscribe then controller.unsubscribe(); controller.unsubscribe = nil end
  controller.native, controller.polling = false, false
  controller.poll:stop()
end

function M.apply()
  if refresh or not package.loaded.codediff then return end
  refresh = require("codediff.ui.refresh")
  attach = refresh.attach
  refresh.attach = function(...)
    local controller = attach(...)
    if controller and not controller.review_event_only then
      controller.review_event_only = true
      controller.watch = event_only
      event_only(controller)
    end
    return controller
  end
end

function M.disable()
  if refresh then refresh.attach = attach end
  refresh, attach = nil, nil
end

function M.status()
  return { applied = refresh ~= nil }
end

return M
