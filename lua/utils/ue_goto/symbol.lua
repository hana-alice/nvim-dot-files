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

-- ---------------------------------------------------------------------------
-- Dependent-name detection (treesitter, cpp grammar)
--
-- Goal: tell M.definition() to stop *before* asking clangd, when the symbol
-- under cursor is provably a dependent name (clangd cannot resolve those
-- without instantiation context — they always return empty after long retries).
--
-- We recognize three syntactic shapes in increasing complexity:
--
--   Shape A — qualified-identifier chain rooted at template param:
--     template <typename T>
--     ... T::Member::Sub::Call ...        ← cursor on any segment
--
--   Shape B — typedef alias rooted (transitively) at template param:
--     template <typename T> struct S {
--       typedef T              U;          (1-hop)
--       typedef typename T::Inner V;       (qualified hop)
--     };
--     ... U::Member ...                    ← root "U" resolves to T
--     ... V::Method ...
--
--   Shape C — field expression on an object whose type is dependent:
--     template <typename T> void f(T* obj) { obj->Method(); }
--     template <typename T> void g() { U u; u.Method(); }   (U typedef → T)
--                                            ↑ cursor on Method
--
-- Each shape is implemented as a small helper that returns
--   (root_template_param_name, displayable_chain_text)
-- or nil if it doesn't match. is_dependent_at_cursor() tries A then B then C.
-- ---------------------------------------------------------------------------

-- Names of every type-parameter declared by a template_declaration node.
-- Used by all shapes to decide "is this name a template parameter in scope?".
local function template_param_names_in_scope(start_node, bufnr)
  local names = {}
  local n = start_node
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
            local pname
            for child in pp:iter_children() do
              if child:type() == "type_identifier" then
                pname = vim.treesitter.get_node_text(child, bufnr)
                break
              end
            end
            if not pname then
              local txt = vim.treesitter.get_node_text(pp, bufnr) or ""
              pname = txt:match("([%w_]+)%s*$")
            end
            if pname then names[pname] = true end
          end
        end
      end
    end
    n = n:parent()
  end
  return names
end

-- Reach the leftmost identifier of a qualified_identifier chain.
-- "A::B::C" -> node for "A".
local function leftmost_of_chain(qid)
  local cur = qid
  while cur and cur:type() == "qualified_identifier" do
    local scope_field = cur:field("scope")
    local scope = scope_field and scope_field[1] or cur:child(0)
    if not scope then break end
    cur = scope
  end
  return cur
end

-- Find the OUTERMOST enclosing qualified_identifier of `node`. Returns nil
-- when `node` is not part of a qualified expression at all.
local function enclosing_qualified_chain(node)
  local chain = nil
  local p = node
  while p do
    if p:type() == "qualified_identifier" then chain = p end
    p = p:parent()
  end
  return chain
end

-- Find the FIRST enclosing field_expression (`obj->member` / `obj.member`).
-- Returns nil if cursor isn't inside one.
local function enclosing_field_expression(node)
  local p = node
  while p do
    if p:type() == "field_expression" then return p end
    p = p:parent()
  end
  return nil
end

-- For a field_expression node, return the text of its argument identifier
-- ("Object" in `Object->GetScriptStruct`). Returns nil for compound LHS like
-- `(*p)->m` or `foo().bar` — we don't try to resolve those.
local function field_expression_object_name(fe, bufnr)
  local arg = fe:field("argument")
  arg = arg and arg[1]
  if not arg then return nil end
  if arg:type() == "identifier" then
    return vim.treesitter.get_node_text(arg, bufnr)
  end
  -- Could be a parenthesized_expression, pointer_expression, etc — give up.
  return nil
end

