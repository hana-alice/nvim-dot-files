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
      local function should_auto_restore()
        if vim.g.started_with_stdin then
          return false
        end
        local argc = vim.fn.argc()
        if argc == 0 then
          return true
        end
        if argc == 1 then
          local arg0 = vim.fn.argv(0)
          return type(arg0) == "string" and arg0 ~= "" and vim.fn.isdirectory(arg0) == 1
        end
        return false
      end

      local function auto_restore_session()
        if not should_auto_restore() then
          return
        end

        local persistence = require("persistence")
        if vim.fn.argc() == 1 then
          local dir_arg = vim.fn.argv(0)
          if type(dir_arg) == "string" and dir_arg ~= "" and vim.fn.isdirectory(dir_arg) == 1 then
            vim.fn.chdir(vim.fn.fnamemodify(dir_arg, ":p"))
          end
        end

        local current = persistence.current()
        local current_plain = persistence.current({ branch = false })
        if vim.fn.filereadable(current) == 1 or vim.fn.filereadable(current_plain) == 1 then
          persistence.load()
        end
      end

      -- Auto-restore only the session that belongs to the current cwd/project.
      vim.api.nvim_create_autocmd("VimEnter", {
        group = vim.api.nvim_create_augroup("persistence_auto_load", { clear = true }),
        callback = function()
          auto_restore_session()
        end,
        nested = true,
      })
    end,
  },
}
