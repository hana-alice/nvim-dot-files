# Instant Goto-Definition Architecture (Tier 1 + Tier 3)

> **For Hermes:** Use subagent-driven-development skill to implement this plan
> task-by-task. The implementer should know nothing about clangd internals
> beyond what's in this doc.

**Goal:** Make `gd` in huge UE TUs (NaniteCullRaster.cpp 7363 lines, etc.)
respond in < 200ms instead of 30-60s, by routing through clangd
`workspace/symbol` (which doesn't need the current TU's AST) before falling
back to `textDocument/definition` (which does).

**Architecture:**
1. **Tier 1 — Instant routing in `lsp_fallback.lua`:** Rewrite `M.definition()`
   so that `workspace/symbol` (fuzzy global index, no AST dependency) and
   `textDocument/definition` (precise but blocks on AST) and GTAGS run in
   parallel. Whichever returns first with a confident match wins; the precise
   path runs in background and posts a "precise definition is at X" hint if it
   disagrees.
2. **Tier 3 — Preheat:** A new module `lua/utils/lsp_preheat.lua` that on
   project entry calls `didOpen` on a configurable list of hot TUs so clangd
   builds their preamble + AST in the background before the user touches them.
   ASTCache (hardcoded 3 slots) keeps them resident.

**Tech Stack:**
- Neovim 0.10+ (vim.lsp.Client API)
- clangd 17+ (workspace/symbol behavior)
- snacks.nvim notifier
- Lua 5.1 (luajit)

**Non-goals:**
- Tier 2 (post-jump precision patching UI) — deferred until Tier 1 measured
- Tier 4 (clangd-indexer static merged index) — deferred
- Touching `M.references()` / `M.implementation()` — only `M.definition()`
- Replacing GTAGS — it remains as final fallback

---

## Background: Why this works

clangd's `textDocument/definition` is hard-wired in `XRefs.cpp::locateSymbolAt`
to require a `ParsedAST`. Cold preamble for NaniteCullRaster.cpp = 30-60s.

clangd's `workspace/symbol` is hard-wired to use `SymbolIndex::fuzzyFind` only
— **no AST involved**. Hot path < 50ms even on UE-scale projects.

The Rider/CLion architecture works the same way: lexer takes the identifier,
global symbol cache returns candidates, AST is consulted only for
disambiguation.

We replicate that in `lsp_fallback.lua` while keeping all the existing
cleanup, ranking, GTAGS, and shader-file handling.

---

## Decisions baked in (no need to re-debate)

1. **Exact name match required.** `workspace/symbol` returns fuzzy results.
   We discard any candidate whose `name` field doesn't equal the cursor
   identifier exactly. This is correct for `gd` semantics.
2. **The precise path still runs.** We don't replace `textDocument/definition`,
   we race it. If precise disagrees with instant, we surface a single line of
   notice (no popup, no quickfix re-open). User can press `<leader>gP` to
   "go to precise" if they want.
3. **Reuse `rerank_locations` and `clear_winner`** for tie-breaking among
   workspace/symbol candidates — same logic as today.
4. **Preheat is opt-in via config table.** No autodetection of "hot TUs"
   in v1. User edits a list. `:UEPreheat` / `:UEPreheatStatus` commands.
5. **Preheat triggers on `LspAttach` of clangd**, not on `VimEnter`, so the
   server is actually ready when we send `didOpen`s.
6. **Preheat opens TUs as scratch buffers** that are immediately wiped from
   the buffer list (`bufhidden=wipe`, `buflisted=false`) — clangd still gets
   `didOpen` and starts AST work, but no UI clutter.
7. **`<Esc>` cancel keymap is dropped** for now (the spinner's own UI from
   the parked stash) — too risky as an override. We'll add a real
   `:UECancelDef` command instead.

---

## Validation Checkpoints (run before/during implementation)

**Before Task 1 — verify hypothesis is real:**
Run `scripts/verify_workspace_symbol_no_ast.lua` (Task 0 below) to confirm
that on a freshly opened cold NaniteCullRaster.cpp, `workspace/symbol` returns
within ~50ms while `textDocument/definition` blocks for 30s+.

