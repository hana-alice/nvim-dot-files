## Context

动机见 `proposal.md`。2026-09-29 的只读调查确认以下事实，均不是性能验收结论：

- `lua/plugins/diffview.lua:183` 的 `s` 是整文件暂存；文件内/跨文件 hunk 浏览与 Gitsigns 操作分属两套接线。
- `lua/plugins/neogit.lua` 显式依赖 Diffview、Telescope；已安装 Neogit HEAD 与 `lazy-lock.json` 的 `792c139da736230855e8341ebe6175bb6eb8268b` 一致，该版本已包含 `codediff`、`snacks` 和 `diff_viewer` 配置。无需预设升级 Neogit。
- `lua/plugins/fugitive.lua` 同时声明 Fugitive 和 advanced-git-search。后者的渲染器仅接受 Diffview/Fugitive，不能只把配置字符串改成 CodeDiff。
- advanced-git-search 的内容查询是 `git log -G ... --pickaxe-all`；已装 Snacks 的 `picker/source/git.lua:153` 默认使用 `-S`。前者匹配补丁中的正则，后者判断字符串出现次数变化，不能等同。
- advanced-git-search 的 Snacks `checkout_reflog` 当前只提示未实现；`<leader>gC` 应移至 Neogit reflog，不把旧占位入口当作已存在的可用能力。
- `lua/trouble/sources/ue_sidebar.lua:134` 的 Git 查询排除了 untracked；新工作区须补齐覆盖。该文件还负责 buffers/TODO，不能整文件删除。
- `lua/utils/async_launcher.lua:290` 仍在主线程回调中执行 `opts.run`；延迟调度不证明底层异步。本 change 不重写公共 launcher。
- `lua/plugins/gitsigns.lua:52` 的 K42 watcher 限制必须保留。探针中既存的 C++ 语义/索引、dirty-set/csearch 历史失败本次不处理：由其他工作承接，与 Git UI 无直接依赖；不得将它们标记解决。

上游依据（实施须锁定具体版本后复核，不能把滚动 README 当作已验证 API）：

- https://github.com/esmuellert/codediff.nvim ：完整双栏、hunk 操作、history、原生库和刷新配置。
- https://github.com/NeogitOrg/neogit/blob/master/lua/neogit/integrations/codediff.lua ：CodeDiff 集成交接。
- https://github.com/folke/snacks.nvim/blob/main/lua/snacks/picker/source/git.lua ：现成 Git picker 和查询参数。
- 本仓历史 `da0d911` / `d64c102` / `e374121`：原工具分工，不作为性能结论。

## Goals / Non-Goals

**Goals:**

- 形成默认完整文件审阅工作流，用户无须切换引擎即可完成日常浏览、暂存、取消暂存和提交检查；保留主动选择熟悉的 Diffview 的能力。
- 先以可执行迁移用例保护独有能力，再删除冗余配置/依赖；减少接线而非新增通用 Git 框架。
- 在 Windows/Neovide 真实环境验证库加载、操作正确性和性能；其他宿主只声明实际验证的范围。

**Non-Goals:**

- 不实现自研 diff 算法、patch 引擎、Git 状态数据库或周期性全仓扫描。
- 不卸载宿主 CLI，不清理整个 lazy 数据目录，不变更 Git 全局配置、fsmonitor 或隐私 hooks。
- 不触碰 SuperUnity、CDB、clangd、UE target、公共异步基础设施及其他正在进行的 change。
- 不删除 Fugitive 的独有功能以追求插件数量；不增加 AI/PR 托管平台依赖。

## Decisions

### 1. 一个审阅主界面，必要能力明确分工

| 组件 | 决策 | 迁移后职责 / 删除门禁 |
|---|---|---|
| CodeDiff | 新增 | 工作区、暂存区、指定版本/分支、历史和冲突的完整文件审阅 |
| Neogit | 保留并收敛 | 提交、push/pull、branch、stash、rebase、reflog；所有查看 diff 的动作选择 CodeDiff，picker 选择 Snacks |
| Gitsigns | 保留 | 普通文件的标记、blame、hunk 操作；CodeDiff buffer 内的 hunk 操作归 CodeDiff，避免双重 handler |
| Fugitive | 保留专项功能 | `Gedit :0`、历史版本 buffer、全文 blame、`Gclog`、行范围追溯；不新增竞争的默认 status/diff 入口 |
| Diffview | 保留按需使用 | 保留配置、lock、原生命令和 `gv/gV`、Visual `gv`；通用 picker/Neogit 不再默认依赖它，不自动同时开启 |
| advanced-git-search | 移除 | 内容搜索和 ref 选择迁至 Snacks，结果打开 CodeDiff；reflog 交 Neogit |
| Telescope | 移除 | 移除 Neogit 引用后检查有效依赖图；保留 Snacks 名为 telescope 的布局 |
| Lazygit 集成 | 移除 | 覆盖 LazyVim 自动键位与菜单入口，不删除宿主二进制或用户配置 |
| Trouble Git sidebar | 移除 | 删除 Git mode、专用请求/缓存；菜单的 Git 项改为打开默认审阅的动作，不再是 Trouble mode；其他六类视图保留 |

