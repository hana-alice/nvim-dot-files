-- A process-local, on-demand relationship investigation. Server items and
-- opaque data remain bound to their provider; only user-expanded nodes query.
local M = {}
local ownership = require("utils.ue_goto.reading_owner")
local results = require("utils.ue_goto.reading_results")
local transaction = require("utils.ue_goto.semantic_transaction")
local latest
local MAX_NODES, MAX_CHILDREN, MAX_DEPTH = 256, 128, 16
local directions = {
  incoming = {
    prepare = "textDocument/prepareCallHierarchy",
    method = "callHierarchy/incomingCalls",
    title = "谁调用了它",
  },
  outgoing = {
    prepare = "textDocument/prepareCallHierarchy",
    method = "callHierarchy/outgoingCalls",
    title = "它调用了谁",
  },
  base = { prepare = "textDocument/prepareTypeHierarchy", method = "typeHierarchy/supertypes", title = "基类关系" },
  derived = {
    prepare = "textDocument/prepareTypeHierarchy",
    method = "typeHierarchy/subtypes",
    title = "派生类关系",
  },
}

local function notify(message)
  vim.notify(message, vim.log.levels.WARN, { title = "关系阅读" })
end

local function key(item)
  local data = type(item.data) == "table" and vim.json.encode(item.data) or tostring(item.data or "")
  local range = item.selectionRange or item.range or {}
  return vim.json.encode({ item.uri, item.name, item.kind, range.start, data })
end

local function source_current(session)
  if
    not vim.api.nvim_buf_is_valid(session.source.buf)
    or vim.api.nvim_buf_get_name(session.source.buf) ~= session.source.path
    or vim.api.nvim_buf_get_changedtick(session.source.buf) ~= session.source.tick
  then
    return false
  end
  local _, build = ownership.context(session.source.buf)
  if not vim.deep_equal(build, session.source.build) then
    return false
  end
  for _, client in ipairs(vim.lsp.get_clients({ bufnr = session.source.buf })) do
    if client == session.client then
      return client.offset_encoding == session.source.encodings[client.id]
    end
  end
  return false
end

local function current(session)
  return latest == session and source_current(session) and ownership.current(session.owner, true)
end

local function make_node(session, item, parent, calls)
  if session.count == MAX_NODES then
    session.limited = true
    return nil
  end
  local range = item.selectionRange or item.range
  if type(item.uri) ~= "string" or type(range) ~= "table" or type(range.start) ~= "table" then
    return nil
  end
  local row =
    results.items({ { uri = item.uri, range = range, _position_encoding = session.client.offset_encoding } })[1]
  if not row then
    return nil
  end
  session.count = session.count + 1
  local node = {
    id = session.count,
    key = key(item),
    item = item,
    row = row,
    parent = parent,
    depth = parent and parent.depth + 1 or 0,
    children = {},
    state = "unexpanded",
    serial = 0,
    call_count = calls or 0,
  }
  local ancestor = parent
  while ancestor do
    if ancestor.key == node.key then
      node.state = "cycle"
      break
    end
    ancestor = ancestor.parent
  end
  return node
end

