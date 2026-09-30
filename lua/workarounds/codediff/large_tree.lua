-- WORKAROUND
-- name: codediff.large_tree
-- scope: codediff
-- issue: internal: CodeDiff v4.0.6 formats and highlights every explorer row synchronously
-- symptom: A 10k-file explorer blocks the main loop while rendering offscreen rows
-- introduced: 2026-09-29
-- removal_condition: pinned CodeDiff bounds explorer formatting and highlights to the viewport
-- owner: hana-alice
-- enabled: true
-- END WORKAROUND

-- Keep every expanded node in the real buffer and every node in the tree's
-- lookup. Only decoration is virtualized; native search and line navigation
-- still see the complete file list. The upstream formatter owns visible text,
-- including custom formatting, Unicode widths, status and selected highlights.
local M = {}
local api = vim.api
local Tree, original
local states = {}
local threshold, margin = 1000, 8
local builder
local jobs = {}
local prepared = {}
local requests = {}
local close_group
local forget

local function release_explorer(lifecycle, session, tab)
  local panel = session and session.panel
  local explorer = panel and panel.name == "explorer" and panel.view
  if not explorer then return end
  local buf = explorer.bufnr
  forget(buf)
  -- v4.0.6 creates an ungrouped resize closure per explorer and never
  -- unregisters it. Match both its pinned source and captured owner.
  for _, item in ipairs(api.nvim_get_autocmds({ event = "WinResized" })) do
    if type(item.callback) == "function" then
      local source = debug.getinfo(item.callback, "S").source:gsub("\\", "/")
      if source:match("/codediff/ui/explorer/render%.lua$") then
        local index = 1
        while true do
          local name, value = debug.getupvalue(item.callback, index)
          if not name then break end
          if name == "explorer" and value == explorer then
            api.nvim_del_autocmd(item.id)
            break
          end
          index = index + 1
        end
      end
    end
  end
  -- The upstream close callback is still disposing mappings and windows.
  -- Delete only its scratch panel after cleanup, never a real file buffer.
  vim.schedule(function()
    if lifecycle.get_session(tab) == session or not buf or not api.nvim_buf_is_valid(buf) then return end
    for _, other_tab in ipairs(api.nvim_list_tabpages()) do
      local other = lifecycle.get_session(other_tab)
      local view = other and other.panel and other.panel.view
      if view and view.bufnr == buf then return end
    end
    if vim.bo[buf].buftype == "nofile" and vim.bo[buf].filetype == "codediff-explorer" then
      api.nvim_buf_delete(buf, { force = true })
    end
  end)
end

local function stop_job(co, job)
  jobs[co] = nil
  if job.timer and not job.timer:is_closing() then job.timer:stop(); job.timer:close() end
end

local function shape(config)
  local explorer = config.options.explorer or {}
  return {
    mode = explorer.view_mode, flatten = explorer.flatten_dirs,
    groups = vim.deepcopy(explorer.visible_groups or { staged = true, unstaged = true, conflicts = true }),
    filter = vim.deepcopy(explorer.file_filter), hide = config.options.diff.hide_merge_artifacts,
  }
end

