## Why

当前 Neovim Espresso 的界面色和 C++ 角色色与用户正在使用的 VS Code Sonokai Espresso 不一致。
本 change 补录已经实施并验证的主题适配，作为同步和归档的可审计记录。

## What Changes

- 对齐 VS Code Sonokai Espresso 0.2.9 的界面、选区、浮窗与状态栏色。
- 对齐 C++ 类型、字段、参数、函数、枚举与宏角色；限定为 Espresso。
- 保留既有六主题入口与依赖，覆盖切换和启动重放。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `curated-theme-entrypoints`：Espresso 外观映射与切换重放。
- `cpp-semantic-highlighting`：Espresso 的角色色与字体边界。

## Impact

涉及 `lua/sonokai_vscode.lua`、`lua/highlights.lua` 与主题回归。无新依赖、无其他主题行为变更。
