local t = require("tests.harness")
local cfg = t.bootstrap()

-- Actual Neovim owns the buffers, windows, marks, registers and jump history.
-- Only M.input's callback transport and the '+' clipboard provider are
-- seams. These cases do not certify installed Snacks input or system clipboard.
local function native(check)
  local run_root = vim.fs.normalize(assert(vim.env.NVIM_TEST_RUN_ROOT)):gsub("/$", "")
  local dir = run_root .. "/document-location-" .. tostring(vim.uv.hrtime())
  local absolute = vim.fs.normalize(vim.fn.fnamemodify(dir, ":p")):gsub("/$", "")
  t.assert_true(absolute:sub(1, #run_root + 1) == run_root .. "/", "fixture must stay inside its owned root")
  vim.fn.mkdir(dir, "p")
  local job = vim.fn.jobstart({ vim.v.progpath, "--headless", "--embed", "-u", "NONE", "-i", "NONE", "-n" }, {
    rpc = true,
    env = {
      XDG_DATA_HOME = dir .. "/data",
      XDG_STATE_HOME = dir .. "/state",
      XDG_CACHE_HOME = dir .. "/cache",
      NVIM_UE_PROBE_PATH = dir .. "/probes.json",
      NVIM_UE_LOG_DIR = dir .. "/logs",
      NVIM_LOG_FILE = dir .. "/nvim.log",
    },
  })
  t.assert_true(job > 0, "owned native Neovim did not start")
  local f, sequence = {}, 0
  ---@return any
  function f.lua(code, ...)
    return vim.rpcrequest(job, "nvim_exec_lua", code, { ... })
  end
  function f.input(keys)
    sequence = sequence + 1
    local input = keys .. "<Cmd>let g:location_input_done = " .. sequence .. "<CR>"
    t.assert_eq(vim.rpcrequest(job, "nvim_input", input), #input)
    t.assert_true(
      vim.wait(1000, function()
        return f.lua("return vim.g.location_input_done") == sequence
      end, 5),
      "native input did not complete"
    )
  end
  local ok, err = xpcall(function()
    f.lua(
      [[
      local cfg, root = ...
      vim.opt.rtp:prepend(cfg)
      package.path = cfg .. '/lua/?.lua;' .. cfg .. '/lua/?/init.lua;' .. package.path
      api, L = vim.api, require('utils.document_location')
      vim.o.hidden, vim.o.swapfile, vim.o.shada, vim.o.clipboard = true, false, '', ''
      api.nvim_set_current_dir(root)
      fixture_root = root
      vim.fn.mkdir(root .. '/project/Folder Space', 'p')
      source_path = root .. '/project/Folder Space/source file.cpp'
      vim.fn.writefile({'disk baseline'}, source_path)
      vim.cmd.edit(vim.fn.fnameescape(source_path))
      source_win, source_buf, source_tab = api.nvim_get_current_win(), api.nvim_get_current_buf(), api.nvim_get_current_tabpage()
      api.nvim_buf_set_lines(source_buf, 0, -1, false, {'alpha beta source', '你 α x', ''})
      api.nvim_win_set_cursor(source_win, {3, 0})
      vim.cmd("normal! m'")
      api.nvim_win_set_cursor(source_win, {1, 4})
      vim.cmd.clearjumps()
      vim.fn.setreg('"', 'keep unnamed', 'v')
      vim.fn.setreg('0', 'keep yank zero', 'v')
      vim.fn.setreg('a', 'keep named register', 'v')
      -- Exercise the real unnamed-register alias after an explicit named yank.
      vim.fn.setreg('"', {points_to='a'})
      assert(vim.fn.getreginfo('"').points_to=='a')
      vim.fn.setqflist({}, ' ', {title='unrelated results', items={{bufnr=source_buf,lnum=2,col=5,text='saved result'}}, context={owner='fixture'}})
      prompts, notices, plus_calls = {}, {}, {}
      -- Callback-only input transport; it never creates a fake picker/window.
      L.input = function(options, callback)
        prompts[#prompts+1] = {options=options, callback=callback}
      end
      vim.notify = function(message) notices[#notices+1] = tostring(message) end
      local setreg = vim.fn.setreg
      local function provider_boundary(register, value, ...)
        if register == '+' then
          plus_calls[#plus_calls+1] = value
          if clipboard_failure then error('controlled provider unavailable') end
          return 0
        end
        return setreg(register, value, ...)
      end
      vim.fn.setreg = provider_boundary
      function snapshot()
        local buf = api.nvim_get_current_buf()
        return {
          win=api.nvim_get_current_win(), tab=api.nvim_get_current_tabpage(), buf=buf,
          name=api.nvim_buf_get_name(buf), cursor=api.nvim_win_get_cursor(0), text=api.nvim_buf_get_lines(buf,0,-1,false),
          tick=api.nvim_buf_get_changedtick(buf), modified=vim.bo[buf].modified,
          source_text=api.nvim_buf_is_loaded(source_buf) and api.nvim_buf_get_lines(source_buf,0,-1,false) or false,
          unnamed=vim.fn.getreginfo('"'), zero=vim.fn.getreginfo('0'), named={text=vim.fn.getreg('a'),type=vim.fn.getregtype('a')},
          previous=vim.fn.getpos("''"), jumps=vim.fn.getjumplist(),
          qf=vim.fn.getqflist({id=0,items=0,idx=0,title=0,context=0}),
          wins=api.nvim_list_wins(), tabs=api.nvim_list_tabpages(), disk=vim.fn.readfile(source_path),
        }
      end
      function answer(value, index)
        assert(prompts[index or #prompts], 'input was not opened').callback(value)
      end
      function assert_untouched(before)
        assert(vim.deep_equal(before,snapshot()), 'callback changed native view, text, registers, quickfix or history')
      end
      function assert_noncopy_state(before)
        local after = snapshot()
        -- Copy owns the normal yank slot and unnamed alias, never register a.
        after.unnamed, after.zero = before.unnamed, before.zero
        local changed={}
        for field,value in pairs(before) do
          if not vim.deep_equal(value,after[field]) then changed[#changed+1]=field end
        end
        table.sort(changed)
        assert(#changed==0, 'copy changed fields: '..table.concat(changed,',')..'; original unnamed target='..tostring(before.unnamed.points_to))
      end
      return true
    ]],
      cfg,
      dir
    )
    check(f)
  end, debug.traceback)
  pcall(vim.fn.jobstop, job)
  pcall(vim.fn.jobwait, { job }, 1000)
  vim.fn.delete(absolute, "rf")
  if not ok then
    error(err, 0)
  end
end

t.describe("document location parser against native buffer rows", function()
  t.it("accepts positive lines and one-based byte columns without moving the editor", function()
    native(function(f)
      f.lua([[
        local before=snapshot()
        assert(vim.deep_equal(assert(L.resolve('2',source_buf)),{2,0}))
        assert(vim.deep_equal(assert(L.resolve(' 1:5 ',source_buf)),{1,4}))
        assert(vim.deep_equal(assert(L.resolve('001:01',source_buf)),{1,0}))
        assert_untouched(before)
      ]])
    end)
  end)
  t.it("accepts the last ASCII byte but refuses the exclusive end-of-line position", function()
    native(function(f)
      f.lua([[
        assert(vim.deep_equal(assert(L.resolve('1:17',source_buf)),{1,16}))
        local pos,err=L.resolve('1:18',source_buf)
        assert(pos==nil and type(err)=='string')
      ]])
    end)
  end)
  t.it("validates actual multibyte character starts rather than character counts", function()
    native(function(f)
      f.lua([[
        for _,column in ipairs({1,4,5,7,8}) do
          assert(vim.deep_equal(assert(L.resolve('2:'..column,source_buf)),{2,column-1}))
        end
        for _,column in ipairs({2,3,6,9}) do
          local pos,err=L.resolve('2:'..column,source_buf)
          assert(pos==nil and type(err)=='string','invalid UTF8 byte accepted: '..column)
        end
      ]])
    end)
  end)
  t.it("allows only column one on an empty final logical line", function()
    native(function(f)
      f.lua([[
        assert(vim.deep_equal(assert(L.resolve('3',source_buf)),{3,0}))
        assert(vim.deep_equal(assert(L.resolve('3:1',source_buf)),{3,0}))
        for _,input in ipairs({'3:2','4','4:1'}) do
          local pos,err=L.resolve(input,source_buf)
          assert(pos==nil and type(err)=='string',input)
        end
      ]])
    end)
  end)
  t.it("rejects blank, zero, negative, decimal, exponent and malformed colon inputs", function()
    native(function(f)
      f.lua([[
        local before=snapshot()
        for _,input in ipairs({'',' ','0','-1','1:0','1:-2','1.5','1e1',':2','1:','1::2','1:2:3','1 | quit','1:2'..string.char(10)..'3'}) do
          local pos,err=L.resolve(input,source_buf)
          assert(pos==nil and type(err)=='string','malformed position accepted: '..input)
        end
        assert_untouched(before)
      ]])
    end)
  end)
  t.it("refuses large numbers and enforces the raw 64-byte input budget before trim", function()
    native(function(f)
      f.lua([[
        assert(vim.deep_equal(assert(L.resolve(string.rep('0',63)..'1',source_buf)),{1,0}))
        for _,input in ipairs({'999999','1:999999',string.rep('9',64),string.rep('0',64)..'1',string.rep(' ',64)..'1'}) do
          local pos,err=L.resolve(input,source_buf)
          assert(pos==nil and type(err)=='string','out-of-budget position accepted')
        end
      ]])
    end)
  end)
  t.it("refuses an actually unloaded or deleted buffer with a readable error", function()
    native(function(f)
      f.lua([[
        local buf=api.nvim_create_buf(true,false)
        api.nvim_buf_set_lines(buf,0,-1,false,{'hidden row'})
        api.nvim_buf_delete(buf,{force=true,unload=true})
        assert(api.nvim_buf_is_valid(buf) and not api.nvim_buf_is_loaded(buf))
        local pos,err=L.resolve('1',buf)
        assert(pos==nil and type(err)=='string')
        api.nvim_buf_delete(buf,{force=true})
        pos,err=L.resolve('1',buf)
        assert(pos==nil and type(err)=='string')
      ]])
    end)
  end)
end)

t.describe("document location native jump and history", function()
  t.it(
    "a cross-line byte jump returns once with actual Ctrl-O and leaves dirty text, registers and quickfix intact",
    function()
      native(function(f)
        f.lua([[
        before=snapshot()
        L.open(); answer('2:5')
        assert(vim.deep_equal(api.nvim_win_get_cursor(0),{2,4}))
        local after=snapshot()
        assert(after.previous[2]==1 and after.previous[3]==5)
        assert(#after.jumps[1]==#before.jumps[1]+1)
        for _,field in ipairs({'text','tick','modified','source_text','unnamed','zero','named','qf','disk','wins','tabs'}) do
          assert(vim.deep_equal(before[field],after[field]),'jump changed '..field)
        end
      ]])
        f.input("<C-o>")
        t.assert_true(
          f.lua("return vim.deep_equal(api.nvim_win_get_cursor(0),{1,4}) and api.nvim_get_current_buf()==source_buf")
        )
      end)
    end
  )
  t.it("same-line jumps preserve the precise native previous-context column for double backtick", function()
    native(function(f)
      f.lua("L.open(); answer('1:9'); assert(vim.deep_equal(api.nvim_win_get_cursor(0),{1,8}))")
      f.input("``")
      t.assert_true(f.lua("return vim.deep_equal(api.nvim_win_get_cursor(0),{1,4})"))
    end)
  end)
  t.it("opens a real closed fold at the destination without modifying its text", function()
    native(function(f)
      f.lua([[
        vim.wo.foldmethod='manual'
        vim.cmd('2,3fold')
        api.nvim_win_set_cursor(0,{1,4})
        assert(vim.fn.foldclosed(3)==2)
        local before=api.nvim_buf_get_lines(0,0,-1,false)
        L.open(); answer('3:1')
        assert(vim.deep_equal(api.nvim_win_get_cursor(0),{3,0}))
        assert(vim.fn.foldclosed(3)==-1)
        assert(vim.deep_equal(before,api.nvim_buf_get_lines(0,0,-1,false)))
      ]])
    end)
  end)
  t.it("jumps within dirty unnamed documents without creating or saving a path", function()
    native(function(f)
      f.lua([[
        api.nvim_buf_set_name(source_buf,'')
        local before=snapshot()
        L.open(); answer('2:5')
        assert(vim.deep_equal(api.nvim_win_get_cursor(0),{2,4}))
        assert(api.nvim_buf_get_name(source_buf)=='' and vim.bo[source_buf].modified)
        assert(vim.deep_equal(before.text,api.nvim_buf_get_lines(source_buf,0,-1,false)))
        assert(vim.deep_equal(before.disk,vim.fn.readfile(source_path)))
      ]])
    end)
  end)
  t.it("an already-current position is a complete native history no-op", function()
    native(function(f)
      f.lua("local before=snapshot(); L.open(); answer('1:5'); assert_untouched(before)")
    end)
  end)
end)

t.describe("document location input ownership with callback transport seam", function()
  t.it("nil cancellation has no effect and consumes the callback once", function()
    native(function(f)
      f.lua("local before=snapshot(); L.open(); answer(nil); answer('2:5'); assert_untouched(before)")
    end)
  end)
  t.it("invalid submitted input cannot alter marks or later reuse its callback", function()
    native(function(f)
      f.lua([[
        local before=snapshot()
        L.open(); answer(''); answer('2:5')
        assert(#notices>0)
        assert_untouched(before)
      ]])
    end)
  end)
  t.it("a duplicate successful callback cannot overwrite later cursor intent", function()
    native(function(f)
      f.lua([[
        L.open(); answer('2:5')
        api.nvim_win_set_cursor(0,{3,0})
        local before=snapshot()
        answer('1:1')
        assert_untouched(before)
      ]])
    end)
  end)
  t.it("a newer dialog revokes the old callback before native marks or jumps", function()
    native(function(f)
      f.lua([[
        local before=snapshot()
        L.open(); L.open()
        assert(#prompts==2)
        answer('2:5',1)
        assert_untouched(before)
        answer('3:1',2)
        assert(vim.deep_equal(api.nvim_win_get_cursor(0),{3,0}))
      ]])
    end)
  end)
  for _, change in ipairs({
    { "cursor", "api.nvim_win_set_cursor(source_win,{1,6})" },
    {
      "text revision even when modified was cleared",
      "api.nvim_buf_set_lines(source_buf,0,1,false,{'new user draft'}); vim.bo[source_buf].modified=false",
    },
    { "file name", "api.nvim_buf_set_name(source_buf,fixture_root..'/renamed.cpp')" },
    {
      "buffer identity",
      "local b=api.nvim_create_buf(true,false); api.nvim_buf_set_lines(b,0,-1,false,{'new document intent'}); api.nvim_win_set_buf(source_win,b)",
    },
    { "current window", "vim.cmd.vsplit()" },
    { "current tab", "vim.cmd.tabnew()" },
    { "closed source window", "vim.cmd.vsplit(); api.nvim_win_close(source_win,true)" },
  }) do
    t.it("rejects late confirmation after changed " .. change[1], function()
      native(function(f)
        f.lua("L.open()")
        f.lua(change[2])
        f.lua("local before=snapshot(); answer('2:5'); assert_untouched(before); assert(#notices>0)")
      end)
    end)
  end
end)

t.describe("document location clipboard with native unnamed register", function()
  t.it("copies absolute and window-cwd-relative paths without saving or moving", function()
    native(function(f)
      f.lua([[
        local fs=require('ue.core.fs')
        local before=snapshot()
        assert(L.copy('absolute')==fs.norm(source_path))
        assert(vim.fn.getreg('"')==fs.norm(source_path))
        assert(vim.fn.getreg('0')==fs.norm(source_path) and vim.fn.getreginfo('"').points_to=='0')
        assert(plus_calls[1]==fs.norm(source_path))
        assert_noncopy_state(before)
        vim.cmd.lcd(vim.fn.fnameescape(fixture_root..'/project'))
        before=snapshot()
        assert(L.copy('relative')=='Folder Space/source file.cpp')
        assert(vim.fn.getreg('"')=='Folder Space/source file.cpp')
        assert(vim.fn.getreg('0')=='Folder Space/source file.cpp')
        assert(plus_calls[2]=='Folder Space/source file.cpp')
        assert(fs.norm(vim.fn.getcwd(-1,-1))==fs.norm(fixture_root))
        assert(notices[#notices]:find('当前窗口工作目录',1,true))
        assert_noncopy_state(before)
      ]])
    end)
  end)
  t.it("quotes paths with spaces and roundtrips exact dirty-buffer UTF8 byte positions", function()
    native(function(f)
      f.lua([[
        api.nvim_win_set_cursor(0,{2,4})
        local before=snapshot()
        local value=assert(L.copy('position'))
        assert(value:sub(1,1)=='"' and value:sub(-4)==':2:5')
        local parsed=require('utils.file_query').parse(value)
        assert(parsed.pattern==require('ue.core.fs').norm(source_path))
        assert(vim.deep_equal(parsed.pos,{2,4}))
        assert(vim.fn.getreg('"')==value and plus_calls[1]==value)
        assert(vim.fn.getreg('0')==value and vim.fn.getreginfo('"').points_to=='0')
        assert(notices[#notices]:find('UTF-8 字节列',1,true))
        assert_noncopy_state(before)
        api.nvim_win_set_cursor(0,{1,0})
        L.open(); answer(parsed.pos[1]..':'..(parsed.pos[2]+1))
        assert(vim.deep_equal(api.nvim_win_get_cursor(0),parsed.pos))
        assert(vim.bo[source_buf].modified and vim.fn.readfile(source_path)[1]=='disk baseline')
      ]])
    end)
  end)
  t.it("retains actual unnamed text and reports a '+' provider failure honestly", function()
    native(function(f)
      f.lua([[
        clipboard_failure=true
        local before=snapshot()
        local value=assert(L.copy('position'))
        assert(vim.fn.getreg('"')==value and #plus_calls==1)
        assert(vim.fn.getreg('0')==value)
        assert(notices[#notices]:find('系统剪贴板不可用',1,true))
        assert(notices[#notices]:find('未命名寄存器',1,true))
        assert_noncopy_state(before)
      ]])
    end)
  end)
  t.it("unnamed documents refuse every copy kind without overwriting either register boundary", function()
    native(function(f)
      f.lua([[
        api.nvim_buf_set_name(source_buf,'')
        local before=snapshot()
        for _,kind in ipairs({'absolute','relative','position'}) do assert(L.copy(kind)==nil) end
        assert(#plus_calls==0 and #notices==3)
        assert_untouched(before)
      ]])
    end)
  end)
  for _, source in ipairs({
    { "a nofile panel", "vim.bo[source_buf].buftype='nofile'" },
    {
      "a floating ordinary buffer",
      "api.nvim_open_win(source_buf,true,{relative='editor',row=2,col=2,width=40,height=8})",
    },
  }) do
    t.it("refuses jump and copy from " .. source[1] .. " before invoking their transports", function()
      native(function(f)
        f.lua(source[2])
        f.lua([[
          local before=snapshot()
          L.open()
          for _,kind in ipairs({'absolute','relative','position'}) do assert(L.copy(kind)==nil) end
          assert(#prompts==0 and #plus_calls==0 and #notices==4)
          assert_untouched(before)
        ]])
      end)
    end)
  end
end)
