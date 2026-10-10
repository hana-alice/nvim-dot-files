-- Own only explicit Explorer file changes. Never unload user text or replace
-- an existing destination. A host no-replace move also isolates trash objects.
local M = {}
local uv = vim.uv or vim.loop
local api = vim.api
local MAX_PATHS = 128
local last_receipt

local function canonical(path)
  path = vim.fs.normalize(path)
  local real = uv.fs_realpath(path)
  if real then
    return vim.fs.normalize(real)
  end
  -- Neovim may retain a Windows short-name buffer while libuv returns its long
  -- name. Resolve an existing ancestor even after the source was moved away.
  local cursor, suffix = path, {}
  for _ = 1, 64 do
    local parent = vim.fs.dirname(cursor)
    if not parent or parent == cursor then
      break
    end
    table.insert(suffix, 1, vim.fs.basename(cursor))
    cursor = parent
    real = uv.fs_realpath(cursor)
    if real then
      return vim.fs.normalize(vim.fs.joinpath(real, unpack(suffix)))
    end
  end
  return path
end

local function key(path)
  return require("utils.platform").driver().path_key(canonical(path))
end

function M.path(path, cwd)
  if type(path) ~= "string" or path == "" or path:find("[%z\r\n]") then
    return nil, "invalid-path"
  end
  if not path:match("^[/\\]") and not path:match("^%a:[/\\]") then
    path = vim.fs.joinpath(cwd or uv.cwd(), path)
  end
  local normalized = vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
  if normalized ~= "/" and not normalized:match("^%a:/$") then
    normalized = normalized:gsub("/$", "")
  end
  return normalized
end

