local t = require("tests.harness")
t.bootstrap()
local entities = require("utils.ue_entities")

local function write(path, bytes)
  local f = assert(io.open(path, "wb"))
  f:write(bytes)
  f:close()
end

local function read(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local bytes = f:read("*a")
  f:close()
  return bytes
end

local function fixture(fn)
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir .. "/Source/Game/Public/Gameplay", "p")
  vim.fn.mkdir(dir .. "/Source/Game/Private/Gameplay", "p")
  write(
    dir .. "/Game.uproject",
    vim.json.encode({ Modules = { { Name = "Game", Type = "Runtime" }, { Name = "Missing" } } })
  )
  write(dir .. "/Source/Game/Game.Build.cs", "using UnrealBuildTool; public class Game : ModuleRules {}\n")
  local ctx = { engine_root = dir, project_root = dir, uproject = dir .. "/Game.uproject" }
  local ok, err = pcall(fn, dir, ctx)
  vim.fn.delete(dir, "rf")
  if not ok then
    error(err)
  end
end

t.describe("IDE UE entities: explicit module and safe two-file creation", function()
  t.it("only descriptor modules with Build.cs are offered; templates preserve module/API/generated include", function()
    fixture(function(dir, ctx)
      local modules = assert(entities.discover(ctx))
      t.assert_eq(#modules, 1)
      t.assert_eq(modules[1].name, "Game")
      for _, row in ipairs({
        { "object", "UMyObject", "UObject", "UObject/Object.h" },
        { "actor", "AMyActor", "AActor", "GameFramework/Actor.h" },
        { "component", "UMyComponent", "UActorComponent", "Components/ActorComponent.h" },
      }) do
        local plan =
          assert(entities.plan(ctx, { module = "Game", kind = row[1], name = row[2], directory = "Gameplay" }))
        t.assert_contains(plan.files[1].content, "class GAME_API " .. row[2] .. " : public " .. row[3])
        t.assert_contains(
          plan.files[1].content,
          '#include "' .. row[4] .. '"\n#include "' .. row[2]:sub(2) .. '.generated.h"'
        )
        t.assert_contains(plan.files[1].path, "/Public/Gameplay/" .. row[2]:sub(2) .. ".h")
        t.assert_contains(plan.files[2].path, "/Private/Gameplay/" .. row[2]:sub(2) .. ".cpp")
        t.assert_contains(plan.files[2].content, '#include "Gameplay/' .. row[2]:sub(2) .. '.h"')
      end
      t.assert_nil(read(dir .. "/Source/Game/Public/Gameplay/MyObject.h"))
    end)
  end)

  t.it("invalid kind/prefix/name and directory escape produce zero writes", function()
    fixture(function(_, ctx)
      for _, spec in ipairs({
        { kind = "actor", name = "UMismatch" },
        { kind = "actor", name = "AMy;Quit" },
        { kind = "actor", name = "A" },
        { kind = "unknown", name = "AMyActor" },
        { kind = "actor", name = "AMyActor", directory = "../Outside" },
      }) do
        spec.module = "Game"
        local plan, err = entities.plan(ctx, spec)
        t.assert_nil(plan)
        t.assert_true(type(err) == "string")
      end
    end)
  end)

  t.it("apply creates both files once and never overwrites an existing destination", function()
    fixture(function(_, ctx)
      local plan = assert(entities.plan(ctx, { module = "Game", kind = "actor", name = "AMyActor" }))
      local ok = entities.apply(plan, { context = ctx })
      t.assert_true(ok)
      t.assert_eq(read(plan.files[1].path), plan.files[1].content)
      t.assert_eq(read(plan.files[2].path), plan.files[2].content)
      write(plan.files[1].path, "changed by user")
      t.assert_false(entities.apply(plan, { context = ctx }))
      t.assert_eq(read(plan.files[1].path), "changed by user")
    end)
  end)

  t.it("project/descriptor/Build.cs/preview mutation invalidates the frozen plan", function()
    fixture(function(_, ctx)
      local function plan()
        return assert(entities.plan(ctx, { module = "Game", kind = "object", name = "UMyObject" }))
      end
      local p = plan()
      local other = vim.deepcopy(ctx)
      other.uproject = other.uproject .. ".different"
      t.assert_false(entities.apply(p, { context = other }))
      p = plan()
      write(ctx.uproject, read(ctx.uproject) .. " ")
      t.assert_false(entities.apply(p, { context = ctx }))
      p = plan()
      write(p.module.build_cs, "different rules")
      t.assert_false(entities.apply(p, { context = ctx }))
      p = plan()
      p.files[1].content = "tampered"
      t.assert_false(entities.apply(p, { context = ctx }))
      t.assert_nil(read(p.files[1].path))
    end)
  end)

  t.it("an unsaved destination buffer and a racing second writer are preserved", function()
    fixture(function(_, ctx)
      local p = assert(entities.plan(ctx, { module = "Game", kind = "object", name = "UMyObject" }))
      local buf = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_name(buf, p.files[1].path)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "user's draft" })
      t.assert_false(entities.apply(p, { context = ctx }))
      t.assert_nil(read(p.files[1].path))
      t.assert_eq(vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1], "user's draft")
      vim.api.nvim_buf_delete(buf, { force = true })
      local count = 0
      t.assert_false(entities.apply(p, {
        context = ctx,
        open = function(path, flags, mode)
          count = count + 1
          if count == 2 then
            write(path, "other writer's source")
          end
          return vim.uv.fs_open(path, flags, mode)
        end,
      }))
      t.assert_nil(read(p.files[1].path))
      t.assert_eq(read(p.files[2].path), "other writer's source")
    end)
  end)

  t.it("Nth-file creation failure removes only unchanged files owned by this plan", function()
    fixture(function(_, ctx)
      local p = assert(entities.plan(ctx, { module = "Game", kind = "object", name = "UMyObject" }))
      local called = 0
      local ok, err = entities.apply(p, {
        context = ctx,
        open = function(path, flags, mode)
          called = called + 1
          if called == 2 then
            return nil, "injected second-file error"
          end
          return vim.uv.fs_open(path, flags, mode)
        end,
      })
      t.assert_false(ok)
      t.assert_contains(err, "injected second-file error")
      t.assert_nil(read(p.files[1].path))
      t.assert_nil(read(p.files[2].path))
      called = 0
      ok, err = entities.apply(p, {
        context = ctx,
        open = function(path, flags, mode)
          called = called + 1
          if called == 2 then
            write(p.files[1].path, "user's intervening edit")
            return nil, "injected second-file error"
          end
          return vim.uv.fs_open(path, flags, mode)
        end,
      })
      t.assert_false(ok)
      t.assert_contains(err, "保留")
      t.assert_eq(read(p.files[1].path), "user's intervening edit")
      t.assert_nil(read(p.files[2].path))
    end)
  end)

  t.it("wizard cancellation makes no files and preview contains both complete files", function()
    fixture(function(_, ctx)
      local old_select, old_input, old_notify = vim.ui.select, vim.ui.input, vim.notify
      local preview
      vim.ui.select = function(items, _, cb)
        cb(items[1])
      end
      vim.ui.input = function(opts, cb)
        if opts.prompt:find("类名", 1, true) then
          cb("UMyObject")
        else
          cb("")
        end
      end
      vim.notify = function() end
      local ok, err = pcall(entities.new, {
        context = ctx,
        resolve_context = function()
          return ctx
        end,
        preview = function(p, cb)
          preview = p
          cb(false)
        end,
      })
      vim.ui.select, vim.ui.input, vim.notify = old_select, old_input, old_notify
      if not ok then
        error(err)
      end
      t.assert_eq(#preview.files, 2)
      t.assert_nil(read(preview.files[1].path))
      t.assert_nil(read(preview.files[2].path))
    end)
  end)

  t.it("native preview owns one window and wiping it cancels without writes", function()
    fixture(function(_, ctx)
      local p = assert(entities.plan(ctx, { module = "Game", kind = "object", name = "UMyObject" }))
      local before, accepted = vim.api.nvim_get_current_win(), nil
      entities.preview(p, function(choice)
        accepted = choice
      end)
      local win, buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
      t.assert_true(win ~= before)
      local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
      t.assert_contains(text, p.files[1].path)
      t.assert_contains(text, p.files[2].path)
      t.assert_contains(text, "class GAME_API UMyObject")
      vim.api.nvim_buf_delete(buf, { force = true })
      t.assert_false(accepted)
      t.assert_nil(read(p.files[1].path))
      t.assert_nil(read(p.files[2].path))
      t.assert_true(vim.api.nvim_win_is_valid(before))
      vim.api.nvim_set_current_win(before)
    end)
  end)
end)

