## Why

现有 Git 工作流分散在 Diffview、Neogit、Lazygit、Gitsigns、Fugitive、advanced-git-search 和自建 Git sidebar 中，完整文件审阅与 hunk 操作、提交、搜索之间缺少连续体验。用户已明确偏好 CodeDiff 接近 VS Code 的界面；本 change 以完整文件双栏为核心，迁移必要能力后移除重复插件和入口。

## What Changes

- 引入并锁定 `esmuellert/codediff.nvim` 及匹配原生库，作为工作区、暂存区、历史、分支比较与冲突审阅的统一主界面；默认显示完整文件，不以局部 patch 或折叠上下文代替全文。
- 保留 Neogit 处理提交、分支、stash、rebase、reflog，改用 CodeDiff 与 Snacks 集成；Gitsigns 仅负责普通编辑 buffer 的改动标记、blame 和 hunk 操作；Fugitive 暂留历史版本 buffer、全文 blame、quickfix 历史及行范围追溯等专项能力。
- CodeDiff 接管默认日常审阅，Diffview 保留按需使用，包括现有 `<leader>gv/gV`、Visual `<leader>gv` 与原生命令；不把选择 CodeDiff 推断成授权删除 Diffview。Neogit 与通用 picker 默认选择 CodeDiff，不自动同时打开两套界面。
- **BREAKING**：移除 advanced-git-search，使用已有 Snacks / Neogit / Fugitive 承接搜索与版本选择；保留 `git log -G --pickaxe-all` 的改动内容搜索语义，不能用提交消息搜索或 `-S` 偷换。
- 移除 Neogit 对 Telescope 的依赖和集成，清理无其他消费者的 lock 条目；Snacks 的 `telescope` 布局名不属于 Telescope 依赖，不删除该布局。
- **BREAKING**：取消 Neovim 内 Lazygit 的默认快捷键与可发现入口；不卸载宿主的 `lazygit` 可执行程序，不修改其用户配置。
- **BREAKING**：移除自建 Trouble Git 状态视图及仅为其服务的查询/缓存，`<leader>vg` 改为统一审阅入口的兼容别名；保留 buffers、symbols、diagnostics、quickfix、loclist、TODO 等侧栏。
- 统一仓库上下文、文件/hunk 操作范围、刷新与返回位置；基于真实 index 验证部分暂存和取消暂存；并发改动不得被过期视图覆盖。
- 在隔离仓库验证正确性，在代表性真实大仓只读测量延迟与资源占用后再切换默认入口；本提案不声称 CodeDiff 已更快。

## Capabilities

### New Capabilities

- `git-review-workspace`: CodeDiff 完整文件审阅、精确 hunk 操作、Git 管理交接、历史/搜索迁移、依赖收敛及性能验收。

### Modified Capabilities

- `editor-behavior-regression`: Git 文件导航从独立 Trouble sidebar 改为统一审阅，继续保护特殊路径、rename/copy 与原有 picker 交互。
- `keymap-command-regression`: 明确 `<leader>vg` 的新语义，并守护统一 Git 键位、模式范围与被移除入口不再出现。

## Impact

- 运行时预计影响：`lua/plugins/diffview.lua`、`neogit.lua`、`fugitive.lua`、`gitsigns.lua`、`sidebar.lua`、`snacks.lua`，`lua/config/keymaps.lua`，`lua/utils/sidebar.lua`、`lua/trouble/sources/ue_sidebar.lua` 及 Git 帮助内容；新增 CodeDiff 配置和必要的轻量路由。仅在确无调用后删除 Git 专用兼容 helper，不重构公共 `async_launcher`。
- 依赖：新增 CodeDiff + 匹配平台的原生库；退出 advanced-git-search、Telescope 的运行时依赖图。保留按需 Diffview，复用现有 Snacks、Neogit、Gitsigns、Fugitive；本次用户选择构成引入 CodeDiff 的明确范围。
- 测试与文档：相关 Git 集成回归、`review_editor`、`keymaps`、`commands`、`cheatsheet`、`smoke`、`structure`；后续实现提交前全量回归、changelog、spec/知识导航同步。
- 用户已授权实施；实现进度与实际验证见 tasks.md 和交付记录。本 change 不触碰正在进行的 SuperUnity change、UE 索引产物或用户未保存 buffer；写操作测试只使用隔离 fixture 仓库。
