local t = require("tests.harness")
local cfg = t.bootstrap()
local installed = vim.fn.stdpath("data") .. "/lazy"

for _, plugin in ipairs({ "lazy.nvim", "LazyVim", "trouble.nvim", "snacks.nvim" }) do
  if vim.fn.isdirectory(installed .. "/" .. plugin) == 0 then
    t.skip("ide_problem_navigation: installed runtime", "Missing installed plugin: " .. plugin, { native = true })
    return
  end
end

-- Load the real LazyVim keymap lifecycle and the real Lazy merged Trouble spec.
-- The bounded runtime omits unrelated project autocmds and UE setup, so these
-- synthetic files cannot start a project indexer or use the user's UE cache.
local function native(code)
  local dir = assert(vim.env.NVIM_TEST_RUN_ROOT) .. "/problem-navigation-" .. tostring(vim.uv.hrtime())
  vim.fn.mkdir(dir, "p")
  local script = dir .. "/case.lua"
  local setup = string.format(
    [[
local cfg, installed, root = %q, %q, %q
local api = vim.api
vim.g.mapleader, vim.g.maplocalleader = ' ', ' '
vim.g.started_with_stdin, vim.g.lazyvim_check_order = true, false
vim.o.hidden, vim.o.swapfile, vim.o.shada = true, false, ''
vim.go.loadplugins = true -- -u NONE disables the actual Lazy startup otherwise.
api.nvim_set_current_dir(root)
vim.opt.rtp:prepend(cfg)
vim.opt.rtp:append(installed .. '/lazy.nvim')
vim.opt.rtp:append(installed .. '/LazyVim')
vim.opt.rtp:append(installed .. '/snacks.nvim')
package.path = cfg .. '/lua/?.lua;' .. cfg .. '/lua/?/init.lua;' .. package.path
assert(vim.fs.normalize(vim.fn.stdpath('data')):find(vim.fs.normalize(root), 1, true))
_G.Snacks = require('snacks')
local base
for _, spec in ipairs(dofile(installed .. '/LazyVim/lua/lazyvim/plugins/editor.lua')) do
  if spec[1] == 'folke/trouble.nvim' then base = spec end
end
assert(base, 'installed LazyVim Trouble spec missing')
base.dir = installed .. '/trouble.nvim'
base.lazy = true
local override = dofile(cfg .. '/lua/plugins/sidebar.lua')[1]
require('lazy').setup({
  spec = {base, override},
  root = root .. '/lazy',
  lockfile = root .. '/lazy-lock.json',
  local_spec = false,
  install = {missing = false},
  checker = {enabled = false},
  change_detection = {enabled = false},
  rocks = {enabled = false},
  pkg = {enabled = false},
})
-- Do not load config.autocmds: only the actual keymap load path is under test.
package.loaded['config.autocmds'] = true
require('lazyvim.config').setup({
  colorscheme = 'habamax',
  news = {lazyvim = false, neovim = false},
  defaults = {autocmds = false, keymaps = true},
})
local notices = {}
vim.notify = function(message, level)
  notices[#notices + 1] = {message = tostring(message), level = level}
end
local function mapping(key)
  local value = vim.fn.maparg(key, 'n', false, true)
  assert(type(value.callback) == 'function', 'missing callback: ' .. key)
  return value
end
local function assert_maps()
  assert(mapping(']q').desc == 'Next quickfix result', vim.inspect(mapping(']q')))
  assert(mapping('[q').desc == 'Previous quickfix result', vim.inspect(mapping('[q')))
end
local function lifecycle(early)
  assert(not package.loaded['config.keymaps'], 'keymaps loaded before lifecycle')
  assert(not require('lazy.core.config').plugins['trouble.nvim']._.loaded)
  if early then
    dofile(cfg .. '/lua/config/keymaps.lua')
    assert_maps()
  end
  api.nvim_exec_autocmds('UIEnter', {modeline = false})
  api.nvim_exec_autocmds('User', {pattern = 'VeryLazy', modeline = false})
  assert(package.loaded['config.keymaps'], 'real VeryLazy did not load root keymaps')
  assert_maps()
  assert(not require('lazy.core.config').plugins['trouble.nvim']._.loaded,
    'quickfix keymaps must not eagerly load Trouble')
  local before = {mapping(']q').callback, mapping('[q').callback}
  require('lazy').load({plugins = {'trouble.nvim'}})
  assert(require('lazy.core.config').plugins['trouble.nvim']._.loaded)
  assert_maps()
  assert(mapping(']q').callback == before[1] and mapping('[q').callback == before[2],
    'lazy.load Trouble replaced the project quickfix callbacks')
end
local function keys(text)
  api.nvim_feedkeys(api.nvim_replace_termcodes(text, true, false, true), 'xt', false)
end
local function fixture()
  local original = api.nvim_get_current_buf()
  local files = {}
  for _, name in ipairs({'BuildA', 'BuildB', 'Other'}) do
    local path = root .. '/' .. name .. '.txt'
    vim.fn.writefile({'one', 'two', 'three', 'four', 'five', 'six'}, path)
    local buf = vim.fn.bufadd(path)
    vim.fn.bufload(buf)
    vim.bo[buf].buflisted = true
    files[name] = buf
  end
  vim.bo[original].buflisted = false
  api.nvim_set_current_buf(files.BuildA)
  local win = api.nvim_get_current_win()
  vim.fn.setqflist({}, ' ', {title = 'Fixture build errors', items = {
    {bufnr = files.BuildA, lnum = 2, col = 1, type = 'E', text = 'first error'},
    {bufnr = files.BuildB, lnum = 3, col = 1, type = 'E', text = 'second error'},
    {bufnr = files.Other, lnum = 4, col = 1, type = 'E', text = 'third error'},
    {bufnr = files.BuildA, lnum = 5, col = 1, type = 'W', text = 'warning'},
    {bufnr = files.BuildB, lnum = 6, col = 1, type = 'W', text = 'last warning'},
  }})
  vim.cmd.cfirst()
  return files, win, vim.fn.getqflist({id = 0, items = 0, title = 0})
end
local function assert_list(expected, idx)
  local actual = vim.fn.getqflist({id = 0, items = 0, title = 0, idx = 0})
  assert(actual.id == expected.id and actual.title == expected.title, 'quickfix owner changed')
  assert(vim.deep_equal(actual.items, expected.items), 'quickfix contents changed')
  assert(actual.idx == idx, 'quickfix index: ' .. actual.idx .. ' expected: ' .. idx)
end
local function assert_location(buf, row)
  assert(api.nvim_get_current_buf() == buf, 'jumped to unrelated buffer')
  assert(api.nvim_win_get_cursor(0)[1] == row, 'wrong source line')
end
local function buffers_sidebar(win)
  local view = assert(require('trouble').open('ue_sidebar_buffers'))
  assert(vim.wait(3000, function()
    return #require('trouble').get_items({mode = 'ue_sidebar_buffers'}) >= 3
  end, 10), 'actual buffers Trouble did not populate: count=' .. view:count()
    .. ' notices=' .. vim.inspect(notices))
  assert(require('trouble').is_open({mode = 'ue_sidebar_buffers'}))
  api.nvim_set_current_win(win)
end
]],
    cfg,
    installed,
    dir
  )
  local body = setup
    .. "\nlocal ok, err = xpcall(function()\n"
    .. code
    .. [[
end, debug.traceback)
if not ok then
  io.stderr:write(tostring(err) .. '\n')
  vim.cmd('cquit 1')
else
  print('PROBLEM_NAVIGATION_NATIVE_OK')
  vim.cmd('qa!')
end
]]
  vim.fn.writefile(vim.split(body, "\n", { plain = true }), script)
  local result = vim
    .system({ vim.v.progpath, "--headless", "-u", "NONE", "-i", "NONE", "-n", "-l", script }, {
      text = true,
      timeout = 15000,
      env = {
        XDG_DATA_HOME = dir .. "/data",
        XDG_STATE_HOME = dir .. "/state",
        XDG_CACHE_HOME = dir .. "/cache",
        NVIM_UE_PROBE_PATH = dir .. "/probes.json",
        NVIM_UE_LOG_DIR = dir .. "/logs",
        NVIM_LOG_FILE = dir .. "/nvim.log",
      },
    })
    :wait()
  vim.fn.delete(dir, "rf")
  local output = (result.stdout or "") .. (result.stderr or "")
  t.assert_eq(result.code, 0, output)
  t.assert_contains(output, "PROBLEM_NAVIGATION_NATIVE_OK")
