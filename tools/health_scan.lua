-- tools/health_scan.lua — one-shot codebase health scanner (read-only).
--
-- Part of openspec change `codebase-health-check`. Produces CANDIDATE lists
-- for human triage — a hit here is NOT automatically a finding (many
-- vim.fn.system calls live in legitimate synchronous user-command paths).
--
-- Usage:
--   nvim --headless -l tools/health_scan.lua > tools/health_scan_output.txt
--
-- Sections emitted:
--   [A] blocking-call candidates: lines containing vim.fn.system / systemlist /
--       io.popen / vim.wait, with surrounding-context classification hints
--       (inside timer:start / autocmd callback / schedule_wrap when detectable
--       by a cheap backward scan).
--   [B] file line counts over the 800-line style cap.
--   [C] handle lifecycle pairing: per file, counts of new_timer/jobstart/
--       new_fs_event vs stop/close references.

local cfg = vim.fn.stdpath("config")
local uv = vim.uv or vim.loop

local function read_lines(path)
  local out = {}
  local f = io.open(path, "r")
  if not f then return out end
  for l in f:lines() do out[#out + 1] = l end
  f:close()
  return out
end

local function list_lua_files()
  local files = vim.fn.glob(cfg .. "/lua/**/*.lua", true, true)
  table.sort(files)
  return files
end

local BLOCK_PATTERNS = {
  { pat = "vim%.fn%.system%f[%W]", label = "vim.fn.system" },
  { pat = "vim%.fn%.systemlist",   label = "vim.fn.systemlist" },
  { pat = "io%.popen",             label = "io.popen" },
  { pat = "vim%.wait%(",           label = "vim.wait" },
}

-- Cheap context hint: scan up to 40 lines backward for enclosing constructs.
local function context_hint(lines, i)
  local hints = {}
  for j = i, math.max(1, i - 40), -1 do
    local l = lines[j]
    if l:find("timer:start(", 1, true) or l:find(":start(", 1, true) and l:find("timer", 1, true) then
      hints[#hints + 1] = "near-timer-start"
      break
    end
    if l:find("nvim_create_autocmd", 1, true) then
      hints[#hints + 1] = "in-autocmd-block"
      break
    end
    if l:find("schedule_wrap", 1, true) then
      hints[#hints + 1] = "in-schedule_wrap"
      break
    end
    if l:find("nvim_create_user_command", 1, true) then
      hints[#hints + 1] = "in-user-command"
      break
    end
    if l:match("^%s*function%s") or l:match("^local function%s") then
      break -- reached enclosing function head with no marker
    end
  end
  return #hints > 0 and table.concat(hints, ",") or "no-marker"
end

local files = list_lua_files()

print("== health_scan @ " .. os.date("%Y-%m-%d %H:%M") .. " ==")
print("files scanned: " .. #files)
print("")
print("[A] blocking-call candidates (human triage required)")
for _, path in ipairs(files) do
  local rel = path:sub(#cfg + 2)
  local lines = read_lines(path)
  for i, l in ipairs(lines) do
    if not l:match("^%s*%-%-") then -- skip pure comment lines
      for _, bp in ipairs(BLOCK_PATTERNS) do
        if l:find(bp.pat) then
          print(("A|%s|%d|%s|%s|%s"):format(rel, i, bp.label, context_hint(lines, i), vim.trim(l):sub(1, 90)))
        end
      end
    end
  end
end

print("")
print("[B] files over 800-line style cap")
for _, path in ipairs(files) do
  local rel = path:sub(#cfg + 2)
  local n = #read_lines(path)
  if n > 800 then
    print(("B|%s|%d"):format(rel, n))
  end
end

print("")
print("[C] handle lifecycle pairing (created vs stop/close refs per file)")
for _, path in ipairs(files) do
  local rel = path:sub(#cfg + 2)
  local src = table.concat(read_lines(path), "\n")
  local timers = select(2, src:gsub("new_timer%(", ""))
  local jobs = select(2, src:gsub("jobstart%(", ""))
  local fsev = select(2, src:gsub("new_fs_event%(", ""))
  if timers + jobs + fsev > 0 then
    local stops = select(2, src:gsub(":stop%(", ""))
    local closes = select(2, src:gsub(":close%(", ""))
    local jobstops = select(2, src:gsub("jobstop%(", ""))
    print(("C|%s|timers=%d jobs=%d fs_event=%d | stop=%d close=%d jobstop=%d")
      :format(rel, timers, jobs, fsev, stops, closes, jobstops))
  end
end

print("")
print("== end ==")
