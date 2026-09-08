-- ue.target_identity — shared Target/Configuration identity for build and DAP.
--
-- Project name, UBT Target name, and Configuration are independent identities.
-- This module keeps their resolution in one headless-testable place so DAP does
-- not infer a Target from `.uproject` while the build planner uses Target.cs.

local fs = require("ue.core.fs")

local M = {
  TARGET_KIND_SUFFIXES = { "Editor", "Client", "Server" },
}

function M.split_configuration(configuration)
  configuration = fs.trim(configuration)
  for _, suffix in ipairs(M.TARGET_KIND_SUFFIXES) do
    local base = fs.trim(configuration:match("^(.-)%s+" .. suffix .. "$") or "")
    if base ~= "" then return base, suffix end
  end
  return configuration ~= "" and configuration or "Development", "Game"
end

function M.detect_target_names(project_root, uproject)
  local search_dirs = {}
  if type(uproject) == "string" and uproject ~= "" then
    search_dirs[#search_dirs + 1] = fs.join(fs.dirname(uproject), "Source")
  end
  if type(project_root) == "string" and project_root ~= "" then
    search_dirs[#search_dirs + 1] = fs.join(project_root, "Source")
  end

  local seen, targets = {}, {}
  for _, dir in ipairs(search_dirs) do
    if not seen[dir] then
      seen[dir] = true
      local found = vim.fn.globpath(dir, "*.Target.cs", false, true)
      if type(found) == "table" then
        for _, path in ipairs(found) do targets[#targets + 1] = path end
      end
    end
  end

  local detected = { Editor = nil, Client = nil, Server = nil, Game = nil }
  for _, path in ipairs(targets) do
    local name = vim.fs.basename(path):gsub("%.Target%.cs$", "")
    local matched = false
    for _, kind in ipairs(M.TARGET_KIND_SUFFIXES) do
      if name:match(kind .. "$") then
        detected[kind] = detected[kind] or name
        matched = true
        break
      end
    end
    if not matched then detected.Game = detected.Game or name end
  end

  local fallback = type(uproject) == "string" and uproject ~= ""
    and vim.fs.basename(uproject):gsub("%.uproject$", "") or nil
  detected.Game = detected.Game or fallback
  return detected
end

function M.detect_target_name(project_root, uproject, kind)
  local detected = M.detect_target_names(project_root, uproject)
  local fallback = type(uproject) == "string" and uproject ~= ""
    and vim.fs.basename(uproject):gsub("%.uproject$", "") or nil
  kind = fs.trim(kind)
  if kind == "Editor" then
    return detected.Editor or detected.Game or detected.Client or detected.Server or fallback
  elseif kind == "Client" then
    return detected.Client or detected.Game or detected.Editor or detected.Server or fallback
  elseif kind == "Server" then
    return detected.Server or detected.Game or detected.Editor or detected.Client or fallback
  elseif kind == "Game" then
    return detected.Game or detected.Editor or detected.Client or detected.Server or fallback
  end
  return detected.Editor or detected.Game or detected.Client or detected.Server or fallback
end

function M.build_target_name(project_root, uproject, kind)
  local override = fs.trim(vim.env.UE_BUILD_TARGET)
  if override ~= "" then return override end
  return M.detect_target_name(project_root, uproject, kind)
end

function M.resolve(ctx)
  ctx = ctx or {}
  -- Match build identity precedence exactly: the environment override is what
  -- UBT receives, so DAP must not keep using a stale persisted configuration.
  local selected = fs.trim(vim.env.UE_TARGET_CONFIGURATION)
  if selected == "" then
    selected = fs.trim(ctx.configuration
      or (ctx.state and ctx.state.target_configuration) or "")
  end
  local configuration, kind = M.split_configuration(selected)
  return {
    target = fs.trim(ctx.target) ~= "" and fs.trim(ctx.target)
      or M.build_target_name(ctx.project_root, ctx.uproject, kind),
    configuration = configuration,
  }
end

return M
