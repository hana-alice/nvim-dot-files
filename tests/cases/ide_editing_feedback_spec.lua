local t = require("tests.harness")
local cfg = t.bootstrap()
local plugins = vim.fn.stdpath("data") .. "/lazy"
vim.opt.rtp:append(plugins .. "/snacks.nvim")
vim.opt.rtp:append(plugins .. "/blink.cmp")
vim.opt.rtp:append(plugins .. "/LazyVim")

local function snippet_mapping(key, active, menu)
  local old_lazy = _G.LazyVim
  local called = {}
  local api = {}
  for _, name in ipairs({ "snippet_forward", "snippet_backward", "select_next", "select_prev" }) do
    api[name] = function()
      called[#called + 1] = name
      return name:find("snippet", 1, true) and active or name:find("select", 1, true) and menu or false
    end
  end
  api.fallback = function()
    called[#called + 1] = "fallback"
    return true
  end
  _G.LazyVim = {
    cmp = {
      map = function(actions)
        return function(cmp)
          for _, name in ipairs(actions) do
            if cmp[name] and cmp[name]() then
              return true
            end
          end
        end
      end,
    },
  }
  local ok, opts = pcall(function()
    return dofile(cfg .. "/lua/plugins/blink.lua")[1].opts(nil, { keymap = { preset = "enter" } })
  end)
  _G.LazyVim = old_lazy
  if not ok then
    error(opts)
  end
  for _, command in ipairs(opts.keymap[key]) do
    local accepted = type(command) == "function" and command(api) or api[command] and api[command]()
    if accepted then
      break
    end
  end
  return called
end

local function fixture(body)
  local root = assert(vim.env.NVIM_TEST_RUN_ROOT) .. "/outline-" .. tostring(vim.uv.hrtime())
  vim.fn.mkdir(root, "p")
  local source = root .. "/Outline.cpp"
  vim.fn.writefile({ "// 你好 Alpha", "int Beta();" }, source)
  local original_win, original_buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
  local old_ue, old_clients, old_snacks = package.loaded.ue, vim.lsp.get_clients, _G.Snacks
  local old_hidden = vim.o.hidden
  local old_windows = {}
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    old_windows[win] = true
  end
  local loaded_snacks = require("snacks")
  local native_picker = loaded_snacks.picker
  local native_open = native_picker.lsp_symbols
  local Async = require("snacks.picker.util.async")
  local source_module = require("snacks.picker.source.lsp")
  local f = { root = root, source = source, requests = {}, cancelled = {}, rows = {} }
  vim.o.hidden = true
  vim.api.nvim_set_current_buf(vim.api.nvim_create_buf(true, false))
  vim.cmd.edit(vim.fn.fnameescape(source))
  vim.bo.filetype = "cpp"
  f.buf, f.win, f.tab =
    vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win(), vim.api.nvim_get_current_tabpage()
  f.client = setmetatable({
    id = 8501,
    name = "clangd",
    offset_encoding = "utf-16",
    supports_method = function()
      return true
    end,
    cancel_request = function(_, id)
      f.cancelled[#f.cancelled + 1] = id
      if f.cancel_error then
        error("controlled cancel error")
      end
    end,
    request = function(_, method, params, callback, buf)
      f.requests[#f.requests + 1] = { method = method, params = params, callback = callback, buf = buf }
      if f.synchronous then
        callback(nil, f.symbols(), { params = params })
      end
      if f.during_request then
        f.during_request()
      end
      return true, #f.requests
    end,
  }, { request = true })
  f.clients = { f.client }
  vim.lsp.get_clients = function(opts)
    if not opts or opts.bufnr == 0 or opts.bufnr == f.buf then
      return f.clients
    end
    return {}
  end
  package.loaded.ue = {
    resolve_context = function()
      return nil
    end,
  }
  _G.Snacks = loaded_snacks
  function f.symbols()
    return {
      {
        name = "Alpha",
        kind = 5,
        range = { start = { line = 0, character = 0 }, ["end"] = { line = 1, character = 0 } },
        selectionRange = { start = { line = 0, character = 6 }, ["end"] = { line = 0, character = 11 } },
        children = {
          {
            name = "Beta",
            kind = 6,
            range = { start = { line = 1, character = 0 }, ["end"] = { line = 1, character = 11 } },
            selectionRange = { start = { line = 1, character = 4 }, ["end"] = { line = 1, character = 8 } },
          },
        },
      },
    }
  end
  native_picker.lsp_symbols = function(opts)
    opts.filter = opts.filter or { default = true }
    local picker = { opts = opts, main = f.win, closed = false, matcher = { opts = {} } }
    function picker:current_win()
      return nil
    end
    function picker:current()
      return f.rows[1]
    end
    function picker:items()
      return f.rows
    end
    function picker:selected()
      return f.rows
    end
    function picker:close()
      if self.closed or self.closing then
        return
      end
      self.closing = true
      if self.opts.on_close then
        self.opts.on_close(self)
      end
      if f.during_close then
        f.during_close()
      end
      self.closed = true
      if self.task then
        self.task:abort()
      end
    end
    function picker:refresh()
      if self.task then
        self.task:abort()
      end
      f.rows = {}
      local ctx = { picker = self, filter = { current_buf = f.buf, current_win = f.win } }
      local finder = source_module.symbols(opts, ctx)
      self.task = Async.new(function()
        ctx.async = Async.running()
        finder(function(row)
          local transformed = row
          if opts.transform then
            transformed = opts.transform(row, ctx)
          end
          if transformed ~= false then
            f.rows[#f.rows + 1] = type(transformed) == "table" and transformed or row
          end
        end)
      end)
    end
    picker:refresh()
    f.picker = picker
    return picker
  end
  function f.open(opts)
    local picker = require("utils.document_symbols").open(opts or { tree = true })
    t.assert_true(picker ~= nil)
    t.assert_true(
      vim.wait(1000, function()
        return #f.requests > 0
      end, 5),
      "documentSymbol was not requested"
    )
    return picker
  end
  function f.respond(result)
    local request = f.requests[#f.requests]
    request.callback(nil, result or f.symbols(), { params = request.params })
    vim.wait(40, function()
      return false
    end, 5)
  end
  local ok, err = xpcall(function()
    body(f)
  end, debug.traceback)
  local owner = package.loaded["utils.ue_goto.reading_owner"]
  if owner then
    owner.cancel()
  end
  native_picker.lsp_symbols = native_open
  vim.lsp.get_clients, package.loaded.ue, _G.Snacks = old_clients, old_ue, old_snacks
  if vim.api.nvim_win_is_valid(original_win) then
    vim.api.nvim_set_current_win(original_win)
    vim.api.nvim_win_set_buf(original_win, original_buf)
  end
  for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
      if not old_windows[win] then
        pcall(vim.api.nvim_win_close, win, true)
      end
    end
  end
  if vim.api.nvim_buf_is_valid(f.buf) then
    pcall(vim.api.nvim_buf_delete, f.buf, { force = true })
  end
  vim.o.hidden = old_hidden
  vim.fn.delete(root, "rf")
  if not ok then
    error(err)
  end
end

t.describe("ide editing feedback", function()
  for _, entry in ipairs({
    { "<Tab>", "snippet_forward", "select_next" },
    { "<S-Tab>", "snippet_backward", "select_prev" },
  }) do
    t.it(entry[1] .. " advances active fields before visible candidates", function()
      local calls = snippet_mapping(entry[1], true, true)
      t.assert_eq(calls[1], entry[2])
      t.assert_eq(#calls, 1)
    end)
    t.it(entry[1] .. " still selects candidates outside snippets", function()
      local calls = snippet_mapping(entry[1], false, true)
      t.assert_eq(calls[#calls], entry[3])
    end)
  end

  for _, drift in ipairs({ "edit", "rename", "window", "tab", "client", "encoding" }) do
    t.it("document outline discards a late " .. drift .. " response", function()
      fixture(function(f)
        f.open()
        if drift == "edit" then
          vim.api.nvim_buf_set_lines(f.buf, 0, 0, false, { "new input" })
        elseif drift == "rename" then
          vim.api.nvim_buf_set_name(f.buf, f.root .. "/Other.cpp")
        elseif drift == "window" then
          vim.cmd.vsplit()
        elseif drift == "tab" then
          vim.cmd.tabnew()
        elseif drift == "client" then
          f.clients = {}
        else
          f.client.offset_encoding = "utf-8"
        end
        f.respond()
        t.assert_eq(#f.rows, 0)
      end)
    end)
  end

  t.it("closing a loading outline cancels only its pending request once", function()
    fixture(function(f)
      f.open()
      f.picker:close()
      f.picker:close()
      f.respond()
      t.assert_eq(#f.cancelled, 1)
      t.assert_eq(f.cancelled[1], 1)
      t.assert_eq(#f.rows, 0)
    end)
  end)

  t.it("a throwing cancellation callback cannot deliver late rows", function()
    fixture(function(f)
      f.cancel_error = true
      f.open()
      f.picker:close()
      f.respond()
      t.assert_eq(#f.cancelled, 1)
      t.assert_eq(#f.rows, 0)
    end)
  end)

  t.it("refreshing a pending outline cancels its old request without closing the new finder", function()
    fixture(function(f)
      f.open()
      local old = f.requests[1]
      f.picker:refresh()
      t.assert_true(
        vim.wait(1000, function()
          return #f.requests == 2
        end, 5),
        "old abort cancelled the new finder"
      )
      t.assert_true(
        vim.wait(1000, function()
          return #f.cancelled > 0
        end, 5),
        "old finder left its request pending"
      )
      t.assert_false(f.picker.closed)
      t.assert_eq(#f.cancelled, 1)
      t.assert_eq(f.cancelled[1], 1)
      old.callback(nil, f.symbols(), { params = old.params })
      f.respond()
      t.assert_eq(#f.rows, 2)
      t.assert_false(f.picker.closed)
    end)
  end)

  t.it("refreshing a completed outline retains its owner and makes one new query", function()
    fixture(function(f)
      f.open()
      f.respond()
      f.picker:refresh()
      t.assert_true(vim.wait(1000, function()
        return #f.requests == 2
      end, 5))
      f.respond()
      t.assert_false(f.picker.closed)
      t.assert_eq(#f.rows, 2)
      t.assert_eq(#f.cancelled, 0)
    end)
  end)

  t.it("native tree conversion keeps parents and never consumes cached protocol children", function()
    fixture(function(f)
      f.open({ tree = true, filter = { default = { "Class", "Method" } } })
      local cached = f.symbols()
      f.respond(cached)
      t.assert_eq(#f.rows, 2)
      t.assert_true(f.rows[2].parent == f.rows[1])
      t.assert_eq(#cached[1].children, 1)
      t.assert_eq(cached[1].selectionRange.start.character, 6)
      f.rows[1].loc.range.start.character = 10
      t.assert_eq(cached[1].selectionRange.start.character, 6)
      t.assert_eq(f.rows[1].location.range.start.character, 6)
      t.assert_false(f.picker.opts.auto_confirm)
    end)
  end)

  t.it("canonical source identity is resolved once per raw path in an outline query", function()
    fixture(function(f)
      f.open()
      local original, calls = vim.uv.fs_realpath, 0
      vim.uv.fs_realpath = function(path)
        calls = calls + 1
        return original(path)
      end
      local ok, err = pcall(f.respond)
      vim.uv.fs_realpath = original
      if not ok then
        error(err)
      end
      t.assert_eq(#f.rows, 2)
      t.assert_true(calls <= 1, "each symbol repeated synchronous canonical-path IO")
    end)
  end)

  t.it("the isolated native patch is idempotent and reversible", function()
    local patch = require("workarounds.snacks.document_symbols_owner")
    local source = require("snacks.picker.source.lsp")
    t.assert_true(patch.apply())
    local symbols, request = source.symbols, source.request
    t.assert_true(patch.apply())
    t.assert_true(source.symbols == symbols and source.request == request)
    patch.disable()
    t.assert_false(source.symbols == symbols)
    t.assert_false(source.request == request)
    t.assert_true(patch.apply())
  end)

  t.it("source changes after response invalidate confirmation and preserve the build list", function()
    fixture(function(f)
      f.open()
      f.respond()
      vim.fn.setqflist(
        {},
        " ",
        { title = "Build fixture", items = { { bufnr = f.buf, lnum = 2, col = 1, text = "old error" } } }
      )
      local qf = vim.fn.getqflist({ id = 0 }).id
      vim.api.nvim_buf_set_lines(f.buf, 0, 0, false, { "new input" })
      local cursor = vim.api.nvim_win_get_cursor(f.win)
      f.picker.opts.confirm(f.picker, f.rows[1], {})
      t.assert_true(vim.deep_equal(vim.api.nvim_win_get_cursor(f.win), cursor))
      t.assert_eq(vim.fn.getqflist({ id = 0 }).id, qf)
      t.assert_true(vim.bo[f.buf].modified)
    end)
  end)

  t.it("an edit during close cannot pass the final jump handoff", function()
    fixture(function(f)
      f.open()
      f.respond()
      local cursor
      f.during_close = function()
        vim.api.nvim_buf_set_lines(f.buf, 0, 0, false, { "handoff input" })
        cursor = vim.api.nvim_win_get_cursor(f.win)
      end
      f.picker.opts.confirm(f.picker, f.rows[2], {})
      t.assert_true(vim.deep_equal(vim.api.nvim_win_get_cursor(f.win), cursor))
      t.assert_eq(vim.api.nvim_buf_get_lines(f.buf, 0, 1, false)[1], "handoff input")
    end)
  end)

  t.it("a synchronous documentSymbol response remains navigable", function()
    fixture(function(f)
      f.synchronous = true
      f.open()
      vim.wait(30, function()
        return false
      end, 5)
      t.assert_eq(#f.rows, 2)
      f.picker.opts.confirm(f.picker, f.rows[2], {})
      t.assert_eq(vim.api.nvim_win_get_cursor(f.win)[1], 2)
      t.assert_eq(#f.cancelled, 0)
    end)
  end)

  t.it("cancellation before client.request returns still cancels the returned ID once", function()
    fixture(function(f)
      f.during_request = function()
        require("utils.ue_goto.reading_owner").cancel()
      end
      f.open()
      f.respond()
      t.assert_eq(#f.cancelled, 1)
      t.assert_eq(f.cancelled[1], 1)
      t.assert_eq(#f.rows, 0)
    end)
  end)
end)
