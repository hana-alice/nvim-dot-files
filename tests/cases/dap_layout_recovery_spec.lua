local t = require("tests.harness")
t.bootstrap()

local function child(body)
  local setup = [=[
    local d = assert(loadfile(vim.fn.stdpath('config') .. '/lua/ue/dap.lua'))()
    local function phase()
      return setmetatable({}, {__index=function(tbl,key) local v={}; rawset(tbl,key,v); return v end})
    end
    local active, cleanup_count, end_count = nil, 0, 0
    local source = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_lines(source, 0, -1, false, {'one','two','three','four'})
    vim.bo[source].filetype = 'cpp'
    vim.api.nvim_set_current_buf(source)
    local code_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_cursor(code_win, {3, 1})
    local empty = vim.api.nvim_create_buf(true, false)
    local repl = vim.api.nvim_create_buf(false, true)
    vim.bo[repl].filetype = 'dap-repl'
    local log = vim.api.nvim_create_buf(false, true)
    vim.bo[log].filetype = 'log'
    vim.bo[log].bufhidden = 'hide'
    vim.b[log].ue_dap_log = true
    vim.api.nvim_buf_set_lines(log,0,-1,false,{'retained history'})
    local dap = {adapters={},configurations={},listeners={before=phase(),after=phase()},
      session=function() return active end, terminate=function() error('UI must not terminate') end}
    local ui = {open=function() end,close=function()
      -- dapui can restore the buffer that preceded the current source frame.
      if vim.api.nvim_win_is_valid(code_win) then vim.api.nvim_win_set_buf(code_win,empty) end
    end,elements={repl={buffer=function() return repl end}}}
    package.loaded['dap.session'] = {_frame_set=function() end}
    package.loaded['ue.dap._persist_bp'] = {setup=function() end}
    package.loaded['ue.targets'] = {supports=function() return false end}
    package.loaded['ue.dap.platforms'] = {
      bind_session=function(s) return {session=s} end,
      dispatch_lifecycle=function(kind) assert(kind=='cleanup'); cleanup_count=cleanup_count+1 end,
      end_session=function() end_count=end_count+1 end,
    }
    d.lldb_dap_path=function() return nil end
    d.ensure_dap_loaded=function() return true,dap end
    d.ensure_dapui_loaded=function() return true,ui end
    d._session_owner_module=function() return {log_buffer=function() return log end} end
    d.setup_dap(dap,ui)
    local function start()
      active={config={_ue_session_owner='captured'},on_close={}}
      dap.listeners.after.event_initialized.dapui_config(active)
      return active
    end
  ]=]
  local result = vim
    .system({
      vim.v.progpath,
      "--headless",
      "-u",
      "NONE",
      "-i",
      "NONE",
      "--cmd",
      "set rtp+=" .. vim.fn.stdpath("config"),
      "-c",
      "lua " .. setup .. body .. "; print('LAYOUT_OK')",
      "-c",
      "qa!",
    }, { text = true })
    :wait()
  t.assert_eq(result.code, 0, result.stderr)
  t.assert_true((result.stderr or ""):find("LAYOUT_OK", 1, true) ~= nil, result.stderr)
end

t.describe("DAP layout recovery", function()
  t.it("a session ending before initialized still dispatches its normal cleanup once", function()
    child([=[
      active={config={_ue_session_owner='captured'},on_close={}}
      local session=active
      dap.listeners.on_session.ue_dap_layout(nil,session)
      active=nil
      dap.listeners.before.event_terminated.dapui_config(session)
      dap.listeners.before.event_exited.dapui_config(session)
      assert(cleanup_count==1 and end_count==1,'pre-initialized cleanup was skipped or duplicated')
      assert(vim.api.nvim_win_get_buf(code_win)==source,'untouched editor was restored unnecessarily')
    ]=])
  end)

  t.it("adapter EOF restores source and cursor without dispatching device cleanup", function()
    child([=[
      local session=start()
      d.dap_bottom_tab('log')
      local win=d._dap_bottom_tab_win
      assert(vim.api.nvim_win_is_valid(win))
      local scratch=vim.api.nvim_create_buf(false,true)
      vim.bo[scratch].filetype='notes'
      local scratch_win=vim.api.nvim_open_win(scratch,false,{relative='editor',row=0,col=0,width=10,height=2})
      active=nil
      assert(type(session.on_close.ue_dap_layout)=='function','no UI EOF callback')
      session.on_close.ue_dap_layout(session)
      vim.wait(50)
      assert(not vim.api.nvim_win_is_valid(win),'log window survived EOF')
      assert(vim.api.nvim_win_get_buf(code_win)==source,'source was replaced by UI teardown')
      assert(vim.deep_equal(vim.api.nvim_win_get_cursor(code_win),{3,1}),'source cursor moved')
      assert(vim.api.nvim_win_is_valid(scratch_win),'unrelated scratch was closed')
      assert(vim.api.nvim_buf_get_lines(log,0,-1,false)[1]=='retained history')
      assert(cleanup_count==0 and end_count==0,'UI close must not dispatch device lifecycle')
      dap.listeners.before.event_terminated.dapui_config(session)
      dap.listeners.after.disconnect.dapui_config(session)
      assert(cleanup_count==1 and end_count==1,'normal end cleanup must run once after EOF')
    ]=])
  end)

  t.it("a queued old EOF and old protocol end cannot close a new session layout", function()
    child([=[
      local old=start()
      assert(type(old.on_close.ue_dap_layout)=='function','no UI EOF callback')
      old.on_close.ue_dap_layout(old)
      local new=start()
      local win=d._dap_bottom_tab_win
      vim.wait(50)
      dap.listeners.before.event_terminated.dapui_config(old)
      assert(vim.api.nvim_win_is_valid(win),'old end closed new UI')
      assert(cleanup_count==0 and end_count==0,'old end cleared new owner')
      assert(active==new)
    ]=])
  end)

  t.it("inactive reset recovers manually opened panels and preserves the current source", function()
    child([=[
      d.dap_toggle_ui()
      local win=d._dap_bottom_tab_win
      vim.api.nvim_set_current_win(win)
      d.dap_reset_layout()
      assert(not vim.api.nvim_win_is_valid(win),'manual bottom panel survived reset')
      assert(vim.api.nvim_win_get_buf(code_win)==source,'reset lost source')
      assert(vim.deep_equal(vim.api.nvim_win_get_cursor(code_win),{3,1}))
      assert(vim.api.nvim_get_current_win()==code_win,'reset did not focus source')
      assert(cleanup_count==0 and end_count==0)
      d.dap_reset_layout()
      assert(vim.api.nvim_win_get_buf(code_win)==source,'repeated reset lost source')
    ]=])
  end)
end)
