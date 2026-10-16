local t = require("tests.harness")
local root = t.bootstrap()
local api = vim.api

local function upvalue(fn, wanted)
  for i = 1, 100 do
    local name, value = debug.getupvalue(fn, i)
    if not name then break end
    if name == wanted then return value, i end
  end
  error("missing upvalue " .. wanted)
end

local function isolated(run)
  local names = { "utils.layout", "utils.bottom_panel", "utils.yazi", "ue.build_diagnostics", "codediff.ui.lifecycle" }
  local saved, tabs, buffers = {}, {}, {}
  for _, name in ipairs(names) do saved[name], package.loaded[name] = package.loaded[name], nil end
  local sessions = {}
  package.loaded["codediff.ui.lifecycle"] = { get_session = function(tab) return sessions[tab] end }
  local initial = api.nvim_get_current_tabpage()
  for _, tab in ipairs(api.nvim_list_tabpages()) do tabs[tab] = true end
  for _, buf in ipairs(api.nvim_list_bufs()) do buffers[buf] = true end
  local hidden = vim.o.hidden
  vim.o.hidden = true
  vim.cmd("tabnew")
  local ok, err = xpcall(function()
    run(require("utils.layout"), sessions, api.nvim_get_current_tabpage())
  end, debug.traceback)
  for _, buf in ipairs(api.nvim_list_bufs()) do
    if not buffers[buf] then vim.bo[buf].modified = false end
  end
  for _, tab in ipairs(api.nvim_list_tabpages()) do
    if not tabs[tab] then api.nvim_set_current_tabpage(tab); vim.cmd("tabclose!") end
  end
  if api.nvim_tabpage_is_valid(initial) then api.nvim_set_current_tabpage(initial) end
  vim.o.hidden = hidden
  for _, name in ipairs(names) do package.loaded[name] = saved[name] end
  if not ok then error(err, 0) end
end

local function buffer(lines, bt)
  local buf = api.nvim_create_buf(true, false)
  api.nvim_buf_set_lines(buf, 0, -1, false, lines or { "one", "two", "three" })
  vim.bo[buf].buftype = bt or ""
  vim.bo[buf].modified = false
  return buf
end

local function review(layout, sessions, tab)
  local wins, bufs = {}, {}
  for i = 1, 3 do
    if i > 1 then vim.cmd("rightbelow vnew") end
    wins[i], bufs[i] = api.nvim_get_current_win(), buffer(nil, i == 3 and "nofile" or "")
    api.nvim_win_set_buf(wins[i], bufs[i])
  end
  sessions[tab] = { original_win = wins[1], modified_win = wins[2], panel = { view = { winid = wins[3] } } }
  layout.sync_review(tab)
  return wins, bufs
end

local function unchanged(wins, bufs)
  for i, win in ipairs(wins) do t.assert_eq(api.nvim_win_get_buf(win), bufs[i], "pane " .. i) end
end

local serial = 0
local function file()
  serial = serial + 1
  local path = root .. "/.tmp/review-gd/terminal-layout-" .. vim.fn.getpid() .. "-" .. serial .. ".cpp"
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  vim.fn.writefile({ "one", "two", "three" }, path)
  return path
end

local function enter(buf)
  for _, map in ipairs(api.nvim_buf_get_keymap(buf, "n")) do
    if map.lhs == "<CR>" then return map.callback() end
  end
  error("missing Enter mapping")
end