end

t.describe("ide_problem_navigation: installed Trouble and native quickfix", function()
  for _, early in ipairs({ false, true }) do
    t.it((early and "early keymap load" or "normal VeryLazy load") .. " survives first Trouble load", function()
      native(("lifecycle(%s)\n"):format(tostring(early)) .. [[
        local files, win, list = fixture()
        buffers_sidebar(win)
        keys(']q')
        assert_location(files.BuildB, 3)
        assert_list(list, 2)
        keys('[q')
        assert_location(files.BuildA, 2)
        assert_list(list, 1)
        assert(require('trouble').is_open({mode = 'ue_sidebar_buffers'}))
      ]])
    end)
  end

  t.it("native mapping counts advance the current list while an unrelated sidebar remains open", function()
    native([[
      lifecycle(false)
      local files, win, list = fixture()
      buffers_sidebar(win)
      keys('2]q')
      assert_location(files.Other, 4)
      assert_list(list, 3)
      keys('2[q')
      assert_location(files.BuildA, 2)
      assert_list(list, 1)
      assert(require('trouble').is_open({mode = 'ue_sidebar_buffers'}))
    ]])
  end)

  t.it("a later search list becomes the explicit quickfix owner without changing the saved build list", function()
    native([[
      lifecycle(false)
      local files, win, build = fixture()
      buffers_sidebar(win)
      vim.fn.setqflist({}, ' ', {title = 'Fixture search results', items = {
        {bufnr = files.Other, lnum = 1, col = 1, text = 'search first'},
        {bufnr = files.BuildA, lnum = 6, col = 1, text = 'search second'},
      }})
      vim.cmd.cfirst()
      local search = vim.fn.getqflist({id = 0, items = 0, title = 0})
      assert(search.id ~= build.id)
      keys(']q')
      assert_location(files.BuildA, 6)
      assert_list(search, 2)
      local saved = vim.fn.getqflist({id = build.id, items = 0, title = 0})
      assert(vim.deep_equal(saved.items, build.items) and saved.title == build.title)
      vim.cmd.colder()
      vim.cmd.cfirst()
      keys(']q')
      assert_location(files.BuildB, 3)
      assert_list(build, 2)
    ]])
  end)

  t.it("list boundaries and an empty list report warnings without changing buffers, positions or entries", function()
    native([[
      lifecycle(false)
      local files, win, list = fixture()
      buffers_sidebar(win)
      local function rejected(key, idx)
        local buf, cursor, count = api.nvim_get_current_buf(), api.nvim_win_get_cursor(0), #notices
        keys(key)
        assert(api.nvim_get_current_buf() == buf and vim.deep_equal(api.nvim_win_get_cursor(0), cursor),
          'failed navigation moved the editor')
        assert_list(list, idx)
        assert(#notices == count + 1 and notices[#notices].level == vim.log.levels.WARN,
          'failed navigation did not report one warning')
      end
      rejected('[q', 1)
      vim.cmd.clast()
      rejected(']q', 5)
      vim.fn.setqflist({}, ' ', {title = 'Fixture empty list', items = {}})
      list = vim.fn.getqflist({id = 0, items = 0, title = 0})
      rejected(']q', 0)
      rejected('[q', 0)
      assert_location(files.BuildB, 6)
    ]])
  end)
end)
