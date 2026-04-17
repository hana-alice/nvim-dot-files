-- ue_goto.ui — user-facing visual concerns: notice spinner, try_jump,
-- shader-ext detect.
--
-- Stateless (except the module-level shared notice id, which is the
-- whole point — at most one gd spinner visible at a time).

local jumper = require("utils.ue_goto.jumper")
local location = require("utils.ue_goto.location")

local M = {}

-- Shader file extensions we treat as "no LSP, GTAGS-only".
M.SHADER_EXTS = {
  usf = true, ush = true,
  hlsl = true, hlsli = true,
  glsl = true,
  frag = true, vert = true,
  metal = true, comp = true,
}

function M.buf_extension(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" then return "" end
  return (name:match("%.([^./\\]+)$") or ""):lower()
end

-- ---------------------------------------------------------------------------
-- Progress notification
-- ---------------------------------------------------------------------------
-- Returns {update = fn(msg), clear = fn(), finish = fn(msg, lifetime_ms)}.
-- Module-level singleton: only ONE LSP-definition notice may be visible at
-- a time. A second gd while the first is still resolving reuses the same
-- notification slot (snacks: same id; nvim-notify: same handle), so the
-- top-right corner never accumulates a stack of spinners.

local _shared_notice_id = nil

function M.progress_notice(initial_msg)
  local function emit(msg, opts_override)
    -- hide_from_history is set from the FIRST emit — without this, snacks
    -- writes every spinner update into :messages history even when we
    -- pass `replace=id`. This is what makes the top-right corner appear to
    -- accumulate "resolving..." entries across multiple gd invocations.
    local opts = {
      title = "LSP definition",
      timeout = false,
      hide_from_history = true,
    }
    if _shared_notice_id ~= nil then
      opts.replace = _shared_notice_id
      opts.id = _shared_notice_id
    else
      opts.id = "ue_lsp_definition_progress"
    end
    if opts_override then
      for k, v in pairs(opts_override) do opts[k] = v end
    end
    local ok, new_id = pcall(vim.notify,
      msg,
      opts_override and opts_override.level or vim.log.levels.INFO,
      opts)
    if ok then
      _shared_notice_id = new_id or _shared_notice_id
    end
  end
  emit(initial_msg)
  local current_id = _shared_notice_id
  return {
    update = function(msg) emit(msg) end,
    clear = function()
      pcall(function()
        if current_id ~= nil then
          if type(current_id) == "table" and current_id.hide then
            current_id:hide()
          elseif vim.notify and package.loaded["notify"] then
            pcall(vim.notify, "", vim.log.levels.INFO, { replace = current_id, timeout = 1 })
          end
        end
      end)
      if _shared_notice_id == current_id then _shared_notice_id = nil end
      current_id = nil
    end,
    -- Update the notice to a "done" message that auto-dismisses after
    -- lifetime_ms. The "done" message is allowed into history so the user
    -- can see the latest resolution in :messages — only spinner ticks are
    -- history-suppressed.
    finish = function(msg, lifetime_ms, level)
      lifetime_ms = lifetime_ms or 3000
      emit(msg, {
        timeout = lifetime_ms,
        level = level or vim.log.levels.INFO,
        hide_from_history = false,
      })
      local id_at_finish = current_id
      vim.defer_fn(function()
        if _shared_notice_id == id_at_finish then
          pcall(function()
            if type(current_id) == "table" and current_id.hide then
              current_id:hide()
            elseif vim.notify and package.loaded["notify"] then
              pcall(vim.notify, "", vim.log.levels.INFO, { replace = current_id, timeout = 1 })
            end
          end)
          _shared_notice_id = nil
          current_id = nil
        end
      end, lifetime_ms + 200)
    end,
  }
end

-- try_jump(locations, title): single-location jump or quickfix.
-- Returns:
--   true         — jumped or quickfix populated
--   false        — empty input or qf was empty
--   "open_failed" — single location resolved but show_document failed
--                   (caller should still treat as terminal — we already
--                   notified — but may want to record stats)
function M.try_jump(locations, title)
  if not locations or #locations == 0 then
    return false
  end
  locations = location.dedup_locations(locations)
  if #locations == 1 then
    local ok = jumper.jump(locations[1])
    if ok then return true end
    vim.notify("LSP location could not be opened: " ..
      tostring(locations[1].uri or locations[1].targetUri), vim.log.levels.WARN)
    return "open_failed"
  end
  return location.populate_quickfix(title, locations) and true or false
end

return M
