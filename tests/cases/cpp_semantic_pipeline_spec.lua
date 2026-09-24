local t = require("tests.harness")
local cfg = t.bootstrap()

t.describe("production semantic header pipeline", function()
  local toolchain = require("utils.ue_goto.semantic_sidecar_libclang").discover_toolchain()
  if not toolchain.ok then
    t.skip("environment/session/query/jump/persist", toolchain.reason, { native = true })
    return
  end
  t.it("runs the real header chain and persists revision-linked resolved feedback on normal exit", function()
    local root = vim.fs.normalize(vim.fn.tempname())
    vim.fn.mkdir(root, "p")
    local ok, err = xpcall(function()
      local process = vim.system({ vim.v.progpath, "--headless", "-u", "NONE", "-i", "NONE",
        "-l", cfg .. "/tests/fixtures/cpp_semantic_pipeline/run.lua", cfg, root, toolchain.clangd_path,
      }, { text = true }):wait(30000)
      t.assert_eq(process.code, 0, (process.stderr or "") .. (process.stdout or ""))
      local result = vim.json.decode(table.concat(vim.fn.readfile(root .. "/result.json"), "\n"))
      t.assert_eq(result.result.state, "resolved")
      t.assert_eq(result.result.identity, "c:@F@selected#")
      t.assert_eq(result.result.compiler_session.actual.toolchain_identity, result.session.actual.toolchain_identity)
      local feedback = vim.json.decode(table.concat(vim.fn.readfile(root .. "/probes.json"), "\n"))
      local observed = false
      for _, topic in pairs(feedback.topics or {}) do
        for _, record in pairs(topic.records or {}) do
          local stats = record.stats or {}
          observed = observed or (type(record.revision) == "string" and record.revision ~= ""
            and topic.observation and record.revision == topic.observation.revision
            and (stats.outcomes or {}).resolved and stats.outcomes.resolved > 0)
        end
      end
      t.assert_true(observed, "normal exit must persist resolved outcome and observation revision")
    end, debug.traceback)
    vim.fn.delete(root, "rf")
    if not ok then error(err) end
  end)
end)
