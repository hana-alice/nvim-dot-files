local t = require("tests.harness")
local cfg = t.bootstrap()

-- Each case owns a fresh manager/registry and an isolated tab. Existing module
-- state, buffers, callbacks and quickfix data must survive even a failed assert.
local function isolated(fn)
  local old_tab = vim.api.nvim_get_current_tabpage()
  local old_eventignore = vim.o.eventignore
  local old_click = _G.UEDapBottomTabClick
  local old_qf = vim.fn.getqflist({ items = 0, title = 0, idx = 0 })
  local modules = { "utils.bottom_panel", "utils.task_registry" }
  local old_modules, old_buffers, jobs, files = {}, {}, {}, {}
  for _, name in ipairs(modules) do
    old_modules[name] = package.loaded[name]
    package.loaded[name] = nil
  end
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do old_buffers[buf] = true end
  vim.o.eventignore = "all"
  vim.cmd("tabnew")
  local tab = vim.api.nvim_get_current_tabpage()
  local ok, err = pcall(function()
    fn(require("utils.bottom_panel"), tab, jobs, files)
  end)
  for _, child in ipairs(jobs) do
    -- Let a real headless child leave naturally after the liveness assertions.
    -- Killing ConPTY children with SIGHUP is unnecessary for normal cleanup.
    vim.fn.writefile({ "stop" }, child.stop)
    local waited, result = pcall(vim.fn.jobwait, { child.id }, 2000)
    if not waited or result[1] ~= 0 then
      pcall(vim.fn.jobstop, child.id)
      pcall(vim.fn.jobwait, { child.id }, 2000)
      ok, err = false, err or "native terminal child failed to exit cleanly"
    end
  end
  for _, file in ipairs(files) do pcall(vim.fn.delete, file) end
  if vim.api.nvim_tabpage_is_valid(tab) then
    vim.api.nvim_set_current_tabpage(tab)
    vim.cmd("tabclose!")
  end
  if vim.api.nvim_tabpage_is_valid(old_tab) then vim.api.nvim_set_current_tabpage(old_tab) end
  vim.fn.setqflist({}, "r", old_qf)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if not old_buffers[buf] then pcall(vim.api.nvim_buf_delete, buf, { force = true }) end
  end
  for _, name in ipairs(modules) do package.loaded[name] = old_modules[name] end
  _G.UEDapBottomTabClick = old_click
  vim.o.eventignore = old_eventignore
  if not ok then error(err, 0) end
end

local function buffer(ft, name)
  local buf = vim.api.nvim_create_buf(false, true)
  if ft then vim.bo[buf].filetype = ft end
  if name then vim.api.nvim_buf_set_name(buf, name) end
  return buf
end

-- Execute the exact private UI closure from the production file. Only dapui's
-- rendering is substituted; bottom_panel and all Neovim window APIs are real.
-- Marker failures are intentional: this fixture must not silently test a stale
-- copy of DAP wiring after the production UI is moved or restructured.
local function dap_ui_fixture(code_win)
  local source = table.concat(vim.fn.readfile(cfg .. "/lua/ue/dap.lua"), "\n")
  local first = assert(source:find("  -- UI ownership is scoped to the session and its starting tab.\n", 1, true), "DAP UI start missing")
  local last = assert(source:find("  local function stop_logcat(", first, true), "DAP UI end missing")
  local factory = assert(loadstring(
      "return function(D, dapui)\n" .. source:sub(first, last - 1)
      .. "\nreturn { close = close_debug_layout, set_logcat = function(buf) logcat_buf = buf end }\nend",
    "@dap-bottom-ui-fixture"
  ))()
  local repl = buffer("dap-repl")
  local opens, closes, renders = 0, 0, 0
  local dapui = {
    open = function(opts)
      t.assert_eq(opts.layout, 1)
      opens = opens + 1
    end,
    close = function(opts)
      t.assert_eq(opts.layout, 1)
      closes = closes + 1
    end,
    elements = { repl = {
      render = function() renders = renders + 1 end,
      buffer = function() return repl end,
    } },
  }
  local D = { dap_focus_main_window = function() return code_win end }
  function D.dap_bottom_tab(name, opts) return D._dap_bottom_tab_impl(name, opts) end
  local fixture = factory(D, dapui)
  fixture.D, fixture.repl = D, repl
  fixture.opens = function() return opens end
  fixture.closes = function() return closes end
  fixture.renders = function() return renders end
  return fixture
