local t = require("tests.harness")
local cfg = t.bootstrap()
local fixture = require("tests.helpers.git_review_fixture")
local plugin = vim.fn.stdpath("data") .. "/lazy/codediff.nvim"

local function child(f, code)
  local index = f.git({ "ls-files", "--stage", "-z" })
  local script = string.format([=[
vim.opt.rtp:prepend(%q)
vim.opt.rtp:append(%q)
vim.cmd.cd(%q)
vim.env.VSCODE_DIFF_NO_AUTO_INSTALL = "1"
vim.env.CODEDIFF_WATCHER_NO_AUTO_INSTALL = "1"
local spec = dofile(%q .. "/lua/plugins/codediff.lua")[1]
spec.config(nil, spec.opts)
vim.cmd("runtime plugin/codediff.lua")
local guard_path = %q .. "/lua/workarounds/codediff/binary_files.lua"
if vim.fn.filereadable(guard_path) == 1 then require("workarounds.codediff.binary_files").apply() end
local review, lifecycle = require("utils.git_review"), require("codediff.ui.lifecycle")
local root, path = %q, %q
local messages = {}
vim.notify = function(message) messages[#messages + 1] = message end
local function session() return lifecycle.get_session(vim.api.nvim_get_current_tabpage()) end
local function lines(buf) return buf and vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_lines(buf, 0, -1, false) or {} end
local function selected()
  local s = session()
  return s and s.panel and s.panel.data.current_selection
end
]=], cfg, plugin, f.root, cfg, cfg, f.root, f.path) .. code
  script = "local ok, err = xpcall(function()\n" .. script
    .. "\nprint('GIT_BINARY_NATIVE_OK')\nend, debug.traceback)\n"
    .. "if not ok then io.stderr:write(err); vim.cmd('cquit 1') else vim.cmd('qa!') end"
  local result = vim.system({ vim.v.progpath, "--headless", "-u", "NONE", "-i", "NONE", "-c", "lua " .. script },
    { text = true, timeout = 30000 }):wait()
  t.assert_eq(result.code, 0, result.stderr)
  t.assert_contains((result.stdout or "") .. (result.stderr or ""), "GIT_BINARY_NATIVE_OK")
  t.assert_eq(f.git({ "ls-files", "--stage", "-z" }), index)
end

if vim.fn.isdirectory(plugin) == 0 then
  t.skip("CodeDiff binary and conflict integration", "Installed CodeDiff is required", { native = true })
else
  t.describe("git_review_binary: installed CodeDiff binary and conflict UI", function()
    t.it("tracked NUL binary stays in Changes with an explicit read-only notice", function()
      fixture.with_repo(function(f)
        f.path = "asset.bin"
        f.baseline("old\0binary\n")
        f.write("new\0binary\n")
        child(f, [=[
review.open({root = root, path = path})
assert(vim.wait(8000, function() return session() and session().git_review_binary end, 20), "binary file silently entered text diff")
local s = session()
assert(selected().path == path, "binary selection missing")
local found
for _, file in ipairs(s.panel.data.status_result.unstaged) do if file.path == path then found = file end end
assert(found and found.line_stats.binary, "binary status missing from Changes")
local notice = table.concat(lines(s.modified_bufnr), "\n")
assert(notice:find("Binary file", 1, true) and notice:find(path, 1, true), notice)
assert(vim.bo[s.modified_bufnr].buftype == "nofile" and not vim.bo[s.modified_bufnr].modifiable)
local blocked
require("workarounds.codediff.safe_mutations").check({tabpage = vim.api.nvim_get_current_tabpage()}, function(err) blocked = err end)
assert(vim.wait(2000, function() return blocked ~= nil end, 20), "binary hunk action was not rejected")
assert(tostring(blocked):lower():find("binary", 1, true), blocked)
local actions = require("codediff.ui.view.actions.hunk")
local ctx = {tabpage = vim.api.nvim_get_current_tabpage(), original_bufnr = s.original_bufnr, modified_bufnr = s.modified_bufnr}
for _, name in ipairs({"stage_hunk", "unstage_hunk", "discard_hunk"}) do
  local before = #messages
  actions[name](ctx)
  assert(#messages == before + 1 and messages[#messages]:lower():find("binary", 1, true), name .. ": " .. vim.inspect(messages))
end
require("codediff.ui.refresh").request(vim.api.nvim_get_current_tabpage(), "manual")
vim.wait(250)
assert(table.concat(lines(s.modified_bufnr), "\n"):find("Binary file", 1, true), "refresh erased binary notice")
local git = require("codediff.core.git")
local function mutate(name)
  local done, failure = false
  git[name](root, path, function(err) failure, done = err, true end)
  assert(vim.wait(5000, function() return done end, 20), name .. " timed out")
  assert(not failure, failure)
end
mutate("stage_file")
local blob = vim.system({"git", "-C", root, "show", ":" .. path}, {text = false}):wait()
assert(blob.code == 0 and blob.stdout == "new\0binary\n", "whole-file binary stage failed")
mutate("unstage_file")
assert(lifecycle.close())
]=])
        t.assert_eq(f.read(), "new\0binary\n")
      end)
    end)

    t.it("untracked NUL detection uses a scratch notice and preserves a dirty real buffer", function()
      fixture.with_repo(function(f)
        f.baseline("base\n")
        f.path = "untracked.bin"
        f.write("new\0binary\n")
        child(f, [=[
vim.cmd.edit(vim.fn.fnameescape(root .. "/" .. path))
local real = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(real, 0, -1, false, {"unsaved user content"})
review.open({root = root, path = path})
assert(vim.wait(8000, function() return session() and session().git_review_binary end, 20), "untracked binary entered text diff")
assert(selected().status == "??")
assert(session().modified_bufnr ~= real)
assert(vim.bo[real].modified and vim.deep_equal(lines(real), {"unsaved user content"}), "binary notice overwrote the real buffer")
assert(lifecycle.close())
]=])
        t.assert_eq(f.read(), "new\0binary\n")
      end)
    end)

    t.it("deleted binary and attribute-marked binary remain explicit without file bytes", function()
      fixture.with_repo(function(f)
        f.path = "attribute.dat"
        vim.fn.writefile({ "*.dat -diff" }, f.root .. "/.gitattributes")
        f.git({ "add", "--", ".gitattributes" })
        f.baseline("opaque but NUL-free\n")
        f.write("changed opaque data\n")
        child(f, [=[
review.open({root = root, path = path})
assert(vim.wait(8000, function() return session() and session().git_review_binary end, 20), "Git binary attribute ignored")
assert(table.concat(lines(session().modified_bufnr), "\n"):find("Binary file", 1, true))
assert(lifecycle.close())
]=])
        assert(vim.uv.fs_unlink(f.root .. "/" .. f.path))
        child(f, [=[
review.open({root = root, path = path})
assert(vim.wait(8000, function() return session() and session().git_review_binary end, 20), "deleted binary rendered as text")
assert(selected().status == "D")
assert(table.concat(lines(session().modified_bufnr), "\n"):find(path, 1, true))
assert(lifecycle.close())
]=])
        t.assert_false(vim.uv.fs_stat(f.root .. "/" .. f.path) ~= nil)
      end)
    end)

    t.it("unmerged index appears in Conflicts with complete ours, theirs and Result buffers", function()
      fixture.with_repo(function(f)
        f.baseline("base\nunchanged context\ntail\n")
        local base = vim.trim(f.git({ "rev-parse", "HEAD:" .. f.path }))
        f.write("ours\nunchanged context\ntail\n")
        local ours = vim.trim(f.git({ "hash-object", "-w", "--", f.path }))
        f.write("theirs\nunchanged context\ntail\n")
        local theirs = vim.trim(f.git({ "hash-object", "-w", "--", f.path }))
        local conflict = "<<<<<<< ours\nours\n=======\ntheirs\n>>>>>>> theirs\nunchanged context\ntail\n"
        f.write(conflict)
        f.git({ "update-index", "--force-remove", "--", f.path })
        local entries = {}
        for i, hash in ipairs({ base, ours, theirs }) do entries[#entries + 1] = "100644 " .. hash .. " " .. i .. "\t" .. f.path .. "\n" end
        local result = vim.system({ "git", "-C", f.root, "update-index", "--index-info" }, { stdin = table.concat(entries) }):wait()
        t.assert_eq(result.code, 0, result.stderr)
        child(f, [=[
review.open({root = root, path = path})
assert(vim.wait(8000, function()
  local s = session()
  return s and s.merge and s.result_bufnr and vim.api.nvim_buf_is_valid(s.result_bufnr)
    and #lines(s.original_bufnr) == 3 and #lines(s.modified_bufnr) == 3
end, 20), "conflict full-file buffers did not load")
local s = session()
assert(#s.panel.data.status_result.conflicts == 1 and selected().group == "conflicts")
local a, b = lines(s.original_bufnr), lines(s.modified_bufnr)
assert((a[1] == "ours" and b[1] == "theirs") or (a[1] == "theirs" and b[1] == "ours"))
assert(a[2] == "unchanged context" and a[3] == "tail" and b[2] == "unchanged context" and b[3] == "tail")
local result = lines(s.result_bufnr)
assert(result[#result - 1] == "unchanged context" and result[#result] == "tail", vim.inspect(result))
assert(not s.git_review_binary)
vim.fn.confirm = function(_, _, default) assert(default == 2); return 2 end
assert(not lifecycle.close(), "cancel discarded merge Result")
assert(session() == s)
vim.fn.confirm = function() return 1 end
assert(lifecycle.close())
]=])
        t.assert_eq(f.read(), conflict)
      end)
    end)

    t.it("historical text ignores binary working bytes and a stale prefix cannot replace a newer file", function()
      fixture.with_repo(function(f)
        f.baseline("base text\ncontext\n")
        f.write("new text\ncontext\n")
        f.git({ "add", "--", f.path })
        local tree = vim.trim(f.git({ "write-tree" }))
        local commit = vim.trim(f.git({ "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit-tree", tree, "-p", "HEAD", "-m", "text revision" }))
        f.git({ "update-ref", "HEAD", commit })
        f.write("binary\0working\n")
        local file = assert(io.open(f.root .. "/A.bin", "wb")); file:write("A\0binary\n"); file:close()
        vim.fn.writefile({ "B text" }, f.root .. "/B.txt")
        child(f, [=[
review.compare("HEAD^", "HEAD", {root = root, path = path})
assert(vim.wait(8000, function()
  local s = session()
  return s and lines(s.original_bufnr)[1] == "base text" and lines(s.modified_bufnr)[1] == "new text"
end, 20), "text revisions were classified from binary working bytes")
assert(not session().git_review_binary)
assert(lifecycle.close())
review.open({root = root, path = path})
assert(vim.wait(8000, function() return session() and session().git_review_binary end, 20))
local s, tab = session(), vim.api.nvim_get_current_tabpage()
local make_path = require("codediff.core.path")
local a = {original = make_path.empty(), modified = make_path.make_ref("A.bin", s.git_root), single_side = "modified", git_root = s.git_root}
local b = {original = make_path.empty(), modified = make_path.make_ref("B.txt", s.git_root), single_side = "modified", git_root = s.git_root}
local open, read = vim.uv.fs_open, vim.uv.fs_read
local owned, delayed = {}, nil
vim.uv.fs_open = function(name, flags, mode, callback)
  if not callback then return open(name, flags, mode) end
  return open(name, flags, mode, function(err, fd)
    if name == a.modified.absolute and fd then owned[fd] = true end
    callback(err, fd)
  end)
end
vim.uv.fs_read = function(fd, length, offset, callback)
  if not callback or not owned[fd] then return read(fd, length, offset, callback) end
  return read(fd, length, offset, function(err, bytes) delayed = function() callback(err, bytes) end end)
end
local view = require("codediff.ui.view")
view.show(tab, a, false)
assert(vim.wait(5000, function() return delayed ~= nil end, 20))
view.show(tab, b, false)
assert(vim.wait(5000, function() return lines(s.modified_bufnr)[1] == "B text" end, 20))
delayed()
vim.wait(100)
vim.uv.fs_open, vim.uv.fs_read = open, read
assert(lines(s.modified_bufnr)[1] == "B text" and not s.git_review_binary, "stale A callback overwrote B")
assert(lifecycle.close())
]=])
        t.assert_eq(f.read(), "binary\0working\n")
      end)
    end)
  end)
end
