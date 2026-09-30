local t = require("tests.harness")
local cfg = t.bootstrap()
local fixture = require("tests.helpers.git_review_fixture")
local plugin = vim.fn.stdpath("data") .. "/lazy/codediff.nvim"

local function commit(f, parents, message)
  local tree = vim.trim(f.git({ "write-tree" }))
  local args = { "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit-tree", tree }
  for _, parent in ipairs(parents) do vim.list_extend(args, { "-p", parent }) end
  vim.list_extend(args, { "-m", message })
  local hash = vim.trim(f.git(args))
  f.git({ "update-ref", "HEAD", hash })
  return hash
end

local function child(f, body)
  local before_head = f.git({ "rev-parse", "HEAD" })
  local before_index = f.git({ "write-tree" })
  local before_content = f.read()
  local script = string.format([=[
vim.opt.rtp:prepend(%q)
vim.opt.rtp:append(%q)
vim.cmd.cd(%q)
vim.env.VSCODE_DIFF_NO_AUTO_INSTALL = "1"
vim.env.CODEDIFF_WATCHER_NO_AUTO_INSTALL = "1"
local spec = dofile(%q .. "/lua/plugins/codediff.lua")[1]
require("codediff").setup(spec.opts)
require("workarounds.codediff.history_paths").apply()
vim.cmd("runtime plugin/codediff.lua")
assert(require("codediff.core.diff").get_version() == require("codediff.version").VERSION)
local review = require("utils.git_review")
local lifecycle = require("codediff.ui.lifecycle")
local root = %q
local function session()
  return lifecycle.get_session(vim.api.nvim_get_current_tabpage())
end
local function lines(buf)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return nil end
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end
local function rendered(original, modified)
  assert(vim.wait(10000, function()
    local s = session()
    return s and vim.deep_equal(lines(s.original_bufnr), original) and vim.deep_equal(lines(s.modified_bufnr), modified)
  end, 20), "full diff content mismatch: " .. vim.inspect(session() and {
    original = lines(session().original_bufnr), modified = lines(session().modified_bufnr),
    left = session().original, right = session().modified,
  }))
  assert(require("codediff.config").options.diff.compact == false)
end
local function close()
  assert(lifecycle.close(), "review did not close")
  assert(vim.wait(2000, function() return session() == nil end, 20))
end
]=], cfg, plugin, f.root, cfg, f.root) .. body
  script = "local ok, err = xpcall(function()\n" .. script
    .. "\nprint('GIT_HISTORY_NATIVE_OK')\nend, debug.traceback)\n"
    .. "if not ok then io.stderr:write(err); vim.cmd('cquit 1') else vim.cmd('qa!') end"
  local result = vim.system({ vim.v.progpath, "--headless", "-u", "NONE", "-i", "NONE", "-c", "lua " .. script },
    { text = true, timeout = 45000 }):wait()
  t.assert_eq(result.code, 0, result.stderr)
  t.assert_contains((result.stdout or "") .. (result.stderr or ""), "GIT_HISTORY_NATIVE_OK")
  t.assert_eq(f.git({ "rev-parse", "HEAD" }), before_head)
  t.assert_eq(f.git({ "write-tree" }), before_index)
  t.assert_eq(f.read(), before_content)
end

if vim.fn.isdirectory(plugin) == 0 then
  t.skip("CodeDiff native history and revision navigation", "Installed CodeDiff is required", { native = true })
