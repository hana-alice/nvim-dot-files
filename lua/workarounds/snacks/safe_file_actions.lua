-- WORKAROUND
-- name: snacks.safe_file_actions
-- scope: snacks
-- issue: internal: explorer rename force-deletes dirty buffers and can overwrite destinations; delete force-unloads dirty text.
-- symptom: Explorer rename/delete loses unsaved text and rename silently replaces an existing file.
-- introduced: 2026-10-04
-- removal_condition: Snacks preserves document identity and implements guarded asynchronous no-overwrite file operations.
-- owner: hana-alice
-- enabled: true
-- END WORKAROUND

-- Apply to Snacks opts without eagerly requiring the explorer or file owners.
local M = {}
local enabled = false
local records = setmetatable({}, { __mode = "k" })
local active = setmetatable({}, { __mode = "k" })

local function notify(reason)
  vim.notify(require("utils.file_mutations").message(reason), vim.log.levels.WARN)
end

local function begin(picker, kind, paths)
  if active[picker] then
    require("utils.file_mutations").cancel(active[picker].plan)
  end
  local token = { cwd = picker:cwd() }
  active[picker] = token
  local plan, err = require("utils.file_mutations").prepare(paths, {
    kind = kind,
    cwd = token.cwd,
    is_current = function()
      return enabled and not picker.closed and active[picker] == token and picker:cwd() == token.cwd
    end,
  })
  if not plan then
    active[picker] = nil
    notify(err)
    return
  end
  token.plan = plan
  return plan
end

local function complete(picker, plan, ok, reason, changed)
  if active[picker] and active[picker].plan == plan then
    active[picker] = nil
  end
  if not ok then
    notify(reason)
  end
  if #(changed or {}) > 0 then
    local Tree = require("snacks.explorer.tree")
    for _, value in ipairs(changed) do
      Tree:refresh(vim.fs.dirname(value.from))
      if value.to then
        Tree:refresh(vim.fs.dirname(value.to))
      end
      if value.recovery then
        vim.notify("原对象已隔离保留，请检查恢复路径：" .. value.recovery, vim.log.levels.WARN)
      elseif not ok and value.to then
        vim.notify("文件已移动，文本仍保留，请检查目标路径：" .. value.to, vim.log.levels.WARN)
      end
    end
    if not picker.closed then
      local target = ok and changed[#changed].to or nil
      require("snacks.explorer.actions").update(picker, { target = target })
    end
    if plan.kind == "delete" and ok then
      vim.notify("已送入回收站；打开的文本仍保留", vim.log.levels.INFO)
    end
  end
end

local function selected(picker)
  local paths = {}
  for _, item in ipairs(picker:selected({ fallback = true })) do
    paths[#paths + 1] = require("snacks.picker.util").path(item)
  end
  return paths
end

local function rename(picker, item)
  item = item or picker:current()
  if not item or not item.file then
    return
  end
  local plan = begin(picker, "rename", { item.file })
  if not plan then
    return
  end
  local relative = vim.fs.relpath(plan.cwd, item.file) or plan.sources[1].path
  vim.ui.input({ prompt = "New File Name (no overwrite): ", default = relative, completion = "file" }, function(value)
    if not value or value == "" or value == relative then
      require("utils.file_mutations").cancel(plan)
      return
    end
    require("utils.file_mutations").rename(plan, { value }, function(...)
      complete(picker, plan, ...)
    end)
  end)
end

local function move(picker)
  local paths = selected(picker)
  if #paths == 0 then
    return
  end
  local plan = begin(picker, "move", paths)
  if not plan then
    return
  end
  vim.ui.input(
    { prompt = "Move into existing directory: ", completion = "dir", default = plan.cwd .. "/" },
    function(value)
      if not value or value == "" then
        require("utils.file_mutations").cancel(plan)
        return
      end
      local path, err = require("utils.file_mutations").path(value, plan.cwd)
      if not path then
        return notify(err)
      end
      local stat = vim.uv.fs_stat(path)
      if not stat or stat.type ~= "directory" then
        return notify("destination-parent-unavailable")
      end
      local targets = {}
      for _, source in ipairs(plan.sources) do
        targets[#targets + 1] = vim.fs.joinpath(path, vim.fs.basename(source.path))
      end
      require("utils.file_mutations").rename(plan, targets, function(...)
        complete(picker, plan, ...)
      end)
    end
  )
end

local function delete(picker)
  local paths = selected(picker)
  if #paths == 0 then
    return
  end
  local plan = begin(picker, "delete", paths)
  if not plan then
    return
  end
  require("snacks.picker.util").confirm("Trash " .. #paths .. " selected paths? Open text is retained.", function()
    require("utils.file_mutations").delete(plan, function(...)
      complete(picker, plan, ...)
    end)
  end)
end

local actions = { explorer_rename = rename, explorer_move = move, explorer_del = delete }

function M.apply(opts)
  opts = opts or {}
  opts.picker = opts.picker or {}
  opts.picker.sources = opts.picker.sources or {}
  opts.picker.sources.explorer = opts.picker.sources.explorer or {}
  local source = opts.picker.sources.explorer
  source.actions = source.actions or {}
  if not records[source.actions] then
    local record = { source = source, previous_close = source.on_close, previous = {}, wrappers = {}, active = true }
    for name, fn in pairs(actions) do
      record.previous[name] = source.actions[name]
      local wrapper = function(picker, item)
        if not enabled or not record.active then
          local previous = record.previous[name]
          if type(previous) == "function" then
            return previous(picker, item)
          end
          if previous then
            local resolved = require("snacks.picker.core.actions").resolve(vim.deepcopy(previous), picker, name)
            return resolved.action(picker, item, resolved)
          end
          return require("snacks.explorer.actions").actions[name](picker, item)
        end
        return fn(picker, item)
      end
      record.wrappers[name] = wrapper
      source.actions[name] = wrapper
    end
    record.close = function(picker)
      if active[picker] then
        require("utils.file_mutations").cancel(active[picker].plan)
        active[picker] = nil
      end
      if record.previous_close then
        record.previous_close(picker)
      end
    end
    source.on_close = record.close
    records[source.actions] = record
  end
  enabled = true
  return opts
end

function M.disable()
  enabled = false
  for picker, token in pairs(active) do
    require("utils.file_mutations").cancel(token.plan)
    active[picker] = nil
  end
  for actions, record in pairs(records) do
    record.active = false
    for name, wrapper in pairs(record.wrappers) do
      if actions[name] == wrapper then
        actions[name] = record.previous[name]
      end
    end
    if record.source.on_close == record.close then
      record.source.on_close = record.previous_close
    end
    records[actions] = nil
  end
end

function M.status()
  return { applied = enabled }
end

return M
