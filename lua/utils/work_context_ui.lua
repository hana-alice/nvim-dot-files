-- Explicit investigation actions over cached metadata and native live owners.
local M = {}
local api = vim.api
local views, request = {}, 0

local function core()
  return require("utils.work_context")
end

local function notify(message, level)
  vim.notify(message or "调查操作未完成。", level or vim.log.levels.WARN, { title = "调查现场" })
end

local function clean(value)
  return tostring(value or ""):gsub("[%z\1-\31\127]", " ")
end

local function enter(source)
  if not source or not api.nvim_win_is_valid(source.win) then
    return false
  end
  if api.nvim_get_current_win() ~= source.win then
    api.nvim_set_current_win(source.win)
  end
  return core().owned(source)
end

local function saved(card, err)
  if not card then
    notify(err)
    return
  end
  notify(
    "已保存调查「" .. clean(card.name) .. "」；只保存元数据，没有保存文件文本。",
    vim.log.levels.INFO
  )
end

function M.prompt_save(opts)
  opts = opts or {}
  local capture, err = core().capture(opts)
  if not capture then
    notify(err)
    return nil, err
  end
  if not enter(capture.source) then
    notify("来源已变化；请重新保存调查。")
    return nil
  end
  request = request + 1
  local ticket = request
  local function current()
    return request == ticket and core().owned(capture.source)
  end
  local function commit(note)
    if note == nil or not current() then
      return
    end
    capture.draft.note = note
    core().save(capture, {}, saved)
  end
  local function name(value)
    if value == nil or not current() then
      return
    end
    if vim.trim(value) == "" then
      notify("调查名称不能为空；本次未保存。")
      return
    end
    capture.draft.name = value
    if opts.note ~= nil then
      commit(opts.note)
    else
      require("utils.document_location").input({ prompt = "下一步备注（单行；可留空）" }, commit)
    end
  end
  if opts.name ~= nil then
    name(opts.name)
    return true
  end
  return require("utils.document_location").input({
    prompt = ("保存调查名称 · %d 个明确关联文件 · 不含未保存文本"):format(#capture.draft.files),
  }, name)
end

local function source_for(opts)
  opts = opts or {}
  return core().source(opts.source_win)
end

local function finish_picker(picker, source, callback)
  picker:norm(function()
    if picker.closed then
      return
    end
    picker:close()
    vim.schedule(function()
      if not core().owned(source) then
        notify("编辑来源或选择已变化；未继续调查操作。")
        return
      end
      callback()
    end)
  end)
end

function M.open(opts)
  opts = opts or {}
  local source, err = source_for(opts)
  if not source then
    notify(err)
    return nil, err
  end
  local project
  project, err = core().project({ source_win = source.win, project = opts.project })
  if not project then
    notify(err)
    return nil, err
  end
  if not enter(source) then
    notify("编辑来源已变化。")
    return nil
  end
  request = request + 1
  local ticket = request
  return core().refresh(project, function(cards, load_err)
    if ticket ~= request or not core().owned(source) then
      return
    end
    if not cards then
      notify(load_err)
      return
    end
    if #cards == 0 then
      notify("此工程没有已保存调查；使用保存当前调查入口。", vim.log.levels.INFO)
      return
    end
    local items = {}
    for _, card in ipairs(cards) do
      items[#items + 1] = {
        text = clean(card.name) .. " · " .. #card.files .. " 文件 · " .. clean(card.note),
        card = card,
        preview = {
          text = table.concat({
            clean(card.name),
            "下一步：" .. clean(card.note),
            "选择后只打开活动文件；查询和原结果须显式操作。",
          }, "\n"),
          ft = "markdown",
        },
      }
    end
    require("snacks").picker({
      source = "ue_work_context",
      title = "继续具名调查 · Enter 打开活动文件",
      items = items,
      main = { current = true },
      format = "text",
      preview = "preview",
      layout = "select",
      confirm = function(picker, item)
        item = item or picker:current()
        if not item then
          return
        end
        local selected = item.card
        finish_picker(picker, source, function()
          local card, stale = core().get(selected)
          if not card then
            notify(stale)
            return
          end
          if opts.on_select then
            opts.on_select(card)
            return
          end
          if opts.details_only then
            core().details(card, { source_win = source.win })
            return
          end
          local win, restore_err, restored = core().restore(card, { project = project, source_win = source.win })
          if restore_err then
            notify(restore_err)
          end
          if win then
            if core().owned(restored) then
              core().details(card, { source_win = win })
            end
          elseif core().owned(source) then
            core().details(card, { source_win = source.win })
          end
        end)
      end,
    })
  end)
end

function M.model(value, opts)
  local card, err = core().get(value, opts)
  if not card then
    return nil, err
  end
  local lines, actions = {}, {}
  local function add(text, action)
    lines[#lines + 1] = text
    if action then
      actions[#lines] = action
    end
  end
  add("调查现场 · " .. clean(card.name))
  add("Enter 执行当前行 · r 只刷新元数据 · dd 删除调查元数据 · q 关闭视图")
  add("版本 " .. card.revision .. "；历史坐标不是当前代码已验证的证据。")
  add("")
  add("下一步：" .. clean(card.note))
  add("  > 编辑下一步备注", { kind = "note" })
  add("  > 追加当前编辑窗口的文件（单窗口也可逐个关联）", { kind = "add" })
  add("")
  add("明确关联的文件 · 卡片不含文件文本；Enter 在新标签页打开所选文件")
  for index, file in ipairs(card.files) do
    add(
      ("  %s%s:%d:%d%s"):format(
        index == card.active and "> " or "",
        clean(file.path),
        file.line,
        file.col,
        file.modified and " [保存时未保存；跨重启仅磁盘内容]" or ""
      ),
      { kind = "file", file = index }
    )
  end
  add("")
  if card.search then
    add("关联查询：" .. clean(card.search.query))
    add("  " .. clean(require("utils.search_recipe").describe(card.search)))
    add(
      "  全词: "
        .. tostring(card.search.mode.word)
        .. " · 范围: "
        .. clean(table.concat(card.search.scope.roots, ", "))
    )
    for _, field in ipairs({ "include", "exclude", "extensions", "extra_globs" }) do
      add("  " .. field .. ": " .. clean(table.concat(card.search.filters[field], ", ")))
    end
    add(
      "  结果筛选: "
        .. clean(card.search.filters.pattern)
        .. " · hidden="
        .. tostring(card.search.filters.hidden)
        .. " ignored="
        .. tostring(card.search.filters.ignored)
        .. " follow="
        .. tostring(card.search.filters.follow)
    )
    add("  > 显式运行关联查询（新查询；不自动运行）", { kind = "search" })
  else
    add("未关联完整查询条件；不猜测最近一次搜索。")
  end
  add("  > 从本工程搜索历史显式关联完整条件", { kind = "associate" })
  if card.has_result then
    local available, unavailable = core().result_status(card)
    add(
      available and "  > 查看本实例的原结果（保存时的历史列表）"
        or "  > 原结果不可用：" .. clean(unavailable),
      { kind = "result" }
    )
  else
    add("没有关联原结果；跨重启不恢复原生列表 ID。")
  end
  return { card = card, lines = lines, actions = actions }
end

local function owned(view)
  return view
    and api.nvim_buf_is_valid(view.buf)
    and api.nvim_buf_get_name(view.buf) == view.name
    and api.nvim_buf_get_changedtick(view.buf) == view.tick
    and vim.bo[view.buf].readonly
    and not vim.bo[view.buf].modifiable
    and not vim.bo[view.buf].modified
end

local function render(view, model)
  vim.bo[view.buf].modifiable = true
  api.nvim_buf_set_lines(view.buf, 0, -1, false, model.lines)
  vim.bo[view.buf].modifiable, vim.bo[view.buf].readonly, vim.bo[view.buf].modified = false, true, false
  view.tick, view.model = api.nvim_buf_get_changedtick(view.buf), model
end

function M.details(value, opts)
  opts = opts or {}
  local model, err = M.model(value, opts)
  if not model then
    return nil, err
  end
  core().select(model.card)
  local tab = api.nvim_get_current_tabpage()
  local view = views[tab]
  if not owned(view) then
    local buf = api.nvim_create_buf(false, true)
    local name = "ue-context://" .. tab .. "/" .. buf
    api.nvim_buf_set_name(buf, name)
    vim.bo[buf].bufhidden, vim.bo[buf].filetype = "hide", "ue_work_context"
    vim.b[buf].ue_bottom_panel_kind = "context"
    view = { buf = buf, name = name }
    views[tab] = view
  end
  view.source_win = opts.source_win or (core().source() and api.nvim_get_current_win())
  render(view, model)
  local function refresh()
    if not owned(view) then
      notify("调查详情已被修改；请重新打开。")
      return
    end
    local revision = view.model.card
    core().refresh(revision.project, function(_, load_err)
      if load_err then
        notify(load_err)
        return
      end
      if not owned(view) or view.model.card.id ~= revision.id then
        return
      end
      local fresh, missing = M.model(revision.id, { project = revision.project })
      if fresh then
        render(view, fresh)
      else
        notify(missing)
      end
    end)
  end
  vim.keymap.set("n", "r", refresh, { buffer = view.buf, desc = "只刷新调查元数据" })
  vim.keymap.set("n", "<CR>", function()
    if not owned(view) then
      notify("调查详情已被修改。")
      return
    end
    local action = view.model.actions[api.nvim_win_get_cursor(0)[1]]
    if not action then
      return
    end
    local card, stale = core().get(view.model.card)
    if not card then
      notify(stale)
      return
    end
    local action_opts = { card = card, project = card.project, source_win = view.source_win }
    local result, action_err
    if action.kind == "file" then
      action_opts.file = action.file
      result, action_err = core().restore(card, action_opts)
    elseif action.kind == "result" then
      result, action_err = core().show_result(card, action_opts)
    elseif action.kind == "search" then
      result, action_err = core().run_search(card, action_opts)
    elseif action.kind == "note" then
      result, action_err = M.edit_note(action_opts)
    elseif action.kind == "add" then
      result, action_err = M.append_current(action_opts)
    elseif action.kind == "associate" then
      result, action_err = M.associate_search(action_opts)
    end
    if action_err then
      notify(action_err)
    elseif result == nil then
      notify("调查操作未完成；请刷新或检查来源编辑窗口。")
    end
  end, { buffer = view.buf, desc = "操作调查当前行" })
  vim.keymap.set("n", "dd", function()
    if not owned(view) then
      notify("调查详情已被修改。")
      return
    end
    local card = view.model.card
    core().delete(card, {}, function(ok, delete_err)
      if not ok then
        notify(delete_err)
        return
      end
      notify("已删除调查元数据；文件、缓冲区、结果与任务保留。", vim.log.levels.INFO)
      if owned(view) and view.model.card.id == card.id then
        render(view, {
          lines = { "调查元数据已删除。", "q 关闭此视图；文件和任务未停止。" },
          card = card,
          actions = {},
        })
      end
    end)
  end, { buffer = view.buf, desc = "删除调查元数据（不删除文件或停止任务）" })
  vim.keymap.set("n", "q", function()
    local win = api.nvim_get_current_win()
    if api.nvim_win_get_buf(win) == view.buf and #api.nvim_tabpage_list_wins(0) > 1 then
      api.nvim_win_close(win, false)
    end
  end, { buffer = view.buf, desc = "关闭调查视图" })
  return require("utils.bottom_panel").show("context", view.buf)
end

local function updated(card, err)
  if not card then
    notify(err)
    return
  end
  notify("调查元数据已更新；原结果仅在同实例且原列表仍匹配时保留。", vim.log.levels.INFO)
end

function M.append_current(opts)
  return core().append_current(opts or {}, updated)
end

function M.edit_note(opts)
  opts = opts or {}
  local card, err = core().get(opts.card or core().active(opts.project), opts)
  if not card then
    notify(err)
    return nil, err
  end
  local source, source_err = source_for(opts)
  if not source then
    notify(source_err)
    return nil, source_err
  end
  if not enter(source) then
    return nil, "编辑来源已变化。"
  end
  return require("utils.document_location").input(
    { prompt = "更新下一步备注（替换原备注；单行）" },
    function(value)
      if value == nil or not core().owned(source) then
        return
      end
      core().edit_note({ card = card, note = value }, updated)
    end
  )
end

function M.associate_search(opts)
  opts = opts or {}
  local card, err = core().get(opts.card or core().active(opts.project), opts)
  if not card then
    notify(err)
    return nil, err
  end
  local source, source_err = source_for(opts)
  if not source then
    notify(source_err)
    return nil, source_err
  end
  if not enter(source) then
    return nil, "编辑来源已变化。"
  end
  local history = require("utils.search_history_store")
  local entries, history_err = history.load(history.key(card.project))
  if history_err then
    notify(history_err)
    return nil, history_err
  end
  local items = {}
  for _, entry in ipairs(entries) do
    if entry.recipe then
      items[#items + 1] = { text = clean(entry.query), recipe = entry.recipe }
    end
  end
  if #items == 0 then
    return nil, "本工程历史没有完整查询条件；请先显式运行并保留搜索。"
  end
  return require("snacks").picker({
    source = "ue_work_context_search",
    title = "显式关联搜索 · 不运行查询",
    items = items,
    main = { current = true },
    format = "text",
    layout = "select",
    confirm = function(picker, item)
      item = item or picker:current()
      if not item then
        return
      end
      finish_picker(picker, source, function()
        core().associate_search({ card = card, recipe = item.recipe }, updated)
      end)
    end,
  })
end

return M
