local function get_ue()
  local ok, ue = pcall(require, "ue")
  return ok and ue or nil
end

local function workspace_opts()
  local ue = get_ue()
  if not ue then return nil end
  local opts = ue.picker_options()
  if type(opts) ~= "table" or #opts.dirs == 0 then return nil end
  return opts
end

local function project_opts()
  local ue = get_ue()
  if not ue then return nil end
  local opts = ue.picker_project_options()
  if type(opts) ~= "table" then return nil end
  return opts
end

local function project_root()
  local ue = get_ue()
  if not ue or type(ue.ue_roots) ~= "function" then return nil end
  local root = ue.ue_roots()
  if type(root) ~= "string" or root == "" then return nil end
  return root
end

local function scope_opts()
  local ue = get_ue()
  if not ue then return nil, nil end
  local opts, scope, err = ue.current_scope_picker_options()
  if type(opts) ~= "table" then return nil, err end
  return opts, nil
end

local function code_ft()
  local ue = get_ue()
  return ue and ue.FT_CODE or nil
end

local function code_globs()
  local ue = get_ue()
  return ue and ue.GLOBS_CODE or nil
end

local function all_globs()
  local ue = get_ue()
  return ue and ue.GLOBS_ALL or nil
end

-- Apply file type filter: ft for files picker, glob for grep picker
local function with_ft(opts, ft)
  if opts and ft then opts.ft = ft end
  return opts
end

local function with_glob(opts, globs)
  if opts and globs then opts.glob = globs end
  return opts
end

-- Keep grep/files history, but open pickers blank by default.
local function history_record_query(record)
  if type(record) ~= "table" then
    return ""
  end
  if type(record.search) == "string" and record.search ~= "" then
    return record.search
  end
  if type(record.pattern) == "string" and record.pattern ~= "" then
    return record.pattern
  end
  return ""
end