**After Task 5 — measure the win:**
Open NaniteCullRaster.cpp cold, press `gd` on `Translate`, expect notice
within < 200ms reading `✓ instant: Translate → SomeFile.h:NN`.

**After Task 8 — preheat sanity:**
With preheat list `{ "NaniteCullRaster.cpp" }`, after `:UEPreheat`, wait 60s,
then open NaniteCullRaster.cpp manually and press `gd` — expect classic
LSP precise path to return in < 1s (AST already cached).

---

## Task 0: Verify workspace/symbol bypasses AST (no code, only confidence)

**Objective:** Prove the hypothesis before writing any production code.

**Files:** Create `scripts/verify_workspace_symbol_no_ast.lua`

```lua
-- Run with: nvim NaniteCullRaster.cpp -c 'luafile scripts/verify_workspace_symbol_no_ast.lua'
-- IMPORTANT: clangd must be cold for this TU (no .cache hit will still warm).
-- The point is to compare ws/symbol response time vs textDocument/definition
-- response time, NOT absolute speed.
local sym = "AddDefaulted_GetRef"
local clients = vim.lsp.get_clients({ bufnr = 0, name = "clangd" })
if vim.tbl_isempty(clients) then
  vim.notify("[verify] no clangd attached", vim.log.levels.ERROR); return
end
local c = clients[1]
local function now_ms() return vim.loop.hrtime() / 1e6 end

local t_ws = now_ms()
c:request("workspace/symbol", { query = sym }, function(err, result)
  vim.notify(string.format("[verify] ws/symbol: %d results in %.0f ms (err=%s)",
    result and #result or 0, now_ms() - t_ws, tostring(err)), vim.log.levels.INFO)
end)

local pos = vim.lsp.util.make_position_params(0, c.offset_encoding or "utf-16")
local t_def = now_ms()
c:request("textDocument/definition", pos, function(err, result)
  vim.notify(string.format("[verify] td/definition: %d results in %.0f ms (err=%s)",
    result and (vim.islist(result) and #result or 1) or 0, now_ms() - t_def, tostring(err)),
    vim.log.levels.INFO)
end)
```

**Step 1: Open NaniteCullRaster.cpp cold (close any existing nvim with UE
attached first, kill any stray clangd: `pkill -f clangd`).**

**Step 2: Place cursor on `AddDefaulted_GetRef` somewhere around line 5367.**

**Step 3: `:luafile scripts/verify_workspace_symbol_no_ast.lua`**

**Expected:**
- ws/symbol responds within 50-500ms with 1-50 results.
- td/definition either responds in 30-60s OR times out / blocks the watchdog.

**If ws/symbol does NOT respond fast** (e.g. > 5s), then clangd is in some
unexpected state and the entire plan must be revised. STOP and report back.

**Step 4: Commit (script only, no production code yet)**

```bash
git add scripts/verify_workspace_symbol_no_ast.lua
git commit -m "tools: add workspace/symbol vs definition timing probe"
```

---

## Task 1: Add `async_lsp_workspace_symbol` helper

**Objective:** A reusable async caller for `workspace/symbol` that filters to
exact-name matches and returns Location-shaped results.

**File:** Modify `lua/utils/lsp_fallback.lua` — add new helper near
`async_lsp_definition_with_retry` (around line 357).

**Code to add (insert before `async_lsp_definition_with_retry`):**

