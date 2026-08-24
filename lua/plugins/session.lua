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
      local MAX_AUTO_RESTORE_BUFFERS = 24
      local MAX_AUTO_RESTORE_TABS = 1

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

      local function session_is_heavy(path)
        if type(path) ~= "string" or path == "" or vim.fn.filereadable(path) ~= 1 then
          return false
        end

        local ok, lines = pcall(vim.fn.readfile, path)
        if not ok or type(lines) ~= "table" then
          return false
        end

        local buffers = 0
        local tabs = 0
        for _, line in ipairs(lines) do
          if line:match("^badd%s+") then
            buffers = buffers + 1
            if buffers > MAX_AUTO_RESTORE_BUFFERS then
              return true
            end
          elseif line:match("^tabnew%s") or line:match("^tabedit%s") then
            tabs = tabs + 1
            if tabs > MAX_AUTO_RESTORE_TABS then
              return true
            end
          end
        end

        return false
      end

      local function pick_session_file(current, current_plain)
        if type(current) == "string" and current ~= "" and vim.fn.filereadable(current) == 1 and not session_is_heavy(current) then
          return current
        end
        if current_plain ~= current
          and type(current_plain) == "string"
          and current_plain ~= ""
          and vim.fn.filereadable(current_plain) == 1
          and not session_is_heavy(current_plain)
        then
          return current_plain
        end
      end

      local function load_session_file(persistence, path)
        if type(path) ~= "string" or path == "" then
          return
        end
        if type(persistence.fire) == "function" then
          persistence.fire("LoadPre")
        end
        vim.cmd("silent! source " .. vim.fn.fnameescape(path))
        if type(persistence.fire) == "function" then
          persistence.fire("LoadPost")
        end
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
        local target = pick_session_file(current, current_plain)
        if target then
          load_session_file(persistence, target)
        end
      end

      -- Auto-restore only the session that belongs to the current cwd/project.
      vim.api.nvim_create_autocmd("VimEnter", {
        group = vim.api.nvim_create_augroup("persistence_auto_load", { clear = true }),
        callback = function()
          -- Restore after startup unwinds so session reads run in the normal
          -- event loop and filetype detection can replay cleanly.
          vim.schedule(auto_restore_session)
        end,
      })
    end,
  },
}
