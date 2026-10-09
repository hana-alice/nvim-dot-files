local t = require("tests.harness")
t.bootstrap()

t.describe("DAP session-owned log tab", function()
  t.it("resolves only the explicit active owner, with no target fallback", function()
    local d = assert(loadfile(vim.fn.stdpath("config") .. "/lua/ue/dap.lua"))()
    local asked = {}
    local provider = { log_buffer = function() end }
    d._session_owner_module = function(id)
      asked[#asked + 1] = id
      return id == "captured" and provider or nil
    end
    d._dap_session_state._ue_session_owner = "later-selection"
    t.assert_nil(d._dap_log_owner(nil))
    t.assert_nil(d._dap_log_owner({ config = {} }))
    t.assert_eq(#asked, 0)
    t.assert_eq(d._dap_log_owner({ config = { _ue_session_owner = "captured" } }), provider)
    t.assert_eq(asked[1], "captured")
    t.assert_nil(d._dap_log_owner({ config = { _ue_session_owner = "unavailable" } }))
  end)

  t.it("log and logcat alias share the fourth window and keep history on tab changes", function()
    local d = assert(loadfile(vim.fn.stdpath("config") .. "/lua/ue/dap.lua"))()
    local old_session = package.loaded["dap.session"]
    local old_persist = package.loaded["ue.dap._persist_bp"]
    local old_click = _G.UEDapBottomTabClick
    local buffers = {}
    local session = { config = { _ue_session_owner = "captured" }, stopped_thread_id = 42 }
    local function buffer(ft)
      local buf = vim.api.nvim_create_buf(false, true)
      buffers[#buffers + 1] = buf
      vim.bo[buf].bufhidden = "hide"
      vim.bo[buf].filetype = ft
      return buf
    end
    local log = buffer("log")
    vim.b[log].ue_dap_log = true
    vim.api.nvim_buf_set_lines(log, 0, -1, false, { "actual history" })
    local repl = buffer("dap-repl")
    local owner = {
      log_label = "iOS Logs",
      log_buffer = function(s)
        t.assert_eq(s, session)
        return log
      end,
    }
    local phase = function()
      return setmetatable({}, {
        __index = function(tbl, key)
          local value = {}
          rawset(tbl, key, value)
          return value
        end,
      })
    end
    local dap = {
      adapters = {},
      configurations = {},
      session = function()
        return session
      end,
      terminate = function()
        error("log must not terminate")
      end,
      listeners = { before = phase(), after = phase() },
    }
    local ui = {
      open = function() end,
      close = function() end,
      elements = { repl = {
        buffer = function()
          return repl
        end,
      } },
    }
    package.loaded["dap.session"] = { _frame_set = function() end }
    package.loaded["ue.dap._persist_bp"] = { setup = function() end }
    d.lldb_dap_path = function()
      return nil
    end
    d._session_owner_module = function(id)
      t.assert_eq(id, "captured")
      return owner
    end
    local ok, err = pcall(function()
      d.setup_dap(dap, ui)
      d.dap_bottom_tab("logcat")
      local win = d._dap_bottom_tab_win
      t.assert_eq(vim.api.nvim_win_get_buf(win), log)
      t.assert_contains(vim.wo[win].statusline, "iOS Logs")
      t.assert_false(vim.wo[win].statusline:find("Logcat", 1, true))
      d.dap_bottom_tab("repl")
      t.assert_eq(vim.api.nvim_win_get_buf(win), repl)
      t.assert_true(vim.api.nvim_buf_is_valid(log))
      d.dap_bottom_tab("log")
      t.assert_eq(d._dap_bottom_tab_win, win)
      t.assert_eq(vim.api.nvim_win_get_buf(win), log)
      t.assert_eq(vim.api.nvim_buf_get_lines(log, 0, -1, false)[1], "actual history")
      t.assert_eq(session.stopped_thread_id, 42)
    end)
    session = nil
    for _, group in ipairs({ "ue_dap_main_window_guard", "ue_dap_cleanup" }) do
      pcall(vim.api.nvim_del_augroup_by_name, group)
    end
    if d._dap_bottom_tab_win and vim.api.nvim_win_is_valid(d._dap_bottom_tab_win) then
      pcall(vim.api.nvim_win_close, d._dap_bottom_tab_win, true)
    end
    for _, buf in ipairs(buffers) do
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
    package.loaded["dap.session"] = old_session
    package.loaded["ue.dap._persist_bp"] = old_persist
    _G.UEDapBottomTabClick = old_click
    if not ok then
      error(err)
    end
  end)
end)
