-- Compiler/server-authored text edits: preview first, then a guarded buffer batch.
-- Disk files are read only. Recovery snapshots belong to this Neovim process.
local M = {}
local api, uv = vim.api, vim.uv or vim.loop
local input = require("utils.workspace_edit_input")
local canonical, documents = input.canonical, input.documents
local LIMIT = input.limits()

local function same(a, b)
  return vim.deep_equal(a, b)
end
local function present(value)
  return value ~= nil and value ~= vim.NIL
end
local function integer(value)
  return type(value) == "number" and value >= 0 and value % 1 == 0
end
local function copy(value)
  return vim.deepcopy(value)
end
local function stat_key(stat)
  if not stat then
    return nil
  end
  return vim.inspect({ stat.type, stat.size, stat.dev, stat.ino, stat.mode, stat.mtime, stat.ctime, stat.birthtime })
end
M.same_document = input.same_document

-- Byte checks are asynchronous, including the post-read path identity check.
local function read_disk(path, callback)
  uv.fs_stat(path, function(err, first)
    if err or not first then
      vim.schedule(function()
        callback(nil, "target-unavailable: " .. tostring(err))
      end)
      return
    end
    if first.type ~= "file" or first.size > LIMIT.bytes then
      vim.schedule(function()
        callback(nil, "target-not-file-or-too-large")
      end)
      return
    end
    uv.fs_open(path, "r", 0, function(open_err, fd)
      if open_err or not fd then
        vim.schedule(function()
          callback(nil, "target-read-failed: " .. tostring(open_err))
        end)
        return
      end
      uv.fs_read(fd, first.size, 0, function(read_err, bytes)
        uv.fs_close(fd, function(close_err)
          uv.fs_stat(path, function(stat_err, last)
            vim.schedule(function()
              if read_err or close_err or stat_err or not bytes or #bytes ~= first.size then
                callback(nil, "target-read-failed")
              elseif stat_key(first) ~= stat_key(last) then
                callback(nil, "target-changed-during-read")
              else
                callback({
                  bytes = bytes,
                  digest = vim.fn.sha256(bytes),
                  stat = stat_key(last),
                  canonical = canonical(path),
                })
              end
            end)
          end)
        end)
      end)
    end)
  end)
end

local function disk_matches(target, disk)
  return disk
    and disk.digest == target.disk.digest
    and disk.stat == target.disk.stat
    and disk.canonical == target.disk.canonical
end

local function options(buf)
  local bo = vim.bo[buf]
  return {
    fileformat = bo.fileformat,
    endofline = bo.endofline,
    fixeol = bo.fixeol,
    bomb = bo.bomb,
    fileencoding = bo.fileencoding,
    binary = bo.binary,
    modified = bo.modified,
    buflisted = bo.buflisted,
  }
end

local function text_options_equal(a, b)
  for _, key in ipairs({ "fileformat", "endofline", "fixeol", "bomb", "fileencoding", "binary" }) do
    if a[key] ~= b[key] then
      return false
    end
  end
  return true
end

local function snapshot(buf)
  return {
    buf = buf,
    name = api.nvim_buf_get_name(buf),
    tick = api.nvim_buf_get_changedtick(buf),
    lines = api.nvim_buf_get_lines(buf, 0, -1, true),
    options = options(buf),
  }
end

local function loaded_buffer(path)
  local key = canonical(path)
  local direct = vim.fn.bufnr(path)
  if direct >= 0 and api.nvim_buf_is_loaded(direct) and canonical(api.nvim_buf_get_name(direct)) == key then
    return direct
  end
  for _, buf in ipairs(api.nvim_list_bufs()) do
    if
      api.nvim_buf_is_loaded(buf)
      and api.nvim_buf_get_name(buf) ~= ""
      and canonical(api.nvim_buf_get_name(buf)) == key
    then
      return buf
    end
  end
end

