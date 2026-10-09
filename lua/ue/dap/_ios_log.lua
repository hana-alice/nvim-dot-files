local Sessions = require("ue.dap._ios_session")
local Tasks = require("utils.task_registry")

local M = { label = "iOS Logs" }
local records = setmetatable({}, { __mode = "k" })
local MAX_LINES = 12000

local function active(record)
  return not record.stopped and records[record.session] == record and vim.api.nvim_buf_is_valid(record.buffer)
end

local function append(record, lines)
  if not active(record) or #lines == 0 then
    return
  end
  local buffer = record.buffer
  local count = vim.api.nvim_buf_line_count(buffer)
  local cursors = {}
  for _, win in ipairs(vim.fn.win_findbuf(buffer)) do
    local cursor = vim.api.nvim_win_get_cursor(win)
    cursors[win] = { cursor = cursor, follow = cursor[1] == count }
  end
  vim.api.nvim_buf_set_lines(buffer, -1, -1, false, lines)
  local excess = math.max(0, vim.api.nvim_buf_line_count(buffer) - MAX_LINES)
  if excess > 0 then
    vim.api.nvim_buf_set_lines(buffer, 0, excess, false, {})
  end
  local last = vim.api.nvim_buf_line_count(buffer)
  for win, saved in pairs(cursors) do
    if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == buffer then
      local row = saved.follow and last or math.max(1, saved.cursor[1] - excess)
      local line = vim.api.nvim_buf_get_lines(buffer, row - 1, row, false)[1] or ""
      pcall(vim.api.nvim_win_set_cursor, win, { row, math.min(saved.cursor[2], #line) })
    end
  end
end

local function failure(record, layer, evidence, remedy)
  local lines = { "[iOS Logs error] layer=" .. layer .. " owner=ios.logrelay" }
  vim.list_extend(lines, vim.split("evidence: " .. tostring(evidence), "\n", { plain = true }))
  vim.list_extend(lines, vim.split("remedy: " .. remedy, "\n", { plain = true }))
  append(record, lines)
end

local function chunks(record, stream, data)
  local lines = {}
  for index, chunk in ipairs(data or {}) do
    record.partial[stream] = record.partial[stream] .. chunk
    if index < #data then
      local line = record.partial[stream]:gsub("\r$", "")
      lines[#lines + 1] = (stream == "stderr" and "[stderr] " or "") .. line
      record.partial[stream] = ""
    end
  end
  return lines
end

local function start_reader(record, udid, network)
  if not active(record) then
    return
  end
  local argv = { record.tool, "--udid", udid, "--process", tostring(record.pid), "--no-colors", "--exit" }
  if network then
    argv[#argv + 1] = "--network"
  end
  local options = {}
  for _, stream in ipairs({ "stdout", "stderr" }) do
    options["on_" .. stream] = function(_, data)
      if record.stopped then
        return
      end
      local lines = chunks(record, stream, data)
      vim.schedule(function()
        append(record, lines)
      end)
    end
  end
  options.on_exit = function(_, code)
    vim.schedule(function()
      if not active(record) then
        return
      end
      record.job = nil
      for _, stream in ipairs({ "stdout", "stderr" }) do
        if record.partial[stream] ~= "" then
          append(record, { (stream == "stderr" and "[stderr] " or "") .. record.partial[stream] })
          record.partial[stream] = ""
        end
      end
      failure(
        record,
        "L1",
        "idevicesyslog exited with code " .. tostring(code),
        "Check the frozen device connection and log relay access."
      )
    end)
  end
  local ok, job = pcall(vim.fn.jobstart, argv, options)
  if not ok or type(job) ~= "number" or job <= 0 then
    failure(
      record,
      "L0",
      "idevicesyslog spawn failed: " .. tostring(job),
      "Check the existing idevicesyslog executable."
    )
    return
  end
  record.job = job
  pcall(Tasks.register, { name = "iOS logs (PID " .. record.pid .. ")", group = "dap", kind = "job", handle = job })
end

local function map_coredevice(record)
  local xcrun = vim.fn.exepath("xcrun")
  if xcrun == "" then
    failure(record, "L0", "xcrun executable unavailable", "Select an installed Xcode toolchain with devicectl.")
    return
  end
  local path = vim.fn.tempname()
  record.query_path = path
  local argv = {
    xcrun,
    "devicectl",
    "device",
    "info",
    "details",
    "--device",
    record.device,
    "--quiet",
    "--timeout",
    "20",
    "--json-output",
    path,
  }
  local ok, handle = pcall(vim.system, argv, { text = true, timeout = 25000 }, function(result)
    vim.schedule(function()
      local read_ok, content = pcall(vim.fn.readfile, path)
      pcall(vim.fn.delete, path)
      if not active(record) then
        return
      end
      record.query = nil
      record.query_path = nil
      if result.code ~= 0 then
        failure(
          record,
          "L1",
          "devicectl device info details exited "
            .. tostring(result.code)
            .. ": "
            .. (result.stderr or result.stdout or ""),
          "Check the frozen CoreDevice connection and pairing."
        )
        return
      end
      local decoded_ok, payload = false, nil
      if read_ok then
        decoded_ok, payload = pcall(vim.json.decode, table.concat(content, "\n"))
      end
      local device = decoded_ok and type(payload) == "table" and payload.result or nil
      if type(device) ~= "table" or device.identifier ~= record.device then
        failure(
          record,
          "L1",
          "devicectl device info details did not identify frozen CoreDevice " .. record.device,
          "Query this exact CoreDevice again; do not substitute another device."
        )
        return
      end
      local hardware = type(device.hardwareProperties) == "table" and device.hardwareProperties or {}
      local udid = hardware.udid
      if type(udid) ~= "string" or vim.trim(udid) == "" then
        failure(
          record,
          "L1",
          "devicectl device info details missing hardwareProperties.udid",
          "Check device pairing and the structured device details response."
        )
        return
      end
      local connection = type(device.connectionProperties) == "table" and device.connectionProperties or {}
      start_reader(record, udid, connection.transportType == "network")
    end)
  end)
  if not ok or not handle then
    pcall(vim.fn.delete, path)
    record.query_path = nil
    failure(
      record,
      "L0",
      "devicectl device info details spawn failed: " .. tostring(handle),
      "Check the selected Xcode devicectl tool."
    )
    return
  end
  record.query = handle
  pcall(Tasks.register, { name = "iOS log device mapping", group = "dap", kind = "system", handle = handle })
end

--- Stop only this session's log reader and pending identity query.
function M.stop(session)
  local record = session and records[session] or nil
  if not record or record.stopped then
    return
  end
  record.stopped = true
  if record.job then
    pcall(vim.fn.jobstop, record.job)
    record.job = nil
  end
  if record.query then
    pcall(function()
      record.query:kill(15)
    end)
    record.query = nil
  end
  if record.query_path then
    pcall(vim.fn.delete, record.query_path)
    record.query_path = nil
  end
  for _, id in ipairs(record.autocmds) do
    pcall(vim.api.nvim_del_autocmd, id)
  end
  if session.on_close and session.on_close.ue_ios_log == record.on_close then
    session.on_close.ue_ios_log = nil
  end
  -- Do not keep a closed session alive through a weak-key table's value.
  record.session = nil
  record.on_close = nil
end

--- Lazily create a log buffer using only the owned session's frozen identity.
function M.buffer(session)
  if not Sessions.is_owned(session) then
    return nil
  end
  local existing = records[session]
  if existing then
    if vim.api.nvim_buf_is_valid(existing.buffer) then
      return existing.buffer
    end
    M.stop(session)
    records[session] = nil
  end
  local config = session.config
  local pid = tonumber(config._ue_process_id or config.pid)
  local buffer = vim.api.nvim_create_buf(false, true)
  local record = {
    session = session,
    buffer = buffer,
    pid = pid,
    device = config._ue_device_id,
    backend = config._ue_ios_session_owner,
    partial = { stdout = "", stderr = "" },
    autocmds = {},
  }
  records[session] = record
  vim.bo[buffer].bufhidden = "hide"
  vim.bo[buffer].filetype = "log"
  vim.b[buffer].ue_dap_log = true
  local name = "ue-ios-log:" .. tostring(pid or "unknown")
  if vim.fn.bufnr(name) ~= -1 then
    name = name .. ":" .. buffer
  end
  vim.api.nvim_buf_set_name(buffer, name)
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { "iOS Logs (PID " .. tostring(pid or "unknown") .. ")" })
  record.on_close = function()
    vim.schedule(function()
      if records[session] == record then
        M.stop(session)
      end
    end)
  end
  session.on_close = session.on_close or {}
  session.on_close.ue_ios_log = record.on_close
  record.autocmds[1] = vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buffer,
    callback = function()
      M.stop(session)
    end,
  })
  record.autocmds[2] = vim.api.nvim_create_autocmd("VimLeavePre", {
    callback = function()
      M.stop(session)
    end,
  })
  if not pid or pid <= 0 or pid % 1 ~= 0 or type(record.device) ~= "string" or vim.trim(record.device) == "" then
    failure(
      record,
      "L1",
      "owned session missing a positive PID or frozen device identifier",
      "Attach or launch an iOS session with a frozen device and PID."
    )
    return buffer
  end
  record.tool = vim.fn.exepath("idevicesyslog")
  if record.tool == "" then
    failure(
      record,
      "L0",
      "idevicesyslog executable unavailable",
      "Make an existing libimobiledevice idevicesyslog executable available on PATH."
    )
  elseif record.backend == "coredevice" then
    map_coredevice(record)
  else
    start_reader(record, record.device, false)
  end
  return buffer
end

return M