local function inside(path, root)
  local p, r = key(path), key(root)
  return p == r or p:sub(1, #r + 1) == r .. "/"
end

local function signature(stat)
  if not stat then
    return nil
  end
  return table.concat({ stat.type, stat.dev, stat.ino, stat.size, stat.mode, stat.mtime.sec, stat.mtime.nsec }, ":")
end

function M.snapshot(path)
  return signature(uv.fs_lstat(path))
end

function M.last()
  return last_receipt and vim.deepcopy(last_receipt) or nil
end

local function parent_identity(path)
  local parent = vim.fs.dirname(path)
  local real, stat = uv.fs_realpath(parent), uv.fs_stat(parent)
  if not real or not stat or stat.type ~= "directory" then
    return nil
  end
  return { path = parent, real = key(real), dev = stat.dev, ino = stat.ino }
end

local function parent_current(value)
  local real, stat = uv.fs_realpath(value.path), uv.fs_stat(value.path)
  return real
    and stat
    and stat.type == "directory"
    and key(real) == value.real
    and stat.dev == value.dev
    and stat.ino == value.ino
end

local function source_index(plan, path)
  local path_key = key(path)
  for index, source in ipairs(plan.sources) do
    if
      not plan.completed[index]
      and (path_key == source.key or source.dir and path_key:sub(1, #source.key + 1) == source.key .. "/")
    then
      return index
    end
  end
end

local function buffers(plan)
  local result = {}
  for _, buf in ipairs(api.nvim_list_bufs()) do
    if api.nvim_buf_is_valid(buf) and vim.bo[buf].buftype == "" then
      local name = api.nvim_buf_get_name(buf)
      local index = name ~= "" and source_index(plan, name) or nil
      if index then
        local loaded = api.nvim_buf_is_loaded(buf)
        result[buf] = {
          buf = buf,
          index = index,
          name = name,
          path = canonical(name),
          loaded = loaded,
          tick = api.nvim_buf_get_changedtick(buf),
          modified = vim.bo[buf].modified,
          stat = signature(uv.fs_lstat(name)),
        }
      end
    end
  end
  return result
end

local function check_buffers(plan)
  local current = buffers(plan)
  for buf, before in pairs(plan.buffers) do
    if not plan.completed[before.index] then
      local now = current[buf]
      if
        not now
        or now.name ~= before.name
        or now.loaded ~= before.loaded
        or now.tick ~= before.tick
        or now.modified ~= before.modified
      then
        return false, "source-buffer-changed"
      end
    end
  end
  for buf, value in pairs(current) do
    if value.modified then
      return false, "source-unsaved"
    end
    if not plan.buffers[buf] then
      return false, "source-buffer-added"
    end
  end
  return true
end

local function destination_buffer(path)
  for _, buf in ipairs(api.nvim_list_bufs()) do
    if api.nvim_buf_is_valid(buf) then
      local name = api.nvim_buf_get_name(buf)
      if name ~= "" and inside(name, path) then
        return buf
      end
    end
  end
end

function M.prepare(paths, opts)
  opts = opts or {}
  if type(paths) ~= "table" or #paths == 0 or #paths > MAX_PATHS then
    return nil, "path-limit"
  end
  local plan = {
    kind = opts.kind or "rename",
    sources = {},
    completed = {},
    cwd = opts.cwd or uv.cwd(),
    is_current = opts.is_current,
    canceled = false,
    finished = false,
  }
  if plan.kind ~= "rename" and plan.kind ~= "move" and plan.kind ~= "delete" then
    return nil, "invalid-operation"
  end
  for _, value in ipairs(paths) do
    local path, err = M.path(value, plan.cwd)
    if not path then
      return nil, err
    end
    local stat = uv.fs_lstat(path)
    if not stat then
      return nil, "source-missing"
    end
    if stat.type ~= "file" and stat.type ~= "directory" then
      return nil, "unsupported-source-type"
    end
    path = vim.fs.normalize(uv.fs_realpath(path) or path)
    for _, source in ipairs(plan.sources) do
      if inside(path, source.path) or inside(source.path, path) then
        return nil, "overlapping-sources"
      end
    end
    local parent = parent_identity(path)
    if not parent then
      return nil, "source-parent-unavailable"
    end
    plan.sources[#plan.sources + 1] =
      { path = path, key = key(path), dir = stat.type == "directory", stat = signature(stat), parent = parent }
  end
  plan.buffers = buffers(plan)
  for _, value in pairs(plan.buffers) do
    if value.modified then
      return nil, "source-unsaved"
    end
  end
  local ok, err = M.validate(plan)
  return ok and plan or nil, err
end

function M.validate(plan)
  if not plan or plan.canceled or plan.finished then
    return false, "canceled"
  end
  if plan.is_current and not plan.is_current() then
    return false, "owner-changed"
  end
  if plan.providers_current and not plan.providers_current() then
    return false, "rename-providers-changed"
  end
  for index, source in ipairs(plan.sources) do
    if not plan.completed[index] then
      if not parent_current(source.parent) or signature(uv.fs_lstat(source.path)) ~= source.stat then
        return false, "source-changed"
      end
    end
  end
  local buffers_valid, buffers_err = check_buffers(plan)
  if not buffers_valid then
    return false, buffers_err
  end
  for index, target in ipairs(plan.targets or {}) do
    if not plan.completed[index] then
      if uv.fs_lstat(target.path) then
        return false, "destination-exists"
      end
      if not parent_current(target.parent) then
        return false, "destination-parent-changed"
      end
      if destination_buffer(target.path) then
        return false, "destination-buffer-exists"
      end
    end
  end
  return true
end

function M.targets(plan, paths)
  local ok, err = M.validate(plan)
  if not ok then
    return false, err
  end
  if type(paths) ~= "table" or #paths ~= #plan.sources then
    return false, "invalid-destinations"
  end
  local targets = {}
  for index, value in ipairs(paths) do
    local source = plan.sources[index]
    local path, path_err = M.path(value, plan.cwd)
    if not path then
      return false, path_err
    end
    if inside(path, source.path) or inside(source.path, path) then
      return false, "overlapping-destination"
    end
    if uv.fs_lstat(path) then
      return false, "destination-exists"
    end
    if destination_buffer(path) then
      return false, "destination-buffer-exists"
    end
    local parent = parent_identity(path)
    if not parent then
      return false, "destination-parent-unavailable"
    end
    for _, target in ipairs(targets) do
      if inside(path, target.path) or inside(target.path, path) then
        return false, "overlapping-destinations"
      end
    end
    targets[#targets + 1] = { path = path, parent = parent }
  end
  plan.targets = targets
  return M.validate(plan)
end

function M.cancel(plan)
  if not plan or plan.finished then
    return
  end
  plan.canceled = true
  if plan.cancel_requests then
    plan.cancel_requests()
  end
end

local function finish(plan, callback, ok, reason)
  if plan.finished then
    return
  end
  plan.finished = true
  local changed = {}
  for index, source in ipairs(plan.sources) do
    if plan.completed[index] or plan.isolated and plan.isolated[index] then
      changed[#changed + 1] = {
        from = source.path,
        to = plan.targets and plan.targets[index].path,
        recovery = plan.isolated and plan.isolated[index] or nil,
      }
    end
  end
  last_receipt = {
    state = ok and "completed" or (#changed > 0 and "needs-review" or "rejected"),
    operation = plan.kind,
    reason = reason,
    changed = vim.deepcopy(changed),
  }
  if callback then
    callback(ok, reason, changed)
  end
end

local function retain_buffer_names(plan, index)
  local source, target = plan.sources[index], plan.targets[index]
  for buf, before in pairs(plan.buffers) do
    if before.index == index and api.nvim_buf_is_valid(buf) and api.nvim_buf_get_name(buf) == before.name then
      -- The same document survives: extmarks, undo, dirty text and all windows.
      local name = target.path .. before.path:sub(#source.path + 1)
      local ok, err = require("utils.file_mutations_documents").rename(before, name, {
        same_path = function(a, b)
          return key(a) == key(b)
        end,
        disk = function()
          return M.snapshot(before.name)
        end,
        current = function()
          return not plan.canceled and (not plan.is_current or plan.is_current())
        end,
      })
      if not ok then
        return false, tostring(err)
      end
      local refreshed, refresh_err = require("utils.file_mutations_metadata").refresh({
        buf = buf,
        name = api.nvim_buf_get_name(buf),
        tick = before.tick,
        loaded = before.loaded,
        modified = before.modified,
      }, {
        disk = function()
          return M.snapshot(name)
        end,
        expected = before.stat,
        current = function()
          return not plan.canceled and (not plan.is_current or plan.is_current())
        end,
      })
      if not refreshed then
        return false, refresh_err
      end
    end
  end
  return true
end

local function move_files(plan, callback)
  local function next_file(index)
    if index > #plan.sources then
      return finish(plan, callback, true)
    end
    local valid, reason = M.validate(plan)
    if not valid then
      return finish(plan, callback, false, reason)
    end
    local source, target = plan.sources[index], plan.targets[index]
    local driver = require("utils.platform").driver()
    if not driver.rename_no_replace then
      return finish(plan, callback, false, "exclusive-move-unavailable")
    end
    driver.rename_no_replace(source.path, target.path, function(ok, move_err)
      if not ok then
        return finish(plan, callback, false, move_err)
      end
      local moved_valid = signature(uv.fs_lstat(target.path)) == source.stat and parent_current(target.parent)
      local documents_valid, document_err = check_buffers(plan)
      local destination_valid = not destination_buffer(target.path)
      local owner_current = not plan.canceled and (not plan.is_current or plan.is_current())
      -- The native move protects destination exclusivity, not source identity.
      -- A changed moved object stays visible at its new path, never discarded.
      plan.completed[index] = true
      if not moved_valid or not documents_valid or not destination_valid or not owner_current then
        return finish(plan, callback, false, document_err or "moved-object-changed")
      end
      local renamed, rename_err = retain_buffer_names(plan, index)
      if not renamed then
        return finish(plan, callback, false, "buffer-rename: " .. rename_err)
      end
      require("utils.file_mutations_lsp").notify(plan, index)
      next_file(index + 1)
    end)
  end
  next_file(1)
end

function M.rename(plan, paths, callback)
  local ok, err = M.targets(plan, paths)
  if not ok then
    return finish(plan, callback, false, err)
  end
  require("utils.file_mutations_lsp").prepare(plan, function(ready, reason)
    if not ready then
      return finish(plan, callback, false, reason)
    end
    move_files(plan, callback)
  end)
end

function M.delete(plan, callback)
  if plan.kind ~= "delete" then
    return finish(plan, callback, false, "invalid-operation")
  end
  local function next_path(index)
    if index > #plan.sources then
      return finish(plan, callback, true)
    end
    local valid, reason = M.validate(plan)
    if not valid then
      return finish(plan, callback, false, reason)
    end
    local source = plan.sources[index]
    if not require("utils.file_mutations_trash").available(source.path) then
      return finish(plan, callback, false, "trash-unavailable")
    end
    local driver = require("utils.platform").driver()
    if not driver.rename_no_replace then
      return finish(plan, callback, false, "exclusive-move-unavailable")
    end
    local quarantine = vim.fs.joinpath(
      vim.fs.dirname(source.path),
      ".nvim-trash-" .. vim.fn.sha256(vim.fn.tempname() .. tostring(uv.hrtime())):sub(1, 24)
    )
    plan.isolated = plan.isolated or {}
    driver.rename_no_replace(source.path, quarantine, function(moved, move_err)
      if not moved then
        return finish(plan, callback, false, move_err)
      end
      plan.isolated[index] = quarantine
      local object_valid = signature(uv.fs_lstat(quarantine)) == source.stat and parent_current(source.parent)
      local documents_valid, document_err = check_buffers(plan)
      if not object_valid or not documents_valid or plan.canceled or plan.is_current and not plan.is_current() then
        return finish(plan, callback, false, document_err or "isolated-object-changed")
      end
      require("utils.file_mutations_trash").run(quarantine, source.stat, function(ok, err)
        if not ok then
          return finish(plan, callback, false, err)
        end
        if uv.fs_lstat(quarantine) then
          return finish(plan, callback, false, "trash-did-not-remove-object")
        end
        -- The child never receives the original path. A new object there survives.
        local document_error
        for buf, before in pairs(plan.buffers) do
          if
            before.index == index
            and before.loaded
            and api.nvim_buf_is_loaded(buf)
            and api.nvim_buf_get_name(buf) == before.name
            and api.nvim_buf_get_changedtick(buf) == before.tick
            and vim.bo[buf].modified == before.modified
            and not uv.fs_lstat(before.name)
          then
            local detached, detach_err = require("utils.file_mutations_documents").rename(before, "", {
              same_path = function(a, b)
                return key(a) == key(b)
              end,
              disk = function()
                return M.snapshot(before.name)
              end,
            })
            if detached then
              vim.bo[buf].modified = true
            else
              document_error = document_error or detach_err
            end
          end
        end
        plan.completed[index], plan.isolated[index] = true, nil
        if document_error then
          return finish(plan, callback, false, document_error)
        end
        next_path(index + 1)
      end)
    end)
  end
  next_path(1)
end

function M.message(reason)
  local messages = {
    ["source-unsaved"] = "文件或目录中有未保存内容，请先保存再操作",
    ["source-buffer-changed"] = "等待期间文件内容或缓冲区身份发生变化，请重新检查",
    ["source-buffer-added"] = "等待期间打开了新的相关缓冲区，请重新检查",
    ["destination-exists"] = "目标已存在，文件改名不会覆盖，请换一个名称",
    ["destination-buffer-exists"] = "目标缓冲区仍存在，请先保存并关闭它",
    ["destination-parent-unavailable"] = "目标目录不存在，请先显式创建目录",
    ["rename-edits-require-preview"] = "语言服务器要求修改相关文件；文件改名尚不支持该预览，已取消",
    ["trash-unavailable"] = "没有可用回收站命令，已保留文件，不会永久删除",
  }
  return messages[reason] or ("操作未完成，请检查状态：" .. tostring(reason))
end

return M
