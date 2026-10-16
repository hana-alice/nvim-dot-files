local t = require("tests.harness")
t.bootstrap()

-- These fixtures verify Hub dispatch; installed picker/Trouble behavior is
-- covered separately by native integration checks.
t.describe("ide_flow_hub: daily navigation and problem entrypoints", function()
  local hub = require("utils.ue_hub")
  local target = { platform = "", state = {} }

  local function action_for(key)
    for _, action in ipairs(hub.actions) do
      if action.key == key then
        return action
      end
    end
    error("missing Hub action: " .. key)
  end

  local function fixture(check)
    local undo = {}
    local function patch(object, key, value)
      local before = object[key]
      undo[#undo + 1] = function()
        object[key] = before
      end
      object[key] = value
    end
    local function mapping(key, callback)
      local before = vim.fn.maparg(key, "n", false, true)
      undo[#undo + 1] = function()
        pcall(vim.keymap.del, "n", key)
        if next(before) then
          vim.fn.mapset("n", false, before)
        end
      end
      vim.keymap.set("n", key, callback)
    end
    local ok, err = pcall(check, patch, mapping)
    for i = #undo, 1, -1 do
      undo[i]()
    end
    if not ok then
      error(err, 0)
    end
  end

  t.it("document outline stays available for fallback without querying clangd", function()
    fixture(function(patch)
      patch(vim.lsp, "get_clients", function()
        error("outline readiness must let the configured provider choose its fallback")
      end)
      local action = action_for("<leader>ss")
      for _, clients in ipairs({ {}, { { name = "pyright" } }, { { name = "clangd" } } }) do
        t.assert_true(hub.action_state(action, target, { clients = clients }).ready)
      end
      t.assert_true(hub.action_state(action, target).ready)
    end)
  end)

  t.it("document outline invokes the current configured key callback", function()
    fixture(function(patch, mapping)
      patch(vim.lsp, "get_clients", function()
        return {}
      end)
      local first, replacement = 0, 0
      mapping("<leader>ss", function()
        first = first + 1
      end)
      local action = action_for("<leader>ss")
      hub.invoke_action(action, { target = target })
      mapping("<leader>ss", function()
        replacement = replacement + 1
      end)
      hub.invoke_action(action, { target = target })
      t.assert_eq(first, 1)
      t.assert_eq(replacement, 1, "Hub must reuse the latest outline provider callback")
    end)
  end)

  t.it("workspace symbols accept another capable provider attached to the source", function()
    fixture(function(patch, mapping)
      local calls, requested = 0, {}
      patch(vim.lsp, "get_clients", function(opts)
        t.assert_nil(opts.name, "workspace symbols must not filter providers by clangd")
        t.assert_eq(opts.bufnr, vim.api.nvim_get_current_buf())
        return {
          {
            name = "pyright",
            supports_method = function(_, method, buf)
              requested[#requested + 1] = { method, buf }
              return method == "workspace/symbol"
            end,
          },
        }
      end)
      mapping("<leader>sS", function()
        calls = calls + 1
      end)
      hub.invoke_action(action_for("<leader>sS"), { target = target })
      t.assert_eq(calls, 1)
      t.assert_eq(requested[1][1], "workspace/symbol")
      t.assert_eq(requested[1][2], vim.api.nvim_get_current_buf())
    end)
  end)

  t.it("workspace symbols refuse an attached provider without the capability", function()
    fixture(function(patch, mapping)
      local calls, prompts = 0, 0
      patch(vim.lsp, "get_clients", function()
        return {
          {
            name = "pyright",
            supports_method = function()
              return false
            end,
          },
        }
      end)
      patch(vim.ui, "select", function(_, opts, done)
        prompts = prompts + 1
        t.assert_contains(opts.prompt, "提供者")
        done(nil)
      end)
      mapping("<leader>sS", function()
        calls = calls + 1
      end)
      hub.invoke_action(action_for("<leader>sS"), { target = target })
      t.assert_eq(calls, 0)
      t.assert_eq(prompts, 1)
      t.assert_nil(hub.pending_action())
    end)
  end)

  t.it("C++ rename still requires clangd before dispatching the key callback", function()
    fixture(function(patch, mapping)
      local clangd, calls, notices = nil, 0, 0
      patch(vim.lsp, "get_clients", function(opts)
        t.assert_eq(opts.name, "clangd")
        return clangd and { clangd } or {}
      end)
      patch(vim, "notify", function(_, level)
        t.assert_eq(level, vim.log.levels.WARN)
        notices = notices + 1
      end)
      mapping("<leader>cr", function()
        calls = calls + 1
      end)
      local action = action_for("<leader>cr")
      t.assert_false(hub.action_state(action, target).ready)
      action.run()
      t.assert_eq(calls, 0)
      t.assert_eq(notices, 1)
      clangd = {
        name = "clangd",
        supports_method = function(_, method)
          return method == "textDocument/rename"
        end,
      }
      t.assert_true(hub.action_state(action, target).ready)
      action.run()
      t.assert_eq(calls, 1)
    end)
  end)

  t.it("relationship browsers retain their clangd and capability guards", function()
    local checked = 0
    for _, action in ipairs(hub.actions) do
      if action.command and action.command:find("^UERelations ") and action.clangd_only then
        checked = checked + 1
        local function provider(name, supported)
          return {
            name = name,
            supports_method = function(_, method)
              t.assert_eq(method, action.method)
              return supported
            end,
          }
        end
        t.assert_false(hub.action_state(action, target, { clients = { provider("pyright", true) } }).ready)
        t.assert_false(hub.action_state(action, target, { clients = { provider("clangd", false) } }).ready)
        t.assert_true(hub.action_state(action, target, { clients = { provider("clangd", true) } }).ready)
      end
    end
    t.assert_eq(checked, 4, "all call and type relationship entrypoints must retain their guards")
  end)

  t.it("undo history, jumps and marks forward to the installed Snacks interfaces", function()
    fixture(function(patch)
      local calls = {}
      local picker = {}
      for _, name in ipairs({ "undo", "jumps", "marks" }) do
        picker[name] = function(...)
          t.assert_eq(select("#", ...), 0)
          calls[#calls + 1] = name
        end
      end
      patch(package.loaded, "snacks", { picker = picker })
      for _, key in ipairs({ "<leader>su", "<leader>sj", "<leader>sm" }) do
        action_for(key).run()
      end
      t.assert_true(vim.deep_equal(calls, { "undo", "jumps", "marks" }))
    end)
  end)

  t.it("word replacement uses the configured callback rather than constructing another command", function()
    fixture(function(_, mapping)
      local calls = 0
      mapping("<leader>sr", function()
        calls = calls + 1
      end)
      local action = action_for("<leader>sr")
      t.assert_true(hub.action_state(action, target).ready)
      action.run()
      t.assert_eq(calls, 1)
    end)
  end)

  t.it("diagnostic entrypoints dispatch their scope without replacing quickfix results", function()
    local before = vim.fn.getqflist({ id = 0, items = 0, title = 0, context = 0, idx = 0 })
    vim.fn.setqflist({}, "r", {
      title = "retained search fixture",
      items = { { filename = vim.fn.tempname() .. ".cpp", lnum = 7, col = 3, text = "search hit" } },
      context = { owner = "search-fixture" },
    })
    local saved = vim.fn.getqflist({ id = 0, items = 0, title = 0, context = 0, idx = 0 })
    local ok, err = pcall(fixture, function(patch)
      local toggles, searches = {}, 0
      patch(package.loaded, "trouble", {
        toggle = function(opts)
          toggles[#toggles + 1] = opts
        end,
      })
      patch(package.loaded, "snacks", {
        picker = {
          diagnostics = function(...)
            t.assert_eq(select("#", ...), 0)
            searches = searches + 1
          end,
        },
      })
      for _, key in ipairs({ "<leader>xx", "<leader>xX", "<leader>sd" }) do
        local action = action_for(key)
        t.assert_eq(action.group, "Problems")
        t.assert_true(hub.action_state(action, target).ready)
        action.run()
      end
      t.assert_eq(toggles[1], "diagnostics")
      t.assert_true(vim.deep_equal(toggles[2], { mode = "diagnostics", filter = { buf = 0 } }))
      t.assert_eq(searches, 1)
      t.assert_true(vim.deep_equal(vim.fn.getqflist({ id = 0, items = 0, title = 0, context = 0, idx = 0 }), saved))
    end)
    if before.id == 0 then
      vim.fn.setqflist({}, "f")
    else
      vim.fn.setqflist({}, "r", before)
    end
    if not ok then
      error(err, 0)
    end
  end)
end)
