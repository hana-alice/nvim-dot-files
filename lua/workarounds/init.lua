-- workarounds.init
--
-- Registry for isolated workaround modules under lua/workarounds/<scope>/.
-- See lua/workarounds/README.md for the contract.
--
-- Public API:
--   require("workarounds").setup()    -- discover + apply all enabled
--   require("workarounds").apply(name) -- apply one by dotted name
--   require("workarounds").list()     -- introspection table
--   require("workarounds").status(name)
--
-- User commands (registered by setup()):
--   :WorkaroundList
--   :WorkaroundStatus <name>
--   :WorkaroundDisable <name>
--   :WorkaroundEnable <name>

local M = {}

-- Each entry: { name, scope, file, frontmatter (table), module (lazy), error }
local registry = {}

-- ---------------------------------------------------------------------------
-- Frontmatter parser
--
-- Reads the leading "-- WORKAROUND" block and returns a key/value table.
-- Strict: every required field must be present, otherwise the workaround
-- is registered with an error and not auto-applied.
-- ---------------------------------------------------------------------------

local REQUIRED_KEYS = { "name", "scope", "issue", "symptom",
                        "introduced", "removal_condition", "owner", "enabled" }

local function parse_frontmatter(path)
  local f, err = io.open(path, "r")
  if not f then return nil, "open: " .. tostring(err) end

  local in_block = false
  local fm = {}
  for line in f:lines() do
    if not in_block then
      if line:match("^%-%-%s*WORKAROUND%s*$") then
        in_block = true
      elseif not line:match("^%s*$") and not line:match("^%-%-") then
        -- non-comment, non-blank line before the block — no frontmatter
        break
      end
    else
      if line:match("^%-%-%s*END%s+WORKAROUND%s*$") then
        in_block = false
        break
      end
      local key, val = line:match("^%-%-%s*([%w_]+):%s*(.-)%s*$")
      if key then fm[key] = val end
    end
  end
  f:close()

  -- Coerce booleans
  if fm.enabled == "true"  then fm.enabled = true  end
  if fm.enabled == "false" then fm.enabled = false end

  -- Validate
  local missing = {}
  for _, k in ipairs(REQUIRED_KEYS) do
    if fm[k] == nil then missing[#missing + 1] = k end
  end
  if #missing > 0 then
    return nil, "missing frontmatter keys: " .. table.concat(missing, ", ")
  end
  return fm
end

-- ---------------------------------------------------------------------------
-- Discovery
-- ---------------------------------------------------------------------------

local function workaround_root()
  -- Use stdpath('config') so it works on both Windows and *nix.
  local root = vim.fn.stdpath("config") .. "/lua/workarounds"
  return (vim.fs and vim.fs.normalize and vim.fs.normalize(root)) or root
end

local function each_workaround_file(cb)
  local root = workaround_root()
  -- Walk: workarounds/<scope>/<name>.lua  (skip init.lua, README.md, TEMPLATE.lua)
  local handle = vim.uv.fs_scandir(root)
  if not handle then return end
  while true do
    local scope_name, scope_type = vim.uv.fs_scandir_next(handle)
    if not scope_name then break end
    if scope_type == "directory" then
      local sdir = root .. "/" .. scope_name
      local sh = vim.uv.fs_scandir(sdir)
      if sh then
        while true do
          local fname, ftype = vim.uv.fs_scandir_next(sh)
          if not fname then break end
          if ftype == "file" and fname:match("%.lua$") then
            local path = sdir .. "/" .. fname
            local mod = "workarounds." .. scope_name .. "." .. fname:gsub("%.lua$", "")
            cb(scope_name, fname, path, mod)
          end
        end
      end
    end
  end
end

local function discover()
  registry = {}
  each_workaround_file(function(scope, _fname, path, mod)
    local fm, err = parse_frontmatter(path)
    if not fm then
      registry[#registry + 1] = {
        name = mod, scope = scope, file = path, error = err,
        frontmatter = nil, module_name = mod,
      }
      return
    end
    -- Sanity: declared name should match the module path (helps grep).
    if fm.name and fm.name ~= "" and fm.name ~= mod:gsub("^workarounds%.", "") then
      vim.schedule(function()
        vim.notify(string.format(
          "workarounds: %s declares name=%q but lives at %s",
          path, fm.name, mod), vim.log.levels.WARN)
      end)
    end
    registry[#registry + 1] = {
      name = fm.name, scope = scope, file = path,
      frontmatter = fm, module_name = mod, error = nil,
    }
  end)
  table.sort(registry, function(a, b) return (a.name or "") < (b.name or "") end)
end

-- ---------------------------------------------------------------------------
-- Apply / status
-- ---------------------------------------------------------------------------

local function find_entry(name)
  for _, e in ipairs(registry) do
    if e.name == name or e.module_name == name then return e end
  end
end

function M.apply(name)
  local e = find_entry(name)
  if not e then
    vim.notify("workarounds: unknown " .. tostring(name), vim.log.levels.ERROR)
    return false
  end
  if e.error then
    vim.notify(string.format("workarounds[%s]: cannot apply (%s)", name, e.error),
               vim.log.levels.ERROR)
    return false
  end
  local ok, mod_or_err = pcall(require, e.module_name)
  if not ok then
    vim.notify(string.format("workarounds[%s]: require failed: %s",
                             name, tostring(mod_or_err)),
               vim.log.levels.ERROR)
    return false
  end
  if type(mod_or_err.apply) ~= "function" then
    vim.notify(string.format("workarounds[%s]: missing apply()", name),
               vim.log.levels.ERROR)
    return false
  end
  local ok2, err = pcall(mod_or_err.apply)
  if not ok2 then
    vim.notify(string.format("workarounds[%s]: apply() error: %s",
                             name, tostring(err)),
               vim.log.levels.ERROR)
    return false
  end
  e.applied = true
  return true
end

function M.disable(name)
  local e = find_entry(name)
  if not e then return false end
  if e.frontmatter then e.frontmatter.enabled = false end
  local ok, mod = pcall(require, e.module_name)
  if ok and type(mod.disable) == "function" then pcall(mod.disable) end
  e.applied = false
  return true
end

function M.enable(name)
  local e = find_entry(name)
  if not e then return false end
  if e.frontmatter then e.frontmatter.enabled = true end
  return M.apply(name)
end

function M.status(name)
  local e = find_entry(name)
  if not e then return nil end
  local s = { name = e.name, scope = e.scope, file = e.file,
              error = e.error, applied = e.applied or false }
  if e.frontmatter then
    for k, v in pairs(e.frontmatter) do s[k] = v end
  end
  if not e.error then
    local ok, mod = pcall(require, e.module_name)
    if ok and type(mod.status) == "function" then
      local ok2, runtime = pcall(mod.status)
      if ok2 then s.runtime = runtime end
    end
  end
  return s
end

function M.list()
  local out = {}
  for _, e in ipairs(registry) do
    out[#out + 1] = {
      name = e.name or e.module_name,
      scope = e.scope,
      enabled = e.frontmatter and e.frontmatter.enabled or false,
      applied = e.applied or false,
      error = e.error,
      symptom = e.frontmatter and e.frontmatter.symptom,
      introduced = e.frontmatter and e.frontmatter.introduced,
      removal_condition = e.frontmatter and e.frontmatter.removal_condition,
    }
  end
  return out
end

-- ---------------------------------------------------------------------------
-- Setup
-- ---------------------------------------------------------------------------

local function register_commands()
  vim.api.nvim_create_user_command("WorkaroundList", function()
    local rows = M.list()
    if #rows == 0 then
      print("(no workarounds registered)")
      return
    end
    local lines = { string.format("%-40s %-12s %-8s %-8s %s",
                                  "name", "scope", "enabled", "applied", "symptom") }
    lines[#lines + 1] = string.rep("-", 110)
    for _, r in ipairs(rows) do
      lines[#lines + 1] = string.format("%-40s %-12s %-8s %-8s %s",
        r.name or "?", r.scope or "?",
        tostring(r.enabled), tostring(r.applied),
        r.error and ("ERR: " .. r.error) or (r.symptom or ""))
    end
    print(table.concat(lines, "\n"))
  end, { desc = "List all registered workarounds" })

  vim.api.nvim_create_user_command("WorkaroundStatus", function(opts)
    local s = M.status(opts.args)
    if not s then
      print("workarounds: unknown " .. opts.args)
      return
    end
    print(vim.inspect(s))
  end, { nargs = 1, desc = "Show one workaround's status",
         complete = function()
           local names = {}
           for _, e in ipairs(registry) do names[#names + 1] = e.name or e.module_name end
           return names
         end })

  vim.api.nvim_create_user_command("WorkaroundDisable", function(opts)
    if M.disable(opts.args) then print("disabled " .. opts.args) end
  end, { nargs = 1 })

  vim.api.nvim_create_user_command("WorkaroundEnable", function(opts)
    if M.enable(opts.args) then print("enabled " .. opts.args) end
  end, { nargs = 1 })
end

-- setup({ auto_apply = true|false }):
--   auto_apply (default true): immediately apply every workaround whose
--     frontmatter `enabled: true`. If false, just discover + register
--     commands and let main code decide when to apply.
function M.setup(opts)
  opts = opts or {}
  local auto_apply = opts.auto_apply ~= false

  discover()
  register_commands()

  if auto_apply then
    for _, e in ipairs(registry) do
      if not e.error and e.frontmatter and e.frontmatter.enabled then
        M.apply(e.name)
      end
    end
  end
end

return M
