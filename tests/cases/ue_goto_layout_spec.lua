local t = require("tests.harness")
local root = t.bootstrap()
local api = vim.api

local function fixture(body)
  local original_tabs = {}
  for _, tab in ipairs(api.nvim_list_tabpages()) do original_tabs[tab] = true end
  local original_buffers = {}
  for _, buf in ipairs(api.nvim_list_bufs()) do original_buffers[buf] = true end
  local before = { tab = api.nvim_get_current_tabpage(), hidden = vim.o.hidden,
    clients = vim.lsp.get_clients, ue = package.loaded.ue,
    lifecycle = package.loaded["codediff.ui.lifecycle"], layout = package.loaded["utils.layout"] }
  vim.o.hidden = true
  vim.cmd.tabnew()
  local tab = api.nvim_get_current_tabpage()
  local directory = vim.fs.joinpath(vim.env.NVIM_TEST_RUN_ROOT or vim.fn.tempname(), "goto-layout-" .. tab)
  vim.fn.mkdir(directory, "p")
  local source_path, target_path = directory .. "/source.cpp", directory .. "/target.cpp"
  vim.fn.writefile({ "int source;", "void call() { source++; }" }, source_path)
  vim.fn.writefile({ "int target;", "void target_body() {}" }, target_path)
  vim.cmd.edit(vim.fn.fnameescape(source_path))
  local source, source_buf = api.nvim_get_current_win(), api.nvim_get_current_buf()
  api.nvim_win_set_cursor(source, { 2, 14 })
  vim.cmd.vnew()
  local aux, aux_buf = api.nvim_get_current_win(), api.nvim_get_current_buf()
  vim.cmd.vnew()
  local panel, panel_buf = api.nvim_get_current_win(), api.nvim_get_current_buf()
  vim.bo[panel_buf].buftype = "nofile"
  vim.wo[panel].winfixbuf = true
  local session = { original_win = source, modified_win = aux, panel = { view = { winid = panel } } }
  package.loaded["codediff.ui.lifecycle"] = { get_session = function(id) return id == tab and session end }
  package.loaded["utils.layout"] = nil
  package.loaded.ue = { resolve_context = function() return nil end }
  vim.lsp.get_clients = function() return {} end
  local layout = require("utils.layout")
  api.nvim_set_current_win(source)
  local f = { tab = tab, source = source, source_buf = source_buf, target_path = target_path,
    original_tabs = original_tabs,
    aux = aux, aux_buf = aux_buf, panel = panel, panel_buf = panel_buf, layout = layout,
    loc = { uri = vim.uri_from_fname(target_path), _position_encoding = "utf-8",
      range = { start = { line = 1, character = 5 } } } }
  function f.unchanged()
    t.assert_eq(api.nvim_win_get_buf(source), source_buf)
    t.assert_true(vim.deep_equal(api.nvim_win_get_cursor(source), { 2, 14 }))
    t.assert_eq(api.nvim_win_get_buf(aux), aux_buf)
    t.assert_eq(api.nvim_win_get_buf(panel), panel_buf)
  end
  local ok, err = xpcall(function() body(f) end, debug.traceback)
  require("utils.ue_goto.reading_results").reset()
  for _, buf in ipairs(api.nvim_list_bufs()) do
    if not original_buffers[buf] then vim.bo[buf].modified = false end
  end
  vim.lsp.get_clients, package.loaded.ue = before.clients, before.ue
  package.loaded["codediff.ui.lifecycle"], package.loaded["utils.layout"] = before.lifecycle, before.layout
  api.nvim_set_current_tabpage(before.tab)
  for _, created in ipairs(api.nvim_list_tabpages()) do
    if not original_tabs[created] then api.nvim_set_current_tabpage(created); vim.cmd("tabclose!") end
  end
  api.nvim_set_current_tabpage(before.tab)
  vim.o.hidden = before.hidden
  if not ok then error(err) end
end

