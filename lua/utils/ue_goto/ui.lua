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

-- Filetypes where clangd cannot help and gtags is the primary jumper.
-- Superset of SHADER_EXTS plus filetypes outside clangd's domain that
-- still benefit from gtags (Build.cs / Target.cs scripts, Python tools,
-- Lua plugin code, USS/UMG-adjacent C# in editor extensions).
M.NON_CLANGD_EXTS = {
  -- Shaders (shared with SHADER_EXTS)
  usf = true, ush = true,
  hlsl = true, hlsli = true,
  glsl = true,
  frag = true, vert = true,
  metal = true, comp = true,
  -- Build / tooling languages clangd does not own
  cs = true,
  py = true,
}

function M.buf_extension(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" then return "" end
  return (name:match("%.([^./\\]+)$") or ""):lower()
end

-- ---------------------------------------------------------------------------
-- Progress notification (FIRE-AND-FORGET model, rewritten 2026-04-20)
-- ---------------------------------------------------------------------------
-- Returns {update = fn(msg) [no-op], clear = fn(), finish = fn(msg, lifetime_ms)}.
--
-- Why this exists in this shape:
--   The previous implementation tried to maintain a single live spinner
--   bubble via snacks.notifier `replace=id` semantics. In practice this
--   was unreliable on Windows + snacks: identical id strings sometimes
--   produced a NEW bubble instead of replacing the existing one (snacks
--   GC'd the original entry but its floating window still lingered in
--   nvim_list_wins). Symptom the user actually hit: two identical
--   "⏳ resolving X ..." bubbles stuck on screen forever after a gd
--   that hit the clangd indexing wall.
--
--   We now model the spinner as a SHORT-LIVED disposable notification
--   with a hard timeout (DEFAULT_LIFETIME_MS). It will self-dismiss
--   regardless of any replace-semantic glitch, so a runaway spinner is
--   impossible by construction. clear() is a BELT-AND-SUSPENDERS sweep
--   that walks every floating window and force-closes anything titled
--   "LSP definition" — this is the ground-truth dismiss path; we no
--   longer trust id-based replace at all.
--
--   `update()` is a no-op shim (kept only to keep the handle shape
--   stable; no live caller used it as of this rewrite).
--
-- Trade-off:
--   - Pro: spinner CANNOT linger past DEFAULT_LIFETIME_MS, ever.
--   - Pro: simpler — no replace, no id juggling, no self-destruct timer.
--   - Con: very long resolves (>DEFAULT_LIFETIME_MS) lose the visible
--     spinner before the result lands. For LSP gd this is fine because
--     OVERALL_TIMEOUT_MS in lsp_fallback is already capped near this.

local DEFAULT_LIFETIME_MS = 8000

-- Force-close any lingering floating notification bubbles for our title.
-- This is the ground truth: it doesn't matter what snacks/noice/native
-- thinks about replace=id — if a window is on screen with our title, we
-- close it.
local function close_all_definition_bubbles()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local ok_cfg, cfg = pcall(vim.api.nvim_win_get_config, win)
    if ok_cfg and cfg.relative and cfg.relative ~= "" then
      -- Title can be string or array-of-{text,hl}. Inspect safely.
      local title_str = ""
      if type(cfg.title) == "string" then
        title_str = cfg.title
      elseif type(cfg.title) == "table" then
        for _, chunk in ipairs(cfg.title) do
          if type(chunk) == "table" and chunk[1] then
            title_str = title_str .. tostring(chunk[1])
          end
        end
      end
      -- Also peek the buffer text — some backends don't set title.
      local buf_text = ""
      local ok_b, lines = pcall(vim.api.nvim_buf_get_lines,
        vim.api.nvim_win_get_buf(win), 0, 3, false)
      if ok_b and lines then buf_text = table.concat(lines, "\n") end

      if title_str:find("LSP definition", 1, true)
        or buf_text:find("resolving", 1, true)
        or buf_text:find("instant index path racing", 1, true)
      then
        pcall(vim.api.nvim_win_close, win, true)
      end
    end
  end
end

function M.progress_notice(initial_msg)
  -- Fire the notification. We deliberately do NOT pass replace= or id=
  -- — every progress_notice is a fresh disposable bubble. snacks/noice
  -- will lay them out vertically; clear()/finish() sweeps them all.
  pcall(vim.notify, initial_msg, vim.log.levels.INFO, {
    title = "LSP definition",
    timeout = DEFAULT_LIFETIME_MS,
    hide_from_history = true,
  })

  local handle = {}

  -- update() kept as no-op shim for handle-shape stability. If you ever
  -- want live progress text again, do it by emitting a brand-new notice
  -- AFTER calling close_all_definition_bubbles() — never rely on replace.
  handle.update = function(_msg) end

  handle.clear = function()
    close_all_definition_bubbles()
  end

  handle.finish = function(msg, lifetime_ms, level)
    close_all_definition_bubbles()
    if msg and msg ~= "" then
      pcall(vim.notify, msg, level or vim.log.levels.INFO, {
        title = "LSP definition",
        timeout = lifetime_ms or 3000,
        hide_from_history = false,
      })
    end
  end

  return handle
end

-- Public hook so other modules (or :GdReset commands) can sweep stuck
-- bubbles without going through a handle.
M.close_all_definition_bubbles = close_all_definition_bubbles

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
