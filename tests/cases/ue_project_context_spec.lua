-- tests/cases/ue_project_context_spec.lua
-- Explicit :UESetProject state must survive while an old project buffer is open.

local t = require("tests.harness")
t.bootstrap()

local ue = require("ue")

local function tmpdir()
  local dir = vim.fn.tempname():gsub("\\", "/")
  vim.fn.mkdir(dir, "p")
  return dir
end

local function write_file(path, content)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  vim.fn.writefile({ content or "" }, path)
end

local function make_engine(root)
  for _, rel in ipairs({
    "Engine/Binaries",
    "Engine/Build",
    "Engine/Config",
    "Engine/Plugins",
    "Engine/Shaders",
    "Engine/Source",
  }) do
    vim.fn.mkdir(root .. "/" .. rel, "p")
  end
end

t.describe("ue.resolve_context project selection", function()
  t.it("persisted project wins over an open buffer from the previous project", function()
    local root = tmpdir()
    local engine = root .. "/engine"
    local old_project = root .. "/old-project"
    local new_project = root .. "/new-project"
    local old_uproject = old_project .. "/Old.uproject"
    local new_uproject = new_project .. "/New.uproject"
    local old_source = old_project .. "/Source/Old.cpp"
    local previous_cwd = vim.fn.getcwd()
    local previous_buf = vim.api.nvim_get_current_buf()
    local test_buf

    make_engine(engine)
    write_file(old_uproject, "{}")
    write_file(new_uproject, "{}")
    write_file(old_source, "int OldProjectFile;")

    ue.update_state_field(engine, "engine_root", engine)
    ue.update_state_field(engine, "project_root", new_project)
    ue.update_state_field(engine, "uproject", new_uproject)

    local ok, err = pcall(function()
      vim.cmd("cd " .. vim.fn.fnameescape(engine))
      local actual_engine = vim.uv.cwd():gsub("\\", "/")
      if actual_engine ~= engine then
        ue.update_state_field(actual_engine, "engine_root", actual_engine)
        ue.update_state_field(actual_engine, "project_root", new_project)
        ue.update_state_field(actual_engine, "uproject", new_uproject)
      end
      test_buf = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_name(test_buf, old_source)
      vim.api.nvim_set_current_buf(test_buf)

      local ctx, resolve_err = ue.resolve_context()
      t.assert_nil(resolve_err)
      t.assert_eq(ctx.engine_root, actual_engine)
      t.assert_eq(ctx.state.project_root, new_project, "fixture state must be read from the resolved engine")
      t.assert_eq(ctx.project_root, new_project, "explicit project pin must remain authoritative")
      t.assert_eq(ctx.uproject, new_uproject)
    end)

    vim.cmd("cd " .. vim.fn.fnameescape(previous_cwd))
    if vim.api.nvim_buf_is_valid(previous_buf) then
      vim.api.nvim_set_current_buf(previous_buf)
    end
    if test_buf and vim.api.nvim_buf_is_valid(test_buf) then
      vim.api.nvim_buf_delete(test_buf, { force = true })
    end
    pcall(vim.fn.delete, root, "rf")
    if not ok then
      error(err)
    end
  end)

  t.it("does not discover a project from cwd or the current buffer", function()
    local root = tmpdir()
    local engine = root .. "/engine"
    local project = root .. "/project"
    local uproject = project .. "/ManualOnly.uproject"
    local source = project .. "/Source/ManualOnly.cpp"
    local previous_cwd = vim.fn.getcwd()
    local previous_buf = vim.api.nvim_get_current_buf()
    local test_buf

    make_engine(engine)
    write_file(uproject, "{}")
    write_file(source, "int ManualOnly;")

    local ok, err = pcall(function()
      vim.cmd("cd " .. vim.fn.fnameescape(engine))
      test_buf = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_name(test_buf, source)
      vim.api.nvim_set_current_buf(test_buf)

      local ctx, resolve_err = ue.resolve_context()
      t.assert_nil(resolve_err)
      t.assert_nil(ctx.project_root, "project must remain unset until :UESetProject")
      t.assert_nil(ctx.uproject, "uproject must remain unset until :UESetProject")
    end)

    vim.cmd("cd " .. vim.fn.fnameescape(previous_cwd))
    if vim.api.nvim_buf_is_valid(previous_buf) then
      vim.api.nvim_set_current_buf(previous_buf)
    end
    if test_buf and vim.api.nvim_buf_is_valid(test_buf) then
      vim.api.nvim_buf_delete(test_buf, { force = true })
    end
    pcall(vim.fn.delete, root, "rf")
    if not ok then
      error(err)
    end
  end)
end)
