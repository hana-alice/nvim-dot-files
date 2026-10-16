local t = require("tests.harness")
local cfg = t.bootstrap()
local installed = vim.fn.stdpath("data") .. "/lazy/"
for _, path in ipairs({
  "LazyVim/lua/lazyvim/config/keymaps.lua",
  "lazy.nvim/lua/lazy/init.lua",
  "snacks.nvim/lua/snacks/init.lua",
}) do
  if vim.fn.filereadable(installed .. path) ~= 1 then
    t.skip("native line movement", "installed LazyVim, Lazy and Snacks are required", { native = true })
    return
  end
end

local setup = [=[
local cfg, installed, root = ...
vim.env.NVIM_UE_PROBE_PATH = root .. "/probe.json"
vim.env.NVIM_UE_LOG_DIR = root .. "/logs"
vim.env.XDG_STATE_HOME = root .. "/state"
vim.env.XDG_CACHE_HOME = root .. "/cache"
for _, path in ipairs({ cfg, installed .. "LazyVim", installed .. "lazy.nvim", installed .. "snacks.nvim" }) do
  vim.opt.rtp:prepend(path)
end
package.path = cfg .. "/lua/?.lua;" .. cfg .. "/lua/?/init.lua;" .. package.path
vim.opt.loadplugins = true
vim.g.mapleader, vim.g.maplocalleader = " ", "\\"
_G.LazyVim = require("lazyvim.util")
require("lazy").setup({ { "folke/snacks.nvim", dir = installed .. "snacks.nvim", lazy = false } }, {
  root = root .. "/plugins", lockfile = root .. "/lock.json", state = root .. "/lazy-state.json",
  install = { missing = false }, checker = { enabled = false }, change_detection = { enabled = false },
  pkg = { enabled = false }, readme = { enabled = false }, performance = { rtp = { reset = false } },
})
require("snacks").setup({ toggle = { enabled = true } })
dofile(installed .. "LazyVim/lua/lazyvim/config/keymaps.lua")
-- Bind the same native expression callbacks used by config/keymaps.lua.
if vim.uv.fs_stat(cfg .. "/lua/utils/line_move.lua") then
  for _, entry in ipairs({ { "<A-j>", 1 }, { "<A-k>", -1 } }) do
    vim.keymap.set({ "n", "i", "x" }, entry[1], function()
      return require("utils.line_move").keys(entry[2])
    end, { expr = true, silent = true })
  end
end
vim.o.clipboard, vim.o.hidden = "", true
return true
]=]

local state = [=[
return {
  mode = vim.api.nvim_get_mode().mode, cursor = vim.api.nvim_win_get_cursor(0), anchor = vim.fn.getpos("v"),
  text = vim.api.nvim_buf_get_lines(0, 0, -1, true), tick = vim.api.nvim_buf_get_changedtick(0),
  unnamed = vim.fn.getreginfo('"'), zero = vim.fn.getreginfo("0"), error = vim.v.errmsg,
}
]=]

