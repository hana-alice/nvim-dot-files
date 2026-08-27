local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
local health_no_mutate = vim.env.NVIM_CORE_HEALTH_NO_MUTATE == "1"
if not (vim.uv or vim.loop).fs_stat(lazypath) then
  local lazyrepo = "https://github.com/folke/lazy.nvim.git"
  local out = vim.fn.system({ "git", "clone", "--filter=blob:none", "--branch=stable", lazyrepo, lazypath })
  if vim.v.shell_error ~= 0 then
    vim.api.nvim_echo({
      { "Failed to clone lazy.nvim:\n", "ErrorMsg" },
      { out, "WarningMsg" },
      { "\nPress any key to exit..." },
    }, true, {})
    vim.fn.getchar()
    os.exit(1)
  end
end
vim.opt.rtp:prepend(lazypath)

require("lazy").setup({
  spec = {
    -- add LazyVim and import its plugins
    { "LazyVim/LazyVim", import = "lazyvim.plugins" },
    -- import/override with your plugins
    { import = "plugins" },
  },
  defaults = {
    -- By default, only LazyVim plugins will be lazy-loaded. Your custom plugins will load during startup.
    -- If you know what you're doing, you can set this to `true` to have all your custom plugins lazy-loaded by default.
    lazy = false,
    -- It's recommended to leave version=false for now, since a lot the plugin that support versioning,
    -- have outdated releases, which may break your Neovim install.
    version = false, -- always use the latest git commit
    -- version = "*", -- try installing the latest stable version for plugins that support semver
  },
  install = {
    missing = not health_no_mutate,
    colorscheme = { "monokai_ristretto", "habamax" },
  },
  checker = {
    enabled = not health_no_mutate, -- health startup probes must remain read-only
    notify = false,
    frequency = 86400, -- check at most once a day (was: every hour)
  },
  change_detection = {
    -- Disabled deliberately (2026-08-25, measured). lazy.manage.reloader arms a
    -- 2000ms/2000ms timer that runs uv.fs_stat over all 33 spec module files
    -- SYNCHRONOUSLY on the main loop (1.2ms p50 idle), and pays 21ms p50 when it
    -- detects a change (Plugin.load + LazyRender/LazyReload autocmds).
    --
    -- The recorded stall trains have exactly this shape: ~2s cadence, no
    -- keypress, and matching hourly counts across two independent Neovim PIDs
    -- (they watch the SAME files, so they react in the same 2s window).
    --
    -- We never want the reload anyway: this config establishes much of its
    -- behaviour through startup ORDER (CONSTRAINTS C3), which hot-reload cannot
    -- reproduce, so config edits are followed by a deliberate restart.
    -- Rationale of record: lua/config/ui_responsiveness.lua.
    enabled = false,
    notify = false, -- silence "config reloaded" toasts
  },
  -- This config has no LuaRocks-backed plugins. Disable the unused provider
  -- instead of provisioning a second Lua runtime through hererocks.
  rocks = {
    enabled = false,
  },
  performance = {
    rtp = {
      -- disable some rtp plugins
      disabled_plugins = {
        "gzip",
        -- "matchit",
        -- "matchparen",
        "netrwPlugin",
        "netrwSettings",
        "netrwFileHandlers",
        "tarPlugin",
        "tohtml",
        "tutor",
        "zipPlugin",
        -- additional unused on UE/Win workflow:
        "rplugin",     -- python/ruby remote plugins (not used)
        "spellfile",   -- spell file downloader (we use offline dict if any)
        "man",         -- :Man pager (not used on Windows)
        -- NOTE: do NOT disable "shada" — it's needed for ' marks, / history,
        -- : history, and last-cursor-position (g`")
      },
    },
  },
})
