local t = require("tests.harness")
local cfg = t.bootstrap()
local lazy = vim.fn.stdpath("data") .. "/lazy/"
local required = { "lazy.nvim", "LazyVim", "codediff.nvim", "diffview.nvim", "gitsigns.nvim", "plenary.nvim", "snacks.nvim" }
for _, name in ipairs(required) do
  if vim.fn.isdirectory(lazy .. name) == 0 then
    t.skip("Git review installed LazyVim runtime", "Missing installed plugin: " .. name, { native = true })
    return
  end
end

t.describe("git review actual LazyVim runtime", function()
  t.it("keeps final mappings and both review tools independent in either opening order", function()
    require("tests.helpers.git_review_fixture").with_repo(function(f)
      f.baseline("one\ntwo\nthree\n")
      f.write("one changed\ntwo\nthree\n")
      local scratch = vim.fn.tempname()
      vim.fn.mkdir(scratch, "p")
      local script = scratch .. "/runtime.lua"
      local code = string.format([[
local root = %q
local function checkpoint(label)
  io.stderr:write("GIT_REVIEW_RUNTIME_STAGE: " .. label .. "\n")
  io.stderr:flush()
end
-- CI on Linux/macOS exits 124 (outer timeout) inside a 12 s vim.wait, so the
-- event loop itself is blocked. A fast-context timer still fires during input
-- waits; report the editor mode to tell a pending prompt from a busy loop.
local watchdog = vim.uv.new_timer()
watchdog:start(15000, 15000, function()
  local mode = vim.api.nvim_get_mode()
  io.stderr:write("GIT_REVIEW_RUNTIME_WATCHDOG: mode=" .. mode.mode .. " blocking=" .. tostring(mode.blocking) .. "\n")
  io.stderr:flush()
end)
local ok, err = xpcall(function()
  checkpoint("startup loaded")
  assert(package.loaded["lazy"] and package.loaded["lazyvim.config"], "real LazyVim startup did not load")
  assert(require("lazy.core.config").options.install.missing == false)
  assert(require("lazy.core.config").options.checker.enabled == false)
  -- Headless has no UIEnter, which is Lazy's normal VeryLazy trigger.
  vim.api.nvim_exec_autocmds("User", { pattern = "VeryLazy", modeline = false })
  checkpoint("VeryLazy loaded")
  assert(package.loaded["config.keymaps"], "VeryLazy did not load the real project keymaps")
  require("lazy").load({ plugins = { "codediff.nvim", "diffview.nvim", "gitsigns.nvim" } })
  checkpoint("review plugins loaded")
  local review = require("utils.git_review")
  local plugins = require("lazy.core.config").plugins
  assert(not plugins["advanced-git-search.nvim"] and not plugins["telescope.nvim"], "removed dependencies remain active")
  assert(plugins["codediff.nvim"].commit == "09d9ebef2cc5a5c04db7a349cd6c61bdf84ecc8e")
  local sources = require("snacks").config.get("picker").sources
  for _, source in ipairs({ "git_log", "git_log_file", "git_log_line", "git_status" }) do
    assert(type(sources[source].confirm) == "function", "missing review confirmation: " .. source)
  end
  local errors = {}
  local notify = vim.notify
  vim.notify = function(message, level, opts)
    if level and level >= vim.log.levels.ERROR then errors[#errors + 1] = tostring(message) end
    return notify(message, level, opts)
  end
  local function wait(predicate, label)
    checkpoint("wait: " .. label)
    if not vim.wait(12000, predicate, 20) then
      local messages = vim.api.nvim_exec2("messages", { output = true }).output
      error(label .. ": " .. table.concat(errors, "\n") .. "\nbuf=" .. vim.api.nvim_buf_get_name(0)
        .. " gitsigns=" .. vim.inspect(vim.b.gitsigns_status_dict) .. " hs=" .. vim.inspect(vim.fn.maparg(" hs", "n", false, true).desc)
        .. " git=" .. vim.fn.system({ "git", "--version" }) .. "\nmessages:\n" .. messages)
    end
    checkpoint("ready: " .. label)
  end
  local function mapping(key, mode)
    local value = vim.fn.maparg(" " .. key, mode or "n", false, true)
    assert(next(value), "missing mapping " .. key)
    return value
  end
  local function invoke(key)
    checkpoint("invoke: " .. key)
    local value = mapping(key)
    if value.callback then value.callback() else vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(value.rhs, true, false, true), "nx", false) end
  end
  vim.cmd.edit(vim.fn.fnameescape(root .. "/review.txt"))
  checkpoint("editing fixture")
  local editing_buf, editing_win, editing_tab = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win(), vim.api.nvim_get_current_tabpage()
  wait(function() return vim.fn.maparg(" hs", "n", false, true).desc == "Git: stage current unstaged hunk" end, "Gitsigns did not attach")
  local ordinary = mapping("hs").callback
  local function assert_maps()
    assert(mapping("gg").desc == "CodeDiff: review changes")
    assert(mapping("gG").desc == "CodeDiff: cwd repository")
    assert(mapping("gh").desc == "Git: search changed content")
    assert(mapping("gv").desc == "Diffview: working tree")
    assert(mapping("gV").rhs:find("DiffviewClose", 1, true))
    assert(mapping("gv", "x").desc == "Diffview: selection history")
    mapping("vg")
    for _, mode in ipairs({ "n", "x" }) do
      for _, map in ipairs(vim.list_extend(vim.api.nvim_get_keymap(mode), vim.api.nvim_buf_get_keymap(editing_buf, mode))) do
        assert(not map.lhs:match("^ gh.+"), "old hunk prefix survived: " .. map.lhs)
      end
    end
  end
  assert_maps()
  local lifecycle = require("codediff.ui.lifecycle")
  local lib = require("diffview.lib")
  local function code_open(key)
    invoke(key)
    wait(function() local s = review.session(); return s and s.stored_diff_result and s.modified.relative == "review.txt" end, "CodeDiff did not open")
    return vim.api.nvim_get_current_tabpage()
  end
  local function diff_open()
    invoke("gv")
    wait(function() local view = lib.get_current_view(); return view and view.cur_entry and view.cur_layout and view.cur_layout:get_main_win():is_file_open() end, "Diffview did not open")
    return lib.get_current_view()
  end
  local function back_to_editing()
    vim.api.nvim_set_current_tabpage(editing_tab)
    vim.api.nvim_set_current_win(editing_win)
    vim.api.nvim_set_current_buf(editing_buf)
    wait(function() return mapping("hs").callback == ordinary end, "ordinary hunk mapping was not restored")
    assert_maps()
  end
  local codediff = code_open("gg")
  local diffview = diff_open()
  local first_diff_tab = diffview.tabpage
  assert(lifecycle.get_session(codediff), "Diffview closed the CodeDiff session")
  invoke("gV")
  wait(function() return not vim.api.nvim_tabpage_is_valid(first_diff_tab) end, "DiffviewClose did not close its own tab")
  assert(lifecycle.get_session(codediff), "DiffviewClose destroyed CodeDiff")
  vim.api.nvim_set_current_tabpage(codediff)
  assert(lifecycle.close(codediff))
  back_to_editing()
  diffview = diff_open()
  local diff_tab = diffview.tabpage
  codediff = code_open("gG")
  assert(vim.api.nvim_tabpage_is_valid(diff_tab), "CodeDiff closed Diffview")
  assert(lifecycle.close(codediff))
  vim.api.nvim_set_current_tabpage(diff_tab)
  assert(lib.get_current_view() == diffview, "CodeDiff close changed the other review")
  vim.api.nvim_set_current_win(diffview.cur_layout:get_main_win().id)
  assert(vim.fn.maparg("q", "n", false, true).rhs:find("DiffviewClose", 1, true), "CodeDiff stole Diffview's close key")
  invoke("gV")
  back_to_editing()
  codediff = code_open("vg")
  assert(lifecycle.close(codediff))
  back_to_editing()
  vim.fn.setpos("'<", { editing_buf, 2, 1, 0 })
  vim.fn.setpos("'>", { editing_buf, 3, 1, 0 })
  mapping("gv", "x").callback()
  wait(function()
    local view = lib.get_current_view()
    return view and view.panel and view.panel.entries and #view.panel.entries > 0
  end, "visual Diffview file history did not open")
  invoke("gV")
  back_to_editing()
  assert(#errors == 0, table.concat(errors, "\n"))
  print("GIT_REVIEW_RUNTIME_OK")
end, debug.traceback)
if not ok then io.stderr:write(tostring(err) .. "\n"); vim.cmd("cquit 1") else vim.cmd("qa!") end
]], f.root)
      vim.fn.writefile(vim.split(code, "\n", { plain = true }), script)
      local handle = vim.system({ vim.v.progpath, "--headless", "-u", cfg .. "/init.lua", "-i", "NONE", "-n",
        "-c", "lua dofile(" .. string.format("%q", script) .. ")" }, {
        text = true, cwd = f.root, timeout = 60000,
        env = vim.tbl_extend("force", vim.fn.environ(), {
          NVIM_CORE_HEALTH_NO_MUTATE = "1", XDG_STATE_HOME = scratch .. "/state", XDG_CACHE_HOME = scratch .. "/cache",
          NVIM_UE_LOG_DIR = scratch .. "/logs", NVIM_UE_PROBE_PATH = scratch .. "/probes.json",
        }),
      })
      -- CI (Linux/macOS) showed the child's own event loop stops: neither its
      -- 12 s vim.wait nor a libuv watchdog timer fire. Snapshot its process
      -- tree from outside before the 60 s kill to see what it blocks on.
      local snapshot
      if not require("utils.platform").is_windows then
        vim.wait(40000, function() return handle:is_closing() end, 100)
        if not handle:is_closing() then
          local tree = vim.system({ "ps", "-ax", "-o", "pid,ppid,stat,etime,command" }, { text = true }):wait(5000)
          local keep = {}
          for line in vim.gsplit(tree.stdout or "", "\n", { plain = true }) do
            if line:find("nvim", 1, true) or line:find("git", 1, true) or line:find("PID", 1, true) then
              keep[#keep + 1] = line:sub(1, 240)
            end
          end
          snapshot = "\nprocess snapshot at 40s (child pid " .. tostring(handle.pid) .. "):\n"
            .. table.concat(keep, "\n")
        end
      end
      local result = handle:wait()
      vim.fn.delete(scratch, "rf")
      t.assert_eq(result.code, 0, tostring(result.stderr) .. (snapshot or ""))
      t.assert_contains((result.stdout or "") .. (result.stderr or ""), "GIT_REVIEW_RUNTIME_OK")
      t.assert_eq(f.read(), "one changed\ntwo\nthree\n")
      t.assert_eq(f.git({ "show", ":review.txt" }), "one\ntwo\nthree\n")
    end)
  end)
end)
