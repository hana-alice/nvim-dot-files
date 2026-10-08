local t = require("tests.harness")
local cfg = t.bootstrap()
local workspace = require("utils.workspace")

local function native(check)
  -- A short-lived isolated native client: the input is consumed by Neovim's
  -- event loop after the RPC returns, rather than substituted with :normal.
  local job = vim.fn.jobstart(
    { vim.v.progpath, "--headless", "--embed", "-u", "NONE", "-i", "NONE", "-n" },
    { rpc = true }
  )
  t.assert_true(job > 0, "native Neovim child startup failed")
  local function lua(code, ...)
    return vim.rpcrequest(job, "nvim_exec_lua", code, { ... })
  end
  local function input(keys)
    local encoded = lua("return vim.api.nvim_replace_termcodes(..., true, false, true)", keys)
    t.assert_true(vim.rpcrequest(job, "nvim_input", encoded) > 0)
  end
  local function eventually(code)
    local ready = vim.wait(2000, function()
      return lua(code)
    end, 10)
    if not ready then
      local details = lua([[return { mode = vim.fn.mode(),
        picker = picker and { input = picker.input:get(), count = picker:count(),
          current = picker:current() and picker:current().text,
          pattern = picker.input.filter.pattern, search = picker.input.filter.search } }]])
      error(code .. ": " .. vim.inspect(details), 0)
    end
  end
  lua(
    [[
    local cfg = ...
    vim.opt.rtp:prepend(cfg)
    package.path = cfg .. '/lua/?.lua;' .. cfg .. '/lua/?/init.lua;' .. package.path
    vim.o.hidden, vim.o.swapfile, vim.o.shada, vim.o.more = true, false, '', false
    workspace = require('utils.workspace')
    bottom = require('utils.bottom_panel')
    registry = require('utils.task_registry')
    source_win, source_buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(source_buf, 0, -1, false, { 'dirty source remains' })
    vim.bo[source_buf].modified = true
  ]],
    cfg
  )
  local ok, err = pcall(check, { lua = lua, input = input, eventually = eventually, job = job })
  -- Reap only this fixture's own process; it in turn stops its registered jobs.
  pcall(
    lua,
    "require('utils.task_registry').cancel_all(); if outsider_job then pcall(vim.fn.jobstop, outsider_job) end"
  )
  pcall(vim.fn.jobstop, job)
  pcall(vim.fn.jobwait, { job }, 1000)
  if not ok then
    error(err, 0)
  end
end

