-- Provision only the existing locked plugin set and required syntax parsers.
-- Run in an isolated CI config/data directory: nvim --headless -l <this file>.
local cfg = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local function normalize(path)
  return vim.fs.normalize(path):gsub("/$", "")
end
assert(normalize(cfg) == normalize(vim.fn.stdpath("config")),
  "CI checkout must be at stdpath(config); tests and startup probes read this path")
assert(vim.env.CI == "true", "bootstrap writes plugin data; run only in an isolated CI environment")
vim.g.started_with_stdin = true
vim.go.loadplugins = true -- -l disables it; lazy.setup otherwise returns early.
vim.opt.rtp:prepend(cfg)
local lock = vim.json.decode(table.concat(vim.fn.readfile(cfg .. "/lazy-lock.json"), "\n"))
local lazy_root = vim.fn.stdpath("data") .. "/lazy"

local function command(argv)
  local result = vim.system(argv, { text = true }):wait(120000)
  assert(result.code == 0, table.concat(argv, " ") .. ": " .. (result.stderr or ""))
  return vim.trim(result.stdout or "")
end

-- Pin the bootstrapper itself before it resolves the configured plugin graph.
local lazy_path = lazy_root .. "/lazy.nvim"
if vim.fn.isdirectory(lazy_path) == 0 then
  command({ "git", "clone", "--filter=blob:none", "--no-checkout", "https://github.com/folke/lazy.nvim.git", lazy_path })
  command({ "git", "-C", lazy_path, "checkout", "--detach", assert(lock["lazy.nvim"]).commit })
end
assert(command({ "git", "-C", lazy_path, "rev-parse", "HEAD" }) == lock["lazy.nvim"].commit,
  "existing lazy.nvim differs from lock; use a fresh CI data directory")
vim.opt.rtp:prepend(lazy_path)

-- Resolve and install the real plugin graph with lockfile=true, but defer
-- startup callbacks: those can start Mason tool installs and a broad parser
-- install. Only the explicit parser list below belongs to CI provisioning.
local loader = require("lazy.core.loader")
local startup = loader.startup
local lazy = require("lazy")
local setup = lazy.setup
lazy.setup = function(opts)
  opts.concurrency = 2
  opts.checker.enabled = false
  opts.spec[#opts.spec + 1] = {
    "nvim-treesitter/nvim-treesitter",
    opts = function(_, parser_opts) parser_opts.ensure_installed = {} end,
  }
  return setup(opts)
end
local lock_manager = require("lazy.manage.lock")
local update_lock = lock_manager.update
-- Lazy discovers transitive dependencies in rounds. Its default lock writer
-- drops not-yet-installed entries after each round; freeze the input lock so
-- later rounds cannot silently install those dependencies at branch HEAD.
lock_manager.lock = vim.deepcopy(lock)
lock_manager._loaded = true
lock_manager.update = function() end
loader.startup = function() end
local configured, configure_error = pcall(require, "config.lazy")
loader.startup = startup
lock_manager.update = update_lock
lazy.setup = setup
assert(configured, configure_error)
for name, plugin in pairs(require("lazy.core.config").plugins) do
  if plugin.url and not plugin._.is_local then
    assert(lock[name], "configured dependency is missing from lazy-lock.json: " .. name)
    assert(command({ "git", "-C", plugin.dir, "rev-parse", "HEAD" }) == lock[name].commit,
      "plugin did not install its locked revision: " .. name)
  end
end

-- nvim-treesitter main uses tree-sitter CLI + a C compiler. Installation may
-- report errors without throwing; loading each parser is the completion gate.
vim.opt.rtp:append(lazy_root .. "/nvim-treesitter")
require("nvim-treesitter").setup({ install_dir = vim.fn.stdpath("data") .. "/site" })
require("nvim-treesitter").install({ "c", "cpp", "hlsl" }, { max_jobs = 2 }):wait(300000)
for _, language in ipairs({ "c", "cpp", "hlsl" }) do
  local loaded, load_error = vim.treesitter.language.add(language)
  assert(loaded, "missing parser " .. language .. ": " .. tostring(load_error))
end
io.write("CI bootstrap: locked plugins and c/cpp/hlsl parsers ready\n")
vim.cmd("qa!")
