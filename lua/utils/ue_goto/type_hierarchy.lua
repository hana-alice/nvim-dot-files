-- Explicit clangd type navigation. The server's opaque item.data stays with
-- the client that prepared it; this never participates in the C++ gd fallback.
local M = {}
local generation = 0
local active_picker
local prepare_method = "textDocument/prepareTypeHierarchy"

local function notify(message)
  vim.notify("类型层级：" .. message, vim.log.levels.WARN, { title = "UE C++" })
end

local function fresh(snapshot, require_focus)
  if snapshot.generation ~= generation
    or not vim.api.nvim_win_is_valid(snapshot.win)
    or not vim.api.nvim_buf_is_valid(snapshot.buf)
    or vim.api.nvim_win_get_buf(snapshot.win) ~= snapshot.buf
    or vim.api.nvim_buf_get_changedtick(snapshot.buf) ~= snapshot.tick
  then
    return false
  end
  local cursor = vim.api.nvim_win_get_cursor(snapshot.win)
  if cursor[1] ~= snapshot.cursor[1] or cursor[2] ~= snapshot.cursor[2] then return false end
  if require_focus and vim.api.nvim_get_current_win() ~= snapshot.win then return false end
  if snapshot.client then
    for _, client in ipairs(vim.lsp.get_clients({ bufnr = snapshot.buf, name = "clangd" })) do
      if client == snapshot.client then return true end
    end
    return false
  end
  return true
end

---Convert server items into Snacks file rows without mutating the LSP items.
---Snacks resolves loc.encoding against the preview/target text into byte columns.
function M.items(items, encoding)
  local rows = {}
  for _, item in ipairs(items or {}) do
    local range = item.selectionRange or item.range
    if type(item.uri) == "string" and type(range) == "table" and type(range.start) == "table" then
      rows[#rows + 1] = {
        text = item.name or "?",
        name = item.name,
        file = vim.uri_to_fname(item.uri),
        pos = { range.start.line + 1, range.start.character },
        loc = { uri = item.uri, range = vim.deepcopy(range), encoding = encoding },
        hierarchy_item = item,
      }
    end
  end
  return rows
end

local function pick(snapshot, title, rows, choose)
  if not fresh(snapshot, true) then return end
  if not (_G.Snacks and Snacks.picker and Snacks.picker.pick) then
    notify("Snacks picker 不可用")
    return
  end
  active_picker = Snacks.picker.pick({
    title = title,
    items = rows,
    format = rows[1].file and "file" or "text",
    preview = rows[1].file and "file" or "none",
    -- Root/client selection must request its hierarchy, never jump to it.
    win = choose and {
      input = { keys = { ["<C-s>"] = false, ["<C-v>"] = false, ["<C-t>"] = false } },
      list = { keys = { ["<C-s>"] = false, ["<C-v>"] = false, ["<C-t>"] = false } },
    } or nil,
    confirm = function(picker, row)
      local focused = vim.api.nvim_get_current_win() == snapshot.win
        or (picker.current_win and picker:current_win() ~= nil)
      if not fresh(snapshot, false) or not row or not focused or picker.main ~= snapshot.win then
        picker:close()
        return
      end
      if choose then
        picker:close()
        vim.schedule(function()
          if fresh(snapshot, true) then choose(row) end
        end)
      else
        Snacks.picker.actions.jump(picker, row, {})
      end
    end,
  })
end

local function request(snapshot, method, params, done)
  if not fresh(snapshot, true) then return end
  local ok, accepted = pcall(snapshot.client.request, snapshot.client, method, params, function(err, result)
    vim.schedule(function()
      if not fresh(snapshot, true) then return end
      if err then
        notify("请求失败（" .. tostring(err.message or err.code or err) .. "）")
        return
      end
      done(result)
    end)
  end, snapshot.buf)
  if not ok or not accepted then notify("无法发送 " .. method .. " 请求") end
end

local function prepare(snapshot, kind)
  local params = vim.lsp.util.make_position_params(snapshot.win, snapshot.client.offset_encoding)
  local function hierarchy(item)
    request(snapshot, "typeHierarchy/" .. kind, { item = item }, function(result)
      local rows = M.items(result, snapshot.client.offset_encoding)
      if #rows == 0 then
        notify(kind == "supertypes" and "没有基类" or "没有派生类")
        return
      end
      pick(snapshot, kind == "supertypes" and "C++ 基类" or "C++ 派生类", rows)
    end)
  end
  request(snapshot, prepare_method, params, function(result)
    local rows = M.items(result, snapshot.client.offset_encoding)
    if #rows == 0 then
      notify("当前位置没有可查询的类型")
    elseif #rows == 1 then
      hierarchy(rows[1].hierarchy_item)
    else
      pick(snapshot, "选择要查询的 C++ 类型", rows, function(row)
        hierarchy(row.hierarchy_item)
      end)
    end
  end)
end

---Asynchronously query immediate base/derived types in the current clangd buffer.
function M.open(kind)
  if kind ~= "supertypes" and kind ~= "subtypes" then
    notify("方向必须是 supertypes 或 subtypes")
    return false
  end
  generation = generation + 1
  if active_picker and not active_picker.closed then active_picker:close() end
  active_picker = nil
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_win_get_buf(win)
  local clients = {}
  for _, client in ipairs(vim.lsp.get_clients({ bufnr = buf, name = "clangd" })) do
    if client.name == "clangd" and client:supports_method(prepare_method, buf) then
      clients[#clients + 1] = client
    end
  end
  if #clients == 0 then
    notify("当前缓冲区没有支持类型层级的 clangd")
    return false
  end
  local snapshot = {
    generation = generation,
    win = win,
    buf = buf,
    tick = vim.api.nvim_buf_get_changedtick(buf),
    cursor = vim.api.nvim_win_get_cursor(win),
  }
  if #clients == 1 then
    snapshot.client = clients[1]
    prepare(snapshot, kind)
  else
    local rows = {}
    for _, client in ipairs(clients) do
      rows[#rows + 1] = { text = "clangd #" .. client.id, client = client }
    end
    pick(snapshot, "选择 clangd 客户端", rows, function(row)
      snapshot.client = row.client
      prepare(snapshot, kind)
    end)
  end
  return true
end

function M.supertypes() return M.open("supertypes") end
function M.subtypes() return M.open("subtypes") end

return M
