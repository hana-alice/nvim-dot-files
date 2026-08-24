# curated-theme-entrypoints Specification

## Purpose

把本项目拥有的主题选择 surface 固定为六项白名单，确保 picker、命令补全、键位入口与持久化恢复不会重新暴露旧主题或未注册 variant，同时保留这六项所需的最小主题来源。

## Requirements
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

#### Scenario: 设置未注册入口

- **WHEN** 用户执行 `:Theme tokyonight`、`:Theme catppuccin-mocha`、`:Theme sonokai`、`:Theme sonokai-maia` 或其他不在六项白名单中的名称
- **THEN** 系统拒绝该值、给出可见错误，且不加载或持久化它

### Requirement: 持久化主题不能扩大公开集合

持久化 state SHALL 仅作为六项白名单内的当前选择使用，MUST NOT 被加入 completion 或 picker。state 缺失时默认 SHALL 为 `monokai_ristretto`；state 含旧值、未知值或已删除 alias 时，启动 SHALL 在尝试加载前回退到 `monokai_ristretto` 并把 state 迁移为该 canonical name。

#### Scenario: 合法 state 恢复

- **WHEN** state 保存 `sonokai-espresso`
- **THEN** 启动按 Espresso variant 加载 Sonokai，picker/completion 仍保持固定六项

#### Scenario: 旧 state 迁移

- **WHEN** state 保存 `tokyonight`、`sonokai`、`porcelain-white` 或任意未知名称
- **THEN** 启动不尝试加载该名称，而加载 `monokai_ristretto` 并重写 state

### Requirement: 公开主题集合严格为六项

系统 SHALL 以单一有序注册表定义公开主题，且集合 MUST 恰好为：`monokai_ristretto`（Monokai Ristretto）、`rider-light`（Rider Light）、`ubuntu-terminal`（Ubuntu Terminal）、`unokai`（Unokai）、`catppuccin`（Catppuccin）、`sonokai-espresso`（Sonokai Espresso）。注册表 MUST NOT 包含额外主题或 flavor/variant；Sonokai 的 Default、Atlantis、Andromeda、Shusia、Maia MUST NOT 成为公开入口。

#### Scenario: 查询主题 completion

- **WHEN** `:Theme` 请求 completion candidates
- **THEN** 返回且仅返回上述六个 canonical name

#### Scenario: 打开主题 picker

- **WHEN** 用户打开 `ThemePicker`
- **THEN** picker 按注册表顺序显示且仅显示六项，并显示对应的人类可读名称

### Requirement: 六项主题来源保持可加载

系统 SHALL 保留六个主题所需的最小来源：Monokai plugin 提供 `monokai_ristretto`，Catppuccin plugin 提供 `catppuccin`，Sonokai plugin 的 Espresso variant 提供 `sonokai-espresso`，本地 colorscheme 提供 Rider Light 与 Ubuntu Terminal，Neovim runtime 提供 Unokai。仅服务已删除主题的插件声明、lock entries 和本地 colorscheme MUST 被移除。

#### Scenario: 逐项加载

- **WHEN** 回归依次应用六个 canonical name
- **THEN** 六次加载均成功；Catppuccin flavor 与 Sonokai runtime colorscheme name 分别映射回公开 current identity `catppuccin` 与 `sonokai-espresso`

#### Scenario: Sonokai variant 固定

- **WHEN** 外部代码把 `g:sonokai_style` 改为其他有效 variant 后再次应用 `sonokai-espresso`
- **THEN** 实际加载前该值被重置为 `espresso`

#### Scenario: 审计主题依赖

- **WHEN** 检查项目 plugin declarations、lock file 和 `colors/`
- **THEN** Sonokai 依赖存在，Tokyo Night、Kanagawa、Apprentice 与 Porcelain White 不再作为项目主题来源存在
