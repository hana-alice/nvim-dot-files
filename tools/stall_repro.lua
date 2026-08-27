-- tools/stall_repro.lua — reproduce interactive stalls WITHOUT a human.
--
-- WHY: the recorded stall evidence (log scope "stall") is overwhelmingly
-- `ft=cpp` + normal mode + navigation keys (j/z/zz/gg/scroll) inside huge UE
-- translation units — 6536 of 8643 records. Fixing that needs a repeatable
-- measurement, but the trigger has always been "user scrolls and it feels bad",
-- which is unfalsifiable and cannot gate a regression.
--
-- This drives the SAME input path from inside a REAL session: feed navigation
-- keys via `nvim_feedkeys(..., "x")` and time each one, so every autocmd,
-- statuscolumn evaluation, treesitter parse, LSP request and redraw a keypress
-- triggers is included in its number.
--
-- IT MUST RUN IN THE LIVE INSTANCE, not `nvim -l`:
--   * `nvim -l` never loads init.lua -> no plugins, no autocmds, no
--     'statuscolumn' -> every key measures ~0.0ms and proves nothing.
--   * `--headless` has no attached UI, so redraw work (statuscolumn, extmarks,
--     signs) is largely skipped -> also proves nothing.
-- Both were tried; both reported a perfectly smooth editor while the user's
-- session was stalling 30x/min. Only the attached session is ground truth.
--
-- USAGE (against the running, stuttering Neovim):
--   nvim --headless --server //./pipe/nvim.<PID>.0 --remote-expr \
--     "luaeval('dofile(_A)', '<config>/tools/stall_repro.lua')"
--
-- Scenario via `vim.g.ue_stall_scenario` or env UE_STALL_SCENARIO
-- (scroll|paging|jumps|insert; default: every read-only scenario).
-- Results append to <stdpath('state')>/stall_repro.<pid>.txt and are returned.
-- Diagnostic only; nothing here is armed by default.

local uv = vim.uv or vim.loop

local SCENARIOS = {
  scroll = { "j", "k", "zz", "zt", "<ScrollWheelDown>", "<ScrollWheelUp>" },
  paging = { "<C-f>", "<C-b>", "<C-d>", "<C-u>" },
  jumps = { "gg", "G", "{", "}", "%" },
  insert = { "i", "x", "<BS>", "<Esc>" },
}

local ROUNDS = tonumber(vim.env.UE_STALL_ROUNDS or "") or 15

local function stats(list)
  if #list == 0 then
    return nil
  end
  table.sort(list)
  local function at(q)
    return list[math.max(1, math.min(#list, math.ceil(#list * q)))]
  end
  local sum = 0
  for _, v in ipairs(list) do
    sum = sum + v
  end
  return { n = #list, mean = sum / #list, p50 = at(0.5), p90 = at(0.9), max = list[#list] }
end

--- Time one key through the real input path, including the redraw it causes.
local function time_key(key)
  local term = vim.api.nvim_replace_termcodes(key, true, false, true)
  local t0 = uv.hrtime()
  pcall(vim.api.nvim_feedkeys, term, "nx", false)
  -- A real UI redraws after each key; force it so redraw-side cost
  -- (statuscolumn, signs, extmarks, treesitter highlight) is attributed here
  -- instead of leaking into the next measurement.
  pcall(vim.api.nvim__redraw, { flush = true })
  return (uv.hrtime() - t0) / 1e6
end

local out = {}
local function emit(line)
  out[#out + 1] = line
end

local buf = vim.api.nvim_get_current_buf()
local name = vim.api.nvim_buf_get_name(buf)
local lines = vim.api.nvim_buf_line_count(buf)

emit(("=== stall_repro %s pid=%d ==="):format(os.date("%Y-%m-%dT%H:%M:%S"), vim.fn.getpid()))
emit(("buf=%s lines=%d ft=%s rounds=%d"):format(
  name ~= "" and vim.fn.fnamemodify(name, ":t") or "[noname]",
  lines,
  vim.bo[buf].filetype,
  ROUNDS
))
emit(("ts_active=%s lsp=%d statuscolumn=%q"):format(
  tostring((function()
    local ok, hl = pcall(function()
      return vim.treesitter.highlighter.active[buf] ~= nil
    end)
    return ok and hl or "?"
  end)()),
  #vim.lsp.get_clients({ bufnr = buf }),
  vim.wo.statuscolumn or ""
))

local want = vim.g.ue_stall_scenario or vim.env.UE_STALL_SCENARIO
-- Default set is READ-ONLY on purpose: this attaches to the user's live
-- session, so it must not dirty their buffer. `insert` is opt-in and still
-- refuses a non-modifiable buffer instead of raising E21 mid-run.
local order = want and { want } or { "scroll", "paging", "jumps" }

local saved = vim.api.nvim_win_get_cursor(0)
for _, scen in ipairs(order) do
  local keys = SCENARIOS[scen]
  if scen == "insert" and not vim.bo[buf].modifiable then
    emit("")
    emit("-- scenario: insert SKIPPED (buffer is not modifiable)")
    keys = nil
  end
  if keys then
    local per_key = {}
    for _, k in ipairs(keys) do
      per_key[k] = {}
    end
    for _ = 1, ROUNDS do
      for _, k in ipairs(keys) do
        table.insert(per_key[k], time_key(k))
      end
    end
    emit("")
    emit(("-- scenario: %s"):format(scen))
    emit(("%-20s %5s %9s %9s %9s %9s"):format("key", "n", "mean", "p50", "p90", "max"))
    local rows = {}
    for k, list in pairs(per_key) do
      local s = stats(list)
      if s then
        rows[#rows + 1] = { key = k, s = s }
      end
    end
    table.sort(rows, function(a, b)
      return a.s.p90 > b.s.p90
    end)
    for _, r in ipairs(rows) do
      emit(("%-20s %5d %8.1fms %8.1fms %8.1fms %8.1fms"):format(
        r.key,
        r.s.n,
        r.s.mean,
        r.s.p50,
        r.s.p90,
        r.s.max
      ))
    end
  end
end
pcall(vim.api.nvim_win_set_cursor, 0, saved)

local path = ("%s/stall_repro.%d.txt"):format(vim.fn.stdpath("state"), vim.fn.getpid())
local f = io.open(path, "a")
if f then
  f:write(table.concat(out, "\n") .. "\n\n")
  f:close()
end

return table.concat(out, "\n")
