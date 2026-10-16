-- Window roles keep external navigation out of a CodeDiff view's paired panes.
-- CodeDiff remains the owner of file selection and of its panel/aux buffers.
local M = {}
local api = vim.api
local tabs = {}
local roles = { code = true, panel = true, aux = true }
local groups, owners, history = {}, {}, {}
local normal_destination
local review_close_watch

local function normal(win, tab)
  return type(win) == "number" and win > 0 and api.nvim_win_is_valid(win)
    and api.nvim_win_get_tabpage(win) == tab and api.nvim_win_get_config(win).relative == ""
end

local function source_live(win, tab)
  return type(win) == "number" and win > 0 and api.nvim_win_is_valid(win) and api.nvim_win_get_tabpage(win) == tab
end

local function state(tab)
  if not api.nvim_tabpage_is_valid(tab) then tabs[tab] = nil; return nil end
  tabs[tab] = tabs[tab] or { windows = {} }
  for win in pairs(tabs[tab].windows) do
    if not normal(win, tab) then tabs[tab].windows[win] = nil end
  end
  return tabs[tab]
end

function M.register(win, role, opts)
  opts = opts or {}
  if not roles[role] then return nil, "Unknown window role" end
  if type(win) ~= "number" or not api.nvim_win_is_valid(win) then return nil, "Window is unavailable" end
  local tab = opts.tab or api.nvim_win_get_tabpage(win)
  if not normal(win, tab) then return nil, "Window is outside this tab or floating" end
  state(tab).windows[win] = { role = role, owner = opts.owner }
  return win
end

function M.unregister(win)
  for _, s in pairs(tabs) do s.windows[win] = nil end
end

-- Discover only an already loaded owner; opening a picker must not load Git UI.
function M.sync_review(tab, session)
  tab = tab or api.nvim_get_current_tabpage()
  local s = state(tab)
  if not s then return nil end
  local lifecycle = package.loaded["codediff.ui.lifecycle"]
  session = session or (lifecycle and lifecycle.get_session(tab))
  local members = {}
  s.anchor = nil
  if session then
    local original, modified = session.original_win, session.modified_win
    if lifecycle and lifecycle.get_windows and (not original or not modified) then
      local a, b = lifecycle.get_windows(tab)
      original, modified = original or a, modified or b
    end
    local panel = session.panel and session.panel.view
    s.anchor = normal(modified, tab) and modified or (normal(original, tab) and original or nil)
    for _, win in pairs({ original = original, modified = modified, result = session.result_win }) do
      if normal(win, tab) then members[win] = "aux" end
    end
    if panel and normal(panel.winid, tab) then members[panel.winid] = "panel" end
  end
  for win, row in pairs(s.windows) do
    if row.owner == "codediff" and not members[win] then s.windows[win] = nil end
  end
  for win, role in pairs(members) do M.register(win, role, { tab = tab, owner = "codediff" }) end
  s.review = session ~= nil
  if session and M.track_review then M.track_review(tab, session) end
  return session
end

function M.is_review(tab)
  return M.sync_review(tab) ~= nil
end

local function code(win, tab, s)
  if not normal(win, tab) or vim.wo[win].winfixbuf then return false end
  local row = s.windows[win]
  if row and row.role ~= "code" then return false end
  local buf = api.nvim_win_get_buf(win)
  local ft = vim.bo[buf].filetype
  local bt = vim.bo[buf].buftype
  return (bt == "" or (row and row.role == "code" and bt == "nowrite")) and not vim.wo[win].diff
    and not ft:match("^snacks_picker") and not ft:match("^dap")
    and not ft:match("^codediff") and not vim.b[buf].ue_bottom_panel_kind
end

function M.is_code(win, tab)
  tab = tab or api.nvim_get_current_tabpage()
  local s = state(tab)
  if not s then return false end
  M.sync_review(tab)
  return code(win, tab, s) == true
end

function M.is_panel(win, tab)
  local s = state(tab or api.nvim_get_current_tabpage())
  local row = s and s.windows[win]
  return row and row.role == "panel" or false
end

function M.window_role(win, tab)
  tab = tab or api.nvim_win_get_tabpage(win)
  local s = state(tab)
  if not s or not normal(win, tab) then return "aux" end
  M.sync_review(tab)
  local row = s.windows[win]
  if row then return row.role, row.owner, true end
  return code(win, tab, s) and "code" or "aux", nil, false
