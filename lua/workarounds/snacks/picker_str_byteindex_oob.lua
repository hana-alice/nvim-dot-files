-- WORKAROUND
-- name: snacks.picker_str_byteindex_oob
-- scope: snacks
-- issue: internal: snacks/picker/util/init.lua:402 calls vim.str_byteindex
--        without strict_indexing=false. When an LSP server returns a
--        Position whose `character` exceeds the byte length of the line
--        snacks pulled from the buffer (or the buffer line is empty
--        because the buf isn't loaded yet), str_byteindex throws
--        "index out of range" via E5108 and the picker action aborts.
-- symptom: <leader>ss (Search: Symbols) sometimes errors
--          `E5108: vim/_editor.lua:804: index out of range` in
--          snacks.picker.util resolve_loc -> str_byteindex when the
--          chosen LSP DocumentSymbol range hits a line snacks reads
--          as empty/short (clangd in heavy UE workspaces, lsp results
--          arriving before snacks lines snapshot, etc). Symbol jump
--          fails silently in some flows; in others a notify pops.
-- introduced: 2026-04-23
-- removal_condition: snacks.nvim picker util M.str_byteindex (or its
--                    callers in resolve_loc) starts passing
--                    strict_indexing=false (or otherwise tolerates
--                    out-of-range character positions).
-- owner: hana-alice
-- enabled: true
-- END WORKAROUND
--
-- NOTES:
-- The upstream call at lua/snacks/picker/util/init.lua line 402 is:
--   local col = line and M.str_byteindex(line, pos.character, item.loc.encoding) or pos.character
-- and M.str_byteindex (line 360) forwards to vim.str_byteindex without
-- a strict_indexing arg, so it defaults to true and throws on OOB.
--
-- The fix wraps M.str_byteindex with a pcall that, on failure, falls
-- back to clamping the character index to the line's byte length. This
-- preserves correct results for in-range cases and keeps the picker
-- usable when an LSP returns slightly stale positions.
--
-- Apply contract:
--   apply()  — call once from setup-time (after snacks plugin spec
--              loads). We defer the actual patch to UIEnter/VimEnter
--              because snacks.picker.util may not be require'd yet at
--              this file's apply() time. Idempotent.

local M = {}

local applied = false
local patched = false
local original_fn = nil

local function patch_now()
  if patched then return true end
  local ok, util = pcall(require, "snacks.picker.util")
  if not ok or type(util) ~= "table" then
    return false
  end
  if type(util.str_byteindex) ~= "function" then
    return false
  end
  -- Don't double-wrap if some other code already patched it.
  if util.__str_byteindex_oob_patched then
    patched = true
    return true
  end

  original_fn = util.str_byteindex

  ---@param s string
  ---@param index number
  ---@param encoding string
  ---@param strict_indexing? boolean
  util.str_byteindex = function(s, index, encoding, strict_indexing)
    -- Honor explicit strict=true callers (none in current snacks, but
    -- be defensive). Otherwise force non-strict so OOB clamps instead
    -- of throwing.
    local effective_strict = strict_indexing
    if effective_strict == nil then
      effective_strict = false
    end
    local ok_call, result = pcall(original_fn, s, index, encoding, effective_strict)
    if ok_call then
      return result
    end
    -- Last-resort fallback: clamp to byte length of the line. Matches
    -- what snacks would visually render anyway (cursor at EOL).
    return s and #s or index
  end
  util.__str_byteindex_oob_patched = true
  patched = true
  return true
end

function M.apply()
  if applied then return end
  applied = true

  -- Try immediately; snacks may already be loaded if another workaround
  -- (picker_first_open_freeze) ran first.
  if patch_now() then return end

  local group = vim.api.nvim_create_augroup(
    "SnacksPickerStrByteindexPatch", { clear = true })

  -- UIEnter + VimEnter double safety net (mirrors picker_first_open_freeze).
  vim.api.nvim_create_autocmd("UIEnter", {
    group = group,
    once = true,
    callback = function()
      vim.defer_fn(function() patch_now() end, 250)
    end,
  })
  vim.api.nvim_create_autocmd("VimEnter", {
    group = group,
    once = true,
    callback = function()
      vim.defer_fn(function() patch_now() end, 600)
    end,
  })

  -- Also re-attempt right before the picker actually opens. If the user
  -- hits <leader>ss before our deferred patch runs, snacks will require
  -- util on demand; intercept that path via a one-shot LazyLoad hook.
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "LazyLoad",
    callback = function(args)
      if args.data == "snacks.nvim" then
        vim.schedule(function() patch_now() end)
      end
    end,
  })
end

function M.disable()
  if not patched then return end
  local ok, util = pcall(require, "snacks.picker.util")
  if ok and util and original_fn then
    util.str_byteindex = original_fn
    util.__str_byteindex_oob_patched = nil
  end
  patched = false
  original_fn = nil
end

function M.status()
  return { applied = applied, patched = patched }
end

return M
