-- Read-only, capability-oriented health audit for this Neovim configuration.
--
-- The interactive editor must never run these probes synchronously.  The
-- public run_async() entrypoint starts scripts/nvim_core_health.lua in a
-- dedicated headless Neovim; run()/run_checks() are intended for that child
-- and for headless regression tests.

local M = {}

local uv = vim.uv or vim.loop

M.SCHEMA_VERSION = 1
M.STATUS = {
  PASS = "PASS",
  FAIL = "FAIL",
  BLOCKED = "BLOCKED",
  SKIP = "SKIP",
}

local VALID_STATUS = {
  PASS = true,
  FAIL = true,
  BLOCKED = true,
  SKIP = true,
}

local function is_list(value)
  if vim.islist then
    return vim.islist(value)
  end
  if type(value) ~= "table" then
    return false
  end
  local count = 0
  for key in pairs(value) do
    if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
      return false
    end
    count = count + 1
  end
  for index = 1, count do
    if value[index] == nil then
      return false
    end
  end
  return true
end

local function copy(value)
  if type(value) ~= "table" then
    return value
  end
  local result = {}
  for key, item in pairs(value) do
    result[copy(key)] = copy(item)
  end
  return result
end

local function trim(value)
  return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function normalize_slashes(value)
  return tostring(value or ""):gsub("\\", "/")
end

