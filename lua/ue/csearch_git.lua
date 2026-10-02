-- Git evidence belongs to the csearch writer lease; it never determines freshness.
local M = {}
local fs = require("ue.core.fs")
local path_key = require("utils.platform").driver().path_key
local function roots(ctx)
  local out, seen = {}, {}
  for _, root in ipairs({ctx and ctx.engine_root or "", ctx and ctx.project_root or ""}) do
    root = fs.norm(root)
    if root ~= "" and not seen[root] then out[#out + 1], seen[root] = root, true end
  end
  return out
end
local function identity(path)
  return fs.norm(vim.uv.fs_realpath(path) or path)
end
local function within(path, root) return fs.path_has_prefix(path_key(path), path_key(root)) end
local function nul(output)
  if output == "" then return {} end
  if type(output) ~= "string" or output:sub(-1) ~= "\0" then return nil end
  return vim.split(output:sub(1, -2), "\0", {plain = true})
end
local function relative_path(top, path)
  if path == "" or fs.is_absolute_path(path) or path:find("[\r\n]") then return nil end
  for part in path:gmatch("[^/]+") do if part == ".." then return nil end end
  return fs.join(top, path)
end
local function status_paths(top, output)
  local records, paths, i = nul(output), {}, 1
  if not records then return nil end
  while i <= #records do
    local row = records[i]
    if #row < 4 or row:sub(3, 3) ~= " " then return nil end
    local path = relative_path(top, row:sub(4))
    if not path then return nil end
    paths[path] = true
    if row:sub(1, 2):find("[RC]") then
      i = i + 1
      path = records[i] and relative_path(top, records[i])
      if not path then return nil end
      paths[path] = true
    end
    i = i + 1
  end
  return paths
end
-- Explicit search build's bounded read-only queries, serialized and cancellable.
local function run(root, args, cb)
  local command = {"git", "--no-optional-locks", "-C", root}
  vim.list_extend(command, args)
  local ok, handle = pcall(vim.system, command, {text = false, timeout = 15000}, function(result)
    vim.schedule(function()
      if result.code ~= 0 then cb(nil, "git query failed") else cb(result.stdout or "") end
    end)
  end)
  if not ok then cb(nil, "git spawn failed"); return end
  pcall(require("utils.task_registry").register, {name = "UE: csearch Git evidence", group = "ue", kind = "system", handle = handle})
end
function M.path(ctx)
  local idx = ctx and ctx.paths and ctx.paths.csearch_idx
  return idx and idx .. ".git-baseline.json" or nil
end
local function read(ctx)
  local path = M.path(ctx)
  local f = path and io.open(path, "rb")
  if not f then return nil end
  local raw = f:read("*a"); f:close()
  local ok, data = pcall(vim.json.decode, raw)
  if not ok or type(data) ~= "table" or data.schema ~= 1 or type(data.roots) ~= "table" then return nil end
  for root, entry in pairs(data.roots) do
    if type(root) ~= "string" or type(entry) ~= "table" then return nil end
    if entry.top ~= nil and type(entry.top) ~= "string" then return nil end
    if entry.coverage_head ~= nil and (type(entry.coverage_head) ~= "string"
        or not entry.coverage_head:match("^[0-9a-f]+$")
        or (#entry.coverage_head ~= 40 and #entry.coverage_head ~= 64)) then return nil end
    if entry.dirty ~= nil then
      if type(entry.dirty) ~= "table" then return nil end
      for path, value in pairs(entry.dirty) do
        if type(path) ~= "string" or value ~= true then return nil end
      end
    end
  end
  return data
end
function M.capture(ctx, cb)
  local wanted, result, index, failures = roots(ctx), {}, 0, {}
  local next_root
  local function failed(err)
    failures[wanted[index]] = tostring(err or "Git evidence unavailable")
    next_root()
  end
  local function query(root, args, fn)
    run(root, args, function(...)
      local ok, err = pcall(fn, ...)
      if not ok then failed("Git capture exception: " .. tostring(err)) end
    end)
  end
  next_root = function()
    index = index + 1
    local root = wanted[index]
    if not root then cb(result, failures); return end
    query(root, {"rev-parse", "--show-toplevel"}, function(output, err)
      if not output then failed(err); return end
      local top = identity(output:gsub("[\r\n]+$", ""))
      if not within(identity(root), top) then failed("root outside Git worktree"); return end
      query(top, {"rev-parse", "--verify", "HEAD"}, function(head, head_err)
        if not head then failed(head_err); return end
        head = head:gsub("[\r\n]+$", "")
        if not head:match("^[0-9a-f]+$") or (#head ~= 40 and #head ~= 64) then failed("invalid Git HEAD"); return end
        query(top, {"status", "--porcelain=v1", "-z", "--untracked-files=no", "--ignore-submodules=all"}, function(status, status_err)
          local dirty = status and status_paths(top, status)
          if not dirty then failed(status_err or "invalid Git status"); return end
          query(top, {"rev-parse", "--verify", "HEAD"}, function(confirmed, confirm_err)
            if not confirmed or confirmed:gsub("[\r\n]+$", "") ~= head then
              failed(confirm_err or "Git HEAD changed during capture"); return
            end
            result[root] = {top = top, head = head, dirty = dirty}
            next_root()
          end)
        end)
      end)
    end)
  end
  next_root()
end
local function union(into, from)
  for path in pairs(from or {}) do into[path] = true end
end
-- Complete means reset, or add fed by complete Git evidence. Ordinary/partial adds
-- retain the older coverage HEAD; an observed HEAD is never a coverage claim.
function M.save(ctx, before, complete, covered, cb)
  local previous, path = read(ctx), M.path(ctx)
  if not path or #roots(ctx) == 0 then cb(); return end
  M.capture(ctx, function(after)
    local data, coverage_valid = {schema = 1, roots = {}}, complete == true
    for _, root in ipairs(roots(ctx)) do
      local pre, post = before and before[root], after and after[root]
      local old = previous and previous.roots[root]
      local entry = post and {top = post.top, observed_head = post.head, dirty = {}} or {}
      if not pre or not post or pre.top ~= post.top or pre.head ~= post.head then coverage_valid = false end
      if pre and post and pre.top == post.top then
        union(entry.dirty, pre.dirty); union(entry.dirty, post.dirty)
        if complete and pre.head == post.head then entry.coverage_head = pre.head
        elseif old and old.top == post.top then
          entry.coverage_head = old.coverage_head
          union(entry.dirty, old.dirty)
        end
        if not complete then
          for _, p in ipairs(covered or {}) do if within(p, root) then entry.dirty[p] = true end end
        end
      end
      data.roots[root] = entry
    end
    local tmp = path .. (".tmp.%d.%s"):format(vim.fn.getpid(), tostring(vim.uv.hrtime()))
    local ok = pcall(function()
      local f = assert(io.open(tmp, "wb"))
      local wrote, err = f:write(vim.json.encode(data)); f:close(); assert(wrote, err)
      assert(vim.uv.fs_rename(tmp, path))
    end)
    if not ok then
      pcall(os.remove, tmp)
      -- An old baseline cannot describe newly indexed dirty contents after a
      -- failed evidence publication. Invalidate it rather than silently trust it.
      pcall(os.remove, path)
    end
    cb(ok, ok and coverage_valid)
  end)
end
-- Bound Lua parsing/intersection work as well as Git subprocess work.
local function chunks(iterator, visit, done)
  local function step()
    for _ = 1, 2048 do
      local item, extra = iterator()
      if item == nil then done(true); return end
      local ok, accepted, err = pcall(visit, item, extra)
      if not ok or accepted == false then done(false, err or accepted); return end
    end
    vim.defer_fn(step, 1)
  end
  vim.defer_fn(step, 1)
end
local function entries(set)
  local key
  return function() local value; key, value = next(set, key); return key, value end
end
local function records(output)
  if type(output) ~= "string" or (output ~= "" and output:sub(-1) ~= "\0") then return nil end
  local offset = 1
  return function()
    if offset > #output then return nil end
    local last = output:find("\0", offset, true)
    local row = output:sub(offset, last - 1); offset = last + 1
    return row
  end
end
function M.recover(ctx, before, current, previous, cb)
  local function query(root, args, fn)
    run(root, args, function(...)
      local ok, err = pcall(fn, ...)
      if not ok then cb(nil, "Git recovery exception: " .. tostring(err)) end
    end)
  end
  local baseline = read(ctx)
  if not baseline or not before or #roots(ctx) == 0 then cb(nil, "missing Git baseline"); return end
  local wanted, changes, index, candidates, conservative = roots(ctx), {}, 0, {}, {}
  local function next_root()
    index = index + 1
    local root = wanted[index]
    if not root then cb(changes, nil, {paths = vim.tbl_count(changes), conservative_paths = vim.tbl_count(conservative)}); return end
    local old, now = baseline.roots[root], before[root]
    if type(old) ~= "table" or not now or old.top ~= now.top
        or type(old.coverage_head) ~= "string" then cb(nil, "missing coverage HEAD"); return end
    local scoped, physical_root = {}, identity(root)
    local function scope_key(path)
      path = fs.norm(path)
      if within(path, root) then path = physical_root .. path:sub(#root + 1) end
      return path_key(path)
    end
    local function include(path)
      local keyed = scope_key(path)
      if scoped[keyed] then changes[scoped[keyed]] = true end
      -- --no-renames diff reports tracked files individually. Gitlink/nested
      -- contents are covered by the tracked complement, not directory expansion.
    end
    local function diff()
      for p in pairs(old.dirty or {}) do include(p) end
      for p in pairs(now.dirty) do include(p) end
      query(now.top, {"diff", "--name-only", "--no-renames", "-z", old.coverage_head, "--"}, function(output, err)
        local iterator = records(output)
        if not iterator then cb(nil, err or "invalid Git diff"); return end
        chunks(iterator, function(rel)
          local path = relative_path(now.top, rel)
          if not path then return false, "invalid Git diff path" end
          include(path)
        end, function(ok, failure)
          if not ok then cb(nil, failure); return end
          query(now.top, {"ls-files", "-v", "-z", "--cached"}, function(tracked_output, tracked_err)
            local rows = records(tracked_output)
            if not rows then cb(nil, tracked_err or "invalid Git tracked set"); return end
            local tracked = {}
            chunks(rows, function(row)
              if #row < 3 or row:sub(2, 2) ~= " " then return false, "invalid Git file flags" end
              local path = relative_path(now.top, row:sub(3))
              if not path then return false, "invalid Git tracked path" end
              tracked[scope_key(path)] = true
              local tag = row:sub(1, 1)
              if tag == "S" or tag:match("%l") then include(path) end
            end, function(parsed, parse_err)
              if not parsed then cb(nil, parse_err); return end
              -- All untracked/ignored/submodule contents are conservatively
              -- included without asking Git to enumerate irrelevant build files.
              chunks(entries(scoped), function(key, p)
                if not tracked[key] then changes[p], conservative[p] = true, true end
              end, next_root)
            end)
          end)
        end)
      end)
    end
    chunks(entries(candidates), function(p)
      if within(p, root) then
        local keyed = scope_key(p)
        scoped[keyed] = p

      end
    end, function(ok, err) if ok then diff() else cb(nil, err) end end)
  end
  local phase, cursor = 1, 0
  chunks(function()
    cursor = cursor + 1
    local value = (phase == 1 and current or previous or {})[cursor]
    if not value and phase == 1 then phase, cursor = 2, 1; value = (previous or {})[1] end
    return value
  end, function(p) candidates[p] = true end, next_root)
end
return M
