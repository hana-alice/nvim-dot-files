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

  t.it("Git aliases delegate without opening or refreshing a Trouble Git view", function()
    child([[
      local opened = 0
      package.loaded['utils.git_review'] = {open = function() opened = opened + 1 end}
      package.loaded.trouble = {
        is_open = function() return false end,
        close = function() error('Git action must not close other sidebar views') end,
        open = function() error('Git action must not open a Trouble view') end,
        refresh = function() error('Git action must not refresh a Trouble view') end,
      }
      local sidebar = require('utils.sidebar')
      for _, alias in ipairs({'git_status', 'git', 'modified'}) do
        sidebar.open(alias)
        sidebar.toggle(alias)
      end
      vim.wait(30)
      assert(opened == 6, tostring(opened))
      assert(not sidebar.is_open('git_status') and not sidebar.is_any_open())
      local opts = dofile(vim.fn.getcwd() .. '/lua/plugins/sidebar.lua')[1].opts(nil, {})
      assert(opts.modes.ue_sidebar_git_status == nil)
      package.loaded['trouble.item'] = {new = function(item) return item end, add_id = function() end}
      local source = require('trouble.sources.ue_sidebar')
      assert(source.get.git_status == nil and source.request_refresh == nil)
      print('EDITOR_REVIEW_OK')
    ]])
  end)

  t.it("Git menu action closes its picker and preserves the last non-Git sidebar", function()
    child([[
      local active, opened
      package.loaded.trouble = {
        is_open = function(mode) return active == mode end,
        close = function() active = nil end,
        open = function(mode) active = mode end,
      }
      package.loaded['utils.git_review'] = {open = function()
        opened = true
        assert(vim.bo.filetype ~= 'ue-sidebar-picker', 'review must use original buffer context')
      end}
      local sidebar = require('utils.sidebar')
      sidebar.open('todo')
      assert(vim.wait(1000, function() return sidebar.is_open('todo') end, 10))
      sidebar.pick()
      local menu = vim.api.nvim_get_current_buf()
      assert(table.concat(vim.api.nvim_buf_get_lines(menu, 0, -1, false), '\n'):find('Git Review', 1, true))
      vim.fn.maparg('1', 'n', false, true).callback()
      assert(opened and not vim.api.nvim_buf_is_valid(menu))
      assert(sidebar.is_open('todo'), 'Git action must preserve unrelated sidebar')
      sidebar.close()
      sidebar.toggle()
      assert(vim.wait(1000, function() return sidebar.is_open('todo') end, 10))
      sidebar.close()
      sidebar.open('buffers')
      sidebar.open('git')
      vim.wait(30)
      assert(not sidebar.is_any_open(), 'Git action must cancel a queued sidebar transition')
      print('EDITOR_REVIEW_OK')
    ]])
  end)
end)

t.describe("review_editor: non-Git sidebar preservation", function()
  t.it("all six sidebar modes preserve configuration, switching and toggle", function()
    child([[
      local kinds = {'buffers', 'symbols', 'diagnostics', 'qflist', 'loclist', 'todo'}
      local active, opened = {}, {}
      package.loaded.trouble = {
        is_open = function(mode) return active[mode] == true end,
        close = function(mode) active[mode] = nil end,
        open = function(mode) active[mode] = true; opened[#opened + 1] = mode end,
      }
      local opts = dofile(vim.fn.getcwd() .. '/lua/plugins/sidebar.lua')[1].opts(nil, {})
      local sidebar = require('utils.sidebar')
      for _, kind in ipairs(kinds) do
        local mode = 'ue_sidebar_' .. kind
        local config = assert(opts.modes[mode], kind)
        assert(config.focus and config.open_no_results and config.warn_no_results == false)
        assert(config.win.position == 'left' and config.win.size == 40)
        assert(config.source == 'ue_sidebar.' .. kind or config.mode == kind)
        sidebar.open(kind)
        assert(vim.wait(1000, function() return sidebar.is_open(kind) end, 10), kind)
        assert(vim.tbl_count(active) == 1, vim.inspect(active))
        sidebar.toggle()
        assert(not sidebar.is_any_open())
        sidebar.toggle()
        assert(vim.wait(1000, function() return sidebar.is_open(kind) end, 10), kind)
      end
      sidebar.close()
      sidebar.open('quickfix')
      assert(vim.wait(1000, function() return sidebar.is_open('qflist') end, 10))
      sidebar.close()
      sidebar.open('buffers')
      sidebar.close()
      vim.wait(30)
      assert(not sidebar.is_any_open(), 'closing must cancel a pending open')
      assert(opts.modes.ue_qflist_bottom.win.position == 'bottom')
      print('EDITOR_REVIEW_OK')
    ]])
  end)

  t.it("menu keeps each non-Git sidebar action available", function()
    child([[
      local kinds = {'buffers', 'symbols', 'diagnostics', 'qflist', 'loclist', 'todo'}
      local active
      package.loaded.trouble = {
        is_open = function(mode) return active == mode end,
        close = function() active = nil end,
        open = function(mode) active = mode end,
      }
      local sidebar = require('utils.sidebar')
      for i, kind in ipairs(kinds) do
        sidebar.pick()
        local menu = vim.api.nvim_get_current_buf()
        assert(vim.bo[menu].filetype == 'ue-sidebar-picker')
        local choice = vim.fn.maparg(tostring(i + 1), 'n', false, true)
        assert(type(choice.callback) == 'function')
        choice.callback()
        assert(not vim.api.nvim_buf_is_valid(menu), 'menu must close after choosing')
        assert(vim.wait(1000, function() return sidebar.is_open(kind) end, 10), kind)
      end
      sidebar.close()
      print('EDITOR_REVIEW_OK')
    ]])
  end)

  t.it("shared source retains current/modified buffers and TODO positions", function()
    child([[
      package.loaded['trouble.item'] = {new = function(item) return item end, add_id = function() end}
      package.loaded.lazy = {load = function() end}
      package.loaded['todo-comments.config'] = {loaded = true}
      local filename = vim.fs.joinpath(vim.uv.cwd(), 'unicode-中文 test.cpp')
      vim.api.nvim_buf_set_name(0, filename)
      vim.api.nvim_buf_set_lines(0, 0, -1, false, {'// TODO: keep source'})
      package.loaded['todo-comments.search'] = {search = function(cb)
        cb({{filename = filename, lnum = 7, col = 3, tag = 'TODO', text = 'keep source'}})
      end}
      local source = require('trouble.sources.ue_sidebar')
      source.get.buffers(function(items)
        local current = assert(items[1])
        assert(current.buf == vim.api.nvim_get_current_buf())
        assert(current.item.kind == 'buffer' and current.item.changed == 1)
        assert(current.text:find('中文 test.cpp', 1, true))
      end)
      local called = false
      source.get.todo(function(items)
        called = true
        assert(#items == 1 and items[1].filename == vim.fs.normalize(filename))
        assert(items[1].pos[1] == 7 and items[1].pos[2] == 2)
        assert(items[1].item.kind == 'todo' and items[1].item.tag == 'TODO')
      end)
      assert(called)
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
