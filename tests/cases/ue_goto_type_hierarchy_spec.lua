local t = require("tests.harness")
t.bootstrap()

local function fixture(run)
  local old_clients, old_notify, old_snacks = vim.lsp.get_clients, vim.notify, _G.Snacks
  local original_win, original_buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(original_win, buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "class Derived {};" })
  vim.api.nvim_win_set_cursor(original_win, { 1, 0 })
  local f = { requests = {}, picks = {}, messages = {}, buf = buf, win = original_win }
  f.client = {
    id = 23,
    name = "clangd",
    offset_encoding = "utf-16",
    supports_method = function(_, method, requested_buf)
      t.assert_eq(method, "textDocument/prepareTypeHierarchy")
      t.assert_eq(requested_buf, buf)
      return true
    end,
    request = function(client, method, params, callback, requested_buf)
      f.requests[#f.requests + 1] = {
        client = client, method = method, params = params, callback = callback, buf = requested_buf,
      }
      return true, #f.requests
    end,
  }
  f.clients = { f.client }
  vim.lsp.get_clients = function(opts)
    t.assert_eq(opts.bufnr, buf)
    return f.clients
  end
  vim.notify = function(message) f.messages[#f.messages + 1] = message end
  _G.Snacks = { picker = {
    pick = function(opts)
      local picker = { opts = opts, closed = false, main = original_win }
      function picker:close()
        self.closed = true
        vim.api.nvim_set_current_win(original_win)
      end
      f.picks[#f.picks + 1] = picker
      return picker
    end,
    actions = { jump = function(picker, row)
      f.jumped = row
      picker:close()
    end },
  } }
  package.loaded["utils.ue_goto.type_hierarchy"] = nil
  f.module = require("utils.ue_goto.type_hierarchy")
  function f.item(name, data)
    return {
      name = name,
      uri = vim.uri_from_bufnr(buf),
      kind = 5,
      range = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 18 } },
      selectionRange = { start = { line = 0, character = 6 }, ["end"] = { line = 0, character = 13 } },
      data = data,
    }
  end
  function f.respond(index, err, result)
    f.requests[index].callback(err, result)
    vim.wait(25, function() return false end, 5)
  end
  local ok, err = xpcall(function() run(f) end, debug.traceback)
  vim.lsp.get_clients, vim.notify, _G.Snacks = old_clients, old_notify, old_snacks
  package.loaded["utils.ue_goto.type_hierarchy"] = nil
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if win ~= original_win then pcall(vim.api.nvim_win_close, win, true) end
  end
  if vim.api.nvim_win_is_valid(original_win) then
    vim.api.nvim_set_current_win(original_win)
    vim.api.nvim_win_set_buf(original_win, original_buf)
  end
  pcall(vim.api.nvim_buf_delete, buf, { force = true })
  if not ok then error(err) end
end

