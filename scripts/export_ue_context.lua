local config_root = vim.fn.stdpath("config")
vim.opt.rtp:prepend(config_root)
package.path = config_root .. "/lua/?.lua;" .. config_root .. "/lua/?/init.lua;" .. package.path

local engine_root = arg[1]
if not engine_root or engine_root == "" then
  error("usage: nvim --headless -l scripts/export_ue_context.lua <engine-root> [output-dir]")
end

engine_root = vim.fs.normalize(vim.fn.fnamemodify(engine_root, ":p"))
local context, err = require("ue").ai_context(engine_root)
if not context then
  error(err)
end

local output_dir = arg[2]
if not output_dir or output_dir == "" then
  output_dir = engine_root .. "/.omx/context"
end

local paths = require("ue.ai_context").write(context, output_dir)
print("JSON: " .. paths.json)
print("Markdown: " .. paths.markdown)
