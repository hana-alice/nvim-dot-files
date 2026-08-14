-- ue.cdb.paths — locate compile_commands.json on disk.
--
-- Phase E.2: lift the path-resolution helpers out of `ue.lua`. These were
-- semi-pure (took `ctx` only) but reached for the file system and external
-- `fd`/`fdfind` to enumerate stray copies — passed in via the `deps`
-- table so the module stays headlessly testable.

local fs = require("ue.core.fs")

local M = {}

--- Canonical compile_commands.json target for the active project/session.
--- New contexts write only inside their project+platform cache bucket so two
--- Neovim processes cannot overwrite each other's active CDB. The two legacy
--- engine-root targets remain only for callers that do not provide ctx.paths.
---@param ctx { engine_root: string, paths?: { active_cdb?: string } }
---@return string[]
function M.targets(ctx)
  if ctx.paths and ctx.paths.active_cdb and ctx.paths.active_cdb ~= "" then
    return { fs.norm(ctx.paths.active_cdb) }
  end
  return {
    fs.join(ctx.engine_root, "compile_commands.json"),
    fs.join(ctx.engine_root, "Engine", "compile_commands.json"),
  }
end

--- Discover every readable compile_commands.json reachable from `ctx`.
--- Combines: canonical targets, project_root, the standard
--- Engine/Intermediate/Build/ location, and an optional `fd` recursive
--- scan when `deps.first_executable` resolves it.
---
--- `deps` lets the caller inject the original `run_lines` /
--- `first_executable` so the module does NOT depend on the monolith's
--- upvalues. When `deps` is omitted we fall back to `ue.core.proc` and
--- skip the fd scan entirely (still useful for tests).
---@param ctx { engine_root: string, project_root?: string }
---@param deps? { first_executable?: fun(list: string[]): string?, run_lines?: fun(cmd: string[], opts: table?): integer, string[]? }
---@return string[]
function M.candidates(ctx, deps)
  deps = deps or {}
  local first_executable = deps.first_executable or require("ue.core.proc").first_executable
  local run_lines        = deps.run_lines  -- nil → no fd-based discovery

  local seen = {}
  local out = {}
  local function add(path)
    path = fs.norm(path)
    if path ~= "" and not seen[path] and fs.is_file(path) then
      seen[path] = true
      table.insert(out, path)
    end
  end

  for _, target in ipairs(M.targets(ctx)) do add(target) end
  -- Engine/project copies are inputs only. They may be emitted by UBT or an
  -- older nvim-ue version, but are never canonical write targets now.
  add(fs.join(ctx.engine_root, "compile_commands.json"))
  add(fs.join(ctx.engine_root, "Engine", "compile_commands.json"))
  if ctx.project_root and ctx.project_root ~= "" then
    add(fs.join(ctx.project_root, "compile_commands.json"))
  end
  add(fs.join(ctx.engine_root, "Engine", "Intermediate", "Build", "compile_commands.json"))

  if run_lines then
    local fd = first_executable({ "fd", "fdfind" })
    if fd then
      local cmd = {
        fd, "--absolute-path", "--type", "f",
        "--hidden", "--follow",
        "--glob", "compile_commands.json",
        "--search-path", ctx.engine_root,
      }
      if ctx.project_root and ctx.project_root ~= "" and ctx.project_root ~= ctx.engine_root then
        table.insert(cmd, "--search-path")
        table.insert(cmd, ctx.project_root)
      end
      local code, lines = run_lines(cmd, { cwd = "/" })
      if code == 0 then
        for _, line in ipairs(lines or {}) do add(line) end
      end
    end
  end

  return out
end

return M
