-- symbolInfo describes the queried AST, not the background index. Prove a
-- cross-TU destination in its own exact-command AST before accepting a jump.
local M = {}
local location = require("utils.ue_goto.location")
local transaction = require("utils.ue_goto.semantic_transaction")

function M.verify(target, usr, client_ids, callback, opts)
  opts = opts or {}
  local path = location.location_path(target)
  local ext = path:lower():match("%.([^./\\]+)$")
  if not ({ c = true, cc = true, cpp = true, cxx = true, m = true, mm = true })[ext] then
    callback({ reason = "definition-not-found" })
    return
  end
  if opts.is_current and not opts.is_current() then
    callback({ reason = "provider-cancelled" })
    return
  end
  local existing = vim.fn.bufnr(path)
  local bufnr = existing >= 0 and existing or vim.fn.bufadd(path)
  local created = existing < 0
  local function cleanup()
    if
      created
      and vim.api.nvim_buf_is_valid(bufnr)
      and not vim.bo[bufnr].modified
      and #vim.fn.win_findbuf(bufnr) == 0
    then
      pcall(vim.api.nvim_buf_delete, bufnr, { force = false })
    end
  end
  local finished = false
  local function finish(result)
    if finished then
      return
    end
    finished = true
    local ok, err = pcall(callback, result)
    cleanup()
    if not ok then
      error(err)
    end
  end
  local ok = pcall(vim.fn.bufload, bufnr)
  if not ok or not vim.api.nvim_buf_is_loaded(bufnr) then
    finish({ reason = "definition-not-found" })
    return
  end
  local tick = vim.api.nvim_buf_get_changedtick(bufnr)
  local function current()
    return not finished
      and (not opts.is_current or opts.is_current())
      and vim.api.nvim_buf_is_valid(bufnr)
      and vim.api.nvim_buf_get_changedtick(bufnr) == tick
      and location.normalize_path(vim.api.nvim_buf_get_name(bufnr)):lower() == location.normalize_path(path):lower()
  end
  local position = (target.targetSelectionRange or target.targetRange or target.range).start
  local line = vim.api.nvim_buf_get_lines(bufnr, position.line, position.line + 1, false)[1]
  if not line then
    finish({ reason = "definition-not-found" })
    return
  end
  local byte = vim.str_byteindex(line, target._position_encoding or "utf-16", position.character, false)
  local tx = transaction.create({
    bufnr = bufnr,
    snapshot = {
      bufnr = bufnr,
      cursor = { position.line + 1, byte },
      changedtick = tick,
      document_version = vim.lsp.util.buf_versions[bufnr] or tick,
    },
  })
  -- Loading a hidden target must not select another provider. Attaching only
  -- the source's verified clients gives didOpen/unsaved text to the same AST owner.
  for _, id in ipairs(client_ids or {}) do
    local client = vim.lsp.get_client_by_id(id)
    if client and not vim.lsp.buf_is_attached(bufnr, id) then
      vim.lsp.buf_attach_client(bufnr, id)
    end
  end
  require("utils.ue_goto.clangd_adapter").async_clangd_symbol_info(bufnr, function(result)
    if not current() then
      finish({ reason = "provider-cancelled" })
      return
    end
    if result.reason ~= "ok" then
      finish(result)
      return
    end
    if result.usr ~= usr then
      result.reason = "identity-conflict"
      finish(result)
      return
    end
    local verified = false
    for _, definition in ipairs(result.definitions or {}) do
      if transaction.same_subject_location(tx, definition) then
        verified = true
      end
    end
    result.reason = verified and "ok" or "definition-not-found"
    finish(result)
  end, {
    snapshot = tx,
    structured = true,
    client_ids = client_ids,
    compile_command_source = path,
    is_current = current,
    register_cancel = opts.register_cancel,
  })
end

return M
