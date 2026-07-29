## 1. 主题注册表与状态迁移

- [x] 1.1 把 `lua/theme.lua` 收敛为有序五项 `THEMES` 注册表，并让 completion、picker、校验、label 与 plugin load 从它派生。
- [x] 1.2 删除旧 aliases 和 flavor entries，设默认 `monokai_ristretto`，使非法持久化值在启动前回退并迁移。
- [x] 1.3 处理 Catppuccin runtime flavor name，使 picker 的公开 current identity 保持 `catppuccin`。

## 2. 入口与依赖清理

- [x] 2.1 将 `<leader>ut` 与 `<leader>uC` 都接到 `ThemePicker`，保持 VeryLazy `nowait` override。
- [x] 2.2 禁用 LazyVim Tokyo Night、删除 Kanagawa spec，更新 lazy install fallback 与 `lazy-lock.json`。
- [x] 2.3 删除 `colors/apprentice.lua`、`colors/porcelain-white.lua`，同步 generic highlights 的自包含主题跳过清单。

## 3. 回归与文档

- [x] 3.1 重写 `tests/cases/theme_spec.lua`，冻结五项名称/label/顺序、旧值迁移、旧入口拒绝和逐项加载。
- [x] 3.2 更新 keymap 与 cheatsheet 回归，覆盖 `<leader>uC` 不再打开上游全量 picker。
- [x] 3.3 更新 float/Markdown cheatsheet，列明五个 canonical name。
- [x] 3.4 运行 `theme`、`smoke`、`keymaps`、`commands`、`cheatsheet`、`structure` filters 与全量回归。
- [x] 3.5 在 `docs/changelog.md` Unreleased 追加记录，Validation 写明实际范围与结果。
- [x] 3.6 运行 `openspec validate limit-theme-entrypoints --strict`，完成后归档 change 并验证主规格。