local function parse_disk(bytes)
  if bytes:find("\0", 1, true) then
    return nil, "binary-target-unsupported"
  end
  local bomb = bytes:sub(1, 3) == "\239\187\191"
  if bomb then
    bytes = bytes:sub(4)
  end
  local dos = bytes:find("\r\n", 1, true) ~= nil
  local text = bytes:gsub("\r\n", "\n")
  if text:find("\r", 1, true) or (dos and text:find("\n", 1, true) and bytes:find("[^\r]\n")) then
    return nil, "mixed-or-mac-line-endings-unsupported"
  end
  local eol = text:sub(-1) == "\n"
  if eol then
    text = text:sub(1, -2)
  end
  return {
    lines = vim.split(text, "\n", { plain = true }),
    options = {
      fileformat = dos and "dos" or "unix",
      endofline = eol,
      fixeol = true,
      bomb = bomb,
      fileencoding = "utf-8",
      binary = false,
      modified = false,
      buflisted = false,
    },
  }
end

local function position_valid(position, lines, encoding)
  if type(position) ~= "table" or not integer(position.line) or not integer(position.character) then
    return false
  end
  if position.line == #lines then
    return position.character == 0
  end
  local line = lines[position.line + 1]
  if not line then
    return false
  end
  local ok, byte = pcall(vim.str_byteindex, line, encoding, position.character, true)
  if not ok then
    return false
  end
  local back_ok, back = pcall(vim.str_utfindex, line, encoding, byte, true)
  return back_ok and back == position.character
end

local function before_position(a, b)
  return a.line < b.line or (a.line == b.line and a.character < b.character)
end

