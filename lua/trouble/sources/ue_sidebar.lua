---@diagnostic disable: inject-field
local Item = require("trouble.item")

---@type trouble.Source
local M = {}

local git_state = {
  by_root = {},
}

local GIT_REFRESH_INTERVAL_MS = 1000

local function git_root()
  if _G.LazyVim and LazyVim.root then
    local ok_git, root = pcall(LazyVim.root.git)
    if ok_git and type(root) == "string" and root ~= "" then
      return root
    end

    local ok_root, fallback = pcall(LazyVim.root.get, { normalize = true })
    if ok_root and type(fallback) == "string" and fallback ~= "" then
      return fallback
    end
  end

  return vim.uv.cwd()
end

local function relpath(path, root)
  if type(path) ~= "string" or path == "" then
    return "[No Name]"
  end
  local rel = vim.fn.fnamemodify(path, ":.")
  if root and root ~= "" then
    local norm_root = vim.fs.normalize(root)
    local norm_path = vim.fs.normalize(path)
    if norm_path:sub(1, #norm_root) == norm_root then
      rel = norm_path:sub(#norm_root + 2)
    end
  end
  return rel ~= "" and rel or vim.fn.fnamemodify(path, ":t")
end

local function git_info_item(root, text, kind)
  return Item.new({
    source = "ue_sidebar",
    filename = root,
    pos = { 1, 0 },
    text = text,
    item = {
      kind = kind or "info",
    },
  })
end

local function git_state_for(root)
  git_state.by_root[root] = git_state.by_root[root] or {
    items = {},
    loaded = false,
    loading = false,
    updated_at = 0,
    error = nil,
    force_refresh = false,
  }
  return git_state.by_root[root]
end

local function parse_git_status_items(root, lines)
  local items = {} ---@type trouble.Item[]

  for _, line in ipairs(lines) do
    local status = line:sub(1, 2)
    local raw = vim.trim(line:sub(4))
    local target = raw
    if raw:find(" -> ", 1, true) then
      local parts = vim.split(raw, " -> ", { plain = true })
      target = parts[#parts]
    end
    local filename = vim.fs.joinpath(root, target)
    local bufnr = vim.fn.bufadd(filename)
    items[#items + 1] = Item.new({
      source = "ue_sidebar",
      buf = bufnr,
      filename = filename,
      pos = { 1, 0 },
      text = string.format("[%s] %s", status, relpath(filename, root)),
      item = {
        kind = "git_status",
        status = status,
      },
    })
  end

  Item.add_id(items, { "text" })
  return items
end

local function git_display_items(root)
  local cache = git_state_for(root)
  local items = {} ---@type trouble.Item[]

  if cache.loading then
    items[#items + 1] = git_info_item(root, "Updating git status...", "git_loading")
  elseif cache.error then
    items[#items + 1] = git_info_item(root, "Git status failed: " .. cache.error, "git_error")
  end

  vim.list_extend(items, cache.items)
  Item.add_id(items, { "text" })
  return items
end

local function refresh_git_sidebar()
  local ok, trouble = pcall(require, "trouble")
  if ok and trouble.is_open("ue_sidebar_git_status") then
    trouble.refresh("ue_sidebar_git_status")
  end
end

local function start_git_refresh(root, force)
  local cache = git_state_for(root)
  local now = vim.uv.now()
  if cache.loading then
    return
  end
  if not force and cache.loaded and (now - (cache.updated_at or 0) < GIT_REFRESH_INTERVAL_MS) then
    return
  end

  cache.loading = true
  cache.error = nil
  cache.force_refresh = false

  local cmd = { "git", "-C", root, "status", "--porcelain=v1", "--untracked-files=all" }
  if vim.system then
    vim.system(cmd, { text = true }, function(result)
      vim.schedule(function()
        local lines = result.code == 0 and vim.split(result.stdout or "", "\n", { trimempty = true }) or {}
        if result.code ~= 0 and #lines == 0 and (result.stdout or "") ~= "" then
          lines = vim.split(result.stdout or "", "\n", { trimempty = true })
        end
        cache.items = parse_git_status_items(root, lines)
        cache.loading = false
        cache.loaded = true
        cache.updated_at = vim.uv.now()
        local err = vim.trim(result.stderr or ""):gsub("%s+", " ")
        if #cache.items > 0 or result.code == 0 then
          cache.error = nil
        else
          cache.error = err ~= "" and err or "git status failed"
        end
        refresh_git_sidebar()
      end)
    end)
    return
  end

  vim.schedule(function()
    local lines = vim.fn.systemlist(cmd)
    cache.items = vim.v.shell_error == 0 and parse_git_status_items(root, lines) or {}
    cache.loading = false
    cache.loaded = true
    cache.updated_at = vim.uv.now()
    if #cache.items > 0 or vim.v.shell_error == 0 then
      cache.error = nil
    else
      cache.error = "git status failed"
    end
    refresh_git_sidebar()
  end)
end

function M.request_refresh(kind)
  if kind ~= "git_status" then
    return
  end
  git_state_for(git_root()).force_refresh = true
end

local function buffer_items()
  local current = vim.api.nvim_get_current_buf()
  local infos = vim.fn.getbufinfo({ buflisted = 1 })
  table.sort(infos, function(a, b)
    if a.bufnr == current then
      return true
    end
    if b.bufnr == current then
      return false
    end
    return (a.lastused or 0) > (b.lastused or 0)
  end)

  local items = {} ---@type trouble.Item[]
  for _, info in ipairs(infos) do
    local name = vim.api.nvim_buf_get_name(info.bufnr)
    local flags = {}
    if info.bufnr == current then
      flags[#flags + 1] = "%"
    end
    if info.changed == 1 then
      flags[#flags + 1] = "+"
    end
    if info.hidden == 0 and info.loaded == 1 then
      flags[#flags + 1] = "a"
    end

    local prefix = #flags > 0 and ("[" .. table.concat(flags, "") .. "] ") or ""
    local cursor = vim.api.nvim_buf_is_loaded(info.bufnr) and vim.api.nvim_buf_get_mark(info.bufnr, [["]]) or { 1, 0 }
    local row = math.max(cursor[1] or 1, 1)
    local col = math.max(cursor[2] or 0, 0)

    items[#items + 1] = Item.new({
      source = "ue_sidebar",
      buf = info.bufnr,
      pos = { row, col },
      text = string.format("%s#%d %s", prefix, info.bufnr, relpath(name, git_root())),
      item = {
        kind = "buffer",
        changed = info.changed,
      },
    })
  end

  Item.add_id(items, { "text" })
  return items
end

local function todo_items(cb)
  pcall(function()
    require("lazy").load({ plugins = { "todo-comments.nvim" } })
  end)
  pcall(function()
    local config = require("todo-comments.config")
    if not config.loaded then
      if type(config._setup) == "function" then
        config._setup()
      else
        require("todo-comments").setup()
      end
    end
  end)

  local ok_search, search = pcall(require, "todo-comments.search")
  if not ok_search then
    cb({})
    return
  end

  search.search(function(results)
    local items = {} ---@type trouble.Item[]
    for _, result in pairs(results) do
      local filename = vim.fs.normalize(result.filename)
      items[#items + 1] = Item.new({
        source = "ue_sidebar",
        buf = vim.fn.bufadd(filename),
        filename = filename,
        pos = { result.lnum, math.max((result.col or 1) - 1, 0) },
        text = string.format("[%s] %s", result.tag, result.text),
        item = {
          kind = "todo",
          tag = result.tag,
        },
      })
    end
    Item.add_id(items, { "text" })
    cb(items)
  end, {})
end

M.get = {
  git_status = function(cb)
    local root = git_root()
    local cache = git_state_for(root)
    start_git_refresh(root, cache.force_refresh or not cache.loaded)
    cb(git_display_items(root))
  end,
  buffers = function(cb)
    cb(buffer_items())
  end,
  todo = function(cb)
    todo_items(cb)
  end,
}

return M
