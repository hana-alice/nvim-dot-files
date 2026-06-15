## ADDED Requirements

### Requirement: 快捷键绑定回归

回归套件 SHALL 验证关键 keymap 在加载 `lua/config/keymaps.lua` 后，于对应模式下存在且映射到预期命令或行为。校验前 SHALL 设置 `vim.g.mapleader = " "`、`vim.g.maplocalleader = " "` 并调用 `require("ue").setup()`，使 `<leader>` 前缀与依赖命令就绪。

#### Scenario: DAP 功能键多模式绑定

- **WHEN** keymap 用例加载完成
- **THEN** `<F5>`/`<F6>`/`<F9>`/`<F10>`/`<F11>`/`<S-F11>` 在 `n`、`i`、`t`、`v` 四种模式下均有映射
- **AND** `<F5>` 映射到 `UEDAPContinue`、`<F9>` 映射到 `UEDAPToggleBreakpoint`、`<F10>` 映射到 `UEDAPStepOver`

#### Scenario: leader 系列绑定存在且指向预期命令

- **WHEN** keymap 用例查询 normal 模式映射
- **THEN** `<leader>db` → `UEDAPToggleBreakpoint`、`<leader>dc` → `UEDAPContinue`、`<leader>da` 含 `UEDAPAttach`
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

### Requirement: 用户命令注册回归

回归套件 SHALL 验证配置定义的用户命令在相应 setup 调用后均已注册（`vim.fn.exists(":Cmd") == 2`）。

#### Scenario: UE 命令全量注册

- **WHEN** 用例调用 `require("ue").setup()` 后查询
- **THEN** 全部 `UE*` 命令（含 `UEBuild`、`UEPrepare`、`UEIndexNow`、`UEDAPAttach`、`UEDAPLaunch`、`UEDAPTab`、`UEExportCompileCommands`、`UEPaths` 等）均 `exists == 2`
- **AND** 任一命令缺失时用例 FAIL 并打印缺失命令名

#### Scenario: 辅助命令注册

- **WHEN** 用例加载 `lua/config/keymaps.lua` 后查询
- **THEN** `Restart`、`RestartDetect`、`UEDefStatus` 均 `exists == 2`

#### Scenario: workarounds 命令在 setup 后注册

- **WHEN** 用例调用 `require("workarounds").setup({ auto_apply = false })`
- **THEN** `WorkaroundList`、`WorkaroundStatus`、`WorkaroundEnable`、`WorkaroundDisable` 均 `exists == 2`