```lua
-- ---------------------------------------------------------------------------
-- workspace/symbol path: AST-free, fast, fuzzy. We filter to exact name
-- match because gd semantics require it.
-- ---------------------------------------------------------------------------

-- SymbolInformation.kind values we want for goto-definition.
-- Filter out things like Module/File/Namespace which can't be a "definition".
local DEFINITION_KINDS = {
  [5] = true,   -- Class
  [6] = true,   -- Method
  [7] = true,   -- Property
  [8] = true,   -- Field
  [9] = true,   -- Constructor
  [10] = true,  -- Enum
  [11] = true,  -- Interface
  [12] = true,  -- Function
  [13] = true,  -- Variable
  [14] = true,  -- Constant
  [22] = true,  -- Struct
  [23] = true,  -- Event
  [24] = true,  -- Operator
  [25] = true,  -- TypeParameter
}

-- async_lsp_workspace_symbol(bufnr, query, exact, on_result):
--   Sends workspace/symbol to all clients on bufnr.
--   Calls on_result(locations|nil) once when all clients have replied
--   (or after 5s, whichever first).
--   When `exact` is true, filters results whose .name ~= query.
local function async_lsp_workspace_symbol(bufnr, query, exact, on_result)
  local clients = vim.lsp.get_clients({ bufnr = bufnr, method = "workspace/symbol" })
  if #clients == 0 then on_result(nil); return end

  local pending = #clients
  local merged = {}
  local fired = false
  local function fire(arg)
    if fired then return end
    fired = true
    on_result(arg)
  end

  -- Hard 5s ceiling — workspace/symbol should be < 200ms; if it's slower
  -- something is wrong (e.g. clangd is rebuilding its symbol DB) and we'd
  -- rather let the precise path / GTAGS take over.
  vim.defer_fn(function() fire(#merged > 0 and merged or nil) end, 5000)

  for _, client in ipairs(clients) do
    client:request("workspace/symbol", { query = query }, function(err, result)
      pending = pending - 1
      if not err and type(result) == "table" then
        for _, sym in ipairs(result) do
          local keep = true
          if exact and sym.name ~= query then keep = false end
          if keep and sym.kind and not DEFINITION_KINDS[sym.kind] then keep = false end
          if keep and sym.location then
            -- normalize SymbolInformation -> Location
            table.insert(merged, {
              uri = sym.location.uri,
              range = sym.location.range,
              -- carry kind for later ranking
              _ws_kind = sym.kind,
              _ws_container = sym.containerName,
            })
          end
        end
      end
      if pending == 0 then fire(#merged > 0 and merged or nil) end
    end, bufnr)
  end
end
```

**Step 1: Insert the code.**

**Step 2: Syntax check.**

```bash
luac -p /mnt/c/Users/hana-alice/AppData/Local/nvim/lua/utils/lsp_fallback.lua
```
Expected: no output (success).

**Step 3: Commit.**

```bash
git add lua/utils/lsp_fallback.lua
git commit -m "feat(lsp_fallback): add async_lsp_workspace_symbol helper

Filters by exact name + LSP SymbolKind suitable for definition.
Hard 5s ceiling. Used by upcoming racing definition router."
```

---

## Task 2: Add config knobs at top of file

**Objective:** Tunable instant-path behavior without editing inline magic
numbers later.

**File:** Modify `lua/utils/lsp_fallback.lua` near existing config constants
(around line 27).

**Code to add (after `local PROGRESS_TICK_INTERVAL_MS` line ~36):**

```lua
-- Instant path config ---------------------------------------------------
-- The instant path uses workspace/symbol (no AST required). If it returns
-- a single high-confidence match within INSTANT_DEADLINE_MS, we jump
-- immediately and skip the AST-bound path.
local INSTANT_DEADLINE_MS = 400      -- give ws/symbol up to 400ms before
                                     -- letting precise path take over UI
local INSTANT_MAX_CANDIDATES = 50    -- if more than this match by name,
                                     -- bail (almost certainly the wrong
                                     -- query, e.g. cursor on `int`)
-- When set, after instant jump we still run the precise path; if it
-- returns a different location we surface a small notice.
local INSTANT_PRECISE_RECONCILE = true
```

**Step 1: Insert.**

**Step 2: `luac -p`** — expect success.

**Step 3: Commit.**

```bash
git add lua/utils/lsp_fallback.lua
git commit -m "feat(lsp_fallback): add instant-path config constants"
```

---

## Task 3: Extract `pick_winner_with_label` from M.definition

**Objective:** Pull the "rerank → clear_winner → jump_to_location → loc_label"
sequence out into a reusable helper, since both instant and precise paths
need it.

**File:** Modify `lua/utils/lsp_fallback.lua` — insert near `try_jump`
(around line 449).

**Code to add:**

