-- WORKAROUND
-- name: codediff.safe_mutations
-- scope: codediff
-- issue: internal: CodeDiff v4.0.6 writes unrelated dirty lines and applies stale zero-context hunks
-- symptom: Discard saves unrelated edits; stale hunk operations can change the wrong index region
-- introduced: 2026-09-29
-- removal_condition: upstream guards displayed sources and dirty buffers and preserves patch line endings
-- owner: hana-alice
-- enabled: true
-- END WORKAROUND

local M = {}
local installed = {}
local busy = {}

local function warn(message)
  vim.notify("CodeDiff: " .. message, vim.log.levels.WARN)
end

local function review_kind(session)
  local panel = session and session.panel
  local data = panel and panel.data or {}
  local refs = data.source_revisions or {}
  local status = panel and panel.name == "explorer" and not data.base_revision and not data.target_revision and not data.source_revisions
  local staged = panel and panel.name == "explorer" and refs.original == "HEAD" and refs.modified == ":0"
  return status, staged
end

local function canonical(path)
  local absolute = vim.fn.fnamemodify(path, ":p")
  local resolved = vim.uv.fs_realpath(absolute)
  if not resolved then
    local parent = vim.uv.fs_realpath(vim.fs.dirname(absolute))
    resolved = parent and (parent .. "/" .. vim.fs.basename(absolute)) or absolute
  end
  local normalized = vim.fs.normalize(resolved):gsub("/$", "")
  return require("utils.platform").driver().path_key(normalized)
end