-- Walk siblings of `start_node` upward looking for a declaration whose name
-- matches `var_name`, returning the *type-name* text of that declaration.
--
-- We accept these grammar shapes (the common ones in UE):
--   parameter_declaration    (function parameters: SourceItemType* Object)
--   declaration              (locals: UScriptStruct* ScriptStruct = ...)
--   field_declaration        (struct/class members)
--   type_definition          (typedefs)
--   alias_declaration        (using X = ...)
--
-- Returns the type-identifier text (e.g. "SourceItemType") or nil.
local function find_decl_type_name(start_node, var_name, bufnr)
  -- Scope = walk up to the enclosing function_definition / compound_statement
  -- / struct_specifier and look at all declarations under it.
  local function decl_var_matches(decl, name)
    -- Look for an identifier descendant whose text == name AND that sits
    -- inside a declarator subtree (not in initializer expression).
    -- Cheap approximation: any identifier child of declarator nodes.
    local function scan(n)
      local t = n:type()
      if t == "init_declarator"
         or t == "function_declarator"
         or t == "pointer_declarator"
         or t == "reference_declarator"
         or t == "array_declarator"
         or t == "identifier" then
        if t == "identifier" then
          if vim.treesitter.get_node_text(n, bufnr) == name then return true end
        else
          for c in n:iter_children() do
            if scan(c) then return true end
          end
        end
      end
      return false
    end
    -- declaration may have several declarators; iterate them.
    for c in decl:iter_children() do
      if scan(c) then return true end
    end
    return false
  end

  local function decl_type_text(decl)
    -- The "type" field on cpp grammar is named "type" for declaration,
    -- field_declaration, and parameter_declaration. type_definition uses
    -- the same.
    local tf = decl:field("type")
    local tn = tf and tf[1]
    if tn then return vim.treesitter.get_node_text(tn, bufnr) end
    return nil
  end

  local n = start_node
  while n do
    -- Containers we should scan for decls of `var_name`.
    local container = n:type()
    if container == "compound_statement"
       or container == "function_definition"
       or container == "field_declaration_list"
       or container == "struct_specifier"
       or container == "class_specifier"
       or container == "namespace_definition"
       or container == "translation_unit" then
      -- Scan direct & nested declarations inside this container.
      -- For function_definition we also need to look at its parameters list.
      if container == "function_definition" then
        -- Check parameters of this function.
        local declarator = n:field("declarator")
        declarator = declarator and declarator[1]
        if declarator then
          local function find_params(node2)
            if node2:type() == "parameter_list" then return node2 end
            for c in node2:iter_children() do
              local r = find_params(c)
              if r then return r end
            end
          end
          local plist = find_params(declarator)
          if plist then
            for param in plist:iter_children() do
              if param:type() == "parameter_declaration" then
                if decl_var_matches(param, var_name) then
                  local t = decl_type_text(param)
                  if t then return t end
                end
              end
            end
          end
        end
      end
      -- Iterate top-level statements/declarations.
      for child in n:iter_children() do
        local ct = child:type()
        if ct == "declaration"
           or ct == "field_declaration"
           or ct == "type_definition"
           or ct == "alias_declaration" then
          if decl_var_matches(child, var_name) then
            local t = decl_type_text(child)
            if t then return t end
          end
        end
      end
    end
    n = n:parent()
  end
  return nil
end

-- Strip pointer/reference/cv decorations from a type-text to get the base
-- type name. "SourceItemType*" -> "SourceItemType",  "const T&" -> "T".
local function base_type_name(type_text)
  if not type_text or type_text == "" then return nil end
  -- Drop trailing * & and any whitespace they trail.
  local t = type_text:gsub("[%*&%s]+$", "")
  -- Drop leading const/volatile.
  t = t:gsub("^const%s+", ""):gsub("^volatile%s+", "")
  -- Drop trailing template args: Foo<Bar>  ->  Foo
  t = t:gsub("%b<>%s*$", "")
  -- Take final identifier in case of qualified type (Ns::Foo -> Foo).
  local last = t:match("([%w_]+)$")
  return last
end

