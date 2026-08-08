-- tests/cases/ue_goto_behavior_spec.lua
-- utils.ue_goto 的 location 行为与 C++ 语义跳转回归。

local t = require("tests.harness")
t.bootstrap()

local function loc(uri, line)
  return { uri = uri, range = { start = { line = line or 0 } } }
end

t.describe("location: dedup_locations 去重", function()
  local location = require("utils.ue_goto.location")
  t.it("重复 location 被去除", function()
    local input = {
      loc("file:///proj/A.cpp", 10),
      loc("file:///proj/A.cpp", 10),
      loc("file:///proj/B.cpp", 20),
    }
    local out = location.dedup_locations(input)
    t.assert_true(#out <= 2, "期望 <=2 条，实际 " .. #out)
  end)
end)

t.describe("provider: compiler identity 必须绑定响应客户端", function()
  t.it("structured provider 保留 unsupported 而不是折叠成 nil", function()
    local provider = require("utils.ue_goto.provider")
    local old_get_clients = vim.lsp.get_clients
    vim.lsp.get_clients = function() return {} end
    local done, symbol_info, definition = false, nil, nil
    provider.async_clangd_symbol_info(0, function(value)
      symbol_info = value
      provider.async_lsp_request(0, "textDocument/definition", function(result)
        definition = result
        done = true
      end, { structured = true })
    end, { structured = true })
    local waited = vim.wait(1000, function() return done end, 10)
    vim.lsp.get_clients = old_get_clients

    t.assert_true(waited)
    t.assert_eq(symbol_info.reason, "provider-method-unsupported")
    t.assert_eq(definition.reason, "provider-method-unsupported")
    t.assert_eq(#definition.locations, 0)
  end)

  t.it("definition 只向通过 symbolInfo 身份校验的 clangd client 请求", function()
    local provider = require("utils.ue_goto.provider")
    local old_get_clients = vim.lsp.get_clients
    local requests = { [17] = 0, [23] = 0 }
    local clients = {}
    for _, id in ipairs({ 17, 23 }) do
      clients[#clients + 1] = {
        id = id,
        name = "clangd",
        offset_encoding = "utf-16",
        request = function(_, method, _, callback)
          if method == "textDocument/symbolInfo" then
            callback(nil, { usr = "usr:verified" })
            return
          end
          requests[id] = requests[id] + 1
          callback(nil, loc("file:///fixture/client-" .. id .. ".cpp", id))
        end,
      }
    end
    vim.lsp.get_clients = function() return clients end

    local info_done, verified_usr, verified_ids = false, nil, nil
    provider.async_clangd_symbol_info(0, function(usr, client_ids)
      verified_usr = usr
      verified_ids = client_ids
      info_done = true
    end)
    local info_waited = vim.wait(1000, function() return info_done end, 10)

    local done, result = false, nil
    provider.async_lsp_request(0, "textDocument/definition", function(locations)
      result = locations
      done = true
    end, { client_ids = { 17 } })
    local definition_waited = vim.wait(1000, function() return done end, 10)

    vim.lsp.get_clients = old_get_clients
    t.assert_true(info_waited)
    t.assert_eq(verified_usr, "usr:verified")
    t.assert_eq(#verified_ids, 2)
    t.assert_eq(verified_ids[1], 17)
    t.assert_eq(verified_ids[2], 23)
    t.assert_true(definition_waited)
    t.assert_eq(requests[17], 1)
    t.assert_eq(requests[23], 0,
      "未通过 exact-cursor USR 校验的 LSP client 不得贡献 definition")
    t.assert_eq(#result, 1)
    t.assert_contains(result[1].uri, "client-17.cpp")
  end)

  t.it("snapshot 建立后切光标和 buffer，provider 仍只使用原始 URI/position", function()
    local provider = require("utils.ue_goto.provider")
    local transaction = require("utils.ue_goto.semantic_transaction")
    local old_get_clients = vim.lsp.get_clients
    local original_buf = vim.api.nvim_get_current_buf()
    local first = vim.api.nvim_create_buf(true, false)
    local second = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(first, "C:/fixture/first.cpp")
    vim.api.nvim_buf_set_name(second, "C:/fixture/second.cpp")
    vim.api.nvim_buf_set_lines(first, 0, -1, false, { "first();", "second();" })
    vim.api.nvim_buf_set_lines(second, 0, -1, false, { "other();" })
    vim.api.nvim_set_current_buf(first)
    vim.api.nvim_win_set_cursor(0, { 1, 2 })
    local tx = transaction.create({
      bufnr = first,
      snapshot = {
        bufnr = first,
        cursor = { 1, 2 },
        document_version = 7,
        changedtick = vim.api.nvim_buf_get_changedtick(first),
      },
    })
    vim.api.nvim_set_current_buf(second)
    vim.api.nvim_win_set_cursor(0, { 1, 0 })

    local captured
    vim.lsp.get_clients = function()
      return {
        {
          id = 99,
          name = "clangd",
          offset_encoding = "utf-16",
          request = function(_, _, params, callback)
            captured = params
            callback(nil, { usr = "usr:first" })
          end,
        },
      }
    end

    local done, result = false, nil
    provider.async_clangd_symbol_info(first, function(value)
      result = value
      done = true
    end, { snapshot = tx, structured = true })
    local waited = vim.wait(1000, function() return done end, 10)

    vim.lsp.get_clients = old_get_clients
    if vim.api.nvim_buf_is_valid(original_buf) then
      vim.api.nvim_set_current_buf(original_buf)
    end
    for _, bufnr in ipairs({ first, second }) do
      if vim.api.nvim_buf_is_valid(bufnr) then
        vim.api.nvim_buf_delete(bufnr, { force = true })
      end
    end

    t.assert_true(waited)
    t.assert_eq(result.usr, "usr:first")
    t.assert_eq(result.document_version, 7)
    t.assert_eq(result.client_results[1].document_version, 7)
    t.assert_eq(captured.textDocument.uri, vim.uri_from_fname("C:/fixture/first.cpp"))
    t.assert_eq(captured.position.line, 0)
    t.assert_eq(captured.position.character, 2)
  end)
end)

t.describe("C++ gd: 每个调用点必须独立请求语义目标", function()
  t.it("裸 symbol 缓存不得把 sibling overload 的落点复用于第二次 gd", function()
    local saved = {}
    local mocked = {
      "utils.ue_goto.symbol",
      "utils.ue_goto.location",
      "utils.ue_goto.provider",
      "utils.ue_goto.ui",
      "utils.ue_goto.jumper",
      "utils.ue_goto.cache",
      "utils.ue_goto.csearch_fallback",
      "utils.ue_goto.semantic_client",
      "utils.lsp_fallback",
    }
    for _, name in ipairs(mocked) do saved[name] = package.loaded[name] end

    local calls, jumps = 0, {}
    local fail_semantic = false
    local legacy_calls = { cache_get = 0, cache_put = 0, csearch = 0, gtags = 0 }
    local cached
    package.loaded["utils.ue_goto.symbol"] = {
      current_symbol = function() return "SubmitActiveCmdBuffer" end,
      current_receiver = function() return nil end,
      is_at_definition_at_cursor = function() return false end,
      is_dependent_at_cursor = function() return false end,
      is_in_unresolvable_context_at_cursor = function() return false end,
    }
    package.loaded["utils.ue_goto.location"] = {
      normalize_path = function(path) return path end,
      location_path = function(location) return vim.uri_to_fname(location.uri) end,
      location_line = function(location) return location.range.start.line + 1 end,
      normalize_locations = function(value) return value end,
      dedup_locations = function(value) return value end,
      filter_self_locations = function(value) return value end,
    }
    package.loaded["utils.ue_goto.provider"] = {
      async_clangd_symbol_info = function(_, callback, opts)
        if fail_semantic then
          if opts and opts.structured then
            callback({ usr = nil, client_ids = {}, reason = "identity-missing" })
          else
            callback(nil)
          end
        else
          local usr = calls == 0 and "usr:noargs" or "usr:args"
          if opts and opts.structured then
            callback({ usr = usr, client_ids = { 17 }, reason = "ok" })
          else
            callback(usr)
          end
        end
      end,
      async_lsp_request = function(_, _, callback, opts)
        calls = calls + 1
        local locations = { loc("file:///fixture/Overloads.h", calls == 1 and 420 or 422) }
        if opts and opts.structured then
          callback({ locations = locations, client_results = {} })
        else
          callback(locations)
        end
      end,
      async_lsp_definition_with_retry = function(_, _, _, _, callback)
        calls = calls + 1
        callback({ loc("file:///fixture/Overloads.h", calls == 1 and 420 or 422) })
      end,
      gtags_fallback_async = function(_, callback)
        legacy_calls.gtags = legacy_calls.gtags + 1
        callback(false)
      end,
      sync_locations = function() return nil, 0 end,
    }
    package.loaded["utils.ue_goto.ui"] = {
      NON_CLANGD_EXTS = {},
      buf_extension = function() return "cpp" end,
      progress_notice = function() return { clear = function() end } end,
      try_jump = function() return false end,
      populate_quickfix = function() end,
    }
    package.loaded["utils.ue_goto.jumper"] = {
      jump = function(location)
        jumps[#jumps + 1] = location.range.start.line
        return true
      end,
    }
    package.loaded["utils.ue_goto.cache"] = {
      get = function()
        legacy_calls.cache_get = legacy_calls.cache_get + 1
        if cached then return { cached }, "SubmitActiveCmdBuffer", "lsp" end
      end,
      put = function(_, _, locations)
        legacy_calls.cache_put = legacy_calls.cache_put + 1
        cached = locations[1]
      end,
      stats = function() return { entries = cached and 1 or 0 } end,
      clear = function() cached = nil; return true end,
    }
    package.loaded["utils.ue_goto.csearch_fallback"] = {
      find = function(_, _, callback)
        legacy_calls.csearch = legacy_calls.csearch + 1
        callback(nil, { count = 0 })
      end,
    }
    local action = 0
    local origin_notes = 0
    local noted_memberships = {}
    package.loaded["utils.ue_goto.semantic_client"] = {
      set_trace = function() end,
      begin_action = function()
        action = action + 1
        return { token = action, winid = 0, cursor = { 1, 1 }, document_version = 1 }
      end,
      discover_toolchain = function()
        return { build_fingerprint = "fixture", cdb_dir = "/fixture" }
      end,
      prove_source = function(_, callback)
        local target = loc("file:///fixture/Overloads.h", calls == 0 and 420 or 422)
        callback({
          state = "resolved",
          context_id = "ctx",
          usr = calls == 0 and "usr:noargs" or "usr:args",
          definition = nil,
          declaration = target,
          origin_context = {
            context_id = "ctx",
            origin_tu = "/fixture/Overloads.cpp",
            cdb_dir = "/fixture",
          },
        })
      end,
      snapshot_is_current = function() return true end,
      note_origin = function(_, context)
        origin_notes = origin_notes + 1
        noted_memberships[#noted_memberships + 1] = context and context.subject_membership or nil
      end,
    }
    package.loaded["utils.lsp_fallback"] = nil

    local old_get_clients = vim.lsp.get_clients
    vim.lsp.get_clients = function(opts)
      return opts and opts.method == "textDocument/definition" and { {} } or {}
    end
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "SubmitActiveCmdBuffer();" })
    vim.bo.modified = false
    vim.api.nvim_win_set_cursor(0, { 1, 1 })

    local ok, err = xpcall(function()
      local gd = require("utils.lsp_fallback")
      gd.definition()
      gd.definition()
      t.assert_eq(calls, 2,
        "第二个 overload 调用点必须发起自己的 textDocument/definition 请求")
      t.assert_eq(#jumps, 2)
      t.assert_eq(jumps[1], 420)
      t.assert_eq(jumps[2], 422,
        "第二次 gd 不得重放第一次无参 overload 的缓存落点")
      t.assert_eq(origin_notes, 2,
        "source TU 跳入 header 后必须记录 proven origin context")
      t.assert_true(noted_memberships[1]["/fixture/overloads.h"] == true)
      t.assert_true(noted_memberships[2]["/fixture/overloads.h"] == true)
      t.assert_eq(legacy_calls.cache_get, 0, "C++ gd 不得读取 definition location cache")
      t.assert_eq(legacy_calls.cache_put, 0, "C++ gd 不得写入 definition location cache")
      t.assert_eq(legacy_calls.csearch, 0, "C++ gd 不得自动调用 csearch")
      t.assert_eq(legacy_calls.gtags, 0, "C++ gd 不得自动调用 GTAGS")

      fail_semantic = true
      gd.definition()
      t.assert_eq(calls, 2, "缺失 compiler identity 时不得继续请求或猜测目标")
      t.assert_eq(#jumps, 2, "语义失败时必须保持当前位置")
      t.assert_eq(legacy_calls.cache_get + legacy_calls.cache_put
        + legacy_calls.csearch + legacy_calls.gtags, 0,
        "C++ 语义失败不得进入任何 legacy definition fallback")
    end, debug.traceback)

    vim.lsp.get_clients = old_get_clients
    for _, name in ipairs(mocked) do package.loaded[name] = saved[name] end
    for _, cmd in ipairs({
      "UEDefTrace", "UEDefSelfTest", "UEDefReload", "UEDefDiag",
      "UEDefCacheClear", "UEDefCancel", "UEDefContextClear", "UEDefExplain",
    }) do
      pcall(vim.api.nvim_del_user_command, cmd)
    end
    if not ok then error(err) end
  end)

  t.it("semantic explain/probe 可回放，150ms 进度在 stale 结束后会清理", function()
    local saved = {}
    local mocked = {
      "utils.ue_goto.symbol",
      "utils.ue_goto.location",
      "utils.ue_goto.provider",
      "utils.ue_goto.ui",
      "utils.ue_goto.jumper",
      "utils.ue_goto.cache",
      "utils.ue_goto.csearch_fallback",
      "utils.ue_goto.semantic_client",
      "utils.probe",
      "utils.lsp_fallback",
    }
    for _, name in ipairs(mocked) do saved[name] = package.loaded[name] end

    local probe_calls = {}
    local notices = { shown = 0, cleared = 0 }
    local stale = false
    package.loaded["utils.ue_goto.symbol"] = {
      current_symbol = function() return "RHISubmitCommandsHint" end,
      current_receiver = function() return "Context" end,
      is_at_definition_at_cursor = function() return false end,
      is_dependent_at_cursor = function() return false end,
      is_in_unresolvable_context_at_cursor = function() return false end,
    }
    package.loaded["utils.ue_goto.location"] = {
      normalize_path = function(path) return path end,
      location_path = function(location) return vim.uri_to_fname(location.uri) end,
      location_line = function(location) return location.range.start.line + 1 end,
      normalize_locations = function(value) return value end,
      dedup_locations = function(value) return value end,
      filter_self_locations = function(value) return value end,
    }
    package.loaded["utils.ue_goto.provider"] = {
      async_clangd_symbol_info = function(_, callback, opts)
        vim.defer_fn(function()
          stale = true
          if opts and opts.structured then
            callback({ usr = nil, client_ids = {}, reason = "identity-missing" })
          else
            callback(nil)
          end
        end, 250)
      end,
      async_lsp_request = function(_, _, callback, opts)
        callback(opts and opts.structured and { locations = {}, client_results = {} } or {})
      end,
      sync_locations = function() return nil, 0 end,
      gtags_fallback_async = function(_, callback) callback(false) end,
    }
    package.loaded["utils.ue_goto.ui"] = {
      NON_CLANGD_EXTS = {},
      buf_extension = function() return "cpp" end,
      progress_notice = function()
        notices.shown = notices.shown + 1
        return { clear = function() notices.cleared = notices.cleared + 1 end }
      end,
    }
    package.loaded["utils.ue_goto.jumper"] = { jump = function() return true end }
    package.loaded["utils.ue_goto.cache"] = {
      get = function() return nil end,
      put = function() end,
      stats = function() return { entries = 0 } end,
      clear = function() return true end,
    }
    package.loaded["utils.ue_goto.csearch_fallback"] = { find = function(_, _, cb) cb(nil, { count = 0 }) end }
    package.loaded["utils.ue_goto.semantic_client"] = {
      set_trace = function() end,
      begin_action = function()
        return { token = 1, winid = 0, bufnr = 0, cursor = { 1, 1 }, document_version = 11, changedtick = 11 }
      end,
      discover_toolchain = function() return { build_fingerprint = "fixture" } end,
      prove_source = function(_, callback)
        callback({
          state = "resolved",
          context_id = "ctx",
          declaration = loc("file:///fixture/VulkanContext.h", 94),
          definition = nil,
          origin_context = { context_id = "ctx", origin_tu = "/fixture/VulkanViewport.cpp" },
        })
      end,
      snapshot_is_current = function()
        return not stale, stale and "superseded" or nil
      end,
      note_origin = function() end,
      cancel_action = function() end,
      clear_contexts = function() end,
      status = function() return {} end,
    }
    package.loaded["utils.probe"] = {
      record = function(topic, key, data)
        probe_calls[#probe_calls + 1] = { topic = topic, key = key, data = data }
        return true
      end,
    }
    package.loaded["utils.lsp_fallback"] = nil

    local old_get_clients = vim.lsp.get_clients
    local old_notify = vim.notify
    vim.lsp.get_clients = function(opts)
      return opts and opts.method == "textDocument/definition" and { { name = "clangd", id = 17 } } or {}
    end
    vim.notify = function() end
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "Context.RHISubmitCommandsHint();" })
    vim.bo.modified = false
    vim.api.nvim_win_set_cursor(0, { 1, 1 })

    local ok, err = xpcall(function()
      local gd = require("utils.lsp_fallback")
      local txmod = require("utils.ue_goto.semantic_transaction")
      local entry_started = vim.uv.hrtime()
      gd.definition()
      local entry_ms = (vim.uv.hrtime() - entry_started) / 1000000
      t.assert_true(entry_ms < 50,
        string.format("C++ gd entry must return UI control within 50ms, got %.2fms", entry_ms))
      t.assert_true(vim.wait(1000, function() return txmod.last_result(gd._last_cpp_transaction) ~= nil end, 10))
      local explain = table.concat(gd._test_explain_lines(), "\n")
      t.assert_true(notices.shown >= 1, "延迟超过 150ms 时必须出现进度提示")
      t.assert_true(notices.cleared >= 1, "stale 结束后必须清理进度提示")
      t.assert_eq(#probe_calls, 0, "stale 终止不得写 failure probe")
      t.assert_contains(explain, "stage: stale")
      t.assert_contains(explain, "reason: stale-request")
    end, debug.traceback)

    vim.notify = old_notify
    vim.lsp.get_clients = old_get_clients
    for _, name in ipairs(mocked) do package.loaded[name] = saved[name] end
    for _, cmd in ipairs({
      "UEDefTrace", "UEDefSelfTest", "UEDefReload", "UEDefDiag",
      "UEDefCacheClear", "UEDefCancel", "UEDefContextClear", "UEDefExplain",
    }) do
      pcall(vim.api.nvim_del_user_command, cmd)
    end
    if not ok then error(err) end
  end)

  t.it("头文件声明必须按同一 USR 继续解析唯一的跨 TU 定义", function()
    local saved = {}
    local mocked = {
      "utils.ue_goto.symbol",
      "utils.ue_goto.provider",
      "utils.ue_goto.ui",
      "utils.ue_goto.jumper",
      "utils.ue_goto.cache",
      "utils.ue_goto.csearch_fallback",
      "utils.ue_goto.semantic_client",
      "utils.lsp_fallback",
    }
    for _, name in ipairs(mocked) do saved[name] = package.loaded[name] end

    local original_buf = vim.api.nvim_get_current_buf()
    local test_buf = vim.api.nvim_create_buf(true, false)
    local header = "C:/fixture/VulkanCommandBuffer.h"
    local source = "C:/fixture/VulkanCommandBuffer.cpp"
    vim.api.nvim_buf_set_name(test_buf, header)
    vim.api.nvim_set_current_buf(test_buf)
    vim.api.nvim_buf_set_lines(test_buf, 0, -1, false, {
      "void SubmitActiveCmdBuffer();",
      "void CallSite() { SubmitActiveCmdBuffer(); }",
    })
    vim.bo[test_buf].modified = false
    vim.api.nvim_win_set_cursor(0, { 1, 5 })

    local clangd_usr = "usr:SubmitActiveCmdBuffer(two-args)"
    local snapshot_line = 1
    local definition_locations = { loc(vim.uri_from_fname(source), 422) }
    local symbol_info_requests = 0
    local definition_requests = 0
    local module_lookup_requests = 0
    local module_definition
    local jumps = {}
    package.loaded["utils.ue_goto.symbol"] = {
      current_symbol = function() return "SubmitActiveCmdBuffer" end,
      current_receiver = function() return nil end,
      is_at_definition_at_cursor = function() return false end,
      is_dependent_at_cursor = function() return false end,
      is_in_unresolvable_context_at_cursor = function() return false end,
    }
    package.loaded["utils.ue_goto.provider"] = {
      async_clangd_symbol_info = function(_, callback, opts)
        symbol_info_requests = symbol_info_requests + 1
        if opts and opts.structured then
          callback({
            usr = clangd_usr,
            client_ids = clangd_usr and { 17 } or {},
            reason = clangd_usr and "ok" or "identity-missing",
          })
        else
          callback(clangd_usr, { 17 })
        end
      end,
      async_lsp_request = function(_, method, callback, opts)
        t.assert_eq(method, "textDocument/definition")
        t.assert_eq(opts.client_ids[1], 17,
          "definition 必须绑定通过 USR 校验的 clangd client")
        definition_requests = definition_requests + 1
        if opts and opts.structured then
          callback({ locations = definition_locations, client_results = {} })
        else
          callback(definition_locations)
        end
      end,
      sync_locations = function() return nil, 0 end,
      gtags_fallback_async = function(_, callback) callback(false) end,
    }
    package.loaded["utils.ue_goto.ui"] = {
      NON_CLANGD_EXTS = {},
      buf_extension = function() return "hpp" end,
    }
    package.loaded["utils.ue_goto.jumper"] = {
      jump = function(location)
        jumps[#jumps + 1] = location
        return true
      end,
    }
    package.loaded["utils.ue_goto.cache"] = {
      stats = function() return { entries = 0 } end,
      clear = function() return true end,
    }
    package.loaded["utils.ue_goto.csearch_fallback"] = {}
    package.loaded["utils.ue_goto.semantic_client"] = {
      set_trace = function() end,
      begin_action = function()
        return { token = 1, winid = 0, cursor = { snapshot_line, 5 }, document_version = 1 }
      end,
      discover_toolchain = function()
        return { build_fingerprint = "fixture", cdb_dir = "C:/fixture" }
      end,
      lookup_definition = function(spec, callback)
        module_lookup_requests = module_lookup_requests + 1
        t.assert_eq(spec.usr, "usr:SubmitActiveCmdBuffer(two-args)")
        callback(module_definition and {
          state = "resolved",
          definition = module_definition,
          metrics = { cache_hit = false },
        } or {
          state = "unavailable",
          reason = "definition-not-found-in-proven-module-context",
        })
      end,
      resolve_header = function(_, callback)
        callback({
          state = "resolved",
          usr = "usr:SubmitActiveCmdBuffer(two-args)",
          definition = nil,
          declaration = loc(vim.uri_from_fname(header), 0),
        })
      end,
      snapshot_is_current = function() return true end,
      cancel_action = function() end,
      clear_contexts = function() end,
      status = function() return {} end,
    }
    package.loaded["utils.lsp_fallback"] = nil

    local old_get_clients = vim.lsp.get_clients
    local old_notify = vim.notify
    vim.lsp.get_clients = function() return { { name = "clangd" } } end
    vim.notify = function() end

    local ok, err = xpcall(function()
      local gd = require("utils.lsp_fallback")
      module_definition = { path = source, line = 423, column = 1 }
      gd.definition()
      t.assert_eq(module_lookup_requests, 1)
      t.assert_eq(symbol_info_requests, 0,
        "proven module AST 已按 canonical USR 找到 body 时不得再请求 clangd identity")
      t.assert_eq(definition_requests, 0,
        "proven module AST 已给出唯一 body 时不得再依赖 clangd index")
      t.assert_eq(#jumps, 1)
      t.assert_eq(require("utils.ue_goto.location").location_path(jumps[1]), source)
      t.assert_eq(require("utils.ue_goto.location").location_line(jumps[1]), 423)

      module_definition = nil
      gd.definition()
      t.assert_eq(symbol_info_requests, 1,
        "libclang 只见声明时必须向 clangd 校验当前位置的 compiler USR")
      t.assert_eq(definition_requests, 1,
        "USR 相等后必须请求跨 TU definition")
      t.assert_eq(#jumps, 2)
      t.assert_eq(require("utils.ue_goto.location").location_path(jumps[2]), source)
      t.assert_eq(require("utils.ue_goto.location").location_line(jumps[2]), 423)

      definition_locations = { loc(vim.uri_from_fname(header), 0) }
      gd.definition()
      t.assert_eq(definition_requests, 2)
      t.assert_eq(#jumps, 2,
        "声明位置在无跨 TU definition 时不得再把原声明当成功落点")

      definition_locations = {
        loc(vim.uri_from_fname(source), 422),
        loc(vim.uri_from_fname("C:/fixture/Other.cpp"), 99),
      }
      gd.definition()
      t.assert_eq(definition_requests, 3)
      t.assert_eq(#jumps, 2,
        "同一 USR 出现多个 definition location 时不得按顺序猜选")

      clangd_usr = "usr:different-overload"
      gd.definition()
      t.assert_eq(symbol_info_requests, 4)
      t.assert_eq(definition_requests, 3,
        "clangd 与 libclang USR 不相等时不得请求或选择定义")
      t.assert_eq(#jumps, 2,
        "USR 不相等时不得回跳到当前位置声明或任何猜测目标")

      clangd_usr = nil
      snapshot_line = 2
      vim.api.nvim_win_set_cursor(0, { 2, 20 })
      gd.definition()
      t.assert_eq(symbol_info_requests, 5)
      t.assert_eq(definition_requests, 3)
      t.assert_eq(#jumps, 3,
        "跨 TU definition 不可证明时，其他调用点仍可退到同一 USR 的声明")
      t.assert_eq(require("utils.ue_goto.location").location_path(jumps[3]), header)
      t.assert_eq(require("utils.ue_goto.location").location_line(jumps[3]), 1)
    end, debug.traceback)

    vim.notify = old_notify
    vim.lsp.get_clients = old_get_clients
    if vim.api.nvim_buf_is_valid(original_buf) then
      vim.api.nvim_set_current_buf(original_buf)
    end
    if vim.api.nvim_buf_is_valid(test_buf) then
      vim.api.nvim_buf_delete(test_buf, { force = true })
    end
    for _, name in ipairs(mocked) do package.loaded[name] = saved[name] end
    for _, cmd in ipairs({
      "UEDefTrace", "UEDefSelfTest", "UEDefReload", "UEDefDiag",
      "UEDefCacheClear", "UEDefCancel", "UEDefContextClear", "UEDefExplain",
    }) do
      pcall(vim.api.nvim_del_user_command, cmd)
    end
    if not ok then error(err) end
  end)
end)
