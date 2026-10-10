-- Unsaved-text recovery: each process/session owns independent atomic files.
-- Restoration always creates a new unnamed buffer; it never overwrites a source.
local M = {}
local uv = vim.uv
local options, session, records, attached, queued = nil, nil, {}, {}, {}
local owned_directories = {}
local generation = 0
local FILEFORMATS = { unix = true, dos = true, mac = true }
M.REVISION = "ide-edit-recovery-2026-10-03"

local function probe(key, data)
  pcall(function()
    require("utils.probe").record("edit-recovery", key, data)
  end)
end

local function config()
  return options or require("ue.config").get("edit_recovery")
end

local function root()
  return config().root or vim.env.NVIM_EDIT_RECOVERY_ROOT or (vim.fn.stdpath("state") .. "/edit-recovery")
end

local function project()
  local ue = package.loaded.ue
  local ok, ctx = pcall(function()
    return ue and ue.resolve_context and ue.resolve_context()
  end)
  local path = ok and ctx and ctx.project_root or vim.fn.getcwd()
  return vim.fs.normalize(uv.fs_realpath(path) or path)
end

local function scheduled(done, ...)
  local args = { ... }
  local count = select("#", ...)
  vim.schedule(function()
    done(unpack(args, 1, count))
  end)
end

local function mkdir(path, done)
  uv.fs_stat(path, function(err, stat)
    if stat and stat.type == "directory" then
      return done(nil)
    end
    local parent = vim.fs.dirname(path)
    if not parent or parent == path then
      return done(err or "invalid recovery directory")
    end
    mkdir(parent, function(parent_err)
      if parent_err then
        return done(parent_err)
      end
      uv.fs_mkdir(path, 448, function(create_err)
        if not create_err or tostring(create_err):find("EEXIST", 1, true) then
          done(nil)
        else
          done(create_err)
        end
      end)
    end)
  end)
end

local function atomic_write(path, text, done)
  local temp = path .. ".tmp." .. tostring(uv.hrtime())
  mkdir(vim.fs.dirname(path), function(dir_err)
    if dir_err then
      return scheduled(done, false, tostring(dir_err))
    end
    uv.fs_open(temp, "w", 384, function(open_err, fd)
      if open_err then
        return scheduled(done, false, tostring(open_err))
      end
      local function finish(err)
        uv.fs_close(fd, function(close_err)
          err = err or close_err
          if err then
            uv.fs_unlink(temp, function()
              scheduled(done, false, tostring(err))
            end)
          else
            uv.fs_rename(temp, path, function(rename_err)
              if rename_err then
                uv.fs_unlink(temp, function()
                  scheduled(done, false, tostring(rename_err))
                end)
              else
                scheduled(done, true, path)
              end
            end)
          end
        end)
      end
      local offset = 0
      local function write()
        uv.fs_write(fd, text:sub(offset + 1), offset, function(err, count)
          if err or not count or count == 0 then
            return finish(err or "short recovery write")
          end
          offset = offset + count
          if offset < #text then
            return write()
          end
          uv.fs_fsync(fd, finish)
        end)
      end
      write()
    end)
  end)
end

