## MODIFIED Requirements

### Requirement: 所有项目主题入口共享白名单

`:Theme [name]`、`:ThemePicker`、`<leader>ut` 与 `<leader>uC` SHALL 复用同一注册表和 picker；任何入口 MUST NOT 绕到列举 runtimepath 全部 colorscheme 的上游 picker。直接设置只接受 canonical name，旧 alias 与未注册的 theme/flavor/variant name MUST 被拒绝。

#### Scenario: 两个键位打开主题选择

- **WHEN** 用户按 `<leader>ut` 或 `<leader>uC`
- **THEN** 两者均执行 `ThemePicker` 并展示同一六项集合

#### Scenario: 设置 canonical theme

- **WHEN** 用户执行 `:Theme <name>` 且 `<name>` 是六个 canonical name 之一
- **THEN** 系统加载该主题并按现有持久化策略保存 canonical name

#### Scenario: 设置 Sonokai Espresso

- **WHEN** 用户执行 `:Theme sonokai-espresso` 或从 picker 选择 Sonokai Espresso
- **THEN** 系统在执行 `:colorscheme sonokai` 前强制 `g:sonokai_style = "espresso"`，并持久化 `sonokai-espresso`
- **AND** 使用 VS Code Sonokai Espresso 0.2.9 的编辑区、选区、搜索、浮窗、侧栏、标签与状态栏配色；沿用现有 Sonokai 插件，不新增主题入口或依赖。RGBA 背景按 editor.background 合成为 Neovim RGB。

#### Scenario: Espresso 切换与启动重放

- **WHEN** 启动恢复、ThemePicker 预览或 `ColorScheme` 重新应用 Sonokai Espresso
- **THEN** VS Code 适配在主题加载后重放，普通注释与关键字不额外强制粗斜体；仅内建类型与 storage modifier 保留原主题斜体语法
- **AND** 切换至其他主题后不残留 Espresso 配色覆盖

#### Scenario: 设置未注册入口

- **WHEN** 用户执行 `:Theme tokyonight`、`:Theme catppuccin-mocha`、`:Theme sonokai`、`:Theme sonokai-maia` 或其他不在六项白名单中的名称
- **THEN** 系统拒绝该值、给出可见错误，且不加载或持久化它
