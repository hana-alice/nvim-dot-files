-- Stable headless entrypoint for the non-mutating core functionality audit.
-- Usage: nvim --headless -l scripts/nvim_core_health.lua [--json] [--live]
--        [--filter <stage-or-id>]

local script = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"):gsub("\\", "/")
local config_root = vim.fs.dirname(vim.fs.dirname(script))
vim.opt.runtimepath:prepend(config_root)
package.path = table.concat({
  config_root .. "/lua/?.lua",
  config_root .. "/lua/?/init.lua",
  config_root .. "/?.lua",
  package.path,
}, ";")

local function fail(message)
  io.stderr:write("nvim_core_health: " .. message .. "\n")
  vim.cmd("cquit 2")
end

local function parse(argv)
  local opts = { json = false, live = false }
  local index = 1
  while index <= #argv do
    local value = argv[index]
    if value == "--json" then
      opts.json = true
    elseif value == "--live" then
      opts.live = true
    elseif value == "--filter" then
      index = index + 1
      if not argv[index] or argv[index] == "" then
        return nil, "--filter requires a stage or check id"
      end
      opts.filter = argv[index]
    elseif value == "--help" or value == "-h" then
      opts.help = true
    else
      return nil, "unknown argument: " .. tostring(value)
    end
    index = index + 1
  end
  return opts
end

local opts, parse_error = parse(arg or {})
if not opts then
  fail(parse_error)
end
if opts.help then
  io.stdout:write(table.concat({
    "Usage: nvim --headless -l scripts/nvim_core_health.lua [options]",
    "  --json              emit the stable JSON report",
    "  --filter <stage|id> run only the selected capability",
    "  --live              add read-only live workspace probes",
    "",
  }, "\n"))
  vim.cmd("quit")
  return
end

local health = require("utils.core_health")
local report = health.run({
  config_root = config_root,
  filter = opts.filter,
  live = opts.live,
})
local output = opts.json and health.encode_json(report) or health.format_text(report)
io.stdout:write(output .. "\n")
if health.exit_code(report) ~= 0 then
  vim.cmd("cquit 1")
else
  vim.cmd("quit")
end
