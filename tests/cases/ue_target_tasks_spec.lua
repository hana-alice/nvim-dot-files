local t = require("tests.harness")
t.bootstrap()

local tasks = require("ue.target_tasks")

t.describe("ue.target_tasks", function()
  t.it("converts a structured plan to argv without shell joining", function()
    local command, err = tasks.command({
      executable = "/Engine Root/Build.sh",
      args = { "Sample Game", "IOS", "Development", "-Project=/Project Root/Sample.uproject" },
    })

    t.assert_eq(err, nil)
    t.assert_eq(command[1], "/Engine Root/Build.sh")
    t.assert_eq(command[2], "Sample Game")
    t.assert_eq(command[5], "-Project=/Project Root/Sample.uproject")
  end)

  t.it("rejects structured unavailable and malformed plans", function()
    local unavailable, unavailable_err = tasks.command({
      status = "unavailable",
      reason = "host capability missing",
    })
    local malformed, malformed_err = tasks.command({ args = {} })

    t.assert_eq(unavailable, nil)
    t.assert_eq(unavailable_err, "host capability missing")
    t.assert_eq(malformed, nil)
    t.assert_eq(malformed_err, "target plan executable is missing")
  end)

  t.it("formats process failures using stderr before stdout", function()
    t.assert_contains(tasks.error_message({ code = 7, stdout = "fallback", stderr = "primary" }), "primary")
    t.assert_false(
      tasks.error_message({ code = 7, stdout = "fallback", stderr = "primary" }):find("fallback", 1, true) ~= nil
    )
  end)

  t.it("returns a start error instead of throwing when the executable cannot spawn", function()
    local original = vim.system
    vim.system = function()
      error("spawn rejected")
    end
    local ok, handle, err = pcall(tasks.run, {
      executable = "/missing/tool",
      args = { "--version" },
    })
    vim.system = original

    t.assert_true(ok)
    t.assert_eq(handle, nil)
    t.assert_contains(err, "spawn rejected")
  end)
end)
