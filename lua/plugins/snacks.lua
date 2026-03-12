local function ue_workspace_picker_opts()
  local ok, ue = pcall(require, "ue")
  if not ok then
    return nil
  end
  local opts = ue.picker_options()
  if type(opts) ~= "table" or #opts.dirs == 0 then
    return nil
  end
  return opts
end

local function ue_project_root()
  local ok, ue = pcall(require, "ue")
  if not ok or type(ue.ue_roots) ~= "function" then
    return nil
  end
  local project_root = ue.ue_roots()
  if type(project_root) ~= "string" or project_root == "" then
    return nil
  end
  return project_root
end

local function ue_project_picker_opts()
  local opts = ue_workspace_picker_opts()
  local project_root = ue_project_root()
  if not opts or not project_root then
    return nil
  end

  opts = vim.deepcopy(opts)
  opts.dirs = { project_root }
  opts.follow = false
  return opts
end

local function ue_scope_picker_opts()
  local ok, ue = pcall(require, "ue")
  if not ok then
    return nil, nil, nil
  end
  local opts, scope, err = ue.current_scope_picker_options()
  if type(opts) ~= "table" then
    return nil, nil, err
  end
  return opts, scope, nil
end

local function ue_files()
  local snacks = require("snacks")
  local opts = ue_project_picker_opts()
  if opts then
    opts.title = "UE Project Files"
    return snacks.picker.files(opts)
  end
  return snacks.picker.files()
end

local function ue_workspace_files()
  local snacks = require("snacks")
  local opts = ue_workspace_picker_opts()
  if opts then
    opts.title = "UE Workspace Files"
    return snacks.picker.files(opts)
  end
  return snacks.picker.files()
end

local function ue_git_files()
  local snacks = require("snacks")
  local project_root = ue_project_root()
  if project_root then
    return snacks.picker.git_files({
      cwd = project_root,
      title = "UE Project Git Files",
    })
  end
  return snacks.picker.git_files()
end

local function ue_grep()
  local snacks = require("snacks")
  local opts = ue_workspace_picker_opts()
  if opts then
    return snacks.picker.grep(opts)
  end
  return snacks.picker.grep()
end

local function ue_scope_files()
  local snacks = require("snacks")
  local opts, _, err = ue_scope_picker_opts()
  if opts then
    opts.title = "UE Scope Files"
    return snacks.picker.files(opts)
  end
  if err then
    vim.notify(err, vim.log.levels.WARN)
    return
  end
  vim.notify("No UE module or plugin scope found", vim.log.levels.WARN)
end

local function ue_scope_grep()
  local snacks = require("snacks")
  local opts, _, err = ue_scope_picker_opts()
  if opts then
    opts.title = "UE Scope Grep"
    return snacks.picker.grep(opts)
  end
  if err then
    vim.notify(err, vim.log.levels.WARN)
    return
  end
  vim.notify("No UE module or plugin scope found", vim.log.levels.WARN)
end

return {
  {
    "folke/snacks.nvim",
    keys = {
      { "<leader>ff", ue_files, desc = "Find Project Files" },
      { "<leader>fF", ue_workspace_files, desc = "Find UE Workspace Files" },
      { "<leader>fg", ue_git_files, desc = "Find Project Git Files" },
      { "<leader>sg", ue_grep, desc = "Grep" },
      { "<leader>uo", ue_scope_files, desc = "UE: Files in current module/plugin" },
      { "<leader>uO", ue_scope_grep, desc = "UE: Grep current module/plugin" },
    },
    opts = function(_, opts)
      opts = opts or {}
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
