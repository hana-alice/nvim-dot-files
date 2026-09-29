local t = require("tests.harness")
local cfg = t.bootstrap()

local function child(code)
  local result = vim.system({
    vim.v.progpath, "--headless", "-u", "NONE", "-i", "NONE",
    "-c", "lua vim.opt.rtp:prepend(" .. string.format("%q", cfg) .. "); " .. code,
    "-c", "qa!",
  }, { text = true, cwd = cfg }):wait(10000)
  t.assert_eq(result.code, 0, (result.stdout or "") .. (result.stderr or ""))
  t.assert_contains((result.stdout or "") .. (result.stderr or ""), "GIT_MAPPING_OK")
end

t.describe("git_review_gitsigns: preserved specialist entrypoints", function()
  t.it("Diffview retains working-tree, close, selection-history and local bindings", function()
    child([=[
      local spec = dofile('lua/plugins/diffview.lua')[1]
      local keys = {}
      for _, key in ipairs(spec.keys) do keys[(key.mode or 'n') .. key[1]] = key end
      local calls = {}
      package.loaded['utils.git_async'] = {launch = function(opts) opts.run() end}
      vim.cmd = function(cmd) calls[#calls + 1] = cmd end
      keys['n<leader>gv'][2]()
      assert(calls[1] == 'DiffviewOpen' and type(keys['v<leader>gv'][2]) == 'function')
      assert(keys['n<leader>gV'][2] == '<cmd>DiffviewClose<cr>')
      package.loaded['diffview.actions'] = setmetatable({}, {__index = function(_, key) return key end})
      local opts = spec.opts()
      assert(opts.view.default.layout == 'diff2_horizontal')
      local local_keys = {}
      for _, key in ipairs(opts.keymaps.view) do local_keys[key[2]] = key[3] end
      assert(local_keys[']h'] and local_keys['[h'] and local_keys['q'])
      assert(local_keys['<tab>'] == 'select_next_entry')
      print('GIT_MAPPING_OK')
    ]=])
  end)

  t.it("Diffview selection history captures the live range before deferred launch", function()
    child([=[
      local spec = dofile('lua/plugins/diffview.lua')[1]
      local callback
      for _, key in ipairs(spec.keys) do
        if key.mode == 'v' and key[1] == '<leader>gv' then callback = key[2] end
      end
      local calls, failure = {}, nil
      vim.api.nvim_create_user_command('DiffviewFileHistory', function(ctx)
        calls[#calls + 1] = {ctx.line1, ctx.line2, vim.api.nvim_get_current_buf()}
      end, {range = true})
      package.loaded['utils.git_async'] = {launch = function(opts)
        vim.schedule(function()
          local ok, err = pcall(opts.run)
          if not ok then failure = err end
        end)
      end}
      vim.api.nvim_buf_set_lines(0, 0, -1, false, {'one', 'two', 'three', 'four', 'five', 'six'})
      local source = vim.api.nvim_get_current_buf()
      vim.cmd('normal! 2GVj')
      callback()
      vim.wait(30)
      assert(not failure, failure)
      assert(vim.deep_equal(calls[1], {2, 3, source}), vim.inspect(calls))
      assert(vim.fn.mode() == 'n', 'history launch must leave visual mode')
      vim.cmd('normal! 6GVk')
      callback()
      vim.wait(30)
      assert(not failure, failure)
      assert(vim.deep_equal(calls[2], {5, 6, source}), vim.inspect(calls))
      vim.cmd('normal! 2GVj')
      callback()
      local other = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_set_current_buf(other)
      vim.wait(30)
      assert(#calls == 2, 'deferred selection must not run in a different file')
      assert(vim.api.nvim_get_current_buf() == other, 'cancelled launch must not steal focus')
      print('GIT_MAPPING_OK')
    ]=])
  end)

  t.it("Fugitive keeps index, blame and quickfix entrypoints", function()
    child([=[
      local spec = dofile('lua/plugins/fugitive.lua')[1]
      local keys, calls = {}, {}
      for _, key in ipairs(spec.keys) do keys[key[1]] = key end
      package.loaded['utils.git_async'] = {launch = function(opts) opts.run() end}
      vim.cmd = function(cmd) calls[#calls + 1] = cmd end
      for _, key in ipairs({'g0', 'gB', 'gl', 'gL'}) do keys['<leader>' .. key][2]() end
      assert(vim.deep_equal(calls, {'Gedit :0', 'Git blame', '0Gclog', 'Gclog'}))
      assert(vim.tbl_contains(spec.cmd, 'Gedit') and vim.tbl_contains(spec.cmd, 'Gclog'))
      print('GIT_MAPPING_OK')
    ]=])
  end)
end)

t.describe("git_review_gitsigns: ordinary and review buffer ownership", function()
  t.it("ordinary editing has unambiguous hunk actions without gh descendants", function()
    child([=[
      vim.g.mapleader = ' '
      local calls, hunks = {}, {{added = {start = 1, count = 1}}}
      vim.api.nvim_buf_set_lines(0, 0, -1, false, {'changed'})
      vim.api.nvim_win_set_cursor(0, {1, 0})
      local function record(name) return function() calls[name] = (calls[name] or 0) + 1 end end
      package.loaded.gitsigns = {
        stage_hunk = record('stage'), reset_hunk = record('reset'), stage_buffer = record('buffer'),
        preview_hunk_inline = record('preview'), blame_line = record('blame'), blame = record('blame_all'),
        select_hunk = record('select'), nav_hunk = function(dir) calls[dir] = true end,
        get_hunks = function() return hunks end,
      }
      local staged
      package.loaded['utils.git_review'] = {open = function(opts) staged = opts.staged end}
      vim.notify = function() end
      local opts = dofile('lua/plugins/gitsigns.lua')[1].opts(nil, {
        on_attach = function() error('upstream gh mappings must not be inherited') end,
      })
      opts.on_attach(vim.api.nvim_get_current_buf())
      local function press(key) vim.fn.maparg(key, 'n', false, true).callback() end
      press(' hs')
      assert(calls.stage == 1, vim.inspect({calls = calls, cursor = vim.api.nvim_win_get_cursor(0)}))
      hunks = {}
      press(' hs')
      assert(calls.stage == 1, 'stage must never toggle a staged-only hunk')
      press(' hu')
      assert(staged and not calls.undo, 'unstage must not mean undo last action')
      hunks = {{added = {start = 0, count = 0}}}
      vim.fn.confirm = function(_, _, default) assert(default == 2); return 2 end
      press(' hr')
      assert(calls.reset == nil, 'cancel must preserve hunk')
      vim.fn.confirm = function() return 1 end
      press(' hr')
      press(' hS')
      press(' hb')
      press(' hB')
      press(']h')
      press('[h')
      assert(calls.reset == 1 and calls.buffer == 1 and calls.blame == 1 and calls.blame_all == 1)
      assert(calls.next and calls.prev)
      for _, map in ipairs(vim.api.nvim_buf_get_keymap(0, 'n')) do
        assert(not map.lhs:find(' gh', 1, true), map.lhs)
      end
      assert(opts.watch_gitdir.enable == false and opts.current_line_blame == true)
      print('GIT_MAPPING_OK')
    ]=])
  end)

  t.it("late attach preserves CodeDiff claims and restores normal keys on close", function()
    child([=[
      vim.g.mapleader = ' '
      local buf = vim.api.nvim_get_current_buf()
      local live = true
      package.loaded['codediff.ui.lifecycle'] = {
        find_tabpage_by_buffer = function(b) return live and b == buf and 1 or nil end,
        get_session = function() return live and {modified_bufnr = buf} or nil end,
      }
      local called = 0
      package.loaded.gitsigns = setmetatable({
        get_hunks = function() return {{added = {start = 1, count = 1}}} end,
        stage_hunk = function() called = called + 1 end,
      }, {__index = function() return function() end end})
      local review = function() end
      vim.keymap.set('n', '<leader>hs', review, {buffer = buf})
      local opts = dofile('lua/plugins/gitsigns.lua')[1].opts(nil, {})
      opts.on_attach(buf)
      assert(vim.fn.maparg(' hs', 'n', false, true).callback == review)
      vim.api.nvim_exec_autocmds('BufEnter', {buffer = buf})
      assert(vim.fn.maparg(' hs', 'n', false, true).callback == review)
      vim.api.nvim_exec_autocmds('User', {pattern = 'CodeDiffClose'})
      live = false
      vim.keymap.del('n', '<leader>hs', {buffer = buf})
      vim.wait(30)
      local normal = vim.fn.maparg(' hs', 'n', false, true).callback
      assert(type(normal) == 'function' and normal ~= review)
      normal()
      assert(called == 1)
      live = true
      normal()
      assert(called == 1, 'a stale ordinary callback must not mutate review content')
      print('GIT_MAPPING_OK')
    ]=])
  end)

  t.it("CodeDiff keymap registry hands original editing keys back after release", function()
    child([=[
      vim.g.mapleader = ' '
      vim.opt.rtp:append(vim.fn.stdpath('data') .. '/lazy/codediff.nvim')
      package.loaded.gitsigns = setmetatable({}, {__index = function() return function() end end})
      dofile('lua/plugins/gitsigns.lua')[1].opts(nil, {}).on_attach(vim.api.nvim_get_current_buf())
      local original = vim.fn.maparg(' hs', 'n', false, true).callback
      local registry = require('codediff.keymap').new('gitsigns-regression')
      local reviewed = false
      local review = function() reviewed = true end
      registry:claim(vim.api.nvim_get_current_buf(), 'n', '<leader>hs', review, {})
      vim.fn.maparg(' hs', 'n', false, true).callback()
      assert(reviewed)
      registry:dispose()
      assert(vim.fn.maparg(' hs', 'n', false, true).callback == original)
      print('GIT_MAPPING_OK')
    ]=])
  end)

  t.it("removed defaults cannot reappear when specialist specs load", function()
    child([=[
      local diff = dofile('lua/plugins/diffview.lua')[1]
      local removed = {['<leader>gm'] = true, ['<leader>gM'] = true, ['<leader>gr'] = true, ['<leader>gk'] = true}
      for _, key in ipairs(diff.keys) do assert(not removed[key[1]], key[1]) end
      local fugitive = dofile('lua/plugins/fugitive.lua')
      assert(#fugitive == 1 and fugitive[1][1] == 'tpope/vim-fugitive')
      print('GIT_MAPPING_OK')
    ]=])
  end)
end)
