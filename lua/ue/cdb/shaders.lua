-- ue.cdb.shaders — synthesise compile_commands entries for UE shader files.
--
-- Phase E.2: lift the JSON-augmentation half of the shader pipeline. The
-- file-system walk (`scan_shader_files`, `shader_include_roots`) stays in
-- ue.lua for now because it captures `UE_CONST` upvalues; this module
-- accepts them as inputs so it remains a pure function over data.
--
-- Inputs:
--   `shader_files`   string[]  — absolute paths to .usf/.ush
--   `include_roots`  string[]  — `-I` candidates (typically Shader/ subdirs)
--   `template`       table     — a CDB entry to clone for compiler/dir info
--
-- Output is a single CDB entry shaped exactly like ue.lua used to emit.

local fs   = require("ue.core.fs")
local json = require("ue.cdb.json")

local M = {}

--- Build one CDB entry for a shader file. Mirrors the original
--- `make_shader_compile_command_entry` byte-for-byte.
function M.make_entry(shader_file, template, include_roots)
  local arguments = {
    json.program(template),
    "-x",
    "c++-header",
    "-fsyntax-only",
    "-Wno-pragma-once-outside-header",
  }
  for _, root in ipairs(include_roots or {}) do
    table.insert(arguments, "-I")
    table.insert(arguments, root)
  end
  table.insert(arguments, shader_file)

  return {
    directory = fs.trim(template.directory or fs.dirname(shader_file)),
    file = shader_file,
    arguments = arguments,
  }
end

--- Take a JSON `content` blob (string), append synthetic entries for any
--- `shader_files` not already present, and return the (possibly updated)
--- JSON. Identical surface to the original `augment_compile_commands_with_shaders`
--- minus the shader_files / include_roots discovery, which the caller now
--- performs upstream.
---
--- Returns the original `content` unchanged when:
---   * decoding fails
---   * `shader_files` is empty
---   * every shader file is already in the CDB
function M.augment(content, shader_files, include_roots)
  if not shader_files or #shader_files == 0 then
    return content
  end

  local ok, decoded = pcall(vim.json.decode, content)
  if not ok or type(decoded) ~= "table" then
    return content
  end

  local template = json.template_entry(decoded)
  local existing = {}
  for _, entry in ipairs(decoded) do
    if type(entry) == "table" and entry.file then
      existing[fs.norm(entry.file):lower()] = true
    end
  end

  local added = false
  for _, shader_file in ipairs(shader_files) do
    local key = shader_file:lower()
    if not existing[key] then
      table.insert(decoded, M.make_entry(shader_file, template, include_roots or {}))
      existing[key] = true
      added = true
    end
  end

  if not added then
    return content
  end

  return vim.json.encode(decoded)
end

return M