end

function M.navigation_owner(tab)
  tab = tab or api.nvim_get_current_tabpage()
  local review = M.sync_review(tab)
  if review then return review, "review" end
  for index = #groups, 1, -1 do
    local group = groups[index]
    if group.tab == tab and group.kind == "debug" and (not group.valid or group.valid(group)) then
      return group.token, "debug"
    end
  end
end

function M.group_kind(tab)
  local _, kind = M.navigation_owner(tab)
  return kind or "normal"
end

function M.routes_to_normal(tab)
  return M.group_kind(tab) ~= "normal"
end

--- External review/debug navigation activates normal; read-only queries and
--- explicit route_to_normal=false keep the owner's source-window selection.
---@param opts? {tab?: integer, source_win?: integer, anchor?: integer, create?: boolean, route_to_normal?: boolean}
---@return integer? win, string? err
function M.resolve(opts)
  opts = opts or {}
  local tab = opts.tab or (opts.source_win and api.nvim_win_is_valid(opts.source_win)
    and api.nvim_win_get_tabpage(opts.source_win)) or api.nvim_get_current_tabpage()
  local s = state(tab)
  if not s then return nil, "Tab is unavailable" end
  M.sync_review(tab)
  if opts.route_to_normal ~= false and (opts.create ~= false or opts.route_to_normal == true)
    and M.routes_to_normal(tab) then
    return normal_destination(tab, opts.source_win or api.nvim_get_current_win(), opts.create == false)
  end
  for _, win in ipairs({ opts.source_win or api.nvim_get_current_win(), s.browser or 0 }) do
    if code(win, tab, s) then M.register(win, "code"); return win end
  end
  for _, win in ipairs(api.nvim_tabpage_list_wins(tab)) do
    if code(win, tab, s) then M.register(win, "code"); return win end
  end
  if opts.create == false or (not s.review and opts.create ~= true) then return nil, "No code window is available" end
  local anchor = opts.anchor or s.anchor
  if not normal(anchor, tab) then
    for _, win in ipairs(api.nvim_tabpage_list_wins(tab)) do
      if normal(win, tab) then anchor = win; break end
    end
  end
  if not normal(anchor, tab) then return nil, "No split anchor is available" end
  local handoff = require("utils.layout_handoff")
  local source = opts.source_win and api.nvim_win_is_valid(opts.source_win) and opts.source_win or api.nvim_get_current_win()
  local snapshot = handoff.capture(source)
  local buf = api.nvim_create_buf(true, false)
  local win, err = handoff.open_window(snapshot, buf, { split = "right", win = anchor })
  if not win then return nil, err end
  -- Window-local options/variables can be inherited from the split anchor.
  vim.wo[win].winfixbuf = false
  vim.wo[win].diff, vim.wo[win].scrollbind, vim.wo[win].cursorbind = false, false, false
  vim.w[win].codediff_restore = nil
  vim.w[win].snacks_main = true
  M.register(win, "code")
  s.browser = win
  return win
end

function M.focus(opts)
  local win, err = M.resolve(opts)
  if win then
    local handoff = require("utils.layout_handoff")
    local source = opts and opts.source_win
    if not source or not api.nvim_win_is_valid(source) then source = api.nvim_get_current_win() end
    local snapshot = handoff.capture(source)
    local ok, _, reason = handoff.handoff(snapshot, { win = win, tab = api.nvim_win_get_tabpage(win),
      buf = api.nvim_win_get_buf(win), code = true }, function() api.nvim_set_current_win(win) end)
    if not ok then return nil, reason end
  end
  return win, err
end

--- Shared file-open action. Custom Git/menu confirmations retain their owners.
function M.confirm(picker, item, action)
  return require("utils.layout_handoff").confirm(picker, item, action)
end

-- Layout management retains UI ownership only; business state stays with its
-- original owner. IDs and callbacks are never serialized across instances.
local next_group, active_group = 0, nil
local kinds = { normal = true, review = true, debug = true }

local function project(tab)
  return vim.t[tab].ue_layout_project or vim.g.ue_project_root or api.nvim_win_call(api.nvim_tabpage_get_win(tab), vim.fn.getcwd)
end