-- Resolve a type-name to a template parameter, following typedef/alias
-- chains within the buffer. Returns the template-param name or nil.
-- Limits recursion to MAX_HOPS to avoid pathological loops.
local MAX_TYPEDEF_HOPS = 4
local function resolve_to_template_param(type_name, scope_node, template_params, bufnr, hops)
  if not type_name then return nil end
  if template_params[type_name] then return type_name end
  hops = hops or 0
  if hops >= MAX_TYPEDEF_HOPS then return nil end

  -- Look up `typedef X type_name;` or `using type_name = X;` in any
  -- enclosing scope, then recurse on X.
  local function alias_target(decl)
    -- type_definition: `typedef OLD NEW;`  -> "type" field is OLD, declarator is NEW
    -- alias_declaration: `using NEW = OLD;` -> "name" field is NEW, "type" field is OLD
    local dt = decl:type()
    if dt == "type_definition" then
      -- Confirm the new name matches type_name
      for c in decl:iter_children() do
        if c:type() == "type_identifier" or c:type() == "identifier" then
          if vim.treesitter.get_node_text(c, bufnr) == type_name then
            local tf = decl:field("type")
            local tn = tf and tf[1]
            if tn then return vim.treesitter.get_node_text(tn, bufnr) end
          end
        end
      end
    elseif dt == "alias_declaration" then
      local nf = decl:field("name")
      local nn = nf and nf[1]
      if nn and vim.treesitter.get_node_text(nn, bufnr) == type_name then
        local tf = decl:field("type")
        local tn = tf and tf[1]
        if tn then return vim.treesitter.get_node_text(tn, bufnr) end
      end
    end
    return nil
  end

  local n = scope_node
  while n do
    local ct = n:type()
    if ct == "compound_statement"
       or ct == "field_declaration_list"
       or ct == "struct_specifier"
       or ct == "class_specifier"
       or ct == "namespace_definition"
       or ct == "translation_unit" then
      for child in n:iter_children() do
        local ctt = child:type()
        if ctt == "type_definition" or ctt == "alias_declaration" then
          local rhs = alias_target(child)
          if rhs then
            local base = base_type_name(rhs)
            return resolve_to_template_param(base, scope_node, template_params, bufnr, hops + 1)
          end
        end
      end
    end
    n = n:parent()
  end
  return nil
end

-- ---------------------------------------------------------------------------
-- Shape detectors. Each returns (root_param_name, chain_text) or nil.
-- ---------------------------------------------------------------------------

local function shape_qualified_chain(node, template_params, bufnr)
  local chain = enclosing_qualified_chain(node)
  if not chain then return nil end
  local root = leftmost_of_chain(chain)
  if not root then return nil end
  local rt = root:type()
  if rt ~= "namespace_identifier" and rt ~= "identifier" and rt ~= "type_identifier" then
    return nil
  end
  local root_name = vim.treesitter.get_node_text(root, bufnr)
  if not root_name or root_name == "" then return nil end

  -- Direct hit: root is a template param.
  if template_params[root_name] then
    return root_name, vim.treesitter.get_node_text(chain, bufnr)
  end

  -- Indirect: root is a typedef/alias to a template param.
  local resolved = resolve_to_template_param(root_name, node, template_params, bufnr, 0)
  if resolved then
    return resolved, vim.treesitter.get_node_text(chain, bufnr)
  end
  return nil
end

local function shape_field_expression(node, template_params, bufnr)
  local fe = enclosing_field_expression(node)
  if not fe then return nil end
  local var_name = field_expression_object_name(fe, bufnr)
  if not var_name then return nil end

  -- Find Var's declared type.
  local type_text = find_decl_type_name(node, var_name, bufnr)
  if not type_text then return nil end
  local base = base_type_name(type_text)
  if not base then return nil end

  -- Direct hit.
  if template_params[base] then
    return base, vim.treesitter.get_node_text(fe, bufnr)
  end

  -- Indirect via typedef/alias.
  local resolved = resolve_to_template_param(base, node, template_params, bufnr, 0)
  if resolved then
    return resolved, vim.treesitter.get_node_text(fe, bufnr)
  end
  return nil
end