-- Invoke the real completion boundary without launching a host process. Only
-- chooser I/O is supplied; tabs, window ownership and buffer opens are native.
local function finish_yazi(path, origin, tab, session, before_finish)
  local yazi = require("utils.yazi")
  local finish = upvalue(yazi.open_current, "finish")
  local old_first, first_i = upvalue(finish, "first_path")
  local old_cleanup, cleanup_i = upvalue(finish, "cleanup_path")
  debug.setupvalue(finish, first_i, function() return path end)
  debug.setupvalue(finish, cleanup_i, function() end)
  local buf = buffer(nil, "nofile")
  local win = api.nvim_open_win(buf, true, { relative = "editor", row = 1, col = 1, width = 20, height = 3 })
  yazi.state = {
    buf = buf, win = win, origin_win = origin, origin_tab = tab, review_session = session,
    navigation_owner = require("utils.layout").navigation_owner(tab),
    origin_buf = api.nvim_win_get_buf(origin), origin_cursor = api.nvim_win_get_cursor(origin),
    origin_tick = api.nvim_buf_get_changedtick(api.nvim_win_get_buf(origin)),
  }
  local ok, err = pcall(function() if before_finish then before_finish() end; finish(0) end)
  debug.setupvalue(finish, first_i, old_first)
  debug.setupvalue(finish, cleanup_i, old_cleanup)
  if not ok then error(err, 0) end
end