local function install_builder()
  local ok, tree = pcall(require, "codediff.ui.explorer.tree")
  if not ok then return end
  local nodes = require("codediff.ui.explorer.nodes")
  local git = require("codediff.core.git")
  local config = require("codediff.config")
  local filter = require("codediff.ui.explorer.filter")
  builder = { tree = tree, nodes = nodes, git = git, create = tree.create_tree_data,
    icon = nodes.get_file_icon, prepare = nodes.prepare_node, status = git.get_status_with_line_stats,
    filter = filter, matches = filter.matches_any_pattern, glob = filter.glob_to_pattern }
  local owner = builder
  nodes.prepare_node = function(node, ...)
    local data = node.data or {}
    local kind = data.type == "group" and "group" or data.type == "directory" and "folder"
    local formatters = (config.options.explorer or {}).formatters or {}
    if kind and not formatters[kind] and data.files and #data.files > threshold then
      -- v4's builtin group/folder formatters never consume ctx.files, but
      -- constructing it clones every descendant's stats on every repaint.
      -- Keep the real node intact and all count/stats/indent fields identical.
      -- Custom formatters retain the complete upstream context contract.
      node = setmetatable({ data = vim.tbl_extend("force", data, { files = {} }) }, { __index = node })
    end
    return owner.prepare(node, ...)
  end
  local function checkpoint()
    local job = jobs[coroutine.running()]
    if job and (vim.uv.hrtime() - job.started) > 8e6 then coroutine.yield() end
    return job
  end
  nodes.get_file_icon = function(...)
    checkpoint()
    return owner.icon(...)
  end
  filter.matches_any_pattern = function(...)
    checkpoint()
    return owner.matches(...)
  end
  filter.glob_to_pattern = function(glob)
    local job = jobs[coroutine.running()]
    if not job then return owner.glob(glob) end
    if not job.patterns[glob] then job.patterns[glob] = owner.glob(glob) end
    return job.patterns[glob]
  end
  tree.create_tree_data = function(status, root, base, directory, groups)
    local cached = prepared[root]
    prepared[root] = nil -- Nodes belong to one tree; never share mutable nodes.
    -- panel.new deep-copies status before creating the explorer. Validate the
    -- one-shot delivery's complete content, not table identity alone.
    if cached and not base and not directory and vim.deep_equal(cached.status, status)
        and vim.deep_equal(cached.shape, shape(config))
        and (not groups or vim.deep_equal(groups, cached.shape.groups)) then
      return cached.nodes
    end
    return owner.create(status, root, base, directory, groups)
  end
  git.get_status_with_line_stats = function(root, callback, pathspec)
    local request = { root = root, callback = callback }
    requests[request] = true
    local function deliver(err, status)
      if request.done then return end
      request.done = true
      requests[request] = nil
      callback(err, status)
    end
    return owner.status(root, function(err, status)
      if request.done then return end -- A late Git reply cannot revive a closed view.
      local count = status and (#(status.unstaged or {}) + #(status.staged or {}) + #(status.conflicts or {})) or 0
      if err or count <= threshold or builder ~= owner then return deliver(err, status) end
      local job = { callback = deliver, status = status, root = root, shape = shape(config), patterns = {} }
      local co = coroutine.create(function() return owner.create(status, root) end)
      request.co = co
      jobs[co] = job
      local function step()
        if jobs[co] ~= job then return end
        job.timer = nil
        job.started = vim.uv.hrtime()
        local resumed, result = coroutine.resume(co)
        if not resumed or coroutine.status(co) == "dead" then
          jobs[co] = nil
          if not resumed then return deliver("CodeDiff tree preparation failed: " .. tostring(result), nil) end
          prepared[root] = { nodes = result, status = vim.deepcopy(status), shape = job.shape }
          deliver(nil, status)
        else
          -- A timer turn gives input/I/O a chance between batches; scheduling
          -- the entire builder once would still block for hundreds of ms.
          job.timer = vim.defer_fn(step, 1)
        end
      end
      vim.schedule(step)
    end, pathspec)
  end
  close_group = api.nvim_create_augroup("CodeDiffLargeTreeJobs", { clear = true })
  api.nvim_create_autocmd("User", { group = close_group, pattern = "CodeDiffClose", callback = function(event)
    local lifecycle = package.loaded["codediff.ui.lifecycle"]
    local closing = event.data and event.data.tabpage
    local session = lifecycle and closing and lifecycle.get_session(closing)
    release_explorer(lifecycle, session, closing)
    local root = session and session.git_root
    if not root then return end
    -- Close is emitted before the session is removed. Exclude exactly that
    -- tab, retaining shared-root work required by any other live session.
    for _, tab in ipairs(api.nvim_list_tabpages()) do
      local other = tab ~= closing and lifecycle.get_session(tab)
      if other and other.git_root == root then return end
    end
    prepared[root] = nil
    -- Invalidate owned request objects now, before deferred callbacks run.
    -- New opens have different tokens and cannot be cancelled by this close.
    for request in pairs(requests) do
      if request.root == root then
        request.done = true
        requests[request] = nil
        local job = request.co and jobs[request.co]
        if job then stop_job(request.co, job) end
        vim.schedule(function() request.callback("CodeDiff view closed before tree preparation completed", nil) end)
      end
    end
  end })
end

local function searchable(node)
  return (node.data and node.data.path) or node.text or ""
end

forget = function(buf)
  local state = states[buf]
  if not state then return end
  states[buf] = nil
  pcall(api.nvim_del_augroup_by_id, state.group)
end

local function paint(state)
  local tree, buf = state.tree, state.tree._bufnr
  if states[buf] ~= state or not api.nvim_buf_is_valid(buf) then return end
  local rows = {}
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    if api.nvim_win_is_valid(win) then
      local top = api.nvim_win_call(win, function() return vim.fn.line("w0") end)
      local last = math.min(#tree._line_to_node, top + api.nvim_win_get_height(win) + margin)
      for line = math.max(1, top - margin), last do rows[line] = true end
    end
  end
  local indices = vim.tbl_keys(rows)
  table.sort(indices)
  local readonly = vim.bo[buf].readonly
  vim.bo[buf].readonly, vim.bo[buf].modifiable = false, true
  api.nvim_buf_clear_namespace(buf, tree._ns_id, 0, -1)
  -- Rows leaving the viewport must become complete searchable text again;
  -- keeping yesterday's ellipsis would make search depend on scroll history.
  for line in pairs(state.painted or {}) do
    if not rows[line] and tree._line_to_node[line] then
      api.nvim_buf_set_lines(buf, line - 1, line, false, { searchable(tree._line_to_node[line]) })
    end
  end
  for _, line in ipairs(indices) do
    local node = tree._line_to_node[line]
    local prepared = tree._prepare_node and tree._prepare_node(node)
    local text = prepared and prepared._segments and prepared:content() or node.text or ""
    api.nvim_buf_set_lines(buf, line - 1, line, false, { text })
    local col = 0
    for _, segment in ipairs(prepared and prepared._segments or {}) do
      if segment.hl and segment.hl ~= "" and #segment.text > 0 then
        pcall(api.nvim_buf_set_extmark, buf, tree._ns_id, line - 1, col, {
          end_col = col + #segment.text, hl_group = segment.hl,
        })
      end
      col = col + #segment.text
    end
  end
  state.painted = rows
  vim.bo[buf].modifiable, vim.bo[buf].readonly = false, readonly
end

local function observe(tree)
  local buf = tree._bufnr
  local state = states[buf]
  if state then state.tree = tree return state end
  state = { tree = tree, group = api.nvim_create_augroup("CodeDiffLargeTree" .. buf, { clear = true }) }
  states[buf] = state
  local function schedule()
    if state.pending then return end
    state.pending = true
    vim.schedule(function()
      state.pending = false
      if states[buf] == state then paint(state) end
    end)
  end
  api.nvim_create_autocmd({ "CursorMoved", "BufWinEnter" }, { group = state.group, buffer = buf, callback = schedule })
  api.nvim_create_autocmd({ "WinScrolled", "WinResized" }, { group = state.group, callback = schedule })
  api.nvim_create_autocmd("BufWipeout", { group = state.group, buffer = buf, once = true, callback = function() forget(buf) end })
  return state
end

local function render(self)
  local buf = self._bufnr
  if not buf or not api.nvim_buf_is_valid(buf) or vim.bo[buf].filetype ~= "codediff-explorer" then
    return original(self)
  end
  local visible = {}
  local function collect(nodes)
    for _, node in ipairs(nodes) do
      visible[#visible + 1] = node
      if node._expanded and #node._children > 0 then collect(node._children) end
    end
  end
  collect(self._nodes)
  if #visible <= threshold then
    forget(buf)
    return original(self)
  end
  for _, node in pairs(self._nodes_by_id) do node._line = nil end
  self._line_to_node = visible
  local lines = {}
  for i, node in ipairs(visible) do
    node._line = i
    lines[i] = searchable(node)
  end
  local readonly = vim.bo[buf].readonly
  vim.bo[buf].readonly, vim.bo[buf].modifiable = false, true
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable, vim.bo[buf].readonly = false, readonly
  local state = observe(self)
  state.painted = {}
  paint(state)
end

function M.apply()
  if Tree then return end
  -- Preserve lazy loading during registry discovery.
  local loaded = package.loaded["codediff.ui.lib.tree"]
  if not loaded then return end
  Tree, original = loaded, loaded.render
  Tree.render = render
  install_builder()
end

function M.disable()
  if Tree and Tree.render == render then Tree.render = original end
  if builder then
    builder.tree.create_tree_data = builder.create
    builder.nodes.get_file_icon = builder.icon
    builder.nodes.prepare_node = builder.prepare
    builder.git.get_status_with_line_stats = builder.status
    builder.filter.matches_any_pattern = builder.matches
    builder.filter.glob_to_pattern = builder.glob
    builder = nil
  end
  for co, job in pairs(jobs) do
    stop_job(co, job)
    vim.schedule(function() job.callback(nil, job.status) end)
  end
  if close_group then api.nvim_del_augroup_by_id(close_group); close_group = nil end
  prepared = {}
  for _, buf in ipairs(vim.tbl_keys(states)) do forget(buf) end
  Tree, original = nil, nil
end

function M.status()
  return { applied = Tree ~= nil and Tree.render == render, buffers = vim.tbl_count(states), builds = vim.tbl_count(jobs),
    pending = vim.tbl_count(requests), prepared = vim.tbl_count(prepared) }
end

return M
