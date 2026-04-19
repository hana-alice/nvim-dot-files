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
--
-- SELF-DESTRUCT (Tier-1 hardening, 2026-04-18):
--   Even if the upstream business logic forgets to call clear()/finish(),
--   every progress_notice() automatically self-destructs after
--   SELF_DESTRUCT_MS. This is a defense-in-depth safety net — the real
--   fix lives in the provider/orchestrator's hard contract — but ensures
--   a runaway spinner can never linger longer than this regardless of
--   what bug crept in upstream.
--
--   Each update()/finish() resets the self-destruct timer. clear() cancels
--   it explicitly.

local _shared_notice_id = nil
local SELF_DESTRUCT_MS = 8000

function M.progress_notice(initial_msg)
  local self_destruct_timer = nil

  local function cancel_self_destruct()
    if self_destruct_timer and not self_destruct_timer:is_closing() then
      pcall(function() self_destruct_timer:stop(); self_destruct_timer:close() end)
      self_destruct_timer = nil
    end
  end

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

  -- Forward declarations so the self-destruct callback can reach hide().
  local handle = {}

  local function hide_now()
    cancel_self_destruct()
    -- Hide the notification, regardless of which notify backend is in use
    -- (snacks.notifier, nvim-notify, noice — all of them honor `replace=id`
    -- with a near-zero timeout to dismiss the original bubble).
    --
    -- HISTORY: previous version only handled the nvim-notify path
    -- (`package.loaded["notify"]`) and a `current_id.hide()` call. With
    -- snacks.notifier (LazyVim default) the id is a string/number — neither
    -- branch fired, so the spinner was never actually dismissed. Symptom:
    -- "✓ jumped" success toast appears AND the "⏳ resolving …" spinner
    -- stays on screen until the 8s self-destruct (or forever if that path
    -- also no-ops). Fix is one universal call.
    pcall(function()
      if current_id == nil then return end
      -- nvim-notify exposes a record with :hide() — use it if present.
      if type(current_id) == "table" and type(current_id.hide) == "function" then
        current_id:hide()
        return
      end
      -- Universal path: emit an empty replacement with a tiny timeout. snacks
      -- and noice both treat this as "remove the bubble". hide_from_history
      -- prevents the empty replacement from polluting :messages.
      pcall(vim.notify, "", vim.log.levels.INFO, {
        replace = current_id,
        id = current_id,
        timeout = 1,
        hide_from_history = true,
      })
    end)
    if _shared_notice_id == current_id then _shared_notice_id = nil end
    current_id = nil
  end

  -- Arm self-destruct: if no one calls clear()/finish() within SELF_DESTRUCT_MS
  -- the spinner force-hides itself. Each update() rearms it.
  local function arm_self_destruct()
    cancel_self_destruct()
    self_destruct_timer = vim.defer_fn(function()
      -- Force a "timed out" finish with a short lifetime so the user
      -- gets a visible cue rather than the spinner just vanishing.
      emit("⌛ progress notice self-timed-out (no terminating callback)", {
        timeout = 2000,
        hide_from_history = false,
        level = vim.log.levels.WARN,
      })
      vim.defer_fn(hide_now, 2200)
    end, SELF_DESTRUCT_MS)
  end

  arm_self_destruct()

  handle.update = function(msg)
    emit(msg)
    arm_self_destruct() -- re-arm on each progress update
  end

  handle.clear = hide_now

  -- Update the notice to a "done" message that auto-dismisses after
  -- lifetime_ms. The "done" message is allowed into history so the user
  -- can see the latest resolution in :messages — only spinner ticks are
  -- history-suppressed.
  handle.finish = function(msg, lifetime_ms, level)
    cancel_self_destruct()
    lifetime_ms = lifetime_ms or 3000
    emit(msg, {
      timeout = lifetime_ms,
      level = level or vim.log.levels.INFO,
      hide_from_history = false,
    })
    local id_at_finish = current_id
    vim.defer_fn(function()
      -- Only hide if we still own the slot (no newer notice has taken it).
      if _shared_notice_id == id_at_finish then
        hide_now()
      end
    end, lifetime_ms + 200)
  end

  return handle
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
