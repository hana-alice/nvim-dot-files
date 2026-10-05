-- Per-process business receipts, not a second process-status registry.
-- Only begin/complete write execution evidence. Handle liveness is queried;
-- retained diagnostics survive the native quickfix stack's bounded history.
local M = {}
local api = vim.api
local records, sequence = {}, 0
local KEEP_DONE, MAX_ROWS, MAX_BYTES = 16, 1024, 1024 * 1024
local identity_fields = {
  "project_root",
  "engine_root",
  "uproject",
  "target",
  "platform",
  "configuration",
  "operation",
  "label",
  "buf",
  "name",
  "jobid",
  "started_at",
  "dirty_count_start",
  "cwd",
}
local item_fields = {
  "bufnr",
  "filename",
  "lnum",
  "end_lnum",
  "col",
  "end_col",
  "vcol",
  "nr",
  "type",
  "text",
  "valid",
  "pattern",
  "_source_location",
}

local function positive(value)
  return type(value) == "number" and value > 0 and value % 1 == 0
end

-- The third return protects an interrupted/unavailable probe from trimming a
-- possibly live process. Invalid native IDs are known to be no longer live.
local function process(record)
  if not positive(record.jobid) then
    return "not_started", nil, false
  end
  local ok, values = pcall(vim.fn.jobwait, { record.jobid }, 0)
  local code = ok and type(values) == "table" and values[1] or nil
  if code == -1 then
    return "running", nil, true
  elseif type(code) == "number" and code >= 0 then
    return "done", code, false
  end
  return "unknown", nil, code ~= -3
end

