local t = require("tests.harness")
local cfg = t.bootstrap()
local format = require("utils.cpp_format")

local function fixture(fn)
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir .. "/Source", "p")
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(buf, dir .. "/Source/Sample.cpp")
  vim.bo[buf].filetype = "cpp"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "void Test(){int Value=1;}" })
  local ok, err = pcall(fn, dir, buf)
  vim.api.nvim_buf_delete(buf, { force = true })
  vim.fn.delete(dir, "rf")
  if not ok then
    error(err)
  end
end

t.describe("cpp_format: 工程风格保护", function()
  t.it("向父级找两种配置名，缺失不缓存", function()
    fixture(function(dir, buf)
      t.assert_nil(format.find_config(buf))
      for _, name in ipairs({ ".clang-format", "_clang-format" }) do
        vim.fn.writefile({ "BasedOnStyle: LLVM" }, dir .. "/" .. name)
        t.assert_eq(vim.fs.normalize(format.find_config(buf)), vim.fs.normalize(dir .. "/" .. name))
        vim.fn.delete(dir .. "/" .. name)
        t.assert_nil(format.find_config(buf))
      end
    end)
  end)

  t.it("缺配置且取消：无 formatter 调用、内容不变、autoformat不变", function()
    fixture(function(_, buf)
      local old_conform, old_select, old_notify = package.loaded.conform, vim.ui.select, vim.notify
      local called, message, choices = false
      package.loaded.conform = {
        format = function()
          called = true
        end,
      }
      vim.notify = function(msg)
        message = msg
      end
      vim.ui.select = function(items, _, cb)
        choices = items
        cb(nil)
      end
      local autoformat = vim.g.autoformat
      format.format({ bufnr = buf })
      package.loaded.conform, vim.ui.select, vim.notify = old_conform, old_select, old_notify
      t.assert_false(called)
      t.assert_contains(message, "本工程没有 .clang-format，已跳过")
      t.assert_contains(choices[1], "UE 风格")
      t.assert_eq(vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1], "void Test(){int Value=1;}")
      t.assert_eq(vim.g.autoformat, autoformat)
    end)
  end)

  t.it("菜单期间修改缓冲区不会格式化过期选区", function()
    fixture(function(_, buf)
      local old_select, old_notify = vim.ui.select, vim.notify
      local callback, item, message
      vim.ui.select = function(items, _, cb)
        item, callback = items[1], cb
      end
      vim.notify = function(msg)
        message = msg
      end
      format.format({ bufnr = buf, range = { start = { 1, 0 }, ["end"] = { 1, 10 } } })
      vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "new content" })
      callback(item)
      vim.ui.select, vim.notify = old_select, old_notify
      t.assert_contains(message, "文件已改变")
    end)
  end)

  if vim.fn.executable(format.command()) ~= 1 then
    t.skip("真实 conform/clang-format", "host clang-format unavailable", { native = true })
  else
    t.it("真实 conform/clang-format：项目配置、缺失拒绝、UE模板和选区", function()
      local code = [[
      local cfg = ...
      vim.opt.rtp:prepend(cfg)
      vim.opt.rtp:append(vim.fn.stdpath('data') .. '/lazy/conform.nvim')
      local fmt = require('utils.cpp_format')
      local spec = dofile(cfg .. '/lua/plugins/ue.lua')[1]
      local conform = require('conform')
      conform.setup(spec.opts)
      local dir = vim.fn.tempname()
      vim.fn.mkdir(dir .. '/Source', 'p')
      vim.api.nvim_buf_set_name(0, dir .. '/Source/Sample.cpp')
      vim.bo.filetype = 'cpp'
      local original = {'void Test(){int Value=1;}', '', 'void Other(){int OtherValue=2;}'}
      vim.api.nvim_buf_set_lines(0, 0, -1, false, original)
      conform.format({lsp_format='never'})
      assert(vim.deep_equal(vim.api.nvim_buf_get_lines(0, 0, -1, false), original))
      vim.fn.writefile({'BasedOnStyle: LLVM', 'IndentWidth: 2', 'AllowShortFunctionsOnASingleLine: None'}, dir .. '/.clang-format')
      local done, err = false
      conform.format({async=true}, function(e) err, done = e, true end)
      assert(vim.wait(5000, function() return done end) and not err, tostring(err))
      assert(table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n'):find('  int Value = 1;', 1, true))
      vim.fn.delete(dir .. '/.clang-format')
      vim.api.nvim_buf_set_lines(0, 0, -1, false, original)
      done = false
      conform.format({formatters={'ue_epic'}, async=true, lsp_format='never',
        range={start={1,0}, ['end']={1,#original[1]}}}, function(e) err, done = e, true end)
      assert(vim.wait(5000, function() return done end) and not err, tostring(err))
      local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
      assert(lines[2] == '{' and lines[3] == '\tint Value = 1;', vim.inspect(lines))
      assert(lines[#lines] == original[3], 'unselected function changed')
      vim.fn.delete(dir, 'rf')
      print('CPP_FORMAT_OK')
    ]]
      local script = vim.fn.tempname() .. ".lua"
      vim.fn.writefile(vim.split(("(function(...) %s end)(%q)"):format(code, cfg), "\n", { plain = true }), script)
      local result = vim
        .system({ vim.v.progpath, "--headless", "-u", "NONE", "-i", "NONE", "-l", script }, { text = true })
        :wait(15000)
      vim.fn.delete(script)
      t.assert_eq(result.code, 0, (result.stdout or "") .. (result.stderr or ""))
      t.assert_contains((result.stdout or "") .. (result.stderr or ""), "CPP_FORMAT_OK")
    end)
  end
end)
