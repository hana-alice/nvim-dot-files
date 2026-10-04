-- Current-document outline with the native Snacks symbol tree and an explicit
-- reading owner. No workspace-symbol routing, parser fallback or LSP handlers.
local M = {}
local ownership = require("utils.ue_goto.reading_owner")
local results = require("utils.ue_goto.reading_results")

function M.open(opts)
  if not require("workarounds.snacks.document_symbols_owner").apply() then
    return nil
  end
  opts = vim.deepcopy(opts or {})
  local owner = ownership.begin()
  local stat = vim.uv.fs_stat(owner.path)
  local file_signature = stat and { size = stat.size, sec = stat.mtime.sec, nsec = stat.mtime.nsec } or nil
  local path_key = require("utils.platform").driver().path_key
  local source_key = path_key(vim.uv.fs_realpath(owner.path) or owner.path)
  local file_keys = { [owner.path] = source_key }
  local previous_transform, previous_close = opts.transform, opts.on_close
  opts.auto_confirm = false
  -- Snacks deep-copies options. Keep the original owner identity in a
  -- closure rather than copying its mutable lifecycle into picker config.
  opts.ue_document_owner = function()
    return owner
  end
  opts.transform = function(row, ctx)
    if previous_transform then
      local transformed = previous_transform(row, ctx)
      if transformed == false then
        return false
      end
      if type(transformed) == "table" then
        row = transformed
      end
    end
    local loc = row.loc
    if not loc or not row.file then
      return false
    end
    if not file_keys[row.file] then
      file_keys[row.file] = path_key(vim.uv.fs_realpath(row.file) or row.file)
    end
    if file_keys[row.file] ~= source_key then
      return false
    end
    row.location = { uri = loc.uri, range = vim.deepcopy(loc.range), _position_encoding = loc.encoding }
    row.loc = vim.deepcopy(loc)
    row.buf, row.target_path, row.target_tick = owner.buf, owner.path, owner.tick
    row.target_signature = file_signature and vim.deepcopy(file_signature) or nil
    return row
  end
  opts.confirm = function(picker, row, action)
    return results.jump(owner, row or picker:current(), action and action.cmd)
  end
  opts.on_close = function(picker)
    ownership.picker_closed(owner, picker)
    if previous_close then
      previous_close(picker)
    end
  end
  opts.actions = vim.tbl_extend("force", opts.actions or {}, {
    jump = opts.confirm,
    edit = opts.confirm,
    pin_sidebar_qflist = function(picker)
      return results.pin(
        owner,
        picker:selected({ fallback = true }),
        { title = picker.title or "Document symbols", source = "LSP" }
      )
    end,
    copy_position = function(picker, row)
      return results.copy(owner, picker, row, "position")
    end,
    copy_absolute_path = function(picker, row)
      return results.copy(owner, picker, row, "absolute")
    end,
    copy_relative_path = function(picker, row)
      return results.copy(owner, picker, row, "relative")
    end,
  })
  opts.jump = vim.tbl_extend("force", opts.jump or {}, { match = false })
  return ownership.present(owner, function()
    return require("snacks").picker.lsp_symbols(opts)
  end)
end

return M