local function validate(value)
  if
    type(value) ~= "table"
    or value.version ~= 1
    or type(value.lines) ~= "table"
    or type(value.name) ~= "string"
    or type(value.pid) ~= "number"
    or type(value.session) ~= "string"
    or type(value.project) ~= "string"
    or #value.lines == 0
  then
    return nil, "invalid recovery snapshot"
  end
  if
    value.pid <= 0
    or value.pid > 2147483647
    or value.pid % 1 ~= 0
    or type(value.at) ~= "number"
    or value.at <= 0
    or value.at % 1 ~= 0
  then
    return nil, "invalid recovery owner/timestamp"
  end
  local prefix = tostring(value.pid) .. "-"
  local epoch = value.session:sub(1, #prefix) == prefix and tonumber(value.session:sub(#prefix + 1))
  if not value.session:match("^%d+%-[%d.eE+%-]+$") or not epoch or epoch <= 0 or epoch >= math.huge then
    return nil, "invalid recovery session owner"
  end
  if not FILEFORMATS[value.fileformat] then
    return nil, "invalid recovery fileformat"
  end
  if
    type(value.filetype) ~= "string"
    or type(value.fileencoding) ~= "string"
    or value.filetype:find("[\r\n]")
    or value.fileencoding:find("[\r\n]")
    or type(value.bomb) ~= "boolean"
    or type(value.endofline) ~= "boolean"
  then
    return nil, "invalid recovery options"
  end
  local count = 0
  for key in pairs(value.lines) do
    if type(key) ~= "number" or key < 1 or key > #value.lines or key % 1 ~= 0 then
      return nil, "invalid recovery lines"
    end
    count = count + 1
  end
  if count ~= #value.lines then
    return nil, "invalid recovery lines"
  end
  for _, line in ipairs(value.lines) do
    if type(line) ~= "string" or line:find("\n", 1, true) then
      return nil, "invalid recovery lines"
    end
  end
  return value
end

local function decode(raw, path)
  local ok, value = pcall(vim.json.decode, raw or "")
  if not ok then
    return nil, "invalid recovery snapshot"
  end
  local valid, err = validate(value)
  if not valid then
    return nil, err
  end
  local directory = vim.fs.dirname(path)
  if
    vim.fs.basename(directory) ~= value.session
    or vim.fs.basename(vim.fs.dirname(directory)) ~= vim.fn.sha256(value.project):sub(1, 24)
  then
    return nil, "recovery snapshot does not match its owner directory"
  end
  value.path = path
  return value
end

local function read_async(path, done)
  uv.fs_stat(path, function(err, stat)
    if err or not stat or stat.type ~= "file" or stat.size > config().max_bytes then
      return scheduled(done, nil, tostring(err or "snapshot exceeds recovery limit"))
    end
    uv.fs_open(path, "r", 384, function(open_err, fd)
      if open_err then
        return scheduled(done, nil, tostring(open_err))
      end
      uv.fs_read(fd, stat.size, 0, function(read_err, raw)
        uv.fs_close(fd, function()
          if read_err then
            return scheduled(done, nil, tostring(read_err))
          end
          vim.schedule(function()
            done(decode(raw, path))
          end)
        end)
      end)
    end)
  end)
end

function M.capture(buf, done)
  done = done or function() end
  if not session then
    M.setup()
  end
  if not config().enabled then
    done(false, "recovery-disabled")
    return false
  end
  if not vim.api.nvim_buf_is_loaded(buf) or vim.bo[buf].buftype ~= "" or vim.bo[buf].binary then
    done(false, "unsupported-buffer")
    return false
  end
  if not vim.bo[buf].modified then
    M.clear(buf, done)
    return false
  end
  local size = vim.api.nvim_buf_get_offset(buf, vim.api.nvim_buf_line_count(buf))
  if size > config().max_bytes then
    done(false, "snapshot exceeds recovery limit")
    return false
  end
  local record = records[buf]
  if not record then
    if vim.tbl_count(records) >= config().max_buffers then
      done(false, "recovery buffer limit")
      return false
    end
    local scope = project()
    record =
      { project = scope, path = vim.fs.joinpath(root(), vim.fn.sha256(scope):sub(1, 24), session, buf .. ".json") }
    records[buf] = record
    owned_directories[vim.fs.dirname(record.path)] = true
  end
  if record.writing or record.clearing then
    record.again = true
    done(false, "write-in-flight")
    return false
  end
  local value = {
    version = 1,
    pid = vim.fn.getpid(),
    session = session,
    project = record.project,
    name = vim.api.nvim_buf_get_name(buf),
    lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false),
    filetype = vim.bo[buf].filetype,
    fileformat = vim.bo[buf].fileformat,
    fileencoding = vim.bo[buf].fileencoding,
    bomb = vim.bo[buf].bomb,
    endofline = vim.bo[buf].endofline,
    tick = vim.api.nvim_buf_get_changedtick(buf),
    at = os.time(),
  }
  if record.snapshot then
    value.at = record.snapshot.at
    if vim.deep_equal(value, record.snapshot) then
      done(true, record.path)
      return false
    end
    value.at = os.time()
  end
  local raw = vim.json.encode(value)
  if #raw > config().max_bytes then
    done(false, "snapshot exceeds recovery limit")
    return false
  end
  record.writing = true
  local owner_generation = generation
  atomic_write(record.path, raw, function(ok, path_or_err)
    record.writing = nil
    if owner_generation ~= generation then
      return done(false, "session-changed")
    end
    if ok then
      record.tick, record.snapshot = value.tick, value
    end
    if not ok then
      probe("write-failed", { state = "failed", reason = tostring(path_or_err):sub(1, 160) })
    end
    done(ok, path_or_err)
    if record.again then
      record.again = nil
      M.capture(buf)
    elseif ok and vim.api.nvim_buf_is_valid(buf) and not vim.bo[buf].modified then
      M.clear(buf)
    end
  end)
  return true
