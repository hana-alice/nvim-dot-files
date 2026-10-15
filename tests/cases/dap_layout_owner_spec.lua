local t = require("tests.harness")
local root = t.bootstrap()

-- Real installed UI modules in isolated children; the only session is an
-- in-memory protocol fixture. No adapter, transport or device is started.
local native = [=[
local root, scenario = arg[1], arg[2]
root = root:gsub("\\", "/")
assert(vim.fn.stdpath("cache"):gsub("\\", "/"):find(root .. "/.tmp/review-gd/l-test-cache/", 1, true))
vim.opt.rtp:prepend(root)
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path
for _, plugin in ipairs({ "nvim-dap", "nvim-dap-ui", "nvim-nio" }) do
  vim.opt.rtp:append(vim.fn.stdpath("data") .. "/lazy/" .. plugin)
end
assert(require("workarounds.dap.pid_scoped_logs").apply(true))
local api = vim.api
local dap, dapui = require("dap"), require("dapui")
local D, layouts = require("ue.dap"), require("utils.layout")
dapui.setup({ force_buffers = false, layouts = { {
  elements = { "scopes", "stacks", "watches" }, position = "left", size = 25,
} }, controls = { enabled = false } })
D.setup_dap(dap, dapui)
require("utils.layout_commands").setup()
assert(require("dap.log").create_logger("dap.log")._path:find("." .. vim.fn.getpid() .. ".log", 1, true))
local function eq(a, b, why)
  assert(vim.deep_equal(a, b), (why or "mismatch") .. ": " .. vim.inspect(a) .. " ~= " .. vim.inspect(b))
end
local notices = {}
vim.notify = function(message) notices[#notices + 1] = tostring(message) end
local calls = {}
local function forbid(owner, key, label)
  label = label or key
  calls[label] = 0
  owner[key] = function()
    calls[label] = calls[label] + 1
    error("layout invoked business action: " .. label)
  end
end
for _, key in ipairs({ "launch", "attach", "run", "terminate", "disconnect", "close" }) do forbid(dap, key) end
for _, key in ipairs({ "dap_stop_session", "stop_android_debugger", "android_dap_attach" }) do forbid(D, key) end
local tasks = require("utils.task_registry")
forbid(tasks, "cancel", "task.cancel")
forbid(tasks, "cancel_all", "task.cancel_all")
local function buffer()
  local buf = api.nvim_create_buf(true, false)
  api.nvim_buf_set_lines(buf, 0, -1, false, { "dirty source one", "source two", "source three" })
  vim.bo[buf].filetype = "lua"
  vim.bo[buf].modified = true
  return buf
end
local normal_tab, normal_win = api.nvim_get_current_tabpage(), api.nvim_get_current_win()
local normal_buf = buffer()
api.nvim_win_set_buf(normal_win, normal_buf)
api.nvim_win_set_cursor(normal_win, { 2, 3 })
local normal_tick = api.nvim_buf_get_changedtick(normal_buf)
layouts.discover_groups()
if scenario == "no_session" then
  vim.cmd("UELayout debug")
  eq(api.nvim_get_current_tabpage(), normal_tab)
  eq(#api.nvim_tabpage_list_wins(normal_tab), 1)
  assert(table.concat(notices, "\n"):find("无调试会话", 1, true), vim.inspect(notices))
else
  vim.cmd("tabnew")
  local debug_tab, main = api.nvim_get_current_tabpage(), api.nvim_get_current_win()
  local source = buffer()
  api.nvim_win_set_buf(main, source)
  api.nvim_win_set_cursor(main, { 2, 2 })
  local tick = api.nvim_buf_get_changedtick(source)
  local config = { type = "layout-fixture", name = "layout owner regression", request = "attach" }
  config = dap.listeners.on_config.ue_debug_layout(config) or config
  local session = {
    id = 81, config = config, sign_group = "dap-layout-owner-fixture",
    threads = {}, dirty = { threads = false }, capabilities = {}, adapter = {},
    request = function(_, _, _, callback) if callback then callback(nil, { threads = {} }) end end,
  }
  dap.set_session(session)
  dap.listeners.after.event_initialized.dapui_config(session)
  local group = assert(layouts.current_group())
  eq(group.kind, "debug", "initialized registers debug owner")
  local token = group.token
  local function intact()
    eq(api.nvim_win_get_buf(main), source, "source buffer survives UI commands")
    eq(api.nvim_buf_get_changedtick(source), tick, "dirty text is never rewritten")
    eq(vim.bo[source].modified, true)
    eq(api.nvim_win_get_cursor(main), { 2, 2 })
  end
  if scenario == "focus" then
    api.nvim_set_current_tabpage(normal_tab)
    vim.cmd("UELayout debug")
    eq(api.nvim_get_current_tabpage(), debug_tab)
    eq(api.nvim_get_current_win(), main)
    eq(layouts.current_group().token, token)
    intact()
  elseif scenario == "closed_restore" then
    vim.cmd("rightbelow vnew")
    local user_win, user_buf = api.nvim_get_current_win(), buffer()
    api.nvim_win_set_buf(user_win, user_buf)
    local user_tick = api.nvim_buf_get_changedtick(user_buf)
    D._dap_close_debug_layout()
    eq(api.nvim_get_current_win(), user_win, "UI close preserves new split focus")
    local valid, why = group.valid(group)
    eq(valid, false)
    assert(why and why:find("关闭", 1, true), tostring(why))
    api.nvim_set_current_tabpage(normal_tab)
    vim.cmd("UELayout debug")
    eq(api.nvim_get_current_tabpage(), debug_tab, "reopen goes to session-owned tab")
    local restored = layouts.current_group()
    eq(restored.kind, "debug")
    assert(restored.token ~= token, "closed invocation must not be resurrected")
    assert(api.nvim_win_is_valid(user_win))
    eq(api.nvim_win_get_buf(user_win), user_buf)
    eq(api.nvim_buf_get_changedtick(user_buf), user_tick)
    intact()
  elseif scenario == "repurposed_restore" then
    local rail, missing
    for _, win in ipairs(api.nvim_tabpage_list_wins(debug_tab)) do
      local ft = vim.bo[api.nvim_win_get_buf(win)].filetype
      if ft == "dapui_scopes" then missing = win end
      if ft == "dapui_stacks" then rail = win end
    end
    assert(rail and missing, "real dap-ui stacks/scopes rail missing")
    api.nvim_win_close(missing, true)
    vim.wo[rail].winfixbuf = false
    local changed = buffer()
    api.nvim_win_set_buf(rail, changed)
    local changed_tick = api.nvim_buf_get_changedtick(changed)
    local count = #api.nvim_tabpage_list_wins(debug_tab)
    vim.cmd("UELayoutRestore")
    assert(api.nvim_win_is_valid(rail), "repurposed window must not be closed")
    eq(api.nvim_win_get_buf(rail), changed)
    eq(api.nvim_buf_get_changedtick(changed), changed_tick)
    eq(#api.nvim_tabpage_list_wins(debug_tab), count)
    assert(table.concat(notices, "\n"):find("新内容", 1, true), vim.inspect(notices))
    intact()
  elseif scenario == "ui_only_logcat" then
    -- Supply reader eligibility without any device connection. Every spawn
    -- attempt fails the test before an external process can start.
    local android = require("ue.dap.android")
    android._session.pid, android._session.serial, android._session.adb = "123", "fixture-device", "adb"
    forbid(vim.fn, "jobstart", "spawn.reader")
    D.dap_bottom_tab("logcat", { quiet = true, ui_only = true })
    vim.cmd("UELayoutRestore")
    D._dap_close_debug_layout()
    api.nvim_set_current_tabpage(normal_tab)
    vim.cmd("UELayout debug")
    eq(api.nvim_get_current_tabpage(), debug_tab)
    eq(layouts.current_group().kind, "debug")
    eq(calls["spawn.reader"], 0, "UI-only restore cannot start missing logcat reader")
    intact()
  elseif scenario == "partial_restore" then
    vim.cmd("rightbelow vnew")
    local user_win, user_buf = api.nvim_get_current_win(), buffer()
    api.nvim_win_set_buf(user_win, user_buf)
    local user_tick = api.nvim_buf_get_changedtick(user_buf)
    local rail
    for _, win in ipairs(api.nvim_tabpage_list_wins(debug_tab)) do
      if vim.bo[api.nvim_win_get_buf(win)].filetype == "dapui_scopes" then rail = win end
    end
    assert(rail, "real dap-ui scopes rail missing")
    api.nvim_win_close(rail, true)
    vim.cmd("UELayoutRestore")
    local scopes = 0
    for _, win in ipairs(api.nvim_tabpage_list_wins(debug_tab)) do
      if vim.bo[api.nvim_win_get_buf(win)].filetype == "dapui_scopes" then scopes = scopes + 1 end
    end
    eq(scopes, 1, "restore repairs missing rail without duplicate UI")
    eq(layouts.current_group().token, token, "partial restore retains owner token")
    assert(api.nvim_win_is_valid(user_win))
    eq(api.nvim_win_get_buf(user_win), user_buf)
    eq(api.nvim_buf_get_changedtick(user_buf), user_tick)
    intact()
  elseif scenario == "roundtrip" then
    api.nvim_set_current_tabpage(normal_tab)
    vim.opt.rtp:prepend(vim.fn.stdpath("data") .. "/lazy/codediff.nvim")
    require("codediff.config").setup({})
    local old_file, new_file = root .. "/.tmp/review-gd/l-test-old.lua", root .. "/.tmp/review-gd/l-test-new.lua"
    vim.fn.writefile({ "old line", "line two" }, old_file)
    vim.fn.writefile({ "new line", "line two" }, new_file)
    local ready = false
    require("codediff.ui.view").create({ original = { absolute = old_file }, modified = { absolute = new_file } },
      "lua", function() ready = true end)
    assert(vim.wait(4000, function() return ready end, 10), "real CodeDiff view failed")
    local review_tab = api.nvim_get_current_tabpage()
    local review = assert(require("codediff.ui.lifecycle").get_session(review_tab))
    layouts.sync_review(review_tab, review)
    local left, right = review.original_win, review.modified_win
    local left_buf, right_buf = api.nvim_win_get_buf(left), api.nvim_win_get_buf(right)
    api.nvim_set_current_tabpage(normal_tab)
    vim.cmd("UELayout normal")
    eq(api.nvim_get_current_tabpage(), normal_tab)
    vim.cmd("UELayout review")
    eq(api.nvim_get_current_tabpage(), review_tab)
    vim.cmd("UELayout debug")
    eq(api.nvim_get_current_tabpage(), debug_tab)
    eq(api.nvim_get_current_win(), main)
    vim.cmd("UELayout normal")
    eq(api.nvim_get_current_tabpage(), normal_tab)
    eq(api.nvim_win_get_buf(normal_win), normal_buf)
    eq(api.nvim_buf_get_changedtick(normal_buf), normal_tick)
    eq(vim.bo[normal_buf].modified, true)
    eq(api.nvim_win_get_cursor(normal_win), { 2, 3 })
    eq(api.nvim_win_get_buf(left), left_buf)
    eq(api.nvim_win_get_buf(right), right_buf)
    intact()
  elseif scenario == "session_end" then
    dap.listeners.before.event_terminated.dapui_config(session)
    local valid, why = group.valid(group)
    eq(valid, false)
    assert(why and why:find("会话", 1, true) and why:find("结束", 1, true), tostring(why))
    dap.sessions()[session.id] = nil
    dap.set_session(nil)
    vim.cmd("UELayout debug")
    assert(table.concat(notices, "\n"):find("无调试会话", 1, true), vim.inspect(notices))
    intact()
  else error("unknown scenario " .. scenario) end
end
for action, count in pairs(calls) do eq(count, 0, action .. " must never execute") end
print("native DAP layout owner: " .. scenario .. " OK")
vim.cmd("qa!")
]=]

t.describe("dap_layout_owner: UI-only debug layout commands", function()
  for _, scenario in ipairs({ "focus", "closed_restore", "partial_restore", "repurposed_restore", "ui_only_logcat", "roundtrip", "no_session", "session_end" }) do
    t.it(scenario, function()
      local script = root .. "/.tmp/review-gd/l-test-owner-native.lua"
      vim.fn.mkdir(vim.fs.dirname(script), "p")
      vim.fn.writefile(vim.split(native, "\n", { plain = true }), script)
      local result = vim.system({ vim.v.progpath, "--headless", "-l", script, root, scenario }, {
        text = true, env = { XDG_CACHE_HOME = root .. "/.tmp/review-gd/l-test-cache/" .. scenario,
          XDG_STATE_HOME = root .. "/.tmp/review-gd/l-test-state/" .. scenario },
      }):wait(10000)
      t.assert_eq(result.code, 0, (result.stdout or "") .. (result.stderr or ""))
      t.assert_contains((result.stdout or "") .. (result.stderr or ""), scenario .. " OK")
    end)
  end
end)
