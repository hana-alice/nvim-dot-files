local t = require("tests.harness")
t.bootstrap()

local compat_mod = require("utils.ue_goto.compat_navigation")

local function with_completion(result, ext, jumped, check)
  local names = {
    "utils.ue_goto.provider", "utils.ue_goto.symbol", "utils.ue_goto.cache", "utils.ue_goto.csearch_fallback",
  }
  local saved, notices = {}, {}
  for _, name in ipairs(names) do saved[name] = package.loaded[name] end
  local old_notify, old_defer, old_clients = vim.notify, vim.defer_fn, vim.lsp.get_clients
  vim.notify = function(message) notices[#notices + 1] = message end
  vim.defer_fn = function() end
  vim.lsp.get_clients = function() return {} end
  package.loaded["utils.ue_goto.provider"] = {
    gtags_fallback_async = function(_, cb) cb(jumped or false, result) end,
  }
  package.loaded["utils.ue_goto.symbol"] = {
    is_at_definition_at_cursor = function() return false end,
    is_dependent_at_cursor = function() return false end,
    is_in_unresolvable_context_at_cursor = function() return false end,
  }
  package.loaded["utils.ue_goto.cache"] = { get = function() end }
  package.loaded["utils.ue_goto.csearch_fallback"] = {
    find = function(_, _, cb) cb(nil, { count = 0, reason = "unavailable" }) end,
  }
  local compat
  local ok, err = xpcall(function()
    compat = compat_mod.install({ dtrace = function() end, jump_to_location = function() return false end })
    compat.definition("OutColor", nil, 0, "/fixture/test." .. ext, 1, ext)
    check(notices)
  end, debug.traceback)
  if compat then compat.dispose() end
  for _, name in ipairs(names) do package.loaded[name] = saved[name] end
  vim.notify, vim.defer_fn, vim.lsp.get_clients = old_notify, old_defer, old_clients
  if not ok then error(err) end
end

t.describe("shader compatibility result presentation", function()
  local outcomes = {
    { backend = "gtags", reason = "empty", coverage = "complete" },
    { backend = "gtags", reason = "empty", coverage = "partial" },
    { backend = "gtags", reason = "coverage-missing", coverage = "partial" },
    { backend = "none", reason = "unavailable", coverage = "unavailable", detail = "no context" },
    { backend = "gtags", reason = "unavailable", coverage = "unavailable", detail = "missing tool or cache" },
    { backend = "rg", reason = "empty", coverage = "partial" },
    { backend = "rg", reason = "command-failed", coverage = "partial" },
    { backend = "gtags", reason = "command-failed", coverage = "complete" },
    { backend = "gtags", reason = "jump-failed", coverage = "complete" },
  }
  for _, result in ipairs(outcomes) do
    t.it(result.backend .. "/" .. result.reason .. "/" .. result.coverage .. " preserves the negative outcome", function()
      with_completion(result, "ush", false, function(notices)
        t.assert_eq(#notices, 1)
        local message = notices[1]
        local proved_empty = result.backend == "gtags" and result.reason == "empty" and result.coverage == "complete"
        t.assert_eq(message:find("GTAGS empty", 1, true) ~= nil, proved_empty)
        t.assert_true(message:find("coverage=" .. result.coverage, 1, true) ~= nil)
        if not proved_empty then
          t.assert_true(message:find("backend=" .. result.backend, 1, true) ~= nil)
          t.assert_true(message:find("reason=" .. result.reason, 1, true) ~= nil)
        end
        t.assert_false(message:find("all empty", 1, true) ~= nil)
      end)
    end)
  end

  t.it("legacy boolean failure has no evidence of an empty GTAGS query", function()
    with_completion(nil, "ush", false, function(notices)
      t.assert_eq(#notices, 1)
      t.assert_true(notices[1]:find("backend=none; reason=unavailable; coverage=unavailable", 1, true) ~= nil)
      t.assert_false(notices[1]:find("GTAGS empty", 1, true) ~= nil)
    end)
  end)

  t.it("compatibility chain does not call missing providers all empty", function()
    with_completion({ backend = "rg", reason = "empty", coverage = "partial" }, "lua", false, function(notices)
      t.assert_eq(#notices, 1)
      t.assert_true(notices[1]:find("backend=rg; reason=empty; coverage=partial", 1, true) ~= nil)
      t.assert_false(notices[1]:find("all empty", 1, true) ~= nil)
      t.assert_false(notices[1]:find("GTAGS empty", 1, true) ~= nil)
    end)
  end)

  t.it("successful rg fallback is labeled with the actual backend", function()
    with_completion({ backend = "rg", coverage = "partial" }, "lua", true, function(notices)
      t.assert_eq(#notices, 1)
      t.assert_true(notices[1]:find("rg fallback", 1, true) ~= nil)
      t.assert_false(notices[1]:find("GTAGS fallback", 1, true) ~= nil)
    end)
  end)

  t.it("structured async completion passes through without losing reason or coverage", function()
    local saved = package.loaded["ue"]
    local expected = { backend = "rg", reason = "command-failed", coverage = "partial" }
    package.loaded["ue"] = { gtags_definition_async = function(_, cb) cb(false, expected) end }
    local received, outcome
    local ok, err = xpcall(function()
      compat_mod.gtags_fallback_async("OutColor", function(value, result) received, outcome = value, result end)
      t.assert_eq(received, false)
      t.assert_eq(outcome, expected)
    end, debug.traceback)
    package.loaded["ue"] = saved
    if not ok then error(err) end
  end)

  t.it("missing symbol has an explicit unavailable result without querying UE", function()
    local received, result
    compat_mod.gtags_fallback_async(nil, function(value, info) received, result = value, info end)
    t.assert_eq(received, false)
    t.assert_eq(result.backend, "none")
    t.assert_eq(result.reason, "unavailable")
    t.assert_eq(result.coverage, "unavailable")
  end)
end)
