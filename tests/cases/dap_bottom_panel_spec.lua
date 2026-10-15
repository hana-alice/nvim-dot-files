local t = require("tests.harness")
t.bootstrap()
local api = vim.api

-- These checks exercise real windows, native :copen, and option enforcement.
local function isolated(fn)
  local previous = api.nvim_get_current_tabpage()
  vim.cmd("tabnew")
  local tab = api.nvim_get_current_tabpage()
  local saved = package.loaded["utils.bottom_panel"]
  package.loaded["utils.bottom_panel"] = nil
  local group = api.nvim_create_augroup("DapBottomPanelSpec", { clear = true })
  local ok, err = xpcall(function() fn(require("utils.bottom_panel"), group) end, debug.traceback)
  api.nvim_del_augroup_by_id(group)
  if api.nvim_tabpage_is_valid(tab) then
    api.nvim_set_current_tabpage(tab)
    vim.cmd("tabclose!")
  end
  if api.nvim_tabpage_is_valid(previous) then api.nvim_set_current_tabpage(previous) end
  package.loaded["utils.bottom_panel"] = saved
  if not ok then error(err, 0) end
end

local function content(text)
  local buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_lines(buf, 0, -1, false, { text })
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].modified = false
  return buf
end

t.describe("dap bottom panel bounded pin handoff", function()
  t.it("pinned debug/logcat/native quickfix cycle keeps one host and code untouched", function()
    isolated(function(bottom)
      local source, source_buf = api.nvim_get_current_win(), api.nvim_get_current_buf()
      local debug_buf, logcat = content("DAP console"), content("retained Logcat")
      vim.fn.setqflist({}, " ", { items = { { bufnr = source_buf, lnum = 1, text = "issue" } } })
      local host = bottom.show("quickfix", nil, { focus = false })
      local qf = api.nvim_win_get_buf(host)
      vim.wo[host].winfixbuf = true
      local count = #api.nvim_tabpage_list_wins(0)
      for _ = 1, 3 do
        for _, row in ipairs({ { "debug", debug_buf }, { "logcat", logcat }, { "quickfix", qf } }) do
          t.assert_eq(bottom.show(row[1], row[2], { focus = false }), host)
          t.assert_eq(api.nvim_win_get_buf(host), row[2])
          t.assert_true(vim.wo[host].winfixbuf)
          t.assert_eq(#api.nvim_tabpage_list_wins(0), count)
          t.assert_eq(api.nvim_get_current_win(), source)
          t.assert_eq(api.nvim_win_get_buf(source), source_buf)
        end
      end
    end)
  end)

  t.it("cold native copen temporarily releases a pinned retained quickfix host", function()
    isolated(function(bottom, group)
      local source = api.nvim_get_current_win()
      vim.fn.setqflist({}, " ", { items = { { lnum = 1, text = "issue" } } })
      local host = bottom.show("quickfix", nil, { focus = false })
      bottom.show("debug", content("DAP console"), { focus = false })
      vim.wo[host].winfixbuf = true
      -- Unloading preserves the native quickfix identity but forces :copen.
      local qf = vim.fn.getqflist({ qfbufnr = 0 }).qfbufnr
      api.nvim_buf_delete(qf, { unload = true })
      local observed
      api.nvim_create_autocmd("BufWinEnter", {
        group = group, pattern = "*", callback = function()
          if vim.bo.buftype == "quickfix" then observed = vim.wo[host].winfixbuf end
        end,
      })
      local count = #api.nvim_tabpage_list_wins(0)
      t.assert_eq(bottom.show("quickfix", nil, { focus = false }), host)
      t.assert_eq(observed, false, "native copen runs within the host pin handoff")
      t.assert_true(vim.wo[host].winfixbuf)
      t.assert_eq(#api.nvim_tabpage_list_wins(0), count)
      t.assert_eq(api.nvim_get_current_win(), source)
      t.assert_eq(vim.bo[api.nvim_win_get_buf(host)].buftype, "quickfix")
    end)
  end)

  t.it("remove replaces debug with its placeholder while keeping the host pinned", function()
    isolated(function(bottom)
      local buf = content("DAP console")
      local host = bottom.show("debug", buf)
      vim.wo[host].winfixbuf = true
      t.assert_true(bottom.remove("debug", buf))
      t.assert_true(api.nvim_win_get_buf(host) ~= buf)
      t.assert_eq(vim.b[api.nvim_win_get_buf(host)].ue_bottom_panel_kind, "debug")
      t.assert_true(vim.wo[host].winfixbuf)
    end)
  end)

  t.it("buffer enter error restores the original pin and reports the real failure", function()
    isolated(function(bottom, group)
      local host = bottom.show("debug", content("DAP console"))
      vim.wo[host].winfixbuf = true
      local buf = content("next logcat")
      local entered
      api.nvim_create_autocmd("BufWinEnter", {
        group = group, buffer = buf, once = true, callback = function()
          entered = true
          error("bottom handoff failure")
        end,
      })
      local ok, err = pcall(bottom.show, "logcat", buf)
      t.assert_false(ok)
      t.assert_true(entered, "replacement must reach the injected native event")
      t.assert_contains(tostring(err), "bottom handoff failure")
      t.assert_true(vim.wo[host].winfixbuf)
    end)
  end)

  t.it("native copen error also restores the host pin", function()
    isolated(function(bottom, group)
      vim.fn.setqflist({}, " ", { items = { { lnum = 1, text = "issue" } } })
      local host = bottom.show("quickfix")
      bottom.show("debug", content("DAP console"))
      vim.wo[host].winfixbuf = true
      api.nvim_buf_delete(vim.fn.getqflist({ qfbufnr = 0 }).qfbufnr, { unload = true })
      local entered, released
      api.nvim_create_autocmd("BufWinEnter", {
        group = group, pattern = "*", callback = function()
          if vim.bo.buftype == "quickfix" then
            entered = true
            released = not vim.wo[host].winfixbuf
            error("native copen handoff failure")
          end
        end,
      })
      local ok, err = pcall(bottom.show, "quickfix")
      t.assert_false(ok)
      t.assert_true(entered)
      t.assert_true(released)
      t.assert_contains(tostring(err), "native copen handoff failure")
      t.assert_true(vim.wo[host].winfixbuf)
    end)
  end)

  t.it("UEPanel and UEPanelNext switch the pinned host through the same bounded handoff", function()
    isolated(function(bottom)
      local debug_buf, logcat = content("DAP console"), content("retained Logcat")
      local host = bottom.show("debug", debug_buf)
      bottom.register("logcat", logcat)
      vim.wo[host].winfixbuf = true
      bottom.setup_commands()
      vim.cmd("UEPanel logcat")
      t.assert_eq(api.nvim_win_get_buf(host), logcat)
      vim.cmd("UEPanelNext")
      t.assert_eq(vim.b[api.nvim_win_get_buf(host)].ue_bottom_panel_kind, "tasks")
      bottom.show("debug", debug_buf)
      bottom.cycle()
      t.assert_eq(vim.b[api.nvim_win_get_buf(host)].ue_bottom_panel_kind, "build")
      t.assert_true(vim.wo[host].winfixbuf)
      t.assert_eq(bottom.window(), host)
      t.assert_eq(#api.nvim_tabpage_list_wins(0), 2)
    end)
  end)

  t.it("an unpinned host stays unpinned and unrelated code pins are untouched", function()
    isolated(function(bottom)
      local source = api.nvim_get_current_win()
      local host = bottom.show("debug", content("DAP console"), { focus = false })
      vim.wo[host].winfixbuf = false
      vim.wo[source].winfixbuf = true
      bottom.show("logcat", content("retained Logcat"), { focus = false })
      t.assert_false(vim.wo[host].winfixbuf)
      t.assert_true(vim.wo[source].winfixbuf)
      vim.wo[source].winfixbuf = false
    end)
  end)
end)
