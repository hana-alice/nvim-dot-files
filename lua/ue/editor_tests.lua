-- Explicit Editor automation, with host plans owned by platform drivers.
-- Output ownership: canonical-project bucket + PID + per-process invocation;
-- no shared mutable results/cache files, no source/index/build writes.
local M = {}
local active, sequence = nil, 0
local history, history_order = {}, {}
local OUTPUT_LIMIT = 2 * 1024 * 1024

local function evidence(run)
  pcall(function()
    local probe = require("utils.probe")
    probe.observe("ue-editor-tests", "ide-ue-tools-2026-10-03")
    -- A correctly reported failed game test is expected workflow output.
    -- Missing results, interrupted startup and inconsistent evidence are gaps.
    local reported_failure = run.report
      and type(run.report.failed) == "table"
      and #run.report.failed > 0
      and run.report.pending == 0
      and (run.signal or 0) == 0
    probe.record("ue-editor-tests", run.plan.operation, {
      state = (run.ok or reported_failure) and "ok" or "unavailable",
      project = vim.fn.sha256(run.plan.identity):sub(1, 16),
      engine_root = run.context.engine_root,
      uproject = run.context.uproject,
      filter = run.plan.filter,
      log_path = run.plan.log_path,
      code = run.exit_code,
      signal = run.signal,
      reason = run.error and run.error:sub(1, 512),
      tests_failed = run.report and run.report.failed and #run.report.failed or nil,
    })
  end)
end

local function field(object, name)
  if type(object) ~= "table" then
    return nil
  end
  local camel = name:sub(1, 1):lower() .. name:sub(2)
  if object[camel] ~= nil then
    return object[camel]
  end
  return object[name]
end

local function project_key(ctx)
  local path = ctx and ctx.uproject and vim.uv.fs_realpath(ctx.uproject)
  if not path then
    return nil
  end
  return require("utils.platform").driver().path_key(vim.fs.normalize(path))
end

local function context_identity(ctx)
  local project = project_key(ctx)
  local engine = ctx and ctx.engine_root and vim.uv.fs_realpath(ctx.engine_root)
  if not project or not engine then
    return nil
  end
  return project .. "\0" .. require("utils.platform").driver().path_key(vim.fs.normalize(engine))
end

local function read(path)
  local stat = vim.uv.fs_stat(path)
  if not stat or stat.type ~= "file" or stat.size > OUTPUT_LIMIT then
    return nil
  end
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local value = f:read("*a")
  f:close()
  return value
end

local function valid_filter(filter)
  return type(filter) == "string" and #filter <= 4096 and vim.trim(filter) ~= "" and not filter:find("[%c;,\"']")
end

