local t = require("tests.harness")
local cfg = t.bootstrap()

t.describe("daily_edit: 真实配置延迟加载接线", function()
  t.it("UIEnter/VeryLazy 后格式化、退出和内联提示键真实生效", function()
    local script = vim.fn.tempname() .. ".lua"
    local code = [[
      vim.api.nvim_exec_autocmds('UIEnter', {})
      vim.api.nvim_exec_autocmds('User', {pattern='VeryLazy'})
      require('lazy').load({plugins={'nvim-lspconfig', 'conform.nvim'}})
      local plugin = require('lazy.core.config').plugins['nvim-lspconfig']
      local opts = require('lazy.core.plugin').values(plugin, 'opts', false)
      assert(opts.inlay_hints.enabled == true)
      assert(vim.g.autoformat == false)
      for _, mode in ipairs({'n', 'x'}) do
        local cf = vim.fn.maparg('<leader>cf', mode, false, true)
        assert(type(cf.callback) == 'function' and cf.desc:find('Format safely', 1, true), vim.inspect(cf))
      end
      assert(vim.fn.maparg('<leader>qq', 'n'):find('UEQuit', 1, true))
      local hints = vim.fn.maparg('<leader>uh', 'n', false, true)
      assert(type(hints.callback) == 'function', vim.inspect(hints))
      local before = vim.lsp.inlay_hint.is_enabled({bufnr=0})
      hints.callback()
      assert(vim.lsp.inlay_hint.is_enabled({bufnr=0}) ~= before)
      hints.callback()
      assert(vim.lsp.inlay_hint.is_enabled({bufnr=0}) == before)
      for _, name in ipairs({'UEFormat', 'UEQuit', 'UEUnsaved'}) do assert(vim.fn.exists(':' .. name) == 2) end
      local persistence = package.loaded.persistence
      if persistence then persistence.stop() end
      print('DAILY_EDIT_LOADED_OK')
      vim.cmd('qa!')
    ]]
    vim.fn.writefile(vim.split(code, "\n", { plain = true }), script)
    local command = {
      vim.v.progpath,
      "--headless",
      "-n",
      "-i",
      "NONE",
      "-u",
      cfg .. "/init.lua",
      "--cmd",
      "lua vim.g.started_with_stdin=true",
      "-c",
      ("lua dofile(%q)"):format(script),
    }
    local options = {
      text = true,
      cwd = cfg,
      env = { NVIM_CORE_HEALTH_NO_MUTATE = "1" },
    }
    local result = vim.system(command, options):wait(20000)
    vim.fn.delete(script)
    local output = (result.stdout or "") .. (result.stderr or "")
    t.assert_eq(result.code, 0, output)
    t.assert_contains(output, "DAILY_EDIT_LOADED_OK")
  end)
end)