t.describe("ue_goto review layout handoff", function()
  for _, stage in ipairs({ "source", "target" }) do
    t.it("jumper cancels same-window buffer replacement during " .. stage .. " staging", function()
      fixture(function(f)
        local code = assert(f.layout.resolve({ source_win = f.source }))
        local replacement = api.nvim_create_buf(true, false)
        api.nvim_buf_set_lines(replacement, 0, -1, false, { "chosen", "user position", "third", "fourth" })
        local chosen = { 4, 3 }
        local fired = false
        local id = api.nvim_create_autocmd("BufEnter", { callback = function(ev)
          local expected = stage == "source" and ev.buf == f.source_buf
            or stage == "target" and vim.fs.normalize(api.nvim_buf_get_name(ev.buf)) == vim.fs.normalize(f.target_path)
          if not fired and expected and api.nvim_get_current_win() == code then
            fired = true
            api.nvim_set_current_buf(replacement)
            api.nvim_win_set_cursor(code, chosen)
          end
        end })
        api.nvim_set_current_win(f.source)
        local ok, result = pcall(require("utils.ue_goto.jumper").jump, f.loc)
        api.nvim_del_autocmd(id)
        t.assert_true(ok)
        t.assert_true(fired)
        t.assert_false(result)
        t.assert_eq(api.nvim_get_current_win(), code)
        t.assert_eq(api.nvim_win_get_buf(code), replacement)
        t.assert_true(vim.deep_equal(api.nvim_win_get_cursor(code), chosen))
        if stage == "source" then
          local jumps = api.nvim_win_call(code, vim.fn.getjumplist)[1]
          for _, jump in ipairs(jumps) do t.assert_false(jump.bufnr == replacement, "replacement never becomes old invocation history") end
        end
        f.unchanged()
      end)
    end)
  end

  for _, command in ipairs({ "split", "vsplit", "tab" }) do
    t.it("reading " .. command .. " preserves a foreign tab selected by creation autocmd", function()
      fixture(function(f)
        local code = assert(f.layout.resolve({ source_win = f.source }))
        local normal_tab = api.nvim_win_get_tabpage(code)
        vim.cmd.tabnew()
        local foreign, foreign_buf = api.nvim_get_current_win(), api.nvim_get_current_buf()
        api.nvim_buf_set_lines(foreign_buf, 0, -1, false, { "foreign dirty document", "second" })
        api.nvim_win_set_cursor(foreign, { 2, 3 })
        api.nvim_set_current_win(f.source)
        local results = require("utils.ue_goto.reading_results")
        local owner = require("utils.ue_goto.reading_owner").begin()
        local row = results.items({ f.loc })[1]
        local fired = false
        local id = api.nvim_create_autocmd("WinEnter", { callback = function()
          local win, tab = api.nvim_get_current_win(), api.nvim_get_current_tabpage()
          local created = command == "tab" and tab ~= f.tab and tab ~= normal_tab
            and win ~= foreign or command ~= "tab" and tab == normal_tab and win ~= code
          if not fired and created then fired = true; api.nvim_set_current_win(foreign) end
        end })
        local ok, result = pcall(results.jump, owner, row, command)
        api.nvim_del_autocmd(id)
        t.assert_true(ok)
        t.assert_true(fired)
        t.assert_false(result)
        t.assert_eq(api.nvim_get_current_win(), foreign)
        t.assert_eq(api.nvim_win_get_buf(foreign), foreign_buf)
        t.assert_true(vim.deep_equal(api.nvim_win_get_cursor(foreign), { 2, 3 }))
        f.unchanged()
      end)
    end)
  end

  for _, entry in ipairs({ "definition", "reading" }) do
    t.it("debug " .. entry .. " uses normal while its owned source and aux panes remain unchanged", function()
      fixture(function(f)
        package.loaded["codediff.ui.lifecycle"] = { get_session = function() return nil end }
        f.layout.sync_review(f.tab)
        local token = {}
        f.layout.register_group("debug", { tab = f.tab, token = token, main = f.source })
        f.layout.register(f.source, "code", { owner = "debug" })
        f.layout.register(f.aux, "aux", { owner = "debug" })
        if entry == "definition" then
          t.assert_true(require("utils.ue_goto.jumper").jump(f.loc))
        else
          local owner = require("utils.ue_goto.reading_owner").begin()
          local results = require("utils.ue_goto.reading_results")
          t.assert_true(results.jump(owner, results.items({ f.loc })[1]))
        end
        t.assert_true(api.nvim_get_current_tabpage() ~= f.tab)
        t.assert_eq(vim.fs.normalize(api.nvim_buf_get_name(0)), vim.fs.normalize(f.target_path))
        f.unchanged()
        t.assert_eq(f.layout.navigation_owner(f.tab), token)
      end)
    end)
  end
  for _, change in ipairs({ "focus-aux", "focus-new-tab", "source-cursor", "destination-role", "source-role" }) do
    t.it("jumper rejects " .. change .. " caused by navigation autocmds", function()
      fixture(function(f)
        local code = f.layout.resolve({ source_win = f.source })
        api.nvim_set_current_win(f.source)
        local event = change == "source-cursor" and "BufEnter" or "WinEnter"
        local fired = false
        local id = api.nvim_create_autocmd(event, { callback = function()
          if fired or api.nvim_get_current_win() ~= code then return end
          fired = true
          if change == "focus-aux" then api.nvim_set_current_win(f.aux)
          elseif change == "focus-new-tab" then vim.cmd.tabnew()
          elseif change == "source-cursor" then api.nvim_win_set_cursor(f.source, { 1, 0 })
          elseif change == "source-role" then
            package.loaded["codediff.ui.lifecycle"] = { get_session = function() return nil end }
          else f.layout.register(code, "aux", { owner = "fixture" }) end
        end })
        local ok, result = pcall(require("utils.ue_goto.jumper").jump, f.loc)
        api.nvim_del_autocmd(id)
        t.assert_true(ok)
        t.assert_false(result)
        t.assert_true(fired)
        t.assert_eq(api.nvim_win_get_buf(f.source), f.source_buf)
        t.assert_eq(api.nvim_win_get_buf(f.aux), f.aux_buf)
        t.assert_eq(api.nvim_win_get_buf(f.panel), f.panel_buf)
        t.assert_false(vim.fs.normalize(api.nvim_buf_get_name(api.nvim_win_get_buf(code))) == vim.fs.normalize(f.target_path))
        if api.nvim_get_current_tabpage() ~= f.tab and not f.original_tabs[api.nvim_get_current_tabpage()] then
          vim.cmd("tabclose!")
          api.nvim_set_current_tabpage(f.tab)
        end
      end)
    end)
  end

  t.it("an existing dirty code window keeps its buffer and aux targets never become the destination", function()
    fixture(function(f)
      local target = vim.fn.bufadd(f.target_path)
      vim.fn.bufload(target)
      api.nvim_win_set_buf(f.aux, target)
      local code = f.layout.resolve({ source_win = f.source })
      local dirty = api.nvim_create_buf(true, false)
      api.nvim_buf_set_lines(dirty, 0, -1, false, { "unsaved work" })
      api.nvim_win_set_buf(code, dirty)
      api.nvim_set_current_win(f.source)
      local count = #api.nvim_tabpage_list_wins(f.tab)
      t.assert_true(require("utils.ue_goto.jumper").jump(f.loc))
      t.assert_eq(api.nvim_get_current_win(), code)
      t.assert_true(api.nvim_get_current_tabpage() ~= f.tab, "external jump switches to normal tab")
      t.assert_eq(api.nvim_get_current_buf(), target)
      t.assert_eq(api.nvim_win_get_buf(f.aux), target)
      t.assert_true(vim.bo[dirty].modified)
      t.assert_eq(api.nvim_buf_get_lines(dirty, 0, -1, false)[1], "unsaved work")
      t.assert_eq(#api.nvim_tabpage_list_wins(f.tab), count)
    end)
  end)

  t.it("ordinary reading confirmation preserves the existing window and tagstack behavior", function()
    fixture(function(f)
      package.loaded["codediff.ui.lifecycle"] = { get_session = function() return nil end }
      local owner = require("utils.ue_goto.reading_owner").begin()
      local results = require("utils.ue_goto.reading_results")
      local tags = vim.deepcopy(vim.fn.gettagstack(f.source))
      local count = #api.nvim_tabpage_list_wins(f.tab)
      t.assert_true(results.jump(owner, results.items({ f.loc })[1]))
      t.assert_eq(api.nvim_get_current_win(), f.source)
      t.assert_eq(#api.nvim_tabpage_list_wins(f.tab), count)
      t.assert_true(vim.deep_equal(vim.fn.gettagstack(f.source), tags))
    end)
  end)

  t.it("compiler lineage commits to the actual code destination while identity stays unchanged", function()
    fixture(function(f)
      local name = "utils.ue_goto.semantic_client"
      local previous, old_notify = package.loaded[name], vim.notify
      local origin = { origin_tu = "compiler-proven-origin.cpp", subject_membership = {} }
      local committed_win, committed
      package.loaded[name] = {
        set_trace = function() end,
        begin_action = function() return { bufnr = f.source_buf, winid = f.source,
          cursor = api.nvim_win_get_cursor(f.source) } end,
        discover_toolchain = function() return { build_fingerprint = "fixed-build", index = {} } end,
        snapshot_is_current = function() return true end,
        resolve_header = function(_, cb) cb({ state = "resolved", usr = "usr:chosen",
          definition = { path = f.target_path, line = 2, column = 6 }, origin_context = origin }) end,
        note_origin = function(win, context, build)
          committed_win, committed = win, context
          t.assert_eq(build, "fixed-build")
        end,
      }
      vim.notify = function() end
      local ok, err = xpcall(function()
        local owner = {}
        local nav = require("utils.ue_goto.semantic_navigation").install(owner, {
          dtrace = function() end, format_jump_msg = function() return "" end,
          jump_to_location = require("utils.ue_goto.jumper").jump,
        })
        nav.cpp_definition("chosen", f.source_buf, "compiler-subject.hpp", "h")
        t.assert_eq(owner._last_cpp_transaction.result.state, "resolved")
        t.assert_eq(owner._last_cpp_transaction.result.identity, "usr:chosen")
        t.assert_eq(committed_win, api.nvim_get_current_win())
        t.assert_true(committed_win ~= f.source)
        t.assert_true(vim.deep_equal(committed, origin))
        f.unchanged()
      end, debug.traceback)
      package.loaded[name], vim.notify = previous, old_notify
      if not ok then error(err) end
    end)
  end)

  t.it("jumper selects code once and preserves aux/source history; Ctrl-O and tag return use the source", function()
    fixture(function(f)
      local source_history = vim.deepcopy(vim.fn.getjumplist())
      local source_tags = vim.deepcopy(vim.fn.gettagstack(f.source))
      local expected_code = f.layout.resolve({ source_win = f.source })
      local previous_buf, previous_cursor = api.nvim_win_get_buf(expected_code), api.nvim_win_get_cursor(expected_code)
      api.nvim_set_current_win(f.source)
      local code_history = api.nvim_win_call(expected_code, vim.fn.getjumplist)
      t.assert_true(require("utils.ue_goto.jumper").jump(f.loc))
      local code = api.nvim_get_current_win()
      t.assert_eq(code, expected_code)
      t.assert_true(code ~= f.source and code ~= f.aux and code ~= f.panel)
      t.assert_true(vim.deep_equal(api.nvim_win_get_cursor(code), { 2, 5 }))
      f.unchanged()
      t.assert_true(vim.deep_equal(api.nvim_win_call(f.source, vim.fn.getjumplist), source_history))
      t.assert_true(vim.deep_equal(vim.fn.gettagstack(f.source), source_tags))
      local jumps = vim.fn.getjumplist()[1]
      local added = #jumps - #code_history[1]
      t.assert_true(added == 1 or added == 2, "one source entry, plus at most the reused editor's native current position")
      if added == 2 then
        local retained = jumps[#jumps - 1]
        t.assert_eq(retained.bufnr, previous_buf)
        t.assert_eq(retained.lnum, previous_cursor[1])
        t.assert_eq(retained.col, previous_cursor[2])
      end
      for index = #code_history[1] + 1, #jumps - 1 do
        t.assert_false(jumps[index].bufnr == f.source_buf, "no duplicate source jump")
      end
      t.assert_eq(jumps[#jumps].bufnr, f.source_buf)
      t.assert_eq(jumps[#jumps].lnum, 2)
      t.assert_eq(jumps[#jumps].col, 14)
      local tags = vim.fn.gettagstack(code).items
      t.assert_true(vim.deep_equal(tags[#tags].from, { f.source_buf, 2, 15, 0 }))
      vim.cmd("execute \"normal! \\<C-O>\"")
      t.assert_eq(api.nvim_get_current_buf(), f.source_buf)
      t.assert_true(vim.deep_equal(api.nvim_win_get_cursor(code), { 2, 14 }))
      api.nvim_feedkeys(api.nvim_replace_termcodes("<C-I>", true, false, true), "nx", false)
      t.assert_eq(vim.fs.normalize(api.nvim_buf_get_name(0)), vim.fs.normalize(f.target_path))
      vim.cmd("pop")
      t.assert_eq(api.nvim_get_current_buf(), f.source_buf)
      t.assert_true(vim.deep_equal(api.nvim_win_get_cursor(code), { 2, 14 }))
      f.unchanged()
      api.nvim_set_current_win(f.source)
      local count = #api.nvim_tabpage_list_wins(f.tab)
      t.assert_true(require("utils.ue_goto.jumper").jump(f.loc))
      t.assert_eq(api.nvim_get_current_win(), code)
      t.assert_true(api.nvim_get_current_tabpage() ~= f.tab)
      t.assert_eq(#api.nvim_tabpage_list_wins(f.tab), count)
    end)
  end)

  t.it("reading keeps the source main and closes there before routing, including explicit splits", function()
    for _, command in ipairs({ "edit", "split", "vsplit", "tab" }) do
      fixture(function(f)
        local ownership = require("utils.ue_goto.reading_owner")
        local results = require("utils.ue_goto.reading_results")
        vim.bo[f.source_buf].buftype = "nowrite"
        local code = f.layout.resolve({ source_win = f.source })
        api.nvim_set_current_win(f.source)
        local owner = ownership.begin()
        local float
        local picker = ownership.present(owner, function()
          float = api.nvim_open_win(api.nvim_create_buf(false, true), true,
            { relative = "editor", row = 1, col = 1, width = 20, height = 2 })
          return { main = code, closed = false,
            current_win = function() return api.nvim_get_current_win() == float and "list" or nil end,
            close = function(self)
              self.closed = true
              api.nvim_win_close(float, true)
              api.nvim_set_current_win(self.main)
              ownership.picker_closed(owner, self)
            end }
        end)
        t.assert_eq(picker.main, f.source)
        t.assert_true(ownership.current(owner, true))
        local row = results.items({ f.loc })[1]
        t.assert_true(results.jump(owner, row, command ~= "edit" and command or nil))
        local destination = api.nvim_get_current_win()
        t.assert_true(destination ~= f.source and destination ~= f.aux and destination ~= f.panel)
        t.assert_true(api.nvim_get_current_tabpage() ~= f.tab)
        t.assert_eq(#api.nvim_tabpage_list_wins(f.tab), 3, "review never creates a browser split")
        t.assert_eq(vim.fs.normalize(api.nvim_buf_get_name(0)), vim.fs.normalize(f.target_path))
        f.unchanged()
        local tags = vim.fn.gettagstack(destination).items
        t.assert_true(vim.deep_equal(tags[#tags].from, { f.source_buf, 2, 15, 0 }))
        t.assert_true(results.return_to_origin())
        t.assert_eq(api.nvim_get_current_win(), f.source)
        f.unchanged()
      end)
    end
  end)

  for _, change in ipairs({ "source-edit", "source-cursor", "other-window", "new-intent" }) do
    t.it("reading rejects " .. change .. " during picker close without creating a destination", function()
      fixture(function(f)
        local ownership = require("utils.ue_goto.reading_owner")
        local results = require("utils.ue_goto.reading_results")
        local owner = ownership.begin()
        local row = results.items({ f.loc })[1]
        owner.picker = { main = f.source, closed = false, close = function(self)
          self.closed = true
          if change == "source-edit" then api.nvim_buf_set_lines(f.source_buf, 0, 1, false, { "changed" })
          elseif change == "source-cursor" then api.nvim_win_set_cursor(f.source, { 1, 0 })
          elseif change == "other-window" then api.nvim_set_current_win(f.aux)
          else ownership.begin() end
        end }
        local count = #api.nvim_tabpage_list_wins(f.tab)
        t.assert_false(results.jump(owner, row))
        t.assert_eq(#api.nvim_tabpage_list_wins(f.tab), count)
        t.assert_eq(api.nvim_win_get_buf(f.source), f.source_buf)
      end)
    end)
  end

  t.it("hidden dirty compiler destination uses the same client/USR and leaves every pane unchanged", function()
    fixture(function(f)
      local buffer = vim.fn.bufadd(f.target_path)
      vim.fn.bufload(buffer)
      api.nvim_buf_set_lines(buffer, 0, 1, false, { "int target; // dirty overlay" })
      local adapter_name = "utils.ue_goto.clangd_adapter"
      local previous = { adapter = package.loaded[adapter_name], get = vim.lsp.get_client_by_id,
        attached = vim.lsp.buf_is_attached, attach = vim.lsp.buf_attach_client }
      local callback, observed
      local client = { id = 431 }
      vim.lsp.get_client_by_id = function(id) return id == client.id and client or nil end
      vim.lsp.buf_is_attached = function() return false end
      vim.lsp.buf_attach_client = function(buf, id)
        t.assert_eq(buf, buffer); t.assert_eq(id, client.id)
        return true
      end
      package.loaded[adapter_name] = { async_clangd_symbol_info = function(buf, cb, opts)
        t.assert_eq(buf, buffer)
        observed, callback = opts, cb
      end }
      local result
      local ok, err = xpcall(function()
        require("utils.ue_goto.clangd_destination").verify(f.loc, "usr:target", { client.id },
          function(value) result = value end, { is_current = function() return true end })
        t.assert_eq(observed.client_ids[1], client.id)
        t.assert_eq(observed.compile_command_source, vim.fs.normalize(f.target_path))
        t.assert_eq(observed.snapshot.subject.bufnr, buffer)
        callback({ reason = "ok", usr = "usr:target", definitions = { f.loc } })
        t.assert_eq(result.reason, "ok")
        t.assert_eq(api.nvim_get_current_win(), f.source)
        t.assert_eq(#vim.fn.win_findbuf(buffer), 0)
        t.assert_true(vim.bo[buffer].modified)
        f.unchanged()
      end, debug.traceback)
      package.loaded[adapter_name], vim.lsp.get_client_by_id = previous.adapter, previous.get
      vim.lsp.buf_is_attached, vim.lsp.buf_attach_client = previous.attached, previous.attach
      if not ok then error(err) end
    end)
  end)
end)