local function picker_history_records(source)
  local ok, history_mod = pcall(require, "snacks.picker.util.history")
  if not ok then
    return {}
  end

  local ok_hist, history = pcall(history_mod.new, "picker_" .. source, {
    filter = function(record)
      return history_record_query(record) ~= ""
    end,
  })
  if not ok_hist or not history then
    return {}
  end

  local records = {}
  for _ = 1, math.max((history.idx or 1) - 1, 0) do
    local record = history:prev()
    if record then
      records[#records + 1] = record
    end
  end
  return records
end

local function rewrite_picker_history(source, records)
  local ok, history_mod = pcall(require, "snacks.picker.util.history")
  if not ok then
    return false, "Snacks history unavailable"
  end

  local ok_hist, history = pcall(history_mod.new, "picker_" .. source)
  if not ok_hist or not history or not history.kv then
    return false, "Picker history unavailable"
  end

  history.kv.data = records or {}
  history.idx = #history.kv.data + 1
  history.cursor = history.idx
  history.kv.loaded_time = 0
  history.kv:close()
  return true
end

local function clear_picker_history(source)
  return rewrite_picker_history(source, {})
end

local function clipboard_text()
  for _, reg in ipairs({ "+", "*" }) do
    local text = vim.fn.getreg(reg)
    if type(text) == "string" and text ~= "" then
      return text
    end
  end
  return ""
end

local function paste_picker_clipboard(picker)
  local input = picker and picker.input
  local win = input and input.win and input.win.win
  if not win or not vim.api.nvim_win_is_valid(win) then
    return
  end

  local text = clipboard_text()
  if text == "" then
    return
  end
  text = text:gsub("\r\n?", "\n"):gsub("\n", " ")

  local current = input:get() or ""
  local col = math.min(vim.api.nvim_win_get_cursor(win)[2], #current)
  local new = current:sub(1, col) .. text .. current:sub(col + 1)

  input:set(new, new)
  vim.api.nvim_win_set_cursor(win, { 1, col + #text })
  picker:find({ refresh = false })
end

local function pin_sidebar_qflist(picker)
  -- We do NOT call snacks.picker.actions.qflist(): that helper does
  -- `vim.cmd("botright copen")` itself, which left us with TWO panels
  -- visible (the native quickfix split AND the trouble float). We want
  -- only the trouble tree, so we replicate the qflist-population logic
  -- inline and skip the copen.

  local sel = picker:selected()
  local items = (sel and #sel > 0) and sel or picker:items()

  local qf = {}
  for _, item in ipairs(items) do
    local file = (item.file ~= nil and item.file ~= "")
        and item.file
        or (Snacks and Snacks.picker and Snacks.picker.util and Snacks.picker.util.path
            and Snacks.picker.util.path(item) or nil)
    qf[#qf + 1] = {
      filename = file,
      bufnr    = item.buf,
      lnum     = (item.pos and item.pos[1]) or 1,
      col      = ((item.pos and item.pos[2]) or 0) + 1,
      end_lnum = item.end_pos and item.end_pos[1] or nil,
      end_col  = item.end_pos and (item.end_pos[2] + 1) or nil,
      text     = item.line or item.comment or item.label or item.name or item.detail or item.text or "",
      pattern  = item.search,
      valid    = true,
    }
  end

  -- Set the list BEFORE closing the picker — closing changes focus and
  -- some snacks bookkeeping; populating first keeps things tidy.
  vim.fn.setqflist({}, " ", {
    title = "Pinned: " .. (picker.opts and picker.opts.title or "picker"),
    items = qf,
  })
  picker:close()

  -- Close any left sidebar so the bottom trouble panel is the only
  -- secondary view, then pop trouble.
  vim.schedule(function()
    pcall(function() require("utils.sidebar").close() end)
    local ok_t, trouble = pcall(require, "trouble")
    if not ok_t then
      vim.notify("Trouble unavailable; falling back to :copen", vim.log.levels.WARN)
      vim.cmd("botright copen 14")
      return
    end
    trouble.open("ue_qflist_bottom")
  end)
end

local function grep_history_items()
  local items = {}
  local seen = {}
  for _, record in ipairs(picker_history_records("grep")) do
    local query = history_record_query(record)
    if query ~= "" and not seen[query] then
      seen[query] = true
      items[#items + 1] = {
        text = query,
        query = query,
        live = record.live == true,
        preview = {
          text = query,
          ft = "regex",
        },
      }
    end
  end
  return items
end

---------- Find files ----------

-- <leader>ff — project files (all types, fast)
local function ue_project_files()
  local snacks = require("snacks")
  local opts = project_opts()
  if opts then
    opts.title = "UE Project Files"
    return snacks.picker.files(opts)
  end
  return snacks.picker.files()
end

local function ue_files()
  local snacks = require("snacks")
  local opts = with_ft(project_opts(), code_ft())
  if opts then
    opts.title = "UE Project Code"
    return snacks.picker.files(opts)
  end
  return snacks.picker.files()
end

local function ue_workspace_files()
  local snacks = require("snacks")
  local ue = get_ue()

  -- Try cached file list first (avoids NTFS directory traversal)
  if ue and ue.cached_files({ title = "UE Workspace Code", list_type = "code" }) then
    return
  end

  local opts = with_ft(workspace_opts(), code_ft())
  if opts then
    opts.title = "UE Workspace Code"
    return snacks.picker.files(opts)
  end
  return snacks.picker.files()
end

local function ue_workspace_all_files()
  local snacks = require("snacks")
  local ue = get_ue()

  -- Try cached file list first (avoids NTFS directory traversal)
  if ue and ue.cached_files({ title = "UE Workspace All Files", list_type = "all" }) then
    return
  end

  local opts = ue and ue.picker_options({ include_third_party = true }) or workspace_opts() or {}
  opts.title = "UE Workspace All Files"
  return snacks.picker.files(opts)
end

local function ue_git_files()
  local snacks = require("snacks")
  local root = project_root()
  if root then
    return snacks.picker.git_files({ cwd = root, title = "UE Project Git Files" })
  end
  return snacks.picker.git_files()
end

---------- Grep ----------

local function ue_project_grep(query)
  local snacks = require("snacks")
  local ue = get_ue()

  -- Try cached grep first (avoids NTFS directory traversal)
  if ue then
    local grep_opts = { title = "Grep All Code (Engine+Project)" }
    if type(query) == "string" and query ~= "" then
      grep_opts.search = query
    end
    if ue.cached_grep(grep_opts) then
      return
    end
  end

  -- Fallback: standard directory-based grep
  local opts = with_glob(workspace_opts(), all_globs()) or {}
  if type(query) == "string" and query ~= "" then
    opts.search = query
  end
  opts.title = "Grep All Code (Engine+Project)"
  return snacks.picker.grep(opts)
end

local function ue_grep()
  local snacks = require("snacks")
  local opts = with_glob(workspace_opts(), code_globs())
  if opts then
    opts.title = "Grep Workspace Code"
    return snacks.picker.grep(opts)
  end
  return snacks.picker.grep()
end

local function ue_grep_all()
  local snacks = require("snacks")
  local opts = workspace_opts()
  if opts then
    opts.title = "Grep Workspace All"
    return snacks.picker.grep(opts)
  end
  return snacks.picker.grep()
end

---------- Scope (current module/plugin) ----------

local function ue_scope_files()
  local snacks = require("snacks")
  local opts, err = scope_opts()
  if opts then
    opts.title = "UE Scope Files"
    with_ft(opts, code_ft())
    return snacks.picker.files(opts)
  end
  vim.notify(err or "No UE module or plugin scope found", vim.log.levels.WARN)
end

local function ue_scope_grep()
  local snacks = require("snacks")
  local opts, err = scope_opts()
  if opts then
    opts.title = "UE Scope Grep"
    with_glob(opts, code_globs())
    return snacks.picker.grep(opts)
  end
  vim.notify(err or "No UE module or plugin scope found", vim.log.levels.WARN)
end

local function ue_grep_history()
  local snacks = require("snacks")
  local items = grep_history_items()
  if vim.tbl_isempty(items) then
    vim.notify("No grep history found", vim.log.levels.WARN)
    return
  end

  return snacks.picker.pick({
    title = "Grep History",
    items = items,
    format = "text",
    preview = "none",
    layout = { preset = "vscode" },
    confirm = function(picker, item)
      picker:close()
      if item and item.query then
        vim.schedule(function()
          ue_project_grep(item.query)
        end)
      end
    end,
  })
end

local function ue_clear_picker_history()
  local ok_files, err_files = clear_picker_history("files")
  local ok_grep, err_grep = clear_picker_history("grep")
  if not ok_files or not ok_grep then
    require("utils.log").notify_error("snacks", err_files or err_grep or "Failed to clear picker history")
    return
  end
  vim.notify("Cleared file and grep history")
end

---------- Plugin spec ----------

return {
  {
    "folke/snacks.nvim",
    lazy = true,
    keys = {
      { "<leader>;", function() Snacks.picker.commands() end, desc = "Commands" },
      -- <leader>fe — file tree browser (snacks.picker.explorer style).
      -- Tree of the project root with directory expand/collapse — for the
      -- "I want to see the structure" workflow. Fuzzy file finder stays on
      -- <leader>ff / <leader><space> (no UX change there).
      { "<leader>fe", function()
        local snacks = require("snacks")
        local cwd = project_root() or vim.uv.cwd()
        snacks.picker.explorer({
          cwd = cwd,
          title = "UE Tree (" .. vim.fn.fnamemodify(cwd, ":t") .. ")",
          auto_close = true,
          jump = { close = true },
          layout = { preset = "telescope" },
        })
      end, desc = "File tree browser (current project)" },
      { "<leader>fE", false },
      { "<leader>e", function() require("utils.yazi").open_current() end, desc = "Yazi (current file)" },
      { "<leader>E", false },
      -- Grep
      { "<leader>/", ue_project_grep, desc = "Grep All Code (Engine+Project)" },
      { "<leader>sg", ue_grep, desc = "Grep Workspace Code (C++/Shader)" },
      { "<leader>sG", ue_grep_all, desc = "Grep Workspace All Files" },
      { "<leader>sH", ue_grep_history, desc = "Search: Grep History" },
      -- Resume the last grep picker, even if it was closed via <C-q> pin.
      -- snacks.picker.resume keys state by source name. Our pickers use
      -- "ue_grep_csearch" / "ue_grep_rg" sources; we try csearch first
      -- then fall back to rg, mirroring the live decision in cached_grep.
      { "<leader>s/", function()
        local picker = require("snacks").picker
        local ok = pcall(picker.resume, "ue_grep_csearch")
        if not ok then pcall(picker.resume, "ue_grep_rg") end
      end, desc = "Resume Last Grep (incl. after <C-q> pin)" },
      { "<leader>sC", ue_clear_picker_history, desc = "Search: Clear Picker History" },
      -- Find files
      { "<leader><space>", ue_workspace_all_files, desc = "Find Workspace All Files" },
      { "<leader>fC", ue_clear_picker_history, desc = "Find: Clear Search History" },
      { "<leader>ff", ue_project_files, desc = "Find Project Files" },
      { "<leader>fF", ue_workspace_files, desc = "Find Workspace Code (C++/Shader)" },
      { "<leader>fa", ue_files, desc = "Find Project Code (C++/Shader)" },
      { "<leader>fg", ue_git_files, desc = "Find Project Git Files" },
      -- Scope (current module/plugin)
      { "<leader>uo", ue_scope_files, desc = "UE: Files in current module/plugin" },
      { "<leader>uO", ue_scope_grep, desc = "UE: Grep current module/plugin" },
    },
    opts = function(_, opts)
      opts = opts or {}
      opts.explorer = vim.tbl_deep_extend("force", opts.explorer or {}, {
        enabled = false,
        replace_netrw = false,
      })
      opts.picker = opts.picker or {}
      opts.picker.layout = vim.tbl_deep_extend("force", { preset = "vscode" }, opts.picker.layout or {})

      -- Per-source layout overrides:
      -- grep wants telescope layout (list + side preview) so users can read
      -- match context without jumping. The global vscode preset has no
      -- preview which makes "<leader>/" feel like a blind drop.
      opts.picker.sources = opts.picker.sources or {}
      opts.picker.sources.grep = vim.tbl_deep_extend(
        "force", opts.picker.sources.grep or {}, {
          layout = { preset = "telescope" },
        })

      -- Workaround: snacks projects picker freezes for ~30s on UE workspaces
      -- (oldfiles walk + per-entry git spawn on main loop). See
      -- lua/workarounds/snacks/projects_picker_freeze.lua for full context.
      require("workarounds.snacks.projects_picker_freeze").apply(opts)

      -- Workaround: smart picker (<leader><leader>) lists buffers whose
      -- file was deleted on disk after a branch switch — selecting one
      -- opens an empty buffer at the stale path.
      -- See lua/workarounds/snacks/smart_picker_dead_buffer.lua.
      require("workarounds.snacks.smart_picker_dead_buffer").apply(opts)

      -- <leader><leader> matcher tuning: smart-case + fzf-style fuzzy +
      -- filename-priority scoring. Snacks defaults already enable
      -- smartcase/ignorecase/fuzzy at the matcher level (see
      -- snacks/picker/core/matcher.lua), but `filename_bonus` is opt-in
      -- and lives on the score config — without it, `MyUI.cpp` and
      -- `src/ui-helpers/foo.cpp` tie when typing "ui". Setting it here
      -- as a global matcher option means the smart picker (and every
      -- other source that doesn't override matcher) gets filename-first
      -- ranking with path matches as a fallback.
      -- Scratch buffer persistence:
      -- Default snacks.scratch already writes to stdpath("data").."/scratch"
      -- and autowrites on hide. The annoyance is `filekey.ft = true`: opening
      -- <leader>. with a different filetype context creates a NEW scratch
      -- file, so the same project ends up with cpp/dosini/markdown/... islands
      -- and `<leader>.` rarely re-opens the one you were just typing in.
      --
      -- We pin scratch to a fixed root under the data dir (explicit, not
      -- magic), drop ft from the file key (one scratch per cwd+branch+count),
      -- and force the buffer's filetype to markdown so headers/lists render.
      -- For a second/third independent scratch in the same project, prefix a
      -- count: `2<leader>.`, `3<leader>.` open distinct (count=2/3) buffers.
      -- `<leader>S` still lists every scratch ever created (full history).
      opts.scratch = vim.tbl_deep_extend("force", opts.scratch or {}, {
        root = vim.fn.stdpath("data") .. "/scratch",
        ft = "markdown",
        autowrite = true,
        filekey = {
          cwd    = true,
          branch = true,
          count  = true,
          ft     = false, -- one persistent scratch per (cwd, branch, count)
        },
      })

      opts.picker.matcher = vim.tbl_deep_extend("force", opts.picker.matcher or {}, {
        fuzzy          = true,   -- fzf-style subsequence matching
        smartcase      = true,   -- lower → case-insensitive; mixed → case-sensitive
        ignorecase     = true,   -- baseline for smartcase to flip off
        filename_bonus = true,   -- score filename matches above path matches
        sort_empty     = false,  -- keep frecency/source order when query is empty
      })

      opts.picker.actions = vim.tbl_deep_extend("force", opts.picker.actions or {}, {
        paste_clipboard = paste_picker_clipboard,
        pin_sidebar_qflist = pin_sidebar_qflist,
        -- Wrap the default jump action to work around two issues:
        -- 1. PreserveBufferView autocmd (config/autocmds.lua) restoring the
        --    old viewport via winrestview, overwriting the jump target.
        --    → Fixed by synchronous skip flag check in autocmds.lua BufEnter.
        -- 2. Neovide sending an implicit mouse-release event when the picker
        --    float closes and focus returns to the main window, which moves
        --    the cursor to wherever the mouse pointer is on screen.
        --    → Fixed by cursor guard using vim.defer_fn(0) that runs AFTER
        --      all pending vim.schedule callbacks (including snacks' own
        --      insert-mode reschedule of M.jump).
        jump = function(picker, item, action)
          -- (1) Tell PreserveBufferView to skip the next BufEnter restore.
          vim.g._restore_view_skip = true

          -- Call the real jump. NOTE: in insert mode (picker input), this
          -- does stopinsert() + vim.schedule(M.jump) internally, so the
          -- actual jump happens in a later event loop tick.
          require("snacks.picker.actions").jump(picker, item, action)

          -- (2) Guard against Neovide mouse-release cursor repositioning.
          -- Neovide issue: when a floating window closes while the mouse button
          -- is released, Neovide sends an implicit <LeftRelease> that moves the
          -- cursor to wherever the mouse pointer sits on screen.
          -- TODO: Remove this workaround once Neovide fixes this behavior.
          -- https://github.com/neovide/neovide/issues — search "cursor jump after float close"
          -- We use a two-layer defer: first vim.schedule to get past the
          -- insert-mode reschedule, then vim.defer_fn(0) to run after
          -- the actual jump's vim.schedule has completed.
          if vim.g.neovide then
            vim.schedule(function()
              vim.defer_fn(function()
                -- By now the real jump has landed. Record the position.
                local win = vim.api.nvim_get_current_win()
                local buf = vim.api.nvim_get_current_buf()
                local ok, pos = pcall(vim.api.nvim_win_get_cursor, win)
                if not ok then return end
                local target = { pos[1], pos[2] }

                -- One-shot CursorMoved guard: if Neovide's mouse event
                -- moves the cursor away, snap it back.
                local guard_id
                guard_id = vim.api.nvim_create_autocmd("CursorMoved", {
                  once = true,
                  callback = function()
                    if vim.api.nvim_get_current_win() == win
                      and vim.api.nvim_get_current_buf() == buf then
                      local cur = vim.api.nvim_win_get_cursor(win)
                      if cur[1] ~= target[1] or cur[2] ~= target[2] then
                        pcall(vim.api.nvim_win_set_cursor, win, target)
                        vim.cmd("silent! normal! zz")
                      end
                    end
                  end,
                })

                -- Clean up guard after 500ms if it never fired
                vim.defer_fn(function()
                  pcall(vim.api.nvim_del_autocmd, guard_id)
                end, 500)
              end, 0)
            end)
          end
        end,
      })
      opts.picker.win = opts.picker.win or {}
      opts.picker.win.input = opts.picker.win.input or {}
      opts.picker.win.list = opts.picker.win.list or {}
      opts.picker.win.input.keys = vim.tbl_deep_extend("force", opts.picker.win.input.keys or {}, {
        ["<C-q>"] = { "pin_sidebar_qflist", mode = { "i", "n" } },
        ["<C-v>"] = { "paste_clipboard", mode = { "i", "n" } },
        ["<Tab>"] = { "list_down", mode = { "i", "n" } },
        ["<S-Tab>"] = { "list_up", mode = { "i", "n" } },
        ["<C-Space>"] = { "select_and_next", mode = { "i", "n" } },
      })
      opts.picker.win.list.keys = vim.tbl_deep_extend("force", opts.picker.win.list.keys or {}, {
        ["<C-q>"] = { "pin_sidebar_qflist", mode = { "n", "x" } },
        ["<C-v>"] = { "paste_clipboard", mode = { "n", "x" } },
        ["<Tab>"] = { "list_down", mode = { "n", "x" } },
        ["<S-Tab>"] = { "list_up", mode = { "n", "x" } },
       ["<C-Space>"] = { "select_and_next", mode = { "n", "x" } },
     })
     return opts
   end,
  },
}
