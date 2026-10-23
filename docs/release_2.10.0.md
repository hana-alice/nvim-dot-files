# hana-alice/nvim 2.10.0 — SuperUnity 合并扩展、上下文迁移与瓶颈定位

> 版本：2.10.0
> 仓库：https://github.com/hana-alice/nvim-dot-files
> 日期：2026-10-23
> 类型：Minor；Tier 1 默认跨 gen/src 合并、上下文迁移作废旧 shard、可选 Tier 2、后台索引成本定位。
> 发布流程：按用户授权同步、脱敏归档、提交、推送并提交 MR；tag 待明确请求。

## 1. 本次交付范围

- **Tier 1 默认不再按 gen/src 拆分**：同模块、完整编译上下文内的 UBT 按字节预算合并；`NVIM_UE_TIER1_SPLIT_CLASSES=1` 回退。
  跨类别块门禁失败时按类别拆分重试一次，子块收据记录 `fallback_of`；规划、只读复用与后台 collect 同一口径。
- **上下文迁移作废旧 main shard**：发布比较新旧 live CDB，对变为 exact 或命令变化的 main 按 CDB 拼写
  （`shard_name.lua`，纯 LuaJIT XXH3-64，与 clangd 实测文件名一致）直接删除，拼写不中时以 own-URI 物理身份兜底
  （`shard_migration.lua` + `tools/clangd_shard_owners.py`）；只删 main shard，不碰头文件 shard。
- **可选 Tier 2**（`NVIM_UE_TIER2=1`，默认关）：同一 SharedPCH 下跨模块整模块打包，除 Tier 1 三条硬门禁外要求
  clang 依赖文件集合与逐模块 Tier 1 并集完全相等；失败退回逐模块 Tier 1。
- **宿主修复**：盘点工具按与生产者相同的路径身份分桶（8.3 短名下不再误判 unknown，且不穿越 junction）；
  测试入口在 8.3 TEMP 下以物理长路径重启；迁移夹具对 AppControl 服务的瞬时文件锁做有界重试。

## 2. 验证与剩余范围

提交前串行全量 `NVIM_TEST_REQUIRE_NATIVE=1 nvim --headless -l tests/run.lua`：**4363/4364、2 SKIP**，
唯一失败是本归档文件尚未写出时的结构内链（本文件写入后 `structure` 复跑见下）。两项跳过：未提供私有 GTAGS
native 工程输入；当前宿主具备 PCH 能力而不适用的不支持场景。首轮全量 4343/4364 的 21 个失败已逐一处置，见第 3 节首条。

| 实测（私有 clangd j1、全新缓存） | 前 | 后 | 边界 |
|---|---:|---:|---|
| 不拆 gen/src，8 模块 / 97 UBT | 304.5 s CPU（A/A 2%） | 238.4 s | −21.9%；成员主 shard 0 缺失，独有定义差异低于 A/A 噪声 |
| 同上，随机 28 模块 / 56 UBT | 303.7 s | 229.1 s | −24.6%；暴露同名 X.cpp/X.gen.cpp + 无 guard 头的编译失败，由门禁拒绝并拆分重试 |
| Tier 2，MovieScene+UMG，生产入口 | 36.8 s | 29.9 s | −19%，单次；离线 UBT TU 364→168 |

**后台索引成本构成（16 个随机已发布 TU，CLANGD_TRACE）**：forced-include 前缀 45%、成员解析 9.5%、符号收集 22%、
写 shard 23%（每个新 shard 约 4.7 ms、串行）。合并只削减前缀；Tier 2 按用户判定收益不达标，保持默认关闭。
**已否决：后台索引用前缀 PCH**——需自编 clangd，两模块合计仅 −12%，且使用 PCH 的 TU 丢失其 UCLASS/USTRUCT
由 UHT 宏生成的成员（2756 个符号 ID），详见 `cpp-semantic-index-coverage` spec 的选型与踩坑。

本版**未宣称全工程索引性能恢复**：未做开启新策略后的全工程冷/热索引、首次 prepare 重验成本（full 约 278 块）
与 gd/refs 查询验收。8.3 短名形式的引擎根/外部 CDB 在 clangd 22.1.5 中会产生空 main shard（上游 URI 不一致），未修复。

公开文档只保留通用结构与测量数值；工程路径、工作站身份与原始实验产物保留于本地。

## 3. 本次工作归档

### 2026-10-23 — 测试入口规避 8.3 TEMP 与新 spawn 登记

**Task**

- 处置里程碑全量门禁暴露的 21 个失败（4343/4364）。

**Implemented**

- `tests/run.lua`：Windows 下若 `TEMP` 是 8.3 短名（与 `fs_realpath` 不同），以真实长路径 TEMP 重启自身一次（`NVIM_TEST_LONG_TEMP=1` 防递归），使所有 `tempname()` 夹具与 clangd/原生 watcher 报告的物理路径同名；8.3 行为仍由显式构造短名的用例覆盖。
- `host_resource_discipline_spec.lua`：登记 `shard_migration.lua` 的单次有界 own-node reader spawn（运行于既有 publication worker 子进程）。
- `index_batch_publication_hash_spec.lua`：真实 clangd 文件名样本改用中性路径重新录制，去除本机用户目录。

**Pitfalls / Gotchas**

- 21 个失败中 18 个（`ue_cdb_prepare_cache` 15、`ue_cdb_prepare_scan_roots` 1、`review_goto_native` 1、及其关联项）只在短名 TEMP 下出现，长名 TEMP 下同 spec 全绿；源码与这些 spec 在本轮均未改动，属宿主环境耦合而非回归。
- 原生 watcher 对短名根报告事件，但 `fs_realpath` 返回长名；夹具若用短名拼写比较路径会误判为输入变化（`input-event`）。

**Validation**

- 见 2.10.0 归档第 2 节的全量门禁结果。

**Follow-ups**

- 无。

### 2026-10-22 — 默认关闭的 Tier 2 跨模块资格与普通发布

**Task**
- 按阶段门禁验证同 SharedPCH 跨模块合并；任何未满足的继续条件均不得进入资格验证或发布。

**Implemented**
- `tools/build_hot_super_unity_cdb.py` 新增 `tier2_unity_chunks`、`tier2_candidate_spec`、`tier2_include_gate`；按完整模块、原 CDB 顺序与字节/UBT 预算规划，仅构造离线候选。
- include 门禁串行运行低优先级 clang，比较逐模块原 argv 与合并候选的实际依赖文件集合；真实工程缓存禁止作为输出目录。既有函数及默认生产行为保持。
- `tests/cases/index_generated_super_unity_tier2_spec.lua` 覆盖模块不可拆、预算、完整上下文、缺失成员、宏封装、依赖正例与同名头遮蔽拒绝。
- `tools/cdb_verified_batch.py` 新增 `accelerate_tier2`/`reuse_tier2`，通过 `NVIM_UE_TIER2=1` 前置四门验证；收据绑定 Definitions 字节、wrapper/成员、工具与环境，失败回到逐模块 Tier 1。确定性拒绝可复用，超时不授予拒绝资格。
- `tools/cdb_background_batch.py` 的普通 plan/work/collect 使用同一规划与复用口径，整块替换已有 Tier 1 owner，计划绑定开关，保留普通与 strict 的边界。
- `lua/ue/index/_publish.lua` 通过普通 live 路线重验 Tier 2 四门及全部 Definitions 输入；不授予 frozen 权限，输入失效或开关关闭保留原始命令。

**Pitfalls / Gotchas**
- Make depfile 的 Windows 反斜杠不能交给 POSIX `shlex`；临时目录实测复现并修正，含空格路径已覆盖。
- 依据补充授权只读真实 wrapper/VFS/源码，未读写 live shard/proof store，也未操作 live nvim/clangd。
- include 集合相等不能排除成员定义的宏/静态符号跨模块泄漏；编译/主 shard/成员覆盖门禁不能证明完整语义图等价。

**Validation**
- `NVIM_TEST_REQUIRE_NATIVE=1` 下 `index_generated_super_unity`：27/27，0 failed、0 skipped；`structure`：85/85；Python AST 解析通过，既有 24 个函数 AST 全部保持。
- 私有临时 clang fixture：依赖相等正例通过，同名不同头负例拒绝；以上不是阶段 1 真实工程准入证据。
- 真实阶段 1：68 个 Tier 2 候选块、264 模块，残余 Tier 1 合计 168 UBT TU、2501 候选行；三个已知对与两个实际多模块块依赖集合相等，4.79–9.77 秒/块。
- 私有 MovieScene+UMG：441 成员、四门通过，Tier 1 两 TU 对 Tier 2 一 TU，clangd CPU 36.78→29.92 秒；重复复用零 native、零写入。同名头负例拒绝后实际资格验证为两个 Tier 1 块，覆盖完整。该已知对显式使用 32/32 实验预算，生产默认仍为 8/8。
- required-native `index_generated_super_unity`：27/27，0 failed、0 skipped。
- required-native `index_verified_batch`：93/93，0 failed、0 skipped。
- required-native `index_batch_background`：95/95，0 failed、0 skipped。
- required-native `index_batch_background_noclass`：21/21，0 failed、0 skipped。
- required-native `index_batch_publication`：132/132，0 failed、0 skipped。
- required-native `index_batch`：513/516，3 failed、0 skipped。
- 最终 Tier 2 追加范围：11/11；structure：85/85；`index_batch` 三个失败按阶段门禁留底停止，未重试、未宣称全绿。

**Follow-ups**
- 全工程资格/冷索引、首次与重复 prepare、gd/refs 及宏/静态泄漏的进一步验证仍未完成；168 TU 是离线候选规划，不是实际发布或全工程性能恢复承诺。

### 2026-10-22 — 消除短 TEMP 夹具耦合与迁移编译器副本瞬时写锁红灯

**Task**

- 定位并处置 `index_batch_publication` 在 Windows 8.3 TEMP 下的两个 native 失败，以及 `index_batch_migration` 偶发的自有 `clang++.exe` 写入拒绝。
- 追加处置 `index_batch_work_inventory` 在默认短名 TEMP 下的历史/活跃单元误分类，统一生产者与 dry-run 盘点的路径身份。

**Implemented**

- `tests/cases/index_batch_publication_spec.lua` 的 `fixture` 在创建目录后取物理长路径，再构造 CDB；`short_path` 通过 Win32 `GetShortPathNameW` 显式产生真实短名，新增临时根规范化、短名 CDB 直接命中和 own-node 物理身份兜底共三个用例。未改变生产 `shard_name.for_path` 或 `shard_migration.invalidate`。
- `tests/cases/index_batch_migration_spec.lua` 的 `write_owned_driver` 对 fixture 自有编译器副本的两处写入加入 2 秒有界 PermissionError 重试，每次最多等待 50ms；永久拒绝仍失败，日志与断言保留次数、等待和总耗时。未修改生产迁移/查询工具。
- 追加修复 `tools/cdb_batch_work_inventory.py`：`path_identity` 在根到叶 `lstat` 拒绝 reparse/symlink 后，按生产者 `_proof_work_root` 的 `Path.resolve()` 口径计算比较身份；store bucket、引用/历史归组、active root 和 CLI 输出边界统一使用该身份。`absolute` 与实际 `os.walk(..., followlinks=False)` 入口保留原拼写。`tests/cases/index_batch_work_inventory_spec.lua` 改用真实生产者生成 bucket，并新增真实 8.3 混合路径、缺失 store、junction/断链拒绝三组回归。

**Pitfalls / Gotchas**

