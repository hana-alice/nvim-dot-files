local t = require("tests.harness")
t.bootstrap()

local commands = require("ue.clangd_commands")

local function write(path, value)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local file = assert(io.open(path, "wb"))
  file:write(type(value) == "string" and value or vim.json.encode(value))
  file:close()
end

local function fixture(entries, opts)
  opts = opts or {}
  local root = vim.fs.normalize(vim.fn.tempname() .. "-clangd-command")
  vim.fn.mkdir(root, "p")
  root = vim.fs.normalize(vim.uv.fs_realpath(root) or root)
  local project_bucket = root .. "/.cache/nvim-ue/projects/Sample-key"
  local semantic = opts.project_bucket
      and project_bucket .. "/clangd/IOS-Development/background-cdb"
    or root .. "/.cache/nvim-ue/clangd/background-cdb"
  local source_cdb = opts.project_bucket
      and project_bucket .. "/cdb/active/IOS-Development/compile_commands.json"
    or root .. "/compile_commands.json"
  local source = root .. "/Source/Runtime/Fixture/Private/subject.cpp"
  write(source, "int subject() { return 1; }\n")
  write(source_cdb, entries(source, root))
  write(semantic .. "/compile_commands.json", {
    {
      directory = semantic,
      file = semantic .. "/full/super_unity_cpps/SuperUnity.full.cpp",
      arguments = { "clang++", "-c", "SuperUnity.full.cpp" },
    },
  })
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(bufnr, source)
  return root, semantic, source, bufnr
end

local function cleanup(root, bufnr)
  require("ue.index.batch_runtime")._reset_for_test()
  if vim.api.nvim_buf_is_valid(bufnr) then pcall(vim.api.nvim_buf_delete, bufnr, { force = true }) end
  pcall(vim.fn.delete, root, "rf")
  commands._reset_for_test()
end

