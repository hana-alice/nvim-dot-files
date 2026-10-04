local t = require("tests.harness")
local cfg = t.bootstrap()

-- Native child processes below are isolated, bounded verification fixtures.
-- They load no user init, LSP, indexing or project jobs; only owned children
-- are terminated. Process-kill recovery is not evidence of power-loss safety.
local function scope(fn)
  local dir = vim.fn.tempname() .. "-ide-recovery"
  vim.fn.mkdir(dir, "p")
  local jobs = {}
  local ok, err = pcall(fn, dir, jobs)
  for _, job in ipairs(jobs) do
    if not job:is_closing() then
      job:kill(9)
    end
    job:wait(5000)
  end
  vim.fn.delete(dir, "rf")
  if not ok then
    error(err, 0)
  end
end

local prelude = [[
  local dir = ...
  vim.o.swapfile = false
  vim.o.shada = ''
  vim.o.hidden = true
  local recovery = require('utils.edit_recovery')
  local function await(action)
    local done, result, count = false, nil, 0
    action(function(...)
      result = {...}
      count = select('#', ...)
      done = true
    end)
    assert(vim.wait(5000, function() return done end, 5), 'async recovery callback timeout')
    return unpack(result, 1, count)
  end
  local function capture(buf)
    local ok, path = await(function(done) recovery.capture(buf, done) end)
    assert(ok, tostring(path))
    assert(type(path) == 'string' and vim.uv.fs_stat(path), 'capture must publish a real file')
    return path
  end
  local function records(opts)
    local list, err = await(function(done) recovery.list(done, opts or {all=true, include_live=true}) end)
    assert(type(list) == 'table' and not err, tostring(err))
    return list
  end
  local function lines(buf)
    return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  end
  local function content(buf, expected)
    assert(vim.deep_equal(lines(buf), expected), vim.inspect(lines(buf)))
  end
  local function read(path)
    local file = assert(io.open(path, 'rb'))
    local data = file:read('*a')
    file:close()
    return data
  end
  recovery.setup({root=dir .. '/journal', delay_ms=80})
]]

