local t = require("tests.harness")
t.bootstrap()

local config = require("ue.config")
local uv = vim.uv

local function write(path, bytes)
  local file = assert(io.open(path, "wb"))
  file:write(bytes)
  file:close()
end

local function fixture(steps, repo_tools, body)
  local names = {
    "ue.cdb.pipeline", "workarounds", "utils.task_registry",
    "workarounds.clangd.friend_template_canonical",
    "workarounds.clangd.header_path_case",
    "workarounds.clangd.legacy_android_warnings",
  }
  local saved = {}
  for _, name in ipairs(names) do saved[name] = package.loaded[name] end
  local options = vim.deepcopy(config.options())
  local unlink = uv.fs_unlink
  local root = vim.fs.normalize(vim.fn.tempname() .. "-pipeline-failures")
  vim.fn.mkdir(root, "p")
  local state = { path = root .. "/compile_commands.json", calls = {}, notices = {}, errors = {}, restarts = 0 }
  write(state.path, "[]")
  state.tools = repo_tools and (vim.fn.stdpath("config") .. "/tools") or (root .. "/missing-tools")
  local ok, err = xpcall(function()
    for _, name in ipairs(names) do
      if name:find("workarounds.clangd.", 1, true) == 1 then
        package.loaded[name] = { apply = function() end, configure_steps = function() end }
      end
    end
    package.loaded["workarounds"] = { status = function() return { enabled = false } end }
    package.loaded["utils.task_registry"] = { register = function() end }
    package.loaded["ue.cdb.pipeline"] = nil
    local pipeline = require("ue.cdb.pipeline")
    config.setup({ cdb = { steps = steps, tools_dir = state.tools } })
    pipeline.set_runtime({
      jobstart = function(command, _, callbacks)
        state.calls[#state.calls + 1] = { command = command, callbacks = callbacks }
        return 41
      end,
      notify = function(message, level)
        state.notices[#state.notices + 1] = { message = message, level = level }
      end,
      log_error = function(_, message) state.errors[#state.errors + 1] = message end,
      restart_clangd = function() state.restarts = state.restarts + 1 end,
    })
    state.pipeline = pipeline
    function state.run(overrides)
      return pipeline.run(state.path, { state.path }, function(success, reason)
        state.ok, state.reason = success, reason
      end, vim.tbl_extend("force", { _host_admitted = true, defer_restart = true }, overrides or {}))
    end
    function state.drain()
      local index = 1
      while pipeline.is_running() do
        t.assert_true(index <= 20, "fixture pipeline must finish within its bounded step list")
        assert(state.calls[index], "pipeline callback is missing").callbacks.on_exit(41, {})
        index = index + 1
      end
    end
    body(state)
  end, debug.traceback)
  uv.fs_unlink = unlink
  config.setup(options)
  for _, name in ipairs(names) do package.loaded[name] = saved[name] end
  if not ok then error(err) end
end

local function notice(state, text, level)
  for _, item in ipairs(state.notices) do
    if item.message:find(text, 1, true) and (not level or item.level == level) then return true end
  end
  return false
end

local function missing_step(state, name, phase)
  local jobid, reason = state.run({ force_restart = true, defer_restart = false })
  t.assert_nil(jobid)
  t.assert_eq(state.ok, false)
  t.assert_eq(state.reason, reason)
  t.assert_contains(reason, "ue-pipeline-" .. (phase or name:gsub("%.py$", "")))
  t.assert_contains(reason, state.tools .. "/" .. name)
  t.assert_eq(#state.calls, 0, "missing required scripts must fail before any stage starts")
  t.assert_eq(state.restarts, 0)
  t.assert_false(state.pipeline.is_running())
  t.assert_nil(uv.fs_stat(state.path .. ".writer.lock"))
  t.assert_nil(uv.fs_stat(state.path .. ".pipeline-result.json"))
  t.assert_eq(table.concat(vim.fn.readfile(state.path), "\n"), "[]")
end

t.describe("ue.cdb.pipeline required stages and cleanup failures", function()
  t.it("a missing configured script fails with its phase and exact path", function()
    fixture({ "expand_response_cdb.py" }, false, function(state)
      missing_step(state, "expand_response_cdb.py")
    end)
  end)

  t.it("a later missing required stage rejects the entire plan before starting an earlier stage", function()
    fixture({ "expand_response_cdb.py", "missing-x4-required-stage.py" }, true, function(state)
      missing_step(state, "missing-x4-required-stage.py")
    end)
  end)

  for _, with_origin in ipairs({ false, true }) do
    t.it(with_origin and "a missing receipt helper cannot skip origin sealing and completion"
      or "a missing receipt helper cannot skip the mandatory completion stage", function()
      fixture({ "expand_response_cdb.py" }, false, function(state)
        vim.fn.mkdir(state.tools, "p")
        local source = assert(io.open(vim.fn.stdpath("config") .. "/tools/expand_response_cdb.py", "rb"))
        local bytes = source:read("*a")
        source:close()
        write(state.tools .. "/expand_response_cdb.py", bytes)
        if with_origin then write(state.path .. ".unity-origin.json", '{"schema":1,"groups":[]}') end
        missing_step(state, "cdb_unity_receipt.py", "complete")
      end)
    end)
  end

  t.it("an explicitly empty step list keeps its successful no-op semantics", function()
    fixture({}, false, function(state)
      t.assert_eq(state.run(), 0)
      t.assert_eq(state.ok, true)
      t.assert_eq(#state.calls, 0)
      t.assert_eq(state.restarts, 0)
      t.assert_false(state.pipeline.is_running())
    end)
  end)

  if type(require("utils.platform").driver().pch_build_plan) == "function" then
    t.it("a host-supported configured PCH stage is required", function()
      fixture({ "prebuild_pch_v2.py" }, false, function(state)
        missing_step(state, "prebuild_pch_v2.py")
      end)
    end)
    t.skip("an unsupported host may skip the configured PCH stage", "current host provides pch_build_plan")
  else
    t.it("an unsupported host may skip the configured PCH stage", function()
      fixture({ "prebuild_pch_v2.py" }, false, function(state)
        t.assert_eq(state.run(), 0)
        t.assert_eq(state.ok, true)
        t.assert_eq(#state.calls, 0)
      end)
    end)
    t.skip("a host-supported configured PCH stage is required", "current host has no pch_build_plan")
  end

  for _, throws in ipairs({ false, true }) do
    t.it(throws and "a throwing unlink warns without reporting freed bytes"
      or "an unlink nil/error warns without reporting freed bytes", function()
      fixture({ "expand_response_cdb.py" }, true, function(state)
        local backup = state.path .. ".pre-pch.bak"
        write(backup, string.rep("B", 1024 * 1024))
        local unlink = uv.fs_unlink
        uv.fs_unlink = function(path, ...)
          if path == backup then
            if throws then error("injected EACCES") end
            return nil, "injected EACCES"
          end
          return unlink(path, ...)
        end
        state.run()
        state.drain()
        t.assert_eq(state.ok, true, "backup cleanup must not invalidate a successful CDB transform")
        t.assert_eq(assert(uv.fs_stat(backup)).size, 1024 * 1024)
        t.assert_true(notice(state, backup, vim.log.levels.WARN))
        t.assert_true(notice(state, "EACCES", vim.log.levels.WARN))
        t.assert_false(notice(state, "removed "))
        t.assert_false(notice(state, "freed "))
      end)
    end)
  end

  t.it("mixed unlink results count only the successful API result", function()
    fixture({ "expand_response_cdb.py" }, true, function(state)
      local failed = state.path .. ".pre-pch.bak"
      local successful = state.path .. ".pre-unify.bak"
      write(failed, string.rep("F", 2 * 1024 * 1024))
      write(successful, string.rep("S", 1024 * 1024))
      local unlink = uv.fs_unlink
      uv.fs_unlink = function(path, ...)
        if path == failed then return nil, "injected EACCES" end
        if path == successful then return true end
        return unlink(path, ...)
      end
      state.run()
      state.drain()
      t.assert_eq(state.ok, true)
      t.assert_true(notice(state, failed, vim.log.levels.WARN))
      t.assert_true(notice(state, "removed 1 intermediate backup(s), freed 1 MB", vim.log.levels.INFO))
      t.assert_false(notice(state, "removed 2 "))
    end)
  end)
end)
