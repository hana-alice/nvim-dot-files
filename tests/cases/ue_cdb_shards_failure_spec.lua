local t = require("tests.harness")
t.bootstrap()

local shards = require("ue.cdb.shards")
local uv = vim.uv
local active_key = "Win64-Fixture-Development"
local sibling_key = "Android-Fixture-Development"

local function write(path, value)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local file = assert(io.open(path, "wb"))
  assert(file:write(type(value) == "string" and value or vim.json.encode(value)))
  assert(file:close())
end

local function read(path)
  local file = assert(io.open(path, "rb"))
  local bytes = assert(file:read("*a"))
  assert(file:close())
  return bytes
end

local function override(owner, key, replacement, body)
  local original = owner[key]
  owner[key] = replacement
  local ok, err = xpcall(body, debug.traceback)
  owner[key] = original
  if not ok then error(err) end
end

local function fixture()
  local base = vim.env.FIX_X4_ROOT
  local root = vim.fs.normalize(base and (base .. "/shards-" .. tostring(uv.hrtime()))
    or (vim.fn.tempname() .. "-shards-failure"))
  local ctx = {
    paths = { cdb_shards_dir = root },
    state = { target_platform = "Win64", target_configuration = "Development", target = "Fixture" },
  }
  local function entry(name, platform)
    return { file = root .. "/" .. name, directory = root,
      arguments = { "clang++", "-DPLATFORM_" .. platform .. "=1", "-c", root .. "/" .. name } }
  end
  local active = { entry("Shared.cpp", "WIN64"), entry("ActiveOnly.cpp", "WIN64") }
  local sibling = { entry("Shared.cpp", "ANDROID"), entry("SiblingOnly.cpp", "ANDROID") }
  local manifest = { active = active_key, shards = {
    [active_key] = { platform = "Win64", target = "Fixture", config = "Development", entry_count = #active },
    [sibling_key] = { platform = "Android", target = "Fixture", config = "Development", entry_count = #sibling },
  } }
  write(shards.shard_path(ctx, active_key), active)
  write(shards.shard_path(ctx, sibling_key), sibling)
  write(root .. "/manifest.json", manifest)
  return ctx, manifest, active
end

t.describe("ue.cdb.shards failure propagation", function()
  t.it("healthy merge keeps the active platform and every declared shard", function()
    local ctx = fixture()
    local entries, stats = shards.merge_shards(ctx)
    t.assert_eq(#entries, 3)
    t.assert_eq(stats.total_in, 4)
    t.assert_eq(stats.dropped, 1)
    t.assert_eq(stats.shard_count, 2)
    for _, entry in ipairs(entries) do
      if entry.file:match("/Shared.cpp$") then
        t.assert_eq(entry.arguments[2], "-DPLATFORM_WIN64=1")
      end
    end
  end)

  t.it("a valid empty array stays distinct from missing and malformed input", function()
    local ctx, manifest = fixture()
    local path = shards.shard_path(ctx, active_key)
    write(path, "[]")
    local entries, err = shards.read_shard(ctx, active_key)
    t.assert_type(entries, "table")
    t.assert_eq(#entries, 0)
    t.assert_nil(err)
    manifest.shards[active_key].entry_count = 0
    local merged = shards.merge_shards(ctx, manifest)
    t.assert_eq(#merged, 2)
    local missing, missing_err, missing_status = shards.read_shard(ctx, "Win64-Missing-Development")
    t.assert_nil(missing)
    t.assert_eq(missing_status, "missing")
    t.assert_contains(missing_err, "Win64-Missing-Development.json")
  end)

  for _, bytes in ipairs({ "{broken", "", "{}", "null", '{"file":"not-an-array.cpp"}' }) do
    t.it("invalid shard is an error rather than an empty array: " .. vim.inspect(bytes), function()
      local ctx = fixture()
      local path = shards.shard_path(ctx, active_key)
      write(path, bytes)
      local entries, err, status = shards.read_shard(ctx, active_key)
      t.assert_nil(entries)
      t.assert_eq(status, "error")
      t.assert_contains(err, path)
    end)
  end

  t.it("permission and read failures stay errors with the shard path", function()
    local ctx = fixture()
    local path = shards.shard_path(ctx, active_key)
    local original_open = io.open
    for _, phase in ipairs({ "open", "read", "close" }) do
      override(io, "open", function(file_path, mode)
        if file_path == path and mode == "rb" then
          if phase == "open" then return nil, "EACCES", 13 end
          return {
            read = function()
              if phase == "read" then return nil, "EIO" end
              return "[]"
            end,
            close = function()
              if phase == "close" then return nil, "EIO" end
              return true
            end,
          }
        end
        return original_open(file_path, mode)
      end, function()
        local entries, err, status = shards.read_shard(ctx, active_key)
        t.assert_nil(entries)
        t.assert_eq(status, "error")
        t.assert_contains(err, path)
      end)
    end
  end)

  t.it("corrupt active shard fails the whole merge without foreign fallback", function()
    local ctx = fixture()
    write(shards.shard_path(ctx, active_key), "{broken")
    local entries, failure = shards.merge_shards(ctx)
    t.assert_nil(entries)
    t.assert_eq(failure.status, "error")
    t.assert_eq(failure.failed_shard, active_key)
    t.assert_eq(failure.shard_count, 2)
    t.assert_contains(failure.error, shards.shard_path(ctx, active_key))
  end)

  t.it("missing non-active declared shard also fails the complete merge", function()
    local ctx, manifest = fixture()
    local key = "IOS-Missing-Development"
    manifest.shards[key] = { platform = "IOS", target = "Missing", config = "Development", entry_count = 1 }
    local entries, failure = shards.merge_shards(ctx, manifest)
    t.assert_nil(entries)
    t.assert_eq(failure.status, "missing")
    t.assert_eq(failure.failed_shard, key)
    t.assert_eq(failure.shard_count, 3)
  end)

  t.it("shard rename failure preserves old bytes and manifest and returns failure", function()
    local ctx, _, entries = fixture()
    local shard_path = shards.shard_path(ctx, active_key)
    local manifest_path = ctx.paths.cdb_shards_dir .. "/manifest.json"
    local old_shard, old_manifest = read(shard_path), read(manifest_path)
    entries[#entries + 1] = vim.deepcopy(entries[1])
    entries[#entries].file = ctx.paths.cdb_shards_dir .. "/New.cpp"
    local original_rename = uv.fs_rename
    override(uv, "fs_rename", function(from, to)
      if to == shard_path then return nil, "EACCES" end
      return original_rename(from, to)
    end, function()
      local key, err = shards.write_shard(ctx, "Win64", "Fixture", "Development", entries)
      t.assert_nil(key)
      t.assert_contains(err, "EACCES")
    end)
    t.assert_eq(read(shard_path), old_shard)
    t.assert_eq(read(manifest_path), old_manifest)
  end)

  t.it("manifest rename failure cannot return a successful shard identity", function()
    local ctx, _, entries = fixture()
    local path = ctx.paths.cdb_shards_dir .. "/manifest.json"
    local old_manifest = read(path)
    entries[#entries + 1] = vim.deepcopy(entries[1])
    local original_rename = uv.fs_rename
    override(uv, "fs_rename", function(from, to)
      if to == path then return nil, "EACCES" end
      return original_rename(from, to)
    end, function()
      local key, err = shards.write_shard(ctx, "Win64", "Fixture", "Development", entries)
      t.assert_nil(key)
      t.assert_contains(err, "EACCES")
    end)
    t.assert_eq(read(path), old_manifest)
  end)

  t.it("write, flush and close failures do not publish a truncated shard", function()
    for _, phase in ipairs({ "write", "flush", "close" }) do
      local ctx, _, entries = fixture()
      local shard_path = shards.shard_path(ctx, active_key)
      local manifest_path = ctx.paths.cdb_shards_dir .. "/manifest.json"
      local old_shard, old_manifest = read(shard_path), read(manifest_path)
      entries[#entries + 1] = vim.deepcopy(entries[1])
      local original_open = io.open
      override(io, "open", function(path, mode)
        local file, err, code = original_open(path, mode)
        if not file or mode ~= "wb" or not path:find(shard_path .. ".tmp.", 1, true) then
          return file, err, code
        end
        return {
          write = function(_, bytes)
            if phase == "write" then return nil, "ENOSPC" end
            return file:write(bytes)
          end,
          flush = function()
            if phase == "flush" then return nil, "ENOSPC" end
            return file:flush()
          end,
          close = function()
            local ok, close_err = file:close()
            if phase == "close" then return nil, "EIO" end
            return ok, close_err
          end,
        }
      end, function()
        local key, err = shards.write_shard(ctx, "Win64", "Fixture", "Development", entries)
        t.assert_nil(key)
        t.assert_type(err, "string")
      end)
      t.assert_eq(read(shard_path), old_shard)
      t.assert_eq(read(manifest_path), old_manifest)
    end
  end)

  t.it("manifest missing initializes an empty store but corruption fails closed", function()
    local ctx = fixture()
    ctx.paths.cdb_shards_dir = ctx.paths.cdb_shards_dir .. "/new-store"
    local empty, missing_err = shards.read_manifest(ctx)
    t.assert_type(empty, "table")
    t.assert_nil(next(empty.shards))
    t.assert_nil(missing_err)
    write(ctx.paths.cdb_shards_dir .. "/manifest.json", "{broken")
    local manifest, err, status = shards.read_manifest(ctx)
    t.assert_nil(manifest)
    t.assert_eq(status, "error")
    t.assert_contains(err, "manifest.json")
    local entries, failure = shards.merge_shards(ctx)
    t.assert_nil(entries)
    t.assert_contains(failure.error, "manifest.json")
  end)
end)
