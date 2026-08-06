## Why

现有主题白名单已收敛为固定集合，但缺少用户指定的 Sonokai Espresso。需要把 `sainnhe/sonokai` 的 `espresso` variant 作为一个明确、可持久化的 canonical theme 接入现有统一入口，而不是暴露 Sonokai 的全部 variants。

## What Changes

- 新增外部主题依赖 `sainnhe/sonokai`，按需加载。
- 新增唯一公开入口 `sonokai-espresso`（显示名 `Sonokai Espresso`），加载前固定 `g:sonokai_style = "espresso"`，实际执行 `:colorscheme sonokai`。
- `:Theme` completion、ThemePicker、`<leader>ut` 与 `<leader>uC` 的白名单从五项扩展为六项；不暴露 Sonokai Default/Atlantis/Andromeda/Shusia/Maia。
- 更新持久化/current identity 映射、回归、cheatsheet 与主题主规格。

## Capabilities

### New Capabilities

- 无。

### Modified Capabilities

- `curated-theme-entrypoints`: 公开主题白名单增加 Sonokai Espresso，并规定 variant 固定和 runtime colorscheme identity 映射。

## Impact

- 修改 `lua/theme.lua`、`lua/plugins/colorscheme.lua`、`lazy-lock.json`。
- 更新 `tests/cases/theme_spec.lua`、两种 cheatsheet surface 与 changelog。
- 修改并归档 OpenSpec `curated-theme-entrypoints` delta。
- 引入用户明确指定的 `sainnhe/sonokai`；不增加其他依赖或 Sonokai variants。
