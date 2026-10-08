local t = require("tests.harness")
local cfg = t.bootstrap()

local function fixture(body)
  local root = vim.fn.tempname():gsub("\\", "/")
  vim.fn.mkdir(root, "p")
  local source, target = root .. "/origin.cpp", root .. "/origin.hpp"
  vim.fn.writefile({ "int call() { return selected(); }" }, source)
  vim.fn.writefile({ "int selected();" }, target)
  local original_win, original_buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
  local old_clients, old_notify, old_snacks = vim.lsp.get_clients, vim.notify, _G.Snacks
  local old_ue = package.loaded.ue
  local old_commands = package.loaded["ue.clangd_commands"]
  local old_context = package.loaded["utils.ue_goto.reading_context"]
  local old_hidden = vim.o.hidden
  local old_buffers = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    old_buffers[buf] = true
  end
  local f = { source = source, target = target, root = root, requests = {}, picks = {}, messages = {}, preparations = {} }
  vim.o.hidden = true
  vim.api.nvim_set_current_buf(vim.api.nvim_create_buf(true, false))
  vim.cmd.edit(vim.fn.fnameescape(source))
  f.win, f.buf, f.tab =
    vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_tabpage()
  vim.bo.filetype = "cpp"
  vim.api.nvim_win_set_cursor(f.win, { 1, 20 })
  f.context = {
    engine_root = root,
    project_root = root,
    state = { target_platform = "Win64", target_configuration = "Test" },
    paths = { active_cdb = root .. "/compile_commands.json" },
  }
  f.client = {
    id = 981,
    name = "clangd",
    offset_encoding = "utf-16",
    config = { root_dir = root },
    supports_method = function()
      return true
    end,
    cancel_request = function() end,
    request = function(client, method, params, callback, buf)
      f.requests[#f.requests + 1] =
        { client = client, method = method, params = params, callback = callback, buf = buf }
      return true, #f.requests
    end,
  }
  f.clients = { f.client }
  vim.lsp.get_clients = function(opts)
    if not opts or not opts.bufnr or opts.bufnr == f.buf or opts.bufnr == 0 then
      return f.clients
    end
    return {}
  end
  vim.notify = function(message)
    f.messages[#f.messages + 1] = message
  end
  package.loaded.ue = {
    resolve_context = function()
      return f.context
    end,
  }
  package.loaded["ue.clangd_commands"] = {
    ensure = function(_, _, callback, opts)
      f.preparations[#f.preparations + 1] = opts
      callback(true, nil, { workingDirectory = root, compilationCommand = { "clang++", "-c", source } })
    end,
  }
  _G.Snacks = {
    picker = {
      pick = function(opts)
        local picker = { opts = opts, main = f.win, closed = false }
        function picker:close()
          self.closed = true
        end
        function picker:current_win()
          return nil
        end
        function picker:current()
          return self.opts.items[1]
        end
        f.picks[#f.picks + 1] = picker
        return picker
      end,
    },
  }
  function f.respond(index, err, value)
    f.requests[index].callback(err, value)
    vim.wait(30, function()
      return false
    end, 5)
  end
  function f.loc()
    return {
      uri = vim.uri_from_fname(target),
      range = { start = { line = 0, character = 4 }, ["end"] = { line = 0, character = 12 } },
    }
  end
  local ok, err = xpcall(function()
    body(f)
  end, debug.traceback)
  local reading = package.loaded["utils.ue_goto.reading"]
  if reading and reading.cancel then
    reading.cancel()
  end
  vim.lsp.get_clients, vim.notify, _G.Snacks = old_clients, old_notify, old_snacks
  package.loaded.ue = old_ue
  package.loaded["ue.clangd_commands"] = old_commands
  package.loaded["utils.ue_goto.reading_context"] = old_context
  vim.o.hidden = old_hidden
  for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
    if tab ~= f.tab then
      local windows = vim.api.nvim_tabpage_list_wins(tab)
      if tab ~= vim.api.nvim_win_get_tabpage(original_win) then
        for _, win in ipairs(windows) do
          pcall(vim.api.nvim_win_close, win, true)
        end
      end
    end
  end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(f.tab)) do
    if win ~= original_win then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
  if vim.api.nvim_win_is_valid(original_win) then
    vim.api.nvim_set_current_win(original_win)
    vim.api.nvim_win_set_buf(original_win, original_buf)
  end
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if not old_buffers[buf] then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end
  vim.fn.delete(root, "rf")
  if not ok then
    error(err)
  end
end

local function header(f)
  vim.cmd.edit(vim.fn.fnameescape(f.target))
  f.buf = vim.api.nvim_get_current_buf()
  vim.bo.filetype = "cpp"
  vim.api.nvim_win_set_cursor(f.win, { 1, 4 })
end

t.describe("ue_goto reading ownership", function()
  t.it("the existing references entry rejects a response after leaving its source window", function()
    fixture(function(f)
      vim.fn.setqflist(
        {},
        " ",
        { title = "Build owner", items = { { filename = f.source, lnum = 1, text = "old error" } } }
      )
      local qf = vim.fn.getqflist({ id = 0, items = 1, title = 1 })
      local compat = require("utils.ue_goto.compat_navigation").install({ dtrace = function() end })
      compat.references()
      vim.cmd.vsplit()
      local other_win = vim.api.nvim_get_current_win()
      local other_buf = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_win_set_buf(other_win, other_buf)
      vim.api.nvim_buf_set_lines(other_buf, 0, -1, false, { "new unrelated input" })
      f.respond(1, nil, { f.loc() })
      t.assert_eq(vim.api.nvim_get_current_win(), other_win)
      t.assert_eq(vim.fn.getqflist({ id = 0 }).id, qf.id)
      t.assert_eq(#f.picks, 0)
      t.assert_true(vim.bo[other_buf].modified)
      compat.dispose()
      pcall(vim.api.nvim_buf_delete, other_buf, { force = true })
    end)
  end)

  t.it("the source/header key rejects a response after switching tabs", function()
    fixture(function(f)
      local upstream = dofile(vim.fn.stdpath("data") .. "/lazy/nvim-lspconfig/lsp/clangd.lua")
      upstream.on_attach(f.client, f.buf)
      local opts = { servers = {} }
      require("plugins.ue")[2].opts(nil, opts)
      local action
      for _, key in ipairs(opts.servers.clangd.keys) do
        if key[1] == "<leader>ch" then
          action = key[2]
        end
      end
      if type(action) == "function" then
        action()
      else
        vim.cmd("LspClangdSwitchSourceHeader")
      end
      vim.cmd.tabnew()
      local other_win, other_buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
      vim.api.nvim_buf_set_lines(other_buf, 0, -1, false, { "unsaved other tab" })
      f.respond(1, nil, vim.uri_from_fname(f.target))
      t.assert_eq(vim.api.nvim_get_current_win(), other_win)
      t.assert_eq(vim.api.nvim_get_current_buf(), other_buf)
      t.assert_true(vim.bo[other_buf].modified)
    end)
  end)

  for _, change in ipairs({ "cursor", "edit", "rename", "target", "detach", "replace-client", "cancel" }) do
    t.it("references reject late " .. change .. " without replacing the current build list", function()
      fixture(function(f)
        local reading = require("utils.ue_goto.reading")
        vim.fn.setqflist(
          {},
          " ",
          { title = "Build owner", items = { { filename = f.source, lnum = 1, text = "old error" } } }
        )
        local id = vim.fn.getqflist({ id = 0 }).id
        t.assert_true(reading.references())
        t.assert_eq(f.requests[1].params.textDocument.uri, vim.uri_from_bufnr(f.buf))
        t.assert_eq(f.requests[1].params.context.includeDeclaration, true)
        if change == "cursor" then
          vim.api.nvim_win_set_cursor(f.win, { 1, 0 })
        elseif change == "edit" then
          vim.api.nvim_buf_set_lines(f.buf, 0, -1, false, { "new input" })
        elseif change == "rename" then
          vim.api.nvim_buf_set_name(f.buf, f.root .. "/renamed.cpp")
        elseif change == "target" then
          f.context.state.target_configuration = "Development"
        elseif change == "detach" then
          f.clients = {}
        elseif change == "replace-client" then
          f.clients = { vim.tbl_extend("force", f.client, { config = {} }) }
        else
          reading.cancel()
        end
        f.respond(1, nil, { f.loc() })
        t.assert_eq(#f.picks, 0)
        t.assert_eq(vim.fn.getqflist({ id = 0 }).id, id)
        t.assert_eq(#f.messages, 0)
      end)
    end)
  end

  t.it("normal references preview even one result, without qf or source cursor changes", function()
    fixture(function(f)
      local reading = require("utils.ue_goto.reading")
      local cursor, id = vim.api.nvim_win_get_cursor(f.win), vim.fn.getqflist({ id = 0 }).id
      t.assert_true(reading.references())
      f.respond(1, nil, { f.loc() })
      t.assert_eq(#f.picks, 1)
      t.assert_eq(f.picks[1].opts.auto_confirm, false)
      t.assert_eq(f.picks[1].opts.layout.preset, "telescope")
      t.assert_true(vim.deep_equal(vim.api.nvim_win_get_cursor(f.win), cursor))
      t.assert_eq(vim.fn.getqflist({ id = 0 }).id, id)
      t.assert_contains(f.picks[1].opts.title, "覆盖未知")
      reading.cancel()
      t.assert_true(f.picks[1].closed)
    end)
  end)

  t.it("a second reading intent wins even when the first response is delivered last", function()
    fixture(function(f)
      local reading = require("utils.ue_goto.reading")
      reading.references()
      reading.references()
      f.respond(2, nil, { f.loc() })
      f.respond(1, nil, { f.loc() })
      t.assert_eq(#f.picks, 1)
    end)
  end)

  t.it("the LSP-empty to GTAGS chain freezes context and rejects late text results", function()
    fixture(function(f)
      local on_gtags, options
      package.loaded.ue.gtags_references_async = function(_, callback, opts)
        on_gtags, options = callback, opts
      end
      require("utils.ue_goto.reading").references()
      f.respond(1, nil, {})
      t.assert_type(on_gtags, "function")
      t.assert_true(options.collect)
      t.assert_eq(options.context.project_root, f.context.project_root)
      t.assert_true(options.is_current())
      vim.cmd.tabnew()
      local win, buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "new input" })
      t.assert_false(options.is_current())
      on_gtags(true, { { filename = f.target, lnum = 1, col = 5, text = "selected" } })
      t.assert_eq(#f.picks, 0)
      t.assert_eq(vim.api.nvim_get_current_win(), win)
      t.assert_true(vim.bo[buf].modified)
    end)
  end)

  for _, change in ipairs({ "cursor", "edit", "target", "detach", "cancel" }) do
    t.it("header switch rejects " .. change .. " before any jump", function()
      fixture(function(f)
        local reading = require("utils.ue_goto.reading")
        t.assert_true(reading.source_header())
        t.assert_eq(f.requests[1].params.uri, vim.uri_from_bufnr(f.buf))
        if change == "cursor" then
          vim.api.nvim_win_set_cursor(f.win, { 1, 0 })
        elseif change == "edit" then
          vim.api.nvim_buf_set_lines(f.buf, 0, -1, false, { "new input" })
        elseif change == "target" then
          f.context.state.target_platform = "Android"
        elseif change == "detach" then
          f.clients = {}
        else
          reading.cancel()
        end
        local cursor, jumps = vim.api.nvim_win_get_cursor(f.win), vim.fn.getjumplist()
        f.respond(1, nil, vim.uri_from_fname(f.target))
        t.assert_eq(vim.api.nvim_win_get_buf(f.win), f.buf)
        t.assert_true(vim.deep_equal(vim.api.nvim_win_get_cursor(f.win), cursor))
        t.assert_true(vim.deep_equal(vim.fn.getjumplist(), jumps))
      end)
    end)
  end

  t.it("header switching opens only the provider file and supports explicit investigation return", function()
    fixture(function(f)
      local reading = require("utils.ue_goto.reading")
      local cursor = vim.api.nvim_win_get_cursor(f.win)
      t.assert_true(reading.source_header())
      f.respond(1, nil, vim.uri_from_fname(f.target))
      t.assert_eq(vim.fs.normalize(vim.api.nvim_buf_get_name(0)), vim.fs.normalize(f.target))
      t.assert_true(reading.return_to_origin())
      t.assert_eq(vim.api.nvim_get_current_buf(), f.buf)
      t.assert_true(vim.deep_equal(vim.api.nvim_win_get_cursor(f.win), cursor))
    end)
  end)

  t.it("header references prepare the compiler-proven donor and expose its provenance", function()
    fixture(function(f)
      header(f)
      local donor = f.root .. "/different-origin.cpp"
      local proof = { context = { origin_tu = donor, compile = { file = donor }, id = "native-context",
        evidence_kind = "clang-d-rsp-unity" }, compile_digest = "native-command" }
      package.loaded["utils.ue_goto.reading_context"] = {
        resolve_header = function(owner, _, callback)
          t.assert_eq(owner.path, vim.api.nvim_buf_get_name(f.buf))
          callback(proof)
        end,
      }
      local reading = require("utils.ue_goto.reading")
      t.assert_true(reading.references())
      t.assert_eq(f.preparations[1].proven_header, proof)
      t.assert_eq(f.requests[1].params.textDocument.uri, vim.uri_from_bufnr(f.buf))
      f.respond(1, nil, { f.loc() })
      t.assert_eq(#f.picks, 1)
      local explanation = table.concat(reading.explain_lines(), "\n")
      t.assert_contains(explanation, "different-origin.cpp")
      t.assert_contains(explanation, "clang-d-rsp-unity")
      t.assert_contains(explanation, "state=resolved")
      t.assert_false(explanation:find(f.root, 1, true) ~= nil, "Explain must not leak the fixture root")
    end)
  end)

  for _, failure in ipairs({ "no-proven-context", "invalid-query-file-not-in-tu", "compile-command-missing", "empty" }) do
    t.it("header references do not replace " .. failure .. " with text-index success", function()
      fixture(function(f)
        header(f)
        local fallback = 0
        package.loaded.ue.gtags_references_async = function() fallback = fallback + 1 end
        package.loaded["utils.ue_goto.reading_context"] = {
          resolve_header = function(_, _, callback)
            if failure == "no-proven-context" or failure == "invalid-query-file-not-in-tu" then
              callback(nil, { state = "unavailable", reason = failure })
            else
              callback({ context = { origin_tu = f.source, compile = { file = f.source } } })
            end
          end,
        }
        if failure == "compile-command-missing" then
          package.loaded["ue.clangd_commands"].ensure = function(_, _, callback)
            callback(false, "compile-command-missing")
          end
        end
        local reading = require("utils.ue_goto.reading")
        reading.references()
        if failure == "empty" then f.respond(1, nil, {}) end
        vim.wait(40, function() return #f.messages > 0 end, 5)
        t.assert_eq(fallback, 0)
        t.assert_eq(#f.picks, 0)
        t.assert_eq(#f.messages, 1)
        t.assert_contains(table.concat(reading.explain_lines(), "\n"), failure)
      end)
    end)
  end

  t.it("late header donor discovery cannot prepare or present references", function()
    fixture(function(f)
      header(f)
      local complete
      package.loaded["utils.ue_goto.reading_context"] = {
        resolve_header = function(_, _, callback) complete = callback end,
      }
      require("utils.ue_goto.reading").references()
      vim.api.nvim_buf_set_lines(f.buf, 0, -1, false, { "new header input" })
      complete({ context = { origin_tu = f.source, compile = { file = f.source } } })
      t.assert_eq(#f.preparations, 0)
      t.assert_eq(#f.requests, 0)
      t.assert_eq(#f.picks, 0)
      t.assert_eq(#f.messages, 0)
    end)
  end)

  for _, target_name in ipairs({ "origin.gen.cpp", "ObjectMacros.h", "Class.h" }) do
    t.it("header switching rejects raw provider target " .. target_name, function()
      fixture(function(f)
        header(f)
        local destination = f.root .. "/" .. target_name
        vim.fn.writefile({ "int unrelated;" }, destination)
        local proofs = 0
        package.loaded["utils.ue_goto.reading_context"] = {
          prove_companion = function() proofs = proofs + 1 end,
        }
        require("utils.ue_goto.reading").source_header()
        f.respond(1, nil, vim.uri_from_fname(destination))
        t.assert_eq(vim.api.nvim_get_current_buf(), f.buf)
        t.assert_eq(proofs, 0, "same-kind and generated candidates must be rejected before inclusion work")
        t.assert_eq(#f.messages, 1)
      end)
    end)
  end

  for _, proven in ipairs({ false, true }) do
    t.it("non-basename companion requires native inclusion proof: " .. tostring(proven), function()
      fixture(function(f)
        header(f)
        local destination = f.root .. "/UnrealMath.cpp"
        vim.fn.writefile({ "int unrelated;" }, destination)
        local complete
        package.loaded["utils.ue_goto.reading_context"] = {
          prove_companion = function(owner, source, subject, callback)
            t.assert_eq(owner.buf, f.buf)
            t.assert_eq(source, destination)
            t.assert_eq(subject, vim.api.nvim_buf_get_name(f.buf))
            complete = callback
          end,
        }
        require("utils.ue_goto.reading").source_header()
        f.respond(1, nil, vim.uri_from_fname(destination))
        t.assert_eq(vim.api.nvim_get_current_buf(), f.buf)
        t.assert_type(complete, "function")
        complete(proven, proven and "compiler-inclusion" or "invalid-query-file-not-in-tu")
        if proven then
          t.assert_eq(vim.fs.normalize(vim.api.nvim_buf_get_name(0)), vim.fs.normalize(destination))
        else
          t.assert_eq(vim.api.nvim_get_current_buf(), f.buf)
          t.assert_eq(#f.messages, 1)
        end
      end)
    end)
  end

  for _, count in ipairs({ 1, 2 }) do
    t.it("known CDB companion count " .. count .. " overrides clangd without guessing among duplicates", function()
      fixture(function(f)
        header(f)
        vim.fn.writefile({ "[]" }, f.context.paths.active_cdb)
        local paths = { f.source }
        if count == 2 then
          vim.fn.mkdir(f.root .. "/Other", "p")
          local duplicate = f.root .. "/Other/origin.cpp"
          vim.fn.writefile({ "int other;" }, duplicate)
          paths[#paths + 1] = duplicate
        end
        package.loaded["ue.clangd_commands"].find_companion = function(_, _, callback, opts)
          t.assert_true(opts.is_current())
          callback(paths)
        end
        require("utils.ue_goto.reading").source_header()
        t.assert_eq(#f.requests, 0, "the known source should not depend on raw switchSourceHeader")
        if count == 1 then
          t.assert_eq(vim.fs.normalize(vim.api.nvim_buf_get_name(0)), vim.fs.normalize(f.source))
        else
          t.assert_eq(vim.api.nvim_get_current_buf(), f.buf)
          t.assert_eq(#f.picks, 1)
          t.assert_eq(#f.picks[1].opts.items, 2)
          t.assert_false(f.picks[1].opts.auto_confirm)
        end
      end)
    end)
  end

  for _, value in ipairs({ "", "https://invalid.example/file", "file:///missing-own-fixture.hpp" }) do
    t.it("header result " .. value .. " fails closed", function()
      fixture(function(f)
        require("utils.ue_goto.reading").source_header()
        f.respond(1, nil, value)
        t.assert_eq(vim.api.nvim_get_current_buf(), f.buf)
        t.assert_eq(#f.picks, 0)
        t.assert_eq(#f.messages, 1)
      end)
    end)
  end

  t.it("explicit declaration Peek keeps a single result until confirmation", function()
    fixture(function(f)
      local reading = require("utils.ue_goto.reading")
      t.assert_true(reading.peek("declaration"))
      f.respond(1, nil, { f.loc() })
      t.assert_eq(#f.picks, 1)
      t.assert_eq(vim.api.nvim_get_current_buf(), f.buf)
      f.picks[1].opts.confirm(f.picks[1], f.picks[1].opts.items[1])
      t.assert_eq(vim.fs.normalize(vim.api.nvim_buf_get_name(0)), vim.fs.normalize(f.target))
      t.assert_true(vim.deep_equal(vim.api.nvim_win_get_cursor(0), { 1, 4 }))
    end)
  end)

  for _, change in ipairs({ "source-edit", "target-edit", "new-intent", "proof-stale", "close-error" }) do
    t.it("confirmation rejects " .. change .. " during the owned picker close", function()
      fixture(function(f)
        local ownership = require("utils.ue_goto.reading_owner")
        local results = require("utils.ue_goto.reading_results")
        local target_buf = vim.fn.bufadd(f.target)
        vim.fn.bufload(target_buf)
        local owner = ownership.begin()
        local row = results.items({ f.loc() })[1]
        local proof_current = true
        if change == "proof-stale" then
          row.proof_is_current = function()
            return proof_current
          end
        end
        t.assert_true(ownership.current(owner, true))
        t.assert_eq(vim.fs.normalize(vim.api.nvim_buf_get_name(target_buf)), vim.fs.normalize(row.file))
        local jumps = vim.fn.getjumplist()
        owner.picker = {
          main = f.win,
          closed = false,
          current_win = function()
            return nil
          end,
          close = function(picker)
            picker.was_closed = true
            picker.closed = true
            if change == "source-edit" then
              vim.api.nvim_buf_set_lines(f.buf, 0, 1, false, { "new source input during close" })
            elseif change == "target-edit" then
              vim.api.nvim_buf_set_lines(target_buf, 0, 1, false, { "new target input during close" })
            elseif change == "new-intent" then
              ownership.begin()
            elseif change == "proof-stale" then
              proof_current = false
            else
              error("controlled picker close error")
            end
          end,
        }
        local ok, jumped = pcall(results.jump, owner, row)
        t.assert_true(owner.picker == nil or owner.picker.was_closed)
        t.assert_true(ok)
        t.assert_false(jumped)
        t.assert_eq(vim.api.nvim_win_get_buf(f.win), f.buf)
        t.assert_true(vim.deep_equal(vim.fn.getjumplist(), jumps))
        if change == "source-edit" then
          t.assert_true(vim.bo[f.buf].modified)
        end
        if change == "target-edit" then
          t.assert_true(vim.bo[target_buf].modified)
        end
        if change == "new-intent" then
          t.assert_true(ownership.active() ~= owner)
        end
      end)
    end)
  end

  for _, extension in ipairs({ "CPP", "H" }) do
    t.it("uppercase " .. extension .. " definition Peek still enters the compiler route", function()
      fixture(function(f)
        local semantic = require("utils.ue_goto.semantic_navigation")
        local old_install, route = semantic.install, nil
        semantic.install = function()
          return {
            cpp_definition = function(_, _, _, ext)
              route = ext
            end,
          }
        end
        vim.api.nvim_buf_set_name(f.buf, f.root .. "/Alpha." .. extension)
        local ok, err = pcall(require("utils.ue_goto.reading").peek, "definition")
        semantic.install = old_install
        t.assert_true(ok, err)
        t.assert_eq(route, extension:lower())
        t.assert_eq(#f.requests, 0)
      end)
    end)
  end

  for _, intent in ipairs({ "confirm", "leave", "cancel" }) do
    t.it("an owned native context window preserves semantic scope only for " .. intent, function()
      fixture(function(f)
        local ownership = require("utils.ue_goto.reading_owner")
        local reading, semantic = require("utils.ue_goto.reading"), require("utils.ue_goto.semantic_client")
        local owner = ownership.begin()
        local snapshot = semantic.begin_action(f.buf, {
          is_current = function()
            return ownership.current(owner, true)
          end,
        })
        _G.Snacks.picker.pick = function(opts)
          local buf = vim.api.nvim_create_buf(false, true)
          local win =
            vim.api.nvim_open_win(buf, true, { relative = "editor", row = 1, col = 1, width = 30, height = 3 })
          local picker = { opts = opts, main = f.win, closed = false }
          function picker:current_win()
            return not self.closed and vim.api.nvim_get_current_win() == win and win or nil
          end
          function picker:close()
            if self.closed then
              return
            end
            self.closed = true
            vim.api.nvim_win_close(win, true)
            if self.opts.on_close then
              self.opts.on_close()
            end
          end
          f.picks[#f.picks + 1] = picker
          return picker
        end
        local contexts = {
          { label = "Context One", origin_tu = f.source, data = { "opaque" } },
          { label = "Context Two", origin_tu = f.source },
        }
        local selected
        t.assert_true(reading.choose_context(owner, contexts, function(choice)
          selected = choice
        end))
        t.assert_true(ownership.current(owner, true))
        t.assert_true(semantic.snapshot_is_current(snapshot))
        if intent == "leave" then
          vim.cmd.tabnew()
        elseif intent == "cancel" then
          f.picks[1]:close()
        end
        f.picks[1].opts.confirm(f.picks[1], f.picks[1].opts.items[1])
        vim.wait(30, function()
          return selected ~= nil
        end, 5)
        if intent == "confirm" then
          t.assert_eq(selected, contexts[1])
          t.assert_true(semantic.snapshot_is_current(snapshot))
          t.assert_eq(vim.api.nvim_get_current_win(), f.win)
          vim.api.nvim_exec_autocmds("CursorMoved", { buffer = f.buf })
          t.assert_true(semantic.snapshot_is_current(snapshot))
          vim.api.nvim_win_set_cursor(f.win, { 1, 0 })
          vim.api.nvim_exec_autocmds("CursorMoved", { buffer = f.buf })
          t.assert_false(semantic.snapshot_is_current(snapshot))
        else
          t.assert_eq(selected, nil)
          t.assert_false(semantic.snapshot_is_current(snapshot))
        end
      end)
    end)
  end

  t.it("explicit return refuses an investigation origin window reused for dirty work", function()
    fixture(function(f)
      local ownership = require("utils.ue_goto.reading_owner")
      local results = require("utils.ue_goto.reading_results")
      local owner = ownership.begin()
      t.assert_true(results.jump(owner, results.items({ f.loc() })[1], "vsplit"))
      local destination = vim.api.nvim_get_current_win()
      local other = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_lines(other, 0, -1, false, { "new work in origin window" })
      vim.api.nvim_win_set_buf(f.win, other)
      t.assert_false(results.return_to_origin())
      t.assert_eq(vim.api.nvim_get_current_win(), destination)
      t.assert_eq(vim.api.nvim_win_get_buf(f.win), other)
      t.assert_true(vim.bo[other].modified)
    end)
  end)

  t.it("picker on_close before its closed flag does not recursively close it", function()
    fixture(function(f)
      local ownership = require("utils.ue_goto.reading_owner")
      local owner = ownership.begin()
      local closed = 0
      local picker = {
        main = f.win,
        closed = false,
        current_win = function()
          return nil
        end,
      }
      function picker:close()
        closed = closed + 1
        ownership.picker_closed(owner, self)
        self.closed = true
      end
      owner.picker = picker
      picker:close()
      t.assert_eq(closed, 1)
      t.assert_eq(ownership.active(), nil)
    end)
  end)

  t.it("native file formatting waits for UTF-16 then displays one-based byte columns without mutating rows", function()
    fixture(function(f)
      vim.fn.writefile({ "// 中文 Alpha" }, f.target)
      local buf = vim.fn.bufadd(f.target)
      vim.fn.bufload(buf)
      require("utils.ue_goto.reading").references()
      local loc = f.loc()
      loc.range.start.character = 6
      loc.range["end"].character = 11
      f.respond(1, nil, { loc })
      local picker, row = f.picks[1], f.picks[1].opts.items[1]
      t.assert_type(picker.opts.format, "function")
      local data = vim.fn.stdpath("data") .. "/lazy/snacks.nvim/lua/snacks/picker/"
      local old_format = package.loaded["snacks.picker.format"]
      local old_svim = _G.svim
      _G.svim = vim.fn.has("nvim-0.11") == 1 and vim or require("snacks.compat")
      package.loaded["snacks.picker.format"] = dofile(data .. "format.lua")
      _G.Snacks.picker.util = dofile(data .. "util/init.lua")
      picker.opts.icons = { files = { enabled = false } }
      picker.opts.formatters = { file = { filename_only = true } }
      local function formatted()
        local parts = picker.opts.format(row, picker)
        return table.concat(vim.tbl_map(function(part)
          return part[1]
        end, parts))
      end
      local ok, err = xpcall(function()
        t.assert_contains(formatted(), "origin.hpp:1 ")
        t.assert_contains(formatted(), "[列待预览]")
        t.assert_eq(row.pos[2], 6)
        _G.Snacks.picker.util.resolve_loc(row)
        t.assert_eq(row.pos[2], 10)
        t.assert_contains(formatted(), "origin.hpp:1:11")
        t.assert_eq(row.pos[2], 10)
      end, debug.traceback)
      package.loaded["snacks.picker.format"] = old_format
      _G.svim = old_svim
      if not ok then
        error(err)
      end
    end)
  end)

  for _, response_kind in ipairs({ "empty", "locations", "stale" }) do
    t.it("legacy reference callback " .. response_kind .. " keeps async fallback and source ownership", function()
      fixture(function(f)
        local previous = package.loaded["utils.ue_goto.provider"]
        local on_lsp, on_gtags, calls = nil, nil, 0
        package.loaded["utils.ue_goto.provider"] = {
          async_lsp_request = function(_, _, callback)
            on_lsp = callback
          end,
          sync_locations = function()
            error("unexpected synchronous LSP")
          end,
        }
        package.loaded.ue.gtags_references = function()
          error("unexpected synchronous GTAGS")
        end
        package.loaded.ue.gtags_references_async = function(_, callback, opts)
          t.assert_true(opts.collect)
          t.assert_true(opts.is_current())
          calls, on_gtags = calls + 1, callback
        end
        local ok, err = xpcall(function()
          local qf = vim.fn.getqflist({ id = 0 }).id
          t.assert_true(require("utils.ue_goto.reading").references())
          t.assert_type(on_lsp, "function")
          t.assert_eq(calls, 0)
          if response_kind == "stale" then
            vim.api.nvim_win_set_cursor(f.win, { 1, 0 })
          end
          on_lsp(response_kind == "locations" and { f.loc() } or nil)
          if response_kind == "empty" then
            t.assert_eq(calls, 1)
            t.assert_type(on_gtags, "function")
            on_gtags(true)
            t.assert_eq(#f.picks, 0)
            t.assert_eq(#f.messages, 1)
          elseif response_kind == "locations" then
            t.assert_eq(#f.picks, 1)
            t.assert_eq(calls, 0)
          else
            t.assert_eq(#f.picks, 0)
            t.assert_eq(calls, 0)
            t.assert_eq(#f.messages, 0)
          end
          t.assert_eq(vim.api.nvim_win_get_buf(f.win), f.buf)
          t.assert_eq(vim.fn.getqflist({ id = 0 }).id, qf)
        end, debug.traceback)
        package.loaded["utils.ue_goto.provider"] = previous
        if not ok then
          error(err)
        end
      end)
    end)
  end
end)
