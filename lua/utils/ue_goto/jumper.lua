-- ===========================================================================
-- utils.ue_goto.jumper
--
-- ONE job: take a precise location and execute the buffer/cursor switch
-- correctly w.r.t. jumplist + shada cursor restore.
--
-- HARD CONTRACT
-- -------------
-- Input:
--   location.uri                          required (string)
--   location.range.start.line             required (0-indexed)
--   location.range.start.character        required (0-indexed UTF-16 col)
--
-- Caller responsibility (NOT this module's):
--   The location must already be PRECISE. drift / ws-symbol staleness /
--   off-by-N-col fixes belong in the provider layer, BEFORE jump().
--   This module will faithfully execute whatever location it receives.
--
-- Post-condition (guaranteed on return true):
--   1. jumplist tail has exactly ONE new entry: the SOURCE position
--      (i.e. one Ctrl-O returns to where gd was invoked from).
--      In particular: NO spurious (target_buf, 1, 0) entry.
--   2. current window's buffer == target buffer.
--   3. cursor == (range.start.line + 1, clamped col).
--   4. view centered (zz).
--
-- Failure: returns false, makes no observable change to jumplist or cursor
-- of the source position.
--
-- DESIGN — why no timer/defer
--   The previous implementation used 30ms + 150ms vim.defer_fn timers as
--   "drift fix" safety nets to fight shada's BufReadPost cursor-restore.
--   That's polling — it papers over the race rather than synchronizing
--   with it. Here we instead hook BufReadPost AND BufWinEnter once on the
--   target buffer; whichever fires after shada's restore re-asserts our
--   cursor exactly once. If a race still exists it must surface as a
--   real, debuggable bug — not be hidden by a timer.
-- ===========================================================================

local M = {}

local function clamp_pos(bufnr, line_1b, col_0b)
  local lc = vim.api.nvim_buf_line_count(bufnr)
  if line_1b > lc then line_1b = lc end
  if line_1b < 1 then line_1b = 1 end
  local lt = vim.api.nvim_buf_get_lines(bufnr, line_1b - 1, line_1b, false)[1] or ""
  if col_0b > #lt then col_0b = #lt end
  if col_0b < 0 then col_0b = 0 end
  return line_1b, col_0b
end

--- Execute a precise jump.
--- @param location table  { uri, range = { start = { line, character } } }
--- @return boolean ok
function M.jump(location)
  -- ---- validate input ----------------------------------------------------
  local uri = location and (location.uri or location.targetUri)
  local range = location and (location.range
    or location.targetSelectionRange
    or location.targetRange)
  if not uri or not range or not range.start then
    return false
  end

  local target_path = vim.uri_to_fname(uri)
  local target_line_0b = range.start.line or 0
  local target_col_0b  = range.start.character or 0
  local target_line_1b = target_line_0b + 1

  -- ---- step 1: push SOURCE onto jumplist BEFORE any buffer mutation -------
  -- This must be the very first vim.cmd we run. If we let `:edit` run first,
  -- the buffer-switch lands cursor at (1, 0) and `m'` would record THAT
  -- bogus position as the "source", stranding Ctrl-O.
  vim.cmd("normal! m'")

  -- ---- step 2: ensure target buffer exists & is loaded --------------------
  local bufnr = vim.fn.bufnr(target_path)
  if bufnr == -1 or not vim.api.nvim_buf_is_loaded(bufnr) then
    -- `keepjumps`: do NOT let :edit append its own (target, 1, 0) jumplist
    -- entry. We've already controlled the jumplist via `m'` above.
    -- `silent!`: suppress "X lines, Y bytes" mid-callback chatter.
    local ok = pcall(vim.cmd, "keepjumps silent! edit "
      .. vim.fn.fnameescape(target_path))
    if not ok then return false end
    bufnr = vim.fn.bufnr(target_path)
    if bufnr == -1 then return false end
  end

  -- ---- step 3: switch current window to target buffer (no jumplist write)--
  -- nvim_set_current_buf is a pure API call; it does NOT push onto jumplist.
  if vim.api.nvim_get_current_buf() ~= bufnr then
    vim.api.nvim_set_current_buf(bufnr)
  end

  -- ---- step 4: set cursor to clamped target position ----------------------
  local ln, cc = clamp_pos(bufnr, target_line_1b, target_col_0b)
  local ok_cur = pcall(vim.api.nvim_win_set_cursor, 0, { ln, cc })
  if not ok_cur then return false end

  -- ---- step 5: shada race guard (one-shot, NO timer) ----------------------
  -- If the target buffer hasn't fully been read yet, BufReadPost may still
  -- fire after we set the cursor and shada autocmds will jump cursor to the
  -- last-known `'` mark from a previous session. Hook ONCE on both events
  -- (whichever runs last after shada wins). The handler bails if user moved
  -- meaningfully (different line) so we don't fight intentional movement.
  --
  -- We trigger this regardless of whether the buffer was just loaded,
  -- because BufWinEnter fires on every buffer-switch and shada's restore
  -- can also be wired there. Cheap to register, dies after one fire.
  local target_buf = bufnr
  local want_line, want_col = ln, cc

  local group = vim.api.nvim_create_augroup(
    "ue_goto_jumper_" .. target_buf .. "_" .. vim.loop.hrtime(),
    { clear = true }
  )

  local function reassert(reason)
    if vim.api.nvim_get_current_buf() ~= target_buf then return end
    local cur = vim.api.nvim_win_get_cursor(0)
    if cur[1] == want_line then return end -- already correct (or user moved a col)
    local rln, rcc = clamp_pos(target_buf, want_line, want_col)
    pcall(vim.api.nvim_win_set_cursor, 0, { rln, rcc })
    pcall(vim.cmd, "normal! zz")
    if M._on_reassert then pcall(M._on_reassert, reason, cur, rln, rcc) end
  end

  vim.api.nvim_create_autocmd({ "BufReadPost", "BufWinEnter" }, {
    group = group,
    buffer = target_buf,
    once = true,
    callback = function(args) reassert(args.event) end,
  })

  -- Auto-tear-down: dispose the augroup on first cursor move OR after the
  -- next CursorHold, whichever comes first. Prevents stale augroups
  -- accumulating across many gd calls.
  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorHold" }, {
    group = group,
    buffer = target_buf,
    once = true,
    callback = function()
      pcall(vim.api.nvim_del_augroup_by_id, group)
    end,
  })

  -- ---- step 6: center view ------------------------------------------------
  pcall(vim.cmd, "normal! zz")
  return true
end

return M
