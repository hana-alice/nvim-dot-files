-- Isolated command/UI test: real file completion, no compiler or user-state writes.
local cfg, mode = arg[1], arg[2]
vim.opt.rtp:prepend(cfg)
package.path = cfg .. "/lua/?.lua;" .. cfg .. "/lua/?/init.lua;" .. package.path
local fs = require("ue.core.fs")
local root = fs.norm(vim.fn.tempname())
vim.fn.mkdir(root, "p")
root = fs.norm(assert(vim.uv.fs_realpath(root)))
vim.env.NVIM_UE_PROBE_PATH = root .. "/probes.json"
local engine = root .. "/engine"
for _, part in ipairs({ "Binaries", "Build", "Config", "Plugins", "Shaders", "Source" }) do
  vim.fn.mkdir(engine .. "/Engine/" .. part, "p")
end
local old = root .. "/old-project"
local new = root .. "/new project"
local rel = "Source/Game/Sample.uproject"
for _, project in ipairs({ old, new }) do
  vim.fn.mkdir(project .. "/Source/Game", "p")
  vim.fn.writefile({ "{}" }, project .. "/" .. rel)
end
vim.cmd.cd(engine)
engine = fs.norm(vim.uv.cwd())
local state = require("ue.project_state")
assert(state.select(engine, old, old .. "/" .. rel))
local ue = require("ue")
ue.setup()
local notices = {}
vim.notify = function(message, level)
  notices[#notices + 1] = { message = message, level = level }
end
local ok, err = pcall(function()
  local expected = new .. "/" .. rel
  if mode == "tab-file" or mode == "tab-workspace" then
    assert(vim.fn.has("win32") == 1, "requires real Windows completion")
    -- Drive-relative to the non-root engine cwd. Inserting '/' would select
    -- a different directory; the OS must resolve the completed path instead.
    local prefix = engine:sub(1, 2) .. "../new pro"
    if mode == "tab-file" then
      prefix = engine:sub(1, 2) .. "../new project/Source/Game/Sam"
    end
    vim.api.nvim_feedkeys(
      vim.api.nvim_replace_termcodes("<C-U>" .. prefix .. "<Tab><CR>", true, false, true),
      "t",
      false
    )
    vim.cmd.UESetProject()
  elseif mode == "absolute" or mode == "probe-failed" then
    if mode == "probe-failed" then
      require("utils.probe").observe = function()
        error("probe unavailable")
      end
    end
    vim.api.nvim_cmd({ cmd = "UESetProject", args = { expected } }, {})
  elseif mode == "drive-root" then
    -- Give the per-drive cwd a valid project: dropping the root slash would
    -- incorrectly select this file instead of evaluating the supplied root.
    vim.fn.writefile({ "{}" }, engine .. "/Wrong.uproject")
    vim.api.nvim_cmd({ cmd = "UESetProject", args = { engine:sub(1, 2) .. "/" } }, {})
    assert(state.current(engine).uproject ~= engine .. "/Wrong.uproject", "absolute drive root became per-drive cwd")
    assert(state.current(engine).project_root == old, "unsupported drive-root selection changed the project")
    assert(notices[#notices].level == vim.log.levels.ERROR, "unsupported drive-root selection must report ERROR")
    return
  elseif mode == "missing" or mode == "empty-directory" or mode == "persist-failed" then
    local input = root .. "/missing"
    local lease
    if mode == "empty-directory" then
      input = root .. "/empty"
      vim.fn.mkdir(input, "p")
    elseif mode == "persist-failed" then
      input = expected
      lease = assert(require("ue.file_lock").acquire(state.selector_path(engine) .. ".lock"))
    end
    vim.api.nvim_cmd({ cmd = "UESetProject", args = { input } }, {})
    if lease then
      require("ue.file_lock").release(lease)
    end
    assert(state.current(engine).project_root == old, "failed selection changed the project")
    local stored = vim.json.decode(table.concat(vim.fn.readfile(state.selector_path(engine)), "\n"))
    assert(stored.project_root == old, "failed selection changed the startup default")
    local last = notices[#notices]
    assert(last.level == vim.log.levels.ERROR, "failed selection must be an error")
    assert(last.message:find("UE project NOT changed", 1, true), last.message)
    assert(last.message:find(old, 1, true), "error must identify the retained project")
    assert(require("utils.probe").pending_summary().unresolved > 0, "failed selection must leave probe evidence")
    return
  else
    error("unknown test mode: " .. tostring(mode))
  end
  local selected = state.current(engine)
  assert(selected.uproject == expected, vim.inspect({ expected = expected, actual = selected }))
  local stored = vim.json.decode(table.concat(vim.fn.readfile(state.selector_path(engine)), "\n"))
  assert(stored.uproject == expected, "startup default did not persist the completed project")
  if mode == "tab-workspace" then
    assert(selected.project_root == new, "workspace root was lost")
  end
  local ctx = assert(ue.resolve_context())
  assert(ctx.uproject == expected, "context still points at old project")
  if vim.fn.has("win32") == 1 then
    assert(state.update_target(engine, "Android", "Development"))
    local cmd, build_err = ue.android_build_command()
    assert(cmd, build_err)
    assert(table.concat(cmd, " "):find("-Project=" .. expected, 1, true), vim.inspect(cmd))
    assert(not table.concat(cmd, " "):find(old, 1, true), "build retained the old project")
  end
  if mode ~= "probe-failed" then
    local probe = require("utils.probe")
    local status = probe.status("project-selection")
    assert(
      status.observation and status.observation.revision == "completion-path-2026-09-11",
      "repair observation missing"
    )
    probe._flush_for_test()
    local evidence = vim.json.decode(table.concat(vim.fn.readfile(vim.env.NVIM_UE_PROBE_PATH), "\n"))
    local selected_record = evidence.topics["project-selection"].records.selected
    assert(selected_record.failure_count == 0, "successful selection counted as failure")
    assert(selected_record.stats.outcomes.resolved == 1, "successful selection classified as unknown")
  end
end)
require("utils.probe")._flush_for_test()
vim.cmd.cd(cfg)
-- root is created above by tempname; never delete user project directories.
vim.fn.delete(root, "rf")
if not ok then
  error(err)
end
print("project-selection " .. mode .. ": PASS")