```lua
-- pick_winner_with_label(locs, platform_hints, ref_file):
--   Reranks, picks a clear winner, returns winner_loc + short label string
--   suitable for the success notice ("FooFile.h:42"). Returns nil,nil if no
--   clear winner (caller should populate quickfix instead).
local function pick_winner_with_label(locs, platform_hints, ref_file)
  if not locs or #locs == 0 then return nil, nil end
  local ranked = rerank_locations(locs, platform_hints, ref_file)
  local winner = clear_winner(ranked, platform_hints, ref_file)
  if not winner then return nil, ranked end

  local p = location_path(winner)
  local short = (p ~= "" and (p:match("([^/\\]+)$") or p)) or "?"
  local lnum
  if winner.range and winner.range.start then
    lnum = winner.range.start.line + 1
  elseif winner.targetSelectionRange and winner.targetSelectionRange.start then
    lnum = winner.targetSelectionRange.start.line + 1
  end
  local label = lnum and string.format("%s:%d", short, lnum) or short
  return winner, label, ranked
end
```

**Step 1: Insert.**

**Step 2: Smoke-test by `luac -p`.**

**Step 3: Commit.**

```bash
git add lua/utils/lsp_fallback.lua
git commit -m "refactor(lsp_fallback): extract pick_winner_with_label helper"
```

---

## Task 4: Rewrite M.definition to race instant + precise + GTAGS

**Objective:** Replace the body of `M.definition()` with the three-track
racing implementation.

**File:** Modify `lua/utils/lsp_fallback.lua` — full replacement of
`function M.definition()` body (lines 581-738 currently).

**Code (replace entire `function M.definition() ... end`):**

