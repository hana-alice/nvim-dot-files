local t = require("tests.harness")
t.bootstrap()

local api = vim.api
local module_names = { "codediff.core.virtual_file", "codediff.ui.lifecycle", "utils.review_goto", "utils.layout" }

local function isolated(fn)
  local saved, preloaded = {}, {}
  for _, name in ipairs(module_names) do
    saved[name], preloaded[name] = package.loaded[name], package.preload[name]
  end
  local notify, get_clients, lsp_config, lsp_start, detach = vim.notify, vim.lsp.get_clients, vim.lsp.config, vim.lsp.start,
    vim.lsp.buf_detach_client
  local original_tab = api.nvim_get_current_tabpage()
  local existing_tabs = {}
  for _, tab in ipairs(api.nvim_list_tabpages()) do existing_tabs[tab] = true end
  local existing_buffers = {}
  for _, buf in ipairs(api.nvim_list_bufs()) do existing_buffers[buf] = true end
  vim.cmd("tabnew")
  local test_tab = api.nvim_get_current_tabpage()
  local cancel
  local ok, err = xpcall(function()
    package.loaded["utils.review_goto"] = nil
    package.loaded["utils.layout"] = nil
    fn(require("utils.review_goto"), function(value) cancel = value end)
  end, debug.traceback)
  if cancel then cancel() end
  for _, buf in ipairs(api.nvim_list_bufs()) do
    if not existing_buffers[buf] then vim.bo[buf].modified = false end
  end
  vim.notify, vim.lsp.get_clients = notify, get_clients
  vim.lsp.config, vim.lsp.start = lsp_config, lsp_start
  vim.lsp.buf_detach_client = detach
  for _, name in ipairs(module_names) do
    package.loaded[name], package.preload[name] = saved[name], preloaded[name]
  end
  for _, tab in ipairs(api.nvim_list_tabpages()) do
    if not existing_tabs[tab] then api.nvim_set_current_tabpage(tab); vim.cmd("tabclose!") end
  end
  if api.nvim_tabpage_is_valid(original_tab) then api.nvim_set_current_tabpage(original_tab) end
  if not ok then error(err, 0) end
end

local function parser(root, path)
  package.loaded["codediff.core.virtual_file"] = {
    parse_url = function(name)
      if name:match("^codediff:///") then return root, "a1b2c3", path end
    end,
  }
end

local function window(lines, opts)
  opts = opts or {}
  local buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_lines(buf, 0, -1, false, lines or { "code" })
  vim.bo[buf].buftype = opts.buftype or ""
  vim.bo[buf].filetype = opts.filetype or "cpp"
  if opts.name then api.nvim_buf_set_name(buf, opts.name) end
  vim.bo[buf].modified = false
  if opts.split then vim.cmd("vsplit") end
  local win = api.nvim_get_current_win()
  api.nvim_win_set_buf(win, buf)
  return win, buf
end

local function lifecycle(original, modified, panel)
  local tab = api.nvim_get_current_tabpage()
  local session = { original_win = original, modified_win = modified,
    panel = panel and { view = { winid = panel } } or nil }
  package.loaded["codediff.ui.lifecycle"] = {
    get_windows = function() return original, modified end,
    get_session = function(candidate) if candidate == tab then return session end end,
  }
end

local function assert_cursor(cursor, line, col)
  t.assert_eq(cursor[1], line, "mapped line")
  t.assert_eq(cursor[2], col, "mapped byte column")
end

