local t = require("tests.harness")
local cfg = t.bootstrap()
local adapter = require("workarounds.neogit.codediff_v4")

local function isolated(fn)
  local names = { "neogit", "neogit.lib.git", "neogit.integrations.codediff", "utils.git_review" }
  local saved, calls, messages = {}, {}, {}
  for _, name in ipairs(names) do saved[name] = package.loaded[name] end
  local old_notify = vim.notify
  local original = function() return "upstream" end
  adapter.disable()
  package.loaded.neogit = {}
  package.loaded["neogit.lib.git"] = { repo = { worktree_root = "C:/fixture/review" } }
  package.loaded["neogit.integrations.codediff"] = { open = original }
  package.loaded["utils.git_review"] = {}
  for _, name in ipairs({ "open", "commit", "compare", "neogit" }) do
    package.loaded["utils.git_review"][name] = function(...)
      calls[#calls + 1] = { action = name, args = { ... } }
      return true
    end
  end
  vim.notify = function(msg) messages[#messages + 1] = msg end
  local ok, err = xpcall(function() fn(calls, messages, original) end, debug.traceback)
  adapter.disable()
  vim.notify = old_notify
  for _, name in ipairs(names) do package.loaded[name] = saved[name] end
  if not ok then error(err) end
end

t.describe("Neogit CodeDiff v4 bridge", function()
  t.it("keeps staged selection and special paths in the Neogit repository", function()
    isolated(function(calls)
      adapter.open("staged", "目录/with space.lua")
      t.assert_eq(calls[1].action, "open")
      t.assert_eq(calls[1].args[1].root, "C:/fixture/review")
      t.assert_eq(calls[1].args[1].path, "目录/with space.lua")
      t.assert_true(calls[1].args[1].staged)
      adapter.open("conflict", { "conflict.lua" })
      t.assert_eq(calls[2].args[1].path, "conflict.lua")
      t.assert_false(calls[2].args[1].staged)
    end)
  end)

  t.it("delegates single commits without constructing an invalid root parent", function()
    isolated(function(calls)
      adapter.open("recent", "abcdef12 Initial commit")
      t.assert_eq(calls[1].action, "commit")
      t.assert_eq(calls[1].args[1], "abcdef12")
      adapter.open("stashes", "stash@{2}: WIP on main")
      t.assert_eq(calls[2].args[1], "stash@{2}")
    end)
  end)

  t.it("distinguishes two-dot comparison and three-dot merge-base comparison", function()
    isolated(function(calls)
      adapter.open("range", " main .. topic ")
      t.assert_eq(calls[1].action, "compare")
      t.assert_eq(calls[1].args[1], "main")
      t.assert_eq(calls[1].args[2], "topic")
      t.assert_nil(calls[1].args[3].merge_base)
      adapter.open("range", "main...")
      t.assert_eq(calls[2].args[2], "HEAD")
      t.assert_true(calls[2].args[3].merge_base)
      adapter.open("log", { "111aaa", "222bbb", "333ccc" })
      t.assert_eq(calls[3].args[1], "111aaa")
      t.assert_eq(calls[3].args[2], "333ccc")
    end)
  end)

  t.it("rejects missing repository and invalid selections before opening review", function()
    isolated(function(calls, messages)
      adapter.open("range", "..main")
      adapter.open("recent", "not a commit")
      adapter.open("log", {})
      package.loaded["neogit.lib.git"].repo.worktree_root = ""
      adapter.open("worktree")
      t.assert_eq(#calls, 0)
      t.assert_eq(#messages, 4)
    end)
  end)

  t.it("refreshes Neogit once on return to its buffer", function()
    isolated(function()
      local buf = vim.api.nvim_create_buf(false, true)
      local refreshes = 0
      adapter.open("unstaged", "review.lua", { on_close = {
        handle = buf,
        fn = function() refreshes = refreshes + 1 end,
      } })
      t.assert_eq(refreshes, 0)
      vim.api.nvim_exec_autocmds("BufEnter", { buffer = buf })
      vim.api.nvim_exec_autocmds("BufEnter", { buffer = buf })
      vim.api.nvim_buf_delete(buf, { force = true })
      t.assert_eq(refreshes, 1)
    end)
  end)

  t.it("installs idempotently and restores the original integration", function()
    isolated(function(_, _, original)
      local bridge = package.loaded["neogit.integrations.codediff"]
      adapter.apply()
      adapter.apply()
      t.assert_eq(bridge.open, adapter.open)
      t.assert_true(adapter.status().applied)
      adapter.disable()
      t.assert_eq(bridge.open, original)
      t.assert_false(adapter.status().applied)
      package.loaded.neogit = nil
      adapter.apply()
      t.assert_eq(bridge.open, original)
    end)
  end)

  t.it("keeps a single root-aware entry with CodeDiff and Snacks integration", function()
    isolated(function(calls)
      local spec = assert(loadfile(cfg .. "/lua/plugins/neogit.lua"))()[1]
      t.assert_eq(#spec.keys, 1)
      spec.keys[1][2]()
      t.assert_eq(calls[1].action, "neogit")
      t.assert_eq(spec.opts.diff_viewer, "codediff")
      t.assert_true(spec.opts.integrations.codediff)
      t.assert_true(spec.opts.integrations.snacks)
      t.assert_false(spec.opts.integrations.diffview)
      t.assert_false(spec.opts.integrations.telescope)
      t.assert_false(vim.tbl_contains(spec.dependencies, "nvim-telescope/telescope.nvim"))
    end)
  end)
end)

local function delayed_return_fixture(fn)
  local review = require("utils.git_review")
  local context, session = review.context, review.session
  local names = { "neogit", "neogit.buffers.status", "codediff.ui.lifecycle", "codediff.ui.refresh" }
  local saved, tabs, sessions = {}, {}, {}
  for _, name in ipairs(names) do saved[name] = package.loaded[name] end
  local previous = vim.api.nvim_get_current_tabpage()
  local function newtab()
    vim.cmd("tabnew")
    local tab = vim.api.nvim_get_current_tabpage()
    tabs[#tabs + 1] = tab
    return tab
  end
  local origin = newtab()
  local third = newtab()
  vim.api.nvim_set_current_tabpage(origin)
  local current_session = { git_root = "C:/fixture" }
  sessions[origin] = current_session
  local manager, buffer, refreshes
  refreshes = 0
  review.context = function() return { root = "C:/fixture" } end
  review.session = function() return sessions[vim.api.nvim_get_current_tabpage()] end
  package.loaded["codediff.ui.lifecycle"] = { get_session = function(tab) return sessions[tab] end }
  package.loaded["codediff.ui.refresh"] = { request = function() refreshes = refreshes + 1 end }
  package.loaded.neogit = { open = function() manager = newtab(); buffer = vim.api.nvim_get_current_buf() end }
  package.loaded["neogit.buffers.status"] = { instance = function() return { buffer = { handle = buffer } } end }
  local ok, err = xpcall(function()
    review.neogit()
    fn(origin, third, manager, buffer, sessions, function() return refreshes end)
  end, debug.traceback)
  if buffer then pcall(vim.api.nvim_del_augroup_by_name, "GitReviewNeogit" .. buffer) end
  for _, tab in ipairs(tabs) do
    if vim.api.nvim_tabpage_is_valid(tab) then vim.api.nvim_set_current_tabpage(tab); vim.cmd("tabclose!") end
  end
  vim.api.nvim_set_current_tabpage(previous)
  review.context, review.session = context, session
  for _, name in ipairs(names) do package.loaded[name] = saved[name] end
  if not ok then error(err) end
end

t.describe("Neogit delayed return intent", function()
  t.it("does not steal focus when a third tab is selected before the scheduled close return", function()
    delayed_return_fixture(function(_, third, _, buffer, _, refreshes)
      vim.api.nvim_exec_autocmds("BufWipeout", { buffer = buffer })
      vim.api.nvim_set_current_tabpage(third)
      vim.wait(20, function() return false end, 5)
      t.assert_eq(vim.api.nvim_get_current_tabpage(), third)
      t.assert_eq(refreshes(), 0)
    end)
  end)
  t.it("checks the original session identity before moving tabs or windows", function()
    delayed_return_fixture(function(origin, _, manager, buffer, sessions, refreshes)
      vim.api.nvim_exec_autocmds("BufWipeout", { buffer = buffer })
      sessions[origin] = { git_root = "C:/different-review" }
      vim.wait(20, function() return false end, 5)
      t.assert_eq(vim.api.nvim_get_current_tabpage(), manager)
      t.assert_eq(refreshes(), 0)
    end)
  end)
end)

local lazy = vim.fn.stdpath("data") .. "/lazy"
if vim.fn.isdirectory(lazy .. "/neogit") == 0 or vim.fn.isdirectory(lazy .. "/plenary.nvim") == 0
    or vim.fn.isdirectory(lazy .. "/codediff.nvim") == 0 then
  t.skip("Neogit native status and root commit", "Installed Neogit, Plenary and CodeDiff are required", { native = true })
else
  t.describe("Neogit installed-plugin integration", function()
    t.it("opens real fixture status and root commit through the pinned integration", function()
      require("tests.helpers.git_review_fixture").with_repo(function(f)
        f.baseline("base\n")
        f.write("changed\n")
        local script = string.format([[
vim.opt.rtp:prepend(%q)
for _, name in ipairs({ "neogit", "plenary.nvim", "snacks.nvim", "codediff.nvim" }) do
  vim.opt.rtp:append(%q .. "/" .. name)
end
vim.cmd.cd(%q)
local spec = assert(loadfile(%q .. "/lua/plugins/neogit.lua"))()[1]
spec.opts.remember_settings = false
spec.config(nil, spec.opts)
assert(require("neogit.config").get_diff_viewer() == "codediff")
assert(require("neogit.config").check_integration("snacks"))
assert(require("neogit.integrations.codediff").open == require("workarounds.neogit.codediff_v4").open)
for _, name in ipairs({ "commit", "stash", "rebase", "log", "branch" }) do
  assert(type(require("neogit.popups." .. name).create) == "function", name)
end
require("neogit").open({ cwd = %q })
assert(vim.wait(10000, function() return vim.bo.filetype == "NeogitStatus" end, 20), "status did not open")
local actual_root, expected_root = vim.uv.fs_realpath(require("neogit.lib.git").repo.worktree_root), vim.uv.fs_realpath(%q)
assert(actual_root == expected_root, "root: " .. actual_root .. " expected: " .. expected_root)
vim.env.VSCODE_DIFF_NO_AUTO_INSTALL = "1"
vim.env.CODEDIFF_WATCHER_NO_AUTO_INSTALL = "1"
require("codediff").setup({ diff = { compact = false } })
vim.cmd("runtime plugin/codediff.lua")
local native = require("codediff.core.diff")
assert(native.get_version() == require("codediff.version").VERSION)
local origin = vim.api.nvim_get_current_tabpage()
local refreshes = 0
require("neogit.integrations.codediff").open("commit", "HEAD", { on_close = {
  handle = vim.api.nvim_get_current_buf(), fn = function() refreshes = refreshes + 1 end,
} })
local lifecycle = require("codediff.ui.lifecycle")
assert(vim.wait(10000, function() return lifecycle.get_session(vim.api.nvim_get_current_tabpage()) ~= nil end, 20), "root diff not opened")
local session = lifecycle.get_session(vim.api.nvim_get_current_tabpage())
assert(session.panel and session.panel.name == "explorer", "missing v4 panel")
assert(session.original_revision == "4b825dc642cb6eb9a060e54bf8d69288fbee4904", "root parent is not empty tree")
assert(session.modified_revision and #session.modified_revision == 40, "root commit did not resolve")
assert(vim.wait(10000, function()
  local buf = lifecycle.get_session(vim.api.nvim_get_current_tabpage()).modified_bufnr
  return buf and vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == "base"
end, 20), "root commit content was not rendered")
assert(lifecycle.close())
vim.api.nvim_set_current_tabpage(origin)
assert(refreshes == 1, "Neogit refresh callback not preserved")
require("neogit").close()
print("NEOGIT_NATIVE_OK")
vim.cmd("qa!")
]], cfg, lazy, f.root, cfg, f.root, f.root)
        script = "local ok, err = xpcall(function()\n" .. script
          .. "\nend, debug.traceback); if not ok then io.stderr:write(err); vim.cmd('cquit 1') end"
        local result = vim.system({ vim.v.progpath, "--headless", "-u", "NONE", "-i", "NONE", "-c", "lua " .. script },
          { text = true, timeout = 20000 }):wait()
        t.assert_eq(result.code, 0, result.stderr)
        t.assert_contains((result.stdout or "") .. (result.stderr or ""), "NEOGIT_NATIVE_OK")
        t.assert_eq(f.read(), "changed\n")
        t.assert_eq(f.git({ "show", ":review.txt" }), "base\n")
      end)
    end)
    t.it("returns from cancelled management and a real commit to the original review across repositories", function()
      local fixture = require("tests.helpers.git_review_fixture")
      fixture.with_repo(function(f)
        fixture.with_repo(function(other)
          f.baseline("base\n")
          f.write("staged\n")
          f.git({ "add", "--", f.path })
          f.write("working\n")
          f.git({ "config", "user.name", "Fixture" })
          f.git({ "config", "user.email", "fixture@example.invalid" })
          f.git({ "config", "commit.gpgsign", "false" })
          other.baseline("other\n")
          local other_head = other.git({ "rev-parse", "HEAD" })
          local script = string.format([[
vim.opt.rtp:prepend(%q)
for _, name in ipairs({ "neogit", "plenary.nvim", "snacks.nvim", "codediff.nvim" }) do vim.opt.rtp:append(%q .. "/" .. name) end
local root, other = %q, %q
vim.cmd.cd(other)
local spec = assert(loadfile(%q .. "/lua/plugins/neogit.lua"))()[1]
spec.opts.remember_settings = false
spec.config(nil, spec.opts)
vim.env.VSCODE_DIFF_NO_AUTO_INSTALL = "1"
vim.env.CODEDIFF_WATCHER_NO_AUTO_INSTALL = "1"
require("codediff").setup({ diff = { compact = false } })
vim.cmd("runtime plugin/codediff.lua")
local review, lifecycle = require("utils.git_review"), require("codediff.ui.lifecycle")
review.open({ root = root, path = "review.txt" })
assert(vim.wait(10000, function() return review.session() ~= nil end, 20), "review did not open")
local origin = vim.api.nvim_get_current_tabpage()
assert(vim.wait(10000, function()
  local s = review.session()
  local line = s and s.modified_bufnr and vim.api.nvim_buf_get_lines(s.modified_bufnr, 0, 1, false)[1]
  return line == "working" or line == "staged"
end, 20), "review did not render: " .. vim.inspect({
  original = review.session().original, modified = review.session().modified,
  lines = review.session().modified_bufnr and vim.api.nvim_buf_get_lines(review.session().modified_bufnr, 0, -1, false),
  panel = review.session().panel and review.session().panel.data,
}))
local function manage()
  vim.cmd.lcd(other)
  review.neogit("commit")
  assert(vim.wait(10000, function() return vim.bo.filetype == "NeogitPopup" end, 20), "commit popup did not open")
  assert(vim.uv.fs_realpath(require("neogit.lib.git").repo.worktree_root) == vim.uv.fs_realpath(root), "wrong commit repository")
end
local function git(args)
  local result = vim.system(vim.list_extend({ "git", "-C", root }, args), { text = true }):wait()
  assert(result.code == 0, result.stderr)
  return result.stdout
end
local before = git({ "rev-parse", "HEAD" })
manage()
require("neogit.lib.popup").instance:close()
assert(vim.wait(5000, function() return vim.bo.filetype == "NeogitStatus" end, 20))
require("neogit").close()
assert(vim.wait(5000, function() return vim.api.nvim_get_current_tabpage() == origin end, 20), "cancel did not return")
assert(git({ "rev-parse", "HEAD" }) == before, "cancel created commit")
assert(git({ "show", ":review.txt" }) == "staged\n", "cancel changed index")
manage()
require("neogit.lib.popup").instance:close()
assert(vim.wait(5000, function() return vim.bo.filetype == "NeogitStatus" end, 20))
local done = false
require("plenary.async").void(function()
  require("neogit.popups.commit.actions").commit({ get_arguments = function() return { "--message=Review fixture commit" } end })
  done = true
end)()
assert(vim.wait(15000, function() return done and vim.api.nvim_get_current_tabpage() == origin end, 20), "commit did not return")
assert(git({ "rev-parse", "HEAD" }) ~= before, "no commit created")
assert(git({ "show", "HEAD:review.txt" }) == "staged\n", "wrong committed content")
assert(git({ "show", ":review.txt" }) == "staged\n", "working data unexpectedly staged")
assert(lifecycle.get_session(origin), "review was closed")
local committed = vim.trim(git({ "rev-parse", "HEAD" }))
review.neogit("reflog")
assert(vim.wait(10000, function() return vim.bo.filetype == "NeogitReflogView" end, 20), "HEAD reflog did not open")
local reflog = require("neogit.buffers.reflog_view").instance
assert(reflog.header == "Reflog for HEAD" and #reflog.entries > 0)
assert(reflog.entries[1].oid == committed, "reflog belongs to another repository")
assert(reflog.entries[1].ref_subject == "Review fixture commit", "real commit missing from reflog")
reflog:close()
require("neogit").close()
assert(vim.wait(5000, function() return vim.api.nvim_get_current_tabpage() == origin end, 20))
assert(vim.trim(git({ "rev-parse", "HEAD" })) == committed, "reflog performed a checkout")
print("NEOGIT_HANDOFF_OK")
vim.cmd("qa!")
]], cfg, lazy, f.root, other.root, cfg)
          script = "local ok, err = xpcall(function()\n" .. script
            .. "\nend, debug.traceback); if not ok then io.stderr:write(err); vim.cmd('cquit 1') end"
          local result = vim.system({ vim.v.progpath, "--headless", "-u", "NONE", "-i", "NONE", "-c", "lua " .. script },
            { text = true, timeout = 45000 }):wait()
          t.assert_eq(result.code, 0, result.stderr)
          t.assert_contains((result.stdout or "") .. (result.stderr or ""), "NEOGIT_HANDOFF_OK")
          t.assert_eq(f.read(), "working\n")
          t.assert_eq(other.git({ "rev-parse", "HEAD" }), other_head)
          t.assert_eq(other.read(), "other\n")
        end)
      end)
    end)
    t.it("reports unborn and empty HEAD reflogs without opening an invalid popup", function()
      for _, born in ipairs({ false, true }) do
        require("tests.helpers.git_review_fixture").with_repo(function(f)
        if born then f.baseline("base\n") end
        local script = string.format([[
vim.opt.rtp:prepend(%q)
for _, name in ipairs({ "neogit", "plenary.nvim", "snacks.nvim", "codediff.nvim" }) do vim.opt.rtp:append(%q .. "/" .. name) end
vim.cmd.cd(%q)
local spec = assert(loadfile(%q .. "/lua/plugins/neogit.lua"))()[1]
spec.opts.remember_settings = false
spec.config(nil, spec.opts)
local messages = {}
local expected = %q
vim.notify = function(message) messages[#messages + 1] = tostring(message) end
require("utils.git_review").neogit("reflog")
assert(vim.wait(10000, function()
  for _, message in ipairs(messages) do if message:find(expected, 1, true) then return true end end
end, 20), vim.inspect(messages))
assert(vim.bo.filetype == "NeogitStatus")
assert(not require("neogit.buffers.reflog_view").is_open())
for _, message in ipairs(messages) do assert(not message:find("Invalid popup", 1, true), message) end
print("NEOGIT_UNBORN_REFLOG_OK")
vim.cmd("qa!")
]], cfg, lazy, f.root, cfg, born and "HEAD reflog 为空" or "尚无提交")
        script = "local ok, err = xpcall(function()\n" .. script
          .. "\nend, debug.traceback); if not ok then io.stderr:write(err); vim.cmd('cquit 1') end"
        local result = vim.system({ vim.v.progpath, "--headless", "-u", "NONE", "-i", "NONE", "-c", "lua " .. script },
          { text = true, timeout = 20000 }):wait()
        t.assert_eq(result.code, 0, result.stderr)
        t.assert_contains((result.stdout or "") .. (result.stderr or ""), "NEOGIT_UNBORN_REFLOG_OK")
        t.assert_eq(f.git({ "status", "--porcelain" }), "")
        end)
      end
    end)
  end)
end
