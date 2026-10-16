# hana-alice/nvim 2.9.0 — Tier 1 SuperUnity 生产交付与发布重验

> 版本：2.9.0
> 仓库：https://github.com/hana-alice/nvim-dot-files
> 日期：2026-10-16
> 类型：Minor；Tier 1 二次合并、资格缓存、正常后台索引交付与失效回退。
> 发布流程：按用户授权同步、脱敏归档、提交与推送；tag 待明确请求。

## 1. 本次交付范围

- 同模块、同编译上下文、同成员类别的 UBT 按字节预算二次合并；候选先在私有目录完成编译、索引和成员覆盖验证，合格后进入普通 live CDB。
- 后台队列和重复 full 交付复用绑定输入字节的 Tier 1 收据。发布时重新检查成员、wrapper、owned overlay 与候选内容，失效块完整保留原命令。
- 临时 writer 锁竞争保留调度；超时、异常及不完整索引不再永久拒绝候选；一次 collect/reuse 内复用 owned overlay 物理名称检查，独立调用重新验证。
- 同步 `cpp-semantic-index-coverage` 规格、项目知识入口与架构总览。Tier 1 不授予严格图证明或 frozen 资格，也不预置 shard。
- 提交门禁复现并修复原生问题列表固定窗口后的构建终端交接错误，保留窗口保护、源码窗口及阶段历史标题；修正鼠标和原生 quickfix 测试的观测位置。

## 2. 验证与剩余范围

本轮提交前串行全量 `nvim --headless -l tests/run.lua` 在 `NVIM_TEST_REQUIRE_NATIVE=1`、
实际 LLVM clangd 下 **4079/4079 通过、0 FAIL、2 SKIP**。两项跳过分别是未提供私有 GTAGS
native 工程输入、当前宿主已具备能力而不适用的 PCH 不支持场景。20 个改动代码文件的测试前后
SHA-256 一致；本轮完整顺序未再出现此前的跨文件失败。
本轮同步规格、归档及知识库后，`structure` **85/85、0 FAIL、0 SKIP**；文档 diff whitespace 检查通过。

实际生产快照中，**278 个 UBT 合为 65 个 Tier 1**，保留 719 个 UBT 和 214 个 exact，
另有 2119 条 shader 兼容记录。14,319 个源的集合与内容摘要完整保留，65 个候选实际 own shard
均为 TU 且无错误。该计数只证明覆盖与采用，不能计算索引加速比。

| 实测范围 | 原 UBT | Tier 1 | 证据边界 |
|---|---:|---:|---|
| 生产 profile，5 UBT / 21 个生成源，j4，空 shard 缓存：墙钟 | 74.18 s | 29.51 s | 窄范围冷索引 2.51×，不是全工程结果 |
| 同轮 CPU 时间 | 211.61 s | 27.31 s | clangd 进程 CPU |
| 同轮峰值 working set | 3.84 GiB | 1.09 GiB | 不等于进程 commit |

两边采用相同 query-driver/cwd/config 和 clangd，源与头文件 own digest 集合一致，成员/TU 完整、无错误。
**首次资格验证另耗 49.17 s**；与候选冷索引分项相加约 78.68 s，并非端到端测量，尚未证明完全无资格缓存的首次启动更快。
操作系统文件缓存未清，正常后台队列仍运行，宿主非独占。

同输入、已有 60 个批次时，重复 full 交付 **84.75 s**，active CDB、full semantic、full background、
marker 和 live CDB 的内容及 mtime 均不变，clangd 进程保持不变；这是 full 阶段复用验收，
不是完整 UEPrepare 或冷索引耗时。

**历史全工程冷基线不能丢失或偷换**：2026-10-13 的 j12 空 shard 测量，原 UBT 为
19 分 59.6 秒 / 20 分 56.0 秒，当时 13 Batch 为 23 分 57.1 秒 / 21 分 13.1 秒。
四轮均覆盖 14,317 个源，保留相同两个 Vulkan 编译失败；未清操作系统缓存。这两对没有测得全工程提速，
也不证明新 Tier 1 的全工程收益。当前输入 j4、8 GiB 进程 commit 上限的私有基线约 42 分钟后 OOM，
只完成 11,506 / 14,319 个源；它既不构成完成基线，也不能替换历史约 20–24 分钟的测量。