t.describe("ue_goto type hierarchy", function()
  for _, kind in ipairs({ "supertypes", "subtypes" }) do
    t.it(kind .. " follows prepare asynchronously and preserves client/item.data", function()
      fixture(function(f)
        t.assert_true(f.module[kind]())
        t.assert_eq(#f.requests, 1)
        t.assert_eq(f.requests[1].method, "textDocument/prepareTypeHierarchy")
        t.assert_eq(f.requests[1].buf, f.buf)
        t.assert_eq(f.requests[1].params.position.character, 0)
        local data = { opaque = "server-owned", nested = { 17, 23 } }
        local root = f.item("Derived", data)
        f.respond(1, nil, { root })
        t.assert_eq(#f.requests, 2)
        t.assert_eq(f.requests[2].method, "typeHierarchy/" .. kind)
        t.assert_eq(f.requests[2].client, f.client)
        t.assert_eq(f.requests[2].params.item, root)
        t.assert_eq(f.requests[2].params.item.data, data)
        local target = f.item("Base")
        f.respond(2, nil, { target })
        t.assert_eq(#f.picks, 1)
        local row = f.picks[1].opts.items[1]
        t.assert_eq(row.name, "Base")
        t.assert_eq(row.loc.range.start.character, 6)
        t.assert_eq(row.loc.encoding, "utf-16")
        f.picks[1].opts.confirm(f.picks[1], row)
        t.assert_eq(f.jumped, row)
      end)
    end)
  end

  t.it("multiple prepared types require explicit root selection", function()
    fixture(function(f)
      f.module.subtypes()
      local a, b = f.item("A", { identity = "A" }), f.item("B", { identity = "B" })
      f.respond(1, nil, { a, b })
      t.assert_eq(#f.requests, 1)
      t.assert_eq(#f.picks, 1)
      t.assert_eq(#f.picks[1].opts.items, 2)
      f.picks[1].opts.confirm(f.picks[1], f.picks[1].opts.items[2])
      vim.wait(25, function() return #f.requests == 2 end, 5)
      t.assert_eq(f.requests[2].params.item, b)
      t.assert_nil(f.jumped)
    end)
  end)

  t.it("multiple clangd clients require a choice and bind the chosen client", function()
    fixture(function(f)
      local second = vim.tbl_extend("force", f.client, { id = 37 })
      f.clients[2] = second
      f.module.supertypes()
      t.assert_eq(#f.requests, 0)
      t.assert_eq(f.picks[1].opts.format, "text")
      f.picks[1].opts.confirm(f.picks[1], f.picks[1].opts.items[2])
      vim.wait(25, function() return #f.requests == 1 end, 5)
      t.assert_eq(f.requests[1].client, second)
    end)
  end)

  t.it("unsupported clangd and non-clangd clients never send requests", function()
    fixture(function(f)
      f.client.supports_method = function() return false end
      t.assert_false(f.module.supertypes())
      f.client.name = "another-lsp"
      t.assert_false(f.module.subtypes())
      t.assert_eq(#f.requests, 0)
      t.assert_eq(#f.messages, 2)
    end)
  end)

  for _, failure in ipairs({ "empty-prepare", "empty-results", "prepare-error", "results-error", "send-failure" }) do
    t.it(failure .. " reports failure without opening a picker", function()
      fixture(function(f)
        if failure == "send-failure" then f.client.request = function() return false end end
        f.module.supertypes()
        if failure == "empty-prepare" then
          f.respond(1, nil, nil)
        elseif failure == "prepare-error" then
          f.respond(1, { message = "provider failed" })
        elseif failure ~= "send-failure" then
          f.respond(1, nil, { f.item("Derived") })
          f.respond(2, failure == "results-error" and { message = "provider failed" } or nil, {})
        end
        t.assert_eq(#f.picks, 0)
        t.assert_eq(#f.messages, 1)
      end)
    end)
  end

  for _, stale in ipairs({ "edit", "cursor", "window", "buffer", "detach", "new-request" }) do
    t.it("stale " .. stale .. " response has no picker or notification side effects", function()
      fixture(function(f)
        f.module.subtypes()
        f.respond(1, nil, { f.item("Derived") })
        if stale == "edit" then
          vim.api.nvim_buf_set_lines(f.buf, 0, -1, false, { "class Changed {};" })
        elseif stale == "cursor" then
          vim.api.nvim_win_set_cursor(f.win, { 1, 2 })
        elseif stale == "window" then
          vim.cmd("vsplit")
        elseif stale == "buffer" then
          vim.api.nvim_win_set_buf(f.win, vim.api.nvim_create_buf(false, true))
        elseif stale == "detach" then
          f.clients = {}
        else
          f.module.supertypes()
        end
        f.respond(2, nil, { f.item("Child") })
        t.assert_eq(#f.picks, 0)
        t.assert_eq(#f.messages, 0)
      end)
    end)
  end

  t.it("an edited root cannot submit a delayed picker selection", function()
    fixture(function(f)
      f.module.subtypes()
      f.respond(1, nil, { f.item("A"), f.item("B") })
      vim.api.nvim_buf_set_lines(f.buf, 0, -1, false, { "class Changed {};" })
      f.picks[1].opts.confirm(f.picks[1], f.picks[1].opts.items[2])
      vim.wait(25, function() return false end, 5)
      t.assert_eq(#f.requests, 1)
      t.assert_true(f.picks[1].closed)
    end)
  end)

  t.it("a result picker cannot jump from an unrelated active window", function()
    fixture(function(f)
      f.module.subtypes()
      f.respond(1, nil, { f.item("Derived") })
      f.respond(2, nil, { f.item("Leaf") })
      vim.cmd("vsplit")
      f.picks[1].opts.confirm(f.picks[1], f.picks[1].opts.items[1])
      t.assert_nil(f.jumped)
      t.assert_true(f.picks[1].closed)
    end)
  end)

  t.it("request position converts a multibyte cursor to the client's encoding", function()
    fixture(function(f)
      vim.api.nvim_buf_set_lines(f.buf, 0, -1, false, { "前😀 Derived" })
      vim.api.nvim_win_set_cursor(f.win, { 1, 8 })
      f.module.supertypes()
      t.assert_eq(f.requests[1].params.position.character, 4)
    end)
  end)

  local util_path = vim.fn.stdpath("data") .. "/lazy/snacks.nvim/lua/snacks/picker/util/init.lua"
  if vim.fn.filereadable(util_path) == 1 then
    t.it("installed Snacks resolves selectionRange utf-16 columns to bytes", function()
      fixture(function(f)
        vim.api.nvim_buf_set_lines(f.buf, 0, -1, false, { "前😀 Derived" })
        local item = f.item("Derived")
        item.selectionRange = { start = { line = 0, character = 4 }, ["end"] = { line = 0, character = 11 } }
        local row = f.module.items({ item }, "utf-16")[1]
        row.buf = f.buf
        dofile(util_path).resolve_loc(row)
        t.assert_eq(row.pos[2], 8)
        t.assert_eq(row.end_pos[2], 15)
        t.assert_eq(item.selectionRange.start.character, 4)
      end)
    end)
  else
    t.skip("installed Snacks Unicode resolution", "Snacks is not installed on this host")
  end
end)

local clangd = require("utils.platform").resolve_tool({
  name = "clangd", env = { "UE_CLANGD" },
  driver_candidates = function(driver) return driver.default_clangd_candidates() end,
})
if not clangd.ok then
  t.skip("native clangd standard type hierarchy", "clangd is unavailable", { native = true })
else
  t.describe("ue_goto native type hierarchy", function()
    t.it("real clangd prepares Derived and returns Base/Leaf over standard methods", function()
      local dir = vim.fn.tempname()
      vim.fn.mkdir(dir, "p")
      local path = dir .. "/hierarchy.cpp"
      vim.fn.writefile({ "class Base {};", "class Derived : public Base {};", "class Leaf : public Derived {};" }, path)
      local original_buf = vim.api.nvim_get_current_buf()
      vim.cmd.edit(vim.fn.fnameescape(path))
      local buf = vim.api.nvim_get_current_buf()
      vim.bo[buf].filetype = "cpp"
      vim.api.nvim_win_set_cursor(0, { 2, 6 })
      -- Foreground bounded test client; background workspace indexing is disabled.
      local id = vim.lsp.start_client({ name = "clangd", root_dir = dir,
        cmd = { clangd.path, "--background-index=false", "--clang-tidy=false", "--pch-storage=memory" },
      })
      local ok, err = xpcall(function()
        t.assert_true(id)
        vim.lsp.buf_attach_client(buf, id)
        local client = vim.lsp.get_client_by_id(id)
        t.assert_true(vim.wait(10000, function() return client.initialized end, 10))
        t.assert_true(client:supports_method("textDocument/prepareTypeHierarchy", buf))
        local function ask(method, params)
          local done, error_response, result = false, nil, nil
          t.assert_true(client:request(method, params, function(e, r)
            done, error_response, result = true, e, r
          end, buf))
          t.assert_true(vim.wait(10000, function() return done end, 10), method .. " timed out")
          t.assert_nil(error_response)
          return result
        end
        local roots = ask("textDocument/prepareTypeHierarchy",
          vim.lsp.util.make_position_params(0, client.offset_encoding))
        t.assert_eq(#roots, 1)
        t.assert_eq(roots[1].name, "Derived")
        t.assert_eq(ask("typeHierarchy/supertypes", { item = roots[1] })[1].name, "Base")
        t.assert_eq(ask("typeHierarchy/subtypes", { item = roots[1] })[1].name, "Leaf")
      end, debug.traceback)
      if id then vim.lsp.stop_client(id) end
      vim.api.nvim_set_current_buf(original_buf)
      vim.api.nvim_buf_delete(buf, { force = true })
      vim.fn.delete(dir, "rf")
      if not ok then error(err) end
    end)
  end)
end