local function sorted_unique(values)
  local seen = {}
  local result = {}
  for _, value in ipairs(values or {}) do
    value = trim(value)
    if value ~= "" and not seen[value] then
      seen[value] = true
      result[#result + 1] = value
    end
  end
  table.sort(result)
  return result
end

---Aggregate check statuses without hiding deterministic failures or gates.
---@param checks table[]
---@return 'PASS'|'FAIL'|'DEGRADED'
function M.overall_status(checks)
  local blocked = false
  for _, check in ipairs(checks or {}) do
    if check.status == M.STATUS.FAIL then
      return "FAIL"
    end
    if check.status == M.STATUS.BLOCKED then
      blocked = true
    end
  end
  return blocked and "DEGRADED" or "PASS"
end

local SECRET_KEYS = {
  "password",
  "passwd",
  "secret",
  "token",
  "credential",
  "private_key",
  "private-key",
  "certificate",
  "identity",
  "device_id",
  "device-id",
  "serial",
}

local function sensitive_key(key)
  local lower = tostring(key or ""):lower()
  for _, needle in ipairs(SECRET_KEYS) do
    if lower:find(needle, 1, true) then
      return true
    end
  end
  return false
end

local function redact_string(value, opts)
  local result = tostring(value)
  local roots = {}
  for _, root in ipairs(opts.sensitive_roots or {}) do
    root = normalize_slashes(root):gsub("/+$", "")
    if root ~= "" then
      roots[#roots + 1] = root
    end
  end
  local home = normalize_slashes(opts.home or (uv.os_homedir and uv.os_homedir()) or ""):gsub("/+$", "")
  if home ~= "" then
    roots[#roots + 1] = home
  end
  table.sort(roots, function(a, b)
    return #a > #b
  end)
  result = normalize_slashes(result)
  for _, root in ipairs(roots) do
    local start = 1
    while true do
      local first, last = result:find(root, start, true)
      if not first then
        break
      end
      result = result:sub(1, first - 1) .. "<redacted-path>" .. result:sub(last + 1)
      start = first + #"<redacted-path>"
    end
  end
  -- Catch home paths even when a report was produced on another machine.
  result = result:gsub("/[Uu]sers/[^/%s]+/[^%s,;]+", "<redacted-path>")
  result = result:gsub("[A-Za-z]:/[Uu]sers/[^/%s]+/[^%s,;]+", "<redacted-path>")
  return result
end

---Return a redacted immutable copy suitable for public text/JSON reports.
---@param value any
---@param opts? { sensitive_roots?: string[], home?: string }
---@return any
function M.redact(value, opts)
  opts = opts or {}
  local function visit(item, key_hint)
    if type(item) == "string" then
      if key_hint and sensitive_key(key_hint) then
        return "<redacted>"
      end
      return redact_string(item, opts)
    end
    if type(item) ~= "table" then
      return item
    end
    local out = {}
    for key, child in pairs(item) do
      local safe_key = type(key) == "string" and redact_string(key, opts) or key
      out[safe_key] = visit(child, key)
    end
    return out
  end
  return visit(value)
end

local function selectors(filter)
  if filter == nil or filter == "" then
    return {}
  end
  if type(filter) == "table" then
    return sorted_unique(filter)
  end
  local result = {}
  for token in tostring(filter):gmatch("[^,]+") do
    result[#result + 1] = trim(token)
  end
  return sorted_unique(result)
end

---Filter definitions by exact id/stage or id prefix. always=true survives.
---@param definitions table[]
---@param filter? string|string[]
---@return table[]
function M.filter_checks(definitions, filter)
  local wanted = selectors(filter)
  if #wanted == 0 then
    return copy(definitions or {})
  end
  local result = {}
  for _, definition in ipairs(definitions or {}) do
    local matched = definition.always == true
    for _, selector in ipairs(wanted) do
      if
        definition.id == selector
        or definition.stage == selector
        or tostring(definition.id):sub(1, #selector + 1) == selector .. "."
      then
        matched = true
        break
      end
    end
    if matched then
      result[#result + 1] = definition
    end
  end
  return result
end

---Pure classifier for the pinned compiler-semantics toolchain.
---@param output string
---@return table
function M.classify_clangd_version(output)
  local version = tostring(output or ""):match("[Vv]ersion%s+(%d+%.%d+%.%d+)")
    or tostring(output or ""):match("[Vv]ersion%s+(%d+%.%d+)")
  if not version then
    return {
      status = M.STATUS.BLOCKED,
      compatible = false,
      summary = "clangd version could not be determined",
    }
  end
  local major, minor = version:match("^(%d+)%.(%d+)")
  local compatible = tonumber(major) == 22 and tonumber(minor) == 1
  return {
    status = compatible and M.STATUS.PASS or M.STATUS.BLOCKED,
    compatible = compatible,
    version = version,
    summary = compatible and ("clangd " .. version .. " satisfies 22.1.x")
      or ("clangd " .. version .. " does not satisfy 22.1.x"),
  }
end

---Pure search capability classifier used by reports and regression tests.
---@param rg_ok boolean
---@param csearch_ok boolean
---@param cindex_ok boolean
---@return table
function M.classify_search_tools(rg_ok, csearch_ok, cindex_ok)
  if not rg_ok then
    return {
      status = M.STATUS.FAIL,
      backend = nil,
      summary = "rg fallback is unavailable",
    }
  end
  if csearch_ok and cindex_ok then
    return {
      status = M.STATUS.PASS,
      backend = "csearch",
      summary = "rg fallback and csearch index toolchain are available",
    }
  end
  local missing = {}
  if not csearch_ok then
    missing[#missing + 1] = "csearch"
  end
  if not cindex_ok then
    missing[#missing + 1] = "cindex-uefilter"
  end
  return {
    status = M.STATUS.BLOCKED,
    backend = "rg",
    missing = missing,
    summary = "rg fallback available; " .. table.concat(missing, " and ") .. " unavailable",
  }
end

local function default_dependencies()
  return {
    now_ms = function()
      return math.floor(uv.hrtime() / 1e6)
    end,
    tempname = vim.fn.tempname,
    mkdir = function(path)
      return vim.fn.mkdir(path, "p") == 1 or vim.fn.isdirectory(path) == 1
    end,
    delete = function(path)
      return vim.fn.delete(path, "rf") == 0
    end,
    stat = uv.fs_stat,
  }
end

local function merge_dependencies(overrides)
  local result = default_dependencies()
  for key, value in pairs(overrides or {}) do
    result[key] = value
  end
  return result
end

local function make_context(opts)
  local deps = merge_dependencies(opts.deps)
  local temp_root = opts.temp_root or (deps.tempname() .. "-nvim-core-health")
  local existed = deps.stat(temp_root) ~= nil
  local created = not existed and deps.mkdir(temp_root)
  return {
    opts = opts,
    deps = deps,
    config_root = opts.config_root or vim.fn.stdpath("config"),
    temp_root = temp_root,
    temp_created = created == true,
    temp_conflict = existed,
    cancellers = {},
  }
end

local function normalize_check(definition, raw, duration_ms, ctx)
  raw = type(raw) == "table" and raw
    or {
      status = M.STATUS.FAIL,
      summary = "check returned an invalid result",
    }
  local status = VALID_STATUS[raw.status] and raw.status or M.STATUS.FAIL
  local result = {
    id = tostring(definition.id),
    stage = tostring(definition.stage),
    status = status,
    duration_ms = math.max(0, math.floor(tonumber(duration_ms) or 0)),
    summary = trim(raw.summary) ~= "" and trim(raw.summary) or "no summary",
    next_step = raw.next_step or vim.NIL,
  }
  if raw.evidence ~= nil then
    result.evidence = raw.evidence
  end
  if raw.deadline_ms ~= nil then
    result.deadline_ms = tonumber(raw.deadline_ms)
  end
  return M.redact(result, {
    sensitive_roots = { ctx.temp_root, ctx.config_root, unpack(ctx.opts.sensitive_roots or {}) },
  })
end

---Run injected or real check definitions with exception isolation.
---@param definitions table[]
---@param opts? table
---@return table report
function M.run_checks(definitions, opts)
  opts = opts or {}
  local ctx = make_context(opts)
  local chosen = M.filter_checks(definitions, opts.filter)
  local checks = {}
  local seen = {}

  for _, definition in ipairs(chosen) do
    local started = ctx.deps.now_ms()
    local raw
    if
      type(definition.id) ~= "string"
      or definition.id == ""
      or type(definition.stage) ~= "string"
      or definition.stage == ""
      or type(definition.run) ~= "function"
    then
      raw = { status = M.STATUS.FAIL, summary = "invalid check definition" }
    elseif seen[definition.id] then
      raw = { status = M.STATUS.FAIL, summary = "duplicate check id" }
    elseif not ctx.temp_created and definition.needs_temp ~= false then
      raw = {
        status = M.STATUS.FAIL,
        summary = ctx.temp_conflict and "refused to reuse an existing temporary directory"
          or "isolated temporary directory could not be created",
        next_step = "Verify the system temporary directory is writable.",
      }
    else
      seen[definition.id] = true
      local ok, value = xpcall(function()
        return definition.run(ctx)
      end, debug.traceback)
      if ok then
        raw = value
      else
        raw = {
          status = M.STATUS.FAIL,
          summary = "check raised an isolated error: " .. tostring(value),
          next_step = "Run the check by id and inspect its redacted error.",
        }
      end
    end
    local elapsed = ctx.deps.now_ms() - started
    if definition.timeout_ms and elapsed > definition.timeout_ms and type(raw) == "table" then
      raw.status = raw.status == M.STATUS.BLOCKED and M.STATUS.BLOCKED or M.STATUS.FAIL
      raw.summary = ("probe exceeded its %dms deadline"):format(definition.timeout_ms)
      raw.next_step = "Run the filtered probe again and inspect the external process or parser."
      raw.deadline_ms = definition.timeout_ms
    end
    checks[#checks + 1] = normalize_check(definition, raw, elapsed, ctx)
  end

  local cleanup_started = ctx.deps.now_ms()
  for _, cancel in ipairs(ctx.cancellers) do
    pcall(cancel)
  end
  local cleanup_ok = not ctx.temp_created or ctx.deps.delete(ctx.temp_root)
  if opts.include_cleanup then
    local cleanup_next_step
    if not cleanup_ok then
      cleanup_next_step = "Remove the redacted health temporary directory manually."
    end
    checks[#checks + 1] = normalize_check({ id = "cleanup.temp", stage = "cleanup" }, {
      status = cleanup_ok and M.STATUS.PASS or M.STATUS.FAIL,
      summary = not ctx.temp_created and "no temporary audit resources were created"
        or cleanup_ok and "temporary audit resources were removed"
        or "temporary audit resources could not be removed",
      next_step = cleanup_next_step,
    }, ctx.deps.now_ms() - cleanup_started, ctx)
  end

  local report = {
    schema_version = M.SCHEMA_VERSION,
    mode = opts.live and "live" or "deterministic",
    overall = M.overall_status(checks),
    checks = checks,
  }
  return M.redact(report, {
    sensitive_roots = { ctx.temp_root, ctx.config_root, unpack(opts.sensitive_roots or {}) },
  })
end

function M.exit_code(report)
  return report and report.overall == "FAIL" and 1 or 0
end

function M.encode_json(report)
  return vim.json.encode(report)
end

function M.format_text(report)
  local lines = {
    ("Neovim core health: %s (%s)"):format(tostring(report.overall), tostring(report.mode)),
  }
  for _, check in ipairs(report.checks or {}) do
    lines[#lines + 1] = ("[%s] %s (%dms) - %s"):format(
      check.status,
      check.id,
      tonumber(check.duration_ms) or 0,
      check.summary
    )
    if check.next_step ~= nil and check.next_step ~= vim.NIL then
      lines[#lines + 1] = "  next: " .. tostring(check.next_step)
    end
  end
  return table.concat(lines, "\n")
end

---Run the complete deterministic/live audit in a dedicated headless process.
---Tests may inject opts.checks; real runs load the capability definitions.
---@param opts? table
---@return table
function M.run(opts)
  opts = opts or {}
  local definitions = opts.checks or require("utils.core_health_checks").definitions(opts)
  local run_opts = copy(opts)
  run_opts.live = opts.live == true or opts.mode == "live"
  if opts.checks == nil and opts.include_cleanup == nil then
    run_opts.include_cleanup = true
  end
  return M.run_checks(definitions, run_opts)
end

local function report_window(lines)
  local buffer = vim.api.nvim_create_buf(false, true)
  vim.bo[buffer].buftype = "nofile"
  vim.bo[buffer].bufhidden = "wipe"
  vim.bo[buffer].swapfile = false
  vim.bo[buffer].filetype = "nvim-core-health"
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, lines)
  vim.bo[buffer].modifiable = false

  local width = math.max(1, math.min(110, vim.o.columns - 4))
  local height = math.max(1, math.min(#lines + 2, vim.o.lines - 4))
  local window = vim.api.nvim_open_win(buffer, true, {
    relative = "editor",
    style = "minimal",
    border = "rounded",
    title = " Neovim Core Health ",
    title_pos = "center",
    width = width,
    height = height,
    row = math.max(1, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
  })
  vim.wo[window].wrap = false
  vim.keymap.set("n", "q", "<cmd>close<cr>", { buffer = buffer, silent = true })
  vim.keymap.set("n", "<Esc>", "<cmd>close<cr>", { buffer = buffer, silent = true })
end

---Start the audit without blocking the interactive editor UI.
---@param opts? { filter?: string, live?: boolean, on_done?: fun(report?: table, error?: string) }
---@return table|nil process
function M.run_async(opts)
  opts = opts or {}
  local config_root = opts.config_root or vim.fn.stdpath("config")
  local nvim = vim.v.progpath ~= "" and vim.v.progpath or vim.fn.exepath("nvim")
  local argv = {
    nvim,
    "--headless",
    "-i",
    "NONE",
    "-l",
    config_root .. "/scripts/nvim_core_health.lua",
    "--json",
  }
  if opts.live then
    argv[#argv + 1] = "--live"
  end
  if opts.filter and opts.filter ~= "" then
    argv[#argv + 1] = "--filter"
    argv[#argv + 1] = opts.filter
  end

  vim.notify("Core health audit started in an isolated Neovim process…", vim.log.levels.INFO)
  local process_handle
  local timer = uv.new_timer()
  local finished = false
  local function finish(report, error_message)
    if finished then
      return
    end
    finished = true
    if timer then
      pcall(timer.stop, timer)
      pcall(timer.close, timer)
    end
    vim.schedule(function()
      if opts.on_done then
        opts.on_done(report, error_message)
        return
      end
      if not report then
        vim.notify("Core health audit failed: " .. tostring(error_message), vim.log.levels.ERROR)
        return
      end
      report_window(vim.split(M.format_text(report), "\n", { plain = true }))
    end)
  end

  timer:start(90000, 0, function()
    if process_handle then
      pcall(process_handle.kill, process_handle, 15)
    end
    finish(nil, "outer audit process exceeded its 90000ms deadline")
  end)
  local ok, spawned = pcall(vim.system, argv, {
    text = true,
    env = vim.tbl_extend("force", vim.fn.environ(), {
      NVIM_CORE_HEALTH_NO_MUTATE = "1",
    }),
  }, function(completed)
    local decoded_ok, report = pcall(vim.json.decode, tostring(completed.stdout or ""))
    if not decoded_ok or type(report) ~= "table" then
      finish(nil, trim(completed.stderr) ~= "" and trim(completed.stderr) or "runner returned invalid JSON")
      return
    end
    finish(report)
  end)
  if not ok then
    finish(nil, tostring(spawned))
    return nil
  end
  process_handle = spawned
  pcall(require("utils.task_registry").register, {
    name = "Neovim core health audit",
    group = "health",
    kind = "system",
    handle = spawned,
  })
  return spawned
end

---Register the non-blocking interactive command once.
function M.setup()
  if vim.fn.exists(":NvimCoreHealth") == 2 then
    return
  end
  vim.api.nvim_create_user_command("NvimCoreHealth", function(command)
    M.run_async({
      filter = trim(command.args),
      live = command.bang,
    })
  end, {
    nargs = "?",
    bang = true,
    desc = "Audit Neovim core capabilities (! enables read-only live probes)",
    complete = function()
      return { "startup", "editor", "syntax", "search", "compiler", "ue", "live" }
    end,
  })
end

return M
