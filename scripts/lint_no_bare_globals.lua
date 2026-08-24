#!/usr/bin/env -S nvim -l
-- scripts/lint_no_bare_globals.lua
--
-- AST-based lint for `lua/` modules: catch "bare global function assignment"
-- patterns like `foo = function() ... end` at file scope. These compile fine
-- but silently leak to _G, breaking any caller that expected a file-local /
-- forward-declared local of the same name in another file.
--
-- Real-world bug it would have caught:
--   ue/dap.lua: `stop_android_debugger = function(opts) ... end`
--   ue.lua:    `local stop_android_debugger`  -- forward decl, never filled
--   crash:     attempt to call upvalue 'stop_android_debugger' (a nil value)
--
-- Allowed patterns (NOT flagged):
--   local foo = function() ... end
--   local function foo() ... end
--   M.foo = function() ... end          -- module export
--   D.foo = function() ... end          -- module export (sub-table)
--   any.dotted.path = function() ... end
--   _G.foo = function() ... end         -- explicit, audited
--
-- Usage:
--   nvim -l scripts/lint_no_bare_globals.lua [path1 path2 ...]
--   (defaults to scanning lua/ recursively)
--
-- Exit codes:
--   0  no offenders
--   1  one or more offenders found (printed in compiler-friendly format)
--   2  ts parser unavailable / IO error

local function eprintf(fmt, ...)
  if select("#", ...) == 0 then io.stderr:write(fmt .. "\n")
  else io.stderr:write(string.format(fmt, ...) .. "\n") end
end
local function printf(fmt, ...)
  if select("#", ...) == 0 then io.write(fmt .. "\n")
  else io.write(string.format(fmt, ...) .. "\n") end
end

-- ── Config ────────────────────────────────────────────────────────────────
local DEFAULT_ROOTS = { "lua" }
local IGNORE_GLOB_PATTERNS = {
  -- treesitter parser dirs sometimes vendored:
  "lua/parser/",
  -- snapshots / tests we don't lint:
  "lua/tests/",
}

-- ── tiny utils ────────────────────────────────────────────────────────────
local function is_ignored(path)
  for _, pat in ipairs(IGNORE_GLOB_PATTERNS) do
    if path:find(pat, 1, true) then return true end
  end
  return false
end

local function list_lua_files(root)
  local out = {}
  local stat = vim.uv.fs_stat(root)
  if not stat then return out end
  if stat.type == "file" then
    if root:match("%.lua$") then table.insert(out, root) end
    return out
  end
  -- recurse
  local stack = { root }
  while #stack > 0 do
    local dir = table.remove(stack)
    local handle = vim.uv.fs_scandir(dir)
    if handle then
      while true do
        local name, t = vim.uv.fs_scandir_next(handle)
        if not name then break end
        local full = dir .. "/" .. name
        if t == "directory" then
          table.insert(stack, full)
        elseif (t == "file" or t == "link") and name:match("%.lua$") then
          if not is_ignored(full) then table.insert(out, full) end
        end
      end
    end
  end
  return out
end

-- ── AST scan ──────────────────────────────────────────────────────────────
local function get_lua_parser(source)
  local ok, parser = pcall(vim.treesitter.get_string_parser, source, "lua")
  if not ok or not parser then return nil, "no lua tree-sitter parser available" end
  local trees = parser:parse()
  if not trees or not trees[1] then return nil, "parse failed" end
  return trees[1]:root()
end