```lua
function M.definition()
  local symbol = current_symbol()
  local bufnr = vim.api.nvim_get_current_buf()
  local ref_file = normalize_path(vim.api.nvim_buf_get_name(bufnr))
  local ref_line = vim.api.nvim_win_get_cursor(0)[1]

  request_token = request_token + 1
  local my_token = request_token
  local function still_current() return my_token == request_token end

  -- Three independent tracks; whichever produces a usable jump first wins.
  local jumped = false   -- some track has navigated the cursor
  local resolved = false -- terminal state, no more notices, no more work
  local notice = nil

  local function clear_notice()
    if notice then pcall(notice.clear); notice = nil end
  end
  local function done(success_msg, lifetime_ms)
    resolved = true
    if success_msg and notice then
      pcall(notice.finish, success_msg, lifetime_ms or 3000); notice = nil
    else
      clear_notice()
    end
  end

  -- Resolve platform hints once.
  local platform_hints = nil
  do
    local ok, ue = pcall(require, "ue")
    if ok and ue.platform_path_priorities then
      platform_hints = ue.platform_path_priorities()
    end
  end

  -- Shader files: still GTAGS-only, same as before.
  local ext = buf_extension(bufnr)
  if SHADER_EXTS[ext] then
    gtags_fallback_async(symbol, function(ok)
      if not still_current() then return end
      done()
      if not ok then
        vim.notify("No definition (GTAGS empty): " .. (symbol or "?"), vim.log.levels.INFO)
      end
    end)
    return
  end

  local has_def_client = #vim.lsp.get_clients({ bufnr = bufnr, method = "textDocument/definition" }) > 0
  local has_ws_client  = #vim.lsp.get_clients({ bufnr = bufnr, method = "workspace/symbol" }) > 0

  if not has_def_client and not has_ws_client then
    gtags_fallback_async(symbol, function(ok)
      if not still_current() then return end
      done()
      if not ok then
        vim.notify("No definition (no LSP, GTAGS empty): " .. (symbol or "?"), vim.log.levels.INFO)
      end
    end)
    return
  end

  -- Progress notice, identical timing to current behavior.
  vim.defer_fn(function()
    if not still_current() or resolved then return end
    notice = progress_notice(string.format(
      "⏳ resolving %s ... (instant index path racing precise AST path)",
      symbol or "?"
    ))
  end, LSP_PROGRESS_NOTICE_MS)

  vim.defer_fn(function()
    if not still_current() or resolved then return end
    done()
    vim.notify(string.format("Definition lookup timed out after %ds (%s)",
      math.floor(OVERALL_TIMEOUT_MS / 1000), symbol or "?"), vim.log.levels.WARN)
  end, OVERALL_TIMEOUT_MS)

  -- ---- Track 1: instant via workspace/symbol -----------------------------
  local instant_done = false
  local instant_winner = nil
  if has_ws_client and symbol and symbol ~= "" then
    async_lsp_workspace_symbol(bufnr, symbol, true, function(ws_locs)
      if not still_current() or resolved then return end
      instant_done = true
      if not ws_locs or #ws_locs == 0 then return end
      if #ws_locs > INSTANT_MAX_CANDIDATES then return end
      ws_locs = filter_self_locations(ws_locs, ref_file, ref_line)
      if not ws_locs or #ws_locs == 0 then return end

      local winner, label = pick_winner_with_label(ws_locs, platform_hints, ref_file)
      if not winner then return end -- ambiguous, let precise path handle

      -- Jump now.
      if not jumped then
        local ok = jump_to_location(winner)
        if ok then
          jumped = true
          instant_winner = winner
          done(string.format("⚡ %s → %s (instant)", symbol or "?", label or "?"), 3000)
          if not INSTANT_PRECISE_RECONCILE then resolved = true end
          -- NOTE: we do NOT set resolved=true here when reconcile is on,
          -- so the precise track keeps running and can post a hint if it
          -- disagrees. But we set jumped=true so the precise track won't
          -- re-jump.
        end
      end
    end)
  end

  -- ---- Track 2: precise via textDocument/definition (+impl/+decl) --------
  if has_def_client then
    async_lsp_definition_with_retry(bufnr, ref_file, ref_line, still_current, function(locs)
      if not still_current() then return end

      if locs and #locs > 0 then
        local winner, label, ranked = pick_winner_with_label(locs, platform_hints, ref_file)
        if not jumped then
          -- precise won the race
          if winner then
            local ok = jump_to_location(winner)
            if ok then
              jumped = true
              done(string.format("✓ %s → %s (precise)", symbol or "?", label or "?"), 3000)
              return
            end
          end
          -- multi-candidate / no clear winner → quickfix
          local outcome = try_jump(ranked or locs, "LSP definitions")
          if outcome == true or outcome == "open_failed" then
            local first = (ranked or locs)[1]
            local _, lab2 = pick_winner_with_label({ first }, platform_hints, ref_file)
            jumped = true
            done(string.format("✓ %s → %s (%d candidates)", symbol or "?",
              lab2 or "?", #(ranked or locs)), 3000)
            return
          end
        else
          -- instant already jumped. Reconcile.
          if INSTANT_PRECISE_RECONCILE and winner and instant_winner then
            local same = location_key(winner) == location_key(instant_winner)
            if not same then
              -- post a single non-spammy hint
              vim.notify(string.format(
                "ℹ precise definition differs: %s (press <leader>gP to switch)",
                label or "?"
              ), vim.log.levels.INFO)
              -- stash the precise winner for <leader>gP
              M._last_precise_winner = winner
            end
          end
          done() -- clear spinner, instant message already shown
          return
        end
      end

      -- LSP precise gave nothing. If instant already jumped, we're fine.
      if jumped then done(); return end

      -- Otherwise fall through to GTAGS.
      gtags_fallback_async(symbol, function(jumped_g)
        if not still_current() or resolved then return end
        if jumped_g then
          jumped = true
          done(string.format("✓ %s (GTAGS fallback)", symbol or "?"), 3000)
        else
          done()
          vim.notify("No definition (LSP and GTAGS both empty): " .. (symbol or "?"),
            vim.log.levels.INFO)
        end
      end)
    end)
  elseif not has_ws_client then
    -- Only ws_client but it's done (above branch handles it). Nothing to do.
  else
    -- ws_client only, no def_client. Wait for instant track + GTAGS fallback.
    vim.defer_fn(function()
      if not still_current() or resolved or jumped then return end
      gtags_fallback_async(symbol, function(jumped_g)
        if not still_current() or resolved then return end
        if jumped_g then
          jumped = true
          done(string.format("✓ %s (GTAGS fallback)", symbol or "?"), 3000)
        else
          done()
          vim.notify("No definition: " .. (symbol or "?"), vim.log.levels.INFO)
        end
      end)
    end, INSTANT_DEADLINE_MS + 100)
  end
end

-- Jump to the precise definition stored by the last reconcile.
function M.jump_to_precise()
  local w = M._last_precise_winner
  if not w then
    vim.notify("No precise winner recorded yet", vim.log.levels.WARN)
    return
  end
  jump_to_location(w)
  M._last_precise_winner = nil
end
```