本版按已确认的阶段交付方式归档，**未宣称全工程性能恢复**。收尾快照中 110 组计划已有 66 组资格通过、
65 组采用，3 组验证失败保留原 UBT，41 组尚未验证。正常队列继续处理；完整新全工程冷索引 A/B、
mixed strict/Tier 1 激活以及历史导航/性能探针仍有未完成验收。资格与采用计数属于该快照，不是持续不变的保证。

公开文档只保留通用结构与测量数值；工程路径、工作站身份、进程标识及原始实验产物保留于本地，未纳入发布归档。

## 3. 本次工作归档

以下记录保留各阶段实际验证范围；较早条目的后续事项由本节顶部的交付结果更新，不把当时的 fixture 验证追记成实机验收。

### 2026-10-16 — 保留固定问题窗口的构建交接

**Task**
处置提交前回归暴露的构建终端错误与测试顺序依赖。

**Implemented**
- `lua/ue.lua` 的 `open_terminal_command` 将新终端 buffer 交给既有 `bottom_panel.show`，删除绕过面板交接的直接换 buffer；在登记前设置构建标题。
- `ue_build_callback_spec.lua` 覆盖正常问题导航启用后的固定 quickfix host → build，核对 pin、源码窗口与历史标题。
- `keymaps_file_reference_layout_spec.lua` 用真实鼠标输入定位测试窗口；`dap_bottom_panel_spec.lua` 在原生 `copen` 入口观察临时解除固定，而不是在已允许重新固定的稍后事件上判定。
- `ide_editing_spec.lua` 在自己的 snippet buffer 中完成 Neovim 延迟排入的选择按键，退出前断言输入队列为空，避免后续鼠标测试执行残留按键并改坏源文本。

**Pitfalls / Gotchas**
- 串行失败不能一律视为测试污染：原生问题导航会固定 quickfix host，直接 `nvim_win_set_buf` 确实会触发 E1513。
- 后续 `BufWinEnter` 回调重新固定窗口属于正常保护；验证临时交接应观察实际命令入口及最终状态。
- snippet 的 `expand` / `jump` 会排入选择按键；测试立即 stop、切换或删除 buffer 会把输入留给下一个用例。不能通过恢复后续用例文本或全局丢弃输入遮掩。

**Validation**
- 构建反例修复前 3/8、修后 8/8；相关六文件顺序复现 48/54 → 54/54，轻量 UI 前缀 292/292。
- snippet → 鼠标两文件反例 11/12 → 12/12；`ide_editing` 24/24，已存在未固定 build host 的构建前置复现 8/8。
- 相同 UI 顺序前缀从 1205/1206 到 1206/1206，零失败、零跳过；鼠标源文本与光标保持预期，原生 snippet 输入没有落入后继用例。
- 最终串行全量门禁见本版本第 2 节；未用禁用 pin、假宿主或跳过断言消除失败。

**Follow-ups**
- 本轮最终全量顺序已通过；保留原生输入队列与窗口保护回归，防止后续重新引入顺序依赖。

### 2026-10-16 — Tier 1 发布输入重验与 full 交付锁重试

**Task**
让 SuperUnity 的真实索引加速能够交付，并修复继续验收时独立复现的失效候选发布与 full 丢调度问题。

**Implemented**
- `cdb_verified_batch.py` 将候选 wrapper 的 `candidate_sha256` 纳入收据和缓存门禁；`_publish.lua` 在每次发布重新校验已声明的 wrapper/member/owned-overlay 字节与候选内容，失败整块保留原 UBT。
- `_publication_async.lua` 从当前与既有 phase 的小 marker 识别批次，将小 CDB 的成员内容校验也交给既有 worker；内容哈希仅在单次发布内复用。
- `_build.lua` / `_schedule.lua` 保留临时 writer 竞争下的 phase，以既有 admission 和调度器重试；drain 不再删除这种任务，成功提前启动会消费旧 timer。
- `cdb_verified_batch.py` 区分完整的确定编译拒绝与超时/异常/未完成验证，后者不再形成永久负缓存；旧的无分类负收据会重新验证。
- `cdb_background_batch.py` 在一次 Tier 1 collect/reuse 内复用相同 owned overlay 的物理名称校验，退出时清空；保留逐次 overlay bytes 与成员 bytes 校验，下一次独立调用重新核对物理路径。