local function trim()
  local exited = {}
  for id, record in pairs(records) do
    local _, _, protected = process(record)
    if record.completed and not protected then
      exited[#exited + 1] = id
    end
  end
  table.sort(exited)
  for index = 1, math.max(0, #exited - KEEP_DONE) do
    records[exited[index]] = nil
  end
end

local function outcome(record, live)
  if not record.completed then
    return live == "running" and "running" or "awaiting_receipt"
  end
  if record.cancelled then
    return "cancelled"
  elseif record.current == false then
    return "not_current"
  elseif not positive(record.jobid) or type(record.code) == "number" and record.code < 0 then
    return "not_started"
  elseif record.current ~= true or type(record.code) ~= "number" or record.code % 1 ~= 0 then
    return "unknown"
  elseif live == "running" then
    return "unknown"
  end
  return record.code == 0 and "exit_zero" or "failed"
end

--- Main-loop business notification only; get/list/navigation do not emit.
function M.changed(data)
  local function emit()
    pcall(api.nvim_exec_autocmds, "User", { pattern = "UEWorkbenchChanged", data = data })
  end
  if vim.in_fast_event() then
    vim.schedule(emit)
  else
    emit()
  end
end

--- Freeze the actual invocation's identity; never infer a replay command.
---@param spec table
---@return integer? id, string? err
function M.begin(spec)
  if type(spec) ~= "table" then
    return nil, "执行凭据缺少上下文"
  end
  sequence = sequence + 1
  local record = { id = sequence, completed = false, items = {}, partial = false, omitted_rows = 0, item_bytes = 2 }
  for _, key in ipairs(identity_fields) do
    record[key] = vim.deepcopy(spec[key])
  end
  record.started_at = record.started_at or os.time()
  if record.name == nil and positive(record.buf) and api.nvim_buf_is_valid(record.buf) then
    record.name = api.nvim_buf_get_name(record.buf)
  end
  if positive(record.buf) and api.nvim_buf_is_valid(record.buf) then
    record._log_buftype = vim.bo[record.buf].buftype
    record._log_channel = vim.bo[record.buf].channel
  end
  records[record.id] = record
  trim()
  M.changed({ id = record.id, event = "begin" })
  return record.id
end

local function copy_item(item)
  if type(item) ~= "table" then
    return nil
  end
  local copy, bytes = {}, 0
  for _, key in ipairs(item_fields) do
    local value = item[key]
    if type(value) == "string" or type(value) == "number" or type(value) == "boolean" then
      copy[key] = value
      if type(value) == "string" then
        bytes = bytes + #value
      end
    end
  end
  if positive(copy.bufnr) and api.nvim_buf_is_valid(copy.bufnr) then
    copy._buf_name = api.nvim_buf_get_name(copy.bufnr)
    if copy._buf_name ~= "" then
      copy.filename = copy._buf_name
    end
    bytes = bytes + #copy._buf_name
  elseif type(copy.filename) == "string" and copy.filename ~= "" then
    copy.filename = vim.fn.fnamemodify(copy.filename, ":p")
    bytes = bytes + #copy.filename
  end
  return copy, bytes
end

local function qf_info(id)
  local info = vim.fn.getqflist({ id = id, context = 0, changedtick = 0 })
  return type(info) == "table" and info.id == id and info or nil
end

--- Accept exactly one terminal business receipt for this invocation.
---@param id integer
---@param receipt table
---@return boolean ok, string? err
function M.complete(id, receipt)
  local record = records[id]
  if not record then
    return false, "执行凭据已淘汰或不存在"
  elseif record.completed then
    return false, "该次执行已有完成凭据"
  elseif type(receipt) ~= "table" then
    return false, "完成凭据格式无效"
  end
  local items = type(receipt.items) == "table" and receipt.items or {}
  local saved, bytes = {}, 2
  for _, item in ipairs(items) do
    if #saved >= MAX_ROWS then
      break
    end
    local copy, raw_bytes = copy_item(item)
    if copy and raw_bytes <= MAX_BYTES - bytes then
      local ok, encoded = pcall(vim.json.encode, copy)
      local size = ok and #encoded + (#saved > 0 and 1 or 0) or MAX_BYTES + 1
      if size <= MAX_BYTES - bytes then
        saved[#saved + 1], bytes = copy, bytes + size
      end
    end
  end
  record.completed = true
  record.code = type(receipt.code) == "number" and receipt.code or nil
  if type(receipt.current) == "boolean" then
    record.current = receipt.current
  end
  record.cancelled = receipt.cancelled == true
  record.qf_id = positive(receipt.qf_id) and receipt.qf_id or nil
  record.qf_tick = type(receipt.qf_tick) == "number" and receipt.qf_tick or nil
  if record.qf_id and record.qf_tick == nil then
    local info = qf_info(record.qf_id)
    record.qf_tick = info and info.changedtick or nil
  end
  record.items, record.item_bytes = saved, bytes
  record.omitted_rows = #items - #saved
  record.partial = record.omitted_rows > 0 or receipt.partial == true
  trim()
  M.changed({ id = id, event = "complete" })
  return true
end

---@return table? snapshot
function M.get(id)
  local record = records[id]
  if not record then
    return nil
  end
  local snapshot = vim.deepcopy(record)
  snapshot.process_status, snapshot.process_code = process(record)
  snapshot.result = outcome(record, snapshot.process_status)
  return snapshot
end

--- Sort by actual begin order, independent of completion or wall-clock order.
---@param opts? table
---@return table[]
function M.list(opts)
  opts = opts or {}
  trim()
  local rows = {}
  for id, record in pairs(records) do
    local matches = true
    for _, key in ipairs({ "project_root", "engine_root", "uproject", "target", "platform", "configuration" }) do
      if opts[key] ~= nil and record[key] ~= opts[key] then
        matches = false
        break
      end
    end
    if matches then
      rows[#rows + 1] = M.get(id)
    end
  end
  table.sort(rows, function(a, b)
    return a.id > b.id
  end)
  return rows
end

---@return integer? win, string? err
function M.show_log(id)
  local record = records[id]
  if not record then
    return nil, "执行凭据已淘汰或不存在"
  elseif
    not positive(record.buf)
    or not api.nvim_buf_is_valid(record.buf)
    or not api.nvim_buf_is_loaded(record.buf)
    or api.nvim_buf_get_name(record.buf) ~= record.name
    or vim.bo[record.buf].buftype ~= record._log_buftype
    or vim.bo[record.buf].channel ~= record._log_channel
    or record._log_buftype == "terminal" and (not positive(record.jobid) or record._log_channel ~= record.jobid)
  then
    return nil, "该次执行的日志已删除或身份已变化"
  end
  if record._log_buftype == "terminal" then
    for _, channel in ipairs(api.nvim_list_chans()) do
      -- open_term can attach a second terminal without changing 'channel'.
      -- A competing native terminal owner makes this log credential ambiguous.
      if channel.buffer == record.buf and channel.mode == "terminal" and channel.id ~= record.jobid then
        return nil, "该次执行的日志已有其他终端来源"
      end
    end
  end
  return require("utils.workspace").activate({
    kind = "log",
    buf = record.buf,
    name = record.name,
    panel = vim.b[record.buf].ue_bottom_panel_kind,
  })
end

local function owned_qf(qf, id, tick)
  local info = positive(qf) and qf_info(qf) or nil
  return info and type(info.context) == "table" and info.context.verification_id == id and info.changedtick == tick
end

local function replay_items(record)
  local items = vim.deepcopy(record.items)
  for _, item in ipairs(items) do
    if
      not positive(item.bufnr)
      or not api.nvim_buf_is_valid(item.bufnr)
      or api.nvim_buf_get_name(item.bufnr) ~= item._buf_name
    then
      -- A retained filename may resolve a new buffer, but an old/reused native
      -- buffer number must never send this diagnostic to another file owner.
      item.bufnr = nil
      if type(item.filename) == "string" and item.filename ~= "" then
        -- Native quickfix caches filename -> buffer bindings across renames.
        -- bufadd resolves the actual file owner without loading or writing it.
        local ok, buf = pcall(vim.fn.bufadd, item.filename)
        if
          not ok
          or not positive(buf)
          or not api.nvim_buf_is_valid(buf)
          or vim.fs.normalize(api.nvim_buf_get_name(buf)) ~= vim.fs.normalize(item.filename)
        then
          return nil, "重建时文件缓冲区归属已变化"
        end
        item.bufnr = buf
      end
    end
    item._buf_name = nil
  end
  return items
end

---@return integer? win, string? err
function M.show_problems(id)
  local record = records[id]
  if not record then
    return nil, "执行凭据已淘汰或不存在"
  end
  local workspace = require("utils.workspace")
  if not owned_qf(record.qf_id, id, record.qf_tick) then
    if #record.items == 0 then
      return nil,
        record.partial and "该次错误超过保存预算；没有保留可重建的行"
          or "该次执行没有保留的错误列表"
    end
    local items, resolve_err = replay_items(record)
    if not items then
      return nil, resolve_err
    end
    local qf, err = workspace.pin(items, {
      title = record.label or ("验证 #" .. id),
      source = "verification",
      recipe = { verification_id = id },
      truncated = record.partial,
    })
    if not qf then
      return nil, err
    end
    local info = qf_info(qf)
    local context = info and info.context
    if type(context) ~= "table" or type(context.recipe) ~= "table" or context.recipe.verification_id ~= id then
      return nil, "保存后的错误列表归属已变化"
    end
    context = vim.deepcopy(context)
    context.verification_id = id
    local ok, value = pcall(vim.fn.setqflist, {}, "a", { id = qf, context = context })
    local captured = qf_info(qf)
    local tick = captured and captured.changedtick
    if not ok or value ~= 0 or not owned_qf(qf, id, tick) then
      return nil, "无法标记该次执行的错误列表"
    end
    -- This is only an expendable navigation reference; evidence stays frozen.
    record.qf_id, record.qf_tick = qf, tick
  end
  local win, err = workspace.activate({ kind = "result", id = record.qf_id })
  if win and not owned_qf(vim.fn.getqflist({ id = 0 }).id, id, record.qf_tick) then
    return nil, "打开期间错误列表已切换；已保留新选择"
  end
  return win, err
end

return M