-- ---------------------------------------------------------------------------
-- is_at_definition_at_cursor() — public entry point
-- ---------------------------------------------------------------------------
--
-- True when the cursor IS the definition site of the symbol it sits on.
-- Goto-definition from this position is a no-op — the LSP would either jump
-- to the same line (best case) or to ANOTHER definition with the same name
-- (overload, friend decl, forward decl in header). Either way we don't want
-- to spin clangd up for 30s and risk landing on a sibling.
--
-- Detection rule (pure syntax via TS, no regex):
--   cursor's leaf identifier is the `name`/`declarator` field of one of
--   these C++ definition nodes:
--     class_specifier       struct_specifier       union_specifier
--     enum_specifier        enumerator             namespace_definition
--     function_definition   field_declaration (function decl WITH body)
--     type_definition (typedef)                    alias_declaration
--     template_type_parameter / parameter_declaration → too noisy, skip
--
-- Returns: bail (bool), kind (string for the toast), name (string)
local DEFINITION_KIND_BY_NODE = {
  class_specifier      = "class",
  struct_specifier     = "struct",
  union_specifier      = "union",
  enum_specifier       = "enum",
  enumerator           = "enumerator",
  namespace_definition = "namespace",
  function_definition  = "function",
  type_definition      = "typedef",
  alias_declaration    = "type alias",
}

