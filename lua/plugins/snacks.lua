local function get_ue()
  local ok, ue = pcall(require, "ue")
  return ok and ue or nil
end

local function workspace_opts()
  local ue = get_ue()
  if not ue then return nil end
  local opts = ue.picker_options()
  if type(opts) ~= "table" or #opts.dirs == 0 then return nil end
  return opts
end

local function project_opts()
  local ue = get_ue()
  if not ue then return nil end
  local opts = ue.picker_project_options()
  if type(opts) ~= "table" then return nil end
  return opts
end

local function project_root()
  local ue = get_ue()
  if not ue or type(ue.ue_roots) ~= "function" then return nil end
  local root = ue.ue_roots()
  if type(root) ~= "string" or root == "" then return nil end
  return root
end

local function scope_opts()
  local ue = get_ue()
  if not ue then return nil, nil end
  local opts, scope, err = ue.current_scope_picker_options()
  if type(opts) ~= "table" then return nil, err end
  return opts, nil
end

local function code_ft()
  local ue = get_ue()
  return ue and ue.FT_CODE or nil
end

local function code_globs()
  local ue = get_ue()
  return ue and ue.GLOBS_CODE or nil
end

local function all_globs()
  local ue = get_ue()
  return ue and ue.GLOBS_ALL or nil
end

-- Apply file type filter: ft for files picker, glob for grep picker
local function with_ft(opts, ft)
  if opts and ft then opts.ft = ft end
  return opts
end

local function with_glob(opts, globs)
  if opts and globs then opts.glob = globs end
  return opts
end

-- Keep grep/files history, but open pickers blank by default.
local function history_record_query(record)
  if type(record) ~= "table" then
    return ""
  end
  if type(record.search) == "string" and record.search ~= "" then
    return record.search
  end
  if type(record.pattern) == "string" and record.pattern ~= "" then
    return record.pattern
  end
  return ""
end

