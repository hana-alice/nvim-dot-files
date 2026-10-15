-- Files picker inventory, independent of csearch/GTAGS/CDB input lists.
-- Only complete successful fd output is cached, in this Neovim process.
local M = {}

local uv = vim.uv or vim.loop
local fs = require("ue.core.fs")
local cache, clock, revision = {}, 0, 0

M.MAX_FILES = 200000
M.MAX_PATH_BYTES = 64 * 1024 * 1024
M.MAX_SCOPES = 8

local function canonical(path, cwd)
  path = fs.norm(path)
  if not fs.is_absolute_path(path) then
    path = fs.join(cwd or uv.cwd() or ".", path)
  end
  return fs.norm(uv.fs_realpath(path) or vim.fn.fnamemodify(path, ":p"))
end

local function strings(values)
  if type(values) == "string" then
    values = { values }
  end
  local ret = {}
  for _, value in ipairs(values or {}) do
    ret[#ret + 1] = tostring(value)
  end
  return ret
end

local function sorted(values)
  local ret = strings(values)
  table.sort(ret)
  return ret
end

local function plan_for(opts, search)
  opts = opts or {}
  local cmd = opts.cmd
  if cmd and cmd ~= "fd" and cmd ~= "fdfind" then
    return nil, "File inventory requires the installed fd/fdfind finder"
  end
  cmd = require("ue.core.proc").first_executable(cmd and { cmd } or { "fd", "fdfind" })
  if not cmd then
    return nil, "File inventory: fd/fdfind is unavailable"
  end
  cmd = vim.fn.exepath(cmd)

  local cwd = canonical(opts.cwd or uv.cwd() or ".")
  local dirs, seen = {}, {}
  for _, dir in ipairs(opts.dirs or { cwd }) do
    dir = canonical(dir, cwd)
    if not seen[dir] then
      dirs[#dirs + 1], seen[dir] = dir, true
    end
  end
  if opts.rtp then
    for _, dir in ipairs(require("snacks.picker.util").rtp()) do
      dir = canonical(dir, cwd)
      if not seen[dir] then
        dirs[#dirs + 1], seen[dir] = dir, true
      end
    end
  end
  if #dirs == 0 then
    dirs = { cwd }
  end
  table.sort(dirs)
  -- Overlapping roots have identical filters; scanning their parent suffices.
  local roots = {}
  for _, dir in ipairs(dirs) do
    local covered = false
    for _, root in ipairs(roots) do
      covered = covered or fs.path_has_prefix(dir, root)
    end
    if not covered then
      roots[#roots + 1] = dir
    end
  end

  local args = { "--type", "f", "--type", "l", "--color", "never", "--absolute-path", "--print0", "-E", ".git" }
  for _, exclude in ipairs(sorted(opts.exclude)) do
    vim.list_extend(args, { "-E", exclude })
  end
  for _, ft in ipairs(sorted(opts.ft)) do
    vim.list_extend(args, { "-e", ft })
  end
  if opts.hidden then
    args[#args + 1] = "--hidden"
  end
  if opts.ignored then
    args[#args + 1] = "--no-ignore"
  end
  if opts.follow then
    args[#args + 1] = "--follow"
  end
  vim.list_extend(args, strings(opts.args))
  local pattern, pargs = require("snacks.picker.util").parse(search or (opts.live and opts.search) or "")
  vim.list_extend(args, pargs)
  -- One foreground directory walk must leave host CPU room for the editor.
  vim.list_extend(args, { "--threads", "1", pattern ~= "" and pattern or "." })
  vim.list_extend(args, roots)

  local command = { cmd }
  vim.list_extend(command, args)
  local env = {}
  for name, value in pairs(opts.env or {}) do
    env[#env + 1] = name .. "=" .. tostring(value)
  end
  table.sort(env)
  local max_files = math.max(0, math.min(M.MAX_FILES, tonumber(opts.inventory_max_files) or M.MAX_FILES))
  local max_bytes = math.max(0, math.min(M.MAX_PATH_BYTES, tonumber(opts.inventory_max_bytes) or M.MAX_PATH_BYTES))
  return {
    key = vim.json.encode({ command, cwd, env, max_files, max_bytes }),
    command = command,
    cwd = cwd,
    max_files = max_files,
    max_bytes = max_bytes,
  }
end

local function totals()
  local files, bytes, scopes = 0, 0, 0
  for _, entry in pairs(cache) do
    files, bytes, scopes = files + #entry.paths, bytes + entry.bytes, scopes + 1
  end
  return files, bytes, scopes
end

local function publish(plan, paths, bytes)
  cache[plan.key] = nil
  while true do
    local files, used, scopes = totals()
    if files + #paths <= M.MAX_FILES and used + bytes <= M.MAX_PATH_BYTES and scopes < M.MAX_SCOPES then
      break
    end
    local oldest_key, oldest
    for key, entry in pairs(cache) do
      if not oldest or entry.used < oldest then
        oldest_key, oldest = key, entry.used
      end
    end
    if not oldest_key then
      return false
    end
    cache[oldest_key] = nil
  end
  clock = clock + 1
  cache[plan.key] = { paths = paths, bytes = bytes, captured_at = os.time(), used = clock }
  return true
end

--- Invalidates one exact finder scope, or all scopes when opts is omitted.
--- This never modifies prepared search/semantic index assets.
function M.invalidate(opts, search)
  revision = revision + 1
  if opts then
    local plan = plan_for(opts, search)
    if plan then
      cache[plan.key] = nil
    end
  else
    cache = {}
  end
end

--- Returns snapshot metadata; cached is not a filesystem freshness claim.
function M.cache_info(opts, search)
  local plan = plan_for(opts, search)
  local entry = plan and cache[plan.key]
  if entry then
    return { count = #entry.paths, path_bytes = entry.bytes, captured_at = entry.captured_at, complete = true }
  end
end

--- Complete an fd prepare list using Git's actual ignore semantics. Only
--- tracked paths with a mixed/upper-case extension are candidates; ordinary
--- ignored tracked files remain excluded. The caller still applies its file
--- types and scan-root/exclusion policy before publishing the returned list.
function M.supplement_tracked(root, search_paths, lines, cb, opts)
  opts = opts or {}
  local original, seen, candidates = vim.list_slice(lines or {}), {}, {}
  local path_key = require("utils.platform").driver().path_key
  for _, line in ipairs(original) do seen[path_key(fs.norm(line))] = true end
  local stopped, handle = false, nil
  local function done(value, err)
    if not stopped then stopped = true; cb(value, err) end
  end
  local function run(args, input, callback)
    local command = { "git", "--no-optional-locks", "-C", root }
    vim.list_extend(command, args)
    -- Short read-only continuation of the explicitly admitted prepare scan.
    local ok, child = pcall(vim.system, command, { text = false, stdin = input, timeout = 15000 }, function(result)
      vim.schedule(function()
        if stopped then return end
        if #(result.stdout or "") > M.MAX_PATH_BYTES then done(nil, "Git inventory exceeds path budget"); return end
        callback(result)
      end)
    end)
    if not ok then done(nil, "Git inventory spawn failed: " .. tostring(child)); return end
    handle = child
    pcall(require("utils.task_registry").register,
      { name = "UE: tracked file supplement", group = "ue", kind = "system", handle = handle })
  end
  local function records(output, visit, finish)
    local from = 1
    local function step()
      for _ = 1, 2048 do
        if from > #output then finish(); return end
        local ending = output:find("\0", from, true)
        if not ending then done(nil, "invalid Git inventory framing"); return end
        local row = output:sub(from, ending - 1); from = ending + 1
        if visit(row) == false then return end
      end
      vim.defer_fn(function() if not stopped then step() end end, 1)
    end
    step()
  end
  local args = { "ls-files", "--cached", "-z", "--" }
  vim.list_extend(args, search_paths or { "." })
  run(args, nil, function(result)
    if result.code ~= 0 then
      if result.code == 128 and (result.stderr or ""):find("not a git repository", 1, true) then done(original)
      else done(nil, "Git tracked inventory unavailable: " .. tostring(result.stderr)) end
      return
    end
    records(result.stdout or "", function(row)
      row = fs.norm(row)
      if fs.is_absolute_path(row) or row:find("[\r\n]") or row:match("^%.%./") or row:find("/../", 1, true) then
        done(nil, "invalid Git inventory path"); return false
      end
      local ext = row:match("%.([^./]+)$")
      if not ext or ext == ext:lower() or seen[path_key(row)] then return end
      local blocked = false
      for part in row:gmatch("[^/]+") do
        for _, exclude in ipairs(opts.excludes or {}) do
          if part:lower() == exclude:lower() then blocked = true end
        end
      end
      if not blocked then
        candidates[#candidates + 1] = row
      end
    end, function()
      if #candidates == 0 then done(original); return end
      run({ "check-ignore", "--no-index", "-z", "--stdin" }, table.concat(candidates, "\0") .. "\0", function(ignored)
        if ignored.code ~= 0 and ignored.code ~= 1 then done(nil, "Git ignore inventory unavailable"); return end
        local excluded = {}
        records(ignored.stdout or "", function(row) excluded[path_key(fs.norm(row))] = true end, function()
          local n = 0
          local function next_path()
            repeat n = n + 1 until not candidates[n] or not excluded[path_key(candidates[n])]
            local path = candidates[n]
            if not path then done(original); return end
            uv.fs_stat(fs.join(root, path), function(err, stat)
              vim.schedule(function()
                if stopped then return end
                if err and not tostring(err):find("ENOENT", 1, true) and not tostring(err):find("ENOTDIR", 1, true) then
                  done(nil, "Git tracked path unavailable: " .. tostring(err)); return
                end
                if stat and stat.type == "file" and not seen[path_key(path)] then
                  original[#original + 1], seen[path_key(path)] = path, true
                end
                next_path()
              end)
            end)
          end
          next_path()
        end)
      end)
    end)
  end)
  return function()
    stopped = true
    if handle and not handle:is_closing() then handle:kill(15) end
  end
end

-- Compatibility for the existing explicitly synchronous prepare path. Normal
-- UI prepare callers use supplement_tracked and retain asynchronous scanning.
function M.supplement_tracked_sync(root, search_paths, lines, opts)
  local completed, result, failure = false, nil, nil
  local stop = M.supplement_tracked(root, search_paths, lines, function(value, err)
    completed, result, failure = true, value, err
  end, opts)
  if not vim.wait(35000, function() return completed end, 5) then
    stop(); return nil, "Git tracked supplement timed out"
  end
  return result, failure
end

local function state(ctx, base, value, detail)
  ctx.meta = ctx.meta or {}
  local meta = ctx.meta.file_inventory or {}
  ctx.meta.file_inventory = vim.tbl_extend("force", meta, { state = value }, detail or {})
  local labels = {
    scanning = "Scanning files",
    cached = "Cached snapshot · F5 refresh",
    complete = "Complete · F5 refresh",
    uncached = detail and detail.over_budget and "Complete · over cache budget" or "Complete · not cached",
    cancelled = "Cancelled · not cached",
    error = "Scan failed · not cached",
    prepared = "Prepared list · " .. tostring(detail and detail.count or 0) .. " files",
  }
  vim.schedule(function()
    local picker = ctx.picker
    if picker and not picker.closed and picker._file_inventory_owner == ctx then
      picker.title = base .. " [" .. labels[value] .. "]"
      picker:update_titles()
    end
  end)
end

---@type snacks.picker.finder
function M.find(opts, ctx)
  if ctx.picker then
    ctx.picker._file_inventory_owner = ctx
  end
  local plan, err = plan_for(opts, ctx.filter and ctx.filter.search)
  local base = opts.title or "Files"
  if not plan then
    state(ctx, base, "error", { complete = false, error = err })
    vim.schedule(function()
      vim.notify(err, vim.log.levels.ERROR)
    end)
    return {}
  end
  if opts.refresh then
    M.invalidate(opts, ctx.filter and ctx.filter.search)
  end
  local entry = cache[plan.key]
  local captured_revision = revision
  local Async = require("snacks.picker.util.async")

  return function(cb)
    local async = assert(Async.running(), "File inventory requires Snacks async finder context")
    local yield = Async.yielder(2)
    if entry then
      clock, entry.used = clock + 1, clock + 1
      state(ctx, base, "cached", {
        complete = true,
        count = #entry.paths,
        path_bytes = entry.bytes,
        captured_at = entry.captured_at,
      })
      for _, path in ipairs(entry.paths) do
        cb({ text = path, file = path })
        yield()
      end
      return
    end

    state(ctx, base, "scanning", { complete = false, count = 0 })
    local queue = require("snacks.picker.util.queue").new()
    local result, read_error, aborted
    local admission = require("utils.host_admission")
    local token = admission.foreground_begin("file inventory")
    local ok, handle = pcall(vim.system, plan.command, {
      cwd = plan.cwd,
      env = opts.env,
      timeout = opts.inventory_timeout_ms or 120000,
      stdout = function(error, data)
        vim.schedule(function()
          read_error = read_error or error
          if data and not aborted then
            queue:push(data)
          end
          async:resume()
        end)
      end,
    }, function(outcome)
      vim.schedule(function()
        result = outcome
        admission.foreground_done(token)
        async:resume()
      end)
    end)
    if not ok then
      admission.foreground_done(token)
      state(ctx, base, "error", { complete = false, error = tostring(handle) })
      return
    end
    pcall(
      require("utils.task_registry").register,
      { name = "Files: fd inventory", group = "search", kind = "system", handle = handle }
    )
    async:on("abort", function()
      aborted = true
      queue:clear()
      state(ctx, base, "cancelled", { complete = false })
      if not handle:is_closing() then
        handle:kill(15)
      end
    end)

    local paths, bytes, count, tail = {}, 0, 0, ""
    local over_budget = false
    while not result or not queue:empty() do
      if queue:empty() then
        async:suspend()
      else
        local data = tail .. queue:pop()
        local from = 1
        while from <= #data do
          local ending = data:find("\0", from, true)
          if not ending then
            break
          end
          local path = fs.norm(data:sub(from, ending - 1))
          from = ending + 1
          if path ~= "" then
            count, bytes = count + 1, bytes + #path
            if not over_budget then
              if count > plan.max_files or bytes > plan.max_bytes then
                over_budget, paths = true, {}
              else
                paths[#paths + 1] = path
              end
            end
            cb({ text = path, file = path })
            yield()
          end
        end
        tail = data:sub(from)
      end
    end

    local complete = not aborted and not read_error and result.code == 0 and (result.signal or 0) == 0 and tail == ""
    local cached = complete and not over_budget and revision == captured_revision and publish(plan, paths, bytes)
    local final = complete and (cached and "complete" or "uncached") or (aborted and "cancelled" or "error")
    state(ctx, base, final, {
      complete = complete,
      count = count,
      path_bytes = bytes,
      cached = cached == true,
      over_budget = over_budget,
      code = result.code,
      error = read_error or (not complete and result.stderr or nil),
    })
  end
end

--- Streams the file list written by :UEPrepare. The list is the prepared scope
--- (engine dirs + project index dirs), so no directory walk happens here.
--- Relative entries resolve against opts.list_root (the workspace root).
---@type snacks.picker.finder
function M.find_list(opts, ctx)
  if ctx.picker then
    ctx.picker._file_inventory_owner = ctx
  end
  local base = opts.title or "Files"
  local root = opts.list_root and fs.norm(opts.list_root) or nil
  local Async = require("snacks.picker.util.async")
  return function(cb)
    local async = assert(Async.running(), "File inventory requires Snacks async finder context")
    local yield = Async.yielder(2)
    local fd = uv.fs_open(opts.list_path or "", "r", 438)
    if not fd then
      state(ctx, base, "error", { complete = false, error = "Cannot read " .. tostring(opts.list_path) })
      return
    end
    local count, tail, offset, read_error = 0, "", 0, nil
    local function close()
      if fd then
        local owned = fd
        fd = nil
        uv.fs_close(owned)
      end
    end
    async:on("abort", function()
      close()
      state(ctx, base, "cancelled", { complete = false, count = count })
    end)
    local ok, err = xpcall(function()
      while true do
        local chunk, error = uv.fs_read(fd, 1024 * 1024, offset)
        if error then
          read_error = tostring(error)
          break
        elseif not chunk or chunk == "" then
          break
        end
        offset = offset + #chunk
        local data, from = tail .. chunk, 1
        while true do
          local ending = data:find("\n", from, true)
          if not ending then
            break
          end
          local line = data:sub(from, ending - 1):gsub("\r$", "")
          from = ending + 1
          if line ~= "" then
            count = count + 1
            cb({ text = line, file = line, cwd = not fs.is_absolute_path(line) and root or nil })
            yield()
          end
        end
        tail = data:sub(from)
      end
      if not read_error then
        tail = tail:gsub("\r$", "")
        if tail ~= "" then
          count = count + 1
          cb({ text = tail, file = tail, cwd = not fs.is_absolute_path(tail) and root or nil })
        end
      end
    end, debug.traceback)
    close()
    if not ok then
      if not async:aborted() then
        state(ctx, base, "error", { complete = false, count = count, error = tostring(err) })
      end
      error(err, 0)
    elseif read_error then
      state(ctx, base, "error", { complete = false, count = count, error = read_error })
    else
      state(ctx, base, "prepared", { complete = true, count = count })
    end
  end
end

--- Keeps the real files source so configured normalize/confirm hooks still run.
function M.open(opts)
  local options = vim.deepcopy(opts or {})
  if options.list_path then
    options.finder = M.find_list
    return Snacks.picker.pick("files", options)
  end
  if options.refresh then
    M.invalidate(options)
    options.refresh = nil
  end
  options.finder = M.find
  options.actions = options.actions or {}
  options.actions.file_inventory_refresh = function(picker)
    M.invalidate(picker.opts, picker:filter().search)
    picker:find({ refresh = true })
  end
  options.win = options.win or {}
  for _, name in ipairs({ "input", "list" }) do
    options.win[name] = options.win[name] or {}
    options.win[name].keys = options.win[name].keys or {}
    options.win[name].keys["<F5>"] = { "file_inventory_refresh", mode = { "n", "i" } }
  end
  return Snacks.picker.pick("files", options)
end

return M
