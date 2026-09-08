local t = require("tests.harness")
t.bootstrap()

-- Each scenario runs real production modules in its own Neovim. Process and
-- device boundaries are faked; no adapter or connected device is exercised.
local function child(code)
  local result = vim.system({ vim.v.progpath, "--headless", "-u", "NONE", "-i", "NONE",
    "--cmd", "set rtp+=" .. vim.fn.stdpath("config"),
    "-c", "lua " .. code, "-c", "qa!" }, { text = true }):wait()
  t.assert_eq(result.code, 0, result.stderr)
  t.assert_true(not (result.stderr or ""):find("Error", 1, true), result.stderr)
  t.assert_true((result.stderr or ""):find("REVIEW_OK", 1, true) ~= nil, result.stderr)
end

t.describe("review DAP and workflow ownership", function()
  t.it("desktop binary prompt accepts an existing file", function()
    child([[
      vim.fn.input=function() return vim.v.progpath end
      assert(require('ue.dap._common').prompt_binary()==vim.v.progpath)
      print('REVIEW_OK')
    ]])
  end)

  t.it("breakpoint A-B-A handoff isolates engine breakpoints and preserves unrelated live entries", function()
    child([[
      local root=vim.fn.tempname():gsub('\\','/')
      local which='A'
      local b=vim.api.nvim_create_buf(true,false)
      local foreign=vim.api.nvim_create_buf(true,false)
      vim.api.nvim_buf_set_name(b,root..'/Engine/Shared.cpp')
      vim.api.nvim_buf_set_name(foreign,root..'/Unrelated.cpp')
      local store={[b]={{line=1}}}
      package.loaded['ue']={resolve_context=function() return {engine_root=root,project_root=root..'/'..which,paths={cache=root..'/'..which}} end}
      package.loaded['dap.breakpoints']={get=function() return store end,
        set=function(opts,buf,line) store[buf]=store[buf] or {}; table.insert(store[buf],{line=line}) end,
        remove=function(buf,line) for i=#(store[buf] or {}),1,-1 do if store[buf][i].line==line then table.remove(store[buf],i) end end end}
      package.loaded['dap']={session=function() end}
      local p=require('ue.dap._persist_bp')
      p.load(); p.save()
      store[foreign]={{line=7}}
      which='B'; p.load(); p.save()
      local data=vim.json.decode(table.concat(vim.fn.readfile(root..'/B/breakpoints.json'),' '))
      assert(not data.breakpoints[root..'/Engine/Shared.cpp'],'A breakpoint leaked into B')
      assert(store[foreign][1].line==7,'unowned breakpoint was cleared')
      store[b]={{line=2}}; p.save()
      which='A'; p.load()
      assert(#store[b]==1 and store[b][1].line==1,'A engine breakpoint was not restored independently')
      p._reset_state_for_test(); vim.fn.delete(root,'rf'); print('REVIEW_OK')
    ]])
  end)

  t.it("an active DAP session retains its breakpoint bucket until it ends", function()
    child([[
      local root=vim.fn.tempname():gsub('\\','/'); local which='A'; local active
      local b=vim.api.nvim_create_buf(true,false); vim.api.nvim_buf_set_name(b,root..'/Shared.cpp')
      local store={[b]={{line=1}}}
      package.loaded['ue']={resolve_context=function() return {engine_root=root,paths={cache=root..'/'..which}} end}
      package.loaded['dap.breakpoints']={get=function() return store end,set=function() error('must not restore B into A session') end,
        remove=function(buf,line) store[buf]={} end}
      package.loaded['dap']={session=function() return active end}
      local p=require('ue.dap._persist_bp'); p.load(); p.save()
      active={}; which='B'; p.load(); p.save()
      assert(store[b][1].line==1,'active session breakpoint removed')
      assert(vim.fn.filereadable(root..'/B/breakpoints.json')==0,'active A store persisted to B')
      active=nil; p.load(); p.save()
      local data=vim.json.decode(table.concat(vim.fn.readfile(root..'/B/breakpoints.json'),' '))
      assert(not data.breakpoints[root..'/Shared.cpp'])
      p._reset_state_for_test(); vim.fn.delete(root,'rf'); print('REVIEW_OK')
    ]])
  end)

  for _, scenario in ipairs({ { 'launch', 'coredevice' }, { 'install', 'coredevice' }, { 'install', 'legacy-mobiledevice' } }) do
    local operation, backend = unpack(scenario)
    t.it("iOS " .. backend .. " " .. operation .. " completion persists to captured project after selection changes", function()
      child(([[
        local operation=%q
        local backend=%q
        local ue=require('ue'); local ps=require('ue.project_state')
        local root=vim.fn.tempname():gsub('\\','/'); local a=root..'/A'; local b=root..'/B'
        assert(ps.select(root,a,a..'/A.uproject'))
        local complete
        local driver={id='IOS',launch_plan=function() return {} end,install_plan=function() return {metadata={backend=backend}} end,
          parse_launch_result=function() return {ok=true,process_id=42} end,parse_install_result=function() return {ok=true} end}
        package.loaded['utils.platform']={driver=function() return {} end}
        package.loaded['ue.targets']={resolve=function() return driver end}
        package.loaded['ue.target_tasks']={progress=function() return {report=function() end,finish=function() end} end,
          run=function(_,opts) complete=opts.on_exit; return {} end}
        package.loaded['ue.workflows.ios.common']={with_target_bundle_id=function(_,_,_,_,done) done('app.A',{}) end,
          prepare_legacy_install=function() return true end}
        local deps={resolve_context=function() return {engine_root=root,project_root=a,uproject=a..'/A.uproject'} end,
          target_context=function() return {device_id='test-device',device_backend=backend},nil,driver end,
          target_launch_running={},target_error=error,run_target_preflight=function(_,_,_,_,done) done(true) end,
          read_result_file=function() return {} end,update_target_runtime=ue._update_target_runtime_for_test}
        local workflow=require('ue.workflows.ios.'..operation)
        if operation=='launch' then workflow.launch('IOS',{},deps) else workflow.install('IOS',deps) end
        assert(ps.select(root,b,b..'/B.uproject')); complete({code=0})
        assert(not ps.read(root).target_runtime,'A result leaked into selected B')
        assert(ps.select(root,a,a..'/A.uproject'))
        assert(ps.read(root).target_runtime.IOS.bundle_id=='app.A','A result was lost')
        vim.fn.delete(root,'rf'); print('REVIEW_OK')
      ]]):format(operation, backend))
    end)
  end
end)
