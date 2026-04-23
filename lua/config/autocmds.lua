-- Autocmds are automatically loaded on the VeryLazy event
-- Default autocmds that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/autocmds.lua
--
-- Add any additional autocmds here
-- with `vim.api.nvim_create_autocmd`
--
-- Or remove existing autocmds by their group name (which is prefixed with `lazyvim_` for the defaults)
-- e.g. vim.api.nvim_del_augroup_by_name("lazyvim_wrap_spell")

-- ── Preserve viewport when switching buffers ─────────────────────────
-- Without this, switching buffers resets the scroll position so the
-- cursor lands in the middle of the screen instead of where you left it.
--
-- Guard: any code that positions the cursor after switching buffers
-- (picker jump, goto-definition, etc.) should set
--   vim.g._restore_view_skip = true
-- before doing so. The BufEnter handler honours this flag and skips the
-- scheduled winrestview so the jump target is not overwritten.
local buf_views = {}
local last_left_buf = nil -- track the buffer we left
local view_group = vim.api.nvim_create_augroup("PreserveBufferView", { clear = true })

vim.api.nvim_create_autocmd("BufLeave", {
  group = view_group,
  callback = function()
    local buf = vim.api.nvim_get_current_buf()
    if vim.bo[buf].buftype == "" then
      buf_views[buf] = vim.fn.winsaveview()
      last_left_buf = buf
    else
      -- Leaving a special buffer (picker, sidebar, terminal, etc.)
      -- → the next BufEnter should NOT restore, because the user is
      --   returning from a jump action, not manually switching buffers.
      last_left_buf = nil
    end
  end,
})

vim.api.nvim_create_autocmd("BufEnter", {
  group = view_group,
  callback = function()
    -- Skip flag (set by picker jump wrapper, goto-definition, etc.)
    if vim.g._restore_view_skip then
      vim.g._restore_view_skip = nil
      return
    end

    local buf = vim.api.nvim_get_current_buf()
    local view = buf_views[buf]

    -- Only restore if we came from another normal buffer (buftype="").
    -- If last_left_buf is nil, we came from a special buffer (sidebar,
    -- picker float, terminal) → skip restore so jump targets stick.
    -- Also skip if we're "returning" to the same buffer we left (e.g.
    -- picker opened and closed on the same file → symbol jump).
    local should_restore = view
      and vim.bo[buf].buftype == ""
      and last_left_buf ~= nil
      and last_left_buf ~= buf

    if not should_restore then
      return
    end

    vim.schedule(function()
      if vim.g._restore_view_skip then
        vim.g._restore_view_skip = nil
        return
      end
      if vim.api.nvim_get_current_buf() ~= buf then
        return
      end
      pcall(vim.fn.winrestview, view)
    end)
  end,
})

vim.api.nvim_create_autocmd("BufDelete", {
  group = view_group,
  callback = function(args)
    buf_views[args.buf] = nil
  end,
})

local is_windows = require("utils.platform").is_windows

if is_windows then
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