else
  t.describe("git_review_history: installed CodeDiff full-file navigation", function()
    t.it("file history follows rename and renders the old path before the rename", function()
      fixture.with_repo(function(f)
        f.baseline("base\nunchanged context\ntail\n")
        local base = vim.trim(f.git({ "rev-parse", "HEAD" }))
        f.write("before rename\nunchanged context\ntail\n")
        f.git({ "add", "--", f.path })
        local previous = commit(f, { base }, "edit original filename")
        local old_path = f.path
        f.path = "renamed 中文 file.txt"
        f.git({ "mv", "--", old_path, f.path })
        local rename = commit(f, { previous }, "rename file")
        f.write("after rename\nunchanged context\ntail\n")
        f.git({ "add", "--", f.path })
        local latest = commit(f, { rename }, "edit renamed file")
        child(f, string.format([=[
vim.cmd.edit(vim.fn.fnameescape(root .. "/" .. %q))
assert(vim.fn.filereadable(vim.api.nvim_buf_get_name(0)) == 1, "edit path: " .. vim.api.nvim_buf_get_name(0))
local ctx = review.context()
local rel = require("codediff.core.git").get_relative_path(ctx.file, ctx.root)
assert(rel == vim.fn.fnamemodify(ctx.file, ":t"), "short/long root mismatch: " .. rel)
review.history(true)
rendered({"before rename", "unchanged context", "tail"}, {"after rename", "unchanged context", "tail"})
local s = session()
assert(s.panel.name == "history")
local commits = s.panel.data.commits
assert(#commits == 4, "rename-follow missed history: " .. vim.inspect(commits))
assert(commits[1].hash == %q and commits[2].hash == %q and commits[3].hash == %q)
assert(commits[3].file_path == %q, "pre-rename path lost: " .. vim.inspect(commits[3]))
require("codediff.ui.history").navigate_next_commit(s.panel.view)
rendered({"before rename", "unchanged context", "tail"}, {"before rename", "unchanged context", "tail"})
require("codediff.ui.history").navigate_next_commit(session().panel.view)
rendered({"base", "unchanged context", "tail"}, {"before rename", "unchanged context", "tail"})
assert(session().modified.relative == %q, "old revision opened under the current filename")
close()
local function commits_for(range, opts)
  local done, result, failure = false
  require("codediff.core.git").get_commit_list(range, root, opts, function(err, value)
    done, failure, result = true, err, value
  end)
  assert(vim.wait(5000, function() return done end, 20), "history query timed out")
  assert(not failure, failure)
  return result
end
local relative = vim.fn.fnamemodify(ctx.file, ":t")
local limited = commits_for("", {path = relative, limit = 2, no_merges = true})
assert(#limited == 2 and limited[1].hash == commits[1].hash, "limit: " .. vim.inspect(limited))
local ranged = commits_for(commits[3].hash .. "..HEAD", {path = relative, reverse = true, no_merges = true})
assert(#ranged == 2 and ranged[1].hash == commits[2].hash and ranged[2].hash == commits[1].hash, "reverse range: " .. vim.inspect(ranged))
local line_history = commits_for("", {path = relative, line_range = {1, 1}, limit = 1, no_merges = true})
assert(#line_history == 1 and line_history[1].hash == commits[1].hash and line_history[1].file_path == relative, "line range: " .. vim.inspect(line_history))
review.history(false)
rendered({"before rename", "unchanged context", "tail"}, {"after rename", "unchanged context", "tail"})
assert(session().panel.name == "history" and session().panel.data.file_path == nil)
close()
]=], f.path, latest, rename, previous, old_path, old_path))
      end)
    end)

    t.it("two refs and three-dot ranges render distinct left sides and merge review selects a parent", function()
      fixture.with_repo(function(f)
        f.baseline("base\nunchanged context\ntail\n")
        local base = vim.trim(f.git({ "rev-parse", "HEAD" }))
        f.write("left\nunchanged context\ntail\n")
        f.git({ "add", "--", f.path })
        local left = commit(f, { base }, "left branch")
        f.git({ "update-ref", "refs/heads/review-left", left })
        f.write("right\nunchanged context\ntail\n")
        f.git({ "add", "--", f.path })
        local right = commit(f, { base }, "right branch")
        f.git({ "update-ref", "refs/heads/review-right", right })
        f.write("merged\nunchanged context\ntail\n")
        f.git({ "add", "--", f.path })
        local merge = commit(f, { left, right }, "merge branches")
        child(f, string.format([=[
vim.cmd.edit(vim.fn.fnameescape(root .. "/review.txt"))
review.compare("review-left", "review-right", {root = root, path = "review.txt"})
rendered({"left", "unchanged context", "tail"}, {"right", "unchanged context", "tail"})
close()
vim.ui.input = function(_, cb) cb("review-left...review-right") end
review.prompt_range()
rendered({"base", "unchanged context", "tail"}, {"right", "unchanged context", "tail"})
assert(session().original_revision == %q, "three-dot did not compare from merge base")
close()
local choices, selected = nil, false
vim.ui.select = function(items, _, cb)
  choices = items
  assert(items[1] == %q and items[2] == %q, vim.inspect(items))
  selected = true
  cb(items[2])
end
review.commit(%q, {root = root, path = "review.txt"})
rendered({"right", "unchanged context", "tail"}, {"merged", "unchanged context", "tail"})
assert(selected and #choices == 2)
close()
local cancelled = false
vim.ui.select = function(_, _, cb) cancelled = true; cb(nil) end
local tabs = #vim.api.nvim_list_tabpages()
review.commit(%q, {root = root})
assert(vim.wait(5000, function() return cancelled end, 20))
assert(session() == nil and #vim.api.nvim_list_tabpages() == tabs, "cancel opened a review")
]=], base, left, right, merge, merge))
      end)
    end)

    t.it("Unicode ref, staged and working comparisons preserve rename sides and path filters", function()
      fixture.with_repo(function(f)
        f.path = "原始 file.txt"
        f.baseline("base\nunchanged context\ntail\n")
        local base = vim.trim(f.git({ "rev-parse", "HEAD" }))
        local old_path = f.path
        f.path = "改名 file.txt"
        f.git({ "mv", "--", old_path, f.path })
        local rename = commit(f, { base }, "rename Unicode file")
        f.write("staged\nunchanged context\ntail\n")
        f.git({ "add", "--", f.path })
        f.write("working\nunchanged context\ntail\n")
        vim.fn.writefile({ "untracked" }, f.root .. "/未跟踪 file.txt")
        vim.fn.mkdir(f.root .. "/新增目录", "p")
        vim.fn.writefile({ "nested" }, f.root .. "/新增目录/child.txt")
        child(f, string.format([=[
review.compare(%q, %q, {root = root})
rendered({"base", "unchanged context", "tail"}, {"base", "unchanged context", "tail"})
assert(session().original.relative == %q and session().modified.relative == %q)
close()
review.open({root = root, path = %q, staged = true})
rendered({"base", "unchanged context", "tail"}, {"staged", "unchanged context", "tail"})
close()
review.compare(%q, nil, {root = root, path = %q})
rendered({"base", "unchanged context", "tail"}, {"working", "unchanged context", "tail"})
close()
local git = require("codediff.core.git")
local function query(method, args)
  local done, value, failure = false
  args[#args + 1] = function(err, result) failure, value, done = err, result, true end
  git[method](unpack(args))
  assert(vim.wait(5000, function() return done end, 20))
  assert(not failure, failure)
  return value
end
local all = query("get_diff_revision", {"HEAD", root})
local found = {}
for _, file in ipairs(all.unstaged) do found[file.path] = file.status end
assert(found[%q] == "M" and found["未跟踪 file.txt"] == "??", vim.inspect(all))
local done, filtered
git.get_diff_revision("HEAD", root, function(err, result) assert(not err, err); filtered, done = result, true end, {"未跟踪 file.txt"})
assert(vim.wait(5000, function() return done end, 20))
assert(#filtered.unstaged == 1 and filtered.unstaged[1].path == "未跟踪 file.txt")
require("codediff.config").options.explorer.untracked = "no"
local tracked = query("get_diff_revision", {"HEAD", root})
assert(#tracked.unstaged == 1 and tracked.unstaged[1].status == "M")
require("codediff.config").options.explorer.untracked = "normal"
local normal = query("get_diff_revision", {"HEAD", root})
local collapsed = {}
for _, file in ipairs(normal.unstaged) do collapsed[file.path] = file.status end
assert(collapsed["新增目录/"] == "??" and not collapsed["新增目录/child.txt"], vim.inspect(normal))
local renamed = query("get_commit_files", {"HEAD", root})
assert(#renamed == 1 and renamed[1].status == "R" and renamed[1].old_path == "原始 file.txt" and renamed[1].path == "改名 file.txt")
local staged = query("get_diff_staged", {"HEAD^", root})
assert(#staged.staged == 1 and staged.staged[1].status == "R" and staged.staged[1].old_path == "原始 file.txt" and staged.staged[1].path == "改名 file.txt")
vim.cmd.edit(vim.fn.fnameescape(root .. "/改名 file.txt"))
vim.cmd("CodeDiff file HEAD^ HEAD")
rendered({"base", "unchanged context", "tail"}, {"base", "unchanged context", "tail"})
assert(session().original.relative == "原始 file.txt" and session().modified.relative == "改名 file.txt")
assert(session().panel == nil, "native single-file command unexpectedly opened an explorer")
close()
local adapter = require("workarounds.codediff.history_paths")
local patched = git.get_diff_revision
adapter.apply()
assert(git.get_diff_revision == patched and adapter.status().applied)
adapter.disable()
assert(git.get_diff_revision ~= patched and not adapter.status().applied)
]=], base, rename, old_path, f.path, f.path, rename, f.path, f.path))
      end)
    end)
  end)
end
