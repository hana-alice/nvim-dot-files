local t = require("tests.harness")
local root = t.bootstrap():gsub("\\", "/")

-- Run real installed DAP/UI/nio and native windows in isolated processes.
-- Session tables model the listener protocol only; no adapter/device is started.
local native = [=[
local root, scenario, own = arg[1], arg[2], arg[3]
root, own = root:gsub("\\", "/"), own:gsub("\\", "/")
local function within(path)
  return path:gsub("\\", "/"):find(own .. "/", 1, true) ~= nil
end
assert(within(vim.fn.stdpath("cache")), "cache isolation missing")
assert(within(vim.fn.stdpath("state")), "state isolation missing")
for _, name in ipairs({ "NVIM_LOG_FILE", "NVIM_UE_LOG_DIR", "NVIM_UE_PROBE_PATH" }) do
  assert(within(assert(vim.env[name])), name .. " isolation missing")
end
vim.opt.rtp:prepend(root)
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path
for _, name in ipairs({ "nvim-dap", "nvim-dap-ui", "nvim-nio" }) do
  vim.opt.rtp:append(vim.fn.stdpath("data") .. "/lazy/" .. name)
end
assert(require("workarounds.dap.pid_scoped_logs").apply(true))
local api, dap, dapui = vim.api, require("dap"), require("dapui")
require("nio")
local logger = require("dap.log").create_logger("dap.log")
assert(within(logger._path) and logger._path:find("." .. vim.fn.getpid() .. ".log", 1, true),
  "DAP logger must be isolated and PID-scoped before plugin setup")
dapui.setup({ force_buffers = false, layouts = { {
  elements = { "scopes", "stacks", "watches" }, position = "left", size = 25,
} }, controls = { enabled = false } })
local D, roles, layout = require("ue.dap"), require("utils.layout"), require("ue.dap._layout")
D.setup_dap(dap, dapui)
local notices = {}
vim.notify = function(message) notices[#notices + 1] = tostring(message) end
local function eq(actual, expected, message)
  local rendered = vim.inspect(actual)
  if #rendered > 500 then rendered = rendered:sub(1, 500) .. "…" end
  assert(vim.deep_equal(actual, expected), (message or "mismatch") .. ": "
    .. rendered .. " ~= " .. vim.inspect(expected))
end
local serial = 0
local function buffer(scratch)
  serial = serial + 1
  local value = api.nvim_create_buf(not scratch, scratch or false)
  if not scratch then api.nvim_buf_set_name(value, own .. "/source-" .. serial .. ".lua") end
  api.nvim_buf_set_lines(value, 0, -1, false, { "line one", "line two", "line three" })
  vim.bo[value].filetype = scratch and "" or "lua"
  vim.bo[value].modified = false
  return value
end
local main, initial = api.nvim_get_current_win(), buffer()
api.nvim_win_set_buf(main, initial)
if scenario == "borrowed_review" then
  vim.opt.rtp:prepend(vim.fn.stdpath("data") .. "/lazy/codediff.nvim")
  require("codediff.config").setup({})
  local old_file, new_file = own .. "/old.lua", own .. "/new.lua"
  vim.fn.writefile({ "old line", "second line" }, old_file)
  vim.fn.writefile({ "new line", "second line" }, new_file)
  local ready = false
  require("codediff.ui.view").create({ original = { absolute = old_file }, modified = { absolute = new_file } },
    "lua", function() ready = true end)
  assert(vim.wait(4000, function() return ready end, 10), "real CodeDiff view did not open")
  local tab = api.nvim_get_current_tabpage()
  local review = assert(require("codediff.ui.lifecycle").get_session(tab))
  roles.sync_review(tab, review)
  main = assert(roles.resolve({ source_win = review.modified_win, route_to_normal = false }))
  api.nvim_set_current_win(main)
  api.nvim_win_set_buf(main, initial)
end
local host, previous, pinned
if scenario:find("borrowed", 1, true) or scenario:find("restore_error", 1, true) then
  previous = buffer(true)
  host = require("utils.bottom_panel").show("build", previous, { focus = false })
  pinned = scenario ~= "borrowed_free" and not scenario:find("^unpinned")
  vim.wo[host].winfixbuf = pinned
end
local function begin(index)
  local config = dap.listeners.on_config.ue_debug_layout({
    type = "release-fixture", name = "release regression", request = "attach",
  })
  local session = {
    id = 800 + index, config = config, sign_group = "dap-release-fixture",
    threads = {}, dirty = { threads = false }, capabilities = {}, adapter = {},
    request = function(_, _, _, callback) if callback then callback(nil, { threads = {} }) end end,
  }
  dap.set_session(session)
  dap.listeners.after.event_initialized.dapui_config(session)
  local group = assert(roles.current_group())
  eq(group.kind, "debug", "native UI must own debug group")
  assert(group.token and group.token.session == session)
  return session, group
end
local function retire_native(session)
  -- Drop real nvim-dap's documented session registry/current-session refs,
  -- leaving our debug ownership record as the object under test.
  dap.sessions()[session.id] = nil
  dap.set_session(nil)
end
local session, group = begin(1)
local evidence = { scenario = scenario, pid = vim.fn.getpid(), logger = logger._path }
if scenario:find("borrowed", 1, true) then
  assert(api.nvim_win_get_buf(host) ~= previous, "UI did not borrow the real host")
  local cleanup, ended = 0, 0
  local platforms = require("ue.dap.platforms")
  platforms.dispatch_lifecycle = function(action) if action == "cleanup" then cleanup = cleanup + 1 end end
  platforms.end_session = function() ended = ended + 1 end
  D._dap_session_state.release_sentinel = true
  local finish = scenario == "borrowed_end" and function()
    dap.listeners.before.event_terminated.dapui_config(session)
  end or D._dap_close_debug_layout
  local ok, err = pcall(finish)
  evidence.close_ok, evidence.error = ok, not ok and tostring(err) or nil
  evidence.after, evidence.pin, evidence.cleanup, evidence.ended = api.nvim_win_get_buf(host), vim.wo[host].winfixbuf, cleanup, ended
  vim.fn.writefile({ vim.json.encode(evidence) }, own .. "/result.json")
  assert(ok, err)
  eq(api.nvim_win_get_buf(host), previous, "borrowed buffer must be returned")
  eq(vim.wo[host].winfixbuf, pinned, "user pin must survive borrowed return")
  if scenario == "borrowed_end" then
    eq(cleanup, 1); eq(ended, 1); eq(D._dap_session_state.release_sentinel, nil)
  end
elseif scenario:find("restore_error", 1, true) then
  local hits = 0
  local ending = scenario:find("end_restore_error", 1, true) ~= nil
  local cleanup, ended = 0, 0
  if ending then
    local platforms = require("ue.dap.platforms")
    platforms.dispatch_lifecycle = function(action) if action == "cleanup" then cleanup = cleanup + 1 end end
    platforms.end_session = function() ended = ended + 1 end
    D._dap_session_state.release_sentinel = true
  end
  api.nvim_create_autocmd("BufWinEnter", {
    buffer = previous,
    callback = function()
      if api.nvim_get_current_win() == host then
        hits = hits + 1
        error("N2 native borrowed restore failure")
      end
    end,
  })
  local ok, err
  if ending then
    ok, err = pcall(dap.listeners.before.event_terminated.dapui_config, session)
    vim.wait(500, function()
      return table.concat(notices, "\n"):find("N2 native borrowed restore failure", 1, true) ~= nil
    end, 10)
  else
    ok, err = pcall(layout.close, group.token)
  end
  evidence.close_ok, evidence.error, evidence.hits = ok, not ok and tostring(err) or nil, hits
  evidence.pin, evidence.cleanup, evidence.ended, evidence.notices = vim.wo[host].winfixbuf, cleanup, ended, notices
  vim.fn.writefile({ vim.json.encode(evidence) }, own .. "/result.json")
  eq(hits, 1, "native BufWinEnter must reach failing restore")
  if ending then
    assert(ok, err)
    eq(cleanup, 1); eq(ended, 1); eq(D._dap_session_state.release_sentinel, nil)
    assert(table.concat(notices, "\n"):find("N2 native borrowed restore failure", 1, true), "native restore error needs explicit report")
    eq(group.token, nil, "native restore error must retire heavy token")
    eq(group.valid(group), false)
  else
    assert(not ok and tostring(err):find("N2 native borrowed restore failure", 1, true), "restore exception must be observable")
  end
  eq(vim.wo[host].winfixbuf, pinned, "finally must restore original pin on native set-buffer failure")
elseif scenario:find("ui_error", 1, true) then
  local cleanup, ended, close_calls = 0, 0, 0
  local platforms = require("ue.dap.platforms")
  platforms.dispatch_lifecycle = function(action) if action == "cleanup" then cleanup = cleanup + 1 end end
  platforms.end_session = function() ended = ended + 1 end
  D._dap_session_state.release_sentinel = true
  local second, native_close = nil, layout.close
  if scenario == "multi_owner_ui_error" then
    vim.cmd("tabnew")
    local extra = buffer()
    api.nvim_win_set_buf(api.nvim_get_current_win(), extra)
    D._dap_open_debug_layout({ reset = true })
    second = assert(roles.current_group())
    eq(second.kind, "debug")
    assert(second ~= group and second.token)
  end
  layout.close = function(state)
    close_calls = close_calls + 1
    if close_calls == 1 then error("N2 forced UI restore failure") end
    return native_close(state)
  end
  local finish = dap.listeners.before.event_terminated.dapui_config
  if scenario == "exited_ui_error" then finish = dap.listeners.before.event_exited.dapui_config end
  if scenario == "disconnect_ui_error" then finish = dap.listeners.after.disconnect.dapui_config end
  local ok, err = pcall(finish, session)
  if ok then
    vim.wait(500, function()
      return table.concat(notices, "\n"):find("N2 forced UI restore failure", 1, true) ~= nil
    end, 10)
  end
  evidence.close_ok, evidence.error, evidence.cleanup, evidence.ended = ok, not ok and tostring(err) or nil, cleanup, ended
  evidence.notices, evidence.close_calls = notices, close_calls
  vim.fn.writefile({ vim.json.encode(evidence) }, own .. "/result.json")
  assert(ok, err)
  eq(cleanup, 1, "UI error must not block platform cleanup")
  eq(ended, 1, "UI error must not block end_session")
  eq(D._dap_session_state.release_sentinel, nil, "UI error must not block reset")
  assert(table.concat(notices, "\n"):find("N2 forced UI restore failure", 1, true), "UI error needs explicit report")
  local valid, reason = group.valid(group)
  eq(valid, false); assert(type(reason) == "string" and #reason > 0)
  eq(group.token, nil, "failure path must retire heavy token")
  eq(close_calls, second and 2 or 1, "one UI error must not block remaining owners")
  if second then
    eq(second.token, nil, "remaining owner must retire its token")
    eq(second.valid(second), false)
  end
elseif scenario == "manual_close_error" then
  local native_close = layout.close
  layout.close = function(state)
    if state then error("N2 forced manual UI close failure") end
    return native_close(state)
  end
  local ok, err = pcall(D._dap_close_debug_layout)
  assert(not ok and tostring(err):find("N2 forced manual UI close failure", 1, true))
  eq(group.token, nil, "manual close failure must retire token in finally")
  local valid, reason = group.valid(group)
  eq(valid, false); assert(type(reason) == "string" and #reason > 0)
  assert(pcall(D._dap_close_debug_layout), "failed invocation must no longer own UI on retry")
elseif scenario == "manual_reopen" then
  local old_id = group.id
  D._dap_close_debug_layout()
  eq(group.token, nil, "UI close retires old invocation token")
  local valid, reason = group.valid(group)
  eq(valid, false); assert(type(reason) == "string" and #reason > 0)
  assert(roles.switch("debug"), "same live session must allow fresh UI")
  local fresh = assert(roles.current_group())
  assert(fresh.id ~= old_id and fresh.token, "reopened UI needs a distinct live record")
  eq(group.token, nil, "opening new UI cannot resurrect retired record")
  eq(group.valid(group), false)
elseif scenario == "retired_token" or scenario == "closed_token" then
  local weak, retired = setmetatable({}, { __mode = "v" }), {}
  for index = 1, 8 do
    if index > 1 then session, group = begin(index) end
    weak[index], retired[index] = group.token, group
    if scenario == "closed_token" then
      D._dap_close_debug_layout()
    else
      dap.listeners.before.event_terminated.dapui_config(session)
    end
    retire_native(session)
    session = nil
  end
  roles.discover_groups()
  collectgarbage("collect"); collectgarbage("collect")
  local retained, ids, reasons = 0, {}, {}
  for index, old in ipairs(retired) do
    if weak[index] then retained = retained + 1 end
    ids[index] = old.id
    local valid, reason = old.valid(old)
    eq(valid, false, "retired record remains honestly invalid")
    reasons[index] = reason
    assert(type(reason) == "string" and #reason > 0, "retired record needs lightweight invalid reason")
  end
  evidence.cycles, evidence.retained, evidence.ids, evidence.reasons = 8, retained, ids, reasons
  vim.fn.writefile({ vim.json.encode(evidence) }, own .. "/result.json")
  eq(retained, 0, "retired group must release all invocation/session tokens")
  for _, old in ipairs(retired) do eq(old.token, nil) end
else
  error("unknown scenario " .. scenario)
end
vim.fn.writefile({ vim.json.encode(evidence) }, own .. "/result.json")
print("native DAP release: " .. scenario .. " OK")
vim.cmd("qa!")
]=]

t.describe("dap_release: native borrowed host and retired ownership", function()
  local scenarios = {
    "borrowed_review", "borrowed_pin", "borrowed_end", "borrowed_free",
    "pinned_restore_error", "unpinned_restore_error", "end_ui_error",
    "pinned_end_restore_error", "unpinned_end_restore_error",
    "exited_ui_error", "disconnect_ui_error", "multi_owner_ui_error", "manual_close_error",
    "manual_reopen", "retired_token", "closed_token",
  }
  local base = root .. "/.tmp/review-gd/n2-test-" .. vim.fn.getpid()
  local script = base .. "/native.lua"
  vim.fn.mkdir(base, "p")
  vim.fn.writefile(vim.split(native, "\n", { plain = true }), script)
  for _, scenario in ipairs(scenarios) do
    t.it(scenario, function()
      local own = base .. "/" .. scenario
      vim.fn.mkdir(own, "p")
      local result = vim.system({ vim.v.progpath, "--headless", "-l", script, root, scenario, own }, {
        text = true, env = {
          XDG_CACHE_HOME = own .. "/cache", XDG_STATE_HOME = own .. "/state",
          NVIM_LOG_FILE = own .. "/nvim.log", NVIM_UE_LOG_DIR = own .. "/logs",
          NVIM_UE_PROBE_PATH = own .. "/ue_probes.json",
        },
      }):wait(10000)
      local output = (result.stdout or "") .. (result.stderr or "")
      vim.fn.writefile(vim.split(output, "\n", { plain = true }), own .. "/output.log")
      t.assert_eq(result.code, 0, output)
      t.assert_contains(output, scenario .. " OK")
    end)
  end
end)
