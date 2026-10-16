local t = require("tests.harness")
local cfg = t.bootstrap()
local fs = require("ue.core.fs")

local function native_write(ctx, key, value, method)
  local report_path = ctx.project_root .. "/native-write-result.json"
  local code = string.format(
    [[
    local state = require('ue.project_state')
    assert(state.select(%q, %q, %q, {persist_default=false}))
    local ok, err = state[%q](%q, %q, %q)
    vim.fn.writefile({vim.json.encode({pid=vim.fn.getpid(),ok=ok,err=err or vim.NIL})}, %q)
  ]],
    ctx.engine_root,
    ctx.project_root,
    ctx.uproject,
    method or "update",
    ctx.engine_root,
    key,
    value,
    report_path
  )
  local result = vim
    .system({
      vim.v.progpath,
      "--headless",
      "-u",
      "NONE",
      "-i",
      "NONE",
      "--cmd",
      "set rtp+=" .. cfg,
      "-c",
      "lua " .. code,
      "-c",
      "qa!",
    }, { text = true })
    :wait(5000)
  t.assert_eq(result.code, 0, result.stderr)
  local report = vim.json.decode(table.concat(vim.fn.readfile(report_path), "\n"))
  t.assert_true(report.pid ~= vim.fn.getpid(), "the competing writer must be another native process")
  return report
end

local function package_key(state, ctx)
  local driver = require("ue.targets").driver(state.read(ctx.engine_root).target_platform)
  for _, row in ipairs(type(driver.hub) == "function" and driver.hub({}).fields or {}) do
    if row.name == "package" then
      return row.state_key
    end
  end
end

local function isolated(fn)
  local directory = fs.norm(vim.fn.tempname())
  vim.fn.mkdir(directory, "p")
  local state = assert(loadfile(cfg .. "/lua/ue/project_state.lua"))()
  local root = directory .. "/engine"
  local project = directory .. "/A/SameName"
  vim.fn.mkdir(project, "p")
  local file = project .. "/SameName.uproject"
  vim.fn.writefile({ "{}" }, file)
  assert(state.select(root, project, file, { persist_default = false }))
  local host = require("utils.platform").driver()
  local platform
  for _, id in ipairs(require("ue.targets").known_ids()) do
    if require("ue.targets").supports(id, "build", host) then
      platform = id
      break
    end
  end
  assert(platform, "native host must expose its build target")
  assert(state.update_target(root, platform, "Development"))
  local context = { engine_root = root, project_root = project, uproject = file }
  local options = {
    state = state,
    host_driver = host,
    resolve_context = function()
      return vim.deepcopy(context)
    end,
    get_device = function()
      return "SERIAL-A"
    end,
    set_target = function(p, c)
      return state.update_target(root, p, c)
    end,
    environment = function()
      return {}
    end,
  }
  local ok, err = pcall(fn, require("ue.run_profiles"), options, context, state, directory)
  vim.fn.delete(directory, "rf")
  if not ok then
    error(err, 0)
  end
end

