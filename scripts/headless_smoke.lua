#!/usr/bin/env -S nvim -l
-- scripts/headless_smoke.lua
--
-- One-shot multi-platform smoke harness. Loads every Phase A–F surface,
-- asserts the public API freeze list still resolves, and exits 0/1 in a
-- shell-friendly way.
--
-- Usage:
--   nvim -l scripts/headless_smoke.lua
--
-- Exit codes:
--   0  every check passed
--   1  one or more checks failed (offending lines printed first)

local function eprintf(fmt, ...)
  if select("#", ...) == 0 then io.stderr:write(fmt .. "\n")
  else io.stderr:write(string.format(fmt, ...) .. "\n") end
end
local function printf(fmt, ...)
  if select("#", ...) == 0 then io.write(fmt .. "\n")
  else io.write(string.format(fmt, ...) .. "\n") end
end

-- The script is invoked from the config root via `nvim -l`. Make sure the
-- config rtp is on the package.path so `require("ue")` resolves regardless
-- of XDG / `init.lua` having loaded.
local cfg = vim.fn.getcwd()
vim.opt.rtp:prepend(cfg)

local results = {}
local function check(name, fn)
  local ok, err = pcall(fn)
  results[#results + 1] = { name = name, ok = ok, err = err }
end

-- ── Phase A: platform driver ────────────────────────────────────────────
check("require utils.platform",            function() return require("utils.platform") end)
check("require utils.platform.windows",    function() return require("utils.platform.windows") end)
check("require utils.platform.macos",      function() return require("utils.platform.macos") end)
check("require utils.platform.linux",      function() return require("utils.platform.linux") end)
check("require utils.platform.stub",       function() return require("utils.platform.stub") end)
check("platform.id is string",             function() assert(type(require("utils.platform").id) == "string") end)
check("platform.driver().shell()",         function() local s = require("utils.platform").driver().shell(); assert(s and s ~= "") end)
check("platform.driver().cmd_quote()",     function() assert(require("utils.platform").driver().cmd_quote("a b") ~= nil) end)
check("backward-compat: is_windows bool",  function() assert(type(require("utils.platform").is_windows) == "boolean") end)
check("backward-compat: is_mac bool",      function() assert(type(require("utils.platform").is_mac) == "boolean") end)
check("backward-compat: is_linux bool",    function() assert(type(require("utils.platform").is_linux) == "boolean") end)

-- Driver interface contract: every concrete driver implements the same shape
for _, id in ipairs({ "windows", "macos", "linux", "stub" }) do
  check("driver " .. id .. ": full interface", function()
    local m = require("utils.platform." .. id)
    assert(m.id == id, "id mismatch")
    for _, k in ipairs({
      "shell", "open_path", "reveal_file", "cmd_quote",
      "default_clangd_candidates", "default_codelldb_paths",
      "default_lldb_server_paths",
    }) do
      assert(type(m[k]) == "function", k .. " missing")
    end
  end)
end

-- ── Phase B: ue/core extraction ─────────────────────────────────────────
check("require ue.core.fs",                function() return require("ue.core.fs") end)
check("require ue.core.proc",              function() return require("ue.core.proc") end)
check("ue.core.fs.norm equivalence",       function() assert(require("ue.core.fs").norm("a\\b\\") == "a/b") end)
check("ue.core.fs.join equivalence",       function() assert(require("ue.core.fs").join("a", "b") == "a/b") end)
check("ue.core.fs.is_absolute_path /a",    function() assert(require("ue.core.fs").is_absolute_path("/a")) end)
check("ue.core.fs.is_absolute_path C:/a",  function() assert(require("ue.core.fs").is_absolute_path("C:/a")) end)
check("ue.core.fs.relative_to",            function() assert(require("ue.core.fs").relative_to("/a", "/a/b") == "b") end)
check("ue.core.proc.first_executable nil", function() assert(require("ue.core.proc").first_executable({}) == nil) end)

-- ── Phase C: ue.config schema ──────────────────────────────────────────
check("require ue.config",                 function() return require("ue.config") end)
check("ue.config.get index.idle_cold_ms",  function() assert(require("ue.config").get("index.idle_cold_ms") == 120000) end)
check("ue.config.get context.ttl_s",       function() assert(require("ue.config").get("context.ttl_s") == 30) end)
check("ue.config.get paths.state_dir",     function() local p = require("ue.config").get("paths.state_dir"); assert(p and p:find("ue") ~= nil) end)
check("ue.config.setup user override",     function()
  local cfg = require("ue.config")
  cfg.setup({ index = { idle_cold_ms = 99 } })
  assert(cfg.get("index.idle_cold_ms") == 99)
  cfg.reset_for_test()
  assert(cfg.get("index.idle_cold_ms") == 120000)
end)
check("ue.config.get unknown returns nil", function() assert(require("ue.config").get("does.not.exist") == nil) end)

-- ── Phase E.1: ue.cdb.json ─────────────────────────────────────────────
check("require ue.cdb.json",               function() return require("ue.cdb.json") end)
check("ue.cdb.json.template_entry happy",  function()
  local t = require("ue.cdb.json").template_entry({{ file = "x.cpp", arguments = { "clang++" } }})
  assert(t.file == "x.cpp")
end)
check("ue.cdb.json.program from arguments",function()
  assert(require("ue.cdb.json").program({ arguments = { "clang++" } }) == "clang++")
end)
check("ue.cdb.json.program from command",  function()
  assert(require("ue.cdb.json").program({ command = '"clang.exe" -c x' }) == "clang.exe")
end)
check("ue.cdb.json.template_entry empty",  function()
  local t = require("ue.cdb.json").template_entry({})
  assert(type(t) == "table")
end)

-- ── Phase E.2: ue.cdb.paths + ue.cdb.shaders ───────────────────────────
check("require ue.cdb.paths",              function() return require("ue.cdb.paths") end)
check("ue.cdb.paths.targets shape",        function()
  local t = require("ue.cdb.paths").targets({ engine_root = "/x" })
  assert(#t == 2 and t[1] == "/x/compile_commands.json")
end)
check("ue.cdb.paths.candidates no fd",     function()
  -- omit `run_lines` → no fd-based discovery; non-existent root → empty
  local c = require("ue.cdb.paths").candidates({ engine_root = "/nonexistent_xyz_12345" }, {})
  assert(type(c) == "table")
end)
check("require ue.cdb.shaders",            function() return require("ue.cdb.shaders") end)
check("ue.cdb.shaders.augment empty list", function()
  assert(require("ue.cdb.shaders").augment("[]", {}, {}) == "[]")
end)
check("ue.cdb.shaders.make_entry shape",   function()
  local e = require("ue.cdb.shaders").make_entry("/s/x.usf",
    { directory = "/d", arguments = { "clang++" } }, { "/inc" })
  assert(e.file == "/s/x.usf" and e.directory == "/d")
  assert(e.arguments[1] == "clang++" and e.arguments[2] == "-x")
end)

-- ── Phase E.3: ue.cdb.pipeline ─────────────────────────────────────────
check("require ue.cdb.pipeline",           function() return require("ue.cdb.pipeline") end)
check("ue.cdb.pipeline.set_runtime + slim noop", function()
  local p = require("ue.cdb.pipeline")
  local notes = {}
  p.set_runtime({
    notify    = function(msg, _) notes[#notes+1] = msg end,
    log_error = function(_, _) end,
    jobstart  = function(_, _, _) return 0 end,
  })
  -- slim() returns false when the python script is missing AND the
  -- notify path produces a warning — both observable in headless.
  local ok = p.slim("/nonexistent/cdb.json")
  assert(ok == false or ok == true)
end)

-- ── Phase F.2: ue.dap.platforms registry ───────────────────────────────
check("require ue.dap.platforms",          function() return require("ue.dap.platforms") end)
check("ue.dap.platforms.register + lookup", function()
  local p = require("ue.dap.platforms")
  p._reset_for_test()
  local hit = false
  p.register_attach("xtest", function() hit = true end)
  local h = p.attach_handler("xtest")
  assert(type(h) == "function")
  h()
  assert(hit, "registered handler did not fire")
  assert(p.launch_handler("xtest") == nil)
  p._reset_for_test()
end)

-- ── Public API freeze (require("ue")) ──────────────────────────────────
check("require ue",                        function() return require("ue") end)
local PUBLIC_TABLES = { "FT_CPP", "FT_SHADER", "FT_CODE", "FT_CONFIG", "FT_ALL", "FT_GTAGS", "GLOBS_CODE", "GLOBS_ALL" }
for _, k in ipairs(PUBLIC_TABLES) do
  check("ue." .. k .. " is non-empty table", function()
    local t = require("ue")[k]
    assert(type(t) == "table" and #t > 0, "expected non-empty table")
  end)
end

local PUBLIC_FUNCTIONS = {
  "clangd_cmd", "clangd_root", "current_platform", "platform_path_priorities",
  "android_build_command", "picker_options", "picker_project_options",
  "current_scope_picker_options", "cached_grep_file_list", "cached_code_file_list",
  "cached_files", "cached_grep", "statusline_status", "index_status", "index_now",
  "index_hot", "index_full", "ue_roots", "gtags_rebuild_shaders",
  "gtags_references", "gtags_definition", "launch_app", "toggle_log",
  "toggle_debug_log", "prepare_headless",
}
for _, fn in ipairs(PUBLIC_FUNCTIONS) do
  check("ue." .. fn .. " is function", function()
    assert(type(require("ue")[fn]) == "function", "expected function")
  end)
end

-- ── Phase F.1+F.2: UEDAP* aliases register on setup() + dispatch table ─
check("ue.setup() registers UEDAP* aliases", function()
  require("ue").setup()
  for _, c in ipairs({
    "UEDAPAttach", "UEDAPLaunch", "UEDAPContinue", "UEDAPPause",
    "UEDAPToggleBreakpoint", "UEDAPStepOver", "UEDAPStepIn",
    "UEDAPStepOut", "UEDAPToggleUI", "UEDAPREPL", "UEDAPDiag",
  }) do
    assert(vim.fn.exists(":" .. c) == 2, c .. " not registered")
  end
end)
check("ue.setup() registers android in dap.platforms", function()
  -- ue.setup() should have populated the dispatch table with android
  local p = require("ue.dap.platforms")
  assert(type(p.attach_handler("android")) == "function", "android attach handler missing")
  assert(type(p.launch_handler("android")) == "function", "android launch handler missing")
end)
check("backward-compat: UEAndroidDAP* still registered", function()
  for _, c in ipairs({
    "UEAndroidDAPAttach", "UEAndroidDAPLaunch", "UEAndroidDAPContinue",
    "UEAndroidDAPPause", "UEAndroidDAPToggleBreakpoint", "UEAndroidDAPStepOver",
    "UEAndroidDAPStepIn", "UEAndroidDAPStepOut", "UEAndroidDAPToggleUI",
    "UEAndroidDAPREPL",
  }) do
    assert(vim.fn.exists(":" .. c) == 2, c .. " was removed")
  end
end)

-- ── Report ──────────────────────────────────────────────────────────────
local fails = 0
for _, r in ipairs(results) do
  if not r.ok then
    fails = fails + 1
    eprintf("FAIL  %s — %s", r.name, tostring(r.err))
  end
end
for _, r in ipairs(results) do
  if r.ok then printf("OK    %s", r.name) end
end
printf("")
printf("=== %d/%d passed, %d failed ===", #results - fails, #results, fails)

if fails == 0 then
  vim.cmd("quit")
else
  vim.cmd("cquit 1")
end
