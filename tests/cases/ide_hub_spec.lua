local t = require("tests.harness")
t.bootstrap()

t.describe("ide_hub: context-aware actions", function()
  local hub = require("utils.ue_hub")
  t.it("shows the missing prerequisite before invoking the action", function()
    local action = { label = "Build", group = "Build", requires = { "project", "platform" } }
    local state = hub.action_state(action, { platform = "", state = {} })
    t.assert_false(state.ready)
    t.assert_eq(state.fix, "UESetProject")
    t.assert_contains(state.reason, "工程")
    state = hub.action_state(action, { project = "Game", platform = "", state = {} })
    t.assert_eq(state.fix, "UESetPlatform")
    t.assert_true(hub.action_state(action, { project = "Game", platform = "Win64", state = {} }).ready)
  end)
  t.it("keeps help and cancellation available without a project", function()
    t.assert_true(hub.action_state({ group = "Help", label = "Guide" }, { platform = "", state = {} }).ready)
    t.assert_true(
      hub.action_state({ group = "Debug", label = "Stop", always = true }, { platform = "", state = {} }).ready
    )
  end)
  t.it("cancelled setup never starts the original action", function()
    local select = vim.ui.select
    local calls = 0
    vim.ui.select = function(_, _, done)
      done(nil)
    end
    local ok, err = pcall(hub.invoke_action, {
      label = "Build",
      group = "Build",
      run = function()
        calls = calls + 1
      end,
    }, { target = { platform = "", state = {} } })
    vim.ui.select = select
    t.assert_true(ok, err)
    t.assert_eq(calls, 0)
    t.assert_nil(hub.pending_action())
  end)
  t.it("legacy actions remain immutable when annotated for a target", function()
    local before = vim.deepcopy(hub.actions)
    local actions = hub.visible_actions({ project = nil, platform = "Win64", state = {} })
    t.assert_false(actions[1].readiness.ready)
    t.assert_contains(hub.format_action(actions[1]), "工程")
    t.assert_eq(hub.actions[1].readiness, nil)
    t.assert_eq(hub.actions[1].label, before[1].label)
  end)

  local function continuation(check)
    local original_target, original_select, original_cmd = hub.target, vim.ui.select, vim.cmd
    local targets = require("ue.targets")
    local original_driver, device = targets.driver, { serial = "device-a" }
    targets.driver = function()
      return {
        hub = function()
          return {
            fields = {
              { name = "device", value = "same display label", identity = device.serial },
            },
          }
        end,
      }
    end
    local source = vim.api.nvim_get_current_buf()
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_set_current_buf(buf)
    local ctx = { platform = "", configuration = "", state = {} }
    local choices, commands, runs = {}, {}, 0
    local action = {
      label = "fixture build",
      group = "Build",
      run = function()
        runs = runs + 1
      end,
    }
    hub.target = function()
      return vim.deepcopy(ctx)
    end
    vim.ui.select = function(items, _, done)
      choices[#choices + 1] = { items = items, done = done }
    end
    vim.cmd = function(name)
      commands[#commands + 1] = name
    end
    local function configure()
      hub.invoke_action(action)
      choices[1].done(choices[1].items[1])
      ctx.project, ctx.project_root, ctx.engine_root = "Game", "/fixture/game", "/fixture/engine"
      ctx.platform, ctx.configuration = "Win64", "Development"
      hub.selection_changed()
      t.assert_true(vim.wait(1000, function()
        return #choices == 2
      end, 5))
    end
    local ok, err = pcall(check, {
      configure = configure,
      choices = choices,
      ctx = ctx,
      buf = buf,
      action = action,
      device = device,
      runs = function()
        return runs
      end,
      commands = commands,
    })
    -- End the fixture's intent so its delayed expiry cannot affect later tests.
    hub.invoke_action({ always = true, run = function() end })
    hub.target, vim.ui.select, vim.cmd = original_target, original_select, original_cmd
    targets.driver = original_driver
    vim.api.nvim_set_current_buf(source)
    vim.api.nvim_buf_delete(buf, { force = true })
    if not ok then
      error(err, 0)
    end
  end

  t.it("successful setup resumes once only after explicit confirmation", function()
    continuation(function(f)
      f.configure()
      t.assert_eq(f.commands[1], "UESetProject")
      t.assert_eq(f.runs(), 0)
      f.choices[2].done(f.choices[2].items[1])
      t.assert_eq(f.runs(), 1)
      -- An old confirmation cannot run the intent a second time.
      f.choices[2].done(f.choices[2].items[1])
      t.assert_eq(f.runs(), 1)
    end)
  end)

  t.it("cancel, intervening edits, target drift and a newer action reject old continuation", function()
    for _, scenario in ipairs({ "cancel", "edit", "rename", "target", "device", "new-intent" }) do
      continuation(function(f)
        f.configure()
        if scenario == "edit" then
          vim.api.nvim_buf_set_lines(f.buf, 0, -1, false, { "new input" })
        elseif scenario == "rename" then
          vim.api.nvim_buf_set_name(f.buf, vim.fn.tempname() .. ".cpp")
        elseif scenario == "target" then
          f.ctx.project_root = "/fixture/other-game"
        elseif scenario == "device" then
          f.device.serial = "device-b"
        elseif scenario == "new-intent" then
          hub.invoke_action({ always = true, run = function() end })
        end
        f.choices[2].done(scenario == "cancel" and "取消" or f.choices[2].items[1])
        t.assert_eq(f.runs(), 0, scenario)
        t.assert_nil(hub.pending_action())
      end)
    end
  end)

  t.it("uses actual client capabilities and keeps active-session F5 available", function()
    local target = { platform = "", state = {} }
    local action = { label = "Rename", group = "Code", key = "<leader>cr" }
    t.assert_false(hub.action_state(action, target, { clients = {} }).ready)
    local client = {
      supports_method = function(_, method)
        return method == "textDocument/rename"
      end,
    }
    t.assert_true(hub.action_state(action, target, { clients = { client } }).ready)
    local dap = package.loaded.dap
    package.loaded.dap = {
      session = function()
        return {}
      end,
    }
    local state = hub.action_state({ group = "Run", key = "<F5>" }, target)
    package.loaded.dap = dap
    t.assert_true(state.ready)
  end)

  t.it("search hub uses the advertised code-search key and reports an unavailable mapping", function()
    local action
    for _, entry in ipairs(hub.actions) do
      if entry.group == "Search" and entry.key == "<leader>sg" then
        action = entry
        break
      end
    end
    t.assert_true(action ~= nil)
    local before = vim.fn.maparg("<leader>sg", "n", false, true)
    local notify, calls, notices = vim.notify, 0, {}
    vim.keymap.set("n", "<leader>sg", function()
      calls = calls + 1
    end)
    vim.notify = function(message, level)
      notices[#notices + 1] = { message, level }
    end
    local ok, err = pcall(function()
      action.run()
      t.assert_eq(calls, 1, "Hub must preserve the same code masks and fallback as its advertised key")
      vim.keymap.del("n", "<leader>sg")
      action.run()
      t.assert_eq(calls, 1)
      t.assert_eq(#notices, 1, "missing search action must be visible")
      t.assert_eq(notices[1][2], vim.log.levels.WARN)
    end)
    vim.notify = notify
    pcall(vim.keymap.del, "n", "<leader>sg")
    if next(before) then
      vim.fn.mapset("n", false, before)
    end
    if not ok then
      error(err, 0)
    end
  end)
end)
