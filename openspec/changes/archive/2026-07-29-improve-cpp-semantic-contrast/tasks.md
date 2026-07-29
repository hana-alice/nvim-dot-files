## 1. 语义角色实现

- [x] 1.1 在 `lua/highlights.lua` 增加六主题 palette-source profile 与安全的 role 应用 helper。
- [x] 1.2 统一 Treesitter、clangd semantic token、Blink/nvim-cmp completion 的 type/field/parameter/variable/function/enum/macro/namespace 映射。
- [x] 1.3 统一 declaration/definition、readonly/static 与 deprecated modifier 的非颜色字形强调，并确保所有白名单主题经过最终语义层。

## 2. 回归与交付

- [x] 2.1 扩展 `tests/cases/theme_spec.lua`，逐主题断言关键角色对比、Treesitter/LSP/completion 一致性及 ColorScheme 重放。
- [x] 2.2 在真实 clangd C++ buffer 中验证 class/property/parameter token，并把新配置热加载到当前 Neovide。
- [x] 2.3 更新 `docs/changelog.md`，运行 `theme`、`smoke` 与全量回归。
- [x] 2.4 运行 `openspec validate improve-cpp-semantic-contrast --strict`，完成并归档 change。
