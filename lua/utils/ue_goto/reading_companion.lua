-- File-pair policy for explicit switchSourceHeader, separate from entity proof.
local M = {}
local navigation = require("utils.ue_goto.semantic_navigation")
local uv = vim.uv or vim.loop

function M.kind(path)
  local ext = tostring(path or ""):match("%.([^./\\]+)$")
  ext = ext and ext:lower() or ""
  return navigation.CPP_HEADER_EXTS[ext] and "header" or navigation.CPP_SOURCE_EXTS[ext] and "source" or nil
end

function M.generated(path)
  local normalized = vim.fs.normalize(tostring(path or "")):lower()
  local name = vim.fs.basename(normalized)
  return name:find(".gen.", 1, true) or name:find(".generated.", 1, true)
    or name:match("^module%.") or name:match("^superunity%.")
    or normalized:find("/intermediate/", 1, true) or normalized:find("/binaries/", 1, true)
    or normalized:find("/saved/", 1, true) or false
end

function M.valid_pair(subject, candidate)
  local source_kind, target_kind = M.kind(subject), M.kind(candidate)
  local stat = uv.fs_stat(candidate)
  if not source_kind or not target_kind or source_kind == target_kind
      or M.generated(candidate) or not stat or stat.type ~= "file" then
    return false, "companion-target-invalid"
  end
  local function stem(path)
    return vim.fs.basename(path):lower():gsub("%.[^.]+$", "")
  end
  return true, stem(subject) == stem(candidate) and "same-basename" or "inclusion-required"
end

function M.known_sources(owner, callback)
  if M.kind(owner.path) ~= "header" then callback(nil); return end
  local context = owner.context or {}
  local cdb = context.paths and context.paths.active_cdb
  if not cdb or not uv.fs_stat(cdb) then callback(nil); return end
  local commands = require("ue.clangd_commands")
  if type(commands.find_companion) ~= "function" then callback(nil); return end
  commands.find_companion(cdb, owner.path, function(candidates)
    local paths = {}
    for _, path in ipairs(candidates or {}) do
      local valid, rule = M.valid_pair(owner.path, path)
      if valid and rule == "same-basename" then paths[#paths + 1] = path end
    end
    callback(#paths > 0 and paths or nil)
  end, { is_current = function() return require("utils.ue_goto.reading_owner").current(owner, true) end })
end

return M
