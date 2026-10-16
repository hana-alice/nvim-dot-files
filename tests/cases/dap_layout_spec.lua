local t = require("tests.harness")
local root = t.bootstrap()

-- A fresh child keeps the real installed DAP/UI/nio modules independent from
-- fixtures used by other case files. No adapter or device session is started.
local native = [=[
local root, scenario = arg[1], arg[2]
root = root:gsub("\\", "/")
assert(vim.fn.stdpath("cache"):gsub("\\", "/"):find(root .. "/.tmp/review-gd/j-test-cache/", 1, true),
  "native DAP cache must remain in the test-owned path")
vim.opt.rtp:prepend(root)
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path
for _, plugin in ipairs({ "nvim-dap", "nvim-dap-ui", "nvim-nio" }) do
  vim.opt.rtp:append(vim.fn.stdpath("data") .. "/lazy/" .. plugin)
end
assert(require("workarounds.dap.pid_scoped_logs").apply(true))
local api = vim.api
local dap, dapui, nio = require("dap"), require("dapui"), require("nio")
local ui_util = require("dapui.util")
local upstream_open_buf = ui_util.open_buf
local layout, roles = require("ue.dap._layout"), require("utils.layout")
local D = require("ue.dap")
dapui.setup({ force_buffers = false, layouts = { {
  elements = { "scopes", "stacks", "watches" }, position = "left", size = 25,
} }, controls = { enabled = false } })
D.setup_dap(dap, dapui)
assert(require("dap.log").create_logger("dap.log")._path:find("." .. vim.fn.getpid() .. ".log", 1, true),
  "native DAP logger must be PID isolated")
local function eq(actual, expected, msg)
  assert(vim.deep_equal(actual, expected), (msg or "mismatch") .. ": " .. vim.inspect(actual) .. " ~= " .. vim.inspect(expected))
end
local serial = 0
local function buffer(ft, scratch)
  serial = serial + 1
  local buf = api.nvim_create_buf(true, scratch or false)
  api.nvim_buf_set_lines(buf, 0, -1, false, { "line one", "line two", "line three", "line four" })
  vim.bo[buf].filetype = ft or "lua"
  vim.bo[buf].modified = false
  return buf
end
local main = api.nvim_get_current_win()
local initial = buffer()
api.nvim_win_set_buf(main, initial)
if scenario == "dirty_restore" then
  vim.bo[initial].modified = true
  api.nvim_win_set_cursor(main, { 2, 2 })
end
local config = { type = "layout-fixture", name = "layout regression", request = "attach" }
local session = {
  id = 71, config = config, sign_group = "dap-layout-fixture", filetype = "lua",
  threads = { [1] = { id = 1, name = "fixture", stopped = true } }, dirty = { threads = false },
  capabilities = {}, adapter = {},
  _request_scopes = function(self) self.scopes_seen = true end,
}
local function begin_ui()
  -- on_config is the real pre-initialized entry; it only captures ownership.
  local listener = dap.listeners.on_config.ue_debug_layout
  assert(type(listener) == "function", "pre-initialization tab owner missing")
  config = listener(config) or config
  session.config = config
  dap.listeners.after.event_initialized.dapui_config(session)
end
local function async(fn)
  local done, failure = false
  nio.run(function()
    local ok, err = xpcall(fn, debug.traceback)
    failure, done = not ok and err or nil, true
  end)
  assert(vim.wait(2000, function() return done end, 10), "nio action timed out")
  assert(not failure, failure)
end
local target_file = root .. "/.tmp/review-gd/j-test-source-" .. scenario .. ".lua"
vim.fn.writefile({ "line one", "line two", "line three", "line four" }, target_file)
local target = vim.fn.bufadd(target_file)
vim.fn.bufload(target)
local frame = { id = 3, name = "fixture", line = 3, column = 1, source = { path = target_file, sourceReference = 0 } }
local review_session
if scenario == "review_real" or scenario == "native_review_real" then
  vim.opt.rtp:prepend(vim.fn.stdpath("data") .. "/lazy/codediff.nvim")
  require("codediff.config").setup({})
  local left_file = root .. "/.tmp/review-gd/j-test-source-old.lua"
  vim.fn.writefile({ "old line", "line two", "line three", "line four" }, left_file)
  local ready = false
  require("codediff.ui.view").create({ original = { absolute = left_file }, modified = { absolute = target_file } },
    "lua", function() ready = true end)
  assert(vim.wait(4000, function() return ready end, 10), "real CodeDiff view must open")
  review_session = assert(require("codediff.ui.lifecycle").get_session(api.nvim_get_current_tabpage()))
  roles.sync_review(api.nvim_get_current_tabpage(), review_session)
  main = assert(roles.resolve({ source_win = review_session.modified_win, route_to_normal = false }))
  api.nvim_set_current_win(main)
  api.nvim_win_set_buf(main, initial)
  target = review_session.modified_bufnr
end

if scenario == "workaround" then
  local workaround = require("workarounds.dap.source_windows")
  local wrapped = ui_util.open_buf
  assert(wrapped ~= upstream_open_buf)
  assert(workaround.apply())
  eq(ui_util.open_buf, wrapped, "repeated apply must retain one wrapper")
  workaround.disable()
  eq(ui_util.open_buf, upstream_open_buf, "disable restores exact upstream function")
  assert(workaround.apply())
  assert(ui_util.open_buf ~= upstream_open_buf)
elseif scenario == "init_tab" then
  local origin = api.nvim_get_current_tabpage()
  local listener = dap.listeners.on_config.ue_debug_layout
  assert(type(listener) == "function")
  session.config = listener(config) or config
  vim.cmd("tabnew")
  local other, other_win = api.nvim_get_current_tabpage(), api.nvim_get_current_win()
  dap.listeners.after.event_initialized.dapui_config(session)
  eq(api.nvim_get_current_tabpage(), other, "initialized must preserve new tab focus")
  eq(api.nvim_get_current_win(), other_win)
  eq(#api.nvim_tabpage_list_wins(other), 1, "no UI in user's later tab")
  assert(#api.nvim_tabpage_list_wins(origin) > 1, "UI belongs to config's captured tab")
else
  if scenario == "pending_restart" then
    dap.listeners.on_config.ue_debug_layout(config)
    -- Simulate a pre-initialized abort: no initialized/session-end event.
    -- The next attempt must capture the user's latest document and view.
    initial = buffer()
    api.nvim_win_set_buf(main, initial)
    api.nvim_win_set_cursor(main, { 2, 2 })
    vim.bo[initial].modified = true
  end
  begin_ui()
  local tab = api.nvim_get_current_tabpage()
  local panels = {}
  for _, win in ipairs(api.nvim_tabpage_list_wins(tab)) do
    if win ~= main then panels[win] = api.nvim_win_get_buf(win) end
  end
  assert(next(panels), "real dap-ui must open a rail/bottom panel")
  local function protected()
    for win, buf in pairs(panels) do
      assert(api.nvim_win_is_valid(win), "protected panel closed")
      eq(api.nvim_win_get_buf(win), buf, "protected panel replaced")
    end
  end
  if scenario == "stopped" then
    api.nvim_set_current_win((next(panels)))
    session.request = function(_, command)
      eq(command, "stackTrace")
      return nil, { stackFrames = { frame } }
    end
    require("dap.session").event_stopped(session, { threadId = 1, reason = "breakpoint", allThreadsStopped = true })
    assert(vim.wait(2000, function() return session.scopes_seen == true end, 10))
    eq(api.nvim_win_get_buf(main), target, "automatic stopped uses source role")
    eq(api.nvim_win_get_cursor(main), { 3, 0 })
    protected()
  elseif scenario == "native_frame" then
    api.nvim_set_current_win((next(panels)))
    require("dap.session")._frame_set(session, frame)
    assert(vim.wait(2000, function() return session.scopes_seen == true end, 10))
    eq(api.nvim_win_get_buf(main), target)
    eq(api.nvim_get_current_win(), main)
    protected()
  elseif scenario == "manual_first" or scenario == "manual_existing" then
    if scenario == "manual_existing" then api.nvim_win_set_buf(main, target) end
    api.nvim_set_current_win((next(panels)))
    async(function() assert(ui_util.open_buf(target, 3, 0)) end)
    eq(api.nvim_get_current_win(), main)
    eq(api.nvim_win_get_buf(main), target)
    eq(api.nvim_win_get_cursor(main), { 3, 0 })
    protected()
  elseif scenario == "repl_alternate" then
    local repl = require("dap.repl").buf
    if type(repl) == "function" then repl = repl() end
    repl = repl or buffer("dap-repl", true)
    api.nvim_win_set_buf(main, repl)
    api.nvim_win_set_buf(main, initial)
    vim.cmd("vnew")
    local panel = api.nvim_get_current_win()
    api.nvim_win_set_buf(panel, repl)
    roles.register(panel, "panel")
    require("dap.session")._frame_set(session, frame)
    eq(api.nvim_win_get_buf(main), target, "REPL alternate cannot become source")
    eq(api.nvim_win_get_buf(panel), repl)
    protected()
  elseif scenario == "external_confirm" then
    vim.opt.rtp:prepend(vim.fn.stdpath("data") .. "/lazy/snacks.nvim")
    local Snacks = require("snacks")
    local specs = assert(loadfile(root .. "/lua/plugins/snacks.lua"))()
    local options = specs[1].opts(nil, {})
    Snacks.config.picker = options.picker
    api.nvim_set_current_win((next(panels)))
    local source = api.nvim_get_current_win()
    local picker = Snacks.picker.pick("files", {
      finder = function() return { { file = target_file, buf = target, pos = { 3, 0 } } } end,
      format = "file", preview = "none", focus = "list", layout = { preset = "select" },
      jump = { close = true, reuse_win = true, match = false },
    })
    assert(vim.wait(2000, function() return picker.list:count() > 0 end, 10), "real picker has no result")
    picker:action("confirm")
    assert(vim.wait(2000, function() return picker.closed end, 10), "real confirm did not close picker")
    local destination = api.nvim_get_current_win()
    assert(api.nvim_get_current_tabpage() ~= tab, "external file confirm must switch away from debug tab")
    eq(roles.current_group().kind, "normal")
    eq(api.nvim_win_get_buf(destination), target, "external file confirm opens normal code")
    eq(api.nvim_win_get_buf(main), initial, "external navigation preserves debug source")
    eq(roles.back(), source, "Back returns to the initiating debug panel")
    eq(api.nvim_get_current_tabpage(), tab)
    protected()
  elseif scenario == "review_real" or scenario == "native_review_real" then
    local left, right = review_session.original_win, review_session.modified_win
    if scenario == "native_review_real" then api.nvim_win_set_cursor(right, { 3, 0 }) end
    local old_left, old_right = api.nvim_win_get_cursor(left), api.nvim_win_get_cursor(right)
    if scenario == "native_review_real" then
      api.nvim_set_current_win(right)
      require("dap.session")._frame_set(session, frame)
    else
      api.nvim_set_current_win(left)
      async(function() assert(ui_util.open_buf(target, 3, 0)) end)
    end
    eq(api.nvim_get_current_win(), main, "real CodeDiff existing target cannot bypass source role")
    eq(api.nvim_win_get_cursor(left), old_left)
    eq(api.nvim_win_get_cursor(right), old_right)
    protected()
  elseif scenario == "review_aux" then
    vim.cmd("rightbelow vnew")
    local aux = api.nvim_get_current_win()
    api.nvim_win_set_buf(aux, target)
    roles.register(aux, "aux")
    vim.wo[aux].diff = true
    api.nvim_set_current_win((next(panels)))
    async(function() assert(ui_util.open_buf(target, 3, 0)) end)
    eq(api.nvim_get_current_win(), main, "existing aux target must not bypass code selection")
    eq(api.nvim_win_get_buf(aux), target)
    eq(vim.wo[aux].diff, true)
    protected()
  elseif scenario == "pinned" or scenario == "closed" then
    if scenario == "pinned" then vim.wo[main].winfixbuf = true else api.nvim_win_close(main, true) end
    api.nvim_set_current_win((next(panels)))
    async(function() assert(ui_util.open_buf(target, 3, 0)) end)
    local replacement = api.nvim_get_current_win()
    assert(replacement ~= main and panels[replacement] == nil, "source fallback must create a safe split")
    eq(api.nvim_win_get_buf(replacement), target)
    eq(vim.wo[replacement].winfixbuf, false)
    protected()
    if scenario == "pinned" then eq(api.nvim_win_get_buf(main), initial); eq(vim.wo[main].winfixbuf, true) end
  elseif scenario == "dirty_restore" or scenario == "pending_restart" then
    async(function() assert(ui_util.open_buf(target, 3, 0)) end)
    dap.listeners.before.event_terminated.dapui_config(session)
    eq(api.nvim_win_get_buf(main), initial, "manual first jump must restore dirty source buffer")
    eq(api.nvim_win_get_cursor(main), { 2, 2 }, "manual first jump restores original reading cursor")
    eq(vim.bo[initial].modified, true, "UI closure cannot erase dirty state")
    eq(api.nvim_buf_get_lines(initial, 0, -1, false), { "line one", "line two", "line three", "line four" })
  elseif scenario == "close_user_split" then
    async(function() assert(ui_util.open_buf(target, 3, 0)) end)
    vim.cmd("rightbelow vnew")
    local user = api.nvim_get_current_win()
    local user_buf = buffer()
    api.nvim_win_set_buf(user, user_buf)
    dap.listeners.before.event_terminated.dapui_config(session)
    eq(api.nvim_get_current_win(), user, "closing UI cannot steal user's split focus")
    eq(api.nvim_win_get_buf(user), user_buf)
    eq(api.nvim_win_get_buf(main), initial, "manual first open is owned/restored")
  else
    error("unknown scenario: " .. scenario)
  end
end
print("native DAP layout: " .. scenario .. " OK")
vim.cmd("qa!")
]=]

t.describe("dap_layout: real DAP and dap-ui entry points", function()
  local scenarios = {
    "stopped", "native_frame", "manual_first", "manual_existing", "repl_alternate",
    "review_aux", "review_real", "native_review_real", "pinned", "closed", "init_tab", "close_user_split",
    "external_confirm", "workaround", "dirty_restore", "pending_restart",
  }
  for _, scenario in ipairs(scenarios) do
    t.it(scenario, function()
      local script = root .. "/.tmp/review-gd/j-test-native.lua"
      vim.fn.mkdir(vim.fs.dirname(script), "p")
      vim.fn.writefile(vim.split(native, "\n", { plain = true }), script)
      local result = vim.system({ vim.v.progpath, "--headless", "-l", script, root, scenario }, {
        text = true, env = { XDG_CACHE_HOME = root .. "/.tmp/review-gd/j-test-cache/" .. scenario,
          XDG_STATE_HOME = root .. "/.tmp/review-gd/j-test-state/" .. scenario },
      }):wait(10000)
      t.assert_eq(result.code, 0, (result.stdout or "") .. (result.stderr or ""))
      t.assert_contains((result.stdout or "") .. (result.stderr or ""), scenario .. " OK")
    end)
  end
end)
