-- Bounded session inspection and on-demand restoration. Lazy mode consumes only
-- native badd/edit metadata, never arbitrary commands from the saved session.
local M = {}

local function filename(text)
  local line, path = text:match("^%+(%d+)%s+(.+)$")
  path = path or text
  path = path:gsub("\\([\\ %[%]{}#|%%!<>+?*$`])", "%1")
  return path, tonumber(line) or 1
end

function M.inspect(path)
  local stat = path and vim.uv.fs_stat(path)
  if not stat or stat.type ~= "file" then
    return nil, "没有已保存的会话"
  end
  if stat.size > 1024 * 1024 then
    return nil, "会话超过 1 MiB，请先检查文件"
  end
  local info = { path = path, files = {}, tabs = 1 }
  local seen = {}
  local base = vim.fn.getcwd()
  for _, line in ipairs(vim.fn.readfile(path)) do
    if
      line:sub(1, 4) == "badd"
      or line:sub(1, 5) == "edit "
      or line:sub(1, 6) == "tabnew"
      or line:sub(1, 7) == "tabedit"
      or line:sub(1, 3) == "cd "
      or line:sub(1, 4) == "lcd "
    then
      local ok, parsed = pcall(vim.api.nvim_parse_cmd, line, {})
      if ok and parsed.nextcmd == "" then
        if (parsed.cmd == "cd" or parsed.cmd == "lcd") and parsed.args[1] then
          local directory = filename(parsed.args[1])
          base = (directory:sub(1, 1) == "/" or directory:match("^%a:[/\\]") or directory:sub(1, 2) == "\\\\")
              and directory
            or vim.fs.joinpath(base, directory)
        end
        if parsed.cmd == "tabnew" or parsed.cmd == "tabedit" then
          info.tabs = info.tabs + 1
        end
        if parsed.cmd == "badd" or parsed.cmd == "edit" then
          local raw = parsed.args[1]
          if raw and raw ~= "" then
            local name, cursor = filename(raw)
            if not (name:sub(1, 1) == "/" or name:match("^%a:[/\\]") or name:sub(1, 2) == "\\\\") then
              name = vim.fs.joinpath(base, name)
            end
            if not name:find("\r", 1, true) and not name:find("\n", 1, true) and not name:find("\0", 1, true) then
              if not seen[name] then
                if #info.files >= 256 then
                  return nil, "会话超过 256 个文件；请检查后显式选择完整恢复"
                end
                local item = { path = name, line = cursor }
                info.files[#info.files + 1], seen[name] = item, item
              end
              if parsed.cmd == "edit" and not info.active then
                info.active = seen[name]
              end
            end
          end
        end
      end
    end
  end
  -- Preserve the old guard: at most 24 badd entries and one extra tab.
  info.heavy = #info.files > 24 or info.tabs > 2
  info.reason = ("%d 个文件、%d 个标签页；可按需恢复，完整恢复可能启动更多解析"):format(
    #info.files,
    info.tabs
  )
  info.active = info.active or info.files[1]
  return info
end

function M.restore_lazy(path)
  if #require("utils.unsaved").list() > 0 then
    vim.notify("当前有未保存文件，请先保存或查看，再恢复会话", vim.log.levels.WARN)
    return false, "unsaved-work"
  end
  local info, err = M.inspect(path)
  if not info or not info.active then
    vim.notify(err or "会话没有可恢复的文件", vim.log.levels.WARN)
    return false, err or "no-files"
  end
  local buffers = {}
  for _, item in ipairs(info.files) do
    buffers[item.path] = vim.fn.bufadd(item.path)
  end
  -- Only the active source is loaded. Other names remain unopened buffers.
  local buf = buffers[info.active.path]
  local ok, load_err = pcall(vim.api.nvim_set_current_buf, buf)
  if not ok then
    return false, load_err
  end
  local line = math.min(info.active.line, vim.api.nvim_buf_line_count(buf))
  vim.api.nvim_win_set_cursor(0, { math.max(1, line), 0 })
  vim.g.ue_session_restore_hint = nil
  vim.notify(("已恢复当前文件；其余 %d 个文件按需打开"):format(#info.files - 1), vim.log.levels.INFO)
  return true
end

function M.current_path()
  local ok, persistence = pcall(require, "persistence")
  if not ok then
    return nil, "会话插件未就绪"
  end
  for _, path in ipairs({ persistence.current(), persistence.current({ branch = false }) }) do
    if path and vim.fn.filereadable(path) == 1 then
      return path, persistence
    end
  end
  return nil, "当前工程没有已保存的会话"
end

function M.open(kind)
  local path, persistence = M.current_path()
  if not path then
    vim.notify(persistence, vim.log.levels.INFO)
    return false
  end
  local info, err
  if kind == "full" then
    info = { path = path }
  else
    info, err = M.inspect(path)
  end
  if not info then
    vim.notify(err, vim.log.levels.WARN)
    return false
  end
  local function restore(selected)
    if selected == "lazy" then
      return M.restore_lazy(path)
    end
    if selected ~= "full" then
      return false
    end
    if #require("utils.unsaved").list() > 0 then
      vim.notify("当前有未保存文件，请先处理，再完整恢复会话", vim.log.levels.WARN)
      return false
    end
    if type(persistence.fire) == "function" then
      persistence.fire("LoadPre")
    end
    local ok, source_err = pcall(vim.cmd, "source " .. vim.fn.fnameescape(path))
    if type(persistence.fire) == "function" then
      persistence.fire("LoadPost")
    end
    if not ok then
      vim.notify(tostring(source_err), vim.log.levels.ERROR)
    end
    return ok
  end
  if kind == "lazy" or kind == "full" then
    return restore(kind)
  end
  vim.ui.select({ "恢复当前文件，其余按需打开", "完整恢复原会话", "取消" }, {
    prompt = info.reason,
  }, function(choice)
    if choice == "恢复当前文件，其余按需打开" then
      restore("lazy")
    elseif choice == "完整恢复原会话" then
      restore("full")
    end
  end)
end

function M.setup_commands()
  vim.api.nvim_create_user_command("UESessionRestore", function(cmd)
    M.open(cmd.args)
  end, {
    nargs = "?",
    complete = function()
      return { "lazy", "full" }
    end,
    desc = "Restore the current project session lazily or explicitly in full",
  })
end

return M
