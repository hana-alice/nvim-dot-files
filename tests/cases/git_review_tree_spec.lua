local t = require("tests.harness")
local cfg = t.bootstrap()
local tree_path = vim.fn.stdpath("data") .. "/lazy/codediff.nvim/lua/codediff/ui/lib/tree.lua"
if vim.fn.filereadable(tree_path) == 0 then
  t.skip("CodeDiff large tree", "Installed CodeDiff tree is required", { native = true })
  return
end

local function fixture(fn)
  local Tree = assert(loadfile(tree_path))()
  local saved = package.loaded["codediff.ui.lib.tree"]
  package.loaded["codediff.ui.lib.tree"] = Tree
  local patch = require("workarounds.codediff.large_tree")
  patch.disable()
  local oldwin = vim.api.nvim_get_current_win()
  vim.cmd("botright 12new")
  local win, buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
  vim.bo[buf].buftype, vim.bo[buf].bufhidden = "nofile", "wipe"
  vim.bo[buf].filetype = "codediff-explorer"
  vim.wo[win].wrap = false
  local calls, selected = 0, nil
  local function prepare(node)
    calls = calls + 1
    local segments = {
      { text = "│ " .. node.text, hl = node:get_id() == selected and "DiffAdd" or "Normal" },
      { text = " 改", hl = "DiffChange" },
    }
    return { _segments = segments, content = function() return segments[1].text .. segments[2].text end }
  end
  local children = {}
  for i = 1, 1200 do children[i] = Tree.Node({ text = string.format("文件-%04d.lua", i), data = { path = "目录/文件-" .. i .. ".lua" } }) end
  local group = Tree.Node({ text = "Changes", data = { type = "group" } }, children)
  group:expand()
  local tree = Tree({ bufnr = buf, nodes = { group }, prepare_node = prepare })
  local f = { Tree = Tree, tree = tree, group = group, children = children, buf = buf, win = win, patch = patch,
    reset = function() calls = 0 end, count = function() return calls end,
    select = function(id) selected = id end }
  local ok, err = xpcall(function() fn(f) end, debug.traceback)
  patch.disable()
  if vim.api.nvim_buf_is_valid(buf) then vim.api.nvim_buf_delete(buf, { force = true }) end
  if vim.api.nvim_win_is_valid(oldwin) then vim.api.nvim_set_current_win(oldwin) end
  package.loaded["codediff.ui.lib.tree"] = saved
  if not ok then error(err) end
end