- 私有 clangd 22.1.5、j1 实验确认：被 include 成员的 own shard 使用展开后的长名，短名 CDB main 则保留短名。全新缓存的小写 main 也产生空 shard；原生 indexer YAML 的符号 URI 为长名，与短名 Sources 的 URI 分片不一致。不能用统一 realpath 改写 hash 输入，也不能把该现象归为旧 wrapper 去重或读错 shard。
- 原 migration 失败实际发生在 `migrate_cache` 返回后恢复编译器原字节。Restart Manager 在本轮失败现场精确查到 AppControl Service 持有自有 exe，当时未发现 fixture clang/clangd 存活；不支持旧 producer 孙进程泄漏或已证实的映像释放延迟结论。一次持有者证据不追溯保证所有历史失败同源。
- Neovim `fnamemodify(':8')` 在本机未生成短名，初稿产生的能力 SKIP 不作验收；已改为原生 API，并在用例注册边界处理能力不足。
- 追加最小实验确认原盘点是生产缺陷：短 store 拼写产生的 bucket 与生产者不同，导致可回收/活跃单元被报为 unknown；短 work root 配长引用时还会漏掉引用并误报 reclaimable。工具始终不支持删除，影响是报告不准；只修 bucket 会留下混合引用误分类。身份解析仅在静态 reparse 守卫通过后执行，不声称能原子抵御并发路径替换。

**Validation**

- 全部设置 `NVIM_TEST_REQUIRE_NATIVE=1`，使用 `nvim --headless -l tests/run.lua <name>` 位置参数：`index_batch_publication` 短 TEMP、长 TEMP 各 **127/127**；`index_batch_migration` 连续五次各 **1/1**；最终 `index_batch` **479/479**；`index_batch_publication_hash` **30/30**。上述最终结果均 **0 FAIL、0 SKIP**。
- 五轮 migration 的恢复写入实际重试 **1/1/2/0/0** 次，等待 **0.050469/0.050156/0.101180/0/0 秒**，验证了真实短锁重试分支。publication 原样基线的两个 native 红灯已由修复后的真实重建断言闭环。
- 文档收尾 `structure` **85/85、0 FAIL、0 SKIP**；本任务三个正式改动文件的 `git diff --check` 通过。
- 追加任务同样设置 `NVIM_TEST_REQUIRE_NATIVE=1`：`index_batch_work_inventory` 短名/长名 TEMP 各 **10/10**；默认短名 TEMP 的 `index_batch` **482/482**；`index_verified_batch` 串行复测 **83/83**；`structure` **85/85**，最终均 **0 FAIL、0 SKIP**。同一私有目录的修复前后实验验证了真实生产者 bucket、短名等价和混合引用分类；新增 junction/断链用例确认解析身份前拒绝链接。
- `index_verified_batch` 首轮与另一组回归并行时为 **82/83**：模板参数证明子进程 30 秒超时，但其结果文件已在请求后约 0.208 秒写出 `ok=true`。未调整超时或断言；默认短名 TEMP 串行复测通过。不能据此断言并发就是原因，退出延迟机制仍待验证；首次日志保留在追加任务报告目录。
- 未跑全量、未操作 live 实例或真实工程缓存；详细报告与原生证据保留在本任务指定的私有报告目录。

**Follow-ups**

- 显式短名 engine root 可沿输出路径传到生产 wrapper；clangd 22.1.5 的短名 main 空 shard 上游行为仍是边界风险。本次修复不等于完整生产 8.3 路径支持，也不构成真实工程性能恢复验收。
- 宿主锁超过 2 秒仍显式报错；没有停止或重配安全服务。
- 盘点身份守卫与解析不是原子路径租约；报告不授权未来删除。模板证明子进程的单次超时原因未闭环，本次未扩展修改该工具。

### 2026-10-21 — Tier 1 同上下文 gen/src 默认合并以减少后台 TU

**Task**

- 按已完成的隔离工程 A/B 结论，减少重复解析 forced-include 前缀的后台 TU；本次只调整 Tier 1 分组。

**Implemented**

- `tier1_grouping_options` 统一私有资格验证、后台规划/复用和 cohort 整块校验的分组参数；默认不拆 gen/src，`NVIM_UE_TIER1_SPLIT_CLASSES=1` 恢复拆分，非法值明确报错。
- 与当前跨类别块相交的普通 Tier 1 catalog 复用须匹配该分组边界，防止旧 gen/src 子组占住成员、令新混合组永远无法进入验证。同类历史块、显式升级与 strict 路径沿用原行为。
- 保留模块/完整编译上下文和预算边界，保留原 strict 与显式整块校验语义；通用 `secondary_unity_chunks` 的 `split_member_classes=True` 默认值不变。
- 2026-10-22 第一阶段（已撤回默认启用）：no-class 装箱曾按 basename 忽略大小写比较 `.cpp/.cc/.cxx` 与 `.gen.cpp` 的 stem，冲突时按原序开新块。该约束保留为 `avoid_same_stem_pairs=True` 显式选项；默认现为关闭，strict 与原 split 策略保持。
- 2026-10-22 方向调整：默认先验证完整 no-class 父块；跨成员类别父块的任一硬门禁失败后，使用同一 `secondary_unity_chunks(split_member_classes=True)` 重规划一次子块。通过的子块独立发布，失败或单个 UBT 保留原命令，最多一层。父失败保留原因，可确认的失败收据正常复用；每个子块的缓存键及收据绑定 `fallback_of=<父 cache_key>`，未完成/异常运行不固化为永久负缓存。
- `reuse_tier1` 用同一失败重试队列只读查询父/子收据；缺子收据只 defer 该子组。后台 plan/work/collect/catalog 将子块作为完整已验 owner，父的一次 work 可完成全部子验证；缺失子块仍调度原父工作，只补入完整、不重叠的新子 owner。未引入独立后台分组算法或修改覆盖门禁。

**Pitfalls / Gotchas**

- 分组变化会让已有 Tier 1 收据整体失配，首次 prepare 需要重新私有验证全部新块（一次性成本）；按用户提供的全工程离线规划，full 阶段以 **278 块**估算重验预算。这里指新分组的整体迁移成本，并非增加无条件 cache 清空：分组、命令与输入身份完全未变的旧块仍遵守原收据复用规则。切换回退开关也会重新选择分组。
- 278 是既有离线规划数，不是本次实跑或全部必然重验数量；没有修改收据 schema、清理缓存或触碰真实工程。
- 同名排斥会同时避开有 guard 的安全 pair，不能将块数变化直接解释为性能收益。2026-10-22 的真实 full semantic CDB 只读规划为：3330 行、997 UBT、214 exact source、2119 shader、14319 个源；旧 no-class 为 278 块 / 合并 911 UBT / 保留 86 UBT / 2697 发布行 / 196 个 pair 块，新为 119 块 / 合并 563 UBT / 保留 434 UBT / 2886 发布行 / **0 个 pair 块**。同输入旧 split=True 为 110 块 / 合并 541 UBT / 保留 456 UBT / 2899 行，新方案仍少 13 行；这些都是资格通过前的规划行数。
- 上述 **119/563/434/2886** 方案相对 split=True 仅少 13 行，因此放弃其默认启用；当前默认恢复 **278/911/86/2697**，含 196 个 pair 块，实际准入仍由门禁决定。若这 196 个父中恰有 26 个失败，按同一 split 分组器生成的子块全部通过时为 **2723 行**；若子块也全部失败，条件上界为 **2832 行**。这是假设恰 26 个失败父的组合边界，不识别哪 26 个、不估测真实失败率。196 个 pair 父中有 164 个拆分后只剩单 UBT、没有可合并子块；不能表述为每个坏父都能恢复压缩，也不能换算为 CPU/墙钟收益。

**Validation**

- 新增默认混合、回退拆分、非法开关、strict 不变、cohort 同口径、原生 plan/work/collect/no-op 及旧 catalog 迁移共 7 个用例；原生验证 4 个混合 UBT 合成 1 块、成员覆盖完整、重复 plan 零新组且产物内容/mtime 不变。
- 迁移用例先真实验证两个拆分块，再切默认完成一个混合块；旧拆分收据自身仍有效但不再阻挡新分组。切回 `1` 后直接复用原两份收据，零新任务、零写。内存移除 catalog 边界检查的负对照复现了默认切换后仍保留两个旧块的缺陷。
- 首次 `index_verified_batch` 为 82/83：原 partial fixture 隐含 gen/src 拆分，默认合并后不再产生独立的成功/失败块。仅为该用例显式设置回退开关 `1`，保留原逐块回退断言；默认混合由新用例独立验证。
- 首次 `index_batch_background` 为 64/66：更新旧 strict fixture 中关于 Tier 1 默认分组的过时断言；并将过宽的 catalog 边界检查收窄到跨类别组迁移，保留原同类非连续 owner/barrier 行为。
- 首次 `index_batch` 为 472/476：4 个 residual strict 场景需要保留混合类别对供 strict 路径处理，现仅对这 4 个场景显式设回退开关 `1`，继续验证原组合、owner 排除及原生失效回退断言。
- 第二次 `index_batch` 为 475/476：既有 archive migration 测试回写自有临时 `clang++.exe` 时出现 `PermissionError`；占用来源未定位，本次不修改该测试/迁移实现，保留失败日志并独立复跑。
- 指定 required-native 窄回归最终结果：用户已跑 `index_generated_super_unity` **16/16**、`index_verified_batch` **83/83**、`index_batch_background` **66/66**、`index_batch_background_noclass` **7/7**；2026-10-22 红灯处置后实跑 `index_batch_publication` 短/长 TEMP 各 **127/127**、`index_batch` **479/479**，这两组最终均 **0 FAIL、0 SKIP**。另实跑 `index_batch_migration` 连续五次各 **1/1**、`index_batch_publication_hash` **30/30**，均零失败、零跳过；根因与修复见上一条。
- 同名排斥阶段新增双向/大小写/多成员/顺序预算与固定旧分组回归；真实 clang++ 证明无 guard 的 `X.h` 在两个原 UBT 中分别可编译、旧合并重定义失败，而当时的默认不生成该候选，覆盖完整且零新证明/文件改写。该阶段 required-native 默认 TEMP 实跑 `index_generated_super_unity` **20/20**、`index_verified_batch` **83/83**、`index_batch_background` **68/68**、`index_batch_background_noclass` **9/9**，均零失败、零跳过；Python AST 及两份 Lua AST lint、diff 检查通过。
- 同名排斥阶段 `index_batch` 首轮 **482/484**：migration 的 query-driver 观察超时，store 的私有 runner 退出码异常。store 独立复跑 **2/2**；migration 中间多次仍失败，且任务开始前两份生产代码快照在同默认 TEMP、原门禁/超时下同样复现查询超时。最终同配置完整重跑 **484/484、0 FAIL、0 SKIP**，未修改相关实现、断言或超时。保留原始失败和对照证据；不把占用来源、退出异常或超时根因写成已证实，不扩大本次修复范围。
- 失败重试阶段新增 12 个父/子门禁与缓存 fixture、4 个后台 plan/work/collect/catalog fixture；真实无 guard 头的 4 UBT 反例先拒绝跨类父，再通过两个同类子块，覆盖 4/4，子收据均绑定父键。warm accelerate 与只读 reuse 均命中父/子三份收据，零新进程、零写入、产物 bytes/mtime 不变。own-shard 结构异常用例先复现遗漏，再纳入硬门禁重试，未放宽不完整运行不可永久负缓存的条件。最终 required-native 默认 TEMP 串行实跑 `index_generated_super_unity` **20/20**、`index_verified_batch` **83/83**、`index_batch_background` **84/84**、`index_batch_background_noclass` **21/21**、`index_batch` **500/500**，全部 **0 FAIL、0 SKIP**；三份 Python AST、三份 Lua AST lint 与 diff 检查通过。未跑全量。
- 离线统计未读取真实缓存 wrapper：从获准 semantic CDB 的 argv 唯一映射真实成员，实测 14105 个 UBT 成员的尺寸，在内存提供 wrapper include 视图并调用新旧生产分组器。新旧覆盖缺失/新增均为 0，重复规划一致，split=True/strict 新旧逐块相同，源 size/mtime 与 CDB SHA256/size/mtime 前后不变；没有真实资格或索引性能测量。