t.describe("ide_run_profiles: project and instance ownership", function()
  t.it("saves independent per-name fields and never persists current device serial", function()
    isolated(function(profiles, options, ctx, state)
      local one, err = profiles.save("调试配置", vim.tbl_extend("force", options, { mode = "debug" }))
      t.assert_nil(err)
      t.assert_eq(one.name, "调试配置")
      t.assert_eq(one.mode, "debug")
      local two = assert(profiles.save("run", vim.tbl_extend("force", options, { mode = "run" })))
      local rows = assert(profiles.list(options))
      t.assert_eq(#rows, 2)
      local fields = state.project_cache_root(ctx.engine_root, state.current(ctx.engine_root)) .. "/state-fields"
      local count = 0
      for name, kind in vim.fs.dir(fields) do
        if kind == "file" and name:find("run_profile_", 1, true) == 1 then
          count = count + 1
          local bytes = table.concat(vim.fn.readfile(fields .. "/" .. name), "\n")
          t.assert_false(bytes:find("SERIAL-A", 1, true) ~= nil)
          t.assert_false(bytes:find('"serial"', 1, true) ~= nil)
        end
      end
      t.assert_eq(count, 2)
      t.assert_eq(two.mode, "run")
    end)
  end)

  t.it("same basename in another checkout has no profile leakage", function()
    isolated(function(profiles, options, ctx, state, directory)
      assert(profiles.save("only A", options))
      local other = directory .. "/B/SameName"
      vim.fn.mkdir(other, "p")
      local file = other .. "/SameName.uproject"
      vim.fn.writefile({ "{}" }, file)
      assert(state.select(ctx.engine_root, other, file, { persist_default = false }))
      ctx.project_root, ctx.uproject = other, file
      t.assert_eq(#assert(profiles.list(options)), 0)
      t.assert_nil(profiles.get("only A", options))
      t.assert_eq(profiles.mode(options), "debug")
    end)
  end)

  t.it("save validates write return and exact table readback, not just table presence", function()
    isolated(function(profiles, options, _, state)
      local original = state.update
      state.update = function()
        return false, "atomic write failed"
      end
      local value, err = profiles.save("failed", options)
      t.assert_nil(value)
      t.assert_contains(err, "atomic write failed")
      state.update = function(engine, key, _, captured)
        return original(engine, key, { name = "different contents" }, captured)
      end
      value, err = profiles.save("mismatched", options)
      t.assert_nil(value)
      t.assert_contains(err, "read-back")
    end)
  end)

  t.it("independent native processes save different names without losing profiles or inheriting active mode", function()
    isolated(function(profiles, options, ctx)
      assert(profiles.save("parent run", vim.tbl_extend("force", options, { mode = "run" })))
      options.ui_select = function(_, _, done)
        done("应用")
      end
      profiles.apply("parent run", options, function(ok, err)
        t.assert_true(ok, err)
      end)
      t.assert_eq(profiles.mode(options), "run")
      local code = string.format(
        [[
        local root, project, file, profile_name = %q, %q, %q, ...
        local state = require('ue.project_state')
        assert(state.select(root, project, file, {persist_default=false}))
        local opts = {state=state, resolve_context=function() return {engine_root=root,project_root=project,uproject=file} end,
          environment=function() return {} end}
        assert(require('ue.run_profiles').mode(opts)=='debug')
        assert(require('ue.run_profiles').save(profile_name,opts))
      ]],
        ctx.engine_root,
        ctx.project_root,
        ctx.uproject
      )
      local handles = {}
      for _, name in ipairs({ "process A", "process B" }) do
        local call = ("assert(loadstring(%q))(%q)"):format(code, name)
        handles[#handles + 1] = vim.system({
          vim.v.progpath,
          "--headless",
          "-u",
          "NONE",
          "-i",
          "NONE",
          "--cmd",
          "set rtp+=" .. cfg,
          "-c",
          "lua " .. call,
          "-c",
          "qa!",
        }, { text = true })
      end
      for _, handle in ipairs(handles) do
        local result = handle:wait(5000)
        t.assert_eq(result.code, 0, result.stderr)
      end
      local rows = assert(profiles.list(options))
      t.assert_eq(#rows, 3)
      t.assert_eq(rows[2].name, "process A")
      t.assert_eq(rows[3].name, "process B")
      t.assert_eq(profiles.mode(options), "run")
    end)
  end)
end)

t.describe("ide_run_profiles: preview and safe application", function()
  local function save_changed(profiles, options, ctx, state)
    assert(state.update_target(ctx.engine_root, state.read(ctx.engine_root).target_platform, "Test"))
    local profile = assert(profiles.save("test run", vim.tbl_extend("force", options, { mode = "run" })))
    assert(state.update_target(ctx.engine_root, profile.platform, "Development"))
    return profile
  end

  t.it("preview shows target/config/mode differences and cancel leaves selectors and device untouched", function()
    isolated(function(profiles, options, ctx, state)
      save_changed(profiles, options, ctx, state)
      local callback, prompt, result
      options.ui_select = function(_, opts, done)
        callback, prompt = done, opts.prompt
      end
      profiles.apply("test run", options, function(ok)
        result = ok
      end)
      t.assert_contains(prompt, "Development")
      t.assert_contains(prompt, "Test")
      t.assert_contains(prompt, "debug")
      t.assert_contains(prompt, "run")
      callback("取消")
      t.assert_false(result)
      t.assert_eq(state.read(ctx.engine_root).target_configuration, "Development")
      t.assert_eq(profiles.mode(options), "debug")
      t.assert_eq(options.get_device(), "SERIAL-A")
    end)
  end)

  t.it("verified readback accepts a setter that returns nil after a successful write", function()
    isolated(function(profiles, options, ctx, state)
      save_changed(profiles, options, ctx, state)
      options.set_target = function(p, c)
        assert(state.update_target(ctx.engine_root, p, c))
      end
      options.ui_select = function(_, _, done)
        done("应用")
      end
      local result, err
      profiles.apply("test run", options, function(ok, message)
        result, err = ok, message
      end)
      t.assert_true(result, err)
      t.assert_eq(state.read(ctx.engine_root).target_configuration, "Test")
      t.assert_eq(profiles.mode(options), "run")
    end)
  end)

  t.it("unchanged target and configuration skip the setter and all target publication for mode-only apply", function()
    isolated(function(profiles, options, ctx, state)
      assert(profiles.save("same target", vim.tbl_extend("force", options, { mode = "run" })))
      local setter_calls, target_writes = 0, 0
      local original = state.update_target
      state.update_target = function(...)
        target_writes = target_writes + 1
        return original(...)
      end
      options.set_target = function(p, c)
        setter_calls = setter_calls + 1
        return state.update_target(ctx.engine_root, p, c)
      end
      options.ui_select = function(_, _, done)
        done("应用")
      end
      profiles.apply("same target", options, function(ok, err)
        t.assert_true(ok, err)
      end)
      t.assert_eq(
        setter_calls,
        0,
        "do not enter set_platform/fast-swap or schedule prepare/restart on an unchanged tuple"
      )
      t.assert_eq(target_writes, 0, "a mode-only application must not publish target artifacts")
      t.assert_eq(profiles.mode(options), "run")
    end)
  end)

  t.it("failed target recovery preserves another native process's persisted pair hidden by the live overlay", function()
    isolated(function(profiles, options, ctx, state)
      local profile = save_changed(profiles, options, ctx, state)
      local setter_calls, applied, recovery = 0, nil, nil
      options.set_target = function(p, c)
        setter_calls = setter_calls + 1
        assert(state.update_target(ctx.engine_root, p, c))
        if c == profile.configuration then
          t.assert_true(native_write(ctx, p, "Shipping", "update_target").ok)
          t.assert_eq(
            state.read(ctx.engine_root).target_configuration,
            "Test",
            "other PID must not redirect the live tuple"
          )
          t.assert_eq(
            state.read(ctx.engine_root, ctx).target_configuration,
            "Shipping",
            "persisted pair must come from the real other writer"
          )
          return false, "controlled post-write target failure"
        end
        return true
      end
      options.ui_select = function(_, _, done)
        done("应用")
      end
      profiles.apply("test run", options, function(ok, _, detail)
        applied, recovery = ok, detail
      end)
      t.assert_false(applied)
      t.assert_eq(setter_calls, 1, "unproved target rollback must never call the previous setter")
      t.assert_eq(
        state.read(ctx.engine_root, ctx).target_configuration,
        "Shipping",
        "rollback must not replace the other PID's persisted pair"
      )
      t.assert_eq(state.read(ctx.engine_root).target_configuration, "Test")
      t.assert_eq(#recovery.blocked, 1)
      t.assert_contains(recovery.blocked[1], "target")
      t.assert_eq(profiles.mode(options), "debug")
    end)
  end)

  for _, latest in ipairs({ "Shipping", "Test" }) do
    t.it(
      "failed target setter preserves the process's latest " .. latest .. " tuple, including same-value ABA",
      function()
        isolated(function(profiles, options, ctx, state)
          local profile = save_changed(profiles, options, ctx, state)
          local setter_calls, applied, recovery = 0, nil, nil
          options.set_target = function(p, c)
            setter_calls = setter_calls + 1
            assert(state.update_target(ctx.engine_root, p, c))
            if c == profile.configuration then
              assert(state.update_target(ctx.engine_root, p, "Shipping"))
              assert(state.update_target(ctx.engine_root, p, latest))
              return false, "controlled post-write target failure"
            end
            return true
          end
          options.ui_select = function(_, _, done)
            done("应用")
          end
          profiles.apply("test run", options, function(ok, _, detail)
            applied, recovery = ok, detail
          end)
          t.assert_false(applied)
          t.assert_eq(setter_calls, 1, "the setter has no receipt proving it still owns the latest tuple")
          t.assert_eq(state.read(ctx.engine_root).target_configuration, latest)
          t.assert_eq(state.read(ctx.engine_root, ctx).target_configuration, latest)
          t.assert_eq(#recovery.blocked, 1)
          t.assert_contains(recovery.blocked[1], "target")
        end)
      end
    )
  end

  for _, same_value in ipairs({ false, true }) do
    t.it(
      "rollback preserves a second process's newer "
        .. (same_value and "same-value revision" or "package input")
        .. " at commit",
      function()
        isolated(function(profiles, options, ctx, state)
          local key = package_key(state, ctx)
          if not key then
            return t.skip("native profile package", "host target declares no package field")
          end
          assert(state.update(ctx.engine_root, key, "com.example.saved"))
          save_changed(profiles, options, ctx, state)
          assert(state.update(ctx.engine_root, key, "com.example.before"))
          local update, compare = state.update, state.compare_update
          local raced = false
          local external = same_value and "com.example.saved" or "com.example.externalnew"
          local function interleave(field, value)
            if field == key and value == "com.example.before" and not raced then
              raced = true
              t.assert_true(native_write(ctx, key, external).ok)
              t.assert_eq(state.read(ctx.engine_root, ctx)[key], external)
            end
          end
          -- Pause at the rollback publication boundary. Before CAS existed this
          -- boundary was update(); afterwards it must be the guarded operation.
          state.update = function(engine, field, value, captured)
            interleave(field, value)
            return update(engine, field, value, captured)
          end
          if compare then
            state.compare_update = function(engine, field, receipt, value, captured)
              interleave(field, value)
              return compare(engine, field, receipt, value, captured)
            end
          end
          options.ui_select = function(_, _, done)
            done("应用")
          end
          options.set_target = function(p, c)
            assert(state.update_target(ctx.engine_root, p, c))
            if c == "Test" then
              return false, "controlled post-write target failure"
            end
            return true
          end
          local applied, recovery
          profiles.apply("test run", options, function(ok, _, detail)
            applied, recovery = ok, detail
          end)
          t.assert_false(applied)
          t.assert_true(raced, "the external writer must execute at the actual rollback commit boundary")
          t.assert_eq(
            state.read(ctx.engine_root, ctx)[key],
            external,
            "rollback must retain the newer owner's exact input"
          )
          t.assert_eq(#recovery.blocked, 2, "target and newer package both require review")
          t.assert_eq(
            state.read(ctx.engine_root).target_configuration,
            "Test",
            "unproved target recovery stays blocked"
          )
        end)
      end
    )
  end

  t.it("CAS holds the per-field lease through publication and ordinary second-process writers honor it", function()
    isolated(function(_, _, ctx, state)
      local key = "cas_field"
      assert(state.update(ctx.engine_root, key, "before", ctx))
      local updated, update_err, receipt = state.update(ctx.engine_root, key, "attempt", ctx)
      t.assert_true(updated, update_err)
      t.assert_type(receipt, "table", "update must return a committed ownership receipt")
      local path = state.project_cache_root(ctx.engine_root, state.current(ctx.engine_root))
        .. "/state-fields/"
        .. key
        .. ".json"
      local rename, competing = vim.uv.fs_rename, nil
      local ok, err = pcall(function()
        vim.uv.fs_rename = function(from, to, ...)
          if to == path and not competing then
            competing = native_write(ctx, key, "external")
            t.assert_false(competing.ok, "the ordinary writer must lose to the held CAS lease")
            t.assert_contains(competing.err, "another Neovim")
          end
          return rename(from, to, ...)
        end
        local restored, restore_err = state.compare_update(ctx.engine_root, key, receipt, "before", ctx)
        t.assert_true(restored, restore_err)
      end)
      vim.uv.fs_rename = rename
      if not ok then
        error(err, 0)
      end
      t.assert_type(competing, "table")
      t.assert_eq(state.read(ctx.engine_root, ctx)[key], "before")
      t.assert_true(native_write(ctx, key, "external").ok, "the lease must release after CAS")
      t.assert_eq(state.read(ctx.engine_root, ctx)[key], "external")
    end)
  end)

  t.it("a busy package lease fails without writing or following up with a target switch", function()
    isolated(function(profiles, options, ctx, state)
      local key = package_key(state, ctx)
      if not key then
        return t.skip("native profile package", "host target declares no package field")
      end
      assert(state.update(ctx.engine_root, key, "com.example.saved"))
      save_changed(profiles, options, ctx, state)
      assert(state.update(ctx.engine_root, key, "com.example.before"))
      local path = state.project_cache_root(ctx.engine_root, state.current(ctx.engine_root))
        .. "/state-fields/"
        .. key
        .. ".json"
      local lock = require("ue.file_lock")
      local lease = assert(lock.acquire(path .. ".lock"))
      local calls, applied, reason = 0, nil, nil
      local ok, err = pcall(function()
        options.set_target = function()
          calls = calls + 1
        end
        options.ui_select = function(_, _, done)
          done("应用")
        end
        profiles.apply("test run", options, function(value, detail)
          applied, reason = value, detail
        end)
      end)
      t.assert_true(lock.release(lease))
      if not ok then
        error(err, 0)
      end
      t.assert_false(applied)
      t.assert_contains(reason, "another Neovim")
      t.assert_eq(calls, 0)
      t.assert_eq(state.read(ctx.engine_root, ctx)[key], "com.example.before")
      t.assert_eq(state.read(ctx.engine_root).target_configuration, "Development")
    end)
  end)

  t.it("a committed receipt survives failed profile readback and guards recovery", function()
    isolated(function(profiles, options, ctx, state)
      local key = package_key(state, ctx)
      if not key then
        return t.skip("native profile package", "host target declares no package field")
      end
      assert(state.update(ctx.engine_root, key, "com.example.saved"))
      save_changed(profiles, options, ctx, state)
      assert(state.update(ctx.engine_root, key, "com.example.before"))
      local read, compare = state.read, state.compare_update
      local mismatch, recovered = false, false
      state.read = function(engine, captured)
        local value, revision = read(engine, captured)
        if captured and value[key] == "com.example.saved" and not mismatch then
          mismatch = true
          value[key] = "read-back failure"
        end
        return value, revision
      end
      state.compare_update = function(engine, field, receipt, value, captured)
        recovered = true
        t.assert_type(receipt, "table", "readback failure must retain the successful write's receipt")
        return compare(engine, field, receipt, value, captured)
      end
      options.set_target = function()
        error("readback failure must stop before target selection")
      end
      options.ui_select = function(_, _, done)
        done("应用")
      end
      profiles.apply("test run", options, function(ok, err)
        t.assert_false(ok)
        t.assert_contains(err, "read-back")
      end)
      t.assert_true(mismatch)
      t.assert_true(recovered)
      t.assert_eq(read(ctx.engine_root, ctx)[key], "com.example.before")
    end)
  end)

  t.it("old writers without a receipt fail closed rather than using an unlocked rollback", function()
    isolated(function(profiles, options, ctx, state)
      local key = package_key(state, ctx)
      if not key then
        return t.skip("native profile package", "host target declares no package field")
      end
      assert(state.update(ctx.engine_root, key, "com.example.saved"))
      save_changed(profiles, options, ctx, state)
      assert(state.update(ctx.engine_root, key, "com.example.before"))
      local update = state.update
      state.update = function(...)
        local ok, err = update(...)
        return ok, err -- Legacy writer has no ownership proof.
      end
      options.set_target = function()
        error("missing receipt must stop before target selection")
      end
      options.ui_select = function(_, _, done)
        done("应用")
      end
      local applied, recovery
      profiles.apply("test run", options, function(ok, _, detail)
        applied, recovery = ok, detail
      end)
      t.assert_false(applied)
      t.assert_eq(#recovery.blocked, 1)
      t.assert_eq(state.read(ctx.engine_root, ctx)[key], "com.example.saved", "unproved writes must not be rolled back")
      t.assert_eq(profiles.mode(options), "debug")
    end)
  end)

  t.it("applying a profile leaves the already-running loop on its immutable original context", function()
    isolated(function(profiles, options, ctx, state)
      save_changed(profiles, options, ctx, state)
      local iterate = require("ue.workflows.android.iterate")
      local snapshot = require("ue.workflows._runtime").snapshot({
        project = ctx.project_root,
        target = "Android",
        configuration = "Development",
        device = { serial = "SERIAL-A" },
        operation = "iterate",
        owner = "test",
      })
      local run = iterate.run({
        set_status = function() end,
        build_so = function()
          return { cancel = function() end }
        end,
      }, { snapshot = snapshot, notify = function() end })
      local ok, err = pcall(function()
        options.ui_select = function(_, _, done)
          done("应用")
        end
        profiles.apply("test run", options, function(applied, reason)
          t.assert_true(applied, reason)
        end)
        t.assert_eq(run.status, "running")
        t.assert_eq(run.snapshot, snapshot)
        t.assert_eq(run.snapshot.configuration, "Development")
        t.assert_eq(profiles.mode(options), "run")
      end)
      run:cancel()
      if not ok then
        error(err, 0)
      end
    end)
  end)

  t.it("project switch or changed selectors during preview reject stale application", function()
    isolated(function(profiles, options, ctx, state, directory)
      save_changed(profiles, options, ctx, state)
      local callback, result, reason
      options.ui_select = function(_, _, done)
        callback = done
      end
      profiles.apply("test run", options, function(ok, err)
        result, reason = ok, err
      end)
      assert(state.update_target(ctx.engine_root, state.read(ctx.engine_root).target_platform, "Shipping"))
      callback("应用")
      t.assert_false(result)
      t.assert_contains(reason, "changed")
      t.assert_eq(state.read(ctx.engine_root).target_configuration, "Shipping")
      assert(state.update_target(ctx.engine_root, state.read(ctx.engine_root).target_platform, "Development"))
      profiles.apply("test run", options, function(ok, err)
        result, reason = ok, err
      end)
      local other = directory .. "/Other"
      vim.fn.mkdir(other, "p")
      assert(state.select(ctx.engine_root, other, nil, { persist_default = false }))
      ctx.project_root, ctx.uproject = other, nil
      callback("应用")
      t.assert_false(result)
      t.assert_contains(reason, "changed")
    end)
  end)

  t.it("failed target setter or ineffective readback never changes the run mode", function()
    isolated(function(profiles, options, ctx, state)
      save_changed(profiles, options, ctx, state)
      options.ui_select = function(_, _, done)
        done("应用")
      end
      for _, setter in ipairs({
        function()
          return false, "target write failed"
        end,
        function()
          return true
        end,
      }) do
        options.set_target = setter
        local ok, reason
        profiles.apply("test run", options, function(value, err)
          ok, reason = value, err
        end)
        t.assert_false(ok)
        t.assert_true(type(reason) == "string")
        t.assert_eq(profiles.mode(options), "debug")
        t.assert_eq(state.read(ctx.engine_root).target_configuration, "Development")
      end
    end)
  end)

  t.it("target failure restores the profile's package write while preserving newer external input", function()
    isolated(function(profiles, options, ctx, state)
      local platform = state.read(ctx.engine_root).target_platform
      local driver = require("ue.targets").driver(platform)
      local key
      for _, row in ipairs(type(driver.hub) == "function" and driver.hub({}).fields or {}) do
        if row.name == "package" then
          key = row.state_key
        end
      end
      if not key then
        return t.skip("profile package recovery", "native target declares no package field")
      end
      assert(state.update(ctx.engine_root, key, "com.example.saved"))
      save_changed(profiles, options, ctx, state)
      assert(state.update(ctx.engine_root, key, "com.example.before"))
      options.ui_select = function(_, _, done)
        done("应用")
      end
      for _, external in ipairs({ false, true }) do
        assert(state.update_target(ctx.engine_root, platform, "Development"))
        assert(state.update(ctx.engine_root, key, "com.example.before"))
        options.set_target = function(p, c)
          assert(state.update_target(ctx.engine_root, p, c))
          if c == "Test" then
            if external then
              assert(state.update(ctx.engine_root, key, "com.example.newinput"))
            end
            return false, "post-write target error"
          end
          return true
        end
        local ok, reason, recovery
        profiles.apply("test run", options, function(value, err, detail)
          ok, reason, recovery = value, err, detail
        end)
        t.assert_false(ok)
        t.assert_contains(reason, "post-write target error")
        t.assert_eq(
          state.read(ctx.engine_root).target_configuration,
          "Test",
          "target recovery lacks an ownership receipt"
        )
        t.assert_eq(state.read(ctx.engine_root)[key], external and "com.example.newinput" or "com.example.before")
        t.assert_eq(#recovery.blocked, external and 2 or 1)
        t.assert_contains(recovery.blocked[1], "target")
        t.assert_eq(profiles.mode(options), "debug")
      end
    end)
  end)

  t.it("changing the saved profile or the process device during preview refuses old intent", function()
    isolated(function(profiles, options, ctx, state)
      local profile = save_changed(profiles, options, ctx, state)
      local callback, result, reason, serial = nil, nil, nil, "SERIAL-A"
      options.get_device = function()
        return serial
      end
      options.ui_select = function(_, _, done)
        callback = done
      end
      profiles.apply("test run", options, function(ok, err)
        result, reason = ok, err
      end)
      serial = "SERIAL-B"
      callback("应用")
      t.assert_false(result)
      t.assert_contains(reason, "changed")
      serial = "SERIAL-A"
      profiles.apply("test run", options, function(ok, err)
        result, reason = ok, err
      end)
      local key = "run_profile_" .. vim.fn.sha256(profile.name:lower())
      profile.mode = "debug"
      assert(state.update(ctx.engine_root, key, profile))
      callback("应用")
      t.assert_false(result)
      t.assert_contains(reason, "Saved profile changed")
      t.assert_eq(state.read(ctx.engine_root).target_configuration, "Development")
    end)
  end)

  t.it("effective environment override that conflicts with the profile is rejected before writes", function()
    isolated(function(profiles, options, ctx, state)
      save_changed(profiles, options, ctx, state)
      options.environment = function()
        return { configuration = "Shipping" }
      end
      local result, err
      profiles.apply("test run", options, function(ok, message)
        result, err = ok, message
      end)
      t.assert_false(result)
      t.assert_contains(err, "environment")
      t.assert_eq(state.read(ctx.engine_root).target_configuration, "Development")
    end)
  end)
end)
