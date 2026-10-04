-- Current-document Find: one result per memory-text occurrence, with local ownership.
local M = {}
local process = require("utils.document_find_process")
local uv = vim.uv or vim.loop
local sessions = setmetatable({}, { __mode = "k" })
local active, retiring_job
local session_sequence = 0

local reasons = {
  ["source-too-large"] = "文档超过 2 MiB 上限",
  ["source-unavailable"] = "源窗口或文档已改变，请重新打开",
  ["stale-source"] = "源位置或内容已改变，F5 刷新",
  ["single-line-query-required"] = "查询必须是非空单行文本",
  ["query-too-large"] = "查询超过 8 KiB 上限",
  ["unsupported-zero-width"] = "不支持零宽匹配，请使用非空匹配的 Rust 正则",
  ["unsupported-binary-text"] = "该行含非 UTF-8 文本，无法安全显示匹配",
  ["source-nul"] = "文档含 NUL，无法安全映射文本坐标",
  ["result-limit"] = "已达 5000 条结果上限（部分结果）",
  ["record-limit"] = "单行结果超过 1 MiB 上限（部分结果）",
  ["output-limit"] = "结果输出超过 8 MiB 上限（部分结果）",
  ["deadline"] = "查找超时，请缩小查询范围",
  ["timer-unavailable"] = "无法创建查找计时器",
  ["spawn-failed"] = "无法启动 rg",
  ["stdin-write-failed"] = "无法把文档发送到 rg，查找已取消",
  ["stdin-incomplete"] = "rg 未完整读取文档，请重新查找",
  ["rg-error"] = "正则或 rg 查找失败",
}

local function source_identity(owner)
  return vim.api.nvim_win_is_valid(owner.win)
    and vim.api.nvim_tabpage_is_valid(owner.tab)
    and vim.api.nvim_win_get_tabpage(owner.win) == owner.tab
    and vim.api.nvim_get_current_tabpage() == owner.tab
    and vim.api.nvim_buf_is_loaded(owner.buf)
    and vim.api.nvim_win_get_buf(owner.win) == owner.buf
    and vim.api.nvim_buf_get_name(owner.buf) == owner.path
    and vim.bo[owner.buf].buftype == ""
end

local function source_valid(owner)
  return source_identity(owner)
    and vim.api.nvim_buf_get_changedtick(owner.buf) == owner.tick
    and vim.deep_equal(vim.api.nvim_win_get_cursor(owner.win), owner.cursor)
end

--- Capture bounded memory text. The offset check precedes any complete-buffer copy.
function M.snapshot(owner, limits)
  limits = limits or process.limits
  if not source_identity(owner) then
    return nil, "source-unavailable"
  end
  local count = vim.api.nvim_buf_line_count(owner.buf)
  if vim.api.nvim_buf_get_offset(owner.buf, count) > limits.source_bytes then
    return nil, "source-too-large"
  end
  local tick, cursor = vim.api.nvim_buf_get_changedtick(owner.buf), vim.api.nvim_win_get_cursor(owner.win)
  local lines = vim.api.nvim_buf_get_lines(owner.buf, 0, -1, false)
  if #lines == 0 then
    lines = { "" }
  end
  for _, line in ipairs(lines) do
    if line:find("[\n%z]") then
      return nil, "source-nul"
    end
  end
  -- A final LF represents the final logical row, even for 'noeol' and blank rows.
  local text = table.concat(lines, "\n") .. "\n"
  if #text > limits.source_bytes then
    return nil, "source-too-large"
  end
  if
    not source_identity(owner)
    or tick ~= vim.api.nvim_buf_get_changedtick(owner.buf)
    or not vim.deep_equal(cursor, vim.api.nvim_win_get_cursor(owner.win))
  then
    return nil, "stale-source"
  end
  return { text = text, lines = lines, tick = tick, cursor = cursor }
end

local function update(session, state, reason, result)
  session.state, session.reason = state, reason
  if result then
    session.count, session.bytes = result.count or 0, result.bytes or 0
    session.stderr = result.stderr
  end
  local picker = session.picker
  if not picker or picker.closed then
    return
  end
  local modes = session.modes
  local mode = (modes.regex and "Regex" or "Literal")
    .. (modes.case_sensitive and " Aa" or " aA")
    .. (modes.whole_word and " Word" or "")
  local feedback = ({
    idle = "输入查询",
    debounce = "等待输入",
    running = "查找中",
    ready = "匹配",
    empty = "无匹配",
    error = "错误",
    truncated = "部分结果",
    stale = "已失效",
    cancelled = "已取消",
  })[state] or state
  local detail = reason and (reasons[reason] or reason) or feedback
  if reason == "rg-error" and session.stderr then
    detail = "正则错误: " .. (session.stderr:match("error:[^\r\n]*") or "请检查 Rust 正则")
  end
  picker.title = ("文档查找 · %s · %d · %s · Alt-C/W/R · F5"):format(mode, session.count or 0, detail)
  picker:update_titles()
