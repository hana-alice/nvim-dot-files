local M = {}

function M.with_repo(fn)
  local root = vim.fn.tempname()
  vim.fn.mkdir(root, "p")
  local f = { root = root, path = "review.txt", buffers = {} }
  function f.git(args)
    local result = vim.system(vim.list_extend({ "git", "-c", "core.autocrlf=false", "-C", root }, args), { text = false }):wait()
    assert(result.code == 0, result.stderr)
    return result.stdout
  end
  function f.write(data)
    local file = assert(io.open(root .. "/" .. f.path, "wb"))
    file:write(data)
    file:close()
  end
  function f.read()
    local file = assert(io.open(root .. "/" .. f.path, "rb"))
    local data = file:read("*a")
    file:close()
    return data
  end
  function f.baseline(data)
    f.write(data)
    f.git({ "add", "--", f.path })
    local tree = vim.trim(f.git({ "write-tree" }))
    local commit = vim.system({ "git", "-C", root, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit-tree", tree }, { stdin = "fixture\n" }):wait()
    assert(commit.code == 0, commit.stderr)
    f.git({ "update-ref", "HEAD", vim.trim(commit.stdout) })
  end
  function f.buffer(data, real)
    local buf = vim.api.nvim_create_buf(false, true)
    f.buffers[#f.buffers + 1] = buf
    if real then
      vim.api.nvim_buf_set_name(buf, root .. "/" .. f.path)
      vim.bo[buf].buftype = ""
      vim.bo[buf].bufhidden = "hide"
    end
    local lines = vim.split(data:gsub("\r\n", "\n"), "\n", { plain = true })
    if lines[#lines] == "" then table.remove(lines) end
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].fileformat = data:find("\r\n", 1, true) and "dos" or "unix"
    vim.bo[buf].endofline = data:sub(-1) == "\n"
    vim.bo[buf].modified = false
    return buf
  end
  f.git({ "init", "-q" })
  local ok, err = xpcall(function() fn(f) end, debug.traceback)
  for _, buf in ipairs(f.buffers) do
    if vim.api.nvim_buf_is_valid(buf) then vim.api.nvim_buf_delete(buf, { force = true }) end
  end
  assert(root ~= "" and root ~= vim.fn.getcwd())
  vim.fn.delete(root, "rf")
  if not ok then error(err) end
end

function M.with_actions(f, original, modified, changes, fn)
  local plugin_modules = {}
  for name, value in pairs(package.loaded) do
    if name == "codediff" or name:sub(1, 9) == "codediff." then plugin_modules[name] = value end
  end
  local names = { "codediff.ui.lifecycle", "codediff.ui.refresh", "codediff.ui.view.actions.hunk" }
  local saved = {}
  for _, name in ipairs(names) do saved[name] = package.loaded[name]; package.loaded[name] = nil end
  local a, b = f.buffer(original), f.buffer(modified, true)
  local tab = vim.api.nvim_get_current_tabpage()
  local session = { git_root = f.root, original_revision = ":0", original = { relative = f.path }, modified = { relative = f.path }, stored_diff_result = { changes = changes } }
  package.loaded[names[1]] = { get_session = function() return session end, get_buffers = function() return a, b end }
  f.refreshes = {}
  package.loaded[names[2]] = { buffer_changed = function() end, request = function(_, event) f.refreshes[#f.refreshes + 1] = event end }
  local ctx = { tabpage = tab, original_bufnr = a, modified_bufnr = b }
  vim.api.nvim_set_current_buf(b)
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  local confirm, notify = vim.fn.confirm, vim.notify
  local system = vim.system
  f.pending = 0
  vim.system = function(argv, opts, callback)
    local owned = opts and opts.cwd == f.root
    for _, arg in ipairs(argv) do if arg == f.root then owned = true end end
    if not callback or not owned then return system(argv, opts, callback) end
    f.pending = f.pending + 1
    local ok, handle = pcall(system, argv, opts, function(result)
      local callback_ok, callback_err = pcall(callback, result)
      -- Run after the scheduled Git continuation, not merely process exit.
      vim.schedule(function() f.pending = f.pending - 1 end)
      if not callback_ok then error(callback_err) end
    end)
    if not ok then f.pending = f.pending - 1; error(handle) end
    return handle
  end
  function f.idle()
    local safety = package.loaded["workarounds.codediff.safe_mutations"]
    return f.pending == 0 and (not safety or safety.status().pending == 0)
  end
  local codediff = package.loaded.codediff
  package.loaded.codediff = package.loaded.codediff or {}
  vim.fn.confirm = function() return 1 end
  f.messages = {}
  vim.notify = function(message) f.messages[#f.messages + 1] = message end
  local ok, err = xpcall(function() fn(require(names[3]), ctx, session, a, b) end, debug.traceback)
  local drained = vim.wait(5000, f.idle, 10)
  local safety = package.loaded["workarounds.codediff.safe_mutations"]
  if safety then safety.disable() end
  package.loaded.codediff = codediff
  vim.fn.confirm, vim.notify, vim.system = confirm, notify, system
  for _, name in ipairs(names) do package.loaded[name] = saved[name] end
  for name in pairs(package.loaded) do
    if name == "codediff" or name:sub(1, 9) == "codediff." then package.loaded[name] = plugin_modules[name] end
  end
  for _, buf in ipairs({ a, b }) do
    if vim.api.nvim_buf_is_valid(buf) then vim.api.nvim_buf_delete(buf, { force = true }) end
  end
  if not ok then error(err) end
  assert(drained, "Git fixture ended before its async actions completed")
end

return M
