-- Opt-in external executor. Configuration stays in the current editor instance.
local M = { owner = "android.distributed" }
local running
local building = false

function M.is_running() return building end

local function nonempty(value)
  return type(value) == "string" and value:find("%S") and value or nil
end

-- Read on invocation: a new editor may inherit an old parent-process environment.
function M.resolve_config(opts)
  opts = opts or {}
  local globals, env = opts.globals or vim.g, opts.env or vim.env
  local path = opts.path or (vim.fn.stdpath("data") .. "/ue-builddispatch.json")
  local config = {
    script = nonempty(globals.ue_builddispatch_script) or nonempty(env.NVIM_UE_BUILDDISPATCH),
    worker_config = nonempty(globals.ue_builddispatch_worker_config) or nonempty(env.NVIM_UE_BUILDDISPATCH_CONFIG),
    python = nonempty(globals.ue_builddispatch_python) or nonempty(env.NVIM_UE_BUILDDISPATCH_PYTHON),
  }
  if not config.script or not config.worker_config or not config.python then
    local stat, stat_err, stat_code = vim.uv.fs_stat(path)
    if stat then
      if stat.type ~= "file" or stat.size > 65536 then
        return nil, "Invalid BuildDispatch config " .. path .. ": expected a JSON file up to 64 KiB"
      end
      local read_ok, lines = pcall(vim.fn.readfile, path)
      if not read_ok then return nil, "Cannot read BuildDispatch config " .. path end
      local content = table.concat(lines, "\n"):gsub("^\239\187\191", "")
      local ok, saved = pcall(vim.json.decode, content)
      if not ok or not content:match("^%s*{") or type(saved) ~= "table" then
        return nil, "Invalid BuildDispatch config " .. path .. ": expected a JSON object"
      end
      for _, key in ipairs({ "script", "worker_config", "python" }) do
        if not config[key] then
          if saved[key] ~= nil and type(saved[key]) ~= "string" then
            return nil, "Invalid BuildDispatch config " .. path .. ": " .. key .. " must be a string"
          end
          config[key] = nonempty(saved[key])
        end
      end
    elseif stat_code ~= "ENOENT" then
      return nil, "Cannot inspect BuildDispatch config " .. path .. ": " .. tostring(stat_err)
    end
  end
  config.python = config.python or "python"
  config.local_config_path = path
  return config
end

function M.start(opts)
  opts = opts or {}
  if running then return nil, "A distributed build or plan is already running" end
  if not opts.dry_run and require("ue").build_running() then
    return nil, "A UE build is already running in this editor"
  end
  local resolved, config_err = M.resolve_config()
  if not resolved then return nil, config_err end
  local script = resolved.script
  if not script or script == "" or vim.fn.filereadable(script) ~= 1 then
    return nil, "Set vim.g.ue_builddispatch_script, NVIM_UE_BUILDDISPATCH, or script in "
      .. resolved.local_config_path .. " to build_android.py"
  end
  local snapshot, err = require("ue").build_snapshot(opts)
  if not snapshot then return nil, err end
  if snapshot.platform ~= "Android" then return nil, "Distributed compilation currently supports Android only" end
  snapshot = vim.deepcopy(snapshot)
  local args = { script, "--context-stdin" }
  if opts.dry_run then args[#args + 1] = "--dry-run" end
  local config = resolved.worker_config
  if config and config ~= "" then
    vim.list_extend(args, { "--worker-config", config })
  end
  local title = (opts.dry_run and "UEBuildDistributedPlan" or "UEBuildDistributed")
    .. " " .. snapshot.platform .. " " .. snapshot.configuration
  if not opts.dry_run then
    require("ue.cdb.pipeline").cancel(title .. " started")
    local prepared, prep_err = require("ue.workflows.android.build").run({
      operation = "build", target_id = "Android",
      payload = { context = snapshot, configuration = snapshot.configuration },
    })
    if not prepared then return nil, prep_err end
  end
  local tasks = require("ue.target_tasks")
  local progress = tasks.progress({ title = title, message = "Starting external build executor" })
  local buffer = vim.api.nvim_create_buf(false, true)
  vim.bo[buffer].buftype = "nofile"
  vim.bo[buffer].filetype = "log"
  vim.api.nvim_buf_set_name(buffer, title .. " " .. tostring(buffer))
  local pending = ""
  local errors = {}
  local function output(data)
    local lines = vim.split(pending .. data, "\n", { plain = true })
    pending = table.remove(lines) or ""
    -- Retain only bounded diagnostic context; the runner owns complete disk logs.
    if #pending > 65536 then pending = pending:sub(-65536) end
    for _, line in ipairs(lines) do
      if line:lower():find("error", 1, true) and #errors < 1000 then errors[#errors + 1] = line end
    end
    if vim.api.nvim_buf_is_valid(buffer) then
      local previous_end = vim.api.nvim_buf_line_count(buffer)
      local following = {}
      for _, window in ipairs(vim.fn.win_findbuf(buffer)) do
        if vim.api.nvim_win_get_cursor(window)[1] == previous_end then
          following[#following + 1] = window
        end
      end
      vim.api.nvim_buf_set_lines(buffer, -1, -1, false, lines)
      local excess = vim.api.nvim_buf_line_count(buffer) - 5000
      if excess > 0 then vim.api.nvim_buf_set_lines(buffer, 0, excess, false, {}) end
      local current_end = vim.api.nvim_buf_line_count(buffer)
      for _, window in ipairs(following) do
        if vim.api.nvim_win_is_valid(window) then
          vim.api.nvim_win_set_cursor(window, { current_end, 0 })
        end
      end
    end
  end
  local handle, run_err = tasks.run({
    executable = resolved.python,
    args = args, cwd = snapshot.build_cwd,
    metadata = { platform = snapshot.platform, operation = "build" },
  }, {
    stdin = vim.json.encode(snapshot), name = title, foreground = not opts.dry_run, capture_output = false,
    on_stdout = output, on_stderr = output,
    on_exit = function(result)
      running = nil
      building = false
      output("\n")
      M.last_result = { code = result.code, signal = result.signal }
      if result.code ~= 0 then
        vim.fn.setqflist({}, "r", { title = title, lines = errors })
      end
      progress:finish(result.code == 0 and "Completed" or ("Failed (exit " .. result.code .. ")"), 100,
        result.code == 0 and vim.log.levels.INFO or vim.log.levels.ERROR)
    end,
  })
  if not handle then
    progress:finish(run_err, nil, vim.log.levels.ERROR)
    return nil, run_err
  end
  running = handle
  building = not opts.dry_run
  M.last_buffer = buffer
  vim.cmd("botright split")
  vim.api.nvim_win_set_buf(0, buffer)
  return handle
end

function M.setup()
  for _, name in ipairs({ "UEBuildDistributed", "UEBuildDistributedPlan" }) do
    vim.api.nvim_create_user_command(name, function(command)
      if #command.fargs > 2 then
        vim.notify("Usage: " .. name .. " [Android] [Development]", vim.log.levels.ERROR)
        return
      end
      local handle, err = M.start({
        platform = command.fargs[1], configuration = command.fargs[2],
        dry_run = name == "UEBuildDistributedPlan",
      })
      if not handle then vim.notify(err, vim.log.levels.ERROR) end
    end, { nargs = "*", desc = "Run external distributed build using the current UE selection" })
  end
end

return M