**Follow-ups**

- 本轮不重测用户已提供的 8 模块 A/B，也不操作 live nvim/clangd 或真实工程缓存；全工程首次重验耗时及最终冷索引收益尚未实测。spec 由用户另行更新。

### 2026-10-21 — 发布编译上下文迁移时作废旧 main shard

**Task**

- 防止原 wrapper 成员变为 exact main，或已有 main 的命令变化后，clangd 因源码字节未变而复用旧上下文的 shard。

**Implemented**

- `publish_semantic_cdb` 比较写前 live CDB 与实际 merged 发布内容，沿用规范化文件 key 与 `entry_key` 的 argv/cwd/output 身份；live 原子写成功后立即作废迁移 main 的精确 shard。未变、仅重排、冻结视图单独变化及 append preflight 不删除。
- 新增无外部依赖的 LuaJIT XXH3-64 文件名实现；直接寻址使用已发布 CDB 的绝对路径拼写及小端八字节大写 hex，不使用 realpath 或 lower-case 改写 hash 输入。算法实现未在后续修正中改动。
- 直接名字缺失时，仅扫描一次 shard 目录，按 basename 忽略大小写筛选候选；单次标准库 Python reader 只读取 RIFF headers、`meta/stri/srcs`，seek 跳过业务记录。仅在唯一非零 digest own URI 经 realpath/path_key 证明与迁移文件同一物理路径、且 shard stat 未变化时删除。header、同名不同目录及零 digest 引用节点均不能授权删除。
- `context_migrated` 区分 removed/removed_by_identity/missing/errors，并记录 compare_ms/scan_ms/read_ms/delete_ms；直接命中不读 shard。小 CDB 已存在缓存时也沿用 publication worker，避免身份读取阻塞编辑器；未修改 clangd 参数、seed、Tier 1 准入或重启策略。

**Pitfalls / Gotchas**

- **纠正上一轮错误结论**：main shard 存储名字来自 `Cmd.Directory + Cmd.Filename` 的 CDB 拼写，不能按磁盘 realpath 命名。上一轮混淆了 IncludeGraph own URI 与 main storage key；真实大小写反例已证伪该推断。realpath 只用于兜底物理身份核对，不参与直接文件名计算。
- live 写成功之后，后续 frozen metadata 写失败会令重试失去旧 CDB；作废必须紧邻 live 提交，不能延迟到全部元数据写完。
- 删除失败不会由 unchanged 发布自动重试；内存索引退役仍依赖既有 reader/restart 条件。正斜杠导致 Cmd 缺失的问题不在此次修改范围内。

**Validation**

- 上一轮 required-native `index_batch_publication` 为 118/118 PASS，但未覆盖旧 shard 与新 CDB 拼写不同的情况；不能作为此次修正的验收。3 个真实文件名与 23 个独立 XXH3 边界向量仍保留。
- native fixture 源码不变，发布删除 1 个 shard 后，p2 从 `wrapper_only` / 无 Cmd / IsTU=0 重建为 `exact_only` / 有 Cmd / IsTU=1。
- 实际独立 `publication_worker.lua` 的 831 行、10,746,277 字节临时 CDB：比较 28.2653 ms、删除 2 个 shard 1.5398 ms；其余 829 个 shard 字节保持。worker 往返 675.9995 ms，父进程 timer 42 次、最大间隔 40.0984 ms；这是隔离 fixture 测量，不是实际编辑器响应或全工程加速承诺。
- 本次大小写修正 required-native 最终结果：`index_batch_publication` 124/124（8.9911 秒）、`index_batch` 469/469（192.1703 秒）、`index_generation` 46/46（8.3521 秒）、`index_batch_publication_hash` 30/30（0.1506 秒）；全部 0 FAIL、0 SKIP，重叠 filter 不累加计数。
- 初次 native fixture 与已有 `A.cpp` 大小写冲突导致找不到预期 shard；改用独立 `src/` 后通过，但当时以 realpath 作为 main 存储 key 的修补仍有缺陷，已由本次 CDB 拼写快路径及 own 身份兜底替换。首次 `index_batch` 混合旧模块/新用例的 461/462 失败仍保留。
- 修正后的 native fixture：磁盘/原 wrapper 使用小写 basename，新 exact 行使用大写 basename，旧 shard 经 removed_by_identity=1 删除后重新得到 exact_only。同时改变父目录大小写的额外尝试中删除成功但 clangd Symbols 为空，此独立 URI 分组现象留底，不修改 clangd 行为或降低最终符号断言。
- 真实大小写 tiny 复跑后经发布路径直接删除 CDB 拼写对应的旧 main shard，trigger shard 保留；direct removed=1、removed_by_identity=0、scan_count/read_ms 均为 0。
- 214 个迁移 main 的人工 fixture（831 行、10,738,798 字节）经实际 publication worker：compare 29.0920 ms、一次 scan 3.1232 ms、批量 read 165.0415 ms（含 Python 启动，reader 内部 41.4397 ms）、其余身份核对及删除 126.8802 ms；removed_by_identity=214、missing/errors=0、617 个其它 shard 保留。worker 往返 1104.6621 ms；这些是隔离测试数据，不是生产索引性能承诺。
- 按任务要求不跑全量、不改 spec、不 commit/push；diff 检查与既有 dirty 文件保全核对通过。

**Follow-ups**

- 本次只验证隔离 fixture 的上下文迁移修复，未操作用户进程或真实工程缓存；不代表历史全工程性能、其它上下文覆盖或 PCM 失效问题已经解决。

### 2026-10-18 — 为显式跨模块有序候选接入严格资格

**Task**

- 将仅 generated 成员的显式跨模块完整原 UBT 范围接入既有 strict 证明流程，保留默认 Tier 1 行为。

**Implemented**

- 新增 `tools/cdb_ordered_batch.py`，通过 `strict_recipe` 显式选择有序构造，保留完整原始范围与参数顺序；不自动跨模块发现、重排或缩组。
- 原 TU 独立图、冻结输入及既有 strict 准入继续决定普通 schema2 收据；后台 plan/work/collect 与独立配方 catalog 沿用正常验证。gzip 图存储同时核验物理与逻辑摘要，只控制存储体积。
- `tests/cases/index_batch_migration_spec.lua` 的归档夹具改为 AST 唯一定位冻结组，修复新增参数后旧文本替换零命中的失配；保留原有 32 项迁移、原生图与拒绝断言，生产工具不变。

**Pitfalls / Gotchas**

- 构造成功、分组 key 相同或压缩文件较小都不代表资格或索引提速。普通 Tier 1 默认及身份不变；旧 strict 证明按 collector 身份正常失效，不能改标签复用。

**Validation**

- required-native `index_ordered_batch` 最近 6/6、零失败、零跳过，6.4229768 秒；producer/metadata 独立审查、后台 30+13 项纯检查及既有 consumer 73/73 通过，后者未启动 native。
- required-native 全量 R1 为 4243/4244、1 FAIL、2 SKIP，1166.7651371 秒；唯一失败是上述迁移夹具构造。修复后迁移专项 1/1、零跳过，26.6451459 秒；随后全量 R2 为 4244/4244、0 FAIL、2 SKIP、exit 0，1167.9924521 秒，6 项封存工具/测试身份保持。R1 失败记录及历史并发持久化缺陷的 DEFER 均保留。
- 默认复用 R2 的迟加载依赖观察器失败及缺少后置封存仍保留。修正后 R3 两次 API 为 20.7667/20.5736 秒，整体 42.5974 秒；92 组、819 native、2938 行和 14,319 源及全部返回字段保持，零 native、零写入，16 项代码身份与 9824 项 stat 前后相等，独立审查通过。此为缓存复用保全，不是冷索引提速。
- 331 文件 bare-globals、四工具 AST 与 diff 检查通过；正常有序配方 catalog 收集与扩大范围的资格、冷索引验收仍待完成。
- 模块/filter 映射与索引 spec 已同步；本次公开文字及新代码的 structure、spec、隐私门禁待最终复验，旧扫描不覆盖本条。

**Follow-ups**

- 完成正常收集、失效回退与真实范围的完整语义、首次资格及冷索引验收；不把私有诊断或窄范围计时视为生产资格。既有全量并发持久化失败继续按原 DEFER 留底。
- 扩大范围的首次资格在查询准备阶段因路径对象异常失败，未启动原生索引器，尚无资格或性能结果；原失败费用保留。

### 2026-10-18 — 减少前缀批次 worker 的重复 overlay 校验

**Task**
- 消除显式前缀批次 worker 在已有资格命中时仍重复校验共享 overlay 的准备开销。

**Implemented**
- `tools/cdb_background_batch.py` 的 `work` 仅为当前 owner 的 `_reuse_completed` 调用增加既有 `tier1_overlay_scope(True)`；退出后才判断 owner 和进入资格路径。
- `tests/cases/index_batch_background_spec.lua` 覆盖单次扫描共享校验、下一调用重新校验、资格阶段无残留 memo，以及 overlay 字节不变但实际头文件消失时拒绝复用。未增加缓存层或跨调用状态。

**Pitfalls / Gotchas**
- 首次真实资格 API 曾耗时 173.0349 秒，其中 proof 为 32.9472 秒；这段历史差额没有完整分解，不能以之后的缓存命中计时追认其全部归因。
- 本次测量是同一已合格批次的缓存命中 worker，包含观察器开销；单次固定 before→after，OS 缓存未控制，不代表首次资格或全工程冷索引收益。

**Validation**
- 两文件候选独审通过后精确应用；44 个映射文件 required-native 回归 911/911，零失败、零跳过；331 文件 bare-globals、两 Python 工具 AST/compile 与 diff 检查通过。
- 真实 18 UBT / 206 成员批次的缓存命中 API 为 138.7296→16.3480 秒，进程 CPU 为 133.0625→15.9375 秒。owner 物理校验由 111 次/120.7062 秒降到 1 次/1.0690 秒，资格路径仍另行校验一次。
- 两侧均缓存命中 1 次、新证明/新批次/native 为零，返回范围相同、产物不变；before/after 各自封存输入稳定，唯一代码转换为上述两文件。

**Follow-ups**
- 全工程冷启动与完整语义恢复仍独立推进；既有全量 dirty-union 并发失败继续保留 DEFER，本次未复跑全量。

### 2026-10-18 — 为完整 Tier 1 批次保留强制包含头的加载边

**Task**
- 修复已接受二次批次在暖进程中遗漏 forced-header shard 的加载边，保留既有压缩与完整回退。

**Implemented**
- `tools/cdb_verified_batch.py` 的 Tier 1 API 可显式选择有序 forced-header 前缀配方；复用严格路径的参数解析，保留完整顺序、重复项和成员次序，只移除对应参数位置。
- 新配方将直接 forced-header 字节、构造描述与候选身份绑定到独立收据；普通配方及其头文件新鲜度取舍不变。
- `tools/cdb_background_batch.py` 的既有 upgrade 请求支持完整 canonical flat owner 的一对一迁移。plan/work/collect 重验当前整组边界，实际收集后才持久选择偏好；新配方失效保留有效 flat，旧 flat 收据缺失不影响仍有效的新收据。
- 三份既有 batch 回归增加真实文件的生命周期、父组绑定、拒绝/超时、同大小同时间戳头漂移，以及原生 prefix/strict 共存和独立回退；未增加依赖或新的调度框架。索引 spec 同步此次选择及直接头字节边界。