**Step 1: Replace the function.** Use `patch` for surgical replacement of
the existing `function M.definition() ... end` block (lines 581-738).

**Step 2: `luac -p`** — must pass.

**Step 3: Open existing reference user (config/keymaps.lua) and add the
`<leader>gP` binding:**

```lua
vim.keymap.set("n", "<leader>gP", function()
  require("utils.lsp_fallback").jump_to_precise()
end, { desc = "Jump to precise definition (after instant jump)" })
```

**Step 4: `luac -p` keymaps.lua.**

**Step 5: Commit.**

```bash
git add lua/utils/lsp_fallback.lua lua/config/keymaps.lua
git commit -m "feat(lsp_fallback): race instant ws/symbol vs precise definition

- workspace/symbol path returns < 200ms (no AST dependency)
- textDocument/definition still runs precisely in background
- if precise disagrees, post hint + offer <leader>gP to switch
- preserves existing GTAGS fallback, shader-file path, ranking, dedup"
```

---

## Task 5: Live verification of Tier 1

**Objective:** Confirm Tier 1 actually works on the user's setup before
moving to preheat.

**Step 1: User opens NaniteCullRaster.cpp cold** (`pkill -f clangd` first).

**Step 2: Cursor on `Translate` line ~5368, press `gd`.**

**Expected:**
- Within 600ms: spinner appears.
- Within ~500ms (often before spinner): cursor jumps to a `Translate`
  definition with notice `⚡ Translate → SomeFile.h:NN (instant)`.
- 30-60s later: either silent (instant matched precise) or hint
  `ℹ precise definition differs: OtherFile.cpp:MM (press <leader>gP to switch)`.

**Step 3: Cursor on `AddDefaulted_GetRef` line ~5367, press `gd`.**

**Expected:** Same pattern — instant jump < 500ms.

**If instant path picks the wrong overload** consistently, tune
`INSTANT_PRECISE_RECONCILE = true` semantics or revisit the
`pick_winner_with_label` ranking. Document the case in this plan and patch
the skill `clangd-pch-precompile` if relevant.

**Step 4: Acknowledge in commit history that Tier 1 is verified working.**

---

## Task 6: New module `lua/utils/lsp_preheat.lua`

**Objective:** A standalone preheat module that opens hot TUs as hidden
buffers so clangd builds their AST in the background.

**File:** Create `lua/utils/lsp_preheat.lua`.

**Code:**