end

local function cancel_request(session, reason)
  local request = session.request
  if not request or request.cancelled then
    return
  end
  request.cancelled = true
  if request.timer then
    pcall(request.timer.stop, request.timer)
    pcall(request.timer.close, request.timer)
    request.timer = nil
  end
  if request.job then
    request.job.cancel(reason)
  end
  if request.async then
    request.async:resume()
  end
end

local function stale(session)
  if session.closed or source_valid(session.owner) then
    return
  end
  cancel_request(session, "stale-source")
  session.count = 0
  update(session, "stale", "stale-source")
  if session.picker and not session.picker.closed then
    session.picker:find()
  end
end

local function close(session)
  if session.closed then
    return
  end
  session.closed = true
  cancel_request(session, "picker-closed")
  local job = session.last_job
  if job and not job.finished then
    retiring_job = job
    job.when_done(function()
      if retiring_job == job then
        retiring_job = nil
      end
    end)
  end
  session.snapshot, session.picker, session.request, session.last_job = nil, nil, nil, nil
  if active == session then
    active = nil
  end
end

local function attach_input(session, picker)
  if session.input_attached or not picker.input.win.buf then
    return
  end
  session.input_attached = true
  vim.api.nvim_buf_attach(picker.input.win.buf, false, {
    on_lines = function()
      if session.closed then
        return true
      end
      cancel_request(session, "query-changed")
      vim.schedule(function()
        local p = session.picker
        if p and not p.closed and p.input:get() ~= session.query then
          p:find()
        end
      end)
    end,
  })
end

-- Native resume reuses configuration callbacks, never the previous source owner.
local function session_for(picker)
  if sessions[picker] then
    return sessions[picker]
  end
  local win = picker.main
  local owner = { win = win, tab = vim.api.nvim_win_get_tabpage(win), buf = vim.api.nvim_win_get_buf(win) }
  owner.path = vim.api.nvim_buf_get_name(owner.buf)
  local limits = vim.tbl_extend("force", process.limits, picker.opts.document_find_limits or {})
  local snapshot, err = M.snapshot(owner, limits)
  if snapshot then
    owner.tick, owner.cursor = snapshot.tick, snapshot.cursor
  end
  session_sequence = session_sequence + 1
  local session = {
    id = session_sequence,
    owner = owner,
    snapshot = snapshot,
    limits = limits,
    initial_error = err,
    last_job = retiring_job,
    picker = picker,
    generation = 0,
    state = "idle",
    count = 0,
    modes = vim.tbl_extend(
      "force",
      { case_sensitive = false, whole_word = false, regex = false },
      picker.opts.document_find_modes or {}
    ),
  }
  sessions[picker], active = session, session
  vim.api.nvim_buf_attach(owner.buf, false, {
    on_lines = function()
      if session.closed then
        return true
      end
      vim.schedule(function()
        stale(session)
      end)
    end,
    on_reload = function()
      if session.closed then
        return
      end
      vim.schedule(function()
        stale(session)
      end)
    end,
    on_detach = function()
      vim.schedule(function()
        stale(session)
      end)
    end,
  })
  return session
end

function M.status(picker)
  local session = picker and sessions[picker] or active
  if not session then
    return nil
  end
  return {
    state = session.state,
    reason = session.reason,
    query = session.query,
    modes = vim.deepcopy(session.modes),
    count = session.count or 0,
    bytes = session.bytes or 0,
    generation = session.generation,
    closed = session.closed or false,
    limits = vim.deepcopy(session.limits),
  }
end

