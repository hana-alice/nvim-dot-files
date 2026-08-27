-- utils.restart — restart Neovim in the current cwd, cross-client.
--
-- "Current cwd" = `vim.fn.getcwd()` of the current tab/window. Picked
-- over "current file's dir" because :cd / :tcd / autochdir intent should
-- be preserved across the restart, and over "project root" because that
-- can surprise you when you've explicitly :tcd'd into a subdir.
--
-- Client detection (in order):
--   1. Neovide   — `vim.g.neovide` is true → spawn `neovide --multigrid <cwd>`
--   2. WezTerm   — `$WEZTERM_PANE` is set  → `wezterm cli spawn --cwd <cwd> -- nvim`
--   3. Fallback  — platform default:
--        Windows  → `cmd /C start "" /D <cwd> nvim`
--        macOS    → `$TERMINAL -e nvim` then `kitty --directory <cwd> nvim`
--        Linux    → `$TERMINAL` else kitty/alacritty/wezterm/foot/xterm
--
-- Why this file is more careful than `os.execute("neovide &")`:
--   * Windows libuv (uv.spawn) does NOT honour PATH/PATHEXT. We must
--     resolve the absolute exe path with `vim.fn.exepath` first.
--   * `cmd /C start` argument ordering is brittle. `start "" /D <dir>
--     <exe> [args...]` is the only form that detaches reliably and
--     respects the working directory.
--   * If the spawn fails we MUST log + notify BEFORE qa, otherwise the
--     user is left with neither old nor new nvim. We log every step
--     to `:NvimLog` (utils.log.scoped("restart")) so post-mortem is
--     possible even when the new process never appeared.
--
-- Public API
-- ----------
--   restart.restart(opts?)  — perform the restart
--     opts = { cwd?: string, dry_run?: bool, force?: bool }
--   restart.detect(cwd?)    — return restart.Plan, no side effects

local M = {}

local uv = vim.uv or vim.loop
local platform = require("utils.platform")

local L
local function log()
  if L then return L end
  local ok, log_mod = pcall(require, "utils.log")
  if ok and log_mod.scoped then
    L = log_mod.scoped("restart")
  else
    -- Stub so call sites don't have to nil-check.
    L = setmetatable({}, { __index = function() return function() end end })
  end
  return L
end

local function executable(bin)
  return vim.fn.executable(bin) == 1
end

-- Resolve a binary name to its absolute exe path. Critical on Windows
-- where uv.spawn does no PATH/PATHEXT lookup. Returns the input if it
-- already looks absolute or if we can't resolve.
local function resolve_exe(name)
  if name:find("[/\\]") and uv.fs_stat(name) then
    return name
  end
  local resolved = vim.fn.exepath(name)
  if resolved and resolved ~= "" then
    return resolved
  end
  return name
end

