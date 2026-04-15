-- Regression test for UE cached_grep's batched Snacks finder.
-- Run:
--   nvim --headless --cmd "lua vim.g.started_with_stdin = true; vim.g.ue_test_file = '<PROJ_DRIVE>/uetemp/Engine/Source/Runtime/VulkanRHI/Private/VulkanQueue.cpp'; vim.g.ue_test_search = 'Vulkan'" -u init.lua +"luafile tools/test_cached_grep.lua"

local function p(...)
  local args = { ... }
  for i, v in ipairs(args) do
    args[i] = tostring(v)
  end
  io.write(table.concat(args, "\t") .. "\n")
  io.flush()
end

local function fail(msg)
  p("FAIL", msg)
  vim.cmd("cquit 1")
end

local function assert_true(value, label)
  if not value then
    fail(label)
  end
end

pcall(function()
  require("persistence").stop()
end)

local test_file = vim.g.ue_test_file
if type(test_file) ~= "string" or test_file == "" then
  test_file = vim.api.nvim_buf_get_name(0)
end
assert_true(type(test_file) == "string" and test_file ~= "" and vim.fn.filereadable(test_file) == 1, "Missing vim.g.ue_test_file")

vim.cmd("edit " .. vim.fn.fnameescape(test_file))

local ue = require("ue")
local file_list, file_list_err = ue.cached_grep_file_list()
assert_true(file_list ~= nil, file_list_err or "cached_grep_file_list failed")
assert_true(type(file_list.files) == "table" and #file_list.files > 200, "Need > 200 files to exercise batching")

local captured
local snacks = require("snacks")
local orig_pick = snacks.picker.pick
snacks.picker.pick = function(spec)
  captured = spec
  return true
end

local search = type(vim.g.ue_test_search) == "string" and vim.g.ue_test_search or "Vulkan"
local ok_call, call_result = pcall(function()
  return ue.cached_grep({ title = "cached_grep test", search = search })
end)
snacks.picker.pick = orig_pick

assert_true(ok_call, "ue.cached_grep errored: " .. tostring(call_result))
assert_true(call_result == true, "ue.cached_grep did not use cached path")
assert_true(type(captured) == "table" and type(captured.finder) == "function", "picker spec not captured")

local Finder = require("snacks.picker.core.finder")
local finder = Finder.new(captured.finder)
finder:init({ search = captured.search or "", source_id = nil, cwd = vim.fn.getcwd() })

local picker = {
  opts = {
    live = true,
    limit_live = 50000,
    limit = 50000,
    debug = { proc = false },
  },
  matcher = { task = { resume = function() end } },
  update = function() end,
}

local ok_run, run_err = pcall(function()
  finder:run(picker)
end)
assert_true(ok_run, "finder:run failed: " .. tostring(run_err))

local ok_wait = vim.wait(8000, function()
  return finder:count() > 0 or not finder:running()
end, 50)
assert_true(ok_wait, "timed out waiting for cached grep results")
assert_true(finder:count() > 0, "cached grep returned no results for search: " .. search)

p("PASS", ("cached_grep returned %d results for %s"):format(finder:count(), search))
vim.cmd("qall!")