不选 Diffview 增强作为默认路线：用户已明确选择 CodeDiff，更接近目标且提供 hunk 操作；但用户随后质疑删除 Diffview，确认此处应只切换默认工作流，保留按需入口。是否最终删除留待用户实际使用反馈与能力对比后另行决定，不设为本 change 完成条件。也不只留 CodeDiff：提交管理和部分历史工作流需要其他组件，重写这些功能反而增加维护负担。当前 Gitsigns 已有全文 blame，Fugitive 保留的理由主要是历史/index 原文及 quickfix 工作流，而非宣称它独占全文 blame。

### 2. 完整文件及三种比较语义

默认 `side-by-side`、`compact=false`、左侧 explorer，显示 Changes / Staged / Conflicts 并包含 untracked。未改区域仍可滚动、搜索；用户可主动折叠，不能默认退化成局部 patch。

- Changes：index 与工作区；支持 stage hunk、discard hunk。
- Staged：HEAD 与 index；支持 unstage hunk，不能改工作区内容。
- 指定 ref / history：明确显示两边版本，只读审阅；不沿用本地暂存快捷键造成误写。

重用 CodeDiff 原生动作；若所选版本的动作不满足保护条件，定位上游边界并按 `lua/workarounds/` 契约隔离修补，禁止在配置里拼第二套 patch 引擎。未保存 buffer 必须与磁盘区分：整文件 stage 的输入范围明确；有脏 buffer 时不自动保存，若磁盘/缓冲区语义无法一致则拒绝写操作并说明原因。stage 不能隐式保存或带入其他修改。

hunk 操作前重验所用的文件/index revision；旧快照失效应刷新并要求重新执行，不能盲写整个 index blob。明确的整文件暂存/取消暂存使用操作时的整个磁盘/index 版本，拒绝存在未保存 buffer 的对象；整文件丢弃在确认后重新检查。上述保护不是与外部 Git 进程之间的原子事务。文件暂存成功消失后选相邻条目；仍有剩余 hunk 时保持文件和附近位置。恢复/丢弃须显式确认目标与范围；取消操作不改变任何内容。

当前 pin 的 hunk 边界：LF、CRLF 和 EOF 纯删除已验证；无末尾换行、rename、未跟踪、整文件删除和超过 8 MiB 的文件明确拒绝 hunk 写入，提示使用显式整文件操作。不会为支持这些情况另造 patch 引擎。

### 3. 键位和路由收敛

由一个薄 Git 路由负责 root/path/revisions 和 CodeDiff 调用，不持有后台 watcher 或重复状态缓存。优先公开命令/API；必须调用内部 API 时只隔离在此边界，并用 pin 与集成回归约束升级。

| 入口 | 目标行为 |
|---|---|
| `<leader>gg` | 当前普通文件所属仓库的审阅主入口；无法从文件定位时回落 cwd 仓库 |
| `<leader>gG` | 显式以 cwd 所属仓库打开，不沿用上一次仓库 |
| `<leader>vg` | 默认审阅入口的兼容别名，重复触发聚焦已有同仓工作区 |
| `<leader>gv` / `<leader>gV` | 保留主动打开 / 关闭 Diffview；不会自动替换正在使用的 CodeDiff 工作区 |
| `<leader>gn` | 同仓 Neogit；从 CodeDiff 进入时使用审阅 session 的 root |
| `<leader>gm` / `<leader>gM` | 当前文件 / 仓库历史，结果进入 CodeDiff |
| Visual `<leader>gv` | 保留既有 Diffview 选中行范围历史；CodeDiff 的行历史通过其显式 history 入口使用并独立验收 |
| `<leader>gr` / `<leader>gk` | 指定两版本或提交的审阅；验证 ref，并区分 `A..B`、`A...B` 与单提交 |
| `<leader>gh` / `<leader>gH` | 仓库 / 当前文件改动内容搜索，保留 `-G` 正则语义 |
| `<leader>gx` / `<leader>gX` | 当前文件对分支 / 提交的比较，经 Snacks 选择后进入 CodeDiff |
| `<leader>gC` / `<leader>gA` | Neogit reflog / Git 操作选择；选择列表本身不改变分支 |
| `<leader>gc` / `<leader>gs` | 既有提交 / 状态 picker，确认项路由完整文件审阅 |

