-- ue_goto.symbol — pure cursor-context extraction.
--
-- Stateless. No side effects. Reads only vim.api / vim.fn.
-- Used by provider.lua to build LSP requests and by ranking.lua to
-- score candidates. Keeping these here means provider/ranking don't
-- import from each other.

local M = {}

-- current_symbol(): the identifier under the cursor, or nil if none.
function M.current_symbol()
  local word = vim.fn.expand("<cword>")
  if word == nil or word == "" then
    return nil
  end
  return word
end

-- current_receiver():
--   For an expression like `RasterPipelines.GetBinCount(...)` or
--   `Ctx->GetBinCount(...)` with cursor on `GetBinCount`, return the
--   receiver identifier ("RasterPipelines" / "Ctx").
--
--   Used to disambiguate ws/symbol candidates that share the same method
--   name but live on different classes — we score candidates whose
--   container name overlaps the receiver name.
--
--   Returns "" if no clear receiver could be identified (free function,
--   start-of-line, after `::`, etc.).
function M.current_receiver()
  local ok, line = pcall(vim.api.nvim_get_current_line)
  if not ok or not line or line == "" then return "" end
  local _, col = unpack(vim.api.nvim_win_get_cursor(0))
  -- walk left from the byte BEFORE the current word to find `.` / `->` / `::`
  -- skip over the cword first
  local i = col
  -- go past identifier chars under and after cursor (cword may be multi-byte
  -- but UE is ASCII identifiers in practice)
  while i > 0 and line:sub(i, i):match("[%w_]") do i = i - 1 end
  -- now line:sub(i,i) is the byte immediately before the identifier
  local prev = line:sub(i, i)
  if prev == "." then
    -- "<receiver>.cword"
    local j = i - 1
    while j > 0 and line:sub(j, j):match("[%w_]") do j = j - 1 end
    return line:sub(j + 1, i - 1)
  elseif prev == ">" and line:sub(i - 1, i - 1) == "-" then
    -- "<receiver>->cword"
    local j = i - 2
    while j > 0 and line:sub(j, j):match("[%w_]") do j = j - 1 end
    return line:sub(j + 1, i - 2)
  elseif prev == ":" and line:sub(i - 1, i - 1) == ":" then
    -- "<Class>::cword" — receiver is the class itself
    local j = i - 2
    while j > 0 and line:sub(j, j):match("[%w_]") do j = j - 1 end
    return line:sub(j + 1, i - 2)
  end
  return ""
end

-- normalize_class_name(name):
--   Strip UE/Hungarian-style class prefix so that "FNaniteRasterPipelines"
--   matches receiver "RasterPipelines" via simple substring containment.
--   Strips: F (struct), U (UObject), A (AActor), T (template), I (interface),
--   E (enum), S (Slate), G (global). Never strips if the result would be
--   empty or start with a lowercase letter (i.e. "Foo" → "oo" is wrong).
function M.normalize_class_name(name)
  if not name or name == "" then return "" end
  local first = name:sub(1, 1)
  local rest = name:sub(2)
  if first:match("[FUATIESG]") and rest:sub(1, 1):match("[A-Z]") then
    return rest
  end
  return name
end

return M
