local t = require("tests.harness")
local cfg = t.bootstrap()
local fixture = require("tests.helpers.git_review_fixture")
if vim.fn.isdirectory(vim.fn.stdpath("data") .. "/lazy/codediff.nvim") == 0 or vim.fn.executable("git") ~= 1 then
  t.skip("git review native routing", "CodeDiff checkout or Git unavailable", { native = true })
  return
end

local function child(root, code)
  local script = vim.fn.tempname() .. ".lua"
  local setup = string.format([[
vim.opt.rtp:prepend(%q)
package.path = %q .. '/lua/?.lua;' .. %q .. '/lua/?/init.lua;' .. package.path
local plugin = vim.fn.stdpath('data') .. '/lazy/codediff.nvim'
vim.opt.rtp:prepend(plugin)
vim.env.VSCODE_DIFF_NO_AUTO_INSTALL = '1'
vim.env.CODEDIFF_WATCHER_NO_AUTO_INSTALL = '1'
vim.env.GIT_OPTIONAL_LOCKS = '0'
local spec = dofile(%q .. '/lua/plugins/codediff.lua')[1]
spec.init()
vim.cmd('runtime plugin/codediff.lua')
vim.g.mapleader = ' '
vim.g.maplocalleader = ' '
local root = %q
local errors = {}
vim.notify = function(msg, level) if level and level >= vim.log.levels.WARN then errors[#errors+1] = msg end end
local ok, err = xpcall(function()
  spec.opts.explorer.auto_refresh = false
  spec.config(nil, spec.opts)
  local review = require('utils.git_review')
  local function wait(fn) assert(vim.wait(10000, fn, 10), table.concat(errors, '\n')) end
  %s
  assert(#errors == 0, table.concat(errors, '\n'))
end, debug.traceback)
if not ok then io.stderr:write(tostring(err) .. '\n'); vim.cmd('cquit 1') else print('GIT_REVIEW_OK'); vim.cmd('qa!') end
]], cfg, cfg, cfg, cfg, root, code)
  vim.fn.writefile(vim.split(setup, "\n", { plain = true }), script)
  local result = vim.system({ vim.v.progpath, "--clean", "--headless", "-i", "NONE", "-n",
    "-c", "lua dofile(" .. string.format("%q", script) .. ")" }, { text = true }):wait(20000)
  vim.fn.delete(script)
  t.assert_eq(result.code, 0, result.stderr)
  t.assert_true((result.stdout .. result.stderr):find("GIT_REVIEW_OK", 1, true) ~= nil, result.stderr)
end

t.describe("git review routing", function()
  t.it("content search preserves -G rather than -S or message search", function()
    fixture.with_repo(function(f)
      f.baseline("value = needle + 1\n")
      f.write("value = needle + 2\n")
      f.git({ "add", "--", f.path })
      local tree = vim.trim(f.git({ "write-tree" }))
      local commit = vim.system({ "git", "-C", f.root, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
        "commit-tree", tree, "-p", "HEAD" }, { stdin = "different arithmetic\n" }):wait()
      t.assert_eq(commit.code, 0)
      local hash = vim.trim(commit.stdout)
      f.git({ "update-ref", "HEAD", hash })
      local args = require("utils.git_review").search_args("needle", f.path)
      local output = f.git(args)
      t.assert_true(output:find(hash, 1, true) ~= nil)
      local counted = f.git({ "log", "--format=%H", "-S", "needle", "--", f.path })
      t.assert_true(counted:find(hash, 1, true) == nil)
      t.assert_true(output:find("different arithmetic", 1, true) ~= nil)
    end)
  end)

  t.it("native explorer preserves full files, special paths and untracked coverage", function()
    fixture.with_repo(function(f)
      f.path = "空 格 file.txt"
      local original = {}
      for n = 1, 80 do original[n] = "unchanged " .. n end
      f.baseline(table.concat(original, "\n") .. "\n")
      original[3], original[70] = "first edit", "second edit"
      f.write(table.concat(original, "\n") .. "\n")
      local untracked = assert(io.open(f.root .. "/new file.txt", "wb")); untracked:write("new\n"); untracked:close()
      child(f.root, [[
        review.open({root=root, path='空 格 file.txt'})
        wait(function() local s=review.session(); return s and s.modified.relative=='空 格 file.txt' and s.stored_diff_result and #s.stored_diff_result.changes==2 end)
        local s=review.session()
        assert(vim.api.nvim_buf_line_count(s.original_bufnr)==80)
        assert(vim.api.nvim_buf_line_count(s.modified_bufnr)==80)
        assert(vim.api.nvim_buf_get_lines(s.modified_bufnr,39,40,false)[1]=='unchanged 40')
        assert(s.compact_mode==false)
        local files=s.panel.data.status_result.unstaged
        assert(#files==2, vim.inspect(files))
        local tabs=#vim.api.nvim_list_tabpages()
        review.open({root=root,path='new file.txt'})
        wait(function() return review.session().modified.relative=='new file.txt' end)
        assert(#vim.api.nvim_list_tabpages()==tabs)
        assert(review.context().root==vim.fs.normalize(vim.uv.fs_realpath(root)))
        review.open({root=root,path='空 格 file.txt'})
        wait(function() local current=review.session(); return current.modified.relative=='空 格 file.txt' and current.stored_diff_result and #current.stored_diff_result.changes==2 end)
        s=review.session()
        vim.api.nvim_set_current_win(s.modified_win)
        vim.api.nvim_win_set_cursor(0,{3,0})
        local stage=vim.fn.maparg(' hs','n',false,true).callback
        assert(type(stage)=='function')
        stage()
        wait(function() return review.session().stored_diff_result and #review.session().stored_diff_result.changes==1 end)
        local staged=vim.system({'git','-C',root,'diff','--cached'},{text=true}):wait()
        assert(staged.stdout:find('+first edit',1,true),staged.stdout)
        assert(not staged.stdout:find('+second edit',1,true),staged.stdout)
      ]])
    end)
  end)

  t.it("native renamed/deleted paths remain discoverable without changing index", function()
    fixture.with_repo(function(f)
      f.path = "old 名.txt"
      f.baseline("one\ntwo\n")
      f.git({ "mv", "--", f.path, "new 名.txt" })
      local before = f.git({ "diff", "--cached", "--binary" })
      child(f.root, [[
        review.open({root=root,path='new 名.txt'})
        wait(function() local s=review.session(); return s and s.panel and #s.panel.data.status_result.staged==1 end)
        local s=review.session()
        assert(s.panel.data.status_result.staged[1].path=='new 名.txt',vim.inspect(s.panel.data.status_result))
        assert(review.context({cwd=true}).root~=review.context().root)
      ]])
      t.assert_eq(f.git({ "diff", "--cached", "--binary" }), before)
    end)
  end)

  t.it("whole-repository routing does not reuse a path-filtered native session", function()
    fixture.with_repo(function(f)
      f.baseline("before\n")
      f.write("after\n")
      local extra = assert(io.open(f.root .. "/other.txt", "wb")); extra:write("new\n"); extra:close()
      child(f.root, [[
        require('codediff.commands.handlers.explorer').run(nil,nil,{repo=root},{'review.txt'})
        wait(function() return review.session() and review.session().panel end)
        local filtered=vim.api.nvim_get_current_tabpage()
        assert(review.session().panel.data.pathspec)
        review.open({root=root})
        wait(function() local s=review.session(); return vim.api.nvim_get_current_tabpage()~=filtered and s and s.panel and #s.panel.data.status_result.unstaged==2 end)
        assert(not review.session().panel.data.pathspec)
        assert(vim.api.nvim_tabpage_is_valid(filtered))
      ]])
    end)
  end)

  t.it("linked worktree files keep their own root and index", function()
    fixture.with_repo(function(f)
      f.baseline("base\n")
      local linked = f.root .. "/linked worktree"
      f.git({ "worktree", "add", "--detach", linked, "HEAD" })
      vim.fn.writefile({ "linked change" }, linked .. "/review.txt")
      child(linked, [[
        vim.cmd.edit(vim.fn.fnameescape(root .. '/review.txt'))
        assert(review.context().root==vim.fs.normalize(vim.uv.fs_realpath(root)))
        review.open()
        wait(function() local s=review.session(); return s and s.stored_diff_result and s.stored_diff_result.changes and #s.stored_diff_result.changes==1 end)
        assert(review.session().git_root==vim.fs.normalize(vim.uv.fs_realpath(root)))
        assert(vim.api.nvim_buf_get_lines(review.session().original_bufnr,0,-1,false)[1]=='base')
        assert(vim.api.nvim_buf_get_lines(review.session().modified_bufnr,0,-1,false)[1]=='linked change')
      ]])
      t.assert_eq(f.git({ "show", ":review.txt" }), "base\n")
      t.assert_eq(f.read(), "base\n")
    end)
  end)

  t.it("range inputs reject options and plain arguments preserve spaces", function()
    local review = require("utils.git_review")
    local notify, messages = vim.notify, {}
    vim.notify = function(msg) messages[#messages + 1] = msg end
    review.compare("--output=oops", "HEAD")
    review.commit("HEAD\n--all")
    vim.notify = notify
    t.assert_eq(#messages, 2)
    local args = review.search_args("a b'|;", "file 名.txt")
    t.assert_eq(args[7], "a b'|;")
    t.assert_eq(args[#args], "file 名.txt")
  end)

  t.it("event refresh has no polling timer and native failures never auto-install", function()
    fixture.with_repo(function(f)
      f.baseline("first\n")
      f.write("changed\n")
      child(f.root, [[
        review.open({root=root})
        wait(function() return review.session() and review.session().refresh end)
        local refresh=review.session().refresh
        assert(not refresh.polling and not refresh.poll:is_active())
        local calls=0
        local installer=require('codediff.core.installer.libvscode_diff')
        installer.install=function() calls=calls+1; error('unexpected automatic install') end
        local temp=vim.fn.tempname()
        vim.fn.mkdir(temp,'p')
        require('codediff.core.path').get_plugin_root=function() return temp end
        package.loaded['codediff.core.diff']=nil
        local ok=pcall(require,'codediff.core.diff')
        assert(not ok,'missing library must fail')
        assert(calls==0,'opening a view must not invoke installer')
        vim.fn.delete(temp,'d')
      ]])
    end)
  end)
end)