保留 Fugitive 的 `<leader>g0/gB/gl/gL` 专项入口。移除 LazyVim 的 `<leader>gh*` 自动嵌套 hunk 键位，避免与 `<leader>gh` 查询前缀竞争；普通编辑及 diff 窗口统一以 buffer-local `<leader>hs/hu/hr` 表示暂存/取消暂存/丢弃，`<leader>hS` 表示文件级操作，语义提示区分对象；具体不适用动作应禁用。CodeDiff 内 `]c/[c` 跳 hunk，`Tab/S-Tab` 切文件，`gS` 切暂存视图；跨文件连续 hunk 使用上游能力，避免复制当前基于光标是否移动的猜测逻辑。审阅内 `<localleader>c` 进入 Neogit commit 流程，完成或取消回到原文件位置。

这些映射是迁移后的合同。Diffview 原配置中迁走的 `gm/gM/gr/gk` 映射只由默认路由定义，避免加载顺序抢占；其原生命令仍提供对应能力。测试要加载 LazyVim、VeryLazy 和 buffer on_attach 后检查最终有效映射，不能只验证配置表里有字符串。菜单和 cheatsheet 同步更新，并明确默认 CodeDiff 与按需 Diffview。

### 4. 搜索/历史迁移不能改变问题本身

优先复用 Snacks finder、异步进程及自定义 confirm，不为高级搜索新建缓存或索引。Snacks 标准 `git_log` 的 live search 是 `-S`，改动内容入口必须显式生成 `-G <pattern> --pickaxe-all` 的 argv；不能通过简单加参数叠出同时启用 `-S/-G` 的不同语义。取消/新查询终止旧任务，陈旧结果不能覆盖新查询。

测试 fixture 含：字符串在旧行和新行都出现但所在代码改变的提交（`-G` 命中而 `-S` 不命中）、仅消息命中的提交、rename 后文件、选定行与无关行分别变化的提交。历史和搜索结果提供 commit/path，confirm 才打开完整审阅；picker 局部预览只作选择辅助。

范围/ref 输入不串成 shell 命令；含空格/中文的路径和用户查询通过 argv 传递。单提交包括根提交；merge commit 必须明确父版本，不能无提示取错父节点。支持文件删除前路径、rename 和 worktree 根目录；选范围不执行 checkout。

### 5. 依赖和生命周期有明确边界

新依赖的必要性已由用户选择及上述交互需求给出。实施首先选择一个实际通过测试的 CodeDiff release/commit，锁定匹配原生库版本与架构，记录来源、平台和校验值。不写未经验证的版本号；不无关升级 Neogit/LazyVim。Neogit 设置 `codediff=true`、`diffview=false`、`telescope=false`、`snacks=true`、`diff_viewer='codediff'` 后按实际 pin 验证。

安装/升级步骤显式完成原生库准备；常规打开审阅时不允许因为缺库而静默联网安装，不伪装成空仓或回退局部 patch。需核验上游安装开关/预检入口以在缺库时给可执行修复提示。宿主探测沿用平台层，无新平台分支散落在插件配置中。

CodeDiff 的 watcher 限于活跃审阅需要；关闭后没有遗留任务或 watcher。Neogit 隐藏时不新增我们的重复全仓刷新；Gitsigns 继续禁用 K42 gitdir watcher。更新后失效相关视图，不使用永久 ticker，不把全局 `async_launcher` 包装当异步证明。

### 6. 实测门禁与验证范围

先在隔离 fixture 仓库执行所有写操作，真实工作仓只读记录启动、切文件、跳 hunk、外部变化感知和资源数据。不得用用户未提交修改做 discard/stage 实验，不重启用户 Neovim 或 clangd。

