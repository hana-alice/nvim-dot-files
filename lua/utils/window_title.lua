local M = {}

local MAX_TITLE_CHARS = 80
local current_name
local commands_installed = false

local function normalize(value)
  local name = tostring(value or "")
  -- A title is emitted to terminal UIs through an OSC sequence. Never allow
  -- user-provided C0/DEL bytes to terminate or inject another sequence.
  name = name:gsub("[%z\1-\31\127]", " ")
  name = name:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
  return vim.fn.strcharpart(name, 0, MAX_TITLE_CHARS)
end

local function literal_titlestring(name)
  -- 'titlestring' uses statusline syntax. Doubling percent signs prevents a
  -- title such as "%{...}" from being evaluated and displays it literally.
  return name:gsub("%%", "%%%%")
end

function M.current()
  return current_name
end

function M.set(value, opts)
  opts = opts or {}
  local name = normalize(value)
  if name == "" then
    return M.reset(opts)
  end

  current_name = name
  vim.o.title = true
  vim.o.titlestring = literal_titlestring(name)
  if opts.notify ~= false then
    vim.notify("Window title: " .. name, vim.log.levels.INFO)
  end
  return name
end

function M.reset(opts)
  opts = opts or {}
  current_name = nil
  vim.o.title = true
  vim.o.titlestring = ""
  if opts.notify ~= false then
    vim.notify("Window title: automatic", vim.log.levels.INFO)
  end
end

function M.prompt()
  vim.ui.input({
    prompt = "Window title: ",
    default = current_name or "",
  }, function(value)
    -- nil means the UI was cancelled. An explicitly confirmed empty value is
    -- meaningful: it restores Neovim's automatic title.
    if value == nil then return end
    M.set(value)
  end)
end

function M.setup()
  if commands_installed then return end
  commands_installed = true

  vim.api.nvim_create_user_command("WindowTitle", function(opts)
    if opts.bang then
      M.reset()
    elseif opts.args == "" then
      M.prompt()
    else
      M.set(opts.args)
    end
  end, {
    nargs = "*",
    bang = true,
    desc = "Name this Neovim/Neovide system window (! resets to automatic)",
  })

  vim.api.nvim_create_user_command("WindowTitleReset", function()
    M.reset()
  end, { desc = "Restore Neovim's automatic system window title" })
end

M._normalize_for_test = normalize

return M