t.describe("CodeDiff large explorer tree", function()
  t.it("preserves viewport formatting and every searchable node while bounding expensive preparation", function()
    fixture(function(f)
      f.tree:render()
      t.assert_eq(f.count(), 1201)
      local baseline = vim.api.nvim_buf_get_lines(f.buf, 0, 10, false)
      f.patch.apply()
      f.reset()
      f.tree:render()
      t.assert_true(f.count() < 100, "prepare_node must be bounded by viewport")
      t.assert_eq(vim.api.nvim_buf_line_count(f.buf), 1201)
      t.assert_eq(vim.inspect(vim.api.nvim_buf_get_lines(f.buf, 0, 10, false)), vim.inspect(baseline))
      t.assert_eq(f.tree:get_node(1201), f.children[1200])
      t.assert_eq(f.children[1200]._line, 1201)
      t.assert_eq(vim.fn.search("文件-1200", "nW"), 1201)
      local marks = vim.api.nvim_buf_get_extmarks(f.buf, f.tree._ns_id, 0, -1, { details = true })
      t.assert_true(#marks < 200)
      t.assert_eq(marks[1][3], 0)
      t.assert_eq(marks[1][4].end_col, #("│ Changes"))
    end)
  end)

  t.it("formats scrolled rows and selection using the original UTF-8 segments", function()
    fixture(function(f)
      f.patch.apply()
      f.tree:render()
      f.reset()
      f.select(f.children[1199]:get_id())
      vim.api.nvim_win_set_cursor(f.win, { 1200, 0 })
      vim.cmd("normal! zz")
      vim.api.nvim_exec_autocmds("WinScrolled", { pattern = tostring(f.win) })
      t.assert_true(vim.wait(1000, function()
        return vim.api.nvim_buf_get_lines(f.buf, 1199, 1200, false)[1] == "│ 文件-1199.lua 改"
      end, 10))
      t.assert_true(f.count() < 100)
      local marks = vim.api.nvim_buf_get_extmarks(f.buf, f.tree._ns_id, { 1199, 0 }, { 1199, -1 }, { details = true })
      t.assert_eq(marks[1][4].hl_group, "DiffAdd")
    end)
  end)

  t.it("keeps collapsed descendants hidden, expands them, and drops removed nodes on refresh", function()
    fixture(function(f)
      f.patch.apply()
      f.tree:render()
      f.group:collapse()
      f.tree:render()
      t.assert_eq(vim.api.nvim_buf_line_count(f.buf), 1)
      t.assert_nil(f.children[1200]._line)
      f.group:expand()
      f.tree:remove_node(f.children[1200]:get_id())
      f.tree:render()
      t.assert_eq(vim.api.nvim_buf_line_count(f.buf), 1200)
      t.assert_nil(f.tree:get_node(f.children[1200]:get_id()))
      local replacement = f.Tree.Node({ text = "replacement.lua" })
      f.tree:set_nodes({ replacement })
      f.reset()
      f.tree:render()
      t.assert_eq(f.count(), 1)
      t.assert_eq(vim.api.nvim_buf_get_lines(f.buf, 0, -1, false)[1], "│ replacement.lua 改")
    end)
  end)

  t.it("leaves small-tree rendering untouched and cleans scheduled callbacks after close", function()
    fixture(function(f)
      f.patch.apply()
      f.patch.apply()
      f.tree:set_nodes({ f.children[1] })
      f.tree:render()
      t.assert_eq(f.count(), 1)
      f.tree:set_nodes({ f.group })
      f.tree:render()
      vim.api.nvim_exec_autocmds("WinScrolled", { pattern = tostring(f.win) })
      vim.api.nvim_buf_delete(f.buf, { force = true })
      vim.wait(30, function() return false end, 10)
      t.assert_eq(f.patch.status().buffers, 0)
    end)
  end)

  t.it("matches the upstream formatter at narrow and wide sizes including CJK filenames", function()
    local oldrtp = vim.o.runtimepath
    vim.opt.rtp:append(vim.fn.stdpath("data") .. "/lazy/codediff.nvim")
    local ok, err = xpcall(function()
      fixture(function(f)
        require("codediff").setup({ explorer = { line_stats = { enabled = false } } })
        local nodes = require("codediff.ui.explorer.nodes")
        local width = 24
        local long_name = "中文超长文件名-这是完整可搜索的后缀.lua"
        f.children[1].text = long_name
        f.children[1].data.path = "目录/" .. long_name
        for _, child in ipairs(f.children) do
          child.data.icon, child.data.icon_color = "", "Normal"
          child.data.status_symbol, child.data.status_color = "M", "DiffChange"
          child.data.group = "unstaged"
        end
        f.tree._prepare_node = function(node) return nodes.prepare_node(node, width, nil, nil) end
        f.tree:render()
        local baseline = vim.api.nvim_buf_get_lines(f.buf, 0, 10, false)
        f.patch.apply()
        f.tree:render()
        t.assert_eq(vim.inspect(vim.api.nvim_buf_get_lines(f.buf, 0, 10, false)), vim.inspect(baseline))
        width = 48
        vim.api.nvim_exec_autocmds("WinResized", {})
        t.assert_true(vim.wait(1000, function()
          return vim.api.nvim_buf_get_lines(f.buf, 1, 2, false)[1] == nodes.prepare_node(f.children[1], width, nil, nil):content()
        end, 10))
        vim.api.nvim_win_set_cursor(f.win, { 1200, 0 })
        vim.cmd("normal! zz")
        vim.api.nvim_exec_autocmds("WinScrolled", { pattern = tostring(f.win) })
        t.assert_true(vim.wait(1000, function()
          return vim.api.nvim_buf_get_lines(f.buf, 1, 2, false)[1] == "目录/" .. long_name
        end, 10))
        t.assert_eq(vim.fn.search("\\V" .. long_name, "bnW"), 2)
      end)
    end, debug.traceback)
    vim.o.runtimepath = oldrtp
    if not ok then error(err) end
  end)

  t.it("builds the complete upstream tree across loop turns and consumes the cache only once", function()
    local oldrtp = vim.o.runtimepath
    local lazy = vim.fn.stdpath("data") .. "/lazy/"
    vim.opt.rtp:append(lazy .. "codediff.nvim")
    vim.opt.rtp:append(lazy .. "mini.icons")
    local git = require("codediff.core.git")
    local original_status = git.get_status_with_line_stats
    local filter = require("codediff.ui.explorer.filter")
    local original_glob = filter.glob_to_pattern
    local conversions = 0
    filter.glob_to_pattern = function(...)
      conversions = conversions + 1
      return original_glob(...)
    end
    local timer
    local ok, err = xpcall(function()
      fixture(function(f)
        require("mini.icons").setup()
        require("mini.icons").mock_nvim_web_devicons()
        require("codediff").setup({ explorer = { view_mode = "tree" } })
        local tree = require("codediff.ui.explorer.tree")
        local result = { unstaged = {}, staged = {}, conflicts = {} }
        local suffix = { ".gen.cpp", ".generated.h", ".json", ".modules", ".uhtmanifest", ".cpp.obj", ".cpp.o", ".pch" }
        for i = 1, 6000 do
          result.unstaged[i] = { path = ("Engine/Intermediate/Module%d/Generated/UHT/Deep%d/File%d%s")
            :format(math.floor(i / 100), i % 20, i, suffix[i % #suffix + 1]), status = "??" }
        end
        result.unstaged[#result.unstaged + 1] = { path = ".git/ignored.txt", status = "??" }
        local function paths(nodes, out)
          out = out or {}
          for _, node in ipairs(nodes) do
            if node.data.path then out[#out + 1] = node.data.path .. ":" .. node.data.group .. ":" .. node.data.status end
            paths(node._children, out)
          end
          return out
        end
        local returned
        local supplied = result
        git.get_status_with_line_stats = function(_, cb) cb(nil, supplied) end
        f.patch.apply()
        local ticks = 0
        timer = vim.uv.new_timer()
        timer:start(0, 1, function() ticks = ticks + 1 end)
        git.get_status_with_line_stats("C:/fixture", function(failure, status)
          t.assert_nil(failure)
          returned = status
        end)
        t.assert_nil(returned, "large status delivery must yield before tree construction")
        t.assert_true(vim.wait(15000, function() return returned ~= nil end, 1))
        t.assert_true(ticks > 2, "tree construction must yield across multiple event-loop turns")
        timer:stop(); timer:close(); timer = nil
        t.assert_eq(returned, result)
        local before_delivery = conversions
        -- panel.new deep-copies panel.data before the real explorer consumes
        -- it. A status-table identity cache misses every production delivery.
        local delivered = vim.deepcopy(result)
        local cached = tree.create_tree_data(delivered, "C:/fixture")
        t.assert_eq(conversions, before_delivery, "copied status delivery rebuilt the tree")
        t.assert_true(before_delivery <= 2, "large-build glob conversion must be job-local and cached")
        local repeated = tree.create_tree_data(result, "C:/fixture")
        t.assert_true(cached ~= repeated, "mutable tree nodes must never be reused")
        t.assert_eq(#paths(cached), 6000)
        t.assert_eq(vim.inspect(paths(cached)), vim.inspect(paths(repeated)))
        t.assert_eq(f.patch.status().builds, 0)
        local small = { unstaged = { result.unstaged[1] }, staged = {} }
        -- A changed tree layout must invalidate an otherwise matching cache.
        returned = nil
        git.get_status_with_line_stats("C:/fixture", function(_, status) returned = status end)
        t.assert_true(vim.wait(15000, function() return returned ~= nil end, 1))
        require("codediff.config").options.explorer.view_mode = "list"
        local flat = tree.create_tree_data(result, "C:/fixture")
        t.assert_eq(#flat[1]._children, 6000)
        t.assert_eq(#tree.create_tree_data(small, "C:/fixture")[1]._children, 1)
        returned = nil
        git.get_status_with_line_stats("C:/fixture", function(_, status) returned = status end)
        t.assert_true(vim.wait(15000, function() return returned ~= nil end, 1))
        local previous_path = returned.unstaged[1].path
        returned.unstaged[1].path = "changed-after-delivery.cpp"
        local changed = tree.create_tree_data(returned, "C:/fixture")
        t.assert_eq(changed[1]._children[1].data.path, "changed-after-delivery.cpp", "a mutated delivery must not reuse stale nodes")
        returned.unstaged[1].path = previous_path
        supplied, returned = small, nil
        git.get_status_with_line_stats("C:/fixture", function(_, status) returned = status end)
        t.assert_eq(returned, small, "small status must keep its original synchronous callback")
        supplied, returned = result, nil
        git.get_status_with_line_stats("C:/fixture", function(_, status) returned = status end)
        t.assert_eq(f.patch.status().builds, 1)
        f.patch.disable()
        t.assert_true(vim.wait(1000, function() return returned ~= nil end, 1))
        t.assert_eq(returned, result, "disabling must not swallow the pending status callback")
        t.assert_eq(f.patch.status().builds, 0)
      end)
    end, debug.traceback)
    if timer then timer:stop(); timer:close() end
    git.get_status_with_line_stats = original_status
    filter.glob_to_pattern = original_glob
    vim.o.runtimepath = oldrtp
    if not ok then error(err) end
  end)

  t.it("last-root close cancels old builds and late status delivery without cancelling a new open", function()
    local oldrtp = vim.o.runtimepath
    vim.opt.rtp:append(vim.fn.stdpath("data") .. "/lazy/codediff.nvim")
    local git = require("codediff.core.git")
    local original_status, original_lifecycle = git.get_status_with_line_stats, package.loaded["codediff.ui.lifecycle"]
    local nodes = require("codediff.ui.explorer.nodes")
    local original_icon, icons = nodes.get_file_icon, 0
    nodes.get_file_icon = function(...)
      icons = icons + 1
      -- A warm cache can finish before this wait observes a yielded build.
      -- Model one slow provider so this close test observes a real yield.
      if icons == 1 then vim.uv.sleep(20) end
      return original_icon(...)
    end
    local extra_tab
    local ok, err = xpcall(function()
      fixture(function(f)
        require("codediff").setup({ explorer = { view_mode = "tree" } })
        local root, other_root = "C:/closing", "C:/remaining"
        local tab = vim.api.nvim_get_current_tabpage()
        local sessions = { [tab] = { git_root = root } }
        package.loaded["codediff.ui.lifecycle"] = { get_session = function(id) return sessions[id] end }
        local pending = {}
        git.get_status_with_line_stats = function(_, cb) pending[#pending + 1] = cb end
        local large = { unstaged = {}, staged = {}, conflicts = {} }
        for i = 1, 6000 do large.unstaged[i] = { path = "Source/File" .. i .. ".cpp", status = "M" } end
        local small = { unstaged = { large.unstaged[1] }, staged = {}, conflicts = {} }
        f.patch.apply()
        local completed, cancelled = 0, 0
        git.get_status_with_line_stats(root, function(failure)
          completed = completed + 1
          if failure then cancelled = cancelled + 1 end
        end)
        pending[1](nil, large)
        t.assert_eq(f.patch.status().builds, 1)
        t.assert_true(vim.wait(5000, function() return icons > 0 and f.patch.status().builds == 1 end, 1),
          "close fixture must reach a yielded build, not only cancel a scheduled start")
        -- Also cover a Git callback that has not arrived when close fires.
        git.get_status_with_line_stats(root, function(failure)
          completed = completed + 1
          if failure then cancelled = cancelled + 1 end
        end)
        local other
        git.get_status_with_line_stats(other_root, function(failure, result)
          t.assert_nil(failure)
          other = result
        end)
        vim.api.nvim_exec_autocmds("User", { pattern = "CodeDiffClose", data = { tabpage = tab } })
        sessions[tab] = nil
        local reopened
        git.get_status_with_line_stats(root, function(failure, result)
          t.assert_nil(failure)
          reopened = result
        end)
        -- The new open begins before old close callbacks get a loop turn.
        pending[4](nil, small)
        pending[2](nil, large)
        pending[3](nil, small)
        t.assert_true(vim.wait(2000, function() return completed == 2 end, 1))
        t.assert_eq(cancelled, 2, "close must complete old callbacks with cancellation exactly once")
        t.assert_eq(other, small)
        t.assert_eq(reopened, small, "a later open must survive the old close")
        t.assert_eq(f.patch.status().builds, 0)
        t.assert_eq(f.patch.status().prepared, 0)
        t.assert_eq(f.patch.status().pending, 0)
        -- A completed but unconsumed tree must be released too.
        sessions[tab] = { git_root = root }
        local delivered
        git.get_status_with_line_stats(root, function(failure, result) t.assert_nil(failure); delivered = result end)
        pending[5](nil, large)
        t.assert_true(vim.wait(10000, function() return delivered ~= nil end, 1))
        t.assert_eq(f.patch.status().prepared, 1)
        vim.api.nvim_exec_autocmds("User", { pattern = "CodeDiffClose", data = { tabpage = tab } })
        sessions[tab] = nil
        vim.wait(20)
        t.assert_eq(f.patch.status().prepared, 0)
        -- Closing one tab must retain work used by another tab of that repo.
        vim.cmd("tabnew")
        extra_tab = vim.api.nvim_get_current_tabpage()
        sessions[tab], sessions[extra_tab] = { git_root = root }, { git_root = root }
        local shared
        git.get_status_with_line_stats(root, function(failure, result) t.assert_nil(failure); shared = result end)
        vim.api.nvim_exec_autocmds("User", { pattern = "CodeDiffClose", data = { tabpage = tab } })
        sessions[tab] = nil
        pending[6](nil, small)
        t.assert_eq(shared, small, "a surviving same-root session must retain its query")
        vim.cmd("tabclose")
        extra_tab = nil
      end)
    end, debug.traceback)
    git.get_status_with_line_stats, package.loaded["codediff.ui.lifecycle"] = original_status, original_lifecycle
    nodes.get_file_icon = original_icon
    if extra_tab and vim.api.nvim_tabpage_is_valid(extra_tab) then
      vim.api.nvim_set_current_tabpage(extra_tab)
      vim.cmd("tabclose!")
    end
    vim.o.runtimepath = oldrtp
    if not ok then error(err) end
  end)

  t.it("builtin large group and folder rows avoid unused file copies while custom formatters retain them", function()
    local oldrtp, deepcopy = vim.o.runtimepath, vim.deepcopy
    vim.opt.rtp:append(vim.fn.stdpath("data") .. "/lazy/codediff.nvim")
    local ok, err = xpcall(function()
      fixture(function(f)
        require("codediff").setup({ explorer = { view_mode = "tree", line_stats = { enabled = true } } })
        local nodes = require("codediff.ui.explorer.nodes")
        local config = require("codediff.config").options.explorer
        local files, individual_stats = {}, {}
        for i = 1, 1200 do
          local stats = { insertions = i, deletions = 1, binary = false }
          files[i] = { path = "目录/File" .. i .. ".cpp", status = "M", group = "unstaged", line_stats = stats }
          individual_stats[stats] = true
        end
        local stats = require("codediff.ui.explorer.line_stats").sum(files)
        f.group.data = { type = "group", label = "Changes", name = "unstaged", files = files, file_count = #files, stats = stats }
        local folder = f.Tree.Node({ text = "目录", data = { type = "directory", name = "目录", dir_path = "目录",
          group = "unstaged", indent_state = { true }, files = files, file_count = #files, stats = stats } })
        local expected_group = nodes.prepare_node(f.group, 42)
        local expected_folder = nodes.prepare_node(folder, 42)
        local copies = 0
        vim.deepcopy = function(value, ...)
          if individual_stats[value] then copies = copies + 1 end
          return deepcopy(value, ...)
        end
        f.patch.apply()
        local actual_group = nodes.prepare_node(f.group, 42)
        local actual_folder = nodes.prepare_node(folder, 42)
        t.assert_eq(vim.inspect(actual_group._segments), vim.inspect(expected_group._segments))
        t.assert_eq(vim.inspect(actual_folder._segments), vim.inspect(expected_folder._segments))
        t.assert_eq(copies, 0, "builtin rows must not copy stats for files they never consume")
        t.assert_eq(f.group.data.files, files)
        t.assert_eq(folder.data.files, files)
        config.formatters.group = function(ctx)
          t.assert_eq(#ctx.files, 1200)
          t.assert_eq(ctx.files[1].stats.insertions, 1)
          ctx.files[1].path = "formatter-local"
          return require("codediff.ui.explorer.formatters.group")(ctx)
        end
        nodes.prepare_node(f.group, 42)
        t.assert_eq(copies, 1200, "custom formatter must retain complete independent file context")
        t.assert_eq(files[1].path, "目录/File1.cpp")
        config.formatters.group = nil
        f.group.data.files = { files[1] }
        copies = 0
        nodes.prepare_node(f.group, 42)
        t.assert_eq(copies, 1, "small groups must retain the original path")
      end)
    end, debug.traceback)
    vim.deepcopy, vim.o.runtimepath = deepcopy, oldrtp
    if not ok then error(err) end
  end)

  t.it("eleven native explorer closes release callbacks, scratch buffers and tree references", function()
    require("tests.helpers.git_review_fixture").with_repo(function(f)
      f.baseline("base\n")
      f.write("changed\n")
      for i = 1, 1001 do vim.fn.writefile({ "content" }, f.root .. "/Extra" .. i .. ".txt") end
      local script = string.format([=[
vim.opt.rtp:prepend(%q)
vim.opt.rtp:append(vim.fn.stdpath('data') .. '/lazy/codediff.nvim')
local spec = dofile(%q .. '/lua/plugins/codediff.lua')[1]
spec.config(nil, spec.opts)
vim.cmd('runtime plugin/codediff.lua')
local root = %q
local review, lifecycle = require('utils.git_review'), require('codediff.ui.lifecycle')
local patch = require('workarounds.codediff.large_tree')
local weak, buffers = setmetatable({}, {__mode = 'v'}), {}
local foreign = vim.api.nvim_create_autocmd('WinResized', {callback = function() end})
local function resize_count()
  local count = 0
  for _, item in ipairs(vim.api.nvim_get_autocmds({event = 'WinResized'})) do
    if type(item.callback) == 'function' then
      local source = debug.getinfo(item.callback, 'S').source:gsub('\\', '/')
      if source:find('/explorer/render.lua', 1, true) then count = count + 1 end
    end
  end
  return count
end
local baseline = resize_count()
for i = 1, 11 do
  review.open({root = root, path = 'review.txt'})
  assert(vim.wait(8000, function()
    local s = review.session()
    return s and s.panel and s.panel.view and s.panel.data.current_selection
  end, 20), 'explorer did not open')
  local s = review.session()
  weak[i], buffers[i] = s.panel.view, s.panel.view.bufnr
  assert(lifecycle.close())
  s = nil
  vim.wait(30)
end
assert(vim.wait(5000, function()
  local jobs = require('workarounds.codediff.threaded_git').status()
  return jobs.active == 0 and jobs.queued == 0
end, 20), 'closed queries did not drain')
vim.wait(100)
collectgarbage('collect'); collectgarbage('collect')
assert(resize_count() == baseline, 'per-explorer WinResized callbacks leaked: ' .. resize_count())
for _, buf in ipairs(buffers) do assert(not vim.api.nvim_buf_is_valid(buf), 'closed explorer scratch buffer retained: ' .. buf) end
local status = patch.status()
assert(status.buffers == 0 and status.builds == 0 and status.pending == 0 and status.prepared == 0, vim.inspect(status))
local foreign_alive = false
for _, item in ipairs(vim.api.nvim_get_autocmds({event = 'WinResized'})) do if item.id == foreign then foreign_alive = true end end
assert(foreign_alive, 'unrelated resize handler was removed')
-- LuaJIT traces can retain constants from the first iterations. The native
-- lifecycle assertions above run with normal JIT; discard trace roots only
-- in this child process to distinguish them from leaked plugin ownership.
jit.flush()
collectgarbage('collect'); collectgarbage('collect')
local retained = {}
for i = 1, 11 do if weak[i] then retained[#retained + 1] = i end end
assert(#retained == 0, 'closed explorer objects remain strongly referenced: ' .. vim.inspect(retained))
print('TREE_CLOSE_NATIVE_OK')
]=], cfg, cfg, f.root)
      script = "local ok, err = xpcall(function()\n" .. script
        .. "\nend, debug.traceback)\nif not ok then io.stderr:write(err); vim.cmd('cquit 1') else vim.cmd('qa!') end"
      local result = vim.system({ vim.v.progpath, "--headless", "-u", "NONE", "-i", "NONE", "-c", "lua " .. script },
        { text = true, timeout = 60000 }):wait()
      t.assert_eq(result.code, 0, result.stderr)
      t.assert_contains((result.stdout or "") .. (result.stderr or ""), "TREE_CLOSE_NATIVE_OK")
    end)
  end)
end)
