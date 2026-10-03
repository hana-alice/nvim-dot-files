local config = vim.fn.stdpath("config")
vim.opt.rtp:prepend(config)
package.path = config .. "/?.lua;" .. config .. "/?/init.lua;" .. package.path
local t = require("tests.harness")
t.bootstrap()

local keys = { "<leader>cI", "<leader>cO", "<leader>cB", "<leader>cD",
  "<leader>ss", "<leader>sS", "<leader>ca", "<leader>cr" }

t.describe("keymaps: clangd code navigation", function()
  t.it("real LazyVim/Snacks attachment installs local keys without touching other buffers", function()
    if vim.env.NVIM_TEST_CLANGD_KEYS_CHILD ~= "1" then
      -- Loading a partial lazy.nvim inside the shared runner changes later
      -- colorscheme behavior. Exercise real keymap wiring in its own process.
      local result = vim.system({
        vim.v.progpath, "--headless", "-u", "NONE", "-i", "NONE",
        "-l", config .. "/tests/cases/keymaps_cpp_navigation_spec.lua",
      }, { text = true, env = { NVIM_TEST_CLANGD_KEYS_CHILD = "1" } }):wait(20000)
      local output = (result.stdout or "") .. (result.stderr or "")
      t.assert_eq(result.code, 0, output)
      t.assert_contains(output, "2/2 passed, 0 failed")
      return
    end
    for _, plugin in ipairs({ "LazyVim", "snacks.nvim", "lazy.nvim" }) do
      vim.opt.rtp:append(vim.fn.stdpath("data") .. "/lazy/" .. plugin)
    end
    _G.Snacks = require("snacks")
    vim.g.mapleader = " "
    local opts = { servers = {} }
    require("plugins.ue")[2].opts(nil, opts)
    local before = {}
    for _, key in ipairs(keys) do before[key] = vim.fn.maparg(key, "n", false, true) end
    local original = vim.api.nvim_get_current_buf()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(buf)
    local closing = false
    local client_id = vim.lsp.start({
      name = "clangd",
      root_dir = vim.fn.tempname(),
      cmd = function(dispatchers)
        return {
          request = function(method, _, callback)
            vim.schedule(function()
              if method == "initialize" then
                callback(nil, { capabilities = {
                  callHierarchyProvider = true, typeHierarchyProvider = true,
                  documentSymbolProvider = true, workspaceSymbolProvider = true,
                  renameProvider = true, codeActionProvider = true,
                } })
              else callback(nil, nil) end
            end)
            return true, 1
          end,
          notify = function() return true end,
          is_closing = function() return closing end,
          terminate = function() closing = true; dispatchers.on_exit(0, 0) end,
        }
      end,
    }, { bufnr = buf })
    local attached = vim.wait(1000, function()
      local client = vim.lsp.get_client_by_id(client_id)
      return client and client.initialized
    end, 10)
    require("lazyvim.plugins.lsp.keymaps").set({ name = "clangd" }, opts.servers.clangd.keys)
    vim.wait(1000, function() return vim.fn.maparg("<leader>cD", "n", false, true).buffer == 1 end, 10)
    local local_maps = {}
    for _, key in ipairs(keys) do local_maps[key] = vim.fn.maparg(key, "n", false, true) end
    local visual = vim.fn.maparg("<leader>ca", "x", false, true)
    vim.api.nvim_set_current_buf(original)
    local after = {}
    for _, key in ipairs(keys) do after[key] = vim.fn.maparg(key, "n", false, true) end
    vim.lsp.get_client_by_id(client_id):stop(true)
    vim.api.nvim_buf_delete(buf, { force = true })
    t.assert_true(attached)
    for _, key in ipairs(keys) do
      t.assert_eq(local_maps[key].buffer, 1, key .. " must be buffer-local")
      t.assert_type(local_maps[key].callback, "function", key)
      t.assert_eq(after[key].callback, before[key].callback, key .. " changed a global mapping")
      t.assert_eq(after[key].rhs, before[key].rhs, key .. " changed a global mapping")
    end
    t.assert_eq(visual.buffer, 1)
  end)

  t.it("hub and both help surfaces expose every code action", function()
    local hub = require("utils.ue_hub")
    local md = table.concat(vim.fn.readfile(vim.fn.stdpath("config") .. "/docs/ue_lazyvim_cheatsheet.md"), "\n")
    for _, key in ipairs(keys) do
      local found = false
      for _, action in ipairs(hub.actions) do if action.key == key then found = true end end
      t.assert_true(found, "hub lacks " .. key)
      t.assert_true(#require("utils.cheatsheet").search(key) > 0)
      t.assert_contains(md, key)
    end
  end)
end)

if vim.env.NVIM_TEST_CLANGD_KEYS_CHILD == "1" then t.run() end
