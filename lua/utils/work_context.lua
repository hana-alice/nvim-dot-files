-- Named investigations persist metadata, never editor text or native IDs.
-- The Workbench reads cached models; disk access belongs to explicit actions.
local M = {}
local api = vim.api
local recipes = require("utils.search_recipe")
local cache, aliases, last_key, instance = {}, {}, nil, {}

local function changed()
  pcall(api.nvim_exec_autocmds, "User", { pattern = "UEWorkbenchChanged", modeline = false })
end

local function path_key(path)
  return require("utils.platform").driver().path_key(vim.fs.normalize(tostring(path or "")))
end

local function raw_key(project)
  if project == nil then
    return last_key
  end
  local root = project.root or project.project_root or project.engine_root
  if type(root) ~= "string" or root == "" then
    return nil
  end
  return table.concat({
    path_key(root),
    path_key(project.identity or project.uproject or root),
    path_key(project.engine or project.engine_root or ""),
  }, "\0")
end

local function key(project)
  local id = raw_key(project)
  return aliases[id] or id
end

local function selection_generation()
  local hub = require("utils.ue_hub")
  return hub.selection_generation and hub.selection_generation() or 0
end

local function bucket(project)
  local id = key(project)
  if not id then
    return nil
  end
  if not cache[id] then
    cache[id] = { project = vim.deepcopy(project), cards = {}, refs = {}, state = "unloaded", epoch = 0, selection = 0 }
  end
  return cache[id], id
end

local function ordinary(win)
  return type(win) == "number"
    and api.nvim_win_is_valid(win)
    and api.nvim_win_get_config(win).relative == ""
    and vim.bo[api.nvim_win_get_buf(win)].buftype == ""
    and vim.b[api.nvim_win_get_buf(win)].ue_bottom_panel_kind == nil
end

function M.source(win)
  win = win or api.nvim_get_current_win()
  if not ordinary(win) then
    return nil, "请从普通编辑窗口操作调查。"
  end
  local buf = api.nvim_win_get_buf(win)
  return {
    win = win,
    tab = api.nvim_win_get_tabpage(win),
    buf = buf,
    name = api.nvim_buf_get_name(buf),
    tick = api.nvim_buf_get_changedtick(buf),
    cursor = api.nvim_win_get_cursor(win),
    project_generation = selection_generation(),
  }
end

function M.owned(source)
  return source
    and ordinary(source.win)
    and api.nvim_buf_is_loaded(source.buf)
    and api.nvim_get_current_win() == source.win
    and api.nvim_get_current_tabpage() == source.tab
    and api.nvim_win_get_tabpage(source.win) == source.tab
    and api.nvim_win_get_buf(source.win) == source.buf
    and api.nvim_buf_get_name(source.buf) == source.name
    and api.nvim_buf_get_changedtick(source.buf) == source.tick
    and vim.deep_equal(api.nvim_win_get_cursor(source.win), source.cursor)
    and source.project_generation == selection_generation()
end

function M.project(opts)
  opts = opts or {}
  local function resolve(project)
    local canonical = recipes.context({
      project_root = project.root or project.project_root,
      uproject = project.identity or project.uproject,
      engine_root = project.engine or project.engine_root,
    })
    local original = raw_key(project)
    if original then
      aliases[original] = raw_key(canonical)
    end
    return canonical
  end
  if opts.project then
    return resolve(opts.project)
  end
  local win = opts.source_win or api.nvim_get_current_win()
  if not ordinary(win) then
    return nil, "请先选择普通编辑窗口。"
  end
  return api.nvim_win_call(win, function()
    local ok, ue = pcall(require, "ue")
    local ctx
    if ok and type(ue.resolve_context) == "function" then
      local resolved, value = pcall(ue.resolve_context)
      if resolved then
        ctx = value
      end
    end
    return resolve(ctx or { project_root = vim.uv.cwd() })
  end)
end

local function fingerprint(path)
  local stat = vim.uv.fs_stat(path)
  if not stat or stat.type ~= "file" then
    return nil
  end
  local mtime = vim.tbl_get(stat, "mtime")
  if type(mtime) ~= "table" then
    return nil
  end
  return { size = stat.size, mtime_sec = mtime.sec, mtime_nsec = mtime.nsec }
