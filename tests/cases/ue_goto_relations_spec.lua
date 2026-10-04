local t = require("tests.harness")
t.bootstrap()

local function fixture(body)
  local root = vim.fn.tempname():gsub("\\", "/")
  vim.fn.mkdir(root, "p")
  local source = root .. "/relations.cpp"
  local lines = {}
  for line = 1, 45 do
    lines[line] = "int value" .. line .. ";"
  end
  vim.fn.writefile(lines, source)
  local old_win, old_buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
  local saved_buffers = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    saved_buffers[buf] = true
  end
  local old_clients, old_notify, old_snacks, old_ue = vim.lsp.get_clients, vim.notify, _G.Snacks, package.loaded.ue
  local old_workspace = package.loaded["utils.workspace"]
  local old_hidden = vim.o.hidden
  vim.o.hidden = true
  vim.api.nvim_set_current_buf(vim.api.nvim_create_buf(true, false))
  vim.cmd.edit(vim.fn.fnameescape(source))
  local f = {
    source = source,
    buf = vim.api.nvim_get_current_buf(),
    win = vim.api.nvim_get_current_win(),
    requests = {},
    picks = {},
    messages = {},
    cancels = {},
    pins = {},
  }
  vim.bo.filetype = "cpp"
  vim.api.nvim_win_set_cursor(f.win, { 5, 4 })
  f.client = {
    id = 991,
    name = "clangd",
    offset_encoding = "utf-16",
    config = { root_dir = root },
    supports_method = function()
      return true
    end,
    cancel_request = function(_, id)
      f.cancels[#f.cancels + 1] = id
    end,
    request = function(client, method, params, callback, buf)
      f.requests[#f.requests + 1] =
        { client = client, method = method, params = params, callback = callback, buf = buf }
      return true, #f.requests
    end,
  }
  f.context = { engine_root = root, project_root = root, state = { target_platform = "Win64" }, paths = {} }
  package.loaded.ue = {
    resolve_context = function()
      return f.context
    end,
  }
  package.loaded["utils.workspace"] = {
    pin = function(items)
      f.pins[#f.pins + 1] = items
      return #f.pins
    end,
  }
  vim.lsp.get_clients = function(opts)
    return not opts.bufnr or opts.bufnr == f.buf and { f.client } or {}
  end
  vim.notify = function(message)
    f.messages[#f.messages + 1] = message
  end
  _G.Snacks = {
    picker = {
      pick = function(opts)
        local picker = { opts = opts, main = f.win, closed = false, index = 1 }
        function picker:close()
          if self.closed then
            return
          end
          self.closed = true
          if self.opts.on_close then
            self.opts.on_close()
          end
        end
        function picker:current_win()
          return nil
        end
        function picker:current()
          return self.opts.items[self.index]
        end
        function picker:refresh()
          self.refreshed = (self.refreshed or 0) + 1
        end
        picker.list = {
          move = function(_, index)
            picker.index = index
          end,
        }
        f.picks[#f.picks + 1] = picker
        return picker
      end,
    },
  }
  f.module = require("utils.ue_goto.relations")
  function f.item(name, line, id)
    return {
      uri = vim.uri_from_bufnr(f.buf),
      name = name,
      kind = 12,
      selectionRange = { start = { line = line - 1, character = 4 }, ["end"] = { line = line - 1, character = 9 } },
      data = { symbolID = id or name, opaque = { "native-provider" } },
    }
  end
  function f.respond(index, err, value)
    f.requests[index].callback(err, value)
    vim.wait(25, function()
      return false
    end, 5)
  end
  function f.start(kind)
    t.assert_true(f.module.open(kind))
    local item = f.item("Root", 5)
    f.respond(#f.requests, nil, { item })
    return f.module.session(), item
  end
  local ok, err = xpcall(function()
    body(f)
  end, debug.traceback)
  f.module.reset()
  require("utils.ue_goto.reading_results").reset()
  vim.lsp.get_clients, vim.notify, _G.Snacks, package.loaded.ue = old_clients, old_notify, old_snacks, old_ue
  package.loaded["utils.workspace"] = old_workspace
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if win ~= old_win then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
  if vim.api.nvim_win_is_valid(old_win) then
    vim.api.nvim_set_current_win(old_win)
    vim.api.nvim_win_set_buf(old_win, old_buf)
  end
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if not saved_buffers[buf] then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end
  vim.o.hidden = old_hidden
  vim.fn.delete(root, "rf")
  if not ok then
    error(err)
  end
end

t.describe("ue_goto relationship investigation", function()
  for kind, method in pairs({
    incoming = "callHierarchy/incomingCalls",
    outgoing = "callHierarchy/outgoingCalls",
    base = "typeHierarchy/supertypes",
    derived = "typeHierarchy/subtypes",
  }) do
    t.it(kind .. " only queries children after an explicit expand and preserves opaque data", function()
      fixture(function(f)
        local session, root = f.start(kind)
        t.assert_eq(#f.requests, 1)
        t.assert_eq(f.picks[1].opts.auto_confirm, false)
        t.assert_contains(f.picks[1].opts.title, "覆盖未知")
        t.assert_true(f.module.expand(session, session.roots[1]))
        t.assert_eq(f.requests[2].method, method)
        t.assert_eq(f.requests[2].params.item, root)
        t.assert_eq(f.requests[2].params.item.data, root.data)
        t.assert_eq(f.requests[2].client, f.client)
        local child = f.item("Child", 12)
        local value = kind == "incoming"
            and { { from = child, fromRanges = { child.selectionRange, child.selectionRange } } }
          or kind == "outgoing" and { { to = child } }
          or { child }
        f.respond(2, nil, value)
        t.assert_eq(#f.module.rows(session), 2)
        t.assert_eq(session.roots[1].children[1].item, child)
        if kind == "incoming" then
          t.assert_contains(f.module.rows(session)[2].label, "2处调用")
        end
        t.assert_eq(vim.api.nvim_get_current_buf(), f.buf)
        t.assert_true(vim.deep_equal(vim.api.nvim_win_get_cursor(f.win), { 5, 4 }))
      end)
    end)
  end

  t.it("three layers expand/collapse without new queries, and recursion is a visible leaf", function()
    fixture(function(f)
      local session, root = f.start("outgoing")
      f.module.expand(session, session.roots[1])
      f.respond(2, nil, { { to = f.item("Middle", 12) } })
      local middle = session.roots[1].children[1]
      f.module.expand(session, middle)
      f.respond(3, nil, { { to = f.item("Leaf", 20) } })
      local leaf = middle.children[1]
      f.module.expand(session, leaf)
      f.respond(4, nil, { { to = root } })
      t.assert_eq(#f.module.rows(session), 4)
      t.assert_eq(leaf.children[1].state, "cycle")
      t.assert_false(f.module.expand(session, leaf.children[1]))
      t.assert_eq(#f.requests, 4)
      f.module.collapse(session, session.roots[1])
      t.assert_eq(#f.module.rows(session), 1)
      f.module.expand(session, session.roots[1])
      t.assert_eq(#f.module.rows(session), 4)
      t.assert_eq(#f.requests, 4)
    end)
  end)

  t.it("a collapsed pending child cannot write the visible tree", function()
    fixture(function(f)
      local session = f.start("outgoing")
      local root = session.roots[1]
      f.module.expand(session, root)
      f.module.collapse(session, root)
      f.respond(2, nil, { { to = f.item("Late", 18) } })
      t.assert_eq(#root.children, 0)
      t.assert_eq(root.state, "unexpanded")
      t.assert_eq(#f.module.rows(session), 1)
    end)
  end)

  for _, change in ipairs({ "cancel", "target", "edit", "new-root" }) do
    t.it("late child after " .. change .. " cannot update an investigation", function()
      fixture(function(f)
        local session = f.start("outgoing")
        local root = session.roots[1]
        f.module.expand(session, root)
        if change == "cancel" then
          require("utils.ue_goto.reading").cancel()
        elseif change == "target" then
          f.context.state.target_platform = "Android"
        elseif change == "edit" then
          vim.api.nvim_buf_set_lines(f.buf, 0, 1, false, { "new input" })
        else
          f.module.open("base")
        end
        f.respond(2, nil, { { to = f.item("Late", 18) } })
        t.assert_eq(#root.children, 0)
      end)
    end)
  end

  t.it("resume retains the root and expanded branch without another provider request", function()
    fixture(function(f)
      local session = f.start("outgoing")
      f.module.expand(session, session.roots[1])
      f.respond(2, nil, { { to = f.item("Child", 12) } })
      f.picks[1]:close()
      t.assert_true(f.module.resume())
      t.assert_eq(f.module.session(), session)
      t.assert_eq(#f.requests, 2)
      t.assert_eq(#f.picks[2].opts.items, 2)
      vim.api.nvim_buf_set_lines(f.buf, 0, 1, false, { "new input" })
      t.assert_false(f.module.resume())
    end)
  end)

  t.it("an empty relation remains visible and never claims full coverage", function()
    fixture(function(f)
      local session = f.start("base")
      f.module.expand(session, session.roots[1])
      f.respond(2, nil, {})
      t.assert_eq(session.roots[1].state, "empty")
      t.assert_contains(f.module.rows(session)[1].label, "覆盖未知")
      t.assert_eq(#f.picks, 1)
    end)
  end)

  t.it("each collapse cancels its child request and permits only one pending query per node", function()
    fixture(function(f)
      local session = f.start("outgoing")
      local root = session.roots[1]
      for _ = 1, 3 do
        t.assert_true(f.module.expand(session, root))
        t.assert_false(f.module.expand(session, root))
        t.assert_true(f.module.collapse(session, root))
        t.assert_eq(root.state, "unexpanded")
      end
      t.assert_eq(#f.requests, 4)
      t.assert_eq(#f.cancels, 3)
      for index = 2, 4 do
        f.respond(index, nil, { { to = f.item("Late", 18) } })
      end
      t.assert_eq(#root.children, 0)
    end)
  end)

  t.it("close cancels loading children and resume can expand them again", function()
    fixture(function(f)
      local session = f.start("outgoing")
      local root = session.roots[1]
      f.module.expand(session, root)
      f.picks[1]:close()
      t.assert_eq(#f.cancels, 1)
      t.assert_eq(root.state, "unexpanded")
      t.assert_true(f.module.resume())
      t.assert_true(f.module.expand(session, root))
      f.respond(3, nil, { { to = f.item("New child", 12) } })
      f.respond(2, nil, { { to = f.item("Stale child", 18) } })
      t.assert_eq(root.children[1].item.name, "New child")
    end)
  end)

  t.it("native UTF-16 preview resolution does not mutate cached nodes on refresh or pin", function()
    fixture(function(f)
      vim.api.nvim_buf_set_lines(f.buf, 4, 5, false, { "// 中文 Alpha" })
      f.module.open("base")
      local item = f.item("Alpha", 5)
      item.selectionRange.start.character, item.selectionRange["end"].character = 6, 11
      f.respond(1, nil, { item })
      local session = f.module.session()
      local util = dofile(vim.fn.stdpath("data") .. "/lazy/snacks.nvim/lua/snacks/picker/util/init.lua")
      local first = f.module.rows(session)[1]
      util.resolve_loc(first)
      t.assert_eq(first.pos[2], 10)
      t.assert_eq(session.roots[1].row.pos[2], 6)
      t.assert_false(session.roots[1].row.loc.resolved)
      t.assert_eq(session.roots[1].item, item)
      local refreshed = f.module.rows(session)[1]
      t.assert_false(refreshed.loc.resolved)
      util.resolve_loc(refreshed)
      t.assert_eq(refreshed.pos[2], 10)
      t.assert_true(
        require("utils.ue_goto.reading_results").pin(
          session.owner,
          { refreshed },
          { title = "Unicode", source = "clangd" }
        )
      )
      t.assert_eq(f.pins[1][1].col, 11)
    end)
  end)

  for _, moment in ipairs({ "before-expand", "pending", "resume" }) do
    t.it("a changed cached target cannot query or restore a relationship at " .. moment, function()
      fixture(function(f)
        local target = vim.fn.fnamemodify(f.source, ":h") .. "/types.hpp"
        vim.fn.writefile({ "struct Alpha {};" }, target)
        local buf = vim.fn.bufadd(target)
        vim.fn.bufload(buf)
        f.module.open("base")
        local item = f.item("Alpha", 1)
        item.uri = vim.uri_from_bufnr(buf)
        f.respond(1, nil, { item })
        local session, root = f.module.session(), f.module.session().roots[1]
        if moment == "pending" then
          f.module.expand(session, root)
        elseif moment == "resume" then
          f.picks[1]:close()
        end
        vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "struct Renamed {};" })
        if moment == "resume" then
          t.assert_false(f.module.resume())
        elseif moment == "pending" then
          f.respond(2, nil, { f.item("Late target", 12) })
          t.assert_eq(#root.children, 0)
          t.assert_eq(root.state, "stale")
        else
          t.assert_false(f.module.expand(session, root))
          t.assert_eq(#f.requests, 1)
          t.assert_eq(root.state, "stale")
        end
      end)
    end)
  end
end)