在切换默认入口前冻结 Diffview 基线及 CodeDiff 候选的相同输入：tracked/untracked/dirty 文件数、目标文件字节数/行数、平台与插件版本、Git 配置、宿主负载。冷启动单列，暖缓存每动作至少 20 次，记录 p50/p95、主循环延迟、CPU、RSS、Git 子进程次数；大仓 status/diff 耗时与渲染时间分开，不将上游 benchmark 当本机证据。

切换默认入口门禁：相同覆盖与可比负载下，暖启动和切文件的 p95 不高于基线 1.2 倍；跳 hunk 的 p95 不高于 `max(基线 × 1.2, 2ms)`；主循环 20ms 心跳额外延迟 p95 不超过 50ms，且没有由本次接线造成的超过 100ms 单次同步停顿。空闲 60 秒不得出现 Git 进程自激风暴；关闭 CodeDiff 工作区后其拥有的后台活动归零，用户独立打开的 Diffview 不被关闭。阈值是实施目标，不是当前实测结果。若失败，保留候选隔离验证、修复后重测，不能把性能缺口标为完成。

fixture 覆盖真实 index 字节及 `git diff --cached` 结果：两个分离 hunk、相邻修改、纯删除、首尾行、CRLF/无末尾换行、untracked、删除/rename、二进制显式提示、冲突、staged 与 unstaged 重叠、未保存 buffer、外部 index 更新、worktree 和不同仓库切换。对暂不支持的操作明确拒绝，不套用错误路径。只检查映射存在不足以验收。

## Risks / Trade-offs

- [CodeDiff 上游文档与实际 pin 行为不同] → 以锁定源码和真实 fixture 实验决定 API 接线，不承诺未验收能力。
- [原生库版本/平台不匹配] → 预检、显式安装及失败诊断；不修改无关工具链，不称其他平台已通过。
- [默认 watcher 在大仓引入开销] → 限生命周期、去重/防抖并记录实际 Git 命令；保留文件覆盖，不能默认隐藏 untracked 换快。
- [删除插件误丢历史能力] → 能力迁移矩阵与回归先行；Fugitive 保留专项能力，避免为删一个插件重写它。
- [多个进程继续写 index/工作区] → 真实竞争 fixture 验证 revision 检查，过期拒绝，未保存内容不能被刷新覆盖。
- [两套按需界面出现键位或状态竞争] → 只定义一套默认路由，Diffview 保留明确独立入口；分别验证打开顺序、关闭与外部 index 刷新，不因切换工具覆盖 buffer 或自动启动另一套界面。

## Migration Plan

1. 锁定能力清单、隔离 fixture 与现状基线，检查是否有同文件并行改动；清理前先补缺失的回归。
2. 在隔离配置中接入 CodeDiff 与原生库，验证 Neogit 现有 pin 集成、完整文件与 hunk 正确性。
3. 实现最少的路由、搜索迁移、键位/提交返回；完成特殊路径与并发数据保护测试。
4. 获得真实大仓只读对比证据后切换默认入口，同一批删除 AGS/Telescope 引用、Lazygit 默认入口和 Trouble Git 子功能；保留按需 Diffview、其他侧栏及专项能力。
5. 更新 lock、帮助、spec/navigation 与 changelog，运行范围回归、Lua lint 和提交前全量回归；未完成测试和平台边界显式记录。

回滚只回退本 change 引入的配置与依赖选择，不删除共享插件目录，不覆盖并行变更，不更改 Git index 或未保存文件。实施与验收状态以 tasks.md 及交付记录为准。

## 验收尺度修订记录（2026-09-29）

原提案将同一个 20% 相对阈值用于所有动作。实测 hunk 为 1.1795ms 对 0.7974ms，原比例门禁失败（约 1.479 倍），该结果保留。仅 hunk 增加 2ms 绝对预算，即 20ms 响应预算的 10%，以避免为约 0.38ms 的差异增加实现复杂度；这是一项明确的工程容差，不是宣称已实测证明用户无法感知。打开、切文件、心跳和 100ms 同步停顿门禁不随之放宽。最终报告须区分原门禁失败和修订后的验收结论。

真实仓库的并行诊断会继续新增 untracked，用户要求保留其他工作的进行。允许按可比覆盖验收：逐次采集完整清单，证明差异仅为独立新增、没有删除/过滤/漏项，tracked/index 和被测文件字节不变；明确报告非冻结输入及打开耗时的限制，稳定目标的切换/hunk 单独判断。不终止其他写入、不改数据来制造基线。原严格冻结输入条件在发生漂移的轮次不成立，不能写成原门禁全部通过。
