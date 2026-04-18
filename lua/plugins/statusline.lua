-- Replace lualine with mini.statusline.
-- Profile result (before): lualine 43.7ms startup load
-- Profile result (after):  mini.statusline ~3-5ms
-- Functionality: mode/git/diagnostics/filename/filetype/encoding/location.
return {
  -- Disable LazyVim's default statusline.
  { "nvim-lualine/lualine.nvim", enabled = false },

  {
    "nvim-mini/mini.statusline",
    event = "VeryLazy",
    opts = function()
      local MiniStatusline = require("mini.statusline")
      return {
        use_icons = true,
        -- Custom content: keep LazyVim feel (mode, git, diag, file, loc, %).
        content = {
          active = function()
            local mode, mode_hl = MiniStatusline.section_mode({ trunc_width = 120 })
            local git           = MiniStatusline.section_git({ trunc_width = 75 })
            local diff          = MiniStatusline.section_diff({ trunc_width = 75 })
            local diagnostics   = MiniStatusline.section_diagnostics({ trunc_width = 75 })
            local lsp           = MiniStatusline.section_lsp({ trunc_width = 75 })
            local filename      = MiniStatusline.section_filename({ trunc_width = 140 })
            local fileinfo      = MiniStatusline.section_fileinfo({ trunc_width = 120 })
            local location      = MiniStatusline.section_location({ trunc_width = 75 })
            local search        = MiniStatusline.section_searchcount({ trunc_width = 75 })

            return MiniStatusline.combine_groups({
              { hl = mode_hl,                  strings = { mode } },
              { hl = "MiniStatuslineDevinfo",  strings = { git, diff, diagnostics, lsp } },
              "%<", -- truncate from here
              { hl = "MiniStatuslineFilename", strings = { filename } },
              "%=", -- right align
              { hl = "MiniStatuslineFileinfo", strings = { fileinfo } },
              { hl = mode_hl,                  strings = { search, location } },
            })
          end,
        },
      }
    end,
    init = function()
      -- Avoid 1-frame empty statusline flash.
      vim.o.laststatus = 2
    end,
  },
}
