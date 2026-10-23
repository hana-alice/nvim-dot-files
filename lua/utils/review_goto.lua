-- Review coordinates are mapped to the live document before normal semantic gd.
local M = {}
local api = vim.api
local pending

local function notify(message)
  vim.notify(message, vim.log.levels.WARN, { title = "审阅定义跳转" })
end

function M.parse_url(name)
  if type(name) ~= "string" or not name:match("^codediff://") then return nil end
  local ok, virtual = pcall(require, "codediff.core.virtual_file")
  if not ok then return nil end
  local parsed, root, commit, filepath = pcall(virtual.parse_url, name)
  if not parsed or not root or not commit or not filepath then return nil end
  return { git_root = root, commit = commit, filepath = filepath, path = vim.fs.joinpath(root, filepath) }
end

function M.map_line(revision, worktree, line)
  local hunks = vim.diff(table.concat(revision, "\n") .. "\n", table.concat(worktree, "\n") .. "\n",
    { result_type = "indices" })
  local offset, mapped = 0, nil
  for _, hunk in ipairs(hunks) do
    local start_a, count_a, start_b, count_b = unpack(hunk)
    if count_a == 0 then
      -- An insertion's start_a is the preceding line, including zero at BOF.
      if line <= start_a then break end
    elseif line < start_a then
      break
    elseif line < start_a + count_a then
      local inside = line - start_a
      if count_b > 0 then
        mapped = start_b + math.min(inside, count_b - 1)
      else
        -- A deletion's start_b is the preceding surviving line.
        mapped = start_b + (inside + 1 <= count_a - inside and 0 or 1)
      end
      break
    end
    offset = offset + count_b - count_a
  end
  return math.max(1, math.min(mapped or line + offset, math.max(1, #worktree)))
end

function M.map_cursor(revision, worktree, cursor, word)
  local line = M.map_line(revision, worktree, cursor[1])
  local before, after = revision[cursor[1]] or "", worktree[line] or ""
  local col = cursor[2]
  if before ~= after and word and word ~= "" then
    local pattern = "\\<\\V" .. vim.fn.escape(word, "\\") .. "\\m\\>"
    local inner, from = 0, 0
    while true do
      local match = vim.fn.matchstrpos(before, pattern, from)
      local first, last = match[2], match[3]
      if first < 0 then break end
      if first <= col and col < last then inner = col - first; break end
      from = last
    end
    local best, distance
    from = 0
    while true do
      local match = vim.fn.matchstrpos(after, pattern, from)
      local first, last = match[2], match[3]
      if first < 0 then break end
      local candidate = first + inner
      if not distance or math.abs(candidate - col) < distance then
        best, distance = candidate, math.abs(candidate - col)
      end
      from = last
    end
    col = best or col
  end
  return { line, math.max(0, math.min(col, math.max(0, #after - 1))) }
end

function M.wait_for_clangd(buf, win, cursor, callback, timeout_ms)
  if pending then pending() end
  local cancelled, timer, attach_event, check = false, nil, nil, nil
  local tick = api.nvim_buf_get_changedtick(buf)
  local started = vim.uv.hrtime()
  local deadline = started + (timeout_ms or 10000) * 1000000
  local start_state = "未找到 clangd 配置"
  local root_ready = true
  local expected_root
  local function cancel()
    cancelled = true
    if timer and not timer:is_closing() then timer:stop(); timer:close() end
    timer = nil
    if attach_event then pcall(api.nvim_del_autocmd, attach_event); attach_event = nil end
    if pending == cancel then pending = nil end
  end
  pending = cancel
  local function current()
    return not cancelled and api.nvim_win_is_valid(win) and api.nvim_buf_is_valid(buf)
      and api.nvim_get_current_win() == win and api.nvim_win_get_buf(win) == buf
      and api.nvim_buf_get_changedtick(buf) == tick
      and vim.deep_equal(api.nvim_win_get_cursor(win), cursor)
  end
  local function stopped(client)
    return type(client.is_stopped) == "function" and client:is_stopped()
  end
  -- Re-enter the configured native LSP start path for hidden/already-loaded
  -- files: bufload/FileType need not fire when revisiting such a document.
  -- The cmd factory, root resolver, on_attach and compile-command ownership
  -- remain those of the normal clangd configuration.
  local config = type(vim.lsp.config) == "table" and vim.lsp.config.clangd
  local function same_root(client)
    return client.name == "clangd" and not stopped(client) and (not config
      or vim.fs.normalize(client.config and client.config.root_dir or "")
        == vim.fs.normalize(expected_root or ""))
  end
  if config then
    root_ready = false
    config = vim.deepcopy(config)
    local function start(root)
      if not current() or vim.bo[buf].buftype ~= "" then return end
      config.root_dir = root
      expected_root = root
      root_ready = true
      start_state = "启动/附加 root=" .. tostring(root)
      for _, client in ipairs(vim.lsp.get_clients({ bufnr = buf, name = "clangd", _uninitialized = true })) do
        if not same_root(client) then vim.lsp.buf_detach_client(buf, client.id) end
      end
      -- Foreground, long-lived language service; use the registered cmd
      -- factory's existing host resource admission and ownership hooks.
      local ok, id = pcall(vim.lsp.start, config, { bufnr = buf, reuse_client = same_root,
        _root_markers = config.root_markers })
      if not ok or not id then start_state = "启动失败：" .. tostring(id) end
      if check then check() end
    end
    if type(config.root_dir) == "function" then
      start_state = "等待配置 root_dir 回调"
      local ok, err = pcall(config.root_dir, buf, function(root)
        vim.schedule(function() start(root) end)
      end)
      if not ok then start_state = "root_dir 失败：" .. tostring(err) end
    else
      start(config.root_dir)
    end
  end
  check = function()
    if timer and not timer:is_closing() then timer:stop(); timer:close() end
    timer = nil
    if cancelled then return end
    if not current() then
      cancel()
      return
    end
    local ready_client
    for _, client in ipairs(vim.lsp.get_clients({ bufnr = buf, name = "clangd", _uninitialized = true })) do
      -- A concurrent attach can occur after the initial root check. Keep the
      -- actual semantic provider's client set confined to this resolved root.
      if root_ready and config and not same_root(client) then
        vim.lsp.buf_detach_client(buf, client.id)
      elseif root_ready and same_root(client) and client.initialized then
        ready_client = client
      end
    end
    if ready_client then
      cancel()
      if pending == cancel then pending = nil end
      callback()
      return
    end
    if vim.uv.hrtime() >= deadline then
      cancel()
      if pending == cancel then pending = nil end
      local clients = {}
      for _, client in ipairs(vim.lsp.get_clients({ name = "clangd", _uninitialized = true })) do
        clients[#clients + 1] = string.format("id=%s root=%s initialized=%s stopped=%s attached=%s",
          tostring(client.id), tostring(client.config and client.config.root_dir),
          tostring(client.initialized), tostring(stopped(client)),
          tostring(client.attached_buffers and client.attached_buffers[buf] ~= nil))
      end
      notify(string.format("等待 clangd 附加超时（%.0f ms）；%s；client 状态：%s。已保留工作区文件，可稍后重试 gd。",
        (vim.uv.hrtime() - started) / 1000000, start_state,
        #clients > 0 and table.concat(clients, "; ") or "无 clangd client"))
      return
    end
    timer = vim.defer_fn(function() timer = nil; check() end, 50)
  end
  attach_event = api.nvim_create_autocmd("LspAttach", { buffer = buf, callback = function(event)
    local client = event.data and vim.lsp.get_client_by_id(event.data.client_id)
    if client and root_ready and same_root(client) then check() end
  end })
  check()
  return cancel
end

function M.definition(next_definition, opts)
  if pending then pending(); pending = nil end
  local revision_buf = api.nvim_get_current_buf()
  local parsed = M.parse_url(api.nvim_buf_get_name(revision_buf))
  local tab, source = api.nvim_get_current_tabpage(), api.nvim_get_current_win()
  local destinations = require("utils.layout")
  if not parsed then
    -- The callback's second request runs in normal, while all code windows
    -- owned by review/debug route to normal before semantic evaluation.
    if not destinations.routes_to_normal(tab) then return false end
    if vim.bo[revision_buf].buftype ~= "" then return false end
  end
  opts = opts or {}
  local path = parsed and parsed.path or api.nvim_buf_get_name(revision_buf)
  local stat = parsed and vim.uv.fs_stat(path)
  if parsed and (not stat or stat.type ~= "file") then
    notify("工作区文件不存在：" .. parsed.path)
    return true
  end
  local revision = api.nvim_buf_get_lines(revision_buf, 0, -1, false)
  local cursor, word = api.nvim_win_get_cursor(0), vim.fn.expand("<cword>")
  local handoff = require("utils.layout_handoff")
  local snapshot = handoff.capture(source)
  local ok, err = pcall(function()
    local buf = parsed and vim.fn.bufadd(path) or revision_buf
    if parsed and not handoff.load(snapshot, buf) then return end
    if not api.nvim_buf_is_loaded(buf) then error("无法读取工作区文件：" .. path) end
    local worktree = api.nvim_buf_get_lines(buf, 0, -1, false)
    local mapped = parsed and M.map_cursor(revision, worktree, cursor, word) or cursor
    if not handoff.revalidate(snapshot, { win = source, tab = tab, buf = revision_buf,
      tick = snapshot.tick, cursor = cursor }) then return end
    -- External gd shares the normal editing group used by picker navigation.
    local win, destination_err = destinations.focus({ tab = tab, source_win = source })
    if not win then error(destination_err, 0) end
    local destination = handoff.capture(win)
    destination.buf, destination.tick, destination.cursor, destination.code = buf, nil, nil, true
    if not handoff.handoff(snapshot, destination, function() api.nvim_win_set_buf(win, buf) end) then return end
    if vim.bo[buf].filetype == "" then
      local ft = vim.filetype.match({ filename = path, buf = buf })
      if ft and not handoff.handoff(snapshot, destination, function() vim.bo[buf].filetype = ft end) then return end
    end
    if not handoff.revalidate(snapshot, destination) then return end
    api.nvim_win_set_cursor(win, mapped)
    mapped = api.nvim_win_get_cursor(win)
    if api.nvim_get_current_win() ~= win or api.nvim_win_get_buf(win) ~= buf
      or destinations.routes_to_normal(api.nvim_win_get_tabpage(win)) then return end
    local navigation = require("utils.ue_goto.semantic_navigation")
    local ext = require("utils.ue_goto.ui").buf_extension(buf)
    if navigation.CPP_SOURCE_EXTS[ext] or navigation.CPP_HEADER_EXTS[ext] then
      M.wait_for_clangd(buf, win, mapped, next_definition, opts.timeout_ms)
    else
      next_definition()
    end
  end)
  if not ok then notify("无法从修订文件跳转：" .. tostring(err)) end
  return true
end

return M
