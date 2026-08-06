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
      async_clangd_symbol_info = function(_, callback)
        if fail_semantic then
          callback(nil)
        else
          callback(calls == 0 and "usr:noargs" or "usr:args")
        end
      end,
      async_lsp_request = function(_, _, callback)
        calls = calls + 1
        callback({ loc("file:///fixture/Overloads.h", calls == 1 and 420 or 422) })
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
          definition = target,
          declaration = target,
          origin_context = {
            context_id = "ctx",
            origin_tu = "/fixture/Overloads.cpp",
            cdb_dir = "/fixture",
          },
        })
      end,
      snapshot_is_current = function() return true end,
      note_origin = function() origin_notes = origin_notes + 1 end,
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
      "UEDefCacheClear", "UEDefCancel", "UEDefContextClear",
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
    local jumps = {}
    package.loaded["utils.ue_goto.symbol"] = {
      current_symbol = function() return "SubmitActiveCmdBuffer" end,
      current_receiver = function() return nil end,
      is_at_definition_at_cursor = function() return false end,
      is_dependent_at_cursor = function() return false end,
      is_in_unresolvable_context_at_cursor = function() return false end,
    }
    package.loaded["utils.ue_goto.provider"] = {
      async_clangd_symbol_info = function(_, callback)
        symbol_info_requests = symbol_info_requests + 1
        callback(clangd_usr, { 17 })
      end,
      async_lsp_request = function(_, method, callback, opts)
        t.assert_eq(method, "textDocument/definition")
        t.assert_eq(opts.client_ids[1], 17,
          "definition 必须绑定通过 USR 校验的 clangd client")
        definition_requests = definition_requests + 1
        callback(definition_locations)
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
      gd.definition()
      t.assert_eq(symbol_info_requests, 1,
        "libclang 只见声明时必须向 clangd 校验当前位置的 compiler USR")
      t.assert_eq(definition_requests, 1,
        "USR 相等后必须请求跨 TU definition")
      t.assert_eq(#jumps, 1)
      t.assert_eq(require("utils.ue_goto.location").location_path(jumps[1]), source)
      t.assert_eq(require("utils.ue_goto.location").location_line(jumps[1]), 423)

      definition_locations = { loc(vim.uri_from_fname(header), 0) }
      gd.definition()
      t.assert_eq(definition_requests, 2)
      t.assert_eq(#jumps, 1,
        "clangd 只返回原声明时必须保持当前位置")

      definition_locations = {
        loc(vim.uri_from_fname(source), 422),
        loc(vim.uri_from_fname("C:/fixture/Other.cpp"), 99),
      }
      gd.definition()
      t.assert_eq(definition_requests, 3)
      t.assert_eq(#jumps, 1,
        "同一 USR 出现多个 definition location 时不得按顺序猜选")

      clangd_usr = "usr:different-overload"
      gd.definition()
      t.assert_eq(symbol_info_requests, 4)
      t.assert_eq(definition_requests, 3,
        "clangd 与 libclang USR 不相等时不得请求或选择定义")
      t.assert_eq(#jumps, 1,
        "USR 不相等时不得回跳到当前位置声明或任何猜测目标")

      clangd_usr = nil
      snapshot_line = 2
      vim.api.nvim_win_set_cursor(0, { 2, 20 })
      gd.definition()
      t.assert_eq(symbol_info_requests, 5)
      t.assert_eq(definition_requests, 3)
      t.assert_eq(#jumps, 2,
        "跨 TU definition 不可证明时，其他调用点仍可退到同一 USR 的声明")
      t.assert_eq(require("utils.ue_goto.location").location_path(jumps[2]), header)
      t.assert_eq(require("utils.ue_goto.location").location_line(jumps[2]), 1)
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
      "UEDefCacheClear", "UEDefCancel", "UEDefContextClear",
    }) do
      pcall(vim.api.nvim_del_user_command, cmd)
    end
    if not ok then error(err) end
  end)
end)