function M.rows(session)
  local rows = {}
  local function visit(node)
    local row = vim.tbl_extend("force", {}, node.row)
    row.loc, row.pos, row.end_pos =
      vim.deepcopy(node.row.loc), vim.deepcopy(node.row.pos), vim.deepcopy(node.row.end_pos)
    local marker = node.state == "loading" and "…"
      or node.state == "cycle" and "↩"
      or node.expanded and "▾"
      or "▸"
    local detail = node.state == "empty" and " · 未返回子项（覆盖未知）"
      or node.state == "error" and (" · " .. tostring(node.error))
      or node.state == "cycle" and " · 循环，停止展开"
      or node.state == "limit" and " · 范围受限"
      or node.state == "stale" and " · 文件已改变，请重新查询"
      or ""
    local relative = vim.fs.relpath(
      session.source.context and session.source.context.project_root or session.client.config.root_dir or "",
      row.file
    ) or vim.fn.fnamemodify(row.file, ":t")
    row.node, row._id = node, node.id
    row.label = string.rep("  ", math.min(node.depth, MAX_DEPTH))
      .. marker
      .. " "
      .. tostring(node.item.name or "?")
      .. (node.item.detail and node.item.detail ~= node.item.name and (" · " .. tostring(node.item.detail)) or "")
      .. (node.call_count > 1 and (" · " .. node.call_count .. "处调用") or "")
      .. detail
      .. (node.limited and " · 范围受限" or "")
      .. "  "
      .. relative
      .. ":"
      .. row.pos[1]
    row.text = row.label
    rows[#rows + 1] = row
    if node.expanded then
      for _, child in ipairs(node.children) do
        visit(child)
      end
    end
  end
  for _, root in ipairs(session.roots) do
    visit(root)
  end
  return rows
end

local function refresh(session)
  local picker = session.owner.picker
  if not current(session) or not picker or picker.closed then
    return
  end
  picker.opts.items = M.rows(session)
  picker.opts.title = session.direction.title
    .. " · 按需展开 · 覆盖未知"
    .. (session.limited and " · 范围受限" or "")
  if picker.refresh then
    picker:refresh()
  end
end

local function cancel_pending(node)
  if node.cancel then
    node.cancel()
    node.cancel = nil
  end
  node.serial = node.serial + 1
  if node.state == "loading" then
    node.state, node.expanded = "unexpanded", false
  end
  for _, child in ipairs(node.children) do
    cancel_pending(child)
  end
end

local function cancel_session(session)
  for _, root in ipairs(session.roots) do
    cancel_pending(root)
  end
  if session.root_state == "loading" then
    session.root_state = "cancelled"
  end
end

function M.expand(session, node)
  if not current(session) or not node or node.state == "cycle" or node.state == "loading" then
    return false
  end
  if not results.target_current(node.row) then
    node.state, node.expanded = "stale", false
    refresh(session)
    return false
  end
  node.expanded = true
  if node.state == "ready" or node.state == "empty" then
    refresh(session)
    return true
  end
  if node.depth >= MAX_DEPTH or session.count >= MAX_NODES then
    node.state, session.limited = "limit", true
    refresh(session)
    return false
  end
  node.serial = node.serial + 1
  local serial = node.serial
  node.state = "loading"
  refresh(session)
  local _, cancel = ownership.request(
    session.owner,
    session.client,
    session.direction.method,
    { item = node.item },
    function(err, response)
      if not current(session) or node.serial ~= serial then
        return
      end
      node.cancel = nil
      if not results.target_current(node.row) then
        node.state, node.expanded = "stale", false
        refresh(session)
        return
      end
      if err then
        node.state, node.error = "error", tostring(err.message or "请求失败")
        refresh(session)
        return
      end
      node.children = {}
      local list = type(response) == "table" and response or {}
      for index, value in ipairs(list) do
        if index > MAX_CHILDREN then
          session.limited, node.limited = true, true
          break
        end
        local item = session.kind == "incoming" and value.from or session.kind == "outgoing" and value.to or value
        if type(item) == "table" then
          local child = make_node(session, item, node, session.kind == "incoming" and #(value.fromRanges or {}) or 0)
          if child then
            node.children[#node.children + 1] = child
          end
        end
      end
      node.state = #node.children == 0 and "empty" or "ready"
      refresh(session)
    end
  )
  node.cancel = cancel
  return true
end

function M.collapse(session, node)
  if not current(session) or not node then
    return false
  end
  node.expanded = false
  cancel_pending(node)
  refresh(session)
  return true
end

local function show(session)
  if not current(session) then
    return nil
  end
  local snacks = _G.Snacks
  if not snacks then
    local ok, loaded = pcall(require, "snacks")
    if ok then
      snacks = loaded
    end
  end
  if not snacks or not snacks.picker then
    notify("Snacks picker 不可用")
    return nil
  end
  local owner = session.owner
  return ownership.present(owner, function()
    return snacks.picker.pick({
      title = session.direction.title
        .. " · 按需展开 · 覆盖未知"
        .. (session.limited and " · 范围受限" or ""),
      items = M.rows(session),
      auto_confirm = false,
      preview = "file",
      layout = { preset = "telescope", reverse = false },
      format = function(item)
        return { { item.label } }
      end,
      matcher = { sort_empty = false },
      confirm = function(_, row)
        if current(session) and row then
          session.origin = session.origin or results.remember(owner)
          results.jump(owner, row, nil, session.origin)
        end
      end,
      actions = {
        relation_expand = function(picker, row)
          row = row or picker:current()
          if row then
            M.expand(session, row.node)
          end
        end,
        relation_collapse = function(picker, row)
          row = row or picker:current()
          if row then
            M.collapse(session, row.node)
          end
        end,
        relation_parent = function(picker, row)
          row = row or picker:current()
          local node = row and row.node
          if current(session) and node and node.parent then
            local visible_rows = picker.items and picker:items() or M.rows(session)
            for index, visible in ipairs(visible_rows) do
              if visible.node == node.parent and picker.list then
                picker.list:move(picker.list.reverse and #visible_rows - index + 1 or index, true)
                return
              end
            end
            notify("父节点被筛选隐藏，请清空筛选后返回")
          end
        end,
        relation_vsplit = function(picker, row)
          row = row or picker:current()
          if current(session) and row then
            session.origin = session.origin or results.remember(owner)
            results.jump(owner, row, "vsplit", session.origin)
          end
        end,
        relation_pin = function()
          results.pin(owner, M.rows(session), { title = session.direction.title, source = session.client.name })
        end,
        copy_position = function(picker, row)
          return results.copy(owner, picker, row, "position")
        end,
        copy_absolute_path = function(picker, row)
          return results.copy(owner, picker, row, "absolute")
        end,
        copy_relative_path = function(picker, row)
          return results.copy(owner, picker, row, "relative")
        end,
      },
      win = {
        input = {
          keys = {
            ["<Esc>"] = { "cancel", mode = { "n", "i" } },
            ["<Right>"] = { "relation_expand", mode = { "n", "i" } },
            ["<Left>"] = { "relation_collapse", mode = { "n", "i" } },
            ["<M-u>"] = { "relation_parent", mode = { "n", "i" } },
            ["<M-v>"] = { "relation_vsplit", mode = { "n", "i" } },
            ["<C-s>"] = false,
            ["<C-t>"] = false,
            ["<C-q>"] = { "relation_pin", mode = { "n", "i" } },
          },
        },
        list = {
          keys = {
            ["<Right>"] = "relation_expand",
            ["<Left>"] = "relation_collapse",
            ["h"] = "relation_collapse",
            ["l"] = "relation_expand",
            ["<M-u>"] = "relation_parent",
            ["<M-v>"] = "relation_vsplit",
            ["<C-s>"] = false,
            ["<C-t>"] = false,
            ["<C-q>"] = "relation_pin",
          },
        },
      },
      on_close = function(picker)
        ownership.picker_closed(owner, picker)
      end,
    })
  end)
end

function M.open(kind)
  if not directions[kind] then
    notify("关系方向必须是 incoming / outgoing / base / derived")
    return false
  end
  require("utils.ue_goto.reading").cancel()
  local owner = ownership.begin()
  local direction = directions[kind]
  return require("utils.ue_goto.reading").choose_client(owner, direction.prepare, function(client)
    local session = {
      owner = owner,
      source = owner,
      client = client,
      direction = direction,
      kind = kind,
      roots = {},
      count = 0,
      root_state = "loading",
    }
    latest = session
    ownership.add_cleanup(owner, function()
      cancel_session(session)
    end)
    local params = transaction.make_position_params(owner, owner.buf, client.offset_encoding)
    params._position_encoding = nil
    ownership.request(owner, client, direction.prepare, params, function(err, items)
      if not current(session) then
        return
      end
      if err then
        session.root_state = "error"
        notify("关系根查询失败：" .. tostring(err.message))
        return
      end
      for index, item in ipairs(type(items) == "table" and items or {}) do
        if index > MAX_CHILDREN then
          session.limited = true
          break
        end
        local node = make_node(session, item)
        if node then
          session.roots[#session.roots + 1] = node
        end
      end
      if #session.roots == 0 then
        session.root_state = "empty"
        notify("当前位置未返回关系根（覆盖未知）")
        return
      end
      session.root_state = "ready"
      show(session)
    end)
  end, true)
end

function M.resume()
  if not latest or not source_current(latest) then
    notify("调查来源已改变或提供者离线，请重新查询")
    return false
  end
  if latest.root_state ~= "ready" then
    notify("尚未取得调查根，请重新查询关系")
    return false
  end
  local function targets_current(nodes)
    for _, node in ipairs(nodes) do
      if not results.target_current(node.row) or not targets_current(node.children) then
        return false
      end
    end
    return true
  end
  if not targets_current(latest.roots) then
    notify("调查中的文件已改变，请重新查询关系")
    return false
  end
  require("utils.ue_goto.reading").cancel()
  local session = latest
  session.owner = ownership.begin()
  ownership.add_cleanup(session.owner, function()
    cancel_session(session)
  end)
  return show(session) ~= nil
end

function M.session()
  return latest
end
function M.reset()
  ownership.cancel()
  latest = nil
end

return M