local function fmt_cmd(cmd, args)
  local out = { tostring(cmd) }
  for _, a in ipairs(args or {}) do out[#out + 1] = tostring(a) end
  return table.concat(out, " ")
end

-- ---------------------------------------------------------------------
-- Spawning
-- ---------------------------------------------------------------------

-- libuv spawn: cleanest detach, but on Windows requires absolute path.
-- Returns ok, err, pid.
--
-- IMPORTANT: returning ok=true from uv.spawn only proves dispatch succeeded.
-- The child may exit code 2 (bad arg) or code 1 (init failure) within
-- microseconds. Callers MUST follow up with verify_alive(pid) before doing
-- anything destructive (like qa-ing the parent).
local function spawn_uv(cmd, args, cwd)
  local exe = resolve_exe(cmd)
  log().debug(string.format("uv.spawn exe=%s cwd=%s args=%s",
    exe, cwd or "(nil)", vim.inspect(args)))

  -- Track early exits via a closure flag so verify_alive can read it.
  local early_exit = nil
  local handle, pid_or_err = uv.spawn(exe, {
    args     = args,
    cwd      = cwd,
    detached = true,
    hide     = false,
    -- Inherit nothing — child gets its own console / GUI surface.
    stdio    = { nil, nil, nil },
  }, function(code, signal)
    early_exit = { code = code, signal = signal }
    log().warn(string.format("uv child exit code=%s signal=%s",
      tostring(code), tostring(signal)))
  end)

  if handle then
    handle:unref()
    log().info(string.format("uv.spawn ok pid=%s exe=%s",
      tostring(pid_or_err), exe))
    return true, nil, pid_or_err, function() return early_exit end
  end
  log().warn(string.format("uv.spawn failed: %s (exe=%s)",
    tostring(pid_or_err), exe))
  return false, pid_or_err
end

-- Verify a spawned child PID is still alive after a grace period. On
-- Windows we can't trust uv.spawn return alone — neovide-with-bad-args
-- exits code 2 in <50ms, looking like a successful spawn from the
-- parent's POV until on_exit fires (which only happens after we've
-- already qa'd ourselves). This blocks the main loop briefly to let the
-- on_exit callback run, then checks the early_exit closure.
--
-- Why vim.wait and not uv.sleep: vim.wait pumps the event loop so the
-- on_exit callback we registered in spawn_uv has a chance to fire.
-- uv.sleep would block but never deliver the callback.
local function verify_alive(pid, get_early_exit, grace_ms)
  grace_ms = grace_ms or 300
  vim.wait(grace_ms, function()
    return get_early_exit and get_early_exit() ~= nil
  end, 20)
  local ee = get_early_exit and get_early_exit()
  if ee then
    return false, string.format(
      "child pid=%s exited within %dms (code=%s signal=%s)",
      tostring(pid), grace_ms, tostring(ee.code), tostring(ee.signal))
  end
  return true
end

-- ---------------------------------------------------------------------
-- Detect (no side effects)
-- ---------------------------------------------------------------------

---@class restart.Plan
---@field client string
---@field cmd    string
---@field args   string[]
---@field cwd    string
---@field reason string

---@return restart.Plan|nil, string?
function M.detect(cwd)
  cwd = cwd or vim.fn.getcwd()

  -- 1. Neovide
  if vim.g.neovide then
    if not executable("neovide") then
      return nil, "Neovide detected but 'neovide' binary not on PATH"
    end
    local exe = resolve_exe("neovide")
    -- DO NOT pass --multigrid: it was removed in neovide >=0.12. Multigrid
    -- is now the default; the only related flag is --no-multigrid which
    -- DISABLES it. Passing the old --multigrid causes neovide to exit
    -- code 2 (clap arg parse error) immediately, which used to look like
    -- "Restart only quits, no new window opens" because uv.spawn / cmd
    -- /C start both report success on dispatch but the child dies
    -- before becoming a window.
    return {
      client = "neovide",
      cmd    = exe,
      args   = { cwd },
      cwd    = cwd,
      reason = "vim.g.neovide is set; resolved to " .. exe,
    }
  end

  -- 2. WezTerm
  if vim.env.WEZTERM_PANE and executable("wezterm") then
    local exe = resolve_exe("wezterm")
    return {
      client = "wezterm",
      cmd    = exe,
      args   = { "cli", "spawn", "--cwd", cwd, "--", "nvim" },
      cwd    = cwd,
      reason = "$WEZTERM_PANE is set; resolved to " .. exe,
    }
  end

  -- 3. Host-owned fallback candidates. The caller only resolves the first
  -- available executable and never branches on host identity.
  local fallback = platform.optional_capability(nil, "restart_fallback_candidates", cwd, vim.env)
  if not fallback.ok then
    return nil, "restart fallback unavailable for current host"
  end
  for _, candidate in ipairs(fallback.value or {}) do
    if executable(candidate.bin) then
      local exe = resolve_exe(candidate.bin)
      local reason = tostring(candidate.reason or (candidate.bin .. " fallback"))
      if reason:find("%%s") then reason = reason:format(exe) end
      return {
        client = candidate.client or "terminal",
        cmd = exe,
        args = candidate.args or {},
        cwd = candidate.cwd or cwd,
        reason = reason,
      }
    end
  end
  return nil, "no host restart fallback executable is available"
end

local function unsaved_count()
  local n = 0
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) and vim.bo[b].modified then
      n = n + 1
    end
  end
  return n
end

-- ---------------------------------------------------------------------
-- Restart (the actual command)
-- ---------------------------------------------------------------------

