local t = require("tests.harness")
local cfg = t.bootstrap()
local snacks_path = vim.fn.stdpath("data") .. "/lazy/snacks.nvim"

local function native(check)
  local dir = assert(vim.env.NVIM_TEST_RUN_ROOT) .. "/workspace-reuse-" .. tostring(vim.uv.hrtime())
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
  t.assert_true(job > 0, "owned native child startup failed")
  local function lua(code, ...)
    return vim.rpcrequest(job, "nvim_exec_lua", code, { ... })
  end
  local function input(keys)
    local encoded = lua("return vim.api.nvim_replace_termcodes(..., true, false, true)", keys)
    t.assert_true(vim.rpcrequest(job, "nvim_input", encoded) > 0)
  end
  local function eventually(code)
    local ready = vim.wait(3000, function()
      return not not lua(code)
    end, 10)
    local details = not ready
        and lua([[
      return {file=vim.fn.fnamemodify(api.nvim_buf_get_name(0),':t'),mode=vim.fn.mode(),notices=notices,
        current_win=api.nvim_get_current_win(),source_win=source_win,source_type=vim.bo[api.nvim_win_get_buf(source_win)].buftype,
        selected=picker and picker:current() and picker:current().data.kind}
    ]])
      or nil
    t.assert_true(ready, code .. (details and "\n" .. vim.inspect(details) or ""))
  end
  local function picker(query)
    input("<Space>wM")
    eventually(
      "picker=Snacks.picker.get({source='ue_workspace'})[1];return picker and not picker.closed and not picker.finder:running() and picker.input.win:valid() and vim.fn.mode()=='i'"
    )
    input(query)
    eventually("return not picker.matcher:running() and #picker:items()>0")
    -- Fuzzy matching can also match digits in a temporary parent directory.
    -- Select the intended displayed file with actual list keys, not a mock row.
    local wanted = "local item=picker:current();return item and item.data and vim.fn.fnamemodify(item.data.name or '',':t'):find("
      .. string.format("%q", query)
      .. ",1,true)~=nil"
    for _ = 1, 20 do
      if lua(wanted) then
        return
      end
      input("<C-n>")
      lua("vim.wait(10)")
    end
    error("requested Workspace file was not selected: " .. query)
  end
  lua(
    [[
    local cfg, root = ...
    vim.opt.rtp:prepend(cfg)
    vim.api.nvim_set_current_dir(root)
    vim.o.hidden, vim.o.swapfile, vim.o.shada, vim.o.more = true, false, '', false
    vim.o.columns, vim.o.lines = 120, 40
    W, api, notices = require('utils.workspace'), vim.api, {}
    vim.notify = function(message) notices[#notices+1] = tostring(message) end
    source_win, source_buf = api.nvim_get_current_win(), api.nvim_get_current_buf()
    api.nvim_buf_set_name(source_buf, root .. '/Source.txt')
    api.nvim_buf_set_lines(source_buf, 0, -1, false, {'alpha beta dirty source', 'second source line', 'third source line'})
    api.nvim_win_set_cursor(source_win,{1,4})
    other_buf = api.nvim_create_buf(true,false)
    api.nvim_buf_set_name(other_buf,root .. '/Other.txt')
    api.nvim_buf_set_lines(other_buf,0,-1,false,{'other pane work'})
    other_win = api.nvim_open_win(other_buf,false,{split='left',win=source_win})
    hidden = {}
    for i=1,3 do
      local b=api.nvim_create_buf(true,false)
      api.nvim_buf_set_name(b,root .. '/Hidden' .. i .. '.txt')
      api.nvim_buf_set_lines(b,0,-1,false,{'hidden file '..i,'hidden second line'})
      vim.bo[b].modified=false
      hidden[i]=b
    end
    vim.fn.setqflist({},' ',{title='Unrelated saved results',items={{bufnr=source_buf,lnum=2,text='saved row'}},context={owner='fixture'}})
    qf_before=vim.fn.getqflist({id=0,items=0,idx=0,title=0,context=0})
    function row_for(buf)
      for _,row in ipairs(W.list({category='buffers'})) do if row.buf==buf then return row end end
      error('hidden buffer missing')
    end
    function unchanged_other_and_qf()
      return api.nvim_win_get_buf(other_win)==other_buf
        and api.nvim_buf_get_lines(other_buf,0,1,false)[1]=='other pane work'
        and vim.deep_equal(qf_before,vim.fn.getqflist({id=0,items=0,idx=0,title=0,context=0}))
    end
    function normal_count()
      local count=0
      for _,win in ipairs(api.nvim_list_wins()) do if api.nvim_win_get_config(win).relative=='' then count=count+1 end end
      return count
    end
  ]],
    cfg,
    dir
  )
  local ok, err = pcall(check, { lua = lua, input = input, eventually = eventually, picker = picker })
  pcall(vim.fn.jobstop, job)
  pcall(vim.fn.jobwait, { job }, 1000)
  vim.fn.delete(dir, "rf")
  if not ok then
    error(err, 0)
  end
end

local function installed_picker(f)
  f.lua(
    [[
    local cfg,snacks_path=...
    vim.opt.rtp:append(snacks_path)
    Snacks=require('snacks')
    Snacks.setup({picker=dofile(cfg..'/lua/plugins/snacks.lua')[1].opts(nil,{}).picker})
    vim.g.mapleader,vim.g.maplocalleader=' ',' '
    W.setup_commands()
    dofile(cfg..'/lua/config/keymaps.lua')
  ]],
    cfg,
    snacks_path
  )
end

t.describe("ide_workspace_reuse: explicit editor destination", function()
  t.it("three hidden files reuse the same editor without adding panes or losing dirty source text", function()
    native(function(f)
      local result = f.lua([[
        local count=#api.nvim_list_wins()
        for _,buf in ipairs(hidden) do
          local win,err=W.activate(row_for(buf),{source_win=source_win,reuse=true})
          assert(win==source_win,err or 'reuse created a different editor')
          assert(api.nvim_win_get_buf(source_win)==buf)
          assert(#api.nvim_list_wins()==count,'reuse added a split')
        end
        local dirty=row_for(source_buf)
        return {dirty_found=dirty~=nil,loaded=api.nvim_buf_is_loaded(source_buf),modified=vim.bo[source_buf].modified,
          text=api.nvim_buf_get_lines(source_buf,0,1,false)[1],others=unchanged_other_and_qf()}
      ]])
      t.assert_true(result.dirty_found and result.loaded and result.modified and result.others)
      t.assert_eq(result.text, "alpha beta dirty source")
    end)
  end)

  t.it("reuse refuses non-file rows before touching their quickfix, log or task owners", function()
    native(function(f)
      f.lua([[
        local count=#api.nvim_list_wins()
        for _,kind in ipairs({'result','task','log','window'}) do
          local row={kind=kind,buf=hidden[1],name=api.nvim_buf_get_name(hidden[1]),id=qf_before.id}
          local win,err=W.activate(row,{source_win=source_win,reuse=true})
          assert(not win and type(err)=='string','reuse accepted '..kind)
          assert(#api.nvim_list_wins()==count and api.nvim_win_get_buf(source_win)==source_buf)
          assert(unchanged_other_and_qf())
        end
      ]])
    end)
  end)

  t.it("native BufLeave edits and a nested same-API view choice remain owned by the user", function()
    native(function(f)
      f.lua([[
        local chosen=api.nvim_create_buf(true,false)
        api.nvim_buf_set_lines(chosen,0,-1,false,{'new chosen view'})
        local called=0
        api.nvim_create_autocmd('BufLeave',{buffer=source_buf,once=true,nested=true,callback=function()
          called=called+1
          api.nvim_buf_set_lines(source_buf,0,1,false,{'new source input during switch'})
          api.nvim_win_set_buf(source_win,chosen)
        end})
        local win,err=W.activate(row_for(hidden[1]),{source_win=source_win,reuse=true})
        assert(not win and type(err)=='string','stale reuse was accepted')
        assert(called==1 and api.nvim_win_get_buf(source_win)==chosen,'nested user view was overwritten or blocked')
        assert(api.nvim_buf_is_loaded(source_buf) and vim.bo[source_buf].modified)
        assert(api.nvim_buf_get_lines(source_buf,0,1,false)[1]=='new source input during switch')
        assert(#vim.fn.win_findbuf(hidden[1])==0 and unchanged_other_and_qf())
      ]])
    end)
  end)

  t.it("dangerous hidden policies and non-editor sources are rejected without fallback or unloading", function()
    native(function(f)
      f.lua([[
        local row=row_for(hidden[1]);local count=normal_count()
        for _,buf in ipairs({source_buf,hidden[1]}) do
          for _,policy in ipairs({'wipe','delete','unload'}) do
            vim.bo[buf].bufhidden=policy
            local win,err=W.activate(row,{source_win=source_win,reuse=true})
            assert(not win and type(err)=='string')
            assert(api.nvim_buf_is_loaded(source_buf) and api.nvim_win_get_buf(source_win)==source_buf)
            assert(api.nvim_buf_get_lines(source_buf,0,1,false)[1]=='alpha beta dirty source')
            assert(normal_count()==count and unchanged_other_and_qf())
          end
          vim.bo[buf].bufhidden=''
        end
        vim.b[source_buf].ue_bottom_panel_kind='build'
        assert(not W.activate(row,{source_win=source_win,reuse=true}))
        vim.b[source_buf].ue_bottom_panel_kind=nil
        vim.wo[source_win].winfixbuf=true
        assert(not W.activate(row,{source_win=source_win,reuse=true}))
        vim.wo[source_win].winfixbuf=false
        api.nvim_win_close(source_win,true)
        assert(not W.activate(row,{source_win=source_win,reuse=true}))
        assert(normal_count()==count-1 and api.nvim_win_get_buf(other_win)==other_buf)
        assert(api.nvim_buf_is_loaded(source_buf) and vim.bo[source_buf].modified)
      ]])
    end)
  end)

  t.it("renamed targets are rejected and visible targets retain default cross-tab focus semantics", function()
    native(function(f)
      f.lua([[
        local stale=row_for(hidden[1])
        api.nvim_buf_set_name(hidden[1],api.nvim_buf_get_name(hidden[1])..'.renamed')
        assert(not W.activate(stale,{source_win=source_win,reuse=true}))
        local row=row_for(hidden[2])
        vim.cmd.tabnew()
        local target_win=api.nvim_get_current_win();local target_tab=api.nvim_get_current_tabpage()
        api.nvim_win_set_buf(target_win,hidden[2])
        api.nvim_set_current_win(source_win)
        local count=normal_count()
        local win,err=W.activate(row,{source_win=source_win,reuse=true})
        assert(not win and err:find('已有窗口',1,true))
        assert(api.nvim_get_current_win()==source_win and normal_count()==count)
        assert(W.activate(row)==target_win and api.nvim_get_current_tabpage()==target_tab)
        assert(normal_count()==count and unchanged_other_and_qf())
      ]])
    end)
  end)

  if vim.fn.isdirectory(snacks_path) == 0 then
    t.skip("workspace reuse actual picker", "installed Snacks unavailable", { native = true })
    return
  end

  t.it("actual wM search Ctrl-O reuses the captured nonzero-column editor three times", function()
    native(function(f)
      installed_picker(f)
      for i = 1, 3 do
        f.picker("Hidden" .. i)
        f.input("<C-o>")
        f.eventually(
          "return picker.closed and api.nvim_win_get_buf(source_win)==hidden["
            .. i
            .. "] and api.nvim_get_current_win()==source_win"
        )
        t.assert_true(f.lua("return normal_count()==2 and unchanged_other_and_qf()"))
      end
      t.assert_true(f.lua([[
        return row_for(source_buf)~=nil and api.nvim_buf_is_loaded(source_buf) and vim.bo[source_buf].modified
          and api.nvim_buf_get_lines(source_buf,0,1,false)[1]=='alpha beta dirty source'
      ]]))
    end)
  end)

  t.it("default Enter retains the source cursor and adds the original recovery split", function()
    native(function(f)
      installed_picker(f)
      f.picker("Hidden1")
      f.input("<CR>")
      f.eventually("return picker.closed and api.nvim_get_current_buf()==hidden[1]")
      t.assert_true(f.lua([[
        return normal_count()==3 and api.nvim_win_get_buf(source_win)==source_buf
          and vim.deep_equal(api.nvim_win_get_cursor(source_win),{1,4}) and unchanged_other_and_qf()
      ]]))
    end)
  end)

  t.it("new source movement or text on native picker close rejects both confirmation routes", function()
    for _, kind in ipairs({ "move", "edit" }) do
      native(function(f)
        installed_picker(f)
        f.picker("Hidden1")
        f.lua(
          [[
          local kind=...
          api.nvim_create_autocmd('WinEnter',{callback=function()
            if not picker.closed or api.nvim_get_current_win()~=source_win then return end
            if kind=='move' then vim.cmd.normal({args={'l'},bang=true})
            else api.nvim_buf_set_lines(source_buf,0,1,false,{'new close input remains'}) end
            mutation={cursor=api.nvim_win_get_cursor(source_win),tick=api.nvim_buf_get_changedtick(source_buf)}
            return true
          end})
        ]],
          kind
        )
        f.input(kind == "move" and "<C-o>" or "<CR>")
        f.eventually("return picker.closed and mutation and #notices>0")
        t.assert_true(f.lua([[
          return api.nvim_win_get_buf(source_win)==source_buf and #vim.fn.win_findbuf(hidden[1])==0
            and vim.deep_equal(api.nvim_win_get_cursor(source_win),mutation.cursor)
            and api.nvim_buf_get_changedtick(source_buf)==mutation.tick
            and normal_count()==2 and unchanged_other_and_qf()
        ]]))
      end)
    end
  end)

  t.it("Escape and a closed pending normal-mode confirmation cannot reuse an editor", function()
    native(function(f)
      installed_picker(f)
      f.picker("Hidden1")
      f.input("<Esc><Esc>")
      f.eventually("return picker.closed")
      f.lua("picker.opts.actions.workspace_reuse(picker);vim.wait(30)")
      t.assert_true(
        f.lua("return api.nvim_win_get_buf(source_win)==source_buf and normal_count()==2 and unchanged_other_and_qf()")
      )
    end)
    native(function(f)
      installed_picker(f)
      f.picker("Hidden1")
      f.lua("picker.opts.actions.workspace_reuse(picker);picker:close();vim.wait(30)")
      t.assert_true(
        f.lua(
          "return picker.closed and api.nvim_win_get_buf(source_win)==source_buf and normal_count()==2 and unchanged_other_and_qf()"
        )
      )
    end)
  end)

  t.it("default terminal recovery tolerates real output changes while the selector is open", function()
    for _, target in ipairs({ "file", "log" }) do
      native(function(f)
        installed_picker(f)
        f.lua([[
          term=api.nvim_create_buf(false,true)
          api.nvim_win_set_buf(source_win,term)
          term_channel=api.nvim_open_term(term,{})
          api.nvim_chan_send(term_channel,'initial owned output\r\n')
          api.nvim_buf_set_name(term,'OwnedStreamingTerminal')
          retained=api.nvim_create_buf(false,true)
          vim.bo[retained].buftype='nofile'
          api.nvim_buf_set_name(retained,'RetainedOutput')
          api.nvim_buf_set_lines(retained,0,-1,false,{'retained log content'})
          vim.b[retained].ue_bottom_panel_kind='build'
          vim.cmd.startinsert()
        ]])
        f.eventually("return vim.fn.mode()=='t'")
        f.picker(target == "file" and "Hidden1" or "RetainedOutput")
        f.lua([[
          term_tick=api.nvim_buf_get_changedtick(term)
          for i=1,8 do api.nvim_chan_send(term_channel,'new streaming output '..i..'\r\n') end
        ]])
        f.eventually("return api.nvim_buf_get_changedtick(term)>term_tick")
        f.input("<CR>")
        f.eventually(
          "return picker.closed and api.nvim_get_current_buf()==" .. (target == "file" and "hidden[1]" or "retained")
        )
        t.assert_true(
          f.lua(
            "return api.nvim_buf_is_loaded(term) and api.nvim_buf_get_name(term):find('OwnedStreamingTerminal',1,true)~=nil"
          )
        )
      end)
    end
  end)
end)
