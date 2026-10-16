-- Independent digest worker; no editor startup or index publication side effects.
local source = debug.getinfo(1, "S").source:sub(2)
local repo = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(source)))))
vim.opt.runtimepath:prepend(repo)
package.path = repo .. "/lua/?.lua;" .. repo .. "/lua/?/init.lua;" .. package.path
local path = assert(arg[1], "missing CDB path")
local helpers = require("ue.index._generation_digest")({}, { h = { read_text_file = function(name)
  local file = io.open(name, "rb")
  if not file then return nil end
  local raw = file:read("*a"); file:close(); return raw
end } })
local before = helpers.cdb_identity(path)
local ok, digest, reason = pcall(helpers.compute_cdb_digest, path)
local after = helpers.cdb_identity(path)
local changed = not vim.deep_equal(before, after)
local result = { ok = ok and not changed and type(digest) == "string" and digest ~= "",
  digest = digest, identity = before, reason = changed and "cdb-changed" or reason
    or (not ok and tostring(digest) or digest == "" and "cdb-invalid-or-unreadable" or nil) }
io.stdout:write(vim.json.encode(result))
vim.cmd(result.ok and "qa!" or "cq 1")
