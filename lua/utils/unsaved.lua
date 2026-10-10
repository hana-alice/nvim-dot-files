-- Event-maintained modified-buffer count; no polling or statusline scans.
local M = {}
local dirty = {}
local attached = {}
local queued = {}
local pending = false

local function update(buf, removed)
  local modified = not removed and vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].modified or nil
  if dirty[buf] == modified then
    return
  end
  dirty[buf] = modified
  local count = vim.tbl_count(dirty)
  vim.g.ue_unsaved_count = count
  vim.g.ue_unsaved_status = count > 0 and ("未保存:" .. count) or ""
  vim.cmd("redrawstatus")
end

local function track(buf)
  update(buf)
  if attached[buf] or not vim.api.nvim_buf_is_loaded(buf) then
    return
  end
  attached[buf] = vim.api.nvim_buf_attach(buf, false, {
    on_lines = function()
      update(buf)
      -- Undo may clear 'modified' AFTER on_lines. Reconcile after the edit,
      -- once per buffer per loop turn, including buffers with no window.
      if queued[buf] then
        return
      end
      queued[buf] = true
      vim.schedule(function()
        queued[buf] = nil
        update(buf, not vim.api.nvim_buf_is_loaded(buf))
      end)
    end,
    on_reload = function()
      update(buf)
    end,
    on_detach = function()
      attached[buf] = nil
      update(buf, true)
    end,
  }) or nil
end

-- Exit/list actions may scan once; drawing the statusline never calls this.
function M.list()
  local items = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].modified then
      local name = vim.api.nvim_buf_get_name(buf)
      local kind = vim.bo[buf].buftype
      items[#items + 1] = {
        buf = buf,
        name = name,
        label = (name ~= "" and vim.fn.fnamemodify(name, ":~:.") or ("[未命名 #" .. buf .. "]"))
          .. (kind ~= "" and (" [" .. kind .. "]") or ""),
      }
    end
  end
  table.sort(items, function(a, b)
    return a.buf < b.buf
  end)
  return items
end

function M.review()
  local items = M.list()
  if #items == 0 then
    vim.notify("没有未保存的缓冲区", vim.log.levels.INFO)
    return
  end
  vim.ui.select(items, {
    prompt = "未保存文件（选择查看，退出已取消）：",
    format_item = function(item)
      return item.label
    end,
  }, function(item)
    if not item or not vim.api.nvim_buf_is_valid(item.buf) then
      return
    end
    -- :buffer preserves the current dirty buffer even with 'hidden' disabled.
    vim.cmd("hide buffer " .. item.buf)
  end)
end

function M.save_all()
  local errors = {}
  for _, item in ipairs(M.list()) do
    if item.name == "" or vim.bo[item.buf].buftype ~= "" then
      errors[#errors + 1] = item.label .. "：请先指定保存路径或处理特殊缓冲区"
    else
      local ok, err = pcall(vim.api.nvim_buf_call, item.buf, function()
        vim.cmd("write")
      end)
      update(item.buf)
      if not ok or vim.bo[item.buf].modified then
        errors[#errors + 1] = item.label .. "：" .. tostring(err or "保存后仍有修改")
      end
    end
  end
  if #errors > 0 then
    vim.notify(table.concat(errors, "\n"), vim.log.levels.WARN)
  end
  return #errors == 0 and #M.list() == 0
end

function M.quit()
  if pending then
    return
  end
  local items = M.list()
  if #items == 0 then
    return vim.cmd("qa")
  end
  pending = true
  local labels = vim.tbl_map(function(item)
    return item.label
  end, items)
  local choices = { "保存全部并退出", "逐个查看（取消退出）", "放弃修改并退出", "取消退出" }
  vim.list_extend(choices, items)
  vim.ui.select(choices, {
    prompt = ("退出：%d 个未保存缓冲区（文件在下方）"):format(#labels),
    format_item = function(item)
      return type(item) == "table" and item.label or item
    end,
  }, function(choice)
    pending = false
    if type(choice) == "table" then
      if vim.api.nvim_buf_is_valid(choice.buf) then
        vim.cmd("hide buffer " .. choice.buf)
      end
    elseif choice == "保存全部并退出" then
      if M.save_all() then
        vim.cmd("qa")
      end
    elseif choice == "逐个查看（取消退出）" then
      M.review()
    elseif choice == "放弃修改并退出" then
      -- Re-read the complete list: buffers may have changed while the picker was open.
      local current = M.list()
      local names = vim.tbl_map(function(item)
        return item.label
      end, current)
      local ticks = {}
      for _, item in ipairs(current) do
        ticks[item.buf] = vim.api.nvim_buf_get_changedtick(item.buf)
      end
      if
        vim.fn.confirm(
          "确定放弃以下文件的修改？\n" .. table.concat(names, "\n"),
          "放弃 (&y)\n取消 (&n)",
          2
        ) == 1
      then
        -- Native confirmation keeps processing events; only discard what was shown.
        local latest = M.list()
        local changed = #current ~= #latest
        for index, item in ipairs(latest) do
          local previous = current[index]
          if
            not previous
            or previous.buf ~= item.buf
            or previous.name ~= item.name
            or ticks[item.buf] ~= vim.api.nvim_buf_get_changedtick(item.buf)
          then
            changed = true
            break
          end
        end
        if changed then
          vim.notify(
            "未保存文件在确认期间发生变化，已取消退出，请重新检查",
            vim.log.levels.INFO
          )
          return
        end
        vim.cmd("qa!")
      end
    end
  end)
end

function M.setup()
  dirty = {}
  vim.g.ue_unsaved_count, vim.g.ue_unsaved_status = 0, ""
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    track(buf)
  end
  local group = vim.api.nvim_create_augroup("UEUnsavedBuffers", { clear = true })
  vim.api.nvim_create_autocmd(
    { "BufModifiedSet", "BufEnter", "BufAdd", "BufDelete", "BufWritePost", "BufWinEnter", "BufReadPost" },
    {
      group = group,
      callback = function(event)
        if event.event == "BufDelete" then
          -- BufDelete runs before unload completes, and also fires on unlisting.
          vim.schedule(function()
            update(event.buf, not vim.api.nvim_buf_is_loaded(event.buf))
          end)
        else
          track(event.buf)
        end
      end,
    }
  )
  vim.api.nvim_create_autocmd({ "BufWipeout", "BufUnload" }, {
    group = group,
    callback = function(event)
      update(event.buf, true)
    end,
  })
  vim.api.nvim_create_autocmd("OptionSet", {
    group = group,
    pattern = { "modified", "buflisted" },
    callback = function()
      update(vim.api.nvim_get_current_buf())
    end,
  })
  vim.api.nvim_create_user_command("UEQuit", M.quit, { desc = "退出前列出未保存文件并选择处理" })
  vim.api.nvim_create_user_command("UEUnsaved", M.review, { desc = "查看未保存文件" })
end

return M
