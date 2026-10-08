local t = require("tests.harness")
t.bootstrap()
local api = vim.api
local UE = require("ue")
local O = require("utils.ue_onboarding")
local H = require("utils.ue_hub")

local function upvalue(fn, wanted)
  for index = 1, 64 do
    local name, value = debug.getupvalue(fn, index)
    if not name then break end
    if name == wanted then return index, value end
  end
  error("missing test seam: " .. wanted)
end

-- Exercise the actual UESetPlatform command and its two nested UI callbacks.
-- Only context/state/fast-swap effects are replaced; no host or executable is faked.
local function fixture(check)
  UE.setup()
  local _, setter = upvalue(UE._set_platform_for_test, "set_platform")
  local _, core = upvalue(setter, "CORE_RT")
  local restore = {}
  local function patch(owner, key, value)
    local original = owner[key]
    restore[#restore + 1] = function() owner[key] = original end
    owner[key] = value
  end
  local function replace(name, value, fn)
    fn = fn or setter
    local index, original = upvalue(fn, name)
    restore[#restore + 1] = function() debug.setupvalue(fn, index, original) end
    debug.setupvalue(fn, index, value)
  end
  local win, previous = api.nvim_get_current_win(), api.nvim_get_current_buf()
  local buf = api.nvim_create_buf(true, false)
  api.nvim_win_set_buf(win, buf)
  api.nvim_buf_set_lines(buf, 0, -1, false, { "preserve this unsaved fixture text" })
  local f = {
    win = win, buf = buf, prompts = {}, updates = 0, swaps = 0,
    patch = patch, replace = replace, core = core, actual_rows = H.target_rows,
    target = { project = "Example", project_root = "/fixture/project", engine_root = "/fixture/engine",
      platform = "", configuration = "", state = {} },
  }
  patch(H, "target", function() return vim.deepcopy(f.target) end)
  patch(H, "target_rows", function()
    return {
      { label = "Project", value = "Example", run = function() vim.cmd("UESetProject") end },
      { label = "Platform", value = "(auto)", run = function() vim.cmd("UESetPlatform") end },
    }
  end)
  patch(O, "readiness", function() return "missing" end)
  patch(package.loaded, "snacks", {})
  patch(vim, "notify", function() end)
  patch(vim.ui, "select", function(items, opts, done)
    f.prompts[#f.prompts + 1] = { items = items, prompt = opts.prompt, done = done }
  end)
  replace("platform_selection_context", function()
    return f.target.engine_root, f.target.project_root, "/fixture/project/Example.uproject", f.target.state
  end)
  replace("target_platform", function() return "Win64" end)
  replace("selected_target_configuration", function() return "Development" end)
  replace("available_platform_choices", function() return { "Win64" } end)
  replace("available_configuration_choices", function() return { "Development" } end)
  replace("invalidate_status_cache", function() end)
  replace("refresh_statusline", function() end)
  replace("read_state", function() return f.target.state end)
  patch(core, "context_cache", {})
  patch(core, "freshness_notified", {})
  patch(core.project_state, "engine_target_default", function() return nil end)
  patch(core.project_state, "stage_target", function(_, platform, configuration)
    f.updates = f.updates + 1
    f.target.platform, f.target.configuration = platform, configuration
    f.target.state.target_platform, f.target.state.target_configuration = platform, configuration
    if f.on_commit then f.on_commit() end
    return true
  end)
  patch(core, "fast_swap_active_platform", function()
    f.swaps = f.swaps + 1
    return false, nil, "fixture: no real task is launched"
  end)
  patch(core, "migrate_legacy_csearch_if_needed", function() end)
  patch(require("utils.code_search"), "_reset_probe_cache", function() end)
  function f.choose(index)
    local prompt = assert(f.prompts[index], "missing prompt " .. index)
    prompt.done(prompt.items[1], 1)
  end
  function f.start_guided()
    t.assert_true(O.start({ source_win = win }))
    f.choose(#f.prompts) -- uu's existing Platform row invokes real :UESetPlatform.
    t.assert_contains(f.prompts[#f.prompts].prompt, "Target Platform")
  end
  function f.enter_configuration()
    f.start_guided()
    f.choose(#f.prompts)
    t.assert_contains(f.prompts[#f.prompts].prompt, "Target Configuration")
    return f.prompts[#f.prompts]
  end
  local ok, err = pcall(check, f)
  O.cancel()
  vim.wait(5)
  for index = #restore, 1, -1 do restore[index]() end
  if api.nvim_win_is_valid(win) and api.nvim_buf_is_valid(previous) then
    api.nvim_win_set_buf(win, previous)
  end
  if api.nvim_buf_is_valid(buf) then api.nvim_buf_delete(buf, { force = true }) end
  if not ok then error(err, 0) end
end

t.describe("workbench onboarding: real platform-selection cancellation", function()
  t.it("cancelled platform callback cannot open configuration or change the target", function()
    fixture(function(f)
      f.start_guided()
      local count = #f.prompts
      t.assert_true(O.cancel())
      f.choose(count)
      t.assert_eq(#f.prompts, count)
      t.assert_eq(f.updates, 0)
      t.assert_eq(f.swaps, 0)
      t.assert_nil(O.current())
    end)
  end)

  t.it("cancelled configuration callback cannot publish or start a CDB fast swap", function()
    fixture(function(f)
      local prompt = f.enter_configuration()
      t.assert_true(O.cancel())
      prompt.done(prompt.items[1], 1)
      t.assert_eq(f.updates, 0)
      t.assert_eq(f.swaps, 0)
      t.assert_nil(O.current())
      t.assert_true(vim.bo[f.buf].modified)
    end)
  end)

  t.it("cancellation during the state commit prevents subsequent fast-swap work", function()
    fixture(function(f)
      f.enter_configuration()
      f.on_commit = O.cancel
      f.choose(#f.prompts)
      t.assert_eq(f.updates, 1, "the already authorized commit happened")
      t.assert_eq(f.swaps, 0, "cancellation must be rechecked after the commit")
      t.assert_nil(O.current())
    end)
  end)

  t.it("ordinary UESetPlatform still works after a guided picker was cancelled", function()
    fixture(function(f)
      local stale = f.enter_configuration()
      O.cancel()
      vim.cmd("UESetPlatform")
      f.choose(#f.prompts)
      f.choose(#f.prompts)
      t.assert_eq(f.updates, 1)
      t.assert_eq(f.swaps, 1)
      stale.done(stale.items[1], 1)
      t.assert_eq(f.updates, 1, "the old guided confirmation stays revoked")
      t.assert_eq(f.swaps, 1)
    end)
  end)

  t.it("source changes revoke a pending inner configuration confirmation", function()
    fixture(function(f)
      local prompt = f.enter_configuration()
      api.nvim_buf_set_lines(f.buf, 0, -1, false, { "new source intent" })
      prompt.done(prompt.items[1], 1)
      t.assert_eq(f.updates, 0)
      t.assert_eq(f.swaps, 0)
      t.assert_nil(O.current())
    end)
  end)

  t.it("old inner confirmations do not cancel or publish into a newer guide", function()
    fixture(function(f)
      local stale = f.enter_configuration()
      f.start_guided()
      local count = #f.prompts
      stale.done(stale.items[1], 1)
      t.assert_eq(#f.prompts, count)
      t.assert_eq(f.updates, 0)
      t.assert_eq(f.swaps, 0)
      t.assert_true(O.current() ~= nil, "the newer guide owns its own lifetime")
    end)
  end)

  t.it("an old target row cannot reopen its setter after the guide advanced", function()
    fixture(function(f)
      t.assert_true(O.start({ source_win = f.win }))
      local stale = f.prompts[1]
      f.target.platform, f.target.configuration = "Win64", "Development"
      H.selection_changed()
      t.assert_true(vim.wait(1000, function() return #f.prompts == 2 end, 5))
      t.assert_contains(f.prompts[2].items[1], "确认运行 :UEPrepare")
      stale.done(stale.items[1], 1)
      t.assert_eq(#f.prompts, 2, "an earlier row must not open a new platform picker")
      t.assert_eq(f.updates, 0)
      t.assert_eq(f.swaps, 0)
      t.assert_eq(O.current().stage, "prompt", "the prepare confirmation stays pending")
    end)
  end)

  t.it("changed device rejects old package discovery UI and its late selection callback", function()
    fixture(function(f)
      local device = require("utils.android_device")
      local packages = require("utils.android_package")
      local original_pick = packages.pick
      f.target.platform, f.target.configuration = "Android", "Development"
      f.serial, f.package_commits = "fixture-device-a", 0
      f.patch(H, "target_rows", f.actual_rows)
      f.patch(device, "get", function() return f.serial end)
      f.replace("current_engine_root", function() return f.target.engine_root end, f.core.set_android_package)
      f.patch(f.core.project_state, "commit", function()
        f.package_commits = f.package_commits + 1
        return true
      end)
      f.patch(packages, "pick", function(opts, done)
        f.package_device, f.package_done = opts.serial, done
        opts.system = function(_, _, finish) f.discovery_done = finish end
        return original_pick(opts, done)
      end)
      t.assert_true(O.start({ source_win = f.win }))
      t.assert_eq(f.prompts[1].items[1].label, "Package")
      f.choose(1)
      t.assert_eq(f.package_device, "fixture-device-a")
      t.assert_type(f.discovery_done, "function")
      f.serial = "fixture-device-b"
      H.selection_changed()
      f.discovery_done({ code = 0, stdout = "package:com.example.fixture\n" })
      vim.wait(30)
      t.assert_eq(#f.prompts, 1, "old-device discovery must not open a package picker")
      t.assert_nil(O.current(), "the obsolete dependency cannot leave the guide waiting without a picker")
      f.package_done("com.example.fixture")
      t.assert_eq(f.package_commits, 0, "old-device package selection must not be published")
    end)
  end)
end)