local function picker_history_records(source)
  local ok, history_mod = pcall(require, "snacks.picker.util.history")
  if not ok then
    return {}
  end

  local ok_hist, history = pcall(history_mod.new, "picker_" .. source, {
    filter = function(record)
      return history_record_query(record) ~= ""
    end,
  })
  if not ok_hist or not history then
    return {}
  end

  local records = {}
  for _ = 1, math.max((history.idx or 1) - 1, 0) do
    local record = history:prev()
    if record then
      records[#records + 1] = record
    end
  end
  return records
end

local function rewrite_picker_history(source, records)
  local ok, history_mod = pcall(require, "snacks.picker.util.history")
  if not ok then
    return false, "Snacks history unavailable"
  end

  local ok_hist, history = pcall(history_mod.new, "picker_" .. source)
  if not ok_hist or not history or not history.kv then
    return false, "Picker history unavailable"
  end

  history.kv.data = records or {}
  history.idx = #history.kv.data + 1
  history.cursor = history.idx
  history.kv.loaded_time = 0
  history.kv:close()
  return true
end

local function clear_picker_history(source)
  return rewrite_picker_history(source, {})
end

local function clipboard_text()
  for _, reg in ipairs({ "+", "*" }) do
    local text = vim.fn.getreg(reg)
    if type(text) == "string" and text ~= "" then
      return text
    end
  end
  return ""
end

local function paste_picker_clipboard(picker)
  local input = picker and picker.input
  local win = input and input.win and input.win.win
  if not win or not vim.api.nvim_win_is_valid(win) then
    return
  end

  local text = clipboard_text()
  if text == "" then
    return
  end
  text = text:gsub("\r\n?", "\n"):gsub("\n", " ")

  local current = input:get() or ""
  local col = math.min(vim.api.nvim_win_get_cursor(win)[2], #current)
  local new = current:sub(1, col) .. text .. current:sub(col + 1)

  input:set(new, new)
  vim.api.nvim_win_set_cursor(win, { 1, col + #text })
  picker:find({ refresh = false })
end

local function pin_sidebar_qflist(picker)
  local ok, actions = pcall(require, "snacks.picker.actions")
  if not ok then
    vim.notify("Snacks picker actions unavailable", vim.log.levels.ERROR)
    return
  end

  actions.qflist(picker)
  vim.schedule(function()
    require("utils.sidebar").open("qflist")
  end)
end

local function grep_history_items()
  local items = {}
  local seen = {}
  for _, record in ipairs(picker_history_records("grep")) do
    local query = history_record_query(record)
    if query ~= "" and not seen[query] then
      seen[query] = true
      items[#items + 1] = {
        text = query,
        query = query,
        live = record.live == true,
        preview = {
          text = query,
          ft = "regex",
        },
      }
    end
  end
  return items
end

---------- Find files ----------

-- <leader>ff — project files (all types, fast)
local function ue_project_files()
  local snacks = require("snacks")
  local opts = project_opts()
  if opts then
    opts.title = "UE Project Files"
    return snacks.picker.files(opts)
  end
  return snacks.picker.files()
end

local function ue_files()
  local snacks = require("snacks")
  local opts = with_ft(project_opts(), code_ft())
  if opts then
    opts.title = "UE Project Code"
    return snacks.picker.files(opts)
  end
  return snacks.picker.files()
end

local function ue_workspace_files()
  local snacks = require("snacks")
  local opts = with_ft(workspace_opts(), code_ft())
  if opts then
    opts.title = "UE Workspace Code"
    return snacks.picker.files(opts)
  end
  return snacks.picker.files()
end

local function ue_workspace_all_files()
  local snacks = require("snacks")
  local ue = get_ue()
  local opts = ue and ue.picker_options({ include_third_party = true }) or workspace_opts() or {}
  opts.title = "UE Workspace All Files"
  return snacks.picker.files(opts)
end

local function ue_git_files()
  local snacks = require("snacks")
  local root = project_root()
  if root then
    return snacks.picker.git_files({ cwd = root, title = "UE Project Git Files" })
  end
  return snacks.picker.git_files()
end

---------- Grep ----------

local function ue_project_grep(query)
  local snacks = require("snacks")
  local opts = with_glob(workspace_opts(), all_globs()) or {}
  if type(query) == "string" and query ~= "" then
    opts.search = query
  end
  opts.title = "Grep All Code (Engine+Project)"
  return snacks.picker.grep(opts)
end

local function ue_grep()
  local snacks = require("snacks")
  local opts = with_glob(workspace_opts(), code_globs())
  if opts then
    opts.title = "Grep Workspace Code"
    return snacks.picker.grep(opts)
  end
  return snacks.picker.grep()
end

local function ue_grep_all()
  local snacks = require("snacks")
  local opts = workspace_opts()
  if opts then
    opts.title = "Grep Workspace All"
    return snacks.picker.grep(opts)
  end
  return snacks.picker.grep()
end

---------- Scope (current module/plugin) ----------

local function ue_scope_files()
  local snacks = require("snacks")
  local opts, err = scope_opts()
  if opts then
    opts.title = "UE Scope Files"
    with_ft(opts, code_ft())
    return snacks.picker.files(opts)
  end
  vim.notify(err or "No UE module or plugin scope found", vim.log.levels.WARN)
end

local function ue_scope_grep()
  local snacks = require("snacks")
  local opts, err = scope_opts()
  if opts then
    opts.title = "UE Scope Grep"
    with_glob(opts, code_globs())
    return snacks.picker.grep(opts)
  end
  vim.notify(err or "No UE module or plugin scope found", vim.log.levels.WARN)
end

local function ue_grep_history()
  local snacks = require("snacks")
  local items = grep_history_items()
  if vim.tbl_isempty(items) then
    vim.notify("No grep history found", vim.log.levels.WARN)
    return
  end

  return snacks.picker.pick({
    title = "Grep History",
    items = items,
    format = "text",
    preview = "none",
    layout = { preset = "vscode" },
    confirm = function(picker, item)
      picker:close()
      if item and item.query then
        vim.schedule(function()
          ue_project_grep(item.query)
        end)
      end
    end,
  })
end

local function ue_clear_picker_history()
  local ok_files, err_files = clear_picker_history("files")
  local ok_grep, err_grep = clear_picker_history("grep")
  if not ok_files or not ok_grep then
    vim.notify(err_files or err_grep or "Failed to clear picker history", vim.log.levels.ERROR)
    return
  end
  vim.notify("Cleared file and grep history")
end

---------- Plugin spec ----------

return {
  {
    "folke/snacks.nvim",
    lazy = true,
    keys = {
      { "<leader>;", function() Snacks.picker.commands() end, desc = "Commands" },
      { "<leader>fe", false },
      { "<leader>fE", false },
      { "<leader>e", function() require("utils.yazi").open_current() end, desc = "Yazi (current file)" },
      { "<leader>E", false },
      -- Grep
      { "<leader>/", ue_project_grep, desc = "Grep All Code (Engine+Project)" },
      { "<leader>sg", ue_grep, desc = "Grep Workspace Code (C++/Shader)" },
      { "<leader>sG", ue_grep_all, desc = "Grep Workspace All Files" },
      { "<leader>sH", ue_grep_history, desc = "Search: Grep History" },
      { "<leader>sC", ue_clear_picker_history, desc = "Search: Clear Picker History" },
      -- Find files
      { "<leader><space>", ue_workspace_all_files, desc = "Find Workspace All Files" },
      { "<leader>fC", ue_clear_picker_history, desc = "Find: Clear Search History" },
      { "<leader>ff", ue_project_files, desc = "Find Project Files" },
      { "<leader>fF", ue_workspace_files, desc = "Find Workspace Code (C++/Shader)" },
      { "<leader>fa", ue_files, desc = "Find Project Code (C++/Shader)" },
      { "<leader>fg", ue_git_files, desc = "Find Project Git Files" },
      -- Scope (current module/plugin)
      { "<leader>uo", ue_scope_files, desc = "UE: Files in current module/plugin" },
      { "<leader>uO", ue_scope_grep, desc = "UE: Grep current module/plugin" },
    },
    opts = function(_, opts)
      opts = opts or {}
      opts.explorer = vim.tbl_deep_extend("force", opts.explorer or {}, {
        enabled = false,
        replace_netrw = false,
      })
      opts.picker = opts.picker or {}
      opts.picker.actions = vim.tbl_deep_extend("force", opts.picker.actions or {}, {
        paste_clipboard = paste_picker_clipboard,
        pin_sidebar_qflist = pin_sidebar_qflist,
      })
      opts.picker.win = opts.picker.win or {}
      opts.picker.win.input = opts.picker.win.input or {}
      opts.picker.win.list = opts.picker.win.list or {}
      opts.picker.win.input.keys = vim.tbl_deep_extend("force", opts.picker.win.input.keys or {}, {
        ["<C-q>"] = { "pin_sidebar_qflist", mode = { "i", "n" } },
        ["<C-v>"] = { "paste_clipboard", mode = { "i", "n" } },
        ["<Tab>"] = { "list_down", mode = { "i", "n" } },
        ["<S-Tab>"] = { "list_up", mode = { "i", "n" } },
        ["<C-Space>"] = { "select_and_next", mode = { "i", "n" } },
      })
      opts.picker.win.list.keys = vim.tbl_deep_extend("force", opts.picker.win.list.keys or {}, {
        ["<C-q>"] = { "pin_sidebar_qflist", mode = { "n", "x" } },
        ["<C-v>"] = { "paste_clipboard", mode = { "n", "x" } },
        ["<Tab>"] = { "list_down", mode = { "n", "x" } },
        ["<S-Tab>"] = { "list_up", mode = { "n", "x" } },
        ["<C-Space>"] = { "select_and_next", mode = { "n", "x" } },
      })
    end,
  },
}
