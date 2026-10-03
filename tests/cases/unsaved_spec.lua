local t = require("tests.harness")
local cfg = t.bootstrap()

local function child(code, event_loop)
  local script = vim.fn.tempname() .. ".lua"
  vim.fn.writefile(vim.split(("vim.opt.rtp:prepend(%q)\n%s"):format(cfg, code), "\n", { plain = true }), script)
  local command = { vim.v.progpath, "--headless", "-u", "NONE", "-i", "NONE", "-n" }
  vim.list_extend(command, event_loop and { "-c", ("lua dofile(%q)"):format(script) } or { "-l", script })
  local result = vim.system(command, { text = true }):wait(10000)
  vim.fn.delete(script)
  t.assert_eq(result.code, 0, (result.stdout or "") .. (result.stderr or ""))
  t.assert_contains((result.stdout or "") .. (result.stderr or ""), "UNSAVED_OK")
end

t.describe("unsaved: 事件缓存与退出保护", function()
  t.it("修改、保存、隐藏未列出和删除事件更新总数；无定时器", function()
    child(
      [[
      local unsaved = require('utils.unsaved')
      local function step(fn)
        vim.defer_fn(function()
          local ok, err = pcall(fn)
          if not ok then print(err); vim.cmd('cquit 1') end
        end, 30)
      end
      unsaved.setup()
      local buf = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, {'dirty'})
      vim.api.nvim_set_current_buf(buf)
      step(function()
        assert(vim.g.ue_unsaved_count == 1, tostring(vim.g.ue_unsaved_count))
        vim.bo[buf].buflisted = false
        assert(vim.g.ue_unsaved_count == 1, 'hidden/unlisted dirty buffer must count')
        vim.bo[buf].modified = false
        step(function()
          assert(vim.g.ue_unsaved_count == 0)
          vim.bo[buf].modified = true
          step(function()
            assert(vim.g.ue_unsaved_count == 1)
            vim.api.nvim_buf_delete(buf, {force=true})
            assert(vim.g.ue_unsaved_count == 0)
            assert(vim.g.ue_unsaved_status == '')
            print('UNSAVED_OK')
            vim.cmd('qa!')
          end)
        end)
      end)
    ]],
      true
    )
  end)

  t.it("bdelete 和 API unload 完成后无幽灵计数，隐藏未列出修改仍计数", function()
    child([[
      local unsaved = require('utils.unsaved')
      unsaved.setup()
      for _, named in ipairs({false, true}) do
        for _, method in ipairs({'bdelete', 'unload'}) do
          local buf = vim.api.nvim_create_buf(true, false)
          if named then vim.api.nvim_buf_set_name(buf, vim.fn.tempname() .. '.cpp') end
          vim.api.nvim_buf_set_lines(buf, 0, -1, false, {'discarded edit'})
          vim.wait(20)
          assert(vim.g.ue_unsaved_count == 1)
          if method == 'bdelete' then
            vim.cmd('bdelete! ' .. buf)
          else
            vim.api.nvim_buf_delete(buf, {unload=true, force=true})
          end
          vim.wait(100)
          assert(vim.api.nvim_buf_is_valid(buf), 'must test unload, not wipeout')
          assert(not vim.api.nvim_buf_is_loaded(buf))
          assert(#unsaved.list() == 0)
          assert(vim.g.ue_unsaved_count == 0, method .. ': ghost count ' .. vim.g.ue_unsaved_count)
          assert(vim.g.ue_unsaved_status == '')
          vim.api.nvim_buf_delete(buf, {force=true})
        end
      end
      local hidden = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_lines(hidden, 0, -1, false, {'keep hidden edit'})
      vim.wait(20)
      vim.bo[hidden].buflisted = false
      vim.wait(100)
      assert(vim.api.nvim_buf_is_loaded(hidden) and vim.bo[hidden].modified)
      assert(#unsaved.list() == 1 and vim.g.ue_unsaved_count == 1)
      vim.api.nvim_buf_delete(hidden, {force=true})
      print('UNSAVED_OK')
    ]])
  end)

  t.it("面板列出全部文件；取消/逐个查看不写入、不退出", function()
    child([[
      local unsaved = require('utils.unsaved')
      vim.o.hidden = true
      unsaved.setup()
      local a = vim.api.nvim_create_buf(true, false)
      local b = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_name(a, vim.fn.tempname() .. 'One.cpp')
      vim.api.nvim_buf_set_name(b, vim.fn.tempname() .. 'Two.cpp')
      vim.api.nvim_buf_set_lines(a, 0, -1, false, {'one'})
      vim.api.nvim_buf_set_lines(b, 0, -1, false, {'two'})
      local picker, options, cb
      vim.ui.select = function(items, opts, callback) picker, options, cb = items, opts, callback end
      unsaved.quit()
      assert(#picker == 6 and #unsaved.list() == 2)
      assert(options.format_item(picker[5]):find('One.cpp', 1, true))
      assert(options.format_item(picker[6]):find('Two.cpp', 1, true))
      cb(nil)
      assert(vim.bo[a].modified and vim.bo[b].modified)
      unsaved.quit()
      cb('逐个查看（取消退出）')
      assert(#picker == 2)
      cb(picker[2])
      assert(vim.api.nvim_get_current_buf() == b and vim.bo[b].modified)
      print('UNSAVED_OK')
    ]])
  end)

  t.it("保存全部写真实文件，未命名/只读失败阻止退出", function()
    child([[
      local unsaved = require('utils.unsaved')
      unsaved.setup()
      local dir = vim.fn.tempname()
      vim.fn.mkdir(dir, 'p')
      local a = vim.api.nvim_create_buf(true, false)
      local b = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_name(a, dir .. '/One.cpp')
      vim.api.nvim_buf_set_name(b, dir .. '/Two.cpp')
      vim.api.nvim_buf_set_lines(a, 0, -1, false, {'one'})
      vim.api.nvim_buf_set_lines(b, 0, -1, false, {'two'})
      assert(unsaved.save_all())
      assert(vim.fn.readfile(dir .. '/One.cpp')[1] == 'one')
      assert(vim.fn.readfile(dir .. '/Two.cpp')[1] == 'two')
      assert(vim.g.ue_unsaved_count == 0)
      local scratch = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_lines(scratch, 0, -1, false, {'keep me'})
      vim.notify = function() end
      assert(not unsaved.save_all() and vim.bo[scratch].modified)
      vim.bo[a].readonly = true
      vim.api.nvim_buf_set_lines(a, 0, -1, false, {'changed'})
      assert(not unsaved.save_all() and vim.bo[a].modified)
      assert(vim.fn.readfile(dir .. '/One.cpp')[1] == 'one')
      vim.fn.delete(dir, 'rf')
      print('UNSAVED_OK')
    ]])
  end)

  t.it("放弃需第二次确认，包含菜单打开后新增的脏buffer", function()
    child([[
      local unsaved = require('utils.unsaved')
      unsaved.setup()
      vim.api.nvim_buf_set_lines(0, 0, -1, false, {'dirty'})
      local cb
      vim.ui.select = function(_, _, callback) cb = callback end
      local native_cmd, exit = vim.cmd
      local confirmation, answer = '', 2
      vim.fn.confirm = function(message, _, default)
        confirmation = message
        assert(default == 2)
        return answer
      end
      unsaved.quit()
      local extra = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_lines(extra, 0, -1, false, {'new dirty'})
      vim.cmd = function(command) exit = command end
      cb('放弃修改并退出')
      assert(not exit and vim.bo[extra].modified)
      assert(confirmation:find('[未命名 #' .. extra .. ']', 1, true))
      unsaved.quit()
      answer = 1
      cb('放弃修改并退出')
      vim.cmd = native_cmd
      assert(exit == 'qa!')
      print('UNSAVED_OK')
    ]])
  end)

  t.it("二次确认期间新增、编辑或重命名文件均取消退出", function()
    child([[
      local unsaved = require('utils.unsaved')
      unsaved.setup()
      local original = vim.api.nvim_get_current_buf()
      vim.api.nvim_buf_set_lines(original, 0, -1, false, {'original edit'})
      local cb, exit, message
      local native_cmd = vim.cmd
      vim.cmd = function(command)
        if command == 'qa!' or command == 'qa' then exit = command else native_cmd(command) end
      end
      vim.notify = function(text) message = text end
      vim.ui.select = function(_, _, callback) cb = callback end
      local changes = {
        function()
          local extra = vim.api.nvim_create_buf(true, false)
          vim.api.nvim_buf_set_lines(extra, 0, -1, false, {'new edit'})
        end,
        function() vim.api.nvim_buf_set_lines(original, 0, -1, false, {'changed during confirmation'}) end,
        function() vim.api.nvim_buf_set_name(original, vim.fn.tempname() .. '.cpp') end,
      }
      for _, change in ipairs(changes) do
        vim.fn.confirm = function() change(); return 1 end
        message = nil
        unsaved.quit()
        cb('放弃修改并退出')
        assert(not exit, 'confirmation must not discard unseen changes')
        assert(message and message:find('确认期间发生变化', 1, true))
        assert(vim.bo[original].modified)
      end
      assert(vim.api.nvim_buf_get_lines(original, 0, 1, false)[1] == 'changed during confirmation')
      vim.cmd = native_cmd
      print('UNSAVED_OK')
    ]])
  end)

  t.it("状态栏只读缓存，即使缓冲区枚举不可用也能渲染", function()
    child([[
      local mini = {}
      for _, name in ipairs({'mode','git','diff','diagnostics','lsp','filename','fileinfo','location','searchcount'}) do
        mini['section_' .. name] = function() return '' end
      end
      mini.is_truncated = function() return false end
      mini.combine_groups = function(groups)
        local text = {}
        for _, group in ipairs(groups) do
          if type(group) == 'table' then vim.list_extend(text, group.strings) end
        end
        return table.concat(text, ' ')
      end
      package.loaded['mini.statusline'] = mini
      package.loaded['utils.ue_hub'] = {debug_indicator=function() return '' end}
      vim.g.ue_unsaved_status = '未保存:3'
      vim.api.nvim_list_bufs = function() error('drawing must not scan buffers') end
      local spec = dofile(vim.fn.getcwd() .. '/lua/plugins/statusline.lua')[2]
      assert(spec.opts().content.active():find('未保存:3', 1, true))
      print('UNSAVED_OK')
    ]])
  end)

  t.it("不进入隐藏缓冲区，API修改、undo和清modified也更新缓存", function()
    child([[
      local unsaved = require('utils.unsaved')
      unsaved.setup()
      local origin = vim.api.nvim_get_current_buf()
      local hidden = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_lines(hidden, 0, -1, false, {'hidden edit'})
      assert(vim.api.nvim_get_current_buf() == origin)
      assert(vim.g.ue_unsaved_count == 1, tostring(vim.g.ue_unsaved_count))
      vim.bo[hidden].modified = false
      assert(vim.g.ue_unsaved_count == 0)
      vim.api.nvim_buf_set_lines(hidden, 0, -1, false, {'second edit'})
      assert(vim.g.ue_unsaved_count == 1)
      vim.api.nvim_buf_call(hidden, function() vim.cmd('undo') end)
      vim.wait(20)
      assert(vim.g.ue_unsaved_count == (vim.bo[hidden].modified and 1 or 0))
      vim.api.nvim_buf_delete(hidden, {force=true})
      assert(vim.g.ue_unsaved_count == 0)
      print('UNSAVED_OK')
    ]])
  end)
end)