```lua
-- Preheats clangd by sending didOpen for a configured list of hot TUs.
-- This builds preamble + AST in the ASTCache (3 slots) so when the user
-- actually opens these files, gd is on the hot path (~800ms) instead of
-- the cold path (30-60s).
--
-- Usage:
--   require("utils.lsp_preheat").setup({
--     enabled = true,
--     -- absolute paths or globs relative to cwd
--     files = {
--       "Engine/Source/Runtime/Renderer/Private/Nanite/NaniteCullRaster.cpp",
--       "Engine/Source/Runtime/Renderer/Private/PostProcess/PostProcessing.cpp",
--     },
--     -- only preheat in projects whose root contains this marker
--     project_marker = "compile_commands.json",
--     -- delay after clangd LspAttach before starting preheat (ms)
--     attach_delay_ms = 5000,
--     -- between successive didOpens (avoid stampeding clangd workers)
--     stagger_ms = 8000,
--   })
local M = {}

local cfg = {
  enabled = false,
  files = {},
  project_marker = "compile_commands.json",
  attach_delay_ms = 5000,
  stagger_ms = 8000,
}

-- State per nvim session
local started = false
local results = {}  -- { [absolute_path] = "queued"|"sent"|"missing"|"skipped" }

local function project_root()
  local found = vim.fs.find(cfg.project_marker, {
    upward = true, path = vim.fn.getcwd(),
  })
  if found and #found > 0 then
    return vim.fn.fnamemodify(found[1], ":h")
  end
  return vim.fn.getcwd()
end

local function resolve_path(root, entry)
  if vim.fn.isabsolutepath and vim.fn.isabsolutepath(entry) == 1 then
    return entry
  end
  if entry:match("^[/~]") or entry:match("^%a:[/\\]") then
    return entry
  end
  return root .. "/" .. entry
end

local function send_didOpen_hidden(path)
  if vim.fn.filereadable(path) ~= 1 then
    results[path] = "missing"
    return
  end
  -- Read file into a scratch buffer; nvim's LSP client will dispatch
  -- didOpen on BufReadPost via its on_attach autocmds when LSP attaches.
  -- But we want to attach the *existing* clangd client to this buffer.
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(bufnr, path)
  vim.bo[bufnr].buftype = ""              -- so LSP treats it as a real file
  vim.bo[bufnr].buflisted = false
  vim.bo[bufnr].bufhidden = "wipe"
  -- Load file content
  local lines = vim.fn.readfile(path)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modified = false
  -- Set filetype so LspAttach autocmds fire
  local ft = path:match("%.cpp$") and "cpp"
        or path:match("%.h$") and "cpp"
        or path:match("%.hpp$") and "cpp"
        or "cpp"
  vim.bo[bufnr].filetype = ft

  -- Find clangd and force-attach to this buffer
  local clients = vim.lsp.get_clients({ name = "clangd" })
  if vim.tbl_isempty(clients) then
    results[path] = "skipped (no clangd)"
    -- Wipe the buffer so it doesn't linger
    vim.schedule(function() pcall(vim.api.nvim_buf_delete, bufnr, { force = true }) end)
    return
  end
  for _, client in ipairs(clients) do
    pcall(vim.lsp.buf_attach_client, bufnr, client.id)
  end
  results[path] = "sent"

  -- Schedule wipe of the scratch buffer ~30s later. clangd holds the
  -- preamble/AST in its own caches independent of buffer existence.
  -- (NB: when bufhidden=wipe and the buffer is never displayed, simply
  -- detaching/closing is enough; we delay so didOpen has time to send.)
  vim.defer_fn(function()
    pcall(function()
      if vim.api.nvim_buf_is_valid(bufnr) then
        -- Send didClose explicitly so clangd doesn't leak doc state.
        for _, client in ipairs(vim.lsp.get_clients({ bufnr = bufnr })) do
          pcall(vim.lsp.buf_detach_client, bufnr, client.id)
        end
        vim.api.nvim_buf_delete(bufnr, { force = true })
      end
    end)
  end, 30000)
end

local function start_preheat()
  if started then return end
  started = true
  local root = project_root()
  local list = cfg.files or {}
  if #list == 0 then return end
  for i, entry in ipairs(list) do
    local abs = resolve_path(root, entry)
    results[abs] = "queued"
    vim.defer_fn(function() send_didOpen_hidden(abs) end, (i - 1) * cfg.stagger_ms)
  end
end

function M.setup(user_cfg)
  cfg = vim.tbl_deep_extend("force", cfg, user_cfg or {})
  if not cfg.enabled then return end

  -- Wait for clangd to attach somewhere, then delay, then preheat.
  vim.api.nvim_create_autocmd("LspAttach", {
    group = vim.api.nvim_create_augroup("UEPreheat", { clear = true }),
    callback = function(args)
      local client = vim.lsp.get_client_by_id(args.data.client_id)
      if not client or client.name ~= "clangd" then return end
      vim.defer_fn(start_preheat, cfg.attach_delay_ms)
    end,
  })
end

function M.run_now() start_preheat() end

function M.status()
  local lines = { "UE preheat status:" }
  if not cfg.enabled then table.insert(lines, "  disabled") end
  for path, state in pairs(results) do
    table.insert(lines, string.format("  [%s] %s", state, path))
  end
  vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
end

return M
```