function M.parse_report(content)
  if type(content) ~= "string" then
    return nil, "没有可读的 UE 测试 JSON 报告"
  end
  if content:sub(1, 3) == "\239\187\191" then
    content = content:sub(4)
  end
  local decoded, document = pcall(vim.json.decode, content)
  local tests = decoded and field(document, "Tests") or nil
  if type(tests) ~= "table" or #tests == 0 then
    return nil, "报告中没有实际测试结果"
  end
  local totals = {}
  for _, name in ipairs({ "Succeeded", "SucceededWithWarnings", "Failed", "NotRun" }) do
    local count = field(document, name)
    if type(count) ~= "number" or count < 0 or count ~= math.floor(count) then
      return nil, "报告统计字段缺失或无效"
    end
    totals[name] = count
  end
  local result = { tests = {}, failed = {}, diagnostics = {}, succeeded = 0, pending = 0, ok = false }
  local seen = {}
  for _, row in ipairs(tests) do
    local name, state = field(row, "FullTestPath"), field(row, "State")
    if type(name) ~= "string" or name == "" or seen[name] then
      return nil, "报告测试名称缺失或重复"
    end
    seen[name] = true
    if state == "Success" then
      result.succeeded = result.succeeded + 1
    elseif state == "Fail" then
      result.failed[#result.failed + 1] = name
    elseif state == "NotRun" or state == "InProcess" then
      result.pending = result.pending + 1
    else
      return nil, "报告含未支持的测试状态：" .. tostring(state)
    end
    result.tests[#result.tests + 1] = { name = name, state = state }
    local entries = field(row, "Entries") or {}
    if type(entries) ~= "table" then
      return nil, "报告事件格式无效"
    end
    local has_error = false
    for _, entry in ipairs(entries) do
      local event = field(entry, "Event")
      local severity = field(event, "Type")
      if severity == "Error" or severity == "Warning" or severity == 2 or severity == 1 then
        local filename, line = field(entry, "Filename"), tonumber(field(entry, "LineNumber"))
        local kind = (severity == "Error" or severity == 2) and "E" or "W"
        has_error = has_error or kind == "E"
        result.diagnostics[#result.diagnostics + 1] = {
          test = name,
          filename = type(filename) == "string" and filename ~= "" and filename or nil,
          lnum = line and line > 0 and math.floor(line) or 0,
          text = name .. ": " .. tostring(field(event, "Message") or ""),
          type = kind,
        }
      end
    end
    if state == "Success" and has_error then
      return nil, "报告成功状态与错误事件矛盾"
    end
    if state == "Fail" and not has_error then
      result.diagnostics[#result.diagnostics + 1] =
        { test = name, text = name .. ": 测试失败，报告没有错误源码位置", type = "E", lnum = 0 }
    end
  end
  if
    result.succeeded ~= totals.Succeeded + totals.SucceededWithWarnings
    or #result.failed ~= totals.Failed
    or result.pending ~= totals.NotRun
    or #tests ~= result.succeeded + #result.failed + result.pending
  then
    return nil, "报告统计与实际测试行不一致"
  end
  result.ok = #result.failed == 0 and result.pending == 0
  return result
end

function M.parse_list(content)
  if type(content) ~= "string" then
    return nil, "没有测试发现日志"
  end
  local found, names, seen = nil, {}, {}
  for line in content:gmatch("[^\r\n]+") do
    local text = line:match("LogAutomationCommandLine:%s*Display:%s?(.*)")
    if text then
      local count = text:match("^%s*Found (%d+) Automation Tests%s*$")
      if count then
        found, names, seen = tonumber(count), {}, {}
      elseif found and text:match("^%s*\t") then
        local name = vim.trim(text)
        if name ~= "" and not seen[name] then
          names[#names + 1] = name
          seen[name] = true
        end
      end
    end
  end
  if found == nil or #names ~= found then
    return nil, "测试发现未完成，或日志中的数量与名称不一致"
  end
  return { tests = names, ok = true, count = found }
end

function M.failed_filter(report)
  if type(report) ~= "table" or type(report.failed) ~= "table" or #report.failed == 0 then
    return nil, "当前工程没有可重跑的失败测试"
  end
  local names = {}
  for _, name in ipairs(report.failed) do
    if not valid_filter(name) or name:find("[+%^$]") then
      return nil, "测试名称含 UE 筛选分隔符，无法安全精确重跑"
    end
    names[#names + 1] = "^" .. name:gsub(" ", "") .. "$"
  end
  local filter = table.concat(names, "+")
  if not valid_filter(filter) then
    return nil, "失败测试筛选过长，先选择单个失败测试"
  end
  return filter
end

function M.plan(ctx, opts)
  opts = opts or {}
  local identity = project_key(ctx)
  if not identity or not ctx.engine_root then
    return nil, "未选择有效工程；先运行 :UESetProject"
  end
  local operation = opts.operation or "list"
  if operation ~= "list" and operation ~= "run" then
    return nil, "测试操作只能是 list 或 run"
  end
  if operation == "run" and not valid_filter(opts.filter) then
    return nil, "测试筛选不能为空或含命令分隔符/引号/换行"
  end
  sequence = sequence + 1
  local project = vim.fn.sha256(identity):sub(1, 16)
  local root = opts.output_root or (vim.fn.stdpath("state") .. "/ue-tests")
  local report_dir = vim.fs.normalize(root .. "/" .. project .. "/" .. vim.fn.getpid() .. "-" .. sequence)
  local frozen = vim.deepcopy(ctx)
  frozen.uproject = vim.fs.normalize(assert(vim.uv.fs_realpath(ctx.uproject)))
  local engine = vim.uv.fs_realpath(ctx.engine_root)
  if not engine then
    return nil, "所选引擎目录不可用"
  end
  frozen.engine_root = vim.fs.normalize(engine)
  local cap = require("utils.platform").optional_capability(opts.driver, "ue_editor_test_plan", {
    engine_root = frozen.engine_root,
    uproject = frozen.uproject,
    operation = operation,
    filter = opts.filter,
    report_dir = report_dir,
    log_path = report_dir .. "/editor.log",
  })
  if not cap.ok then
    return nil, "宿主 ue_editor_test_plan 不可用：" .. tostring(cap.detail or cap.reason)
  end
  local plan = cap.value
  if type(plan) ~= "table" or type(plan.argv) ~= "table" or type(plan.argv[1]) ~= "string" or plan.argv[1] == "" then
    return nil, "宿主 Editor 测试计划不完整"
  end
  if plan.report_dir ~= report_dir or plan.log_path ~= report_dir .. "/editor.log" then
    return nil, "宿主测试计划改变了本次拥有的输出路径"
  end
  return {
    argv = vim.deepcopy(plan.argv),
    cwd = plan.cwd,
    report_dir = report_dir,
    log_path = plan.log_path,
    context = frozen,
    identity = identity,
    operation = operation,
    filter = opts.filter,
  }
end

local function diagnostics(run)
  local out = {}
  for _, item in ipairs(run.report and run.report.diagnostics or {}) do
    local copy = vim.deepcopy(item)
    if copy.filename then
      copy.filename = vim.fs.normalize(copy.filename)
    end
    if copy.filename and not require("ue.core.fs").is_absolute_path(copy.filename) then
      local root = copy.filename:match("^Engine/") and run.context.engine_root or vim.fs.dirname(run.context.uproject)
      copy.filename = vim.fs.normalize(root .. "/" .. copy.filename)
    end
    copy._source_location = copy.filename ~= nil and copy.lnum > 0 and vim.fn.filereadable(copy.filename) == 1
    if not copy._source_location then
      copy.filename, copy.lnum = run.plan.log_path, 1
    end
    out[#out + 1] = copy
  end
  if #out == 0 and not run.ok then
    out[1] = {
      text = run.error or "UE 测试未确认完成",
      type = "E",
      filename = run.plan.log_path,
      lnum = 1,
      _source_location = false,
    }
  end
  return out
end

local function remember(run)
  if not history[run.plan.identity] then
    history_order[#history_order + 1] = run.plan.identity
  end
  history[run.plan.identity] = run
  if #history_order > 16 then
    history[table.remove(history_order, 1)] = nil
  end
end

function M.start(ctx, opts, callback)
  opts = opts or {}
  if active then
    return nil, "已有 Editor 测试任务运行；可在 :Tasks 中停止"
  end
  local plan, err = M.plan(ctx, opts)
  if not plan then
    return nil, err
  end
  local made, mkdir_err = pcall(vim.fn.mkdir, plan.report_dir, "p")
  if not made or vim.fn.isdirectory(plan.report_dir) ~= 1 then
    return nil, "无法创建测试输出目录：" .. tostring(mkdir_err)
  end
  local admission = require("utils.host_admission")
  local token = admission.foreground_begin("UE Editor tests")
  local run = { plan = plan, context = vim.deepcopy(plan.context), output = {}, output_bytes = 0 }
  active = run
  local function collect(error_message, data)
    local chunk = data or (error_message and tostring(error_message))
    if not chunk or run.output_bytes >= OUTPUT_LIMIT then
      return
    end
    chunk = chunk:sub(1, OUTPUT_LIMIT - run.output_bytes)
    run.output[#run.output + 1], run.output_bytes = chunk, run.output_bytes + #chunk
  end
  -- Foreground, single owned Editor process, bounded lifetime. All executable
  -- and low-resource argv policy is supplied by the current host driver.
  local spawned, handle = pcall(opts.system or vim.system, plan.argv, {
    cwd = plan.cwd,
    text = true,
    timeout = opts.timeout_ms or (plan.operation == "list" and 120000 or 600000),
    stdout = collect,
    stderr = collect,
  }, function(result)
    vim.schedule(function()
      admission.foreground_done(token)
      if active == run then
        active = nil
      end
      run.exit_code, run.signal = result.code, result.signal
      local report, parse_err
      if plan.operation == "list" then
        report, parse_err = M.parse_list(table.concat(run.output, ""))
        if not report then
          report, parse_err = M.parse_list(read(plan.log_path))
        end
      else
        report, parse_err = M.parse_report((opts.read_report or read)(plan.report_dir .. "/index.json"))
      end
      run.report = report
      run.ok = result.code == 0 and (result.signal or 0) == 0 and report ~= nil and report.ok
      if not run.ok then
        local reasons = {}
        if result.code ~= 0 then
          reasons[#reasons + 1] = "Editor 退出码 " .. tostring(result.code)
        end
        if (result.signal or 0) ~= 0 then
          reasons[#reasons + 1] = "中止信号 " .. tostring(result.signal)
        end
        reasons[#reasons + 1] = parse_err or "UE 测试失败或尚未完成"
        run.error = table.concat(reasons, "；")
      end
      remember(run)
      evidence(run)
      local notify = opts.notify or vim.notify
      local text = plan.operation == "list" and "发现 " .. tostring(report and report.count or 0) .. " 个测试"
        or "测试通过 "
          .. tostring(report and report.succeeded or 0)
          .. "，失败 "
          .. tostring(report and #report.failed or 0)
      notify(
        run.ok and text or (run.error .. "；日志：" .. plan.log_path),
        run.ok and vim.log.levels.INFO or vim.log.levels.WARN
      )
      if plan.operation == "run" and (not run.ok or #(report and report.diagnostics or {}) > 0) then
        (opts.publish or require("ue.build_diagnostics").publish)("UE 测试 " .. (plan.filter or ""), diagnostics(run))
      end
      if callback then
        callback(run)
      end
    end)
  end)
  if spawned then
    pcall(
      require("utils.task_registry").register,
      { name = "UE tests " .. (plan.filter or "list"), group = "ue", kind = "system", handle = handle }
    )
  end
  if not spawned or not handle then
    admission.foreground_done(token)
    active = nil
    return nil, "无法启动 Editor 测试：" .. tostring(handle)
  end
  run.handle = handle
  local notify = opts.notify or vim.notify
  notify("UE Editor 测试已启动；可在 :Tasks 中查看/停止", vim.log.levels.INFO)
  return run
end

function M.last(ctx)
  local identity = project_key(ctx)
  local run = identity and history[identity] or nil
  return run and context_identity(run.context) == context_identity(ctx) and run or nil
end

function M.show_log(run)
  if not run then
    return nil
  end
  local buf = run.log_buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    buf = vim.api.nvim_create_buf(false, true)
    run.log_buf = buf
    vim.api.nvim_buf_set_name(buf, "ue-tests-log://" .. vim.fn.getpid() .. "/" .. vim.fs.basename(run.plan.report_dir))
    local content = read(run.plan.log_path) or table.concat(run.output or {}, "")
    local lines = { "UE 测试日志：" .. run.plan.log_path, "" }
    vim.list_extend(lines, vim.split(content, "\n", { plain = true }))
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].filetype, vim.bo[buf].modifiable, vim.bo[buf].bufhidden = "log", false, "hide"
  end
  return require("utils.bottom_panel").show("debug", buf, { focus = true })
end

function M.results(ctx)
  local run = M.last(ctx)
  if not run then
    vim.notify("当前工程没有本进程的测试结果", vim.log.levels.INFO)
    return
  end
  require("ue.build_diagnostics").publish("UE 测试结果", diagnostics(run))
  if run.report and run.plan.operation == "run" then
    vim.ui.select(run.report.tests, {
      prompt = "测试结果（选择后查看报告日志）：",
      format_item = function(row)
        return row.state .. "  " .. row.name
      end,
    }, function(row)
      if not row then
        return
      end
      local entries = {}
      for _, item in ipairs(diagnostics(run)) do
        if item.test == row.name then
          entries[#entries + 1] = item
        end
      end
      if #entries > 0 and require("ue.build_diagnostics").publish("UE 测试 " .. row.name, entries) then
        require("utils.bottom_panel").show("quickfix", nil, { focus = true })
      else
        M.show_log(run)
      end
    end)
  elseif run.plan.operation == "list" and run.report then
    M.choose(ctx, run.report.tests)
  else
    M.show_log(run)
  end
end

function M.choose(ctx, names)
  local original = context_identity(ctx)
  if original ~= context_identity(require("ue").resolve_context()) then
    vim.notify("工程或引擎已切换；测试发现结果已保留，请重新打开结果", vim.log.levels.INFO)
    return false
  end
  vim.ui.select(names, { prompt = "选择测试（启动命令行 Editor；不会自动构建）：" }, function(name)
    if not name then
      return
    end
    local current = require("ue").resolve_context()
    if context_identity(current) ~= original then
      vim.notify("工程或引擎已切换，请重新发现测试", vim.log.levels.WARN)
      return
    end
    local filter, err = M.failed_filter({ failed = { name } })
    if not filter then
      vim.notify(err, vim.log.levels.WARN)
      return
    end
    local run, start_err = M.start(ctx, { operation = "run", filter = filter })
    if not run then
      vim.notify(start_err, vim.log.levels.WARN)
    end
  end)
end

function M.command(args, captured)
  local ctx, context_err = require("ue").resolve_context()
  if not ctx or not project_key(ctx) then
    vim.notify(context_err or "先运行 :UESetProject", vim.log.levels.WARN)
    return
  end
  if captured and context_identity(captured) ~= context_identity(ctx) then
    vim.notify("工程或引擎已切换，请重新选择测试操作", vim.log.levels.WARN)
    return
  end
  local operation = args and args[1]
  if not operation then
    local choices = {
      { id = "list", label = "列出可运行测试（启动命令行 Editor）" },
      { id = "run", label = "输入筛选并运行" },
      { id = "results", label = "查看上一结果" },
      { id = "rerun", label = "只重跑失败测试" },
    }
    local frozen = vim.deepcopy(ctx)
    vim.ui.select(choices, {
      prompt = "UE Editor 测试：",
      format_item = function(choice)
        return choice.label
      end,
    }, function(choice)
      if not choice then
        return
      end
      if choice.id == "run" then
        vim.ui.input({ prompt = "UE 测试筛选（子串；^名称$ 精确；+ 多个）：" }, function(filter)
          if filter then
            M.command({ "run", filter }, frozen)
          end
        end)
      else
        M.command({ choice.id }, frozen)
      end
    end)
    return
  end
  if operation == "results" then
    return M.results(ctx)
  end
  local filter = args[2] and table.concat(args, " ", 2) or nil
  if operation == "rerun" then
    local last = M.last(ctx)
    local err
    filter, err = M.failed_filter(last and last.report)
    if not filter then
      vim.notify(err, vim.log.levels.INFO)
      return
    end
    operation = "run"
  end
  local run, err = M.start(ctx, { operation = operation, filter = filter }, function(done)
    if done.ok and done.plan.operation == "list" then
      M.choose(done.context, done.report.tests)
    end
  end)
  if not run then
    vim.notify(err, vim.log.levels.WARN)
  end
end

function M.setup_commands()
  vim.api.nvim_create_user_command("UETests", function(args)
    M.command(args.fargs)
  end, {
    nargs = "*",
    desc = "发现、运行和重跑 UE Editor 测试",
    complete = function()
      return { "list", "run", "rerun", "results" }
    end,
  })
end

return M