local function view_row(win, tab)
  if not normal(win, tab) then return nil end
  local buf = api.nvim_win_get_buf(win)
  local ft = vim.bo[buf].filetype
  if ft:match("^snacks_picker") then return nil end
  local registered = state(tab).windows[win]
  local role = registered and registered.role or (code(win, tab, state(tab)) and "code" or "panel")
  return { win = win, tab = tab, buf = buf, name = api.nvim_buf_get_name(buf), role = role,
    label = vim.b[buf].ue_bottom_panel_kind or (ft ~= "" and ft or role),
    panel = vim.b[buf].ue_bottom_panel_kind, view = api.nvim_win_call(win, vim.fn.winsaveview),
    width = api.nvim_win_get_width(win), height = api.nvim_win_get_height(win) }
end

local function retained(row)
  return api.nvim_buf_is_valid(row.buf) and api.nvim_buf_is_loaded(row.buf)
    and api.nvim_buf_get_name(row.buf) == row.name
end

local function live(row)
  return normal(row.win, row.tab) and retained(row) and api.nvim_win_get_buf(row.win) == row.buf
end

local function remember(group)
  if active_group and active_group ~= group.id then
    history[#history + 1] = active_group
    if #history > 32 then table.remove(history, 1) end
  end
  active_group = group.id
end

--- Owners register their actual UI token, not a copy of debugger/Git state.
--- callbacks: valid(group)->boolean,reason; focus/restore(group)->win,reason.
function M.register_group(kind, opts)
  opts = opts or {}
  if not kinds[kind] then return nil, "未知布局类型。" end
  local tab = opts.tab or api.nvim_get_current_tabpage()
  if not api.nvim_tabpage_is_valid(tab) then return nil, "布局 tab 已关闭。" end
  for _, group in ipairs(groups) do
    if group.kind == kind and group.tab == tab and group.token == opts.token then
      for key, value in pairs(opts) do group[key] = value end
      return group
    end
  end
  next_group = next_group + 1
  local group = vim.tbl_extend("force", { id = next_group, kind = kind, tab = tab,
    project = project(tab), owner = kind, views = {} }, opts)
  groups[#groups + 1] = group
  -- Keep a bounded tail of invalid ownership records for honest recovery UI.
  if #groups > 64 then
    for index, old in ipairs(groups) do
      if not api.nvim_tabpage_is_valid(old.tab) or (old.valid and not old.valid(old)) then
        table.remove(groups, index); break
      end
    end
  end
  return group
end

--- open(opts)->group,reason opens UI only; discover() registers existing UI.
--- Debug's owner installs this after its own initialization. No DAP is loaded
--- just to list layouts, and these callbacks must never launch/attach/stop.
function M.register_owner(kind, callbacks)
  if not kinds[kind] or type(callbacks) ~= "table" then return nil, "布局 owner 无效。" end
  owners[kind] = callbacks
  return true
end

local function review_valid(group)
  local lifecycle = package.loaded["codediff.ui.lifecycle"]
  if not group.token or not lifecycle or lifecycle.get_session(group.tab) ~= group.token then
    return false, "原审阅 owner 已失效；需重新打开比较（已保留 repo / revisions / pathspec）。"
  end
  local session = group.token
  local sides = { "original", "modified" }
  if session.layout == "inline" then sides = { "modified" }
  elseif session.single_pane or session.single_side then
    sides = { session.single_side or (normal(session.modified_win, group.tab) and "modified" or "original") }
  end
  for _, side in ipairs(sides) do
    local win = session[side .. "_win"]
    if not normal(win, group.tab) then
      return false, "审阅 diff pane 已关闭；原 owner 无安全恢复接口，需重新打开比较。"
    end
    local buffer_side = session.layout == "inline" and (session.single_side or "modified") or side
    local buf = session[buffer_side .. "_bufnr"]
    if buf and (not api.nvim_buf_is_valid(buf) or api.nvim_win_get_buf(win) ~= buf) then
      return false, "审阅 pane 内容已被替换；保留新内容，需重新打开比较。"
    end
  end
  if session.result_win and (not normal(session.result_win, group.tab)
    or (session.result_bufnr and api.nvim_win_get_buf(session.result_win) ~= session.result_bufnr)) then
    return false, "审阅 merge result 已关闭或更换内容；需重新打开比较。"
  end
  return true
end

local function review_focus(group)
  local session = group.token
  local win = normal(session.modified_win, group.tab) and session.modified_win or session.original_win
  if normal(win, group.tab) then api.nvim_set_current_win(win); return win end
  return nil, "审阅窗口已失效；需重新打开比较。"
end

local function review_restore(group)
  local panel = group.token.panel
  local view = panel and panel.view
  if panel and not view then return nil, "原审阅面板引用已失效；需重新打开比较。" end
  if view and normal(view.winid, group.tab) and view.bufnr
    and api.nvim_win_get_buf(view.winid) ~= view.bufnr then
    return nil, "审阅面板已有新内容；已保留，需重新打开比较。"
  end
  if view and not normal(view.winid, group.tab) then
    -- toggle_visibility requests a full Git refresh. The retained owner split
    -- can show the same tree/buffer without replaying that query or selection.
    if not view.split or type(view.split.show) ~= "function"
      or not view.bufnr or not api.nvim_buf_is_valid(view.bufnr) or not api.nvim_buf_is_loaded(view.bufnr)
      or view.split.bufnr ~= view.bufnr then
      return nil, "审阅面板引用已失效；需重新打开比较。"
    end
    local ok, err = pcall(view.split.show, view.split)
    if not ok then return nil, "审阅面板恢复失败：" .. tostring(err) end
    view.winid, view.is_hidden = view.split.winid, false
    if not normal(view.winid, group.tab) then return nil, "原审阅 owner 未恢复面板窗口。" end
  end
  M.sync_review(group.tab, group.token)
  return review_focus(group)
end

function M.track_review(tab, session)
  if not review_close_watch then
    review_close_watch = api.nvim_create_augroup("UELayoutReviewLifecycle", { clear = true })
    api.nvim_create_autocmd("User", { group = review_close_watch, pattern = "CodeDiffClose", callback = function(ev)
      -- Close is emitted before owner cleanup. Retire its token afterwards,
      -- even when only Git navigation (not layout commands) initialized us.
      local closed = ev.data and ev.data.tabpage or api.nvim_get_current_tabpage()
      vim.schedule(function() M.discover_groups(closed) end)
    end })
  end
  local group = M.register_group("review", { tab = tab, token = session, owner = "codediff",
    project = session.git_root or project(tab), valid = review_valid,
    focus = review_focus, restore = review_restore })
  local panel = session.panel
  local data = panel and panel.data or {}
  local view = panel and panel.view
  group.metadata = vim.deepcopy({ repo = session.git_root, original_revision = session.original_revision,
    modified_revision = session.modified_revision, source_revisions = session.source_revisions,
    pathspec = data.pathspec, base_revision = data.base_revision, target_revision = data.target_revision,
    selected_path = (view and view.data and view.data.current_file_path)
      or (group.metadata and group.metadata.selected_path),
    original = session.original, modified = session.modified })
  return group
end

local function normal_capture(group)
  local previous, current = group.views or {}, {}
  for _, row in ipairs(previous) do
    if not normal(row.win, group.tab) then current[#current + 1] = row end
  end
  for _, win in ipairs(api.nvim_tabpage_list_wins(group.tab)) do
    local row = view_row(win, group.tab)
    if row then current[#current + 1] = row end
  end
  group.views = current
  group.main = api.nvim_tabpage_get_win(group.tab)
end

local function normal_focus(group)
  local win = group.main
  if not normal(win, group.tab) then win = api.nvim_tabpage_get_win(group.tab) end
  api.nvim_set_current_win(win)
  return win
end

-- Native nvim_open_win(enter=false) restores its source after WinNew callbacks.
-- Retain an explicit callback choice of an existing window within this one
-- operation; no persistent WinEnter/BufEnter cursor or focus guard is installed.
local function open_retained(group, row, anchor)
  local source = api.nvim_get_current_win()
  local existing = {}
  for _, win in ipairs(api.nvim_list_wins()) do existing[win] = true end
  local chosen
  local guard = api.nvim_create_autocmd("WinNew", { callback = function()
    local current = api.nvim_get_current_win()
    if existing[current] and current ~= source then chosen = current end
  end })
  local ok, win = pcall(api.nvim_open_win, row.buf, false, { split = "right", win = anchor })
  pcall(api.nvim_del_autocmd, guard)
  if chosen and api.nvim_win_is_valid(chosen) then
    api.nvim_set_current_win(chosen)
    return nil, "恢复窗口回调选择了另一窗口；已保留新焦点。"
  end
  if not ok then return nil, "编辑视图恢复失败：" .. tostring(win) end
  return win
end

local function normal_restore(group)
  local unavailable = {}
  local source_win = api.nvim_get_current_win()
  local source_buf = api.nvim_win_get_buf(source_win)
  local function unchanged_source()
    return api.nvim_get_current_tabpage() == group.tab and normal(source_win, group.tab)
      and api.nvim_get_current_win() == source_win and api.nvim_win_get_buf(source_win) == source_buf
  end
  for _, row in ipairs(group.views or {}) do
    if not live(row) and not normal(row.win, group.tab) then
      if not retained(row) then unavailable[#unavailable + 1] = row.name ~= "" and row.name or tostring(row.buf)
      elseif row.role == "code" then
        -- Open the retained buffer in an additional view. Never take back a
        -- repurposed window, reload text, save it or run a session script.
        local existing
        for _, win in ipairs(api.nvim_tabpage_list_wins(group.tab)) do
          if api.nvim_win_get_buf(win) == row.buf and normal(win, group.tab) then existing = win; break end
        end
        if existing then row.win = existing
        else
          local anchor = api.nvim_tabpage_get_win(group.tab)
          local tick = api.nvim_buf_get_changedtick(row.buf)
          local win, err = open_retained(group, row, anchor)
          if not win then return nil, err end
          if not unchanged_source() or not normal(win, group.tab) or not retained(row)
            or api.nvim_win_get_buf(win) ~= row.buf or api.nvim_buf_get_changedtick(row.buf) ~= tick then
            return nil, "恢复回调产生了新窗口、内容或焦点；已保留新选择。"
          end
          vim.wo[win].winfixbuf = false
          vim.wo[win].diff, vim.wo[win].scrollbind, vim.wo[win].cursorbind = false, false, false
          vim.w[win].codediff_restore = nil
          vim.w[win].ue_bottom_panel_pin = nil
          vim.w[win].snacks_main = true
          api.nvim_win_call(win, function() vim.fn.winrestview(row.view) end)
          row.win = win
          M.register(win, "code")
        end
      elseif row.panel then
        local owner = require("utils.bottom_panel")
        local host = owner.window()
        if host and api.nvim_win_get_buf(host) ~= row.buf then
          unavailable[#unavailable + 1] = row.label .. "（底栏已有新内容，已保留；请用 UEWorkspace 查看旧输出）"
        elseif row.panel == "quickfix" then
          unavailable[#unavailable + 1] = "quickfix（请从 UEWorkspace 按原结果 ID 恢复）"
        else
          local win = owner.show(row.panel, row.buf, { focus = false, height = row.height })
          if not unchanged_source() then return nil, "面板恢复回调产生了新选择；已保留。" end
          if win then row.win = win
          else unavailable[#unavailable + 1] = row.label .. "（原面板 owner 不可恢复）" end
        end
      else unavailable[#unavailable + 1] = row.label .. "（请从 UEWorkspace 按原 owner 恢复）" end
    end
  end
  if not unchanged_source() then return nil, "恢复期间窗口或内容有了新选择；已保留。" end
  if #unavailable > 0 then return nil, "部分视图已失效：" .. table.concat(unavailable, "；") end
  return normal_focus(group)
end

function M.discover_groups(tab)
  tab = tab or api.nvim_get_current_tabpage()
  local lifecycle = package.loaded["codediff.ui.lifecycle"]
  for _, group in ipairs(groups) do
    if group.tab == tab and group.kind == "review" and group.token and (not api.nvim_tabpage_is_valid(group.tab)
      or not lifecycle or lifecycle.get_session(group.tab) ~= group.token) then
      -- Keep reopen metadata and the invalid group ID, not the closed UI tree.
      group.token, group.navigation_origin = nil, nil
    end
  end
  for _, callbacks in pairs(owners) do if callbacks.discover then callbacks.discover(tab) end end
  if api.nvim_tabpage_is_valid(tab) then
    local review = M.sync_review(tab)
    local other
    for _, group in ipairs(groups) do
      if group.tab == tab and group.kind ~= "normal" and (not group.valid or group.valid(group)) then other = group end
    end
    if not review and not other then
      local group = M.register_group("normal", { tab = tab, focus = normal_focus, restore = normal_restore })
      if #group.views == 0 then normal_capture(group) end
    end
  end
end

local function validity(group)
  if not api.nvim_tabpage_is_valid(group.tab) then return false, "布局 tab 已关闭。" end
  if group.kind == "normal" then
    for _, other in ipairs(groups) do
      if other.tab == group.tab and other.kind ~= "normal" and (not other.valid or other.valid(other)) then
        return false, "当前 tab 已由 " .. other.kind .. " UI owner 使用；普通编辑布局暂不可选。"
      end
    end
  end
  if group.valid then return group.valid(group) end
  return true
end

function M.current_group()
  M.discover_groups()
  local tab = api.nvim_get_current_tabpage()
  for index = #groups, 1, -1 do
    local group = groups[index]
    if group.tab == tab and group.kind ~= "normal" and validity(group) then return group end
  end
  for _, group in ipairs(groups) do if group.tab == tab and validity(group) then return group end end
  for index = #groups, 1, -1 do if groups[index].tab == tab then return groups[index] end end
end

function M.list_groups()
  for _, tab in ipairs(api.nvim_list_tabpages()) do M.discover_groups(tab) end
  local current = M.current_group()
  local rows = {}
  for _, group in ipairs(groups) do
    local valid, reason = validity(group)
    local status = not valid and "已失效" or (current == group and "当前" or "可恢复")
    local metadata = group.metadata or {}
    local selected = metadata.selected_path or (type(metadata.modified) == "table" and metadata.modified.relative)
      or (type(metadata.original) == "table" and metadata.original.relative)
    local comparison = group.kind == "review" and (" · %s → %s%s"):format(
      tostring(metadata.base_revision or metadata.original_revision or "工作区"),
      tostring(metadata.target_revision or metadata.modified_revision or "工作区"),
      selected and (" · " .. selected) or "") or ""
    rows[#rows + 1] = { id = group.id, kind = group.kind, project = group.project, tab = group.tab,
      status = status, reason = reason, metadata = vim.deepcopy(group.metadata),
      text = ("%s · %s · tab %s · %s%s"):format(group.kind, tostring(group.project),
        api.nvim_tabpage_is_valid(group.tab) and api.nvim_tabpage_get_number(group.tab) or "closed",
        status, comparison .. (reason and (" · " .. reason) or "")) }
  end
  return rows
end

local function group_by_id(id)
  for _, group in ipairs(groups) do if group.id == id then return group end end
end

function M.activate_group(id, opts)
  local group = group_by_id(type(id) == "table" and id.id or id)
  if not group then return nil, "布局记录已失效。" end
  local valid, reason = validity(group)
  if not valid then return nil, reason end
  local source = M.current_group()
  if source and source.kind == "normal" then normal_capture(source) end
  local previous_tab = api.nvim_get_current_tabpage()
  local destination = api.nvim_tabpage_get_win(group.tab)
  api.nvim_set_current_tabpage(group.tab)
  -- TabEnter callbacks may choose different work. Respect that new selection.
  if api.nvim_get_current_tabpage() ~= group.tab then return nil, "切换回调选择了另一 tab；保留新选择。" end
  if previous_tab ~= group.tab and api.nvim_get_current_win() ~= destination then
    return nil, "切换回调选择了新窗口；保留新选择。"
  end
  valid, reason = validity(group)
  if not valid then return nil, reason end
  local action = group.focus
  if opts and opts.restore then action = group.restore end
  if not action then return nil, "布局 owner 尚未注册恢复/聚焦接口。" end
  local ok, win, err = pcall(action, group)
  if not ok then return nil, "布局 owner 操作失败：" .. tostring(win) end
  if win and (not normal(win, group.tab) or api.nvim_get_current_win() ~= win or not validity(group)) then
    return nil, "布局恢复期间 owner / 视图有了新选择；已保留当前状态。"
  end
  if win then remember(group) end
  return win, err
end

function M.switch(kind)
  if not kinds[kind] then return nil, "布局类型：normal / review / debug。" end
  -- Explicit group switching may discover untouched tabs; passive entry only
  -- discovers its current tab. Standalone navigation therefore reuses normal.
  for _, tab in ipairs(api.nvim_list_tabpages()) do M.discover_groups(tab) end
  local current = M.current_group()
  if current then remember(current) end
  local candidate, invalid
  for _, group in ipairs(groups) do
    if group.kind == kind then
      local valid, reason = validity(group)
      if valid then
        if not candidate or group.tab == api.nvim_get_current_tabpage()
          or (candidate.project ~= (current and current.project) and group.project == (current and current.project)) then candidate = group end
      else invalid = reason end
    end
  end
  if candidate then return M.activate_group(candidate.id) end
  if kind == "normal" then
    local handoff = require("utils.layout_handoff")
    local snapshot, buf = handoff.capture(), api.nvim_create_buf(true, false)
    local win, reason = handoff.new_tab(snapshot, buf)
    if not win then return nil, reason end
    local group = M.current_group()
    if not group or group.kind ~= "normal" then return nil, "新 tab 回调选择了另一布局；已保留。" end
    return M.activate_group(group.id)
  end
  local owner = owners[kind]
  if owner and owner.open then
    local ok, group, err = pcall(owner.open, { project = current and current.project })
    if not ok then return nil, "布局 UI 打开失败：" .. tostring(group) end
    if not group then return nil, err end
    if type(group) ~= "table" or group.kind ~= kind then return nil, "布局 owner 未返回对应类型的 UI group。" end
    return M.activate_group(group.id, { restore = true })
  end
  return nil, invalid or (kind == "review" and "尚无审阅布局；请先重新打开比较。"
    or "debug UI owner 尚未就绪；请先加载调试 UI（布局命令不会 launch / attach）。")
end

normal_destination = function(tab, source, query)
  if api.nvim_get_current_tabpage() ~= tab or not source_live(source, tab) then
    return nil, "导航来源 tab / 窗口已变化；保留新选择。"
  end
  local group = M.current_group()
  if query then
    local candidate
    for _, row in ipairs(groups) do
      if row.kind == "normal" and validity(row) and (not candidate
        or (candidate.project ~= (group and group.project) and row.project == (group and group.project))) then
        candidate = row
      end
    end
    if not candidate then return nil, "没有可复用的普通编辑布局。" end
    return M.resolve({ tab = candidate.tab, source_win = candidate.main, create = false, route_to_normal = false })
  end
  local origin = { win = source, buf = api.nvim_win_get_buf(source), cursor = api.nvim_win_get_cursor(source) }
  origin.tick = api.nvim_buf_get_changedtick(origin.buf)
  if group then group.navigation_origin = origin end
  local expected = normal_destination(tab, source, true)
  local expected_buf = expected and api.nvim_win_get_buf(expected)
  local expected_tick = expected_buf and api.nvim_buf_get_changedtick(expected_buf)
  local expected_cursor = expected and api.nvim_win_get_cursor(expected)
  local win, err = M.switch("normal")
  if not win then return nil, err end
  if expected and (not M.is_code(expected, api.nvim_get_current_tabpage())
    or api.nvim_win_get_buf(expected) ~= expected_buf
    or api.nvim_buf_get_changedtick(expected_buf) ~= expected_tick
    or not vim.deep_equal(api.nvim_win_get_cursor(expected), expected_cursor)) then
    return nil, "编辑布局的目标窗口/内容/角色已变化；保留新选择。"
  end
  if not source_live(source, tab) or api.nvim_win_get_buf(source) ~= origin.buf
    or api.nvim_buf_get_changedtick(origin.buf) ~= origin.tick
    or not vim.deep_equal(api.nvim_win_get_cursor(source), origin.cursor) then
    return nil, "导航切换期间来源内容/位置已变化；保留当前布局。"
  end
  return M.resolve({ tab = api.nvim_get_current_tabpage(), source_win = win, create = true, route_to_normal = false })
end

function M.restore_group()
  local group = M.current_group()
  if not group then return nil, "当前没有布局 group。" end
  return M.activate_group(group.id, { restore = true })
end

function M.back()
  local current = M.current_group()
  while #history > 0 do
    local id = table.remove(history)
    local group = group_by_id(id)
    if group and group ~= current and validity(group) then
      local win, err = M.activate_group(id)
      if win then table.remove(history) end -- activation pushed the source; Back consumes history.
      local origin = group.navigation_origin
      if win and origin and normal(origin.win, group.tab)
        and api.nvim_win_get_buf(origin.win) == origin.buf
        and api.nvim_buf_get_changedtick(origin.buf) == origin.tick
        and vim.deep_equal(api.nvim_win_get_cursor(origin.win), origin.cursor) then
        api.nvim_set_current_win(origin.win)
        win = api.nvim_get_current_win()
      end
      group.navigation_origin = nil
      return win, err
    end
  end
  return nil, "没有上一个仍有效的布局。"
end

function M.list_views(role)
  local group = M.current_group()
  local rows = {}
  if not group then return rows end
  for _, win in ipairs(api.nvim_tabpage_list_wins(group.tab)) do
    local row = view_row(win, group.tab)
    if row and (not role or row.role == role) then
      row.group = group.id
      row.text = ("%s · %s · win %d · %s%s"):format(row.role, row.label, win,
        vim.bo[row.buf].modified and "[未保存] " or "", row.name ~= "" and row.name or "[No Name]")
      rows[#rows + 1] = row
    end
  end
  return rows
end

function M.activate_view(row)
  local group = type(row) == "table" and group_by_id(row.group)
  if not group or not validity(group) or not live(row) then return nil, "视图 owner / 窗口 / buffer 已变化；请刷新列表。" end
  local now = view_row(row.win, row.tab)
  if not now or now.role ~= row.role then return nil, "视图角色已变化；请刷新列表。" end
  api.nvim_set_current_win(row.win)
  if not live(row) or api.nvim_get_current_win() ~= row.win or not validity(group) then
    return nil, "视图聚焦回调产生了新选择；已保留当前内容。"
  end
  remember(group)
  return row.win
end

function M.setup_groups()
  local augroup = api.nvim_create_augroup("UELayoutGroups", { clear = true })
  -- Capture visible ownership before a user's first window close. Subsequent
  -- captures observe entry/leave only; they never restore focus or cursors.
  for _, tab in ipairs(api.nvim_list_tabpages()) do M.discover_groups(tab) end
  api.nvim_create_autocmd("WinClosed", { group = augroup, callback = function(ev)
    M.unregister(tonumber(ev.match))
  end })
  api.nvim_create_autocmd("TabClosed", { group = augroup, callback = function()
    for tab in pairs(tabs) do if not api.nvim_tabpage_is_valid(tab) then tabs[tab] = nil end end
    for _, group in ipairs(groups) do
      if not api.nvim_tabpage_is_valid(group.tab) and group.kind == "review" then group.token = nil end
    end
  end })
  api.nvim_create_autocmd({ "BufWinEnter", "WinLeave" }, { group = augroup, callback = function()
    local tab, win = api.nvim_get_current_tabpage(), api.nvim_get_current_win()
    if M.sync_review(tab) then return end
    for _, group in ipairs(groups) do
      if group.tab == tab and group.kind == "normal" then
        local row = view_row(win, tab)
        if row then
          for index, old in ipairs(group.views) do
            if old.win == win then group.views[index] = row; return end
          end
          group.views[#group.views + 1] = row
        end
        return
      end
    end
  end })
  api.nvim_create_autocmd("TabLeave", { group = augroup, callback = function()
    local group = M.current_group()
    if group then if group.kind == "normal" then normal_capture(group) end; remember(group) end
  end })
  api.nvim_create_autocmd("TabEnter", { group = augroup, callback = function()
    local group = M.current_group()
    if group then remember(group) end
  end })
  api.nvim_create_autocmd("User", { group = augroup, pattern = "CodeDiffOpen", callback = function(ev)
    M.discover_groups(ev.data and ev.data.tabpage or api.nvim_get_current_tabpage())
  end })
end

-- Read existing Back/source records only: no discovery, owner callbacks or IO.
function M.navigation_source()
  local tab, current = api.nvim_get_current_tabpage(), nil
  for _, group in ipairs(groups) do
    if group.id == active_group and group.tab == tab then current = group; break end
  end
  if not current or current.kind ~= "normal" then return nil end
  for index = #history, 1, -1 do
    local group = group_by_id(history[index])
    if group and group ~= current and api.nvim_tabpage_is_valid(group.tab) then
      local origin = group.navigation_origin
      if not origin or not group.token or (group.kind ~= "review" and group.kind ~= "debug") then return nil end
      if source_live(origin.win, group.tab) and api.nvim_win_get_buf(origin.win) == origin.buf
        and api.nvim_buf_get_changedtick(origin.buf) == origin.tick
        and vim.deep_equal(api.nvim_win_get_cursor(origin.win), origin.cursor) then
        return { id = group.id, kind = group.kind, tab = group.tab, tabnr = api.nvim_tabpage_get_number(group.tab) }
      end
      return nil
    end
  end
end

return M