end

function M.clear(buf, done)
  done = done or function() end
  local record = records[buf]
  if not record then
    done(true)
    return
  end
  if record.writing or record.clearing then
    record.again = true
    done(false, "write-in-flight")
    return
  end
  record.clearing = true
  uv.fs_unlink(record.path, function(err)
    vim.schedule(function()
      record.clearing = nil
      local ok = not err or tostring(err):find("ENOENT", 1, true) ~= nil
      if ok and records[buf] == record then
        records[buf] = nil
      end
      done(ok, err and tostring(err) or nil)
      if record.again then
        M.capture(buf)
      end
    end)
  end)
end

local function queue(buf)
  if queued[buf] then
    return
  end
  local owner_generation = generation
  queued[buf] = true
  vim.defer_fn(function()
    if owner_generation ~= generation then
      return
    end
    queued[buf] = nil
    M.capture(buf, function(ok, reason)
      if not ok and reason ~= "unsupported-buffer" and reason ~= "write-in-flight" then
        vim.g.ue_recovery_status = "恢复缓存未更新: " .. tostring(reason)
      elseif ok then
        vim.g.ue_recovery_status = nil
      end
    end)
  end, config().delay_ms)
end

local function track(buf)
  if attached[buf] or not vim.api.nvim_buf_is_loaded(buf) or vim.bo[buf].buftype ~= "" then
    return
  end
  attached[buf] = vim.api.nvim_buf_attach(buf, false, {
    on_lines = function()
      vim.schedule(function()
        queue(buf)
      end)
    end,
    on_detach = function()
      attached[buf] = nil
    end,
  }) or nil
  if vim.bo[buf].modified then
    queue(buf)
  end
end

