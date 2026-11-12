local t = require("tests.harness")
t.bootstrap()
local uht = require("ue.cdb.uht_freshness")

local function sync_deps(mtimes, files)
  return {
    stat = function(path, done)
      local m = mtimes[path]
      done(m and { mtime = { sec = m } } or nil)
    end,
    read = function(path) return files[path] end,
    schedule = function(fn) fn() end,
  }
end

t.describe("UHT freshness", function()
  t.it("flags reflected headers newer than their module Timestamp", function()
    local ts = "B/Android/Client/Inc/Engine/Timestamp"
    local deps = sync_deps({ [ts] = 100, ["D:/E/A.h"] = 90, ["D:/E/MaterialInterface.h"] = 200, ["D:/E/Gone.h"] = nil },
      { [ts] = "D:\\E\\A.h\r\nD:/E/MaterialInterface.h\r\nD:/E/Gone.h\r\n" })
    local got
    uht.check({ ts }, function(r) got = r end, deps)
    t.assert_eq(got.manifests, 1)
    t.assert_eq(got.headers, 3)
    t.assert_eq(got.stale, 1)
    t.assert_eq(got.examples[1], "MaterialInterface.h")
    t.assert_contains(uht.message(got, "Android"), "build Android once")
  end)

  t.it("is silent when everything is fresh or no manifest exists", function()
    local got
    uht.check({}, function(r) got = r end, sync_deps({}, {}))
    t.assert_eq(got.stale, 0)
    t.assert_eq(uht.message(got, "Android"), nil)
    uht.check({ "missing/Timestamp" }, function(r) got = r end, sync_deps({}, {}))
    t.assert_eq(got.manifests, 0)
  end)

  t.it("discovers Timestamp manifests for the active platform only", function()
    local root = vim.fn.tempname():gsub("\\", "/")
    for _, p in ipairs({ "Android/Client/Inc/Engine", "Win64/ClientEditor/Inc/Engine" }) do
      vim.fn.mkdir(root .. "/" .. p, "p")
      vim.fn.writefile({ "x.h" }, root .. "/" .. p .. "/Timestamp")
    end
    local found = uht.timestamp_files({ root, root }, "Android")
    vim.fn.delete(root, "rf")
    t.assert_eq(#found, 1)
    t.assert_contains(found[1], "/Android/Client/Inc/Engine/Timestamp")
    t.assert_eq(#uht.timestamp_files({ root }, ""), 0)
  end)

  t.it("works asynchronously against the real filesystem", function()
    local root = vim.fn.tempname():gsub("\\", "/")
    vim.fn.mkdir(root .. "/Android/C/Inc/M", "p")
    local header = root .. "/Fresh.h"
    vim.fn.writefile({ "" }, header)
    local ts = root .. "/Android/C/Inc/M/Timestamp"
    vim.fn.writefile({ header }, ts)
    vim.uv.fs_utime(header, os.time() + 60, os.time() + 60)
    local got
    uht.check(uht.timestamp_files({ root }, "Android"), function(r) got = r end)
    t.assert_true(vim.wait(5000, function() return got ~= nil end, 10))
    vim.fn.delete(root, "rf")
    t.assert_eq(got.stale, 1)
  end)
end)
