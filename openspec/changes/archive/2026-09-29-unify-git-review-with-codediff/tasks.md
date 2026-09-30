## 1. 基线与迁移保护

- [x] 1.1 复核目标文件并行改动、当前有效 Git 键位和插件版本，记录范围；读当前探针并处置相关失败，不触碰其他 SuperUnity 工作。
- [x] 1.2 在隔离临时 Git 仓库补齐清理前缺失的行为基线：`-G` 搜索、特殊路径/rename、文件/选中行历史、Fugitive 专项入口、六类非 Git sidebar；记录 AGS reflog 占位现状而非把它当通过。
- [x] 1.3 记录可比的 Diffview 大仓只读基线（并发新增按 design 的逐次清单差异核对并披露，不冒称冻结输入）（文件覆盖、输入大小、宿主负载、冷/暖缓存、每动作至少 20 次、主循环和 CPU/RSS/Git 进程数据），不改变真实 index 或用户 buffer。

## 2. CodeDiff 隔离接入

- [x] 2.1 选择并记录可验证的 CodeDiff pin 与匹配原生库版本、来源、平台/架构及校验值；在隔离配置完成安装，验证缺库/错架构明确失败且正常打开不隐式下载。
- [x] 2.2 配置完整文件双栏、默认展开未改区域、Changes/Staged/Conflicts 和 untracked 覆盖；验证删除与二进制提示、全文搜索及文件/hunk 导航。
- [x] 2.3 使用真实 fixture index 验证 hunk 暂存/取消暂存/丢弃确认、混合 staged/unstaged、纯删除、CRLF/无末尾换行及不支持操作拒绝；不只断言映射存在。
- [x] 2.4 验证未保存 buffer 和外部 index/文件更新的保护、失败后的恢复与位置保持；需要上游修补时依既有 workaround 契约隔离，不自研第二套 patch 引擎。

## 3. 默认工作流及专项入口

- [x] 3.1 增加最少的 Git 路由，按 design 键位表统一 root/path/ref；验证普通文件、虚拟 buffer、cwd 不同仓库、worktree、重复打开/关闭，保留 `gv/gV` 与 Visual `gv` 的 Diffview 行为。
- [x] 3.2 将现有 Neogit pin 接入 CodeDiff + Snacks，禁用其 Diffview/Telescope 集成；验证提交/取消返回原审阅、stash/rebase/reflog 可用及错误路径，不自动 push。
- [x] 3.3 将 AGS 内容查询迁至 Snacks 的异步 `-G --pickaxe-all` finder，验证与 `-S`/消息查询不同的 fixture、文件范围、rename-follow、取消和陈旧查询隔离；结果确认打开 CodeDiff。
- [x] 3.4 迁移 branch/commit/range/file history 选择与默认 status/commit picker 确认动作；验证两点/三点范围、根提交、merge 父版本、选中行追溯及查询不执行 checkout；Fugitive 专项能力保留。
- [x] 3.5 消除 LazyVim hunk 前缀与内容搜索冲突，区分 Gitsigns 普通 buffer 和 CodeDiff buffer 的操作 owner；在 VeryLazy/on_attach 之后验证最终键位，分别验证 Diffview/CodeDiff 的打开顺序不互相抢占。

## 4. 性能门禁和冗余清理

- [x] 4.1 按 design 的完整覆盖和可比负载复测 CodeDiff（并发输入差异单列）：暖打开/切文件 p95 ≤ Diffview 基线 1.2 倍，hunk p95 ≤ max(基线×1.2, 2ms)（修订理由见 design，保留原比例失败记录），20ms 心跳额外延迟 p95 ≤ 50ms，无接线造成的 >100ms 同步停顿；失败先修复，不切默认并宣称完成。
- [x] 4.2 验证空闲 60 秒无 Git 自激循环、关闭后 CodeDiff 自有后台活动归零，并保留 Gitsigns K42 限制；不终止用户独立打开的 Diffview。
- [x] 4.3 在能力迁移和性能门禁通过后切换默认入口，删除 advanced-git-search 配置/依赖以及无其他消费者的 Telescope 配置/lock 项；保留 Diffview 插件与按需入口、Snacks telescope 布局和公共 helper。
- [x] 4.4 移除 Neovim 内 Lazygit 默认键位和菜单入口，`gg/gG` 路由 CodeDiff；保留宿主二进制/配置，验证上游延迟加载不会重建旧绑定。
- [x] 4.5 将 `vg` 及侧栏菜单 Git 项路由默认审阅，移除 Trouble Git mode 和仅服务它的查询/缓存；保留其他六类视图、共享 source 文件与对应回归。只删除已证明无调用的 Git 专用兼容层。

## 5. 回归、文档和交付

- [x] 5.1 为统一审阅能力建立真实集成回归及能力守卫；执行 `review_editor`、`keymaps`、`commands`、`cheatsheet`、`smoke`、`structure` 和新增 Git 回归，执行受影响 Lua 的仓库 lint/static checks，不用假原生库冒充验收。
- [x] 5.2 同步本 change 的 delta specs、治理导航与测试 filter 映射，更新 cheatsheet/用户文档，明确默认 CodeDiff、按需 Diffview、删除入口及能力迁移去向。
- [x] 5.3 在 changelog 记录实际验证范围、结果、spec 处置和大仓证据；提交/合并前执行全量 `nvim --headless -l tests/run.lua`，逐项处置失败；未得到用户指令不执行 commit/push/tag。
- [x] 5.4 复核无无关文件改动，记录版本化配置回退方式与未测平台；只有功能及性能证据齐全才标记实现完成。Diffview 的最终删除不在本 change 任务中。

## 交付证据与范围

- 版本记录：`docs/release_2.0.0.md`；完整证据/限制：`docs/git-review-delivery.md`，安全聚合：`docs/git-review-benchmark-2026-09-29.json`。
- 冻结版本 required-native 全量 2338/2338、0 failed/0 skipped；真实启动无需手工注入 setup，旧依赖退出有效图。
- 性能按 design 中明确修订的 hunk 2ms预算及可比覆盖条件验收；原纯比例失败/早期输入漂移记录保留，未放宽100ms同步停顿限制。
- 原生库实际验收平台为 Windows x64；缺库路径已验证。未实测其他平台/架构；没有拿伪库作为通过证据。Snacks 取消与陈旧结果隔离做已安装源码闭环，未宣称完成GUI连续输入压力测试。
- 实现验收时未重启现有用户会话、未执行 commit/push/tag；随后用户授权 sync/archive/commit/push，tag 仍待授权。Diffview 保留，其他SuperUnity change与既存C++问题未标记完成。