**Pitfalls / Gotchas**
- 缺少候选 digest 的旧 Tier 1 收据需要重新私有验证；reuse-only 保留原命令，不能称作旧缓存无成本复用。头文件依赖仍保持此前明确的 Tier 1 取舍。
- 现场当前 generation 仅有 hot，而 full 属于旧 generation；旧 full 的批次不能冒充当前 reader 已采用。锁竞争丢任务已由 fixture 证明，但没有足够历史日志将现场缺失唯一归因于此。
- mixed strict/Tier 1 目前会拒绝 strict 激活；盘根订阅的 watch-error 日志也不证明该盘根是原生 overflow 来源。对应方向与事实边界已记入 `cpp-semantic-index-coverage` spec。

**Validation**
- 本轮阶段交付及首次资格/冷索引成本边界已同步到 `openspec/specs/cpp-semantic-index-coverage/spec.md`，同时更新项目知识入口与架构总览；归档后的文档结构回归 85/85。本轮提交前全量结果见第 2 节。
- 发布反例修复前新增用例有 15 FAIL，修后 `index_batch_publication` 63/63；最终 required-native `index_verified_batch` 62/62，零跳过（含真实编译冲突负缓存与临时失败恢复）。独立 publisher 反例确认删除候选、修改成员与重复发布前删除候选均回退完整原命令。
- `index_publication_async` 19/19；writer 锁竞争反例修复前 4/8、修后 8/8；`index_delivery` 145/145，零跳过。
- 临时失败负缓存的定向回归修复前 1/7、修后 7/7，全部 Tier 1 非 native fixture 33/33；`index_batch_background` 22/22，覆盖 timeout → collect → 再计划重试，以及跨调用物理路径变化和同调用 overlay bytes 变化仍失效。
- 重复 full 实测暴露逐组重验同一 27128 项 overlay 的成本；两个真实缓存组只读对照中，原边界8.105 s/3次物理校验，新边界3.059 s/1次，下一独立调用2.933 s且重新校验。均复用2批、零私有索引/生产文件改写；此数据是缓存复用成本，不是 clangd 索引速度。
- `index_generation` 46/46、`index_subset_async` 11/11、`clangd_commands` 23/23、`ue_api` 66/66、`ue_platform_boundary` 20/20、`host_resource_discipline` 13/13；Lua AST lint 与 diff whitespace 检查通过。
- 私有真实 VulkanRHI 5 UBT / 30 源 → 1 Tier 1：前置验证 33.47 s，重复资格复用 1.10 s 且零改写；生产发布后的 clangd j1 冷索引 25.40 s / CPU 22.84 s / 峰值 WS 1.18 GiB，热启动 1.85 s，全部成员及候选主 shard 完整，1674 个 shard 的 bytes/mtime 未变。
- 新私有 A/B（同 j4、空 shard 缓存、config 关闭、无 query-driver profile）：同一 5 UBT /30 源的 wall 48.411→21.2198 s（2.28×），CPU125.2031→19.2656 s，峰值 WS4.11→1.18 GiB；源与头文件的实际 own digest 集合相同，所有成员/TU 完整、零编译错误。资格成本单列，OS 页缓存未清；不是完整工程或生产 profile 对照。
- 当前工程与构建的正常 full 交付已补齐，52.45 s 后 full 与 active generation 一致，真实后台 Tier 1 队列规划110组。独立生产产物审计通过：快照中的23 UBT→9批次、14319源完整保留，214 exact/2119 shader记录不丢；不是用条目数推导提速。真实 reader 已观测到完整 `background-index end`，实际缓存中的新候选 own-shard 有 IsTU 且无错误。
- **实际生产 profile 的窄 A/B**：已采用的 AugmentedReality 5 UBT/21个生成源，保留真实跨盘路径布局；同 query-driver/cwd/config、同 clangd、j4、全新私有 shard。wall74.1846→29.5116 s（2.51×）、CPU211.6094→27.3125 s、峰值WS3.84→1.09 GiB。全部源/头 own digest集合相同，成员与TU完整，零错误。前置资格49.172 s单列；后台正常proof队列仍运行，非独占宿主基准。原始测量保留于本地。
- **实际重复 full 交付通过**：60批次（248 UBT→60，749 UBT保留）时，同输入 full 运行84.75 s；active、full semantic、full background、marker、live CDB 的 bytes/mtime 全部不变，既有 reader 进程未重启。期间有 collect 尝试但无新发布，未暂停正常队列。原始测量保留于本地；这是 full 交付复用验收，不是完整 UEPrepare 或全工程冷索引计时。
- 收尾实时快照：278 UBT→65批次，其余719 UBT与214 exact保留、2119 shader记录单列；最终生产审计通过14319源SHA与完整覆盖、65收据复用和998条live CDB投影一致性。真实reader已完成该轮索引，65/65候选 own shard 均为IsTU且无错误，3055成员路径齐全。临时LSP观察器已移除，正常资格队列继续工作。

