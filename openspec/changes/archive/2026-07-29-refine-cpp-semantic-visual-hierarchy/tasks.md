## 1. 成熟方案审计与实现

- [x] 1.1 审计本机 Rider Light、VS Code Dark+/Light+、Catppuccin、Monokai 与 Sonokai 的角色色族和字形策略。
- [x] 1.2 将 `lua/highlights.lua` 的六主题 profile 收敛为 type/data/local/callable/macro 角色族。
- [x] 1.3 移除基础角色强制 bold/italic，中和常见 clangd modifier，仅保留 deprecated 删除线。

## 2. 回归与交付

- [x] 2.1 更新 `tests/cases/theme_spec.lua`，覆盖关键冲突、允许共享、基础字形和跨 surface 一致性。
- [x] 2.2 在真实 clangd UE C++ buffer 中热加载并视觉验证当前主题。
- [x] 2.3 更新 `docs/changelog.md`，运行 `theme`、`smoke` 与全量回归。
- [x] 2.4 严格验证并归档 OpenSpec change。