end

local function named(path)
  return type(path) == "string" and path ~= "" and not path:find("[%z\r\n]") and not path:match("^%a[%w+.-]*://")
end

local function file_from(entry)
  local buf, win
  if type(entry) == "number" then
    buf = entry
  elseif type(entry) == "table" then
    buf, win = entry.buf, entry.win
  end
  if not buf or not api.nvim_buf_is_loaded(buf) or vim.bo[buf].buftype ~= "" then
    return nil, "关联文件必须是已载入的普通文件缓冲区。"
  end
  local name = api.nvim_buf_get_name(buf)
  if not named(name) then
    return nil, "未命名文档或 URI 不能作为调查文件；请先命名。"
  end
  if not win then
    for _, candidate in ipairs(api.nvim_tabpage_list_wins(0)) do
      if ordinary(candidate) and api.nvim_win_get_buf(candidate) == buf then
        win = candidate
        break
      end
    end
  end
  local pos = win and api.nvim_win_get_cursor(win) or { 1, 0 }
  if type(entry) == "table" then
    pos = { entry.line or pos[1], entry.col and entry.col - 1 or pos[2] }
  end
  local path = recipes.canonical(name)
  return { path = path, line = pos[1], col = pos[2] + 1, modified = vim.bo[buf].modified, disk = fingerprint(path) }, {
    buf = buf,
    name = name,
    tick = api.nvim_buf_get_changedtick(buf),
  }
end

local function current_result(project, explicit_search)
  local qf = vim.fn.getqflist({ id = 0, changedtick = 0, context = 0, size = 0 })
  if not qf.id or qf.id == 0 or qf.size == 0 then
    return nil, nil
  end
  local context = type(qf.context) == "table" and qf.context or {}
  local recipe = context.recipe and recipes.validate(context.recipe) or nil
  local matching = recipe and key(recipe.project) == key(project)
  if matching and explicit_search then
    matching = vim.deep_equal(recipe, explicit_search)
  end
  local verification = context.verification_id
  if verification ~= nil then
    local runs = package.loaded["utils.verification_runs"]
    local run = type(verification) == "number" and runs and runs.get(verification)
    if
      not run
      or path_key(run.project_root) ~= path_key(project.root)
      or run.qf_id ~= qf.id
      or run.qf_tick ~= qf.changedtick
    then
      return nil, nil
    end
    if not matching and not explicit_search then
      matching = true
    end
  end
  if not matching then
    return nil, nil
  end
  return recipe, { id = qf.id, tick = qf.changedtick, verification_id = verification }
end