local function fixture(body)
  local root = assert(vim.env.NVIM_TEST_RUN_ROOT) .. "/line_move_" .. tostring(vim.uv.hrtime())
  vim.fn.mkdir(root, "p")
  local job = vim.fn.jobstart({ vim.v.progpath, "-u", "NONE", "-i", "NONE", "--headless", "--embed" }, {
    rpc = true,
    env = { NVIM_LOG_FILE = root .. "/nvim.log" },
  })
  t.assert_true(job > 0, "native Neovim could not be started")
  local f = {}
  local input_sequence = 0
  function f.lua(code, ...)
    return vim.rpcrequest(job, "nvim_exec_lua", code, { ... })
  end
  function f.keys(text)
    input_sequence = input_sequence + 1
    local keys = text .. "<Cmd>let g:line_move_input_done = " .. input_sequence .. "<CR>"
    t.assert_eq(vim.rpcrequest(job, "nvim_input", keys), #keys)
    t.assert_true(
      vim.wait(1000, function()
        return f.lua("return vim.g.line_move_input_done") == input_sequence
      end, 5),
      "native input did not finish"
    )
  end
  ---@return {mode:string, cursor:integer[], anchor:integer[], text:string[], tick:integer, unnamed:table, zero:table, error:string}
  function f.snapshot()
    return assert(f.lua(state), "owned native snapshot unavailable")
  end
  function f.source(lines)
    f.keys("<Esc>")
    local path = root .. "/source-" .. tostring(vim.uv.hrtime()) .. ".txt"
    vim.fn.writefile(lines, path)
    f.lua(
      [=[
      vim.cmd.edit(vim.fn.fnameescape(...))
      vim.bo.cindent, vim.bo.shiftwidth = true, 4
      vim.fn.setreg('"', "retained register", "v")
      vim.v.errmsg = ""
    ]=],
      path
    )
  end
  function f.blocked(setup_keys, action)
    f.source({ "alpha", "beta", "gamma", "delta" })
    f.keys(setup_keys)
    local before = f.snapshot()
    f.keys(action)
    t.assert_true(
      vim.deep_equal(f.snapshot(), before),
      "blocked move changed mode, cursor, live selection, text or registers"
    )
    t.assert_eq(f.snapshot().error, "", "blocked move raised an error")
  end
  local ok, err = xpcall(function()
    t.assert_true(f.lua(setup, cfg, installed, root))
    body(f)
  end, debug.traceback)
  pcall(vim.fn.jobstop, job)
  vim.fn.jobwait({ job }, 1000)
  vim.fn.delete(root, "rf")
  if not ok then
    error(err)
  end
end

t.describe("line movement native interaction", function()
  t.it("keeps normal mode at both file boundaries", function()
    fixture(function(f)
      f.blocked("gg2l", "<A-k>")
      f.blocked("G2l", "<A-j>")
    end)
  end)
  t.it("refuses normal count overflow before moving", function()
    fixture(function(f)
      f.blocked("2G2l", "9<A-k>")
      f.blocked("3G2l", "9<A-j>")
    end)
  end)
  for _, selection in ipairs({ "v2l", "V", "<C-v>2l" }) do
    t.it("keeps live selection at boundaries: " .. selection, function()
      fixture(function(f)
        f.blocked("gg0" .. selection .. "j", "<A-k>")
        f.blocked("G0" .. selection .. "k", "<A-j>")
      end)
    end)
  end
  t.it("refuses visual count overflow while retaining selection", function()
    fixture(function(f)
      f.blocked("2GVj", "9<A-k>")
      f.blocked("2G0v2lj", "9<A-j>")
    end)
  end)
  t.it("keeps insert mode and exact cursor at both boundaries", function()
    fixture(function(f)
      f.blocked("gg2li", "<A-k>")
      f.blocked("G2li", "<A-j>")
    end)
  end)
  t.it("moves and reindents with native counts and one undo", function()
    fixture(function(f)
      local lines = { "if (ready) {", "    inside();", "}", "outside();" }
      f.source(lines)
      f.keys("G<A-k>")
      t.assert_true(vim.deep_equal(f.snapshot().text, { "if (ready) {", "    inside();", "    outside();", "}" }))
      f.keys("u")
      t.assert_true(vim.deep_equal(f.snapshot().text, lines), "one u must undo move and reindent")
      f.source({ "one", "two", "three", "four" })
      f.keys("gg2<A-j>")
      t.assert_true(vim.deep_equal(f.snapshot().text, { "two", "three", "one", "four" }))
      f.keys("u")
      t.assert_true(vim.deep_equal(f.snapshot().text, { "one", "two", "three", "four" }))
    end)
  end)
  t.it("moves the live visual range, retains it and undoes once", function()
    fixture(function(f)
      for _, selection in ipairs({ "V", "v2l" }) do
        local lines = { "one", "two", "three", "four", "five" }
        f.source(lines)
        f.keys("ggV<Esc>3G0" .. selection .. "j<A-k>")
        local after = f.snapshot()
        t.assert_true(vim.deep_equal(after.text, { "one", "three", "four", "two", "five" }))
        t.assert_eq(after.mode, selection == "V" and "V" or "v")
        t.assert_eq(math.min(after.anchor[2], after.cursor[1]), 2)
        t.assert_eq(math.max(after.anchor[2], after.cursor[1]), 3)
        f.keys("<Esc>u")
        t.assert_true(vim.deep_equal(f.snapshot().text, lines), "one u must undo the visual move")
      end
    end)
  end)
  t.it("resumes insert mode after a valid reindented move and undoes once", function()
    fixture(function(f)
      local lines = { "if (ready) {", "    inside();", "outside();", "}" }
      f.source(lines)
      f.keys("3G2li<A-k>")
      t.assert_eq(f.snapshot().mode, "i")
      t.assert_true(vim.deep_equal(f.snapshot().text, { "if (ready) {", "    outside();", "    inside();", "}" }))
      f.keys("<Esc>u")
      t.assert_true(vim.deep_equal(f.snapshot().text, lines), "one u must undo the insert move and reindent")
    end)
  end)
  t.it("moves from the actual native insert completion submode", function()
    fixture(function(f)
      for _, mode in ipairs({ "ic", "ix" }) do
        f.source({ "one", "two", "three" })
        f.keys("2G0i")
        f.lua(mode == "ic" and "vim.fn.complete(1, { 'alpha', 'alpine' })" or "vim.api.nvim_input('<C-x>')")
        t.assert_true(
          vim.wait(1000, function()
            return f.snapshot().mode == mode
          end, 5),
          "native completion submode was not entered"
        )
        local before = f.snapshot()
        f.keys("<A-k>")
        local after = f.snapshot()
        t.assert_eq(after.mode:sub(1, 1), "i", "move did not resume insert mode")
        t.assert_true(
          vim.deep_equal(after.text, { before.text[2], before.text[1], before.text[3] }),
          "insert completion disabled a valid line move"
        )
      end
    end)
  end)
end)
