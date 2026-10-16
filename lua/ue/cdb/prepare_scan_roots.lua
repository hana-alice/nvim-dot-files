-- Prepare-only scan-root discovery worker. Reuse the original policy, including
-- whitelist precedence, nested anchors, exclusions and discovery/default union.
local M = {}
local owned = {}
local leave_registered = false

function M.collect(ctx)
  local started = vim.uv.hrtime()
  local ok, dirs = pcall(require("ue")._project_index_dirs_for_test, ctx)
  return { ok = ok, dirs = ok and dirs or nil, reason = not ok and tostring(dirs) or nil,
    wall_ms = (vim.uv.hrtime() - started) / 1e6 }
end

function M.start(ctx, done)
  local cancelled, finished, process, request_path = false, false
  local function cleanup()
    if request_path then os.remove(request_path); request_path = nil end
    if process then owned[process] = nil end
  end
  local function finish(dirs, err, stats)
    if cancelled or finished then return end
    finished = true
    cleanup()
    done(dirs, err, stats)
  end
  local function cancel()
    if cancelled or finished then return end
    cancelled = true
    if process then pcall(process.kill, process, 15) end
    cleanup()
  end
  require("utils.host_admission").run_when_allowed({
    name = "UE prepare scan roots",
    start = function()
      if cancelled then return end
      request_path = vim.fn.tempname() .. "-prepare-scan-roots.json"
      local file, err = io.open(request_path, "wb")
      if not file then finish(nil, err); return end
      local wrote = file:write(vim.json.encode({ project_root = ctx.project_root }))
      local closed = file:close()
      if not wrote or not closed then finish(nil, "scan-root request write failed"); return end
      local script = vim.fn.stdpath("config") .. "/lua/ue/cdb/prepare_scan_roots.lua"
      local ok, handle = pcall(vim.system, { vim.v.progpath, "--headless", "-u", "NONE", "-i", "NONE",
        "-l", script, request_path }, { text = true, timeout = 60000 }, function(result)
        vim.schedule(function()
          if cancelled or finished then return end
          local decoded, value = pcall(vim.json.decode, result.stdout or "")
          if result.code ~= 0 or not decoded or type(value) ~= "table" or not value.ok
              or type(value.dirs) ~= "table" then
            finish(nil, decoded and type(value) == "table" and value.reason
              or ("scan-root worker failed: " .. tostring(result.code) .. " " .. tostring(result.stderr)))
            return
          end
          for _, path in ipairs(value.dirs) do
            if type(path) ~= "string" then finish(nil, "invalid scan-root result"); return end
          end
          finish(value.dirs, nil, { worker_ms = value.wall_ms })
        end)
      end)
      if not ok then finish(nil, tostring(handle)); return end
      pcall(require("utils.task_registry").register, { name = "UE prepare scan roots", group = "ue",
        kind = "system", handle = handle })
      process = handle
      owned[process] = cancel
      if not leave_registered then
        leave_registered = true
        vim.api.nvim_create_autocmd("VimLeavePre", { callback = function()
          local pending = {}
          for _, stop in pairs(owned) do pending[#pending + 1] = stop end
          for _, stop in ipairs(pending) do stop() end
        end })
      end
      return handle
    end,
    on_error = function(err) finish(nil, tostring(err)) end,
    on_cancel = function() finish(nil, "scan-root discovery cancelled") end,
  })
  return cancel
end

function M.begin(ctx, opts, rt, lease, continue_prepare, fail)
  local cache = require("ue.cdb.prepare_cache")
  cache.begin(ctx, opts, function(reused_inputs)
    if not require("ue")._prepare_running or rt.prepare_lease ~= lease then return end
    local project_key = require("ue.core.fs").norm(ctx.project_root or "")
    if reused_inputs or project_key == "" or rt.project_index_dirs_cache[project_key] then
      continue_prepare(reused_inputs)
      return
    end
    -- Input observation precedes discovery; a changed epoch cannot prime the
    -- cache later consumed by synchronous readiness and workspace scan paths.
    local epoch = cache.status().epoch
    M.start(ctx, function(dirs, err)
      if not require("ue")._prepare_running or rt.prepare_lease ~= lease then return end
      if epoch ~= cache.status().epoch then
        dirs, err = nil, "inputs changed during scan-root discovery; retry UEPrepare"
      end
      if not dirs then fail(err); return end
      rt.project_index_dirs_cache[project_key] = dirs
      continue_prepare(false)
    end)
  end)
end

if arg and arg[0] and arg[0]:gsub("\\", "/"):match("/prepare_scan_roots%.lua$") then
  local config = vim.fn.stdpath("config")
  vim.opt.runtimepath:prepend(config)
  package.path = config .. "/lua/?.lua;" .. config .. "/lua/?/init.lua;" .. package.path
  local ok, result = pcall(function()
    local file = assert(io.open(arg[1], "rb"))
    local raw = file:read("*a"); file:close()
    return M.collect(vim.json.decode(raw))
  end)
  io.stdout:write(vim.json.encode(ok and result or { ok = false, reason = tostring(result) }))
end

return M
