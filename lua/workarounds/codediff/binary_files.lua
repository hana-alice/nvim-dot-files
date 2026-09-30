-- WORKAROUND
-- name: codediff.binary_files
-- scope: codediff
-- issue: internal: CodeDiff v4.0.6 feeds binary changes into text diff buffers
-- symptom: Binary files have no explicit unsupported-text-diff state and expose hunk actions
-- introduced: 2026-09-29
-- removal_condition: upstream renders binary notices and blocks binary hunk mutations
-- owner: hana-alice
-- enabled: true
-- END WORKAROUND

local M = {}
local installed

local function binary_metadata(session, relative)
  local status = session.panel and session.panel.data.status_result or {}
  for _, group in ipairs({ "unstaged", "staged", "conflicts" }) do
    for _, file in ipairs(status[group] or {}) do
      if file.path == relative and file.line_stats and file.line_stats.binary then return true end
    end
  end
  return false
end

-- Untracked files have no numstat metadata. Read only a bounded prefix,
-- without loading or replacing a user's existing buffer.
local function nul_prefix(path, callback)
  if not path or path == "" then callback(false); return end
  vim.uv.fs_open(path, "r", 438, function(err, fd)
    if err then vim.schedule(function() callback(false) end); return end
    vim.uv.fs_read(fd, 8192, 0, function(_, bytes)
      vim.uv.fs_close(fd)
      vim.schedule(function() callback(bytes and bytes:find("\0", 1, true) ~= nil or false) end)
    end)
  end)
end

function M.apply()
  if installed or not package.loaded.codediff then return end
  local view = require("codediff.ui.view")
  local inputs = require("codediff.ui.refresh.inputs")
  local lifecycle = require("codediff.ui.lifecycle")
  local refresh = require("codediff.ui.refresh")
  local original_show, original_read, original_welcome = view.show, inputs.read, view.show_welcome
  local function show(tab, comparison, jump)
    local session = lifecycle.get_session(tab)
    if not session then return false end
    local generation = session.refresh and session.refresh.generation
    local request = (session.git_review_binary_request or 0) + 1
    session.git_review_binary_request = request
    local relative = comparison.modified.relative ~= "" and comparison.modified.relative or comparison.original.relative
    local function display(binary)
      if not refresh.is_current(tab, session, generation) or session.git_review_binary_request ~= request then return end
      session.git_review_binary = nil
      if not binary then original_show(tab, comparison, jump); return end
      local buf = vim.api.nvim_create_buf(false, true)
      vim.bo[buf].buftype, vim.bo[buf].bufhidden, vim.bo[buf].swapfile = "nofile", "wipe", false
      vim.bo[buf].filetype = "codediff-binary"
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
        "Binary file: " .. relative,
        "",
        "Text diff and hunk operations are unavailable.",
        "Use the file list for whole-file stage / unstage.",
      })
      vim.bo[buf].modifiable = false
      lifecycle.update_merge(tab, false)
      require("codediff.ui.view.side_by_side").show_welcome(tab, buf)
      lifecycle.update_paths(tab, comparison.original, comparison.modified)
      lifecycle.update_revisions(tab, comparison.original_revision, comparison.modified_revision)
      session.git_review_binary = { path = relative }
      refresh.ready(tab)
    end
    if binary_metadata(session, relative) then
      display(true)
    else
      -- Historical/index sides must never be classified using today's disk
      -- bytes: a text revision can coexist with a binary working copy.
      local working
      for _, side in ipairs({ "modified", "original" }) do
        if require("codediff.ui.refresh.policy").is_working(comparison[side .. "_revision"])
          and comparison[side].absolute ~= "" then working = comparison[side].absolute; break end
      end
      if working then nul_prefix(working, display) else display(false) end
    end
    return true
  end
  local function read(session, event, previous, done)
    if session.git_review_binary then
      done(nil, inputs.capture(session))
    else
      original_read(session, event, previous, done)
    end
  end
  local function welcome(tab)
    local session = lifecycle.get_session(tab)
    if session then
      session.git_review_binary = nil
      session.git_review_binary_request = (session.git_review_binary_request or 0) + 1
    end
    return original_welcome(tab)
  end
  installed = { view = view, inputs = inputs, show = show, read = read, welcome = welcome,
    original_show = original_show, original_read = original_read, original_welcome = original_welcome }
  view.show, inputs.read, view.show_welcome = show, read, welcome
end

function M.disable()
  if not installed then return end
  if installed.view.show == installed.show then installed.view.show = installed.original_show end
  if installed.inputs.read == installed.read then installed.inputs.read = installed.original_read end
  if installed.view.show_welcome == installed.welcome then installed.view.show_welcome = installed.original_welcome end
  installed = nil
end

function M.status()
  return { applied = installed ~= nil }
end

return M