-- Returns a list of offenses { line, col, name, snippet }
local function scan_file(path)
  local fd = io.open(path, "rb")
  if not fd then return nil, "cannot read: " .. path end
  local source = fd:read("*a")
  fd:close()

  local root, err = get_lua_parser(source)
  if not root then return nil, err end

  local lines = {}
  for line in (source .. "\n"):gmatch("([^\n]*)\n") do table.insert(lines, line) end

  local offenses = {}

  -- ── Pass 1: collect file-scope forward-declared local names ─────────────
  -- A `local foo` (or `local foo, bar`) with no `= ...` initializer is the
  -- legitimate forward-decl pattern. Same-file bare assignments to these
  -- names DO work (Lua main-chunk locals are shared across the chunk), so
  -- they should NOT be flagged. The cross-file failure mode (the actual bug
  -- the lint exists for) only happens when a bare global assignment has NO
  -- forward decl in the same file.
  local forward_decl_names = {}
  for child in root:iter_children() do
    if child:type() == "variable_declaration" then
      -- shape: (variable_declaration (assignment_statement (variable_list ident,...) (expression_list ...)))
      -- A bare `local foo` with no init is `(variable_declaration (variable_list (identifier)))` — no inner assignment.
      local first = child:named_child(0)
      if first and first:type() == "variable_list" then
        for i = 0, first:named_child_count() - 1 do
          local id = first:named_child(i)
          if id and id:type() == "identifier" then
            forward_decl_names[vim.treesitter.get_node_text(id, source)] = true
          end
        end
      end
    end
  end

  -- ── Pass 2: find bare global function assignments at file scope ─────────
  for child in root:iter_children() do
    if child:type() == "assignment_statement" then
      -- treesitter-lua doesn't expose field names on assignment_statement —
      -- positional children are: [0]=variable_list, [1]=expression_list.
      local var_list = child:named_child(0)
      local expr_list = child:named_child(1)
      if var_list and var_list:type() == "variable_list"
         and expr_list and expr_list:type() == "expression_list" then
        -- Only single-target = single-value (most common shape; multi-target
        -- assignments rarely declare functions and are out of scope).
        if var_list:named_child_count() == 1 and expr_list:named_child_count() == 1 then
          local target = var_list:named_child(0)
          local rhs = expr_list:named_child(0)
          if target and target:type() == "identifier"
             and rhs and rhs:type() == "function_definition" then
            local name = vim.treesitter.get_node_text(target, source)
            -- Skip if there's a same-file forward declaration — that pattern
            -- works (local visible to all subsequent code in the chunk).
            if not forward_decl_names[name] then
              local sr, sc = target:start()
              local snippet = lines[sr + 1] or ""
              table.insert(offenses, {
                line = sr + 1,
                col = sc + 1,
                name = name,
                snippet = snippet:gsub("^%s+", ""):sub(1, 120),
              })
            end
          end
        end
      end
    end
  end

  return offenses
end

-- ── main ──────────────────────────────────────────────────────────────────
local function main(argv)
  local roots = (#argv > 0) and argv or DEFAULT_ROOTS
  local files = {}
  for _, r in ipairs(roots) do
    for _, f in ipairs(list_lua_files(r)) do table.insert(files, f) end
  end

  if #files == 0 then
    eprintf("lint_no_bare_globals: no .lua files under %s", table.concat(roots, " "))
    return 0
  end

  local total_offenses = 0
  local total_files_with_offenses = 0
  for _, file in ipairs(files) do
    local offenses, err = scan_file(file)
    if not offenses then
      eprintf("lint_no_bare_globals: %s — %s", file, err)
      return 2
    end
    if #offenses > 0 then
      total_files_with_offenses = total_files_with_offenses + 1
      for _, o in ipairs(offenses) do
        total_offenses = total_offenses + 1
        -- compiler-style: file:line:col: message
        printf("%s:%d:%d: bare global function assignment '%s = function ...' — use `local %s = function ...`, `local function %s(...)`, or `M.%s = function ...`",
          file, o.line, o.col, o.name, o.name, o.name, o.name)
        printf("    %s", o.snippet)
      end
    end
  end

  if total_offenses == 0 then
    eprintf("lint_no_bare_globals: %d files scanned, OK", #files)
    return 0
  end

  eprintf("")
  eprintf("lint_no_bare_globals: FAIL — %d offense(s) across %d file(s) (out of %d scanned)",
    total_offenses, total_files_with_offenses, #files)
  eprintf("")
  eprintf("Why this matters:")
  eprintf("  Bare assignments at file scope leak the function to _G. If any other")
  eprintf("  file declared `local %s` as a forward-decl thinking this would")
  eprintf("  fill it, that local stays nil and crashes at call time.")
  eprintf("  See commit 63df422 for a real instance (stop_android_debugger).")
  return 1
end

local argv = _G.arg or {}
local code = main(argv)
-- nvim -l swallows os.exit(); use :cquit to propagate exit code to the shell.
if code == 0 then
  vim.cmd("quit")
else
  vim.cmd("cquit " .. tostring(code))
end
