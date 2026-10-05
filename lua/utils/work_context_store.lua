-- Metadata only. Each project collection has one lease; writers reread, merge,
-- atomically replace, and verify through the same bounded reader before success.
local M = {}
local uv = vim.uv
local recipes = require("utils.search_recipe")
local fs = require("ue.core.fs")
local locks = require("ue.file_lock")
local MAX_CARDS, MAX_FILES, MAX_BYTES = 16, 32, 2 * 1024 * 1024
local MAX_INTEGER = 9007199254740991
local serial = 0
local draft_fields = { name = true, note = true, files = true, active = true, search = true, has_result = true }
local card_fields = vim.tbl_extend("force", draft_fields, {
  id = true,
  revision = true,
  created_at = true,
  updated_at = true,
})

local function later(done, ...)
  local args, count = { ... }, select("#", ...)
  vim.schedule(function()
    done(unpack(args, 1, count))
  end)
end

local function object(value, allowed)
  if type(value) ~= "table" then
    return false
  end
  for key in pairs(value) do
    if not allowed[key] then
      return false
    end
  end
  return true
end

local function integer(value, low, high)
  return type(value) == "number" and value >= low and value <= high and value % 1 == 0
end

local function text(value, limit, empty)
  return type(value) == "string"
    and #value <= limit
    and not value:find("[%z\1-\31\127]")
    and (empty or value:find("%S") ~= nil)
end

local function project_value(project)
  if not object(project, { root = true, identity = true, engine = true }) then
    return nil, "schema: 工程上下文含未知字段或格式无效"
  end
  local out = {}
  for _, key in ipairs({ "root", "identity", "engine" }) do
    local path = project[key]
    if path == nil and key == "engine" then
      path = ""
    end
    if not text(path, 2048, key == "engine") or path ~= "" and not fs.is_absolute_path(path) then
      return nil, "schema: 工程路径必须是有界绝对路径"
    end
    out[key] = recipes.canonical(path)
    if #out[key] > 2048 then
      return nil, "budget: 工程路径超过 2048 字节"
    end
  end
  return out
end

local function same_project(a, b)
  return recipes.path_key(a.identity) == recipes.path_key(b.identity)
    and recipes.path_key(a.root) == recipes.path_key(b.root)
end

---@param project table
---@return string? key, string? err
function M.key(project)
  local value, err = project_value(project)
  if not value then
    return nil, err
  end
  return vim.fn.sha256(recipes.path_key(value.identity))
end

---@param project table
---@return string? path, string? err
function M.path(project)
  local key, err = M.key(project)
  if not key then
    return nil, err
  end
  return vim.fs.joinpath(vim.fn.stdpath("state"), "ue_work_contexts", key .. ".json")
end

