local t = require("tests.harness")
local cfg = t.bootstrap()
local fixture = require("tests.helpers.git_review_fixture")
local plugins = vim.fn.stdpath("data") .. "/lazy"
local codediff = plugins .. "/codediff.nvim"
local lazy = plugins .. "/lazy.nvim"
local icons = plugins .. "/mini.icons"

local function child(f, name, body)
  local script = f.root .. "/" .. name .. ".lua"
  vim.fn.writefile(vim.split("local ok, err = xpcall(function()\n" .. body
    .. "\nprint('URI_RESTORE_NATIVE_OK')\nend, debug.traceback)\n"
    .. "if not ok then io.stderr:write(err); vim.cmd('cquit 1') else vim.cmd('qa!') end", "\n"), script)
  local result = vim.system({ vim.v.progpath, "--headless", "-u", "NONE", "-i", "NONE", "-l", script },
    { text = true, timeout = 20000 }):wait()
  t.assert_eq(result.code, 0, result.stderr)
  t.assert_contains((result.stdout or "") .. (result.stderr or ""), "URI_RESTORE_NATIVE_OK")
end

local function restore(f, enabled)
  local index = f.git({ "ls-files", "--stage", "-z" })
  local session = f.root .. "/restore.vim"
  child(f, "save", string.format([=[
vim.opt.rtp:prepend(%q)
vim.opt.rtp:append(%q)
vim.env.VSCODE_DIFF_NO_AUTO_INSTALL = "1"
vim.env.CODEDIFF_WATCHER_NO_AUTO_INSTALL = "1"
require("codediff").setup({ explorer = { auto_refresh = false } })
vim.cmd("runtime plugin/codediff.lua")
local url = require("codediff.core.virtual_file").create_url(%q, ":0", %q)
vim.cmd("edit " .. vim.fn.fnameescape(url))
assert(vim.wait(5000, function() return vim.api.nvim_buf_get_lines(0, 0, 1, false)[1] == "int staged = 7;" end, 10))
assert(vim.bo.filetype == "" and vim.bo.buftype == "nowrite")
vim.opt.sessionoptions = { "buffers", "tabpages", "winsize", "help", "globals", "skiprtp" }
vim.cmd("mksession! " .. vim.fn.fnameescape(%q))
]=], cfg, codediff, f.root, f.path, session))

  child(f, enabled and "restore-fixed" or "restore-control", string.format([=[
vim.opt.rtp:prepend(%q)
vim.opt.rtp:prepend(%q)
vim.go.loadplugins = true
vim.cmd("filetype on")
local spec = dofile(%q .. "/lua/plugins/codediff.lua")[1]
spec.dir = %q
spec.dependencies = { { "nvim-mini/mini.icons", dir = %q } }
local enabled = %s
if not enabled then spec.event = nil end
require("lazy").setup({ spec }, {
  root = %q .. "/lazy-root", lockfile = %q .. "/lazy-lock.json",
  state = %q .. "/lazy-state.json", local_spec = false,
  install = { missing = false }, checker = { enabled = false }, change_detection = { enabled = false },
  rocks = { enabled = false }, pkg = { enabled = false },
  performance = { cache = { enabled = false }, rtp = { reset = false } },
})
local config = require("lazy.core.config")
assert(not config.plugins["codediff.nvim"]._.loaded, "CodeDiff was eagerly loaded")
assert(not package.loaded["codediff.core.virtual_file"], "URI reader is already loaded")
local detected, newfiles = {}, {}
-- A BufReadCmd observer is itself a reader and would mask the original bug.
vim.api.nvim_create_autocmd("FileType", { callback = function(ev)
  if vim.api.nvim_buf_get_name(ev.buf):match("^codediff://") then detected[#detected + 1] = ev.match end
end })
vim.api.nvim_create_autocmd("BufNewFile", { callback = function(ev)
  if vim.api.nvim_buf_get_name(ev.buf):match("^codediff://") then newfiles[#newfiles + 1] = ev.buf end
end })
vim.cmd("source " .. vim.fn.fnameescape(%q))
local buf = vim.api.nvim_get_current_buf()
assert(vim.api.nvim_buf_get_name(buf):match("^codediff://"))
if enabled then
  assert(config.plugins["codediff.nvim"]._.loaded, "session read did not lazy-load CodeDiff")
  assert(vim.wait(5000, function() return vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == "int staged = 7;" end, 10), "Git revision bytes did not load")
  assert(vim.bo[buf].filetype == "" and vim.bo[buf].buftype == "nowrite")
  assert(#detected == 0, "revision fired FileType: " .. vim.inspect(detected))
  assert(#newfiles == 0, "revision was read as a new local file")
else
  assert(not config.plugins["codediff.nvim"]._.loaded)
  assert(vim.bo[buf].filetype == "cpp" and vim.bo[buf].buftype == "")
  assert(vim.tbl_contains(detected, "cpp") and #newfiles == 1, "control failed to reproduce cold session detection")
end
]=], cfg, lazy, cfg, codediff, icons, tostring(enabled), f.root, f.root, f.root, session))
  t.assert_eq(f.git({ "ls-files", "--stage", "-z" }), index, "restoration changed Git index")
  t.assert_eq(f.read(), "int staged = 7;\n", "restoration changed worktree bytes")
end

if vim.fn.isdirectory(codediff) == 0 or vim.fn.isdirectory(lazy) == 0 or vim.fn.isdirectory(icons) == 0 then
  t.skip("git_review_uri_restore native lazy reader", "Installed CodeDiff, lazy.nvim and mini.icons are required", { native = true })
else
  t.describe("git_review_uri_restore: native cold session with real lazy.nvim", function()
    t.it("loads the CodeDiff URI reader before filename detection and reads staged C++ bytes", function()
      fixture.with_repo(function(f)
        f.path = "restore.cpp"
        f.write("int staged = 7;\n")
        f.git({ "add", "--", f.path })
        restore(f, true)
      end)
    end)
    t.it("reproduces FileType cpp without the URI load event as a negative control", function()
      fixture.with_repo(function(f)
        f.path = "restore.cpp"
        f.write("int staged = 7;\n")
        f.git({ "add", "--", f.path })
        restore(f, false)
      end)
    end)
  end)
end
