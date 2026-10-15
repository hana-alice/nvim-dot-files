-- Bounded content evidence. A usable index header proves structure, not trigrams.
local M = {}
local uv = vim.uv
local fs = require("ue.core.fs")

local function deliver(cb, ...)
  local values = { ... }
  local count = select("#", ...)
  vim.schedule(function() cb(unpack(values, 1, count)) end)
end

function M.read_list(path, cb)
  uv.fs_open(path, "r", 438, function(err, fd)
    if err then deliver(cb, nil, err); return end
    local lines, tail, offset = {}, "", 0
    local function finish(failure)
      uv.fs_close(fd, function()
        if not failure and tail ~= "" then lines[#lines + 1] = tail:gsub("\r$", "") end
        if failure then deliver(cb, nil, failure) else deliver(cb, lines) end
      end)
    end
    local function next_chunk()
      uv.fs_read(fd, 65536, offset, function(read_err, raw)
        if read_err then finish(read_err); return end
        if raw == "" then finish(); return end
        offset = offset + #raw
        vim.schedule(function()
          local text, start = tail .. raw, 1
          while true do
            local last = text:find("\n", start, true)
            if not last then break end
            local line = text:sub(start, last - 1):gsub("\r$", "")
            if line ~= "" then lines[#lines + 1] = line end
            start = last + 1
          end
          tail = text:sub(start)
          if #tail > 1024 * 1024 then finish("oversized csearch list record"); return end
          next_chunk()
        end)
      end)
    end
    next_chunk()
  end)
end

function M.sample(changed, all, random)
  local out, seen = {}, {}
  local function add(path)
    if not seen[path] then seen[path] = true; out[#out + 1] = path end
  end
  -- Cap changed-file reads as well as subprocess count on large branch switches.
  for i = 1, math.min(#changed, 16) do add(changed[i]) end
  random = random or math.random
  for _ = 1, math.min(#all, 4) do
    local start = random(#all)
    for offset = 0, #all - 1 do
      local path = all[(start + offset - 1) % #all + 1]
      if not seen[path] then add(path); break end
    end
  end
  return out
end

local function identifiers(raw)
  -- Only certify complete small text files. A truncated window cannot rule out
  -- a later intentional upstream text-filter exclusion.
  if #raw >= 65536 or raw:find("\0", 1, true) then return {} end
  local previous, line, trigrams, trigram_count = 0, 0, {}, 0
  for i = 1, #raw do
    local byte = raw:byte(i)
    local valid = (previous < 0x80 and (byte < 0x80 or (byte >= 0xc0 and byte < 0xf8)))
      or (previous >= 0x80 and previous < 0xc0 and byte < 0xf8)
      or (previous >= 0xc0 and previous < 0xf8 and byte >= 0x80 and byte < 0xc0)
    if not valid then return {} end
    previous, line = byte, line + 1
    if line > 2000 then return {} end
    if byte == 10 then line = 0 end
    if i >= 3 then
      local trigram = raw:sub(i - 2, i)
      if not trigrams[trigram] then
        trigrams[trigram] = true; trigram_count = trigram_count + 1
        if trigram_count > 20000 then return {} end
      end
    end
  end
  local out, seen = {}, {}
  for token in raw:gmatch("[A-Za-z_][A-Za-z_0-9]*") do
    if #token >= 12 and #token <= 192 and not seen[token] then
      seen[token] = true; out[#out + 1] = token
    end
  end
  -- Prefix includes often survive edits. Prefer distinctive long identifiers
  -- across the read window instead of always checking the first two includes.
  table.sort(out, function(a, b) return #a == #b and a < b or #a > #b end)
  return { out[1], out[2] }
end

local function file_regex(path)
  return "^" .. fs.norm(path):gsub("([\\.^$|?*+(){}%[%]])", "\\%1") .. "$"
end

function M.check(ctx, paths, cb, cancelled, required)
  local cs = require("utils.code_search")
  local executable = cs.csearch_exe()
  if not executable then deliver(cb, nil, "csearch verification tool unavailable"); return end
  local stats, index = { sampled_files = #paths, checked_tokens = 0, skipped_files = 0 }, 0
  local function finish(ok, reason) cb(ok, reason, stats) end
  local next_file
  next_file = function()
    if cancelled and cancelled() then return end
    index = index + 1
    local path = paths[index]
    if not path then finish(true); return end
    uv.fs_open(path, "r", 438, function(err, fd)
      -- A removed random old-snapshot entry is not a promised current file.
      if err then
        vim.schedule(function()
          if (required and required[path]) or not tostring(err):find("ENOENT", 1, true) then
            finish(nil, "csearch verification file unavailable: " .. path .. ": " .. tostring(err))
          else stats.skipped_files = stats.skipped_files + 1; next_file() end
        end)
        return
      end
      uv.fs_read(fd, 65536, 0, function(read_err, raw)
        uv.fs_close(fd, function()
          vim.schedule(function()
            if read_err then finish(nil, "csearch verification read failed: " .. tostring(read_err)); return end
            local tokens, number = identifiers(raw or ""), 0
            if #tokens == 0 then stats.skipped_files = stats.skipped_files + 1; next_file(); return end
            local function query()
              if cancelled and cancelled() then return end
              number = number + 1
              local token = tokens[number]
              if not token then next_file(); return end
              local command = { executable, "-l", "-f", file_regex(path), token }
              local ok, handle = pcall(vim.system, command, {
                text = true, timeout = 5000, env = { CSEARCHINDEX = cs.index_path(ctx) },
              }, function(result)
                vim.schedule(function()
                  if cancelled and cancelled() then return end
                  stats.checked_tokens = stats.checked_tokens + 1
                  if result.code == 1 or (result.code == 0 and vim.trim(result.stdout or "") == "") then
                    stats.path, stats.token = path, token
                    finish(false, "csearch trigram content mismatch: " .. path .. " (" .. token .. ")")
                  elseif result.code ~= 0 then
                    finish(nil, "csearch verification query failed: " .. tostring(result.stderr or result.code))
                  else query() end
                end)
              end)
              if not ok then finish(nil, "csearch verification spawn failed: " .. tostring(handle)); return end
              pcall(require("utils.task_registry").register, {
                name = "UE: csearch content check", group = "ue", kind = "system", handle = handle,
              })
            end
            query()
          end)
        end)
      end)
    end)
  end
  vim.schedule(next_file)
end

function M.check_lists(ctx, changed_path, full_path, cb, cancelled)
  M.read_list(changed_path, function(changed, err)
    if not changed then cb(nil, err); return end
    local required = {}
    for _, path in ipairs(changed) do required[path] = true end
    M.read_list(full_path, function(all)
      M.check(ctx, M.sample(changed, all or {}), cb, cancelled, required)
    end)
  end)
end

-- Called only after a proven mismatch, while the original writer still owns its
-- lease. No directory walk: use the caller's full input or prior exact snapshot.
function M.repair_list(changed_path, full_path, out_path, cb, cancelled)
  M.read_list(full_path, function(all, err)
    if not all then cb(nil, "cannot repair without full csearch input: " .. tostring(err)); return end
    M.read_list(changed_path, function(changed, changed_err)
      if not changed then cb(nil, changed_err); return end
      local seen, remaining, index = {}, {}, 0
      for _, path in ipairs(changed) do all[#all + 1] = path end
      local function next_path()
        if cancelled and cancelled() then return end
        index = index + 1
        local path = all[index]
        if not path then
          local raw = table.concat(remaining, "\n") .. "\n"
          uv.fs_open(out_path, "w", 438, function(open_err, fd)
            if open_err then deliver(cb, nil, open_err); return end
            uv.fs_write(fd, raw, 0, function(write_err, bytes)
              uv.fs_close(fd, function()
                deliver(cb, not write_err and bytes == #raw and out_path or nil, write_err)
              end)
            end)
          end)
          return
        end
        if seen[path] then vim.schedule(next_path); return end
        seen[path] = true
        uv.fs_stat(path, function(stat_err, stat)
          vim.schedule(function()
            if stat_err and not tostring(stat_err):find("ENOENT", 1, true)
                and not tostring(stat_err):find("ENOTDIR", 1, true) then
              cb(nil, "cannot stat csearch repair input: " .. tostring(stat_err)); return
            end
            if stat and stat.type == "file" then remaining[#remaining + 1] = path end
            next_path()
          end)
        end)
      end
      vim.schedule(next_path)
    end)
  end)
end
return M
