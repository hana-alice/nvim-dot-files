-- Theme registry + supported colorscheme contracts.

local t = require("tests.harness")
t.bootstrap()

-- `nvim -l` does not bootstrap lazy.nvim, so expose retained external
-- colorscheme roots explicitly for real load checks.
for _, plugin in ipairs({ "monokai.nvim", "catppuccin", "sonokai" }) do
  local path = vim.fn.stdpath("data") .. "/lazy/" .. plugin
  if vim.fn.isdirectory(path) == 1 then
    vim.opt.rtp:prepend(path)
  end
end

local theme = require("theme")
local highlights = require("highlights")
local EXPECTED_NAMES = {
  "monokai_ristretto",
  "rider-light",
  "ubuntu-terminal",
  "unokai",
  "catppuccin",
  "sonokai-espresso",
}
local EXPECTED_LABELS = {
  "Monokai Ristretto",
  "Rider Light",
  "Ubuntu Terminal",
  "Unokai",
  "Catppuccin",
  "Sonokai Espresso",
}

local function with_tmp_state(fn)
  local dir = vim.fn.tempname():gsub("\\", "/")
  vim.fn.mkdir(dir, "p")
  local path = dir .. "/theme.txt"
  theme._set_state_path_for_test(path)
  local ok, err = pcall(fn, path)
  theme._set_state_path_for_test(nil)
  pcall(vim.fn.delete, dir, "rf")
  if not ok then error(err) end
end

