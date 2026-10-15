local t = require("tests.harness")
local root = t.bootstrap()

-- Each child starts with exactly one tab. The ownership token is a fixture;
-- buffer/tab/window creation, routing and layout commands use real modules.
local native = [=[
local root, scenario = arg[1], arg[2]
vim.opt.rtp:prepend(root)
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path
local api = vim.api
local sessions = {}
package.loaded["codediff.ui.lifecycle"] = { get_session = function(tab) return sessions[tab] end }
local m = require("utils.layout")
require("utils.layout_commands").setup()
local function eq(a, b, why)
  assert(vim.deep_equal(a, b), (why or "mismatch") .. ": " .. vim.inspect(a) .. " ~= " .. vim.inspect(b))
end
local function window(split)
  if split then vim.cmd("rightbelow vnew") end
  local win, buf = api.nvim_get_current_win(), api.nvim_create_buf(true, false)
  api.nvim_buf_set_lines(buf, 0, -1, false, { "source one", "source two", "source three" })
  vim.bo[buf].modified = false
  api.nvim_win_set_buf(win, buf)
  return win, buf
end
local tab = api.nvim_get_current_tabpage()
local left, left_buf = window()
local right, right_buf = window(true)
local panel, panel_buf = window(true)
vim.bo[panel_buf].buftype, vim.bo[panel_buf].filetype = "nofile", "test-panel"
m.register(panel, "panel")
if scenario == "debug" then
  m.register(left, "code")
  m.register(right, "aux")
  m.register_group("debug", { tab = tab, token = {}, owner = "test-debug-ui",
    valid = function() return true end,
    focus = function() api.nvim_set_current_win(right); return right end })
else
  sessions[tab] = { original_win = left, modified_win = right, panel = { view = { winid = panel } } }
  m.sync_review(tab)
end
api.nvim_win_set_cursor(left, { 2, 2 })
api.nvim_win_set_cursor(right, { 3, 1 })
api.nvim_set_current_win(left)
local old_count = #api.nvim_tabpage_list_wins(tab)
local left_tick, right_tick = api.nvim_buf_get_changedtick(left_buf), api.nvim_buf_get_changedtick(right_buf)
if scenario == "internal" then
  local code = assert(m.resolve({ source_win = left, route_to_normal = false }))
  eq(api.nvim_win_get_tabpage(code), tab, "native internal code must remain in source tab")
  eq(#api.nvim_list_tabpages(), 1)
  eq(#api.nvim_tabpage_list_wins(tab), old_count + 1)
else
  local code = assert(m.focus({ source_win = left }))
  local normal = api.nvim_get_current_tabpage()
  assert(normal ~= tab, "external navigation must switch the entire UI")
  eq(m.current_group().kind, "normal")
  eq(#api.nvim_list_tabpages(), 2, "missing normal group creates only one tab")
  eq(api.nvim_win_get_tabpage(code), normal)
  for _ = 1, 3 do
    vim.cmd("UELayoutBack")
    eq(api.nvim_get_current_tabpage(), tab)
    eq(api.nvim_get_current_win(), left, "Back restores exact originating pane, not owner default")
    eq(api.nvim_win_get_cursor(left), { 2, 2 })
    eq(m.focus({ source_win = left }), code, "repeat navigation reuses normal code")
    eq(api.nvim_get_current_tabpage(), normal)
    eq(#api.nvim_list_tabpages(), 2, "repeat navigation cannot accumulate tabs")
  end
  eq(#api.nvim_tabpage_list_wins(tab), old_count, "no browser split in source layout")
end
eq(api.nvim_win_get_buf(left), left_buf)
eq(api.nvim_win_get_buf(right), right_buf)
eq(api.nvim_win_get_buf(panel), panel_buf)
eq(api.nvim_win_get_cursor(left), { 2, 2 })
eq(api.nvim_win_get_cursor(right), { 3, 1 })
eq(api.nvim_buf_get_changedtick(left_buf), left_tick)
eq(api.nvim_buf_get_changedtick(right_buf), right_tick)
assert(not package.loaded["dap"], "layout routing may not load or launch DAP")
print("NORMAL_ROUTE_OK " .. scenario)
vim.cmd("qa!")
]=]

t.describe("layout_normal_route real tabs and ownership", function()
  for _, scenario in ipairs({ "review", "debug", "internal" }) do
    t.it(scenario .. " creates/reuses normal and preserves source", function()
      local run = root .. "/.tmp/review-gd/m-layout-normal/" .. scenario
      vim.fn.mkdir(run, "p")
      local script = run .. "/native.lua"
      vim.fn.writefile(vim.split(native, "\n", { plain = true }), script)
      local result = vim.system({ vim.v.progpath, "--headless", "-u", "NONE", "-i", "NONE", "-l", script, root, scenario }, {
        text = true, env = { XDG_CACHE_HOME = run .. "/cache", XDG_STATE_HOME = run .. "/state",
          NVIM_LOG_FILE = run .. "/startup.log", NVIM_UE_LOG_DIR = run .. "/ue-logs",
          NVIM_UE_PROBE_PATH = run .. "/probes.json" },
      }):wait(10000)
      t.assert_eq(result.code, 0, (result.stdout or "") .. (result.stderr or ""))
      t.assert_contains((result.stdout or "") .. (result.stderr or ""), "NORMAL_ROUTE_OK " .. scenario)
    end)
  end
end)

t.describe("layout current-tab discovery", function()
  t.it("passive TabEnter never scans other review owners", function()
    local run = root .. "/.tmp/review-gd/n1-layout-discovery"
    vim.fn.mkdir(run, "p")
    local script = run .. "/native.lua"
    local code = [=[
local root = arg[1]
vim.opt.rtp:prepend(root)
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path
local api, sessions, seen = vim.api, {}, {}
for _ = 1, 4 do
  vim.cmd("tabnew")
  local left = api.nvim_get_current_win()
  vim.cmd("vsplit")
  sessions[api.nvim_get_current_tabpage()] = { original_win = left, modified_win = api.nvim_get_current_win() }
end
package.loaded["codediff.ui.lifecycle"] = { get_session = function(tab)
  seen[tab] = (seen[tab] or 0) + 1
  return sessions[tab]
end }
local layout = require("utils.layout")
layout.setup_groups()
seen = {}
local current = api.nvim_get_current_tabpage()
for _ = 1, 5 do
  layout.current_group()
  api.nvim_exec_autocmds("TabEnter", { group = "UELayoutGroups" })
end
assert(seen[current] and seen[current] > 0)
for tab in pairs(seen) do assert(tab == current, "passive query inspected unrelated review tab") end
print("CURRENT_TAB_DISCOVERY_OK")
vim.cmd("qa!")
]=]
    vim.fn.writefile(vim.split(code, "\n", { plain = true }), script)
    local result = vim.system({ vim.v.progpath, "-u", "NONE", "-i", "NONE", "--headless", "-l", script, root }, {
      text = true, env = { XDG_CACHE_HOME = run .. "/cache", XDG_STATE_HOME = run .. "/state",
        NVIM_LOG_FILE = run .. "/startup.log", NVIM_UE_LOG_DIR = run .. "/ue-logs",
        NVIM_UE_PROBE_PATH = run .. "/probes.json" },
    }):wait(10000)
    local output = (result.stdout or "") .. (result.stderr or "")
    t.assert_eq(result.code, 0, output)
    t.assert_contains(output, "CURRENT_TAB_DISCOVERY_OK")
  end)
end)