**Pitfalls / Gotchas**
- 部分 child、多 owner 拼接和 legacy root-only owner 不授予首次迁移资格；catalog 记录不等同编译证明或历史采纳证明。候选 worker 成功也不能自行建立默认偏好。
- 暖启动可达性与冷启动收益分开验收；直接强制包含头的字节检查不代表完整传递依赖或负向 include lookup 证明。

**Validation**
- 独立代码与测试审查通过；required-native 下 `index_batch_background` 58/58、`index_verified_batch` 83/83、`index_batch_residual` 38/38，均零失败、零跳过。包含真实新配方资格、strict 收据共存、重复零新索引和独立失效回退。
- 其余 37 个映射文件 731/731 通过，合计 44 文件、910/910，零失败/跳过；331 文件 bare-globals、两工具语法编译、索引 spec strict 与 diff 检查通过。
- 同一真实完整批次的隔离诊断中，18 UBT / 206 成员仍为一个 main，2307 个 own shard 的可达数由 2056 恢复为 2307，五类完整记录无差分，暖启动 3.0953 秒且零项目重建。冷启动 25.4021→25.4885 秒，未证明提速；固定先后顺序、未控制 OS 缓存，无 A-warm 或独立原 TU 图并集验收。此诊断不替代公开 plan/work/collect 资格。
- 真实整组的新配方公开 plan/work/collect 均通过独立审查：native 资格索引 25.7824 秒，collect API 14.9141 秒，目录 111→112 仅追加新配方；默认复用保持 92 组、819 native、2938 行与 14,319 源。重复 work 零新证明/native，重复 collect 不重写，旧 flat 回退仍有效；新配方证明、完整输入及输出身份保持。三阶段总耗时 334.4219 秒包含修复前慢 worker 的费用，不代表优化后的首次总成本或用户激活。

**Follow-ups**
- 既有全量 dirty-union 并发失败保留 DEFER，本次未复跑全量；当前全工程冷索引与完整语义恢复尚未验收。新配方仅按显式请求用于已验证整组，用户 live CDB 和 clangd 尚未切换。

### 2026-10-18 — 减少已接受批次复用中的重复纯计算

**Task**
- 降低 SuperUnity 重复准备成本，保留既有资格、覆盖与文件新鲜度检查。

**Implemented**
- `tools/build_hot_super_unity_cdb.py` 的 `strip_write_only_flags` 使用相同前缀 tuple 直接匹配，保留参数顺序、操作数处理和原对象。
- `tools/cdb_background_batch.py` 在单次 Tier 1 `_reuse_completed` 中按需建立升级序列；前置校验通过后才请求，完整构建成功后共享，调用结束即丢弃。
- `tests/cases/index_batch_background_spec.lua` 覆盖参数保留、序列校验优先级、无升级/strict 零构建、失败扫描重试及后续调用的输入变化。

**Pitfalls / Gotchas**
- 只复用本次同步输入的纯 tuple 顺序；成员/overlay/tool 字节读取、预算、收据与完整 owner 门禁不变。严格收据仍遵循原 collector 身份失效规则。

**Validation**
- 已审候选的 AST 提取纯测试三项通过；`NVIM_TEST_REQUIRE_NATIVE=1` 下 `index_batch_background` 49/49、`index_generation` 46/46、`structure` 85/85，均零失败、零跳过。
- 其余 batch、graph、receipt、cohort、inventory、query/VFS、controlled generator、semantic client 与宿主边界映射共 40 文件、718/718 通过，零跳过。首轮 query-profile 因测试进程未设置 `UE_CLANGD` 且 PATH 未包含 clangd，在能力前置门产生 0/1 FAIL；保留该记录，显式指定现有真实 pin 后另次执行 7/7 通过，未改测试或注入假工具。
- 相同当前默认复用每侧两次：墙钟均值 15.6229→12.8194s（减少 17.9449%），进程 CPU 均值减少 19.1909%；保留 95 组、822 条 native 命令和 14,319 个源目标，完整输出相同，无写入或新 native 工作。固定 before→after 顺序、观察器开销和未控制的 OS 缓存仍是限制；两侧之间执行了上述首组回归，此数字不代表冷索引提速。

**Follow-ups**
- 既有全量回归的 dirty-union 并发失败仍按原处置保留 DEFER，本次未复跑全量。全工程冷索引性能与完整语义覆盖仍未通过恢复验收。

### 2026-10-18 — 保留强制包含头的加载边并接入严格批次

**Task**
- 让已证明的严格二次合并在后续 clangd 进程中完整加载，并保留既有 Tier 1 压缩。

**Implemented**
- `tools/cdb_verified_batch.py` 将支持的完整、有序、绝对路径 `-include` 序列写入最终候选 main 的 include 前缀，只删除对应参数位置。原 UBT 命令、成员和完整语义门禁保持；不支持的参数形式沿用原构造路径。
- 同一构造描述绑定严格队列、缓存、冻结产物、收据、恢复和激活校验；旧 collector 身份的严格证明需要重验，不能复制旧收据冒充新资格。Tier 1 构造与准入不变。
- `lua/ue/index/_build.lua` 的既有 `batch-store.json` 可用非空、唯一的 `phases` 列表限定 current/hot/full；省略时保留原行为。只选择 current/hot 时，full 继续普通缓存复用和后台队列。
- 选择文件的纯数据验证复用 `lua/ue/index/batch_descriptor.lua`；文件读取、租约与队列路由继续由 `_build.lua` 管理。三个分支共有的复用参数只追加一次，保留参数顺序并遵守原有模块行数上限。
- 普通 prepare 与两类 collect 组合当前分别验证的 Tier 1 和 strict 结果：Tier 1 整组优先，退出其 memo 作用域后才在 strict 作用域验证严格回执；重叠 strict owner 整组排除，其余原始、exact、shader 条目保持。collector 与收据准入规则不变。
- 显式 `request.residual_strict_limit` 仅接受 1 或 2，以单 worker 的严格剩余范围队列替代本次新资格队列；未指定时不追加这类资格工作。前次计划的有界游标轮转避免缓存拒绝一直堵住后续范围；游标只负责调度，循环回访仍重验当前资格与修复后的头文件，strict collect 保留实际失效计数。
- strict catalog 的父范围只作查找提示，整组边界按当前通过原收据门禁的实际 child owner 判断；保留不重叠的完整 child 和原条目，既有 owner 优先，重复 collect/prepare 不因新父组排序替换旧候选。完整父范围的完成确认仍单独核验。
- Tier 1 cache-only 调用仅在本次 stat 收据目录确实抛出 `FileNotFoundError` 时直接返回未接受的原条目和当前 deferred 分组；不创建目录、不识别工具、不启动资格。目录存在（包括空目录）、同名文件及其他访问错误仍交原 verifier；不保存负缓存，各 catalog store 分别重验，strict 路径不变。

**Pitfalls**
- 命令行强制包含的头文件可能有磁盘 shard，却没有从 CDB main 出发的加载边。只检查磁盘记录或零重建不足以证明暖进程可见性；顺序、未加 guard 的头及完整 Sources 可达性须分别验证。
- 参数操作必须识别选项与操作数；例如 `-I -include` 中后者是目录名，不能删除。标准库预索引与项目 TU 重建也须分开观测。
- 完整诊断记录的差分不等同生产语义准入：空 definition 变体被完整记录替代不能报作已知定义丢失。独立原 TU 图的并集与单进程共享缓存也须实测对照；磁盘可达性不等同当前冷进程的 live 可见性。

**Validation**
- 新增 required-native `index_verified_batch_prefix`：8/8 PASS、0 FAIL、0 SKIP。实际公开 plan/work/collect、收据验证、非空 BaseOf 关系、9/9 Sources 可达性、重复零新进程/产物保持及头文件失效回退通过。
- required-native `index_verified_batch` 81/81、`index_subset_async` 11/11、`stability` 26/26 PASS，均零失败/跳过；331 文件 bare-globals 检查通过。阶段测试包含 build 完成回调向普通 full 队列提交请求，其生成/发布边界使用测试桩。
- 首次新全量 4176/4177 通过、1 失败、2 跳过，失败为 `_build.lua` 超出既有 800 行上限；按上述职责修复到 799 行后，required-native 全量 4177/4177 PASS、0 失败、2 跳过，用时 1100.20 秒。跳过仍为私有 GTAGS 环境缺失和当前宿主不适用的“不支持 PCH”守卫；旧失败保留。该全量覆盖剩余范围接入前的代码；接入后的 required-native 全量为 4204/4204 PASS、0 失败、2 跳过，1077.49 秒，exit 0。
- 剩余范围接入：Lua queue 35/35、request 3/3 PASS，零跳过；Python/Lua 独立审查通过。required-native `index_batch_residual` R2 为 19/19 PASS、零失败/跳过、13.45 秒，包含真实 Tier 1/strict 收据、双向 mixed collect、产物不变的重复复用及头失效后仅严格整对回退。R1 的 18/19、12.16 秒失败保留：夹具将控制文件写入源码 include 库存，改为源码/控制目录分离后通过，未放宽生产新鲜度门禁。该耗时为整个 filter，非索引提速数据。
- 此前 4204 全量未覆盖 catalog 父范围仅部分 child 有效时的压缩保全回归。R3 已修复并通过 required-native 30/30、零失败/跳过、26.90 秒：真实父组和首 child 被原图门禁拒绝、末 child 通过，七次实际索引报告，重复只读及成员源文件失效回退通过；旧 mixed native 另覆盖头文件失效。70 个纯例与独审通过，旧失败证据保留。
- 缺目录优化增加七个真实临时目录回归，含目录创建/移除/重建、文件占位、异常分类及 catalog 独立恢复；77 个纯例与独审通过。合入后的 required-native `index_batch_residual` 为 37/37 PASS、零失败/跳过、27.79 秒；最新 required-native 全量为 4221/4222 通过、1 失败、2 跳过，1097.10 秒；唯一失败是既有多实例 dirty 持久化的真实争用，已单独复现，按索引范围外 DEFER 记录，当前全量未绿。旧 4204 不覆盖 R3 与此优化；本次文字更新后隐私门禁须重验。
- 真实工程已有 101 组普通复用两次保持：消耗 481 个原 UBT、保留 516 个 UBT、214 个 exact 与 2119 个 shader，覆盖 14319 源文件；无新 native 索引/写入，15675 个保护文件保持。
- 新接入后，按原审计流程再次运行默认组合导出两次，字段、顺序、成员与收据均等于原 2950 条结果：仍为上述 101 组、831 个 native 命令，15675 文件不变，零子进程/写入。审计总计 79.16 秒，两次导出分别 21.13/21.91 秒；strict 家族此次为 0，证明现有压缩保全，不代表新增严格范围已在全工程交付。
- 同输入的默认复用前后审计均保持上述 101 组、完整字段/顺序/收据及 15675 个产物，零子进程/写入。两次调用的平均墙钟由 23.66 降至 13.81 秒（41.61%），CPU 由 22.70 降至 13.41 秒（40.93%）；完整审计 82.17→62.13 秒。固定先后顺序、每侧两次调用，未控制 OS 缓存；这是实际 cache-only 复用阶段的成本，未运行 native indexing，不能当作整个 prepare、UI 或冷索引提速。
- 新严格范围的真实公开资格接受 2 UBT / 6 源文件到 1 候选；资格 API 204.74 秒。观察器后处理失败及随后仅缓存恢复合计 702.04 秒，不能把 API 子计时当首次总成本。重复 collect/plan 无新索引且产物保持；匹配冷/暖 reader 结果见下。索引 spec 同步此次构造与交付边界。
- 相同范围、单线程、空私有索引缓存的单次冷 reader 对照已完成，具体时延与资源记录保留于私有证据；固定顺序且未清 OS 缓存。候选 2775 个 own shard 全部可达；续分析完成的 A/B 对照没有源、引用、关系、旧目标或已知定义位置丢失。原始侧缺的两个完整定义在候选中补回，空定义变体差异仍原样保留，不能称完整记录逐项相同。
- 同缓存 warm 加载完成 3.29 秒、进程总时长 3.89 秒；零项目/未知/标准库重建，六个完整查询冷暖一致，2775 个 idx 的 SHA/大小/mtime 保持。未打开实际项目源修补查询，未激活用户缓存。
- B-cold 离线检查在 285.53 秒因预算停止的失败保留；独立续分析 139.27 秒、warm 校验阶段 62.15 秒均通过。包含失败的 reader 实验/审计链累计 898.75 秒，公开资格链 702.04 秒另计；这些费用不等同 clangd 加载耗时，也不能用续跑的当前输入校验追溯证明旧中断区间完全未变化。实际查询只覆盖六个样例，不宣称全量 LSP 内存等价。
- 另一真实范围的 58 源文件（31 普通、27 生成）通过严格原 TU 图并集门禁，2 个完整 UBT 合为 1 个候选，并完成公开收集、直接校验及重复复用，独立审计全部通过。首次资格阶段 153.84 秒（API 137.71 秒），八阶段累计 321.65 秒；重复阶段零新索引，7232 个证明/发布产物的 SHA、大小和 mtime 保持。该范围另完成八阶段 matched reader/图对照及独审：独立候选资格与候选冷 reader 的五类记录相同，原始→候选目标及已知定义位置无丢失；95 个完整符号记录发生空→非空定义变化，其中 20 个还改变文档/flags，不称逐字段相同。冷时延/资源明细留私有证据；同缓存暖启零项目重建、六查询两轮一致。reader 研究链 525.94 秒与资格链另计，首次资格成本超过原始冷 reader，不能称从零首启加速、全部 LSP 等价或用户激活；两个独立私有严格范围不计作全工程 103 组。

