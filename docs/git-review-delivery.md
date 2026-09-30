# Git 审阅迁移记录

## 交付范围

CodeDiff 承担完整文件双栏审阅；Diffview 保留 `<leader>gv/gV`、Visual `<leader>gv` 和原生命令。
Neogit 管理提交、分支、stash、rebase、reflog，使用 CodeDiff 和 Snacks 集成。
Gitsigns 负责普通编辑 buffer，Fugitive 保留历史/index 原文及 quickfix 专项入口。

移除 advanced-git-search、无其他消费者的 Telescope 依赖、编辑器内 Lazygit 默认入口，以及
Trouble 的独立 Git 状态查询/缓存。Snacks 的 `telescope` 布局、其他侧栏、宿主 Lazygit
程序和用户配置保留。未修改其他 SuperUnity change 或用户实际仓库的 index。

## 依赖证据

- CodeDiff v4.0.6，commit `09d9ebef2cc5a5c04db7a349cd6c61bdf84ecc8e`。
- Windows x64 原生库来自 [官方 v4.0.6 release](https://github.com/esmuellert/codediff.nvim/releases/tag/v4.0.6)，
  资源 `libvscode_diff_windows_x64_4.0.6.dll`，安装名 `libvscode_diff_4.0.6.dll`。
- SHA256 与同 release 的 SHA256SUMS 逐字一致：
  `30717718478c5020d6703e5d35c58b8655f16fcbbb4d794848927082b7d93fb3`。
- Neogit 保持 `792c139da736230855e8341ebe6175bb6eb8268b`；其已有 CodeDiff 开关，但调用旧 API，
  使用独立 v4 适配补丁，不无关升级。
- 正常打开设置两个禁止自动安装开关；缺库或版本不匹配明确失败，修复入口为 `:Lazy` 的 build。

## 实测发现及修复

所有写入实验均在一次性 fixture 仓库进行。真实大仓只读，使用 `GIT_OPTIONAL_LOCKS=0`。

- 上游 discard hunk 会隐式保存同 buffer 的其他脏行；现先检查脏 buffer，拒绝隐式保存。
- 上游零上下文 insertion patch 可成功应用到已变化的 index；现核对显示内容与当前来源，过期拒绝。
- Windows 路径大小写及短路径会漏掉脏 buffer；现规范化真实路径并按平台比较。
- Unicode/rename 的展示字符串不能当路径；历史及 ref 列表改为 NUL 路径协议，保留前后路径。
- Neogit 延迟关闭回调会抢走第三个 tab 的焦点；现执行时重验原 session 和当前位置。
- 当前 Neogit 不存在名为 `reflog` 的 popup；`gC` 通过原生 reflog API 打开真实 HEAD 历史。
  双仓提交后的记录、空历史及未提交仓库已验证，打开列表不改变 HEAD。
- 路径过滤的原生 CodeDiff session 不能被全仓入口复用，否则缺失其他文件；已加范围检查。
- Diffview Visual `gv` 首次选择会因旧 marks 不存在报 `E20`；现捕获当前正向/反向选区，
  延迟执行期间换文件则取消，仍调用 Diffview 本身。
- 上游默认回退轮询每 500ms 扫仓；改为保存、操作完成、返回 tab/窗口和手动 `R` 刷新。
- 10552 条文件列表的同步格式化和建树会阻塞主循环；保留全部节点和原始路径，
  仅对可见区域做昂贵装饰，完整建树跨事件循环分批执行。
- 上游复制状态表导致预构建缓存不命中；交接改为验证完整状态副本并一次性消费。
  真实大仓诊断中同步树创建由约 123ms 降到 0.78ms，构建次数由两次变为一次。
- 多轮打开/关闭暴露对象残留：独立小仓实验在关闭并 GC 后仍存活 3/3 个 explorer，
  由上游未清理的 `WinResized` 回调持有；大树还存在面板引用残留。关闭流程单独修复验收。
- 11 轮真实打开/关闭验证专属回调、scratch 面板及构建状态均已释放；其他插件回调保留。
  测试排除 LuaJIT trace 自身的引用后，弱引用也全部释放；生产配置不清理 JIT 或强制 GC。
- 剩余标题渲染热点来自内置格式器不使用的 `ctx.files` 全组副本。仅对大组/目录的内置格式器省去副本，
  单次分配由约 5 MiB 降至 6 KiB；原生显示片段、计数、统计严格相同，自定义格式器保持完整上下文。
- 无 profiler 的实际大仓探针发现单次 `uv.spawn` 耗时约 740ms，对应约 745ms 心跳延迟；
  Git 进程创建移入 worker，最多两个并发，取消仅操作自己持有的进程 handle。

撤回的判断：审查曾认为 staged/history 会被全仓入口复用；核对上游初始化后发现它会写入
base/target revision，此判断不成立。实际缺口仅为 pathspec 过滤，已独立复现并修复。

## 操作边界

- hunk 操作在调用 Git 前验证显示快照；LF、CRLF、纯 EOF 删除有真实 index 验证。
  此前置检查不构成覆盖任意外部写入时机的跨进程事务。
- 无末尾换行、rename、未跟踪、整文件删除及超过 8 MiB 的文件拒绝 hunk 写入，
  使用明确的整文件动作；历史比较拒绝工作区/index 写操作。
- 整文件暂存/取消暂存针对操作时的整个文件，拒绝脏 buffer；不是旧快照逐 hunk 应用，
  也不承诺与外部 Git 进程之间的原子事务。
- 二进制使用 Git numstat 元数据和工作文件有界 NUL 检查；不宣称识别所有自定义二进制格式。
- 搜索保留 `git log -G --pickaxe-all`，不替换成 `-S` 或消息查询。
- 单文件搜索确认保留文件范围，并追溯所选提交及父提交的 rename 路径；不混入同提交的其他文件。
  Snacks 的新查询/关闭取消与陈旧结果隔离已核对已安装源码；未宣称完成图形界面连续输入压力测试。

## 验证与性能

最终性能通过下述明确修订后的门禁。原始中间失败不改写为成功。安全聚合证据见
[性能数据](git-review-benchmark-2026-09-29.json)；完整私有路径清单留在系统临时目录。

验收修订：原 hunk 相对门禁失败，`1.1795 / 0.7974 ≈ 1.479 > 1.2`，绝对差约 0.38ms。
仅此动作改为 `p95 ≤ max(基线 × 1.2, 2ms)`；2ms 是 20ms 响应预算的 10% 工程容差，
不是“已实测无法感知”的结论。打开、切文件、心跳和 100ms 同步停顿门禁保持不变。
此前 107ms 心跳峰值不因此豁免；后续归因确认 view.create 有约 111.5ms 的自身回调，
经关闭清理及格式器分配修复后重新完成 20 次测量，最终无超过 100ms 的自身回调。

最终候选为 262001 tracked、4 dirty、10567 untracked，完整面板 10571 项。首次及 20 次暖打开
逐次覆盖数量/路径指纹一致，本轮 status、tracked、index 与两个目标文件字节前后一致。
两目标文件为 471/293 行、16047/12384 字节；不以该样本承诺任意大小文件的延迟。

| 指标（各 20 次） | Diffview p50 / p95 | CodeDiff p50 / p95 |
|---|---:|---:|
| 暖打开，ms | 8167.28 / 9202.78 | 3579.16 / 4000.47 |
| 相邻时间窗口成对切文件，ms | 123.28 / 202.66 | 108.84 / 200.45 |
| 相邻时间窗口成对跳 hunk，ms | 0.347 / 0.615 | 1.047 / 1.441 |

首次进程打开分别为 8593.96/3840.65ms。完整 CodeDiff 跑次的切文件和 hunk p95 分别为
123.56/1.339ms；表中采用随后相同输入的成对动作数据，保留测量波动。

输入限制：暖打开对照基线开始为 10556 项，结束时独立诊断新增 1 个 untracked；后续独立写入
继续增加文件，私有清单已验证后续差异只有新增、没有删除/隐藏。早期基线未记录目标文件结束
字节 hash，不能冒称它具备完整的冻结输入证明。打开数据因此保留并发输入限制。成对切文件/hunk
两边均为相同 10571 项、相同 status/路径指纹，index/目标字节均前后稳定，可单独判断。

候选各阶段心跳额外延迟 p95 最高 26.77ms、最大 63.14ms；空闲 62.04 秒新增 Git 进程 0，
关闭后 5.10 秒新增 Git 进程及 Neovim CPU 增量均 0。worker active/queued、大树 buffers/
pending/builds/prepared 全部 0；剩余活动 timer 仅为 benchmark 心跳。

同一套测量阶段的 Neovim CPU 累计为 83.797/21.250 秒，采样 RSS 峰值 3956.05/605.34 MiB，
关闭后 RSS 3946.55/560.59 MiB；直接 Git 查询进程 299/106。顺序均为 Diffview/CodeDiff。
这些不是全宿主 CPU/内存，也不包括 Git 子进程 CPU；没有以强制 GC 或缓存清理降低数字。

复测脚本：`scripts/benchmark_git_review.lua`。原始 JSON 保留在本机临时目录，不提交私有路径。
环境为 Windows x64、Neovim 0.11.5、Git 2.55.0.windows.5，使用真实 mini.icons 与 38 列树形列表。
冷启动指本进程首次打开，不代表清空操作系统缓存。CPU/RSS 是 Neovim 本进程读数，不包含 Git
子进程内存；headless 不测 Neovide/GPU/字体绘制。

测量后只切换默认键位/lock，并将显式 build 改为强制重装以修复同名错误库；审阅运行时实现未变。
聚合内保留测量时文件指纹，启动接线由另外的真实 LazyVim 测试验证。

功能回归：第一次本轮 required-native 全量为 2334/2336，两个失败分别是 worktree 测试提前读取
未就绪结果、以及新代码绕过宿主归属层。前者修正等待条件并通过 7/7；后者复用现有 path_key/
resolve_tool、把 Windows Git 候选留在 Windows driver，平台边界 17/17、platform 51/51，未扩 allowlist。
正式切换后的真实启动验证 1/1，确认无需注入 setup、旧依赖退出有效图、双方打开/关闭独立。
最终冻结版本 required-native 全量 **2338/2338**，0 failed、0 skipped；运行命令为设置 `NVIM_TEST_REQUIRE_NATIVE=1` 后执行 `nvim --headless -l tests/run.lua`。21 个相关 Lua 文件通过 AST lint；没有通过跳过 native 用例制造全绿。版本记录见 [2.0.0](release_2.0.0.md)。

## 回退与未测范围

随时可用保留的 `<leader>gv` 打开 Diffview。配置回退应只还原本 change 的文件块和 lock 选择，
不删除共享插件目录、不覆盖并行工作、不 reset 用户仓库。已有 Neovim 进程不做强制热替换。
未验收 macOS/Linux 原生库、Neovide 图形渲染或自定义 Git hook/filter 的后代进程清理。
上述实现验收时尚未执行 commit、push、tag；随后用户授权 sync/archive/commit/push。
Change 归档于 `openspec/changes/archive/2026-09-29-unify-git-review-with-codediff/`；tag 仍待授权。