local function activate_frozen(root, semantic, bufnr, clangd)
  local runtime = require("ue.index.batch_runtime")
  runtime._reset_for_test()
  local descriptor = { ok = true, info_sha256 = "transport-proof", generation_id = "transport-generation",
    compiler_environment = {}, tool_path = clangd, receipts = { root .. "/receipt.json" }, watch_roots = { root },
    input_roots = { root .. "/Source" },
    watched_files = { semantic .. "/verified/compile_commands.json" }, exclude_roots = {},
    original_cdb = semantic .. "/compile_commands.json", verified_cdb = semantic .. "/verified/compile_commands.json" }
  local waiting, released = {}, false
  runtime.prepare(bufnr, root, function() released = true end, {
    clangd = clangd, no_buffer_watch = true,
    get_command = function() return { clangd, "--compile-commands-dir=" .. semantic } end,
    resolve_context = function() return { paths = { semantic_cdb = descriptor.original_cdb,
      clangd_dir = vim.fs.dirname(semantic) } } end,
    fingerprint = function() return "transport-metadata" end,
    get_generation = function() return "transport-generation" end,
    schedule = function(callback) waiting[#waiting + 1] = callback end,
    probe_recursive = function(callback) callback(true) end,
    watch_factory = function() return { close = function() end }, { recursive = true } end,
    run_async = function(_, _, _, callback) callback(descriptor) end,
  })
  while #waiting > 0 do table.remove(waiting, 1)() end
  t.assert_true(released)
  return runtime
end

t.describe("clangd exact compile-command transport", function()
  t.it("rejects an arbitrary verified folder instead of silently skipping exact commands", function()
    local root, semantic, _, bufnr = fixture(function(path, cwd)
      return { { directory = cwd, file = path, arguments = { "clang++", "-c", path } } }
    end, { project_bucket = true })
    write(semantic .. "/verified/compile_commands.json", {})
    local result, reason
    commands.ensure({ config = { cmd = { "clangd", "--compile-commands-dir=" .. semantic .. "/verified" } },
      notify = function() error("untrusted folder must not receive commands") end }, bufnr,
      function(ok, why) result, reason = ok, why end)
    t.assert_false(result)
    t.assert_eq(reason, "frozen-cdb-unverified")
    cleanup(root, bufnr)
  end)

  t.it("real frozen client receives its scoped exact command and reopens into the correct compiler identity", function()
    local tool = require("utils.platform").resolve_tool({ name = "clangd", env = { "UE_CLANGD" },
      config_candidates = require("utils.ue_goto.semantic_sidecar_libclang").discover_clangd_candidates() })
    if not tool.ok then t.skip("real frozen clangd transport", tool.reason, { native = true }); return end
    local root, semantic, source, bufnr = fixture(function(path, cwd)
      return { { directory = cwd, file = path,
        arguments = { "clang++", "-std=c++17", "-DEXACT_CHOICE=1", "-c", path } } }
    end, { project_bucket = true })
    local client
    local ok, err = xpcall(function()
      local lines = { "int choose(int);", "int choose(double);", "#if EXACT_CHOICE", "using Arg = int;",
        "#else", "using Arg = double;", "#endif", "int subject(){ return choose(Arg{}); }" }
      write(source, table.concat(lines, "\n") .. "\n")
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
      vim.bo[bufnr].buftype, vim.bo[bufnr].filetype, vim.bo[bufnr].modified = "", "cpp", false
      local wrapper = semantic .. "/verified/frozen.cpp"
      write(wrapper, '#include "' .. source .. '"\n')
      write(semantic .. "/verified/compile_commands.json", { { directory = root, file = wrapper,
        arguments = { "clang++", "-std=c++17", "-DEXACT_CHOICE=0", "-c", wrapper } } })
      local runtime = activate_frozen(root, semantic, bufnr, tool.path)
      local config = { name = "frozen-exact-fixture", root_dir = root }
      config.cmd = runtime.configure_process(runtime.command({ tool.path, "--enable-config=false", "-j=1",
        "--background-index=false", "--log=error", "--compile-commands-dir=" .. semantic }), config)
      config._ue_resolved_cmd = config.cmd
      t.assert_contains(config.cmd[#config.cmd], "/verified")
      local id = assert(vim.lsp.start(config, { bufnr = bufnr, reuse_client = function() return false end }))
      client = assert(vim.lsp.get_client_by_id(id))
      t.assert_true(vim.wait(10000, function() return client.initialized end, 10))
      runtime.attach(client, bufnr)
      local function identity()
        local done, answer, failure = false, nil, nil
        client:request("textDocument/symbolInfo", { textDocument = { uri = vim.uri_from_fname(source) },
          position = { line = 7, character = lines[8]:find("choose", 1, true) - 1 } }, function(e, r)
          done, answer, failure = true, r, e
        end, bufnr)
        t.assert_true(vim.wait(10000, function() return done end, 10))
        t.assert_nil(failure, vim.inspect(failure))
        return answer and answer[1] and answer[1].usr
      end
      t.assert_eq(identity(), "c:@F@choose#d#", "initial frozen inference must expose the wrong macro context")
      local notifications, original_notify = {}, client.notify
      client.notify = function(owner, method, params, ...)
        if method == "textDocument/didClose" or method == "workspace/didChangeConfiguration" or method == "textDocument/didOpen" then
          notifications[#notifications + 1] = method
        end
        return original_notify(owner, method, params, ...)
      end
      local delivered, delivery_ok, why, exact = false, nil, nil, nil
      commands.ensure(client, bufnr, function(value, reason, command)
        delivered, delivery_ok, why, exact = true, value, reason, command
      end)
      t.assert_true(vim.wait(10000, function() return delivered end, 10))
      t.assert_true(delivery_ok, why)
      t.assert_eq(exact.compilationCommand[3], "-DEXACT_CHOICE=1")
      t.assert_eq(table.concat(notifications, ","), "textDocument/didClose,workspace/didChangeConfiguration,textDocument/didOpen")
      t.assert_eq(identity(), "c:@F@choose#I#", "reopened AST must use the exact active command")
    end, debug.traceback)
    if client then
      client:stop()
      if not vim.wait(1000, function() return client:is_stopped() end, 10) then
        client:stop(true)
        vim.wait(1000, function() return client:is_stopped() end, 10)
      end
    end
    cleanup(root, bufnr)
    if not ok then error(err) end
  end)

  for _, termination in ipairs({ "cancel", "timeout" }) do
    t.it("does not deliver late preparation after transport " .. termination, function()
      local root, semantic, source, bufnr = fixture(function(path, cwd)
        return { { directory = cwd, file = path, arguments = { "clang++", "-c", path } } }
      end)
      local old_system, old_clients, old_defer = vim.system, vim.lsp.get_clients, vim.defer_fn
      local complete, timeout, result
      local notifications, requests = 0, 0
      vim.system = function(_, _, callback) complete = callback; return {} end
      vim.defer_fn = function(callback)
        timeout = callback
        return { is_closing = function() return false end, stop = function() end, close = function() end }
      end
      vim.lsp.get_clients = function() return { {
        id = 193, name = "clangd", config = { cmd = { "clangd", "--compile-commands-dir=" .. semantic } },
        notify = function() notifications = notifications + 1; return true end,
        request = function() requests = requests + 1; return true, 123 end,
      } } end
      local ok, err = xpcall(function()
        local handle = require("utils.ue_goto.clangd_adapter").async_lsp_request(bufnr, "textDocument/definition",
          function(value) result = value end, { structured = true, is_current = function() return true end })
        t.assert_type(complete, "function")
        if termination == "cancel" then handle.cancel() else timeout() end
        complete({ stdout = vim.json.encode({ state = "resolved", command = {
          workingDirectory = root, compilationCommand = { "clang++", "-c", source },
        } }) })
        t.assert_true(vim.wait(1000, function() return result ~= nil end))
        vim.wait(20, function() return false end)
        t.assert_eq(notifications, 0)
        t.assert_eq(requests, 0)
        t.assert_eq(result.reason, termination == "cancel" and "provider-cancelled" or "provider-timeout")
      end, debug.traceback)
      vim.system, vim.lsp.get_clients, vim.defer_fn = old_system, old_clients, old_defer
      cleanup(root, bufnr)
      if not ok then error(err) end
    end)
  end

  t.it("a cancelled waiter cannot deliver a shared prepared command for a newer waiter", function()
    local root, semantic, source, bufnr = fixture(function(path, cwd)
      return { { directory = cwd, file = path, arguments = { "clang++", "-c", path } } }
    end)
    local old_system = vim.system
    local complete, lookups = nil, 0
    local sent = { 0, 0 }
    vim.system = function(_, _, callback) lookups = lookups + 1; complete = callback; return {} end
    local function make_client(index)
      return { id = 100 + index, config = { cmd = { "clangd", "--compile-commands-dir=" .. semantic } },
        notify = function() sent[index] = sent[index] + 1; return true end }
    end
    local current, first, second = true, nil, nil
    local ok, err = xpcall(function()
      commands.ensure(make_client(1), bufnr, function(value, why) first = { value, why } end,
        { is_current = function() return current end })
      commands.ensure(make_client(2), bufnr, function(value) second = value end,
        { is_current = function() return true end })
      current = false
      complete({ stdout = vim.json.encode({ state = "resolved", command = {
        workingDirectory = root, compilationCommand = { "clang++", "-c", source },
      } }) })
      t.assert_true(vim.wait(1000, function() return first ~= nil and second ~= nil end))
      t.assert_eq(lookups, 1)
      t.assert_false(first[1])
      t.assert_eq(first[2], "stale-request")
      t.assert_true(second)
      t.assert_eq(sent[1], 0)
      t.assert_true(sent[2] > 0)
    end, debug.traceback)
    vim.system = old_system
    cleanup(root, bufnr)
    if not ok then error(err) end
  end)

  t.it("sends one exact command over compilationDatabaseChanges and caches the lookup", function()
    local root, semantic, source, bufnr = fixture(function(path, cwd)
      return {
        {
          directory = cwd,
          file = path,
          arguments = { "clang++", "-std=c++20", "-DFIXTURE=1", "-c", path },
        },
      }
    end)
    local notifications = {}
    local client = {
      id = 17,
      config = { cmd = { "clangd", "--compile-commands-dir=" .. semantic } },
      notify = function(_, method, params)
        notifications[#notifications + 1] = { method = method, params = params }
        return true
      end,
    }
    local transport_opts = {
      is_attached = function(_, client_id) return client_id == 17 end,
      buffer_version = function() return 7 end,
      language_id = function() return "cpp" end,
      buffer_text = function() return "int subject() { return 1; }\n" end,
    }
    local done, ok, reason, exact_command = false, false, nil, nil
    commands.ensure(client, bufnr, function(value, why, command)
      done, ok, reason, exact_command = true, value, why, command
    end, transport_opts)
    t.assert_true(vim.wait(10000, function() return done end, 10), "compile command query timed out")
    t.assert_true(ok, tostring(reason))
    t.assert_eq(reason, nil)
    t.assert_eq(#notifications, 3)
    t.assert_eq(notifications[1].method, "textDocument/didClose")
    t.assert_eq(notifications[2].method, "workspace/didChangeConfiguration")
    t.assert_eq(notifications[3].method, "textDocument/didOpen")
    t.assert_eq(notifications[3].params.textDocument.version, 7)
    t.assert_eq(notifications[3].params.textDocument.languageId, "cpp")
    t.assert_contains(notifications[3].params.textDocument.text, "int subject()")
    local sent = notifications[2].params.settings.compilationDatabaseChanges[source]
    t.assert_eq(vim.fs.normalize(sent.workingDirectory), root)
    t.assert_eq(sent.compilationCommand[3], "-DFIXTURE=1")
    t.assert_eq(exact_command, sent,
      "successful exact-command transport must expose the same compiler evidence to navigation")
    t.assert_eq(vim.bo[bufnr].syntax, "",
      "ordinary C++ commands must not enable the Objective-C syntax overlay")

    local cached = false
    commands.ensure(client, bufnr, function(value) cached = value end, transport_opts)
    t.assert_true(cached, "warm lookup must complete from memory without a process")
    t.assert_eq(#notifications, 3,
      "the same exact command must not close/reopen the buffer more than once per client")

    local header = root .. "/Source/Runtime/Fixture/Private/subject.hpp"
    write(header, "int subject();\n")
    local header_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(header_buf, header)
    local header_done, header_ok = false, false
    commands.ensure(client, header_buf, function(value) header_done, header_ok = true, value end, {
      compile_command_source = source,
      is_attached = transport_opts.is_attached,
      buffer_version = transport_opts.buffer_version,
      language_id = transport_opts.language_id,
      buffer_text = transport_opts.buffer_text,
    })
    t.assert_true(vim.wait(10000, function() return header_done end, 10))
    t.assert_true(header_ok)
    t.assert_eq(notifications[4].method, "textDocument/didClose")
    t.assert_eq(notifications[5].method, "workspace/didChangeConfiguration")
    t.assert_eq(notifications[6].method, "textDocument/didOpen")
    local header_command = notifications[5].params.settings.compilationDatabaseChanges[header]
    t.assert_eq(vim.fs.normalize(header_command.compilationCommand[#header_command.compilationCommand]), header)
    pcall(vim.api.nvim_buf_delete, header_buf, { force = true })
    cleanup(root, bufnr)
  end)

  t.it("finds the scoped active CDB beside a project-bucket semantic index", function()
    local root, semantic, source, bufnr = fixture(function(path, cwd)
      return { {
        directory = cwd,
        file = path,
        arguments = { "clang++", "-std=c++20", "-DSCOPED_CDB=1", "-c", path },
      } }
    end, { project_bucket = true })
    local notifications = {}
    local client = {
      config = { _ue_resolved_cmd = { "clangd", "--compile-commands-dir=" .. semantic } },
      notify = function(_, method, params)
        notifications[#notifications + 1] = { method = method, params = params }
        return true
      end,
    }

    local done, ok, reason = false, nil, nil
    commands.ensure(client, bufnr, function(value, why) done, ok, reason = true, value, why end)
    t.assert_true(vim.wait(10000, function() return done end, 10), "compile command query timed out")
    t.assert_true(ok, tostring(reason))
    t.assert_eq(reason, nil)
    local sent = notifications[1].params.settings.compilationDatabaseChanges[source]
    t.assert_eq(sent.compilationCommand[3], "-DSCOPED_CDB=1")

    cleanup(root, bufnr)
  end)

  t.it("overlays Objective-C++ syntax without replacing the cpp filetype", function()
    local syntax_was_on = vim.g.syntax_on == 1
    vim.cmd("syntax on")
    local root, semantic, _, bufnr = fixture(function(path, cwd)
      return { {
        directory = cwd,
        file = path,
        arguments = { "clang++", "-x", "objective-c++", "-std=c++20", "-c", path },
      } }
    end)
    vim.bo[bufnr].filetype = "cpp"
    vim.bo[bufnr].syntax = ""
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "void f() { @autoreleasepool {} }" })
    local done, ok, reason = false, nil, nil
    commands.detect_syntax(bufnr, { "clangd", "--compile-commands-dir=" .. semantic },
      function(value, why) done, ok, reason = true, value, why end)
    t.assert_true(vim.wait(10000, function() return done end, 10), "compile command query timed out")
    t.assert_true(ok, tostring(reason))
    t.assert_eq(vim.bo[bufnr].filetype, "cpp",
      "compile language must not disable the mixed file's cpp Tree-sitter parser")
    t.assert_eq(vim.bo[bufnr].syntax, "objcpp",
      "Objective-C++ lexical constructs need the built-in syntax overlay")
    local objc_group = vim.api.nvim_buf_call(bufnr, function()
      return vim.fn.synIDattr(vim.fn.synID(1, 12, true), "name")
    end)
    t.assert_eq(objc_group, "objcPool")

    cleanup(root, bufnr)
    if not syntax_was_on then vim.cmd("syntax off") end
  end)

  t.it("recognizes the resolved argv retained by a native LSP cmd factory", function()
    local root, semantic, _, bufnr = fixture(function(path, cwd)
      return { {
        directory = cwd,
        file = path,
        arguments = { "clang++", "-std=c++20", "-c", path },
      } }
    end)
    local notifications = {}
    local client = {
      id = -1,
      config = {
        cmd = function() end,
        _ue_resolved_cmd = { "clangd", "--compile-commands-dir=" .. semantic },
      },
      notify = function(_, method, params)
        notifications[#notifications + 1] = { method = method, params = params }
        return true
      end,
    }

    local done, ok, reason = false, nil, nil
    commands.ensure(client, bufnr, function(value, why) done, ok, reason = true, value, why end)
    t.assert_true(vim.wait(10000, function() return done end, 10), "compile command query timed out")
    t.assert_true(ok, tostring(reason))
    t.assert_eq(reason, nil)
    t.assert_eq(#notifications, 1)

    cleanup(root, bufnr)
  end)

  t.it("rejects distinct duplicate commands instead of choosing by CDB order", function()
    local root, semantic, _, bufnr = fixture(function(path, cwd)
      return {
        { directory = cwd, file = path, arguments = { "clang++", "-DA=1", "-c", path } },
        { directory = cwd, file = path, arguments = { "clang++", "-DB=1", "-c", path } },
      }
    end)
    local client = {
      config = { cmd = { "clangd", "--compile-commands-dir=" .. semantic } },
      notify = function() error("ambiguous command must not be sent") end,
    }
    local done, ok, reason = false, true, nil
    commands.ensure(client, bufnr, function(value, why) done, ok, reason = true, value, why end)
    t.assert_true(vim.wait(10000, function() return done end, 10))
    t.assert_false(ok)
    t.assert_eq(reason, "compile-command-ambiguous")
    cleanup(root, bufnr)
  end)
end)