**Follow-ups**
- 完成 R3 与缺目录优化的新全量及最终门禁，再完成新增严格范围与既有 owner 的组合交付验证，再扩大严格合并范围并测包含准备/重验成本的实际收益。候选调查发现 173 对同模块、同精确上下文且符合严格预算的完整 src/gen 双 UBT；它们尚未逐组取得资格，不能计作已接受压缩。尚未安装用户的阶段选择文件，未宣称全工程性能恢复。

### 2026-10-17 — 打通严格跨类别入口并验证大组与旧资格共存

**Task**
让已证明的候选进入公开流程，继续扩大压缩，同时保留已交付的 Tier 1 性能基线。

**Implemented**
- strict 分组保留已有同类块，对同类残余迭代到稳定后再尝试跨 gen/src；默认 Tier 1 分组不变。修复了两轮规划产生的子组不能独立重规划闭合的反例，未修改语义证明或身份门禁。
- 混合发布在 live 与 verified CDB 中保留相同 Tier 1 命令；与 Tier 1 原始范围重叠的 strict 候选整组延后，保持现有严格覆盖检查。
- 真实六源、两个 UBT 的公开 plan/work/collect 完整通过。首次 worker 为 193.408s，启动三次后台索引；重复 plan/collect 均约 12s，零索引器、零查询子进程，缓存及 CDB 的字节与 mtime 不变。
- 隔离 Neovim 实际同时消费六源 strict 与五源 Tier 1；重复发布不重启，真实 active CDB 文件事件撤权后仅重启实验 reader，回退保留 Tier 1。六个严格成员的 1517 条引用、关系及 397 个目标保留，已知目标定义无丢失；五个 Tier 1 成员仅核验 own 覆盖，未证明所有 header/provider 或 LSP 行为等价。
- 27 UBT / 589 生成源按现有 Tier 1 门禁合为一组：资格调用 57.767s，其中实际索引 47.811s、CPU43.719s、峰值 WS1.41GiB。重复资格调用 2.221s，无子进程或存储改写。新私有候选损坏后完整退回 27 个原 UBT，恢复资产后再次复用；真实项目源未修改。
- 扩容接口接入前的分组/发布修正重新验证原有 101 组全部可复用，481 UBT 的合并资格保留；14319 源、214 exact、2119 shader 完整，831 条已发布 native 命令不变，零新 proof，15552 个受保护文件未变。
- 后续增加精确大组提案：仅对该组传入有界 packing，实际重验单个大候选后整体替换完整旧组；旧 catalog 保留以供失效回退，普通 prepare 的既有复用入口可发现已接受升级。默认分组不重排，严格拆组恢复仍逐个核对真实子组与候选。
- 正常后台队列接入 Tier 1 自动大组优先：每轮最多两个候选，各限 32 UBT / 32×384KiB 成员字节预算；同 tuple 保序，并把当前有效 owner 与原普通小组作为不可拆单位。首次直接验证大组，已暖小组仅做增量升级；只有最终 collector 实际采用且发布确认成功，才跳过对应小组资格。失败、失效或未采用则释放原小组任务，已有有效资格继续保留；恢复流程不会把旧 worker 成功当作跳过依据。
- 新空资格缓存的真实队列 A/B 已完成：27 UBT / 589 源从四次小组 worker 减为一次大组 worker，队列耗时 156.830→72.425s，减少 53.8%；四个子组经实际 collect 与私有发布确认后跳过。此轮验证首次资格调度收益，未激活用户 reader。
- 修正实验 observer 后的 repeat V2 两侧均通过：普通四组队列 11.3635s，合法执行一次产物不变的 collect；自动大组队列 7.8501s，无 collect。两侧均零 worker/native/新资格，选择与首次相同，状态和发布产物的 SHA、大小、mtime 均与首次及重复前后相同。
- 全输入真实只读规划完成：3330 原始条目包含 997 UBT、214 exact、2119 shader，覆盖 14319 个 native 物理源。空资格缓存 auto off/on 规划为 14.203s/24.730s，已有资格下 auto on 为 36.628s；零规划子进程和资格资产写入。排序修改前的 cap2 在两候选成功时仅将 110 个普通资格任务预计减为 107，并非全工程已取得资格或索引提速。
- 27 UBT 的新公开增量流程已实际完成：四小组资格/收集 → 单大组资格/收集 → 普通 prepare 入口发现升级；589 源保持，私有大候选损坏后精确回退四个有效小组，恢复后重新采用大组，重复调用不改产物。串行四组 worker 合计 159.608s，单大组 54.431s；这是资格范围实测，不是全工程首次墙钟。普通重复复用由约 3.352s 增至 4.157s，仍有额外验证开销。
- 同一私有缓存的四组到单组 reader 实测完成：旧四组首次 61.705s、原样暖启 4.087s、升级后 40.850s（CPU36.953s、峰值 WS1.39GiB）。589 成员的完整引用/关系与已知目标定义位置保留，升级产物与独立单组资格在所比较范围一致；13 个新增未解析 ID 已确认为关系对象，旧全局符号表也不含它们，不能报成旧目标丢失；完整 header/LSP 等价仍未证明。
- `tools/cdb_verified_batch.py` 在一次 Tier 1 调用内仅保留 overlay/tool 两个最近完整字节及摘要；每次仍实际读取并比较全部字节，相同才复用 SHA，不同继续原有验证。外层正常/异常退出清空，源文件和 strict 工具检查保持；不引入时间戳信任或跨 prepare 缓存。
- 后续已应用限定恰好两候选的 cohort 资格原型及 20 个协议/收据用例；四成员烟测和真实 UE 已知闭包的 27 UBT / 589 成员双组资格、同缓存 reader 均已通过。完整语义、匹配首次成本和用户交付验收仍未完成，不能沿用此前全量通过作为新代码门禁。
- 曾实验按待资格普通子组数降序选择大组；两个优先源文件类候选真实编译均失败后，已撤回该排序一行及新增排序用例。原自动 large-first、cap2、policy v1、32/32 packing、资格/整体 owner 门禁保留，未以普通全量索引替代已保留的压缩能力。
- 生产strict API新增`accelerate(..., group_indexes=None)`：默认发现策略不变，显式索引只选择一个完整原始范围，仍执行原strict proof/cache/成员与预算门禁；失败不改用较小范围冒充成功。非法索引、max_sources=None及坏caps前置拒绝，未新增CLI/Lua接线。代码已集成，专项和新全量验证状态见下文。

**Pitfalls / Gotchas**
- 同模块、完整上下文相同、同成员类别且保序的大组仍属于 Tier 1；旧八 UBT/字节预算是规划限制。此前将严格 header UNION/provider 失败作为该大组的必经门槛是不当扩展，已纠正；已发现的真实源引用、目标或定义丢失仍不得忽略。
- Tier 1 不绑定 strict collector 文件摘要，修改严格分组器不会自动使全部 Tier 1 收据失效；改变默认分组或候选字节仍可能破坏复用，必须看真实产物。
- 已有四组覆盖全部原始索引，不等于新的大组已验证；增量升级必须实际重验新收据、原子替换完整旧组，并保留旧资格用于回退。
- 自动调度回归暴露真实 whole-owner 缺陷：collector 先排除已采用的 16 UBT 大组，再把旧 catalog 与新 32 UBT 提案按大小重排，导致新组通过时看不到旧 owner 的部分重叠。现先完整重验当前选择，再评估新提案；未采用的新父组不得获得确认或进入 catalog，后续普通复用仍保留原 owner。计划结构校验与当前资格门禁分开，父组因源大小变化超预算时，不阻塞仍合法的小组验证。
- 混合 reader 首次 raw 图审计有两条引用列号不同，原失败记录保留。初始化协议、实际源码和 clangd 22.1.5 源码闭环证明：资格默认 UTF-16，Neovim 协商 UTF-8，13 个中文字符产生 26 列差值。按确证编码转换到相同物理字节位置后，六源完整引用 multiset 相等，未改 SymbolID 或丢弃引用；后续资格缓存交付必须额外绑定坐标编码。
- 全工程保存产物的完整源图审计未通过保全：源 own 节点相同仍有引用/全局目标差异。定向完整解码确认两例旧ref-slab记录保持原样、候选磁盘索引却没有目标符号和定义，其中一例所属原 UBT 未合并。后续role核对区分一条含Reference与一条definition-role记录，不能统称真实调用悬空。这两例的历史全工程成因仍未闭环，不能把该现象直接归为源 TU 合并错误，亦不能用新增符号更多抵销已丢记录。
- 后续六 shard 实测在单候选资格中找到已丢目标，而三侧源引用与源/头 digest 相同。独立小型因果实验进一步证明：相同最终 CDB/有效命令、三源引用/关系相同，先前子集 producer 的完整缓存仍可改变宏生成方法的持久目标集合。正向四个方法 ID/八条原引用失去目标，反向另两个 ID/四条引用失去目标，不能混算方向；标准库索引另报不完整。它没有重建历史全工程时序，也没有验证实际 LSP 跳转。
- 后续真实 LSP 对照确认该小夹具的纯索引方法查询有差异：六个带类名的方法查询对应不同缓存出现/消失，三类正向控制均通过；打开源文件后两侧又都能返回定义和引用。零后台 TU 重建，完整缓存字节/mtime 保持；前台成功不代表持久缺失已修复，也不外推全工程跳转失败。首轮实验脚本误拒 clangd 正常推断命令，按固定版本源码修正后重新实测，原失败保留。
- 589 源四到一对照中，112 个退出成员局部存储的 ID 仍全部存在于全局；13 个新增未解析 ID 全部仅作为当前可达头文件的关系对象出现，无直接引用/container 记录，独立冷单组也相同。旧全局符号记录也不含这 13 个 ID；缺失集合的差分不证明旧符号存在，这是新增未解析关系，不能报成旧符号或源引用丢失，也不能拿额外全图条件替换 Tier 1 三门。完整 header/LSP 等价仍未证明。

