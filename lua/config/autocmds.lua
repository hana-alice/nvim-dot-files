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
local buf_views = {}
local view_group = vim.api.nvim_create_augroup("PreserveBufferView", { clear = true })

vim.api.nvim_create_autocmd("BufLeave", {
  group = view_group,
  callback = function()
    local buf = vim.api.nvim_get_current_buf()
    if vim.bo[buf].buftype == "" then
      buf_views[buf] = vim.fn.winsaveview()
    end
  end,
})

vim.api.nvim_create_autocmd("BufEnter", {
  group = view_group,
  callback = function()
    local buf = vim.api.nvim_get_current_buf()
    local view = buf_views[buf]
    if view and vim.bo[buf].buftype == "" then
      vim.schedule(function()
        if vim.api.nvim_get_current_buf() == buf then
          pcall(vim.fn.winrestview, view)
        end
      end)
    end
  end,
})

vim.api.nvim_create_autocmd("BufDelete", {
  group = view_group,
  callback = function(args)
    buf_views[args.buf] = nil
  end,
})

local is_windows = vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1

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
      vim.cmd("silent keepalt keepjumps noautocmd edit ++ff=dos")
      pcall(vim.fn.winrestview, view)
    end,
  })
end
