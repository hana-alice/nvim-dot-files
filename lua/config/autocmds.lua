-- Autocmds are automatically loaded on the VeryLazy event
-- Default autocmds that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/autocmds.lua
--
-- Add any additional autocmds here
-- with `vim.api.nvim_create_autocmd`
--
-- Or remove existing autocmds by their group name (which is prefixed with `lazyvim_` for the defaults)
-- e.g. vim.api.nvim_del_augroup_by_name("lazyvim_wrap_spell")

-- Note: PreserveBufferView (BufLeave winsaveview / BufEnter winrestview) was
-- removed on 2026-05-09. It was a workaround for the perceived "buffer
-- viewport gets lost on switch" symptom, but it stomped on legitimate cursor
-- positioning by any code that crossed buffers (LSP gd, ue_goto/jumper, the
-- snacks picker jump action, etc.). Each such code path had to set
-- vim.g._restore_view_skip = true to opt out — easy to forget and silently
-- caused cursor drift after goto-definition (verified via
-- selftest_gd11 trace 2026-05-09: jumper landed at GlobalShader.h:388:8,
-- then PreserveBufferView's scheduled winrestview snapped back to the
-- buffer's last-left view {lnum=368, col=0, topline=364}, dragging the
-- cursor with it). Vim/Neovim's native behavior already restores the
-- per-buffer cursor on re-enter; the residual "viewport feels reset"
-- symptom is handled by lazyvim_last_loc on first read and by the user's
-- own zz/zt habits afterwards. Removing this autocmd also lets us drop
-- the _restore_view_skip dance from snacks.lua picker jump wrapper.

local platform = require("utils.platform")

if platform.supports_capability("mixed_eol_guard") then
  local mixed_eol_group = vim.api.nvim_create_augroup("UEMixedEOLReload", { clear = true })

  local function has_trailing_cr(bufnr, max_lines)
    local line_count = vim.api.nvim_buf_line_count(bufnr)
    if line_count == 0 then
      return false
    end

    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, math.min(line_count, max_lines or 2000), false)
    for _, line in ipairs(lines) do
      if line:sub(-1) == "\r" then
        return true
      end
    end

    return false
  end

  -- Mixed LF/CRLF files are detected as `unix`, which leaves literal `^M`
  -- in the buffer on Windows and makes gitsigns think many clean lines changed.
  vim.api.nvim_create_autocmd("BufReadPost", {
    group = mixed_eol_group,
    nested = true,
    callback = function(args)
      local bufnr = args.buf
      if vim.b[bufnr].ue_mixed_eol_checked then
        return
      end
      vim.b[bufnr].ue_mixed_eol_checked = true

      if vim.bo[bufnr].buftype ~= "" or vim.bo[bufnr].binary or vim.bo[bufnr].fileformat ~= "unix" then
        return
      end

      local name = vim.api.nvim_buf_get_name(bufnr)
      if name == "" or vim.fn.filereadable(name) ~= 1 or not has_trailing_cr(bufnr) then
        return
      end

      local view = vim.fn.winsaveview()
      -- Re-read with the correct fileformat and let the normal BufRead/FileType
      -- pipeline run again. The buffer-local guard above prevents a reload loop.
      vim.cmd("silent keepalt keepjumps edit ++ff=dos")
      pcall(vim.fn.winrestview, view)
    end,
  })
end

-- ── Recent projects MRU tracker ──────────────────────────────────────
-- Maintains lua/utils/recent_projects.lua state file via DirChanged /
-- VimEnter / BufReadPost autocmds. Without this, the snacks projects
-- picker workaround sees <5 entries and synchronously walks oldfiles
-- (60+ stat calls per file × 30 files) on the main loop → ~5s freeze
-- when pressing `p` in the dashboard on cold Neovide.
require("utils.recent_projects").setup()

-- ── Snacks picker subsystem warmup ───────────────────────────────────
-- Pre-load the heavy picker modules during the window where the user
-- is reading the dashboard. Without this, the FIRST press of any
-- picker key (dashboard p/f/g/r, <leader>;, <leader>ff) blocks for
-- ~2-4s on cold Neovide while snacks lazy-loads its picker subsystem
-- + creates 3 floating windows on the main loop.
require("workarounds.snacks.picker_first_open_freeze").apply()

-- ── Snacks picker: tolerate OOB LSP positions in str_byteindex ───────
-- Wrap snacks.picker.util.str_byteindex so that LSP-provided Position
-- characters past the end of the line clamp instead of throwing
-- E5108 "index out of range" (snacks defaults strict_indexing=true).
-- See lua/workarounds/snacks/picker_str_byteindex_oob.lua for full
-- context. Triggered by <leader>ss (Search: Symbols) on clangd in UE.
require("workarounds.snacks.picker_str_byteindex_oob").apply()