**Follow-ups**
- 当前 build 的完整 j4 冷基线在私有 8GiB process commit 上限内遇到 LLVM OOM：11506/14319 源完成、2813 缺失，所有日志和29422 shards保留。该失败不能作为完成基线或计算全工程提速；完整 A/B 仍有缺口。收尾快照110组计划中66组资格通过/65组已采用，3组验证失败仍保留原UBT，41组尚未验证；正常队列继续推进，mixed 激活仍需单独验收。

### 2026-10-16 — Tier 1 缓存接入 prepare 与 live CDB 发布

**Task**
将 Tier 1 私有验证结果接入正常 full prepare/后台发布，保留严格模式与完整源覆盖。

**Implemented**
- `cdb_verified_batch.py` 增加确定性 `_tier1_cache_key`、只读 `_tier1_candidate_spec` / `_tier1_cached` 和 `reuse_tier1`；索引指向不可变收据，成功及确定编译拒绝按 wrapper/member/owned-overlay 字节重验复用（临时失败边界由后续修复收紧），缓存命中不索引、不写文件。
- `cdb_background_batch.py` 默认 `NVIM_UE_BATCH_TIER=1`，`strict` 保留原图证明；plan/work/collect/catalog/prepare reuse 绑定模式，确定编译拒绝缓存不重复排工，collect 与 prepare 共用同一复用与编码路径。
- `_publish.lua` 校验 Tier 1 收据及同 phase 原 semantic 命令，唯一消费原 UBT 后将候选写入 live CDB；保留标准字段剥离，Tier 1 不进入 frozen/verified、不增加 batches receipts、不预置 shard。
- 无效候选整块回退并返回 `tier1_fallbacks`；原 semantic 丢失时仅由 SHA 有效的 sealed receipt 恢复原 UBT，两种基线均不可验证则保留原发布并明确失败，避免缩窄覆盖。
- 相同输入复用收据及发布 bytes/mtime；Tier 1 发布重新核验收据，篡改不能绕过 publication cache。正常 full 源码链路的 semantic 输入、proof store 与完整环境相互一致。

**Pitfalls / Gotchas**
- **头文件变化不会使 Tier 1 receipt 失效**；缓存边界仅含 wrapper、成员源、owned overlays、工具与编译环境，这是已接受的取舍，不能当作 frozen 语义证明。
- strict/Tier 1 混合 phase 的 live 覆盖有 fixture；strict 覆盖门禁会拒绝混合 authority，完整 runtime 激活仍未实测。显式外置 `batch-store.json` selector 保留既有 strict 旁路。
- 该阶段只运行隔离 fixture；未读取或修改真实工程 `.cache/nvim-ue`、live nvim/clangd 或其 shard 缓存。

**Validation**
- `index_generated_super_unity`：13 PASS / 0 FAIL / 0 SKIP；`index_generation`：46 PASS / 0 FAIL / 0 SKIP。
- `NVIM_TEST_REQUIRE_NATIVE=1` 下 `index_verified_batch`：54 PASS / 0 FAIL / 0 SKIP；`index_batch`：292 PASS / 0 FAIL / 0 SKIP。
- `index_batch_background`：20 PASS / 0 FAIL / 0 SKIP；`index_batch_publication`：47 PASS / 0 FAIL / 0 SKIP（含 Python 实际收据到 Lua live 发布的跨语言 fixture）。
- `cpp_semantic_index`：1 PASS / 0 FAIL / 0 SKIP（隔离 native clangd fixture）；`clangd_commands`：23 PASS / 0 FAIL / 0 SKIP；`ue_api`：66 PASS / 0 FAIL / 0 SKIP；`structure`：85 PASS / 0 FAIL / 0 SKIP。
- 新增 35 个缓存、后台及发布用例；独立只读审查未发现具体任务违例。两份 Python 工具 AST 解析及 `git diff --check` 通过，按任务要求未跑全量。

