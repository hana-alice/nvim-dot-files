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
      local function source_session(persistence, file, dir)
        if type(file) ~= "string" or file == "" or vim.fn.filereadable(file) ~= 1 then
          return false
        end
        if dir and dir ~= "" and vim.fn.isdirectory(dir) == 1 then
          vim.fn.chdir(dir)
        end
        persistence.fire("LoadPre")
        vim.cmd("silent! source " .. vim.fn.fnameescape(file))
        persistence.fire("LoadPost")
        return true
      end

      local function session_dir_from_file(file)
        if type(file) ~= "string" or file == "" then
          return nil
        end
        local stem = vim.fn.fnamemodify(file, ":t:r")
        local dir = vim.split(stem, "%%", { plain = true })[1] or ""
        dir = dir:gsub("%%", "/")
        if jit.os:find("Windows") then
          dir = dir:gsub("^(%w)/", "%1:/")
        end
        return vim.fn.isdirectory(dir) == 1 and dir or nil
      end

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
          return
        end

        local last = persistence.last()
        if type(last) ~= "string" or last == "" or vim.fn.filereadable(last) ~= 1 then
          return
        end

        local dir = session_dir_from_file(last)
        if dir then
          if source_session(persistence, last, dir) then
            return
          end
        else
          if source_session(persistence, last) then
            return
          end
        end

        persistence.load({ last = true })
      end

      -- Auto-restore session on startup (only when no file args)
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
