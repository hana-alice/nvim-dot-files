## MODIFIED Requirements

### Requirement: 快捷键绑定回归

回归套件 SHALL 验证关键 keymap 在加载 `lua/config/keymaps.lua` 后，于对应模式下存在且映射到预期命令或行为。校验前 SHALL 设置 `vim.g.mapleader = " "`、`vim.g.maplocalleader = " "` 并调用 `require("ue").setup()`，使 `<leader>` 前缀与依赖命令就绪。Git 键位 SHALL 另在插件延迟加载和 buffer 附加完成后验证最终行为，防止继承入口覆盖迁移结果。

#### Scenario: DAP 功能键多模式绑定
- **WHEN** keymap 用例加载完成
- **THEN** `<F5>`/`<F6>`/`<F9>`/`<F10>`/`<F11>`/`<S-F11>` 在 `n`、`i`、`t`、`v` 四种模式下均有映射
- **AND** `<F5>` 映射到 `UEDAPContinue`、`<F9>` 映射到 `UEDAPToggleBreakpoint`、`<F10>` 映射到 `UEDAPStepOver`

#### Scenario: leader 系列绑定存在且指向预期命令
- **WHEN** keymap 用例查询 normal 模式映射
- **THEN** `<leader>?` → `UECheatsheet`、`<leader>uW` → `WindowTitle`、`<leader>db` → `UEDAPToggleBreakpoint`、`<leader>dc` → `UEDAPContinue`、`<leader>da` 含 `UEDAPAttach`
- **AND** `<leader>vv`/`<leader>vb` 等非 Git sidebar 键均有映射，`<leader>vg` 转入统一 Git 审阅
- **AND** `<leader>ub` → `UEBuild`、`<leader>ul` → `UELaunch`（由 VeryLazy 覆盖应用后）

#### Scenario: 核心编辑/导航键绑定
- **WHEN** keymap 用例读取映射
- **THEN** `gd`、`gr`、`gc`（normal/visual）、`gcc` 均有映射
- **AND** Windows 平台下 cmdline 模式 `<C-v>` 映射为 `<C-r>+`、insert 模式 `<C-v>` 映射为 `<C-r><C-o>+`

#### Scenario: keymap 查询辅助可用
- **WHEN** 用例通过 harness 的 keymap 查询辅助按 `(mode, lhs)` 检索
- **THEN** 返回该映射的 rhs/callback 信息或 nil
- **AND** 查询不存在的映射返回 nil 而非报错

#### Scenario: Git 入口在插件加载后保持一致
- **WHEN** LazyVim 的延迟映射和 Git buffer 映射均已生效
- **THEN** `<leader>gg/vg` 进入默认完整文件审阅，`<leader>gG` 使用 cwd 仓库，`<leader>gn` 进入当前审阅仓库的 Git 管理
- **AND** `<leader>gv/gV`、Visual `<leader>gv` 保留 Diffview 专项入口，不被默认路由覆盖
- **AND** 原终端 Git 默认入口不因插件加载而复活
- **AND** 内容搜索和 hunk 操作没有相互等待的前缀冲突，普通编辑与审阅分别只执行自己的 hunk handler
