-- ue/gtags.lua — shared GTAGS plan plus admitted asynchronous rebuild.
--
-- UEPrepareSync deliberately uses build_sync. Watcher-triggered shader rebuilds
-- MUST use rebuild_async: the watcher flush runs from a debounce timer, so a
-- vim.system():wait() there freezes the editor and violates P6.

local fs = require("ue.core.fs")
local proc = require("ue.core.proc")

local M = {}
local active = false
local active_control = nil
local active_handle = nil

local function plugin_root()
  local source = debug.getinfo(1, "S").source or ""
  if source:sub(1, 1) == "@" then source = source:sub(2) end
  return vim.fn.fnamemodify(source, ":h:h:h")
end

local function clean_db_dir(dir)
  pcall(vim.fn.delete, dir, "rf")
  fs.ensure_dir(dir)
end

local function db_ready(dir)
  if type(dir) ~= "string" or dir == "" then return false end
  for _, name in ipairs({ "GTAGS", "GRTAGS", "GPATH" }) do
    local stat = (vim.uv or vim.loop).fs_stat(fs.join(dir, name))
    if not stat or stat.type ~= "file" or (stat.size or 0) <= 0 then return false end
  end
  return true
end

--- Build a structured GTAGS command plan, or a skip/unavailable result.
function M.plan(spec)
  spec = spec or {}
  local gtags = (spec.first_executable or proc.first_executable)({ "gtags" })
  if not gtags then return nil, "gtags not found in PATH" end
  if not fs.is_file(spec.filelist) or vim.fn.getfsize(spec.filelist) <= 0 then
    return { skip = true, message = tostring(spec.label or "gtags") .. ": no files to index" }
  end

  local env
  local conf_path = fs.join(plugin_root(), "tools", "gtags", "gtags.conf")
  if fs.is_file(conf_path) then
    env = { GTAGSCONF = conf_path, GTAGSLABEL = "hlsl-cpp" }
  end
  return {
    command = {
      gtags, "-f", spec.filelist, "--skip-unreadable", "--skip-symlink", spec.db_dir,
    },
    cwd = spec.root,
    env = env,
  }
end

--- Explicit blocking entry for :UEPrepareSync only.
function M.build_sync(spec)
  local plan, err = M.plan(spec)
  if not plan then return false, err end
  clean_db_dir(spec.db_dir)
  if plan.skip then return true, plan.message end

  local run_lines = spec.run_lines
  if type(run_lines) ~= "function" then
    run_lines = function(command, opts)
      local result = vim.system(command, {
        cwd = opts.cwd,
        env = opts.env,
        text = true,
      }):wait()
      local text = (result.stdout or "") .. (result.stderr or "")
      local lines = vim.split(text, "\n", { plain = true, trimempty = true })
      return result.code, lines
    end
  end

  local code, lines = run_lines(plan.command, { cwd = plan.cwd, env = plan.env })
  if code ~= 0 then return false, table.concat(lines or {}, "\n") end
  if not db_ready(spec.db_dir) then
    local output = table.concat(lines or {}, "\n")
    return false, output ~= "" and output or ("GTAGS database not generated: " .. spec.db_dir)
  end
  return true
end

local function finish(ok, message, callback)
  active = false
  active_control = nil
  active_handle = nil
  if type(callback) == "function" then callback(ok, message) end
end

--- Queue/start one asynchronous GTAGS rebuild.
--- @return boolean accepted
--- @return string state_or_error
--- @return table|nil admission_control
function M.rebuild_async(spec, callback)
  spec = spec or {}
  if active then return false, "GTAGS rebuild is already queued or running" end
  active = true

  local admission = require("utils.host_admission")
  local started, _, start_err, control = admission.run_when_allowed({
    name = tostring(spec.label or "GTAGS rebuild"),
    start = function()
      local plan, plan_err = M.plan(spec)
      if not plan then
        finish(false, plan_err, callback)
        return nil, plan_err
      end
      clean_db_dir(spec.db_dir)
      if plan.skip then
        finish(true, plan.message, callback)
        return function() end
      end

      local system = spec.system or vim.system
      local ok, handle = pcall(system, plan.command, {
        cwd = plan.cwd,
        env = plan.env,
        text = true,
      }, function(result)
        vim.schedule(function()
          if result.code ~= 0 then
            local stderr = tostring(result.stderr or "")
            local detail = stderr ~= "" and stderr or tostring(result.stdout or "")
            finish(false, ("gtags exit=%d: %s"):format(result.code or -1, detail), callback)
            return
          end
          if not db_ready(spec.db_dir) then
            finish(false, "GTAGS process completed without a usable database", callback)
            return
          end
          finish(true, "GTAGS rebuild complete", callback)
        end)
      end)
      if not ok or not handle then
        finish(false, "failed to spawn GTAGS: " .. tostring(handle), callback)
        return nil, handle
      end
      active_handle = handle
      pcall(function()
        require("utils.task_registry").register({
          name = tostring(spec.label or "GTAGS rebuild"),
          group = "ue",
          kind = "system",
          handle = handle,
          started_at = os.time(),
        })
      end)
      return function()
        if active_handle and type(active_handle.kill) == "function" then
          pcall(active_handle.kill, active_handle, 15)
        end
      end
    end,
    on_defer = function(reason, reading, deferrals)
      pcall(function()
        require("utils.log").debug_ctx("host.admission", "deferred GTAGS rebuild", {
          reason = reason,
          deferrals = deferrals,
          host_pct = reading and reading.host_pct or nil,
        })
      end)
    end,
    on_error = function(err)
      finish(false, "GTAGS admission failed: " .. tostring(err), callback)
    end,
    on_cancel = function()
      finish(false, "GTAGS rebuild cancelled before start", callback)
    end,
  })
  if active then active_control = control end
  if started and start_err then return false, tostring(start_err), control end
  return true, started and "running" or "queued", control
end

function M.is_running()
  return active
end

function M._reset_for_test()
  if active_control then active_control:cancel() end
  active = false
  active_control = nil
  active_handle = nil
end

M._db_ready_for_test = db_ready

return M