-- Return an error instead of selecting the saved file behind a dirty buffer.
function M.dirty(root, relative)
  local target = canonical(root .. "/" .. (relative or ""))
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].modified and vim.bo[buf].buftype == "" then
      local name = canonical(vim.api.nvim_buf_get_name(buf))
      if name == target or name:sub(1, #target + 1) == target .. "/" then
        return "Unsaved buffer: " .. name .. ". Save or undo it explicitly before this operation."
      end
    end
  end
end

local function lines(bytes)
  local result = vim.split(bytes:gsub("\r\n", "\n"), "\n", { plain = true })
  if result[#result] == "" then table.remove(result) end
  if #result == 0 then result = { "" } end
  return result
end

local function same(buf, bytes)
  return vim.api.nvim_buf_is_valid(buf)
    and vim.deep_equal(vim.api.nvim_buf_get_lines(buf, 0, -1, false), lines(bytes))
end

local function read_file(path, callback)
  vim.uv.fs_open(path, "r", 438, function(err, fd)
    if err then vim.schedule(function() callback(err) end); return end
    vim.uv.fs_fstat(fd, function(stat_err, stat)
      if stat_err or not stat or stat.size > 8 * 1024 * 1024 then
        vim.uv.fs_close(fd)
        vim.schedule(function() callback(stat_err or "File exceeds the 8 MiB safe hunk limit; use whole-file operations") end)
        return
      end
      vim.uv.fs_read(fd, stat.size, 0, function(read_err, bytes)
        vim.uv.fs_close(fd)
        vim.schedule(function() callback(read_err, bytes) end)
      end)
    end)
  end)
end

-- Validate the exact buffers used by the upstream hunk action against Git/disk.
-- This is async and reads one file only; it never refreshes or saves a buffer.
function M.check(ctx, callback)
  local lifecycle = require("codediff.ui.lifecycle")
  local session = lifecycle.get_session(ctx.tabpage)
  if not session or not session.git_root then callback("No Git review session"); return end
  if session.git_review_binary then callback("Binary file: hunk operations are unavailable; use the whole-file action"); return end
  if session.modified_revision ~= nil and session.modified_revision ~= ":0" then
    callback("Historical comparison is read-only"); return
  end
  -- The refresh layer resolves HEAD to a hash. Classify the panel's source
  -- identities instead of mistaking that normal status view for history.
  local status_view, staged_view = review_kind(session)
  if (session.modified_revision == nil and session.original_revision ~= ":0" and not status_view)
    or (session.modified_revision == ":0" and session.original_revision ~= "HEAD" and not status_view and not staged_view) then
    callback("Hunk mutation requires Index/Working or HEAD/Index review"); return
  end
  local path = session.modified.relative ~= "" and session.modified.relative or session.original.relative
  if not path or path == "" then callback("No file selected"); return end
  if session.original.relative ~= "" and session.original.relative ~= path then
    callback("Renamed file: use the explicit whole-file action"); return
  end
  local dirty = M.dirty(session.git_root, path)
  if dirty then callback(dirty); return end
  local a, b = lifecycle.get_buffers(ctx.tabpage)
  if not a or not b or not vim.api.nvim_buf_is_valid(a) or not vim.api.nvim_buf_is_valid(b) then
    callback("Review buffers are unavailable"); return
  end
  local ticks = { vim.api.nvim_buf_get_changedtick(a), vim.api.nvim_buf_get_changedtick(b) }
  local staged = session.modified_revision == ":0"
  local index_buf = staged and b or a
  local function valid()
    local current_a, current_b = lifecycle.get_buffers(ctx.tabpage)
    return lifecycle.get_session(ctx.tabpage) == session
      and current_a == a and current_b == b
      and (session.modified.relative ~= "" and session.modified.relative or session.original.relative) == path
      and vim.api.nvim_buf_is_valid(a) and vim.api.nvim_buf_is_valid(b)
      and vim.api.nvim_buf_get_changedtick(a) == ticks[1] and vim.api.nvim_buf_get_changedtick(b) == ticks[2]
      and not M.dirty(session.git_root, path)
  end
  require("workarounds.codediff.threaded_git").system({ "show", ":0:" .. path }, { cwd = session.git_root, text = false, timeout = 5000 }, function(result)
    vim.schedule(function()
      if not valid() then callback("Review changed while checking; retry"); return end
      if result.code ~= 0 then callback("No stage-0 blob; use the explicit whole-file action"); return end
      local index = result.stdout
      if not same(index_buf, index) then callback("Index changed outside this view; refresh before retrying"); return end
      if index ~= "" and index:sub(-1) ~= "\n" then
        callback("No final newline: hunk operations are unsupported; use the whole-file action"); return
      end
      local info = { root = session.git_root, path = path, index = index, staged = staged, session = session }
      if staged then
        require("workarounds.codediff.threaded_git").system({ "show", "HEAD:" .. path }, { cwd = session.git_root, text = false, timeout = 5000 }, function(head)
          vim.schedule(function()
            if not valid() then callback("Review changed while checking; retry"); return end
            if head.code ~= 0 or not same(a, head.stdout) then callback("Base revision changed; refresh before retrying"); return end
            if head.stdout ~= "" and head.stdout:sub(-1) ~= "\n" then callback("No final newline: use the whole-file action"); return end
            info.base = head.stdout
            callback(nil, info)
          end)
        end)
      else
        read_file(session.git_root .. "/" .. path, function(err, bytes)
          if not valid() then callback("Review changed while checking; retry"); return end
          if err then callback("Working file unavailable: " .. tostring(err) .. "; use the whole-file action"); return end
          if not same(b, bytes) then callback("Working file changed outside this view; refresh before retrying"); return end
          if bytes ~= "" and bytes:sub(-1) ~= "\n" then callback("No final newline: use the whole-file action"); return end
          info.disk = bytes
          callback(nil, info)
        end)
      end
    end)
  end)
end

local function crlf(bytes)
  return bytes and bytes:find("\r\n", 1, true) ~= nil
end

local function patch_eol(patch, info, reverse)
  local old_crlf = crlf(reverse and info.base or info.index)
  local new_crlf = crlf(info.index)
  local result = {}
  for line in patch:gmatch("(.-)\n") do
    local prefix = line:sub(1, 1)
    if (#result >= 3 and prefix == "-" and old_crlf)
      or (#result >= 3 and prefix == "+" and new_crlf) then
      line = line:gsub("\r$", "") .. "\r"
    end
    result[#result + 1] = line
  end
  return table.concat(result, "\n") .. "\n"
end

local function replace(target, name, fn)
  installed[#installed + 1] = { target, name, target[name] }
  target[name] = fn
end

local function refresh(tabpage, event)
  require("codediff.ui.refresh").request(tabpage, event)
end

function M.apply()
  if #installed > 0 then return true end
  -- Registry discovery must not trigger loading a plugin or native installer.
  if not package.loaded["codediff"] then return false end
  local hunk = require("codediff.ui.view.actions.hunk")
  local git = require("codediff.core.git")
  local find_hunk = hunk.find_hunk_at_cursor
  replace(hunk, "find_hunk_at_cursor", function(ctx)
    local found, number = find_hunk(ctx)
    if found then return found, number end
    local session = require("codediff.ui.lifecycle").get_session(ctx.tabpage)
    local buf = vim.api.nvim_get_current_buf()
    local line = vim.api.nvim_win_get_cursor(0)[1]
    local count = vim.api.nvim_buf_line_count(buf)
    if not session or not session.stored_diff_result or line ~= count then return end
    for i, mapping in ipairs(session.stored_diff_result.changes or {}) do
      local range = not ctx.is_inline and buf == ctx.original_bufnr and mapping.original or mapping.modified
      if range.start_line == range.end_line and range.start_line == count + 1 then return mapping, i end
    end
  end)
  for _, name in ipairs({ "stage_hunk", "unstage_hunk", "discard_hunk" }) do
    local original = hunk[name]
    replace(hunk, name, function(ctx)
      if busy[ctx.tabpage] then warn("A hunk operation is already in progress"); return end
      local session = require("codediff.ui.lifecycle").get_session(ctx.tabpage)
      if session and session.git_review_binary then warn("Binary file: hunk operations are unavailable; use the whole-file action"); return end
      local selected = hunk.find_hunk_at_cursor(ctx)
      if not selected then warn("No hunk at cursor position"); return end
      local win = vim.api.nvim_get_current_win()
      local cursor = vim.api.nvim_win_get_cursor(win)
      local buf = vim.api.nvim_get_current_buf()
      busy[ctx.tabpage] = true
      local function execute(err, info)
        if err then busy[ctx.tabpage] = nil; warn(err); return end
        if vim.api.nvim_get_current_win() ~= win or not vim.api.nvim_win_is_valid(win) or vim.api.nvim_win_get_buf(win) ~= buf
          or hunk.find_hunk_at_cursor(ctx) ~= selected
          or not vim.deep_equal(vim.api.nvim_win_get_cursor(win), cursor) then
          busy[ctx.tabpage] = nil
          warn("Review position changed while checking; retry"); return
        end
        local apply_patch = git.apply_patch
        local confirm = vim.fn.confirm
        local mutation_started = false
        git.apply_patch = function(root, patch, reverse, callback)
          mutation_started = true
          return apply_patch(root, patch_eol(patch, info, reverse), reverse, function(err)
            busy[ctx.tabpage] = nil
            callback(err)
            if not err then refresh(ctx.tabpage, { index = true }) end
          end)
        end
        if name == "discard_hunk" then vim.fn.confirm = function() return 1 end end
        local ok, action_err = pcall(vim.api.nvim_win_call, win, function() original(ctx) end)
        git.apply_patch, vim.fn.confirm = apply_patch, confirm
        if not ok or not mutation_started then busy[ctx.tabpage] = nil end
        if not ok then warn(tostring(action_err)) end
        if ok and name == "discard_hunk" then refresh(ctx.tabpage, { buffer = true, worktree = true }) end
      end
      M.check(ctx, function(err, info)
        if err or name ~= "discard_hunk" then execute(err, info); return end
        local prompt = "Discard hunk?\nRepository: " .. info.root .. "\nFile: " .. info.path
        if vim.fn.confirm(prompt, "&Discard\n&Cancel", 2, "Warning") ~= 1 then busy[ctx.tabpage] = nil; return end
        -- Recheck after the confirmation: another process may change the file.
        M.check(ctx, execute)
      end)
    end)
  end
  for _, name in ipairs({ "stage_file", "unstage_file", "restore_file", "delete_untracked", "stage_all", "unstage_all" }) do
    local original = git[name]
    replace(git, name, function(root, ...)
      local args = { ... }
      local argc = select("#", ...)
      local tabpage = vim.api.nvim_get_current_tabpage()
      local path = (name == "stage_all" or name == "unstage_all") and "" or args[1]
      local session = require("codediff.ui.lifecycle").get_session(vim.api.nvim_get_current_tabpage())
      local panel = session and session.panel
      local data = panel and panel.data or {}
      local _, staged_view = review_kind(session)
      local historical = session and session.git_root == root
        and ((panel and panel.name == "history") or ((data.base_revision or data.target_revision or data.source_revisions) and not staged_view)
          or (not panel and session.original_revision ~= ":0" and session.modified_revision ~= ":0"))
      local err = historical and "Historical comparison is read-only" or M.dirty(root, path)
      if err then
        local callback = args[argc]
        if type(callback) == "function" then callback(err) else warn(err) end
        return
      end
      local callback = args[argc]
      args[argc] = function(mutation_err, ...)
        callback(mutation_err, ...)
        if not mutation_err then
          refresh(tabpage, (name == "restore_file" or name == "delete_untracked") and { worktree = true } or { index = true })
        end
      end
      return original(root, unpack(args, 1, argc))
    end)
  end
  local explorer_actions = require("codediff.ui.explorer.actions")
  M.guard_explorer(explorer_actions)
  local facade = package.loaded["codediff.ui.explorer"]
  if facade then replace(facade, "restore_entry", explorer_actions.restore_entry) end
  return true
end

-- Called once the explorer facade exists, keeping registry discovery lazy.
function M.guard_explorer(explorer)
  if explorer._local_safe_restore then return end
  local original = explorer.restore_entry
  replace(explorer, "_local_safe_restore", true)
  replace(explorer, "restore_entry", function(panel, tree)
    if not panel or not panel.data then return end
    if panel.data.base_revision or panel.data.target_revision then warn("Historical comparison is read-only"); return end
    local confirm = vim.fn.confirm
    vim.fn.confirm = function(prompt, ...)
      return confirm(prompt .. "\nRepository: " .. tostring(panel.data.git_root), ...)
    end
    local ok, err = pcall(original, panel, tree)
    vim.fn.confirm = confirm
    if not ok then warn(tostring(err)) end
  end)
end

function M.disable()
  for i = #installed, 1, -1 do
    local entry = installed[i]
    entry[1][entry[2]] = entry[3]
  end
  installed, busy = {}, {}
end

function M.status()
  return { applied = #installed > 0, pending = vim.tbl_count(busy) }
end

return M