-- Return true if `id_node` is the "name" of `def_node`. We resolve "name"
-- via the grammar's named fields for each definition kind, with a fallback
-- of structural identity (id_node IS the field's first-result node).
local function id_is_name_of_definition(id_node, def_node)
  local def_type = def_node:type()
  -- Field accessors per node type:
  --   class/struct/union/enum/namespace_definition/alias_declaration → "name"
  --   function_definition/type_definition → "declarator"  (which itself
  --     contains the actual identifier, possibly wrapped in qualified_id)
  --   enumerator → "name"
  local field_name
  if def_type == "function_definition" or def_type == "type_definition" then
    field_name = "declarator"
  else
    field_name = "name"
  end

  local fld = def_node:field(field_name)
  if not fld or not fld[1] then return false end
  local target = fld[1]

  -- For function_definition/type_definition we may need to dig into the
  -- declarator to reach the bare identifier. Walk down through
  -- function_declarator / pointer_declarator / reference_declarator etc.
  local function find_id_in_declarator(d)
    if not d then return nil end
    local t = d:type()
    if t == "identifier" or t == "field_identifier" or t == "type_identifier" then
      return d
    end
    -- qualified_identifier: take its rightmost name field
    if t == "qualified_identifier" then
      local nm = d:field("name")
      if nm and nm[1] then return find_id_in_declarator(nm[1]) end
    end
    -- function_declarator / pointer_declarator / reference_declarator /
    -- parenthesized_declarator / array_declarator / init_declarator
    --   all expose the inner declarator via "declarator" field.
    local inner = d:field("declarator")
    if inner and inner[1] then
      return find_id_in_declarator(inner[1])
    end
    -- destructor_name / operator_name / template_function — treat as name
    if t == "destructor_name" or t == "operator_name" or t == "template_function" then
      return d
    end
    return nil
  end

  if def_type == "function_definition" or def_type == "type_definition" then
    target = find_id_in_declarator(target) or target
  elseif def_type == "alias_declaration" then
    -- alias_declaration "name" field IS already a type_identifier; nothing
    -- to dig.
  end

  if not target then return false end

  -- Compare by range — same start/end means same node.
  local a1, a2, a3, a4 = target:range()
  local b1, b2, b3, b4 = id_node:range()
  return a1 == b1 and a2 == b2 and a3 == b3 and a4 == b4
end

function M.is_at_definition_at_cursor()
  local bufnr = vim.api.nvim_get_current_buf()
  local ok_parser, parser = pcall(vim.treesitter.get_parser, bufnr, "cpp")
  if not ok_parser or not parser then return false end
  local trees = parser:parse()
  if not trees or not trees[1] then return false end

  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  row = row - 1
  local node = trees[1]:root():descendant_for_range(row, col, row, col)
  if not node then return false end

  -- Only consider leaf identifier-ish nodes — bail-out logic is tied to
  -- "cursor sits on the symbol itself".
  local nt = node:type()
  if nt ~= "identifier"
     and nt ~= "field_identifier"
     and nt ~= "type_identifier"
     and nt ~= "namespace_identifier" then
    return false
  end

  -- Walk up at most a few levels looking for an enclosing definition node.
  -- We don't walk arbitrarily deep — definitions wrap their name within
  -- 1-4 ancestor steps in practice (class/struct/enum: 1; function via
  -- declarators: 2-4).
  local p = node:parent()
  local hops = 0
  while p and hops < 6 do
    local pt = p:type()
    local kind = DEFINITION_KIND_BY_NODE[pt]
    if kind then
      if id_is_name_of_definition(node, p) then
        local name = vim.treesitter.get_node_text(node, bufnr)
        return true, kind, name
      end
      -- Found a definition node but cursor isn't its name field
      -- (e.g. cursor on base class identifier in class_specifier's
      -- base_class_clause). Don't bail — this is a use site.
      return false
    end
    -- Stop walking once we leave the local declarator chain.
    if pt == "translation_unit" or pt == "compound_statement" then
      return false
    end
    p = p:parent()
    hops = hops + 1
  end
  return false
end

-- ---------------------------------------------------------------------------
-- is_dependent_at_cursor() — public entry point
-- ---------------------------------------------------------------------------

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

  -- Cursor must be inside SOME enclosing template_declaration to even
  -- consider this a dependent-name candidate.
  local template_params = template_param_names_in_scope(node, bufnr)
  if vim.tbl_isempty(template_params) then return false end

  -- Try shape A: qualified chain (T::M  or  AliasOfT::M).
  local r, chain = shape_qualified_chain(node, template_params, bufnr)
  if r then return true, r, chain end

  -- Try shape C: field expression (obj->m  /  obj.m  where obj's type is dependent).
  r, chain = shape_field_expression(node, template_params, bufnr)
  if r then return true, r, chain end

  return false
end

-- Back-compat shim: callers that pass a receiver string still work, but we
-- ignore the argument and use the cursor context (which is more correct).
function M.is_dependent_name(_receiver)
  local ok = M.is_dependent_at_cursor()
  return ok and true or false
end

-- ---------------------------------------------------------------------------
-- Call-site arity (treesitter, cpp grammar)
--
-- Goal: tell syntax_filter.lua how many arguments the cursor's call
-- expression takes, so candidate function definitions with mismatched
-- parameter count can be eliminated.
--
-- Returns (arity:int, callee_name:string) when cursor sits inside an
-- enclosing call_expression (or template_function whose parent is a
-- call_expression). Returns nil when cursor is not in a call (e.g. on a
-- declaration name, in a type expression).
-- ---------------------------------------------------------------------------
function M.call_arity_at_cursor()
  local bufnr = vim.api.nvim_get_current_buf()
  local ok_parser, parser = pcall(vim.treesitter.get_parser, bufnr, "cpp")
  if not ok_parser or not parser then return nil end
  local trees = parser:parse()
  if not trees or not trees[1] then return nil end

  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  row = row - 1  -- TS is 0-indexed
  local node = trees[1]:root():descendant_for_range(row, col, row, col)
  if not node then return nil end

  -- Walk up to the nearest call_expression. Stop at function_definition
  -- (we do NOT want to accept a nested call from a sibling, only the one
  -- that lexically encloses cursor).
  local call = nil
  local n = node
  while n do
    local t = n:type()
    if t == "call_expression" then call = n; break end
    -- function_declarator catches prototypes (no body); function_definition
    -- catches definitions with body. Both indicate cursor is on a declaration
    -- site rather than at a call site.
    if t == "function_definition" or t == "function_declarator" then
      return nil  -- cursor is on a declaration site, not a call
    end
    n = n:parent()
  end
  if not call then return nil end

  -- Extract argument_list and count direct children that are not punctuation.
  local args_field = call:field("arguments")
  local arglist = args_field and args_field[1]
  if not arglist then
    -- Some grammars expose arguments as second child without the field.
    for c in call:iter_children() do
      if c:type() == "argument_list" then arglist = c; break end
    end
  end
  if not arglist then return nil end

  local arity = 0
  for c in arglist:iter_children() do
    local ct = c:type()
    -- Skip punctuation: `(`, `)`, `,`. Count everything else as one arg.
    if ct ~= "(" and ct ~= ")" and ct ~= "," and ct ~= "comment" and ct ~= "ERROR" then
      arity = arity + 1
    end
  end

  -- Extract callee name (best-effort: identifier, qualified_identifier,
  -- field_expression, template_function).
  local function leaf_name(callee_node)
    if not callee_node then return nil end
    local t = callee_node:type()
    if t == "identifier" or t == "field_identifier" or t == "type_identifier" then
      return vim.treesitter.get_node_text(callee_node, bufnr)
    elseif t == "qualified_identifier" then
      -- rightmost identifier
      local nf = callee_node:field("name")
      if nf and nf[1] then return leaf_name(nf[1]) end
    elseif t == "field_expression" then
      local fld = callee_node:field("field")
      if fld and fld[1] then return leaf_name(fld[1]) end
    elseif t == "template_function" then
      local nm = callee_node:field("name")
      if nm and nm[1] then return leaf_name(nm[1]) end
    end
    -- Fallback: text
    local txt = vim.treesitter.get_node_text(callee_node, bufnr) or ""
    return txt:match("([%w_]+)%s*$")
  end

  local fn_field = call:field("function")
  local fn_node = fn_field and fn_field[1]
  local name = leaf_name(fn_node)

  return arity, name
end

-- ---------------------------------------------------------------------------
-- Off-buffer function-declarator arity probe.
--
-- Reads file from disk, parses with vim.treesitter.get_string_parser (no
-- buffer side effect), locates the nearest function_declarator at or
-- straddling line_1b, and returns (formal_count, default_count, is_variadic).
--
-- Returns nil on parse failure / file missing — caller should treat nil as
-- "unknown, do not filter this candidate out".
--
-- Tolerance: clangd's index line numbers can be off by ±1 vs source (newline
-- normalization, multi-line declarators). We search a ±3 line window for
-- the nearest function_declarator node.
-- ---------------------------------------------------------------------------
function M.declarator_arity_at(path, line_1b)
  if not path or path == "" then return nil end
  local f = io.open(path, "rb")
  if not f then return nil end
  local content = f:read("*a"); f:close()
  if not content or content == "" then return nil end

  local ok_p, parser = pcall(vim.treesitter.get_string_parser, content, "cpp")
  if not ok_p or not parser then return nil end
  local ok_parse, trees = pcall(function() return parser:parse() end)
  if not ok_parse or not trees or not trees[1] then return nil end
  local root = trees[1]:root()

  local target_row = (line_1b or 1) - 1
  local LO = math.max(0, target_row - 3)
  local HI = target_row + 3

  -- Find the function_declarator whose start_row falls within [LO, HI],
  -- preferring the one closest to target_row.
  local best_decl = nil
  local best_dist = math.huge

  local function walk(node)
    local sr = node:start()
    local er = node:end_()
    if er < LO or sr > HI then
      -- entirely outside window — recurse only if node spans across (could contain a hit)
      if sr <= HI and er >= LO then
        for c in node:iter_children() do walk(c) end
      end
      return
    end
    local t = node:type()
    if t == "function_declarator" then
      local d = math.abs(sr - target_row)
      if d < best_dist then best_dist = d; best_decl = node end
    end
    for c in node:iter_children() do walk(c) end
  end
  walk(root)
  if not best_decl then return nil end

  -- parameters field
  local pf = best_decl:field("parameters")
  local plist = pf and pf[1]
  if not plist then
    for c in best_decl:iter_children() do
      if c:type() == "parameter_list" then plist = c; break end
    end
  end
  if not plist then return 0, 0, false end

  local count = 0
  local defaults = 0
  local variadic = false

  for c in plist:iter_children() do
    local t = c:type()
    if t == "parameter_declaration" or t == "optional_parameter_declaration" then
      count = count + 1
      if t == "optional_parameter_declaration" then defaults = defaults + 1 end
    elseif t == "variadic_parameter_declaration" or t == "..." then
      variadic = true
    end
  end

  return count, defaults, variadic
end

return M
