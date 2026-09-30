---@diagnostic disable: inject-field
local Item = require("trouble.item")

---@type trouble.Source
local M = {}

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
  buffers = function(cb)
    cb(buffer_items())
  end,
  todo = function(cb)
    todo_items(cb)
  end,
}

return M
