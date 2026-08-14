# keymap-command-regression Specification

## Purpose

定义针对本 Neovim 配置中快捷键绑定与用户命令注册的回归测试覆盖范围：验证关键 keymap 在加载后于对应模式存在且指向预期命令或行为，并验证配置定义的用户命令在相应 setup 调用后均已注册，确保「开发完跑一遍」即可发现键位与命令层面的回归。

## Requirements

### Requirement: 快捷键绑定回归

回归套件 SHALL 验证关键 keymap 在加载 `lua/config/keymaps.lua` 后，于对应模式下存在且映射到预期命令或行为。校验前 SHALL 设置 `vim.g.mapleader = " "`、`vim.g.maplocalleader = " "` 并调用 `require("ue").setup()`，使 `<leader>` 前缀与依赖命令就绪。

#### Scenario: DAP 功能键多模式绑定

- **WHEN** keymap 用例加载完成
- **THEN** `<F5>`/`<F6>`/`<F9>`/`<F10>`/`<F11>`/`<S-F11>` 在 `n`、`i`、`t`、`v` 四种模式下均有映射
- **AND** `<F5>` 映射到 `UEDAPContinue`、`<F9>` 映射到 `UEDAPToggleBreakpoint`、`<F10>` 映射到 `UEDAPStepOver`

#### Scenario: leader 系列绑定存在且指向预期命令

- **WHEN** keymap 用例查询 normal 模式映射
- **THEN** `<leader>?` → `UECheatsheet`、`<leader>uW` → `WindowTitle`、`<leader>db` → `UEDAPToggleBreakpoint`、`<leader>dc` → `UEDAPContinue`、`<leader>da` 含 `UEDAPAttach`
- **AND** `<leader>vv`/`<leader>vb`/`<leader>vg` 等 sidebar 键均有映射
- **AND** `<leader>ub` → `UEBuild`、`<leader>ul` → `UELaunch`（由 VeryLazy 覆盖应用后）

#### Scenario: 核心编辑/导航键绑定

- **WHEN** keymap 用例查询映射
- **THEN** `gd`、`gr`、`gc`（normal/visual）、`gcc` 均有映射
- **AND** Windows 平台下 cmdline 模式 `<C-v>` 映射为 `<C-r>+`、insert 模式 `<C-v>` 映射为 `<C-r><C-o>+`

#### Scenario: keymap 查询辅助可用

- **WHEN** 用例通过 harness 的 keymap 查询辅助按 `(mode, lhs)` 检索
- **THEN** 返回该映射的 rhs/callback 信息或 nil
- **AND** 查询不存在的映射返回 nil 而非报错

### Requirement: 快捷键帮助可搜索且保留分类

浮动 cheatsheet SHALL 提供 `/` 实时搜索入口；搜索 SHALL 同时覆盖快捷键、描述和原始分类，并在结果界面保留 `Tab › Section` 两级分类。用于展示成对大小写命令的空格分隔符 SHALL 不妨碍直接组合查询。

#### Scenario: mixed-case 成对快捷键可直接发现

- **WHEN** 用户在 `<leader>?` 浮窗按 `/` 并输入 `wW`
- **THEN** 结果直接包含 `w / W`
- **AND** 该结果显示为 `Basics › Motions`
- **WHEN** 用户输入 `aA`
- **THEN** 结果直接包含 `a / A`
- **AND** 该结果显示为 `Basics › Modes`

#### Scenario: 搜索交互与分类回归

- **WHEN** 回归套件真实喂入 `/wW<CR>`
- **THEN** cheatsheet 进入 `wW` 搜索状态
- **AND** 实际浮窗 extmark 内容包含 `Basics › Motions` 与 `w / W`
- **AND** 搜索大小写不敏感，每条命中均携带非空 tab 与 section 分类

### Requirement: 用户命令注册回归

回归套件 SHALL 验证配置定义的用户命令在相应 setup 调用后均已注册（`vim.fn.exists(":Cmd") == 2`）。

#### Scenario: UE 命令全量注册

- **WHEN** 用例调用 `require("ue").setup()` 后查询
- **THEN** 全部 `UE*` 命令（含 `UEBuild`、`UEPrepare`、`UEIndexNow`、`UEDAPAttach`、`UEDAPLaunch`、`UEDAPTab`、`UEExportCompileCommands`、`UEPaths` 等）均 `exists == 2`
- **AND** 任一命令缺失时用例 FAIL 并打印缺失命令名

#### Scenario: 辅助命令注册

- **WHEN** 用例加载 `lua/config/keymaps.lua` 后查询
- **THEN** `Restart`、`RestartDetect`、`UEDefStatus`、`WindowTitle`、`WindowTitleReset` 均 `exists == 2`

### Requirement: 系统窗口标题命名

配置 SHALL 允许为当前 Neovim/Neovide 系统窗口设置会话级名称，并 SHALL 提供恢复 Neovim 自动标题的明确路径。自定义名称进入 `'titlestring'` 时 SHALL 按字面显示，不得把用户输入当作 statusline 表达式执行；终端控制字符 SHALL 被移除。

#### Scenario: 快捷键输入名称

- **WHEN** 用户按 `<leader>uW` 并确认一个非空名称
- **THEN** 当前系统窗口标题立即显示该名称
- **AND** 名称仅作用于当前 Neovim 会话

#### Scenario: 命令直接设置与恢复自动标题

- **WHEN** 用户执行 `:WindowTitle Build Window`
- **THEN** 系统窗口标题按字面显示 `Build Window`
- **WHEN** 用户执行 `:WindowTitle!`、`:WindowTitleReset`，或在输入框确认空值
- **THEN** 自定义名称被清除并恢复 Neovim 自动标题
- **AND** 取消输入框不改变现有标题

#### Scenario: 标题输入安全且有界

- **WHEN** 名称含 `%{...}`、换行或终端控制字符
- **THEN** 百分号按字面显示，控制字符被折叠为空格
- **AND** 标题最多保留 80 个 Unicode 字符且不会切坏 UTF-8

#### Scenario: workarounds 命令在 setup 后注册

- **WHEN** 用例调用 `require("workarounds").setup({ auto_apply = false })`
- **THEN** `WorkaroundList`、`WorkaroundStatus`、`WorkaroundEnable`、`WorkaroundDisable` 均 `exists == 2`
