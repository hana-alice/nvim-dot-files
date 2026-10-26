-- tests/cases/clangd_temp_spec.lua
-- clangd preamble files live in a per-session TEMP; only dead sessions are swept.

local t = require("tests.harness")
t.bootstrap()

local temp = require("ue.clangd_temp")

local function fixture()
  local cache = vim.fn.tempname()
  vim.fn.mkdir(cache, "p")
  return cache
end

t.describe("clangd per-session TEMP", function()
  t.it("gives clangd TEMP/TMP under the session directory and keeps other env", function()
    temp._reset_for_test()
    local cache = fixture()
    local env = temp.spawn_env({ KEEP = "1" }, { cache = cache, pid = 4242, process_exists = function() return true end })
    local dir = vim.fs.joinpath(cache, "clangd-tmp", "4242")
    t.assert_eq(env.TEMP, dir)
    t.assert_eq(env.TMP, dir)
    t.assert_eq(env.KEEP, "1")
    t.assert_eq(vim.fn.isdirectory(dir), 1)
  end)

  t.it("does not mutate the caller's environment table", function()
    temp._reset_for_test()
    local original = { KEEP = "1" }
    temp.spawn_env(original, { cache = fixture(), pid = 1, process_exists = function() return true end })
    t.assert_nil(original.TEMP)
  end)

  t.it("sweeps only directories whose owning session is provably dead", function()
    local cache = fixture()
    local root = vim.fs.joinpath(cache, "clangd-tmp")
    for _, name in ipairs({ "100", "200", "300", "999", "notapid" }) do
      vim.fn.mkdir(vim.fs.joinpath(root, name), "p")
      vim.fn.writefile({ "x" }, vim.fs.joinpath(root, name, "preamble-1.pch"))
    end
    local alive = { [100] = false, [200] = true, [300] = nil }
    local removed = temp.sweep({ cache = cache, pid = 999, process_exists = function(pid) return alive[pid] end })
    t.assert_eq(removed, 1)
    t.assert_eq(vim.fn.isdirectory(vim.fs.joinpath(root, "100")), 0)
    t.assert_eq(vim.fn.isdirectory(vim.fs.joinpath(root, "200")), 1) -- alive
    t.assert_eq(vim.fn.isdirectory(vim.fs.joinpath(root, "300")), 1) -- unknown liveness
    t.assert_eq(vim.fn.isdirectory(vim.fs.joinpath(root, "999")), 1) -- self
    t.assert_eq(vim.fn.isdirectory(vim.fs.joinpath(root, "notapid")), 1)
  end)

  t.it("sweeps once per session, then reuses the directory", function()
    temp._reset_for_test()
    local cache, sweeps = fixture(), 0
    local deps = { cache = cache, pid = 7, process_exists = function() sweeps = sweeps + 1; return true end }
    vim.fn.mkdir(vim.fs.joinpath(cache, "clangd-tmp", "8"), "p")
    temp.spawn_env(nil, deps)
    temp.spawn_env(nil, deps)
    t.assert_eq(sweeps, 1)
  end)
end)