local function draft_value(draft, project, published)
  if not object(draft, published and card_fields or draft_fields) then
    return nil, "schema: 工作上下文含未知字段或格式无效"
  end
  local note = draft.note == nil and "" or draft.note
  if not text(draft.name, 128, false) or not text(note, 2048, true) then
    return nil, "budget: 名称须为 1–128 字节，下一步说明最多 2048 字节"
  end
  if type(draft.files) ~= "table" or not vim.islist(draft.files) or #draft.files < 1 or #draft.files > MAX_FILES then
    return nil, "budget: 每个上下文须含 1–32 个文件"
  end
  if not integer(draft.active, 1, #draft.files) then
    return nil, "schema: 活跃文件编号无效"
  end
  local out = { name = draft.name, note = note, active = draft.active, files = {} }
  for _, file in ipairs(draft.files) do
    if
      not object(file, { path = true, line = true, col = true, modified = true, disk = true })
      or not text(file.path, 2048, false)
      or not fs.is_absolute_path(file.path)
      or not integer(file.line, 1, 2147483647)
      or not integer(file.col, 1, 2147483647)
      or file.modified ~= nil and type(file.modified) ~= "boolean"
    then
      return nil, "schema: 文件只接受绝对路径、正整数行列及修改提示"
    end
    local saved = { path = file.path, line = file.line, col = file.col, modified = file.modified }
    if file.disk ~= nil then
      local disk = file.disk
      if
        not object(disk, { size = true, mtime_sec = true, mtime_nsec = true })
        or not integer(disk.size, 0, MAX_INTEGER)
        or not integer(disk.mtime_sec, -MAX_INTEGER, MAX_INTEGER)
        or not integer(disk.mtime_nsec, 0, 999999999)
      then
        return nil, "schema: 磁盘版本提示无效"
      end
      saved.disk = vim.deepcopy(disk)
    end
    out.files[#out.files + 1] = saved
  end
  if draft.has_result ~= nil and type(draft.has_result) ~= "boolean" then
    return nil, "schema: 结果提示必须为布尔值"
  end
  out.has_result = draft.has_result == true
  if draft.search ~= nil then
    local recipe, err = recipes.validate(draft.search)
    if not recipe then
      return nil, "schema: 搜索条件无效: " .. tostring(err)
    end
    if recipes.path_key(recipe.project.identity) ~= recipes.path_key(project.identity) then
      return nil, "project: 搜索条件属于其他工程"
    end
    out.search = recipe
  end
  if published then
    if
      not text(draft.id, 96, false)
      or not draft.id:match("^[%w_-]+$")
      or not integer(draft.revision, 1, MAX_INTEGER - 1)
      or not integer(draft.created_at, 1, MAX_INTEGER)
      or not integer(draft.updated_at, 1, MAX_INTEGER)
    then
      return nil, "schema: 工作上下文的编号、版本或时间无效"
    end
    for _, key in ipairs({ "id", "revision", "created_at", "updated_at" }) do
      out[key] = draft[key]
    end
  end
  return out
end

local function collection_value(raw, project)
  if raw == nil then
    return { version = 1, project = project, cards = {} }
  end
  local ok, value = pcall(vim.json.decode, raw)
  if not ok or not object(value, { version = true, project = true, cards = true }) or value.version ~= 1 then
    return nil, "corrupt: 工作上下文文件格式或版本无效"
  end
  local owner, owner_err = project_value(value.project)
  if not owner or not same_project(owner, project) then
    return nil, "corrupt: 工作上下文文件的工程归属无效" .. (owner_err and (": " .. owner_err) or "")
  end
  if type(value.cards) ~= "table" or not vim.islist(value.cards) or #value.cards > MAX_CARDS then
    return nil, "corrupt: 工作上下文列表无效或超过 16 项"
  end
  local cards, seen = {}, {}
  for _, card in ipairs(value.cards) do
    local saved, err = draft_value(card, project, true)
    if not saved or seen[saved.id] then
      return nil, "corrupt: " .. (err or "工作上下文编号重复")
    end
    cards[#cards + 1], seen[saved.id] = saved, true
  end
  return { version = 1, project = owner, cards = cards }
end

-- UV callbacks never validate or invoke user callbacks in a fast event.
local function read_raw(path, done)
  uv.fs_open(path, "r", 384, function(open_err, fd)
    if open_err then
      if tostring(open_err):find("ENOENT", 1, true) then
        return later(done)
      end
      return later(done, nil, "read: " .. tostring(open_err))
    end
    local function close(raw, err)
      uv.fs_close(fd, function(close_err)
        later(done, raw, err or (close_err and ("read: " .. tostring(close_err))))
      end)
    end
    uv.fs_fstat(fd, function(stat_err, stat)
      if stat_err or not stat or stat.type ~= "file" then
        return close(nil, "read: 无法读取工作上下文文件")
      elseif stat.size > MAX_BYTES then
        return close(nil, "budget: 工作上下文文件超过 2 MiB")
      end
      local chunks, offset = {}, 0
      local function read()
        uv.fs_read(fd, math.min(65536, MAX_BYTES + 1 - offset), offset, function(err, chunk)
          if err or type(chunk) ~= "string" then
            return close(nil, "read: " .. tostring(err or "invalid read"))
          elseif chunk == "" then
            return close(table.concat(chunks))
          end
          offset = offset + #chunk
          if offset > MAX_BYTES then
            return close(nil, "budget: 工作上下文文件超过 2 MiB")
          end
          chunks[#chunks + 1] = chunk
          read()
        end)
      end
      read()
    end)
  end)
end

local function mkdir(path, done)
  uv.fs_stat(path, function(err, stat)
    if stat then
      return later(done, stat.type ~= "directory" and "write: 工作上下文目录不是目录" or nil)
    end
    if err and not tostring(err):find("ENOENT", 1, true) then
      return later(done, "write: " .. tostring(err))
    end
    local parent = vim.fs.dirname(path)
    if not parent or parent == path then
      return later(done, "write: 无法创建工作上下文目录")
    end
    mkdir(parent, function(parent_err)
      if parent_err then
        return done(parent_err)
      end
      uv.fs_mkdir(path, 448, function(create_err)
        if create_err and not tostring(create_err):find("EEXIST", 1, true) then
          return later(done, "write: " .. tostring(create_err))
        end
        uv.fs_stat(path, function(stat_err, created)
          later(
            done,
            (stat_err or not created or created.type ~= "directory") and "write: 无法创建工作上下文目录"
              or nil
          )
        end)
      end)
    end)
  end)
end

local function token()
  serial = serial + 1
  return table.concat({ vim.fn.getpid(), uv.hrtime(), serial }, "-")
end

local function publish(path, raw, done)
  local temp = path .. ".tmp." .. token()
  local function fail(err)
    uv.fs_unlink(temp, function()
      later(done, "write: " .. tostring(err))
    end)
  end
  uv.fs_open(temp, "wx", 384, function(open_err, fd)
    if open_err then
      return later(done, "write: " .. tostring(open_err))
    end
    local function close(err)
      uv.fs_close(fd, function(close_err)
        err = err or close_err
        if err then
          return fail(err)
        end
        uv.fs_rename(temp, path, function(rename_err)
          if rename_err then
            return fail(rename_err)
          end
          later(done)
        end)
      end)
    end
    local offset = 0
    local function write()
      uv.fs_write(fd, raw:sub(offset + 1), offset, function(err, count)
        if err or not count or count <= 0 then
          return close(err or "short write")
        end
        offset = offset + count
        if offset < #raw then
          return write()
        end
        uv.fs_fsync(fd, close)
      end)
    end
    write()
  end)
end

local function transaction(project, change, done)
  local path = assert(M.path(project))
  mkdir(vim.fs.dirname(path), function(dir_err)
    if dir_err then
      return done(nil, dir_err)
    end
    local called, lease, lock_err = pcall(locks.acquire, path .. ".lock")
    if not called or not lease then
      local reason = called and lock_err or lease
      return done(nil, "busy: 工作上下文正由另一操作更新，请重试: " .. tostring(reason))
    end
    local finished = false
    local function finish(result, err)
      if finished then
        return
      end
      finished = true
      local released, value = pcall(locks.release, lease)
      if not released or not value then
        result, err = nil, "lock: 无法释放工作上下文写入租约"
      end
      later(done, result, err)
    end
    read_raw(path, function(previous, read_err)
      if read_err then
        return finish(nil, read_err)
      end
      local collection, decode_err = collection_value(previous, project)
      if not collection then
        return finish(nil, decode_err)
      end
      local result, change_err = change(collection)
      if result == nil then
        return finish(nil, change_err)
      end
      local encoded, raw = pcall(vim.json.encode, collection)
      if not encoded or #raw > MAX_BYTES then
        return finish(nil, "budget: 工作上下文集合超过 2 MiB 或无法序列化")
      end
      local function rollback(reason)
        -- One operation-local re-read proves ownership before guarded recovery.
        read_raw(path, function(current, current_err)
          if current_err or current ~= raw then
            return finish(nil, "verify: " .. reason .. "; 无法确认当前文件仍属本次发布，已保留现状")
          end
          local function restored(err)
            if err then
              return finish(nil, "verify: " .. reason .. "; 原元数据恢复失败: " .. err)
            end
            read_raw(path, function(recovered, recovery_err)
              if recovery_err or recovered ~= previous then
                return finish(nil, "verify: " .. reason .. "; 原元数据恢复无法核验")
              end
              finish(nil, "verify: " .. reason .. "; 原元数据已保留")
            end)
          end
          if previous ~= nil then
            publish(path, previous, restored)
          else
            uv.fs_unlink(path, function(err)
              later(restored, err and ("write: " .. tostring(err)))
            end)
          end
        end)
      end
      publish(path, raw, function(write_err)
        if write_err then
          return finish(nil, write_err)
        end
        read_raw(path, function(observed, verify_err)
          if verify_err or observed ~= raw then
            return rollback(verify_err or "发布后的回读字节不一致")
          end
          local valid, valid_err = collection_value(observed, project)
          if not valid then
            return rollback(valid_err or "发布后的元数据无效")
          end
          if type(result) == "table" then
            for _, card in ipairs(valid.cards) do
              if card.id == result.id and card.revision == result.revision then
                return finish(card)
              end
            end
            return rollback("回读中未找到本次卡片版本")
          end
          finish(result)
        end)
      end)
    end)
  end)
end

--- Read only the selected disk bucket; no cache, live references or UI.
---@param project table
---@param done fun(cards: table[]?, err: string?)
function M.load(project, done)
  assert(type(done) == "function", "work context load callback required")
  project = vim.deepcopy(project)
  vim.schedule(function()
    local owner, err = project_value(project)
    if not owner then
      return done(nil, err)
    end
    read_raw(assert(M.path(owner)), function(raw, read_err)
      if read_err then
        return done(nil, read_err)
      end
      local collection, decode_err = collection_value(raw, owner)
      done(collection and collection.cards or nil, decode_err)
    end)
  end)
end

---@param project table
---@param draft table
---@param opts? table|fun(card: table?, err: string?)
---@param done? fun(card: table?, err: string?)
function M.save(project, draft, opts, done)
  if type(opts) == "function" then
    done, opts = opts, {}
  end
  assert(type(done) == "function", "work context save callback required")
  project, draft, opts = vim.deepcopy(project), vim.deepcopy(draft), vim.deepcopy(opts or {})
  vim.schedule(function()
    local owner, err = project_value(project)
    if not owner then
      return done(nil, err)
    end
    local card, draft_err = draft_value(draft, owner, false)
    if not card then
      return done(nil, draft_err)
    end
    if
      not object(opts, { id = true, expected_revision = true })
      or opts.id ~= nil and (not text(opts.id, 96, false) or not opts.id:match("^[%w_-]+$") or not integer(
        opts.expected_revision,
        1,
        MAX_INTEGER - 1
      ))
      or opts.id == nil and opts.expected_revision ~= nil
    then
      return done(nil, "revision: 更新须给出原卡片编号和版本")
    end
    transaction(owner, function(collection)
      local existing, index
      for i, item in ipairs(collection.cards) do
        if item.id == opts.id then
          existing, index = item, i
          break
        end
      end
      if opts.id then
        if not existing or existing.revision ~= opts.expected_revision then
          return nil, "revision: 卡片已更新或删除，请刷新后重试"
        end
        if existing.revision >= MAX_INTEGER - 1 then
          return nil, "budget: 卡片版本已达到整数预算，未更新元数据"
        end
        card.id, card.revision, card.created_at = existing.id, existing.revision + 1, existing.created_at
        table.remove(collection.cards, index)
      else
        if #collection.cards >= MAX_CARDS then
          return nil, "full: 已有 16 个工作上下文，请先显式删除元数据"
        end
        card.id, card.revision, card.created_at = vim.fn.sha256(token()):sub(1, 32), 1, os.time()
      end
      card.updated_at = os.time()
      table.insert(collection.cards, 1, card)
      return card
    end, done)
  end)
end

---@param project table
---@param id string
---@param expected_revision integer
---@param done fun(ok: boolean?, err: string?)
function M.delete(project, id, expected_revision, done)
  assert(type(done) == "function", "work context delete callback required")
  project = vim.deepcopy(project)
  vim.schedule(function()
    local owner, err = project_value(project)
    if not owner then
      return done(nil, err)
    end
    if not text(id, 96, false) or not id:match("^[%w_-]+$") or not integer(expected_revision, 1, MAX_INTEGER - 1) then
      return done(nil, "revision: 删除须给出原卡片编号和版本")
    end
    transaction(owner, function(collection)
      for index, card in ipairs(collection.cards) do
        if card.id == id and card.revision == expected_revision then
          table.remove(collection.cards, index)
          return true
        end
      end
      return nil, "revision: 卡片已更新或删除，请刷新后重试"
    end, done)
  end)
end

M.limits = { cards = MAX_CARDS, files = MAX_FILES, bytes = MAX_BYTES }
return M
