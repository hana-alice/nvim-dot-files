-- Code search dispatcher.
--
-- Delivers full <file>:<line>:<col>:<text> match results for live grep
-- in pickers. Backends in priority order; the first available wins.
--
--   csearch (trigram index, sub-second on 100k-file UE workspaces) ←
--     requires `cindex-uefilter` to have built an index, which UEPrepare
--     does automatically. See tools/cindex-uefilter/.
--   rg (walks the workspace; ~14-32s on UE — used as fallback only)
--
-- API:
--
--   require("utils.code_search").is_indexed(ctx) → boolean
--       Cheap probe: does a usable csearch index exist for this ctx?
--
--   require("utils.code_search").current_backend(ctx) → "csearch" | "rg" | nil
--
--   require("utils.code_search").stream(ctx, pattern, opts, callbacks)
--       Spawn a search; callbacks = { on_line, on_done }.
--       on_line(file, lnum, col, text)
--       on_done(exit_code, err_msg | nil)
--       Returns a stop() function the caller can invoke to kill the proc.
--
-- opts: { code_only = bool, max_count = int, smart_case = bool }

local M = {}

local platform = require("utils.platform")

-- ── csearch backend ──────────────────────────────────────────────────────

-- Resolve csearch executable path. Cached per-session.
local _csearch_path = nil
local _csearch_probed = false

local function csearch_exe()
  if _csearch_probed then return _csearch_path end
  _csearch_probed = true
  local candidates = {
    vim.fn.exepath("csearch"),
    vim.fn.exepath("csearch.exe"),
    vim.env.GOPATH and (vim.env.GOPATH .. (platform.is_windows and "\\bin\\csearch.exe" or "/bin/csearch")) or nil,
    vim.env.USERPROFILE and (vim.env.USERPROFILE .. "\\go\\bin\\csearch.exe") or nil,
    vim.env.HOME and (vim.env.HOME .. "/go/bin/csearch") or nil,
  }
  for _, c in ipairs(candidates) do
    if c and c ~= "" and vim.fn.executable(c) == 1 then
      _csearch_path = c
      return c
    end
  end
  return nil
end

local _cindex_path = nil
local _cindex_probed = false

function M.cindex_uefilter_exe()
  if _cindex_probed then return _cindex_path end
  _cindex_probed = true
  local candidates = {
    vim.fn.exepath("cindex-uefilter"),
    vim.fn.exepath("cindex-uefilter.exe"),
    vim.env.GOPATH and (vim.env.GOPATH .. (platform.is_windows and "\\bin\\cindex-uefilter.exe" or "/bin/cindex-uefilter")) or nil,
    vim.env.USERPROFILE and (vim.env.USERPROFILE .. "\\go\\bin\\cindex-uefilter.exe") or nil,
    vim.env.HOME and (vim.env.HOME .. "/go/bin/cindex-uefilter") or nil,
  }
  for _, c in ipairs(candidates) do
    if c and c ~= "" and vim.fn.executable(c) == 1 then
      _cindex_path = c
      return c
    end
  end
  return nil
end

-- Per-workspace index path. Lives next to UEPrepare's other caches.
-- ctx must expose workspace_root either as a field OR via a wrapper —
-- callers typically pass { workspace_root = "...", ... }.
--
-- Layout v2: prefer ctx.csearch_idx if caller passed it (avoids duplicating
-- the layout knowledge here). Fall back to legacy in-cache location for
-- back-compat with non-ue.lua callers.
function M.index_path(ctx)
  -- v2: caller supplied an explicit path (single source of truth in ue.lua)
  if ctx.csearch_idx and ctx.csearch_idx ~= "" then
    local dir = vim.fn.fnamemodify(ctx.csearch_idx, ":h")
    if vim.fn.isdirectory(dir) == 0 then vim.fn.mkdir(dir, "p") end
    return ctx.csearch_idx
  end
  local root = ctx.workspace_root or ctx.root
  if not root or root == "" then
    return nil
  end
  local csearch_dir = root .. "/.cache/nvim-ue/csearch"
  if vim.fn.isdirectory(csearch_dir) == 0 then
    vim.fn.mkdir(csearch_dir, "p")
  end
  return csearch_dir .. "/csearch.idx"