**Step 1: Create file.**

**Step 2: `luac -p lua/utils/lsp_preheat.lua` — must pass.**

**Step 3: Commit.**

```bash
git add lua/utils/lsp_preheat.lua
git commit -m "feat: add lsp_preheat module to warm clangd ASTCache"
```

---

## Task 7: Wire preheat into config + add commands

**Objective:** Initialize preheat and expose `:UEPreheat` / `:UEPreheatStatus`.

**File:** Modify `lua/config/keymaps.lua` (or wherever LSP config init lives —
implementer should `search_files("lsp_fallback", target='content')` to find
where `M.definition` is currently bound and add commands there).

**Code to add:**

```lua
-- LSP preheat: pre-build AST for hot UE TUs so first gd is fast.
-- Disabled by default — uncomment and tune the file list per your project.
require("utils.lsp_preheat").setup({
  enabled = false,
  files = {
    -- "Engine/Source/Runtime/Renderer/Private/Nanite/NaniteCullRaster.cpp",
    -- "Engine/Source/Runtime/Renderer/Private/PostProcess/PostProcessing.cpp",
  },
})

vim.api.nvim_create_user_command("UEPreheat", function()
  require("utils.lsp_preheat").run_now()
end, { desc = "Force-run LSP preheat for configured hot TUs" })

vim.api.nvim_create_user_command("UEPreheatStatus", function()
  require("utils.lsp_preheat").status()
end, { desc = "Show LSP preheat per-file status" })
```

**Step 1: Add code.**

**Step 2: `luac -p`.**

**Step 3: Commit.**

```bash
git add lua/config/keymaps.lua
git commit -m "feat: wire LSP preheat with :UEPreheat / :UEPreheatStatus"
```

---

## Task 8: User configures + verifies preheat

**Objective:** User flips `enabled = true`, lists their actual hot TUs, and
verifies preheat populates the AST cache.

**Step 1: User edits `lua/config/keymaps.lua`** to set `enabled = true` and
add 2-3 of their hottest TUs (NaniteCullRaster + 1-2 others they hit daily).

**Step 2: User restarts nvim in the UE project root.**

**Step 3: Wait ~5s for clangd attach + ~5s preheat delay = ~10s,
then `:UEPreheatStatus`.**

**Expected:** Each file shows `[sent]` or `[missing]` with absolute path.

**Step 4: Wait 60s** (let clangd build the AST in the background; check
`htop` / `nvidia-smi` — clangd CPU should be high).

**Step 5: Open NaniteCullRaster.cpp manually, press `gd` on `Translate`.**

**Expected:** The instant path still wins (< 500ms), but ALSO the precise
path now returns within 1-2s instead of 30-60s. The reconcile hint (if any)
arrives within seconds, not minutes.

**Step 6: Document what you observed in this plan as an Outcomes section.**

---

## Outcomes

(Filled in after Task 5 and Task 8.)

- Tier 1 verified: ⏳
- Tier 3 verified: ⏳
- Edge cases discovered: ⏳

---

## Rollback

If any task makes things worse:

```bash
git log --oneline -10            # find the offending commit
git revert <sha>                 # safe revert
```

The plan is structured so each task is one commit. Revert is one-shot.

---

## Future Work (deferred)

- **Tier 2 — interactive precise reconcile:** Replace the simple hint with
  a virtual-text annotation on the instant-jump line, plus a `<leader>gp`
  cycle through alternates.
- **Tier 4 — clangd-indexer static merged index:** Run
  `clangd-indexer --executor=all-TUs compile_commands.json > UE.idx` and
  add `--index-file=UE.idx` to clangd args. Speeds up workspace/symbol
  lookups by 3-5x according to dexp benchmarks. ~30-60min initial build.
- **Auto-detect hot TUs:** Track per-file `BufRead` frequency in a json
  cache, auto-populate the preheat list.
- **Per-platform preheat lists:** Different hot TUs for D3D12 vs Vulkan
  workflows.
