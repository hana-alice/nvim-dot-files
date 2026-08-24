-- ue.cdb.json — pure JSON helpers for compile_commands entries.
--
-- Phase E.1: lift the helpers that have ZERO upvalue capture (no engine
-- state, no shared mutable, no platform-specific calls) so they can be
-- exercised in isolation by the headless smoke tests and reused by future
-- pipeline steps.
--
-- IMPORTANT: a "compile_commands entry" here means a single element of
-- the compile_commands.json array — `{ directory, file, command? | arguments? }`
-- — as defined by the LLVM JSON Compilation Database spec.
--
-- Functions intentionally NOT lifted in E.1:
--   * augment_compile_commands_with_shaders — captures `scan_shader_files`,
--     `shader_include_roots`, and `UE_CONST` upvalues (lifts in E.2)
--   * make_shader_compile_command_entry  — peer of the above, same reason
--   * compile_commands_targets / _candidates — depend on `ctx` shape from
--     `resolve_context`; lift in E.2

local fs   = require("ue.core.fs")
local proc = require("ue.core.proc")

local M = {}

--- Extract the compiler executable from a single CDB entry.
--- Order of preference matches the LLVM spec: `arguments[1]` wins, then
--- the first whitespace-separated token of `command`, then a system
--- fallback via `proc.first_executable`.
---@param entry table
---@return string program
function M.program(entry)
  if type(entry) == "table" and type(entry.arguments) == "table" and entry.arguments[1] then
    return fs.trim(entry.arguments[1])
  end

  local command = type(entry) == "table" and fs.trim(entry.command) or ""
  if command ~= "" then
    if command:sub(1, 1) == '"' then
      return command:match('^"([^"]+)"') or command:match("^(%S+)")
    end
    return command:match("^(%S+)")
  end

  local candidates = require("utils.platform").driver().cdb_compiler_candidates()
  return proc.first_executable(candidates) or candidates[1] or "clang++"
end

--- Pick a "template" entry to clone when synthesising new entries (e.g.
--- when adding shader files that have no native CDB entry). Prefers an
--- entry that has both `arguments` and `file`; falls back to anything
--- with a `file`; finally returns an empty table so callers can handle
--- the empty-CDB edge case without crashing.
---@param entries table[]
---@return table template
function M.template_entry(entries)
  for _, entry in ipairs(entries or {}) do
    if type(entry) == "table" and type(entry.arguments) == "table" and entry.arguments[1] and entry.file then
      return entry
    end
  end
  for _, entry in ipairs(entries or {}) do
    if type(entry) == "table" and entry.file then
      return entry
    end
  end
  return {}
end

return M
