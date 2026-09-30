-- Read-only isolated benchmark. Does not load this repository's init or write a Git index.
-- Set GIT_REVIEW_BENCH_ENGINE=diffview|codediff, GIT_REVIEW_BENCH_REPO and GIT_REVIEW_BENCH_OUTPUT.
-- nvim --clean --headless -c "lua dofile('scripts/benchmark_git_review.lua')"
-- Use normal headless startup (-c), not Lua-script mode (-l): Diffview requires normal startup state.
-- Optional: GIT_REVIEW_BENCH_SAMPLES (default 20), GIT_REVIEW_BENCH_IDLE_SECONDS (default 60),
-- GIT_REVIEW_BENCH_PLUGIN_ROOT (default stdpath('data')/lazy), GIT_REVIEW_BENCH_FILES (JSON array).
-- GIT_REVIEW_BENCH_AUTO_REFRESH=false disables CodeDiff's periodic fallback, as a distinct candidate.
-- GIT_REVIEW_BENCH_PROFILE=1 adds intrusive function/JIT profiling; "timing" measures coarse functions only.
-- Do not use profiled timings for acceptance.
-- GIT_REVIEW_BENCH_PATCHED=1 loads the repository's actual plugin opts/config (including workarounds).
-- GIT_REVIEW_BENCH_WARM_SAMPLES overrides only reopen iterations for targeted follow-up measurements.
-- GIT_REVIEW_BENCH_CALLBACK_TIMING=1 diagnoses slow scheduled/worker-completion callbacks; use only for follow-up.
-- Output is local evidence: paths/config fingerprints may be private; do not commit raw reports.
local uv = vim.uv
local config_root = vim.fn.getcwd()
local engine = vim.env.GIT_REVIEW_BENCH_ENGINE
local root = vim.env.GIT_REVIEW_BENCH_REPO
local output = vim.env.GIT_REVIEW_BENCH_OUTPUT
assert(engine == "diffview" or engine == "codediff", "engine must be diffview or codediff")
assert(root and output, "repository and output JSON path required")
assert(not vim.tbl_contains(vim.v.argv, "-l"), "use --clean --headless -c lua dofile(...), not -l")
assert(#vim.api.nvim_list_uis() == 0, "run in isolated --clean --headless Neovim")
vim.env.GIT_OPTIONAL_LOCKS = "0"
vim.env.VSCODE_DIFF_NO_AUTO_INSTALL = "1"
vim.env.CODEDIFF_WATCHER_NO_AUTO_INSTALL = "1"
vim.o.swapfile, vim.o.undofile, vim.o.writebackup = false, false, false
vim.o.shadafile = "NONE"
vim.o.lines, vim.o.columns = 60, 180
local plugins = vim.env.GIT_REVIEW_BENCH_PLUGIN_ROOT or (vim.fn.stdpath("data") .. "/lazy")
local samples = tonumber(vim.env.GIT_REVIEW_BENCH_SAMPLES) or 20
local warm_samples = tonumber(vim.env.GIT_REVIEW_BENCH_WARM_SAMPLES) or samples
local idle_seconds = tonumber(vim.env.GIT_REVIEW_BENCH_IDLE_SECONDS) or 60
local auto_refresh = vim.env.GIT_REVIEW_BENCH_AUTO_REFRESH ~= "false"
local report = {
  engine = engine, repository = root, samples = samples, idle_seconds = idle_seconds, pid = vim.fn.getpid(),
  started_at = os.date("!%Y-%m-%dT%H:%M:%SZ"), platform = uv.os_uname(),
  nvim = vim.version(), phases = {}, commands = {}, notifications = {}, stalls = {},
  fingerprint_encoding = "SHA256(base64(raw bytes)); permits binary index/NUL-delimited Git output",
  codediff_auto_refresh = auto_refresh,
  limitations = {
    "Headless: no Neovide/GPU/font rendering measurement; elapsed includes Lua, buffer and headless redraw work.",
    "Cold means first plugin open in this process, NOT cold OS/Git filesystem caches; no caches are cleared.",
    "CPU/RSS measure Neovim only, not Git subprocesses; uv spawn counts do not include Git grandchildren.",
    "Polling uses 5ms readiness checks plus a 30ms stable completion window, reported separately.",
    "File switching selects the same two paths through panel callbacks; it does not time adjacent-file tree traversal.",
    "Independent concurrent file writers may change the input; compare fingerprints before accepting ratios.",
  },
}
local function save()
  vim.fn.writefile({ vim.json.encode(report) }, output)
end
local function now() return uv.hrtime() / 1e6 end
local function process_cpu()
  local r = uv.getrusage()
  return r.utime.sec + r.utime.usec / 1e6 + r.stime.sec + r.stime.usec / 1e6
end
local function digest(bytes) return vim.fn.sha256(vim.base64.encode(bytes)) end
local function summary(values)
  local copy = vim.deepcopy(values)
  table.sort(copy)
  local function percentile(p) return copy[math.max(1, math.ceil(#copy * p))] or 0 end
  return { count = #copy, p50_ms = percentile(0.5), p95_ms = percentile(0.95), max_ms = copy[#copy] or 0 }
end
local phase = "inventory"
local processes, active, last_exit = 0, 0, now()
local original_spawn = uv.spawn
uv.spawn = function(command, opts, callback)
  processes = processes + 1
  active = active + 1
  local entry = { command = command, args = opts.args, phase = phase, started_ms = now() }
  report.commands[#report.commands + 1] = entry
  local handle, pid = original_spawn(command, opts, function(code, signal)
    active = active - 1
    last_exit = now()
    entry.elapsed_ms, entry.code, entry.signal = now() - entry.started_ms, code, signal
    if callback then callback(code, signal) end
  end)
  entry.spawn_call_ms = now() - entry.started_ms
  if not handle then active = active - 1 end
  return handle, pid
end
vim.notify = function(message, level)
  report.notifications[#report.notifications + 1] = { message = tostring(message), level = level, phase = phase }
end
local function git(args)
  local argv = { "git", "-C", root }
  vim.list_extend(argv, args)
  local result = vim.system(argv, { text = false }):wait(60000)
  assert(result.code == 0, result.stderr)
  return result.stdout
end
local function fingerprint(path)
  local file = io.open(path, "rb")
  if not file then return "missing" end
  local bytes = file:read("*a")
  file:close()
  return digest(bytes)
end
local function inventory()
  local status = git({ "status", "--porcelain=v1", "-z", "--untracked-files=all" })
  local manifest = assert(io.open(output .. "." .. phase .. ".status", "wb"))
  manifest:write(status)
  manifest:close()
  local tracked = git({ "ls-files", "-z" })
  local records = vim.split(status, "\0", { plain = true, trimempty = true })
  local dirty, untracked, skip = 0, 0, false
  for _, record in ipairs(records) do
    if skip then
      skip = false
    elseif record:sub(1, 2) == "??" then
      untracked = untracked + 1
    else
      dirty = dirty + 1
      skip = record:sub(1, 2):find("[RC]") ~= nil
    end
  end
  return { status_sha256 = digest(status), tracked_sha256 = digest(tracked),
    tracked = select(2, tracked:gsub("%z", "")), dirty = dirty, untracked = untracked }
end
local heartbeat, beats, beat_last, beat_cpu
local function start_heartbeat()
  beats, beat_last, beat_cpu = {}, now(), process_cpu()
  heartbeat = uv.new_timer()
  heartbeat:start(20, 20, vim.schedule_wrap(function()
    local tick = now()
    local cpu = process_cpu()
    local extra = math.max(0, tick - beat_last - 20)
    beats[#beats + 1] = extra
    if extra > 50 then
      local transport_module = package.loaded["workarounds.codediff.threaded_git"]
      local worker = transport_module and transport_module.status() or {}
      report.stalls[#report.stalls + 1] = { phase = phase, start_ms = beat_last, end_ms = tick, extra_ms = extra,
        process_cpu_ms = (cpu - beat_cpu) * 1000, process_cpu_ratio = (cpu - beat_cpu) * 1000 / (tick - beat_last),
        worker_active = worker.active or 0, worker_queued = worker.queued or 0 }
    end
    beat_last, beat_cpu = tick, cpu
  end))
end
local function usage()
  return { cpu_seconds = process_cpu(),
    rss_bytes = uv.resident_set_memory() }
end
if vim.env.GIT_REVIEW_BENCH_CALLBACK_TIMING == "1" then
  report.slow_callbacks = {}
  report.callback_timing_intrusive = true
  local function timed(callback, kind)
    return function(...)
      local started, cpu = now(), process_cpu()
      local result = { callback(...) }
      local elapsed, consumed = now() - started, (process_cpu() - cpu) * 1000
      if elapsed > 50 then
        local info = debug.getinfo(callback, "S")
        report.slow_callbacks[#report.slow_callbacks + 1] = { kind = kind, phase = phase,
          source = info.short_src, line = info.linedefined, elapsed_ms = elapsed, process_cpu_ms = consumed,
          started_ms = started }
      end
      return unpack(result)
    end
  end
  local schedule, new_work = vim.schedule, uv.new_work
  vim.schedule = function(callback) return schedule(timed(callback, "schedule")) end
  uv.new_work = function(work, after) return new_work(work, timed(after, "worker_completion")) end
end
local function handles()
  local counts = {}
  uv.walk(function(h)
    if not h:is_closing() and h:is_active() then
      local kind = uv.handle_get_type(h)
      counts[kind] = (counts[kind] or 0) + 1
    end
  end)
  return counts
end
local function transport()
  local mod = package.loaded["workarounds.codediff.threaded_git"]
  return mod and mod.status() or { active = 0, queued = 0, spawned = 0 }
end
local function profile_start()
  local mode = vim.env.GIT_REVIEW_BENCH_PROFILE
  if (mode ~= "1" and mode ~= "timing") or engine ~= "codediff" then return end
  report.profile = { inclusive_functions = {}, jit_samples = {}, intrusive = true }
  local targets = {
    ["codediff.ui.explorer.render"] = { "create" },
    ["codediff.ui.explorer.tree"] = { "create_tree_data", "rebuild", "get_all_files" },
    ["codediff.ui.explorer.nodes"] = { "create_file_nodes", "create_tree_file_nodes", "prepare_node", "get_file_icon" },
    ["codediff.ui.lib.tree"] = { "new", "render", "set_nodes" },
    ["codediff.ui.view.render"] = { "render_diff", "update" },
    ["codediff.ui.explorer.filter"] = { "apply" },
    ["codediff.core.git"] = { "get_status_with_line_stats" },
    ["codediff.ui.view"] = { "create" },
    ["codediff.ui.view.side_by_side"] = { "create" },
    ["codediff.ui.view.panel"] = { "setup_explorer", "setup_history" },
    ["codediff.ui.refresh.panel"] = { "new" },
    ["codediff.ui.lifecycle"] = { "create_session" },
    ["codediff.ui.layout"] = { "arrange" },
    ["codediff.ui.refresh"] = { "attach" },
  }
  if mode == "timing" then targets["codediff.ui.explorer.nodes"] = { "create_file_nodes", "create_tree_file_nodes" } end
  for module_name, names in pairs(targets) do
    local mod = require(module_name)
    for _, name in ipairs(names) do
      local original = mod[name]
      assert(type(original) == "function", module_name .. "." .. name)
      local row = { calls = 0, total_ms = 0, max_ms = 0, net_lua_heap_kib = 0, max_heap_growth_kib = 0 }
      report.profile.inclusive_functions[module_name .. "." .. name] = row
      mod[name] = function(...)
        if name == "create_tree_data" then
          local _, repository, base, directory, groups = ...
          report.profile.tree_arguments = { root = repository, base = base, directory = directory, groups = groups }
        elseif name == "get_status_with_line_stats" then
          report.profile.status_root = select(1, ...)
        end
        local started = now()
        local heap = collectgarbage("count")
        local results = { original(...) }
        local elapsed = now() - started
        local growth = collectgarbage("count") - heap
        row.net_lua_heap_kib, row.max_heap_growth_kib = row.net_lua_heap_kib + growth, math.max(row.max_heap_growth_kib, growth)
        row.calls, row.total_ms, row.max_ms = row.calls + 1, row.total_ms + elapsed, math.max(row.max_ms, elapsed)
        return unpack(results)
      end
    end
  end
  local deepcopy = vim.deepcopy
  local copies = { calls = 0, total_ms = 0, max_ms = 0, net_lua_heap_kib = 0, max_heap_growth_kib = 0 }
  report.profile.inclusive_functions["vim.deepcopy"] = copies
  vim.deepcopy = function(...)
    local started, heap = now(), collectgarbage("count")
    local result = deepcopy(...)
    local elapsed, growth = now() - started, collectgarbage("count") - heap
    copies.calls, copies.total_ms, copies.max_ms = copies.calls + 1, copies.total_ms + elapsed, math.max(copies.max_ms, elapsed)
    copies.net_lua_heap_kib, copies.max_heap_growth_kib = copies.net_lua_heap_kib + growth, math.max(copies.max_heap_growth_kib, growth)
    return result
  end
  if mode == "1" then
    report.profile.jit_enabled = true
    local profiler = require("jit.profile")
    profiler.start("fi1", function(thread, count, state)
      local stack = state .. ": " .. profiler.dumpstack(thread, "f", 10)
      report.profile.jit_samples[stack] = (report.profile.jit_samples[stack] or 0) + count
    end)
  end
end
local function settle(predicate, timeout)
  local stable
  assert(vim.wait(timeout or 60000, function()
    local worker = transport()
    if active == 0 and worker.active == 0 and worker.queued == 0 and predicate() then
      stable = stable or now()
      return now() - math.max(stable, last_exit) >= 30
    end
    stable = nil
    return false
  end, 5), "timed out waiting for " .. phase)
end
local function measure(name, fn)
  phase = name
  io.stderr:write("benchmark phase: " .. name .. "\n")
  io.stderr:flush()
  local cpu, started, count, beat_start = usage(), now(), processes, #beats
  local worker_before = transport()
  local value = fn()
  local after = usage()
  local latencies = {}
  for i = beat_start + 1, #beats do latencies[#latencies + 1] = beats[i] end
  local worker_after = transport()
  local tree_module = package.loaded["workarounds.codediff.large_tree"]
  local worker_module = package.loaded["workarounds.codediff.threaded_git"]
  if worker_module and worker_module.jobs then report.worker_jobs_recent = worker_module.jobs() end
  local worker_spawned = (worker_after.spawned or 0) - (worker_before.spawned or 0)
  local row = { elapsed_ms = now() - started, subprocesses = processes - count + worker_spawned,
    main_thread_subprocesses = processes - count, worker_subprocesses = worker_spawned, transport = worker_after,
    tree_state = tree_module and tree_module.status() or nil,
    worker_spawn_call_ms = (worker_after.spawn_ms or 0) - (worker_before.spawn_ms or 0),
    cpu_seconds = after.cpu_seconds - cpu.cpu_seconds, rss_bytes = after.rss_bytes,
    heartbeat_extra = summary(latencies), result = value }
  report.phases[name] = row
  save()
  return row
end
local generation = 0
local selected_files
local function session()
  if engine == "diffview" then return require("diffview.lib").get_current_view() end
  return require("codediff.ui.lifecycle").get_session(vim.api.nvim_get_current_tabpage())
end
local function ready()
  local s = session()
  if not s then return false end
  if engine == "diffview" then return s.initialized and s.cur_entry and s.cur_entry.opened end
  return s.stored_diff_result ~= nil and s.panel and s.panel.view
end
local function open()
  generation = 0
  vim.cmd.edit(vim.fn.fnameescape(root .. "/" .. selected_files[1]))
  if engine == "diffview" then
    vim.cmd("DiffviewOpen --selected-file=" .. vim.fn.fnameescape(root .. "/" .. selected_files[1]))
  elseif report.actual_repository_config then
    report.open_entrypoint = "utils.git_review.open(root, path)"
    require("utils.git_review").open({ root = root, path = root .. "/" .. selected_files[1] })
  else
    vim.cmd("CodeDiff")
  end
  settle(ready)
end
local function close()
  if engine == "diffview" then vim.cmd("DiffviewClose")
  else require("codediff.ui.lifecycle").close(vim.api.nvim_get_current_tabpage(), true) end
  settle(function() return session() == nil end)
end
local function select_file(path)
  local s, old = session(), generation
  if engine == "diffview" then
    local selected
    for _, entry in s.files:iter() do
      if entry.path == path and entry.kind == "working" then selected = entry; break end
    end
    assert(selected, "Diffview missing working file: " .. path)
    s:set_file(selected, true, true)
  else
    local explorer = s.panel.view
    if explorer.data.current_file_path == path and explorer.data.current_file_group == "unstaged" and ready() then return end
    local selected
    for _, node in ipairs(require("codediff.ui.explorer").get_all_files(explorer.tree)) do
      if node.data.path == path and node.data.group == "unstaged" then selected = node.data; break end
    end
    assert(selected, "CodeDiff missing unstaged file: " .. path)
    explorer.on_file_select(selected)
  end
  settle(function() return ready() and generation > old end)
end
local coverage_sequence = 0
local function coverage()
  local paths = {}
  local s = session()
  if engine == "diffview" then
    for _, entry in s.files:iter() do paths[entry.path] = true end
  else
    for _, node in ipairs(require("codediff.ui.explorer").get_all_files(s.panel.view.tree)) do paths[node.data.path] = true end
  end
  local sorted = vim.tbl_keys(paths)
  table.sort(sorted)
  local bytes = table.concat(sorted, "\n")
  coverage_sequence = coverage_sequence + 1
  local manifest_path = output .. ".open-" .. coverage_sequence .. ".paths"
  local manifest = assert(io.open(manifest_path, "wb"))
  manifest:write(bytes)
  manifest:close()
  return { files = #sorted, paths_sha256 = digest(bytes), manifest = manifest_path }
end
local ok, failure = xpcall(function()
  root = vim.trim(git({ "rev-parse", "--show-toplevel" }))
  vim.api.nvim_set_current_dir(root)
  local index_path = vim.trim(git({ "rev-parse", "--path-format=absolute", "--git-path", "index" }))
  report.index_before_sha256 = fingerprint(index_path)
  report.input_before = inventory()
  report.git_version = vim.trim(git({ "--version" }))
  report.git_config_sha256 = digest(git({ "config", "--list", "--show-origin" }))
  local files = vim.env.GIT_REVIEW_BENCH_FILES and vim.json.decode(vim.env.GIT_REVIEW_BENCH_FILES)
    or vim.split(git({ "diff", "--name-only", "-z", "--diff-filter=M" }), "\0", { plain = true, trimempty = true })
  assert(#files >= 2, "need at least two modified tracked files (or explicit JSON GIT_REVIEW_BENCH_FILES)")
  table.sort(files)
  files = { files[1], files[2] }
  selected_files = files
  report.selected_files = {}
  for _, path in ipairs(files) do
    local lines = vim.fn.readfile(root .. "/" .. path)
    report.selected_files[#report.selected_files + 1] = { path = path, bytes = uv.fs_stat(root .. "/" .. path).size,
      lines = #lines, sha256 = fingerprint(root .. "/" .. path) }
  end
  for _, name in ipairs({ "plenary.nvim", "nui.nvim", "mini.icons", engine .. ".nvim" }) do
    vim.opt.rtp:append(plugins .. "/" .. name)
  end
  report.plugin_commit = vim.trim(vim.system({ "git", "-C", plugins .. "/" .. engine .. ".nvim", "rev-parse", "HEAD" }):wait().stdout)
  start_heartbeat()
  report.handles_before = handles()
  measure("setup", function()
    -- Match LazyVim's installed icon provider. Missing optional devicons otherwise causes
    -- CodeDiff to search runtime paths once per file, unlike the delivered configuration.
    require("mini.icons").setup()
    require("mini.icons").mock_nvim_web_devicons()
    report.icon_provider = "installed mini.icons + mock_nvim_web_devicons (LazyVim integration)"
    local actual
    if vim.env.GIT_REVIEW_BENCH_PATCHED == "1" then
      vim.opt.rtp:append(config_root)
      actual = dofile(config_root .. "/lua/plugins/" .. engine .. ".lua")[1]
      report.actual_repository_config = true
      if actual.init then actual.init(actual) end
    end
    vim.cmd("runtime plugin/" .. engine .. ".lua")
    if engine == "diffview" then
      local opts = actual and actual.opts() or { use_icons = true, enhanced_diff_hl = true,
        show_untracked = true, view = { default = { layout = "diff2_horizontal" } },
        file_panel = { listing_style = "tree", win_config = { width = 38 } },
        hooks = { diff_buf_read = function() vim.opt_local.foldenable = false end } }
      require("diffview").setup(opts)
      report.explorer_options = opts.file_panel
      -- file_open_post is a view emitter event, not a configurable global hook.
      local class = require("diffview.scene.views.diff.diff_view").DiffView
      local original = class.file_open_post
      class.file_open_post = function(self, ...)
        generation = generation + 1
        return original(self, ...)
      end
    else
      local opts = actual and actual.opts or { diff = { layout = "side-by-side", compact = false },
        explorer = { untracked = "all", view_mode = "tree", width = 38, auto_refresh = auto_refresh, initial_focus = "modified" } }
      if actual then actual.config(actual, opts) else require("codediff").setup(opts) end
      report.explorer_options = opts.explorer
      report.codediff_auto_refresh = opts.explorer.auto_refresh
      if actual then report.large_tree = require("workarounds.codediff.large_tree").status() end
      local render = require("codediff.ui.view.render")
      local original = render.render_diff
      render.render_diff = function(...)
        local result = original(...)
        generation = generation + 1
        return result
      end
    end
    if actual then
      report.integration_hashes = { ["lua/plugins/" .. engine .. ".lua"] = fingerprint(config_root .. "/lua/plugins/" .. engine .. ".lua") }
      for name in pairs(package.loaded) do
        if name:match("^workarounds%.codediff%.") or name == "utils.git_review"
            or name == "utils.platform" or name:match("^utils%.platform%.") then
          local path = "lua/" .. name:gsub("%.", "/") .. ".lua"
          report.integration_hashes[path] = fingerprint(config_root .. "/" .. path)
        end
      end
    end
  end)
  profile_start()
  measure("cold_open", open)
  report.coverage = coverage()
  report.open_coverage = { report.coverage }
  measure("initial_select", function() select_file(files[1]) end)
  measure("warm_open", function()
    local timings = {}
    for _ = 1, warm_samples do
      close()
      local started = now()
      open()
      timings[#timings + 1] = now() - started
      -- Coverage audit is outside the action timer; never hide untracked entries.
      report.open_coverage[#report.open_coverage + 1] = coverage()
    end
    return { timings_ms = timings, summary = summary(timings) }
  end)
  select_file(files[1])
  measure("switch_file", function()
    local timings = {}
    for i = 1, samples do
      local started = now()
      select_file(files[i % 2 + 1])
      timings[#timings + 1] = now() - started
    end
    return { timings_ms = timings, summary = summary(timings) }
  end)
  measure("jump_hunk", function()
    local timings, action_times, redraw_times = {}, {}, {}
    local s = session()
    local win = engine == "diffview" and s.cur_layout:get_main_win().id or s.modified_win
    vim.api.nvim_set_current_win(win)
    for i = 1, samples do
      -- Start outside the hunk so a measured jump really moves, and CodeDiff's
      -- configured cross-file cycling is not mistaken for a synchronous hunk jump.
      local first = i % 2 == 1
      vim.api.nvim_win_set_cursor(win, { first and 1 or vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(win)), 0 })
      local before = vim.api.nvim_win_get_cursor(win)[1]
      local started = now()
      if engine == "diffview" then vim.cmd(first and "normal! ]c" or "normal! [c")
      else require("codediff")[first and "next_hunk" or "prev_hunk"]() end
      local action_done = now()
      vim.cmd("redraw")
      local finished = now()
      timings[#timings + 1] = finished - started
      action_times[#action_times + 1] = action_done - started
      redraw_times[#redraw_times + 1] = finished - action_done
      assert(vim.api.nvim_win_get_cursor(win)[1] ~= before, "hunk navigation did not move the cursor")
      vim.wait(25, function() return false end, 5)
    end
    return { timings_ms = timings, summary = summary(timings), action = summary(action_times), redraw = summary(redraw_times) }
  end)
  measure("idle", function() vim.wait(idle_seconds * 1000, function() return false end, 20) end)
  report.handles_open = handles()
  measure("close", close)
  measure("after_close", function() vim.wait(5000, function() return false end, 20) end)
  report.handles_closed = handles()
  heartbeat:stop()
  heartbeat:close()
  if report.profile and report.profile.jit_enabled then require("jit.profile").stop() end
  phase = "final_inventory"
  report.input_after = inventory()
  report.selected_input_unchanged = true
  for _, file in ipairs(report.selected_files) do
    file.after_sha256 = fingerprint(root .. "/" .. file.path)
    if file.after_sha256 ~= file.sha256 then report.selected_input_unchanged = false end
  end
  report.index_after_sha256 = fingerprint(index_path)
  report.index_unchanged = report.index_before_sha256 == report.index_after_sha256
  report.input_unchanged = vim.deep_equal(report.input_before, report.input_after)
  report.status = "MEASURED"
end, debug.traceback)
if not ok then report.status, report.error = "FAILED", failure end
save()
print(report.status .. " " .. output)
if not ok then print(failure) end
vim.cmd(ok and "qa!" or "cquit 1")
