-- Inspect TS structure for the new case: Object->GetScriptStruct
-- Where Object: SourceItemType*  (typedef ExternalSourceItemType SourceItemType)
-- And ExternalSourceItemType is a template parameter on the enclosing class.

local file = "<PROJ_DRIVE>/UEProj/Engine/Source/Runtime/Net/Iris/Public/Iris/Serialization/PolymorphicNetSerializerImpl.h"
vim.cmd("edit " .. file)
local parser = vim.treesitter.get_parser(0, "cpp")
parser:parse()

local function inspect_at(line, token)
  local L = vim.api.nvim_buf_get_lines(0, line - 1, line, false)[1] or ""
  local col = L:find(token, 1, true)
  if not col then print("token", token, "not on line", line); return end
  vim.api.nvim_win_set_cursor(0, { line, col - 1 })
  local node = parser:parse()[1]:root():descendant_for_range(line - 1, col - 1, line - 1, col - 1)
  print(string.format("\n=== line %d cursor on %q col=%d ===", line, token, col - 1))
  local n = node
  for d = 0, 10 do
    if not n then break end
    local sr, sc, er, ec = n:range()
    local txt = vim.treesitter.get_node_text(n, 0):sub(1, 70):gsub("\n", "\\n")
    print(string.format("  %2d %-30s [%d:%d-%d:%d] %s", d, n:type(), sr, sc, er, ec, txt))
    n = n:parent()
  end
end

-- The reported case
inspect_at(110, "GetScriptStruct")
inspect_at(110, "Object")
inspect_at(110, "DestroyStruct")
inspect_at(110, "ScriptStruct")
-- also line 109 Object->GetScriptStruct
inspect_at(109, "Object")
inspect_at(109, "GetScriptStruct")
vim.cmd("qa!")
