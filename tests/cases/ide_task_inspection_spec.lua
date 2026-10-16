local t = require("tests.harness")
local cfg = t.bootstrap()

local function native(check)
  -- Only fixture-owned, idle Neovim processes are started. Actual nvim_input
  -- through RPC exercises mappings without touching the user's GUI. The
  -- independent linegrid proof uses a client that can consume redraw events.
  local job = vim.fn.jobstart(
    { vim.v.progpath, "--headless", "--embed", "-u", "NONE", "-i", "NONE", "-n" },
    { rpc = true }
  )
  t.assert_true(job > 0, "native Neovim child unavailable")
  local function lua(code, ...)
    return vim.rpcrequest(job, "nvim_exec_lua", code, { ... })
  end
  local function input(keys)
    local encoded = lua("return vim.api.nvim_replace_termcodes(..., true, false, true)", keys)
    t.assert_true(vim.rpcrequest(job, "nvim_input", encoded) > 0)
  end
  local function eventually(code)
    t.assert_true(
      vim.wait(3000, function()
        return lua(code) == true
      end, 10),
      code
    )
  end
  lua(
    [[
    local cfg = ...
    vim.opt.rtp:prepend(cfg)
    package.path = cfg .. '/lua/?.lua;' .. cfg .. '/lua/?/init.lua;' .. package.path
    vim.o.hidden, vim.o.swapfile, vim.o.shada, vim.o.more = true, false, '', false
    registry = require('utils.task_registry')
    bottom = require('utils.bottom_panel')
    source_win, source_buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(source_buf, 0, -1, false, { 'unsaved task-inspection source' })
    source_tick = vim.api.nvim_buf_get_changedtick(source_buf)
    vim.fn.setqflist({}, ' ', { title = 'owned inspection quickfix', items = {
      { bufnr = source_buf, lnum = 1, text = 'retain this result' } } })
    source_qf = vim.fn.getqflist({ id = 0, items = 0 })
    idle = { vim.v.progpath, '--headless', '-u', 'NONE', '-i', 'NONE', '-n', '-c',
      "lua print('task inspection fixture'); vim.defer_fn(function() vim.cmd('qa!') end, 30000)" }
    function select_task(id)
      local win = bottom.show('tasks')
      local buf = vim.api.nvim_win_get_buf(win)
      for index, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
        if line:match('^(%d+) ') == tostring(id) then
          vim.api.nvim_win_set_cursor(win, { index, 0 })
          return win
        end
      end
      error('fixture task missing')
    end
    function source_preserved()
      return vim.api.nvim_win_get_buf(source_win) == source_buf
        and vim.api.nvim_buf_get_changedtick(source_buf) == source_tick
        and vim.bo[source_buf].modified
        and vim.api.nvim_buf_get_lines(source_buf, 0, -1, false)[1] == 'unsaved task-inspection source'
        and vim.deep_equal(vim.fn.getqflist({ id = 0, items = 0 }), source_qf)
    end
  ]],
    cfg
  )
  local ok, err = pcall(check, { lua = lua, input = input, eventually = eventually })
  -- All handles in this child belong to this fixture, including the control.
  pcall(lua, "registry.cancel_all(); if control_job then pcall(vim.fn.jobstop, control_job) end")
  pcall(vim.fn.jobstop, job)
  pcall(vim.fn.jobwait, { job }, 1000)
  if not ok then
    error(err, 0)
  end
end