local function finder(session, _, ctx)
  cancel_request(session, "superseded")
  session.generation = session.generation + 1
  local generation = session.generation
  local query = ctx.filter.search
  session.query, session.count, session.bytes, session.stderr = query, 0, 0, nil
  if session.initial_error then
    update(session, "error", session.initial_error)
    return {}
  end
  if not source_valid(session.owner) then
    update(session, "stale", "stale-source")
    return {}
  end
  local invalid = process.validate(query, session.limits)
  if invalid then
    update(session, "error", invalid)
    return {}
  end
  if query == "" then
    update(session, "idle")
    return {}
  end
  local request = { pending = {}, index = 1, received = 0, done = false }
  session.request = request
  update(session, "debounce")
  return function(cb)
    request.async = ctx.async
    local function current()
      return not session.closed and not request.cancelled and session.generation == generation and not ctx.picker.closed
    end
    local function abort()
      if request.timer then
        pcall(request.timer.stop, request.timer)
        pcall(request.timer.close, request.timer)
        request.timer = nil
      end
      request.cancelled = true
      if request.job then
        request.job.cancel("finder-aborted")
      end
    end
    ctx.async:on("abort", abort)
    ctx.async:on("error", abort)
    request.timer = uv.new_timer()
    if not request.timer then
      ctx.async:schedule(function()
        update(session, "error", "timer-unavailable")
      end)
      return
    end
    local elapsed = false
    request.timer:start(150, 0, function()
      vim.schedule(function()
        if request.timer then
          pcall(request.timer.close, request.timer)
          request.timer = nil
        end
        elapsed = true
        if current() then
          ctx.async:resume()
        end
      end)
    end)
    while not elapsed and current() do
      ctx.async:suspend()
    end
    if not current() then
      return
    end
    local previous = session.last_job
    if previous and not previous.finished then
      previous.when_done(function()
        if current() then
          ctx.async:resume()
        end
      end)
      while not previous.finished and current() do
        ctx.async:suspend()
      end
    end
    if not current() then
      return
    end
    ctx.async:schedule(function()
      if not current() then
        return
      end
      if not source_valid(session.owner) then
        stale(session)
        return
      end
      update(session, "running")
      request.job = process.start({
        text = session.snapshot.text,
        lines = session.snapshot.lines,
        query = query,
        modes = session.modes,
        limits = session.limits,
      }, {
        on_items = function(rows)
          if not current() then
            return
          end
          if not source_valid(session.owner) then
            stale(session)
            return
          end
          for _, row in ipairs(rows) do
            row.buf, row.pos, row.generation, row.owner_id =
              session.owner.buf, { row.lnum, row.col }, generation, session.id
            request.received = request.received + 1
            request.pending[request.received] = row
          end
          session.count = request.received
          update(session, "running")
          ctx.async:resume()
        end,
        on_done = function(result)
          request.done = true
          if not current() then
            return
          end
          if not source_valid(session.owner) then
            stale(session)
            return
          end
          if result.state == "error" then
            request.pending, request.index, request.received = {}, 1, 0
            session.count = 0
            result = vim.tbl_extend("force", result, { count = 0 })
            -- Already delivered rows must not survive an invalid/zero-width query.
            vim.schedule(function()
              if current() then
                ctx.picker.finder.items = {}
                ctx.picker.matcher:run(ctx.picker)
                ctx.picker:update()
              end
            end)
          end
          update(session, result.state, result.reason, result)
          ctx.async:resume()
        end,
      })
      session.last_job = request.job
    end)
    while current() and (not request.done or request.index <= request.received) do
      while request.index <= request.received and current() do
        local row = request.pending[request.index]
        request.pending[request.index], request.index = nil, request.index + 1
        cb(row)
      end
      if not request.done and current() then
        ctx.async:suspend()
      end
    end
  end
end

local function confirm(session, picker, row)
  if picker.closed then
    return
  end
  if picker.input:get() ~= session.query then
    picker:find()
    return
  end
  if
    not row
    or row.owner_id ~= session.id
    or row.generation ~= session.generation
    or not source_valid(session.owner)
    or session.state == "error"
    or session.state == "stale"
  then
    stale(session)
    vim.notify("查找结果已失效，请按 F5 刷新", vim.log.levels.WARN)
    return
  end
  picker:norm(function()
    if picker.closed then
      return
    end
    if picker.input:get() ~= session.query then
      picker:find()
      return
    end
    if not source_valid(session.owner) or row.owner_id ~= session.id or row.generation ~= session.generation then
      stale(session)
      return
    end
    local closed = pcall(picker.close, picker)
    if
      not closed
      or not source_valid(session.owner)
      or vim.api.nvim_get_current_win() ~= session.owner.win
      or picker.input:get() ~= session.query
      or row.owner_id ~= session.id
      or row.generation ~= session.generation
    then
      vim.notify("源文档或位置已改变，跳转已取消", vim.log.levels.WARN)
      return
    end
    local owner = session.owner
    if not source_valid(owner) then
      return
    end
    vim.cmd("normal! m'")
    vim.api.nvim_win_set_cursor(owner.win, { row.lnum, row.col })
    vim.cmd("normal! zz")
  end)
end

