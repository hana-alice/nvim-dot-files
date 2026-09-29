local t = require("tests.harness")
local cfg = t.bootstrap()
local lazy = vim.fn.stdpath("data") .. "/lazy/codediff.nvim"
if vim.fn.isdirectory(lazy) == 0 then
  t.skip("Git file search confirmation", "Installed CodeDiff is required", { native = true })
  return
end

t.describe("Git search file scope", function()
  t.it("keeps file-only results and both rename sides when confirming historical commits", function()
    require("tests.helpers.git_review_fixture").with_repo(function(f)
      local old, new = "原 名.txt", "新 名.txt"
      f.path = old
      f.baseline("needle = 1\n")
      local initial = vim.trim(f.git({ "rev-parse", "HEAD" }))
      local function commit(message)
        local tree = vim.trim(f.git({ "write-tree" }))
        local result = vim.system({ "git", "-C", f.root, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
          "commit-tree", tree, "-p", "HEAD" }, { stdin = message .. "\n", text = true }):wait()
        t.assert_eq(result.code, 0, result.stderr)
        local hash = vim.trim(result.stdout)
        f.git({ "update-ref", "HEAD", hash })
        return hash
      end
      f.write("needle = 2\n")
      vim.fn.writefile({ "unrelated" }, f.root .. "/other.txt")
      f.git({ "add", "--", old, "other.txt" })
      local changed = commit("Change code and unrelated file")
      f.git({ "mv", "--", old, new })
      local renamed = commit("Rename file")
      f.path = new
      local script = vim.fn.tempname() .. ".lua"
      local code = string.format([[
vim.opt.rtp:prepend(%q)
vim.opt.rtp:append(%q)
vim.env.VSCODE_DIFF_NO_AUTO_INSTALL = "1"
vim.env.CODEDIFF_WATCHER_NO_AUTO_INSTALL = "1"
vim.cmd("runtime plugin/codediff.lua")
local ok, err = xpcall(function()
  local spec = dofile(%q .. "/lua/plugins/codediff.lua")[1]
  spec.config(nil, spec.opts)
  local review, lifecycle = require("utils.git_review"), require("codediff.ui.lifecycle")
  local root, old, new = %q, %q, %q
  local function wait(fn, label) assert(vim.wait(10000, fn, 10), label) end
  local function open(hash, captured)
    local closed = false
    review.confirm_commit({ opts = captured and { git_review_file = root .. "/" .. new } or {},
      close = function() closed = true end, cwd = function() return root end },
      { commit = hash, file = root .. "/" .. new, cwd = root })
    assert(closed)
    wait(function()
      local s = review.session()
      return s and s.modified_revision == hash and s.modified_bufnr and vim.api.nvim_buf_is_valid(s.modified_bufnr)
        and (vim.api.nvim_buf_get_lines(s.modified_bufnr, 0, 1, false)[1] or ""):find("needle", 1, true)
    end, "comparison did not render")
    local s = review.session()
    assert(#s.panel.data.status_result.unstaged == 1, "file search expanded to unrelated commit files")
    return s
  end
  local s = open(%q, true)
  assert(s.original.relative == old and s.modified.relative == old, "pre-rename path was lost")
  assert(vim.api.nvim_buf_get_lines(s.original_bufnr, 0, 1, false)[1] == "needle = 1")
  assert(vim.api.nvim_buf_get_lines(s.modified_bufnr, 0, 1, false)[1] == "needle = 2")
  assert(lifecycle.close())
  s = open(%q, false)
  assert(s.original.relative == old and s.modified.relative == new, "rename sides were not preserved")
  assert(s.panel.data.status_result.unstaged[1].status == "R")
  assert(vim.api.nvim_buf_get_lines(s.original_bufnr, 0, 1, false)[1] == "needle = 2")
  assert(vim.api.nvim_buf_get_lines(s.modified_bufnr, 0, 1, false)[1] == "needle = 2")
  assert(lifecycle.close())
  s = open(%q, true)
  assert(s.modified.relative == old)
  assert((s.original_revision or s.panel.data.base_revision) == "4b825dc642cb6eb9a060e54bf8d69288fbee4904",
    vim.inspect({ revision = s.original_revision, panel = s.panel.data }))
  assert(vim.api.nvim_buf_get_lines(s.modified_bufnr, 0, 1, false)[1] == "needle = 1")
  assert(lifecycle.close())
  vim.cmd.edit(vim.fn.fnameescape(root .. "/" .. new))
  local captured
  local snacks = package.loaded.snacks
  package.loaded.snacks = { picker = {
    git_log = function(opts) captured = opts end,
    git_branches = function(opts) captured = opts end,
  } }
  for _, branch in ipairs({ false, true }) do
    review.pick_file_ref(branch)
    assert(captured and captured.confirm)
    captured.confirm({ close = function() end }, branch and { branch = %q } or { commit = %q })
    wait(function()
      local current = review.session()
      return current and current.original.relative == old and current.modified.relative == new
        and current.stored_diff_result ~= nil
    end, "file reference comparison lost its rename side")
    assert(review.session().panel.data.status_result.unstaged[1].status == "R")
    assert(lifecycle.close())
    vim.cmd.edit(vim.fn.fnameescape(root .. "/" .. new))
  end
  package.loaded.snacks = snacks
  print("GIT_SEARCH_SCOPE_OK")
end, debug.traceback)
if not ok then io.stderr:write(tostring(err) .. "\n"); vim.cmd("cquit 1") else vim.cmd("qa!") end
]], cfg, lazy, cfg, f.root, old, new, changed, renamed, initial, changed, changed)
      vim.fn.writefile(vim.split(code, "\n", { plain = true }), script)
      local result = vim.system({ vim.v.progpath, "--headless", "-u", "NONE", "-i", "NONE",
        "-c", "lua dofile(" .. string.format("%q", script) .. ")" }, { text = true, cwd = f.root, timeout = 30000 }):wait()
      vim.fn.delete(script)
      t.assert_eq(result.code, 0, result.stderr)
      t.assert_contains((result.stdout or "") .. (result.stderr or ""), "GIT_SEARCH_SCOPE_OK")
      t.assert_eq(f.read(), "needle = 2\n")
      t.assert_eq(vim.trim(f.git({ "rev-parse", "HEAD" })), renamed)
      t.assert_eq(f.git({ "diff", "--cached" }), "")
    end)
  end)
end)