t.describe("terminal layout owner boundaries", function()
  for _, entry in ipairs({ "build", "logcat", "yazi" }) do
    for _, mutation in ipairs({ "load_tab", "target_buffer", "target_owner" }) do
      t.it(entry .. " cancels " .. mutation .. " callback without reviving old navigation", function()
        isolated(function(layout, sessions, tab)
          local wins, bufs = review(layout, sessions, tab)
          api.nvim_set_current_win(wins[2])
          local code = assert(layout.resolve({ tab = tab, source_win = wins[2] }))
          local before = api.nvim_win_get_buf(code)
          local path = file()
          local target = vim.fn.bufadd(path)
          local replacement = buffer({ "new selection", "second", "third" })
          vim.cmd("tabnew")
          local foreign, foreign_buf = api.nvim_get_current_win(), api.nvim_get_current_buf()
          api.nvim_set_current_win(wins[2])
          local fired = false
          local watch = api.nvim_create_autocmd(mutation == "load_tab" and "BufReadPost" or "BufEnter", {
            buffer = target, callback = function()
              if fired or (mutation ~= "load_tab" and api.nvim_get_current_win() ~= code) then return end
              fired = true
              if mutation == "load_tab" then api.nvim_set_current_win(foreign)
              elseif mutation == "target_buffer" then
                api.nvim_win_set_buf(code, replacement)
                api.nvim_win_set_cursor(code, { 1, 0 })
              else
                sessions[tab] = vim.deepcopy(sessions[tab])
                api.nvim_win_set_cursor(code, { 1, 0 })
              end
            end,
          })
          if entry == "build" then
            local d = require("ue.build_diagnostics")
            d.publish("handoff fixture", { { filename = path, lnum = 3, col = 3, type = "E", text = "error" } })
            api.nvim_set_current_win(wins[2])
            t.assert_false(d.jump_first())
          elseif entry == "logcat" then
            local log = buffer({ path .. ":3" }, "nofile")
            require("utils.android_logcat").attach(log)
            require("utils.bottom_panel").show("logcat", log)
            enter(log)
          else finish_yazi(path, wins[2], tab, sessions[tab]) end
          api.nvim_del_autocmd(watch)
          t.assert_true(fired, "native callback must run")
          if mutation == "load_tab" then
            t.assert_eq(api.nvim_get_current_win(), foreign)
            t.assert_eq(api.nvim_win_get_buf(code), before)
            t.assert_eq(api.nvim_win_get_buf(foreign), foreign_buf)
          else
            t.assert_eq(api.nvim_get_current_win(), code)
            t.assert_true(vim.deep_equal(api.nvim_win_get_cursor(code), { 1, 0 }))
            if mutation == "target_buffer" then t.assert_eq(api.nvim_win_get_buf(code), replacement) end
          end
          unchanged(wins, bufs)
        end)
      end)
    end
  end
  for _, entry in ipairs({ "build", "logcat", "yazi" }) do
    t.it("debug " .. entry .. " external navigation switches to normal without replacing debug panes", function()
      isolated(function(layout, sessions, tab)
        local wins, bufs = review(layout, sessions, tab)
        sessions[tab] = nil
        layout.sync_review(tab)
        local token = {}
        layout.register_group("debug", { tab = tab, token = token, main = wins[2] })
        layout.register(wins[1], "aux", { owner = "debug" })
        layout.register(wins[2], "code", { owner = "debug" })
        local path = file()
        local target = vim.fn.bufadd(path)
        vim.fn.bufload(target)
        api.nvim_set_current_win(wins[2])
        if entry == "build" then
          local diagnostics = require("ue.build_diagnostics")
          diagnostics.publish("debug build", { { bufnr = target, lnum = 2, type = "E", text = "error" } })
          api.nvim_set_current_win(wins[2])
          t.assert_true(diagnostics.jump_first())
        elseif entry == "logcat" then
          local log = buffer({ path .. ":2" }, "nofile")
          require("utils.android_logcat").attach(log)
          require("utils.bottom_panel").show("logcat", log)
          enter(log)
        else
          finish_yazi(path, wins[2], tab)
        end
        t.assert_true(api.nvim_get_current_tabpage() ~= tab)
        t.assert_eq(api.nvim_get_current_buf(), target)
        unchanged(wins, bufs)
        t.assert_eq(layout.navigation_owner(tab), token)
      end)
    end)
  end
  t.it("review panel is pinned while its owner can cycle and remove contents", function()
    isolated(function(layout, sessions, tab)
      local wins, bufs = review(layout, sessions, tab)
      local panel = require("utils.bottom_panel")
      local host = panel.show("build", buffer())
      t.assert_true(vim.wo[host].winfixbuf)
      t.assert_false(pcall(api.nvim_win_set_buf, host, buffer()), "ordinary assignment must fail")
      t.assert_eq(panel.show("logcat", buffer()), host)
      local log = api.nvim_win_get_buf(host)
      t.assert_true(panel.remove("logcat", log))
      t.assert_true(vim.wo[host].winfixbuf)
      t.assert_true(layout.resolve({ tab = tab, source_win = host }) ~= host)
      unchanged(wins, bufs)
    end)
  end)

  t.it("ordinary panel preserves replacement and releases an obsolete panel role", function()
    isolated(function(layout)
      local panel = require("utils.bottom_panel")
      local host = panel.show("build", buffer())
      t.assert_false(vim.wo[host].winfixbuf)
      api.nvim_win_set_buf(host, buffer())
      t.assert_nil(panel.window())
      t.assert_eq(layout.resolve({ source_win = host, create = false }), host)
    end)
  end)

  t.it("review pin restores its prior state when review ownership ends", function()
    isolated(function(layout, sessions, tab)
      review(layout, sessions, tab)
      local panel = require("utils.bottom_panel")
      local host = panel.show("build", buffer())
      sessions[tab] = nil
      t.assert_eq(panel.window(), host)
      t.assert_false(vim.wo[host].winfixbuf)
      vim.wo[host].winfixbuf = true
      local original = api.nvim_tabpage_list_wins(tab)
      sessions[tab] = { original_win = original[1], modified_win = original[2] }
      panel.show("tasks")
      sessions[tab] = nil
      panel.window()
      t.assert_true(vim.wo[host].winfixbuf, "preserve a pin belonging to another owner")
    end)
  end)

  t.it("first build error opens a hidden dirty target in code and preserves new quickfix", function()
    isolated(function(layout, sessions, tab)
      local wins, bufs = review(layout, sessions, tab)
      local target = buffer({ "one", "dirty target", "three" })
      vim.bo[target].modified = true
      local diagnostics = require("ue.build_diagnostics")
      diagnostics.publish("old build", { { bufnr = target, lnum = 2, col = 3, type = "E", text = "error" } })
      vim.fn.setqflist({}, " ", { title = "new search", items = { { bufnr = target, lnum = 1, text = "search" } } })
      local qf = vim.fn.getqflist({ id = 0, changedtick = 0 })
      api.nvim_set_current_win(wins[2])
      t.assert_true(diagnostics.jump_first())
      t.assert_true(api.nvim_get_current_tabpage() ~= tab)
      t.assert_eq(#api.nvim_tabpage_list_wins(tab), 4)
      t.assert_eq(api.nvim_get_current_buf(), target)
      t.assert_true(vim.deep_equal(api.nvim_win_get_cursor(0), { 2, 2 }))
      t.assert_true(vim.bo[target].modified)
      t.assert_true(vim.deep_equal(vim.fn.getqflist({ id = 0, changedtick = 0 }), qf))
      unchanged(wins, bufs)
    end)
  end)

  t.it("first build error does not reuse an existing aux target", function()
    isolated(function(layout, sessions, tab)
      local wins, bufs = review(layout, sessions, tab)
      local diagnostics = require("ue.build_diagnostics")
      diagnostics.publish("build", { { bufnr = bufs[1], lnum = 3, type = "E", text = "error" } })
      api.nvim_set_current_win(require("utils.bottom_panel").window())
      t.assert_true(diagnostics.jump_first())
      t.assert_true(api.nvim_get_current_win() ~= wins[1])
      t.assert_eq(api.nvim_get_current_buf(), bufs[1])
      unchanged(wins, bufs)
    end)
  end)

  t.it("first build error cancels when BufRead edits the source", function()
    isolated(function(layout, sessions, tab)
      local wins, bufs = review(layout, sessions, tab)
      local path = file()
      local diagnostics = require("ue.build_diagnostics")
      diagnostics.publish("build", { { filename = path, lnum = 2, type = "E", text = "error" } })
      api.nvim_set_current_win(wins[2])
      api.nvim_create_autocmd("BufReadPost", { buffer = vim.fn.bufnr(path), once = true,
        callback = function() api.nvim_buf_set_lines(bufs[2], 1, 2, false, { "new edit" }) end })
      t.assert_false(diagnostics.jump_first())
      t.assert_eq(api.nvim_get_current_win(), wins[2])
      t.assert_eq(api.nvim_buf_get_lines(bufs[2], 1, 2, false)[1], "new edit")
      unchanged(wins, bufs)
    end)
  end)

  t.it("logcat Enter routes past the alternate diff and preserves hidden dirty source", function()
    isolated(function(layout, sessions, tab)
      local wins, bufs = review(layout, sessions, tab)
      local path = file()
      local target = vim.fn.bufadd(path)
      vim.fn.bufload(target)
      api.nvim_buf_set_lines(target, 1, 2, false, { "unsaved source" })
      local log = buffer({ "[File:" .. path .. "] [Line: 2]" }, "nofile")
      require("utils.android_logcat").attach(log)
      api.nvim_set_current_win(wins[2])
      local host = require("utils.bottom_panel").show("logcat", log)
      enter(log)
      t.assert_true(api.nvim_get_current_tabpage() ~= tab)
      t.assert_eq(api.nvim_get_current_buf(), target)
      t.assert_eq(api.nvim_win_get_cursor(0)[1], 2)
      t.assert_true(vim.bo[target].modified)
      t.assert_eq(api.nvim_win_get_buf(host), log)
      t.assert_true(vim.wo[host].winfixbuf)
      unchanged(wins, bufs)
    end)
  end)

  t.it("ordinary logcat keeps its previous editor window", function()
    isolated(function()
      local origin = api.nvim_get_current_win()
      local path = file()
      local log = buffer({ path .. ":3" }, "nofile")
      require("utils.android_logcat").attach(log)
      local host = require("utils.bottom_panel").show("logcat", log)
      enter(log)
      t.assert_eq(api.nvim_get_current_win(), origin)
      t.assert_eq(api.nvim_win_get_cursor(0)[1], 3)
      t.assert_eq(api.nvim_win_get_buf(host), log)
    end)
  end)

  t.it("logcat cancels when BufRead changes the selected log line", function()
    isolated(function(layout, sessions, tab)
      local wins, bufs = review(layout, sessions, tab)
      local path = file()
      local log = buffer({ path .. ":2", "new selection" }, "nofile")
      require("utils.android_logcat").attach(log)
      local host = require("utils.bottom_panel").show("logcat", log)
      local target = vim.fn.bufadd(path)
      api.nvim_create_autocmd("BufReadPost", { buffer = target, once = true,
        callback = function() api.nvim_win_set_cursor(host, { 2, 0 }) end })
      enter(log)
      t.assert_eq(api.nvim_get_current_win(), host)
      t.assert_eq(api.nvim_win_get_cursor(host)[1], 2)
      t.assert_eq(api.nvim_win_get_buf(host), log)
      unchanged(wins, bufs)
    end)
  end)

  t.it("Yazi completion from a diff origin opens the selected dirty file in code", function()
    isolated(function(layout, sessions, tab)
      local wins, bufs = review(layout, sessions, tab)
      local path = file()
      local target = vim.fn.bufadd(path)
      vim.fn.bufload(target)
      api.nvim_buf_set_lines(target, 1, 2, false, { "dirty chosen" })
      api.nvim_set_current_win(wins[2])
      finish_yazi(path, wins[2], tab, sessions[tab])
      t.assert_true(api.nvim_get_current_tabpage() ~= tab)
      t.assert_eq(api.nvim_get_current_buf(), target)
      t.assert_true(api.nvim_get_current_win() ~= wins[2])
      t.assert_true(vim.bo[target].modified)
      unchanged(wins, bufs)
    end)
  end)

  t.it("Yazi completion does not return from a different tab", function()
    isolated(function(layout, sessions, tab)
      local wins, bufs = review(layout, sessions, tab)
      local path = file()
      local foreign, foreign_buf
      finish_yazi(path, wins[2], tab, sessions[tab], function()
        vim.cmd("tabnew")
        foreign, foreign_buf = api.nvim_get_current_win(), api.nvim_get_current_buf()
      end)
      t.assert_eq(api.nvim_get_current_win(), foreign)
      t.assert_eq(api.nvim_get_current_buf(), foreign_buf)
      unchanged(wins, bufs)
    end)
  end)

  t.it("Yazi completion rejects replaced review ownership", function()
    isolated(function(layout, sessions, tab)
      local wins, bufs = review(layout, sessions, tab)
      local old = sessions[tab]
      finish_yazi(file(), wins[2], tab, old, function() sessions[tab] = vim.deepcopy(old) end)
      unchanged(wins, bufs)
      t.assert_eq(#api.nvim_tabpage_list_wins(tab), 3)
    end)
  end)

  t.it("Yazi completion rejects an origin reused for new work", function()
    isolated(function(layout, sessions, tab)
      local wins, bufs = review(layout, sessions, tab)
      local replacement = buffer({ "new work" })
      finish_yazi(file(), wins[2], tab, sessions[tab], function()
        api.nvim_win_set_buf(wins[2], replacement)
      end)
      t.assert_eq(api.nvim_win_get_buf(wins[2]), replacement)
      t.assert_eq(#api.nvim_tabpage_list_wins(tab), 3)
      t.assert_eq(api.nvim_win_get_buf(wins[1]), bufs[1])
    end)
  end)

  t.it("Yazi completion uses code even when its chosen file is already in aux", function()
    isolated(function(layout, sessions, tab)
      local wins, bufs = review(layout, sessions, tab)
      local path = file()
      local target = vim.fn.bufadd(path)
      vim.fn.bufload(target)
      api.nvim_win_set_buf(wins[1], target)
      bufs[1] = target
      api.nvim_set_current_win(wins[3])
      finish_yazi(path, wins[3], tab, sessions[tab])
      t.assert_eq(api.nvim_get_current_buf(), target)
      t.assert_true(api.nvim_get_current_win() ~= wins[1])
      unchanged(wins, bufs)
    end)
  end)

  t.it("Yazi ordinary completion returns to its origin editor", function()
    isolated(function(_, _, tab)
      local origin = api.nvim_get_current_win()
      local path = file()
      finish_yazi(path, origin, tab)
      t.assert_eq(api.nvim_get_current_win(), origin)
      t.assert_eq(vim.fs.normalize(api.nvim_buf_get_name(0)), vim.fs.normalize(path))
    end)
  end)
end)