t.describe("ide_workspace: native ownership and recovery", function()
  local snacks_path = vim.fn.stdpath("data") .. "/lazy/snacks.nvim"
  if vim.fn.isdirectory(snacks_path) == 0 then
    t.skip(
      "native Snacks entry filters and restores a file after <C-w>q",
      "installed Snacks unavailable",
      { native = true }
    )
  else
    t.it("native Snacks entry filters and restores a file after <C-w>q through real keyboard input", function()
      native(function(f)
        f.lua(
          [[
          local snacks_path, cfg = ...
          vim.opt.rtp:append(snacks_path)
          Snacks = require('snacks')
          Snacks.setup({ picker = { enabled = true } })
          vim.g.mapleader, vim.g.maplocalleader = ' ', ' '
          workspace.setup_commands()
          dofile(cfg .. '/lua/config/keymaps.lua')
          file_buf = vim.api.nvim_create_buf(true, false)
          vim.api.nvim_buf_set_name(file_buf, vim.fn.tempname() .. '-recover-keyboard.cpp')
          vim.api.nvim_buf_set_lines(file_buf, 0, -1, false, { 'keyboard recovery leaves dirty input intact' })
          vim.bo[file_buf].modified = true
          file_win = vim.api.nvim_open_win(file_buf, true, { split = 'right', win = source_win })
        ]],
          snacks_path,
          cfg
        )
        f.input("<C-w>q")
        f.eventually("return not vim.api.nvim_win_is_valid(file_win)")
        f.input("<Space>wM")
        f.eventually(
          "picker = Snacks.picker.get()[1]; return picker and picker:count() > 0 and picker.input.win:valid() and vim.api.nvim_get_current_win() == picker.input.win.win and vim.fn.mode():match('i') ~= nil"
        )
        f.input("recover-keyboard")
        f.eventually(
          "return picker.input:get() == 'recover-keyboard' and picker.list:count() == 1 and picker:current().data.buf == file_buf"
        )
        f.input("<CR>")
        f.eventually("return picker.closed and vim.api.nvim_get_current_buf() == file_buf")
        local result = f.lua([[
          return { source = vim.api.nvim_win_get_buf(source_win) == source_buf,
            dirty = vim.bo[file_buf].modified,
            text = vim.api.nvim_buf_get_lines(file_buf, 0, -1, false)[1] }
        ]])
        t.assert_true(result.source)
        t.assert_true(result.dirty)
        t.assert_eq(result.text, "keyboard recovery leaves dirty input intact")
      end)
    end)
  end

  t.it("actual <C-w>q hides a dirty file; the searchable entry opens its buffer in a new split", function()
    native(function(f)
      f.lua([[
        file_buf = vim.api.nvim_create_buf(true, false)
        vim.api.nvim_buf_set_name(file_buf, vim.fn.tempname() .. '.cpp')
        vim.api.nvim_buf_set_lines(file_buf, 0, -1, false, { 'unsaved file work' })
        vim.bo[file_buf].modified = true
        file_win = vim.api.nvim_open_win(file_buf, true, { split = 'right', win = source_win })
      ]])
      f.input("<C-w>q")
      f.eventually("return not vim.api.nvim_win_is_valid(file_win)")
      local result = f.lua([[
        local rows = workspace.list({ category = 'buffers' })
        for _, row in ipairs(rows) do
          if row.buf == file_buf then
            local found, err = workspace.activate(row, { source_win = source_win })
            return { found = found ~= nil, err = err, hidden_label = row.text:find('hidden', 1, true) ~= nil,
              current = vim.api.nvim_get_current_buf() == file_buf,
              dirty = vim.bo[file_buf].modified,
              source = vim.api.nvim_buf_get_lines(source_buf, 0, -1, false)[1],
              source_visible = vim.api.nvim_win_get_buf(source_win) == source_buf,
              text = vim.api.nvim_buf_get_lines(file_buf, 0, -1, false)[1] }
          end
        end
        return { found = false }
      ]])
      t.assert_true(result.found, result.err)
      t.assert_true(result.hidden_label)
      t.assert_true(result.current)
      t.assert_true(result.dirty)
      t.assert_true(result.source_visible)
      t.assert_eq(result.source, "dirty source remains")
      t.assert_eq(result.text, "unsaved file work")
    end)
  end)

  t.it("focuses an existing window across tabs, and rejects a row whose window changed buffers", function()
    native(function(f)
      local result = f.lua([[
        vim.cmd('tabnew')
        other_tab, other_win = vim.api.nvim_get_current_tabpage(), vim.api.nvim_get_current_win()
        local buf = vim.api.nvim_get_current_buf()
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'other tab unsaved' })
        local row
        for _, candidate in ipairs(workspace.list({ category = 'windows' })) do
          if candidate.win == other_win then row = candidate end
        end
        vim.api.nvim_set_current_win(source_win)
        local before = #vim.api.nvim_list_wins()
        local found = workspace.activate(row)
        local focused = found == other_win and vim.api.nvim_get_current_tabpage() == other_tab
        local replacement = vim.api.nvim_create_buf(true, false)
        vim.api.nvim_win_set_buf(other_win, replacement)
        vim.api.nvim_set_current_win(source_win)
        local rejected, err = workspace.activate(row)
        return { focused = focused, windows = #vim.api.nvim_list_wins() == before,
          rejected = rejected == nil, error = err, source = vim.api.nvim_get_current_win() == source_win,
          untouched = vim.api.nvim_win_get_buf(other_win) == replacement,
          dirty = vim.api.nvim_buf_get_lines(buf, 0, -1, false)[1] == 'other tab unsaved' }
      ]])
      t.assert_true(result.focused)
      t.assert_true(result.windows)
      t.assert_true(result.rejected)
      t.assert_contains(result.error, "窗口内容已变化")
      t.assert_true(result.source)
      t.assert_true(result.untouched)
      t.assert_true(result.dirty)
    end)
  end)

  t.it("a closed window row recovers its existing buffer, and a deleted buffer is honestly unavailable", function()
    native(function(f)
      f.lua([[
        closed_buf = vim.api.nvim_create_buf(true, false)
        closed_win = vim.api.nvim_open_win(closed_buf, true, { split = 'right', win = source_win })
        for _, row in ipairs(workspace.list({ category = 'windows' })) do
          if row.win == closed_win then closed_row = row end
        end
      ]])
      f.input("<C-w>q")
      f.eventually("return not vim.api.nvim_win_is_valid(closed_win)")
      local result = f.lua([[
        local restored = workspace.activate(closed_row, { source_win = source_win })
        local success = restored and vim.api.nvim_win_get_buf(restored) == closed_buf
        vim.api.nvim_buf_delete(closed_buf, { force = true })
        local before = #vim.api.nvim_list_wins()
        local missing, err = workspace.activate(closed_row, { source_win = source_win })
        return { restored = success, unavailable = missing == nil, err = err,
          no_extra_window = #vim.api.nvim_list_wins() == before }
      ]])
      t.assert_true(result.restored)
      t.assert_true(result.unavailable)
      t.assert_contains(result.err, "删除或更名")
      t.assert_true(result.no_extra_window)
    end)
  end)

  t.it("pin is passive; <C-w>q results are found by stable native id and reuse the one bottom host", function()
    native(function(f)
      local result = f.lua([[
        sidebar_buf = vim.api.nvim_create_buf(false, true)
        vim.bo[sidebar_buf].filetype = 'trouble'
        sidebar_win = vim.api.nvim_open_win(sidebar_buf, false, { split = 'left', win = source_win })
        vim.fn.setqflist({}, ' ', { title = 'build errors', items = { { bufnr = source_buf, lnum = 1, text = 'build row' } } })
        original_id = vim.fn.getqflist({ id = 0 }).id
        local before = #vim.api.nvim_list_wins()
        saved_id = assert(workspace.pin({ { bufnr = source_buf, lnum = 1, col = 0, text = 'saved line-only row' } },
          { title = 'Pinned search', source = 'ue_grep_csearch', truncated = true }))
        return { no_windows = #vim.api.nvim_list_wins() == before,
          focused = vim.api.nvim_get_current_win() == source_win,
          sidebar = vim.api.nvim_win_is_valid(sidebar_win),
          original = vim.fn.getqflist({ id = 0 }).id == original_id,
          saved = vim.fn.getqflist({ id = saved_id, items = 0 }).items[1].col == 0 }
      ]])
      for _, key in ipairs({ "no_windows", "focused", "sidebar", "original", "saved" }) do
        t.assert_true(result[key], key)
      end
      f.lua([[
        result_row = nil
        for _, row in ipairs(workspace.list({ category = 'results' })) do
          if row.id == saved_id then result_row = row end
        end
        assert(result_row and result_row.text:find('partial', 1, true))
        result_win = assert(workspace.activate(result_row))
      ]])
      f.input("<C-w>q")
      f.eventually("return not vim.api.nvim_win_is_valid(result_win)")
      local reopened = f.lua([[
        local log = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_lines(log, 0, -1, false, { 'preserved build log' })
        local host = bottom.show('build', log)
        local before = #vim.api.nvim_list_wins()
        local found = workspace.activate(result_row)
        return { same = found == host, single = #vim.api.nvim_list_wins() == before,
          id = vim.fn.getqflist({ id = 0 }).id == saved_id,
          sidebar = vim.api.nvim_win_is_valid(sidebar_win),
          source = vim.api.nvim_win_get_buf(source_win) == source_buf,
          log = vim.api.nvim_buf_get_lines(log, 0, -1, false)[1] }
      ]])
      t.assert_true(reopened.same)
      t.assert_true(reopened.single)
      t.assert_true(reopened.id)
      t.assert_true(reopened.sidebar)
      t.assert_true(reopened.source)
      t.assert_eq(reopened.log, "preserved build log")
    end)
  end)

  t.it("passive pin preserves native quickfix cursor and scroll views across tabs after real scrolling", function()
    native(function(f)
      f.lua([[
        local items = {}
        for i = 1, 120 do items[i] = { bufnr = source_buf, lnum = 1, text = 'build error ' .. i } end
        vim.fn.setqflist({}, ' ', { title = 'long build result', items = items })
        build_id = vim.fn.getqflist({ id = 0 }).id
        first_qf = bottom.show('quickfix')
      ]])
      f.input("80Gzz")
      f.eventually("return vim.api.nvim_win_get_cursor(first_qf)[1] == 80 and vim.fn.winsaveview().topline > 1")
      f.lua([[
        vim.cmd('tabnew')
        second_qf = bottom.show('quickfix')
      ]])
      f.input("45Gzz")
      f.eventually("return vim.api.nvim_win_get_cursor(second_qf)[1] == 45 and vim.fn.winsaveview().topline > 1")
      local result = f.lua([[
        local views = {}
        for _, win in ipairs({ first_qf, second_qf }) do
          views[#views + 1] = { win = win, tab = vim.api.nvim_win_get_tabpage(win),
            buf = vim.api.nvim_win_get_buf(win), view = vim.api.nvim_win_call(win, vim.fn.winsaveview) }
        end
        local focus, tab = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_tabpage()
        local pinned = assert(workspace.pin({ { bufnr = source_buf, lnum = 1, text = 'new saved search' } },
          { title = 'passive search pin' }))
        local same = true
        for _, row in ipairs(views) do
          same = same and vim.api.nvim_win_get_tabpage(row.win) == row.tab
            and vim.api.nvim_win_get_buf(row.win) == row.buf
            and vim.deep_equal(row.view, vim.api.nvim_win_call(row.win, vim.fn.winsaveview))
        end
        return { views = same, current = vim.fn.getqflist({ id = 0 }).id == build_id,
          focus = vim.api.nvim_get_current_win() == focus and vim.api.nvim_get_current_tabpage() == tab,
          first_line = views[1].view.lnum, second_line = views[2].view.lnum,
          first_top = views[1].view.topline, second_top = views[2].view.topline,
          pinned = vim.fn.getqflist({ id = pinned, size = 0 }).size == 1 }
      ]])
      t.assert_eq(result.first_line, 80)
      t.assert_eq(result.second_line, 45)
      t.assert_true(result.first_top > 1)
      t.assert_true(result.second_top > 1)
      t.assert_true(result.views)
      t.assert_true(result.current)
      t.assert_true(result.focus)
      t.assert_true(result.pinned)
    end)
  end)

  t.it("passive pin refuses to evict the current oldest list when native history is full", function()
    native(function(f)
      local result = f.lua([[
        local ids = {}
        for i = 1, 10 do
          vim.fn.setqflist({}, ' ', { title = i == 1 and 'current build errors' or ('search ' .. i),
            items = { { bufnr = source_buf, lnum = 1, text = 'retained row ' .. i } } })
          ids[i] = vim.fn.getqflist({ id = 0 }).id
        end
        vim.cmd('silent chistory 1')
        local qf_win = bottom.show('quickfix', nil, { focus = false })
        local sidebar_buf = vim.api.nvim_create_buf(false, true)
        local sidebar_win = vim.api.nvim_open_win(sidebar_buf, false, { split = 'left', win = source_win })
        local function layout()
          local rows = {}
          for _, win in ipairs(vim.api.nvim_list_wins()) do
            rows[#rows + 1] = { win = win, buf = vim.api.nvim_win_get_buf(win),
              height = vim.api.nvim_win_get_height(win), width = vim.api.nvim_win_get_width(win),
              position = vim.api.nvim_win_get_position(win) }
          end
          return rows
        end
        local before, focus, tab = layout(), vim.api.nvim_get_current_win(), vim.api.nvim_get_current_tabpage()
        local pinned, err = workspace.pin({ { bufnr = source_buf, lnum = 1, text = 'new pinned result' } },
          { title = 'pin would erase active build' })
        local unchanged = true
        for nr, id in ipairs(ids) do
          local info = vim.fn.getqflist({ id = id, nr = 0, items = 0 })
          unchanged = unchanged and info.id == id and info.nr == nr
            and info.items[1].text == 'retained row ' .. nr
        end
        return { refused = pinned == nil, err = err, all_ids = unchanged,
          current = vim.fn.getqflist({ id = 0, nr = 0 }).id == ids[1],
          ten_lists = vim.fn.getqflist({ nr = '$' }).nr == 10,
          layout = vim.deep_equal(before, layout()),
          focus = vim.api.nvim_get_current_win() == focus and vim.api.nvim_get_current_tabpage() == tab,
          panels = vim.api.nvim_win_is_valid(qf_win) and vim.api.nvim_win_is_valid(sidebar_win) }
      ]])
      t.assert_true(result.refused)
      t.assert_contains(result.err, "10")
      t.assert_contains(result.err, "当前")
      for _, key in ipairs({ "all_ids", "current", "ten_lists", "layout", "focus", "panels" }) do
        t.assert_true(result[key], key)
      end
    end)
  end)

  t.it("native history eviction does not open or overwrite an unrelated result", function()
    native(function(f)
      local result = f.lua([[
        local stale = assert(workspace.pin({ { bufnr = source_buf, lnum = 1, text = 'old' } }, { title = 'old saved' }))
        for i = 1, 12 do
          -- Explicitly leave the oldest list before allowing native history to
          -- evict it. Passive saves must preserve the actively selected list.
          vim.cmd('silent chistory ' .. vim.fn.getqflist({ nr = '$' }).nr)
          assert(workspace.pin({ { bufnr = source_buf, lnum = 1, text = 'new ' .. i } }, { title = 'new ' .. i }))
        end
        local current = vim.fn.getqflist({ id = 0 }).id
        local before = #vim.api.nvim_list_wins()
        local win, err = workspace.activate({ kind = 'result', id = stale })
        return { unavailable = win == nil, err = err, same_id = current == vim.fn.getqflist({ id = 0 }).id,
          same_windows = before == #vim.api.nvim_list_wins() }
      ]])
      t.assert_true(result.unavailable)
      t.assert_contains(result.err, "淘汰")
      t.assert_true(result.same_id)
      t.assert_true(result.same_windows)
    end)
  end)

  t.it(
    "native terminal close preserves its registered live job; reopening and cancelling touch only that owner",
    function()
      native(function(f)
        f.lua([[
        terminal_buf = vim.api.nvim_create_buf(true, false)
        terminal_win = vim.api.nvim_open_win(terminal_buf, true, { split = 'below', win = source_win })
        terminal_job = vim.fn.termopen({ vim.v.progpath, '--headless', '-u', 'NONE', '-i', 'NONE', '-n', '-c',
          "lua print('workspace native log'); vim.defer_fn(function() vim.cmd('qa!') end, 30000)" })
        assert(terminal_job > 0)
        terminal_id = registry.register({ name = 'native terminal log', group = 'workspace-test', kind = 'job', handle = terminal_job })
        bottom.register('build', terminal_buf)
        outsider_job = vim.fn.jobstart({ vim.v.progpath, '--headless', '-u', 'NONE', '-i', 'NONE', '-n', '-c',
          "lua vim.defer_fn(function() vim.cmd('qa!') end, 30000)" })
        assert(outsider_job > 0)
      ]])
        f.input("<C-w>q")
        f.eventually("return not vim.api.nvim_win_is_valid(terminal_win)")
        local result = f.lua([[
        local task
        for _, row in ipairs(workspace.list({ category = 'tasks' })) do
          if row.id == terminal_id then task = row end
        end
        local live = registry.status(terminal_id) == 'running'
        local retained = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_lines(retained, 0, -1, false, { 'existing logcat view' })
        local host = bottom.show('logcat', retained)
        local windows = #vim.api.nvim_list_wins()
        local win = workspace.activate(task, { source_win = source_win })
        local output = win and vim.api.nvim_win_get_buf(win) == terminal_buf
        local same_job = vim.bo[terminal_buf].channel == terminal_job
        local stopped = workspace.stop(task)
        assert(vim.wait(2000, function() return registry.status(terminal_id) ~= 'running' end, 10))
        local outsider = vim.fn.jobwait({ outsider_job }, 0)[1] == -1
        vim.fn.jobstop(outsider_job)
        return { live = live, output = output, same_job = same_job, stopped = stopped,
          cancelled = registry.status(terminal_id) == 'cancelled', outsider = outsider,
          same_host = win == host, single_host = #vim.api.nvim_list_wins() == windows,
          source = vim.api.nvim_buf_get_lines(source_buf, 0, -1, false)[1] }
      ]])
        for _, key in ipairs({
          "live",
          "output",
          "same_job",
          "stopped",
          "cancelled",
          "outsider",
          "same_host",
          "single_host",
        }) do
          t.assert_true(result[key], key)
        end
        t.assert_eq(result.source, "dirty source remains")
      end)
    end
  )

  t.it("task query observes real process completion without state copies, timers or relaunch", function()
    native(function(f)
      local result = f.lua([[
        local process = vim.system({ vim.v.progpath, '--headless', '-u', 'NONE', '-i', 'NONE', '-n', '-c', 'qa!' })
        local id = registry.register({ name = 'short native job', group = 'workspace-test', kind = 'system', handle = process })
        local initial = registry.status(id)
        assert(vim.wait(5000, function() return registry.status(id) ~= 'running' end, 10))
        local row
        for _, candidate in ipairs(workspace.list({ category = 'tasks' })) do if candidate.id == id then row = candidate end end
        local record = registry.get(id)
        local status, code = registry.status(id)
        local count = #registry.list()
        local win = workspace.activate(row)
        return { initial = initial, code = code, done = status == 'done', no_copy = record.state == nil,
          no_relaunch = #registry.list() == count, panel = win and vim.b[vim.api.nvim_win_get_buf(win)].ue_bottom_panel_kind == 'task',
          stop = workspace.stop(row), label = row.text }
      ]])
      t.assert_eq(result.initial, "running")
      t.assert_eq(result.code, 0)
      t.assert_true(result.done)
      t.assert_true(result.no_copy)
      t.assert_true(result.no_relaunch)
      t.assert_true(result.panel)
      t.assert_false(result.stop)
      t.assert_contains(result.label, "success")
    end)
  end)

  t.it("cancel refuses stale task identities and non-task rows", function()
    native(function(f)
      local result = f.lua([[
        local process = vim.system({ vim.v.progpath, '--headless', '-u', 'NONE', '-i', 'NONE', '-n', '-c',
          "lua vim.defer_fn(function() vim.cmd('qa!') end, 30000)" })
        local id = registry.register({ name = 'owned native job', kind = 'system', handle = process })
        local stale = { kind = 'task', id = id, handle = {}, task_kind = 'system' }
        local denied = not workspace.stop(stale)
        local ordinary = not workspace.stop({ kind = 'window', id = id, handle = process })
        local live = registry.status(id) == 'running'
        registry.cancel(id)
        return { denied = denied, ordinary = ordinary, live = live }
      ]])
      t.assert_true(result.denied)
      t.assert_true(result.ordinary)
      t.assert_true(result.live)
    end)
  end)
end)

t.describe("ide_workspace: searchable entry contracts", function()
  t.it("pin validates bounded plain metadata and preserves its inputs", function()
    local bad, err = workspace.pin({ { lnum = 1, text = "one row" } }, { recipe = { run = function() end } })
    t.assert_nil(bad)
    t.assert_contains(err, "格式无效")
    t.assert_nil(workspace.pin({}))
    local items, recipe = { { lnum = 1, text = "immutable row" } }, { version = 1, query = "Alpha" }
    local id = workspace.pin(items, { recipe = recipe })
    t.assert_true(id > 0)
    local context = vim.fn.getqflist({ id = id, context = 0 }).context
    t.assert_eq(context.recipe.query, "Alpha")
    t.assert_nil(items[1].bufnr)
    t.assert_eq(recipe.query, "Alpha")
  end)

  t.it("normal and terminal recovery mappings are registered after the real keymap loader", function()
    vim.g.mapleader, vim.g.maplocalleader = " ", " "
    require("ue").setup()
    dofile(cfg .. "/lua/config/keymaps.lua")
    for _, mode in ipairs({ "n", "t" }) do
      t.assert_contains(t.get_keymap(mode, "<leader>wM").rhs, "UEWorkspace")
    end
    workspace.setup_commands()
    t.assert_eq(vim.fn.exists(":UEWorkspace"), 2)
  end)

  t.it("the hub discovers recovery, saved results and task logs without a selected project", function()
    local groups, found = {}, false
    for _, action in ipairs(require("utils.ue_hub").visible_actions({ platform = "", state = {} })) do
      groups[action.group] = true
      if action.key == "<leader>wM" then
        found = action.readiness.ready
      end
    end
    t.assert_true(found)
    for _, group in ipairs({ "Work", "Recovery", "Search", "Tasks", "Logs", "Read" }) do
      t.assert_true(groups[group], group)
    end
    local routes = {}
    for _, action in ipairs(require("utils.ue_hub").visible_actions({ platform = "", state = {} })) do
      if action.command and action.command:find("UEWorkspace", 1, true) then
        t.assert_eq(action.group, "Recovery")
        t.assert_true(action.readiness.ready)
        routes[action.command] = true
      end
    end
    for _, route in ipairs({ "UEWorkspace", "UEWorkspace windows", "UEWorkspace buffers", "UEWorkspace results", "UEWorkspace tasks", "UEWorkspace logs" }) do
      t.assert_true(routes[route], route)
    end
  end)
end)