local function validate_edits(edits, before, encoding, annotations)
  local ordered = {}
  for _, edit in ipairs(edits) do
    if
      type(edit) ~= "table"
      or type(edit.newText) ~= "string"
      or type(edit.range) ~= "table"
      or edit.newText:find("\0", 1, true)
    then
      return false, "invalid-text-edit"
    end
    local first, last = edit.range.start, edit.range["end"]
    if
      not position_valid(first, before.lines, encoding)
      or not position_valid(last, before.lines, encoding)
      or before_position(last, first)
    then
      return false, "invalid-or-stale-edit-range"
    end
    if present(edit.annotationId) and not (annotations and annotations[edit.annotationId]) then
      return false, "change-annotation-missing"
    end
    ordered[#ordered + 1] = edit
  end
  table.sort(ordered, function(a, b)
    return before_position(a.range.start, b.range.start)
  end)
  for i = 2, #ordered do
    if before_position(ordered[i].range.start, ordered[i - 1].range["end"]) then
      return false, "overlapping-text-edits"
    end
  end
  return true
end

local function transformed(before, edits, encoding)
  local scratch = api.nvim_create_buf(false, true)
  local ok, result = pcall(function()
    api.nvim_buf_set_lines(scratch, 0, -1, true, before.lines)
    for _, key in ipairs({ "fileformat", "endofline", "fixeol", "bomb", "fileencoding", "binary" }) do
      vim.bo[scratch][key] = before.options[key]
    end
    vim.lsp.util.apply_text_edits(copy(edits), scratch, encoding)
    return api.nvim_buf_get_lines(scratch, 0, -1, true)
  end)
  pcall(api.nvim_buf_delete, scratch, { force = true })
  return ok and result or nil, ok and nil or tostring(result)
end

local function check_context(batch, phase)
  if not batch.check then
    return true
  end
  local ok, good, reason = pcall(batch.check, phase or "preview")
  return ok and good == true, ok and reason or tostring(good)
end

local function check_buffer(target, state)
  local buf = state.buf or loaded_buffer(target.path)
  if not buf then
    return state.buf == nil, "target-buffer-unloaded"
  end
  if not api.nvim_buf_is_valid(buf) or not api.nvim_buf_is_loaded(buf) then
    return false, "target-buffer-unloaded"
  end
  if state.buf and buf ~= state.buf then
    return false, "target-buffer-replaced"
  end
  if state.name and api.nvim_buf_get_name(buf) ~= state.name then
    return false, "target-renamed"
  end
  if canonical(api.nvim_buf_get_name(buf)) ~= target.disk.canonical then
    return false, "target-renamed"
  end
  if state.tick and api.nvim_buf_get_changedtick(buf) ~= state.tick then
    return false, "target-buffer-changed"
  end
  if
    not same(api.nvim_buf_get_lines(buf, 0, -1, true), state.lines)
    or not text_options_equal(options(buf), state.options)
  then
    return false, "target-buffer-changed"
  end
  if vim.bo[buf].readonly or not vim.bo[buf].modifiable or vim.bo[buf].buftype ~= "" then
    return false, "target-not-editable"
  end
  if vim.bo[buf].modified ~= state.options.modified then
    return false, "target-modified-state-changed"
  end
  if target.version ~= nil and vim.lsp.util.buf_versions[buf] ~= target.version then
    return false, "document-version-stale"
  end
  return true
end

--- Prepare only the returned targets. Cancellation never changes target text.
--- opts.check(phase) guards the frozen server/request context; opts.baseline is
--- the loaded-buffer metadata captured before requesting unversioned edits.
function M.prepare(edit, encoding, opts, callback)
  opts = opts or {}
  local docs, why = documents(edit)
  if not docs or not ({ ["utf-8"] = true, ["utf-16"] = true, ["utf-32"] = true })[encoding] then
    callback(nil, why or "position-encoding-unsupported")
    return
  end
  local batch = {
    state = "preparing",
    targets = {},
    encoding = encoding,
    check = opts.check,
    label = opts.label or "Workspace edit",
    annotations = copy(edit.changeAnnotations),
    evidence = {},
  }
  local index, bytes = 0, 0
  local function next_target()
    if batch.state ~= "preparing" then
      return
    end
    local valid, context_err = check_context(batch)
    if not valid then
      batch.state = "rejected"
      callback(nil, context_err or "request-stale")
      return
    end
    index = index + 1
    local doc = docs[index]
    if not doc then
      batch.state = "preview"
      callback(batch)
      return
    end
    read_disk(doc.path, function(disk, err)
      if batch.state ~= "preparing" then
        return
      end
      local function reject(reason)
        batch.state = "rejected"
        callback(nil, reason)
      end
      if not disk then
        reject(err)
        return
      end
      local buf = loaded_buffer(doc.path)
      local size = buf and api.nvim_buf_get_offset(buf, api.nvim_buf_line_count(buf)) or #disk.bytes
      if size > LIMIT.bytes then
        reject("target-overlay-too-large")
        return
      end
      bytes = bytes + math.max(#disk.bytes, size)
      if bytes > LIMIT.total then
        reject("workspace-text-size-limit")
        return
      end
      local before, parse_err
      if buf then
        before = snapshot(buf)
      else
        before, parse_err = parse_disk(disk.bytes)
      end
      if not before then
        reject(parse_err)
        return
      end
      local old = opts.baseline and opts.baseline[buf]
      if buf and opts.baseline and not old then
        reject("target-loaded-or-recreated-during-request")
        return
      end
      if old and (old.tick ~= before.tick or old.name ~= before.name) then
        reject("target-changed-during-request")
        return
      end
      if before.options.binary or (before.options.fileencoding ~= "" and before.options.fileencoding ~= "utf-8") then
        reject("target-encoding-unsupported")
        return
      end
      if before.options.modified and opts.client and not vim.lsp.buf_is_attached(buf, opts.client.id) then
        reject("dirty-target-not-attached-to-server")
        return
      end
      if doc.version ~= nil and (not buf or vim.lsp.util.buf_versions[buf] ~= doc.version) then
        reject("document-version-stale")
        return
      end
      local edits_ok, edit_err = validate_edits(doc.edits, before, encoding, edit.changeAnnotations)
      if not edits_ok then
        reject(edit_err)
        return
      end
      local after, transform_err = transformed(before, doc.edits, encoding)
      if not after then
        reject(transform_err)
        return
      end
      -- Retain digests, not a second full copy of disk bytes (dirty overlays differ).
      disk.bytes = nil
      batch.targets[#batch.targets + 1] = {
        path = doc.path,
        uri = doc.uri,
        version = doc.version,
        disk = disk,
        before = before,
        after = after,
        edit_count = #doc.edits,
      }
      vim.schedule(next_target)
    end)
  end
  next_target()
  return batch
end

--- Validate every target before the first write, including byte-identical stat changes.
function M.validate(batch, callback, phase)
  local index = 0
  local function next_target()
    local valid, reason = check_context(batch, phase)
    if not valid then
      callback(false, reason or "request-stale")
      return
    end
    index = index + 1
    local target = batch.targets[index]
    if not target then
      callback(true)
      return
    end
    local good, err = check_buffer(target, target.before)
    if not good then
      callback(false, err .. ": " .. target.path)
      return
    end
    read_disk(target.path, function(disk, disk_err)
      if not disk_matches(target, disk) then
        callback(false, disk_err or ("target-disk-changed: " .. target.path))
        return
      end
      local stable, buffer_err = check_buffer(target, target.before)
      if not stable then
        callback(false, buffer_err .. ": " .. target.path)
        return
      end
      next_target()
    end)
  end
  next_target()
end

-- One native minimal-span edit per target gives recovery an observable owned
-- version. Surrounding marks/extmarks survive; there is no whole-file overwrite.
local function span(before, after)
  if same(before, after) then
    return nil
  end
  local first = 1
  while before[first] and after[first] and before[first] == after[first] do
    first = first + 1
  end
  if not before[first] then
    local replacement = { "" }
    for i = first, #after do
      replacement[#replacement + 1] = after[i]
    end
    return #before - 1, #before[#before], #before - 1, #before[#before], replacement
  end
  if not after[first] then
    return #after - 1, #after[#after], #before - 1, #before[#before], { "" }
  end
  local last_old, last_new = #before, #after
  while last_old > first and last_new > first and before[last_old] == after[last_new] do
    last_old, last_new = last_old - 1, last_new - 1
  end
  local prefix, suffix = 0, 0
  local left, right = before[first], after[first]
  while prefix < math.min(#left, #right) and left:byte(prefix + 1) == right:byte(prefix + 1) do
    prefix = prefix + 1
  end
  while prefix > 0 and (left:byte(prefix + 1) or 0) >= 128 and (left:byte(prefix + 1) or 0) < 192 do
    prefix = prefix - 1
  end
  left, right = before[last_old], after[last_new]
  local maximum = math.min(#left - (last_old == first and prefix or 0), #right - (last_new == first and prefix or 0))
  while suffix < maximum and left:byte(#left - suffix) == right:byte(#right - suffix) do
    suffix = suffix + 1
  end
  while suffix > 0 and (left:byte(#left - suffix + 1) or 0) >= 128 and (left:byte(#left - suffix + 1) or 0) < 192 do
    suffix = suffix - 1
  end
  local replacement = {}
  for i = first, last_new do
    replacement[#replacement + 1] =
      after[i]:sub(i == first and prefix + 1 or 1, i == last_new and #after[i] - suffix or #after[i])
  end
  return first - 1, prefix, last_old - 1, #before[last_old] - suffix, replacement
end

local function write_lines(buf, before, after)
  local row, col, end_row, end_col, replacement = span(before, after)
  if row then
    api.nvim_buf_set_text(buf, row, assert(col), assert(end_row), assert(end_col), assert(replacement))
  end
end

local function owned(target)
  local post = target.post
  if not post or post.conflict then
    return false, "no-owned-post-version"
  end
  return check_buffer({ path = target.path, disk = target.disk }, post)
end

local function disk_stat_matches(target)
  return stat_key(uv.fs_stat(target.path)) == target.disk.stat and canonical(target.path) == target.disk.canonical
end

local function change_target(target, lines, modified)
  local buf, observations, detach = target.before.buf, 0, false
  api.nvim_buf_attach(buf, false, {
    on_lines = function()
      observations = observations + 1
      return detach
    end,
    on_detach = function()
      detach = true
    end,
  })
  local ok, err = pcall(write_lines, buf, api.nvim_buf_get_lines(buf, 0, -1, true), lines)
  detach = true -- only detach this observer on its next event, not other subscribers.
  if api.nvim_buf_is_valid(buf) and api.nvim_buf_is_loaded(buf) then
    local current = snapshot(buf)
    if
      not ok
      and observations == 0
      and current.tick == target.before.tick
      and same(current.lines, target.before.lines)
    then
      return false, tostring(err)
    end
    current.conflict = observations > 1 or not same(current.lines, lines)
    target.post = current
    if ok and not current.conflict and observations > 0 then
      vim.bo[buf].modified = modified
      target.post.options.modified = vim.bo[buf].modified
    end
  end
  return ok and target.post and not target.post.conflict, ok and "input-during-apply" or tostring(err)
end

local function recover(batch, failure)
  batch.evidence = { state = "failed", failure = failure, files = {} }
  for _, target in ipairs(batch.targets) do
    local record = { path = target.path, state = "untouched" }
    if target.post then
      local good, reason = owned(target)
      if good and disk_stat_matches(target) then
        local restored, restore_err = change_target(target, target.before.lines, target.before.options.modified)
        record.state = restored and "restored" or "recovery-blocked"
        record.reason = restored and nil or restore_err
      else
        record.state, record.reason = "recovery-blocked", reason or "target-disk-changed"
      end
    end
    batch.evidence.files[#batch.evidence.files + 1] = record
  end
  batch.state = "failed"
end

local function apply_now(batch)
  batch.state = "applying"
  for _, target in ipairs(batch.targets) do
    local valid, reason = check_context(batch, "applying")
    if not valid then
      recover(batch, reason or "request-stale")
      return false
    end
    for _, previous in ipairs(batch.targets) do
      if previous.post and not owned(previous) then
        recover(batch, "input-during-apply: " .. previous.path)
        return false
      end
    end
    local good, err = check_buffer(target, target.before)
    if not good or not disk_stat_matches(target) then
      recover(batch, err or ("target-disk-changed: " .. target.path))
      return false
    end
    local modified = true
    if target.restore_modified ~= nil then
      modified = target.restore_modified
    end
    local changed, change_err = change_target(target, target.after, modified)
    if not changed then
      recover(batch, change_err)
      return false
    end
    if not disk_stat_matches(target) then
      recover(batch, "target-disk-changed-during-apply: " .. target.path)
      return false
    end
  end
  -- A subscriber may mutate a previous buffer during the last native edit.
  for _, target in ipairs(batch.targets) do
    if not owned(target) then
      recover(batch, "input-during-apply: " .. target.path)
      return false
    end
  end
  batch.state, batch.evidence = "applied", { state = "applied", files = {} }
  for _, target in ipairs(batch.targets) do
    batch.evidence.files[#batch.evidence.files + 1] = { path = target.path, state = "applied", tick = target.post.tick }
  end
  return true
end

function M.cancel(batch)
  if not batch or (batch.state ~= "preview" and batch.state ~= "preparing" and batch.state ~= "validating") then
    return false
  end
  batch.state = "cancelled"
  return true
end

function M.apply(batch, callback)
  callback = callback or function() end
  if not batch or batch.state ~= "preview" then
    callback(false, "batch-not-in-preview")
    return false
  end
  batch.state = "validating"
  -- Loading is explicit and asynchronous between targets; never read target
  -- files or launch LSP clients merely to show their preview.
  local index = 0
  local function load_next()
    if batch.state ~= "validating" then
      callback(false, "batch-cancelled")
      return
    end
    index = index + 1
    local target = batch.targets[index]
    if not target then
      M.validate(batch, function(valid, reason)
        if batch.state ~= "validating" then
          callback(false, "batch-cancelled")
          return
        end
        if not valid then
          batch.state = "rejected"
          callback(false, reason)
          return
        end
        local applied = apply_now(batch)
        callback(applied, applied and nil or batch.evidence.failure, batch.evidence)
      end)
      return
    end
    local good, reason = check_buffer(target, target.before)
    if not good then
      batch.state = "rejected"
      callback(false, reason)
      return
    end
    if not target.before.buf then
      local called, buf = pcall(function()
        local id = vim.uri_to_bufnr(target.uri)
        vim.fn.bufload(id)
        return id
      end)
      if not called or not api.nvim_buf_is_loaded(buf) then
        batch.state = "rejected"
        callback(false, "target-load-failed: " .. target.path)
        return
      end
      local state = snapshot(buf)
      -- UTF-8 fileencoding may be empty after native loading; both mean UTF-8.
      if state.options.fileencoding == "" then
        target.before.options.fileencoding = ""
      end
      if
        not same(state.lines, target.before.lines)
        or not text_options_equal(state.options, target.before.options)
        or state.options.modified
      then
        batch.state = "rejected"
        callback(false, "target-changed-while-loading: " .. target.path)
        return
      end
      target.before = state
    end
    vim.schedule(load_next)
  end
  M.validate(batch, function(valid, reason)
    if batch.state ~= "validating" then
      callback(false, "batch-cancelled")
      return
    end
    if not valid then
      batch.state = "rejected"
      callback(false, reason)
      return
    end
    load_next()
  end)
  return true
end

--- Undo only this batch, all-or-nothing preflight; newer input/disk is retained.
function M.undo(batch, callback)
  callback = callback or function() end
  if not batch or batch.state ~= "applied" then
    callback(false, "no-applied-batch")
    return false
  end
  local reverse = { state = "preview", targets = {}, label = "Undo " .. batch.label, evidence = {} }
  local function rejected(reason)
    batch.undo_evidence = { operation = "undo", state = "rejected", failure = reason, files = {} }
    for _, target in ipairs(batch.targets) do
      batch.undo_evidence.files[#batch.undo_evidence.files + 1] = { path = target.path, state = "untouched" }
    end
    callback(false, reason, batch.undo_evidence)
  end
  for _, target in ipairs(batch.targets) do
    local good, reason = owned(target)
    if not good then
      rejected("undo-refused: " .. tostring(reason) .. ": " .. target.path)
      return false
    end
    reverse.targets[#reverse.targets + 1] = {
      path = target.path,
      uri = target.uri,
      disk = copy(target.disk),
      before = copy(target.post),
      after = copy(target.before.lines),
      restore_modified = target.before.options.modified,
    }
  end
  batch.state = "undo-validating"
  M.apply(reverse, function(ok, reason, evidence)
    batch.undo_evidence = copy(evidence or { state = "rejected", failure = reason, files = {} })
    batch.undo_evidence.operation = "undo"
    if ok then
      batch.state = "undone"
      batch.undo_evidence.state = "undone"
      for _, item in ipairs(batch.undo_evidence.files) do
        item.state = "undone"
      end
    else
      batch.state = evidence and evidence.state == "failed" and "undo-failed" or "applied"
    end
    callback(ok, reason, batch.undo_evidence)
  end)
  return true
end

function M.report(batch)
  return batch and copy(batch.undo_evidence or batch.evidence) or nil
end

return M
