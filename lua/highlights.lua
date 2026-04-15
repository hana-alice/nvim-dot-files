local M = {}

local setup_done = false

local function hl(name)
  local ok, value = pcall(vim.api.nvim_get_hl, 0, { name = name })
  if ok and type(value) == "table" and next(value) then
    value.link = nil
    return value
  end
  return nil
end

local function set_from(targets, source, extra)
  local base = hl(source)
  extra = extra or {}
  for _, target in ipairs(targets) do
    if base then
      vim.api.nvim_set_hl(0, target, vim.tbl_extend("force", base, extra))
    else
      local spec = vim.deepcopy(extra)
      spec.link = source
      vim.api.nvim_set_hl(0, target, spec)
    end
  end
end

function M.apply()
  -- ubuntu-terminal defines its own treesitter/LSP semantic groups inline;
  -- skip the generic overrides so they don't flatten the per-role colours.
  if vim.g.colors_name == "ubuntu-terminal" then
    return
  end

  set_from({
    "@keyword",
    "@keyword.function",
    "@keyword.return",
    "@conditional",
    "@repeat",
    "@exception",
    "@label",
  }, "Keyword", { bold = true })

  set_from({
    "@module",
    "@lsp.type.namespace",
    "@lsp.type.namespace.cpp",
  }, "Include", { bold = true })

  set_from({
    "@type",
    "@type.builtin",
    "@type.definition",
    "@type.qualifier",
    "@lsp.type.type",
    "@lsp.type.type.cpp",
    "@lsp.type.class",
    "@lsp.type.class.cpp",
    "@lsp.type.struct",
    "@lsp.type.struct.cpp",
    "@lsp.type.enum",
    "@lsp.type.enum.cpp",
    "@lsp.type.interface",
    "@lsp.type.typeParameter",
    "@lsp.type.typeParameter.cpp",
  }, "Type", { bold = true })

  set_from({
    "@function",
    "@function.call",
    "@function.method",
    "@function.method.call",
    "@constructor",
    "@lsp.type.function",
    "@lsp.type.function.cpp",
    "@lsp.type.method",
    "@lsp.type.method.cpp",
  }, "Function", { bold = true })

  set_from({
    "@field",
    "@property",
    "@variable.member",
    "@lsp.type.property",
    "@lsp.type.property.cpp",
  }, "Identifier", { italic = true })

  set_from({
    "@parameter",
    "@lsp.type.parameter",
    "@lsp.type.parameter.cpp",
  }, "Identifier", { italic = true })

  set_from({
    "@constant",
    "@constant.builtin",
    "@lsp.type.enumMember",
    "@lsp.type.enumMember.cpp",
  }, "Constant", { bold = true })

  set_from({
    "@constant.macro",
    "@lsp.type.macro",
    "@lsp.type.macro.cpp",
    "@attribute",
    "@attribute.cpp",
  }, "Macro", { bold = true })

  set_from({
    "@comment.documentation",
    "@comment.note",
  }, "Comment", { italic = true })

  set_from({
    "@keyword.hlsl",
    "@type.hlsl",
    "@function.hlsl",
    "@constant.hlsl",
  }, "Keyword", { bold = true })
end

function M.setup()
  if setup_done then
    return
  end
  setup_done = true

  local group = vim.api.nvim_create_augroup("UserSemanticHighlights", { clear = true })
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = group,
    callback = M.apply,
  })

  -- One deferred initial call to apply highlights after the startup colorscheme
  -- has loaded. The ColorScheme autocmd handles all subsequent theme changes.
  vim.schedule(M.apply)
end

return M