t.describe("review_goto URL", function()
  t.it("真实文件不加载虚拟 parser", function()
    isolated(function(m)
      package.loaded["codediff.core.virtual_file"] = nil
      package.preload["codediff.core.virtual_file"] = function() error("must not load") end
      t.assert_nil(m.parse_url("C:/project/Source/Main.cpp"))
      t.assert_nil(m.parse_url(nil))
    end)
  end)

  t.it("插件未加载或 require 失败不抛异常", function()
    isolated(function(m)
      package.loaded["codediff.core.virtual_file"] = nil
      package.preload["codediff.core.virtual_file"] = function() error("plugin unavailable") end
      t.assert_nil(m.parse_url("codediff:///C:/repo///a1b2/Main.cpp"))
    end)
  end)

  t.it("parser 抛异常或返回不完整值时安全拒绝", function()
    isolated(function(m)
      package.loaded["codediff.core.virtual_file"] = { parse_url = function() error("bad URL") end }
      t.assert_nil(m.parse_url("codediff:///C:/repo///a1b2/Main.cpp"))
      package.loaded["codediff.core.virtual_file"] = { parse_url = function() return "C:/repo", "HEAD" end }
      t.assert_nil(m.parse_url("codediff:///C:/repo///HEAD/Main.cpp"))
    end)
  end)

  t.it("URL 三返回值转为工作区文件路径", function()
    isolated(function(m)
      parser("C:/repo with spaces", "Source/Main.cpp")
      local parsed = m.parse_url("codediff:///C:/repo with spaces///a1b2c3/Source/Main.cpp")
      t.assert_eq(parsed.git_root, "C:/repo with spaces")
      t.assert_eq(parsed.commit, "a1b2c3")
      t.assert_eq(parsed.filepath, "Source/Main.cpp")
      t.assert_eq(parsed.path, vim.fs.joinpath("C:/repo with spaces", "Source/Main.cpp"))
    end)
  end)

  local installed = vim.fs.joinpath(vim.fn.stdpath("data"), "lazy", "codediff.nvim", "lua", "codediff", "core", "virtual_file.lua")
  if vim.uv.fs_stat(installed) then
    t.it("安装的 CodeDiff parser 支持 SHA、HEAD 和暂存区 URL", function()
      isolated(function(m)
        package.loaded["codediff.core.virtual_file"] = assert(loadfile(installed))()
        for _, commit in ipairs({ "a1b2c3", "HEAD", ":0", "a1b2c3^" }) do
          local parsed = m.parse_url("codediff:///D:/project/Engine///" .. commit .. "/Source/Main.cpp")
          t.assert_eq(parsed.git_root, "D:/project/Engine")
          t.assert_eq(parsed.commit, commit)
          t.assert_eq(parsed.filepath, "Source/Main.cpp")
        end
        t.assert_nil(m.parse_url("codediff:///malformed"))
      end)
    end)
  else
    t.skip("安装的 CodeDiff parser 支持 SHA、HEAD 和暂存区 URL", "installed plugin unavailable; mocked parser coverage remains")
  end
end)

