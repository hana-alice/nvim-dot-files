local t = require("tests.harness")
t.bootstrap()
local api = vim.api
local O = require("utils.ue_onboarding")
local H = require("utils.ue_hub")
local W = require("utils.development_workbench")

local function fixture(check)
  local before = { target = H.target, rows = H.target_rows, readiness = O.readiness,
    select = vim.ui.select, cmd = vim.cmd, snacks = package.loaded.snacks }
  local source_win, source_buf = api.nvim_get_current_win(), api.nvim_get_current_buf()
  local buf = api.nvim_create_buf(true, false)
  api.nvim_win_set_buf(source_win, buf)
  api.nvim_buf_set_lines(buf, 0, -1, false, { "keep this unsaved text" })
  local f = { target = { platform = "", configuration = "", state = {} }, choices = {}, commands = {}, ready = "missing" }
  H.target = function() return vim.deepcopy(f.target) end
  H.target_rows = function(target)
    local rows = {
      { label = "Project", value = target.project or "(none)", run = function() vim.cmd("UESetProject") end },
      { label = "Platform", value = target.platform, run = function() vim.cmd("UESetPlatform") end },
    }
    if f.mobile then
      for _, field in ipairs({ "Device", "Package" }) do
        rows[#rows + 1] = { label = field, value = f[field] or "(none)",
          run = function() vim.cmd("Set" .. field) end }
      end
    end
    return rows
  end
  O.readiness = function() return f.ready end
  package.loaded.snacks = {}
  vim.ui.select = function(items, opts, done)
    f.choices[#f.choices + 1] = { items = items, opts = opts, done = done }
  end
  vim.cmd = function(command) f.commands[#f.commands + 1] = command end
  f.win, f.buf, f.actual_cmd = source_win, buf, before.cmd
  local ok, err = pcall(check, f)
  O.cancel()
  H.target, H.target_rows, O.readiness = before.target, before.rows, before.readiness
  vim.ui.select, vim.cmd, package.loaded.snacks = before.select, before.cmd, before.snacks
  api.nvim_win_set_buf(source_win, source_buf)
  api.nvim_buf_delete(buf, { force = true })
  if not ok then error(err, 0) end
end

local function choose(f, index, item)
  local choice = assert(f.choices[index], "missing guided prompt " .. index)
  choice.done(choice.items[item or 1], item or 1)
end

local function updated(f, expected)
  H.selection_changed()
  t.assert_true(vim.wait(1000, function() return #f.choices == expected end, 5))
end

t.describe("workbench onboarding: continuous intent and cancellation", function()
  t.it("orders missing items using the selected target's existing fields", function()
    fixture(function(f)
      f.mobile = true
      local steps = O.steps(f.target)
      t.assert_true(vim.deep_equal(vim.tbl_map(function(step) return step.id end, steps),
        { "project", "platform", "Device", "Package", "prepare" }))
      f.target.project, f.target.platform, f.target.configuration = "Example", "Selected", "Development"
      f.Device, f.Package, f.ready = "a selected device", "a selected app", "ready"
      t.assert_eq(#O.steps(f.target), 0)
    end)
  end)

  t.it("each committed item automatically enters the next picker and prepare still needs consent", function()
    fixture(function(f)
      f.mobile = true
      t.assert_true(O.start({ source_win = f.win }))
      choose(f, 1)
      t.assert_eq(f.commands[1], "UESetProject")
      f.target.project, f.target.project_root, f.target.engine_root = "Example", "/fixture/example", "/fixture/engine"
      updated(f, 2)
      t.assert_eq(f.choices[2].items[1].label, "Platform")
      choose(f, 2)
      t.assert_eq(f.commands[2], "UESetPlatform")
      f.target.platform, f.target.configuration = "Selected", "Development"
      updated(f, 3)
      t.assert_eq(f.choices[3].items[1].label, "Device")
      choose(f, 3)
      f.Device = "chosen"
      updated(f, 4)
      t.assert_eq(f.choices[4].items[1].label, "Package")
      choose(f, 4)
      f.Package = "chosen"
      updated(f, 5)
      t.assert_contains(f.choices[5].items[1], "确认运行 :UEPrepare")
      t.assert_false(vim.tbl_contains(f.commands, "UEPrepare"))
      t.assert_true(vim.bo[f.buf].modified)
    end)
  end)

  t.it("cancel at every prompt invalidates later selection events and old confirmations", function()
    for _, phase in ipairs({ "project", "platform", "prepare" }) do
      fixture(function(f)
        if phase ~= "project" then
          f.target.project, f.target.project_root = "Example", "/fixture/example"
        end
        if phase == "prepare" then
          f.target.platform, f.target.configuration = "Selected", "Development"
        end
        O.start({ source_win = f.win })
        local prompt = f.choices[1]
        prompt.done(nil)
        t.assert_nil(O.current())
        prompt.done(prompt.items[1], 1)
        H.selection_changed()
        vim.wait(30)
        t.assert_eq(#f.commands, 0, phase)
        t.assert_eq(#f.choices, 1, phase)
      end)
    end
  end)

  t.it("changed text, source identity and a new project revoke pending prepare", function()
    for _, drift in ipairs({ "text", "buffer", "rename", "cursor", "project" }) do
      fixture(function(f)
        f.target.project, f.target.project_root, f.target.engine_root = "Example", "/fixture/example", "/fixture/engine"
        f.target.platform, f.target.configuration = "Selected", "Development"
        O.start({ source_win = f.win })
        if drift == "text" then api.nvim_buf_set_lines(f.buf, 0, -1, false, { "new input" })
        elseif drift == "buffer" then api.nvim_win_set_buf(f.win, api.nvim_create_buf(true, false))
        elseif drift == "rename" then api.nvim_buf_set_name(f.buf, vim.fn.tempname())
        elseif drift == "cursor" then api.nvim_win_set_cursor(f.win, { 1, 3 })
        else f.target.project_root = "/fixture/new-project" end
        choose(f, 1)
        t.assert_eq(#f.commands, 0, drift)
        t.assert_nil(O.current())
      end)
    end
  end)

  t.it("closing an old target picker cannot cancel a newer wizard", function()
    fixture(function(f)
      f.target.project, f.target.project_root = "Example", "/fixture/example"
      O.start({ source_win = f.win })
      local old = f.choices[1]
      O.start({ source_win = f.win })
      old.done(nil)
      old.done(old.items[1])
      t.assert_true(O.current() ~= nil)
      t.assert_eq(#f.commands, 0)
      choose(f, 2)
      t.assert_eq(f.commands[1], "UESetPlatform")
    end)
  end)

  t.it("a ready selection skips setup and doctor is invoked only once", function()
    fixture(function(f)
      f.target.project, f.target.project_root = "Example", "/fixture/example"
      f.target.platform, f.target.configuration, f.ready = "Selected", "Development", "ready"
      O.start({ source_win = f.win })
      H.selection_changed()
      vim.wait(30)
      t.assert_eq(#f.choices, 0)
      t.assert_eq(#f.commands, 1)
      t.assert_eq(f.commands[1], "UEDoctor")
      t.assert_nil(O.current())
    end)
  end)

  t.it("the real UEPrepare command checks its captured guard before deferred work starts", function()
    require("ue").setup()
    fixture(function(f)
      f.target.project, f.target.project_root = "Example", "/fixture/example"
      f.target.platform, f.target.configuration = "Selected", "Development"
      local launcher = require("utils.async_launcher")
      local original, captured = launcher.launch
      launcher.launch = function(opts) captured = opts end
      local patched_cmd = vim.cmd
      -- Use the actual command definition, without running a prepare or faking a host.
      vim.cmd = function(cmd)
        if cmd == "UEPrepare" then return f.actual_cmd(cmd) end
        patched_cmd(cmd)
      end
      local ok, err = pcall(function()
        O.start({ source_win = f.win })
        choose(f, 1)
        t.assert_true(captured ~= nil)
        O.cancel()
        local original_resolve = require("ue").resolve_context
        local source_tick = api.nvim_buf_get_changedtick(f.buf)
        captured.run()
        t.assert_nil(O.current())
        t.assert_eq(#f.commands, 0)
        t.assert_eq(api.nvim_buf_get_changedtick(f.buf), source_tick)
        t.assert_eq(require("ue").resolve_context, original_resolve)
      end)
      launcher.launch = original
      if not ok then error(err, 0) end
    end)
  end)
end)

t.describe("workbench: one main entry and intent-based recovery", function()
  t.it("only five sections are displayed and recovery delegates all existing owners", function()
    fixture(function(f)
      local model = W.model({ target = f.target })
      t.assert_eq(#model.sections, 5)
      for i, label in ipairs({ "当前目标", "下一步", "最近结果", "运行中任务", "恢复" }) do
        t.assert_contains(model.sections[i].label, label)
      end
      local recovery = W.recovery_actions(f.target)
      local commands = {}
      for _, action in ipairs(recovery) do
        action.run()
        commands[#commands + 1] = action.command
      end
      t.assert_true(vim.deep_equal(commands, { "UEWorkspace logs", "UEWorkspace", "UEWorkContext", "UESessionRestore", "UERecovery" }))
      t.assert_true(vim.deep_equal(f.commands, commands))
      local visible = H.visible_actions(f.target)
      t.assert_eq(visible[1].key, "<leader>uH")
      for _, action in ipairs(H.actions) do
        if action.command and (action.command:find("UEWorkspace", 1, true)
          or action.command == "UEWorkContext" or action.command == "UERecovery"
          or action.command == "UESessionRestore") then
          t.assert_eq(action.group, "Recovery")
        end
      end
    end)
  end)
end)
