local t = require("tests.harness")
t.bootstrap()

local hub = require("utils.ue_hub")
local target = { project = "Game", platform = "Win64", configuration = "Development", state = {} }

local function action_for(field, value)
  for _, action in ipairs(hub.actions) do
    if action[field] == value then
      return action
    end
  end
  error("Hub action missing: " .. tostring(value))
end

local function source_fixture(check)
  local previous = vim.api.nvim_get_current_win()
  vim.cmd("new")
  local win, buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "one", "two", "three" })
  vim.api.nvim_win_set_cursor(win, { 1, 0 })
  local ok, err = pcall(check, { win = win, buf = buf })
  if vim.api.nvim_win_is_valid(win) then
    pcall(vim.api.nvim_win_close, win, true)
  end
  if vim.api.nvim_win_is_valid(previous) then
    vim.api.nvim_set_current_win(previous)
  end
  if vim.api.nvim_buf_is_valid(buf) then
    vim.api.nvim_buf_delete(buf, { force = true })
  end
  if not ok then
    error(err, 0)
  end
end

local function picker_fixture(check)
  source_fixture(function(source)
    local original_snacks, original_target = package.loaded.snacks, hub.target
    local original_clients, original_notify = vim.lsp.get_clients, vim.notify
    local picker_options, notices = nil, {}
    hub.target = function()
      return vim.deepcopy(target)
    end
    vim.lsp.get_clients = function()
      return {}
    end
    vim.notify = function(message)
      notices[#notices + 1] = message
    end
    package.loaded.snacks = {
      picker = {
        pick = function(options)
          picker_options = options
          return options
        end,
      },
    }
    local runs, ran_buf = 0, nil
    local action = {
      group = "Help",
      label = "source fixture",
      always = true,
      run = function()
        runs, ran_buf = runs + 1, vim.api.nvim_get_current_buf()
      end,
    }
    hub.command_hub()
    source.options = function()
      return picker_options
    end
    source.open = hub.command_hub
    source.action, source.notices = action, notices
    source.runs = function()
      return runs
    end
    source.ran_buf = function()
      return ran_buf
    end
    source.finish = function(close, choice)
      local picker = { close = close or function() end }
      picker_options.confirm(picker, choice ~= false and { data = action } or nil)
      local drained = false
      vim.schedule(function()
        drained = true
      end)
      t.assert_true(vim.wait(1000, function()
        return drained
      end, 5))
    end
    local ok, err = pcall(check, source)
    hub.invoke_action({ always = true, run = function() end }, { target = target })
    package.loaded.snacks, hub.target = original_snacks, original_target
    vim.lsp.get_clients, vim.notify = original_clients, original_notify
    if not ok then
      error(err, 0)
    end
  end)
end

t.describe("ide_hub discovery: existing routes and provider readiness", function()
  t.it("exposes the existing daily navigation and search keys", function()
    for _, key in ipairs({ "gd", "gr", "<leader>ch", "<leader><space>", "<leader>sG", "<leader>s/", "<leader>fh" }) do
      t.assert_type(action_for("key", key).run, "function")
    end
  end)

  t.it("shows real command names for actions without a shortcut", function()
    for _, name in ipairs({ "UEPeek", "UEReadReturn", "UEReadCancel", "UERelations incoming", "UEWorkspace results" }) do
      t.assert_contains(hub.format_action(action_for("command", name)), ":" .. name)
    end
  end)

  t.it("reports missing and unsupported relationship providers", function()
    local unsupported = {
      name = "clangd",
      supports_method = function()
        return false
      end,
    }
    for _, label in ipairs({
      "Browse incoming calls / 连续浏览调用者",
      "Browse outgoing calls / 连续浏览调用目标",
      "Browse base types / 连续浏览基类",
      "Browse derived types / 连续浏览派生类",
    }) do
      local action = action_for("label", label)
      local missing = hub.action_state(action, target, { clients = {} })
      t.assert_false(missing.ready, label)
      t.assert_contains(missing.reason, "提供者")
      t.assert_eq(missing.fix, "UEDoctor")
      t.assert_false(hub.action_state(action, target, { clients = { unsupported } }).ready)
    end
  end)

  t.it("checks each relationship method and the chooser's clangd identity against the real source buffer", function()
    source_fixture(function(source)
      local get_clients, queried = vim.lsp.get_clients, nil
      local client = {
        name = "fixture-provider",
        supports_method = function(_, method, buf)
          t.assert_eq(buf, source.buf)
          return method == "textDocument/prepareCallHierarchy"
        end,
      }
      vim.lsp.get_clients = function(opts)
        queried = opts
        return { client }
      end
      local ok, err = pcall(function()
        local calls = action_for("label", "Browse incoming calls / 连续浏览调用者")
        t.assert_false(hub.action_state(calls, target, { buf = source.buf }).ready)
        t.assert_eq(queried.bufnr, source.buf)
        t.assert_nil(queried.name, "match the chooser's case-insensitive clangd aliases, not only the exact name")
        client.name = "clangd"
        t.assert_true(hub.action_state(calls, target, { buf = source.buf }).ready)
        client.name = "UE-ClAnGd"
        t.assert_true(hub.action_state(calls, target, { buf = source.buf }).ready)
        t.assert_false(
          hub.action_state(action_for("label", "Browse base types / 连续浏览基类"), target, { buf = source.buf }).ready
        )
      end)
      vim.lsp.get_clients = get_clients
      if not ok then
        error(err, 0)
      end
    end)
  end)

  t.it("a non-clangd provider cannot make Hub ready when the actual relationship chooser refuses it", function()
    source_fixture(function(source)
      local get_clients, notify, ue = vim.lsp.get_clients, vim.notify, package.loaded.ue
      local requests, notices = 0, {}
      local client = {
        id = 991,
        name = "fixture-provider",
        offset_encoding = "utf-8",
        supports_method = function(_, method, buf)
          t.assert_eq(buf, source.buf)
          return method == "textDocument/prepareCallHierarchy" or method == "textDocument/prepareTypeHierarchy"
        end,
        request = function()
          requests = requests + 1
          return true, requests
        end,
      }
      vim.lsp.get_clients = function(opts)
        return opts.bufnr == source.buf and { client } or {}
      end
      vim.notify = function(message)
        notices[#notices + 1] = message
      end
      package.loaded.ue = {
        resolve_context = function()
          return nil
        end,
      }
      local relations = require("utils.ue_goto.relations")
      local reading = require("utils.ue_goto.reading")
      local ok, err = pcall(function()
        for _, kind in ipairs({ "incoming", "outgoing", "base", "derived" }) do
          local ready =
            hub.action_state(action_for("command", "UERelations " .. kind), target, { buf = source.buf }).ready
          local opened = relations.open(kind)
          t.assert_eq(opened, false)
          t.assert_eq(requests, 0)
          t.assert_false(ready, "actual chooser refused " .. kind .. "; Hub must not advertise readiness")
          reading.cancel()
        end
        t.assert_eq(#notices, 4)
        for _, message in ipairs(notices) do
          t.assert_contains(message, "没有支持此操作的提供者")
        end
      end)
      reading.cancel()
      relations.reset()
      vim.lsp.get_clients, vim.notify, package.loaded.ue = get_clients, notify, ue
      if not ok then
        error(err, 0)
      end
    end)
  end)

  t.it("does not add an attached-LSP gate to compiler-authoritative gd or default Peek", function()
    for _, action in ipairs({
      action_for("key", "gd"),
      action_for("label", "Peek definition / 预览定义并保留上下文"),
      action_for("label", "Return to investigation origin / 返回调查起点"),
      action_for("label", "Cancel reading request / 取消待返回的阅读请求"),
      action_for("label", "Resume relationship browser / 找回上次关系浏览"),
    }) do
      t.assert_true(hub.action_state(action, target, { clients = {} }).ready)
    end
  end)

  t.it("borrows the actual buffer mapping and reports an unavailable key without guessing a route", function()
    source_fixture(function(source)
      local notify, called, notices = vim.notify, 0, {}
      local global_mapping = vim.fn.maparg("gd", "n", false, true)
      vim.notify = function(message)
        notices[#notices + 1] = message
      end
      vim.keymap.set("n", "gd", function()
        t.assert_eq(vim.api.nvim_get_current_buf(), source.buf)
        called = called + 1
      end, { buffer = source.buf })
      local ok, err = pcall(function()
        action_for("key", "gd").run()
        t.assert_eq(called, 1)
        vim.keymap.del("n", "gd", { buffer = source.buf })
        if next(vim.fn.maparg("gd", "n", false, true)) then
          vim.keymap.del("n", "gd")
        end
        action_for("key", "gd").run()
        t.assert_eq(called, 1)
        t.assert_eq(#notices, 1)
      end)
      vim.notify = notify
      if next(global_mapping) then
        vim.fn.mapset("n", false, global_mapping)
      end
      if not ok then
        error(err, 0)
      end
    end)
  end)

  t.it("uses the real plugin-defined gd, references and source-header callbacks", function()
    source_fixture(function(source)
      local fallback, reading = package.loaded["utils.lsp_fallback"], package.loaded["utils.ue_goto.reading"]
      local get_clients, calls = vim.lsp.get_clients, {}
      package.loaded["utils.lsp_fallback"] = {
        definition = function()
          calls[#calls + 1] = "compiler-definition"
        end,
        references = function()
          calls[#calls + 1] = "owned-references"
        end,
      }
      package.loaded["utils.ue_goto.reading"] = {
        source_header = function()
          calls[#calls + 1] = "owned-header"
        end,
      }
      vim.lsp.get_clients = function()
        return { { name = "clangd" } }
      end
      local ok, err = pcall(function()
        local specs = dofile(t.bootstrap() .. "/lua/plugins/ue.lua")
        local options = { servers = {} }
        specs[2].opts(nil, options)
        for _, key in ipairs({ "gd", "gr", "<leader>ch" }) do
          local callback
          for _, mapping in ipairs(options.servers.clangd.keys) do
            if mapping[1] == key then
              callback = mapping[2]
              break
            end
          end
          t.assert_type(callback, "function")
          vim.keymap.set("n", key, callback, { buffer = source.buf })
          action_for("key", key).run()
        end
        t.assert_eq(table.concat(calls, ","), "compiler-definition,owned-references,owned-header")
      end)
      package.loaded["utils.lsp_fallback"], package.loaded["utils.ue_goto.reading"] = fallback, reading
      vim.lsp.get_clients = get_clients
      if not ok then
        error(err, 0)
      end
    end)
  end)

  t.it("uses actual search callbacks to retain workspace masks, snapshot scope and resume ownership", function()
    source_fixture(function(source)
      local names = { "ue", "snacks", "utils.history_hub", "utils.search_recipe" }
      local original, calls, context = {}, {}, { source = "frozen fixture context" }
      for _, name in ipairs(names) do
        original[name] = package.loaded[name]
      end
      package.loaded.ue = {
        picker_options = function()
          return { dirs = { "/fixture/game", "/fixture/engine" } }
        end,
        resolve_context = function()
          return context
        end,
        cached_files = function(options)
          t.assert_eq(options.list_type, "all")
          calls[#calls + 1] = "workspace-snapshot"
          return true
        end,
      }
      package.loaded.snacks = { picker = {} }
      package.loaded["utils.history_hub"] = {
        resume_search = function()
          calls[#calls + 1] = "native-latest-resume"
        end,
        hub = function()
          calls[#calls + 1] = "history-owner"
        end,
      }
      package.loaded["utils.search_recipe"] = {
        open_grep = function(options, scope)
          t.assert_false(options.code_only)
          t.assert_eq(options.ue_search_context, context)
          t.assert_eq(scope, "workspace")
          calls[#calls + 1] = "full-text-recipe"
        end,
      }
      local ok, err = pcall(function()
        local keys = dofile(t.bootstrap() .. "/lua/plugins/snacks.lua")[1].keys
        for _, key in ipairs({ "<leader><space>", "<leader>sG", "<leader>s/", "<leader>fh" }) do
          local callback
          for _, mapping in ipairs(keys) do
            if mapping[1] == key then
              callback = mapping[2]
              break
            end
          end
          t.assert_type(callback, "function")
          vim.keymap.set("n", key, callback, { buffer = source.buf })
          action_for("key", key).run()
        end
        t.assert_eq(table.concat(calls, ","), "workspace-snapshot,full-text-recipe,native-latest-resume,history-owner")
      end)
      for _, name in ipairs(names) do
        package.loaded[name] = original[name]
      end
      if not ok then
        error(err, 0)
      end
    end)
  end)
end)

t.describe("ide_hub discovery: native window ownership during picker close", function()
  t.it("runs a chosen action in its original native source", function()
    picker_fixture(function(f)
      f.finish()
      t.assert_eq(f.runs(), 1)
      t.assert_eq(f.ran_buf(), f.buf)
    end)
  end)

  t.it("canceling the picker never runs a deferred action", function()
    picker_fixture(function(f)
      f.finish(nil, false)
      t.assert_eq(f.runs(), 0)
    end)
  end)

  t.it("a late confirmation cannot execute from an already closed picker", function()
    picker_fixture(function(f)
      f.options().confirm({
        closed = true,
        close = function()
          error("must remain closed")
        end,
      }, { data = f.action })
      local drained = false
      vim.schedule(function()
        drained = true
      end)
      t.assert_true(vim.wait(1000, function()
        return drained
      end, 5))
      t.assert_eq(f.runs(), 0)
    end)
  end)

  t.it("rejects edits, cursor moves and source renames while the hub is open", function()
    for _, change in ipairs({ "edit", "cursor", "rename" }) do
      picker_fixture(function(f)
        if change == "edit" then
          vim.api.nvim_buf_set_lines(f.buf, 0, 1, false, { "new intent" })
        elseif change == "cursor" then
          vim.api.nvim_win_set_cursor(f.win, { 2, 0 })
        else
          vim.api.nvim_buf_set_name(f.buf, vim.fn.tempname() .. ".cpp")
        end
        f.finish()
        t.assert_eq(f.runs(), 0, change)
      end)
    end
  end)

  t.it("rejects close callbacks and queued edits that change the source", function()
    for _, timing in ipairs({ "close", "queued" }) do
      picker_fixture(function(f)
        f.finish(function()
          local edit = function()
            vim.api.nvim_buf_set_lines(f.buf, 0, 1, false, { "late input" })
          end
          if timing == "queued" then
            vim.schedule(edit)
          else
            edit()
          end
        end)
        t.assert_eq(f.runs(), 0, timing)
      end)
    end
  end)

  t.it("rejects source buffer replacement after picker close", function()
    picker_fixture(function(f)
      local other = vim.api.nvim_create_buf(false, true)
      f.finish(function()
        vim.api.nvim_win_set_buf(f.win, other)
      end)
      t.assert_eq(f.runs(), 0)
      vim.api.nvim_win_set_buf(f.win, f.buf)
      vim.api.nvim_buf_delete(other, { force = true })
    end)
  end)

  t.it("does not steal focus from a new native split after picker close", function()
    picker_fixture(function(f)
      local other
      f.finish(function()
        vim.cmd("vsplit")
        other = vim.api.nvim_get_current_win()
      end)
      local ok, err = pcall(function()
        t.assert_eq(f.runs(), 0)
        t.assert_eq(vim.api.nvim_get_current_win(), other)
      end)
      vim.api.nvim_win_close(other, true)
      if not ok then
        error(err, 0)
      end
    end)
  end)

  t.it("an older hub cannot execute after a newer hub has opened", function()
    picker_fixture(function(f)
      local old = f.options()
      f.open()
      old.confirm({ close = function() end }, { data = f.action })
      local drained = false
      vim.schedule(function()
        drained = true
      end)
      t.assert_true(vim.wait(1000, function()
        return drained
      end, 5))
      t.assert_eq(f.runs(), 0)
    end)
  end)

  t.it("rejects target drift or a newer action queued during picker close", function()
    for _, change in ipairs({ "target", "new-intent" }) do
      picker_fixture(function(f)
        f.finish(function()
          if change == "target" then
            hub.target = function()
              return vim.tbl_extend("force", target, { configuration = "Debug" })
            end
          else
            hub.invoke_action({ always = true, run = function() end }, { target = target })
          end
        end)
        t.assert_eq(f.runs(), 0, change)
      end)
    end
  end)

  t.it("never executes a choice if closing the picker fails", function()
    picker_fixture(function(f)
      f.finish(function()
        error("fixture close failed")
      end)
      t.assert_eq(f.runs(), 0)
      t.assert_eq(#f.notices, 1)
    end)
  end)

  t.it("rechecks source text after native WinEnter callbacks before invoking a mapping", function()
    source_fixture(function(source)
      vim.cmd("wincmd p")
      local entered = vim.api.nvim_create_autocmd("WinEnter", {
        callback = function()
          if vim.api.nvim_get_current_win() == source.win then
            vim.api.nvim_buf_set_lines(source.buf, 0, 1, false, { "changed by WinEnter" })
          end
        end,
      })
      local called = 0
      local ok, err = pcall(hub.invoke_action, {
        always = true,
        run = function()
          called = called + 1
        end,
      }, { source_win = source.win, target = target })
      vim.api.nvim_del_autocmd(entered)
      t.assert_true(ok, err)
      t.assert_eq(called, 0)
    end)
  end)
end)