end

-- Check that a usable csearch index file exists for this workspace.
function M.is_indexed(ctx)
  if not csearch_exe() then return false end
  local idx = M.index_path(ctx)
  if not idx then return false end
  local stat = vim.loop.fs_stat(idx)
  return stat ~= nil and stat.size > 1024  -- empty index is ~73 bytes
end

function M.current_backend(ctx)
  if M.is_indexed(ctx) then return "csearch" end
  if vim.fn.executable("rg") == 1 then return "rg" end
  return nil
end

-- Stream csearch output. csearch's -n format:
--   /path/to/file.cpp:123:matched line text here
-- We reconstruct column by re-finding pattern (rough; sufficient for
-- picker preview placement). For exact column, use rg fallback.
local function stream_csearch(ctx, pattern, opts, callbacks)
  local cs = csearch_exe()
  if not cs then
    callbacks.on_done(1, "csearch not found in PATH")
    return function() end
  end

  local args = { "-n" }
  if opts.code_only then
    -- csearch -f filters by FILE PATH regex (not glob). Build a regex
    -- that matches the source extensions.
    table.insert(args, "-f")
    table.insert(args,
      "\\.(cpp|c|cc|cxx|h|hpp|hh|hxx|inl|cs|usf|ush|hlsl|hlsli|ini|cfg|json|xml|uproject|uplugin|target\\.cs|build\\.cs)$")
  end
  if opts.smart_case ~= false then
    -- csearch uses RE2; default is case-sensitive. Apply a lowercase
    -- pattern + (?i) prefix when no uppercase chars present (smart-case).
    if not pattern:match("%u") then
      pattern = "(?i)" .. pattern
    end
  end
  table.insert(args, pattern)

  local stdout = vim.loop.new_pipe(false)
  local stderr = vim.loop.new_pipe(false)
  local stderr_buf = {}
  local handle
  local closed = false
  local leftover = ""

  -- csearch uses CSEARCHINDEX env var. Pass per-workspace index.
  local env = {}
  for k, v in pairs(vim.fn.environ()) do
    if k ~= "CSEARCHINDEX" then
      table.insert(env, k .. "=" .. v)
    end
  end
  table.insert(env, "CSEARCHINDEX=" .. M.index_path(ctx))

  -- Stopped is set the moment the picker tells us to stop. From this
  -- point on we MUST NOT call any callback — the picker has marked its
  -- finder done and any further yield trips snacks' "yielded after done"
  -- bug-trap (which spams the user with red Snacks Picker Finder errors).
  local stopped = false

  local function safe_close()
    if closed then return end
    closed = true
    if stdout then pcall(stdout.read_stop, stdout) end
    if stderr then pcall(stderr.read_stop, stderr) end
    if stdout then pcall(stdout.close, stdout) end
    if stderr then pcall(stderr.close, stderr) end
  end

  local function safe_kill()
    if handle and not closed then
      pcall(handle.kill, handle, "sigterm")
    end
  end

  -- Pre-compile a Lua plain-find pattern for column estimation.
  -- For RE2 prefixed patterns we strip the (?i) flag before matching.
  local needle = pattern:gsub("^%(%?i%)", ""):lower()

  local emitted = 0
  local max_count = opts.max_count or 5000

  handle = vim.loop.spawn(cs, {
    args = args,
    env = env,
    stdio = { nil, stdout, stderr },
  }, function(code)
    safe_close()
    if handle then handle:close() end
    if stopped then return end
    vim.schedule(function()
      if stopped then return end
      callbacks.on_done(code, code ~= 0 and table.concat(stderr_buf, "") or nil)
    end)
  end)

  if not handle then
    safe_close()
    vim.schedule(function()
      if stopped then return end
      callbacks.on_done(1, "failed to spawn csearch")
    end)
    return function() stopped = true end
  end

  stdout:read_start(function(_, data)
    if stopped then return end
    if not data then return end
    leftover = leftover .. data
    while true do
      local nl = leftover:find("\n")
      if not nl then break end
      local line = leftover:sub(1, nl - 1):gsub("\r$", "")
      leftover = leftover:sub(nl + 1)
      if line ~= "" and emitted < max_count and not stopped then
        -- Format: <file>:<lnum>:<text>
        -- Files on Windows can start with C:\ — find the FIRST `:` AFTER
        -- the drive letter pair.
        local search_start = 1
        if line:sub(2, 2) == ":" then search_start = 3 end
        local file_end = line:find(":", search_start, true)
        if file_end then
          local file = line:sub(1, file_end - 1)
          local rest = line:sub(file_end + 1)
          local lnum_str, text = rest:match("^(%d+):(.*)$")
          if lnum_str and text then
            local lnum = tonumber(lnum_str) or 1
            local col = (text:lower():find(needle, 1, true) or 1)
            emitted = emitted + 1
            vim.schedule(function()
              -- Re-check inside the scheduled tick: by the time this
              -- runs the picker may have moved on (new keystroke ⇒ new
              -- finder ⇒ stop() called on us).
              if stopped then return end
              callbacks.on_line(file, lnum, col, text)
            end)
          end
        end
      end
    end
  end)
  stderr:read_start(function(_, data)
    if stopped then return end
    if data then table.insert(stderr_buf, data) end
  end)

  return function()
    -- Picker is done with us. Mark stopped FIRST so any in-flight
    -- vim.schedule callback short-circuits before touching the picker,
    -- THEN kill+close. Order matters: scheduled callbacks already on the
    -- main-loop queue would otherwise still call on_line.
    stopped = true
    safe_kill()
    safe_close()
  end
