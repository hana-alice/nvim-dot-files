-- Persistent breakpoints, scoped to the current UE *project* (not engine).
--
-- Storage layout
--   <engine_root>/.cache/nvim-ue/breakpoints/<project_name>.json
--
-- Why per-project (not per-engine):
--   one engine can host multiple game projects; each ships its own gameplay
--   code and accumulates its own breakpoints.  Bucketing by project_name
--   keeps them isolated and avoids a foreign project's stale paths
--   polluting your set when you switch checkouts.
--
-- File format (versioned, future-proof)
--   {
--     "version": 1,
--     "project": "MyGame",
--     "saved_at": "2026-05-13T13:55:00Z",
--     "breakpoints": {
--       "D:/proj/.../Source/X.cpp": [
--         { "line": 42 },
--         { "line": 57, "condition": "i == 3" },
--         { "line": 80, "log_message": "hit i={i}" }
--       ],
--       ...
--     }
--   }
--
-- Save trigger:  toggle_breakpoint / clear_breakpoints / conditional / log
-- Load trigger:  BufReadPost (restore any bp whose key matches the new buf
--                absolute path).  This is lazy on purpose: most UE projects
--                have 50k+ files and we don't want to mass-set bps on every
--                file we never open.
--
-- Pitfalls handled:
--   * Path keys normalized via vim.fs.normalize (forward slashes, no '..').
--     Avoids the classic "D:\foo\bar" vs "D:/foo/bar" mis-match across
--     Windows / Git Bash / WSL.
--   * Save is debounced; rapid F9 toggles don't thrash disk.
--   * Load wraps require('dap.breakpoints').set in pcall — a stale entry
--     pointing at a deleted line should not crash BufReadPost.

local M = {}

local SAVE_DEBOUNCE_MS = 250

local state = {
  loaded = false,         -- did we load this session yet?
  cache_path = nil,       -- absolute path to the json
  data = nil,             -- decoded { version, project, breakpoints = {} }
  pending_paths = {},     -- file -> bp[]  waiting for BufReadPost
  save_timer = nil,
}

local function norm(p)
  if not p or p == "" then return p end
  return vim.fs.normalize(p)
end

local function read_json_file(path)
  local fh = io.open(path, "r")
  if not fh then return nil end
  local raw = fh:read("*a")
  fh:close()
  if not raw or raw == "" then return nil end
  local ok, decoded = pcall(vim.json.decode, raw)
  if not ok then return nil end
  return decoded
end

local function write_json_file(path, tbl)
  local dir = vim.fs.dirname(path)
  vim.fn.mkdir(dir, "p")
  local raw = vim.json.encode(tbl)
  local fh, err = io.open(path, "w")
  if not fh then return false, err end
  fh:write(raw)
  fh:close()
  return true
end

-- Resolve <cache_path, project_name> from current ctx.
-- Returns nil if we're not in a UE workspace (no engine_root) — in that
-- case persistence silently degrades to "no save / no load", same UX as
-- vanilla nvim-dap.
local function resolve_cache_path()
  local ok_ue, ue = pcall(require, "ue")
  if not ok_ue then return nil end
  local ok_ctx, ctx = pcall(ue.resolve_context, {})
  if not ok_ctx or not ctx then return nil end
  if not ctx.engine_root or ctx.engine_root == "" then return nil end
  -- project_name: prefer ctx.uproject basename (without .uproject); else
  -- project_root basename; else literal "default".
  local project_name
  if ctx.uproject and ctx.uproject ~= "" then
    project_name = vim.fs.basename(ctx.uproject):gsub("%.uproject$", "")
  elseif ctx.project_root and ctx.project_root ~= "" then
    project_name = vim.fs.basename(ctx.project_root)
  else
    project_name = "default"
  end
  -- sanitize: filename-safe
  project_name = project_name:gsub("[^%w%._%-]", "_")
  local cache = norm(ctx.engine_root) .. "/.cache/nvim-ue/breakpoints/" .. project_name .. ".json"
  return cache, project_name
end

-- ── load on session start ────────────────────────────────────────────────
function M.load()
  if state.loaded then return end
  state.loaded = true
  local cache, project_name = resolve_cache_path()
  if not cache then return end
  state.cache_path = cache
  local data = read_json_file(cache) or {
    version = 1, project = project_name, breakpoints = {},
  }
  if type(data.breakpoints) ~= "table" then data.breakpoints = {} end
  state.data = data
  -- Stage every entry for lazy restore on BufReadPost.
  for path, bps in pairs(data.breakpoints) do
    state.pending_paths[norm(path)] = bps
  end
  -- Also try restoring into already-open buffers (e.g. user did
  -- :luafile after editing files).  Important for our hot-reload flow.
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      M.restore_for_buf(bufnr)
    end
  end
end

-- ── restore for one buffer ───────────────────────────────────────────────
function M.restore_for_buf(bufnr)
  if not state.data then return end
  local name = vim.api.nvim_buf_get_name(bufnr)
  if not name or name == "" then return end
  local key = norm(name)
  local bps = state.pending_paths[key]
  if not bps or #bps == 0 then return end
  local ok_dapbp, dapbp = pcall(require, "dap.breakpoints")
  if not ok_dapbp then return end
  for _, bp in ipairs(bps) do
    pcall(dapbp.set, {
      condition    = bp.condition,
      hit_condition = bp.hit_condition,
      log_message  = bp.log_message,
    }, bufnr, bp.line)
  end
  -- Once restored, drop from pending so we don't double-set on reload.
  state.pending_paths[key] = nil
  -- If a session is already running, push the freshly-restored breakpoints to
  -- the adapter so they arm live (no reattach needed). nvim-dap's
  -- session:set_breakpoints reads the current dap.breakpoints store for the
  -- given bufnr, so we pass the bufnr keyed to its real breakpoint list rather
  -- than an empty table (the previous `{ [bufnr] = nil }` was a silent no-op).
  local ok_dap, dap = pcall(require, "dap")
  if ok_dap and dap.session() then
    pcall(function()
      local cur = dapbp.get(bufnr)
      local list = cur and cur[bufnr] or {}
      dap.session():set_breakpoints({ [bufnr] = list })
    end)
  end
