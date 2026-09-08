local t = require("tests.harness")
local cfg = t.bootstrap()

local function child(code)
  local result = vim.system({
    vim.v.progpath, "--headless", "-u", "NONE", "-i", "NONE",
    "-c", "lua vim.opt.rtp:prepend(" .. string.format("%q", cfg) .. "); " .. code,
    "-c", "qa!",
  }, { text = true, cwd = cfg }):wait(10000)
  t.assert_eq(result.code, 0, (result.stdout or "") .. (result.stderr or ""))
  t.assert_contains((result.stdout or "") .. (result.stderr or ""), "EDITOR_REVIEW_OK")
end

t.describe("review_editor: interaction regressions", function()
  t.it("visual replace captures first and subsequent live selections", function()
    child([[
      package.loaded['utils.window_title'] = { setup = function() end }
      package.loaded['utils.lsp_fallback'] = {}
      vim.g.mapleader = ' '
      dofile(vim.fn.getcwd() .. '/lua/config/keymaps.lua')
      local callback = vim.fn.maparg(' sr', 'x', false, true).callback
      local captured
      local feedkeys = vim.fn.feedkeys
      vim.fn.feedkeys = function(keys) captured = keys end
      vim.api.nvim_buf_set_lines(0, 0, -1, false, {'alpha beta', 'gamma delta'})
      vim.cmd('normal! gg0v4l')
      callback()
      vim.wait(20)
      assert(captured and captured:find('alpha', 1, true), tostring(captured))
      assert(not vim.fn.mode():find('[vV]'), 'selection must be exited')
      feedkeys(captured .. 'OMEGA' .. vim.api.nvim_replace_termcodes('<CR>a', true, false, true), 'xt')
      assert(vim.api.nvim_get_current_line() == 'OMEGA beta', vim.api.nvim_get_current_line())
      captured = nil
      vim.cmd('normal! 2G0v4l')
      callback()
      vim.wait(20)
      assert(captured and captured:find('gamma', 1, true), tostring(captured))
      assert(not captured:find('alpha', 1, true), 'stale selection used')
      print('EDITOR_REVIEW_OK')
    ]])
  end)

  t.it("picker jump preserves the next deliberate cursor movement", function()
    child([[
      package.loaded['workarounds.snacks.projects_picker_freeze'] = { apply = function() end }
      package.loaded['workarounds.snacks.smart_picker_dead_buffer'] = { apply = function() end }
      package.loaded['dashboard_pix'] = {}
      local upstream = function() vim.api.nvim_win_set_cursor(0, {2, 0}) end
      package.loaded['snacks.picker.actions'] = { jump = upstream }
      local spec = dofile(vim.fn.getcwd() .. '/lua/plugins/snacks.lua')[1]
      local opts = spec.opts(nil, {})
      vim.g.neovide = true
      vim.api.nvim_buf_set_lines(0, 0, -1, false, {'one', 'two', 'three'})
      local jump = opts.picker.actions.jump or upstream
      jump({}, {})
      vim.wait(30)
      vim.cmd('normal! j')
      vim.api.nvim_exec_autocmds('CursorMoved', {})
      assert(vim.api.nvim_win_get_cursor(0)[1] == 3, 'intentional j was reverted')
      print('EDITOR_REVIEW_OK')
    ]])
  end)

  t.it("git sidebar preserves literal paths and consumes rename source records", function()
    child([[
      package.loaded['trouble.item'] = { new = function(x) return x end, add_id = function() end }
      package.loaded['trouble'] = { is_open = function() return false end }
      local names = {'foo bar.cpp', 'new -> name.cpp', 'unicode-中文.cpp'}
      local command
      vim.system = function(cmd, opts, cb)
        command = cmd
        cb({code = 0, stdout = ' M ' .. names[1] .. '\0R  ' .. names[2]
          .. '\0old name.cpp\0 M ' .. names[3] .. '\0', stderr = ''})
      end
      local source = require('trouble.sources.ue_sidebar')
      source.get.git_status(function() end)
      vim.wait(20)
      assert(vim.tbl_contains(command, '-z'), 'porcelain must use NUL paths')
      source.get.git_status(function(items)
        assert(#items == #names, vim.inspect(items))
        for i, name in ipairs(names) do
          assert(items[i].filename == vim.fs.joinpath(vim.uv.cwd(), name), vim.inspect(items[i]))
        end
      end)
      print('EDITOR_REVIEW_OK')
    ]])
  end)

  t.it("git sidebar reads real porcelain output for spaced and Unicode filenames", function()
    child([[
      local root = vim.fs.normalize(vim.fn.tempname() .. '-review-editor')
      vim.fn.mkdir(root, 'p')
      local owned_root = vim.uv.fs_realpath(root)
      local ok, err = pcall(function()
        local function git(args)
          local cmd = {'git', '-C', root}
          vim.list_extend(cmd, args)
          local result = vim.system(cmd, {text = true}):wait(5000)
          assert(result.code == 0, result.stderr)
        end
        git({'init', '-q'})
        local names = {'foo bar.cpp', 'new name.cpp', 'unicode-中文.cpp'}
        for _, name in ipairs(names) do
          vim.fn.writefile({'int value;'}, root .. '/' .. name)
          git({'add', '--', name})
        end
        package.loaded['trouble.item'] = {new = function(x) return x end, add_id = function() end}
        package.loaded['trouble'] = {is_open = function() return false end}
        _G.LazyVim = {root = {git = function() return root end}}
        local source = require('trouble.sources.ue_sidebar')
        local items
        source.get.git_status(function() end)
        assert(vim.wait(5000, function()
          source.get.git_status(function(value) items = value end)
          return items and #items == 3 and items[1].item.kind == 'git_status'
        end, 20), vim.inspect(items))
        local found = {}
        for _, item in ipairs(items) do found[item.filename] = true end
        for _, name in ipairs(names) do
          assert(found[vim.fs.joinpath(root, name)], vim.inspect(items))
        end
      end)
      assert(owned_root and owned_root == vim.uv.fs_realpath(root), 'temporary root changed')
      vim.fn.delete(owned_root, 'rf')
      assert(ok, err)
      print('EDITOR_REVIEW_OK')
    ]])
  end)
end)

t.describe("review_editor: toolchain policy", function()
  t.it("health mode never clones a missing lazy installation", function()
    child([[
      vim.env.NVIM_CORE_HEALTH_NO_MUTATE = '1'
      local stat = vim.uv.fs_stat
      local lazy_path = vim.fn.stdpath('data') .. '/lazy/lazy.nvim'
      vim.uv.fs_stat = function(path, ...)
        if path == lazy_path then return nil end
        return stat(path, ...)
      end
      local cloned = false
      vim.fn.system = function() cloned = true; return '' end
      package.loaded.lazy = {setup = function() end}
      local ok, err = pcall(dofile, vim.fn.getcwd() .. '/lua/config/lazy.lua')
      assert(not cloned, 'health probe attempted network bootstrap')
      assert(not ok and tostring(err):find('lazy.nvim', 1, true), 'missing dependency must fail closed')
      print('EDITOR_REVIEW_OK')
    ]])
  end)

  t.it("merged upstream Mason configs cannot install tools or servers", function()
    child([[
      local policy_path = vim.fn.getcwd() .. '/lua/plugins/toolchain.lua'
      local policy = vim.fn.filereadable(policy_path) == 1 and dofile(policy_path) or {}
      local upstream = dofile(vim.fn.stdpath('data') .. '/lazy/LazyVim/lua/lazyvim/plugins/lsp/init.lua')
      local by_name = {}
      for _, spec in ipairs(policy) do by_name[spec[1]:match('[^/]+$')] = spec end
      local function merged(name, opts)
        if by_name[name] then return by_name[name].opts(nil, opts) or opts end
        return opts
      end
      local installed = 0
      local mason_setup = false
      package.loaded.mason = {setup = function() mason_setup = true end}
      package.loaded['mason-registry'] = {
        on = function() end,
        refresh = function(cb) cb() end,
        get_package = function() return {
          is_installed = function() return false end,
          install = function() installed = installed + 1 end,
        } end,
      }
      local server_install
      package.loaded['mason-lspconfig'] = {setup = function(opts) server_install = opts.ensure_installed end}
      package.loaded['mason-lspconfig.mappings'] = {get_mason_map = function()
        return {lspconfig_to_package = {clangd = 'clangd', lua_ls = 'lua-language-server', disabled = 'disabled'}}
      end}
      package.loaded['lazyvim.plugins.lsp.keymaps'] = {set = function() end}
      local declared = {clangd = {}, lua_ls = true, disabled = false, ['*'] = {}}
      local configured, enabled = {}, {}
      vim.lsp.config = function(name, opts) configured[name] = opts end
      vim.lsp.enable = function(name) enabled[name] = true end
      _G.LazyVim = {
        format = {register = function() end}, lsp = {formatter = function() return {} end},
        has = function() return true end,
        opts = function() return merged('mason-lspconfig.nvim', {ensure_installed = {'extra_ls'}}) end,
      }
      local opts = merged('nvim-lspconfig', {
        servers = declared, setup = {}, diagnostics = {},
        inlay_hints = {enabled = false}, folds = {enabled = false}, codelens = {enabled = false},
      })
      upstream[1].config(nil, opts)
      local tools = merged('mason.nvim', {ensure_installed = {'stylua', 'shfmt'}})
      for _, spec in ipairs(upstream) do
        if spec[1]:match('/mason.nvim$') then
          assert(spec.cmd == 'Mason', 'manual Mason entry must remain')
          local configure = by_name['mason.nvim'] and by_name['mason.nvim'].config or spec.config
          configure(nil, tools)
        end
      end
      assert(installed == 0, 'upstream installed ' .. installed .. ' tools')
      assert(mason_setup, 'manual Mason must remain configured')
      assert(server_install and #server_install == 0, vim.inspect(server_install))
      assert(configured.clangd.mason == false and configured.lua_ls.mason == false)
      assert(enabled.clangd and enabled.lua_ls and not enabled.disabled and not enabled.extra_ls)
      print('EDITOR_REVIEW_OK')
    ]])
  end)
end)