**Validation**
- required-native：`index_generated_super_unity` 16/16、`index_batch_background` 23/23、`index_verified_batch` 65/65、`index_batch_publication` 73/73，均零失败与跳过。
- 公开严格流程、27 UBT 首次/重复/只读复用/私有候选失效、101 组只读复验及上述混合生命周期/六源物理坐标审计通过；升级接入前串行全量 4095/4096、1 FAIL、2 SKIP，失败为搜索历史两个真实进程写入后的单条记录计数缺失。该 filter 随后独立重跑 16/16、零失败与跳过；保留全量红灯，不用重跑结果覆盖它。索引 spec 同步此次选型与纠错。
- 升级接入后 `index_batch_background` 36/36、零失败与跳过；首跑发现非法 tier 组合在拒绝前进入 cache gate，已将顶层参数校验前移并重跑通过。新增 9 个升级、4 个 strict split 场景的 native indexing 使用 mock，真实收据/复用/catalog 逻辑执行；后续真实大组调度流水及最新全量另有下述通过记录。
- 全工程审计完整解码 33030/32650 个 shard，14319 源和 32032 个真实文件均保留；发现 352 条旧引用记录减少、68431 条增加。源相关引用/容器/归属/关系端点全集中，890 个旧 ID 在候选全局符号表缺失，不能直接等同 890 条悬空引用；两例已独立复核为保留ref-slab记录对应的磁盘目标缺失。原“两个悬空引用”表述现按role纠正：其中一条是definition-role，附加Call位不证明真实调用。另一区分样例仍有其它定义位置，一个仅签名/补全文本不同。全部 shard 当前字节前后校验通过，但历史完整头文件/shard 预封存仍有缺口，未宣称完整 LSP 内存图等价。
- 升级接入后直接调用真实默认全量 scheduler 两次：均保留 101 批次、516 UBT、214 exact、2119 shader 和全部输出字段/顺序，零新 proof/子进程/写入，15675 个受保护文件不变。核心调用 35.840s/36.953s（含只读计数观测，不含封存），并非完整 UEPrepare 耗时；保全产物不代表上述语义缺口消失。
- 成本采样的 41.906s 调用中，SHA-256 实现独占 11.688s；同一个 overlay 读取 3188 次、工具读取 108 次，合计约 26.71GiB 应用层读取，不能称物理磁盘流量。摘要复用后同一输入两次调用为 30.700s/27.487s、CPU29.125s/26.172s，全部 101 组、输出顺序和 15675 个受保护文件保持，零写入/子进程。固定前后顺序、非独占宿主；该收益只覆盖重复 scheduler 调用。required-native `index_verified_batch` 最终重跑 68/68、零失败/跳过，包含正常/异常 scope 退出立即清空 memo 与恢复 depth 的断言。
- 自动大组优先修复后，`index_batch_background` 46/46、`index_batch_queue` 27/27，均零失败/跳过。保留后台首轮 45/46 的 whole-owner 真实失败及修复证据；队列首轮 15/27 的失败是列表断言误用引用相等，改为内容比较后重跑。新增调度 fixture 的 native indexing 使用既有 mock，执行真实规划/收据/collect 或队列状态逻辑；上述新空资格缓存 A/B 另行运行了真实索引器。索引 spec 已同步此次调度方向与 13-ID 纠错。
- 新队列 A/B 均串行执行，27 UBT、589 源与 3578 个真实 own 路径完整；A 的 native 索引合计 119.7485s、CPU108.3281s、单进程峰值 WS 最大 1272692736B，B 为 49.1461s、CPU45.5156s、峰值 WS1513877504B。队列墙钟包含规划、资格、收集和私有发布回调，未包含后续审计或冷 reader；私有发布回调不等于用户激活。顺序固定 A→B，未控制 OS 文件缓存。repeat V2 及最终比较均通过：首次 A/B 的 3578 个 own 路径、digest、flags 相等，两个 repeat 与比较阶段的 V2 代码封存一致；本轮只验正向 own 闭包，不宣称完整引用/目标等价。旧 prepare 路径解析错误、首次 repeat 误拒合法 collect 的两次 observer 失败仍保留，合计 171.307856s 属研究失败成本，不是生产资格失败。
- `structure` 85/85、零失败/跳过；本批更新前的索引 spec strict 校验通过，现追加已完成比较及冷/暖加载边界后的最后文字待复验。此前全部 spec strict 校验40/41，未修改的 `android-so-quick-deploy` 第六条 requirement 缺少 Scenario，已单独复现并记录为范围外既有文档缺陷；不得表述为全部 spec 全绿。
- cohort 接入前的最新已完成串行全量 **4136/4136、0 FAIL、2 SKIP，exit 0**。两项跳过分别为 GTAGS X1 原生私有证据缺所需环境变量，以及当前宿主支持 PCH 时不适用的 unsupported-host 守卫。旧 4095/4096 搜索历史失败保持原记录；这次通过不代表旧失败原因已定位或独立错误处理缺口已修复，也不覆盖后续 cohort 代码。
- 全输入规划的源出现次数覆盖相等、catalog 与所检查源文件大小/mtime 保持；已有 101 组资格仍对应 481 个合并 UBT、2950 条实际复用输出。2931 条是候选全部通过后的预计值，未发布。候选排序 survey 在当前规则下发现 25 个候选，计数排序曾预计 104 个资格任务；该全成功前提随后被两次真实编译失败否定，不能报成收益。实验排序已撤回，cap2 保持，旧调查封存不改。
- 此全输入 greedy 计划没有与已实测 27 个生成类 UBT 完全相同的候选，该范围被拆进带额外原 UBT 的两个组；排序前两名又属于源文件类。窄范围 A/B 通过及 53.8% 队列收益不能为这些不同候选代替 native 资格或收益验收。
- cohort 接入后 AST 3/3 通过；首轮专项回归 **19/20、1 FAIL、0 SKIP** 保留。独立诊断确认 legacy fixture 的反斜杠成员路径导致收据输入排序与旧 helper 的字面正斜杠路径不一致，触发 `tier1-cache-inputs-changed`。只修正夹具两条手工成员路径，未放宽生产校验；r2 **20/20、零失败/跳过、exit0**。实验排序版本的后台47/47和既有 verified68/68保留为当时结果；排序及新增用例回滚后的 cohort 全量已通过下述4156项检查。
- 小型真实 cohort 烟测通过：4 UBT / 4 成员合成 2 候选，单 producer 资格 3.0591s，其中 native 索引 2.4480s、CPU1.375s、峰值 WS58,953,728B；同缓存 reader 作用域验证 0.3356s、索引 1.2349s、进程 1.3005s。完整 worker4.8469s、supervisor6.0535s；8 个 shard 的 SHA/大小/mtime 不变，实际 CDB、UTF8、完整进度与零 reader `Indexed` 检查通过。保留编码扩展弃用日志，无编译失败/HadErrors；未测语义 LSP 等价、用户激活、冷 reader 对照或 UE 性能，不据此宣称总首次提速。
- 排序修改后的真实全输入 fresh 规划通过：auto off/on 为 15.8293s/21.5202s，实际选择此前调查排序前两名的源文件类候选；110 个普通定义加 2 父组、8 deferred、104 ready，全部成功时预计 104 secondary / 2893 条输出。覆盖保持、零规划子进程/资格写入，worker64.7842s。修改后的独立 warm 规划也通过：planning39.5752s、worker62.8853s，实际 101 组/481 合并 UBT/2950 行及覆盖保持，零子进程/资格写入；2931 行仍是候选全成功的预测。两者均非 native 收益。
- 真实 27 UBT / 589 成员的双组 cohort v1 准备通过，supervisor29.1147s，其中已知闭包预封存7.9190s、3628 个受保护文件。随后资格阶段6.0692s失败，尚未创建 native 进程：私有 observer 错把 Windows Python 审计的空 executable、命令字符串按路径和 argv 列表处理。原 `cohort_run` 为空、三份 producer 日志为空、无部分资格提交；固定本机源码及独立审查已确认失败发生在 `CreateProcess` 前。旧封存/失败和已发生费用保留，修正后在新 V2 私有目录重新准备，不把旧失败计作 UE 编译或语义拒绝。
- required-native 既有图兼容过滤 **12/12、零失败/跳过、exit0**。cohort 加排序回滚后的首次全量以 require-native=1 运行，**4156/4156、0 FAIL、2 SKIP、exit0，1126.2106s**；它早于随后实施的loader gate，不能作为新门禁验证。两项跳过仍为 GTAGS X1 私有环境缺失和当前宿主不适用的 unsupported-host PCH 守卫。旧4095失败和4136历史通过不抹除，全量通过不代表旧搜索历史触发原因已定位。
- 真实 UE cohort V2 准备、资格、暖 reader 均通过：准备 supervisor30.1079s（已知闭包封存7.9928s）；单 producer 接受两组/27 UBT/589 成员，Q API71.6585s、native 索引50.4398s/CPU45.8281s/峰值 WS1,489,403,904B。reader 作用域验证6.0555s、索引3.8111s/进程3.9030s/CPU3.2188s/峰值 WS374,104,064B；3581 个 shard 的 SHA/大小/mtime 与绑定资产不变，实际 CDB/root/环境/UTF8/完整背景进度通过，零 `Indexed`。这是原位复用的工程范围证据，尚未证明语义 LSP、原始 UBT 全图保全或用户激活。
- V2 成功 prepare/Q/warm 的 supervisor 合计159.4581s；资格内 manifest 解码9.2909s，另行研究快照3581 shards/34,592,296B耗时25.0669s。其后完整审计26.1120s通过：3578 个真实 own 路径、589 成员、249679 条成员引用出现次数、6 条成员关系，producer/reader 缓存字节相同；没有 A/原始 UBT 语义比较，仍不证明目标保全或 LSP 等价。旧 v1 准备29.1147s和 guard 失败6.0692s继续计为额外实际费用。
- 新 A 基线的准备、四次独立资格、空缓存 UTF8 cold reader 全通过。指定必要组件为 Q117.902419s+CDB0.0066427s+reader56.7364s=174.6454617s；B 已知闭包预封存+Q+lease+reader 为89.6098515s。后续离线比较已完成，但尚未比较真实 cold-live A 与 warm-live B，因此不能称等价ready加速。A/B supervisor 合计250.6105878s/159.4581355s的研究开销不同，不能当生产倍数；固定 B→A、OS 缓存未控制，也不代表未知闭包首次总账。
- 两个 ranked source parent 均真实编译失败且未采纳，work+collect 累计175.8325254s；每候选一条 aggregate compile failure，均非超时。收集保留全部997 UBT、214 exact、2119 shader，零小组 fallback worker，回退成本仍未测。精确源码原因缺诊断支撑，不能归为已证宏/重定义问题；104 任务只是未实现的历史预测，失败记录与私有负资格保留。
- 离线 comparator 完成47.1259s：3578 real-own digest/flags一致，589成员的249679引用和6关系完整Counter相等。50成员的98删/28增符号记录分别为14声明位置变化、14定义补充（其中7伴随文档/flag补充）及70条局部声明记录移除；相关ID仍全局存在。公共31565成员目标域内，旧实际目标ID、已知定义ID及定义位置均零丢失；完整全局数量与delta另可推导两对称视图均零整ID消失，但并非所有字段相同。
- 两侧磁盘恰有同一组312个loader不可达shard，disk-all与reachable之间各差13690个ID；所有589成员可达。冷编译直接安装slab，暖进程只按main可达图加载，两种对称离线比较不等于实际cold-live/warm-live比较。forced-include的虚拟predefines可能缺真实includer FileEntry，省main边而仍产own节点。新guarded微型夹具四次native运行通过：原方案目标冷有暖无；保留`-include`并从wrapper显式include同一guarded头后，真实main边出现、目标冷暖均有，orphan从2变0。成员引用/关系和目标记录相等，两warm均零重建、5个idx的SHA/大小/mtime不变；完整supervisor6.0506s。原observer误判`.gitignore` mtime导致的3.5523s失败及两次native仍保留，两轮合6次native，不能把旧失败覆盖为通过。
- 上述guarded夹具已完成独立实际结果审查，原始查询、命令、进度及全部Sources-key可达遍历相符；该成员只有2条ref、0条relation，空关系集合相等不代表非空关系图验证。工程三root记录检查显示内层guarded头自身无符号/引用，外层PCH和另一root有独立记录，不能据此宣称内层anchor修复全部312路径。完整工程cold-live/warm-live可用性及安全include顺序仍待验证。
- 新真实窄范围准备、producer及同缓存warm reader均完成，114成员的四组查询Counter在冷暖相等，warm零重建。一个待查目标在首次producer已有definition-role ref-slab记录，但磁盘、可达图和live均无目标；这不是冷到暖丢失的证据，也不能把collector附加的Call位当真实调用。另一个含Reference位的记录在两阶段的目标均存在。累计supervisor109.4051s已含旧私有observer失败17.1360s，既非全工程提速，也不关闭首次producer缺口；旧失败不是工程编译失败。
- 同缓存reader交接的loader可达性门禁已实现并冻结：从实际最终CDB mains沿全部Sources keys检查完整own-shard可达性，失败只拒交接，保留两个已接受候选、压缩与普通schema1资格收据；旧v1交接证据拒绝。专项contract `index_tier1_cohort` **28/28、零失败/跳过**，AST、静态及真实结果独立审查通过。两真实producer实验8.0523s：textual9/9 own可达允许交接，forced-only9/7拒绝；两边均保留2收据/2普通复用命中且产物SHA/大小/mtime不变。零native reader，不能称暖reader通过。随后require-native=1全量 **4164/4164、0 FAIL、2 SKIP、exit0，1262.9491s**；两skip仍为GTAGS私有环境缺失和当前宿主不适用的unsupported-host PCH守卫。该全量仅覆盖pre-explicit loader checkpoint，旧4156为pre-gate历史；可达结构仍只是必要条件，不足以证明完整语义或性能恢复。
- 共享宏头V1 split/unity两次fresh native实验3.5734s复现局部目标差异：实际split先B后A，A原调用位置的Reference-bearing记录保留却无磁盘/live目标，unity中目标存在，且两臂所有own均可达。完整引用Counter相等、关系均为空；独立审查保留B目标flags0→8及成员main/include混杂。原PLAN的run后文字澄清已另存原版本并核对原seal，旧attempt/封存未改。
- V2双侧include-only wrapper对照随后完成两次fresh native，3.5686s、exit0、实际B→A。A/B各3个完整符号、7条引用、空关系的Counter均相等，消除成员main/include字段混杂；共享宏头split1/unity2符号，唯一新增是此前缺失的A方法，B方法全字段也相等。独立runtime审查已完成：全局7→8符号、零移除/仅一新增，15条完整引用相等且全部own可达。真实调用由表达式及位置绑定证明；成员记录保持仍不能保证共享头目标完整。此为微型机制证据，未还原真实工程中间状态，也不是工程资格或性能验收。
- explicit strict最新38行source及修复已独审，新增5个生产测试；私有五场景non-native验证通过，涉及路由/缓存的场景使用明确标注的拒绝桩或合成收据，不能冒充真实资格。生产required-native `index_verified_batch`专项 **73/73、0 FAIL、0 SKIP、exit0，160.3344s**，包含原68项与新5项；接入后required-native全量 **4169/4169、0 FAIL、2 SKIP、exit0，1295.6126s**。两skip仍为GTAGS私有环境缺失和当前宿主不适用的unsupported-host PCH守卫；4164保留为pre-explicit历史。
- 真实公开strict入口小范围资格及独立审查已完成：4完整UBT跨src/gen合为1，外部exact1/shader1完整保留；资格5.845651s含4原始基线和1候选的5次实际索引。重复cache-only0.123874s、零native，85项保存产物身份不变；唯一私有成员变化后完整回退原6条记录，零新proof/native。负例validator false及第三次库存相等由helper断言留证，未另存第三份库存及失败 validator 返回体，不冒充独立重比。默认UTF16、ASCII无header夹具、无workspace查询或用户激活；这是资格/复用/失效链验证，不是完整冷reader、真实工程资格或全工程加速比。
- 当前实现的 Python AST **4/4通过**。此前隐私r3扫描3482行及后续loader-r1扫描3707新增行均通过，后者含1个untracked cohort测试及author/committer；cpp semantic spec strict也通过。本批追加full4164/V2文字后须重跑隐私与spec校验，不能沿用3707行扫描作为最后文字证明；历史all-spec40/41的Android缺Scenario仍单独保留。