local function assert_list_eq(actual, expected, message)
  t.assert_eq(#actual, #expected, (message or "list length") .. " length")
  for index, value in ipairs(expected) do
    t.assert_eq(actual[index], value, (message or "list") .. " item " .. index)
  end
end

t.describe("theme: six-entry public surface", function()
  t.it(":Theme completion contains exactly the six canonical names", function()
    assert_list_eq(theme.complete(), EXPECTED_NAMES, "completion")
  end)

  t.it("picker exposes the same names and labels in stable order", function()
    local names, labels = {}, {}
    for _, item in ipairs(theme.available()) do
      names[#names + 1] = item.name
      labels[#labels + 1] = item.label
    end
    assert_list_eq(names, EXPECTED_NAMES, "picker names")
    assert_list_eq(labels, EXPECTED_LABELS, "picker labels")
  end)

  t.it("saved legacy theme is rejected and migrated to Monokai Ristretto", function()
    with_tmp_state(function(path)
      vim.fn.writefile({ "tokyonight" }, path)
      t.assert_eq(theme.startup(), "monokai_ristretto")
      theme.load_startup()
      t.assert_eq(vim.g.colors_name, "monokai_ristretto")
      t.assert_eq(vim.trim(vim.fn.readfile(path)[1] or ""), "monokai_ristretto")
    end)
  end)

  t.it("saved Sonokai Espresso restores the fixed variant", function()
    with_tmp_state(function(path)
      vim.fn.writefile({ "sonokai-espresso" }, path)
      vim.g.sonokai_style = "maia"
      t.assert_eq(theme.startup(), "sonokai-espresso")
      theme.load_startup()
      t.assert_eq(vim.g.colors_name, "sonokai")
      t.assert_eq(vim.g.sonokai_style, "espresso")
      t.assert_eq(theme.current(), "sonokai-espresso")
      t.assert_eq(vim.trim(vim.fn.readfile(path)[1] or ""), "sonokai-espresso")
      t.assert_true(theme.apply("monokai_ristretto", { persist = false, silent = true }))
    end)
  end)

  t.it("removed aliases and variants are not accepted", function()
    for _, name in ipairs({
      "tokyonight", "kanagawa", "monokai", "monokai_pro", "monokai_soda",
      "catppuccin-mocha", "catppuccin_mocha", "sonokai", "sonokai-maia",
      "porcelain-white", "white", "apprentice",
    }) do
      t.assert_false(theme.apply(name, { persist = false, silent = true }), name .. " must be rejected")
    end
  end)

  t.it("all six canonical themes load", function()
    for _, name in ipairs(EXPECTED_NAMES) do
      local ok = theme.apply(name, { persist = false, silent = true })
      t.assert_true(ok, name .. " should load")
      if name == "catppuccin" then
        t.assert_true((vim.g.colors_name or ""):match("^catppuccin") ~= nil)
      elseif name == "sonokai-espresso" then
        t.assert_eq(vim.g.colors_name, "sonokai")
        t.assert_eq(vim.g.sonokai_style, "espresso")
        t.assert_eq(vim.g.sonokai_better_performance, 0)
        local config = vim.fn["sonokai#get_configuration"]()
        t.assert_eq(config.style, "espresso")
        local normal = vim.api.nvim_get_hl(0, { name = "Normal" })
        t.assert_eq(normal.bg, 0x312C2B, "Espresso Normal background must match the upstream palette")
      else
        t.assert_eq(vim.g.colors_name, name)
      end
      t.assert_eq(theme.current(), name)
    end
    t.assert_true(theme.apply("monokai_ristretto", { persist = false, silent = true }))
  end)

  t.it("Sonokai Espresso resets a mutated variant before every load", function()
    vim.g.sonokai_style = "maia"
    t.assert_true(theme.apply("sonokai-espresso", { persist = false, silent = true }))
    t.assert_eq(vim.g.sonokai_style, "espresso")
    t.assert_eq(vim.fn["sonokai#get_configuration"]().style, "espresso")
    t.assert_eq(theme.current(), "sonokai-espresso")
    t.assert_true(theme.apply("monokai_ristretto", { persist = false, silent = true }))
  end)

  t.it("all six themes use restrained C++ role families aligned across surfaces", function()
    local role_groups = {
      namespace = {
        "@module.cpp", "@lsp.type.namespace.cpp", "CmpItemKindModule", "BlinkCmpKindModule",
      },
      type = {
        "@type.cpp", "@lsp.type.struct.cpp", "CmpItemKindStruct", "BlinkCmpKindStruct",
      },
      field = {
        "@property.cpp", "@lsp.type.property.cpp", "CmpItemKindField", "BlinkCmpKindField",
      },
      parameter = {
        "@variable.parameter.cpp", "@lsp.type.parameter.cpp",
      },
      variable = {
        "@variable.cpp", "@lsp.type.variable.cpp", "CmpItemKindVariable", "BlinkCmpKindVariable",
      },
      ["function"] = {
        "@function.method.cpp", "@lsp.type.method.cpp", "CmpItemKindMethod", "BlinkCmpKindMethod",
      },
      enum_member = {
        "@constant.cpp", "@lsp.type.enumMember.cpp", "CmpItemKindEnumMember", "BlinkCmpKindEnumMember",
        "CmpItemKindConstant", "BlinkCmpKindConstant",
      },
      macro = {
        "@constant.macro.cpp", "@lsp.type.macro.cpp",
      },
    }

    local function fg(group, theme_name)
      local value = vim.api.nvim_get_hl(0, { name = group, link = false }).fg
      t.assert_true(type(value) == "number", theme_name .. " must define foreground for " .. group)
      return value
    end

    for _, name in ipairs(EXPECTED_NAMES) do
      t.assert_true(theme.apply(name, { persist = false, silent = true }))
      highlights.apply()

      local colors = {}
      for role, groups in pairs(role_groups) do
        colors[role] = fg(groups[1], name)
        for index = 2, #groups do
          t.assert_eq(fg(groups[index], name), colors[role],
            name .. " " .. role .. " must match across Treesitter/LSP/completion")
        end
      end

      -- Mature IDE themes use coherent families instead of forcing all roles
      -- into different accents. Only the ambiguity-bearing pairs are required
      -- to differ; namespace/type, enum/field and parameter/local may share.
      for _, pair in ipairs({
        { "type", "field" },
        { "field", "parameter" },
        { "field", "variable" },
        { "function", "variable" },
        { "enum_member", "type" },
        { "macro", "namespace" },
      }) do
        t.assert_true(colors[pair[1]] ~= colors[pair[2]],
          name .. " must distinguish " .. pair[1] .. " from " .. pair[2])
      end

      t.assert_eq(colors.namespace, colors.type, name .. " namespace should join the type family")
      if name ~= "catppuccin" then
        t.assert_eq(colors.enum_member, colors.field, name .. " enum member should join the data family")
      end
      if name ~= "ubuntu-terminal" and name ~= "catppuccin" then
        t.assert_eq(colors.parameter, colors.variable, name .. " parameter should stay in the low-weight local family")
      end

      for role, groups in pairs(role_groups) do
        for _, group in ipairs(groups) do
          local value = vim.api.nvim_get_hl(0, { name = group, link = false })
          t.assert_nil(value.bold, name .. " " .. role .. " base role must not force bold")
          t.assert_nil(value.italic, name .. " " .. role .. " base role must not force italic")
          t.assert_nil(value.strikethrough, name .. " " .. role .. " base role must not strike through")
        end
      end

      for _, group in ipairs({
        "@lsp.mod.declaration.cpp",
        "@lsp.typemod.property.declaration.cpp",
        "@lsp.typemod.method.readonly.cpp",
        "@lsp.typemod.class.abstract.cpp",
        "@lsp.typemod.method.classScope.cpp",
        "@lsp.typemod.variable.globalScope.cpp",
      }) do
        local value = vim.api.nvim_get_hl(0, { name = group, link = false })
        t.assert_nil(value.fg, name .. " " .. group .. " must preserve role foreground")
        t.assert_nil(value.bold, name .. " " .. group .. " must not force bold")
        t.assert_nil(value.italic, name .. " " .. group .. " must not force italic")
        t.assert_nil(value.strikethrough, name .. " " .. group .. " must not strike through")
      end

      local deprecated_hl = vim.api.nvim_get_hl(0, { name = "@lsp.mod.deprecated.cpp", link = false })
      t.assert_true(deprecated_hl.strikethrough == true, name .. " deprecated modifier should strike through")
      t.assert_nil(deprecated_hl.fg, name .. " modifier must not override semantic role foreground")
    end

    t.assert_true(theme.apply("monokai_ristretto", { persist = false, silent = true }))
    highlights.apply()
  end)

  t.it("ColorScheme replays the active profile without leaking the previous theme", function()
    highlights.setup()
    t.assert_true(theme.apply("sonokai-espresso", { persist = false, silent = true }))
    local sonokai_field = vim.api.nvim_get_hl(0, { name = "@lsp.type.property.cpp", link = false }).fg

    t.assert_true(theme.apply("catppuccin", { persist = false, silent = true }))
    local catppuccin_field = vim.api.nvim_get_hl(0, { name = "@lsp.type.property.cpp", link = false }).fg
    local catppuccin_type = vim.api.nvim_get_hl(0, { name = "@lsp.type.struct.cpp", link = false }).fg
    t.assert_true(catppuccin_field ~= sonokai_field, "new theme must not retain Sonokai field RGB")
    t.assert_true(catppuccin_field ~= catppuccin_type, "new theme must immediately restore role contrast")

    t.assert_true(theme.apply("monokai_ristretto", { persist = false, silent = true }))
    highlights.apply()
  end)

  t.it("theme sources remove obsolete plugins and local files", function()
    local config = vim.fn.stdpath("config")
    local source = table.concat(vim.fn.readfile(config .. "/lua/plugins/colorscheme.lua"), "\n")
    local lock = table.concat(vim.fn.readfile(config .. "/lazy-lock.json"), "\n")
    t.assert_contains(source, "tanvirtin/monokai.nvim")
    t.assert_contains(source, "sainnhe/sonokai")
    t.assert_contains(source, 'name = "sonokai"')
    t.assert_contains(source, 'vim.g.sonokai_style = "espresso"')
    t.assert_contains(source, "vim.g.sonokai_better_performance = 0")
    t.assert_contains(lock, '"sonokai"')
    t.assert_contains(source, '"folke/tokyonight.nvim", enabled = false')
    t.assert_true(source:find("rebelot/kanagawa.nvim", 1, true) == nil, "Kanagawa plugin must be removed")
    t.assert_true(lock:find('"tokyonight.nvim"', 1, true) == nil, "Tokyo Night lock entry must be removed")
    t.assert_true(lock:find('"kanagawa.nvim"', 1, true) == nil, "Kanagawa lock entry must be removed")

    local local_themes = {}
    for _, path in ipairs(vim.fn.glob(config .. "/colors/*", true, true)) do
      local_themes[#local_themes + 1] = vim.fn.fnamemodify(path, ":t")
    end
    table.sort(local_themes)
    assert_list_eq(local_themes, { "rider-light.lua", "ubuntu-terminal.lua" }, "local themes")
  end)

  t.it("both theme entry keymaps route to the filtered picker", function()
    local source = table.concat(vim.fn.readfile(vim.fn.stdpath("config") .. "/lua/plugins/colorscheme.lua"), "\n")
    t.assert_contains(source, '{ "<leader>ut", "<leader>uC" }')
    t.assert_contains(source, "ThemePicker")
    t.assert_contains(source, "nowait = true")
  end)
end)
