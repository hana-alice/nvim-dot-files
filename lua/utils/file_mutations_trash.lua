-- Reuse Snacks' host trash argv, but run the explicit operation asynchronously.
-- No permanent-delete fallback and no copied task status.
local M = {}

local function command(path)
  local snacks = require("snacks")
  if not snacks.explorer.config.trash then
    return nil
  end
  for _, candidate in ipairs(require("snacks.explorer.actions").get_trash_cmds(path)) do
    if vim.fn.executable(candidate[1]) == 1 then
      return candidate
    end
  end
end

function M.available(path)
  return command(path) ~= nil
end

function M.run(path, expected, callback)
  local argv = command(path)
  if not argv then
    return callback(false, "trash-unavailable")
  end
  -- Only an owned, already-isolated object reaches the child. This identity
  -- check is not an OS lock against an external replacement of quarantine.
  if require("utils.file_mutations").snapshot(path) ~= expected then
    return callback(false, "isolated-object-changed")
  end
  local admission = require("utils.host_admission")
  local foreground = admission.foreground_begin("Explorer trash")
  local released = false
  local function done(ok, reason)
    if not released then
      released = true
      admission.foreground_done(foreground)
    end
    callback(ok, reason)
  end
  local ok, handle = pcall(vim.system, argv, { text = true, timeout = 10000 }, function(result)
    vim.schedule(function()
      done(result.code == 0, result.code == 0 and nil or (result.stderr or "trash-failed"))
    end)
  end)
  if not ok then
    return done(false, tostring(handle))
  end
  pcall(require("utils.task_registry").register, {
    name = "Explorer trash",
    group = "files",
    kind = "system",
    handle = handle,
  })
end

return M