**Follow-ups**
- 自动大组优先的空资格缓存队列 A/B 与 repeat V2 已完成，仍待大组实际 Neovim 交付、保留其它 TU 时的缓存升级与新的全工程冷索引对照；完整首次成本须计入失败大组、小组回退、收集及 reader，不能将旧 101 组资格当作首次免费的先验。窄范围 own 闭包及既有混合生命周期验证不能替代完整性能验收。
- 先处置全工程实际目标保全差异；既有 1656.6612→1140.4418s 只保留为同输入速度实测，不能表述为完整正确性与性能验收通过。自动扩容从首次资格到实际 reader 交付的总成本仍需继续验证；cohort 接入前的功能全量通过不关闭这项验收缺口。
- 并发搜索历史失败仍待独立定位；本轮索引改动未触及 history store/锁实现，不为推进索引调查而改动无关搜索语义。保留旧失败与新全量通过各自证据，继续隔离研究，不据新全量通过宣称旧缺陷已修复。
- 保留原自动 large-first，计数降序实验已撤回。guarded机制、窄范围P/W1、loader gate真实producer、full4164及双侧included宏对照已完成，继续独立复核机制并定位真实工程首次producer缺口。不由夹具成功直接修改真实PCH或采用统一anchor。保持producer进程并非小配置接管，仍缺owner客户端的观察/发布/attach生命周期。离线保全、费用差与功能全量均不关闭工程cold-live/warm-live差异、用户接线或原全工程目标丢失问题；目标仍未完成。

### 2026-10-17 — 核实跨类别资格与索引声明证据的边界

**Task**
继续验证更大压缩和首次资格成本，区分图比较、实际资格及 LSP 行为。

**Implemented**
- 六源跨 gen/src 样本的公开分组器实际选出 0 组；此前严格图比较通过不代表生产入口可达。仅在私有工具副本增加显式分组入口，保留全部冻结、目录、编译器及语义门禁，完整资格流程通过并生成真实 schema2 收据。
- 完整实验墙钟 212.3876s，资格调用 206.3195s；三次独立原始/候选 native 索引合计 116.7211s，其余包含输入冻结、图解码、比较、序列化及目录校验。补齐此前未预封存的 36 个依赖，2822 项输入前后不变。该结果不等于首次启动更快。
- 重复资格调用 11.3333s，命中一组、无新证明、无子进程启动，存储文件清单、大小和时间戳不变。修改私有命令宏后不复用旧资格；私有冻结头快照被修改后收据拒绝。生产验证器实际以工具身份变化拒绝试验收据。
- 同一资格候选的完整 2775 shard 单独封存交付后，相同有效命令的空缓存 reader 为 35.8216s，复用 reader 为 3.4014s；后者无候选 TU 重建，两侧完整图均与真实收据摘要一致。仅限这一个候选，标准库工作仍计入 reader 时间，不能称为冷启动优化。
- 独立微型夹具经真实宿主编译器取得完整资格后，实际头文件内容变化和此前不存在的可选头文件出现均触发收据失效；测试文件恢复，真实项目源未改。最初缺显式 target/sysroot 的夹具被原门禁拒绝，修正来自真实编译器能力查询，未绕过检查。
- 27 UBT 样本的两个真实 TU 经同版本 libclang 检查，同一类型引用在原始及合并上下文中均绑定同一 ID、同一声明位置，两个 TU 均无编译错误。原索引图只保存引用，不能据此认定编译器没有声明；撤回这两个上下文在该位置因合并改变 canonical 声明的推测。
- 对剩余 39 条头引用删除定向读取 24 个 shard，15 个位置在候选中均非空、集合均等于原始 context0；11 个位置完整核对后仍存在目标子集减少或替换。另一上下文的完整 run 清单未列出相关头文件，四位置保留上下文缺口。不能称整位置丢失，也未证明目标差异无害；未改变门禁。

**Pitfalls / Gotchas**
- LSP 观测须分开标准库、前台 AST 与工程后台索引。首轮脚本将标准库日志误判为工程缓存重建，已保留失败记录并修正分类；两侧有效重跑均无工程后台 TU 重建，原始缓存及输入 seal 不变。
- 纯缓存 workspace 查询出现声明位置变化；相同实际 wrapper 命令下，另一类型的补全插入头文件也确实改变。该头文件已在原始 provider 集合中，但尚未证明完整 LSP 等价或定义可用性。目标类型两侧均因头文件不在 include path 上而未生成插入编辑，不能解释成已经包含。
- 合并侧后续直接打开源/头文件时推断到了惰性触发文件的命令，缺失头文件并返回空查询结果；这组前台对照无效，不能将空结果归因于合并索引。真实 TU 的编译器绑定检查保留为独立证据。
- 缓存封存、完整解码验证和复制本身耗时 58.6297s；复用 reader 的前置验证/复制另耗 32.3438s，后置图验证另耗 45.6152s。首次资格、封存及复用阶段的 supervisor 墙钟相加为 353.6809s，仍未包含准备阶段，也不是一次端到端计时；当前原型没有证明首次启动净收益。生产接入需明确复用资格输出的证明边界，不能直接删除校验来制造收益。

**Validation**
- 完整私有资格、重复复用、生产身份拒绝、命令/冻结资产/夹具头文件/新增 include 路径失效检查通过；原始 TU 定向绑定证明及完整缓存复用对照通过。
- 本轮未修改生产索引实现或 live cache；文档结构 85/85、索引 spec strict validate、diff check 及新增内容脱敏扫描通过。索引 spec 记录了资格入口、声明证据及 LSP 命令上下文的验收边界。

**Follow-ups**
- 公开分组入口、更多原始上下文的 provider/声明补证及资格产物复用的生产接入仍待推进；尚无新的全工程冷索引或首次启动提速结论。

本轮 Tier 1 切片已归档至 [2.9.0](release_2.9.0.md)；提交前串行全量 4079/4079、0 FAIL、2 SKIP。

### 2026-10-16 — 单次 Esc 取消搜索与全局 scratch

**Task**
落实 scratch 中记录的搜索退出、长行阅读和跨工程共用笔记需求。

**Implemented**
- Snacks picker 输入窗在 insert / normal 模式均以一次 Esc 执行原生 cancel，保留原窗口与视图恢复。
- scratch 使用全局 Markdown 文件，按 count 区分独立笔记；长行开启 wrap、linebreak、breakindent，保留隐藏自动保存与旧笔记历史。
- 简化原项目隔离说明，同步用户手册；当前会话只更新这几项配置，原笔记保留并复制到此前不存在的全局文件。

**Pitfalls / Gotchas**
- 原生 cancel 与单纯 close 的恢复语义不同；沿用既有 Esc 的 cancel 动作。
- 隔离原生 smart 测量的空 cache 会触发上游 SQLite 下载；复测使用本机已有 DLL，并将临时目录隔离，没有新增仓库依赖。