local function start(dir, jobs, code, looping, stream)
  local script = dir .. "/child-" .. (#jobs + 1) .. ".lua"
  local text = ("vim.opt.rtp:prepend(%q)\nlocal function test(...)\n%s\n%s\nend\n"):format(cfg, prelude, code)
    .. ("local ok, err = pcall(test, %q)\nif not ok then print(err); vim.cmd('cquit 1') end\n"):format(dir)
  if not looping then
    text = text .. "print('IDE_RECOVERY_OK')\n"
  else
    -- A parent test crash must not leave its verification writer resident.
    text = "vim.defer_fn(function() print('IDE_RECOVERY_WRITER_TIMEOUT'); vim.cmd('cquit 2') end, 20000)\n" .. text
  end
  vim.fn.writefile(vim.split(text, "\n", { plain = true }), script)
  local command = { vim.v.progpath, "--headless", "-u", "NONE", "-i", "NONE", "-n" }
  vim.list_extend(command, looping and { "-c", ("lua dofile(%q)"):format(script) } or { "-l", script })
  local environment = {}
  for _, key in ipairs({ "XDG_CONFIG_HOME", "XDG_STATE_HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME" }) do
    environment[key] = dir .. "/" .. key:lower()
  end
  local output = { stdout = "", stderr = "" }
  local job = vim.system(command, {
    text = true,
    env = environment,
    stdout = stream and function(_, data)
      output.stdout = output.stdout .. (data or "")
    end or nil,
    stderr = stream and function(_, data)
      output.stderr = output.stderr .. (data or "")
    end or nil,
  })
  jobs[#jobs + 1] = job
  return job, output
end

local function child(code)
  scope(function(dir, jobs)
    local job = start(dir, jobs, code)
    local result = job:wait(15000)
    local diagnostic = (result.stdout or "") .. (result.stderr or "")
    t.assert_eq(result.code, 0, diagnostic)
    t.assert_contains(diagnostic, "IDE_RECOVERY_OK")
  end)
end

local function writer(dir, jobs, normal_exit)
  local job, output = start(dir, jobs, [[
    local disk = dir .. '/Crash.cpp'
    local file = assert(io.open(disk, 'wb'))
    file:write('disk untouched\r\n')
    file:close()
    local named = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_name(named, disk)
    vim.bo[named].fileformat = 'dos'
    vim.api.nvim_buf_set_lines(named, 0, -1, false, {'crash named café', 'preserved second line'})
    local named_path = capture(named)
    local unnamed = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_lines(unnamed, 0, -1, false, {'crash unnamed Ω'})
    local unnamed_path = capture(unnamed)
    print('IDE_RECOVERY_READY ' .. vim.json.encode({pid=vim.fn.getpid(), named=named_path, unnamed=unnamed_path}))
  ]] .. (normal_exit and "\nvim.cmd('qa!')\n" or ""), true, true)
  local ready
  local completed = vim.wait(10000, function()
    local encoded = (output.stdout .. output.stderr):match("IDE_RECOVERY_READY (%b{})")
    if encoded then
      ready = vim.json.decode(encoded)
      return true
    end
    return job:is_closing()
  end, 10)
  t.assert_true(completed and ready, output.stdout .. output.stderr .. "\nwriter did not publish durable READY")
  t.assert_true(ready.pid ~= vim.fn.getpid(), "writer must be a distinct native process")
  t.assert_eq(ready.pid, job.pid, "READY must identify only our owned writer")
  t.assert_true(vim.uv.fs_stat(ready.named) and vim.uv.fs_stat(ready.unnamed), "durable callback paths must exist")
  return job, ready
end

local function reader(dir, jobs, code)
  local job = start(dir, jobs, code)
  local result = job:wait(15000)
  local diagnostic = (result.stdout or "") .. (result.stderr or "")
  t.assert_eq(result.code, 0, diagnostic)
  t.assert_contains(diagnostic, "IDE_RECOVERY_OK")
  return job.pid
end

t.describe("ide_recovery: 真实异步编辑日志", function()
  t.it("恢复 API 可在隔离原生进程加载", function()
    child([[
      for _, name in ipairs({'setup', 'capture', 'list', 'restore', 'clear', 'prune'}) do
        assert(type(recovery[name]) == 'function', 'missing public API: ' .. name)
      end
    ]])
  end)

  t.it("named/unnamed UTF-8 快照真实落盘，恢复副本保留 dos 元数据与原始输入", function()
    child([[
      local disk = dir .. '/Original.cpp'
      local file = assert(io.open(disk, 'wb'))
      file:write('disk 原始\r\n')
      file:close()
      local original = read(disk)
      local named = vim.api.nvim_get_current_buf()
      vim.api.nvim_buf_set_name(named, disk)
      vim.bo[named].fileformat = 'dos'
      vim.bo[named].fileencoding = 'utf-8'
      vim.bo[named].bomb = true
      vim.bo[named].endofline = false
      vim.api.nvim_buf_set_lines(named, 0, -1, false, {'未保存 café β', '第二行'})
      local named_path = capture(named)
      local unnamed = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_lines(unnamed, 0, -1, false, {'无名 Ω'})
      local unnamed_path = capture(unnamed)
      assert(named_path ~= unnamed_path, 'buffer journals must have distinct paths')
      assert(read(named_path):find('未保存', 1, true), 'UTF-8 text must survive JSON write')
      local list = records()
      assert(#list == 2, vim.inspect(list))
      -- Restoration never edits the source path or an already open buffer.
      vim.api.nvim_buf_set_lines(named, 0, -1, false, {'new live input'})
      local restored, err = recovery.restore(named_path)
      assert(type(restored) == 'number', tostring(err))
      assert(restored ~= named and restored ~= unnamed)
      assert(vim.api.nvim_buf_get_name(restored) == '')
      assert(vim.bo[restored].buftype == '' and vim.bo[restored].modified)
      assert(vim.bo[restored].fileformat == 'dos' and vim.bo[restored].fileencoding == 'utf-8')
      assert(vim.bo[restored].bomb and not vim.bo[restored].endofline)
      content(restored, {'未保存 café β', '第二行'})
      content(named, {'new live input'})
      assert(read(disk) == original, 'restoration must not overwrite original disk data')
      local unnamed_record
      for _, record in ipairs(list) do
        if record.path == unnamed_path then unnamed_record = record end
      end
      assert(unnamed_record, 'list must expose each restorable path')
      local copy = assert(recovery.restore(unnamed_record))
      assert(copy ~= unnamed and vim.api.nvim_buf_get_name(copy) == '' and vim.bo[copy].modified)
      content(copy, {'无名 Ω'})
      content(unnamed, {'无名 Ω'})
    ]])
  end)

  t.it("损坏/截断日志拒绝恢复，保留当前输入和原文件", function()
    child([[
      local buf = vim.api.nvim_get_current_buf()
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, {'keep current input'})
      local path = capture(buf)
      for _, broken in ipairs({'{"version":', 'null', '[]', '{}'}) do
        vim.fn.writefile({broken}, path, 'b')
        local before = #vim.api.nvim_list_bufs()
        local ok, restored, err = pcall(recovery.restore, path)
        assert(ok, 'malformed snapshots must return an error, not throw: ' .. tostring(restored))
        assert(not restored and err, 'invalid snapshot must not produce a successful buffer')
        assert(#vim.api.nvim_list_bufs() == before, 'invalid data must not create a buffer')
        content(buf, {'keep current input'})
        assert(read(path) == broken, 'validation must not rewrite the rejected snapshot')
      end
    ]])
  end)

  t.it("合法 JSON 的非法元数据也被拒绝，不抛异常或遗留半建 buffer", function()
    child([[
      local buf = vim.api.nvim_get_current_buf()
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, {'keep input through validation'})
      local path = capture(buf)
      local valid = vim.json.decode(read(path))
      for _, mutation in ipairs({
        {fileformat='invalid-format'}, {fileencoding={}}, {filetype={}},
        {endofline='yes'}, {bomb='yes'}, {lines={'valid text', false}},
      }) do
        local record = vim.tbl_extend('force', vim.deepcopy(valid), mutation)
        local raw = vim.json.encode(record)
        vim.fn.writefile({raw}, path, 'b')
        assert(#records() == 0, 'invalid metadata must not be offered by list')
        for _, value in ipairs({path, record}) do
          local before = #vim.api.nvim_list_bufs()
          local ok, restored, err = pcall(recovery.restore, value)
          assert(ok, 'invalid metadata must return nil,error: ' .. tostring(restored))
          assert(not restored and err, 'invalid metadata must not claim a usable restored buffer')
          assert(#vim.api.nvim_list_bufs() == before, 'validation must precede buffer allocation')
          content(buf, {'keep input through validation'})
        end
        assert(read(path) == raw, 'invalid snapshot must remain untouched')
      end
    ]])
  end)

  t.it("非法 PID/session/timestamp 被拒绝，原始输入和日志不被修改", function()
    child([[
      local buf = vim.api.nvim_get_current_buf()
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, {'keep owner-validation input'})
      local path = capture(buf)
      local valid = vim.json.decode(read(path))
      for _, mutation in ipairs({
        {pid=0}, {pid=-1}, {pid=0.5},
        {session=''}, {session='..'}, {session='../' .. valid.session},
        {session=(valid.pid + 1) .. '-123'}, {session=valid.pid .. '-not-a-number'},
        {session=valid.pid .. '-0'}, {session=valid.pid .. '--1'},
        {at=0}, {at=-1}, {at=1.5}, {at='yesterday'},
      }) do
        local record = vim.tbl_extend('force', vim.deepcopy(valid), mutation)
        local raw = vim.json.encode(record)
        vim.fn.writefile({raw}, path, 'b')
        assert(#records() == 0, 'invalid owner metadata must not enter list: ' .. vim.inspect(mutation))
        for _, value in ipairs({path, record}) do
          local before = #vim.api.nvim_list_bufs()
          local ok, restored, err = pcall(recovery.restore, value)
          assert(ok and not restored and err, 'owner metadata must fail closed: ' .. vim.inspect(mutation))
          assert(#vim.api.nvim_list_bufs() == before)
          content(buf, {'keep owner-validation input'})
        end
        assert(read(path) == raw, 'validation must leave rejected journals unchanged')
      end
    ]])
  end)

  t.it("max_bytes 拒绝超限输入，真实日志中不发布部分内容", function()
    child([[
      require('ue.config').setup({edit_recovery={max_bytes=1024}})
      recovery.setup({root=dir .. '/journal', delay_ms=80})
      local buf = vim.api.nvim_get_current_buf()
      local text = string.rep('界', 500)
      assert(#text > 1024 and vim.fn.strchars(text) < 1024, 'bound is bytes, not displayed characters')
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, {text})
      local ok, err = await(function(done) recovery.capture(buf, done) end)
      assert(not ok and err, 'oversized buffers must fail explicitly')
      assert(#records() == 0, 'no truncated or partial successful journal may be listed')
      content(buf, {text})
      assert(vim.bo[buf].modified, 'capture failure must preserve unsaved state')
    ]])
  end)

  t.it("干净保存删除自己的日志，显式 clear 保持磁盘和内容", function()
    child([[
      local buf = vim.api.nvim_get_current_buf()
      local disk = dir .. '/Saved.cpp'
      vim.api.nvim_buf_set_name(buf, disk)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, {'write this café'})
      local path = capture(buf)
      vim.api.nvim_buf_call(buf, function() vim.cmd('write') end)
      assert(vim.wait(5000, function() return not vim.uv.fs_stat(path) end, 10),
        'clean BufWritePost must delete owned journal')
      assert(not vim.bo[buf].modified and read(disk):find('write this café', 1, true))
      vim.wait(200)
      assert(not vim.uv.fs_stat(path), 'a pending dirty capture must not republish after clean save')
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, {'keep later input'})
      local later = capture(buf)
      local ok, err = await(function(done) recovery.clear(buf, done) end)
      assert(ok, tostring(err))
      assert(not vim.uv.fs_stat(later), 'clear must complete after actual file removal')
      content(buf, {'keep later input'})
      assert(vim.bo[buf].modified)
      assert(read(disk):find('write this café', 1, true), 'clear must not alter original disk')
    ]])
  end)

  t.it("事件自动合并连续编辑，仅保留最新的 buffer 日志", function()
    child([[
      recovery.setup({root=dir .. '/journal', delay_ms=250})
      local buf = vim.api.nvim_get_current_buf()
      for index = 1, 20 do
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, {'latest edit ' .. index})
      end
      vim.wait(80)
      assert(#records() == 0, 'debounced capture must not publish on every edit')
      local list, deadline = records(), vim.uv.hrtime() + 5e9
      while #list == 0 and vim.uv.hrtime() < deadline do
        vim.wait(20)
        list = records()
      end
      assert(#list > 0, 'buffer events did not produce an automatic snapshot')
      assert(#list == 1, 'coalesced edits must not accumulate separate records')
      local copy, err = recovery.restore(list[1])
      assert(copy, tostring(err))
      content(copy, {'latest edit 20'})
      content(buf, {'latest edit 20'})
    ]])
  end)

  t.it("真实 async unlink 与保存后新编辑并发，最新快照不被旧 cleanup 删除", function()
    child([[
      local buf = vim.api.nvim_get_current_buf()
      local disk = dir .. '/Race.cpp'
      vim.api.nvim_buf_set_name(buf, disk)
      for index = 1, 8 do
        local saved, fresh = 'saved input ' .. index, 'new input ' .. index
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, {saved})
        local path = capture(buf)
        vim.api.nvim_buf_call(buf, function() vim.cmd('write') end)
        local clear_done, clear_ok, clear_error = false
        recovery.clear(buf, function(ok, err)
          clear_done, clear_ok, clear_error = true, ok, err
        end)
        assert(not clear_done, 'the real fs unlink must remain in flight before new input')
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, {fresh})
        -- Submit while deletion is in flight; production must keep/queue new text.
        -- No filesystem API or callback is replaced to manufacture ordering.
        recovery.capture(buf)
        assert(vim.wait(5000, function() return clear_done end, 5), 'clear callback timeout')
        assert(clear_ok, tostring(clear_error))
        assert(vim.wait(5000, function()
          local ok, snapshot = pcall(function() return vim.json.decode(read(path)) end)
          return ok and vim.deep_equal(snapshot.lines, {fresh})
        end, 10), 'latest edit did not survive concurrent old-file cleanup')
        content(buf, {fresh})
        assert(vim.bo[buf].modified and read(disk):find(saved, 1, true))
        vim.wait(120)
        assert(vim.deep_equal(vim.json.decode(read(path)).lines, {fresh}),
          'delayed save event must not remove the newer dirty snapshot')
      end
    ]])
  end)

  t.it("kill 已落盘 writer 后，第二个原生 PID 恢复 named/unnamed 且不覆盖新的输入", function()
    scope(function(dir, jobs)
      local process, ready = writer(dir, jobs)
      process:kill(9)
      local stopped = process:wait(5000)
      t.assert_true(stopped.code ~= 0 or stopped.signal ~= 0, "writer must be stopped without normal VimLeavePre")
      local reader_pid = reader(
        dir,
        jobs,
        ([[
        local writer_pid = %d
        assert(vim.fn.getpid() ~= writer_pid)
        local found = records({all=true})
        assert(#found == 2, vim.inspect(found))
        for _, record in ipairs(found) do
          assert(record.pid == writer_pid, 'must read the terminated writer session')
        end
        local disk = dir .. '/Crash.cpp'
        local disk_before = read(disk)
        local live = vim.api.nvim_get_current_buf()
        vim.api.nvim_buf_set_name(live, disk)
        vim.api.nvim_buf_set_lines(live, 0, -1, false, {'new input after restart'})
        local named, err = recovery.restore(%q)
        assert(named, tostring(err))
        assert(named ~= live and vim.api.nvim_buf_get_name(named) == '')
        assert(vim.bo[named].buftype == '' and vim.bo[named].modified and vim.bo[named].fileformat == 'dos')
        content(named, {'crash named café', 'preserved second line'})
        local unnamed = assert(recovery.restore(%q))
        assert(unnamed ~= named and unnamed ~= live and vim.api.nvim_buf_get_name(unnamed) == '')
        assert(vim.bo[unnamed].buftype == '' and vim.bo[unnamed].modified)
        content(unnamed, {'crash unnamed Ω'})
        content(live, {'new input after restart'})
        assert(read(disk) == disk_before and disk_before == 'disk untouched\r\n')
        print('IDE_RECOVERY_RESTART ' .. writer_pid .. ' -> ' .. vim.fn.getpid())
      ]]):format(ready.pid, ready.named, ready.unnamed)
      )
      t.assert_true(reader_pid ~= ready.pid, "restore must run under a second PID")
    end)
  end)

  t.it("两个活跃 PID 的日志独立，第二实例 clear/保存不能删除第一实例记录", function()
    scope(function(dir, jobs)
      local process, ready = writer(dir, jobs)
      local first_named = table.concat(vim.fn.readfile(ready.named, "b"), "\n")
      local first_unnamed = table.concat(vim.fn.readfile(ready.unnamed, "b"), "\n")
      reader(
        dir,
        jobs,
        ([[
        assert(vim.fn.getpid() ~= %d)
        local prior = records()
        assert(#prior == 2, vim.inspect(prior))
        local buf = vim.api.nvim_get_current_buf()
        vim.api.nvim_buf_set_name(buf, dir .. '/Second.cpp')
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, {'second process input'})
        local own = capture(buf)
        assert(own ~= %q and own ~= %q, 'PID/session namespace must prevent buffer-ID collisions')
        assert(#records() == 3, 'both active instances must remain independently discoverable')
        local ok, err = await(function(done) recovery.clear(buf, done) end)
        assert(ok, tostring(err))
        assert(not vim.uv.fs_stat(own))
        assert(vim.uv.fs_stat(%q) and vim.uv.fs_stat(%q))
        local again = capture(buf)
        vim.api.nvim_buf_call(buf, function() vim.cmd('write') end)
        assert(vim.wait(5000, function() return not vim.uv.fs_stat(again) end, 10))
        assert(vim.uv.fs_stat(%q) and vim.uv.fs_stat(%q))
      ]]):format(ready.pid, ready.named, ready.unnamed, ready.named, ready.unnamed, ready.named, ready.unnamed)
      )
      t.assert_false(process:is_closing(), "first instance must stay active throughout isolation checks")
      t.assert_eq(table.concat(vim.fn.readfile(ready.named, "b"), "\n"), first_named)
      t.assert_eq(table.concat(vim.fn.readfile(ready.unnamed, "b"), "\n"), first_unnamed)
    end)
  end)

  t.it("过期 live-owner 日志保留，prune 不删除另一活跃原生 PID 的文件", function()
    scope(function(dir, jobs)
      local process, ready = writer(dir, jobs)
      reader(
        dir,
        jobs,
        ([[
        -- Let setup's asynchronous startup scan finish while records are fresh.
        vim.wait(150)
        local expected, raw = {%q, %q}, {}
        for _, path in ipairs(expected) do
          local value = vim.json.decode(read(path))
          assert(value.pid == %d)
          value.at = os.time() - 8 * 86400
          raw[path] = vim.json.encode(value)
          vim.fn.writefile({raw[path]}, path, 'b')
        end
        local found = records()
        assert(#found == 2)
        for _, record in ipairs(found) do
          assert(record.owner_state == 'active' and not record.closed, 'liveness must be measured, not supplied')
        end
        local count = await(function(done) recovery.prune(done) end)
        assert(count == 0, 'old records from a real live process must not expire')
        for _, path in ipairs(expected) do assert(read(path) == raw[path]) end
        assert(#records() == 2)
      ]]):format(ready.named, ready.unnamed, ready.pid)
      )
      t.assert_false(process:is_closing(), "prune must not stop another live instance")
      t.assert_true(vim.uv.fs_stat(ready.named) and vim.uv.fs_stat(ready.unnamed))
    end)
  end)

  t.it("prune 只删除过期 dead/closed 日志，新的 crash 日志继续可恢复", function()
    scope(function(dir, jobs)
      local crashed, crash = writer(dir, jobs)
      crashed:kill(9)
      crashed:wait(5000)
      local exited, closed = writer(dir, jobs, true)
      local exit_result = exited:wait(5000)
      t.assert_eq(exit_result.code, 0, "normal fixture must execute native qa!")
      local marker = vim.fs.dirname(closed.named) .. "/closed"
      t.assert_true(vim.uv.fs_stat(marker), "normal VimLeavePre must actually mark the exited session")
      reader(
        dir,
        jobs,
        ([[
        vim.wait(150)
        local old = {%q, %q, %q}
        local fresh = %q
        local found = records()
        assert(#found == 4, vim.inspect(found))
        local closed_count = 0
        for _, item in ipairs(found) do
          assert(item.owner_state == 'dead', 'both real fixture owners must have exited')
          if item.closed then closed_count = closed_count + 1 end
        end
        assert(closed_count == 2)
        assert(#records({all=true}) == 2, 'normal exit must not appear as a crash before pruning')
        for _, path in ipairs(old) do
          local value = vim.json.decode(read(path))
          value.at = os.time() - 8 * 86400
          vim.fn.writefile({vim.json.encode(value)}, path, 'b')
        end
        local fresh_before = read(fresh)
        local count = await(function(done) recovery.prune(done) end)
        assert(count == 3, 'actual removal count must include only three expired files: ' .. tostring(count))
        for _, path in ipairs(old) do assert(not vim.uv.fs_stat(path)) end
        assert(read(fresh) == fresh_before, 'recent crash journal must remain byte-for-byte unchanged')
        assert(#records() == 1 and #records({all=true}) == 1)
        local copy = assert(recovery.restore(fresh))
        content(copy, {'crash unnamed Ω'})
        assert(vim.api.nvim_buf_get_name(copy) == '' and vim.bo[copy].modified)
      ]]):format(crash.named, closed.named, closed.unnamed, crash.unnamed)
      )
    end)
  end)

  t.it("错放 project/session 目录的 dead-owner alias 拒绝读取恢复且 prune 保留", function()
    scope(function(dir, jobs)
      local process, ready = writer(dir, jobs)
      process:kill(9)
      process:wait(5000)
      reader(
        dir,
        jobs,
        ([[
        vim.wait(150)
        local source = %q
        local value = vim.json.decode(read(source))
        value.at = os.time() - 8 * 86400
        local raw = vim.json.encode(value)
        local scope_dir = vim.fs.dirname(vim.fs.dirname(source))
        local project_root = vim.fs.dirname(scope_dir)
        local aliases = {
          vim.fs.joinpath(scope_dir, 'wrong-session', vim.fs.basename(source)),
          vim.fs.joinpath(project_root, string.rep('0', 24), value.session, vim.fs.basename(source)),
        }
        for _, path in ipairs(aliases) do
          vim.fn.mkdir(vim.fs.dirname(path), 'p')
          vim.fn.writefile({raw}, path, 'b')
          local before = #vim.api.nvim_list_bufs()
          local ok, copy, err = pcall(recovery.restore, path)
          assert(ok and not copy and err, 'path alias must fail ownership validation')
          assert(#vim.api.nvim_list_bufs() == before)
        end
        local found = records()
        assert(#found == 2, 'alias records must not be offered by list: ' .. vim.inspect(found))
        local count = await(function(done) recovery.prune(done) end)
        assert(count == 0, 'an invalid alias does not prove ownership for deletion')
        for _, path in ipairs(aliases) do assert(read(path) == raw) end
        assert(vim.uv.fs_stat(source), 'legitimate fresh source journal must remain')
      ]]):format(ready.named)
      )
    end)
  end)

  t.it(
    "dirty 原生 buffer 重复 setup 幂等，改配置自动重捕获并标记所有正常退出 session",
    function()
      scope(function(dir, jobs)
        local job = start(
          dir,
          jobs,
          [[
        local same = {root=dir .. '/journal', delay_ms=80}
        local disk = dir .. '/Setup.cpp'
        local file = assert(io.open(disk, 'wb'))
        file:write('original disk input\r\n')
        file:close()
        local named = vim.api.nvim_get_current_buf()
        vim.api.nvim_buf_set_name(named, disk)
        vim.api.nvim_buf_set_lines(named, 0, -1, false, {'named dirty unchanged café'})
        local unnamed = vim.api.nvim_create_buf(true, false)
        vim.api.nvim_buf_set_lines(unnamed, 0, -1, false, {'unnamed dirty unchanged Ω'})
        recovery.setup(same)
        local old = {capture(named), capture(unnamed)}
        vim.wait(200)
        local raw, modified_at = {}, {}
        for _, path in ipairs(old) do
          raw[path] = read(path)
          modified_at[path] = vim.uv.fs_stat(path).mtime
        end
        for _ = 1, 3 do
          recovery.setup(same)
          assert(capture(named) == old[1] and capture(unnamed) == old[2],
            'same configuration must keep snapshot paths and session identity')
        end
        vim.wait(200)
        for _, path in ipairs(old) do
          assert(read(path) == raw[path], 'same-config setup must not rewrite snapshot bytes')
          assert(vim.deep_equal(vim.uv.fs_stat(path).mtime, modified_at[path]),
            'same-config setup must not perform a redundant atomic rewrite')
        end
        local ticks = {vim.api.nvim_buf_get_changedtick(named), vim.api.nvim_buf_get_changedtick(unnamed)}
        recovery.setup({root=dir .. '/journal', delay_ms=35})
        -- No edits and no explicit capture after changing options: setup itself
        -- must queue the two dirty buffers whose listeners are already attached.
        local found, deadline = records(), vim.uv.hrtime() + 5e9
        while #found < 4 and vim.uv.hrtime() < deadline do
          vim.wait(10)
          found = records()
        end
        assert(#found == 4, 'new session must automatically capture both dirty buffers')
        local new, previous_session = {}, vim.json.decode(read(old[1])).session
        for _, record in ipairs(found) do
          if record.path ~= old[1] and record.path ~= old[2] then
            assert(record.session ~= previous_session)
            new[#new + 1] = record.path
            local expected = record.name == disk and {'named dirty unchanged café'} or {'unnamed dirty unchanged Ω'}
            assert(vim.deep_equal(record.lines, expected))
          end
        end
        assert(#new == 2)
        for _, path in ipairs(old) do assert(read(path) == raw[path]) end
        content(named, {'named dirty unchanged café'})
        content(unnamed, {'unnamed dirty unchanged Ω'})
        assert(vim.bo[named].modified and vim.bo[unnamed].modified)
        assert(vim.api.nvim_buf_get_changedtick(named) == ticks[1])
        assert(vim.api.nvim_buf_get_changedtick(unnamed) == ticks[2])
        assert(read(disk) == 'original disk input\r\n')
        print('IDE_RECOVERY_SETUP_PATHS ' .. vim.json.encode({old=old, new=new}))
        print('IDE_RECOVERY_OK')
        vim.cmd('qa!')
      ]]
        )
        local result = job:wait(15000)
        local output = (result.stdout or "") .. (result.stderr or "")
        t.assert_eq(result.code, 0, output)
        t.assert_contains(output, "IDE_RECOVERY_OK")
        local encoded = output:match("IDE_RECOVERY_SETUP_PATHS (%b{})")
        t.assert_true(encoded, "native child must report the actual old/new snapshot paths")
        local paths = vim.json.decode(encoded)
        for _, group in ipairs({ paths.old, paths.new }) do
          for _, path in ipairs(group) do
            t.assert_true(vim.uv.fs_stat(path), "setup and normal exit must preserve existing snapshots")
            t.assert_true(
              vim.uv.fs_stat(vim.fs.dirname(path) .. "/closed"),
              "normal exit must mark each previously owned session directory"
            )
          end
        end
      end)
    end
  )

  t.it("两代64条closed日志不能耗尽默认发现预算并隐藏最新真实crash", function()
    scope(function(dir, jobs)
      local job, output = start(
        dir,
        jobs,
        [[
        local closed = {}
        for cohort, count in ipairs({64, 64, 1}) do
          recovery.setup({root=dir .. '/journal', delay_ms=80 + cohort})
          local buffers, paths = {}, {}
          for index = 1, count do
            local buf = vim.api.nvim_create_buf(true, false)
            vim.api.nvim_buf_set_lines(buf, 0, -1, false, {'cohort ' .. cohort .. ' item ' .. index .. ' Ω'})
            buffers[#buffers + 1] = buf
            paths[#paths + 1] = capture(buf)
          end
          if cohort < 3 then
            local directory = vim.fs.dirname(paths[1])
            for _, path in ipairs(paths) do assert(vim.fs.dirname(path) == directory) end
            -- These are this real process's completed previous configuration
            -- cohorts; only the third session remains an unclosed crash cohort.
            vim.fn.writefile({'completed owned cohort'}, directory .. '/closed')
            closed[#closed + 1] = directory
            for _, buf in ipairs(buffers) do vim.api.nvim_buf_delete(buf, {force=true}) end
          else
            print('IDE_RECOVERY_BUDGET_READY ' .. vim.json.encode({pid=vim.fn.getpid(),
              closed_a=closed[1], closed_b=closed[2], latest=paths[1]}))
          end
        end
      ]],
        true,
        true
      )
      local ready
      local complete = vim.wait(15000, function()
        local encoded = (output.stdout .. output.stderr):match("IDE_RECOVERY_BUDGET_READY (%b{})")
        if encoded then
          ready = vim.json.decode(encoded)
          return true
        end
        return job:is_closing()
      end, 10)
      t.assert_true(complete and ready, output.stdout .. output.stderr .. "\n129 snapshots were not durably published")
      t.assert_eq(ready.pid, job.pid, "READY must belong to our owned native writer")
      for _, directory in ipairs({ ready.closed_a, ready.closed_b }) do
        local count = 0
        for name, kind in vim.fs.dir(directory) do
          if kind == "file" and name:match("^%d+%.json$") then
            count = count + 1
          end
        end
        t.assert_eq(count, 64, "each old cohort must contain 64 actual snapshot files")
        t.assert_true(vim.uv.fs_stat(directory .. "/closed"))
      end
      t.assert_true(vim.uv.fs_stat(ready.latest), "latest snapshot must exist before the real process kill")
      job:kill(9)
      local stopped = job:wait(5000)
      t.assert_true(stopped.code ~= 0 or stopped.signal ~= 0)
      reader(
        dir,
        jobs,
        ([[
        assert(vim.fn.getpid() ~= %d)
        local found = records({})
        assert(#found == 1 and found[1].path == %q,
          'two closed 64-file cohorts hid the latest crash from default discovery: ' .. vim.inspect(found))
        assert(found[1].owner_state == 'dead' and not found[1].closed)
        local bulk, err, metadata = await(function(done)
          recovery.list(done, {all=true, include_live=true})
        end)
        assert(not err and #bulk == 128 and metadata and metadata.truncated,
          'bounded discovery must report the 129-record truncation: ' .. vim.inspect({count=#bulk, err=err, metadata=metadata}))
        local latest_in_bulk = false
        for _, record in ipairs(bulk) do
          if record.path == found[1].path then latest_in_bulk = true end
        end
        assert(latest_in_bulk, 'bounded all-project scan must prioritize the latest session')
        local copy = assert(recovery.restore(found[1]))
        content(copy, {'cohort 3 item 1 Ω'})
        assert(vim.api.nvim_buf_get_name(copy) == '' and vim.bo[copy].modified)
      ]]):format(ready.pid, ready.latest)
      )
    end)
  end)

  t.it("其他真实project的128条crash日志不能隐藏当前project的最新文本", function()
    scope(function(dir, jobs)
      local job, output = start(
        dir,
        jobs,
        [[
        local candidates = {}
        for _, name in ipairs({'BudgetProjectA', 'BudgetProjectB'}) do
          local path = dir .. '/' .. name
          vim.fn.mkdir(path, 'p')
          path = vim.fs.normalize(vim.uv.fs_realpath(path))
          candidates[#candidates + 1] = {path=path, hash=vim.fn.sha256(path):sub(1, 24)}
        end
        table.sort(candidates, function(a, b) return a.hash < b.hash end)
        local foreign, selected = candidates[1], candidates[2]
        assert(foreign.hash < selected.hash, 'the old lexical scan must visit the foreign project first')
        local cohorts = {}
        for cohort, count in ipairs({64, 64, 1}) do
          vim.cmd('cd ' .. vim.fn.fnameescape(cohort < 3 and foreign.path or selected.path))
          recovery.setup({root=dir .. '/journal', delay_ms=90 + cohort})
          local buffers, paths = {}, {}
          for index = 1, count do
            local buf = vim.api.nvim_create_buf(true, false)
            vim.api.nvim_buf_set_lines(buf, 0, -1, false, {'project cohort ' .. cohort .. ' item ' .. index})
            buffers[#buffers + 1] = buf
            paths[#paths + 1] = capture(buf)
          end
          if cohort < 3 then
            cohorts[#cohorts + 1] = vim.fs.dirname(paths[1])
            for _, buf in ipairs(buffers) do vim.api.nvim_buf_delete(buf, {force=true}) end
          else
            print('IDE_RECOVERY_PROJECT_READY ' .. vim.json.encode({pid=vim.fn.getpid(), selected=selected.path,
              foreign_a=cohorts[1], foreign_b=cohorts[2], latest=paths[1]}))
          end
        end
      ]],
        true,
        true
      )
      local ready
      local complete = vim.wait(15000, function()
        local encoded = (output.stdout .. output.stderr):match("IDE_RECOVERY_PROJECT_READY (%b{})")
        if encoded then
          ready = vim.json.decode(encoded)
          return true
        end
        return job:is_closing()
      end, 10)
      t.assert_true(
        complete and ready,
        output.stdout .. output.stderr .. "\nproject fixtures did not reach durable READY"
      )
      t.assert_eq(ready.pid, job.pid)
      for _, directory in ipairs({ ready.foreign_a, ready.foreign_b }) do
        local count = 0
        for name, kind in vim.fs.dir(directory) do
          if kind == "file" and name:match("^%d+%.json$") then
            count = count + 1
          end
        end
        t.assert_eq(count, 64)
        t.assert_false(vim.uv.fs_stat(directory .. "/closed"), "foreign fixtures must remain real crash sessions")
      end
      t.assert_true(vim.uv.fs_stat(ready.latest))
      job:kill(9)
      job:wait(5000)
      reader(
        dir,
        jobs,
        ([[
        assert(vim.fn.getpid() ~= %d)
        vim.cmd('cd ' .. vim.fn.fnameescape(%q))
        local found = records({})
        assert(#found == 1 and found[1].path == %q,
          'foreign project snapshots consumed default discovery budget: ' .. vim.inspect(found))
        assert(found[1].project == vim.fs.normalize(vim.uv.fs_realpath(vim.fn.getcwd())))
        local copy = assert(recovery.restore(found[1]))
        content(copy, {'project cohort 3 item 1'})
        assert(vim.api.nvim_buf_get_name(copy) == '' and vim.bo[copy].modified)
      ]]):format(ready.pid, ready.selected, ready.latest)
      )
    end)
  end)
end)