end

t.describe("android_ide_panel_lifecycle: native terminal and DAP host ownership", function()
  t.it("在生产式 host 创建真实 terminal，循环和手动关窗都不终止子进程", function()
    isolated(function(panel, tab, jobs, files)
      vim.fn.setqflist({}, "r", { items = {} })
      local host = panel.show("build", nil)
      -- Same ownership order as ensure_build_terminal: create the host first,
      -- switch it to a NEW buffer, termopen in that host, then register content.
      local buf = buffer()
      vim.api.nvim_win_set_buf(host, buf)
      -- ConPTY/headless stdout routing differs across hosts. A child-written
      -- temporary marker proves readiness without relying on terminal rendering.
      local ready = vim.fn.tempname():gsub("\\", "/")
      local stop = ready .. "-stop"
      files[#files + 1] = ready
      files[#files + 1] = stop
      local child_lua = string.format(
        "lua vim.fn.writefile({'ready'}, %q); vim.wait(10000, function() return vim.fn.filereadable(%q) == 1 end, 10)",
        ready, stop
      )
      local job = vim.api.nvim_win_call(host, function()
        return vim.fn.termopen({
          vim.v.progpath, "--headless", "-u", "NONE", "-i", "NONE",
          "-c", child_lua,
          "-c", "qa!",
        })
      end)
      t.assert_true(job > 0, "真实 Neovim terminal child 必须成功启动")
      jobs[#jobs + 1] = { id = job, stop = stop }
      t.assert_true(panel.register("build", buf))
      t.assert_true(vim.wait(2000, function()
        return vim.fn.filereadable(ready) == 1
      end, 10), "child ready marker 必须来自真实进程")
      t.assert_eq(vim.fn.readfile(ready)[1], "ready")
      t.assert_eq(vim.bo[buf].buftype, "terminal")
      for _, kind in ipairs({ "quickfix", "logcat", "tasks", "build" }) do
        t.assert_eq(panel.cycle(), host)
        t.assert_eq(vim.b[vim.api.nvim_win_get_buf(host)].ue_bottom_panel_kind, kind)
        t.assert_eq(#vim.api.nvim_tabpage_list_wins(tab), 2)
        t.assert_eq(vim.fn.jobwait({ job }, 0)[1], -1, kind .. " 切换后 child 仍存活")
      end
      t.assert_eq(vim.api.nvim_win_get_buf(host), buf)
      vim.api.nvim_win_close(host, true)
      t.assert_eq(vim.fn.jobwait({ job }, 0)[1], -1, "关闭显示 terminal 的 host 后 child 仍存活")
      t.assert_true(vim.api.nvim_buf_is_valid(buf))
      local reopened = panel.show("build")
      t.assert_true(reopened ~= host)
      t.assert_eq(vim.api.nvim_win_get_buf(reopened), buf, "重开仍显示原 terminal buffer")
      t.assert_eq(vim.fn.jobwait({ job }, 0)[1], -1)
    end)
  end)

  t.it("生产 DAP logcat 与 build/tasks 共用 host，收尾保留当前 build/tasks", function()
    isolated(function(panel, tab)
      local code = vim.api.nvim_get_current_win()
      local build = buffer()
      local host = panel.show("build", build, { focus = false })
      local dap = dap_ui_fixture(code)
      local logcat = buffer("log", "ue-dap-fixture-logcat:1")
      dap.set_logcat(logcat)
      for _, kind in ipairs({ "build", "tasks" }) do
        dap.D.dap_bottom_tab("logcat")
        t.assert_eq(panel.window(), host)
        t.assert_eq(dap.D._dap_bottom_tab_win, host)
        t.assert_eq(vim.api.nvim_win_get_buf(host), logcat)
        t.assert_eq(vim.api.nvim_get_current_win(), code, "DAP 不偷代码焦点")
        t.assert_eq(panel.show(kind, nil, { focus = false }), host)
        local visible = vim.api.nvim_win_get_buf(host)
        dap.close()
        t.assert_true(vim.api.nvim_win_is_valid(host), "DAP 收尾必须保留 " .. kind)
        t.assert_eq(vim.api.nvim_win_get_buf(host), visible)
        t.assert_nil(dap.D._dap_bottom_tab_win)
        t.assert_eq(#vim.api.nvim_tabpage_list_wins(tab), 2)
      end
      t.assert_eq(dap.closes(), 0, "cleanup closes only owned IDs; broad dapui.close is not used")
      t.assert_eq(panel.show("build"), host)
      t.assert_eq(vim.api.nvim_win_get_buf(host), build)
    end)
  end)

  t.it("生产 DAP 收尾正确关闭自己可见的 debug/logcat，保留 buffer 可再打开", function()
    isolated(function(panel, tab)
      local code = vim.api.nvim_get_current_win()
      local dap = dap_ui_fixture(code)
      local logcat = buffer("log", "ue-dap-fixture-logcat:2")
      dap.set_logcat(logcat)
      for _, name in ipairs({ "repl", "logcat" }) do
        dap.D.dap_bottom_tab(name)
        local host = panel.window()
        t.assert_true(vim.api.nvim_win_is_valid(host))
        local buf = name == "repl" and dap.repl or logcat
        t.assert_eq(vim.api.nvim_win_get_buf(host), buf)
        t.assert_eq(#vim.api.nvim_tabpage_list_wins(tab), 2)
        dap.close()
        t.assert_false(vim.api.nvim_win_is_valid(host))
        t.assert_true(vim.api.nvim_buf_is_valid(buf))
        t.assert_eq(#vim.api.nvim_tabpage_list_wins(tab), 1)
        t.assert_eq(vim.api.nvim_get_current_win(), code)
      end
      t.assert_eq(dap.closes(), 0)
      t.assert_eq(dap.renders(), 1)
      dap.D.dap_bottom_tab("repl")
      t.assert_eq(vim.api.nvim_win_get_buf(panel.window()), dap.repl)
    end)
  end)

  t.it("生产 DAP toggle 从 build/tasks/quickfix 借用 host，再按恢复原内容", function()
    isolated(function(panel, tab)
      local code = vim.api.nvim_get_current_win()
      local dap = dap_ui_fixture(code)
      local source = buffer()
      vim.fn.setqflist({}, "r", { items = { { bufnr = source, lnum = 1, text = "test error", type = "E" } } })
      for index, kind in ipairs({ "build", "tasks", "quickfix" }) do
        local host = panel.show(kind, nil, { focus = false })
        local borrowed = vim.api.nvim_win_get_buf(host)
        t.assert_eq(#vim.api.nvim_tabpage_list_wins(tab), 2)
        dap.D._dap_toggle_debug_layout()
        t.assert_eq(dap.opens(), index, kind .. " host 存在时应打开左侧调试布局")
        t.assert_eq(dap.closes(), 0, "首次 toggle 不得误调用 broad close")
        t.assert_eq(panel.window(), host, "首次 toggle 应复用 " .. kind .. " host")
        t.assert_eq(vim.api.nvim_win_get_buf(host), dap.repl)
        t.assert_eq(#vim.api.nvim_tabpage_list_wins(tab), 2, "调试内容不得叠底部窗口")
        t.assert_eq(vim.api.nvim_get_current_win(), code)
        dap.D._dap_toggle_debug_layout()
        t.assert_eq(dap.opens(), index)
        t.assert_eq(dap.closes(), 0)
        t.assert_true(vim.api.nvim_win_is_valid(host), "借用的 host 必须保留")
        t.assert_eq(vim.api.nvim_win_get_buf(host), borrowed)
        t.assert_nil(dap.D._dap_bottom_tab_win)
        t.assert_eq(#vim.api.nvim_tabpage_list_wins(tab), 2)
      end
    end)
  end)
end)