t.describe("ide_task_inspection: native task lifecycle", function()
  t.it("Enter views the same live terminal; closing its view keeps it running; dd stops only that task", function()
    native(function(f)
      f.lua([[
        terminal_buf = vim.api.nvim_create_buf(true, false)
        terminal_win = vim.api.nvim_open_win(terminal_buf, true, { split = 'below', win = source_win })
        task_job = vim.fn.termopen(idle)
        assert(task_job > 0)
        task_id = registry.register({ name = 'owned terminal', group = 'inspection', kind = 'job', handle = task_job })
        bottom.register('build', terminal_buf)
        control_job = vim.fn.jobstart(idle)
        assert(control_job > 0)
      ]])
      f.eventually(
        "return vim.api.nvim_buf_get_lines(terminal_buf, 0, -1, false)[1]:find('task inspection fixture', 1, true) ~= nil"
      )
      f.input("<C-w>q")
      f.eventually("return not vim.api.nvim_win_is_valid(terminal_win)")
      f.lua("panel_host = select_task(task_id); panel_count = #vim.api.nvim_list_wins()")
      f.input("<CR>")
      f.eventually("return vim.api.nvim_get_current_buf() == terminal_buf or registry.status(task_id) ~= 'running'")
      t.assert_eq(f.lua("return registry.status(task_id)"), "running", "viewing must not stop the task")
      local seen = f.lua([[
        return { same_output = vim.api.nvim_get_current_buf() == terminal_buf,
          same_channel = vim.bo[terminal_buf].channel == task_job,
          same_host = vim.api.nvim_get_current_win() == panel_host,
          single_host = #vim.api.nvim_list_wins() == panel_count, source = source_preserved() }
      ]])
      for key, value in pairs(seen) do
        t.assert_true(value, key)
      end
      f.input("<C-w>q")
      f.eventually("return not vim.api.nvim_win_is_valid(panel_host)")
      t.assert_eq(f.lua("return registry.status(task_id)"), "running", "closing output must not stop the task")
      f.lua("select_task(task_id)")
      f.input("dd")
      f.eventually("return registry.status(task_id) == 'cancelled'")
      t.assert_true(f.lua("return vim.fn.jobwait({control_job}, 0)[1] == -1 and source_preserved()"))
    end)
  end)

  t.it("a real system task has read-only details; Enter and refresh neither stop nor relaunch it", function()
    native(function(f)
      f.lua([[
        completion_count = 0
        process = vim.system(idle, {}, function() completion_count = completion_count + 1 end)
        task_id = registry.register({ name = 'owned system', group = 'inspection', kind = 'system', handle = process })
        original_handle = registry.get(task_id).handle
        panel_host = select_task(task_id)
        panel_count = #vim.api.nvim_list_wins()
      ]])
      f.input("<CR>")
      f.eventually(
        "return vim.b[vim.api.nvim_get_current_buf()].ue_bottom_panel_kind == 'task' or registry.status(task_id) ~= 'running'"
      )
      t.assert_eq(f.lua("return registry.status(task_id)"), "running", "detail view must not stop a system task")
      local details = f.lua([[
        detail_buf = vim.api.nvim_get_current_buf()
        return { no_output = require('utils.task_inspector').inspect(task_id).output == nil,
          read_only = not vim.bo[detail_buf].modifiable and vim.bo[detail_buf].readonly,
          same_host = vim.api.nvim_get_current_win() == panel_host,
          single_host = #vim.api.nvim_list_wins() == panel_count, source = source_preserved() }
      ]])
      for key, value in pairs(details) do
        t.assert_true(value, key)
      end
      f.input("<CR>r")
      f.eventually("return vim.fn.mode(1) == 'n'")
      t.assert_true(f.lua([[
        return registry.status(task_id) == 'running' and registry.get(task_id).handle == original_handle
          and #registry.list() == 1 and completion_count == 0 and source_preserved()
      ]]))
      f.input("<C-x>")
      f.eventually("return registry.status(task_id) == 'cancelled' and completion_count == 1")
      t.assert_true(f.lua("return registry.get(task_id).state == nil and source_preserved()"))
    end)
  end)
end)

t.describe("ide_task_inspection: task identity and retained facts", function()
  t.it("facts reflect a real failed process without changing its registry record", function()
    native(function(f)
      local result = f.lua([[
        local process = vim.system({ vim.v.progpath, '--headless', '-u', 'NONE', '-i', 'NONE', '-n', '-c', 'cquit 7' })
        local id = registry.register({ name = 'failed fixture', group = 'inspection', kind = 'system', handle = process })
        assert(vim.wait(3000, function() return registry.status(id) ~= 'running' end, 10))
        local record = registry.get(id)
        local inspector = require('utils.task_inspector')
        local facts = assert(inspector.inspect(id))
        local status, code = registry.status(id)
        local result = { status = facts.status, code = facts.code, result = facts.result,
          same_truth = facts.status == status and facts.code == code,
          same_handle = facts.handle == process, no_output = facts.output == nil }
        facts.name, facts.group, facts.status, facts.code = 'changed view', 'other', 'running', 0
        result.unchanged = record.name == 'failed fixture' and record.group == 'inspection'
          and record.state == nil and record.status == nil and record.code == nil
        return result
      ]])
      t.assert_eq(result.status, "done")
      t.assert_eq(result.code, 7)
      t.assert_eq(result.result, "failed")
      for _, key in ipairs({ "same_truth", "same_handle", "no_output", "unchanged" }) do
        t.assert_true(result[key], key)
      end
    end)
  end)

  t.it("an expected handle mismatch expires before opening a view or stopping a live task", function()
    native(function(f)
      local result = f.lua([[
        local process = vim.system(idle)
        local id = registry.register({ name = 'same label', kind = 'system', handle = process })
        local before_win, before_count = vim.api.nvim_get_current_win(), #vim.api.nvim_list_wins()
        local win, err = require('utils.task_inspector').open(id, { expected = { kind = 'system', handle = {} } })
        return { refused = win == nil, err = err, running = registry.status(id) == 'running',
          no_view = before_count == #vim.api.nvim_list_wins() and before_win == vim.api.nvim_get_current_win(),
          no_cancel = not registry.get(id).cancelled, source = source_preserved() }
      ]])
      for _, key in ipairs({ "refused", "running", "no_view", "no_cancel", "source" }) do
        t.assert_true(result[key], key)
      end
      t.assert_contains(result.err, "过期")
    end)
  end)

  t.it("a retained terminal is matched by channel even after exit, never by another task's name", function()
    native(function(f)
      f.lua([[
        terminal_buf = vim.api.nvim_create_buf(true, false)
        vim.api.nvim_open_win(terminal_buf, true, { split = 'below', win = source_win })
        task_job = vim.fn.termopen({ vim.v.progpath, '--headless', '-u', 'NONE', '-i', 'NONE', '-n', '-c', 'qa!' })
        task_id = registry.register({ name = 'same name', kind = 'job', handle = task_job })
        bottom.register('build', terminal_buf)
        -- Same display name has no terminal. Association must not use labels.
        process = vim.system(idle)
        other_id = registry.register({ name = 'same name', kind = 'system', handle = process })
      ]])
      f.eventually("return registry.status(task_id) ~= 'running'")
      local result = f.lua([[
        local inspector = require('utils.task_inspector')
        local facts = assert(inspector.inspect(task_id))
        local other = assert(inspector.inspect(other_id))
        local status, code = registry.status(task_id)
        return { same_channel = facts.output.buf == terminal_buf and vim.bo[terminal_buf].channel == facts.handle,
          same_name = facts.output.name == vim.api.nvim_buf_get_name(terminal_buf),
          panel = facts.output.panel, same_truth = facts.status == status and facts.code == code,
          unrelated = other.output == nil and other.status == 'running' }
      ]])
      t.assert_eq(result.panel, "build")
      for _, key in ipairs({ "same_channel", "same_name", "same_truth", "unrelated" }) do
        t.assert_true(result[key], key)
      end
      f.input("<C-w>q")
      f.eventually("return #vim.fn.win_findbuf(terminal_buf) == 0")
      f.lua("select_task(task_id)")
      f.input("<CR>")
      f.eventually("return vim.api.nvim_get_current_buf() == terminal_buf")
      t.assert_true(f.lua("return registry.status(task_id) ~= 'running' and source_preserved()"))
    end)
  end)

  t.it("a new terminal channel in the same exited buffer cannot be shown as the old task's output", function()
    native(function(f)
      f.lua([[
        terminal_buf = vim.api.nvim_create_buf(true, false)
        vim.api.nvim_open_win(terminal_buf, true, { split = 'below', win = source_win })
        task_job = vim.fn.termopen({ vim.v.progpath, '--headless', '-u', 'NONE', '-i', 'NONE', '-n', '-c', 'qa!' })
        task_id = registry.register({ name = 'old terminal owner', kind = 'job', handle = task_job })
        bottom.register('build', terminal_buf)
        terminal_name = vim.api.nvim_buf_get_name(terminal_buf)
      ]])
      f.eventually("return registry.status(task_id) ~= 'running'")
      f.lua([[
        new_channel = vim.api.nvim_open_term(terminal_buf, {})
        assert(new_channel > 0 and new_channel ~= task_job)
        vim.api.nvim_chan_send(new_channel, 'new terminal owner output\r\n')
      ]])
      f.eventually(
        [[return table.concat(vim.api.nvim_buf_get_lines(terminal_buf, 0, -1, false), '\n'):find('new terminal owner output', 1, true) ~= nil]]
      )
      local witness = f.lua([[
        local channels = 0
        for _, channel in ipairs(vim.api.nvim_list_chans()) do
          if channel.mode == 'terminal' and channel.buffer == terminal_buf then channels = channels + 1 end
        end
        return { same_buffer = vim.api.nvim_get_current_buf() == terminal_buf,
          same_name = vim.api.nvim_buf_get_name(terminal_buf) == terminal_name,
          stale_option = vim.bo[terminal_buf].channel == task_job, multiple_channels = channels > 1 }
      ]])
      for key, value in pairs(witness) do
        t.assert_true(value, key)
      end
      local facts = f.lua([[
        local facts = assert(require('utils.task_inspector').inspect(task_id))
        return { no_output = facts.output == nil, reason = facts.output_reason }
      ]])
      t.assert_true(facts.no_output, "the new terminal stream must not be associated with the old job")
      t.assert_contains(facts.reason, "无法唯一关联")
      f.lua("select_task(task_id)")
      f.input("<CR>")
      f.eventually("return vim.b[vim.api.nvim_get_current_buf()].ue_bottom_panel_kind == 'task'")
      local result = f.lua([[
        local buf = vim.api.nvim_get_current_buf()
        return { detail = buf ~= terminal_buf and vim.bo[buf].readonly and not vim.bo[buf].modified,
          reason = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n'),
          stream_preserved = vim.api.nvim_get_chan_info(new_channel).buffer == terminal_buf,
          source = source_preserved() }
      ]])
      for _, key in ipairs({ "detail", "stream_preserved", "source" }) do
        t.assert_true(result[key], key)
      end
      t.assert_contains(result.reason, "无法唯一关联")
    end)
  end)

  t.it("details of a GC'd completed task report expired and cannot cancel another live task", function()
    native(function(f)
      f.lua([[
        messages = {}
        vim.notify = function(message) messages[#messages + 1] = tostring(message) end
        local process = vim.system({ vim.v.progpath, '--headless', '-u', 'NONE', '-i', 'NONE', '-n', '-c', 'qa!' })
        expired_id = registry.register({ name = 'old completed', kind = 'system', handle = process })
        assert(vim.wait(3000, function() return registry.status(expired_id) ~= 'running' end, 10))
        assert(require('utils.task_inspector').open(expired_id))
        detail_buf = vim.api.nvim_get_current_buf()
        -- Duplicate registrations of an already-ended owned handle exercise
        -- the registry's existing bounded GC, without spawning 17 processes.
        for index = 1, registry._KEEP_DONE + 1 do
          registry.register({ name = 'completed GC fixture ' .. index, kind = 'system', handle = process })
        end
        local control = vim.system(idle)
        control_id = registry.register({ name = 'live control', kind = 'system', handle = control })
        registry.list()
        assert(registry.get(expired_id) == nil)
      ]])
      f.input("dd")
      f.eventually("return #messages > 0")
      local result = f.lua([[
        local facts, err = require('utils.task_inspector').inspect(expired_id)
        return { expired = facts == nil, err = err,
          message = messages[#messages], live = registry.status(control_id) == 'running',
          same_view = vim.api.nvim_get_current_buf() == detail_buf,
          clean = not vim.bo[detail_buf].modified, source = source_preserved() }
      ]])
      for _, key in ipairs({ "expired", "live", "same_view", "clean", "source" }) do
        t.assert_true(result[key], key)
      end
      t.assert_contains(result.err, "过期")
      t.assert_contains(result.message, "过期")
    end)
  end)
end)
