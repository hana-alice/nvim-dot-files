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

-- is_dependent_at_cursor():
--   Treesitter check: is the symbol at cursor a member of a chain rooted at
--   a template parameter (i.e. a C++ dependent name)?
--
--   clangd cannot resolve dependent names without instantiation context, so
--   for these we must not race / retry / spin.
--
--   Algorithm (pure syntax, zero regex on source text):
--     1. Get the TS node at cursor and walk UP through every enclosing
--        `qualified_identifier`, taking the OUTERMOST one. That gives us
--        the full `A::B::C::D` chain even if cursor is on B/C/D.
--     2. Recurse into that chain via field("scope") to find the LEFTMOST
--        identifier — the chain's root (e.g. `A`).
--     3. Walk UP from there collecting every enclosing `template_declaration`,
--        and for each, read its `template_parameter_list` and extract every
--        type-parameter identifier (typename T / class T / template-template
--        / variadic / optional).
--     4. If the chain root identifier name matches one of those names, the
--        whole chain is dependent.
--
--   Returns: dependent (bool), root_name (string|nil), chain_text (string|nil)
function M.is_dependent_at_cursor()
  local bufnr = vim.api.nvim_get_current_buf()

  local ok_parser, parser = pcall(vim.treesitter.get_parser, bufnr, "cpp")
  if not ok_parser or not parser then return false end
  local trees = parser:parse()
  if not trees or not trees[1] then return false end

  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  row = row - 1

  local node = trees[1]:root():descendant_for_range(row, col, row, col)
  if not node then return false end

  -- 1. Find OUTERMOST enclosing qualified_identifier (the full chain).
  local chain = nil
  local p = node
  while p do
    if p:type() == "qualified_identifier" then chain = p end
    p = p:parent()
  end
  if not chain then return false end -- not a qualified expression at all

  -- 2. Recurse left to find the chain root identifier.
  local function leftmost(qid)
    local cur = qid
    while cur and cur:type() == "qualified_identifier" do
      local scope_field = cur:field("scope")
      local scope = scope_field and scope_field[1] or cur:child(0)
      if not scope then break end
      cur = scope
    end
    return cur
  end
  local root_node = leftmost(chain)
  if not root_node then return false end
  local rt = root_node:type()
  -- Acceptable identifier-like leaf types in the cpp grammar.
  if rt ~= "namespace_identifier"
     and rt ~= "identifier"
     and rt ~= "type_identifier" then
    return false
  end
  local root_name = vim.treesitter.get_node_text(root_node, bufnr)
  if not root_name or root_name == "" then return false end

  -- 3. Collect template parameters from every enclosing template_declaration.
  local function param_name(param_node)
    for child in param_node:iter_children() do
      if child:type() == "type_identifier" then
        return vim.treesitter.get_node_text(child, bufnr)
      end
    end
    local txt = vim.treesitter.get_node_text(param_node, bufnr) or ""
    return txt:match("([%w_]+)%s*$")
  end

  local n = node
  while n do
    if n:type() == "template_declaration" then
      local plist
      local pf = n:field("parameters")
      plist = pf and pf[1]
      if not plist then
        for c in n:iter_children() do
          if c:type() == "template_parameter_list" then plist = c; break end
        end
      end
      if plist then
        for pp in plist:iter_children() do
          local t = pp:type()
          if t == "type_parameter_declaration"
             or t == "variadic_type_parameter_declaration"
             or t == "optional_type_parameter_declaration"
             or t == "template_template_parameter" then
            if param_name(pp) == root_name then
              local chain_text = vim.treesitter.get_node_text(chain, bufnr)
              return true, root_name, chain_text
            end
          end
        end
      end
    end
    n = n:parent()
  end

  return false
end

-- Back-compat shim: callers that pass a receiver string still work, but we
-- ignore the argument and use the cursor context (which is more correct).
function M.is_dependent_name(_receiver)
  local ok = M.is_dependent_at_cursor()
  return ok and true or false
end

return M
