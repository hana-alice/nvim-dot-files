local t = require("tests.harness")
t.bootstrap()
local native = require("tests.fixtures.search_native")

t.describe("search_state: native csearch terminal evidence", function()
  t.it("no match is empty with completed coverage, not a backend error", function()
    native.with_index(t, function(fixture)
      local hits, result = native.query(t, fixture, "MISSING_NEEDLE_987", { regex = false })
      t.assert_eq(#hits, 0)
      t.assert_eq(result.meta.state, "empty")
      t.assert_true(result.meta.complete)
      t.assert_true(result.meta.total_known)
    end)
  end)

  t.it("invalid regex is an error with a visible reason", function()
    native.with_index(t, function(fixture)
      local _, result = native.query(t, fixture, "[", { regex = true })
      t.assert_eq(result.meta.state, "error")
      t.assert_false(result.meta.complete)
      t.assert_true(result.err and result.err ~= "")
      t.assert_eq(result.meta.reason, "invalid-pattern")
    end)
  end)

  t.it("first three rows are explicitly incomplete when native has more", function()
    native.with_index(t, function(fixture)
      local hits, result = native.query(t, fixture, "Alpha", { regex = false, max_count = 3 })
      t.assert_eq(#hits, 3)
      t.assert_eq(result.meta.state, "truncated")
      t.assert_eq(result.meta.delivered, 3)
      t.assert_false(result.meta.complete)
      t.assert_false(result.meta.total_known)
      t.assert_eq(result.meta.reason, "result-limit")
    end)
  end)

  t.it("exactly the limit is complete when no extra row exists", function()
    native.with_index(t, function(fixture)
      local hits, result = native.query(t, fixture, "Axxa", { regex = false, max_count = 1 })
      t.assert_eq(#hits, 1)
      t.assert_eq(result.meta.state, "complete")
      t.assert_true(result.meta.complete)
      t.assert_true(result.meta.total_known)
    end)
  end)

  t.it("stop returns cancellation evidence and never invokes later callbacks", function()
    native.with_index(t, function(fixture)
      local calls = 0
      local stop = require("utils.code_search").stream({ csearch_idx = fixture.index }, "Alpha", {}, {
        on_line = function()
          calls = calls + 1
        end,
        on_done = function()
          calls = calls + 1
        end,
      })
      local status = stop("new-query")
      t.assert_eq(status.state, "canceled")
      t.assert_eq(status.reason, "new-query")
      vim.wait(100)
      t.assert_eq(calls, 0)
    end)
  end)

  t.it("an index-only query never switches to rg when its index disappears", function()
    native.with_index(t, function(fixture)
      t.assert_true(vim.uv.fs_rename(fixture.index, fixture.index .. ".moved"))
      local hits, result = native.query(t, fixture, "Alpha", { regex = false, require_index = true })
      t.assert_eq(#hits, 0)
      t.assert_eq(result.meta.backend, "csearch")
      t.assert_eq(result.meta.state, "index_unavailable")
      t.assert_false(result.meta.complete)
    end)
  end)
end)

local function owned_reader(options, command, callback)
  local calls, result = {}, nil
  local reader = require("utils.code_search.stream_reader").new(
    vim.tbl_extend("force", {
      backend = "native-pipe-fixture",
      parse = function(record)
        return { file = "owned.cpp", lnum = 1, text = record }
      end,
    }, options),
    {
      on_line = function(_, _, _, text)
        calls[#calls + 1] = text
      end,
      on_done = function(code, err, meta)
        result = { code = code, err = err, meta = meta, at = #calls }
      end,
    }
  )
  local handle, err = vim.uv.spawn(vim.v.progpath, {
    args = { "--headless", "-u", "NONE", "-i", "NONE", "-c", command, "-c", "qa!" },
    stdio = { nil, reader.stdout, reader.stderr },
  }, function(code, signal)
    reader:exit(code, signal)
  end)
  local stop = reader:attach(handle, err)
  local completed = vim.wait(5000, function()
    return result ~= nil
  end, 5)
  if not completed then
    stop("test-timeout")
  end
  t.assert_true(completed, "owned native reader failed to finish")
  t.assert_eq(result.at, #calls)
  callback(calls, result)
  t.assert_true(
    vim.wait(2000, function()
      return reader.exited or handle == nil
    end, 5),
    "owned child was not reaped"
  )
end

t.describe("search_state: native reader ownership", function()
  t.it("process exit does not drop pipe tail or a final unterminated UTF-8 row", function()
    owned_reader(
      { timeout_ms = 2000 },
      "lua io.stdout:write('first\\n你好 tail');io.stdout:flush()",
      function(calls, result)
        t.assert_eq(#calls, 2)
        t.assert_eq(calls[1], "first")
        t.assert_eq(calls[2], "你好 tail")
        t.assert_eq(result.meta.state, "complete")
        t.assert_eq(result.meta.delivered, 2)
      end
    )
  end)

  t.it("timeout reports partial coverage and stops only its owned child", function()
    owned_reader({ timeout_ms = 50 }, "lua vim.wait(500)", function(_, result)
      t.assert_eq(result.code, 124)
      t.assert_eq(result.meta.state, "timeout")
      t.assert_eq(result.meta.reason, "deadline")
      t.assert_false(result.meta.complete)
      t.assert_false(result.meta.total_known)
    end)
  end)

  t.it("invalid output is visible as an error rather than a complete empty result", function()
    owned_reader(
      { parse = function() end },
      "lua io.stdout:write('invalid record\\n');io.stdout:flush()",
      function(_, result)
        t.assert_eq(result.meta.state, "error")
        t.assert_eq(result.meta.reason, "invalid-output")
        t.assert_true(result.code ~= 0)
        t.assert_true(result.err ~= nil)
      end
    )
  end)

  t.it("a provider's explicit false skips a control row without hiding invalid output", function()
    owned_reader(
      {
        parse = function(record)
          if record == "control" then
            return false
          end
          return { file = "owned.cpp", lnum = 1, text = record }
        end,
      },
      "lua io.stdout:write('control\\nmatch\\n');io.stdout:flush()",
      function(calls, result)
        t.assert_eq(#calls, 1)
        t.assert_eq(calls[1], "match")
        t.assert_eq(result.meta.state, "complete")
        t.assert_eq(result.meta.delivered, 1)
      end
    )
  end)
end)

t.describe("search_state: post-result filters", function()
  local picker = require("utils.code_search.picker")
  t.it("path and type refinement keeps query separate and filters in memory", function()
    local spec = {
      root = "C:/fixture/Project",
      include = { "Source/**" },
      exclude = { "**/Private/**" },
      types = { "h", "build.cs" },
    }
    local copy = vim.deepcopy(spec)
    local filter = assert(picker.compile_filter(spec))
    t.assert_true(filter.match({ file = "C:/fixture/Project/Source/Game/Public/Actor.h" }))
    t.assert_true(filter.match({ file = "C:/fixture/Project/Source/Game/Game.Build.cs" }))
    t.assert_false(filter.match({ file = "C:/fixture/Project/Source/Game/Private/Actor.h" }))
    t.assert_false(filter.match({ file = "C:/fixture/Project/Source/Game/Actor.cpp" }))
    t.assert_false(filter.match({ file = "C:/fixture/ProjectTwo/Source/Game/Actor.h" }))
    t.assert_true(vim.deep_equal(spec, copy), "filter compilation mutated the source recipe")
    local state = { input = { filter = { search = "Alpha", pattern = "Actor" } } }
    t.assert_eq(picker.query(state), "Alpha")
    t.assert_true(picker.picker_options({}).supports_live)
  end)

  t.it("basename globs and invalid filter input have explicit semantics", function()
    local filter = assert(picker.compile_filter({ include = { "*.h" } }))
    t.assert_true(filter.match({ file = "C:/fixture/Source/Actor.h" }))
    t.assert_false(filter.match({ file = "C:/fixture/Source/Actor.cpp" }))
    -- Native vim.glob treats an unmatched '[' as a literal filename byte.
    -- Invalid input here is a control character, not a guessed glob dialect.
    local invalid, err = picker.compile_filter({ include = { "Actor\n.h" } })
    t.assert_nil(invalid)
    t.assert_true(err ~= nil)
  end)

  t.it("relative path masks use captured scope roots and the narrowest matching root", function()
    local filter = assert(picker.compile_filter({
      roots = { "C:/fixture", "C:/fixture/Project", "C:/other/Engine" },
      include = { "Source/**" },
    }))
    t.assert_true(filter.match({ file = "C:/fixture/Project/Source/Game/Actor.h" }))
    t.assert_true(filter.match({ file = "C:/other/Engine/Source/Core/Actor.h" }))
    t.assert_false(filter.match({ file = "C:/fixture/Project/Config/Default.ini" }))
    t.assert_false(filter.match({ file = "C:/outside/Source/Actor.h" }))
  end)

  t.it("status and scope summaries do not claim a known total for partial results", function()
    local label = picker.status_label({ state = "truncated", delivered = 3, total_known = false })
    t.assert_contains(label, "前 3 行")
    t.assert_contains(label, "不完整")
    t.assert_contains(picker.status_label({ state = "error", reason = "invalid-pattern" }), "无效")
    local scope = picker.scope_summary({ label = "Project", excluded = { "Content" }, complete = false })
    t.assert_contains(scope, "Project")
    t.assert_contains(scope, "Content")
    t.assert_contains(scope, "未确认")
  end)
end)