function M.open(opts)
  opts = opts or {}
  if active and active.picker and not active.picker.closed then
    active.picker:close()
  end
  local owner = {
    win = vim.api.nvim_get_current_win(),
    tab = vim.api.nvim_get_current_tabpage(),
    buf = vim.api.nvim_get_current_buf(),
  }
  owner.path = vim.api.nvim_buf_get_name(owner.buf)
  local limits = vim.tbl_extend("force", process.limits, opts.limits or {})
  local snapshot, err = M.snapshot(owner, limits)
  if not snapshot then
    vim.notify(reasons[err] or err, vim.log.levels.WARN)
    return nil
  end
  local function toggle(key)
    return function(picker)
      local session = session_for(picker)
      session.modes[key] = not session.modes[key]
      picker:find()
    end
  end
  local function refresh(picker)
    local session = session_for(picker)
    local source = session.owner
    local fresh, reason = M.snapshot(source, session.limits)
    if not fresh then
      update(session, "stale", reason)
      cancel_request(session, reason)
      return
    end
    session.snapshot, session.initial_error, source.tick, source.cursor = fresh, nil, fresh.tick, fresh.cursor
    picker:find()
  end
  local function cancel(picker)
    if picker.closed then
      return
    end
    picker:norm(function()
      if not picker.closed then
        picker:close()
      end
    end)
  end
  local keys = {
    ["<a-c>"] = { "document_find_case", mode = { "n", "i" } },
    ["<a-w>"] = { "document_find_word", mode = { "n", "i" } },
    ["<a-r>"] = { "document_find_regex", mode = { "n", "i" } },
    ["<F5>"] = { "document_find_refresh", mode = { "n", "i" } },
    ["<Esc>"] = { "document_find_cancel", mode = { "n", "i" } },
    ["<C-c>"] = { "document_find_cancel", mode = { "n", "i" } },
    ["<C-g>"] = { "document_find_single_document", mode = { "n", "i" } },
    ["<C-q>"] = { "document_find_single_document", mode = { "n", "i" } },
    ["<C-s>"] = { "document_find_single_document", mode = { "n", "i" } },
    ["<C-t>"] = { "document_find_single_document", mode = { "n", "i" } },
    ["<C-v>"] = { "paste_clipboard", mode = { "n", "i" } },
    ["<M-v>"] = { "document_find_single_document", mode = { "n", "i" } },
    ["<a-v>"] = { "document_find_single_document", mode = { "n", "i" } },
    ["<S-CR>"] = { "document_find_single_document", mode = { "n", "i" } },
  }
  local picker = require("snacks").picker.pick({
    source = "ue_document_find",
    title = "文档查找",
    live = true,
    search = opts.text or "",
    document_find_limits = limits,
    finder = function(options, ctx)
      return finder(session_for(ctx.picker), options, ctx)
    end,
    format = function(item)
      return {
        { ("%d:%d "):format(item.lnum, item.col + 1), "SnacksPickerLineNr" },
        { item.text:sub(1, item.from) },
        { item.text:sub(item.from + 1, item.to), "Search" },
        { item.text:sub(item.to + 1) },
      }
    end,
    preview = function(ctx)
      local session = session_for(ctx.picker)
      local source = session.owner
      if
        not source_valid(source)
        or ctx.item.owner_id ~= session.id
        or ctx.item.generation ~= session.generation
        or ctx.picker.input:get() ~= session.query
      then
        ctx.preview:notify("源文档已改变，请按 F5 刷新", "warn")
        return
      end
      ctx.preview:set_buf(source.buf)
      ctx.preview:set_title(
        "内存文档 · " .. (source.path ~= "" and vim.fn.fnamemodify(source.path, ":t") or "[未命名]")
      )
      vim.api.nvim_win_set_cursor(ctx.win, ctx.item.pos)
      vim.api.nvim_win_call(ctx.win, function()
        vim.fn.clearmatches()
        vim.fn.matchaddpos("Search", { { ctx.item.lnum, ctx.item.col + 1, ctx.item.end_col - ctx.item.col } })
        vim.cmd("normal! zz")
      end)
    end,
    main = { current = true },
    layout = { preset = "telescope", preview = true },
    matcher = { fuzzy = false, ignorecase = false, smartcase = false, sort_empty = false },
    sort = { fields = { "idx" } },
    filter = {
      transform = function(p, filter)
        filter.search, filter.pattern = p.input:get(), ""
      end,
    },
    actions = {
      document_find_case = toggle("case_sensitive"),
      document_find_word = toggle("whole_word"),
      document_find_regex = toggle("regex"),
      document_find_refresh = refresh,
      document_find_cancel = cancel,
      document_find_single_document = function()
        vim.notify("当前文档查找使用 Enter 跳转，F5 刷新", vim.log.levels.INFO)
      end,
    },
    win = { input = { keys = keys }, list = { keys = keys } },
    confirm = function(p, row)
      confirm(session_for(p), p, row)
    end,
    on_show = function(p)
      local session = session_for(p)
      attach_input(session, p)
      update(session, session.state, session.reason)
    end,
    on_close = function(p)
      local session = sessions[p]
      if not session then
        return
      end
      p.init_opts.document_find_modes = vim.deepcopy(session.modes)
      p.input.filter.search = p.input:get()
      close(session)
    end,
  })
  return picker
end

return M
