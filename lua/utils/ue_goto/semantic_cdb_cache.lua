-- Bounded positive parsed-input cache, never a context/proof outcome cache.
local M = {}
local libclang = require("utils.ue_goto.semantic_sidecar_libclang")
local context = require("utils.ue_goto.semantic_context")
local Cache = {}
Cache.__index = Cache

local function signature(path)
  local stat = libclang.uv.fs_stat(path)
  if not stat or stat.type ~= "file" then return nil end
  local function time(value) return { value and value.sec or 0, value and value.nsec or 0 } end
  return vim.json.encode({ path, stat.dev, stat.ino, stat.size, time(stat.mtime), time(stat.ctime) })
end

function Cache:load(path, verified_digest)
  path = libclang.normalize(path)
  local before = signature(path)
  local bytes, actual_digest
  -- Legacy callers have no content-bound provenance; establish a digest by
  -- reading bytes rather than trusting a stat-only positive cache key.
  if not verified_digest then
    bytes = libclang.read_all(path)
    if not bytes then self.entries[path] = nil; return nil, "cdb-unreadable", false end
    actual_digest = vim.fn.sha256(bytes)
    verified_digest = actual_digest
  end
  self.sequence = self.sequence + 1
  local cached = self.entries[path]
  if before and cached and cached.signature == before and cached.digest == verified_digest then
    cached.last_used = self.sequence
    return cached.db, nil, true
  end
  self.entries[path] = nil
  bytes = bytes or libclang.read_all(path)
  if not bytes then return nil, "cdb-unreadable", false end
  actual_digest = actual_digest or vim.fn.sha256(bytes)
  if actual_digest ~= verified_digest then return nil, "cdb-changed-during-read", false end
  local ok, decoded = pcall(vim.json.decode, bytes)
  if not ok then decoded = nil end
  local readable = type(decoded) == "table"
  local db, detail = context.load_compilation_database(decoded)
  local after = signature(path)
  if not before or before ~= after then return nil, "cdb-changed-during-read", readable end
  if db and db.complete then
    self.entries[path] = { signature = after, digest = verified_digest, db = db, last_used = self.sequence }
    local count = vim.tbl_count(self.entries)
    if count > self.max_entries then
      local oldest_path, oldest
      for candidate, entry in pairs(self.entries) do
        if candidate ~= path and (not oldest or entry.last_used < oldest) then
          oldest_path, oldest = candidate, entry.last_used
        end
      end
      if oldest_path then self.entries[oldest_path] = nil end
    end
  end
  return db, detail, readable
end

function Cache:clear() self.entries = {} end

function M.new()
  return setmetatable({ entries = {}, sequence = 0, max_entries = 2 }, Cache)
end

return M
