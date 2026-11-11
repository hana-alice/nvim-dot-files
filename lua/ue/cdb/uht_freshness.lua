-- Detect stale UnrealHeaderTool output for the active target platform.
--
-- UEPrepare builds compile_commands from the last real build's .rsp files and
-- never runs UHT. After a branch switch or merge, reflected headers change but
-- the *.generated.h files (and their __LINE__-keyed GENERATED_BODY macros) do
-- not, so clangd reports cascades of bogus errors from the shared PCH. UHT
-- writes Inc/<Module>/Timestamp listing every header it processed; any listed
-- header newer than that Timestamp has not been regenerated.
local M = {}
local fs = require("ue.core.fs")

M.MAX_EXAMPLES = 3

--- Timestamp manifests under <root>/<platform>/*/Inc/*/Timestamp.
function M.timestamp_files(build_roots, platform, glob)
  glob = glob or function(pattern) return vim.fn.glob(pattern, false, true) end
  local out, seen = {}, {}
  if not platform or platform == "" then return out end
  for _, root in ipairs(build_roots or {}) do
    for _, path in ipairs(glob(fs.join(root, platform, "*", "Inc", "*", "Timestamp")) or {}) do
      path = fs.norm(path)
      if not seen[path] then seen[path], out[#out + 1] = true, path end
    end
  end
  return out
end

--- Asynchronously compare each listed header with its module Timestamp.
--- cb({ manifests, headers, stale, examples }) — never errors; unreadable
--- entries are skipped because absence is not evidence of staleness.
function M.check(timestamps, cb, deps)
  deps = deps or {}
  local stat = deps.stat or function(path, done) vim.uv.fs_stat(path, function(_, st) done(st) end) end
  local read = deps.read or function(path)
    local file = io.open(path, "rb")
    if not file then return nil end
    local content = file:read("*a")
    file:close()
    return content
  end
  local schedule = deps.schedule or vim.schedule
  local result = { manifests = 0, headers = 0, stale = 0, examples = {} }
  local pending = 1
  local function settle()
    pending = pending - 1
    if pending == 0 then schedule(function() cb(result) end) end
  end
  for _, ts in ipairs(timestamps or {}) do
    pending = pending + 1
    stat(ts, function(ts_stat)
      local content = ts_stat and read(ts)
      if not content then settle(); return end
      result.manifests = result.manifests + 1
      local limit = ts_stat.mtime.sec
      for line in content:gmatch("[^\r\n]+") do
        local header = vim.trim(line)
        if header ~= "" then
          result.headers = result.headers + 1
          pending = pending + 1
          stat(header, function(header_stat)
            if header_stat and header_stat.mtime.sec > limit then
              result.stale = result.stale + 1
              if #result.examples < M.MAX_EXAMPLES then
                result.examples[#result.examples + 1] = vim.fs.basename(fs.norm(header))
              end
            end
            settle()
          end)
        end
      end
      settle()
    end)
  end
  settle()
end

function M.message(result, platform)
  if not result or result.stale == 0 then return nil end
  return ("UHT output for %s is stale: %d reflected header(s) changed since the last build (e.g. %s).\n"
    .. "clangd will report false errors until you build %s once, then :LspRestart.")
    :format(platform, result.stale, table.concat(result.examples, ", "), platform)
end

return M