--- Capture only explicitly selected or currently visible files in this tab.
--- The returned source/live tables are process-local; save passes only draft.
function M.capture(opts)
  opts = opts or {}
  local source, err = M.source(opts.source_win)
  if not source then
    return nil, err
  end
  if not named(source.name) then
    return nil, "当前文档尚未命名；请先命名再保存调查。"
  end
  local project
  project, err = M.project({ source_win = source.win, project = opts.project })
  if not project then
    return nil, err
  end
  local selected = opts.files or {}
  if not opts.files then
    for _, win in ipairs(api.nvim_tabpage_list_wins(source.tab)) do
      if ordinary(win) then
        selected[#selected + 1] = { buf = api.nvim_win_get_buf(win), win = win }
      end
    end
  end
  local files, refs, seen = {}, {}, {}
  local entries = { { buf = source.buf, win = source.win } }
  vim.list_extend(entries, selected)
  for _, entry in ipairs(entries) do
    local file, ref = file_from(entry)
    if not file then
      return nil, ref
    end
    local identity = path_key(file.path)
    if not seen[identity] then
      if #files == 32 then
        return nil, "调查最多关联 32 个文件；请显式缩小范围。"
      end
      seen[identity], refs[identity] = true, ref
      files[#files + 1] = file
    end
  end
  local search
  if opts.search then
    search, err = recipes.validate(opts.search)
    if not search or key(search.project) ~= key(project) then
      return nil, err or "查询属于其他工程。"
    end
  end
  local current_search, result = current_result(project, search)
  search = search or current_search
  return {
    project = project,
    source = source,
    draft = {
      name = opts.name or "",
      note = opts.note or "",
      files = files,
      active = 1,
      search = search,
      has_result = result ~= nil,
    },
    live = { files = refs, result = result },
  }
end

local function model(state, card)
  local copy = vim.deepcopy(card)
  copy.project = vim.deepcopy(state.project)
  return copy
end

function M.rows(project)
  local state = cache[key(project)]
  local cards = {}
  if state then
    for _, card in ipairs(state.cards) do
      cards[#cards + 1] = model(state, card)
    end
  end
  return cards
end

function M.status(project)
  local state = cache[key(project)]
  if not state then
    return { state = "unloaded", loaded = false, known = 0 }
  end
  return {
    state = state.state,
    loaded = state.loaded == true,
    error = state.error,
    count = state.loaded and #state.cards or nil,
    known = #state.cards,
  }
end

function M.active(target)
  local state = cache[key(target)]
  if state then
    for _, card in ipairs(state.cards) do
      if card.id == state.active then
        return model(state, card)
      end
    end
  end
end

function M.get(value, opts)
  opts = opts or {}
  local project = opts.project or (type(value) == "table" and value.project or nil)
  local state = cache[key(project)]
  local id = type(value) == "table" and value.id or value
  if not state then
    return nil, "调查列表尚未读取；请先打开继续调查。"
  end
  for _, card in ipairs(state.cards) do
    if card.id == id then
      if type(value) == "table" and value.revision ~= card.revision then
        return nil, "调查版本已变化；请刷新元数据。"
      end
      return model(state, card), state
    end
  end
  return nil, "调查已删除或不在此工程；请刷新元数据。"
end

function M.select(value, opts)
  local card, state = M.get(value, opts)
  if not card then
    return nil, state
  end
  state.active, state.selection = card.id, state.selection + 1
  last_key = key(state.project)
  changed()
  return card
end

function M.refresh(project, done)
  done = done or function() end
  local state = bucket(project)
  if not state then
    done(nil, "没有可读取的工程调查。")
    return false
  end
  state.epoch, state.state, state.error = state.epoch + 1, "loading", nil
  changed()
  local epoch = state.epoch
  require("utils.work_context_store").load(project, function(cards, err)
    if state.epoch ~= epoch then
      done(nil, "调查缓存已有更新；请再次刷新。")
      return
    end
    if not cards then
      state.state, state.error = "error", err
      changed()
      done(nil, err)
      return
    end
    state.cards, state.loaded, state.state, state.error = vim.deepcopy(cards), true, "ready", nil
    local revisions, active = {}, false
    for _, card in ipairs(cards) do
      revisions[card.id] = card.revision
      active = active or card.id == state.active
    end
    for id, ref in pairs(state.refs) do
      if revisions[id] ~= ref.revision then
        state.refs[id] = nil
      end
    end
    if not active then
      state.active = nil
    end
    changed()
    done(M.rows(project))
  end)
  return true
end

local function valid_result(result)
  if not result then
    return false
  end
  local info = vim.fn.getqflist({ id = result.id, changedtick = 0, context = 0 })
  local context = type(info.context) == "table" and info.context or {}
  return info.id == result.id
    and info.changedtick == result.tick
    and (not result.verification_id or context.verification_id == result.verification_id)
end

function M.save(capture, opts, done)
  opts, done = opts or {}, done or function() end
  if type(capture) ~= "table" or not capture.project or not capture.draft then
    done(nil, "没有可保存的调查快照。")
    return false
  end
  local state = bucket(capture.project)
  if not state then
    done(nil, "调查工程无效。")
    return false
  end
  local selection = state.selection
  state.epoch = state.epoch + 1
  require("utils.work_context_store").save(capture.project, capture.draft, opts, function(card, err)
    if not card then
      state.error = err
      if state.state == "loading" then
        state.state = state.loaded and "ready" or (#state.cards > 0 and "cached" or "unloaded")
      end
      changed()
      done(nil, err)
      return
    end
    local live = capture.live
    if capture.renew then
      local old = state.refs[card.id]
      if
        old == capture.renew
        and old.instance == instance
        and old.revision == opts.expected_revision
        and valid_result(old.result)
      then
        live = { files = old.files, result = old.result }
      else
        live = nil
      end
    end
    state.epoch, state.error = state.epoch + 1, nil
    local replaced = false
    for index, old in ipairs(state.cards) do
      if old.id == card.id then
        state.cards[index], replaced = vim.deepcopy(card), true
        break
      end
    end
    if not replaced then
      table.insert(state.cards, 1, vim.deepcopy(card))
    end
    state.state = state.loaded and "ready" or "cached"
    state.refs[card.id] = live
        and { revision = card.revision, instance = instance, files = live.files, result = live.result }
      or nil
    -- A completed write is not authority to reactivate an older investigation.
    if state.selection == selection and M.owned(capture.source) then
      state.active, state.selection = card.id, state.selection + 1
      last_key = key(capture.project)
    end
    changed()
    done(model(state, card))
  end)
  return true
end

local function draft_of(card)
  local draft = {}
  for _, name in ipairs({ "name", "note", "files", "active", "search", "has_result" }) do
    draft[name] = vim.deepcopy(card[name])
  end
  return draft
end

function M.update(value, changes, opts, done)
  local card, state = M.get(value, opts)
  if not card then
    (done or function() end)(nil, state)
    return false
  end
  local draft = draft_of(card)
  for name, data in pairs(changes) do
    draft[name] = vim.deepcopy(data)
  end
  -- Only our successful CAS may renew an unchanged historical association.
  -- External revisions and explicit search reassociation never borrow it.
  local old = state.refs[card.id]
  local renew = changes.search == nil
      and changes.has_result == nil
      and old
      and old.revision == card.revision
      and old.instance == instance
      and valid_result(old.result)
      and old
    or nil
  return M.save(
    { project = card.project, draft = draft, renew = renew },
    { id = card.id, expected_revision = card.revision },
    done
  )
end

function M.append_current(opts, done)
  opts = opts or {}
  if not done then
    return require("utils.work_context_ui").append_current(opts)
  end
  local project, err = M.project(opts)
  if not project then
    done(nil, err)
    return false
  end
  local card, card_state = M.get(opts.card or M.active(project), { project = project })
  if not card then
    done(nil, card_state)
    return false
  end
  local source
  source, err = M.source(opts.source_win)
  if not source then
    done(nil, err)
    return false
  end
  local file, file_info = file_from({ buf = source.buf, win = source.win })
  if not file then
    done(nil, file_info)
    return false
  end
  local files, active = vim.deepcopy(card.files), nil
  for index, old in ipairs(files) do
    if path_key(old.path) == path_key(file.path) then
      files[index], active = file, index
      break
    end
  end
  if not active then
    if #files == 32 then
      done(nil, "调查最多关联 32 个文件。")
      return false
    end
    files[#files + 1], active = file, #files + 1
  end
  return M.update(card, { files = files, active = active }, {}, done)
end

function M.edit_note(opts, done)
  opts = opts or {}
  if opts.note == nil then
    return require("utils.work_context_ui").edit_note(opts)
  end
  local card = opts.card or M.active(opts.project)
  return M.update(card, { note = opts.note }, opts, done)
end

function M.associate_search(opts, done)
  opts = opts or {}
  if not opts.recipe then
    return require("utils.work_context_ui").associate_search(opts)
  end
  local card, err = M.get(opts.card or M.active(opts.project), opts)
  if not card then
    (done or function() end)(nil, err)
    return false
  end
  local recipe
  recipe, err = recipes.validate(opts.recipe)
  if not recipe or key(recipe.project) ~= key(card.project) then
    (done or function() end)(nil, err or "查询属于其他工程。")
    return false
  end
  return M.update(card, { search = recipe, has_result = false }, {}, done)
end

function M.delete(value, opts, done)
  done = done or function() end
  local card, state = M.get(value, opts)
  if not card then
    done(nil, state)
    return false
  end
  require("utils.work_context_store").delete(card.project, card.id, card.revision, function(ok, err)
    if not ok then
      done(nil, err)
      return
    end
    state.epoch = state.epoch + 1
    for index, old in ipairs(state.cards) do
      if old.id == card.id then
        table.remove(state.cards, index)
        break
      end
    end
    state.refs[card.id] = nil
    state.state, state.error = state.loaded and "ready" or (#state.cards > 0 and "cached" or "unloaded"), nil
    if state.active == card.id then
      state.active, state.selection = nil, state.selection + 1
    end
    changed()
    done(true)
  end)
  return true
end

function M.result_status(value, opts)
  local card, state = M.get(value, opts)
  if not card then
    return nil, state
  end
  local ref = state.refs[card.id]
  if not ref or ref.instance ~= instance or ref.revision ~= card.revision or not ref.result then
    return nil, "原结果仅在保存它的实例和调查版本内可用；请显式运行关联查询。"
  end
  if not valid_result(ref.result) then
    return nil, "原结果已修改或被淘汰；未使用当前或最近的其他结果。"
  end
  return vim.deepcopy(ref.result)
end

function M.show_result(value, opts)
  local ref, err = M.result_status(value, opts)
  if not ref then
    return nil, err
  end
  local win
  win, err = require("utils.workspace").activate({ kind = "result", id = ref.id }, opts)
  local current = vim.fn.getqflist({ id = 0, changedtick = 0 })
  if win and (current.id ~= ref.id or current.changedtick ~= ref.tick) then
    return nil, "打开期间结果选择已变化；保留了新选择。"
  end
  return win, err
end

function M.run_search(value, opts)
  opts = opts or {}
  local card, err = M.get(value, opts)
  if not card or not card.search then
    return nil, err or "调查没有完整查询条件；请先显式关联。"
  end
  local project
  project, err = M.project(opts)
  if not project or key(project) ~= key(card.project) then
    return nil, err or "请先显式切回调查的原工程。"
  end
  local source
  source, err = M.source(opts.source_win)
  if not source then
    return nil, err
  end
  api.nvim_set_current_win(source.win)
  if not M.owned(source) then
    return nil, "编辑窗口选择已变化；本次未启动查询。"
  end
  return recipes.run(card.search)
end

--- Restore one saved file in a new tab, keeping the interrupted tab untouched.
function M.restore(value, opts)
  opts = opts or {}
  local card, state = M.get(value, opts)
  if not card then
    return nil, state
  end
  local project, err = M.project(opts)
  if not project or key(project) ~= key(card.project) then
    return nil, err or "请先显式切回调查的原工程；不会自动切换目标。"
  end
  local file = card.files[opts.file or card.active]
  if not file then
    return nil, "调查没有所选文件。"
  end
  local ref = state.refs[card.id]
  local original = ref and ref.revision == card.revision and ref.files and ref.files[path_key(file.path)]
  local win, notice, restored = require("utils.work_context_restore").restore(file, {
    disk = fingerprint(file.path),
    original = original,
  }, {
    ordinary = ordinary,
    source = M.source,
    owned = M.owned,
    generation = selection_generation,
  })
  if win then
    M.select(card)
  end
  return win, notice, restored
end

function M.details(value, opts)
  return require("utils.work_context_ui").details(value, opts)
end

function M.model(value, opts)
  return require("utils.work_context_ui").model(value, opts)
end

function M.open(opts)
  return require("utils.work_context_ui").open(opts)
end

function M.prompt_save(opts)
  return require("utils.work_context_ui").prompt_save(opts)
end

function M.setup()
  api.nvim_create_user_command("UEWorkContext", function(args)
    local action = args.args ~= "" and args.args or "list"
    if action == "save" then
      M.prompt_save()
    elseif action == "add" then
      M.append_current()
    elseif action == "note" then
      M.edit_note()
    elseif action == "search" then
      M.associate_search()
    elseif action == "list" then
      M.open()
    else
      vim.notify("UEWorkContext: save/list/add/note/search", vim.log.levels.WARN)
    end
  end, {
    nargs = "?",
    complete = function()
      return { "save", "list", "add", "note", "search" }
    end,
    desc = "保存与继续具名调查（仅元数据）",
    force = true,
  })
end

function M._reset_for_test()
  cache, aliases, last_key, instance = {}, {}, nil, {}
end

return M
