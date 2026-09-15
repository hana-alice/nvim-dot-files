-- Process-isolated production header path. Only the UE project configuration
-- boundary is supplied by the fixture; compiler, IPC, actions, navigation,
-- target switching and persistence are the actual production modules.
local cfg, root, clangd = assert(arg[1]), assert(arg[2]), assert(arg[3])
vim.opt.rtp:prepend(cfg)
package.path = cfg .. "/lua/?.lua;" .. cfg .. "/lua/?/init.lua;" .. package.path
vim.env.NVIM_UE_PROBE_PATH = root .. "/probes.json"
vim.env.NVIM_UE_LOG_DIR = root .. "/logs"
vim.env.UE_CLANGD = clangd

local function write(path, lines)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  assert(vim.fn.writefile(lines, path) == 0)
end
local api, target, source = root .. "/api.hpp", root .. "/defs.hpp", root .. "/origin.cpp"
write(target, { "inline int selected() { return 7; }" })
local call = "inline int caller() { return selected(); }"
write(api, { '#include "defs.hpp"', call })
write(source, { '#include "api.hpp"' })
write(root .. "/compile_commands.json", { vim.json.encode({ {
  directory = root, file = source, arguments = { "clang++", "-std=c++20", "-c", source },
} }) })
write(root .. "/Intermediate/Build/Win64/Fixture/Development/Module/origin.cpp.json", {
  vim.json.encode({ Data = { Source = source, Includes = { api, target } } }),
})
local ctx = { engine_root = root, project_root = root, state = {},
  paths = { active_cdb = root .. "/compile_commands.json", cdb_shards_dir = root .. "/shards" } }
local index = { readiness = "ready", freshness = "fresh", complete = true,
  generation_id = "pipeline-fixture", artifact_fingerprint = "pipeline-artifact" }
local environment_reads = 0
package.loaded["ue"] = {
  resolve_context = function() environment_reads = environment_reads + 1; return ctx end,
  clangd_cmd = function() return { clangd } end,
  semantic_index_snapshot = function() return vim.deepcopy(index) end,
}
local buffer = vim.fn.bufadd(api)
vim.fn.bufload(buffer)
vim.api.nvim_set_current_buf(buffer)
vim.bo[buffer].filetype = "cpp"
vim.api.nvim_win_set_cursor(0, { 2, assert(call:find("selected", 1, true)) - 1 })

local client = require("utils.ue_goto.semantic_client")
-- Match normal application lifecycle registration without loading UI plugins.
require("utils.probe").setup()
local owner = {}
local navigation = require("utils.ue_goto.semantic_navigation").install(owner, {
  dtrace = function() end,
  format_jump_msg = function() return "pipeline fixture resolved" end,
  jump_to_location = require("utils.ue_goto.jumper").jump,
})
navigation.cpp_definition("selected", buffer, api, "hpp")
assert(vim.wait(20000, function()
  return owner._last_cpp_transaction and owner._last_cpp_transaction.result ~= nil
end, 10), "production navigation did not finish")
local result = owner._last_cpp_transaction.result
assert(result.state == "resolved", vim.inspect(result))
assert(vim.fs.normalize(vim.api.nvim_buf_get_name(0)) == target, "wrong actual destination buffer")
assert(vim.api.nvim_win_get_cursor(0)[1] == 1, "wrong actual destination line")
assert(environment_reads > 0, "environment discovery was not exercised")
assert(result.identity == "c:@F@selected#", "canonical compiler identity absent: " .. vim.inspect(result))
assert(result.compiler_session and result.compiler_session.actual.toolchain_identity,
  "actual compiler session absent from terminal evidence")
assert(result.metrics and result.metrics.query_kinds, "native query metrics absent")
write(root .. "/result.json", { vim.json.encode({ result = result, destination = target,
  environment_reads = environment_reads, session = client.status().session }) })
client.stop()
assert(vim.wait(3000, function() return not client.status().running end, 10), "sidecar did not stop")
-- Exit normally: the production feedback lifecycle must flush its own data.
vim.cmd("qa!")
