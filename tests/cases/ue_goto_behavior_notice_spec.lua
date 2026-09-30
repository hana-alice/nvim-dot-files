local t = require("tests.harness")
t.bootstrap()

t.describe("progress notice owns its floating window", function()
  t.it("explicit reset leaves unrelated matching-title floating windows intact", function()
    local ui = require("utils.ue_goto.ui")
    local buffer = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { "resolving unrelated plugin" })
    local window = vim.api.nvim_open_win(buffer, false, {
      relative = "editor", row = 1, col = 1, width = 28, height = 1,
      border = "single", title = "LSP definition", focusable = false,
    })
    local handle = ui.progress_notice("resolving owned action")
    local ok, err = xpcall(function()
      ui.close_all_definition_bubbles()
      t.assert_true(vim.api.nvim_win_is_valid(window))
      t.assert_eq(vim.api.nvim_buf_get_lines(buffer, 0, 1, false)[1], "resolving unrelated plugin")
    end, debug.traceback)
    handle.clear()
    if vim.api.nvim_win_is_valid(window) then vim.api.nvim_win_close(window, true) end
    if vim.api.nvim_buf_is_valid(buffer) then vim.api.nvim_buf_delete(buffer, { force = true }) end
    if not ok then error(err) end
  end)

  t.it("late compatibility cleanup cannot detach the newer notice from dispose", function()
    local names = { "utils.ue_goto.provider", "utils.ue_goto.symbol", "utils.ue_goto.cache" }
    local saved = {}
    for _, name in ipairs(names) do saved[name] = package.loaded[name] end
    local old_defer, old_clients = vim.defer_fn, vim.lsp.get_clients
    local starts, replies = {}, {}
    vim.defer_fn = function(callback, delay)
      if delay == 600 then starts[#starts + 1] = callback end
      return { is_closing = function() return false end, stop = function() end, close = function() end }
    end
    vim.lsp.get_clients = function() return { {} } end
    package.loaded["utils.ue_goto.provider"] = {
      async_lsp_definition_with_retry = function(_, _, _, _, cb) replies[#replies + 1] = cb end,
    }
    package.loaded["utils.ue_goto.symbol"] = {
      is_at_definition_at_cursor = function() return false end,
      is_dependent_at_cursor = function() return false end,
      is_in_unresolvable_context_at_cursor = function() return false end,
    }
    package.loaded["utils.ue_goto.cache"] = { get = function() end }
    local compat, newer
    local before = {}
    for _, win in ipairs(vim.api.nvim_list_wins()) do before[win] = true end
    local ok, err = xpcall(function()
      compat = require("utils.ue_goto.compat_navigation").install({
        dtrace = function() end, jump_to_location = function() end, format_jump_msg = function() end,
      })
      compat.definition("older", nil, 0, "/fixture/a.lua", 1, "lua")
      starts[1]()
      compat.definition("newer", nil, 0, "/fixture/a.lua", 1, "lua")
      starts[2]()
      for _, win in ipairs(vim.api.nvim_list_wins()) do if not before[win] then newer = win end end
      t.assert_type(newer, "number")
      replies[1](nil)
      t.assert_true(vim.api.nvim_win_is_valid(newer))
      compat.dispose()
      t.assert_false(vim.api.nvim_win_is_valid(newer), "dispose must retain ownership of the newer notice")
    end, debug.traceback)
    if compat then compat.dispose() end
    if newer and vim.api.nvim_win_is_valid(newer) then vim.api.nvim_win_close(newer, true) end
    for _, name in ipairs(names) do package.loaded[name] = saved[name] end
    vim.defer_fn, vim.lsp.get_clients = old_defer, old_clients
    if not ok then error(err) end
  end)

  for _, action in ipairs({ "clear", "finish", "timeout" }) do
    t.it("old " .. action .. " leaves the newer real floating window intact", function()
      local old_defer, old_notify = vim.defer_fn, vim.notify
      local timers = {}
      vim.defer_fn = function(callback, delay)
        timers[#timers + 1] = { callback = callback, delay = delay }
        return { is_closing = function() return false end, stop = function() end, close = function() end }
      end
      vim.notify = function() end
      local handles, owned = {}, {}
      local function open_notice(text)
        local before = {}
        for _, win in ipairs(vim.api.nvim_list_wins()) do before[win] = true end
        handles[#handles + 1] = require("utils.ue_goto.ui").progress_notice(text)
        for _, win in ipairs(vim.api.nvim_list_wins()) do
          if not before[win] then owned[#owned + 1] = win; return win end
        end
      end
      local ok, err = xpcall(function()
        local first = open_notice("resolving first action")
        local second = open_notice("resolving second action")
        t.assert_type(first, "number", "progress must expose an owned real floating window")
        t.assert_type(second, "number")
        t.assert_true(first ~= second)
        t.assert_eq(timers[1].delay, 8000)
        local second_buf = vim.api.nvim_win_get_buf(second)
        if action == "timeout" then timers[1].callback()
        elseif action == "finish" then handles[1].finish("first completed")
        else handles[1].clear() end
        t.assert_false(vim.api.nvim_win_is_valid(first))
        t.assert_true(vim.api.nvim_win_is_valid(second))
        t.assert_eq(vim.api.nvim_buf_get_lines(second_buf, 0, 1, false)[1], "resolving second action")
        handles[1].clear() -- late repeated cleanup is harmless
        t.assert_true(vim.api.nvim_win_is_valid(second))
      end, debug.traceback)
      for _, handle in ipairs(handles) do handle.clear() end
      for _, win in ipairs(owned) do
        if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
      end
      vim.defer_fn, vim.notify = old_defer, old_notify
      if not ok then error(err) end
    end)
  end
end)