**Follow-ups**
- 该阶段后续由生产交付验收接续，见本版第 2 节；spec 已同步。完整工程性能仍不能由 fixture 全绿或条目数下降推导。

### 2026-10-16 — 显式 Tier 1 UBT 二次合并与字节预算

**Task**
在限时 fixture 范围实现同模块、同编译上下文、同成员类别的 Tier 1 二次合并。

**Implemented**
- `tools/build_hot_super_unity_cdb.py::secondary_unity_chunks` 以 module/context/gen-src-mixed 三元组分桶，按成员实际字节和打包；默认预算为 `8 × 393216`，支持参数与 `NVIM_UE_SUPER_UNITY_BUDGET_FACTOR`，保留 UBT 数上限和原块顺序。
- 未知源大小按超过整块预算处理并返回诊断；超大 UBT 不拆分，单 UBT 块不生成候选。显式 `max_sources` 只为既有严格调用方保留额外数量上限。
- `tools/cdb_verified_batch.py::accelerate_tier1` 提供显式 Tier 1 入口，以候选编译/索引成功、成员主 shard 完整和实际成员集合一致三门禁准入；失败保留该块原条目，receipt 标注 `tier: 1` 和门禁结果。
- Tier 1 跳过原 TU 图索引与图比较，使用独立收据及资产目录；既有 `accelerate` 严格准入入口继续保持原门禁。
- `_tier1_ubt_members` 校验原 wrapper 全文为 producer 的 canonical include 清单，防止展平时丢掉额外宏或 include 上下文。
- 在 `index_generated_super_unity_spec`、`index_verified_batch_spec` 增加 21 个分桶、字节预算和准入回退用例；`index_generation_spec`、`index_batch_background_spec` 的旧分组 fixture 改用真实临时 wrapper/member 支持大小检查，保留原断言。

**Pitfalls / Gotchas**
- Tier 1 独立收据不授予既有严格 runtime 的发布资格；该阶段的初版显式入口每次重新索引候选，资格缓存由后续条目接入。
- PCH、response/config/module 等间接输入继续沿用原验证器的拒绝策略，保留原 UBT 并报告原因。
- 该阶段只验证 fixture，不运行真实工程、用户 live nvim/clangd 或其 shard 缓存，不能据此宣称性能恢复或真实收益。
- 启动探针中的既有导航/性能及 Android、搜索等失败本次保留未解决；此前串行全量 9 FAIL 的跨文件状态泄漏同样不处理，原因是超出本次范围且任务明确禁止全量回归。

**Validation**
- `index_generated_super_unity`：13 PASS / 0 FAIL / 0 SKIP。
- `NVIM_TEST_REQUIRE_NATIVE=1` 下 `index_verified_batch`：42 PASS / 0 FAIL / 0 SKIP（包含新 Tier 1 小型 native 索引与原严格准入用例）。
- `NVIM_TEST_REQUIRE_NATIVE=1` 下 `index_batch`：270 PASS / 0 FAIL / 0 SKIP；首次 256 PASS / 14 FAIL 的原因是后台 fixture 只有假路径，补真实临时源文件后复跑全绿。
- `index_generation`：46 PASS / 0 FAIL / 0 SKIP；`index_batch_background`：14 PASS / 0 FAIL / 0 SKIP。
- `index_graph`：12 PASS / 0 FAIL / 0 SKIP；`structure`：85 PASS / 0 FAIL / 0 SKIP。
- 原 wrapper 额外宏/include 两项先复现错误准入，再验证修复后回退且索引调用为零；重复 fixture 验证资产/收据不重写及源字节变化后重新准入。
- `NVIM_TEST_REQUIRE_NATIVE=1` 下 `index_vfs_aliases`：6 PASS / 0 FAIL / 0 SKIP；两份 Python 工具 AST 解析及 `git diff --check` 均通过。

**Follow-ups**
- 该阶段后续已完成 spec 同步、生产接入及重复 full 验收，见本版第 2 节；完整 UEPrepare 和全工程性能仍待独立验收。
