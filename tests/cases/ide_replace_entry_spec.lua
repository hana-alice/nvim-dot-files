local t = require("tests.harness")
local cfg = t.bootstrap()
local lazy_root = vim.fn.stdpath("data") .. "/lazy/"
for _, path in ipairs({
  "LazyVim/lua/lazyvim/plugins/editor.lua",
  "lazy.nvim/lua/lazy/init.lua",
  "grug-far.nvim/plugin/grug-far.lua",
}) do
  if vim.fn.filereadable(lazy_root .. path) ~= 1 then
    t.skip("native delayed replace entry", "installed LazyVim, Lazy and GrugFar are required", { native = true })
    return
  end
end

local child_code = [=[
local cfg, root, scenario = arg[1], arg[2], arg[3]
vim.env.NVIM_UE_PROBE_PATH = root .. "/probe.json"
vim.env.NVIM_UE_LOG_DIR = root .. "/logs"
vim.env.XDG_STATE_HOME = root .. "/state"
vim.env.XDG_CACHE_HOME = root .. "/cache"
vim.opt.rtp:prepend(cfg)
package.path = cfg .. "/lua/?.lua;" .. cfg .. "/lua/?/init.lua;" .. package.path
local installed = vim.fn.stdpath("data") .. "/lazy/"
vim.opt.rtp:prepend(installed .. "lazy.nvim")
vim.opt.loadplugins = true
vim.g.mapleader, vim.g.maplocalleader = " ", "\\"
local inherited = dofile(installed .. "LazyVim/lua/lazyvim/plugins/editor.lua")[1]
inherited.dir = installed .. "grug-far.nvim"
inherited.opts.history = { historyDir = root .. "/grug-history" }
local specs = { inherited }
local override = cfg .. "/lua/plugins/grug-far.lua"
-- The pre-fix run uses the inherited spec alone and catches the actual drift.
if vim.uv.fs_stat(override) then specs[#specs + 1] = dofile(override) end
require("lazy").setup(specs, {
  root = root .. "/plugins", lockfile = root .. "/lock.json", state = root .. "/lazy-state.json",
  install = { missing = false }, checker = { enabled = false }, change_detection = { enabled = false },
  pkg = { enabled = false }, readme = { enabled = false }, performance = { rtp = { reset = false } },
})
dofile(cfg .. "/lua/config/keymaps.lua")
local mode = scenario == "visual" and "x" or "n"
local before = vim.fn.maparg(" sr", mode, false, true)
assert(type(before.callback) == "function", "source replace callback missing")
local source_buf, source_win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
local original = scenario == "visual" and { "alpha beta", "gamma alpha", "alpha gamma" }
  or { "alpha beta", "alphabeta", "second alpha" }
vim.api.nvim_buf_set_lines(source_buf, 0, -1, true, original)
vim.api.nvim_win_set_cursor(source_win, { 1, 0 })
assert(not require("lazy.core.config").plugins["grug-far.nvim"]._.loaded, "Grug loaded before the command")
vim.cmd("GrugFar")
assert(require("lazy.core.config").plugins["grug-far.nvim"]._.loaded, "native command did not load Grug")
assert(vim.fn.exists(":GrugFar") == 2 and vim.fn.exists(":GrugFarWithin") == 2,
  "explicit native commands must remain available")
local after = vim.fn.maparg(" sr", mode, false, true)
assert(after.callback == before.callback, mode .. " replace callback changed after first GrugFar command")
assert(after.desc == before.desc, mode .. " replace description changed after plugin load")
assert(vim.deep_equal(vim.api.nvim_buf_get_lines(source_buf, 0, -1, true), original),
  "opening the explicit replacement tool changed source text")
vim.api.nvim_set_current_win(source_win)
vim.api.nvim_win_set_buf(source_win, source_buf)
if scenario == "visual" then
  vim.cmd("normal! gg0v4l")
  after.callback()
  vim.wait(30)
else after.callback() end
local keys = vim.api.nvim_replace_termcodes("OMEGA<CR>a", true, false, true)
vim.api.nvim_feedkeys(keys, "xt", false)
local expected = scenario == "visual" and { "OMEGA beta", "gamma alpha", "alpha gamma" }
  or { "OMEGA beta", "alphabeta", "second OMEGA" }
assert(vim.deep_equal(vim.api.nvim_buf_get_lines(source_buf, 0, -1, true), expected),
  "native substitute did not keep the requested literal/range behavior")
assert(vim.bo[source_buf].modified, "substitute must remain an unsaved source edit")
vim.api.nvim_feedkeys("u", "xt", false)
assert(vim.deep_equal(vim.api.nvim_buf_get_lines(source_buf, 0, -1, true), original),
  "native u did not restore the source text after substitution")
io.write("REPLACE_ENTRY_NATIVE_OK\n")
]=]

local function native(scenario)
  local parent = vim.env.NVIM_TEST_RUN_ROOT or vim.fn.tempname()
  local root = vim.fs.joinpath(parent, "replace_entry_" .. scenario)
  vim.fn.mkdir(root, "p")
  local script = root .. "/native.lua"
  vim.fn.writefile(vim.split(child_code, "\n", { plain = true }), script)
  local result = vim
    .system({
      vim.v.progpath,
      "-u",
      "NONE",
      "-i",
      "NONE",
      "--headless",
      "-l",
      script,
      cfg,
      root,
      scenario,
    }, { text = true, env = { NVIM_LOG_FILE = root .. "/nvim.log" } })
    :wait(15000)
  vim.fn.delete(root, "rf")
  t.assert_eq(result.code, 0, result.stderr)
  t.assert_contains(result.stdout, "REPLACE_ENTRY_NATIVE_OK")
end

t.describe("replace entry native delayed plugin loading", function()
  t.it("preserves whole-word buffer substitute after the first GrugFar command", function()
    native("normal")
  end)
  t.it("preserves the live visual range substitute after the first GrugFar command", function()
    native("visual")
  end)
end)