---@param opts table?  { cwd?, dry_run?, force? }
function M.restart(opts)
  opts = opts or {}
  log().info(string.format("restart requested cwd=%s force=%s dry=%s",
    opts.cwd or vim.fn.getcwd(), tostring(opts.force), tostring(opts.dry_run)))

  local plan, err = M.detect(opts.cwd)
  if not plan then
    log().error("detect failed: " .. tostring(err))
    vim.notify("restart: " .. err, vim.log.levels.ERROR, { title = "restart" })
    return
  end

  log().info(string.format("plan client=%s cmd=%s args=%s cwd=%s reason=%s",
    plan.client, plan.cmd, vim.inspect(plan.args), plan.cwd, plan.reason))

  if opts.dry_run then
    vim.notify(string.format(
      "restart plan:\n  client: %s\n  reason: %s\n  cwd:    %s\n  cmd:    %s",
      plan.client, plan.reason, plan.cwd, fmt_cmd(plan.cmd, plan.args)),
      vim.log.levels.INFO, { title = "restart" })
    return plan
  end

  -- Try uv.spawn first. On Windows GUI clients (neovide), if uv.spawn
  -- fails, fall back to `cmd /C start ...` which is the spell that
  -- has historically worked for detached Windows GUI launches.
  --
  -- ALSO — uv.spawn can "succeed" (handle returned, PID assigned) and
  -- then the child immediately exits a few ms later (e.g. bad args →
  -- exit 2). We verify the child is still alive after a 300ms grace
  -- before committing to qa. If it's dead, fall through to the
  -- cmd-start fallback path so the user keeps their session.
  --
  -- For the cmd /C start fallback we have no PID handle, so we use a
  -- second uv.spawn cycle as a "probe" — spawn one MORE neovide and
  -- verify_alive that one. If even the probe dies, we know args are
  -- bad and refuse to qa.
  local ok, spawn_err, pid, get_early_exit = spawn_uv(plan.cmd, plan.args, plan.cwd)
  if ok then
    local alive, why = verify_alive(pid, get_early_exit, 300)
    if not alive then
      log().warn("uv.spawn child died early: " .. tostring(why))
      ok = false
      spawn_err = why
    end
  end
  local reprobe = platform.optional_capability(nil, "restart_requires_spawn_reprobe")
  if not ok and reprobe.ok and reprobe.value == true then
    log().info("uv.spawn failed/died; host driver requests a strict second probe")
    -- Re-probe the args by uv.spawn-ing once more with strict verify.
    -- If THIS dies too, the args themselves are wrong; cmd /C start
    -- won't fix it (start would just dispatch the same broken args
    -- and we'd lose the user's session for no gain).
    local probe_ok, _, probe_pid, probe_ee = spawn_uv(plan.cmd, plan.args, plan.cwd)
    if probe_ok then
      local alive2 = verify_alive(probe_pid, probe_ee, 300)
      if alive2 then
        ok = true
        spawn_err = nil
      else
        log().warn("probe spawn also died — refusing to qa with broken args")
      end
    end
  end

  if not ok then
    local msg = "restart: spawn failed — " .. tostring(spawn_err or "unknown") ..
                "\n  cmd: " .. fmt_cmd(plan.cmd, plan.args) ..
                "\n  cwd: " .. plan.cwd ..
                "\n  see :NvimLog for the full trace"
    log().error(msg)
    vim.notify(msg, vim.log.levels.ERROR, { title = "restart" })
    return  -- DO NOT qa — we'd leave the user with nothing.
  end

  local n = unsaved_count()
  if n > 0 and not opts.force then
    log().warn(string.format("%d unsaved buffer(s) — confirming before quit", n))
    vim.notify(string.format("restart: %d unsaved — confirming", n),
      vim.log.levels.WARN, { title = "restart" })
  end

  -- Wait long enough for:
  --   * the new process to actually appear (Neovide's splash takes
  --     200–400ms on Windows, after which it has its own message loop)
  --   * any error from spawn to surface (jobstart's on_exit wouldn't
  --     fire instantly anyway)
  --   * the placeholder window to read "Restart in cwd ..." for ≥250ms
  -- Old delay was 50ms which was racing all of the above.
  local delay_capability = platform.optional_capability(nil, "restart_shutdown_delay_ms")
  local delay = delay_capability.ok and tonumber(delay_capability.value) or 400
  log().debug(string.format("scheduling qa in %dms (force=%s)",
    delay, tostring(opts.force)))

  vim.defer_fn(function()
    log().info("issuing " .. (opts.force and "qa!" or "confirm qa"))
    pcall(vim.cmd, opts.force and "qa!" or "confirm qa")
  end, delay)
end

return M