end

-- ── snapshot current bps and persist ─────────────────────────────────────
function M.save()
  if not state.cache_path then
    -- First save in this session may run before load() (e.g. user toggles
    -- in a pristine nvim).  Resolve lazily.
    local cache, project_name = resolve_cache_path()
    if not cache then return end
    state.cache_path = cache
    state.data = state.data or {
      version = 1, project = project_name, breakpoints = {},
    }
  end
  local ok_dapbp, dapbp = pcall(require, "dap.breakpoints")
  if not ok_dapbp then return end
  -- dap.breakpoints.get() -> { [bufnr] = { { line, condition?, ... }, ... } }
  local raw = dapbp.get()
  local out = {}
  for bufnr, bps in pairs(raw) do
    local name = vim.api.nvim_buf_get_name(bufnr)
    if name and name ~= "" then
      local key = norm(name)
      local list = {}
      for _, bp in ipairs(bps) do
        local entry = { line = bp.line }
        if bp.condition and bp.condition ~= "" then entry.condition = bp.condition end
        if bp.hitCondition and bp.hitCondition ~= "" then entry.hit_condition = bp.hitCondition end
        if bp.logMessage and bp.logMessage ~= "" then entry.log_message = bp.logMessage end
        table.insert(list, entry)
      end
      if #list > 0 then out[key] = list end
    end
  end
  -- Merge with pending_paths (bps for files not yet opened this session).
  -- Without this merge, opening one file and then saving would erase every
  -- bp for files we haven't opened — disaster.
  for k, v in pairs(state.pending_paths) do
    if not out[k] then out[k] = v end
  end
  state.data.breakpoints = out
  state.data.saved_at = os.date("!%Y-%m-%dT%H:%M:%SZ")
  pcall(write_json_file, state.cache_path, state.data)
end

function M.save_debounced()
  if state.save_timer then state.save_timer:stop() end
  state.save_timer = vim.defer_fn(function()
    state.save_timer = nil
    M.save()
  end, SAVE_DEBOUNCE_MS)
end

-- ── public toggles / clears (replace dap.toggle_breakpoint at call site) ──
function M.toggle()
  M.load()
  local ok, dap = pcall(require, "dap")
  if not ok then return end
  dap.toggle_breakpoint()
  M.save_debounced()
end

function M.toggle_conditional()
  M.load()
  local ok, dap = pcall(require, "dap")
  if not ok then return end
  vim.ui.input({ prompt = "Breakpoint condition: " }, function(cond)
    if not cond then return end
    dap.set_breakpoint(cond)
    M.save_debounced()
  end)
end

function M.toggle_logpoint()
  M.load()
  local ok, dap = pcall(require, "dap")
  if not ok then return end
  vim.ui.input({ prompt = "Log message (use {expr}): " }, function(msg)
    if not msg then return end
    dap.set_breakpoint(nil, nil, msg)
    M.save_debounced()
  end)
end

function M.clear_all()
  M.load()
  local ok, dap = pcall(require, "dap")
  if not ok then return end
  dap.clear_breakpoints()
  -- Also wipe persisted state for files we haven't opened.
  state.pending_paths = {}
  M.save_debounced()
end

function M.list()
  M.load()
  local lines = {}
  if not state.data then
    print("[ue.dap.bp] no project context")
    return
  end
  local total = 0
  for path, bps in pairs(state.data.breakpoints or {}) do
    for _, bp in ipairs(bps) do
      total = total + 1
      local extra = {}
      if bp.condition then table.insert(extra, "if=" .. bp.condition) end
      if bp.hit_condition then table.insert(extra, "hit=" .. bp.hit_condition) end
      if bp.log_message then table.insert(extra, "log=" .. bp.log_message) end
      table.insert(lines, string.format("%s:%d  %s", path, bp.line,
        #extra > 0 and ("[" .. table.concat(extra, " ") .. "]") or ""))
    end
  end
  table.sort(lines)
  print(string.format("== %d persisted breakpoint(s) for project '%s' ==",
    total, state.data.project or "?"))
  for _, l in ipairs(lines) do print("  " .. l) end
  if state.cache_path then print("file: " .. state.cache_path) end
end

-- ── autocmd glue ─────────────────────────────────────────────────────────
function M.setup()
  local g = vim.api.nvim_create_augroup("ue_dap_persist_bp", { clear = true })
  -- Restore when a buffer is read or entered (covers :e and lazy-loaded
  -- buffers picked up via splits / buffer cycling).
  vim.api.nvim_create_autocmd({ "BufReadPost", "BufNewFile" }, {
    group = g,
    callback = function(args)
      M.load()
      M.restore_for_buf(args.buf)
    end,
  })
  -- Re-save on exit so we never miss the last toggle if debounce fires
  -- after VimLeavePre.
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = g,
    callback = function()
      if state.save_timer then state.save_timer:stop() end
      M.save()
    end,
  })
  -- Initial load.
  M.load()
end

return M
