local t = require("tests.harness")
t.bootstrap()

-- These tests use the installed dap-ui and real Neovim window/buffer APIs.
-- Session events are controlled; no adapter, inferior or device is fabricated.
local data = vim.fn.stdpath("data") .. "/lazy/"
for _, name in ipairs({ "nvim-dap", "nvim-dap-ui", "nvim-nio" }) do
  vim.opt.rtp:append(data .. name)
end

local function snapshot(win)
  return {
    buf = vim.api.nvim_win_get_buf(win),
    view = vim.api.nvim_win_call(win, vim.fn.winsaveview),
    width = vim.api.nvim_win_get_width(win),
    height = vim.api.nvim_win_get_height(win),
  }
end

local function source(win, name)
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(buf, vim.fn.tempname() .. "-" .. name .. ".cpp")
  local lines = {}
  for i = 1, 200 do
    lines[i] = "int value_" .. i .. " = " .. i .. ";"
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_win_set_buf(win, buf)
  vim.api.nvim_win_set_cursor(win, { 45, 4 })
  vim.api.nvim_win_call(win, function()
    vim.cmd("normal! zt")
  end)
  return buf
end

local function with_ui(test)
  local old_d = package.loaded["ue.dap"]
  local dap = require("dap")
  local old_session, old_listeners, old_terminate = dap.session, dap.listeners, dap.terminate
  local old_configurations, old_click = dap.configurations, _G.UEDapBottomTabClick
  local session_module = require("dap.session")
  local old_frame_set = session_module._frame_set
  local old_frame_original = session_module._ue_android_orig_frame_set
  local old_frame_guard = session_module._ue_android_invalid_frame_guard
  local old_switchbuf = dap.defaults.lldb.switchbuf
  -- Use the actual host dimensions. Synthetic columns/lines resizing after
  -- native terminal cases triggered a Neovim 0.11.5 heap crash before dap-ui.
  -- The native split/view/ratio assertions below require no global resize.
  dap.configurations = {}
  local original_tab, original_win = vim.api.nvim_get_current_tabpage(), vim.api.nvim_get_current_win()
  local tabs, buffers = {}, {}
  package.loaded["ue.dap"] = nil
  local d = require("ue.dap")
  d.setup_core({ trim = vim.trim, norm = vim.fs.normalize })
  d.lldb_dap_path = function()
    return nil
  end
  dap.session = function()
    return nil
  end
  dap.listeners = setmetatable({}, {
    __index = function(tbl, key)
      local events = setmetatable({}, {
        __index = function(inner, event)
          local listeners = {}
          rawset(inner, event, listeners)
          return listeners
        end,
      })
      rawset(tbl, key, events)
      return events
    end,
  })
  vim.cmd("tabnew")
  tabs[1] = vim.api.nvim_get_current_tabpage()
  local main = vim.api.nvim_get_current_win()
  buffers[#buffers + 1] = source(main, "main")
  vim.cmd("vsplit")
  local right = vim.api.nvim_get_current_win()
  buffers[#buffers + 1] = source(right, "right")
  vim.cmd("split")
  local lower = vim.api.nvim_get_current_win()
  buffers[#buffers + 1] = source(lower, "lower")
  vim.api.nvim_win_set_width(main, 81)
  vim.api.nvim_win_set_height(lower, 19)
  local panel_buf = vim.api.nvim_create_buf(false, true)
  buffers[#buffers + 1] = panel_buf
  vim.api.nvim_buf_set_lines(panel_buf, 0, -1, false, { "Doctor / unrelated scratch panel" })
  local panel = vim.api.nvim_open_win(panel_buf, false, { split = "below", win = main, height = 7 })
  vim.cmd("tabnew")
  tabs[2] = vim.api.nvim_get_current_tabpage()
  local elsewhere = vim.api.nvim_get_current_win()
  buffers[#buffers + 1] = source(elsewhere, "elsewhere")
  vim.cmd("vsplit")
  local elsewhere2 = vim.api.nvim_get_current_win()
  buffers[#buffers + 1] = source(elsewhere2, "elsewhere2")
  vim.api.nvim_set_current_win(main)
  require("utils.bottom_panel")._reset_for_test()
  local dapui = require("dapui")
  dapui.setup({
    force_buffers = false,
    controls = { enabled = false },
    layouts = {
      {
        position = "left",
        size = 36,
        elements = { { id = "scopes", size = 0.4 }, { id = "stacks", size = 0.3 }, { id = "watches", size = 0.3 } },
      },
    },
  })
  d.setup_dap(dap, dapui)
  local session = { config = { type = "lldb", name = "IDE UI fixture" } }
  local ctx = {
    d = d,
    dap = dap,
    dapui = dapui,
    session = session,
    main = main,
    right = right,
    lower = lower,
    panel = panel,
    panel_buf = panel_buf,
    elsewhere = elsewhere,
    elsewhere2 = elsewhere2,
    tabs = tabs,
    buffers = buffers,
  }
  ctx.start = function()
    dap.listeners.after.event_initialized.dapui_config(session)
  end
  ctx.stop = function()
    dap.listeners.before.event_terminated.dapui_config(session)
  end
  local ok, err = xpcall(function()
    test(ctx)
  end, debug.traceback)
  pcall(ctx.stop)
  require("dapui.util").stop_render_tasks()
  dap.session, dap.listeners, dap.terminate = old_session, old_listeners, old_terminate
  dap.configurations, _G.UEDapBottomTabClick = old_configurations, old_click
  dap.defaults.lldb.switchbuf = old_switchbuf
  session_module._frame_set = old_frame_set
  session_module._ue_android_orig_frame_set = old_frame_original
  session_module._ue_android_invalid_frame_guard = old_frame_guard
  pcall(vim.api.nvim_del_augroup_by_name, "ue_dap_cleanup")
  package.loaded["ue.dap"] = old_d
  for _, tab in ipairs(tabs) do
    if vim.api.nvim_tabpage_is_valid(tab) then
      vim.api.nvim_set_current_tabpage(tab)
      vim.cmd("tabclose!")
    end
  end
  for _, buf in ipairs(buffers) do
    if vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end
  if vim.api.nvim_tabpage_is_valid(original_tab) then
    vim.api.nvim_set_current_tabpage(original_tab)
  end
  if vim.api.nvim_win_is_valid(original_win) then
    vim.api.nvim_set_current_win(original_win)
  end
  require("utils.bottom_panel")._reset_for_test()
  if not ok then
    error(err, 0)
  end
end

t.describe("IDE debug: native layout ownership", function()
  t.it("preserves two tabs, source splits, dirty views, ratios and an unrelated nofile panel", function()
    with_ui(function(c)
      local before = {}
      for _, win in ipairs({ c.main, c.right, c.lower, c.panel, c.elsewhere, c.elsewhere2 }) do
        before[win] = snapshot(win)
      end
      c.start()
      for win in pairs(before) do
        t.assert_true(vim.api.nvim_win_is_valid(win), "opening DAP closed user window")
      end
      c.stop()
      for win, expected in pairs(before) do
        t.assert_true(vim.api.nvim_win_is_valid(win), "stopping DAP closed user window")
        local actual = snapshot(win)
        t.assert_eq(actual.buf, expected.buf)
        t.assert_true(vim.deep_equal(actual.view, expected.view), "reading position changed")
        t.assert_eq(actual.width, expected.width, "split width changed")
        t.assert_eq(actual.height, expected.height, "split height changed")
        if vim.bo[expected.buf].buftype == "" then
          t.assert_true(vim.bo[expected.buf].modified)
        end
      end
      t.assert_eq(#vim.api.nvim_list_tabpages(), 3)
    end)
  end)

  t.it("keeps deliberate split/buffer changes and does not reclaim a rail changed into source", function()
    with_ui(function(c)
      c.start()
      t.assert_true(vim.api.nvim_win_is_valid(c.main), "original source window survives")
      local owned
      for _, win in ipairs(vim.api.nvim_tabpage_list_wins(c.tabs[1])) do
        if vim.bo[vim.api.nvim_win_get_buf(win)].filetype == "dapui_scopes" then
          owned = win
          break
        end
      end
      t.assert_true(owned ~= nil, "native dap-ui rail opened")
      c.buffers[#c.buffers + 1] = source(owned, "repurposed")
      local repurposed_buf = vim.api.nvim_win_get_buf(owned)
      vim.api.nvim_set_current_win(c.main)
      c.buffers[#c.buffers + 1] = source(c.main, "chosen_during_debug")
      local chosen = vim.api.nvim_win_get_buf(c.main)
      vim.cmd("vsplit")
      local new_win = vim.api.nvim_get_current_win()
      c.buffers[#c.buffers + 1] = source(new_win, "new_split")
      vim.api.nvim_win_set_width(new_win, 43)
      vim.api.nvim_win_close(c.lower, true)
      local view = snapshot(c.main).view
      local ratio = vim.api.nvim_win_get_width(new_win) / vim.api.nvim_win_get_width(c.main)
      c.stop()
      for _, win in ipairs({ c.main, c.right, c.panel, new_win, owned }) do
        t.assert_true(vim.api.nvim_win_is_valid(win), "user's layout change was discarded")
      end
      t.assert_false(vim.api.nvim_win_is_valid(c.lower), "closed source split was respawned")
      t.assert_eq(vim.api.nvim_win_get_buf(owned), repurposed_buf)
      t.assert_eq(vim.api.nvim_win_get_buf(c.main), chosen)
      t.assert_true(vim.deep_equal(snapshot(c.main).view, view))
      local restored_ratio = vim.api.nvim_win_get_width(new_win) / vim.api.nvim_win_get_width(c.main)
      t.assert_true(math.abs(restored_ratio - ratio) < 0.03, "deliberate split proportions changed")
    end)
  end)

  t.it("restores a borrowed bottom panel and cleanup from another tab keeps its current window", function()
    with_ui(function(c)
      local panel = require("utils.bottom_panel")
      local task_win = panel.show("tasks", nil, { focus = false, height = 9 })
      local task_buf = vim.api.nvim_win_get_buf(task_win)
      local before = snapshot(task_win)
      c.start()
      t.assert_eq(c.d._dap_bottom_tab_win, task_win, "DAP borrows the existing shared host")
      vim.api.nvim_set_current_win(c.elsewhere2)
      c.stop()
      t.assert_eq(vim.api.nvim_get_current_win(), c.elsewhere2)
      t.assert_true(vim.api.nvim_win_is_valid(task_win), "borrowed task host was closed")
      t.assert_eq(vim.api.nvim_win_get_buf(task_win), task_buf)
      t.assert_eq(vim.api.nvim_win_get_height(task_win), before.height)
    end)
  end)

  t.it("a late terminated event does not close the next session's windows", function()
    with_ui(function(c)
      c.start()
      local older = c.session
      c.session = { config = { type = "lldb", name = "next session" } }
      c.dap.listeners.after.event_initialized.dapui_config(c.session)
      local bottom = c.d._dap_bottom_tab_win
      c.dap.listeners.before.event_terminated.dapui_config(older)
      t.assert_true(vim.api.nvim_win_is_valid(bottom), "stale cleanup closed current DAP host")
      c.dap.listeners.before.event_terminated.dapui_config(c.session)
    end)
  end)

  t.it("explicit reset does not close unrelated windows or respawn a deliberately closed split", function()
    with_ui(function(c)
      c.start()
      vim.api.nvim_win_close(c.lower, true)
      c.d._dap_close_debug_layout()
      t.assert_false(vim.api.nvim_win_is_valid(c.lower))
      t.assert_true(vim.api.nvim_win_is_valid(c.panel))
      c.d.dap_reset_layout()
      t.assert_true(vim.api.nvim_win_is_valid(c.main))
      t.assert_true(vim.api.nvim_win_is_valid(c.elsewhere2))
    end)
  end)

  t.it(
    "debug content opened explicitly in another tab is owned and closes without touching its source windows",
    function()
      with_ui(function(c)
        local first, second = snapshot(c.elsewhere), snapshot(c.elsewhere2)
        c.start()
        vim.api.nvim_set_current_win(c.elsewhere2)
        c.d.dap_bottom_tab("repl")
        local other_host = c.d._dap_bottom_tab_win
        t.assert_eq(vim.api.nvim_win_get_tabpage(other_host), c.tabs[2])
        c.stop()
        t.assert_false(vim.api.nvim_win_is_valid(other_host), "second tab's debug host leaked")
        t.assert_eq(vim.api.nvim_get_current_win(), c.elsewhere2)
        t.assert_true(vim.deep_equal(snapshot(c.elsewhere), first))
        t.assert_true(vim.deep_equal(snapshot(c.elsewhere2), second))
      end)
    end
  )

  local function native_frame(c, line)
    local native = require("dap.session")
    c.session.sign_group, c.session.filetype = "ide-debug-fixture", "cpp"
    c.session._request_scopes = function() end -- no inferior requests in a UI regression
    setmetatable(c.session, { __index = native })
    local previous = c.dap.defaults.lldb.switchbuf
    c.dap.defaults.lldb.switchbuf = "uselast"
    vim.api.nvim_set_current_win(c.main)
    local ok, err = pcall(native._frame_set, c.session, {
      id = 1,
      name = "native frame",
      line = line,
      column = 1,
      source = { path = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(c.right)) },
    })
    c.dap.defaults.lldb.switchbuf = previous
    if not ok then
      error(err, 0)
    end
  end

  t.it("a real nvim-dap frame jump restores the original buffer/view after stopping", function()
    with_ui(function(c)
      local before = snapshot(c.main)
      c.start()
      native_frame(c, 80)
      t.assert_eq(
        vim.api.nvim_win_get_buf(c.main),
        vim.api.nvim_win_get_buf(c.right),
        "native frame actually changed source"
      )
      t.assert_eq(vim.api.nvim_win_get_cursor(c.main)[1], 80)
      c.stop()
      t.assert_eq(vim.api.nvim_win_get_buf(c.main), before.buf)
      t.assert_true(vim.deep_equal(snapshot(c.main), before), "programmatic frame replaced reading context")
    end)
  end)

  t.it("a native stopped event and JSON stackTrace response bracket automatic frame restoration", function()
    with_ui(function(c)
      local before = snapshot(c.main)
      c.start()
      local native = require("dap.session")
      setmetatable(c.session, { __index = native })
      c.session.sign_group, c.session.filetype = "ide-debug-fixture", "cpp"
      c.session.id, c.session.seq = 1, 0
      c.session.threads, c.session.dirty =
        { [1] = { id = 1, name = "controlled thread", stopped = true } }, { threads = false }
      c.session.message_callbacks, c.session.message_requests = {}, {}
      c.session._request_scopes = function() end
      local sent
      c.session.client = {
        write = function(packet)
          local body = packet:match("\r\n\r\n(.*)$")
          if body then
            sent = vim.json.decode(body)
          end
        end,
      }
      local previous = c.dap.defaults.lldb.switchbuf
      c.dap.defaults.lldb.switchbuf = "uselast"
      vim.api.nvim_set_current_win(c.main)
      native.event_stopped(c.session, { threadId = 1, reason = "breakpoint", allThreadsStopped = true })
      t.assert_eq(sent.command, "stackTrace", "native DAP emitted the actual request")
      native.handle_body(
        c.session,
        vim.json.encode({
          type = "response",
          command = "stackTrace",
          success = true,
          request_seq = sent.seq,
          body = {
            stackFrames = {
              {
                id = 1,
                name = "controlled frame",
                line = 90,
                column = 1,
                source = { path = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(c.right)) },
              },
            },
            totalFrames = 1,
          },
        })
      )
      local jumped = vim.wait(1000, function()
        return vim.api.nvim_win_get_cursor(c.main)[1] == 90
      end, 5)
      c.dap.defaults.lldb.switchbuf = previous
      t.assert_true(jumped, "native response handler actually performed the frame jump")
      c.stop()
      t.assert_true(vim.deep_equal(snapshot(c.main), before), "automatic stop replaced original reading context")
    end)
  end)

  t.it("frame restoration keeps subsequent user input and uses their latest context before a later frame", function()
    with_ui(function(c)
      c.start()
      native_frame(c, 80)
      vim.api.nvim_win_set_cursor(c.main, { 84, 3 })
      local chosen = snapshot(c.main)
      native_frame(c, 95)
      c.stop()
      t.assert_eq(vim.api.nvim_win_get_buf(c.main), chosen.buf)
      t.assert_true(
        vim.deep_equal(snapshot(c.main).view, chosen.view),
        "user navigation before next frame was discarded"
      )
    end)
    with_ui(function(c)
      c.start()
      native_frame(c, 80)
      local frame_buf = vim.api.nvim_win_get_buf(c.main)
      vim.api.nvim_buf_set_lines(frame_buf, 79, 80, false, { "// user edited this stopped frame" })
      local chosen = snapshot(c.main)
      c.stop()
      t.assert_eq(vim.api.nvim_win_get_buf(c.main), frame_buf)
      t.assert_true(vim.deep_equal(snapshot(c.main).view, chosen.view))
      t.assert_contains(vim.api.nvim_buf_get_lines(frame_buf, 79, 80, false)[1], "user edited")
      t.assert_true(vim.bo[frame_buf].modified)
    end)
  end)

  t.it("mixed synthetic/local native stops restore context in either before-listener order", function()
    local failures = {}
    for _, capture_first in ipairs({ true, false }) do
      for _, mixed in ipairs({ true, false }) do
        local label = (capture_first and "capture first" or "sanitizer first")
          .. (mixed and " / mixed" or " / synthetic")
        local ok, err = xpcall(function()
          with_ui(function(c)
            local before = snapshot(c.main)
            c.start()
            -- This identifies the existing sanitizer without binding a device
            -- owner or starting any transport. The response and jump are native.
            c.session.config.name, c.session.config.request = "UE Android Attach / UI regression", "attach"
            local native = require("dap.session")
            setmetatable(c.session, { __index = native })
            c.session.sign_group, c.session.filetype = "ide-debug-fixture", "cpp"
            c.session.id, c.session.seq = 1, 0
            c.session.threads = { [1] = { id = 1, name = "controlled thread", stopped = true } }
            c.session.dirty, c.session.message_callbacks, c.session.message_requests = { threads = false }, {}, {}
            c.session._request_scopes = function() end
            local sent
            c.session.client = {
              write = function(packet)
                local body = packet:match("\r\n\r\n(.*)$")
                if body then
                  sent = vim.json.decode(body)
                end
              end,
            }
            local listeners = c.dap.listeners.before.stackTrace
            local capture, sanitize = listeners.ue_debug_layout, listeners.ue_source_path_rewrite
            c.dap.listeners.before.stackTrace = {
              controlled_order = function(...)
                if capture_first then
                  capture(...)
                  sanitize(...)
                else
                  sanitize(...)
                  capture(...)
                end
              end,
            }
            local layout = require("ue.dap._layout")
            local original_capture, captures = layout.before_frame, 0
            layout.before_frame = function(states)
              captures = captures + 1
              return original_capture(states)
            end
            local passed, failure = xpcall(function()
              local frames = {
                {
                  id = 10,
                  name = "PC-only frame",
                  line = 0,
                  column = 1,
                  source = { name = "synthetic", sourceReference = 42 },
                },
              }
              if mixed then
                frames[#frames + 1] = {
                  id = 11,
                  name = "local frame",
                  line = 105,
                  column = 1,
                  source = { path = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(c.right)) },
                }
              end
              c.dap.defaults.lldb.switchbuf = "uselast"
              vim.api.nvim_set_current_win(c.main)
              native.event_stopped(c.session, { threadId = 1, reason = "breakpoint", allThreadsStopped = true })
              t.assert_eq(sent.command, "stackTrace")
              native.handle_body(
                c.session,
                vim.json.encode({
                  type = "response",
                  command = "stackTrace",
                  success = true,
                  request_seq = sent.seq,
                  body = { stackFrames = frames, totalFrames = #frames },
                })
              )
              t.assert_true(
                vim.wait(1000, function()
                  return c.session.current_frame ~= nil
                end, 5),
                label
              )
              if mixed then
                t.assert_eq(c.session.current_frame.id, 11, "native callback uses the sanitized local frame")
                t.assert_eq(vim.api.nvim_win_get_cursor(c.main)[1], 105, "native callback actually jumps")
                t.assert_eq(vim.api.nvim_win_get_buf(c.main), vim.api.nvim_win_get_buf(c.right))
                c.stop()
                t.assert_true(vim.deep_equal(snapshot(c.main), before), label .. " lost pre-debug context")
              else
                t.assert_eq(captures, 0, "all-synthetic response owns no frame restoration")
                t.assert_eq(c.session.current_frame.line, -1)
                t.assert_eq(vim.api.nvim_win_get_buf(c.main), before.buf, "synthetic frame never opens source")
                vim.api.nvim_win_set_cursor(c.main, { 68, 3 })
                local chosen = snapshot(c.main).view
                c.stop()
                t.assert_eq(vim.api.nvim_win_get_buf(c.main), before.buf)
                t.assert_true(
                  vim.deep_equal(snapshot(c.main).view, chosen),
                  "synthetic response reclaimed user navigation"
                )
              end
            end, debug.traceback)
            layout.before_frame = original_capture
            if not passed then
              error(failure, 0)
            end
          end)
        end, debug.traceback)
        if not ok then
          failures[#failures + 1] = label .. ": " .. err
        end
      end
    end
    t.assert_eq(#failures, 0, table.concat(failures, "\n"))
  end)
end)

t.describe("IDE debug: retained log reading", function()
  local logs = require("ue.dap._log_view")
  local function with_log(test, opts)
    local old_tab = vim.api.nvim_get_current_tabpage()
    local old_win = vim.api.nvim_get_current_win()
    vim.cmd("tabnew")
    local tab = vim.api.nvim_get_current_tabpage()
    local view = logs.new(opts)
    local win = require("utils.bottom_panel").show("logcat", view.buf, { focus = true, height = 10 })
    logs.shown(view, win)
    local ok, err = xpcall(function()
      test(view, win)
    end, debug.traceback)
    if vim.api.nvim_tabpage_is_valid(tab) then
      vim.api.nvim_set_current_tabpage(tab)
      vim.cmd("tabclose!")
    end
    if vim.api.nvim_tabpage_is_valid(old_tab) then
      vim.api.nvim_set_current_tabpage(old_tab)
    end
    if vim.api.nvim_win_is_valid(old_win) then
      vim.api.nvim_set_current_win(old_win)
    end
    if vim.api.nvim_buf_is_valid(view.buf) then
      vim.api.nvim_buf_delete(view.buf, { force = true })
    end
    if not ok then
      error(err, 0)
    end
  end

  local function line(level, tag, text)
    return "01-01 00:00:00.000  1000  1001 " .. level .. " " .. tag .. " : " .. text
  end

  local function contents(view)
    return table.concat(vim.api.nvim_buf_get_lines(view.buf, 1, -1, false), "\n")
  end

  t.it("filters retained level/content/tag history and preserves source/crash actions", function()
    with_log(function(view)
      local records =
        { line("I", "UE4", "started"), line("E", "UE4", "boom File.cpp:42"), line("W", "Other", "warning") }
      logs.append(view, records)
      logs.render(view)
      t.assert_eq(contents(view), table.concat(records, "\n"))
      logs.filter(view, { level = "W", tag = "UE4", text = "boom" })
      t.assert_eq(contents(view), records[2])
      logs.filter(view, { level = "V", tag = "", text = "" })
      t.assert_eq(contents(view), table.concat(records, "\n"), "filtered-out original records remain available")
      local keys = {}
      for _, map in ipairs(vim.api.nvim_buf_get_keymap(view.buf, "n")) do
        keys[map.lhs] = map
      end
      t.assert_type(keys["<CR>"].callback, "function")
      t.assert_eq(keys["gx"].rhs, "<Cmd>UEAndroidCrash<CR>")
      keys["gl"].callback()
      keys["gl"].callback()
      t.assert_eq(view.level, "I", "cycling reads the latest local filter rather than restarting with stale options")
      keys["g0"].callback()
      t.assert_eq(contents(view), table.concat(records, "\n"))
      t.assert_false(vim.bo[view.buf].modifiable)
    end)
  end)

  t.it("scrolling up pauses following and G explicitly resumes at the newest line", function()
    with_log(function(view, win)
      local records = {}
      for i = 1, 70 do
        records[i] = line("I", "UE4", "row " .. i)
      end
      logs.append(view, records)
      logs.render(view)
      t.assert_eq(vim.api.nvim_win_get_cursor(win)[1], 71)
      vim.api.nvim_win_set_cursor(win, { 22, 5 })
      vim.api.nvim_win_call(win, function()
        vim.cmd("normal! zt")
      end)
      local before = vim.api.nvim_win_call(win, vim.fn.winsaveview)
      logs.append(view, { line("E", "UE4", "later") })
      logs.render(view)
      t.assert_true(
        vim.deep_equal(vim.api.nvim_win_call(win, vim.fn.winsaveview), before),
        "append moved paused viewport"
      )
      t.assert_false(view.follow)
      local resume
      for _, map in ipairs(vim.api.nvim_buf_get_keymap(view.buf, "n")) do
        if map.lhs == "G" then
          resume = map.callback
        end
      end
      resume()
      logs.append(view, { line("E", "UE4", "newest") })
      logs.render(view)
      t.assert_eq(vim.api.nvim_win_get_cursor(win)[1], 73)
      t.assert_true(view.follow)
    end)
  end)

  t.it("bounded eviction is visible and retained filtered records can be revisited", function()
    with_log(function(view, win)
      logs.append(view, { line("I", "UE4", "one"), line("E", "UE4", "two"), line("I", "UE4", "three") })
      logs.render(view)
      vim.api.nvim_win_set_cursor(win, { 2, 0 })
      logs.append(view, { line("W", "UE4", "four"), line("E", "UE4", "five") })
      logs.render(view)
      t.assert_eq(view.dropped, 2)
      t.assert_eq(vim.api.nvim_buf_line_count(view.buf), 4)
      t.assert_contains(vim.api.nvim_buf_get_lines(view.buf, 0, 1, false)[1], "已淘汰 2")
      t.assert_contains(contents(view), "three")
      t.assert_false(contents(view):find("one", 1, true) ~= nil)
      logs.filter(view, { level = "E" })
      t.assert_contains(contents(view), "five")
      logs.filter(view, { level = "V" })
      t.assert_contains(contents(view), "three")
      logs.append(view, { string.rep("x", 300) })
      logs.render(view)
      t.assert_true(view.bytes <= view.max_bytes)
      t.assert_true(view.truncated > 0)
      t.assert_contains(contents(view), "line truncated")
    end, { max_lines = 3, max_bytes = 500, max_line_bytes = 100 })
  end)

  t.it("joins split Unicode chunks and flushes the final unfinished line when stopped", function()
    with_log(function(view)
      local record = line("E", "UE4", "错误🙂 File.cpp:42")
      local cut = record:find("🙂", 1, true) + 1
      logs.feed(view, { record:sub(1, cut) })
      logs.feed(view, { record:sub(cut + 1), "tail without newline" })
      logs.stopped(view, "device disconnected exit=1")
      logs.render(view)
      t.assert_eq(contents(view), record .. "\ntail without newline")
      t.assert_contains(vim.api.nvim_buf_get_lines(view.buf, 0, 1, false)[1], "device disconnected")
      t.assert_true(vim.api.nvim_buf_is_valid(view.buf))
      logs.filter(view, { text = "错误🙂" })
      t.assert_eq(contents(view), record)
    end)
  end)

  t.it("a real reader survives hide/filter/reopen and its stopped output remains readable", function()
    with_log(function(view, win)
      local child_file = vim.fn.tempname():gsub("\\", "/") .. ".lua"
      local stop_file = child_file .. ".stop"
      vim.fn.writefile({
        "io.stdout:write(" .. vim.json.encode(line("I", "UE4", "native ready") .. "\n") .. "); io.stdout:flush()",
        "io.stdout:write('unfinished'); io.stdout:flush()",
        "vim.wait(10000, function() return vim.fn.filereadable(" .. string.format("%q", stop_file) .. ") == 1 end, 10)",
        "io.stdout:write(' joined'); io.stdout:flush()",
      }, child_file)
      local exited
      local job = vim.fn.jobstart({ vim.v.progpath, "--headless", "-u", "NONE", "-i", "NONE", "-l", child_file }, {
        on_stdout = function(_, data)
          logs.feed(view, data)
        end,
        on_exit = function(_, code)
          exited = code
          logs.stopped(view, "reader ended")
        end,
      })
      local ok, err = xpcall(function()
        t.assert_true(job > 0)
        t.assert_true(vim.wait(3000, function()
          return contents(view):find("native ready", 1, true) ~= nil
        end, 10))
        vim.api.nvim_win_close(win, true)
        logs.filter(view, { text = "ready" })
        t.assert_eq(vim.fn.jobwait({ job }, 0)[1], -1, "hide/filter terminated the actual child")
        local reopened = require("utils.bottom_panel").show("logcat", view.buf)
        logs.shown(view, reopened)
        t.assert_eq(vim.api.nvim_win_get_buf(reopened), view.buf)
        vim.fn.writefile({ "stop" }, stop_file)
        t.assert_true(vim.wait(3000, function()
          return exited ~= nil
        end, 10))
        t.assert_eq(exited, 0)
        logs.filter(view, { text = "" })
        logs.render(view)
        t.assert_contains(contents(view), "native ready")
        t.assert_contains(contents(view), "unfinished joined")
      end, debug.traceback)
      if not exited then
        pcall(vim.fn.jobstop, job)
        pcall(vim.fn.jobwait, { job }, 1000)
      end
      vim.fn.delete(child_file)
      vim.fn.delete(stop_file)
      if not ok then
        error(err, 0)
      end
    end)
  end)
end)

t.describe("IDE debug: frozen launch completion", function()
  t.it("passes explicit launch context, callbacks and cancellation through the wrapper unchanged", function()
    local d = require("ue.dap")
    local prior = package.loaded["ue.dap.android"]
    local _, previous_core = debug.getupvalue(d.setup_core, 1)
    local seen, changes = nil, 0
    local handle = {
      cancel = function()
        return true
      end,
    }
    package.loaded["ue.dap.android"] = {
      launch = function(opts)
        seen = opts
        return handle
      end,
    }
    d.setup_core({
      resolve_context = function()
        changes = changes + 1
        return { project_root = "wrong-live-project" }
      end,
      resolve_target_identity = function()
        changes = changes + 1
        return { target = "wrong", configuration = "Shipping" }
      end,
    })
    local opts = {
      owner = "run-A",
      context = {
        project_root = "frozen-project",
        target = "Game",
        configuration = "Test",
        state = { android_package = "com.example.game" },
      },
      serial = "DEVICE-A",
      package_name = "com.example.game",
      configuration = "Test",
      on_stage = function() end,
      on_complete = function() end,
    }
    local ok, err = xpcall(function()
      local result = d.android_dap_launch(opts)
      t.assert_eq(result, handle)
      t.assert_eq(changes, 0, "frozen run must not re-resolve live project/target/configuration")
      t.assert_eq(seen.owner, "run-A")
      t.assert_eq(seen.serial, "DEVICE-A")
      t.assert_eq(seen.package_name, "com.example.game")
      t.assert_eq(seen.on_stage, opts.on_stage)
      t.assert_eq(seen.on_complete, opts.on_complete)
      t.assert_true(vim.deep_equal(seen.context, opts.context))
    end, debug.traceback)
    package.loaded["ue.dap.android"] = prior
    d.setup_core(previous_core)
    if not ok then
      error(err, 0)
    end
  end)

  local function with_attach(test)
    local android = require("ue.dap.android")
    local common, dap = require("ue.dap._common"), require("dap")
    local saved = {
      session = android._session,
      stop = android.stop_android_debugger,
      run = common.run,
      last = android._last_session,
      busy = android._attach_in_progress,
      cleanup = android._cleanup_in_progress,
      dap_session = dap.session,
      stdpath = vim.fn.stdpath,
      listener = dap.listeners.after.attach["ue-android-attach-result"],
    }
    local calls, cfg, run_options, stopped = {}, nil, nil, 0
    vim.fn.stdpath = function(kind)
      if kind == "cache" then
        return vim.env.NVIM_TEST_RUN_ROOT
      end
      return saved.stdpath(kind)
    end
    dap.session = function()
      return nil
    end
    android.stop_android_debugger = function()
      stopped = stopped + 1
      return {}
    end
    common.run = function(config, _, _, _, opts)
      cfg, run_options = config, opts
      return true
    end
    local operation = android._begin_operation({
      owner = "run-A",
      on_complete = function(code, detail)
        calls[#calls + 1] = { code = code, detail = detail }
      end,
    })
    local sess = android._session
    sess.serial, sess.pid, sess.package_name = "DEVICE-A", 4242, "com.example.game"
    sess.symbol_lib = nil
    operation.stage("attach", { state = "running" })
    android._attach_in_progress = true
    local c = {
      android = android,
      common = common,
      dap = dap,
      operation = operation,
      session = sess,
      calls = calls,
      config = function()
        return cfg
      end,
      options = function()
        return run_options
      end,
      stopped = function()
        return stopped
      end,
      start = function()
        android._finalize_attach_config(sess, 4242, "UE Android Launch (wait-for-debugger)", "fixture")
      end,
    }
    local ok, err = xpcall(function()
      test(c)
    end, debug.traceback)
    android._session, android.stop_android_debugger, common.run = saved.session, saved.stop, saved.run
    android._last_session, android._attach_in_progress, android._cleanup_in_progress =
      saved.last, saved.busy, saved.cleanup
    dap.session, vim.fn.stdpath = saved.dap_session, saved.stdpath
    dap.listeners.after.attach["ue-android-attach-result"] = saved.listener
    if not ok then
      error(err, 0)
    end
  end

  t.it("reports success exactly once only after the matching attach response", function()
    with_attach(function(c)
      c.start()
      t.assert_eq(#c.calls, 0, "request creation is not attach success")
      local listener = c.dap.listeners.after.attach["ue-android-attach-result"]
      listener({ config = vim.tbl_extend("force", c.config(), { _ue_operation_id = -1 }) }, nil)
      t.assert_eq(#c.calls, 0, "another operation with the same PID cannot complete this one")
      listener({ config = c.config() }, nil)
      listener({ config = c.config() }, nil)
      t.assert_eq(#c.calls, 1)
      t.assert_eq(c.calls[1].code, 0)
      t.assert_eq(c.calls[1].detail.owner, "run-A")
      t.assert_true(c.session.attach_succeeded)
      t.assert_false(c.android._attach_in_progress)
    end)
  end)

  t.it("attach failure and adapter close both finish with failure, never initialized success", function()
    with_attach(function(c)
      c.start()
      c.dap.listeners.after.attach["ue-android-attach-result"]({ config = c.config() }, { message = "attach refused" })
      t.assert_eq(c.calls[1].code, 1)
      t.assert_contains(c.calls[1].detail.reason, "attach refused")
      t.assert_false(c.session.attach_succeeded)
      t.assert_eq(c.stopped(), 1)
    end)
    with_attach(function(c)
      c.start()
      c.options().after() -- actual nvim-dap close callback has no session argument
      t.assert_true(vim.wait(1000, function()
        return #c.calls == 1
      end, 5))
      t.assert_eq(c.calls[1].code, 1)
      t.assert_contains(c.calls[1].detail.reason, "adapter closed")
    end)
  end)

  t.it("missing adapter completes once and cancelled callbacks cannot affect the next attempt", function()
    with_attach(function(c)
      c.common.run = function()
        return false
      end
      c.start()
      t.assert_eq(#c.calls, 1)
      t.assert_eq(c.calls[1].code, 1)
    end)
    with_attach(function(c)
      c.start()
      local older = c.dap.listeners.after.attach["ue-android-attach-result"]
      local older_config = c.config()
      local pending = c.operation.hold()
      t.assert_true(c.operation.handle:cancel("loop stopped"))
      t.assert_eq(c.calls[1].code, -1)
      t.assert_eq(c.stopped(), 0, "cleanup must wait for a command that can still arm the gate")
      pending()
      t.assert_eq(c.stopped(), 1)
      t.assert_false(c.operation.handle:cancel())
      local newer = c.android._begin_operation({ owner = "run-B" })
      older({ config = older_config }, nil)
      t.assert_eq(#c.calls, 1)
      t.assert_eq(c.android._session._operation, newer)
      t.assert_nil(c.android._session.attach_succeeded)
    end)
  end)
end)