local editor_tests = require("ue.editor_tests")

t.describe("IDE UE tests: source-authored results and frozen workflow", function()
  t.it("structured UE4 report preserves failed names, event source locations and warnings", function()
    local report = assert(editor_tests.parse_report(vim.json.encode({
      succeeded = 1,
      failed = 1,
      notRun = 0,
      succeededWithWarnings = 0,
      tests = {
        { fullTestPath = "Game.Pass", state = "Success", entries = {} },
        {
          fullTestPath = "Game.Fail",
          state = "Fail",
          entries = {
            {
              event = { type = "Error", message = "Expected actual value", context = "case one" },
              filename = "Source/Failure.cpp",
              lineNumber = 27,
            },
          },
        },
      },
    })))
    t.assert_false(report.ok)
    t.assert_true(vim.deep_equal(report.failed, { "Game.Fail" }))
    t.assert_eq(report.diagnostics[1].filename, "Source/Failure.cpp")
    t.assert_eq(report.diagnostics[1].lnum, 27)
    t.assert_eq(report.diagnostics[1].type, "E")
    t.assert_contains(report.diagnostics[1].text, "Expected actual value")
  end)

  t.it("empty, partial, unknown state and corrupt reports cannot claim test success", function()
    for _, document in ipairs({
      {},
      { tests = {} },
      { tests = { { fullTestPath = "Game.X", state = "InProcess" } } },
      {
        tests = { { fullTestPath = "Game.X", state = "Success" } },
        failed = 1,
        succeeded = 0,
        notRun = 0,
        succeededWithWarnings = 0,
      },
    }) do
      local report = editor_tests.parse_report(vim.json.encode(document))
      t.assert_true(report == nil or report.ok == false)
    end
    t.assert_nil(editor_tests.parse_report("not JSON"))
  end)

  t.it("test discovery accepts only declared Automation log names and verifies the declared count", function()
    local report = assert(
      editor_tests.parse_list(
        "noise Game.Fake\n[time]LogAutomationCommandLine: Display: Found 2 Automation Tests\n[time]LogAutomationCommandLine: Display: \tGame.One\n[time]LogAutomationCommandLine: Display: \tGame.Two\nLogOther: Display: Game.Hidden\n"
      )
    )
    t.assert_true(vim.deep_equal(report.tests, { "Game.One", "Game.Two" }))
    t.assert_nil(
      editor_tests.parse_list(
        "LogAutomationCommandLine: Display: Found 3 Automation Tests\nLogAutomationCommandLine: Display: \tGame.One\n"
      )
    )
  end)

  t.it("a missing host capability and command separators fail before spawn or writes", function()
    fixture(function(dir, ctx)
      local plan, err =
        editor_tests.plan(ctx, { operation = "list", driver = { id = "stub" }, output_root = dir .. "/Output" })
      t.assert_nil(plan)
      t.assert_contains(err, "ue_editor_test_plan")
      local calls = 0
      local driver = {
        id = "unit",
        ue_editor_test_plan = function()
          calls = calls + 1
          return { argv = { "unused" } }
        end,
      }
      for _, filter in ipairs({ "A;Quit", "A,Quit", "A\nQuit", 'A"Quit', "A'Quit", "" }) do
        t.assert_nil(
          editor_tests.plan(
            ctx,
            { operation = "run", filter = filter, driver = driver, output_root = dir .. "/Output" }
          )
        )
      end
      t.assert_eq(calls, 0)
      t.assert_eq(vim.fn.isdirectory(dir .. "/Output"), 0)
    end)
  end)

  t.it("failed rerun uses exact supported UE filters and cannot redirect another project", function()
    local filter = assert(editor_tests.failed_filter({ failed = { "Game.One", "Game.Two" } }))
    t.assert_eq(filter, "^Game.One$+^Game.Two$")
    t.assert_nil(editor_tests.failed_filter({ failed = { "Game.Has+Delimiter" } }))
    fixture(function(_, ctx)
      local spawned, callback, finished = 0
      local driver = {
        id = "unit",
        ue_editor_test_plan = function(spec)
          return {
            argv = { "unused", spec.uproject },
            cwd = vim.fs.dirname(spec.uproject),
            report_dir = spec.report_dir,
            log_path = spec.log_path,
          }
        end,
      }
      local captured
      local run = assert(editor_tests.start(ctx, {
        driver = driver,
        operation = "run",
        filter = "Game.Fail",
        system = function(argv, _, cb)
          spawned, captured, callback = spawned + 1, vim.deepcopy(argv), cb
          return {
            pid = 99999,
            is_closing = function()
              return true
            end,
          }
        end,
        read_report = function()
          return vim.json.encode({
            succeeded = 0,
            succeededWithWarnings = 0,
            failed = 1,
            notRun = 0,
            tests = { { fullTestPath = "Game.Fail", state = "Fail", entries = {} } },
          })
        end,
        publish = function() end,
        notify = function() end,
      }, function(result)
        finished = result
      end))
      local original = ctx.uproject
      local canonical = vim.fs.normalize(assert(vim.uv.fs_realpath(original)))
      ctx.uproject = ctx.uproject .. ".changed"
      callback({ code = 0, signal = 0 })
      t.assert_true(vim.wait(1000, function()
        return finished ~= nil
      end))
      t.assert_eq(captured[2], canonical)
      t.assert_false(finished.ok)
      t.assert_nil(editor_tests.last(ctx))
      ctx.uproject = original
      t.assert_true(vim.deep_equal(editor_tests.last(ctx).report.failed, { "Game.Fail" }))
      t.assert_eq(run.context.uproject, canonical)
      t.assert_eq(spawned, 1)
      vim.fn.delete(run.plan.report_dir, "rf")
    end)
  end)

  t.it("nonzero exit, termination, missing reports and spawn errors release foreground ownership", function()
    fixture(function(dir, ctx)
      local admission = require("utils.host_admission")
      local driver = {
        id = "unit",
        ue_editor_test_plan = function(spec)
          return { argv = { "unused" }, cwd = dir, report_dir = spec.report_dir, log_path = spec.log_path }
        end,
      }
      local pass = vim.json.encode({
        succeeded = 1,
        succeededWithWarnings = 0,
        failed = 0,
        notRun = 0,
        tests = { { fullTestPath = "Game.One", state = "Success", entries = {} } },
      })
      for _, outcome in ipairs({
        { code = 6, signal = 0 },
        { code = 0, signal = 9 },
        { code = 0, signal = 0, missing = true },
      }) do
        local callback, finished
        local run = assert(editor_tests.start(ctx, {
          output_root = dir .. "/Output",
          driver = driver,
          operation = "run",
          filter = "Game.One",
          notify = function() end,
          publish = function() end,
          read_report = function()
            if outcome.missing then
              return nil
            end
            return pass
          end,
          system = function(_, _, cb)
            callback = cb
            return {
              pid = 99999,
              is_closing = function()
                return true
              end,
            }
          end,
        }, function(done)
          finished = done
        end))
        t.assert_true(admission.foreground_active())
        t.assert_nil(editor_tests.start(ctx, { driver = driver }))
        callback(outcome)
        t.assert_true(vim.wait(1000, function()
          return finished ~= nil
        end))
        t.assert_false(finished.ok)
        if outcome.code ~= 0 then
          t.assert_contains(finished.error, "退出码 " .. outcome.code)
        end
        if outcome.signal ~= 0 then
          t.assert_contains(finished.error, "信号 " .. outcome.signal)
        end
        t.assert_false(admission.foreground_active())
        vim.fn.delete(run.plan.report_dir, "rf")
      end
      local run, err = editor_tests.start(ctx, {
        output_root = dir .. "/Output",
        driver = driver,
        operation = "run",
        filter = "Game.One",
        system = function()
          error("native spawn error")
        end,
      })
      t.assert_nil(run)
      t.assert_contains(err, "native spawn error")
      t.assert_false(admission.foreground_active())
    end)
  end)

  t.it("pending test menu and discovery choices reject a same-project engine switch before opening or spawn", function()
    fixture(function(dir, ctx)
      vim.fn.mkdir(dir .. "/OtherEngine", "p")
      local other = vim.deepcopy(ctx)
      other.engine_root = dir .. "/OtherEngine"
      local old_ue, old_select, old_notify = package.loaded.ue, vim.ui.select, vim.notify
      local menus, message = 0
      package.loaded.ue = {
        resolve_context = function()
          return other
        end,
      }
      vim.ui.select = function()
        menus = menus + 1
      end
      vim.notify = function(text)
        message = text
      end
      local ok, err = pcall(function()
        editor_tests.command({ "run", "Game.One" }, ctx)
        editor_tests.choose(ctx, { "Game.One" })
      end)
      package.loaded.ue, vim.ui.select, vim.notify = old_ue, old_select, old_notify
      if not ok then
        error(err)
      end
      t.assert_eq(menus, 0)
      t.assert_contains(message, "引擎已切换")
    end)
  end)

  t.it("explicit test log opens the shared panel while retaining dirty source text", function()
    fixture(function(dir, _)
      local win, old_buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
      local buf = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_name(buf, dir .. "/Dirty.cpp")
      vim.api.nvim_win_set_buf(win, buf)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "user's unsaved work" })
      local tick = vim.api.nvim_buf_get_changedtick(buf)
      local run = {
        plan = { report_dir = dir .. "/Report", log_path = dir .. "/missing-editor.log" },
        output = { "actual owned stdout\n" },
      }
      local panel = editor_tests.show_log(run)
      t.assert_true(panel ~= win)
      t.assert_true(vim.bo[buf].modified)
      t.assert_eq(vim.api.nvim_buf_get_changedtick(buf), tick)
      t.assert_contains(
        table.concat(vim.api.nvim_buf_get_lines(run.log_buf, 0, -1, false), "\n"),
        "actual owned stdout"
      )
      require("utils.bottom_panel").remove("debug", run.log_buf)
      vim.api.nvim_buf_delete(run.log_buf, { force = true })
      vim.api.nvim_set_current_win(win)
      vim.api.nvim_win_set_buf(win, old_buf)
      vim.api.nvim_buf_delete(buf, { force = true })
    end)
  end)
end)
