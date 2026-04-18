-- Comprehensive test of is_dependent_at_cursor() across template forms.
-- Tests are real UE engine source positions, not synthetic.

local cases = {
  -- {file, line, token, expected_dep, label}

  -- 1. The original report: TShaderClass::FParameters::FTypeInfo::GetStructMetadata
  --    Pattern: template<typename TShaderClass>
  {"<PROJ_DRIVE>/UEProj/Engine/Source/Runtime/RenderCore/Public/ShaderParameterStruct.h",
    349, "TShaderClass",      true,  "chain root (typename T)"},
  {"<PROJ_DRIVE>/UEProj/Engine/Source/Runtime/RenderCore/Public/ShaderParameterStruct.h",
    349, "FParameters",       true,  "chain middle"},
  {"<PROJ_DRIVE>/UEProj/Engine/Source/Runtime/RenderCore/Public/ShaderParameterStruct.h",
    349, "FTypeInfo",         true,  "chain middle"},
  {"<PROJ_DRIVE>/UEProj/Engine/Source/Runtime/RenderCore/Public/ShaderParameterStruct.h",
    349, "GetStructMetadata", true,  "chain rightmost"},

  -- 2. EnableIf.h:56  using type = typename Func::Type;
  --    Pattern: template<typename Func>  (or wherever Func is template param)
  {"<PROJ_DRIVE>/UEProj/Engine/Source/Runtime/Core/Public/Templates/EnableIf.h",
    56,  "Func",              true,  "typename Func::Type — Func is template param"},
  {"<PROJ_DRIVE>/UEProj/Engine/Source/Runtime/Core/Public/Templates/EnableIf.h",
    56,  "Type",              true,  "::Type member of dependent Func"},

  -- 3. Overload.h:64  using InvocableTypes::operator()...;
  --    Pattern: template<typename... InvocableTypes>  — VARIADIC
  {"<PROJ_DRIVE>/UEProj/Engine/Source/Runtime/Core/Public/Templates/Overload.h",
    64, "InvocableTypes",     true,  "variadic typename... InvocableTypes"},

  -- 4. NEGATIVE: ShaderParameterStruct.h:349 also contains a non-dependent
  --    type name `FShaderParametersMetadata` (declared as concrete struct
  --    elsewhere in UE). Cursor on it must NOT trigger early-bail.
  {"<PROJ_DRIVE>/UEProj/Engine/Source/Runtime/RenderCore/Public/ShaderParameterStruct.h",
    349, "FShaderParametersMetadata", false, "negative: concrete type, not in template-param chain"},
  {"<PROJ_DRIVE>/UEProj/Engine/Source/Runtime/RenderCore/Public/ShaderParameterStruct.h",
    349, "ParametersMetadata",        false, "negative: local variable, not qualified"},

  -- 5. NEGATIVE: a fully-qualified call from a non-template function.
  --    Pick line 64 of Overload.h but cursor on `operator` — that's not
  --    `InvocableTypes`-rooted at the parser level (it's an operator-call).
  --    Actually the chain root IS InvocableTypes, so this should still be
  --    dependent — keep as positive sanity:
  {"<PROJ_DRIVE>/UEProj/Engine/Source/Runtime/Core/Public/Templates/Overload.h",
    64, "operator",           true,  "still dependent — operator() is rightmost in InvocableTypes::operator()"},

  -- 6. EDGE CASE: `template <typename T>` followed by `TFoo<T>::Member`
  --    Decay.h:45 has `TRemoveReference<T>::Type` — here the LHS is a
  --    template_type, not a qualified_identifier scope chain rooted at T.
  --    My algorithm finds qualified_identifier outermost, but its leftmost
  --    via field("scope") on the template_type may not yield "T".
  --    Document expected behavior: this case may NOT be detected (false neg).
  {"<PROJ_DRIVE>/UEProj/Engine/Source/Runtime/Core/Public/Templates/Decay.h",
    45, "Type",               nil,   "EDGE: TRemoveReference<T>::Type — template_type LHS"},
}

local function run(file, line, target_token, expect_dep, label)
  vim.cmd("edit! " .. vim.fn.fnameescape(file))
  local ok, parser = pcall(vim.treesitter.get_parser, 0, "cpp")
  if not ok then
    print(string.format("SKIP %s:%d  no parser", vim.fn.fnamemodify(file, ":t"), line))
    return false
  end
  parser:parse()

  local L = vim.api.nvim_buf_get_lines(0, line - 1, line, false)[1] or ""
  local col = L:find(target_token, 1, true)
  if not col then
    print(string.format("MISS %s:%d token %q not on line", vim.fn.fnamemodify(file, ":t"), line, target_token))
    return false
  end
  vim.api.nvim_win_set_cursor(0, { line, col - 1 })

  package.loaded["utils.ue_goto.symbol"] = nil
  local symbol = require("utils.ue_goto.symbol")
  local dep, root, chain = symbol.is_dependent_at_cursor()
  local pass = (dep == expect_dep)
  print(string.format("[%s] %-30s:%d cw=%-22s dep=%-5s root=%-12s | %s",
    pass and "OK  " or "FAIL",
    vim.fn.fnamemodify(file, ":t"), line,
    vim.fn.expand("<cword>"),
    tostring(dep), tostring(root or "-"),
    label))
  return pass
end

local ok_count, total = 0, 0
for _, c in ipairs(cases) do
  total = total + 1
  -- expect_dep == nil means "edge case, just report what we got"
  if c[4] == nil then
    vim.cmd("edit! " .. vim.fn.fnameescape(c[1]))
    local parser = vim.treesitter.get_parser(0, "cpp"); parser:parse()
    local L = vim.api.nvim_buf_get_lines(0, c[2] - 1, c[2], false)[1] or ""
    local col = L:find(c[3], 1, true)
    if col then
      vim.api.nvim_win_set_cursor(0, { c[2], col - 1 })
      package.loaded["utils.ue_goto.symbol"] = nil
      local symbol = require("utils.ue_goto.symbol")
      local dep, root, _chain = symbol.is_dependent_at_cursor()
      print(string.format("[INFO] %-30s:%d cw=%-22s dep=%-5s root=%-12s | %s",
        vim.fn.fnamemodify(c[1], ":t"), c[2], vim.fn.expand("<cword>"),
        tostring(dep), tostring(root or "-"), c[5]))
    end
    ok_count = ok_count + 1 -- don't count edge as failure
  elseif run(unpack(c)) then
    ok_count = ok_count + 1
  end
end
print(string.format("\n=== %d/%d (positive+negative cases passed; INFO rows are edge-case observations) ===", ok_count, total))

vim.cmd("qa!")
