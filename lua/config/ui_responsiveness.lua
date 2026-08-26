-- config/ui_responsiveness.lua — enforce main-loop headroom invariants.
--
-- WHY THIS FILE EXISTS
-- --------------------
-- P6 ("never block the UI thread") is a repository constraint, and K40/K42 show
-- how it gets violated: not by one obviously slow function, but by cheap work
-- repeated on the main loop until it adds up. Those cases were each found by an
-- expensive investigation and then fixed at their call site. This module holds
-- the fixes that are NOT ours to make at a call site — they are defaults chosen
-- by Neovim core or by a plugin, which we must override deliberately.
--
-- Everything here is backed by a measurement recorded in docs/changelog.md;
-- nothing here is speculative tuning.

local M = {}

-- ---------------------------------------------------------------------------
-- 1. vim.lsp stderr logging: 58,803 synchronous write+flush pairs
-- ---------------------------------------------------------------------------
-- MEASURED (2026-08-25): nvim-data/lsp.log had grown to 16.6 MB containing
-- 58,803 lines, every single one tagged [ERROR].
--
-- Upstream chain in Neovim 0.11.5:
--   vim/lsp/_transport.lua:36  on_stderr -> log.error('rpc', cmd[1], 'stderr', chunk)
--   vim/lsp/log.lua:38         current_log_level = WARN  (so ERROR always passes)
--   vim/lsp/log.lua:145-147    logfile:write(...) followed by logfile:flush()
--
-- So EVERY stderr chunk a language server emits costs, on the main loop:
-- debug.getinfo(2,'Sl') + string.format + a file write + an explicit flush()
-- syscall. clangd with --background-index is extremely chatty on stderr — one
-- "Indexed <file> (72502 symbols, 390906 refs, 2044 files)" line per TU plus
-- "--> $/progress" spam — and none of it is an error at all; it is clangd's
-- ordinary informational output being mislabelled by nvim.
--
-- Measured cost per chunk: 0.045ms typical, up to 0.63ms max, and 0.094ms for
-- the batched multi-line chunks clangd actually sends. Across the observed
-- 58,803 events that is ~2.6s of main-loop time spent writing a log nobody
-- reads — in bursts precisely when clangd indexes, which is when the editor is
-- least able to spare it.
--
-- FIX: set the LSP log level to OFF. Measured cost afterwards: 0.000ms.
-- This is a deliberate policy choice, not a workaround: it is upstream's own
-- supported knob, and we are not patching or shadowing any upstream function.
--
-- TRADE-OFF: server stderr no longer lands in lsp.log. That is acceptable here
-- because this repository already keeps its own structured, level-filtered,
-- rotating log (utils.log, default WARN) which is where our diagnostics live.
-- When a server genuinely misbehaves, raise it for that session with
-- :LspLogLevel debug (installed below) and reproduce — the evidence you need is
-- one command away, instead of being paid for continuously by every keystroke.
local LSP_LOG_DEFAULT = "off"

function M.setup_lsp_logging()
  -- Guard: vim.lsp.set_log_level exists in 0.10+; never hard-fail startup.
  local ok = pcall(function()
    vim.lsp.set_log_level(vim.log.levels.OFF)
  end)

  vim.api.nvim_create_user_command("LspLogLevel", function(args)
    local level = vim.trim(args.args or "")
    if level == "" then
      local current = "?"
      pcall(function()
        current = tostring(vim.lsp.log.get_level())
      end)
      vim.notify(
        ("LSP log level = %s (default %s; raise it only while reproducing a server bug)")
          :format(current, LSP_LOG_DEFAULT),
        vim.log.levels.INFO,
        { title = "lsp" }
      )
      return
    end
    local map = {
      off = vim.log.levels.OFF,
      error = vim.log.levels.ERROR,
      warn = vim.log.levels.WARN,
      info = vim.log.levels.INFO,
      debug = vim.log.levels.DEBUG,
      trace = vim.log.levels.TRACE,
    }
    local value = map[level:lower()]
    if not value then
      vim.notify("unknown level: " .. level .. " (off|error|warn|info|debug|trace)", vim.log.levels.ERROR)
      return
    end
    local set_ok = pcall(function()
      vim.lsp.set_log_level(value)
    end)
    vim.notify(
      set_ok and ("LSP log level -> " .. level:lower() .. "  (" .. vim.lsp.log.get_filename() .. ")")
        or "failed to set LSP log level",
      set_ok and vim.log.levels.INFO or vim.log.levels.ERROR,
      { title = "lsp" }
    )
  end, {
    nargs = "?",
    complete = function()
      return { "off", "error", "warn", "info", "debug", "trace" }
    end,
    desc = "Show/set the vim.lsp log level (default off: server stderr is not an error)",
    force = true,
  })

  return ok
end

-- ---------------------------------------------------------------------------
-- 2. lazy.nvim change_detection: a 2s main-loop poll of the config tree
-- ---------------------------------------------------------------------------
-- MEASURED (2026-08-25), in the live session:
--   * lazy.manage.reloader arms start(2000, 2000) and each tick runs
--     uv.fs_stat over 33 spec module files SYNCHRONOUSLY on the main loop:
--     1.2ms p50 when nothing changed.
--   * When a change IS detected it calls Plugin.load() plus the LazyRender and
--     LazyReload autocmds: 21ms p50 of main-loop time, 18x the idle scan.
--
-- Why this matters beyond its own cost: the recorded stall trains arrive on a
-- ~2s cadence (672 of the inter-arrival gaps were exactly 2s) with no keypress
-- within 0.3s for 8518 of 8643 records. A 2s main-loop timer that stats the
-- filesystem is exactly that shape. It is also shared state: every Neovim
-- watching the same config files reacts inside the same 2s window, which is why
-- two independent PIDs logged stall trains with matching hourly counts.
--
-- FIX: disable change_detection. We are not developing plugins in this repo;
-- config edits are followed by a deliberate restart (:UERestart / utils.restart)
-- because half of this config's behaviour is established at startup order
-- (see CONSTRAINTS C3) and cannot be correctly hot-reloaded anyway. So the
-- feature was paying a continuous main-loop tax for a reload we never want.
--
-- This is configured in config/lazy.lua (the setup call site) rather than here;
-- this comment is the rationale of record, and the assertion below keeps the two
-- from silently drifting apart.
function M.assert_change_detection_disabled()
  local ok, cfg = pcall(require, "lazy.core.config")
  if not ok or type(cfg) ~= "table" or type(cfg.options) ~= "table" then
    return nil
  end
  local cd = cfg.options.change_detection
  local enabled = type(cd) == "table" and cd.enabled ~= false
  if enabled then
    require("utils.log").warn_ctx("perf", "lazy change_detection is enabled", {
      cost = "2s main-loop fs_stat poll; 21ms on detected change",
      expected = "disabled in config/lazy.lua",
    })
  end
  return not enabled
end

function M.setup()
  M.setup_lsp_logging()
  -- Verify after lazy has been configured; a mismatch is logged, never fatal.
  vim.schedule(function()
    pcall(M.assert_change_detection_disabled)
  end)
end

return M