-- Scan only this small local recovery store, not the project or file tree.
-- Each record is read asynchronously, one decode per event-loop turn.
function M.list(done, opts)
  opts = opts or {}
  done = done or function() end
  local paths, result = {}, {}
  local selected = project()
  local metadata = { truncated = false }
  local function visit(path, depth, finish)
    uv.fs_scandir(path, function(_, request)
      if not request then
        return scheduled(finish)
      end
      local entries = {}
      while #entries < 256 do
        local name, kind = uv.fs_scandir_next(request)
        if not name then
          break
        end
        entries[#entries + 1] = { name, kind }
      end
      if #entries == 256 and uv.fs_scandir_next(request) then
        metadata.truncated = true
      end
      local index = 0
      local function next_entry()
        index = index + 1
        local entry = entries[index]
        if not entry then
          return finish()
        end
        if #paths >= 128 then
          metadata.truncated = true
          return finish()
        end
        local name, kind = entry[1], entry[2]
        local child = vim.fs.joinpath(path, name)
        if kind == "directory" and depth < 2 then
          if depth == 1 and not opts.include_live then
            -- Exclude normal/live cohorts before they consume the read budget.
            local pid = tonumber(name:match("^(%d+)%-"))
            local alive = pid and pid > 0 and pid <= 2147483647 and uv.kill(pid, 0)
            if alive then
              return next_entry()
            end
            uv.fs_stat(vim.fs.joinpath(child, "closed"), function(_, closed)
              if closed then
                next_entry()
              else
                visit(child, depth + 1, next_entry)
              end
            end)
          else
            visit(child, depth + 1, next_entry)
          end
        elseif kind == "file" and depth == 2 and name:match("^%d+%.json$") then
          paths[#paths + 1] = child
          next_entry()
        else
          next_entry()
        end
      end
      -- A bounded async directory metadata pass favors recent crash sessions;
      -- retention instead favors oldest cohorts. No project tree is inspected.
      local stat_index = 0
      local function order_entries()
        stat_index = stat_index + 1
        local entry = entries[stat_index]
        if not entry then
          table.sort(entries, function(a, b)
            local left, right = a[3] or 0, b[3] or 0
            if left == right then
              return a[1] < b[1]
            end
            return opts.oldest_first and left < right or (not opts.oldest_first and left > right)
          end)
          return next_entry()
        end
        if entry[2] ~= "directory" then
          return order_entries()
        end
        uv.fs_stat(vim.fs.joinpath(path, entry[1]), function(_, stat)
          entry[3] = stat and stat.mtime and (stat.mtime.sec + stat.mtime.nsec / 1e9) or 0
          order_entries()
        end)
      end
      order_entries()
    end)
  end
  local scan_root = opts.all and root() or vim.fs.joinpath(root(), vim.fn.sha256(selected):sub(1, 24))
  visit(scan_root, opts.all and 0 or 1, function()
    local index = 0
    local function next_record()
      index = index + 1
      local path = paths[index]
      if not path then
        table.sort(result, function(a, b)
          return (a.at or 0) > (b.at or 0)
        end)
        return done(result, nil, metadata)
      end
      read_async(path, function(record)
        if record and (opts.all or record.project == selected) then
          uv.fs_stat(vim.fs.joinpath(vim.fs.dirname(path), "closed"), function(_, closed)
            local alive, alive_err = uv.kill(record.pid, 0)
            local dead = not alive and tostring(alive_err):find("ESRCH", 1, true) ~= nil
            record.owner_state = alive and "active" or (dead and "dead" or "unknown")
            record.closed = closed ~= nil
            if opts.include_live or (dead and not closed) then
              result[#result + 1] = record
            end
            next_record()
          end)
        else
          next_record()
        end
      end)
    end
    scheduled(next_record)
  end)
end

-- Retention removes only expired records with a proven dead process owner.
-- Permission failures/unknown owners never count as death; no recursive delete.
function M.prune(done)
  done = done or function() end
  local days = tonumber(config().retention_days)
  if not days or days <= 0 then
    done(0)
    return
  end
  M.list(function(items)
    local expired = {}
    local cutoff = os.time() - days * 86400
    for _, item in ipairs(items) do
      if
        item.owner_state == "dead"
        and item.at < cutoff
        and vim.fs.basename(vim.fs.dirname(item.path)) == item.session
      then
        expired[#expired + 1] = item.path
      end
    end
    local index, count = 0, 0
    local function next_file()
      index = index + 1
      if not expired[index] then
        return scheduled(done, count)
      end
      uv.fs_unlink(expired[index], function(err)
        if not err then
          count = count + 1
        end
        next_file()
      end)
    end
    next_file()
  end, { all = true, include_live = true, oldest_first = true })
end

function M.restore(value)
  if type(value) == "string" then
    local stat = uv.fs_stat(value)
    if not stat or stat.size > config().max_bytes then
      return nil, "invalid recovery snapshot size"
    end
    local file = io.open(value, "rb")
    if not file then
      return nil, "snapshot cannot be read"
    end
    local raw = file:read(config().max_bytes + 1)
    file:close()
    value = decode(raw, value)
  end
  local valid, err = validate(value)
  if not valid then
    return nil, err
  end
  local buf = vim.api.nvim_create_buf(true, false)
  local ok, apply_err = pcall(function()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, value.lines)
    for _, key in ipairs({ "filetype", "fileformat", "fileencoding", "bomb", "endofline" }) do
      vim.bo[buf][key] = value[key]
    end
  end)
  if not ok then
    vim.api.nvim_buf_delete(buf, { force = true })
    return nil, tostring(apply_err)
  end
  vim.bo[buf].modified = true
  vim.b[buf].ue_recovery_source = value.name
  vim.b[buf].ue_recovery_snapshot = value.path
  vim.api.nvim_set_current_buf(buf)
  probe("restored", { state = "ok", lines = #value.lines })
  return buf
end

function M.open(all)
  M.list(function(items, _, metadata)
    if metadata and metadata.truncated then
      vim.notify("恢复列表达到扫描上限，部分历史记录未显示；快照保留", vim.log.levels.WARN)
    end
    if #items == 0 then
      vim.notify(
        metadata and metadata.truncated and "已扫描范围内没有可恢复快照"
          or "没有可恢复的异常退出快照",
        vim.log.levels.INFO
      )
      return
    end
    vim.ui.select(items, {
      prompt = "恢复未保存文本到新的缓冲区（原文件保留）：",
      format_item = function(item)
        return (item.name ~= "" and item.name or "[未命名]") .. " · " .. os.date("%m-%d %H:%M", item.at)
      end,
    }, function(item)
      if item then
        M.restore(item)
      end
    end)
  end, { all = all })
end

function M.setup(opts)
  local next_options = vim.tbl_extend("force", {}, require("ue.config").get("edit_recovery"), opts or {})
  if session and vim.deep_equal(options, next_options) then
    if options.enabled then
      for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        track(buf)
        if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].modified then
          queue(buf)
        end
      end
    end
    return
  end
  generation = generation + 1
  options = next_options
  records, queued = {}, {}
  session = vim.fn.getpid() .. "-" .. tostring(uv.hrtime())
  local group = vim.api.nvim_create_augroup("UEEditRecovery", { clear = true })
  if not options.enabled then
    return
  end
  pcall(function()
    require("utils.probe").observe("edit-recovery", M.REVISION, { days = 7 })
  end)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    track(buf)
    if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].modified then
      queue(buf)
    end
  end
  vim.api.nvim_create_autocmd({ "BufReadPost", "BufNewFile", "BufEnter" }, {
    group = group,
    callback = function(event)
      track(event.buf)
    end,
  })
  vim.api.nvim_create_autocmd({ "BufModifiedSet", "BufWritePost" }, {
    group = group,
    callback = function(event)
      queue(event.buf)
    end,
  })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
      for directory in pairs(owned_directories) do
        local file = io.open(vim.fs.joinpath(directory, "closed"), "wb")
        if file then
          file:write("normal exit\n")
          file:close()
        end
      end
    end,
  })
  local function startup_summary()
    local owner_generation = generation
    M.prune(function()
      M.list(function(items, _, metadata)
        if owner_generation ~= generation then
          return
        end
        vim.g.ue_recovery_available = #items > 0 and ("可恢复文本:" .. #items) or ""
        if metadata and metadata.truncated then
          vim.g.ue_recovery_available = vim.g.ue_recovery_available .. "（扫描受限）"
        end
        vim.cmd("redrawstatus")
      end)
    end)
  end
  if vim.v.vim_did_enter == 1 then
    vim.schedule(startup_summary)
  else
    vim.api.nvim_create_autocmd("VimEnter", { group = group, once = true, callback = startup_summary })
  end
end

function M.setup_commands()
  M.setup()
  vim.api.nvim_create_user_command("UERecovery", function(cmd)
    M.open(cmd.args == "all")
  end, {
    nargs = "?",
    complete = function()
      return { "all" }
    end,
    desc = "Recover bounded unsaved snapshots after an abnormal exit into new buffers",
  })
end

return M