end

-- ── rg fallback ──────────────────────────────────────────────────────────

local function stream_rg(ctx, pattern, opts, callbacks)
  local rg = vim.fn.exepath("rg")
  if rg == "" then
    callbacks.on_done(1, "rg not found and no csearch index available")
    return function() end
  end

  local args = {
    "--color=never", "--no-heading", "--with-filename",
    "--line-number", "--column",
    "--smart-case", "--max-columns=500", "-0",
    "-j", "32", "--mmap",
  }
  for _, ex in ipairs(opts.exclude_dirs or {}) do
    table.insert(args, "-g"); table.insert(args, "!**/" .. ex .. "/**")
  end
  if opts.code_only then
    for _, ext in ipairs({ "cpp","c","cc","cxx","h","hpp","hh","hxx","inl",
                            "cs","usf","ush","hlsl","hlsli" }) do
      table.insert(args, "-g"); table.insert(args, "*." .. ext)
    end
  end
  table.insert(args, "--"); table.insert(args, pattern)
  for _, dir in ipairs(opts.search_dirs or {}) do
    table.insert(args, dir)
  end

  local stdout = vim.loop.new_pipe(false)
  local stderr = vim.loop.new_pipe(false)
  local stderr_buf = {}
  local handle
  local closed = false
  local leftover = ""

  local function safe_close()
    if closed then return end
    closed = true
    if stdout then pcall(stdout.close, stdout) end
    if stderr then pcall(stderr.close, stderr) end
  end

  handle = vim.loop.spawn(rg, {
    args = args,
    cwd = ctx.workspace_root,
    stdio = { nil, stdout, stderr },
  }, function(code)
    safe_close()
    if handle then handle:close() end
    vim.schedule(function()
      callbacks.on_done(code, code ~= 0 and table.concat(stderr_buf, "") or nil)
    end)
  end)

  if not handle then
    safe_close()
    vim.schedule(function() callbacks.on_done(1, "failed to spawn rg") end)
    return function() end
  end

  local emitted = 0
  local max_count = opts.max_count or 5000

  stdout:read_start(function(_, data)
    if not data then return end
    leftover = leftover .. data
    while true do
      local nul = leftover:find("\0")
      if not nul then break end
      local rec = leftover:sub(1, nul - 1)
      -- After NUL comes "<lnum>:<col>:<text>\n"
      leftover = leftover:sub(nul + 1)
      local nl = leftover:find("\n")
      if not nl then
        -- Push the file part back; wait for more data.
        leftover = rec .. "\0" .. leftover
        break
      end
      local rest = leftover:sub(1, nl - 1):gsub("\r$", "")
      leftover = leftover:sub(nl + 1)
      local lnum_s, col_s, text = rest:match("^(%d+):(%d+):(.*)$")
      if lnum_s and col_s and text and emitted < max_count then
        emitted = emitted + 1
        vim.schedule(function()
          callbacks.on_line(rec, tonumber(lnum_s), tonumber(col_s), text)
        end)
      end
    end
  end)
  stderr:read_start(function(_, data)
    if data then table.insert(stderr_buf, data) end
  end)

  return function()
    if handle and not closed then
      pcall(handle.kill, handle, "sigterm")
    end
  end
