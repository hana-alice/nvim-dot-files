local t = require("tests.harness")
t.bootstrap()

local function fixture()
  local root = vim.fs.normalize(vim.fn.tempname())
  local state = { index_selection = { generation_id = "same-build" } }
  local signature, pending = "publication-1", false
  local calls, timers = {}, {}
  local client = { id = 1, initialized = true, attached_buffers = {}, config = {
    cmd = { "clangd", "--compile-commands-dir=" .. root },
  } }
  function client:notify(method, params) calls[#calls + 1] = { method, params }; return true end
  function client:request(method, params, callback)
    calls[#calls + 1] = { method, params }; self.reply = callback; return true
  end
  function client:stop() calls[#calls + 1] = { "stop" } end
  local module, runtime = {}, { last_restart_at = 0, restart_debounce_s = 0 }
  require("ue.index._clangd")(module, { RT = runtime, h = {
    unix_now = function() return 100 end,
    file_signature = function() return signature end,
    ensure_index_state = function() return state end,
  } })
  module.source_refresh_pending = function() return pending end
  local options = { context = { paths = { semantic_cdb = root .. "/compile_commands.json" } },
    same_generation = true, original_append_only = true,
    get_clients = function() return { client } end, list_bufs = function() return {} end,
    defer_fn = function(callback, delay) timers[#timers + 1] = { callback, delay } end,
  }
  return { module = module, state = state, options = options, client = client,
    calls = calls, timers = timers, runtime = runtime,
    change_signature = function() signature = "publication-2" end,
    source_pending = function() pending = true end }
end

t.describe("普通阶段同进程追加交付", function()
  t.it("等待目录重验后仅用内存URI触发reload，解析回调后关闭且不消耗restart debounce", function()
    local f = fixture()
    t.assert_false(f.module.maybe_restart_clangd_for_index(f.options))
    t.assert_eq(#f.calls, 0)
    t.assert_eq(f.runtime.last_restart_at, 0)
    t.assert_eq(f.timers[1][2], 6000)
    f.timers[1][1]()
    t.assert_eq(f.calls[1][1], "textDocument/didOpen")
    local doc = f.calls[1][2].textDocument
    t.assert_eq(doc.text, "")
    t.assert_eq(vim.uv.fs_stat(vim.uri_to_fname(doc.uri)), nil)
    t.assert_eq(f.calls[2][1], "textDocument/documentSymbol")
    t.assert_eq(f.calls[2][2].textDocument.uri, doc.uri)
    f.client.reply(nil, {})
    t.assert_eq(f.calls[3][1], "textDocument/didClose")
    f.timers[2][1]()
    t.assert_eq(#f.calls, 3, "关闭必须幂等")
  end)

  for _, reason in ipairs({ "generation", "publication", "source", "reader", "retirement" }) do
    t.it("延迟期间" .. reason .. "变化时丢弃旧reload", function()
      local f = fixture()
      f.module.maybe_restart_clangd_for_index(f.options)
      if reason == "generation" then f.state.index_selection.generation_id = "other-build"
      elseif reason == "publication" then f.change_signature()
      elseif reason == "source" then f.source_pending()
      elseif reason == "reader" then f.client.config.cmd = { "clangd", "--compile-commands-dir=/other" }
      else
        f.runtime.last_restart_at, f.runtime.restart_debounce_s = 100, 5
        f.options.original_append_only = false
        f.module.maybe_restart_clangd_for_index(f.options)
      end
      f.timers[1][1]()
      t.assert_eq(#f.calls, 0)
    end)
  end

  for _, reason in ipairs({ "generation", "command", "frozen", "foreign", "invalidated" }) do
    t.it(reason .. "不满足追加前提时保留原重启路径", function()
      local f = fixture()
      if reason == "generation" then f.options.same_generation = false
      elseif reason == "command" then f.options.original_append_only = false
      elseif reason == "frozen" then f.client.config._ue_batch_scope = "guarded"
      elseif reason == "foreign" then f.client.config.cmd = { "clangd", "--compile-commands-dir=/other" }
      else f.options.invalidated_frozen_batch = true end
      t.assert_true(f.module.maybe_restart_clangd_for_index(f.options))
      t.assert_eq(f.calls[1][1], "stop")
      t.assert_eq(f.timers[1][2], 500)
    end)
  end

  t.it("先前非追加发布被debounce推迟后，不能用下一次追加为旧reader背书", function()
    local f = fixture()
    f.runtime.last_restart_at, f.runtime.restart_debounce_s = 100, 5
    f.options.original_append_only = false
    local started, delay = f.module.maybe_restart_clangd_for_index(f.options)
    t.assert_false(started); t.assert_eq(delay, 5000)
    f.options.original_append_only = true
    f.options.now = function() return 106 end
    t.assert_true(f.module.maybe_restart_clangd_for_index(f.options))
    t.assert_eq(f.calls[1][1], "stop")
    t.assert_eq(f.timers[1][2], 500)
  end)
end)
