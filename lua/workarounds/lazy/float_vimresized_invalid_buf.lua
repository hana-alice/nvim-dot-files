-- WORKAROUND
-- name: lazy.float_vimresized_invalid_buf
-- scope: lazy
-- issue: upstream: lazy.nvim/lua/lazy/view/float.lua VimResized callback guards self.win but reuses opts() which touches vim.bo[self.buf]; if the buffer was already wiped (bufhidden=wipe + WinClosed race) the access raises E5560 "Invalid buffer id".
-- symptom: On window resize (Neovide startup, zen-mode toggle, splits) after a Lazy float was just closed, you get: "Error executing lua callback: .../lazy/view/float.lua:180: Invalid buffer id: N".
-- introduced: 2026-04-28
-- removal_condition: lazy.nvim ships a guarded VimResized callback (probably adding `or not vim.api.nvim_buf_is_valid(self.buf)` at line 192).
-- owner: hana-alice
-- enabled: true
-- END WORKAROUND

-- Strategy: in-place source patch with self-healing.
--
-- Why source patch (not monkey-patch):
--   * The buggy code is inside a closure (`opts()`) created during
--     Float:init(). The closure is captured by the VimResized autocmd
--     before we get any chance to wrap it.
--   * vim.bo / nvim_buf_set_option can't be safely globally guarded —
--     swallowing E5560 there would mask real bugs in unrelated code.
--   * The fix is one line: extend the existing `self.win` validity guard
--     to also cover `self.buf`. Same shape as the existing guard.
--
-- Self-healing: `:Lazy update lazy.nvim` will overwrite our edit. So on
-- every nvim startup we re-check and re-apply if missing. Idempotent and
-- cheap (one file read, one regex match).
--
-- Removal trigger: when M.apply() detects upstream already shipped the
-- buf-validity guard (look for "nvim_buf_is_valid(self.buf)" near line
-- 192), it skips and the workaround is effectively dormant. Watch for
-- this on `:Lazy update`; once seen, delete this file.

local M = {}

local applied        = false
local already_fixed  = false   -- upstream already did our job
local last_error     = nil

-- The line we want to modify (lazy.nvim 11.17.5):
--
--     if not (self.win and vim.api.nvim_win_is_valid(self.win)) then
--
-- becomes:
--
--     if not (self.win and vim.api.nvim_win_is_valid(self.win))
--         or not (self.buf and vim.api.nvim_buf_is_valid(self.buf)) then
--
-- Match shape lets us survive minor whitespace changes upstream.

local TARGET_PATTERN = "if not %(self%.win and vim%.api%.nvim_win_is_valid%(self%.win%)%) then"
local FIXED_MARKER   = "or not %(self%.buf and vim%.api%.nvim_buf_is_valid%(self%.buf%)%) then"

local REPLACEMENT =
  "if not (self.win and vim.api.nvim_win_is_valid(self.win))\n"
  .. "          or not (self.buf and vim.api.nvim_buf_is_valid(self.buf)) then"

local function float_path()
  -- vim.fn.stdpath('data') gives the lazy parent on both *nix and Windows.
  local p = vim.fn.stdpath("data") .. "/lazy/lazy.nvim/lua/lazy/view/float.lua"
  return (vim.fs and vim.fs.normalize and vim.fs.normalize(p)) or p
end

local function read_all(path)
  local fd = io.open(path, "rb")
  if not fd then return nil, "open failed" end
  local s = fd:read("*a")
  fd:close()
  return s
end

local function write_all(path, content)
  -- Atomic-ish: tmp + rename, so a crash mid-write doesn't brick lazy.
  local tmp = path .. ".workaround.tmp"
  local fd, err = io.open(tmp, "wb")
  if not fd then return false, "open tmp failed: " .. tostring(err) end
  fd:write(content)
  fd:close()
  local ok = os.rename(tmp, path)
  if not ok then
    -- On Windows os.rename fails if dst exists; fall back to remove+rename.
    os.remove(path)
    ok = os.rename(tmp, path)
  end
  if not ok then
    os.remove(tmp)
    return false, "rename failed"
  end
  return true
end

function M.apply()
  applied = false
  already_fixed = false
  last_error = nil

  local path = float_path()
  local src, err = read_all(path)
  if not src then
    last_error = "read: " .. tostring(err) .. " (" .. path .. ")"
    return false
  end

  -- Already patched (by us last session, or upstream landed the fix)?
  if src:find(FIXED_MARKER) then
    already_fixed = true
    applied = true   -- guard is in place, regardless of who put it
    return true
  end

  -- Locate the buggy line.
  if not src:find(TARGET_PATTERN) then
    last_error = "target line not found (lazy.nvim version drift?); skipping"
    return false
  end

  -- Replace exactly once. We use a function form to avoid % capture issues
  -- with the replacement string.
  local new_src, n = src:gsub(TARGET_PATTERN, function() return REPLACEMENT end, 1)
  if n ~= 1 then
    last_error = string.format("expected 1 substitution, got %d", n)
    return false
  end

  local ok, werr = write_all(path, new_src)
  if not ok then
    last_error = "write: " .. tostring(werr)
    return false
  end

  applied = true
  -- Defer the notify so we don't spam during startup; user sees it once.
  vim.schedule(function()
    vim.notify(
      "workarounds.lazy.float_vimresized_invalid_buf: patched float.lua "
      .. "(self.buf validity guard added). Will re-apply after :Lazy update.",
      vim.log.levels.INFO)
  end)
  return true
end

function M.disable()
  -- We don't auto-revert: lazy.nvim's own update flow will overwrite our
  -- edit anyway. To fully disable, set frontmatter enabled=false and
  -- restart; the file stays patched until next :Lazy update.
end

function M.status()
  return {
    applied        = applied,
    already_fixed  = already_fixed,
    last_error     = last_error,
    file           = float_path(),
  }
end

return M
