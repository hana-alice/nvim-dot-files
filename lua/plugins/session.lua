return {
  {
    "rmagatti/auto-session",
    enabled = false,
  },
  {
    "folke/persistence.nvim",
    lazy = false,
    opts = {},
    init = function()
      -- Auto-restore session on startup (only when no file args)
      vim.api.nvim_create_autocmd("VimEnter", {
        group = vim.api.nvim_create_augroup("persistence_auto_load", { clear = true }),
        callback = function()
          if vim.fn.argc() == 0 and not vim.g.started_with_stdin then
            require("persistence").load()
          end
        end,
        nested = true,
      })
    end,
  },
}
