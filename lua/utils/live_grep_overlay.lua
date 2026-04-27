-- lua/utils/live_grep_overlay.lua
-- ----------------------------------------------------------------------------
-- Stream rg matches over a known file list. The "rg-on-dirty" half of the
-- csearch + rg-on-dirty hybrid grep — see lua/utils/dirty_files.lua for the
-- "why".
--
-- DESIGN:
--   This module owns ZERO picker knowledge. It takes a pattern + a file
--   list, spawns rg via vim.system, parses its line-oriented stdout into
--   { file, lnum, col, text } records, and streams them through on_line
--   callbacks. The caller (ue.lua's grep finder) decides whether to push
--   them into a snacks picker, a quickfix list, or print them to :messages.
--
-- WHY a separate module:
--   * Test-friendly — the smoke test can spawn it in headless and
--     assert on the captured records without touching snacks.
--   * Reusable — same primitive serves "rg-on-dirty for csearch overlay"
--     and any future "rg over open buffers" / "rg over git diff" feature.
--
-- WINDOWS COMMAND-LINE LIMIT:
--   ~32K. dirty_files.lua truncates to 500 paths by default; with average
--   UE path length ~120 chars that leaves headroom. We still log a warn
--   if the constructed argv exceeds 28K (safety margin) and bail early —
--   silent ENAMETOOLONG would be miserable to diagnose.
--
-- RG FLAGS (pinned):
--   --no-heading        flat file:lnum:col:text per match line
--   --line-number
--   --column
--   --color=never       no ANSI escapes leaking into the picker text
--   --hidden=false      default; we already filtered .git/ in dirty_files
--   --no-ignore=false   keep gitignore behavior — Saved/Build are ignored
--                       in UE checkouts anyway
--   --max-columns=2000  defang minified files in shaders/.usf includes
--   -e PATTERN          explicit so patterns starting with - don't blow up
--
-- LIVE SEARCH SEMANTICS:
--   start() returns a handle with :stop(). Caller can spawn many in
--   sequence (one per keystroke); each new spawn should kill the previous.
--   We do NOT track "current" globally — that's the caller's job since
--   they own the picker lifecycle.
-- ----------------------------------------------------------------------------

local M = {}

M.MAX_ARGV_BYTES = 28 * 1024  -- safety cap below Windows 32K

-- Parse a single rg --no-heading --column line: "file:lnum:col:text"
-- Windows quirk: paths contain "C:" so first colon is part of the drive
-- letter. We have to scan from the END for lnum:col, not split on first
-- colons.
local function parse_rg_line(line)
  -- Match from right: ":lnum:col:rest"
  -- lnum/col are pure digits. rest is everything after.
  local file_part, lnum, col, text = line:match("^(.+):(%d+):(%d+):(.*)$")
  if not file_part then return nil end
  lnum = tonumber(lnum)
  col = tonumber(col)
  if not lnum or not col then return nil end
  return { file = file_part, lnum = lnum, col = col, text = text or "" }
end

-- Build the rg argv. Returns argv table or nil + reason.
local function build_argv(pattern, files, opts)
  if not pattern or pattern == "" then return nil, "empty pattern" end
  if not files or #files == 0 then return nil, "no files" end
  opts = opts or {}

  local argv = {
    "rg",
    "--no-heading",
    "--line-number",
    "--column",
    "--color=never",
    "--max-columns=2000",
    -- Force file: prefix even with a single file arg. rg's default is to
    -- omit the filename when only one path is given, which breaks our
    -- file:lnum:col:text parser. With --with-filename the format is
    -- consistent regardless of file count.
    "--with-filename",
  }
  if opts.smart_case ~= false then table.insert(argv, "--smart-case") end
  if opts.fixed_strings then table.insert(argv, "--fixed-strings") end

  table.insert(argv, "-e")
  table.insert(argv, pattern)

  -- File args come last so rg can't misinterpret them.
  -- Pre-flight argv byte count — Windows cmdline cap is 32K.
  local size = 0
  for _, a in ipairs(argv) do size = size + #a + 3 end  -- +3 for quoting+space
  for _, f in ipairs(files) do
    size = size + #f + 3
    if size > M.MAX_ARGV_BYTES then
      return nil, string.format("argv too large (%d bytes > cap %d) — caller should pre-truncate file list",
        size, M.MAX_ARGV_BYTES)
    end
    table.insert(argv, f)
  end
  return argv
end

-- Start a streaming rg run.
--
-- pattern: literal regex (smart_case applied unless opts.smart_case=false)
-- files:   array of absolute paths (already filtered + capped by caller)
-- opts:
--   smart_case      bool, default true
--   fixed_strings   bool, default false
--   on_line         function(record)  — called per match record
--   on_done         function(code, err_str_or_nil) — called once
--
-- Returns:
--   handle = {
--     stop = function(),     -- kills rg (idempotent)
--     pid  = number_or_nil,  -- rg pid for debug
--     argv_size = number,    -- byte count, useful for tuning max_files
--   }
--   OR nil + reason on argv-build failure.
function M.start(pattern, files, opts)
  opts = opts or {}
  local argv, err = build_argv(pattern, files, opts)
  if not argv then
    if opts.on_done then vim.schedule(function() opts.on_done(-1, err) end) end
    return nil, err
  end

  local stopped = false
  local handle = { argv_size = 0 }

  -- Compute argv_size for the handle (debug / tuning).
  for _, a in ipairs(argv) do handle.argv_size = handle.argv_size + #a + 1 end

  -- Streaming stdout: vim.system buffers by default. To stream we use
  -- the stdout callback form which fires per chunk. We accumulate a
  -- partial-line buffer because rg may flush mid-line on big results.
  local stdout_buf = ""
  local stderr_buf = ""

  local function on_stdout(_, chunk)
    if not chunk or chunk == "" then return end
    if stopped then return end
    stdout_buf = stdout_buf .. chunk
    -- Drain complete lines.
    while true do
      local nl = stdout_buf:find("\n", 1, true)
      if not nl then break end
      local line = stdout_buf:sub(1, nl - 1)
      stdout_buf = stdout_buf:sub(nl + 1)
      -- Strip trailing \r (Windows rg uses \n but be safe).
      if line:sub(-1) == "\r" then line = line:sub(1, -2) end
      if line ~= "" and opts.on_line then
        local rec = parse_rg_line(line)
        if rec then
          -- Call back directly. The stdout callback already runs on the
          -- main loop (vim.system delivers chunks via the libuv event
          -- loop, not a separate thread). Caller is responsible for
          -- vim.schedule wrapping if they touch nvim API from inside
          -- on_line — but most pickers just push into a Lua table here
          -- and drain it from the picker's own scheduler tick.
          if not stopped then opts.on_line(rec) end
        end
      end
    end
  end

  local function on_stderr(_, chunk)
    if chunk and chunk ~= "" then stderr_buf = stderr_buf .. chunk end
  end

  local sysobj
  local ok, sys_err = pcall(function()
    sysobj = vim.system(argv, {
      text = true,
      stdout = on_stdout,
      stderr = on_stderr,
    }, function(out)
      -- Process exited. Drain any tail line.
      if stdout_buf ~= "" and not stopped and opts.on_line then
        local tail = stdout_buf
        if tail:sub(-1) == "\r" then tail = tail:sub(1, -2) end
        local rec = parse_rg_line(tail)
        if rec and not stopped then opts.on_line(rec) end
        stdout_buf = ""
      end
      if opts.on_done then
        local errmsg = nil
        -- rg exit: 0 = matches found, 1 = no matches (NOT an error),
        -- 2 = real error. Treat 0/1 as success.
        if out.code and out.code ~= 0 and out.code ~= 1 then
          errmsg = (stderr_buf ~= "" and stderr_buf or ("rg exit " .. tostring(out.code)))
        end
        -- on_done MAY touch nvim API (notify, picker close, etc.) so we
        -- DO schedule this one — exit callback runs in the libuv close
        -- handler context where vim API may be restricted.
        vim.schedule(function() opts.on_done(out.code or -1, errmsg) end)
      end
    end)
  end)
  if not ok then
    if opts.on_done then vim.schedule(function() opts.on_done(-1, "spawn failed: " .. tostring(sys_err)) end) end
    return nil, "spawn failed: " .. tostring(sys_err)
  end

  handle.pid = sysobj and sysobj.pid or nil
  handle.stop = function()
    if stopped then return end
    stopped = true
    if sysobj then pcall(function() sysobj:kill(15) end) end
  end
  return handle
end

-- Test hooks.
M._parse_rg_line = parse_rg_line
M._build_argv = build_argv

return M
