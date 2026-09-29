-- WORKAROUND
-- name: codediff.history_paths
-- scope: codediff
-- issue: internal: CodeDiff v4.0.6 parses display-form numstat paths and loses rename sides
-- symptom: Unicode file history opens empty buffers and rename commits use an invalid combined path
-- introduced: 2026-09-29
-- removal_condition: upstream history consumes NUL paths and passes rename old_path into comparisons
-- owner: hana-alice
-- enabled: true
-- END WORKAROUND

local M = {}
local installed

local function name_status(output)
  local tokens, files, i = vim.split(output, "\0", { plain = true }), {}, 1
  while i <= #tokens and tokens[i] ~= "" do
    local status, old_path, path = tokens[i]:gsub("^\n", ""):sub(1, 1), nil, tokens[i + 1]
    if status == "R" or status == "C" then
      old_path, path, i = path, tokens[i + 2], i + 1
    end
    if not path or path == "" then return nil, "Incomplete Git file record" end
    files[#files + 1] = { status = status, path = path, old_path = old_path }
    i = i + 2
  end
  return files
end

local function query_files(args, root, callback)
  require("codediff.core.git.runner").run_async(args, { cwd = root, no_optional_locks = true }, function(err, output)
    if err then callback(err); return end
    local files, parse_err = name_status(output)
    callback(parse_err, files)
  end)
end

-- Metadata, statistics, ordering and -L remain upstream-owned. One bounded
-- name-status query repairs only the literal paths of the returned commits.
local function path_records(output)
  local tokens = vim.split(output, "\0", { plain = true })
  local records, hash, i = {}, nil, 1
  while i <= #tokens do
    local token = tokens[i]
    if token == "" and tokens[i + 1] and tokens[i + 1]:match("^%x+$") and #tokens[i + 1] == 40 then
      hash = tokens[i + 1]
      i = i + 2
    else
      local status = token:gsub("^\n", "")
      if hash and status:match("^[RC]%d+$") then
        records[hash] = { file_path = tokens[i + 2], old_path = tokens[i + 1] }
        i = i + 3
      elseif hash and status:match("^[AMDTUXB]$") then
        records[hash] = { file_path = tokens[i + 1] }
        i = i + 2
      else
        i = i + 1
      end
    end
  end
  return records
end

function M.apply()
  if installed or not package.loaded.codediff then return end
  local git = require("codediff.core.git")
  local changes = require("codediff.core.git.changes")
  local history = require("codediff.core.git.history")
  local revision = require("codediff.core.git.revision")
  local repository = require("codediff.core.git.repository")
  local panel = require("codediff.ui.refresh.panel")
  local original_list, original_comparison = git.get_commit_list, panel.comparison
  local original_relative_path = git.get_relative_path
  local function get_relative_path(file, root)
    local absolute = vim.fs.normalize(vim.fn.fnamemodify(file, ":p"))
    local directory = vim.fs.dirname(absolute)
    absolute = vim.fs.joinpath(vim.uv.fs_realpath(directory) or directory, vim.fs.basename(absolute))
    return original_relative_path(absolute, vim.uv.fs_realpath(root) or root)
  end
  local function resolve_path_at_revision(rev, root, relative, callback)
    query_files({ "log", "--follow", "--diff-filter=RC", "--format=", "--name-status", "-z", rev .. "..HEAD", "--", relative }, root, function(err, files)
      if not err then
        for i = #files, 1, -1 do
          if files[i].old_path then callback(nil, files[i].old_path); return end
        end
      end
      callback(err, relative)
    end)
  end
  local function get_commit_list(range, root, opts, callback)
    opts = opts or {}
    if not opts.path or opts.path == "" or opts.line_range then
      return original_list(range, root, opts, callback)
    end
    local args = { "log", "--format=%x00%H", "--name-status", "-z", "--follow" }
    if opts.no_merges then args[#args + 1] = "--no-merges" end
    if opts.limit then vim.list_extend(args, { "-n", tostring(opts.limit) }) end
    -- Git --follow walks rename identity backwards; combining --reverse
    -- with it loses later commits after the rename. Reverse only the result.
    local query_opts = vim.tbl_extend("force", opts, { reverse = false })
    if range and range ~= "" then args[#args + 1] = range end
    vim.list_extend(args, { "--", opts.path })
    original_list(range, root, query_opts, function(err, commits)
      if err or not commits or #commits == 0 then callback(err, commits); return end
      vim.schedule(function()
        require("codediff.core.git.runner").run_async(args, { cwd = root }, function(path_err, output)
          if path_err then callback(path_err); return end
          local records = path_records(output)
          for _, entry in ipairs(commits) do
            local record = records[entry.hash]
            if not record or not record.file_path or record.file_path == "" then
              callback("Missing literal history path for commit " .. entry.hash)
              return
            end
            entry.file_path, entry.old_path = record.file_path, record.old_path
          end
          if opts.reverse then
            for i = 1, math.floor(#commits / 2) do
              commits[i], commits[#commits + 1 - i] = commits[#commits + 1 - i], commits[i]
            end
          end
          callback(nil, commits)
        end)
      end)
    end)
  end
  local function comparison(view, file)
    local selected = file or view.data.current_selection
    if view.name == "history" and selected and not selected.old_path then
      for _, entry in ipairs(view.data.commits or {}) do
        if entry.hash == selected.commit_hash and entry.file_path == selected.path and entry.old_path then
          selected = vim.tbl_extend("force", selected, { old_path = entry.old_path })
          break
        end
      end
    end
    return original_comparison(view, selected)
  end
  local function get_commit_files(hash, root, callback)
    query_files({
      "diff-tree", "--root", "--no-commit-id", "--name-status", "-z", "-r", "-M", hash,
    }, root, callback)
  end
  local function get_diff_revisions(first, second, root, callback, pathspec)
    query_files(vim.list_extend({ "diff", "--name-status", "-z", "-M", first, second, "--" }, pathspec or {}), root, function(err, files)
      callback(err, not err and { unstaged = files, staged = {} } or nil)
    end)
  end
  local function get_diff_staged(revision, root, callback, pathspec)
    query_files(vim.list_extend({ "diff", "--cached", "--name-status", "-z", "-M", revision, "--" }, pathspec or {}), root, function(err, files)
      callback(err, not err and { unstaged = {}, staged = files, conflicts = {} } or nil)
    end)
  end
  local function get_diff_revision(revision, root, callback, pathspec)
    query_files(vim.list_extend({ "diff", "--name-status", "-z", "-M", revision, "--" }, pathspec or {}), root, function(err, files)
      if err then callback(err); return end
      local result = { unstaged = files, staged = {} }
      local mode = require("codediff.config").options.explorer.untracked
      if mode == "no" then callback(nil, result); return end
      local args = { "ls-files", "--others", "--exclude-standard", "-z" }
      if mode == "normal" then args[#args + 1] = "--directory" end
      args[#args + 1] = "--"
      vim.list_extend(args, pathspec or {})
      vim.schedule(function()
        require("codediff.core.git.runner").run_async(args, { cwd = root, no_optional_locks = true }, function(untracked_err, output)
          if not untracked_err then
            for _, path in ipairs(vim.split(output, "\0", { plain = true, trimempty = true })) do
              files[#files + 1] = { path = path, status = "??" }
            end
          end
          callback(nil, result)
        end)
      end)
    end)
  end
  installed = {}
  local function patch(target, key, replacement)
    installed[#installed + 1] = { target = target, key = key, original = target[key], replacement = replacement }
    target[key] = replacement
  end
  for _, target in ipairs({ git, history }) do patch(target, "get_commit_list", get_commit_list) end
  for _, target in ipairs({ git, repository }) do patch(target, "get_relative_path", get_relative_path) end
  for _, target in ipairs({ git, revision }) do patch(target, "resolve_path_at_revision", resolve_path_at_revision) end
  for _, target in ipairs({ git, changes }) do
    patch(target, "get_commit_files", get_commit_files)
    patch(target, "get_diff_revision", get_diff_revision)
    patch(target, "get_diff_revisions", get_diff_revisions)
    patch(target, "get_diff_staged", get_diff_staged)
  end
  patch(panel, "comparison", comparison)
end

function M.disable()
  if not installed then return end
  for _, item in ipairs(installed) do
    if item.target[item.key] == item.replacement then item.target[item.key] = item.original end
  end
  installed = nil
end

function M.status()
  return { applied = installed ~= nil }
end

return M
