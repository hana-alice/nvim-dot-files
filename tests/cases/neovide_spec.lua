-- tests/cases/neovide_spec.lua
-- Neovide macOS folder workflow: native selection, cwd handoff, dashboard entry.

local t = require("tests.harness")
local cfg = t.bootstrap()
local neovide = require("config.neovide")

t.describe("neovide: macOS Open Folder", function()
  t.it("executes the host plan and normalizes the selected directory", function()
    local command
    local opened
    local ok = neovide.open_folder({
      driver = {
        folder_picker_plan = function()
          return { executable = "/usr/bin/osascript", args = { "-e", "choose folder" } }
        end,
      },
      run = function(argv, _, callback)
        command = argv
        callback({ code = 0, stdout = "/Users/example/Projects/SampleGame/\n", stderr = "" })
        return { pid = 1 }
      end,
      schedule = function(callback) callback() end,
      is_directory = function(path)
        return path == "/Users/example/Projects/SampleGame" and 1 or 0
      end,
      on_open = function(path) opened = path end,
    })

    t.assert_true(ok)
    t.assert_eq(command[1], "/usr/bin/osascript")
    t.assert_eq(command[2], "-e")
    t.assert_eq(opened, "/Users/example/Projects/SampleGame")
  end)

  t.it("treats native dialog cancellation as a silent no-op", function()
    local notifications = 0
    local ok = neovide.open_folder({
      driver = {
        folder_picker_plan = function()
          return { executable = "/usr/bin/osascript", args = {} }
        end,
      },
      run = function(_, _, callback)
        callback({ code = 1, stdout = "", stderr = "execution error: User canceled. (-128)" })
        return { pid = 1 }
      end,
      schedule = function(callback) callback() end,
      notify = function() notifications = notifications + 1 end,
    })

    t.assert_true(ok)
    t.assert_eq(notifications, 0)
  end)

  t.it("dashboard exposes exactly one macOS Neovide o entry", function()
    local specs = dofile(cfg .. "/lua/plugins/snacks.lua")
    local configure
    for _, spec in ipairs(specs) do
      if spec[1] == "folke/snacks.nvim" and type(spec.opts) == "function" then
        configure = spec.opts
        break
      end
    end
    t.assert_type(configure, "function")

    local opts = { dashboard = { preset = { keys = {} } } }
    configure(nil, opts)
    configure(nil, opts)

    local matches = {}
    for _, item in ipairs(opts.dashboard.preset.keys) do
      if item.key == "o" then matches[#matches + 1] = item end
    end
    t.assert_eq(#matches, 1)
    t.assert_eq(matches[1].desc, "Open Folder")
    t.assert_type(matches[1].action, "function")
    t.assert_type(matches[1].enabled, "function")
  end)
end)
