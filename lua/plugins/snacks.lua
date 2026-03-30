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

-- Track last search queries so the picker reopens with previous input
local last_query = {}

local function with_last_query(key, opts)
  opts = opts or {}
  if last_query[key] and last_query[key] ~= "" then
    opts.search = last_query[key]
  end
  local orig_on_close = opts.on_close
  opts.on_close = function(picker)
    local f = type(picker.filter) == "function" and picker:filter() or picker.filter
    local q = (f and f.search) or ""
    last_query[key] = q
    if orig_on_close then orig_on_close(picker) end
  end
  return opts
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
  local opts = with_last_query("files", workspace_opts() or {})
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

local function ue_project_grep()
  local snacks = require("snacks")
  local opts = with_last_query("grep", with_glob(workspace_opts(), all_globs()) or {})
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

---------- Plugin spec ----------

return {
  {
    "folke/snacks.nvim",
    keys = {
      { "<leader>fe", false },
      { "<leader>fE", false },
      { "<leader>e", function() require("utils.yazi").open_current() end, desc = "Yazi (current file)" },
      { "<leader>E", false },
      -- Grep
      { "<leader>/", ue_project_grep, desc = "Grep All Code (Engine+Project)" },
      { "<leader>sg", ue_grep, desc = "Grep Workspace Code (C++/Shader)" },
      { "<leader>sG", ue_grep_all, desc = "Grep Workspace All Files" },
      -- Find files
      { "<leader><space>", ue_workspace_all_files, desc = "Find Engine Files" },
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
      opts.picker.win = opts.picker.win or {}
      opts.picker.win.input = opts.picker.win.input or {}
      opts.picker.win.list = opts.picker.win.list or {}
      opts.picker.win.input.keys = vim.tbl_deep_extend("force", opts.picker.win.input.keys or {}, {
        ["<Tab>"] = { "list_down", mode = { "i", "n" } },
        ["<S-Tab>"] = { "list_up", mode = { "i", "n" } },
        ["<C-Space>"] = { "select_and_next", mode = { "i", "n" } },
      })
      opts.picker.win.list.keys = vim.tbl_deep_extend("force", opts.picker.win.list.keys or {}, {
        ["<Tab>"] = { "list_down", mode = { "n", "x" } },
        ["<S-Tab>"] = { "list_up", mode = { "n", "x" } },
        ["<C-Space>"] = { "select_and_next", mode = { "n", "x" } },
      })
    end,
  },
}