**Validation**
- `review_editor` 9/9、`keymaps` 85/85、`commands` 167/167、`smoke` 19/19；改动 Lua 的 AST lint 通过。
- 原生 Neovim ext_linegrid：grep、smart、files、真实小 C++ clangd document symbols 各自从 insert / normal 一次 Esc 退出，8/8 保留原窗口、buffer 和 view。
- 单行内容实际显示为 4 行且字节不变；隐藏自动写入、两个真实 cwd / branch 共用同一笔记、count 2 独立、旧项目笔记仍可列出均通过。
- 当前用户会话配置核对通过，现有笔记内容与原文件一致；未进行 Neovide GPU 渲染测量。此条发生在 2.9.0 提交之后，不冒用该提交的全量结果。

**Follow-ups**
- 后续提交前按仓库门禁再跑串行全量。

### 2026-10-16 — 验证 Tier 1 全工程冷索引收益并分离首次资格成本

**Task**
继续核对 SuperUnity 的实际采用与冷启动成本，保留历史完整测量口径。

**Implemented**
- 只读复核正常后台队列：110 组全部尝试，101 组采用、9 组保留原命令；481 个 UBT 合为 101 个批次，native 命令由 1211 降到 831，14319 源与 2119 shader 记录完整保留。
- 完成独立空 shard、同 clangd 22.1.5/profile/j8 的全工程 A/B：原 UBT 1656.6612s → Tier 1 1140.4418s（27:36.66 → 19:00.44），耗时减少 31.16%，约 1.45×。
- CPU 11988.17 → 8371.16s（减少 30.17%）；峰值工作集 10.38 → 10.99GiB（增加 5.91%），1Hz 采样峰值 private bytes 12.16 → 12.70GiB。本轮证明提速，未证明降低峰值内存。
- 独立审计补足主比较未核对的逐文件 flags、全部 native 主文件 own TU/错误标记及原始失败日志；将非 TU 缓存角色变化的已复现机制同步到 spec、约束索引与知识库，自动修复仍未落地。
- 两组同 context 的生成源候选（220 源）共享 j1 资格 reader：全新缓存正序 45.5183→33.8680s，另建全新缓存反序 45.3288→33.5427s，减少 25.59%/26.00%；CPU 减少 23.15%/23.55%。独立峰值 WS 约 1.04GiB，共享约 1.12/1.20GiB；仅是原生 worker 组成部分的收益，尚未接入生产队列。

**Pitfalls / Gotchas**
- 首次资格队列跨度 76 分 57 秒包含调度、等待与并发，不能当作一次冷索引耗时；已有资格后的索引收益不能隐藏这项首次成本。
- 9 个未采用组中，6 个是完成后的编译失败，3 个在 90 秒内未完成；后 3 个不形成永久拒绝，且其中 2 个也记录了编译失败。
- 原 j12 实验因宿主 commit 余量不足未启动；后续另建 j8 对照，保留原记录。新 j8 的 27 分钟基线不能与历史 j12 的约 20 分钟直接相比并判为退化。
- 此处冷指 reader shard 为空，资格收据已存在；OS 文件缓存未清，A→B 固定顺序、宿主非独占。全部成员源预先封存，头文件依赖未完整预封存；实际产出的 source/header own 摘要及标记相等，也不等于完整 symbols/refs/relations 图等价。

**Validation**
- 101 份收据重新验证，零新 proof；23337 条保护记录对应 15534 个不同路径，14319 个源字节一致。
- 全 A/B 两侧正常完成、退出 0、无编译失败、无缺失或冲突；14319/14319 源覆盖，32032 个实际 source/header own 集合、digest 与 flags 相同。全部 1211/831 条 native 命令及各自实验触发文件均有无错误的 own TU shard，前后 seal 未变。
- IDLE/j8，启动 physical/commit 准入 20/22GiB；两侧最小宿主 commit 余量 10.34/9.05GiB，未触发 4GiB 连续三样本保护，采样无错误。
- 两候选正反序实验各自封存 2410 个文件，220 源、2379 个 own 文件集合/digest/flags 一致（其中 2 个是候选 wrapper，实际 source/header 为 2377 个）；六次原生运行均完成、无编译失败或标记冲突，跨顺序对应产物的 own 内容也相同。各实验总耗时 103.85/103.19s，均在 180s 预算内；原生索引时间与实验总时间分别统计。
- 真实 live cache 中 101/101 候选具有无错误的 own TU shard，14319/14319 成员 own shard 存在；无解码错误或预算截断，检查前后发布一致。
- 831 条 native 命令均有 own shard，其中 829 带 TU 标记；另外 2 条不能仅凭缓存存在认定本次 TU 编译完成。当前客户端无 pending progress，但没有可追溯的本次 begin/end 时间，不能倒推冷索引耗时。
- 文档结构回归 85/85、索引 spec strict validate 及新增内容脱敏扫描通过。

**Follow-ups**
- 首次资格建立的端到端收益仍待测。后续图审计发现共享两 TU 相对独立原图新增 717 个不可解析源引用目标、22 个目标失去 definition，不能将共享产物直接交付；own 摘要相同不足以证明目标保全。旧非 TU shard 的自动定向修复尚未实现。

### 2026-10-16 — 查明继续压缩的范围与源引用验收缺口

**Task**
19 分钟全工程冷索引仍不足，继续研究更大的真实合并收益。

**Implemented**
- 保持当前模块、完整上下文及 gen/src 边界时，即使不限制块大小，当前输入的 native 命令理论下界仍为 726；只提高 8 块上限而保留 3MiB 预算，规划结果不变。跨 gen/src 的同模块完整上下文研究下界为 516，均为包含未合并 UBT、合并 TU 和 exact 的 native 命令数下界，不是耗时预测。
- 全量日志与 1211/831 条命令一一核对；368 个分类单例占候选 reader 引用记录出现量的 46.43%，214 个 exact 占 20.00%。这些含重复头文件，不能冒充 CPU 占比；现有 info 日志没有逐 TU 起始时刻，无法给出单 TU 耗时排名。
- 同上下文 220 源的 12 UBT 真正合成一个 TU，相对两个候选 TU 从 33.3866 降到 26.6329s；源 refs/relations 不变，恢复共享两 TU 相对独立原图缺失的 739 个目标及定义。没有将共享缓存直接拼接交付。
- 两个跨 gen/src 小样本保留 9 源及源引用目标；同进程两原 TU 对照分别为 10.4010→6.6268s、7.8080→6.9024s。原 TU 独立缓存用于语义基线，其耗时不相加冒充正常 reader 基线。
- 再从 174 对同上下文 src/gen 中选择引用输出最多的一对（6 源），既有严格图门禁原样通过；成员 refs/relations 及相关目标全部字段保持，无新增缺失或失去定义。全新同进程两 TU 对照 44.4522→合并 34.0266s（减少 23.45%），CPU 40.2656→30.5000s，峰值 WS 1.482→1.458GiB。证明存在可先沿用严格门禁推进的跨类别组。
- 更大同上下文生成源样本为 27 UBT/589 源，当前四批次→一批次，wall60.2704→42.7426s（减少29.08%）、CPU55.6875→38.6094s；峰值WS1.305→1.403GiB（增加7.54%）。与四份独立旧资格图核对，成员 refs/relations 不变，无新增缺失目标或丢失定义；原 strict 比较仍因 include provider 变化失败，没有将它记为整图等价。
- 214 个 exact 分成 66 个严格完整上下文，30 条与 UBT 上下文相同；其来源包含 C/CC 直接编译、模块显式禁 Unity 和较小模块。没有漏掉的 UBT wrapper，也不能补造 Tier 1 成员身份。仅对 exact 模拟同模块/上下文分组，保留源类别的无限制下界为 86，跨类别为 66；这些仍未取得合并资格。

**Pitfalls / Gotchas**
- Renderer 六 UBT 的真实静态函数重定义可以由有序 2+4 拆分消除，耗时 83.4582→44.4367s，但深查出现 14 条源引用记录删除、597 条新增及目标变化。14 条已归因于两个 `__COUNTER__` 匿名注册名及 container 变化，没有整位置消失；另有 1992 个不同的闭包目标 ID 缺失仍未解决，尚不能采用。编译成功、覆盖完整和速度提升不能替代这项检查。
- 两个混合样本的旧整图比较均失败：各有 127 条共享头引用差异，涉及 63 个位置；原始 src/gen 在所有这些位置本就具有不同目标集合，合并结果采用 src 集合，无整位置消失。该归因不是自动豁免，尚未建立通用 Tier 2 准入。
- 六次混合运行发现同样 23 个已知输入清单外的依赖，own 摘要及标记相同；不声称预先封存了完整头文件闭包。实际 LSP 行为尚未验证。
- 高输出样本的三次语义运行另有 36 个未预先封存的依赖，执行时 own 摘要/标记一致。最初两 TU 对照与依赖扫描重叠 27.31s，已保留污染标记并另建空缓存复测；上述 44.4522s 使用无该扫描重叠的复测结果，顺序为合并后再测两 TU，非随机重复基准。
- 高输出样本建立独立语义基线与候选的三次原生时间合计 102.8050s，另有约 39.22s 图审计；两者为分项，不是资格流程端到端计时。单 reader 的 23.45% 收益没有证明无资格缓存的首次启动更快，后续仍须减少资格与交付的重复索引。
- 27 UBT 样本在运行前补齐 310 个头文件；已沿实际强制 include 根与 own include 边证实闭包遗漏来源。9892 份原 seal 与 946 份补充 seal 前后通过，新产物实际依赖均被覆盖；历史文件摘要可比，不补造历史不存在路径与搜索目录状态的证据。
- 2096 shard 的仅元数据解码原型从 3.2098→0.5730s，但漏检三类图 payload 损坏，不能直接替代生产完整校验，也不能外推首次资格队列的端到端收益。

**Validation**
- 私有实验保持完整源集合、原编译参数和顺序，j1/IDLE、独立空 shard；输入前后 seal 通过，OS 缓存未清，宿主非独占。
- 正向结果与旧 strict 图比较失败分别留存；本轮未修改生产索引实现、准入规则或 live cache。
- 文档结构回归 85/85、索引 spec strict validate、diff check 与新增内容脱敏扫描通过。

**Follow-ups**
- 扩大同上下文真实合并样本；优先研究分类单例与 exact 的可证明压缩，继续核查源引用到目标的完整身份。尚无新的全工程冷索引或首次资格端到端收益。

## 已归档补记（2.8.0）

以下保留 [2.8.0](release_2.8.0.md) 的脱敏收尾记录，不属于 2.9.0 的功能范围。

### 2026-10-16 — 公开镜像脱敏与 2.8.0 归档

**Task**
同步、归档并推送本轮收敛结果，推送前移除测试夹具中的私有标识。

**Implemented**
- `gtags_x1_spec` 私有 native 用例的工程 shader 路径与符号改由 `NVIM_X1_NATIVE_PROJECT_SHADER` / `NVIM_X1_NATIVE_PROJECT_SYMBOL` 提供，缺失即 skip。
- `ue_index_status_spec` 索引文件名改为中性 `sample_project`；`ue_cdb_partition_spec` 插件名改为 Sample*（与远端已脱敏版本一致）。
- `layout_handoff_spec` 子进程的 snacks.nvim 路径由父进程按 `stdpath("data")` 经 `SCAN_SNACKS_RTP` 传入，不再写死个人目录。
- Unreleased 切片归档至 `docs/release_2.8.0.md`。

**Pitfalls / Gotchas**
- 外置 denylist 只拦截部分私有标识，工程插件名、平台键与个人路径需人工补扫。

**Validation**
- `gtags_x1` 14/14（1 skip）、`ue_index_status` 29/29、`layout_handoff` 13/13、`ue_cdb_partition` 9/9。
- 串行全量 3978/3987，9 FAIL（既有顺序依赖）、2 SKIP。

**Follow-ups**
- 定位串行全量跨文件状态泄漏，恢复全绿门禁。