end

-- ── Public dispatcher ────────────────────────────────────────────────────

function M.stream(ctx, pattern, opts, callbacks)
  opts = opts or {}
  callbacks = callbacks or {}
  if not callbacks.on_line then callbacks.on_line = function() end end
  if not callbacks.on_done then callbacks.on_done = function() end end

  if M.is_indexed(ctx) then
    return stream_csearch(ctx, pattern, opts, callbacks)
  end
  return stream_rg(ctx, pattern, opts, callbacks)
end

-- ── Index build (called from UEPrepare) ──────────────────────────────────

-- Run cindex-uefilter -reset -files-from <abs_list>. Async; calls
-- cb(ok, err_msg, stats) on vim.schedule.
--
--   abs_list_path : a temp file containing absolute paths (one per line)
--   cb(ok, err, { count, ms, index_size })
function M.build_index(ctx, abs_list_path, cb)
  local cindex = M.cindex_uefilter_exe()
  if not cindex then
    vim.schedule(function()
      cb(false,
         "cindex-uefilter not found. Build it via:\n" ..
         "  cd <nvim-config>/tools/cindex-uefilter && go install ./...",
         {})
    end)
    return
  end

  local idx = M.index_path(ctx)
  local env = {}
  for k, v in pairs(vim.fn.environ()) do
    if k ~= "CSEARCHINDEX" then
      table.insert(env, k .. "=" .. v)
    end
  end
  table.insert(env, "CSEARCHINDEX=" .. idx)

  local stderr = vim.loop.new_pipe(false)
  local stderr_buf = {}
  local handle
  local started = vim.loop.hrtime()

  handle = vim.loop.spawn(cindex, {
    args = { "-reset", "-files-from", abs_list_path },
    env = env,
    stdio = { nil, nil, stderr },
  }, function(code)
    if stderr then pcall(stderr.close, stderr) end
    if handle then handle:close() end
    local ms = math.floor((vim.loop.hrtime() - started) / 1e6)
    vim.schedule(function()
      if code ~= 0 then
        cb(false, "cindex-uefilter exit=" .. code .. ": " .. table.concat(stderr_buf, ""), { ms = ms })
        return
      end
      local stat = vim.loop.fs_stat(idx)
      cb(true, nil, {
        ms = ms,
        index_size = stat and stat.size or 0,
      })
    end)
  end)

  if not handle then
    if stderr then pcall(stderr.close, stderr) end
    vim.schedule(function() cb(false, "failed to spawn cindex-uefilter", {}) end)
    return
  end

  stderr:read_start(function(_, data)
    if data then table.insert(stderr_buf, data) end
  end)
end

return M
