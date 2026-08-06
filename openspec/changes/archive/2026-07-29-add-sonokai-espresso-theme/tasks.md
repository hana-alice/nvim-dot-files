## 1. Sonokai Espresso 接入

- [x] 1.1 在 `lua/plugins/colorscheme.lua` 声明 `sainnhe/sonokai`，使用稳定 plugin name 并在 init 固定 Espresso/performance 配置。
- [x] 1.2 扩展 `lua/theme.lua` registry metadata 与统一加载 helper，加入 `sonokai-espresso`，映射到 runtime colorscheme `sonokai`。
- [x] 1.3 安装 plugin 并更新 `lazy-lock.json`，确认锁定上游 commit。

## 2. 回归与文档

- [x] 2.1 扩展 `tests/cases/theme_spec.lua`，冻结六项集合、Espresso style、variant 重置、current identity 与旧入口拒绝。
- [x] 2.2 更新 float/Markdown cheatsheet 和 anti-drift assertions，列明 Sonokai Espresso canonical name。
- [x] 2.3 运行 `theme`、`smoke`、`keymaps`、`commands`、`cheatsheet`、`structure` filters 与完整启动 probe。
- [x] 2.4 运行全量 `nvim --headless -l tests/run.lua` 并确保全绿。
- [x] 2.5 在 `docs/changelog.md` Unreleased 更新主题条目，Validation 写明实际结果。
- [x] 2.6 运行 `openspec validate add-sonokai-espresso-theme --strict`，归档 change 并验证主规格。
