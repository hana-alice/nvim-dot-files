-- One-time seeding of an empty frozen shard cache from the original cache.
-- Retained frozen commands equal their original commands byte-for-byte, and
-- clangd validates shards only by content digest, so original shards are
-- reusable; the helper adds absent names only and never writes the source.
local M = {}
local uv = vim.uv or vim.loop
local platform = require("utils.platform")

local function index_dir(cdb)
  return vim.fs.joinpath(vim.fs.dirname(cdb), ".cache", "clangd", "index")
end

function M.paths(original, verified)
  return index_dir(original), index_dir(verified)
end

local function has_shard(directory)
  local handle = uv.fs_scandir(directory)
  if not handle then return nil end
  while true do
    local name, kind = uv.fs_scandir_next(handle)
    if not name then return false end
    if kind == "file" and name:sub(-4) == ".idx" then return true end
  end
end

--- Seed only when the original cache holds shards and the frozen one holds none.
function M.needed(source, target)
  local stat = uv.fs_lstat(source)
  if not stat or stat.type ~= "directory" then return false end
  return has_shard(target) == false and has_shard(source) == true
end

function M.run(source, target, _, callback)
  local python = platform.resolve_tool({ name = "python", env = { "UE_PYTHON" },
    driver_candidates = function(driver) return driver.python_candidates() end })
  if not python.ok then vim.schedule(function() callback({ ok = false, reason = "python-unavailable" }) end); return end
  local command = { python.path, "-B", "-I", vim.fn.stdpath("config") .. "/tools/clangd_shard_seed.py",
    "--source", source, "--target", target }
  -- The compiler environment belongs to clangd, not to this file-only helper.
  local handle = vim.system(command, { text = true, timeout = 600000 }, function(result)
      vim.schedule(function()
        local ok, decoded = pcall(vim.json.decode, result.stdout or "")
        if not ok or type(decoded) ~= "table" then decoded = { ok = false, reason = "seed-helper-failed" } end
        if result.code ~= 0 then decoded.ok = false end
        pcall(function()
          require("utils.log").info_ctx("ue.index", "frozen shard cache seeded", {
            ok = decoded.ok, reason = decoded.reason, linked = decoded.linked, copied = decoded.copied,
            seconds = decoded.seconds,
          })
        end)
        callback(decoded)
      end)
    end)
  pcall(require("utils.task_registry").register, { name = "Seed frozen index cache", group = "index", kind = "system", handle = handle })
end

--- Run `continue` after an optional seed; helper failure leaves a cold cache.
--- `record.pending_helpers` counts the seed so retries wait for its exit.
function M.before(record, original, verified, run, continue)
  local source, target = M.paths(original, verified)
  if not M.needed(source, target) then continue(); return end
  record.pending_helpers = record.pending_helpers + 1
  local done = false
  local ok = pcall(run or M.run, source, target, nil, function(result)
    if done then return end
    done = true
    record.pending_helpers = record.pending_helpers - 1
    record.seed = result
    continue()
  end)
  if not ok and not done then
    done = true
    record.pending_helpers = record.pending_helpers - 1
    continue()
  end
end

return M
