## Why

当前 `:Theme`、`ThemePicker` 与上游 colorscheme 入口暴露十余个主题及变体，既包含重复的 Catppuccin/Monokai 变体，也包含已不再需要的 Tokyo Night、Kanagawa、Apprentice 和 Porcelain White。需要把所有用户可达主题入口收敛到明确的五项白名单，避免入口之间结果不一致和持久化旧值重新引入已移除主题。

## What Changes

- **BREAKING**：主题公开集合缩减为且仅为 `monokai_ristretto`、`rider-light`、`ubuntu-terminal`、`unokai`、`catppuccin`。
- `:Theme` completion、自研 `ThemePicker`、`<leader>ut` 与上游 `<leader>uC` 入口统一复用同一五项注册表。
- 删除旧主题 alias；旧持久化值在启动时回退并迁移为 `monokai_ristretto`。
- 删除不再需要的 Tokyo Night/Kanagawa 插件声明与 lock entries，以及 Apprentice/Porcelain White 本地 colorscheme 文件。
- 增加回归，冻结五个 canonical name、显示名称、顺序、加载能力和旧值迁移行为。

## Capabilities

### New Capabilities

- `curated-theme-entrypoints`: 主题白名单、所有主题入口一致性、持久化值校验与回退契约。

### Modified Capabilities

- 无。

## Impact

- 修改 `lua/theme.lua`、`lua/plugins/colorscheme.lua`、`lua/config/lazy.lua`、`lua/config/keymaps.lua`、`lua/highlights.lua` 与 `lazy-lock.json`。
- 删除 `colors/apprentice.lua`、`colors/porcelain-white.lua`。
- 更新 theme/keymap/cheatsheet 回归与两种 cheatsheet surface。
- 不引入新依赖；继续复用现有 Monokai、Catppuccin 插件、本地 Rider/Ubuntu 主题和 Neovim 内置 Unokai。