t.describe("review_goto 真实 vim.diff 行列映射", function()
  t.it("相同内容保留行号并钳制文件边界", function()
    isolated(function(m)
      t.assert_eq(m.map_line({ "a", "b" }, { "a", "b" }, 2), 2)
      t.assert_eq(m.map_line({ "a", "b" }, { "a", "b" }, 99), 2)
      t.assert_eq(m.map_line({ "a" }, {}, 1), 1)
    end)
  end)

  t.it("文件首部、中间和尾部新增只偏移其后修订行", function()
    isolated(function(m)
      local revision = { "a", "b", "c" }
      t.assert_eq(m.map_line(revision, { "new", "a", "b", "c" }, 1), 2)
      t.assert_eq(m.map_line(revision, { "a", "new", "b", "c" }, 1), 1)
      t.assert_eq(m.map_line(revision, { "a", "new", "b", "c" }, 2), 3)
      t.assert_eq(m.map_line(revision, { "a", "b", "c", "new" }, 3), 3)
    end)
  end)

  t.it("删除块选最近存活前后行，块后行抵消删除偏移", function()
    isolated(function(m)
      local revision, worktree = { "before", "gone1", "gone2", "gone3", "after" }, { "before", "after" }
      t.assert_eq(m.map_line(revision, worktree, 2), 1)
      t.assert_eq(m.map_line(revision, worktree, 4), 2)
      t.assert_eq(m.map_line(revision, worktree, 5), 2)
      local tie = m.map_line(revision, worktree, 3)
      t.assert_true(tie == 1 or tie == 2, "equidistant deletion may choose either adjacent survivor")
      t.assert_eq(m.map_line({ "gone", "after" }, { "after" }, 1), 1)
      t.assert_eq(m.map_line({ "before", "gone" }, { "before" }, 2), 1)
    end)
  end)

  t.it("修改块按块内相对行映射并钳制较短替换", function()
    isolated(function(m)
      t.assert_eq(m.map_line({ "before", "old1", "old2", "after" }, { "before", "new1", "new2", "after" }, 3), 3)
      t.assert_eq(m.map_line({ "before", "old1", "old2", "after" }, { "before", "new", "after" }, 3), 2)
      t.assert_eq(m.map_line({ "before", "old1", "old2", "after" }, { "before", "new", "after" }, 4), 3)
    end)
  end)

  t.it("多个独立 hunk 累计偏移不混淆插入和删除", function()
    isolated(function(m)
      local revision = { "A", "B", "C", "D", "E", "F", "G", "H", "I" }
      local worktree = { "head", "A", "B", "C", "E", "F", "middle", "G", "H", "I" }
      t.assert_true(#vim.diff(table.concat(revision, "\n"), table.concat(worktree, "\n"), { result_type = "indices" }) >= 3)
      for old, new in pairs({ [1] = 2, [3] = 4, [5] = 5, [6] = 6, [7] = 8, [9] = 10 }) do
        t.assert_eq(m.map_line(revision, worktree, old), new, "multi-hunk original line " .. old)
      end
    end)
  end)

  t.it("相同行保持 byte 列，修改行保留符号内偏移", function()
    isolated(function(m)
      assert_cursor(m.map_cursor({ "Foo();" }, { "new", "Foo();" }, { 1, 2 }, "Foo"), 2, 2)
      assert_cursor(m.map_cursor({ "  Foo();" }, { "      Foo();" }, { 1, 3 }, "Foo"), 1, 7)
      assert_cursor(m.map_cursor({ "  Foo();" }, { "你 Foo();" }, { 1, 3 }, "Foo"), 1, 5)
    end)
  end)

  t.it("重复符号选择最近对应列，缺失符号时钳制列", function()
    isolated(function(m)
      assert_cursor(m.map_cursor({ "Foo + Foo" }, { "xx Foo + xx Foo" }, { 1, 7 }, "Foo"), 1, 4)
      assert_cursor(m.map_cursor({ "long_symbol();" }, { "x" }, { 1, 8 }, "long_symbol"), 1, 0)
      assert_cursor(m.map_cursor({ "old" }, { "" }, { 1, 2 }, "old"), 1, 0)
    end)
  end)

  t.it("整词列映射跳过 FooBar/xFoo/Foo_ 并保留符号内偏移", function()
    isolated(function(m)
      assert_cursor(m.map_cursor({ "  Foo();" }, { "FooBar + xx Foo();" }, { 1, 3 }, "Foo"), 1, 13)
      assert_cursor(m.map_cursor({ "  Foo();" }, { "FooBar xFoo Foo_ Foo();" }, { 1, 3 }, "Foo"), 1, 18)
      assert_cursor(m.map_cursor({ "FooBar + xx Foo();" }, { "FooBar + Foo + xx Foo();" }, { 1, 13 }, "Foo"), 1, 10)
    end)
  end)
end)

t.describe("review_goto definition 与异步 clangd", function()
  t.it("resolved root and start return recheck readiness without running the fallback timer", function()
    isolated(function(m, keep_cancel)
      local win, buf = window({ "Foo();" })
      local old_defer = vim.defer_fn
      local release, calls, started, timers = nil, 0, 0, 0
      local ready = { name = "clangd", id = 7, initialized = true,
        config = { root_dir = "C:/fixture" }, is_stopped = function() return false end }
      vim.lsp.config = { clangd = { name = "clangd", root_dir = function(_, callback) release = callback end } }
      vim.lsp.get_clients = function() return { ready } end
      vim.lsp.start = function() started = started + 1; return 7 end
      vim.defer_fn = function()
        timers = timers + 1
        local closed = false
        return { stop = function() end, close = function() closed = true end, is_closing = function() return closed end }
      end
      local ok, err = xpcall(function()
        keep_cancel(m.wait_for_clangd(buf, win, { 1, 0 }, function() calls = calls + 1 end, 1000))
        t.assert_eq(calls, 0)
        release("C:/fixture")
        t.assert_true(vim.wait(300, function() return calls == 1 end, 1), "root completion itself checks ready client")
        t.assert_eq(started, 1)
        t.assert_eq(calls, 1)
        t.assert_true(timers <= 1, "root completion must not await a second fallback timer")
      end, debug.traceback)
      vim.defer_fn = old_defer
      if not ok then error(err, 0) end
    end)
  end)

  t.it("matching LspAttach checks immediately and removes its listener after completion", function()
    isolated(function(m, keep_cancel)
      local win, buf = window({ "Foo();" })
      local old_get = vim.lsp.get_client_by_id
      local calls = 0
      local ready = { name = "clangd", id = 7, initialized = false,
        config = { root_dir = "C:/fixture" }, is_stopped = function() return false end }
      local wrong = { name = "clangd", id = 8, initialized = true,
        config = { root_dir = "C:/other" }, is_stopped = function() return false end }
      vim.lsp.config = { clangd = { name = "clangd", root_dir = "C:/fixture" } }
      vim.lsp.start = function() return 7 end
      vim.lsp.get_clients = function() return { ready } end
      vim.lsp.get_client_by_id = function(id) return id == 7 and ready or wrong end
      local before = #api.nvim_get_autocmds({ event = "LspAttach", buffer = buf })
      local ok, err = xpcall(function()
        keep_cancel(m.wait_for_clangd(buf, win, { 1, 0 }, function() calls = calls + 1 end, 1000))
        api.nvim_exec_autocmds("LspAttach", { buffer = buf, data = { client_id = 8 } })
        t.assert_eq(calls, 0)
        ready.initialized = true
        api.nvim_exec_autocmds("LspAttach", { buffer = buf, data = { client_id = 7 } })
        t.assert_eq(calls, 1, "matching attach must not wait 50 ms")
        t.assert_eq(#api.nvim_get_autocmds({ event = "LspAttach", buffer = buf }), before)
        api.nvim_exec_autocmds("LspAttach", { buffer = buf, data = { client_id = 7 } })
        t.assert_eq(calls, 1)
      end, debug.traceback)
      vim.lsp.get_client_by_id = old_get
      if not ok then error(err, 0) end
    end)
  end)

  for _, event in ipairs({ "BufEnter", "FileType" }) do
    t.it(event .. " replacement keeps the callback's new buffer and cursor before semantic continuation", function()
      isolated(function(m)
        local root = vim.fs.joinpath(vim.env.NVIM_TEST_RUN_ROOT or vim.fn.tempname(), "review-handoff-" .. event)
        vim.fn.mkdir(root, "p")
        local filename = event == "FileType" and "Main.cpp" or "Main.usf"
        local path = root .. "/" .. filename
        vim.fn.writefile({ "float target();", "void call() { target(); }" }, path)
        parser(root, filename)
        local source, revision = window({ "float target();", "void call() { target(); }" },
          { buftype = "nowrite", filetype = "", name = "codediff:///" .. root .. "///a1b2c3/" .. filename })
        local modified = window(nil, { split = true })
        lifecycle(source, modified)
        if event == "FileType" then
          local target = vim.fn.bufadd(path)
          vim.fn.bufload(target)
          vim.bo[target].filetype = ""
        end
        local replacement = api.nvim_create_buf(true, false)
        api.nvim_buf_set_lines(replacement, 0, -1, false, { "one", "two", "three", "four" })
        local chosen, calls, entered = { 4, 3 }, 0, 0
        local destination
        local id = api.nvim_create_autocmd(event, { callback = function(ev)
          if entered == 0 and api.nvim_get_current_tabpage() ~= api.nvim_win_get_tabpage(source)
              and vim.fs.normalize(api.nvim_buf_get_name(ev.buf)) == vim.fs.normalize(path) then
            entered = entered + 1
            destination = api.nvim_get_current_win()
            api.nvim_win_set_buf(destination, replacement)
            api.nvim_win_set_cursor(destination, chosen)
          end
        end })
        api.nvim_set_current_win(source)
        api.nvim_win_set_cursor(source, { 2, 14 })
        t.assert_true(m.definition(function() calls = calls + 1 end))
        api.nvim_del_autocmd(id)
        t.assert_eq(entered, 1)
        t.assert_eq(calls, 0)
        t.assert_eq(api.nvim_get_current_win(), destination)
        t.assert_eq(api.nvim_win_get_buf(destination), replacement)
        t.assert_true(vim.deep_equal(api.nvim_win_get_cursor(destination), chosen))
        t.assert_eq(api.nvim_win_get_buf(source), revision)
        t.assert_true(vim.deep_equal(api.nvim_win_get_cursor(source), { 2, 14 }))
      end)
    end)
  end

  t.it("普通文件交回正常 definition，缺失工作区文件仅通知", function()
    isolated(function(m)
      local _, buf = window()
      local calls, messages = 0, {}
      vim.notify = function(message) messages[#messages + 1] = message end
      t.assert_false(m.definition(function() calls = calls + 1 end))
      local root = vim.fs.joinpath(vim.env.NVIM_TEST_RUN_ROOT or vim.fn.tempname(), "missing-review")
      parser(root, "absent.cpp")
      api.nvim_buf_set_name(buf, "codediff:///" .. root .. "///a1b2c3/absent.cpp")
      vim.bo[buf].buftype = "nowrite"
      t.assert_true(m.definition(function() calls = calls + 1 end))
      t.assert_eq(calls, 0)
      t.assert_eq(#messages, 1)
      t.assert_contains(messages[1], "工作区文件不存在")
      t.assert_contains(messages[1], "absent.cpp")
    end)
  end)

  t.it("真实文件切到 normal tab 并等待 initialized clangd 后只调用一次，审阅原样保留", function()
    isolated(function(m)
      local root = vim.fs.joinpath(vim.env.NVIM_TEST_RUN_ROOT or vim.fn.tempname(), "review-goto-flow")
      vim.fn.mkdir(root, "p")
      local path = vim.fs.joinpath(root, "Main.cpp")
      vim.fn.writefile({ "// added", "void Foo();", "void Run() { Foo(); }" }, path)
      parser(root, "Main.cpp")
      local original, revision_buf = window({ "void Foo();", "void Run() { Foo(); }" },
        { buftype = "nowrite", name = "codediff:///" .. root .. "///a1b2c3/Main.cpp", filetype = "" })
      local modified, modified_buf = window({ "second revision" }, { split = true })
      vim.bo[revision_buf].bufhidden = "wipe"
      vim.bo[modified_buf].bufhidden = "wipe"
      lifecycle(original, modified)
      api.nvim_set_current_win(original)
      api.nvim_win_set_cursor(original, { 2, 14 })
      local ready, calls, callback_buf, callback_cursor = false, 0
      vim.lsp.get_clients = function()
        return { { name = "clangd", initialized = ready }, { name = "other", initialized = true } }
      end
      local before = #api.nvim_tabpage_list_wins(0)
      local source_tab = api.nvim_get_current_tabpage()
      local started = vim.uv.hrtime()
      t.assert_true(m.definition(function()
        calls = calls + 1
        callback_buf, callback_cursor = api.nvim_get_current_buf(), api.nvim_win_get_cursor(0)
      end, { timeout_ms = 1000 }))
      t.assert_true((vim.uv.hrtime() - started) / 1000000 < 150, "definition must return without waiting for clangd")
      t.assert_eq(calls, 0)
      t.assert_eq(#api.nvim_tabpage_list_wins(source_tab), before)
      t.assert_true(api.nvim_get_current_tabpage() ~= source_tab)
      t.assert_eq(require("utils.layout").current_group().kind, "normal")
      t.assert_eq(api.nvim_win_get_buf(original), revision_buf)
      t.assert_eq(api.nvim_win_get_buf(modified), modified_buf)
      t.assert_true(api.nvim_get_current_win() ~= modified)
      t.assert_eq(vim.bo.filetype, "cpp")
      t.assert_true(vim.wait(100, function() return false end, 10) == false)
      t.assert_eq(calls, 0, "uninitialized clangd must not invoke normal definition")
      ready = true
      t.assert_true(vim.wait(500, function() return calls == 1 end, 10))
      t.assert_eq(vim.fs.normalize(api.nvim_buf_get_name(callback_buf)), vim.fs.normalize(path))
      assert_cursor(callback_cursor, 3, 14)
      vim.wait(100, function() return false end, 10)
      t.assert_eq(calls, 1)
    end)
  end)

  t.it("shader 审阅沿用正常 definition，不等待 clangd", function()
    isolated(function(m)
      local root = vim.fs.joinpath(vim.env.NVIM_TEST_RUN_ROOT or vim.fn.tempname(), "review-goto-shader")
      vim.fn.mkdir(root, "p")
      vim.fn.writefile({ "float Foo();" }, vim.fs.joinpath(root, "Main.usf"))
      parser(root, "Main.usf")
      local win = window({ "float Foo();" },
        { buftype = "nowrite", name = "codediff:///" .. root .. "///a1b2c3/Main.usf", filetype = "" })
      lifecycle(nil, nil)
      vim.w[win].snacks_main = true
      local calls, client_queries = 0, 0
      vim.lsp.get_clients = function() client_queries = client_queries + 1; return {} end
      t.assert_true(m.definition(function() calls = calls + 1 end, { timeout_ms = 20 }))
      t.assert_true(vim.wait(300, function() return calls == 1 end, 10))
      t.assert_eq(client_queries, 0)
      t.assert_eq(calls, 1)
    end)
  end)

  t.it("超时通知一次，不调用 definition", function()
    isolated(function(m, keep_cancel)
      local win, buf = window({ "Foo();" })
      local messages, calls = {}, 0
      vim.notify = function(message) messages[#messages + 1] = message end
      vim.lsp.get_clients = function() return {} end
      keep_cancel(m.wait_for_clangd(buf, win, { 1, 0 }, function() calls = calls + 1 end, 20))
      t.assert_true(vim.wait(300, function() return #messages > 0 end, 10))
      t.assert_contains(messages[1], "超时")
      t.assert_contains(messages[1], "ms")
      t.assert_contains(messages[1], "client 状态")
      vim.wait(100, function() return false end, 10)
      t.assert_eq(calls, 0)
      t.assert_eq(#messages, 1)
    end)
  end)

  t.it("等待期间用户移动光标使旧请求失效", function()
    isolated(function(m, keep_cancel)
      local win, buf = window({ "Foo();" })
      local ready, calls, messages = false, 0, 0
      vim.notify = function() messages = messages + 1 end
      vim.lsp.get_clients = function() return { { name = "clangd", initialized = ready } } end
      keep_cancel(m.wait_for_clangd(buf, win, { 1, 0 }, function() calls = calls + 1 end, 100))
      vim.wait(20, function() return false end, 5)
      api.nvim_win_set_cursor(win, { 1, 1 })
      ready = true
      vim.wait(150, function() return false end, 10)
      t.assert_eq(calls, 0)
      t.assert_eq(messages, 0, "stale cancellation is not a timeout")
    end)
  end)

  t.it("initialized 但已退出的 clangd 不能触发 semantic 回调", function()
    isolated(function(m, keep_cancel)
      local win, buf = window({ "Foo();" })
      local calls, messages = 0, {}
      vim.lsp.config = {}
      vim.notify = function(message) messages[#messages + 1] = message end
      vim.lsp.get_clients = function()
        return { { name = "clangd", id = 91, initialized = true,
          config = { root_dir = "C:/old-root" }, attached_buffers = { [buf] = true },
          is_stopped = function() return true end } }
      end
      keep_cancel(m.wait_for_clangd(buf, win, { 1, 0 }, function() calls = calls + 1 end, 20))
      t.assert_true(vim.wait(300, function() return #messages == 1 end, 10))
      t.assert_eq(calls, 0)
      t.assert_contains(messages[1], "id=91")
      t.assert_contains(messages[1], "stopped=true")
    end)
  end)

  t.it("异步 root_dir 未完成前不能借错 root client 派发，过期来源不会启动进程", function()
    isolated(function(m, keep_cancel)
      local win, buf = window({ "Foo();" })
      local resolve_root, calls, starts = nil, 0, 0
      vim.lsp.config = { clangd = { name = "clangd", root_dir = function(_, cb) resolve_root = cb end } }
      vim.lsp.start = function() starts = starts + 1 end
      vim.lsp.get_clients = function() return { { name = "clangd", initialized = true } } end
      keep_cancel(m.wait_for_clangd(buf, win, { 1, 0 }, function() calls = calls + 1 end, 500))
      vim.wait(50, function() return false end, 10)
      t.assert_eq(calls, 0)
      api.nvim_win_set_cursor(win, { 1, 1 })
      resolve_root("C:/correct-root")
      vim.wait(80, function() return false end, 10)
      t.assert_eq(starts, 0)
      t.assert_eq(calls, 0)
    end)
  end)

  t.it("等待期间 wrong-root 重新附加仍须移除，不能借其 initialized 派发 semantic", function()
    isolated(function(m, keep_cancel)
      local win, buf = window({ "Foo();" })
      local calls, detached, wrong_attached, correct_ready = 0, 0, false, false
      vim.lsp.config = { clangd = { name = "clangd", root_dir = "C:/correct-root" } }
      vim.lsp.start = function() return 99 end
      vim.lsp.buf_detach_client = function(target, id)
        t.assert_eq(target, buf)
        t.assert_eq(id, 91)
        detached, wrong_attached = detached + 1, false
      end
      vim.lsp.get_clients = function()
        local clients = { { name = "clangd", id = 99, initialized = correct_ready,
          config = { root_dir = "C:/correct-root" } } }
        if wrong_attached then clients[#clients + 1] = { name = "clangd", id = 91, initialized = true,
          config = { root_dir = "C:/wrong-root" } } end
        return clients
      end
      keep_cancel(m.wait_for_clangd(buf, win, { 1, 0 }, function() calls = calls + 1 end, 500))
      vim.wait(20, function() return false end, 5)
      wrong_attached = true
      t.assert_true(vim.wait(200, function() return detached == 1 end, 10))
      t.assert_eq(calls, 0)
      correct_ready = true
      t.assert_true(vim.wait(200, function() return calls == 1 end, 10))
    end)
  end)

  for _, change in ipairs({ "window", "buffer", "close" }) do
    local action = change
    t.it("等待期间改变 " .. action .. " 取消回调且不发超时通知", function()
      isolated(function(m, keep_cancel)
        local win, buf = window({ "Foo();" })
        local other = window({ "other" }, { split = true })
        api.nvim_set_current_win(win)
        local ready, calls, messages = false, 0, 0
        vim.notify = function() messages = messages + 1 end
        vim.lsp.get_clients = function() return { { name = "clangd", initialized = ready } } end
        keep_cancel(m.wait_for_clangd(buf, win, { 1, 0 }, function() calls = calls + 1 end, 100))
        vim.wait(20, function() return false end, 5)
        if action == "window" then
          api.nvim_set_current_win(other)
        elseif action == "buffer" then
          local replacement = api.nvim_create_buf(false, true)
          api.nvim_buf_set_lines(replacement, 0, -1, false, { "replacement" })
          api.nvim_win_set_buf(win, replacement)
        else
          api.nvim_win_close(win, true)
        end
        ready = true
        vim.wait(180, function() return false end, 10)
        t.assert_eq(calls, 0)
        t.assert_eq(messages, 0, "window/buffer cancellation is not a timeout")
      end)
    end)
  end

  t.it("新等待取消旧等待，文档变动也取消旧请求", function()
    isolated(function(m, keep_cancel)
      local win, buf = window({ "Foo();" })
      local ready, old_calls, new_calls = false, 0, 0
      vim.lsp.get_clients = function() return { { name = "clangd", initialized = ready } } end
      m.wait_for_clangd(buf, win, { 1, 0 }, function() old_calls = old_calls + 1 end, 300)
      keep_cancel(m.wait_for_clangd(buf, win, { 1, 0 }, function() new_calls = new_calls + 1 end, 300))
      ready = true
      t.assert_true(vim.wait(300, function() return new_calls == 1 end, 10))
      t.assert_eq(old_calls, 0)
      ready = false
      keep_cancel(m.wait_for_clangd(buf, win, { 1, 0 }, function() new_calls = new_calls + 1 end, 100))
      vim.wait(20, function() return false end, 5)
      api.nvim_buf_set_lines(buf, 0, -1, false, { "Bar();" })
      ready = true
      vim.wait(150, function() return false end, 10)
      t.assert_eq(new_calls, 1)
    end)
  end)
end)
